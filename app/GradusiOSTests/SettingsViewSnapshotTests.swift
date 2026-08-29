@testable import GradusiOS
import GradusKit
import SnapshotTesting
import SwiftUI
import Testing

// P5/T5.3 gate: four-group `SettingsView` layout (Warning alerts,
// Local Display, Warning Threshold, About), notification-on/off states, light+dark -- following
// `DashboardSnapshotTests.swift`'s exact `.image(layout: .fixed)` pattern.
// No live CloudKit: `DashboardViewModel` is built without a
// `subscriptionManager`, so the notification control renders straight from seeded
// `UserDefaults` state.

private let fixedNow = Date(timeIntervalSince1970: 1_785_000_000)

/// Opt in only while intentionally refreshing these baselines:
/// OTHER_SWIFT_FLAGS='$(inherited) -D SETTINGS_SNAPSHOT_RECORD'
private let settingsSnapshotRecording: SnapshotTestingConfiguration.Record = {
    #if SETTINGS_SNAPSHOT_RECORD
        return .all
    #else
        return .never
    #endif
}()

/// A fresh suite per call, matching `DashboardViewModelSyncTests.swift`'s
/// `isolatedDefaults()` -- `notificationsEnabled` persists to `UserDefaults`,
/// and `.standard` is shared process-wide.
private func isolatedDefaults(_ test: String = #function) -> UserDefaults {
    scratchDefaults("settings-snapshot", test)!
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
                    paceDelta: -0.05
                )
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
        )
    ]
}

/// Reports a fixed authorization state, standing in for
/// `notificationSettings()`. Deliberately a second copy of the stub in
/// `NotificationAuthorizationTests.swift` rather than a shared one: both are
/// three lines, and sharing it would couple two files whose only real
/// relationship is using the same protocol.
private struct StubAuthorizationSource: NotificationAuthorizationSource {
    let authorization: NotificationAuthorization

    func currentAuthorization() async -> NotificationAuthorization {
        authorization
    }
}

@MainActor
private func makeViewModel(
    notificationsEnabled: Bool, systemAuthorization: NotificationAuthorization? = nil,
    test: String = #function
) -> DashboardViewModel {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-settings-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
    let cache = FileLocalCacheStore(directory: directory)
    let providers = sampleProviders()
    #expect(providers.contains { $0.ok && !$0.windows.isEmpty })
    #expect(providers.contains { !$0.ok && $0.windows.isEmpty })
    try? cache.saveCachedStatuses(providers, syncedAt: fixedNow)
    let defaults = isolatedDefaults(test)
    defaults.set(notificationsEnabled, forKey: DashboardViewModel.notificationsEnabledKey)
    return DashboardViewModel(
        cache: cache,
        notificationAuthorizationSource: systemAuthorization.map { StubAuthorizationSource(authorization: $0) },
        userDefaults: defaults
    )
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
    #expect(viewModel.cardColumnPreference == 0)
    for columns in [0, 1, 3] {
        viewModel.cardColumnPreference = columns
        #expect(defaults.integer(forKey: DashboardViewModel.cardColumnPreferenceKey) == columns)
        #expect(viewModel.cardColumnPreference == columns)
    }
    viewModel.setAvailableCardColumns(4)
    #expect(viewModel.availableCardColumns == 4)

    viewModel.showExhausted = false
    viewModel.setProviderIncludedInWidget("cursor", included: false)

    #expect(defaults.bool(forKey: DashboardViewModel.showExhaustedKey) == false)
    #expect(viewModel.showExhausted == false)
    #expect(!viewModel.isProviderIncludedInWidget("cursor"))
    #expect(defaults.stringArray(forKey: DashboardViewModel.widgetExcludedProviderNamesKey) == ["cursor"])
}

@Test func warningAlertsCopyIsExplicitlyOptionalAndIndependentOfICloudSync() {
    #expect(
        SettingsView.warningAlertsDescription
            == "Notifies you when a provider reaches your warning threshold. Optional; iCloud syncing is unaffected."
    )
    #expect(SettingsView.warningAlertsRequestingDescription.contains("iCloud syncing continues"))
}

