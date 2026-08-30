import SwiftUI

/// The sample-mode section of `SettingsView`: reset and exit controls once
/// already inside local-only sample data. Entry remains on the dashboard's
/// clean-install empty state, where it has useful context.
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
}
