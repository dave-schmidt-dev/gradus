import GradusKit
import SnapshotTesting
import SwiftUI
import Testing
import UIKit

@testable import GradusiOS

// iPad Option B (David, 2026-08-05: "I like ipad b with bars for each
// bucket"): behavior coverage for the dense layout's routing, card content,
// and header provenance. The pixel coverage lives in
// `DensityLayoutSnapshotTests` below.

private let fixedNow = Date(timeIntervalSince1970: 1_785_000_000)

private func window(
    _ id: String, _ percentLeft: Double, pace: Double? = nil, reset: String? = "2026-07-26T09:00:00-04:00"
) -> ProviderWindow {
    ProviderWindow(id: id, percentLeft: percentLeft, resetISO: reset, windowHours: 168, paceDelta: pace)
}

private func provider(
    _ name: String, windows: [ProviderWindow], ok: Bool = true, error: String? = nil
) -> ProviderStatus {
    ProviderStatus(
        providerName: name,
        providerDisplayName: name.capitalized,
        ok: ok,
        errorMessage: error,
        windows: windows,
        data: [:],
        observedAt: ISO8601DateFormatter().string(from: fixedNow),
        snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
        publishedAt: fixedNow
    )
}

@MainActor
private func makeDensityViewModel(providers: [ProviderStatus]) -> DashboardViewModel {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-density-tests-\(UUID().uuidString)", isDirectory: true)
    let cache = FileLocalCacheStore(directory: directory)
    let defaults = UserDefaults(suiteName: "gradus-density-\(UUID().uuidString)")!
    defaults.set(true, forKey: DashboardViewModel.showExhaustedKey)
    try? cache.saveCachedStatuses(providers, syncedAt: fixedNow)
    return DashboardViewModel(cache: cache, userDefaults: defaults)
}

@MainActor
@Test func multiColumnIsSelectedForRegularWidthAndSingleColumnForCompact() {
    // The override exists for tests; the default path is the size class, so
    // assert the derivation itself rather than only the override.
    let viewModel = makeDensityViewModel(providers: [provider("codex", windows: [window("weekly", 50)])])
    #expect(DashboardContent(viewModel: viewModel, now: fixedNow, layout: .denseGrid).layout == .denseGrid)
    #expect(
        DashboardContent(viewModel: viewModel, now: fixedNow, layout: .denseSingleColumn).layout
            == .denseSingleColumn)
    // No override and no environment (the default `horizontalSizeClass` is
    // nil off-screen) must not silently pick the multi-column grid.
    #expect(DashboardContent(viewModel: viewModel, now: fixedNow).layout == .denseSingleColumn)
}

/// The layouts differ in density detail, never in *which* windows they show.
/// Guards the parity rule in `INVARIANTS.md` while exercising the runtime reset
/// answer: the two presentations may receive different row detail, but neither
/// may filter the provider's windows.
@MainActor
@Test func bothLayoutsShowEveryWindowAndDifferOnlyInDensityDetail() {
    let threeWindows = provider(
        "opencode",
        windows: [window("five_hour", 100), window("weekly", 61), window("monthly", 7)])
    let viewModel = makeDensityViewModel(providers: [threeWindows])
    let presentations: [(layout: DashboardLayout, width: CGFloat, expectedReset: Bool)] = [
        (.denseSingleColumn, 361, false),
        (.denseGrid, 802, true),
    ]

    for presentation in presentations {
        let dashboard = DashboardContent(
            viewModel: viewModel,
            now: fixedNow,
            layout: presentation.layout,
            density: .compact)
        let columns = presentation.layout == .denseSingleColumn
            ? 1
            : maxColumns(
                containerWidth: presentation.width,
                scaledFixedColumnWidth: 0,
                cardPadding: 0,
                cardGap: DashboardDensity.compact.metrics.cardGap,
                minimumBarWidth: DashboardDensity.compact.metrics.gridMinimum)
        let showsReset = dashboard.runtimeShowsReset(
            inContentWidth: presentation.width,
            columns: columns,
            scaledFixedColumnWidth: DashboardDensity.compact.metrics.fixedColumnWidth(showsReset: true))
        #expect(showsReset == presentation.expectedReset)

        let card = ProviderDensityCard(provider: threeWindows, now: fixedNow, showsReset: showsReset)
        #expect(card.visibleWindows.count == 3, "reset column must not change which windows render")
    }
}

@Test func syncStatusLineReportsAgeAndComputerName() {
    let published = fixedNow.addingTimeInterval(-120)
    let line = SyncStatusLine(
        source: SyncSource(computerName: "dm5mbp", userName: "dave"),
        publishedAt: published,
        now: fixedNow)
    #expect(line.renderedText == "synced 2m ago · dm5mbp")
}

@Test func syncStatusLineDegradesRatherThanFabricating() {
    let source = SyncSource(computerName: "dm5mbp", userName: "dave")
    // No publish timestamp: name only, no invented age.
    #expect(SyncStatusLine(source: source, publishedAt: nil, now: fixedNow).renderedText == "dm5mbp")
    // No source: age only.
    #expect(
        SyncStatusLine(source: nil, publishedAt: fixedNow.addingTimeInterval(-7200), now: fixedNow)
            .renderedText == "synced 2h ago")
    // Neither: render nothing at all rather than a placeholder.
    #expect(SyncStatusLine(source: nil, publishedAt: nil, now: fixedNow).renderedText == nil)
}

@Test func densityCardRendersEveryValidWindowAndDropsInvalidOnes() {
    // The point of Option B: no window is hidden behind a badge or a drill-in.
    let card = ProviderDensityCard(
        provider: provider(
            "codex",
            windows: [
                window("five_hour", 82, pace: 0.02),
                window("weekly", 47, pace: -0.08),
                window("monthly", 31, pace: -0.04),
            ]),
        now: fixedNow)
    #expect(card.visibleWindows.map(\.id) == ["five_hour", "weekly", "monthly"])

    // INV-3 violations are dropped, not drawn as an `unknown`-colored row --
    // at this density a muted row reads as a spent pool, not as missing data.
    let withInvalid = ProviderDensityCard(
        provider: provider("cursor", windows: [window("api", 150), window("auto", 40)]),
        now: fixedNow)
    #expect(withInvalid.visibleWindows.map(\.id) == ["auto"])
}

/// The candidate is deliberately row-major: every row is left-to-right and
/// every later row is below the complete preceding row. The test calls the
/// production frame model, so reverting production to independent columns (or
/// changing its row sizing) changes these exact results.
@Test func rowBalancedPlacementKeepsProviderOrderWithoutRaggedCards() {
    let heights: [CGFloat] = [244, 116, 190, 148, 92, 92, 168, 168]
    let spacing: CGFloat = 14
    let frames = ProviderRowBalancedLayout.frames(
        cardHeights: heights,
        columns: 2,
        cardWidth: 100,
        horizontalSpacing: spacing,
        verticalSpacing: spacing)

    #expect(frames.count == heights.count)
    #expect(frames[0].minY == 0)
    #expect(frames[1].minY == 0)
    #expect(frames[0].height == frames[1].height)
    #expect(frames[2].minY == frames[0].maxY + spacing)
    #expect(frames[3].minY == frames[2].minY)
    #expect(frames[2].height == frames[3].height)
    #expect(
        frames[2].minY >= frames[1].maxY,
        "a later source row must never appear above an earlier provider")
}

@Test func singleColumnPlacementRemainsContentDriven() {
    let heights: [CGFloat] = [144, 92, 118, 90]

    #expect(
        ProviderRowBalancedLayout.rowHeights(cardHeights: heights, columns: 1) == heights,
        "iPhone cards must retain their measured content heights")
    #expect(
        ProviderRowBalancedLayout.frames(
            cardHeights: heights,
            columns: 1,
            cardWidth: 361,
            horizontalSpacing: 14,
            verticalSpacing: 14
        ).map(\.height) == heights)
}

@Test func providerCardBorderIsFixedStructuralNavy() {
    #expect(ProviderDensityCardStructuralToken.navyHex == 0x00005F)
    #expect(ProviderDensityCardStructuralToken.opacity == 0.55)
}

