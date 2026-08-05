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
/// `selectedWindow == nil` is a real, reachable state -- an errored or
/// no-window-data provider can legitimately be ranked as the hero (Phase
/// 3's OW-1 ranking fix) -- and renders an error variant in both sizes.
/// This is a superset of `ProviderCard.swift`'s existing three-way
/// error/window/no-data branch (`ProviderCard.swift:29-53`), not a new
/// invented UI state: `!provider.ok` renders `errorMessage` in red exactly
/// like `ProviderCard`'s error branch, and `provider.ok` with no window
/// data renders the same "no window data" secondary-style copy.
struct StatTile: View {
    let provider: ProviderStatus
    let selectedWindow: ProviderWindow?
    let badgeWindows: [ProviderWindow]
    let onSelectWindow: (ProviderWindow) -> Void
    let now: Date
    var isHero: Bool = false

    init(
        provider: ProviderStatus,
        selectedWindow: ProviderWindow?,
        badgeWindows: [ProviderWindow] = [],
        isHero: Bool = false,
        now: Date = Date(),
        onSelectWindow: @escaping (ProviderWindow) -> Void = { _ in }
    ) {
        self.provider = provider
        self.selectedWindow = selectedWindow
        self.badgeWindows = badgeWindows
        self.isHero = isHero
        self.now = now
        self.onSelectWindow = onSelectWindow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isHero ? 6 : 2) {
            Text(provider.providerDisplayName)
                .font(isHero ? .title2.bold() : .headline)

            if let selectedWindow {
                windowBody(selectedWindow)
            } else {
                errorBody
            }
        }
        .padding(.vertical, isHero ? 10 : 3)
    }

    @ViewBuilder
    private func windowBody(_ window: ProviderWindow) -> some View {
        let color = SignalColor.forWindow(window)

        if isHero {
            HStack(alignment: .firstTextBaseline) {
                Text(ProviderWindowLabel.label(for: window.id))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(Int(window.percentLeft))%")
                    .font(.system(size: 48, weight: .bold).monospacedDigit())
                    .foregroundStyle(color)
            }
            UsageBar(window: window, color: color)
        } else {
            Text(ProviderWindowLabel.label(for: window.id))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                UsageBar(window: window, color: color)
                Text("\(Int(window.percentLeft))%")
                    .font(.subheadline.monospacedDigit())
            }
        }

        if !badgeWindows.isEmpty {
            HStack(spacing: 6) {
                ForEach(badgeWindows, id: \.id) { badgeWindow in
                    Button {
                        onSelectWindow(badgeWindow)
                    } label: {
                        Text("\(ProviderWindowLabel.label(for: badgeWindow.id)) \(Int(badgeWindow.percentLeft))%")
                            .font(.caption.weight(.semibold).monospacedDigit())
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(
                        "Select \(ProviderWindowLabel.label(for: badgeWindow.id)), \(Int(badgeWindow.percentLeft)) percent remaining"
                    )
                }
            }
            // UsageBar's red pace marker intentionally extends beyond its
            // four-point layout height. Keep the alternate-window controls
            // clear of that marker without restoring the larger provider-row
            // padding that was removed for the dense dashboard.
            .padding(.top, 8)
        }

        HStack(spacing: 12) {
            if let resetISO = window.resetISO {
                Text("reset \(friendlyResetDate(resetISO, now: now) ?? resetISO)")
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
