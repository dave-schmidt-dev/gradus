import SwiftUI

/// The "Explore Sample" section(s) of `SettingsView`: entry into local-only
/// sample data when not already sampling, and reset/exit controls once
/// inside it. Split out of `SettingsView.swift` to keep that file's type
/// body under SwiftLint's length gate.
extension SettingsView {
    var sampleSection: some View {
        Section("Explore Sample") {
            Text("This is local-only sample data. It does not use iCloud, notifications, or provider connections.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Reset Sample Data", action: onResetSample)
                .accessibilityIdentifier("sample-data-reset-settings")
            Button("Exit Explore Sample", action: onExitSample)
                .accessibilityIdentifier("sample-data-exit-settings")
        }
    }

    var exploreSampleSection: some View {
        Section("Explore Sample") {
            Text("See a complete dashboard using local-only sample data. Your iCloud data stays unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                onExploreSample()
            } label: {
                HStack(spacing: 8) {
                    if isSampleEntryInProgress {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(Self.exploreSampleButtonTitle(isInProgress: isSampleEntryInProgress))
                }
            }
            .accessibilityIdentifier("explore-sample-settings")
            .accessibilityValue(isSampleEntryInProgress ? "In progress" : "")
            .disabled(isSampleEntryInProgress)
        }
    }

    static func exploreSampleButtonTitle(isInProgress: Bool) -> String {
        isInProgress ? "Entering Sample…" : "Explore Sample"
    }
}