@MainActor
@Test func fullFixturePinsPortraitLandscapeMeasurementsAndLargeText() {
    let providers = fullProviderSet()
    #expect(providers.count == 8)
    #expect(providers.reduce(0) { $0 + $1.windows.count } == 14)

    let standard = DashboardDensity.standard.metrics
    let solverMetrics = DashboardDensity.compact.metrics
    let portraitWidth = CGFloat(834) - dashboardHorizontalInset * 2
    let landscapeWidth = CGFloat(1194) - dashboardHorizontalInset * 2
    let portraitMaximum = maxColumns(
        containerWidth: portraitWidth,
        scaledFixedColumnWidth: solverMetrics.fixedColumnWidth(showsReset: false),
        cardPadding: solverMetrics.cardPadding,
        cardGap: solverMetrics.cardGap,
        minimumBarWidth: DensityMetrics.minimumBarWidth)
    let landscapeMaximum = maxColumns(
        containerWidth: landscapeWidth,
        scaledFixedColumnWidth: solverMetrics.fixedColumnWidth(showsReset: false),
        cardPadding: solverMetrics.cardPadding,
        cardGap: solverMetrics.cardGap,
        minimumBarWidth: DensityMetrics.minimumBarWidth)
    let portraitColumns = DashboardViewModel.resolvedCardColumnCount(
        preference: pinnedCardColumnPreference, maximum: portraitMaximum)
    let landscapeColumns = DashboardViewModel.resolvedCardColumnCount(
        preference: pinnedCardColumnPreference, maximum: landscapeMaximum)
    #expect(portraitColumns == portraitMaximum)
    #expect(landscapeColumns == landscapeMaximum)
    let portraitCardWidth = cardWidth(
        containerWidth: portraitWidth, columns: portraitColumns, cardGap: standard.cardGap)
    let landscapeCardWidth = cardWidth(
        containerWidth: landscapeWidth, columns: landscapeColumns, cardGap: standard.cardGap)

    struct MeasuredDevice {
        let name: String
        let cardWidth: CGFloat
        let columns: Int
    }
    for device in [
        MeasuredDevice(
            name: "iPad Pro 11-inch (M5) portrait", cardWidth: portraitCardWidth, columns: portraitColumns),
        MeasuredDevice(
            name: "iPad Pro 11-inch (M5) landscape", cardWidth: landscapeCardWidth, columns: landscapeColumns),
    ] {
        let heights = providers.map { provider in
            UIHostingController(
                rootView: ProviderDensityCard(
                    provider: provider,
                    now: fixedNow,
                    showsReset: true,
                    metrics: standard
                )
                .environment(\.dynamicTypeSize, .xxxLarge)
                .frame(width: device.cardWidth, alignment: .leading)
            ).sizeThatFits(in: CGSize(width: device.cardWidth, height: 4_000)).height
        }
        #expect(heights.allSatisfy { $0 > 0 }, "\(device.name) produced an empty provider card")
        let frames = ProviderRowBalancedLayout.frames(
            cardHeights: heights,
            columns: device.columns,
            cardWidth: device.cardWidth,
            horizontalSpacing: standard.cardGap,
            verticalSpacing: standard.cardGap)
        #expect(frames.count == providers.count)
        #expect(frames[0].minY == 0)
        for rowStart in stride(from: 0, to: frames.count, by: device.columns) {
            let rowEnd = min(rowStart + device.columns, frames.count)
            let rowFrames = Array(frames[rowStart..<rowEnd])
            let rowY = rowFrames[0].minY
            #expect(rowFrames.dropFirst().allSatisfy { $0.minY == rowY })
            #expect(rowFrames.dropFirst().allSatisfy { $0.height == rowFrames[0].height })
            if rowStart > 0 {
                #expect(rowY >= frames[rowStart - 1].maxY)
            }
        }
    }
}

/// The iPhone and iPad snapshots may differ in geometry, but never in the
/// provider/window identity set. The sole visual exception owned by this
/// phase is the shared label foreground token from Task 2.1.
@MainActor
@Test func iPhoneAndIPadSemanticSnapshotsHaveExactWindowParity() {
    let providers = fullProviderSet()
    let iPhone = DashboardContent(
        viewModel: makeDensityViewModel(providers: providers),
        now: fixedNow,
        layout: .denseSingleColumn,
        density: .standard)
    let iPad = DashboardContent(
        viewModel: makeDensityViewModel(providers: providers),
        now: fixedNow,
        layout: .denseGrid,
        density: .standard)

    let expectedProviderNames = Set(providers.map(\.providerName))
    #expect(Set(iPhone.semanticProviderWindowSet.map(\.providerName)) == expectedProviderNames)
    #expect(Set(iPad.semanticProviderWindowSet.map(\.providerName)) == expectedProviderNames)
    #expect(iPhone.semanticProviderWindowSet.count == 8)
    #expect(iPhone.semanticProviderWindowSet.reduce(0) { $0 + $1.windowIDs.count } == 14)
    #expect(iPhone.semanticProviderWindowSet == iPad.semanticProviderWindowSet)

    // Production's one-column frame model is compared with the explicit
    // legacy single-column geometry. This is the bounded render comparison:
    // no card position, width, height, provider order, or window set may vary
    // on iPhone; the only named pixel exception is the Task 2.1 label token.
    let measuredHeights: [CGFloat] = [144, 92, 118, 90]
    let iPhoneFrames = ProviderRowBalancedLayout.frames(
        cardHeights: measuredHeights,
        columns: 1,
        cardWidth: 361,
        horizontalSpacing: 14,
        verticalSpacing: 14)
    var expectedY: CGFloat = 0
    let expectedFrames = measuredHeights.map { height in
        let frame = CGRect(x: 0, y: expectedY, width: 361, height: height)
        expectedY += height + 14
        return frame
    }
    #expect(iPhoneFrames == expectedFrames)

    let visualDifferenceAllowlist = Set(["label-foreground-token"])
    let observedSharedDifference = String(describing: WindowRow.labelForegroundToken) == "readable"
        ? Set(["label-foreground-token"])
        : Set(["unlisted-label-token"])
    #expect(observedSharedDifference.subtracting(visualDifferenceAllowlist).isEmpty)
}

// MARK: - density (TASKS row 24)

/// Content width for each destination the gate runs, minus `denseGrid`'s shared
/// horizontal inset on each side.
private let deviceContentWidths: [(name: String, width: CGFloat, isGrid: Bool)] = [
    ("iPhone portrait", 393 - dashboardHorizontalInset * 2, false),
    ("iPad 11\" portrait", 834 - dashboardHorizontalInset * 2, true),
    ("iPad 11\" landscape", 1194 - dashboardHorizontalInset * 2, true),
    ("iPad 13\" landscape", 1366 - dashboardHorizontalInset * 2, true),
]

private let densityPropertyDynamicTypeSizes: [DynamicTypeSize] = [
    .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
    .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5,
]

private let densityPropertyProviderCounts = [1, 2, 4, 8]

private func usesTwoLineRow(at dynamicTypeSize: DynamicTypeSize) -> Bool {
    switch dynamicTypeSize {
    case .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5:
        true
    default:
        false
    }
}

/// The styles here mirror the nine `@ScaledMetric` declarations in
/// `WindowRow` and `DashboardContent`. UIKit supplies the same Dynamic Type
/// scale table without reading a SwiftUI Dynamic Property off-view.
private enum ProductionScaledMetricStyle {
    case caption
    case caption2
    case footnote
    case subheadline

    var uiTextStyle: UIFont.TextStyle {
        switch self {
        case .caption: .caption1
        case .caption2: .caption2
        case .footnote: .footnote
        case .subheadline: .subheadline
        }
    }
}

