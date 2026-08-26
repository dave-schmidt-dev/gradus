import Foundation
import GradusKit
import SwiftUI

/// Applies the density decision before the provider content enters the menu.
/// The false arm deliberately has a fixed viewport: a `ScrollView` allowed to
/// take its content height would still make the popover overflow.
struct MenuProviderListView: View {
    let providers: [ProviderEntry]
    let now: Date
    let sortOption: ProviderSortOption
    let localThreshold: Double
    let availableMenuHeight: CGFloat?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        providers: [ProviderEntry],
        now: Date = Date(),
        sortOption: ProviderSortOption = .mostUrgent,
        localThreshold: Double = PublisherViewModel.defaultLocalWarningThresholdPercent,
        availableMenuHeight: CGFloat? = nil
    ) {
        self.providers = providers
        self.now = now
        self.sortOption = sortOption
        self.localThreshold = localThreshold
        self.availableMenuHeight = availableMenuHeight
    }

    private var resolution: MenuDensityResolution {
        MenuVerticalBudget.resolve(
            providers: providers,
            dynamicTypeSize: dynamicTypeSize,
            referenceHeight: availableMenuHeight ?? MenuVerticalBudget.runtimeReferenceHeight
        )
    }

    var body: some View {
        if resolution.didFit {
            providerList
        } else {
            ScrollView {
                providerList.padding(.bottom, 1)
            }
            .frame(height: MenuVerticalBudget.providerViewportHeight(for: resolution.referenceHeight))
            .accessibilityIdentifier("menu-provider-list-scroll")
        }
    }

    private var providerList: some View {
        ProviderListView(
            providers: providers,
            now: now,
            sortOption: sortOption,
            localThreshold: localThreshold,
            density: resolution.rung
        )
    }
}

// The provider rows, split out from `MenuContentView` so they can be
// snapshot-tested standalone. Multi-window providers use a provider heading
// and labeled bucket rows; singleton providers compose both names in one
// compact header. The menu stays a single ordered column so the visual order
// always matches the selected sort without reserving empty grid cells.

struct ProviderListView: View {
    let providers: [ProviderEntry]
    let now: Date
    let sortOption: ProviderSortOption
    let localThreshold: Double
    let density: MenuDensityRung

    init(
        providers: [ProviderEntry],
        now: Date = Date(),
        sortOption: ProviderSortOption = .mostUrgent,
        localThreshold: Double = PublisherViewModel.defaultLocalWarningThresholdPercent,
        density: MenuDensityRung = .standard
    ) {
        self.providers = providers
        self.now = now
        self.sortOption = sortOption
        self.localThreshold = localThreshold
        self.density = density
    }

    private var ranked: RankedProviders<ProviderEntry> {
        rankedPartition(providers, localThreshold: localThreshold, sortOption: sortOption)
    }

    var body: some View {
        if providers.isEmpty {
            Text("No snapshot data yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let ranked = ranked
            VStack(alignment: .leading, spacing: density.providerSpacing) {
                activeProviders(ranked.active)
                if !ranked.exhausted.isEmpty {
                    ExhaustedProviderSection(providers: ranked.exhausted, now: now, density: density)
                }
            }
        }
    }

    private func activeProviders(_ providers: [ProviderEntry]) -> some View {
        ForEach(providers, id: \.name) { provider in
            ProviderRow(provider: provider, now: now, density: density)
        }
    }
}

/// Providers with nothing left stay at the bottom, but retain the same provider
/// header and per-window rows as active providers. The menu's information
/// contract is the same for every provider: one header plus every window.
private struct ExhaustedProviderSection: View {
    let providers: [ProviderEntry]
    let now: Date
    let density: MenuDensityRung

    var body: some View {
        VStack(alignment: .leading, spacing: density.rowSpacing + 1) {
            Divider()
            Text("Exhausted")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            ForEach(providers, id: \.name) { provider in
                ProviderRow(provider: provider, now: now, density: density)
            }
        }
    }
}

/// One provider. Every bucket renders the same label, bar, reset, and pace
/// structure. Severity changes color, never whether a bucket explains itself.
private struct ProviderRow: View {
    /// Declared here rather than inline because the metadata line below has to
    /// clear the expected-remaining marker, which is deliberately taller than
    /// the bar so it reads as a tick rather than a segment. Without reserving
    /// that overhang the "resets …" text visually touches the marker.
    let provider: ProviderEntry
    let now: Date
    let density: MenuDensityRung

