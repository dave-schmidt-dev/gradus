import GradusKit
import SwiftUI
import UIKit

/// Grid-resolution math and the dense-grid rendering itself, split out of
/// `DashboardView.swift` (T3.3 gate: file/type length) but still part of
/// `DashboardContent` -- every member here reads the same `@ScaledMetric`/
/// `@State`/`@Environment` storage the main declaration installs.
extension DashboardContent {
    /// One column on iPhone, an explicit solver-selected count on iPad.
    ///
    /// The compact case is `.flexible()` rather than the same
    /// former 320pt minimum. That rule *would* resolve to one column at
    /// 361pt of content width, but only as arithmetic that happens to work
    /// out — a narrower card minimum or a wider phone would silently produce
    /// two cramped columns. Stating "one column" says what is meant.
    /// Explicit test rung, or the compact ladder floor for callers that ask a
    /// non-geometric question. Rendering always uses `gridResolution(in:)`.
    var metrics: DensityMetrics {
        (densityOverride ?? .compact).metrics
    }

    private struct GridResolution {
        let metrics: DensityMetrics
        let columns: Int
        let maximumColumns: Int
        let didFitDensity: Bool
    }

    /// The three `@ScaledMetric` demand columns for one density rung, named so
    /// the width solver doesn't have to spell out an anonymous 3-member tuple.
    private struct DensityColumnWidths {
        let label: CGFloat
        let percent: CGFloat
        let reset: CGFloat
    }

    private func gridResolution(in contentWidth: CGFloat) -> GridResolution {
        switch layout {
        case .denseSingleColumn:
            singleColumnGridResolution()
        case .denseGrid:
            denseGridResolution(in: contentWidth)
        }
    }

    private func singleColumnGridResolution() -> GridResolution {
        let rung = densityOverride
            ?? DashboardViewModel.resolvedCardDensity(
                preference: viewModel.cardColumnPreference,
                sizeStops: DashboardViewModel.cardSizeStopCount(
                    for: viewModel.availableCardColumns
                )
            )
            ?? .compact
        return GridResolution(
            metrics: rung.metrics, columns: 1, maximumColumns: 1, didFitDensity: true
        )
    }

    private func denseGridResolution(in contentWidth: CGFloat) -> GridResolution {
        // Explicit rungs are snapshot-only fixtures. They preserve the
        // pre-slider baselines while production follows the one-way
        // slider -> column count -> card width -> rung pipeline below.
        if let densityOverride {
            let columns = legacyColumnCount(for: densityOverride, contentWidth: contentWidth)
            return GridResolution(
                metrics: densityOverride.metrics,
                columns: columns,
                maximumColumns: columns,
                didFitDensity: true
            )
        }

        let compact = DashboardDensity.compact.metrics
        let stops = feasibleColumnStops(
            containerWidth: contentWidth,
            scaledFixedColumnWidth: scaledFixedColumnWidth(
                for: .compact, showsReset: false
            ),
            cardPadding: compact.cardPadding,
            cardGap: compact.cardGap,
            minimumBarWidth: DensityMetrics.minimumBarWidth
        )
        let maximum = stops.last ?? 1
        let sizeStops = DashboardViewModel.cardSizeStopCount(for: maximum)
        let selectedColumns = DashboardViewModel.resolvedCardColumnCount(
            preference: viewModel.cardColumnPreference,
            maximum: maximum,
            sizeStops: sizeStops
        )
        let preferred = DashboardViewModel.resolvedCardDensity(
            preference: viewModel.cardColumnPreference,
            sizeStops: sizeStops
        )
        let resolution = DashboardDensity.resolveRung(preferred: preferred) { rung in
            let rungMetrics = rung.metrics
            let width = cardWidth(
                containerWidth: contentWidth,
                columns: selectedColumns,
                cardGap: rungMetrics.cardGap
            )
            return width - rungMetrics.cardPadding * 2
                - scaledFixedColumnWidth(for: rung, showsReset: false)
                >= DensityMetrics.minimumBarWidth
        }
        return GridResolution(
            metrics: resolution.rung.metrics,
            columns: selectedColumns,
            maximumColumns: maximum,
            didFitDensity: resolution.didFit
        )
    }