private func uiContentSizeCategory(for size: DynamicTypeSize) -> UIContentSizeCategory {
    switch size {
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
}

private func rowTextStyle(for density: DashboardDensity) -> UIFont.TextStyle {
    switch density {
    case .compact: .caption1
    case .standard: .footnote
    case .large: .subheadline
    }
}

private func scaledProductionMetric(
    _ value: CGFloat,
    relativeTo style: ProductionScaledMetricStyle,
    dynamicTypeSize: DynamicTypeSize
) -> CGFloat {
    let traits = UITraitCollection(
        preferredContentSizeCategory: uiContentSizeCategory(for: dynamicTypeSize))
    return UIFontMetrics(forTextStyle: style.uiTextStyle)
        .scaledValue(for: value, compatibleWith: traits)
}

private struct ScaledFixedColumnWidths {
    let label: CGFloat
    let percent: CGFloat
    let reset: CGFloat

    func total(showsReset: Bool, columnGap: CGFloat) -> CGFloat {
        label + percent + (showsReset ? reset : 0)
            + columnGap * CGFloat(showsReset ? 3 : 2)
    }
}

private func scaledProductionColumnWidths(
    density: DashboardDensity,
    dynamicTypeSize: DynamicTypeSize
) -> ScaledFixedColumnWidths {
    let metrics = density.metrics
    let styles: (label: ProductionScaledMetricStyle, percent: ProductionScaledMetricStyle, reset: ProductionScaledMetricStyle)
    switch density {
    case .compact:
        styles = (.caption, .caption, .caption2)
    case .standard:
        styles = (.footnote, .footnote, .caption)
    case .large:
        styles = (.subheadline, .subheadline, .footnote)
    }
    return ScaledFixedColumnWidths(
        label: scaledProductionMetric(metrics.labelWidth, relativeTo: styles.label, dynamicTypeSize: dynamicTypeSize),
        percent: scaledProductionMetric(metrics.percentWidth, relativeTo: styles.percent, dynamicTypeSize: dynamicTypeSize),
        reset: scaledProductionMetric(metrics.resetWidth, relativeTo: styles.reset, dynamicTypeSize: dynamicTypeSize)
    )
}

/// The default-size branch intentionally preserves the shipped packing. The
/// values are the historical card minima, kept here as test inputs rather
/// than read from the retired adaptive-grid metric. Once the scaled reset
/// demand grows, production switches to the no-reset fixed demand below.
private func historicalDefaultCardMinimum(for density: DashboardDensity) -> CGFloat {
    switch density {
    case .compact: 320
    case .standard: 360
    case .large: 460
    }
}

private let compactHistoricalTightCase = (
    density: DashboardDensity.compact,
    deviceName: "iPad 13\" landscape / historical tight case",
    contentWidth: CGFloat(1334),
    dynamicTypeSize: DynamicTypeSize.large,
    providerCount: 1,
    expectedBarWidth: CGFloat(54.5)
)

/// Pins `cardWidth` to what SwiftUI renders, rather than to itself.
///
/// So these four widths are not computed here: they were read off the committed
/// iPad baselines with a pixel scan (both are 834pt portrait at 3x, leaving
/// 802pt of content inside `denseGrid`'s 16pt margins). They are SwiftUI's own
/// output. No phone baseline reaches the exhausted section, so grounding the
/// formula on the two iPad surfaces is what makes its phone predictions —
/// `theExhaustedGridPacksAsIntendedOnEveryPhone` — worth trusting.
///
/// The standard exhausted row is the case that discriminates. Its minimum is
/// 260, but SwiftUI renders 260.67, which only follows if `.adaptive` seats
/// `floor((content + gap) / (minimum + gap))` columns and then divides *all*
/// the leftover space among them. The intuitive "each cell gets the minimum"
/// model predicts 260 and is simply wrong; the 0.5pt tolerance below is tight
/// enough to fail on it.
@Test func theColumnFormulaMatchesWhatSwiftUIActuallyRenders() {
    let iPadPortraitContent = deviceContentWidths[1].width
    let standard = DashboardDensity.standard.metrics
    let large = DashboardDensity.large.metrics

    let measured: [(columns: Int, gap: CGFloat, rendered: CGFloat, source: String)] = [
        (2, standard.cardGap, 394,
         "densityStandardPadPortraitLight, provider card at y=310pt spans 16.0->410.0"),
        (1, large.cardGap, 802,
         "densityLargePadPortraitLight, provider card at y=146pt spans 16.0->818.0"),
        (3, standard.exhaustedGap, 260.67,
         "densityStandardPadPortraitLight, exhausted cell at y=536pt spans 16.0->276.7"),
        (2, large.exhaustedGap, 395,
         "densityLargePadPortraitLight, exhausted cell at y=1074pt spans 16.0->411.0"),
    ]

    for (columns, gap, rendered, source) in measured {
        let predicted = cardWidth(
            containerWidth: iPadPortraitContent, columns: columns, cardGap: gap)
        #expect(
            abs(predicted - rendered) < 0.5,
            """
            The packing model this file is built on no longer matches SwiftUI: \
            columns \(columns) with gap \(gap) predicts \(predicted)pt, but the \
            baseline shows \(rendered)pt (\(source)). Re-measure before changing \
            the expected value — the baseline is the authority here, not the formula.
            """)
    }
}

