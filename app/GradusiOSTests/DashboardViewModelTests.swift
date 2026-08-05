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

private let selectionTestDate = Date(timeIntervalSince1970: 1_785_000_000)

private func selectionProvider(_ name: String, windows: [ProviderWindow]) -> ProviderStatus {
    ProviderStatus(
        providerName: name, providerDisplayName: name, ok: true, errorMessage: nil,
        windows: windows, data: [:], observedAt: nil,
        snapshotUpdatedAt: "2026-08-04T12:00:00Z", publishedAt: selectionTestDate)
}

private final class SelectionCloudFetcher: CloudFetcher {
    let result: [ProviderStatus]

    init(result: [ProviderStatus]) {
        self.result = result
    }

    func fetchAll() async throws -> [ProviderStatus] { result }
}

private final class SelectionZoneChangesFetcher: ZoneChangesFetcher {
    let outcome: ZoneChangesOutcome

    init(outcome: ZoneChangesOutcome) {
        self.outcome = outcome
    }

    func fetchZoneChanges(sinceToken: Data?) async -> ZoneChangesOutcome { outcome }
}

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
@Test func selectedWindowDefaultsToDeterministicWorstValidWindow() throws {
    let provider = selectionProvider("codex", windows: [
        ProviderWindow(id: "z-window", percentLeft: 20, resetISO: nil, windowHours: 168, paceDelta: nil),
        ProviderWindow(id: "a-window", percentLeft: 20, resetISO: nil, windowHours: 168, paceDelta: nil),
        ProviderWindow(id: "invalid", percentLeft: 101, resetISO: nil, windowHours: 168, paceDelta: nil),
    ])
    let cache = dashboardPreferenceCache()
    try cache.saveCachedStatuses([provider], syncedAt: selectionTestDate)

    let viewModel = DashboardViewModel(cache: cache, userDefaults: dashboardPreferenceDefaults())

    #expect(viewModel.selectedWindowIDs.isEmpty)
    #expect(viewModel.selectedWindow(for: provider)?.id == "a-window")
}

@MainActor
@Test func defaultWindowFollowsWorstWindowAcrossFullSync() async throws {
    let initial = selectionProvider("codex", windows: [
        ProviderWindow(id: "weekly", percentLeft: 10, resetISO: nil, windowHours: 168, paceDelta: nil),
        ProviderWindow(id: "monthly", percentLeft: 50, resetISO: nil, windowHours: 720, paceDelta: nil),
    ])
    let updated = selectionProvider("codex", windows: [
        ProviderWindow(id: "weekly", percentLeft: 80, resetISO: nil, windowHours: 168, paceDelta: nil),
        ProviderWindow(id: "monthly", percentLeft: 20, resetISO: nil, windowHours: 720, paceDelta: nil),
    ])
    let cache = dashboardPreferenceCache()
    try cache.saveCachedStatuses([initial], syncedAt: selectionTestDate)
    let defaults = dashboardPreferenceDefaults()
    defaults.set(true, forKey: DashboardViewModel.syncEnabledKey)
    let viewModel = DashboardViewModel(
        cache: cache, fetcher: SelectionCloudFetcher(result: [updated]), userDefaults: defaults)
    viewModel.updateAccountStatus(.available)

    await viewModel.sync()

    #expect(viewModel.selectedWindowIDs.isEmpty)
    #expect(viewModel.selectedWindow(for: updated)?.id == "monthly")
}

