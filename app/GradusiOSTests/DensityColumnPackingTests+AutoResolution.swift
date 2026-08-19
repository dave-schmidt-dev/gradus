@testable import GradusiOS
import GradusKit
import SwiftUI
import Testing
import UIKit

// Auto-density rung-resolution coverage split out of `DensityColumnPackingTests`
// (file/type length gate): whether Auto picks the richest rung a width can
// support, rather than fixing the column count at `.compact`'s maximum first.

/// Auto used to fix the column count at `.compact`'s maximum first, which
/// starves every richer rung of the width it needs and almost always falls
/// through to `.compact` -- even on a width with room for `.standard` or
/// `.large` at fewer columns. This is the reported bug: on an iPad landscape
/// width, Auto left roughly half the screen unused because it maximized
/// columns of the shortest-row rung instead of picking a richer rung.
@Test func autoPicksTheRichestRungRatherThanCrammingCompactColumns() throws {
    let device = deviceContentWidths[2] // iPad 11" landscape
    let dynamicTypeSize = DynamicTypeSize.large

    let candidates = DashboardDensity.allCases.reversed().map { rung -> RungCandidate<DashboardDensity> in
        let scaled = scaledProductionColumnWidths(density: rung, dynamicTypeSize: dynamicTypeSize)
        return RungCandidate(
            rung: rung,
            scaledFixedColumnWidth: scaled.total(showsReset: false, columnGap: rung.metrics.columnGap),
            cardPadding: rung.metrics.cardPadding,
            cardGap: rung.metrics.cardGap
        )
    }

    let resolution = try #require(
        richestFittingResolution(
            containerWidth: device.width,
            candidates: candidates,
            minimumBarWidth: DensityMetrics.minimumBarWidth
        )
    )
    #expect(resolution.rung != .compact, "a richer rung fits this width; Auto must not default to compact")

    let compactCandidate = try #require(candidates.first { $0.rung == .compact })
    let compactMaximum = try #require(
        feasibleColumnStops(
            containerWidth: device.width,
            scaledFixedColumnWidth: compactCandidate.scaledFixedColumnWidth,
            cardPadding: compactCandidate.cardPadding,
            cardGap: compactCandidate.cardGap,
            minimumBarWidth: DensityMetrics.minimumBarWidth
        ).last
    )
    #expect(
        !(resolution.rung == .compact && resolution.columns == compactMaximum),
        "Auto regressed to the old fixed-at-compact-maximum behavior"
    )
}

/// `richestFittingResolution` falls through to a leaner candidate only when
/// the richer one cannot seat even one column at the bar floor, and always
/// returns that candidate's own maximum -- never the count computed for a
/// different candidate in the list.
@Test func richestFittingResolutionPicksEachCandidatesOwnMaximum() throws {
    let large = DashboardDensity.large.metrics
    let compact = DashboardDensity.compact.metrics
    let largeCandidate = RungCandidate(
        rung: DashboardDensity.large,
        scaledFixedColumnWidth: large.fixedColumnWidth(showsReset: false),
        cardPadding: large.cardPadding,
        cardGap: large.cardGap
    )
    let compactCandidate = RungCandidate(
        rung: DashboardDensity.compact,
        scaledFixedColumnWidth: compact.fixedColumnWidth(showsReset: false),
        cardPadding: compact.cardPadding,
        cardGap: compact.cardGap
    )

    // Wide enough for `.large` to seat more than one column: the algorithm
    // must report `.large` at *its own* maximum, not fall through to
    // `.compact`'s far higher column count at this same width.
    let expectedLargeColumns = try #require(
        feasibleColumnStops(
            containerWidth: 900,
            scaledFixedColumnWidth: largeCandidate.scaledFixedColumnWidth,
            cardPadding: largeCandidate.cardPadding,
            cardGap: largeCandidate.cardGap,
            minimumBarWidth: DensityMetrics.minimumBarWidth
        ).last
    )
    #expect(expectedLargeColumns > 1, "the fixture should exercise more than one large column")
    let resolved = richestFittingResolution(
        containerWidth: 900,
        candidates: [largeCandidate, compactCandidate],
        minimumBarWidth: DensityMetrics.minimumBarWidth
    )
    #expect(resolved?.rung == .large)
    #expect(resolved?.columns == expectedLargeColumns)

    // Too narrow for even one `.large` column, but still room for `.compact`:
    // falls through to `.compact`.
    let tooNarrowForLarge = richestFittingResolution(
        containerWidth: 250,
        candidates: [largeCandidate, compactCandidate],
        minimumBarWidth: DensityMetrics.minimumBarWidth
    )
    #expect(tooNarrowForLarge?.rung == .compact)

    // No candidate fits at all.
    let none = richestFittingResolution(
        containerWidth: 10,
        candidates: [compactCandidate],
        minimumBarWidth: DensityMetrics.minimumBarWidth
    )
    #expect(none == nil)
}