/// The property that makes the density numbers trustworthy rather than
/// plausible: on every density, at every width the app ships to, the usage bar
/// still has room to read as a proportion.
///
/// This is the test the metrics table exists to satisfy. David chose (2026-08-06)
/// to scale type as well as spacing, which turned the row's *horizontal* demand
/// into a density variable — `labelWidth`/`percentWidth`/`resetWidth` all grow,
/// and a 320pt card that comfortably seated `.caption` columns cannot seat
/// `.subheadline` ones. Without this assertion the failure mode is a bar
/// squeezed toward zero on the widest screens, which no snapshot of an iPhone
/// would ever show.
@MainActor
@Test func everyDensityLeavesTheBarRoomToRead() {
    for device in deviceContentWidths {
        for dynamicTypeSize in densityPropertyDynamicTypeSizes {
            for providerCount in densityPropertyProviderCounts {
                let providers = (0..<providerCount).map { index in
                    provider(
                        "provider-\(index)",
                        windows: [window("weekly", 50)])
                }
                let viewModel = makeDensityViewModel(providers: providers)

                for density in DashboardDensity.allCases {
                    let metrics = density.metrics

                    if providerCount == densityPropertyProviderCounts.first,
                       usesTwoLineRow(at: dynamicTypeSize)
                    {
                        let traits = UITraitCollection(
                            preferredContentSizeCategory: uiContentSizeCategory(for: dynamicTypeSize))
                        let textLineHeight = UIFont.preferredFont(
                            forTextStyle: rowTextStyle(for: density), compatibleWith: traits).lineHeight
                        let rowWidth = max(1, device.width - metrics.cardPadding * 2)
                        let renderedHeight = UIHostingController(
                            rootView: WindowRow(
                                window: window("weekly", 50),
                                now: fixedNow,
                                showsReset: true,
                                metrics: metrics
                            )
                            .environment(\.dynamicTypeSize, dynamicTypeSize)
                        ).sizeThatFits(in: CGSize(width: rowWidth, height: 2_000)).height
                        let minimumTwoLineHeight = textLineHeight
                            + metrics.rowGap + metrics.barHeight
                        #expect(
                            renderedHeight >= minimumTwoLineHeight - 0.5,
                            "(density.rawValue) on (device.name) at (dynamicTypeSize) rendered (renderedHeight)pt, below the (minimumTwoLineHeight)pt two-line floor"
                        )
                    }

                    let scaledColumns = scaledProductionColumnWidths(
                        density: density, dynamicTypeSize: dynamicTypeSize)
                    let fixedDemand: CGFloat
                    if scaledColumns.total(showsReset: true, columnGap: metrics.columnGap)
                        > metrics.fixedColumnWidth(showsReset: true)
                    {
                        fixedDemand = scaledColumns.total(
                            showsReset: false, columnGap: metrics.columnGap)
                    } else {
                        fixedDemand = max(
                            0,
                            historicalDefaultCardMinimum(for: density)
                                - metrics.cardPadding * 2
                                - DensityMetrics.minimumBarWidth)
                    }
                    let columns = device.isGrid
                        ? maxColumns(
                            containerWidth: device.width,
                            scaledFixedColumnWidth: fixedDemand,
                            cardPadding: metrics.cardPadding,
                            cardGap: metrics.cardGap,
                            minimumBarWidth: DensityMetrics.minimumBarWidth)
                        : 1
                    let resolvedWidth = cardWidth(
                        containerWidth: device.width,
                        columns: columns,
                        cardGap: metrics.cardGap)
                    let scaledResetDemand = scaledColumns.total(
                        showsReset: true, columnGap: metrics.columnGap)
                    let dashboard = DashboardContent(
                        viewModel: viewModel,
                        now: fixedNow,
                        layout: device.isGrid ? .denseGrid : .denseSingleColumn,
                        density: density)
                    let showsReset = dashboard.runtimeShowsReset(
                        inContentWidth: device.width,
                        columns: columns,
                        scaledFixedColumnWidth: scaledResetDemand)
                    let expectedShowsReset = device.isGrid
                        && metrics.fitsResetColumn(
                            inCardWidth: resolvedWidth,
                            scaledFixedColumnWidth: scaledResetDemand)
                    #expect(
                        showsReset == expectedShowsReset,
                        """
                        \(density.rawValue) on \(device.name) at \(dynamicTypeSize) with \
                        \(providerCount) providers resolved reset=\(showsReset), expected \
                        \(expectedShowsReset).
                        """
                    )

                    // Phase 2 owns the visual two-line reflow at AX1+. Keep
                    // this Phase 1 arithmetic aligned with that contract: the
                    // bar gets the full card content width on its own line,
                    // while smaller text sizes pay the fixed-column demand.
                    let barWidth: CGFloat
                    if usesTwoLineRow(at: dynamicTypeSize) {
                        barWidth = resolvedWidth - metrics.cardPadding * 2
                    } else {
                        barWidth = resolvedWidth - metrics.cardPadding * 2
                            - (showsReset ? scaledResetDemand : scaledColumns.total(
                                showsReset: false, columnGap: metrics.columnGap))
                    }

                    #expect(
                        barWidth >= DensityMetrics.minimumBarWidth,
                        """
                        \(density.rawValue) on \(device.name): the bar gets \(barWidth)pt, \
                        under the \(DensityMetrics.minimumBarWidth)pt floor. Either the \
                        fixed columns grew or the solver packed too many columns.
                        """
                    )
                }
            }
        }
    }

    let historical = scaledProductionColumnWidths(
        density: compactHistoricalTightCase.density,
        dynamicTypeSize: compactHistoricalTightCase.dynamicTypeSize)
    let historicalColumns = maxColumns(
        containerWidth: compactHistoricalTightCase.contentWidth,
        scaledFixedColumnWidth: historicalDefaultCardMinimum(
            for: compactHistoricalTightCase.density)
            - compactHistoricalTightCase.density.metrics.cardPadding * 2
            - DensityMetrics.minimumBarWidth,
        cardPadding: compactHistoricalTightCase.density.metrics.cardPadding,
        cardGap: compactHistoricalTightCase.density.metrics.cardGap,
        minimumBarWidth: DensityMetrics.minimumBarWidth)
    let historicalCardWidth = cardWidth(
        containerWidth: compactHistoricalTightCase.contentWidth,
        columns: historicalColumns,
        cardGap: compactHistoricalTightCase.density.metrics.cardGap)
    let historicalBarWidth = historicalCardWidth
        - compactHistoricalTightCase.density.metrics.cardPadding * 2
        - historical.total(
            showsReset: true,
            columnGap: compactHistoricalTightCase.density.metrics.columnGap)
    #expect(historicalColumns == 4)
    #expect(historicalBarWidth == compactHistoricalTightCase.expectedBarWidth)
}

@Test func cardLayoutSolverKeepsBarsAboveTheFloorWhenPackingMultipleColumns() {
    let cases: [(container: CGFloat, fixed: CGFloat, padding: CGFloat, gap: CGFloat, minimum: CGFloat)] = [
        (802, 246, 12, 12, 48),
        (1162, 246, 12, 16, 48),
        (1334, 246, 12, 20, 48),
    ]

    #expect(
        maxColumns(
            containerWidth: 10,
            scaledFixedColumnWidth: 246,
            cardPadding: 12,
            cardGap: 12,
            minimumBarWidth: 48) == 1)

    for item in cases {
        let columns = maxColumns(
            containerWidth: item.container,
            scaledFixedColumnWidth: item.fixed,
            cardPadding: item.padding,
            cardGap: item.gap,
            minimumBarWidth: item.minimum)
        #expect(columns >= 1)
        if columns > 1 {
            let resolved = cardWidth(
                containerWidth: item.container, columns: columns, cardGap: item.gap)
            let barWidth = resolved - item.fixed - item.padding * 2
            #expect(barWidth >= item.minimum)
        }
    }
}

private func feasibleStops(
    for device: (name: String, width: CGFloat, isGrid: Bool),
    dynamicTypeSize: DynamicTypeSize
) -> [Int] {
    let scaledColumns = scaledProductionColumnWidths(
        density: .compact, dynamicTypeSize: dynamicTypeSize)
    return feasibleColumnStops(
        containerWidth: device.width,
        scaledFixedColumnWidth: scaledColumns.total(
            showsReset: false, columnGap: DashboardDensity.compact.metrics.columnGap),
        cardPadding: DashboardDensity.compact.metrics.cardPadding,
        cardGap: DashboardDensity.compact.metrics.cardGap,
        minimumBarWidth: DensityMetrics.minimumBarWidth)
}

@Test func feasibleSliderStopsCoverEveryDeviceWidthInLargerCardOrder() {
    for device in deviceContentWidths {
        let stops = feasibleStops(for: device, dynamicTypeSize: .large)
        let scaledColumns = scaledProductionColumnWidths(
            density: .compact, dynamicTypeSize: .large)
        let expectedMaximum = maxColumns(
            containerWidth: device.width,
            scaledFixedColumnWidth: scaledColumns.total(
                showsReset: false, columnGap: DashboardDensity.compact.metrics.columnGap),
            cardPadding: DashboardDensity.compact.metrics.cardPadding,
            cardGap: DashboardDensity.compact.metrics.cardGap,
            minimumBarWidth: DensityMetrics.minimumBarWidth)

        #expect(stops == Array(1...expectedMaximum), Comment(rawValue: device.name))
        #expect(stops.allSatisfy { $0 >= 1 }, Comment(rawValue: device.name))
    }

    // A two-column layout is not offered when only one column clears the bar.
    #expect(
        feasibleColumnStops(
            containerWidth: 390,
            scaledFixedColumnWidth: 120,
            cardPadding: 12,
            cardGap: 12,
            minimumBarWidth: 48) == [1])
}

@Test func extraExtraExtraLargeOffersFewerSliderStopsOnTheSameDevice() {
    let device = deviceContentWidths[3]
    let defaultStops = feasibleStops(for: device, dynamicTypeSize: .large)
    let xxxLargeStops = feasibleStops(for: device, dynamicTypeSize: .xxxLarge)

    #expect(xxxLargeStops.count < defaultStops.count)
}

@Test func everyFeasibleSliderStopLeavesTheMinimumBarWidthAcrossTextSizes() {
    let metrics = DashboardDensity.compact.metrics

    for device in deviceContentWidths {
        for dynamicTypeSize in densityPropertyDynamicTypeSizes {
            let scaledColumns = scaledProductionColumnWidths(
                density: .compact, dynamicTypeSize: dynamicTypeSize)
            let fixedWidth = scaledColumns.total(
                showsReset: false, columnGap: metrics.columnGap)
            for columns in feasibleStops(for: device, dynamicTypeSize: dynamicTypeSize) {
                let barWidth = cardWidth(
                    containerWidth: device.width,
                    columns: columns,
                    cardGap: metrics.cardGap)
                    - metrics.cardPadding * 2
                    - fixedWidth
                #expect(
                    barWidth >= DensityMetrics.minimumBarWidth,
                    "\(device.name) at \(dynamicTypeSize), \(columns) columns")
            }
        }
    }
}

