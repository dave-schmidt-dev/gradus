import GradusKit
import SwiftUI

/// A provider and *every* one of its windows, as one card (iPad Option B).
///
/// Deliberately not a `StatTile` variant. `StatTile` answers "which single
/// window matters most for this provider", and its selected-window/badge state
/// only means something when one window is privileged. This card answers "show
/// me everything", so it has no selection state at all — every window is a peer
/// `WindowRow`. Trying to express both in one type meant a selection concept
/// that was inert half the time.
///
/// Tapping still pushes Provider Detail: this card shows the same windows, but
/// detail adds pace, per-window provenance, and the observed-at footer.
struct ProviderDensityCard: View {
    let provider: ProviderStatus
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(provider.providerDisplayName)
                .font(.headline)
                .lineLimit(1)

            body(for: provider)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provider-card-\(provider.providerName)")
    }

    /// Mirrors `ProviderDetailView.windowsBody`'s three cases so a provider
    /// that is errored or window-less reads the same on both screens.
    @ViewBuilder
    private func body(for provider: ProviderStatus) -> some View {
        if !provider.ok {
            Text(provider.errorMessage ?? "error")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .frame(height: 22, alignment: .leading)
        } else if visibleWindows.isEmpty {
            Text("no window data")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(height: 22, alignment: .leading)
        } else {
            VStack(spacing: 2) {
                ForEach(Array(visibleWindows.enumerated()), id: \.offset) { _, window in
                    WindowRow(window: window, now: now)
                }
            }
        }
    }

    /// Windows whose percentage violates INV-3 are dropped rather than drawn
    /// as an `unknown`-colored row: at this density a muted row reads as a real
    /// pool the user has run down, not as missing data.
    var visibleWindows: [ProviderWindow] {
        provider.windows.filter { percentIsValid($0.percentLeft) }
    }
}
