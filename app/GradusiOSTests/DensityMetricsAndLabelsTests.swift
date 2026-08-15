@testable import GradusiOS
import GradusKit
import SwiftUI
import Testing
import UIKit

// Density metric constants, label contrast/identifiability, and
// `WindowRow` scaling coverage split out of `DensityLayoutTests`.

private let fixedNow = Date(timeIntervalSince1970: 1_785_000_000)

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
        recessed.dark.contrastRatio(with: ProviderDensityCardSurfaceToken.dark)
    )
    #expect(
        recessedNormalRatio < 4.5,
        "the old secondary token unexpectedly clears normal-label AA; keep the mutation fixture honest"
    )
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
        ("ap", "API")
    ]

    for dynamicTypeSize in [DynamicTypeSize.large, .xxxLarge] {
        for (id, label) in expected {
            let row = WindowRow(
                window: window(id, 47), now: fixedNow, showsReset: false, metrics: .standard
            )
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            let renderedWidth = UIHostingController(
                rootView: row.fixedSize(horizontal: true, vertical: false)
            ).sizeThatFits(in: CGSize(width: 2000, height: 200)).width

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
        window: window("weekly", 47), now: fixedNow, showsReset: true, metrics: .compact
    )
    let defaultSize = UIHostingController(rootView: row.fixedSize(horizontal: true, vertical: false))
        .sizeThatFits(in: CGSize(width: 2000, height: 200))
    let xxxLargeSize = UIHostingController(
        rootView: row.environment(\.dynamicTypeSize, .xxxLarge)
            .fixedSize(horizontal: true, vertical: false)
    ).sizeThatFits(in: CGSize(width: 2000, height: 200))
    // Apple's literal `.xxxLarge` category scales this row by about 1.48x;
    // the plan's documented ~1.9x checkpoint is reached at the next
    // accessibility rung. The row itself reflows at AX1+, so compare the
    // fixed-column demand directly rather than comparing two different row
    // structures' intrinsic widths.
    #expect(xxxLargeSize.width > defaultSize.width)
    let defaultColumns = scaledProductionColumnWidths(
        density: .compact, dynamicTypeSize: .large
    )
    let xxxLargeColumns = scaledProductionColumnWidths(
        density: .compact, dynamicTypeSize: .xxxLarge
    )
    let accessibility2Columns = scaledProductionColumnWidths(
        density: .compact, dynamicTypeSize: .accessibility2
    )
    for (defaultValue, xxxLargeValue) in zip(
        [defaultColumns.label, defaultColumns.percent, defaultColumns.reset],
        [xxxLargeColumns.label, xxxLargeColumns.percent, xxxLargeColumns.reset]
    ) {
        #expect(xxxLargeValue > defaultValue)
    }
    for (xxxLargeValue, accessibility2Value) in zip(
        [xxxLargeColumns.label, xxxLargeColumns.percent, xxxLargeColumns.reset],
        [accessibility2Columns.label, accessibility2Columns.percent, accessibility2Columns.reset]
    ) {
        #expect(accessibility2Value > xxxLargeValue)
    }
    let ratio = accessibility2Columns.total(showsReset: true, columnGap: DensityMetrics.compact.columnGap)
        / defaultColumns.total(showsReset: true, columnGap: DensityMetrics.compact.columnGap)
    #expect(ratio > 1.75 && ratio < 2.05, "expected roughly 1.9x fixed-column width, got \(ratio)x")
}

@MainActor
@Test func windowRowUsesScaledContentHeightAsTheRowFloorAtExtraExtraExtraLarge() {
    let row = WindowRow(
        window: window("weekly", 47), now: fixedNow, showsReset: true, metrics: .compact
    )
    let rendered = UIHostingController(
        rootView: row.environment(\.dynamicTypeSize, .xxxLarge)
    ).sizeThatFits(in: CGSize(width: 2000, height: 200))
    let trait = UITraitCollection(preferredContentSizeCategory: .extraExtraExtraLarge)
    let scaledContentHeight = UIFont.preferredFont(
        forTextStyle: .caption1, compatibleWith: trait
    ).lineHeight

    #expect(rendered.height >= scaledContentHeight)
    #expect(rendered.height >= DensityMetrics.compact.rowHeight)
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
