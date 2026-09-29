import AppKit
import GradusKit
import SwiftUI

/// The Mac's settings window, opened from the menu's "Settings…" row, mirroring
/// the iOS `SettingsView` section for section so the two apps can be described
/// with one set of words.
///
/// There is deliberately no ⌘, here. That key equivalent comes from a SwiftUI
/// `Settings` scene, and this app has none -- see `SettingsWindow` for why.
///
/// Everything here is device-local. The Mac is the *publisher* in this system,
/// which makes it tempting to treat its preferences as authoritative and push
/// them to iCloud alongside the usage data -- but sorting and a warning
/// threshold describe how one screen is read, not what is true about the
/// providers. Syncing them would let a Mac reorder an iPhone's list.
///
/// Split out from `MenuContentView` rather than added to it: the dropdown is
/// the at-a-glance surface and the reason its rows are as dense as they are.
/// Sliders and pickers belong in a window the user opens on purpose.
struct MacSettingsView: View {
    @ObservedObject var viewModel: PublisherViewModel

    /// A continuous slider avoids AppKit's secondary tick-mark rail, while
    /// quantizing at the binding preserves the shared whole-percent contract.
    var warningThresholdBinding: Binding<Double> {
        Binding(
            get: { viewModel.localWarningThresholdPercent },
            set: { viewModel.localWarningThresholdPercent = Self.wholePercent($0) }
        )
    }

