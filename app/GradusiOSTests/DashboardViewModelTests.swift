import CloudKit
import Foundation
import GradusKit
import Testing

@testable import GradusiOS

private func dashboardPreferenceDefaults() -> UserDefaults {
    UserDefaults(suiteName: "gradus-dashboard-preferences-\(UUID().uuidString)")!
}

private func dashboardPreferenceCache() -> FileLocalCacheStore {
    FileLocalCacheStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent(
            "gradus-dashboard-preferences-\(UUID().uuidString)", isDirectory: true))
}

private let fixedTestDate = Date(timeIntervalSince1970: 1_785_000_000)

@MainActor
@Test func showExhaustedDefaultsVisibleAndPreferencesPersistLocally() throws {
    let defaults = dashboardPreferenceDefaults()
    let cache = dashboardPreferenceCache()
    let exhausted = ProviderStatus(
        providerName: "exhausted", providerDisplayName: "Exhausted", ok: true, errorMessage: nil,
        windows: [ProviderWindow(id: "weekly", percentLeft: 0, resetISO: nil, windowHours: 168, paceDelta: nil)],
        data: [:], observedAt: nil, snapshotUpdatedAt: "2026-08-04T12:00:00Z", publishedAt: Date())
    try? cache.saveCachedStatuses([exhausted], syncedAt: Date())

    let viewModel = DashboardViewModel(cache: cache, userDefaults: defaults)
    #expect(viewModel.showExhausted)
    #expect(viewModel.providers.map(\.providerName) == ["exhausted"])

    viewModel.showExhausted = false
    viewModel.providerSortOption = .nameAZ
    let reloaded = DashboardViewModel(cache: cache, userDefaults: defaults)
    #expect(!reloaded.showExhausted)
    #expect(reloaded.providerSortOption == .nameAZ)
    #expect(reloaded.providers.isEmpty)

    // Preferences remain view-model state: the provider payload has no local
    // sort/filter fields to serialize into CloudKit's ProviderStatus record.
    let payload = try JSONEncoder().encode(exhausted)
    let payloadText = try #require(String(data: payload, encoding: .utf8))
    #expect(!payloadText.contains(DashboardViewModel.providerSortOptionKey))
    #expect(!payloadText.contains(DashboardViewModel.showExhaustedKey))
}



@MainActor
@Test func connectedSourceUsesNewestPublishedMetadataEvenWhenExhaustedIsHidden() throws {
    let olderSource = SyncSource(computerName: "Older Mac", userName: "old-user")
    let newerSource = SyncSource(computerName: "Dave's MacBook Pro", userName: "dave")
    let older = ProviderStatus(
        providerName: "codex", providerDisplayName: "Codex", ok: true, errorMessage: nil,
        windows: [ProviderWindow(id: "weekly", percentLeft: 80, resetISO: nil, windowHours: 168, paceDelta: nil)],
        data: [:], observedAt: nil, snapshotUpdatedAt: "2026-08-04T12:00:00Z",
        publishedAt: fixedTestDate, syncSource: olderSource)
    let newerExhausted = ProviderStatus(
        providerName: "cursor", providerDisplayName: "Cursor", ok: true, errorMessage: nil,
        windows: [ProviderWindow(id: "weekly", percentLeft: 0, resetISO: nil, windowHours: 168, paceDelta: nil)],
        data: [:], observedAt: nil, snapshotUpdatedAt: "2026-08-04T12:05:00Z",
        publishedAt: fixedTestDate.addingTimeInterval(60), syncSource: newerSource)
    let cache = dashboardPreferenceCache()
    try cache.saveCachedStatuses([older, newerExhausted], syncedAt: fixedTestDate)
    let defaults = dashboardPreferenceDefaults()
    defaults.set(false, forKey: DashboardViewModel.showExhaustedKey)

    let viewModel = DashboardViewModel(cache: cache, userDefaults: defaults)

    #expect(viewModel.connectedSource == newerSource)
    #expect(viewModel.connectedSourcePublishedAt == newerExhausted.publishedAt)
    #expect(viewModel.providers.map(\.providerName) == ["codex"])
}