@MainActor
@Test func connectedSourceUsesNewestPublishedMetadataEvenWhenExhaustedIsHidden() throws {
    let olderSource = SyncSource(computerName: "Older Mac", userName: "old-user")
    let newerSource = SyncSource(computerName: "Dave's MacBook Pro", userName: "dave")
    let older = ProviderStatus(
        providerName: "codex", providerDisplayName: "Codex", ok: true, errorMessage: nil,
        windows: [ProviderWindow(id: "weekly", percentLeft: 80, resetISO: nil, windowHours: 168, paceDelta: nil)],
        data: [:], observedAt: nil, snapshotUpdatedAt: "2026-08-04T12:00:00Z",
        publishedAt: selectionTestDate, syncSource: olderSource)
    let newerExhausted = ProviderStatus(
        providerName: "cursor", providerDisplayName: "Cursor", ok: true, errorMessage: nil,
        windows: [ProviderWindow(id: "weekly", percentLeft: 0, resetISO: nil, windowHours: 168, paceDelta: nil)],
        data: [:], observedAt: nil, snapshotUpdatedAt: "2026-08-04T12:05:00Z",
        publishedAt: selectionTestDate.addingTimeInterval(60), syncSource: newerSource)
    let cache = dashboardPreferenceCache()
    try cache.saveCachedStatuses([older, newerExhausted], syncedAt: selectionTestDate)
    let defaults = dashboardPreferenceDefaults()
    defaults.set(false, forKey: DashboardViewModel.showExhaustedKey)

    let viewModel = DashboardViewModel(cache: cache, userDefaults: defaults)

    #expect(viewModel.connectedSource == newerSource)
    #expect(viewModel.connectedSourcePublishedAt == newerExhausted.publishedAt)
    #expect(viewModel.providers.map(\.providerName) == ["codex"])
}

@MainActor
@Test func selectedWindowPreservesExactIDAcrossFullSync() async throws {
    let initial = selectionProvider("codex", windows: [
        ProviderWindow(id: "weekly", percentLeft: 10, resetISO: nil, windowHours: 168, paceDelta: nil),
        ProviderWindow(id: "monthly", percentLeft: 50, resetISO: nil, windowHours: 720, paceDelta: nil),
    ])
    let updated = selectionProvider("codex", windows: [
        ProviderWindow(id: "weekly", percentLeft: 1, resetISO: nil, windowHours: 168, paceDelta: nil),
        ProviderWindow(id: "monthly", percentLeft: 90, resetISO: nil, windowHours: 720, paceDelta: nil),
    ])
    let cache = dashboardPreferenceCache()
    try cache.saveCachedStatuses([initial], syncedAt: selectionTestDate)
    let defaults = dashboardPreferenceDefaults()
    defaults.set(true, forKey: DashboardViewModel.syncEnabledKey)
    let viewModel = DashboardViewModel(
        cache: cache, fetcher: SelectionCloudFetcher(result: [updated]), userDefaults: defaults)
    viewModel.selectWindow(providerName: "codex", windowID: "monthly")
    viewModel.updateAccountStatus(.available)

    await viewModel.sync()

    #expect(viewModel.selectedWindowIDs == ["codex": "monthly"])
    #expect(viewModel.selectedWindow(for: updated)?.id == "monthly")
}

@MainActor
@Test func selectedWindowFallsBackWhenExactIDDisappears() async throws {
    let initial = selectionProvider("codex", windows: [
        ProviderWindow(id: "weekly", percentLeft: 10, resetISO: nil, windowHours: 168, paceDelta: nil),
        ProviderWindow(id: "monthly", percentLeft: 50, resetISO: nil, windowHours: 720, paceDelta: nil),
    ])
    let updated = selectionProvider("codex", windows: [
        ProviderWindow(id: "monthly", percentLeft: 50, resetISO: nil, windowHours: 720, paceDelta: nil),
        ProviderWindow(id: "invalid", percentLeft: 101, resetISO: nil, windowHours: 168, paceDelta: nil),
    ])
    let cache = dashboardPreferenceCache()
    try cache.saveCachedStatuses([initial], syncedAt: selectionTestDate)
    let defaults = dashboardPreferenceDefaults()
    defaults.set(true, forKey: DashboardViewModel.syncEnabledKey)
    let viewModel = DashboardViewModel(
        cache: cache, fetcher: SelectionCloudFetcher(result: [updated]), userDefaults: defaults)
    viewModel.selectWindow(providerName: "codex", windowID: "weekly")
    viewModel.updateAccountStatus(.available)

    await viewModel.sync()

    #expect(viewModel.selectedWindowIDs.isEmpty)
    #expect(viewModel.selectedWindow(for: updated)?.id == "monthly")
}

