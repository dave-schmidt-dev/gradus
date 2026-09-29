import SwiftUI

/// The "Warning Threshold" section of `SettingsView`: the local, per-device
/// points-behind-pace threshold used to highlight providers. Split out of
/// `SettingsView.swift` to keep that file's type body under SwiftLint's
/// length gate.
extension SettingsView {
    var warningThresholdSection: some View {
        Section("Warning Threshold") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Icon.warning
                        .frame(width: 24)
                    Text("Warn when behind pace by")
                    Spacer()
                    Text("\(Int(dashboardViewModel.localWarningThresholdPercent)) pts")
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: $dashboardViewModel.localWarningThresholdPercent,
                    in: 0 ... 10,
                    step: 1,
                    onEditingChanged: { isEditing in
                        if !isEditing {
                            dashboardViewModel.commitWarningThreshold()
                        }
                    }
                )
                .accessibilityIdentifier("warning-threshold-slider")
                Text(
                    "Highlights providers this many points behind their expected pace, on this device only. "
                        + "Gradus always warns at 10 points behind, so a lower value only warns sooner."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}