@MainActor
@Test func autoUsesTheLargestFeasibleStopOnPhoneAndPad() {
    let phone = deviceContentWidths.first { !$0.isGrid }!
    let pad = deviceContentWidths.first { $0.isGrid }!
    let phoneStops = feasibleStops(for: phone, dynamicTypeSize: .large)
    let padStops = feasibleStops(for: pad, dynamicTypeSize: .large)

    #expect(phoneStops == [1], "iPhone has one feasible column count")
    #expect(DashboardViewModel.cardSizeStopCount(for: phoneStops.last!) == 1)
    #expect(padStops.count > phoneStops.count, "iPad exposes its wider feasible range")
    #expect(
        DashboardViewModel.resolvedCardColumnCount(
            preference: 0, maximum: phoneStops.last!) == phoneStops.last!)
    #expect(
        DashboardViewModel.resolvedCardColumnCount(
            preference: 0, maximum: padStops.last!) == padStops.last!)
    #expect(
        DashboardViewModel.resolvedCardColumnCount(
            preference: 1, maximum: padStops.last!) == padStops.last!)
}

/// Selecting `.compact` must reproduce 1.6.0 exactly, so that adding the
/// density axis is not itself a visual change for anyone who never opens the
/// setting.
///
/// The literals are spelled out rather than compared against the views'
/// constants, because the views now *read* these — asserting they match would
/// only prove `a == a`. These numbers come from the pre-density source: the
/// three column widths and 22pt row from `WindowRow`, the 12pt padding and
/// corner radius from `ProviderDensityCard`, the 4pt bar from `UsageBar`, and
/// the 320pt minimum from `DashboardContent.columns`.
@Test func compactDensityReproducesTheShippedGeometry() {
    let compact = DensityMetrics.compact
    #expect(compact.labelWidth == 78)
    #expect(compact.percentWidth == 40)
    #expect(compact.resetWidth == 104)
    #expect(compact.columnGap == 8)
    #expect(compact.rowHeight == 22)
    #expect(compact.barHeight == 4)
    #expect(compact.cardPadding == 12)
    #expect(compact.titleGap == 6)
    #expect(compact.rowGap == 2)
    #expect(compact.cardGap == 12)
    #expect(compact.cornerRadius == 12)
    #expect(compact.gridMinimum == 320)
    // The documented pre-density arithmetic, restated as the two numbers
    // `WindowRow`'s comment cites. A 393pt phone gives a 361pt card; 246pt of
    // fixed columns leaves the bar 91pt, and dropping reset gives it 203pt.
    #expect(compact.fixedColumnWidth(showsReset: true) == 246)
    #expect(361 - compact.cardPadding * 2 - compact.fixedColumnWidth(showsReset: true) == 91)
    #expect(361 - compact.cardPadding * 2 - compact.fixedColumnWidth(showsReset: false) == 203)

    // Note what this does *not* claim: 91pt clears `minimumBarWidth`, so the
    // reset column does not collapse the bar on a phone — `fitsResetColumn`
    // correctly says it fits. Dropping it at compact width is a stricter
    // editorial choice on top of that (91pt against 203pt is a large
    // readability difference), not a geometric necessity. Conflating the two
    // is what this assertion originally got wrong: it expected the collapse
    // test to justify a comfort decision.
    #expect(compact.fitsResetColumn(inCardWidth: 361))

    // The exhausted section's compact measurements. Its column count is now
    // derived from the typeset reset label at the live text size, rather than
    // from a separate unscaled minimum.
    #expect(compact.exhaustedLineGap == 2)
    #expect(compact.exhaustedGap == 8)
    #expect(compact.exhaustedRowHeight == 52)
    #expect(compact.exhaustedCornerRadius == 10)
}

/// The provider card is rendered over the real light/dark surface tokens, not
/// over an abstract white/black background. `.secondary` is the prior
/// recessed token; it is intentionally asserted below as a failing mutation
/// fixture so a future visual regression cannot quietly restore it.
@Test func usageBucketLabelContrastMeetsWCAGAAAgainstCardSurfaces() {
    let token = WindowRow.labelForegroundToken
    let foreground = token.effectiveForeground
    let lightRatio = foreground.light.contrastRatio(with: ProviderDensityCardSurfaceToken.light)
    let darkRatio = foreground.dark.contrastRatio(with: ProviderDensityCardSurfaceToken.dark)
    let normalRatio = min(lightRatio, darkRatio)

    #expect(normalRatio >= 4.5, "normal label contrast is only \(normalRatio):1")
    #expect(min(lightRatio, darkRatio) >= 3, "large/accessibility label contrast is only \(normalRatio):1")

    let recessed = WindowRowLabelForegroundToken.recessed.effectiveForeground
    let recessedNormalRatio = min(
        recessed.light.contrastRatio(with: ProviderDensityCardSurfaceToken.light),
        recessed.dark.contrastRatio(with: ProviderDensityCardSurfaceToken.dark))
    #expect(
        recessedNormalRatio < 4.5,
        "the old secondary token unexpectedly clears normal-label AA; keep the mutation fixture honest")
}

/// Standard and XXXL are the two readability checkpoints for the named
/// buckets. The spoken row value is a semantic snapshot of the same label that
/// is drawn beside the bar, so this catches an accidental raw-id fallback or
/// truncation without adding a second byte-identical pixel baseline.
@MainActor
@Test func usageBucketLabelsRemainIdentifiableAtStandardAndXXXL() {
    let expected: [(id: String, label: String)] = [
        ("five_hour", "5 Hour"),
        ("weekly", "Weekly"),
        ("monthly", "Monthly"),
        ("premium", "Monthly"),
        ("billing_cycle", "Monthly"),
        ("ac", "Auto"),
        ("ap", "API"),
    ]

    for dynamicTypeSize in [DynamicTypeSize.large, .xxxLarge] {
        for (id, label) in expected {
            let row = WindowRow(
                window: window(id, 47), now: fixedNow, showsReset: false, metrics: .standard)
                .environment(\.dynamicTypeSize, dynamicTypeSize)
            let renderedWidth = UIHostingController(
                rootView: row.fixedSize(horizontal: true, vertical: false)
            ).sizeThatFits(in: CGSize(width: 2_000, height: 200)).width

            #expect(ProviderWindowLabel.label(for: id) == label)
            #expect(rowContentContainsLabel(id: id, label: label))
            #expect(renderedWidth >= 1, "\(label) rendered no measurable row at \(dynamicTypeSize)")
        }
    }
}

private func rowContentContainsLabel(id: String, label: String) -> Bool {
    let row = WindowRow(window: window(id, 47), now: fixedNow, showsReset: false, metrics: .standard)
    return row.spokenLabel.hasPrefix("\(label),")
}

/// A density that is only *partly* larger reads as a rendering bug rather than
/// a setting. Ordering is asserted across the whole table so a future edit to
/// one field cannot leave, say, `.standard` with taller rows than `.large`.
@Test func densitiesAreOrderedOnEveryMeasurement() {
    let ordered = DashboardDensity.allCases.map(\.metrics)
    #expect(DashboardDensity.allCases == [.compact, .standard, .large])

    for (smaller, bigger) in zip(ordered, ordered.dropFirst()) {
        #expect(bigger.rowHeight > smaller.rowHeight)
        #expect(bigger.barHeight > smaller.barHeight)
        #expect(bigger.cardPadding > smaller.cardPadding)
        #expect(bigger.rowGap > smaller.rowGap)
        #expect(bigger.cardGap > smaller.cardGap)
        #expect(bigger.titleGap > smaller.titleGap)
        // Type grows, so the columns sized for it must grow too. This is the
        // pairing that broke when only the fonts were bumped: `resetWidth` was
        // already corrected once from 74, which truncated "Aug 23, 9:30 PM" to
        // "Aug 23, 9:3…" -- and a half-rendered timestamp still reads as
        // information, which is worse than omitting it.
        #expect(bigger.labelWidth > smaller.labelWidth)
        #expect(bigger.percentWidth > smaller.percentWidth)
        #expect(bigger.resetWidth > smaller.resetWidth)
        #expect(bigger.gridMinimum > smaller.gridMinimum)
        // The exhausted section is on the same screen, directly under the
        // cards. If it did not move with them, choosing a larger density would
        // scale the top of the dashboard and leave the bottom at 12pt -- and
        // the reason to choose a larger density is that 12pt is hard to read.
        #expect(bigger.exhaustedRowHeight > smaller.exhaustedRowHeight)
        #expect(bigger.exhaustedGap > smaller.exhaustedGap)
        #expect(bigger.exhaustedLineGap > smaller.exhaustedLineGap)
        #expect(bigger.exhaustedCornerRadius > smaller.exhaustedCornerRadius)
    }
}

