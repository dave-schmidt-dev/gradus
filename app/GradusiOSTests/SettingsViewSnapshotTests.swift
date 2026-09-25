@testable import GradusiOS
import GradusKit
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
import Vision

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
    notificationsEnabled: Bool,
    resetAlertsEnabled: Bool = false,
    systemAuthorization: NotificationAuthorization? = nil,
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
    let viewModel = DashboardViewModel(
        cache: cache,
        notificationAuthorizationSource: systemAuthorization.map { StubAuthorizationSource(authorization: $0) },
        userDefaults: defaults
    )
    viewModel.setBankedResetAlertsEnabled(resetAlertsEnabled)
    viewModel.setUsageRefillAlertsEnabled(resetAlertsEnabled)
    return viewModel
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

@Test func resetAlertsCopyNamesCoverageAndMobileDelivery() {
    #expect(SettingsView.bankedResetAlertsDescription.contains("Codex"))
    #expect(SettingsView.bankedResetAlertsDescription.contains("starting balance"))
    #expect(SettingsView.usageRefillAlertsDescription.contains("Codex (Spark)"))
    #expect(SettingsView.usageRefillAlertsDescription.contains("Claude"))
    #expect(SettingsView.claudeBankedUnavailableDescription == "Claude banked resets are unavailable to Gradus.")
    #expect(
        SettingsView.mobileResetDeliveryDescription
            == "On iPhone and iPad, delivery may wait until you open Gradus."
    )
    #expect(SettingsView.resetAlertSourceDescription.contains("Mac refreshes"))
}

@Test func settingsCopyDistinguishesDashboardCardsFromWidgetSizing() {
    #expect(SettingsView.dashboardCardSizeTitle == "Dashboard card size")
    #expect(SettingsView.dashboardCardSizeDescription.contains("dashboard cards only"))
    #expect(SettingsView.dashboardCardSizeDescription.contains("widget gallery"))
    #expect(SettingsView.widgetDescription.contains("only chooses providers"))
    #expect(SettingsView.widgetDescription.contains("widget gallery"))
}

/// 1750pt clipped the final Version row in denied settings; 2050pt leaves a
/// 24pt OCR margin below the final About text.
private let settingsSnapshotHeight: CGFloat = 2050

private func assertVersionVisible(in image: UIImage, testName: String) {
    guard let cgImage = image.cgImage else {
        Issue.record("\(testName): snapshot has no CGImage")
        return
    }
    let scale = image.scale > 0 ? image.scale : 1
    let cropHeight = min(cgImage.height, Int((image.size.height * 0.35 * scale).rounded()))
    let cropRect = CGRect(
        x: 0,
        y: cgImage.height - cropHeight,
        width: cgImage.width,
        height: cropHeight
    )
    guard let croppedCGImage = cgImage.cropping(to: cropRect) else {
        Issue.record("\(testName): could not crop the bottom of the Settings snapshot")
        return
    }
    let croppedImage = UIImage(cgImage: croppedCGImage, scale: scale, orientation: .up)

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    do {
        try VNImageRequestHandler(cgImage: croppedCGImage, orientation: .up).perform([request])
    } catch {
        Issue.record("\(testName): Vision could not inspect the snapshot: \(error)")
        return
    }
    guard let observation = request.results?.first(where: {
        $0.topCandidates(1).first?.string.range(of: "Version", options: .caseInsensitive) != nil
    }) else {
        Issue.record("\(testName): final About Version text is outside the snapshot")
        return
    }
    let bounds = observation.boundingBox
    let inside = !bounds.isEmpty && bounds.minX >= 0 && bounds.minY >= 0 && bounds.maxX <= 1 && bounds.maxY <= 1
    if !inside {
        Issue.record("\(testName): final About Version text lies outside the snapshot image")
    }
    let bottomMargin = bounds.minY * croppedImage.size.height // Vision's origin is bottom-left.
    if bottomMargin < 24 {
        Issue.record("\(testName): final About Version text has less than 24pt below it")
    }
}

/// Verify the final About label in the same fixed image that SnapshotTesting compares.
@MainActor
private func assertResetSettingsSnapshot(
    viewModel: DashboardViewModel,
    style: UIUserInterfaceStyle,
    requesting: Bool = false,
    testName: String
) {
    let view = SettingsView(
        dashboardViewModel: viewModel,
        initialResetAlertsPending: requesting
    )
    let viewSnapshotting = Snapshotting<SettingsView, UIImage>.image(
        layout: .fixed(width: 390, height: settingsSnapshotHeight),
        traits: UITraitCollection(userInterfaceStyle: style)
    )
    let checkedSnapshotting = Snapshotting<SettingsView, UIImage>(
        pathExtension: viewSnapshotting.pathExtension,
        diffing: viewSnapshotting.diffing,
        asyncSnapshot: { snapshotView in
            Async<UIImage> { callback in
                viewSnapshotting.snapshot(snapshotView).run { image in
                    assertVersionVisible(in: image, testName: testName)
                    callback(image)
                }
            }
        }
    )
    assertIOSSnapshot(
        of: view,
        as: checkedSnapshotting,
        record: settingsSnapshotRecording,
        testName: testName
    )
}

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

@MainActor
@Test func settingsViewResetAlertsOnLight() async {
    let viewModel = makeViewModel(
        notificationsEnabled: true, resetAlertsEnabled: true, systemAuthorization: .authorized
    )
    await viewModel.refreshNotificationAuthorization()
    assertResetSettingsSnapshot(viewModel: viewModel, style: .light, testName: #function)
}

@MainActor
@Test func settingsViewResetAlertsOnDark() async {
    let viewModel = makeViewModel(
        notificationsEnabled: true, resetAlertsEnabled: true, systemAuthorization: .authorized
    )
    await viewModel.refreshNotificationAuthorization()
    assertResetSettingsSnapshot(viewModel: viewModel, style: .dark, testName: #function)
}

@MainActor
@Test func settingsViewResetAlertsRequestingLight() {
    let viewModel = makeViewModel(notificationsEnabled: false, resetAlertsEnabled: true)
    assertResetSettingsSnapshot(viewModel: viewModel, style: .light, requesting: true, testName: #function)
}

@MainActor
@Test func settingsViewResetAlertsRequestingDark() {
    let viewModel = makeViewModel(notificationsEnabled: false, resetAlertsEnabled: true)
    assertResetSettingsSnapshot(viewModel: viewModel, style: .dark, requesting: true, testName: #function)
}

@MainActor
@Test func settingsViewResetAlertsDeniedLight() async {
    let viewModel = makeViewModel(
        notificationsEnabled: true, resetAlertsEnabled: true, systemAuthorization: .denied
    )
    await viewModel.refreshNotificationAuthorization()
    #expect(viewModel.resetAlertsSuppressedBySystem)
    assertResetSettingsSnapshot(viewModel: viewModel, style: .light, testName: #function)
}

@MainActor
@Test func settingsViewResetAlertsDeniedDark() async {
    let viewModel = makeViewModel(
        notificationsEnabled: true, resetAlertsEnabled: true, systemAuthorization: .denied
    )
    await viewModel.refreshNotificationAuthorization()
    #expect(viewModel.resetAlertsSuppressedBySystem)
    assertResetSettingsSnapshot(viewModel: viewModel, style: .dark, testName: #function)
}
