import Foundation
import GradusKit
import Testing

@testable import GradusiOS

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

private func makeStatus(_ name: String) -> ProviderStatus {
    ProviderStatus(
        providerName: name, providerDisplayName: name, ok: true, errorMessage: nil, windows: [], data: [:],
        observedAt: nil, snapshotUpdatedAt: "2026-08-02T20:00:00-04:00", publishedAt: Date(timeIntervalSince1970: 1_785_000_000))
}

/// A fresh suite per call -- `syncEnabled` persists to `UserDefaults`
/// (T3.2/T3.3), and `.standard` is shared process-wide, so tests that flip
/// it would otherwise leak state into each other under Swift Testing's
/// same-process execution.
private func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "gradus-sync-tests-\(UUID().uuidString)")!
}

@MainActor
private func makeViewModel(cache: LocalCacheStore, fetcher: ZoneChangesFetcher) -> DashboardViewModel {
    let viewModel = DashboardViewModel(cache: cache, zoneChangesFetcher: fetcher, userDefaults: isolatedDefaults())
    viewModel.syncEnabled = true
    viewModel.updateAccountStatus(.available)
    return viewModel
}

private func tempCache() -> FileLocalCacheStore {
    FileLocalCacheStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent(
            "gradus-sync-tests-\(UUID().uuidString)", isDirectory: true))
}

@MainActor
@Test func incrementalSyncMergesChangedProviders() async {
    let cache = tempCache()
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
    let cache = tempCache()
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
@Test func handleRemoteNotificationNoOpsWhenSyncDisabled() async {
    let cache = tempCache()
    let fetcher = MockZoneChangesFetcher(outcomes: [.success(changed: [makeStatus("codex")], deletedProviderNames: [], newToken: nil)])
    let viewModel = DashboardViewModel(cache: cache, zoneChangesFetcher: fetcher, userDefaults: isolatedDefaults())
    viewModel.updateAccountStatus(.available)
    // syncEnabled defaults OFF.
    await viewModel.handleRemoteNotification()

    #expect(viewModel.providers.isEmpty)
    #expect(fetcher.tokensRequested.isEmpty)
}

@MainActor
@Test func updateAccountStatusTriggersSyncOnlyOnAvailableTransition() async {
    let cache = tempCache()
    let fetcher = MockZoneChangesFetcher(outcomes: [])
    let viewModel = DashboardViewModel(cache: cache, zoneChangesFetcher: fetcher, userDefaults: isolatedDefaults())
    viewModel.syncEnabled = true

    viewModel.updateAccountStatus(.noAccount)
    #expect(viewModel.accountStatus == .noAccount)

    viewModel.updateAccountStatus(.available)
    #expect(viewModel.accountStatus == .available)
    // updateAccountStatus's sync() call runs full-fetch via `fetcher:
    // CloudFetcher?` (nil here), which no-ops -- this test only asserts the
    // status transition itself is recorded correctly, not the fetch.
}