@Test func deniedWarningAlertsKeepICloudSyncSeparate() {
    #expect(SettingsView.warningAlertsDescription.contains("iCloud syncing is unaffected"))
    #expect(SettingsView.warningAlertsRequestingDescription.contains("iCloud syncing continues"))
    #expect(NotificationAuthorization.denied == .denied)
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
/// Raised again from 760 (2026-08-07), because 760 did not in fact satisfy the
/// sentence above: it cut off mid-`Slider`, so the warning threshold's own
/// control, its caption, and the entire About group were outside every
/// baseline. Measured by recording once at 1400 and reading where the content
/// actually ended (~1085pt), then trimming to leave roughly one row of slack —
/// slack is deliberate, so a single appended row lands inside the frame and
/// gets covered instead of silently falling past the edge.
///
/// Anything appended to `SettingsView` must check it still fits here.
private let settingsSnapshotHeight: CGFloat = 1150

@MainActor
@Test func settingsViewNotificationsOnLight() {
    let viewModel = makeViewModel(notificationsEnabled: true)
    let view = SettingsView(dashboardViewModel: viewModel)
    assertIOSSnapshot(
        of: view,
        as: .image(
            layout: .fixed(width: 390, height: settingsSnapshotHeight),
            traits: UITraitCollection(userInterfaceStyle: .light)
        ),
        record: settingsSnapshotRecording
    )
}

@MainActor
@Test func settingsViewNotificationsOnDark() {
    let viewModel = makeViewModel(notificationsEnabled: true)
    let view = SettingsView(dashboardViewModel: viewModel)
    assertIOSSnapshot(
        of: view,
        as: .image(
            layout: .fixed(width: 390, height: settingsSnapshotHeight),
            traits: UITraitCollection(userInterfaceStyle: .dark)
        ),
        record: settingsSnapshotRecording
    )
}

@MainActor
@Test func settingsViewNotificationsOffLight() {
    let viewModel = makeViewModel(notificationsEnabled: false)
    let view = SettingsView(dashboardViewModel: viewModel)
    assertIOSSnapshot(
        of: view,
        as: .image(
            layout: .fixed(width: 390, height: settingsSnapshotHeight),
            traits: UITraitCollection(userInterfaceStyle: .light)
        ),
        record: settingsSnapshotRecording
    )
}

@MainActor
@Test func settingsViewNotificationsOffDark() {
    let viewModel = makeViewModel(notificationsEnabled: false)
    let view = SettingsView(dashboardViewModel: viewModel)
    assertIOSSnapshot(
        of: view,
        as: .image(
            layout: .fixed(width: 390, height: settingsSnapshotHeight),
            traits: UITraitCollection(userInterfaceStyle: .dark)
        ),
        record: settingsSnapshotRecording
    )
}

/// The state that shipped invisible in 1.6.0: our toggle on, iOS refusing to
/// display anything. The four cases above build view models with no
/// authorization source at all, so `systemNotificationAuthorization` stays
/// `.notDetermined` and this branch never renders in them -- which is why they
/// went green without covering a pixel of it.
@MainActor
@Test func settingsViewWarnsWhenSystemNotificationsAreDeniedLight() async {
    let viewModel = makeViewModel(notificationsEnabled: true, systemAuthorization: .denied)
    await viewModel.refreshNotificationAuthorization()
    #expect(viewModel.notificationsSuppressedBySystem)
    let view = SettingsView(dashboardViewModel: viewModel)
    assertIOSSnapshot(
        of: view,
        as: .image(
            layout: .fixed(width: 390, height: settingsSnapshotHeight),
            traits: UITraitCollection(userInterfaceStyle: .light)
        ),
        record: settingsSnapshotRecording
    )
}

@MainActor
@Test func settingsViewWarnsWhenSystemNotificationsAreDeniedDark() async {
    let viewModel = makeViewModel(notificationsEnabled: true, systemAuthorization: .denied)
    await viewModel.refreshNotificationAuthorization()
    #expect(viewModel.notificationsSuppressedBySystem)
    let view = SettingsView(dashboardViewModel: viewModel)
    assertIOSSnapshot(
        of: view,
        as: .image(
            layout: .fixed(width: 390, height: settingsSnapshotHeight),
            traits: UITraitCollection(userInterfaceStyle: .dark)
        ),
        record: settingsSnapshotRecording
    )
}
