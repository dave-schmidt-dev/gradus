import GradusKit
import SwiftUI
import UIKit

let dashboardHorizontalInset: CGFloat = 16

/// The "Now" screen (P3/T3.3): every provider as a `ProviderDensityCard`
/// showing every one of its windows, in `rankProviders`' total order — or one
/// of the three distinct empty states (CV-5) when there's nothing to show yet.
///
/// Both size classes use the same presentation, differing only in column count
/// and whether each window row carries its reset time. The earlier compact
/// layout was a ranked list of `StatTile`s: one hero tile enlarging the worst
/// provider, and one window per provider with the rest behind selection
/// badges. It was replaced rather than kept alongside because the two answered
/// the same question with different amounts of the answer — the phone showed
/// one window per provider while the iPad showed all of them, so the same
/// account read as healthy on one device and not the other.
///
/// Root is a populated `NavigationStack`: the dashboard is always the first
/// screen, including on compact iPhone widths. Provider detail remains a
/// normal push destination, so its back affordance returns to this populated
/// root rather than an empty split-view sidebar.
struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel
    let now: Date

    init(viewModel: DashboardViewModel, now: Date = Date()) {
        self.viewModel = viewModel
        self.now = now
    }

    var body: some View {
        NavigationStack {
            DashboardContent(viewModel: viewModel, now: now)
        }
    }
}

/// The "Now" screen's actual content, factored out of `DashboardView.body`
/// (T3.3 gate) so it's directly snapshot-testable and independently
/// reusable. Factored out specifically to sidestep a distinct
/// navigation shell. `DashboardSnapshotTests` snapshots this type directly so
/// content ordering stays independently testable from navigation chrome.
/// Which dashboard presentation to use. Derived from the horizontal size
/// class, but expressible directly so tests can assert the dense layout
/// without depending on how an offscreen snapshot host propagates traits.
enum DashboardLayout {
    /// iPhone and any compact width: the same `ProviderDensityCard`s as iPad in
    /// a single column, with each row's reset column dropped so the bar keeps
    /// enough width to read.
    case denseSingleColumn
    /// iPad and any regular width (Option B): a multi-column grid of
    /// `ProviderDensityCard`s showing every provider *and* every window at
    /// once, no drill-in needed.
    case denseGrid

    /// The editorial comfort rule: reset is welcome on the wider presentation
    /// but deliberately omitted from the compact presentation even when the
    /// collapse floor says the column would technically fit.
    var editorialShowsReset: Bool { self == .denseGrid }
}

/// The provider/window identity that both size classes promise to present.
/// Keeping this semantic shape separate from pixels lets parity tests reject
/// an information split even when the two devices necessarily have different
/// viewport geometry.
struct DashboardProviderWindowSet: Equatable {
    let providerName: String
    let windowIDs: [String]
}

struct DashboardContent: View {
    @ObservedObject var viewModel: DashboardViewModel
    let now: Date

    /// `nil` means "follow the size class". Tests pass an explicit value.
    private let layoutOverride: DashboardLayout?
    /// `nil` means "use the stored preference". Snapshot tests pass an explicit
    /// density so a baseline names the density it depicts rather than depending
    /// on whatever `UserDefaults` the fixture happened to build.
    private let densityOverride: DashboardDensity?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Row-tap navigation target (P4/T4.2): set on tap of any
    /// `ProviderDensityCard`, pushing `ProviderDetailView` for that provider.
    /// Same behavior in both layouts (INV-12). Tracked by `providerName`
    /// (not the `ProviderStatus` value itself) since `ProviderStatus` isn't
    /// `Hashable` and `.navigationDestination(item:)` requires that --
    /// looking the provider back up from `viewModel.providers` by name
    /// keeps this file from having to add a `Hashable` conformance to a
    /// `GradusKit` model type for a purely-iOS navigation concern.
    @State private var selectedProviderName: String?
    /// Settings presentation (P5/T5.3): a sheet rather than a
    /// `navigationDestination` push -- decoupled from the `selectedProviderName`
    /// push-navigation state Phase 4 owns above, and matches the design
    /// system's "one trailing accessory" nav-bar rule without needing
    /// Settings to participate in the same navigation stack as provider
    /// detail drill-in.
    @State private var showingSettings = false

