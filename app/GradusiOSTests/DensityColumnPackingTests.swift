@testable import GradusiOS
import GradusKit
import SwiftUI
import Testing
import UIKit

// Column-packing solver coverage split out of `DensityLayoutTests`
// (TASKS row 24): the arithmetic that decides how many columns fit and
// whether the usage bar keeps room to read.

private let fixedNow = Date(timeIntervalSince1970: 1_785_000_000)

private let densityPropertyProviderCounts = [1, 2, 4, 8]

private func usesTwoLineRow(at dynamicTypeSize: DynamicTypeSize) -> Bool {
    switch dynamicTypeSize {
    case .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5:
        true
    default:
        false
    }
}

private func rowTextStyle(for density: DashboardDensity) -> UIFont.TextStyle {
    switch density {
    case .compact: .caption1
    case .standard: .footnote
    case .large: .subheadline
    }
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

    struct MeasuredColumnWidth {
        let columns: Int
        let gap: CGFloat
        let rendered: CGFloat
        let source: String
    }

    let measured: [MeasuredColumnWidth] = [
        MeasuredColumnWidth(
            columns: 2, gap: standard.cardGap, rendered: 394,
            source: "densityStandardPadPortraitLight, provider card at y=310pt spans 16.0->410.0"
        ),
        MeasuredColumnWidth(
            columns: 1, gap: large.cardGap, rendered: 802,
            source: "densityLargePadPortraitLight, provider card at y=146pt spans 16.0->818.0"
        ),
        MeasuredColumnWidth(
            columns: 3, gap: standard.exhaustedGap, rendered: 260.67,
            source: "densityStandardPadPortraitLight, exhausted cell at y=536pt spans 16.0->276.7"
        ),
        MeasuredColumnWidth(
            columns: 2, gap: large.exhaustedGap, rendered: 395,
            source: "densityLargePadPortraitLight, exhausted cell at y=1074pt spans 16.0->411.0"
        )
    ]

    for item in measured {
        let predicted = cardWidth(
            containerWidth: iPadPortraitContent, columns: item.columns, cardGap: item.gap
        )
        #expect(
            abs(predicted - item.rendered) < 0.5,
            """
            The packing model this file is built on no longer matches SwiftUI: \
            columns \(item.columns) with gap \(item.gap) predicts \(predicted)pt, but the \
            baseline shows \(item.rendered)pt (\(item.source)). Re-measure before changing \
            the expected value — the baseline is the authority here, not the formula.
            """
        )
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
/// Renders the fixed-column row at an accessibility Dynamic Type size and
/// checks it grew tall enough for the two-line reflow Phase 2 owns.
@MainActor
private func assertTwoLineRowMeetsFloor(
    device: DeviceContentWidth,
    dynamicTypeSize: DynamicTypeSize,
    density: DashboardDensity,
    metrics: DensityMetrics
) {
    let traits = UITraitCollection(
        preferredContentSizeCategory: uiContentSizeCategory(for: dynamicTypeSize)
    )
    let textLineHeight = UIFont.preferredFont(
        forTextStyle: rowTextStyle(for: density), compatibleWith: traits
    ).lineHeight
    let rowWidth = max(1, device.width - metrics.cardPadding * 2)
    let renderedHeight = UIHostingController(
        rootView: WindowRow(
            window: window("weekly", 50),
            now: fixedNow,
            showsReset: true,
            metrics: metrics
        )
        .environment(\.dynamicTypeSize, dynamicTypeSize)
    ).sizeThatFits(in: CGSize(width: rowWidth, height: 2000)).height
    let minimumTwoLineHeight = textLineHeight
        + metrics.rowGap + metrics.barHeight
    #expect(
        renderedHeight >= minimumTwoLineHeight - 0.5,
        """
        (density.rawValue) on (device.name) at (dynamicTypeSize) rendered \
        (renderedHeight)pt, below the (minimumTwoLineHeight)pt two-line floor
        """
    )
}

private struct ColumnDemandResolution {
    let columns: Int
    let resolvedWidth: CGFloat
    let scaledColumns: ScaledFixedColumnWidths
}

/// The solver's column count and resulting card width for one device/type-size/
/// density combination, split out so neither this nor its caller re-grows past
/// the function-length floor.
private func resolvedColumnDemand(
    device: DeviceContentWidth,
    dynamicTypeSize: DynamicTypeSize,
    density: DashboardDensity
) -> ColumnDemandResolution {
    let metrics = density.metrics
    let scaledColumns = scaledProductionColumnWidths(
        density: density, dynamicTypeSize: dynamicTypeSize
    )
    let fixedDemand: CGFloat = if scaledColumns.total(showsReset: true, columnGap: metrics.columnGap)
        > metrics.fixedColumnWidth(showsReset: true) {
        scaledColumns.total(
            showsReset: false, columnGap: metrics.columnGap
        )
    } else {
        max(
            0,
            historicalDefaultCardMinimum(for: density)
                - metrics.cardPadding * 2
                - DensityMetrics.minimumBarWidth
        )
    }
    let columns = device.isGrid
        ? maxColumns(
            containerWidth: device.width,
            scaledFixedColumnWidth: fixedDemand,
            cardPadding: metrics.cardPadding,
            cardGap: metrics.cardGap,
            minimumBarWidth: DensityMetrics.minimumBarWidth
        )
        : 1
    let resolvedWidth = cardWidth(
        containerWidth: device.width,
        columns: columns,
        cardGap: metrics.cardGap
    )
    return ColumnDemandResolution(columns: columns, resolvedWidth: resolvedWidth, scaledColumns: scaledColumns)
}

private struct ResetColumnResolution {
    let resolvedWidth: CGFloat
    let showsReset: Bool
    let scaledResetDemand: CGFloat
    let scaledColumns: ScaledFixedColumnWidths
}

