import Foundation
@testable import GradusiOS
import GradusKit
import Testing

// T4.3 gate: the push-driven delta-sync reconciliation (T4.1) and the
// PM-3-required recovery paths (changeTokenExpired -> drop token + full
// refetch; zoneNotFound/zoneDeleted -> reset to waiting-for-first-publish),
// all exercised against a mock `ZoneChangesFetcher` -- no live CloudKit.
//
// Split across four files to stay under SwiftLint's file_length limit: this
// file (the T4.3 gate itself), DashboardViewModelWarningNotificationTests.swift
// (warning notification content and scheduling), and
// DashboardViewModelAccountLifecycleTests.swift (account status, retry, and
// live/sample lifecycle transitions), all sharing fixtures declared in
// DashboardViewModelSyncFixtures.swift.

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
@Test func incrementalResultAfterSampleSuspensionDoesNotReconcileOrPersist() async {
    let cache = syncTempCache()
    let cached = makeStatus("cached")
    try? cache.saveCachedStatuses([cached], syncedAt: Date())
    let oldToken = Data([1])
    try? cache.saveChangeToken(oldToken)

    let fetcher = DelayedZoneChangesFetcher()
    let gate = LiveLifecycleGate()
    let defaults = syncIsolatedDefaults()
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

@MainActor
@Test func cachedErrorRemainsVisibleUntilDelayedHealthyFullFetchArrives() async {
    let cache = syncTempCache()
    let cachedError = ProviderStatus(
        providerName: "copilot", providerDisplayName: "Copilot", ok: false,
        errorMessage: "provider probe failed", windows: [], data: [:], observedAt: nil,
        snapshotUpdatedAt: "2026-08-11T12:00:00Z",
        publishedAt: Date(timeIntervalSince1970: 1_786_000_000)
    )
    try? cache.saveCachedStatuses([cachedError], syncedAt: Date())

    let fetcher = DelayedCloudFetcher(result: [makeStatus("copilot")])
    let defaults = syncIsolatedDefaults()
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
    let cache = syncTempCache()
    try? cache.saveCachedStatuses([makeStatus("codex")], syncedAt: Date())
    let fetcher = MockZoneChangesFetcher(outcomes: [
        .success(changed: [makeStatus("cursor")], deletedProviderNames: [], newToken: Data([1, 2, 3]))
    ])
    let viewModel = makeViewModel(cache: cache, fetcher: fetcher)
    await viewModel.handleRemoteNotification()

    #expect(viewModel.providers.map(\.providerName).sorted() == ["codex", "cursor"])
    #expect(cache.loadChangeToken() == Data([1, 2, 3]))
    #expect(viewModel.lastSyncedAt != nil)
}

@MainActor
@Test func incrementalSyncAppliesDeletions() async {
    let cache = syncTempCache()
    try? cache.saveCachedStatuses([makeStatus("codex"), makeStatus("cursor")], syncedAt: Date())
    let fetcher = MockZoneChangesFetcher(outcomes: [
        .success(changed: [], deletedProviderNames: ["cursor"], newToken: nil)
    ])
    let viewModel = makeViewModel(cache: cache, fetcher: fetcher)
    await viewModel.handleRemoteNotification()

    #expect(viewModel.providers.map(\.providerName) == ["codex"])
}

@MainActor
@Test func changeTokenExpiredClearsTokenAndRetriesWithNil() async {
    let cache = syncTempCache()
    try? cache.saveChangeToken(Data([9, 9]))
    let fetcher = MockZoneChangesFetcher(outcomes: [
        .changeTokenExpired,
        .success(changed: [makeStatus("codex")], deletedProviderNames: [], newToken: Data([4, 5]))
    ])
    let viewModel = makeViewModel(cache: cache, fetcher: fetcher)
    await viewModel.handleRemoteNotification()

    #expect(fetcher.tokensRequested == [Data([9, 9]), nil])
    #expect(viewModel.providers.map(\.providerName) == ["codex"])
    #expect(cache.loadChangeToken() == Data([4, 5]))
}

@MainActor
@Test func repeatedChangeTokenExpiredDoesNotLoopForever() async {
    let cache = syncTempCache()
    let fetcher = MockZoneChangesFetcher(outcomes: [.changeTokenExpired, .changeTokenExpired, .changeTokenExpired])
    let viewModel = makeViewModel(cache: cache, fetcher: fetcher)
    await viewModel.handleRemoteNotification()

    #expect(fetcher.tokensRequested == [nil, nil])
    #expect(cache.loadChangeToken() == nil)
}

@MainActor
@Test func zoneNotFoundResetsToWaitingForFirstPublish() async {
    let cache = syncTempCache()
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
    let cache = syncTempCache()
    try? cache.saveCachedStatuses([makeStatus("codex")], syncedAt: Date())
    let fetcher = MockZoneChangesFetcher(outcomes: [.zoneDeleted])
    let viewModel = makeViewModel(cache: cache, fetcher: fetcher)
    await viewModel.handleRemoteNotification()

    #expect(viewModel.providers.isEmpty)
}

@MainActor
@Test func transientFailureLeavesStateUnchanged() async {
    let cache = syncTempCache()
    try? cache.saveCachedStatuses([makeStatus("codex")], syncedAt: Date())
    try? cache.saveChangeToken(Data([7]))
    let fetcher = MockZoneChangesFetcher(outcomes: [.failure])
    let viewModel = makeViewModel(cache: cache, fetcher: fetcher)
    await viewModel.handleRemoteNotification()

    #expect(viewModel.providers.map(\.providerName) == ["codex"])
    #expect(cache.loadChangeToken() == Data([7]))
}
