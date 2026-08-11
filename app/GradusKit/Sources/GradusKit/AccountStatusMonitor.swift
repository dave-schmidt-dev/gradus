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

/// Holds a `NotificationCenter` observer token so it can be unregistered from a
/// `nonisolated deinit`.
///
/// The raw token is `any NSObjectProtocol`, which is not `Sendable`, so Swift 6
/// refuses to touch it outside the actor. The token is never used *as* an
/// object — it is only handed straight back to `NotificationCenter`, which is
/// itself thread-safe — so `@unchecked Sendable` is accurate here rather than a
/// suppression.
private final class ObserverToken: @unchecked Sendable {
    private let token: any NSObjectProtocol
    private let center: NotificationCenter

    init(_ token: any NSObjectProtocol, center: NotificationCenter) {
        self.token = token
        self.center = center
    }

    func remove() {
        center.removeObserver(token)
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
    private let notificationCenter: NotificationCenter
    private let onChange: @Sendable (CKAccountStatus) -> Void
    public private(set) var lastKnownStatus: CKAccountStatus = .couldNotDetermine
    private var observerToken: ObserverToken?
    /// Set by `stopObserving()` before sample-mode entry waits for this actor.
    /// Already-running account requests are awaited by the actor; callbacks
    /// queued after the stop are rejected before touching CloudKit.
    private var refreshesSuspended = false
    /// Invalidates an in-flight refresh even if a new live lifecycle starts
    /// before that old request returns.
    private var lifecycleGeneration: UInt64 = 0

    /// - Parameter notificationCenter: Injectable so tests can post
    ///   `.CKAccountChanged` to an isolated center. Sharing the process-wide
    ///   `.default` means one test's post reaches every other test's monitor,
    ///   which Swift Testing's parallel execution turns into cross-test
    ///   interference.
    public init(
        source: AccountStatusSource,
        notificationCenter: NotificationCenter = .default,
        onChange: @escaping @Sendable (CKAccountStatus) -> Void
    ) {
        self.source = source
        self.notificationCenter = notificationCenter
        self.onChange = onChange
    }

    /// Fetch the current status once and begin observing `.CKAccountChanged`
    /// for the rest of the process lifetime.
    public func start() async {
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        refreshesSuspended = false
        await refresh()
        guard !refreshesSuspended, generation == lifecycleGeneration else { return }
        startObserving()
    }

    /// Re-fetch account status. On a transient fetch error, `lastKnownStatus`
    /// is left unchanged (never crash, never silently mark ready) and
    /// `onChange` is NOT called — callers should treat "no update" as "still
    /// whatever it was."
    public func refresh() async {
        guard !refreshesSuspended else { return }
        let generation = lifecycleGeneration
        do {
            let status = try await source.currentAccountStatus()
            // Actor reentrancy permits `stopObserving()` to run while the
            // account request is suspended. Do not publish a result from a
            // request that completed after observation was stopped.
            guard !refreshesSuspended, generation == lifecycleGeneration else { return }
            lastKnownStatus = status
            onChange(status)
        } catch {
            // Leave lastKnownStatus untouched; a future refresh (e.g. the
            // next `.CKAccountChanged` notification) may succeed.
        }
    }

    /// Registers the `.CKAccountChanged` observer.
    ///
    /// `addObserver` registers synchronously, so once this returns there is no
    /// window in which a posted notification can be missed. The previous form
    /// — `Task { for await _ in NotificationCenter.default.notifications(...) }`
    /// — returned as soon as the Task was *created*, but that sequence does not
    /// subscribe until the child task first iterates it. A `.CKAccountChanged`
    /// posted in between was silently dropped (found 2026-08-05: the test for
    /// this behavior only passed because it slept 10ms first, which is also
    /// what made the suite flake under load).
    ///
    /// Tradeoff accepted: the old `for await` loop awaited each `refresh()`
    /// before pulling the next notification, so refreshes were serialized. This
    /// form spawns one Task per post, so N rapid notifications produce N
    /// concurrent refreshes that can interleave — the older status could win the
    /// final assignment. `.CKAccountChanged` is user-driven (signing out of
    /// iCloud, switching accounts), so bursts are not a real pattern, and both
    /// call sites (`GradusiOSApp`, `GradusMacApp`) only read `lastKnownStatus`
    /// to gate publishing, which the next refresh corrects. Revisit if a
    /// programmatic source ever posts this notification in a loop.
    private func startObserving() {
        observerToken = ObserverToken(
            notificationCenter.addObserver(
                forName: .CKAccountChanged,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { await self?.refresh() }
            },
            center: notificationCenter
        )
    }

    public func stopObserving() {
        refreshesSuspended = true
        lifecycleGeneration &+= 1
        observerToken?.remove()
        observerToken = nil
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
        observerToken?.remove()
    }
}
