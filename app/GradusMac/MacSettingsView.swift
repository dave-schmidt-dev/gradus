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

            Section("Display") {
                Picker("Sort providers by", selection: $viewModel.providerSortOption) {
                    ForEach(ProviderSortOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Show exhausted", isOn: $viewModel.showExhausted)
                Text("These display choices apply on this Mac only.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Warning Threshold") {
                Slider(
                    value: warningThresholdBinding,
                    in: 0 ... 100
                ) {
                    Text("Warn at or below \(Int(viewModel.localWarningThresholdPercent))%")
                }
                Text("Highlights providers at or below this level.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Connected Devices") {
                if viewModel.connectedDevices.isEmpty {
                    Text("No active iPhone or iPad sessions")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.connectedDevices) { device in
                        Label(device.displayName.rawValue, systemImage: device.displayName == .iPad
                            ? "ipad"
                            : "iphone")
                    }
                }
                Text("Only foreground sessions active within the last ten minutes appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: Self.versionLabel)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    static func wholePercent(_ value: Double) -> Double {
        min(100, max(0, value.rounded()))
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
