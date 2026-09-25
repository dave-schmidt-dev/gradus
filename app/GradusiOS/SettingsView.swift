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
    let isSampleMode: Bool
    let onExitSample: () -> Void
    let onResetSample: () -> Void
    /// Only supplied by the UI-test launch fixture. Normal launches start
    /// false and enter this state only after the user enables Warning alerts.
    let initialWarningAlertsPending: Bool
    let onAboutVersionFrame: ((CGRect) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var warningAlertPermissionRequestPending = false
    @State private var resetAlertFixtureRequestPending = false
    @State var showingWidgetProviders = false

    init(
        dashboardViewModel: DashboardViewModel,
        isSampleMode: Bool = false,
        onExitSample: @escaping () -> Void = {},
        onResetSample: @escaping () -> Void = {},
        initialWarningAlertsPending: Bool = false,
        initialResetAlertsPending: Bool = false,
        onAboutVersionFrame: ((CGRect) -> Void)? = nil
    ) {
        self.dashboardViewModel = dashboardViewModel
        self.isSampleMode = isSampleMode
        self.onExitSample = onExitSample
        self.onResetSample = onResetSample
        self.initialWarningAlertsPending = initialWarningAlertsPending
        self.onAboutVersionFrame = onAboutVersionFrame
        _warningAlertPermissionRequestPending = State(
            initialValue: initialWarningAlertsPending
        )
        _resetAlertFixtureRequestPending = State(
            initialValue: initialResetAlertsPending
                || (GradusUITestFixture.current?.startsResetAlertRequest ?? false)
        )
    }

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
                guard newValue != dashboardViewModel.notificationsEnabled else { return }
                if newValue,
                   dashboardViewModel.systemNotificationAuthorization == .notDetermined {
                    warningAlertPermissionRequestPending = true
                }
                Task { await dashboardViewModel.setNotificationsEnabled(newValue) }
            }
        )
    }

    static let warningAlertsDescription =
        "Notifies you when a provider reaches your warning threshold. Optional; iCloud syncing is unaffected."

    static let warningAlertsRequestingDescription =
        "Waiting for your iOS notification choice. iCloud syncing continues either way."

    static let bankedResetAlertsDescription =
        "Alert when a new Codex banked reset credit is observed. Existing credits set the starting balance."

    static let usageRefillAlertsDescription =
        "Alert when a reported Codex, Codex (Spark), or Claude usage window refills."

    static let claudeBankedUnavailableDescription =
        "Claude banked resets are unavailable to Gradus."

    static let mobileResetDeliveryDescription =
        "On iPhone and iPad, delivery may wait until you open Gradus."

    static let resetAlertSourceDescription =
        "Alerts depend on Mac refreshes and sync to this device."

    var body: some View {
        VStack(spacing: 0) {
            MobileNavBar(title: "Settings") {
                IconButton(Icon.close) { dismiss() }
            }

            List {
                if isSampleMode {
                    sampleSection
                } else {
                    warningAlertsSection
                    resetAlertsSection
                }
                connectedComputerSection
                localDisplaySection
                widgetProvidersSection
                warningThresholdSection
                aboutSection
            }
            .listStyle(.plain)
        }
        .onChange(of: dashboardViewModel.systemNotificationAuthorization) {
            if dashboardViewModel.systemNotificationAuthorization != .notDetermined {
                warningAlertPermissionRequestPending = false
            }
        }
        .onChange(of: dashboardViewModel.notificationsEnabled) {
            if !dashboardViewModel.notificationsEnabled {
                warningAlertPermissionRequestPending = false
            }
        }
        .onChange(of: dashboardViewModel.systemNotificationAuthorization) {
            if dashboardViewModel.systemNotificationAuthorization != .notDetermined {
                resetAlertFixtureRequestPending = false
            }
        }
        .coordinateSpace(name: "settings-frame")
        .onPreferenceChange(AboutVersionFramePreferenceKey.self) { frame in
            if let frame {
                onAboutVersionFrame?(frame)
            }
        }
        .sheet(isPresented: $showingWidgetProviders) {
            WidgetProviderSettingsView(dashboardViewModel: dashboardViewModel)
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

    private var warningAlertsSection: some View {
        Section("Warning alerts") {
            ListRow.toggle(
                icon: Icon.bell,
                label: warningAlertsToggleLabel,
                isOn: notificationsBinding,
                accessibilityIdentifier: "warning-alerts-toggle"
            )
            .disabled(warningAlertPermissionRequestPending)
            .accessibilityHint(warningAlertsAccessibilityHint)
            Text(Self.warningAlertsDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            if warningAlertPermissionRequestPending {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(Self.warningAlertsRequestingDescription)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
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

    private var warningAlertsToggleLabel: String {
        warningAlertPermissionRequestPending ? "Requesting warning-alert permission…" : "Warning alerts"
    }

    private var bankedResetAlertsBinding: Binding<Bool> {
        Binding(
            get: { dashboardViewModel.bankedResetAlertsEnabled },
            set: { dashboardViewModel.setBankedResetAlertsEnabled($0) }
        )
    }

    private var usageRefillAlertsBinding: Binding<Bool> {
        Binding(
            get: { dashboardViewModel.usageRefillAlertsEnabled },
            set: { dashboardViewModel.setUsageRefillAlertsEnabled($0) }
        )
    }

    private var resetAlertsSection: some View {
        Section("Reset alerts") {
            ListRow.toggle(
                icon: Icon.bell,
                label: "New banked resets",
                isOn: bankedResetAlertsBinding,
                accessibilityIdentifier: "reset-alerts-banked-toggle"
            )
            .disabled(resetAlertPermissionRequestPending)
            Text(Self.bankedResetAlertsDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            BankedResetStatusRow(status: dashboardViewModel.bankedResetStatus)
            Text(Self.claudeBankedUnavailableDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            ListRow.toggle(
                icon: Icon.clock,
                label: "Usage refilled",
                isOn: usageRefillAlertsBinding,
                accessibilityIdentifier: "reset-alerts-refill-toggle"
            )
            .disabled(resetAlertPermissionRequestPending)
            Text(Self.usageRefillAlertsDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Self.mobileResetDeliveryDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(Self.resetAlertSourceDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            if resetAlertPermissionRequestPending {
                Label("Waiting for your iOS notification choice.", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("reset-alerts-permission-requesting")
            }
            if dashboardViewModel.resetAlertsSuppressedBySystem {
                resetAlertPermissionDeniedRow
            }
        }
    }

    private var resetAlertPermissionDeniedRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("iOS is not allowing Gradus to show reset alerts. Usage still refreshes.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                Button("Open iOS Settings") { openURL(settingsURL) }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reset-alerts-permission-denied")
    }

    private var warningAlertsAccessibilityHint: String {
        if warningAlertPermissionRequestPending {
            return "Waiting for your iOS notification choice. This does not affect iCloud syncing."
        }
        if dashboardViewModel.systemNotificationAuthorization == .denied,
           dashboardViewModel.notificationsEnabled {
            return
                "iOS is blocking warning alerts. Open iOS Settings to allow them. This does not affect iCloud syncing."
        }
        return "Notifies you when a provider reaches your warning threshold. Optional and separate from iCloud syncing."
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
    private var systemAuthorizationWarning: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Icon.warning
            // The button sits inside the text column rather than beside the
            // icon, so it indents under the sentence it acts on. Recording the
            // first baseline caught it hanging off the row's leading edge
            // instead, reading as an unrelated control.
            VStack(alignment: .leading, spacing: 6) {
                Text("iOS is not allowing Gradus to show warning alerts. iCloud syncing is unaffected.")
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
}

private extension SettingsView {
    var resetAlertPermissionRequestPending: Bool {
        resetAlertFixtureRequestPending || dashboardViewModel.resetAlertAuthorizationRequestInProgress
    }
}

private struct BankedResetStatusRow: View {
    let status: ResetBankedStatus

    var body: some View {
        Group {
            switch status {
            case let .current(count, _):
                Text("Codex banked resets: \(count) available")
            case let .unavailable(lastObservedCount, _):
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex banked resets: Unavailable")
                    if let lastObservedCount {
                        Text("Last observed: \(lastObservedCount)")
                    }
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