@MainActor
@Test func selectedWindowIsNilWhenProviderHasNoValidWindows() throws {
    let provider = selectionProvider("codex", windows: [
        ProviderWindow(id: "negative", percentLeft: -1, resetISO: nil, windowHours: 168, paceDelta: nil),
        ProviderWindow(id: "over", percentLeft: 101, resetISO: nil, windowHours: 168, paceDelta: nil),
    ])
    let cache = dashboardPreferenceCache()
    try cache.saveCachedStatuses([provider], syncedAt: selectionTestDate)

    let viewModel = DashboardViewModel(cache: cache, userDefaults: dashboardPreferenceDefaults())

    #expect(viewModel.selectedWindowIDs.isEmpty)
    #expect(viewModel.selectedWindow(for: provider) == nil)
}

@MainActor
@Test func selectedWindowPreservesThenFallsBackAcrossIncrementalReconcile() async throws {
    let initial = selectionProvider("codex", windows: [
        ProviderWindow(id: "weekly", percentLeft: 10, resetISO: nil, windowHours: 168, paceDelta: nil),
        ProviderWindow(id: "monthly", percentLeft: 50, resetISO: nil, windowHours: 720, paceDelta: nil),
    ])
    let updateWithSelection = selectionProvider("codex", windows: [
        ProviderWindow(id: "weekly", percentLeft: 1, resetISO: nil, windowHours: 168, paceDelta: nil),
        ProviderWindow(id: "monthly", percentLeft: 90, resetISO: nil, windowHours: 720, paceDelta: nil),
    ])
    let updateWithoutSelection = selectionProvider("codex", windows: [
        ProviderWindow(id: "weekly", percentLeft: 40, resetISO: nil, windowHours: 168, paceDelta: nil),
        ProviderWindow(id: "invalid", percentLeft: 101, resetISO: nil, windowHours: 168, paceDelta: nil),
    ])
    let cache = dashboardPreferenceCache()
    try cache.saveCachedStatuses([initial], syncedAt: selectionTestDate)
    let defaults = dashboardPreferenceDefaults()
    defaults.set(true, forKey: DashboardViewModel.syncEnabledKey)

    let firstFetcher = SelectionZoneChangesFetcher(outcome: .success(
        changed: [updateWithSelection], deletedProviderNames: [], newToken: nil))
    let viewModel = DashboardViewModel(
        cache: cache, zoneChangesFetcher: firstFetcher, userDefaults: defaults)
    viewModel.selectWindow(providerName: "codex", windowID: "monthly")
    viewModel.updateAccountStatus(.available)
    await viewModel.handleRemoteNotification()
    #expect(viewModel.selectedWindowIDs == ["codex": "monthly"])

    let secondFetcher = SelectionZoneChangesFetcher(outcome: .success(
        changed: [updateWithoutSelection], deletedProviderNames: [], newToken: nil))
    let secondViewModel = DashboardViewModel(
        cache: cache, zoneChangesFetcher: secondFetcher, userDefaults: defaults)
    secondViewModel.selectWindow(providerName: "codex", windowID: "monthly")
    secondViewModel.updateAccountStatus(.available)
    await secondViewModel.handleRemoteNotification()

    #expect(secondViewModel.selectedWindowIDs.isEmpty)
    #expect(secondViewModel.selectedWindow(forProviderName: "codex")?.id == "weekly")
}

@MainActor
@Test func selectionStateNeverEntersProviderPayloadOrCloudKitRecord() throws {
    let provider = selectionProvider("codex", windows: [
        ProviderWindow(id: "weekly", percentLeft: 10, resetISO: nil, windowHours: 168, paceDelta: nil),
    ])
    let cache = dashboardPreferenceCache()
    try cache.saveCachedStatuses([provider], syncedAt: selectionTestDate)
    let viewModel = DashboardViewModel(cache: cache, userDefaults: dashboardPreferenceDefaults())
    viewModel.selectWindow(providerName: "codex", windowID: "weekly")

    let encoded = try JSONEncoder().encode(provider)
    let payload = try #require(String(data: encoded, encoding: .utf8))
    #expect(!payload.contains("selectedWindow"))
    #expect(!payload.contains("windowID"))

    let zoneID = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)
    let record = try provider.toCKRecord(zoneID: zoneID)
    #expect(record["selectedWindow"] == nil)
    #expect(record["selectedWindowID"] == nil)
    #expect(record["windowID"] == nil)
}
