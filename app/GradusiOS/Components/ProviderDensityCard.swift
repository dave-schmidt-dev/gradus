import GradusKit
import SwiftUI

/// A provider and *every* one of its windows, as one card (iPad Option B).
///
/// Deliberately not a variant of the superseded `StatTile` (deleted
/// 2026-08-06; recoverable at `5bce2af`, the commit before the deletion —
/// `249deaf` is only where its last *caller* went away). That tile answered
/// "which single
/// window matters most for this provider", and its selected-window/badge state
/// only meant something when one window was privileged. This card answers "show
/// me everything", so it has no selection state at all — every window is a peer
/// `WindowRow`. Trying to express both in one type meant a selection concept
/// that was inert half the time, which is why the whole selection API went with
/// the tile rather than being kept for a future caller.
///
/// Tapping still pushes Provider Detail: this card shows the same windows, but
/// detail adds pace, per-window provenance, and the observed-at footer.
struct ProviderDensityCard: View {
    let provider: ProviderStatus
    let now: Date
    /// Forwarded to every `WindowRow`; see that type for why compact width
    /// drops the reset column.
    let showsReset: Bool

    init(provider: ProviderStatus, now: Date, showsReset: Bool = true) {
        self.provider = provider
        self.now = now
        self.showsReset = showsReset
    }

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
                    WindowRow(window: window, now: now, showsReset: showsReset)
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