/// Resolves the solver's reset-column decision for one device/type-size/
/// density combination, and asserts the runtime answer matches what the
/// solver predicts.
@MainActor
private func assertShowsResetMatchesSolver(
    device: DeviceContentWidth,
    dynamicTypeSize: DynamicTypeSize,
    providerCount: Int,
    density: DashboardDensity,
    viewModel: DashboardViewModel
) -> ResetColumnResolution {
    let metrics = density.metrics
    let demand = resolvedColumnDemand(device: device, dynamicTypeSize: dynamicTypeSize, density: density)
    let scaledResetDemand = demand.scaledColumns.total(
        showsReset: true, columnGap: metrics.columnGap
    )
    let dashboard = DashboardContent(
        viewModel: viewModel,
        now: fixedNow,
        layout: device.isGrid ? .denseGrid : .denseSingleColumn,
        density: density
    )
    let showsReset = dashboard.runtimeShowsReset(
        inContentWidth: device.width,
        columns: demand.columns,
        scaledFixedColumnWidth: scaledResetDemand
    )
    let expectedShowsReset = device.isGrid
        && metrics.fitsResetColumn(
            inCardWidth: demand.resolvedWidth,
            scaledFixedColumnWidth: scaledResetDemand
        )
    #expect(
        showsReset == expectedShowsReset,
        """
        \(density.rawValue) on \(device.name) at \(dynamicTypeSize) with \
        \(providerCount) providers resolved reset=\(showsReset), expected \
        \(expectedShowsReset).
        """
    )
    return ResetColumnResolution(
        resolvedWidth: demand.resolvedWidth,
        showsReset: showsReset,
        scaledResetDemand: scaledResetDemand,
        scaledColumns: demand.scaledColumns
    )
}

/// One (device, Dynamic Type size, provider count, density) case: resolves
/// the solver's answer and checks the bar it leaves behind still clears the
/// readability floor.
@MainActor
private func assertBarClearsFloor(
    device: DeviceContentWidth,
    dynamicTypeSize: DynamicTypeSize,
    providerCount: Int,
    density: DashboardDensity,
    viewModel: DashboardViewModel
) {
    let metrics = density.metrics

    if providerCount == densityPropertyProviderCounts.first, usesTwoLineRow(at: dynamicTypeSize) {
        assertTwoLineRowMeetsFloor(
            device: device, dynamicTypeSize: dynamicTypeSize, density: density, metrics: metrics
        )
    }

    let resolution = assertShowsResetMatchesSolver(
        device: device, dynamicTypeSize: dynamicTypeSize, providerCount: providerCount,
        density: density, viewModel: viewModel
    )

    // Phase 2 owns the visual two-line reflow at AX1+. Keep
    // this Phase 1 arithmetic aligned with that contract: the
    // bar gets the full card content width on its own line,
    // while smaller text sizes pay the fixed-column demand.
    let barWidth: CGFloat = if usesTwoLineRow(at: dynamicTypeSize) {
        resolution.resolvedWidth - metrics.cardPadding * 2
    } else {
        resolution.resolvedWidth - metrics.cardPadding * 2
            - (resolution.showsReset ? resolution.scaledResetDemand : resolution.scaledColumns.total(
                showsReset: false, columnGap: metrics.columnGap
            ))
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

/// Pins the historical compact/tight-case bar width once, outside the sweep
/// above, against the pre-scaled-type packing it must still reproduce.
private func assertHistoricalTightCaseKeepsFourColumns() {
    let historical = scaledProductionColumnWidths(
        density: compactHistoricalTightCase.density,
        dynamicTypeSize: compactHistoricalTightCase.dynamicTypeSize
    )
    let historicalColumns = maxColumns(
        containerWidth: compactHistoricalTightCase.contentWidth,
        scaledFixedColumnWidth: historicalDefaultCardMinimum(
            for: compactHistoricalTightCase.density
        )
            - compactHistoricalTightCase.density.metrics.cardPadding * 2
            - DensityMetrics.minimumBarWidth,
        cardPadding: compactHistoricalTightCase.density.metrics.cardPadding,
        cardGap: compactHistoricalTightCase.density.metrics.cardGap,
        minimumBarWidth: DensityMetrics.minimumBarWidth
    )
    let historicalCardWidth = cardWidth(
        containerWidth: compactHistoricalTightCase.contentWidth,
        columns: historicalColumns,
        cardGap: compactHistoricalTightCase.density.metrics.cardGap
    )
    let historicalBarWidth = historicalCardWidth
        - compactHistoricalTightCase.density.metrics.cardPadding * 2
        - historical.total(
            showsReset: true,
            columnGap: compactHistoricalTightCase.density.metrics.columnGap
        )
    #expect(historicalColumns == 4)
    #expect(historicalBarWidth == compactHistoricalTightCase.expectedBarWidth)
}

@MainActor
@Test func everyDensityLeavesTheBarRoomToRead() {
    for device in deviceContentWidths {
        for dynamicTypeSize in densityPropertyDynamicTypeSizes {
            for providerCount in densityPropertyProviderCounts {
                let providers = (0 ..< providerCount).map { index in
                    provider(
                        "provider-\(index)",
                        windows: [window("weekly", 50)]
                    )
                }
                let viewModel = makeDensityViewModel(providers: providers)

                for density in DashboardDensity.allCases {
                    assertBarClearsFloor(
                        device: device,
                        dynamicTypeSize: dynamicTypeSize,
                        providerCount: providerCount,
                        density: density,
                        viewModel: viewModel
                    )
                }
            }
        }
    }

    assertHistoricalTightCaseKeepsFourColumns()
}
