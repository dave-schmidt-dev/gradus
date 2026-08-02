import CloudKit
import Foundation

/// Abstraction over "what is the current CloudKit account status" so tests
/// can inject a fake without touching a real iCloud account.
public protocol AccountStatusSource: Sendable {
    func currentAccountStatus() async throws -> CKAccountStatus
}

/// Real, production-backed source: asks the named container.
public struct ContainerAccountStatusSource: AccountStatusSource {
    private let container: CKContainer

    public init(containerIdentifier: String) {
        self.container = CKContainer(identifier: containerIdentifier)
    }

    public func currentAccountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }
}

/// Tracks CloudKit account status and reacts to account changes mid-session
/// (user signs out of iCloud, switches accounts, etc. while the app is
/// running). Exposes a simple ready/blocked classification so the publish
/// pipeline can gate on it without matching on every CKAccountStatus case
/// itself.
public actor AccountStatusMonitor {
    public enum PublishingState: Equatable, Sendable {
        case ready
        case blocked(CKAccountStatus)
    }

    private let source: AccountStatusSource
    private let onChange: @Sendable (CKAccountStatus) -> Void
    public private(set) var lastKnownStatus: CKAccountStatus = .couldNotDetermine
    private var notificationTask: Task<Void, Never>?

    public init(source: AccountStatusSource, onChange: @escaping @Sendable (CKAccountStatus) -> Void) {
        self.source = source
        self.onChange = onChange
    }

    /// Fetch the current status once and begin observing `.CKAccountChanged`
    /// for the rest of the process lifetime.
    public func start() async {
        await refresh()
        startObserving()
    }

    /// Re-fetch account status. On a transient fetch error, `lastKnownStatus`
    /// is left unchanged (never crash, never silently mark ready) and
    /// `onChange` is NOT called — callers should treat "no update" as "still
    /// whatever it was."
    public func refresh() async {
        do {
            let status = try await source.currentAccountStatus()
            lastKnownStatus = status
            onChange(status)
        } catch {
            // Leave lastKnownStatus untouched; a future refresh (e.g. the
            // next `.CKAccountChanged` notification) may succeed.
        }
    }

    private func startObserving() {
        notificationTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .CKAccountChanged) {
                guard let self else { return }
                await self.refresh()
            }
        }
    }

    public func stopObserving() {
        notificationTask?.cancel()
        notificationTask = nil
    }

    /// Maps a raw `CKAccountStatus` to whether the publish pipeline should
    /// proceed. Only `.available` is ready; every other case (including
    /// `.couldNotDetermine`, which is not one of the four named states in
    /// the spec but IS a real enum case that must compile exhaustively)
    /// blocks publishing.
    public nonisolated static func publishingState(for status: CKAccountStatus) -> PublishingState {
        status == .available ? .ready : .blocked(status)
    }

    deinit {
        notificationTask?.cancel()
    }
}