@MainActor
@Test func windowRowScalesFixedColumnsAtExtraExtraExtraLarge() {
    let row = WindowRow(
        window: window("weekly", 47), now: fixedNow, showsReset: true, metrics: .compact)
    let defaultSize = UIHostingController(rootView: row.fixedSize(horizontal: true, vertical: false))
        .sizeThatFits(in: CGSize(width: 2_000, height: 200))
    let xxxLargeSize = UIHostingController(
        rootView: row.environment(\.dynamicTypeSize, .xxxLarge)
            .fixedSize(horizontal: true, vertical: false)
    ).sizeThatFits(in: CGSize(width: 2_000, height: 200))
    // Apple's literal `.xxxLarge` category scales this row by about 1.48x;
    // the plan's documented ~1.9x checkpoint is reached at the next
    // accessibility rung. The row itself reflows at AX1+, so compare the
    // fixed-column demand directly rather than comparing two different row
    // structures' intrinsic widths.
    #expect(xxxLargeSize.width > defaultSize.width)
    let defaultColumns = scaledProductionColumnWidths(
        density: .compact, dynamicTypeSize: .large)
    let xxxLargeColumns = scaledProductionColumnWidths(
        density: .compact, dynamicTypeSize: .xxxLarge)
    let accessibility2Columns = scaledProductionColumnWidths(
        density: .compact, dynamicTypeSize: .accessibility2)
    for (defaultValue, xxxLargeValue) in zip(
        [defaultColumns.label, defaultColumns.percent, defaultColumns.reset],
        [xxxLargeColumns.label, xxxLargeColumns.percent, xxxLargeColumns.reset])
    {
        #expect(xxxLargeValue > defaultValue)
    }
    for (xxxLargeValue, accessibility2Value) in zip(
        [xxxLargeColumns.label, xxxLargeColumns.percent, xxxLargeColumns.reset],
        [accessibility2Columns.label, accessibility2Columns.percent, accessibility2Columns.reset])
    {
        #expect(accessibility2Value > xxxLargeValue)
    }
    let ratio = accessibility2Columns.total(showsReset: true, columnGap: DensityMetrics.compact.columnGap)
        / defaultColumns.total(showsReset: true, columnGap: DensityMetrics.compact.columnGap)
    #expect(ratio > 1.75 && ratio < 2.05, "expected roughly 1.9x fixed-column width, got \(ratio)x")
}

@MainActor
@Test func windowRowUsesScaledContentHeightAsTheRowFloorAtExtraExtraExtraLarge() {
    let row = WindowRow(
        window: window("weekly", 47), now: fixedNow, showsReset: true, metrics: .compact)
    let rendered = UIHostingController(
        rootView: row.environment(\.dynamicTypeSize, .xxxLarge)
    ).sizeThatFits(in: CGSize(width: 2_000, height: 200))
    let trait = UITraitCollection(preferredContentSizeCategory: .extraExtraExtraLarge)
    let scaledContentHeight = UIFont.preferredFont(
        forTextStyle: .caption1, compatibleWith: trait).lineHeight

    #expect(rendered.height >= scaledContentHeight)
    #expect(rendered.height >= DensityMetrics.compact.rowHeight)
}

/// Every iPhone width the app ships to, minus `denseSingleColumn`'s 16pt
/// horizontal padding on each side. The list spans the range rather than
/// sampling it, because what this test checks is *where the column count
/// changes*, and a boundary is only visible from both sides of it.
private let phoneContentWidths: [(name: String, content: CGFloat)] = [
    ("iPhone SE / mini (375pt)", 343),
    ("iPhone 15 (390pt)", 358),
    ("iPhone 16 (393pt)", 361),
    ("iPhone 16 Pro (402pt)", 370),
    ("iPhone 16 Plus (430pt)", 398),
    ("iPhone 16 Pro Max (440pt)", 408),
]

/// The exhausted grid on a phone is the one part of this section no snapshot
/// reaches: at every density the eight active cards push it past the bottom of a
/// 393x852 viewport, so `densityLargePhoneDark` passes without covering a pixel
/// of it. That is worth stating rather than papering over with a snapshot at a
/// height no device has — the section is real, a user scrolls to it, and what
/// can be checked cheaply is the number that decides its shape.
///
/// The count is derived from the same typeset reset-label demand that the view
/// supplies to the solver. This keeps every phone from gaining a second column
/// when Dynamic Type makes the timestamp wider.
@Test func theExhaustedGridPacksAsIntendedOnEveryPhone() {
    for (density, _, resetStyle) in exhaustedTextStyles {
        let metrics = density.metrics
        for dynamicTypeSize in densityPropertyDynamicTypeSizes {
            let resetDemand = typesetWidth(
                "resets Aug 12, 7:46 PM",
                exhaustedFont(resetStyle, dynamicTypeSize: dynamicTypeSize))
            for phone in phoneContentWidths {
                let packed = maxColumns(
                    containerWidth: phone.content,
                    scaledFixedColumnWidth: resetDemand,
                    cardPadding: metrics.cardPadding,
                    cardGap: metrics.exhaustedGap,
                    minimumBarWidth: 0)
                let resolvedWidth = cardWidth(
                    containerWidth: phone.content,
                    columns: packed,
                    cardGap: metrics.exhaustedGap)
                let textWidth = resolvedWidth - metrics.cardPadding * 2
                let widestResetToken = widestUnbreakableTokenWidth(
                    in: "resets Aug 12, 7:46 PM", font: exhaustedFont(
                        resetStyle, dynamicTypeSize: dynamicTypeSize))
                #expect(
                    textWidth >= widestResetToken,
                    """
                    \(density.rawValue) at \(dynamicTypeSize) packs \(packed) exhausted columns on \
                    \(phone.name), leaving \(textWidth)pt for its widest unbreakable reset component \
                    (\(widestResetToken)pt). The full label may wrap at accessibility sizes but must not truncate.
                    """
                )
                if resetDemand <= textWidth {
                    #expect(textWidth >= resetDemand)
                } else {
                    #expect(packed == 1)
                }
            }
        }
    }
}

/// SwiftUI's `Font` exposes neither a point size nor line metrics, so measuring
/// what the exhausted cell has to hold means going through UIKit's equivalent
/// text style. This table is the one thing the test cannot derive: it restates
/// the style each density's `exhaustedTitleFont`/`exhaustedResetFont` names.
/// Change a font in `DashboardDensity.swift` without changing the matching row
/// here and the test keeps passing while measuring the wrong string.
private let exhaustedTextStyles:
    [(density: DashboardDensity, title: UIFont.TextStyle, reset: UIFont.TextStyle)] = [
        (.compact, .subheadline, .caption1),
        (.standard, .callout, .footnote),
        (.large, .body, .subheadline),
    ]

private func exhaustedFont(
    _ style: UIFont.TextStyle,
    dynamicTypeSize: DynamicTypeSize = .large
) -> UIFont {
    UIFont.preferredFont(
        forTextStyle: style,
        compatibleWith: UITraitCollection(
            preferredContentSizeCategory: uiContentSizeCategory(for: dynamicTypeSize)))
}

private func typesetWidth(_ string: String, _ font: UIFont) -> CGFloat {
    (string as NSString).size(withAttributes: [.font: font]).width
}