    /// The pre-slider behavior remains available only to explicit snapshot
    /// fixtures. Runtime selection is handled by `gridResolution(in:)`.
    private func legacyColumnCount(
        for density: DashboardDensity,
        contentWidth: CGFloat
    ) -> Int {
        let metrics = density.metrics
        let fixedColumnWidth: CGFloat = if scaledFixedColumnWidth(for: density, showsReset: true)
            > metrics.fixedColumnWidth(showsReset: true) {
            scaledFixedColumnWidth(for: density, showsReset: false)
        } else {
            max(
                0,
                metrics.gridMinimum - metrics.cardPadding * 2
                    - DensityMetrics.minimumBarWidth
            )
        }
        return maxColumns(
            containerWidth: contentWidth,
            scaledFixedColumnWidth: fixedColumnWidth,
            cardPadding: metrics.cardPadding,
            cardGap: metrics.cardGap,
            minimumBarWidth: DensityMetrics.minimumBarWidth
        )
    }

    /// The row owns Dynamic Type scaling; the grid only consumes its exposed
    /// values to choose a count before the rows are laid out. This is resolved
    /// in this view rather than by reading a temporary WindowRow, because
    /// DynamicProperty values are only valid after their owning view installs
    /// them in the environment.
    private func scaledFixedColumnWidth(
        for density: DashboardDensity,
        showsReset: Bool
    ) -> CGFloat {
        let columns = switch density {
        case .compact:
            DensityColumnWidths(label: compactLabelWidth, percent: compactPercentWidth, reset: compactResetWidth)
        case .standard:
            DensityColumnWidths(label: standardLabelWidth, percent: standardPercentWidth, reset: standardResetWidth)
        case .large:
            DensityColumnWidths(label: largeLabelWidth, percent: largePercentWidth, reset: largeResetWidth)
        }
        let fixed = columns.label + columns.percent
            + (showsReset ? columns.reset : 0)
        let gaps = density.metrics.columnGap * CGFloat(showsReset ? 3 : 2)
        return fixed + gaps
    }

    /// The answer sent to every card after the grid has resolved its count and
    /// therefore its actual card width. Geometry can only remove reset from
    /// the layout's named editorial comfort decision.
    func runtimeShowsReset(
        inContentWidth contentWidth: CGFloat,
        columns: Int,
        scaledFixedColumnWidth: CGFloat
    ) -> Bool {
        runtimeShowsReset(
            inContentWidth: contentWidth,
            columns: columns,
            metrics: metrics,
            scaledFixedColumnWidth: scaledFixedColumnWidth
        )
    }

    private func runtimeShowsReset(
        inContentWidth contentWidth: CGFloat,
        columns: Int,
        metrics: DensityMetrics,
        scaledFixedColumnWidth: CGFloat
    ) -> Bool {
        let resolvedWidth = cardWidth(
            containerWidth: contentWidth,
            columns: columns,
            cardGap: metrics.cardGap
        )
        return layout.editorialShowsReset
            && metrics.fitsResetColumn(
                inCardWidth: resolvedWidth,
                scaledFixedColumnWidth: scaledFixedColumnWidth
            )
    }

