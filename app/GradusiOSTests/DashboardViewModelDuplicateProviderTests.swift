import Foundation
@testable import GradusiOS
import GradusKit
import Testing

// Regression for 2026-10-07: a duplicate provider name reached the cached
// provider list, and every silent push then trapped in
// `Dictionary(uniqueKeysWithValues:)` inside `reconcile`, before the new data
// could be saved. The dashboard stayed 39 hours stale and the app closed on
// each refresh.

private struct DuplicateFullFetcher: CloudFetcher {
    let statuses: [ProviderStatus]

    func fetchAll() async throws -> [ProviderStatus] {
        statuses
    }
}

@MainActor
@Test func pushAfterDuplicateCachedProviderReconcilesInsteadOfTrapping() async {
    let cache = syncTempCache()
    try? cache.saveCachedStatuses(
        [makeStatus("codex"), makeStatus("claude"), makeStatus("claude", isWarning: true)],
        syncedAt: Date()
    )
    let fetcher = MockZoneChangesFetcher(outcomes: [
        .success(changed: [makeStatus("cursor")], deletedProviderNames: [], newToken: Data([4]))
    ])
    let viewModel = makeViewModel(cache: cache, fetcher: fetcher)

    await viewModel.handleRemoteNotification()

    #expect(viewModel.providers.map(\.providerName).sorted() == ["claude", "codex", "cursor"])
    #expect(cache.loadChangeToken() == Data([4]))
    #expect(Set(cache.loadCachedStatuses().map(\.providerName)).count == cache.loadCachedStatuses().count)
}

@MainActor
@Test func pushWithRepeatedChangedProviderKeepsOneEntry() async {
    let cache = syncTempCache()
    try? cache.saveCachedStatuses([makeStatus("codex")], syncedAt: Date())
    let fetcher = MockZoneChangesFetcher(outcomes: [
        .success(
            changed: [makeStatus("claude"), makeStatus("claude", isWarning: true)],
            deletedProviderNames: [], newToken: Data([5])
        )
    ])
    let viewModel = makeViewModel(cache: cache, fetcher: fetcher)

    await viewModel.handleRemoteNotification()

    #expect(viewModel.providers.map(\.providerName).sorted() == ["claude", "codex"])
    #expect(viewModel.providers.first { $0.providerName == "claude" }?.isWarning == true)
}

@MainActor
@Test func fullSyncWithDuplicateRecordsStoresOneEntryPerProvider() async {
    let defaults = syncIsolatedDefaults()
    defaults.set(true, forKey: DashboardViewModel.syncEnabledKey)
    let cache = syncTempCache()
    let viewModel = DashboardViewModel(
        cache: cache,
        fetcher: DuplicateFullFetcher(
            statuses: [makeStatus("claude"), makeStatus("codex"), makeStatus("claude", isWarning: true)]
        ),
        userDefaults: defaults
    )
    viewModel.updateAccountStatus(.available)

    #expect(await viewModel.sync())

    #expect(viewModel.providers.map(\.providerName).sorted() == ["claude", "codex"])
    #expect(cache.loadCachedStatuses().map(\.providerName).sorted() == ["claude", "codex"])
}
