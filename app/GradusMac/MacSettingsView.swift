import GradusKit
import SwiftUI

/// The Mac's settings window (⌘,), mirroring the iOS `SettingsView` section
/// for section so the two apps can be described with one set of words.
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

    var body: some View {
        Form {
            Section("Sync") {
                Toggle("Enable iCloud Sync", isOn: $viewModel.syncEnabled)
                Text(
                    viewModel.syncEnabled
                        ? (MenuContentView.lastSyncLabel(viewModel.lastSyncedAt) ?? "Not synced yet")
                        : "Usage data stays on this Mac."
                )
                .font(.caption)
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
                Text("Exhausted providers always sort to the bottom, in every mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Warning Threshold") {
                // Step 1 and a 0...100 range, identical to the iOS slider --
                // a threshold that means 20% on the phone and 20.4% here would
                // put the same provider in different tiers on two screens.
                Slider(
                    value: $viewModel.localWarningThresholdPercent,
                    in: 0...100,
                    step: 1
                ) {
                    Text("Warn at or below")
                }
                Text("Warn at or below \(Int(viewModel.localWarningThresholdPercent))% remaining.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("A local display choice on this Mac only. It never relaxes the shared pace warning — it can only flag more providers, never fewer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: Self.versionLabel)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
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
