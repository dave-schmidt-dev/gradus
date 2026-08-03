import GradusKit
import SwiftUI

/// The Settings screen (P5/T5.3): three groups -- Sync + Notifications,
/// Warning threshold, Providers + about. Takes the live `DashboardViewModel`
/// instance directly, `@ObservedObject`, **not** a separate
/// `SettingsViewModel` -- per the plan's explicit reversal
/// (`ios-design-system-2026-08-03.md`, Phase 5 section): a standalone view
/// model would persist its own `UserDefaults` copies correctly but have no
/// path back into `GradusiOSApp`'s `.task`/`.onChange` wiring that actually
/// calls `CKSubscriptionManager.subscribeToWarnings()`/
/// `unsubscribeFromWarnings()`, so toggling it would silently do nothing
/// until next relaunch. This is the exact same `DashboardViewModel`
/// instance `GradusiOSApp` already holds as `@StateObject`.
///
/// No "Publishing Mac" row: `sourceDevice` is deliberately never written to
/// CloudKit (`CloudKitMapping.swift`) -- an intentional omission, not a gap
/// this screen should paper over with an invented value.
struct SettingsView: View {
    @ObservedObject var dashboardViewModel: DashboardViewModel
    @Environment(\.dismiss) private var dismiss

    /// Custom binding, not a direct `$dashboardViewModel.notificationsEnabled`
    /// binding: `notificationsEnabled` is `private(set)` precisely because
    /// toggle-off is success-gated (P5/T5.1, CR-5) through
    /// `setNotificationsEnabled(_:)` rather than an optimistic direct write.
    /// The `Toggle` still reads live from the published property, so a
    /// failed toggle-off visibly springs back to "on" once the async call
    /// resolves, instead of the UI claiming a state the network call didn't
    /// achieve.
    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { dashboardViewModel.notificationsEnabled },
            set: { newValue in
                Task { await dashboardViewModel.setNotificationsEnabled(newValue) }
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            MobileNavBar(title: "Settings") {
                IconButton(Icon.close) { dismiss() }
            }

            List {
                syncAndNotificationsSection
                warningThresholdSection
                aboutSection
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var syncAndNotificationsSection: some View {
        Section("Sync & Notifications") {
            ListRow.toggle(icon: Icon.syncing, label: "iCloud Sync", isOn: $dashboardViewModel.syncEnabled)
            ListRow.toggle(icon: Icon.bell, label: "Notifications", isOn: notificationsBinding)
            if let error = dashboardViewModel.notificationsToggleError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var warningThresholdSection: some View {
        Section("Warning Threshold") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Icon.warning
                        .frame(width: 24)
                    Text("Local warning threshold")
                    Spacer()
                    Text("\(Int(dashboardViewModel.localWarningThresholdPercent))%")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $dashboardViewModel.localWarningThresholdPercent, in: 0...100, step: 1)
                Text(
                    "Highlights providers below this % on this device only -- does not change which alerts get pushed."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section("About") {
            ListRow.value(icon: Icon.listBullet, label: "Providers", value: "\(dashboardViewModel.providers.count)")
            ListRow.value(icon: Icon.infoCircle, label: "Version", value: Self.appVersion)
        }
    }

    /// `Bundle.main` in a real app run; falls back to em-dashes rather than
    /// crashing when the keys are absent (e.g. an unusual test host bundle).
    private static var appVersion: String {
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "\u{2014}"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "\u{2014}"
        return "\(shortVersion) (\(build))"
    }
}
