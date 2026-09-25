import Foundation

/// Watches the refresh agent's public status file without coupling status
/// presentation to snapshot delivery. The agent replaces its JSON atomically,
/// so the directory (rather than the file inode) is watched.
@MainActor
public final class BackgroundAgentStatusObserver {
    public static let canonicalFilename = "agent-status.json"

    public static func statusFileURL(for snapshotFileURL: URL) -> URL {
        snapshotFileURL.deletingLastPathComponent().appendingPathComponent(canonicalFilename)
    }

    private enum FileRevision: Equatable {
        case missing
        case contents(Data)
    }

    private let statusFileURL: URL
    private let directoryURL: URL
    private let retryDelay: TimeInterval
    private let coalescingDelay: TimeInterval
    private let staleRefreshInterval: TimeInterval
    private let onChange: @MainActor @Sendable () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var rereadWorkItem: DispatchWorkItem?
    private var retryWorkItem: DispatchWorkItem?
    private var staleTimer: DispatchSourceTimer?
    private var isRunning = false
    private var generation: UInt64 = 0
    private var lastObservedRevision: FileRevision?

    /// The URL is injectable so tests never observe the installed user's state.
    /// Only the canonical credential-free filename is accepted: watching any
    /// other file here would widen the UI's filesystem boundary by accident.
    public init(
        statusFileURL: URL,
        retryDelay: TimeInterval = 2,
        coalescingDelay: TimeInterval = 0.05,
        staleRefreshInterval: TimeInterval = 60,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        precondition(statusFileURL.lastPathComponent == Self.canonicalFilename)
        self.statusFileURL = statusFileURL
        directoryURL = statusFileURL.deletingLastPathComponent()
        self.retryDelay = retryDelay
        self.coalescingDelay = coalescingDelay
        self.staleRefreshInterval = staleRefreshInterval
        self.onChange = onChange
    }

    /// Production wiring keeps agent-status events constrained to the local
    /// presentation state owned by `PublisherViewModel`.
    public convenience init(statusFileURL: URL, viewModel: PublisherViewModel) {
        self.init(statusFileURL: statusFileURL) { [weak viewModel] in
            viewModel?.refreshBackgroundAgentState()
        }
    }

    public convenience init(
        snapshotFileURL: URL,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        self.init(statusFileURL: Self.statusFileURL(for: snapshotFileURL), onChange: onChange)
    }

    deinit {
        source?.cancel()
        staleTimer?.cancel()
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        generation &+= 1
        lastObservedRevision = nil
        let activeGeneration = generation
        scheduleReread(immediately: true, generation: activeGeneration)
        watchDirectory(generation: activeGeneration)
        startStaleTimer(generation: activeGeneration)
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        generation &+= 1
        rereadWorkItem?.cancel()
        rereadWorkItem = nil
        retryWorkItem?.cancel()
        retryWorkItem = nil
        source?.cancel()
        source = nil
        staleTimer?.cancel()
        staleTimer = nil
    }

    private func watchDirectory(generation expectedGeneration: UInt64) {
        guard isCurrent(expectedGeneration), source == nil else { return }
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            scheduleRetry(generation: expectedGeneration)
            return
        }

        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .global(qos: .utility)
        )
        newSource.setEventHandler { [weak self] in
            let events = newSource.data
            Task { @MainActor [weak self] in
                self?.handleDirectoryEvent(events, generation: expectedGeneration)
            }
        }
        newSource.setCancelHandler { close(descriptor) }
        newSource.resume()
        source = newSource
        // Close the gap between the read that motivated this watch and the
        // descriptor becoming active, including a directory recreated while a
        // retry was pending.
        scheduleReread(generation: expectedGeneration)
    }

    private func handleDirectoryEvent(
        _ events: DispatchSource.FileSystemEvent,
        generation expectedGeneration: UInt64
    ) {
        guard isCurrent(expectedGeneration) else { return }
        if !events.isDisjoint(with: [.delete, .rename]) {
            source?.cancel()
            source = nil
            scheduleReread(generation: expectedGeneration)
            watchDirectory(generation: expectedGeneration)
            return
        }
        scheduleReread(generation: expectedGeneration)
    }

    private func scheduleRetry(generation expectedGeneration: UInt64) {
        guard isCurrent(expectedGeneration), retryWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, isCurrent(expectedGeneration) else { return }
                retryWorkItem = nil
                watchDirectory(generation: expectedGeneration)
            }
        }
        retryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: workItem)
    }

    private func scheduleReread(
        immediately: Bool = false,
        generation expectedGeneration: UInt64
    ) {
        guard isCurrent(expectedGeneration) else { return }
        rereadWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, isCurrent(expectedGeneration) else { return }
                rereadWorkItem = nil
                rereadStatusFile()
            }
        }
        rereadWorkItem = workItem
        let delay = immediately ? 0 : coalescingDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func rereadStatusFile() {
        // Compare only the canonical file. Directory sources report sibling
        // writes too, but those must not refresh presentation state. The
        // manager/resolver still owns malformed and missing-file semantics.
        let revision = (try? Data(contentsOf: statusFileURL)).map(FileRevision.contents)
            ?? .missing
        guard revision != lastObservedRevision else { return }
        lastObservedRevision = revision
        onChange()
    }

    private func startStaleTimer(generation expectedGeneration: UInt64) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + staleRefreshInterval,
            repeating: staleRefreshInterval,
            leeway: .milliseconds(50)
        )
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, isCurrent(expectedGeneration) else { return }
                onChange()
            }
        }
        timer.resume()
        staleTimer = timer
    }

    private func isCurrent(_ expectedGeneration: UInt64) -> Bool {
        isRunning && generation == expectedGeneration
    }
}
