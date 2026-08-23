import SwiftUI

/// The "Warning Threshold" section of `SettingsView`: the local, per-device
/// percent-remaining threshold used to highlight providers. Split out of
/// `SettingsView.swift` to keep that file's type body under SwiftLint's
/// length gate.
extension SettingsView {
    var warningThresholdSection: some View {
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
                Slider(
                    value: $dashboardViewModel.localWarningThresholdPercent,
                    in: 0 ... 100,
                    step: 1,
                    onEditingChanged: { isEditing in
                        if !isEditing {
                            dashboardViewModel.commitWarningThreshold()
                        }
                    }
                )
                .accessibilityIdentifier("warning-threshold-slider")
                Text(
                    "Highlights providers below this % on this device only -- does not change which alerts get pushed."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}
