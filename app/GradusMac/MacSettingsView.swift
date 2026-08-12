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
            Section("Sync") {
                Text(
                    viewModel.syncEnabled
                        ? (MenuContentView.lastSyncLabel(viewModel.lastSyncedAt) ?? "Not synced yet")
                        : "Required iCloud setup is awaiting confirmation."
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { viewModel.launchAtLoginEnabled },
                        set: { viewModel.setLaunchAtLogin($0) }
                    )
                )
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
