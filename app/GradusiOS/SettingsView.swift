import GradusKit
import SwiftUI
import UIKit

/// The Settings screen (P5/T5.3): Sync + Notifications, connected computer,
/// local display, warning threshold, and About. Takes the live `DashboardViewModel`
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
struct SettingsView: View {
    @ObservedObject var dashboardViewModel: DashboardViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

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
                connectedComputerSection
                localDisplaySection
                warningThresholdSection
                aboutSection
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var connectedComputerSection: some View {
        if let source = dashboardViewModel.connectedSource {
            Section("Connected Computer") {
                ListRow.value(icon: Icon.laptop, label: "Mac", value: source.computerName)
                ListRow.value(icon: Icon.accountWarning, label: "User", value: source.userName)
            }
        }
    }

    @ViewBuilder
    private var localDisplaySection: some View {
        Section("Local Display") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sort providers")
                    .font(.headline)
                Picker("Sort providers", selection: $dashboardViewModel.providerSortOption) {
                    ForEach(ProviderSortOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                Text("Sorting, density and exhausted-provider visibility are local display choices on this device only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 8) {
                Text("Card size")
                    .font(.headline)
                HStack {
                    Text("Small")
                    Spacer()
                    Text(cardSizeLabel)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Large")
                }
                .font(.caption)
                Slider(
                    value: Binding(
                        get: { Double(dashboardViewModel.cardColumnPreference) },
                        set: { dashboardViewModel.cardColumnPreference = Int($0.rounded()) }),
                    in: 0...Double(dashboardViewModel.availableCardColumns),
                    step: 1
                )
                .accessibilityLabel("Card size")
                Text("Auto uses the most columns that fit this device and text size. Every position keeps all provider windows visible.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            ListRow.toggle(
                icon: Icon.listBullet,
                label: "Show exhausted",
                isOn: $dashboardViewModel.showExhausted)
        }
    }

    private var cardSizeLabel: String {
        let selection = dashboardViewModel.cardColumnPreference
        if selection == 0 { return "Auto" }
        let clamped = min(max(selection, 1), dashboardViewModel.availableCardColumns)
        return clamped == 1 ? "1 column" : "\(clamped) columns"
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
            if dashboardViewModel.notificationsSuppressedBySystem {
                systemAuthorizationWarning
            }
        }
    }

    /// Shown only when our own toggle is on and iOS is dropping the result --
    /// the state where the app would otherwise look like it simply does not
    /// notify. The button rather than prose-only because the fix is four taps
    /// deep in a different app, and HIG's Settings guidance names this pattern
    /// directly: "consider providing a button that opens it directly from your
    /// interface."
    ///
    /// Says what still works, not just what does not. The warning subscription
    /// keeps waking the app to sync even with alerts suppressed, so "you will
    /// not see alerts" is the accurate claim and "notifications are off" is not.
    @ViewBuilder
    private var systemAuthorizationWarning: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Icon.warning
            // The button sits inside the text column rather than beside the
            // icon, so it indents under the sentence it acts on. Recording the
            // first baseline caught it hanging off the row's leading edge
            // instead, reading as an unrelated control.
            VStack(alignment: .leading, spacing: 6) {
                Text("iOS is not allowing Gradus to show notifications, so you won't see warning alerts. Syncing is unaffected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    // Explicit accent tint: inside a `.plain`-styled `List`
                    // row this button's label otherwise renders in the primary
                    // label color, which is indistinguishable from the prose
                    // above it and gives no sign it is tappable.
                    Button("Open iOS Settings") { openURL(settingsURL) }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .padding(.vertical, 4)
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
