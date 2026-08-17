import GradusKit
import SwiftUI

/// A quiet structural edge for the card surface. This is deliberately a
/// fixed design token rather than a provider or health accent: window signal
/// remains encoded by the bars and status text inside the card.
enum ProviderDensityCardStructuralToken {
    static let navyHex: UInt32 = 0x00005F
    static let opacity = 0.55

    static var color: Color {
        Color(red: 0, green: 0, blue: 95.0 / 255.0).opacity(opacity)
    }
}

/// A provider and *every* one of its windows, as one card (iPad Option B).
///
/// Deliberately not a variant of the superseded `StatTile` (deleted
/// 2026-08-06; recoverable at `5bce2af`, the commit before the deletion —
/// `249deaf` is only where its last *caller* went away). That tile answered
/// "which single window matters most for this provider", and its
/// selected-window/badge state only meant something when one window was
/// privileged. This card answers "show me everything", so it has no selection
/// state at all — every window is a peer `WindowRow`. Trying to express both in
/// one type meant a selection concept that was inert half the time, which is
/// why the whole selection API went with the tile rather than being kept for a
/// future caller.
///
/// Tapping still pushes Provider Detail: this card shows the same windows, but
/// detail adds pace, per-window provenance, and the observed-at footer.
struct ProviderDensityCard: View {
    let provider: ProviderStatus
    let now: Date
    /// Forwarded to every `WindowRow`; see that type for why compact width
    /// drops the reset column.
    let showsReset: Bool
    /// The density the user picked, as measurements. Passed down rather than
    /// re-derived per view so the card's padding and its rows' heights cannot
    /// come from different densities mid-render.
    let metrics: DensityMetrics

    init(
        provider: ProviderStatus,
        now: Date,
        showsReset: Bool = true,
        metrics: DensityMetrics = .compact
    ) {
        self.provider = provider
        self.now = now
        self.showsReset = showsReset
        self.metrics = metrics
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.titleGap) {
            Text(provider.providerDisplayName)
                .font(metrics.titleFont)
                // The row-balanced layout measures each card at its actual width,
                // so a large Dynamic Type title can wrap without pushing a
                // neighbouring column or losing the provider identity.
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            body(for: provider)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(metrics.cardPadding)
        .background(
            .quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: metrics.cornerRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: metrics.cornerRadius)
                .strokeBorder(ProviderDensityCardStructuralToken.color, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provider-card-\(provider.providerName)")
    }

    /// Mirrors `ProviderDetailView.windowsBody`'s three cases so a provider
    /// that is errored or window-less reads the same on both screens.
    @ViewBuilder
    private func body(for provider: ProviderStatus) -> some View {
        if !visibleWindows.isEmpty {
            VStack(spacing: metrics.rowGap) {
                ForEach(Array(visibleWindows.enumerated()), id: \.offset) { _, window in
                    WindowRow(
                        window: window, now: now, showsReset: showsReset, metrics: metrics
                    )
                }
                if !provider.ok, !IOSProviderRetryAccessibility.isCarriedFailure(provider) {
                    errorText
                }
            }
        } else if !provider.ok, !IOSProviderRetryAccessibility.isCarriedFailure(provider) {
            errorText
                .frame(height: metrics.rowHeight, alignment: .leading)
        } else {
            Text("no window data")
                .font(metrics.labelFont)
                .foregroundStyle(.secondary)
                .frame(height: metrics.rowHeight, alignment: .leading)
        }
    }

    private var errorText: some View {
        let label = IOSProviderRetryAccessibility.displayLabel(for: provider) ?? "error"
        return Text(label)
            .font(metrics.labelFont)
            .foregroundStyle(
                IOSProviderRetryAccessibility.isRetrying(provider) ? Color.secondary : Color.red
            )
            .lineLimit(2)
            .accessibilityLabel(label)
    }

    /// Windows whose percentage violates INV-3 are dropped rather than drawn
    /// as an `unknown`-colored row: at this density a muted row reads as a real
    /// pool the user has run down, not as missing data.
    var visibleWindows: [ProviderWindow] {
        CrossSurfaceParity.visibleWindows(provider.windows)
    }
}