    var body: some View {
        Form {
            Section("Required iCloud") {
                Text(
                    viewModel.syncEnabled
                        ? (MenuContentView.lastSyncLabel(viewModel.lastSyncedAt) ?? "Not synced yet")
                        : "Required iCloud setup is awaiting confirmation."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("Background Refresh") {
                Toggle(
                    "Monitor in Background",
                    isOn: Binding(
                        get: { viewModel.monitorInBackgroundEnabled },
                        set: { viewModel.setMonitorInBackground($0) }
                    )
                )
                .accessibilityIdentifier("settings-monitor-in-background")

                Text(viewModel.backgroundAgentState.headline)
                    .font(.callout)
                    .accessibilityIdentifier("settings-agent-headline")
                Text(viewModel.backgroundAgentState.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-agent-explanation")

                ForEach(viewModel.backgroundAgentState.recoveryActions) { action in
                    Button(action.title) {
                        viewModel.performBackgroundAgentRecovery(action)
                    }
                    .accessibilityIdentifier("settings-agent-action-\(action.id)")
                }

                Toggle(
                    "Open Menu at Login",
                    isOn: Binding(
                        get: { viewModel.launchAtLoginEnabled },
                        set: { viewModel.setLaunchAtLogin($0) }
                    )
                )
                .accessibilityIdentifier("settings-open-menu-at-login")
                Text(
                    """
                    These are separate. Monitor in Background keeps usage current while Gradus is closed. \
                    Open Menu at Login only puts the menu-bar icon back after you restart this Mac.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            // Absent entirely on a Mac that never ran the old launchd job --
            // an empty "nothing to migrate" section is noise for everyone who
            // installed Gradus as one app in the first place.
            if viewModel.legacyMigration != .notApplicable {
                Section("Legacy Background Job") {
                    Text(viewModel.legacyMigration.headline)
                        .font(.callout)
                        .accessibilityIdentifier("settings-legacy-headline")
                    Text(viewModel.legacyMigration.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-legacy-explanation")
                    if viewModel.legacyMigration.canStartMigration {
                        Button("Move Refresh into Gradus") {
                            viewModel.startLegacyMigration()
                        }
                        .accessibilityIdentifier("settings-legacy-migrate")
                    }
                }
            }

            Section("Display") {
                Picker("Menu bar", selection: $viewModel.menuBarDisplaySelection) {
                    Label("Gauge", systemImage: "gauge")
                        .tag(MenuBarDisplaySelection.gauge)
                    ForEach(viewModel.menuBarBucketChoices) { choice in
                        Text(choice.title)
                            .tag(choice.selection)
                            .disabled(!choice.available)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settings-menu-bar-display")
                Picker("Sort providers by", selection: $viewModel.providerSortOption) {
                    ForEach(ProviderSortOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Show exhausted", isOn: $viewModel.showExhausted)
                Text(
                    "A selected bucket shows its remaining percentage. An asterisk marks stale data; "
                        + "a dash means unavailable. These choices apply on this Mac only."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            warningThresholdSection

            Section("Reset Alerts") {
                Text("Reset alerts are separate from low-usage warnings and apply on this Mac only.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Toggle(
                    "New banked resets",
                    isOn: Binding(
                        get: { viewModel.resetGrantAlertsEnabled },
                        set: { enabled in
                            Task { await viewModel.setResetGrantAlertsEnabled(enabled) }
                        }
                    )
                )
                .accessibilityIdentifier("settings-reset-grants")
                Text("Alert when a new Codex redeemable reset credit is observed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(
                    "Usage refilled",
                    isOn: Binding(
                        get: { viewModel.resetRefillAlertsEnabled },
                        set: { enabled in
                            Task { await viewModel.setResetRefillAlertsEnabled(enabled) }
                        }
                    )
                )
                .accessibilityIdentifier("settings-reset-refills")
                Text("Alert when a reported allowance refills for Codex or Claude.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Codex banked resets", value: viewModel.bankedCreditStatusText)
                    .accessibilityIdentifier("settings-banked-status")
                if let lastObserved = viewModel.lastObservedBankedCreditText {
                    Text(lastObserved)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings-banked-last-observed")
                }
                Text("Claude banked resets: Unavailable. Gradus cannot read their count or arrival.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if viewModel.bankedCreditCount == nil {
                    switch viewModel.bankedAccessRecoveryState {
                    case .idle, .denied:
                        Button(
                            viewModel.bankedAccessRecoveryState == .denied
                                ? "Retry Background Access" : "Allow Background Access"
                        ) {
                            Task { await viewModel.authorizeBankedBackgroundAccess() }
                        }
                        .accessibilityIdentifier("settings-banked-access-action")
                    case .requesting:
                        Text("Requesting background access…")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings-banked-access-requesting")
                    case .allowed:
                        Text("Access allowed. The next refresh will check for banked resets.")
                            .foregroundStyle(.secondary)
                    }
                    if viewModel.bankedAccessRecoveryState == .denied {
                        Text("Background access was not allowed. You can retry here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings-banked-access-denied")
                    }
                }

                if viewModel.resetGrantAlertsEnabled || viewModel.resetRefillAlertsEnabled {
                    switch viewModel.resetNotificationAuthorization {
                    case .notDetermined:
                        Text("Notification permission has not been checked yet.")
                            .foregroundStyle(.secondary)
                    case .requesting:
                        Text("Requesting notification permission…")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings-reset-permission-requesting")
                    case .denied:
                        Text("Notifications are blocked for Gradus. Alerts will not appear.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings-reset-permission-denied")
                        Button("Open Notification Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .accessibilityIdentifier("settings-reset-permission-recovery")
                    case .authorized:
                        Text("System notifications are allowed.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Connected Devices") {
                if viewModel.connectedDevicesUnavailable {
                    // Never fold a failed read into the empty state: they look
                    // identical to the user, and that is how a presence fetch
                    // that had never once succeeded went unnoticed.
                    Label(
                        "Couldn't read connected devices from iCloud",
                        systemImage: "exclamationmark.icloud"
                    )
                    .foregroundStyle(.secondary)
                } else if viewModel.connectedDevices.isEmpty {
                    Text("No active iPhone or iPad sessions")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.connectedDevices) { device in
                        Label(device.displayName.rawValue, systemImage: device.displayName == .iPad
                            ? "ipad"
                            : "iphone")
                    }
                }
                Text(
                    """
                    A device appears here while Gradus is open on it, and leaves when the app is \
                    backgrounded or the screen locks.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: Self.versionLabel)
            }
        }
        .formStyle(.grouped)
        // Form supplies the scrolling viewport when SettingsWindow has to
        // shrink below this ideal height for a smaller visible screen.
        .frame(width: 460)
        .frame(idealHeight: 700)
        // Read when Settings opens, not on every snapshot: this is the only
        // screen that renders it, and it costs two `launchctl` calls.
        .onAppear {
            viewModel.refreshLegacyMigration()
            Task { await viewModel.refreshResetNotificationAuthorization() }
        }
    }

    /// The shared ramp already warns at 10 points behind pace, so a larger
    /// local threshold could never change anything.
    static let maxWarningPointsBehind: Double = 10

    static func wholePercent(_ value: Double) -> Double {
        min(maxWarningPointsBehind, max(0, value.rounded()))
    }

    /// Reads the same two Info.plist keys the iOS About section does, so a
    /// coupled release (`VERSIONING.md`) can be confirmed by opening both.
    static var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}

extension MacSettingsView {
    var warningThresholdSection: some View {
        Section("Warning Threshold") {
            Slider(
                value: warningThresholdBinding,
                in: 0 ... Self.maxWarningPointsBehind
            ) {
                Text("Warn at \(Int(viewModel.localWarningThresholdPercent)) points behind pace")
            }
            Text(
                "Highlights providers this far behind their expected pace. Gradus always warns "
                    + "at 10 points behind, so a lower value only warns sooner."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}
