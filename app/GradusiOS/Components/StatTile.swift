import GradusKit
import SwiftUI

/// Reusable per-provider stat tile (P2/T2.1): one component covering both
/// the large "hero" tile (exactly one per screen, Phase 3) and the compact
/// ranked-row variant, switched via `isHero` rather than two separate
/// types. Renders headline/percent/bar; colour comes from the percent-based
/// `SignalColor` ramp, never `ProviderAccent` (provider identity) -- per
/// the design system's own component rule ("colour comes from the signal
/// ramp, not the provider accent").
///
/// `worstWindow == nil` is a real, reachable state -- an errored or
/// no-window-data provider can legitimately be ranked as the hero (Phase
/// 3's OW-1 ranking fix) -- and renders an error variant in both sizes.
/// This is a superset of `ProviderCard.swift`'s existing three-way
/// error/window/no-data branch (`ProviderCard.swift:29-53`), not a new
/// invented UI state: `!provider.ok` renders `errorMessage` in red exactly
/// like `ProviderCard`'s error branch, and `provider.ok` with no window
/// data renders the same "no window data" secondary-style copy.
struct StatTile: View {
    let provider: ProviderStatus
    let worstWindow: ProviderWindow?
    var isHero: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: isHero ? 8 : 4) {
            Text(provider.providerDisplayName)
                .font(isHero ? .title2.bold() : .headline)

            if let worstWindow {
                windowBody(worstWindow)
            } else {
                errorBody
            }
        }
        .padding(.vertical, isHero ? 12 : 6)
    }

    @ViewBuilder
    private func windowBody(_ window: ProviderWindow) -> some View {
        let percent = max(0, min(100, window.percentLeft))
        let color = SignalColor.forPercent(window.percentLeft)

        if isHero {
            Text("\(Int(window.percentLeft))%")
                .font(.system(size: 48, weight: .bold).monospacedDigit())
                .foregroundStyle(color)
            ProgressView(value: percent / 100)
                .tint(color)
        } else {
            HStack {
                ProgressView(value: percent / 100)
                    .tint(color)
                Text("\(Int(window.percentLeft))%")
                    .font(.subheadline.monospacedDigit())
            }
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
    }

    @ViewBuilder
    private var errorBody: some View {
        if !provider.ok {
            Text(provider.errorMessage ?? "error")
                .font(.subheadline)
                .foregroundStyle(.red)
        } else {
            Text("no window data")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