    // The grid must resolve its column count before the child WindowRows are
    // installed. Keep the same compile-time style mapping as WindowRow here;
    // reading a child's @ScaledMetric through a temporary View would use the
    // default environment and silently make the solver ignore Dynamic Type.
    @ScaledMetric(relativeTo: .caption) private var compactLabelWidth = DensityMetrics.compact.labelWidth
    @ScaledMetric(relativeTo: .caption) private var compactPercentWidth = DensityMetrics.compact.percentWidth
    @ScaledMetric(relativeTo: .caption2) private var compactResetWidth = DensityMetrics.compact.resetWidth
    @ScaledMetric(relativeTo: .footnote) private var standardLabelWidth = DensityMetrics.standard.labelWidth
    @ScaledMetric(relativeTo: .footnote) private var standardPercentWidth = DensityMetrics.standard.percentWidth
    @ScaledMetric(relativeTo: .caption) private var standardResetWidth = DensityMetrics.standard.resetWidth
    @ScaledMetric(relativeTo: .subheadline) private var largeLabelWidth = DensityMetrics.large.labelWidth
    @ScaledMetric(relativeTo: .subheadline) private var largePercentWidth = DensityMetrics.large.percentWidth
    @ScaledMetric(relativeTo: .footnote) private var largeResetWidth = DensityMetrics.large.resetWidth

    init(
        viewModel: DashboardViewModel,
        now: Date = Date(),
        layout: DashboardLayout? = nil,
        density: DashboardDensity? = nil
    ) {
        self.viewModel = viewModel
        self.now = now
        self.layoutOverride = layout
        self.densityOverride = density
    }

    var layout: DashboardLayout {
        layoutOverride ?? (horizontalSizeClass == .regular ? .denseGrid : .denseSingleColumn)
    }

