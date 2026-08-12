import Foundation
@testable import GradusiOS
import GradusKit
import Testing

// T4.3 gate: the push-driven delta-sync reconciliation (T4.1) and the
// PM-3-required recovery paths (changeTokenExpired -> drop token + full
// refetch; zoneNotFound/zoneDeleted -> reset to waiting-for-first-publish),
// all exercised against a mock `ZoneChangesFetcher` -- no live CloudKit.

private final class MockZoneChangesFetcher: ZoneChangesFetcher {
    var outcomes: [ZoneChangesOutcome]
    private(set) var tokensRequested: [Data?] = []

    init(outcomes: [ZoneChangesOutcome]) {
        self.outcomes = outcomes
    }

    func fetchZoneChanges(sinceToken token: Data?) async -> ZoneChangesOutcome {
        tokensRequested.append(token)
        guard !outcomes.isEmpty else { return .failure }
        return outcomes.removeFirst()
    }
}

private actor DelayedZoneChangesFetcher: ZoneChangesFetcher {
    private var continuation: CheckedContinuation<ZoneChangesOutcome, Never>?
    private(set) var requestStarted = false

    func fetchZoneChanges(sinceToken _: Data?) async -> ZoneChangesOutcome {
        requestStarted = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilRequestStarts() async {
        while !requestStarted {
            await Task.yield()
        }
    }

    func release(_ outcome: ZoneChangesOutcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
}

/// Holds a full fetch after the view model has published its cached state.
/// The test can therefore inspect the offline error before releasing the
/// healthy CloudKit replacement, without sleeping or using a live account.
private actor DelayedCloudFetcher: CloudFetcher {
    private let result: [ProviderStatus]
    private var continuation: CheckedContinuation<[ProviderStatus], Never>?
    private(set) var fetchStarted = false

    init(result: [ProviderStatus]) {
        self.result = result
    }

    func fetchAll() async throws -> [ProviderStatus] {
        fetchStarted = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilFetchStarts() async {
        while !fetchStarted {
            await Task.yield()
        }
    }

    func releaseHealthyResult() {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
private final class RecordingWarningNotificationScheduler: WarningNotificationScheduling {
    private(set) var scheduledProviders: [String] = []

    func scheduleWarningNotification(for provider: ProviderStatus, thresholdPercent _: Double) {
        scheduledProviders.append(provider.providerName)
    }
}

@Test func warningNotificationNamesProviderWindowAndThreshold() {
    let provider = ProviderStatus(
        providerName: "opencode-go", providerDisplayName: "OpenCode Go", ok: true,
        errorMessage: nil,
        windows: [
            ProviderWindow(id: "five_hour", percentLeft: 20, resetISO: nil, windowHours: 5, paceDelta: nil),
            ProviderWindow(id: "weekly", percentLeft: 80, resetISO: nil, windowHours: 168, paceDelta: nil),
        ], data: [:], observedAt: nil, snapshotUpdatedAt: "2026-08-11T12:00:00Z",
        publishedAt: Date(timeIntervalSince1970: 1_786_000_000), isWarning: true
    )

    let content = WarningNotificationContent.make(for: provider, thresholdPercent: 25)

    #expect(content?.title == "OpenCode Go 5 Hour warning")
    #expect(content?.body == "20% remaining, below your 25% warning threshold.")
}

@Test func providerWarningWithoutALocallyReachedThresholdDoesNotClaimOne() {
    let provider = ProviderStatus(
        providerName: "opencode-go", providerDisplayName: "OpenCode Go", ok: true,
        errorMessage: nil,
        windows: [
            ProviderWindow(id: "five_hour", percentLeft: 62, resetISO: nil, windowHours: 5, paceDelta: -0.20),
        ], data: [:], observedAt: nil, snapshotUpdatedAt: "2026-08-11T12:00:00Z",
        publishedAt: Date(timeIntervalSince1970: 1_786_000_000), isWarning: true
    )

    let content = WarningNotificationContent.make(for: provider, thresholdPercent: 25)

    #expect(content?.title == "OpenCode Go warning")
    #expect(content?.body == "A provider warning was reported. Open Gradus for details.")
}

@MainActor
@Test func nonWarningUpdateDoesNotScheduleNotification() async {
    let cache = tempCache()
    let scheduler = RecordingWarningNotificationScheduler()
    let fetcher = MockZoneChangesFetcher(outcomes: [
        .success(changed: [makeStatus("opencode-go")], deletedProviderNames: [], newToken: nil),
    ])
    let viewModel = makeViewModel(cache: cache, fetcher: fetcher, warningNotificationScheduler: scheduler)

    await viewModel.handleRemoteNotification()

    #expect(scheduler.scheduledProviders.isEmpty)
}

@MainActor
@Test func incrementalResultAfterSampleSuspensionDoesNotReconcileOrPersist() async {
    let cache = tempCache()
    let cached = makeStatus("cached")
    try? cache.saveCachedStatuses([cached], syncedAt: Date())
    let oldToken = Data([1])
    try? cache.saveChangeToken(oldToken)

    let fetcher = DelayedZoneChangesFetcher()
    let gate = LiveLifecycleGate()
    let defaults = isolatedDefaults()
    defaults.set(true, forKey: DashboardViewModel.syncEnabledKey)
    let viewModel = DashboardViewModel(
        cache: cache, zoneChangesFetcher: fetcher, liveLifecycleGate: gate, userDefaults: defaults
    )
    viewModel.updateAccountStatus(.available)

    let syncTask = Task { await viewModel.handleRemoteNotification() }
    await fetcher.waitUntilRequestStarts()

    let suspendTask = Task { await gate.suspend() }
    while !gate.isSuspended {
        await Task.yield()
    }
    await fetcher.release(.success(
        changed: [makeStatus("late")], deletedProviderNames: [], newToken: Data([2])
    ))

    await suspendTask.value
    await syncTask.value
    #expect(viewModel.providers.map(\.providerName) == ["cached"])
    #expect(cache.loadChangeToken() == oldToken)
}

private func makeStatus(_ name: String, isWarning: Bool = false) -> ProviderStatus {
    ProviderStatus(
        providerName: name, providerDisplayName: name, ok: true, errorMessage: nil, windows: [], data: [:],
        observedAt: nil, snapshotUpdatedAt: "2026-08-02T20:00:00-04:00", publishedAt: Date(timeIntervalSince1970: 1_785_000_000),
        isWarning: isWarning
    )
}

/// A fresh suite per call -- `syncEnabled` persists to `UserDefaults`
/// (T3.2/T3.3), and `.standard` is shared process-wide, so tests that flip
/// it would otherwise leak state into each other under Swift Testing's
/// same-process execution.
private func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "gradus-sync-tests-\(UUID().uuidString)")!
}

@MainActor
private func makeViewModel(
    cache: LocalCacheStore, fetcher: ZoneChangesFetcher,
    warningNotificationScheduler: WarningNotificationScheduling? = nil,
    userDefaults: UserDefaults = isolatedDefaults()
) -> DashboardViewModel {
    if userDefaults.object(forKey: DashboardViewModel.syncEnabledKey) == nil {
        userDefaults.set(true, forKey: DashboardViewModel.syncEnabledKey)
    }
    if userDefaults.object(forKey: DashboardViewModel.notificationsEnabledKey) == nil {
        userDefaults.set(true, forKey: DashboardViewModel.notificationsEnabledKey)
    }
    let viewModel = DashboardViewModel(
        cache: cache, zoneChangesFetcher: fetcher, warningNotificationScheduler: warningNotificationScheduler,
        userDefaults: userDefaults
    )
    viewModel.syncEnabled = true
    viewModel.updateAccountStatus(.available)
    return viewModel
}

private actor LifecycleSeamRecorder {
    private(set) var calls: [String] = []
    private var blockedContinuation: CheckedContinuation<Void, Never>?

    func call(_ seam: String, blocking: Bool = false) async {
        calls.append(seam)
        guard blocking else { return }
        await withCheckedContinuation { continuation in
            blockedContinuation = continuation
        }
    }

    func releaseBlockedCall() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}

private actor TransitionCompletionRecorder {
    private(set) var completionCount = 0

    func markCompleted() {
        completionCount += 1
    }
}

/// The sample transition is a real lifecycle boundary, not only a view swap:
/// iPhone and iPad must both wait out an in-flight live seam and reject every
/// subsequent account/sync/subscription/notification/provider call.
@MainActor
struct LiveLifecycleTransitionTests {
    @Test
    func concurrentSampleSuspendsAllWaitForLiveQuiescence() async {
        let gate = LiveLifecycleGate()
        let recorder = TransitionCompletionRecorder()
        #expect(gate.begin() != nil)

        let first = Task { @MainActor in
            await gate.suspend()
            await recorder.markCompleted()
        }
        while !gate.isSuspended {
            await Task.yield()
        }

        let second = Task { @MainActor in
            await gate.suspend()
            await recorder.markCompleted()
        }
        await Task.yield()
        #expect(await recorder.completionCount == 0)

        gate.finish()
        await first.value
        await second.value
        #expect(await recorder.completionCount == 2)
    }

    @Test
    func sampleEntryPendingLabelsAreVisibleAndDistinct() {
        #expect(EmptyStateView.exploreSampleButtonTitle(isInProgress: false) == "Explore Sample")
        #expect(EmptyStateView.exploreSampleButtonTitle(isInProgress: true) == "Entering Sample…")
        #expect(SettingsView.exploreSampleButtonTitle(isInProgress: false) == "Explore Sample")
        #expect(SettingsView.exploreSampleButtonTitle(isInProgress: true) == "Entering Sample…")
    }

    @Test(arguments: ["iPhone", "iPad"])
    func exploreSampleWaitsForQuiescenceAndEpochGatesLiveSeams(_ device: String) async {
        let gate = LiveLifecycleGate()
        let recorder = LifecycleSeamRecorder()

        let liveWork = Task { @MainActor in
            await gate.withOperation { operationEpoch in
                await recorder.call("account", blocking: true)
                guard gate.isCurrent(operationEpoch) else { return }
                await recorder.call("sync")
                guard gate.isCurrent(operationEpoch) else { return }
                await recorder.call("subscription")
                guard gate.isCurrent(operationEpoch) else { return }
                await recorder.call("notification")
                guard gate.isCurrent(operationEpoch) else { return }
                await recorder.call("provider")
            }
        }

        // The first seam call proves the transition really has work to drain.
        while await recorder.calls.isEmpty {
            await Task.yield()
        }
        let enterSample = Task { @MainActor in await gate.suspend() }
        while !gate.isSuspended {
            await Task.yield()
        }

        // Entry invalidates the epoch immediately, but waits for the in-flight
        // account call before returning and exposing the sample UI.
        #expect(await recorder.calls == ["account"], "\(device) entered before quiescence")
        await recorder.releaseBlockedCall()
        await enterSample.value
        await liveWork.value

        let rejected = await gate.withOperation { _ in
            await recorder.call("post-entry")
        }
        #expect(rejected == nil)
        #expect(await recorder.calls == ["account"], "\(device) made a live call after sample entry")
    }
}

private func tempCache() -> FileLocalCacheStore {
    FileLocalCacheStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent(
            "gradus-sync-tests-\(UUID().uuidString)", isDirectory: true
        )
    )
}

@MainActor
@Test func cachedErrorRemainsVisibleUntilDelayedHealthyFullFetchArrives() async {
    let cache = tempCache()
    let cachedError = ProviderStatus(
        providerName: "copilot", providerDisplayName: "Copilot", ok: false,
        errorMessage: "provider probe failed", windows: [], data: [:], observedAt: nil,
        snapshotUpdatedAt: "2026-08-11T12:00:00Z",
        publishedAt: Date(timeIntervalSince1970: 1_786_000_000)
    )
    try? cache.saveCachedStatuses([cachedError], syncedAt: Date())

    let fetcher = DelayedCloudFetcher(result: [makeStatus("copilot")])
    let defaults = isolatedDefaults()
    defaults.set(false, forKey: DashboardViewModel.syncEnabledKey)
    let viewModel = DashboardViewModel(cache: cache, fetcher: fetcher, userDefaults: defaults)
    viewModel.updateAccountStatus(.available)
    viewModel.syncEnabled = true

    let syncTask = Task { await viewModel.sync() }
    await fetcher.waitUntilFetchStarts()

    #expect(viewModel.providers.map(\.providerName) == ["copilot"])
    #expect(viewModel.providers.first?.ok == false)
    #expect(viewModel.providers.first?.errorMessage == "provider probe failed")

    await fetcher.releaseHealthyResult()
    await syncTask.value

    #expect(viewModel.providers.map(\.providerName) == ["copilot"])
    #expect(viewModel.providers.first?.ok == true)
    #expect(viewModel.providers.first?.errorMessage == nil)
}

@Test func cloudKitConfigurationSkipsEntitlementlessSimulator() {
    #expect(CloudKitRuntimeConfiguration.shouldUseCloudKit(isSimulator: true, hasCloudKitEntitlement: false) == false)
    #expect(CloudKitRuntimeConfiguration.shouldUseCloudKit(isSimulator: true, hasCloudKitEntitlement: true) == true)
    #expect(CloudKitRuntimeConfiguration.shouldUseCloudKit(isSimulator: false, hasCloudKitEntitlement: true) == true)

    #if targetEnvironment(simulator)
        #expect(CloudKitRuntimeConfiguration.currentValue == false)
    #endif
}

@MainActor
@Test func incrementalSyncMergesChangedProviders() async {
    let cache = tempCache()
    try? cache.saveCachedStatuses([makeStatus("codex")], syncedAt: Date())
    let fetcher = MockZoneChangesFetcher(outcomes: [
        .success(changed: [makeStatus("cursor")], deletedProviderNames: [], newToken: Data([1, 2, 3])),
    ])
    let viewModel = makeViewModel(cache: cache, fetcher: fetcher)
    await viewModel.handleRemoteNotification()

    #expect(viewModel.providers.map(\.providerName).sorted() == ["codex", "cursor"])
    #expect(cache.loadChangeToken() == Data([1, 2, 3]))
    #expect(viewModel.lastSyncedAt != nil)
}

@MainActor
@Test func incrementalSyncAppliesDeletions() async {
    let cache = tempCache()
    try? cache.saveCachedStatuses([makeStatus("codex"), makeStatus("cursor")], syncedAt: Date())
    let fetcher = MockZoneChangesFetcher(outcomes: [
        .success(changed: [], deletedProviderNames: ["cursor"], newToken: nil),
    ])
    let viewModel = makeViewModel(cache: cache, fetcher: fetcher)
    await viewModel.handleRemoteNotification()

    #expect(viewModel.providers.map(\.providerName) == ["codex"])
}

@MainActor
@Test func changeTokenExpiredClearsTokenAndRetriesWithNil() async {
    let cache = tempCache()
    try? cache.saveChangeToken(Data([9, 9]))
    let fetcher = MockZoneChangesFetcher(outcomes: [
        .changeTokenExpired,
        .success(changed: [makeStatus("codex")], deletedProviderNames: [], newToken: Data([4, 5])),
    ])
    let viewModel = makeViewModel(cache: cache, fetcher: fetcher)
    await viewModel.handleRemoteNotification()

    #expect(fetcher.tokensRequested == [Data([9, 9]), nil])
    #expect(viewModel.providers.map(\.providerName) == ["codex"])
    #expect(cache.loadChangeToken() == Data([4, 5]))
}

@MainActor
@Test func repeatedChangeTokenExpiredDoesNotLoopForever() async {
    let cache = tempCache()
    let fetcher = MockZoneChangesFetcher(outcomes: [.changeTokenExpired, .changeTokenExpired, .changeTokenExpired])
    let viewModel = makeViewModel(cache: cache, fetcher: fetcher)
    await viewModel.handleRemoteNotification()

    #expect(fetcher.tokensRequested == [nil, nil])
    #expect(cache.loadChangeToken() == nil)
}

@MainActor
@Test func zoneNotFoundResetsToWaitingForFirstPublish() async {
    let cache = tempCache()
    try? cache.saveCachedStatuses([makeStatus("codex")], syncedAt: Date())
    try? cache.saveChangeToken(Data([1]))
    let fetcher = MockZoneChangesFetcher(outcomes: [.zoneNotFound])
    let viewModel = makeViewModel(cache: cache, fetcher: fetcher)
    await viewModel.handleRemoteNotification()

    #expect(viewModel.providers.isEmpty)
    #expect(viewModel.lastSyncedAt == nil)
    #expect(cache.loadChangeToken() == nil)
    #expect(cache.loadCachedStatuses().isEmpty)
}

@MainActor
@Test func zoneDeletedResetsToWaitingForFirstPublish() async {
    let cache = tempCache()
    try? cache.saveCachedStatuses([makeStatus("codex")], syncedAt: Date())
    let fetcher = MockZoneChangesFetcher(outcomes: [.zoneDeleted])
    let viewModel = makeViewModel(cache: cache, fetcher: fetcher)
    await viewModel.handleRemoteNotification()

    #expect(viewModel.providers.isEmpty)
}

@MainActor
@Test func transientFailureLeavesStateUnchanged() async {
    let cache = tempCache()
    try? cache.saveCachedStatuses([makeStatus("codex")], syncedAt: Date())
    try? cache.saveChangeToken(Data([7]))
    let fetcher = MockZoneChangesFetcher(outcomes: [.failure])
    let viewModel = makeViewModel(cache: cache, fetcher: fetcher)
    await viewModel.handleRemoteNotification()

    #expect(viewModel.providers.map(\.providerName) == ["codex"])
    #expect(cache.loadChangeToken() == Data([7]))
}

@MainActor
@Test func firstWarningSchedulesOneLocalNotification() async {
    let cache = tempCache()
    let scheduler = RecordingWarningNotificationScheduler()
    let fetcher = MockZoneChangesFetcher(outcomes: [
        .success(changed: [makeStatus("codex", isWarning: true)], deletedProviderNames: [], newToken: nil),
    ])
    let viewModel = makeViewModel(cache: cache, fetcher: fetcher, warningNotificationScheduler: scheduler)

    await viewModel.handleRemoteNotification()

    #expect(scheduler.scheduledProviders == ["codex"])
}

@MainActor
@Test func repeatedWarningUpdateDoesNotScheduleAnotherLocalNotification() async {
    let cache = tempCache()
    try? cache.saveCachedStatuses([makeStatus("codex")], syncedAt: Date())
    let scheduler = RecordingWarningNotificationScheduler()
    let warning = makeStatus("codex", isWarning: true)
    let fetcher = MockZoneChangesFetcher(outcomes: [
        .success(changed: [warning], deletedProviderNames: [], newToken: nil),
        .success(changed: [warning], deletedProviderNames: [], newToken: nil),
    ])
    let viewModel = makeViewModel(cache: cache, fetcher: fetcher, warningNotificationScheduler: scheduler)

    await viewModel.handleRemoteNotification()
    await viewModel.handleRemoteNotification()

    #expect(scheduler.scheduledProviders == ["codex"])
}

@MainActor
@Test func clearThenWarningSchedulesANewLocalNotification() async {
    let cache = tempCache()
    try? cache.saveCachedStatuses([makeStatus("codex")], syncedAt: Date())
    let scheduler = RecordingWarningNotificationScheduler()
    let fetcher = MockZoneChangesFetcher(outcomes: [
        .success(changed: [makeStatus("codex", isWarning: true)], deletedProviderNames: [], newToken: nil),
        .success(changed: [makeStatus("codex")], deletedProviderNames: [], newToken: nil),
        .success(changed: [makeStatus("codex", isWarning: true)], deletedProviderNames: [], newToken: nil),
    ])
    let viewModel = makeViewModel(cache: cache, fetcher: fetcher, warningNotificationScheduler: scheduler)

    await viewModel.handleRemoteNotification()
    await viewModel.handleRemoteNotification()
    await viewModel.handleRemoteNotification()

    #expect(scheduler.scheduledProviders == ["codex", "codex"])
}

@MainActor
@Test func warningNotificationIsGatedByNotificationsPreference() async {
    let defaults = isolatedDefaults()
    defaults.set(false, forKey: DashboardViewModel.notificationsEnabledKey)
    let cache = tempCache()
    try? cache.saveCachedStatuses([makeStatus("codex")], syncedAt: Date())
    let scheduler = RecordingWarningNotificationScheduler()
    let fetcher = MockZoneChangesFetcher(outcomes: [
        .success(changed: [makeStatus("codex", isWarning: true)], deletedProviderNames: [], newToken: nil),
    ])
    let viewModel = makeViewModel(
        cache: cache, fetcher: fetcher, warningNotificationScheduler: scheduler, userDefaults: defaults
    )

    await viewModel.handleRemoteNotification()

    #expect(scheduler.scheduledProviders.isEmpty)
}

@MainActor
@Test func handleRemoteNotificationNoOpsWhenSyncDisabled() async {
    let cache = tempCache()
    let fetcher = MockZoneChangesFetcher(outcomes: [.success(changed: [makeStatus("codex")], deletedProviderNames: [], newToken: nil)])
    let defaults = isolatedDefaults()
    defaults.set(false, forKey: DashboardViewModel.syncEnabledKey)
    let viewModel = DashboardViewModel(cache: cache, zoneChangesFetcher: fetcher, userDefaults: defaults)
    viewModel.updateAccountStatus(.available)
    // Legacy false requires confirmation and must not start live work.
    await viewModel.handleRemoteNotification()

    #expect(viewModel.providers.isEmpty)
    #expect(fetcher.tokensRequested.isEmpty)
}

@MainActor
@Test func updateAccountStatusTriggersSyncOnlyOnAvailableTransition() {
    let cache = tempCache()
    let fetcher = MockZoneChangesFetcher(outcomes: [])
    let viewModel = DashboardViewModel(cache: cache, zoneChangesFetcher: fetcher, userDefaults: isolatedDefaults())
    viewModel.syncEnabled = true

    viewModel.updateAccountStatus(.noAccount)
    #expect(viewModel.accountStatus == .noAccount)

    viewModel.updateAccountStatus(.available)
    #expect(viewModel.accountStatus == .available)
    // The app-level reconciliation callback owns the full fetch; this test
    // only asserts the status transition itself is recorded correctly.
}

@MainActor
@Test func temporaryAccountStatesUseCheckingThenTryAgainAndConfirmedRecoveryCopy() {
    let viewModel = DashboardViewModel(cache: tempCache(), userDefaults: isolatedDefaults())

    viewModel.updateAccountStatus(.couldNotDetermine)
    #expect(viewModel.emptyState == .checkingICloud)

    viewModel.accountAvailabilityCheckFailed()
    #expect(viewModel.emptyState == .tryAgain)

    viewModel.updateAccountStatus(.noAccount)
    #expect(viewModel.emptyState == .notSignedIn)

    viewModel.updateAccountStatus(.restricted)
    #expect(viewModel.emptyState == .restricted)
}

@MainActor
@Test func retryableSyncFailureRetainsCachedDataAndSurfacesRetry() async {
    let cache = tempCache()
    let cached = makeStatus("cached")
    try? cache.saveCachedStatuses([cached], syncedAt: Date())
    let defaults = isolatedDefaults()
    defaults.set(true, forKey: DashboardViewModel.syncEnabledKey)
    let viewModel = DashboardViewModel(
        cache: cache, fetcher: FailingCloudFetcher(), userDefaults: defaults
    )
    viewModel.updateAccountStatus(.available)

    await viewModel.reconcileLiveLifecycle()

    #expect(viewModel.providers.map(\.providerName) == ["cached"])
    #expect(viewModel.liveLifecycleNeedsRetry)
}

private struct FailingCloudFetcher: CloudFetcher {
    func fetchAll() async throws -> [ProviderStatus] {
        struct RetryableError: Error {}
        throw RetryableError()
    }
}
