import GradusKit
import SnapshotTesting
import SwiftUI
import Testing

@testable import GradusiOS

// P5/T5.3 gate: four-group `SettingsView` layout (Sync & Notifications,
// Local Display, Warning Threshold, About), toggle-on/off states, light+dark -- following
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
@Test func settingsControlsBindToLiveLocalPreferencesAndPersist() {
    let defaults = isolatedDefaults()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-settings-local-controls-\(UUID().uuidString)", isDirectory: true)
    let viewModel = DashboardViewModel(cache: FileLocalCacheStore(directory: directory), userDefaults: defaults)

    #expect(ProviderSortOption.allCases.map(\.title) == ["Most urgent", "Reset soonest", "Name A-Z"])
    for option in ProviderSortOption.allCases {
        viewModel.providerSortOption = option
        #expect(defaults.string(forKey: DashboardViewModel.providerSortOptionKey) == option.rawValue)
        #expect(viewModel.providerSortOption == option)
    }
    viewModel.showExhausted = false

    #expect(defaults.bool(forKey: DashboardViewModel.showExhaustedKey) == false)
    #expect(viewModel.showExhausted == false)
}

/// Tall enough to contain every control, including the last one.
///
/// Raised from 500 when the density picker was added (2026-08-06): at 500 the
/// new control fell below the viewport, so the baselines would have been
/// re-recorded — showing a real diff, since the section caption above it also
/// changed — while covering none of the pixels of the thing that was added. A
/// fixed-height snapshot of a scrolling screen silently stops testing whatever
/// grows past its bottom edge, and it does so by *passing*.
///
/// Anything appended to `SettingsView` must check it still fits here.
private let settingsSnapshotHeight: CGFloat = 760

@MainActor
@Test func settingsViewAllTogglesOnLight() {
    let viewModel = makeViewModel(syncEnabled: true, notificationsEnabled: true)
    let view = SettingsView(dashboardViewModel: viewModel)
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 390, height: settingsSnapshotHeight), traits: UITraitCollection(userInterfaceStyle: .light)))
}

@MainActor
@Test func settingsViewAllTogglesOnDark() {
    let viewModel = makeViewModel(syncEnabled: true, notificationsEnabled: true)
    let view = SettingsView(dashboardViewModel: viewModel)
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 390, height: settingsSnapshotHeight), traits: UITraitCollection(userInterfaceStyle: .dark)))
}

@MainActor
@Test func settingsViewTogglesOffLight() {
    let viewModel = makeViewModel(syncEnabled: false, notificationsEnabled: false)
    let view = SettingsView(dashboardViewModel: viewModel)
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 390, height: settingsSnapshotHeight), traits: UITraitCollection(userInterfaceStyle: .light)))
}

@MainActor
@Test func settingsViewTogglesOffDark() {
    let viewModel = makeViewModel(syncEnabled: false, notificationsEnabled: false)
    let view = SettingsView(dashboardViewModel: viewModel)
    assertSnapshot(
        of: view, as: .image(layout: .fixed(width: 390, height: settingsSnapshotHeight), traits: UITraitCollection(userInterfaceStyle: .dark)))
}
