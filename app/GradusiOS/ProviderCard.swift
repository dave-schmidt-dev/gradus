import GradusKit
import SwiftUI

/// One dashboard card per provider (T3.1): label · % · bar · reset · pace,
/// mirroring the TUI's per-provider panel (`gradus/ui.py`), plus an
/// offline/stale age badge keyed off `observedAt` rather than publish time
/// (T3.4/CR-1).
struct ProviderCard: View {
    let provider: ProviderStatus
    let now: Date

    private var worstWindow: ProviderWindow? {
        provider.windows.min { $0.percentLeft < $1.percentLeft }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(provider.providerDisplayName).font(.headline)
                Spacer()
                if case .stale(let ageDisplay) = freshness(observedAt: provider.observedAt, now: now) {
                    Label("offline \(ageDisplay)", systemImage: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .labelStyle(.titleAndIcon)
                }
            }

            if !provider.ok {
                Text(provider.errorMessage ?? "error")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            } else if let window = worstWindow {
                HStack {
                    ProgressView(value: max(0, min(100, window.percentLeft)) / 100)
                        .tint(provider.isWarning ? .orange : .green)
                    Text("\(Int(window.percentLeft))%")
                        .font(.subheadline.monospacedDigit())
                }
                HStack(spacing: 12) {
                    if let resetISO = window.resetISO {
                        Text("reset \(resetISO)")
                    }
                    if let pace = window.paceDelta {
                        Text(String(format: "pace %+.0f%%", pace * 100))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("no window data")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}
