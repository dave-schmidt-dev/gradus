import Foundation

/// Watches the public sidecar's parent directory so an atomic replacement is
/// observed even though the old file inode has disappeared.
@MainActor
public final class BankedObservationWatcher {
    private enum FileRevision: Equatable {
        case missing
        case contents(Data)
    }

    public let fileURL: URL
    private let directoryURL: URL
    private let retryDelay: TimeInterval
    private let coalescingDelay: TimeInterval
    private let onChange: @MainActor @Sendable () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var rereadWorkItem: DispatchWorkItem?
    private var retryWorkItem: DispatchWorkItem?
    private var isRunning = false
    private var generation: UInt64 = 0
    private var lastObservedRevision: FileRevision?

    /// Tests inject a temporary snapshot URL; production passes its one
    /// canonical snapshot URL. The watcher derives the sibling from that URL.
    public init(
        snapshotFileURL: URL,
        retryDelay: TimeInterval = 2,
        coalescingDelay: TimeInterval = 0.05,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        fileURL = BankedObservation.fileURL(for: snapshotFileURL)
        directoryURL = fileURL.deletingLastPathComponent()
        self.retryDelay = retryDelay
        self.coalescingDelay = coalescingDelay
        self.onChange = onChange
    }

    deinit { source?.cancel() }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        generation &+= 1
        lastObservedRevision = nil
        let activeGeneration = generation
        scheduleReread(immediately: true, generation: activeGeneration)
        watchDirectory(generation: activeGeneration)
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
    }

    /// The pipeline rereads on its serial executor and joins against the
    /// current v2 token. A malformed or missing file reports nil.
    public func currentObservation() -> BankedObservation? {
        BankedObservation.read(from: fileURL)
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
        // An atomic replacement can fall between the initial read and the
        // descriptor becoming active; close that gap with another comparison.
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
                scheduleReread(generation: expectedGeneration)
            }
        }
        retryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: workItem)
    }

    private func scheduleReread(immediately: Bool = false, generation expectedGeneration: UInt64) {
        guard isCurrent(expectedGeneration) else { return }
        rereadWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, isCurrent(expectedGeneration) else { return }
                rereadWorkItem = nil
                rereadFile()
            }
        }
        rereadWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (immediately ? 0 : coalescingDelay), execute: workItem
        )
    }

    private func rereadFile() {
        let revision = (try? Data(contentsOf: fileURL)).map(FileRevision.contents) ?? .missing
        guard revision != lastObservedRevision else { return }
        lastObservedRevision = revision
        onChange()
    }

    private func isCurrent(_ expectedGeneration: UInt64) -> Bool {
        isRunning && generation == expectedGeneration
    }
}
