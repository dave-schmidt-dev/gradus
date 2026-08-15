import CloudKit
import Foundation
@testable import GradusiOS
import GradusKit
import Testing

private func dashboardPreferenceDefaults() -> UserDefaults {
    UserDefaults(suiteName: "gradus-dashboard-preferences-\(UUID().uuidString)")!
}

private func dashboardPreferenceCache() -> FileLocalCacheStore {
    FileLocalCacheStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent(
            "gradus-dashboard-preferences-\(UUID().uuidString)", isDirectory: true
        )
    )
}

private let fixedTestDate = Date(timeIntervalSince1970: 1_785_000_000)

@Test func requiredICloudMigrationPreservesLegacyPresenceAndPrecedence() throws {
    let suite = "gradus-required-icloud-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(false, forKey: DashboardViewModel.syncEnabledKey)
    #expect(
        RequiredICloudMigration.migrate(defaults: defaults, legacyKey: DashboardViewModel.syncEnabledKey)
            == .awaitingConfirmation
    )
    #expect(defaults.object(forKey: DashboardViewModel.syncEnabledKey) == nil)

    let trueSuite = "gradus-required-icloud-true-\(UUID().uuidString)"
    let trueDefaults = try #require(UserDefaults(suiteName: trueSuite))
    defer { trueDefaults.removePersistentDomain(forName: trueSuite) }
    trueDefaults.set(true, forKey: DashboardViewModel.syncEnabledKey)
    #expect(
        RequiredICloudMigration.migrate(defaults: trueDefaults, legacyKey: DashboardViewModel.syncEnabledKey)
            == .confirmed
    )

    defaults.set(true, forKey: DashboardViewModel.syncEnabledKey)
    defaults.set(RequiredICloudMode.awaitingConfirmation.rawValue, forKey: RequiredICloudMigration.modeKey)
    #expect(
        RequiredICloudMigration.migrate(defaults: defaults, legacyKey: DashboardViewModel.syncEnabledKey)
            == .awaitingConfirmation
    )
}

@Test func requiredICloudMigrationFreshAndInterruptedWritesAreDeterministic() throws {
    let freshSuite = "gradus-required-icloud-fresh-\(UUID().uuidString)"
    let fresh = try #require(UserDefaults(suiteName: freshSuite))
    defer { fresh.removePersistentDomain(forName: freshSuite) }
    #expect(
        RequiredICloudMigration.migrate(defaults: fresh, legacyKey: DashboardViewModel.syncEnabledKey)
            == .confirmed
    )

    let interruptedSuite = "gradus-required-icloud-interrupted-\(UUID().uuidString)"
    let interrupted = try #require(UserDefaults(suiteName: interruptedSuite))
    defer { interrupted.removePersistentDomain(forName: interruptedSuite) }
    interrupted.set(false, forKey: DashboardViewModel.syncEnabledKey)
    let interruptedMode = RequiredICloudMigration.migrate(
        defaults: interrupted,
        legacyKey: DashboardViewModel.syncEnabledKey,
        writeMode: { _, _ in }
    )
    #expect(interruptedMode == .awaitingConfirmation)
    #expect(interrupted.object(forKey: DashboardViewModel.syncEnabledKey) as? Bool == false)
    #expect(interrupted.object(forKey: RequiredICloudMigration.modeKey) == nil)
    #expect(
        RequiredICloudMigration.migrate(defaults: interrupted, legacyKey: DashboardViewModel.syncEnabledKey)
            == .awaitingConfirmation
    )
    #expect(interrupted.object(forKey: DashboardViewModel.syncEnabledKey) == nil)
}

@MainActor
@Test func requiredICloudModeConfirmsAndSurvivesRelaunch() throws {
    let suite = "gradus-required-icloud-relaunch-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let cache = dashboardPreferenceCache()
    defaults.set(false, forKey: DashboardViewModel.syncEnabledKey)

    let awaiting = DashboardViewModel(cache: cache, userDefaults: defaults)
    #expect(awaiting.requiredICloudMode == .awaitingConfirmation)
    #expect(!awaiting.syncEnabled)
    awaiting.syncEnabled = true

    let relaunched = DashboardViewModel(cache: cache, userDefaults: defaults)
    #expect(relaunched.requiredICloudMode == .confirmed)
    #expect(relaunched.syncEnabled)
    #expect(defaults.object(forKey: DashboardViewModel.syncEnabledKey) == nil)
    #expect(
        defaults.integer(forKey: DashboardViewModel.requiredICloudModeVersionKey)
            == DashboardViewModel.requiredICloudModeVersion
    )
}

@MainActor
@Test func showExhaustedDefaultsVisibleAndPreferencesPersistLocally() throws {
    let defaults = dashboardPreferenceDefaults()
    let cache = dashboardPreferenceCache()
    let exhausted = ProviderStatus(
        providerName: "exhausted", providerDisplayName: "Exhausted", ok: true, errorMessage: nil,
        windows: [ProviderWindow(id: "weekly", percentLeft: 0, resetISO: nil, windowHours: 168, paceDelta: nil)],
        data: [:], observedAt: nil, snapshotUpdatedAt: "2026-08-04T12:00:00Z", publishedAt: Date()
    )
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
        publishedAt: fixedTestDate, syncSource: olderSource
    )
    let newerExhausted = ProviderStatus(
        providerName: "cursor", providerDisplayName: "Cursor", ok: true, errorMessage: nil,
        windows: [ProviderWindow(id: "weekly", percentLeft: 0, resetISO: nil, windowHours: 168, paceDelta: nil)],
        data: [:], observedAt: nil, snapshotUpdatedAt: "2026-08-04T12:05:00Z",
        publishedAt: fixedTestDate.addingTimeInterval(60), syncSource: newerSource
    )
    let cache = dashboardPreferenceCache()
    try cache.saveCachedStatuses([older, newerExhausted], syncedAt: fixedTestDate)
    let defaults = dashboardPreferenceDefaults()
    defaults.set(false, forKey: DashboardViewModel.showExhaustedKey)

    let viewModel = DashboardViewModel(cache: cache, userDefaults: defaults)

    #expect(viewModel.connectedSource == newerSource)
    #expect(viewModel.connectedSourcePublishedAt == newerExhausted.publishedAt)
    #expect(viewModel.providers.map(\.providerName) == ["codex"])
}
