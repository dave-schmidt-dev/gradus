import GradusKit
import SnapshotTesting
import SwiftUI
import Testing

@testable import GradusiOS

// P5/T5.3 gate: three-group `SettingsView` layout (Sync & Notifications,
// Warning Threshold, About), toggle-on/off states, light+dark -- following
// `DashboardSnapshotTests.swift`'s exact `.image(layout: .fixed)` pattern.
// No live CloudKit: `DashboardViewModel` is built without a
// `subscriptionManager`, so the toggles render straight from seeded
// `UserDefaults` state.

private let fixedNow = Date(timeIntervalSince1970: 1_785_000_000)

/// A fresh suite per call, matching `DashboardViewModelSyncTests.swift`'s
/// `isolatedDefaults()` -- `syncEnabled`/`notificationsEnabled` persist to
/// `UserDefaults`, and `.standard` is shared process-wide.
private func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "gradus-settings-snapshot-tests-\(UUID().uuidString)")!
}

private func sampleProviders() -> [ProviderStatus] {
    [
        ProviderStatus(
            providerName: "codex",
            providerDisplayName: "Codex",
            ok: true,
            errorMessage: nil,
            windows: [
                ProviderWindow(
                    id: "weekly", percentLeft: 62, resetISO: "2026-08-08T05:00:00-04:00", windowHours: 168,
                    paceDelta: -0.05)
            ],
            data: [:],
            observedAt: ISO8601DateFormatter().string(from: fixedNow.addingTimeInterval(-30)),
            snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
            publishedAt: fixedNow
        ),
        ProviderStatus(
            providerName: "cursor",
            providerDisplayName: "Cursor",
            ok: false,
            errorMessage: "transient fetch failure",
            windows: [],
            data: [:],
            observedAt: nil,
            snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
            publishedAt: fixedNow
        ),
    ]
}

@MainActor
private func makeViewModel(syncEnabled: Bool, notificationsEnabled: Bool) -> DashboardViewModel {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-settings-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
    let cache = FileLocalCacheStore(directory: directory)
    try? cache.saveCachedStatuses(sampleProviders(), syncedAt: fixedNow)
    let defaults = isolatedDefaults()
    defaults.set(syncEnabled, forKey: DashboardViewModel.syncEnabledKey)
    defaults.set(notificationsEnabled, forKey: DashboardViewModel.notificationsEnabledKey)
    return DashboardViewModel(cache: cache, userDefaults: defaults)
}

@MainActor
@Test func settingsViewAllTogglesOnLight() {
    let viewModel = makeViewModel(syncEnabled: true, notificationsEnabled: true)
    let view = SettingsView(dashboardViewModel: viewModel)
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 390, height: 500), traits: UITraitCollection(userInterfaceStyle: .light)))
}

@MainActor
@Test func settingsViewAllTogglesOnDark() {
    let viewModel = makeViewModel(syncEnabled: true, notificationsEnabled: true)
    let view = SettingsView(dashboardViewModel: viewModel)
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 390, height: 500), traits: UITraitCollection(userInterfaceStyle: .dark)))
}

@MainActor
@Test func settingsViewTogglesOffLight() {
    let viewModel = makeViewModel(syncEnabled: false, notificationsEnabled: false)
    let view = SettingsView(dashboardViewModel: viewModel)
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 390, height: 500), traits: UITraitCollection(userInterfaceStyle: .light)))
}

@MainActor
@Test func settingsViewTogglesOffDark() {
    let viewModel = makeViewModel(syncEnabled: false, notificationsEnabled: false)
    let view = SettingsView(dashboardViewModel: viewModel)
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 390, height: 500), traits: UITraitCollection(userInterfaceStyle: .dark)))
}