/// `Text` wraps at whitespace once its full line exceeds the solver-selected
/// cell width. The width assertion therefore protects every unbreakable piece,
/// which is the condition that makes the whole timestamp and provider name
/// readable without truncation on a narrow accessibility-size phone.
private func widestUnbreakableTokenWidth(in string: String, font: UIFont) -> CGFloat {
    string
        .split(whereSeparator: \.isWhitespace)
        .map { typesetWidth(String($0), font) }
        .max() ?? 0
}

/// The exhausted cell's job is to name a spent provider and say when it comes
/// back. A full reset timestamp is more important than preserving a one-line
/// cell: when Dynamic Type makes it too wide, the text wraps and the cell grows.
///
/// Asserted against the width the cell is actually *given* at each shipping
/// device width. The solver takes the typeset reset width as its fixed demand,
/// then divides the leftover space among its explicit columns.
///
/// Both strings are measured through UIKit rather than estimated from an
/// average character width. An earlier version of this test used `22 * 0.52 *
/// pointSize`; the constant had been fitted to one shipped number, which made
/// every margin it reported unfalsifiable.
@Test func exhaustedCellsFitTheStringTheyExistToShow() {
    // The widest strings the section renders: the longest provider display name
    // in the fixture set, and a full `friendlyResetDate` with month, day, and a
    // two-digit hour.
    let longestTitle = "Antigravity (Claude)"
    let longestReset = "resets Aug 12, 7:46 PM"

    for (density, titleStyle, resetStyle) in exhaustedTextStyles {
        let m = density.metrics
        // Every phone and iPad width, at every supported text size. The reset
        // demand is the runtime solver input; the title is verified too because
        // both labels may wrap at accessibility sizes.
        let surfaces: [(name: String, content: CGFloat, isGrid: Bool)] =
            phoneContentWidths.map { ($0.name, $0.content, false) }
            + deviceContentWidths.filter(\.isGrid).map { ($0.name, $0.width, true) }

        for dynamicTypeSize in densityPropertyDynamicTypeSizes {
            let titleFont = exhaustedFont(titleStyle, dynamicTypeSize: dynamicTypeSize)
            let resetFont = exhaustedFont(resetStyle, dynamicTypeSize: dynamicTypeSize)
            let resetDemand = typesetWidth(longestReset, resetFont)
            let needed = max(
                widestUnbreakableTokenWidth(in: longestTitle, font: titleFont),
                widestUnbreakableTokenWidth(in: longestReset, font: resetFont))

            for device in surfaces {
                let columns = maxColumns(
                    containerWidth: device.content,
                    scaledFixedColumnWidth: resetDemand,
                    cardPadding: m.cardPadding,
                    cardGap: m.exhaustedGap,
                    minimumBarWidth: 0)
                let cellWidth = cardWidth(
                    containerWidth: device.content, columns: columns, cardGap: m.exhaustedGap)
                let textWidth = cellWidth - m.cardPadding * 2
                #expect(
                    textWidth >= needed,
                    """
                    \(density.rawValue) on \(device.name) at \(dynamicTypeSize): the cell gives its text \
                    \(textWidth)pt and its widest unbreakable title/reset component needs \(needed)pt, so it \
                    truncates. The reset label remains the solver's fixed demand; a full label may wrap.
                    """
                )
            }
        }

        // This height check is intentionally pinned to `.large`: it verifies the
        // unscaled metric still binds, not what Dynamic Type does. Unlike the width
        // above, falling short here does not truncate: `minHeight` is a floor,
        // so a cell whose text is taller simply grows, as the XXXL baselines
        // show. What the assertion protects is that the metric still *binds* —
        // below this figure `exhaustedRowHeight` stops setting the row height
        // and the grid's cells size to their own content instead, which is a
        // dead number pretending to be a design choice.
        let titleFont = exhaustedFont(titleStyle)
        let resetFont = exhaustedFont(resetStyle)
        let twoLines =
            titleFont.lineHeight + resetFont.lineHeight + m.exhaustedLineGap + m.exhaustedGap * 2
        #expect(
            m.exhaustedRowHeight >= twoLines,
            """
            \(density.rawValue): exhaustedRowHeight is \(m.exhaustedRowHeight)pt against \
            \(twoLines)pt of content, so the minimum no longer decides the row.
            """
        )
    }
}

/// INV-12 restated against the density axis: density changes how much room a
/// provider's windows get, never how many of them are shown. A density that
/// dropped windows would be the 1.5.0 divergence again, this time shipped as a
/// setting rather than as a size-class accident.
@MainActor
@Test func everyDensityShowsEveryWindow() {
    let threeWindows = provider(
        "opencode",
        windows: [window("five_hour", 100), window("weekly", 61), window("monthly", 7)])
    for density in DashboardDensity.allCases {
        let card = ProviderDensityCard(
            provider: threeWindows, now: fixedNow, metrics: density.metrics)
        #expect(card.visibleWindows.count == 3, "\(density.rawValue) hid a window")
    }
}

/// Device-local, like the sort option and exhausted-visibility controls it sits
/// beside in Settings' "Local Display" section. `0` is Auto; positive values
/// are the slider's Small-to-Large stops, which the dashboard clamps against
/// the actual device geometry and Dynamic Type size.
@MainActor
@Test func densityPersistsPerDeviceAndDefaultsToCompact() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-density-pref-\(UUID().uuidString)", isDirectory: true)
    let suite = "gradus-density-pref-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!

    // Unset defaults to Auto. The selected count is resolved only from the
    // live container and Dynamic Type environment, not provider data.
    let viewModel = DashboardViewModel(
        cache: FileLocalCacheStore(directory: directory), userDefaults: defaults)
    #expect(viewModel.cardColumnPreference == 0)

    viewModel.cardColumnPreference = 3
    #expect(defaults.integer(forKey: DashboardViewModel.cardColumnPreferenceKey) == 3)

    // Survives a relaunch against the same defaults.
    let relaunched = DashboardViewModel(
        cache: FileLocalCacheStore(directory: directory), userDefaults: defaults)
    #expect(relaunched.cardColumnPreference == 3)

    // A stale invalid value falls back to Auto rather than producing an
    // impossible slider position.
    defaults.set(-1, forKey: DashboardViewModel.cardColumnPreferenceKey)
    let unknown = DashboardViewModel(
        cache: FileLocalCacheStore(directory: directory), userDefaults: defaults)
    #expect(unknown.cardColumnPreference == 0)
}

@MainActor
@Test func legacyColumnPreferenceMigratesAfterGeometryIsKnown() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-density-migration-\(UUID().uuidString)", isDirectory: true)
    let defaults = UserDefaults(suiteName: "gradus-density-migration-\(UUID().uuidString)")!

    // Build 12 stored a direct column count. Before geometry is available the
    // new model stays on Auto rather than briefly treating that number as a
    // size stop; the first dashboard geometry pass translates it exactly.
    defaults.set(3, forKey: DashboardViewModel.cardColumnPreferenceKey)
    let viewModel = DashboardViewModel(
        cache: FileLocalCacheStore(directory: directory), userDefaults: defaults)
    #expect(viewModel.cardColumnPreference == 0)

    viewModel.setAvailableCardColumns(5)
    #expect(viewModel.cardColumnPreference == 3, "three old columns should remain three columns")
    #expect(defaults.integer(forKey: DashboardViewModel.cardColumnPreferenceKey) == 3)

    let relaunched = DashboardViewModel(
        cache: FileLocalCacheStore(directory: directory), userDefaults: defaults)
    #expect(relaunched.cardColumnPreference == 3)
}

@MainActor
@Test func legacyColumnPreferenceDoesNotRemigrateAfterOneColumnGeometry() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-density-migration-one-column-\(UUID().uuidString)", isDirectory: true)
    let defaults = UserDefaults(suiteName: "gradus-density-migration-one-column-\(UUID().uuidString)")!
    defaults.set(3, forKey: DashboardViewModel.cardColumnPreferenceKey)

    let viewModel = DashboardViewModel(
        cache: FileLocalCacheStore(directory: directory), userDefaults: defaults)
    viewModel.setAvailableCardColumns(1)
    #expect(viewModel.cardColumnPreference == 0)
    #expect(defaults.integer(forKey: DashboardViewModel.cardColumnPreferenceKey) == 0)

    let relaunched = DashboardViewModel(
        cache: FileLocalCacheStore(directory: directory), userDefaults: defaults)
    relaunched.setAvailableCardColumns(4)
    #expect(relaunched.cardColumnPreference == 2, "three legacy columns should map to two stops from Small")
}