    var body: some View {
        VStack(spacing: 0) {
            MobileNavBar(title: "Gradus") {
                HStack(spacing: 12) {
                    // Both layouts traded the former ConnectionInfoCard's four
                    // stacked lines for this one, so the provenance it dropped
                    // has somewhere to go. The full computer/user/publish
                    // detail lives in Settings' "Connected Computer" section.
                    SyncStatusLine(
                        source: viewModel.connectedSource,
                        publishedAt: viewModel.connectedSourcePublishedAt,
                        now: now
                    )
                    IconButton(Icon.settings) {
                        showingSettings = true
                    }
                }
            }

            Group {
                if let emptyState = viewModel.emptyState {
                    EmptyStateView(state: emptyState) {
                        viewModel.syncEnabled = true
                    }
                } else {
                    denseGrid
                }
            }
        }
        .navigationDestination(item: $selectedProviderName) { providerName in
            if let provider = viewModel.providers.first(where: { $0.providerName == providerName }) {
                ProviderDetailView(provider: provider, now: now)
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(dashboardViewModel: viewModel)
        }
    }

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

    /// Semantic parity surface for iPhone and iPad snapshots. Ordering is
    /// intentional: it is the row-major provider order users read left to
    /// right, followed by the source window order inside each card.
    var semanticProviderWindowSet: [DashboardProviderWindowSet] {
        viewModel.providers.map {
            DashboardProviderWindowSet(
                providerName: $0.providerName,
                windowIDs: $0.windows.map(\.id))
        }
    }

    private struct GridResolution {
        let metrics: DensityMetrics
        let columns: Int
        let maximumColumns: Int
        let didFitDensity: Bool
    }

    private func gridResolution(in contentWidth: CGFloat) -> GridResolution {
        switch layout {
        case .denseSingleColumn:
            let rung = densityOverride
                ?? DashboardViewModel.resolvedCardDensity(
                    preference: viewModel.cardColumnPreference,
                    sizeStops: DashboardViewModel.cardSizeStopCount(
                        for: viewModel.availableCardColumns))
                ?? .compact
            return GridResolution(
                metrics: rung.metrics, columns: 1, maximumColumns: 1, didFitDensity: true)
        case .denseGrid:
            // Explicit rungs are snapshot-only fixtures. They preserve the
            // pre-slider baselines while production follows the one-way
            // slider -> column count -> card width -> rung pipeline below.
            if let densityOverride {
                let columns = legacyColumnCount(for: densityOverride, contentWidth: contentWidth)
                return GridResolution(
                    metrics: densityOverride.metrics,
                    columns: columns,
                    maximumColumns: columns,
                    didFitDensity: true)
            }

            let compact = DashboardDensity.compact.metrics
            let stops = feasibleColumnStops(
                containerWidth: contentWidth,
                scaledFixedColumnWidth: scaledFixedColumnWidth(
                    for: .compact, showsReset: false),
                cardPadding: compact.cardPadding,
                cardGap: compact.cardGap,
                minimumBarWidth: DensityMetrics.minimumBarWidth)
            let maximum = stops.last ?? 1
            let sizeStops = DashboardViewModel.cardSizeStopCount(for: maximum)
            let selectedColumns = DashboardViewModel.resolvedCardColumnCount(
                preference: viewModel.cardColumnPreference,
                maximum: maximum,
                sizeStops: sizeStops)
            let preferred = DashboardViewModel.resolvedCardDensity(
                preference: viewModel.cardColumnPreference,
                sizeStops: sizeStops)
            let resolution = DashboardDensity.resolveRung(preferred: preferred) { rung in
                let rungMetrics = rung.metrics
                let width = cardWidth(
                    containerWidth: contentWidth,
                    columns: selectedColumns,
                    cardGap: rungMetrics.cardGap)
                return width - rungMetrics.cardPadding * 2
                    - scaledFixedColumnWidth(for: rung, showsReset: false)
                    >= DensityMetrics.minimumBarWidth
            }
            return GridResolution(
                metrics: resolution.rung.metrics,
                columns: selectedColumns,
                maximumColumns: maximum,
                didFitDensity: resolution.didFit)
        }
    }

    /// The pre-slider behavior remains available only to explicit snapshot
    /// fixtures. Runtime selection is handled by `gridResolution(in:)`.
    private func legacyColumnCount(
        for density: DashboardDensity,
        contentWidth: CGFloat
    ) -> Int {
        let metrics = density.metrics
        let fixedColumnWidth: CGFloat
        if scaledFixedColumnWidth(for: density, showsReset: true)
            > metrics.fixedColumnWidth(showsReset: true)
        {
            fixedColumnWidth = scaledFixedColumnWidth(for: density, showsReset: false)
        } else {
            fixedColumnWidth = max(
                0,
                metrics.gridMinimum - metrics.cardPadding * 2
                    - DensityMetrics.minimumBarWidth)
        }
        return maxColumns(
            containerWidth: contentWidth,
            scaledFixedColumnWidth: fixedColumnWidth,
            cardPadding: metrics.cardPadding,
            cardGap: metrics.cardGap,
            minimumBarWidth: DensityMetrics.minimumBarWidth)
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
        let columns: (label: CGFloat, percent: CGFloat, reset: CGFloat)
        switch density {
        case .compact:
            columns = (compactLabelWidth, compactPercentWidth, compactResetWidth)
        case .standard:
            columns = (standardLabelWidth, standardPercentWidth, standardResetWidth)
        case .large:
            columns = (largeLabelWidth, largePercentWidth, largeResetWidth)
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
            scaledFixedColumnWidth: scaledFixedColumnWidth)
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
            cardGap: metrics.cardGap)
        return layout.editorialShowsReset
            && metrics.fitsResetColumn(
                inCardWidth: resolvedWidth,
                scaledFixedColumnWidth: scaledFixedColumnWidth)
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
    @ViewBuilder
    private var denseGrid: some View {
        GeometryReader { geometry in
            let contentWidth = geometry.size.width - dashboardHorizontalInset * 2
            let resolution = gridResolution(in: contentWidth)
            let resolvedShowsReset = runtimeShowsReset(
                inContentWidth: contentWidth,
                columns: resolution.columns,
                metrics: resolution.metrics,
                scaledFixedColumnWidth: scaledFixedColumnWidth(
                    for: resolution.metrics.rung, showsReset: true))
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
            minimumBarWidth: 0)
        return Array(
            repeating: GridItem(.flexible(), spacing: metrics.exhaustedGap, alignment: .top),
            count: columns)
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

/// A row-major, row-balanced layout for the provider cards.
///
/// `LazyVGrid` keeps every card in a row at the height of that row's tallest
/// card, but its implicit sizing leaves the shorter card background ragged.
/// This layout makes that contract explicit: it measures each row, assigns
/// every card in the row the measured maximum height, and advances only after
/// the complete row. That preserves true left-to-right/top-to-bottom reading
/// order while removing the ragged below-card edge.
struct ProviderRowBalancedLayout: Layout {
    let columns: Int
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    private var resolvedColumns: Int { max(1, columns) }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? 0
        let columnWidth = widthForColumn(containerWidth: width)
        let rowHeights = rowHeights(subviews: subviews, columnWidth: columnWidth)
        let totalHeight = rowHeights.reduce(0) { partial, rowHeight in
            partial + rowHeight + (partial == 0 ? 0 : verticalSpacing)
        }
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let columnWidth = widthForColumn(containerWidth: bounds.width)
        let heights = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
        }
        let frames = Self.frames(
            cardHeights: heights,
            columns: resolvedColumns,
            cardWidth: columnWidth,
            horizontalSpacing: horizontalSpacing,
            verticalSpacing: verticalSpacing)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    /// Production's row measurement is exposed to tests so the regression
    /// check cannot drift into a duplicate arithmetic model.
    static func rowHeights(cardHeights: [CGFloat], columns: Int) -> [CGFloat] {
        let count = max(1, columns)
        return stride(from: 0, to: cardHeights.count, by: count).map { start in
            cardHeights[start..<min(start + count, cardHeights.count)].max() ?? 0
        }
    }

    /// The production frame model used by the semantic/render parity test.
    static func frames(
        cardHeights: [CGFloat],
        columns: Int,
        cardWidth: CGFloat,
        horizontalSpacing: CGFloat,
        verticalSpacing: CGFloat
    ) -> [CGRect] {
        let count = max(1, columns)
        let rows = rowHeights(cardHeights: cardHeights, columns: count)
        var result: [CGRect] = []
        var rowOrigin: CGFloat = 0
        for (row, rowHeight) in rows.enumerated() {
            let firstIndex = row * count
            let lastIndex = min(firstIndex + count, cardHeights.count)
            for index in firstIndex..<lastIndex {
                let column = index - firstIndex
                result.append(CGRect(
                    x: CGFloat(column) * (cardWidth + horizontalSpacing),
                    y: rowOrigin,
                    width: cardWidth,
                    height: rowHeight))
            }
            rowOrigin += rowHeight + verticalSpacing
        }
        return result
    }

    private func widthForColumn(containerWidth: CGFloat) -> CGFloat {
        max(
            0,
            (containerWidth - CGFloat(resolvedColumns - 1) * horizontalSpacing)
                / CGFloat(resolvedColumns))
    }

    private func rowHeights(subviews: Subviews, columnWidth: CGFloat) -> [CGFloat] {
        Self.rowHeights(
            cardHeights: subviews.map {
                $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            },
            columns: resolvedColumns)
    }
}