    var body: some View {
        Group {
            if provider.ok, provider.windows.count == 1 {
                compactWindow(provider.windows[0])
            } else {
                expandedWindows
            }
        }
        .accessibilityIdentifier("menu-provider-\(provider.name)")
    }

    private func compactWindow(_ window: ProviderWindow) -> some View {
        VStack(alignment: .leading, spacing: density.rowSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(MenuContentView.compactProviderLabel(providerName: provider.name))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(percentDisplay(window.percentLeft))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(MenuSignalPalette.color(for: window))
            }

            ProgressBar(
                fraction: max(0, min(100, window.percentLeft)) / 100,
                markerFraction: ProgressBar.expectedRemainingMarkerFraction(
                    percentLeft: window.percentLeft,
                    paceDelta: window.paceDelta
                ),
                tint: MenuSignalPalette.color(for: window)
            )
            .frame(height: density.barHeight)

            MenuWindowMetadata(window: window, now: now, density: density)
            zenCreditRow
        }
    }

    private var expandedWindows: some View {
        VStack(alignment: .leading, spacing: density.rowSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(provider.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if provider.windows.isEmpty {
                    Text("—")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(provider.ok ? .secondary : SignalColor.forLevel(.red))
                }
            }

            if !provider.ok,
               !ProviderRetryAccessibility.isCarriedFailure(provider)
               || ProviderRetryAccessibility.isClaudeRateLimited(provider) {
                let label = ProviderRetryAccessibility.displayLabel(for: provider)
                    ?? "Provider probe failed"
                Text(label)
                    .font(.caption)
                    .foregroundStyle(
                        ProviderRetryAccessibility.isRetrying(provider)
                            || ProviderRetryAccessibility.isStale(provider)
                            ? .secondary
                            : SignalColor.forLevel(.red)
                    )
                    .lineLimit(2)
                    .accessibilityIdentifier("provider-status-\(provider.name)")
                    .accessibilityLabel(label)
            }

            if provider.windows.isEmpty, provider.ok {
                Text("no window data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(CrossSurfaceParity.visibleWindows(provider.windows), id: \.id) { window in
                    MenuWindowRow(provider: provider, window: window, now: now, density: density)
                }
            }
            zenCreditRow
        }
    }

    private var zenCreditText: String? {
        guard provider.name == "OpenCode Go",
              let credit = provider.data["zen_credit"]?.doubleValue,
              credit.isFinite,
              credit >= 0 else {
            return nil
        }
        return String(
            format: "$%.3f", locale: Locale(identifier: "en_US_POSIX"), credit
        )
    }

    @ViewBuilder
    private var zenCreditRow: some View {
        if let credit = zenCreditText {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Zen credit")
                    .font(density.metadataFont.weight(.medium))
                Spacer(minLength: 4)
                Text(credit)
                    .font(density.metadataFont.monospacedDigit())
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }
}

private struct MenuWindowRow: View {
    let provider: ProviderEntry
    let window: ProviderWindow
    let now: Date
    let density: MenuDensityRung

    var body: some View {
        VStack(alignment: .leading, spacing: density.rowSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(ProviderWindowLabel.label(for: window.id))
                    .font(density.metadataFont.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(percentDisplay(window.percentLeft))
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(MenuSignalPalette.color(for: window))
            }

            ProgressBar(
                fraction: max(0, min(100, window.percentLeft)) / 100,
                markerFraction: ProgressBar.expectedRemainingMarkerFraction(
                    percentLeft: window.percentLeft,
                    paceDelta: window.paceDelta
                ),
                tint: MenuSignalPalette.color(for: window)
            )
            .frame(height: density.barHeight)

            MenuWindowMetadata(window: window, now: now, density: density)
        }
        .padding(.leading, MenuContentView.providerBarLeadingInset)
    }
}

struct MenuWindowMetadata: View {
    let window: ProviderWindow
    let now: Date
    let density: MenuDensityRung

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.resetLabel(for: window, now: now))
            Spacer(minLength: 4)
            Text(paceLabel(for: window))
        }
        .font(density.metadataFont)
        .foregroundStyle(.secondary)
        .padding(.top, ProgressBar.markerOverhang(barHeight: density.barHeight))
    }

    static func resetLabel(for window: ProviderWindow, now: Date) -> String {
        guard let resetISO = window.resetISO else { return "reset unavailable" }
        return "resets \(friendlyResetDate(resetISO, now: now) ?? resetISO)"
    }
}