    /// Every provider and every window at once, on both platforms.
    ///
    /// On iPad, the solver chooses an explicit count rather than a fixed two.
    /// The mock was drawn at portrait width, where this resolves to two — but
    /// the whole point is to use the screen, and landscape has room for three.
    /// A fixed count would stretch cards across 1366pt and reintroduce the
    /// wasted horizontal space this layout exists to remove.
    ///
    /// Active providers as full density cards, then exhausted ones in a
    /// compact section at the bottom.
    ///
    /// An earlier version rendered exhausted providers inline as ordinary
    /// cards, on the reasoning that the ranking already sorts them last and an
    /// all-red card reads as spent. In practice that spends a full card —
    /// every window, every bar — on the one provider you can do nothing about,
    /// and on a phone it pushes the actionable rows off the first screen. A
    /// spent provider raises exactly one question: when does it come back.
    /// Name and reset time answer it in two lines.
    ///
    /// The `showExhausted` preference still applies upstream — it filters the
    /// source array, so hiding them removes this section entirely.
    var denseGrid: some View {
        GeometryReader { geometry in
            let contentWidth = geometry.size.width - dashboardHorizontalInset * 2
            let resolution = gridResolution(in: contentWidth)
            let resolvedShowsReset = runtimeShowsReset(
                inContentWidth: contentWidth,
                columns: resolution.columns,
                metrics: resolution.metrics,
                scaledFixedColumnWidth: scaledFixedColumnWidth(
                    for: resolution.metrics.rung, showsReset: true
                )
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ProviderRowBalancedLayout(
                        columns: resolution.columns,
                        horizontalSpacing: resolution.metrics.cardGap,
                        verticalSpacing: resolution.metrics.cardGap
                    ) {
                        ForEach(activeProviders, id: \.providerName) { provider in
                            ProviderDensityCard(
                                provider: provider,
                                now: now,
                                showsReset: resolvedShowsReset,
                                metrics: resolution.metrics
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedProviderName = provider.providerName
                            }
                        }
                    }
                    .frame(width: contentWidth, alignment: .leading)
                    if !exhaustedProviders.isEmpty {
                        exhaustedSection(metrics: resolution.metrics, contentWidth: contentWidth)
                    }
                }
                .padding(.horizontal, dashboardHorizontalInset)
                .padding(.bottom, 16)
            }
            .onAppear {
                viewModel.setAvailableCardColumns(resolution.maximumColumns)
            }
            .onChange(of: resolution.maximumColumns) { _, maximum in
                viewModel.setAvailableCardColumns(maximum)
            }
        }
    }

    /// `viewModel.providers` already arrives in `rankedPartition` order with
    /// exhausted last, so filtering here preserves both the split and the
    /// order within each half — it does not re-derive either.
    private var activeProviders: [ProviderStatus] {
        viewModel.providers.filter { !$0.isDepleted }
    }

    private var exhaustedProviders: [ProviderStatus] {
        viewModel.providers.filter(\.isDepleted)
    }

    /// Sizes cells from the actual reset-label demand at the active Dynamic
    /// Type size. The timestamp is the exhausted cell's purpose, so an explicit
    /// solver count must never create a cell that truncates it mid-string.
    private func exhaustedColumns(metrics: DensityMetrics, contentWidth: CGFloat) -> [GridItem] {
        let columns = maxColumns(
            containerWidth: contentWidth,
            scaledFixedColumnWidth: exhaustedResetLabelWidth(for: metrics.rung),
            cardPadding: metrics.cardPadding,
            cardGap: metrics.exhaustedGap,
            minimumBarWidth: 0
        )
        return Array(
            repeating: GridItem(.flexible(), spacing: metrics.exhaustedGap, alignment: .top),
            count: columns
        )
    }

    private func exhaustedSection(metrics: DensityMetrics, contentWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: metrics.exhaustedGap) {
            Text("Exhausted")
                .font(metrics.exhaustedHeaderFont)
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("exhausted-section-header")
            LazyVGrid(
                columns: exhaustedColumns(metrics: metrics, contentWidth: contentWidth),
                alignment: .leading,
                spacing: metrics.exhaustedGap
            ) {
                ForEach(exhaustedProviders, id: \.providerName) { provider in
                    exhaustedCell(provider, metrics: metrics)
                }
            }
        }
    }

    private func exhaustedResetLabelWidth(for density: DashboardDensity) -> CGFloat {
        let style: UIFont.TextStyle = switch density {
        case .compact: .caption1
        case .standard: .footnote
        case .large: .subheadline
        }
        let font = UIFont.preferredFont(forTextStyle: style, compatibleWith: dynamicTypeTraits)
        return ("resets Aug 12, 7:46 PM" as NSString).size(withAttributes: [.font: font]).width
    }

    private var dynamicTypeTraits: UITraitCollection {
        let category: UIContentSizeCategory = switch dynamicTypeSize {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
        return UITraitCollection(preferredContentSizeCategory: category)
    }

    /// Still tappable through to the detail view: compact is about how much
    /// the row costs on screen, not about withholding the full breakdown from
    /// anyone who wants it.
    private func exhaustedCell(_ provider: ProviderStatus, metrics: DensityMetrics) -> some View {
        VStack(alignment: .leading, spacing: metrics.exhaustedLineGap) {
            Text(provider.providerDisplayName)
                .font(metrics.exhaustedTitleFont)
                // At accessibility sizes, a one-column iPhone can no longer
                // fit a full provider name on one line. Let the cell grow
                // rather than replace part of the name with an ellipsis.
                .fixedSize(horizontal: false, vertical: true)
            Text(earliestResetLabel(provider.windows, now: now) ?? "reset unknown")
                .font(metrics.exhaustedResetFont)
                .foregroundStyle(.secondary)
                // The solver prevents a second cramped column. A full reset
                // timestamp can still exceed a narrow phone at AX4/AX5, so it
                // wraps instead of truncating mid-timestamp.
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: metrics.exhaustedRowHeight, alignment: .leading)
        .padding(.horizontal, metrics.cardPadding)
        .padding(.vertical, metrics.exhaustedGap)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: metrics.exhaustedCornerRadius))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedProviderName = provider.providerName
        }
        .accessibilityIdentifier("exhausted-provider-\(provider.providerName)")
    }
}