@Test func cardSizeStopsKeepAutoExplicitAndInvertLargeToSmall() {
    // Auto stays a distinct persisted value. Explicit positions run from
    // the smallest cards on the left to one large card on the right. A
    // one-column device has no manual positions because none can change its
    // layout.
    #expect(DashboardViewModel.cardSizeStopCount(for: 1) == 1)
    #expect(DashboardViewModel.resolvedCardDensity(preference: 0, sizeStops: 1) == nil)
    #expect(
        DashboardViewModel.resolvedCardColumnCount(
            preference: 0, maximum: 1, sizeStops: 1) == 1)

    #expect(
        DashboardViewModel.resolvedCardColumnCount(
            preference: 1, maximum: 4, sizeStops: 4) == 4)
    #expect(
        DashboardViewModel.resolvedCardColumnCount(
            preference: 4, maximum: 4, sizeStops: 4) == 1)
    #expect(
        DashboardViewModel.cardSizeLabel(preference: 0, maximumColumns: 1) == "Auto")
    #expect(
        DashboardViewModel.cardSizeLabel(preference: 1, maximumColumns: 4)
            .hasPrefix("Small · 4 columns"))
    #expect(
        DashboardViewModel.cardSizeLabel(preference: 3, maximumColumns: 1)
            == "Auto")
}

@MainActor
@Test func oneColumnGeometryForcesAutomaticCardSize() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-one-column-size-\(UUID().uuidString)", isDirectory: true)
    let defaults = UserDefaults(suiteName: "gradus-one-column-size-\(UUID().uuidString)")!
    let viewModel = DashboardViewModel(
        cache: FileLocalCacheStore(directory: directory), userDefaults: defaults)

    viewModel.setAvailableCardColumns(4)
    viewModel.cardColumnPreference = 4
    viewModel.setAvailableCardColumns(1)

    #expect(viewModel.cardColumnPreference == 0)
    #expect(defaults.integer(forKey: DashboardViewModel.cardColumnPreferenceKey) == 0)
    #expect(DashboardViewModel.cardSizeStopCount(for: viewModel.availableCardColumns) == 1)

    viewModel.setAvailableCardColumns(4)
    #expect(viewModel.cardColumnPreference == 4, "the iPad should restore its deferred Large stop")
}

@MainActor
@Test func automaticCardSizeDisablesManualSlider() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-card-size-binding-\(UUID().uuidString)", isDirectory: true)
    let suite = "gradus-card-size-binding-\(UUID().uuidString)"
    let viewModel = DashboardViewModel(
        cache: FileLocalCacheStore(directory: directory),
        userDefaults: UserDefaults(suiteName: suite)!)
    viewModel.setAvailableCardColumns(4)
    let settings = SettingsView(dashboardViewModel: viewModel)

    #expect(settings.cardSizeSliderEnabled == false)
    settings.automaticCardSizeBinding.wrappedValue = false
    #expect(viewModel.cardColumnPreference == 1)
    #expect(settings.cardSizeSliderEnabled)

    settings.automaticCardSizeBinding.wrappedValue = true
    #expect(viewModel.cardColumnPreference == 0)
    #expect(settings.cardSizeSliderEnabled == false)

    viewModel.setAvailableCardColumns(1)
    #expect(viewModel.cardColumnPreference == 0)
    #expect(settings.cardSizeSliderEnabled == false)
}

@MainActor
@Test func cardSizeAccessibilityMovesOneWholeStopAtATime() {
    let slider = QuietDiscreteUISlider()
    slider.minimumValue = 1
    slider.maximumValue = 3
    slider.value = 1

    slider.accessibilityIncrement()
    #expect(slider.value == 2)
    slider.accessibilityIncrement()
    #expect(slider.value == 3)
    slider.accessibilityIncrement()
    #expect(slider.value == 3)

    slider.accessibilityDecrement()
    #expect(slider.value == 2)
    slider.accessibilityDecrement()
    #expect(slider.value == 1)
    slider.accessibilityDecrement()
    #expect(slider.value == 1)

    slider.isEnabled = false
    slider.accessibilityIncrement()
    slider.accessibilityDecrement()
    #expect(slider.value == 1)
}

/// Asking for compact explicitly remains a stable snapshot fixture while the
/// production path resolves its rung from slider-selected card width.
///
/// This is the property a duplicate `.compact` snapshot baseline appeared to
/// cover and did not: two baselines rendered from the same metrics move
/// together under any edit, so neither can catch the other drifting. What can
/// actually break here is the *override plumbing* — a `densityOverride` that
/// was ignored, or a default that stopped being compact — and that is a
/// comparison of resolved values, not of pixels.
@MainActor
@Test func explicitCompactResolvesTheSameAsTheDefault() {
    let viewModel = makeDensityViewModel(providers: [provider("codex", windows: [window("weekly", 50)])])
    #expect(viewModel.cardColumnPreference == 0)

    let explicit = DashboardContent(
        viewModel: viewModel, now: fixedNow, layout: .denseGrid, density: .compact)
    let byPreference = DashboardContent(viewModel: viewModel, now: fixedNow, layout: .denseGrid)
    #expect(explicit.metrics == byPreference.metrics)

    // The override must actually override, or the two fixtures above would
    // agree for the wrong reason.
    let overridden = DashboardContent(
        viewModel: viewModel, now: fixedNow, layout: .denseGrid, density: .large)
    #expect(overridden.metrics != byPreference.metrics)

    let standard = DashboardDensity.resolveRung { $0 == .standard }
    #expect(standard.rung == .standard && standard.didFit)
    let fallback = DashboardDensity.resolveRung { _ in false }
    #expect(fallback.rung == .compact && !fallback.didFit)
}

/// The two axes must stay independent: density is the user's choice, the reset
/// column is a width consequence. Crossing them is how "large on iPhone"
/// would end up with a reset column it has no room for.
@MainActor
@Test func densityDoesNotDecideTheResetColumn() {
    let viewModel = makeDensityViewModel(providers: [provider("codex", windows: [window("weekly", 50)])])
    for density in DashboardDensity.allCases {
        let metrics = density.metrics
        let gridColumns = maxColumns(
            containerWidth: 802,
            scaledFixedColumnWidth: 0,
            cardPadding: 0,
            cardGap: metrics.cardGap,
            minimumBarWidth: metrics.gridMinimum)
        #expect(
            !DashboardContent(
                viewModel: viewModel, now: fixedNow, layout: .denseSingleColumn, density: density
            ).runtimeShowsReset(
                inContentWidth: 361,
                columns: 1,
                scaledFixedColumnWidth: metrics.fixedColumnWidth(showsReset: true)))
        #expect(
            DashboardContent(
                viewModel: viewModel, now: fixedNow, layout: .denseGrid, density: density
            ).runtimeShowsReset(
                inContentWidth: 802,
                columns: gridColumns,
                scaledFixedColumnWidth: metrics.fixedColumnWidth(showsReset: true)))
    }
}

@Test func windowRowSpeaksAsOneElement() {
    // Bar + percentage + reset are three views but one fact; VoiceOver should
    // stop once, not three times.
    let row = WindowRow(window: window("weekly", 47, pace: -0.08), now: fixedNow)
    // Composed from the shared reset formatter rather than a second one, so
    // the row and Provider Detail cannot word the same reset differently.
    let expectedReset = friendlyResetDate("2026-07-26T09:00:00-04:00", now: fixedNow)
    #expect(expectedReset != nil)
    #expect(row.resetText == expectedReset)
    #expect(row.spokenLabel == "Weekly, 47 percent remaining, resets \(expectedReset!)")

    let noReset = WindowRow(window: window("weekly", 47, reset: nil), now: fixedNow)
    #expect(noReset.spokenLabel == "Weekly, 47 percent remaining")
}
