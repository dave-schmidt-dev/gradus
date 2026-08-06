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
/// Guards the parity rule in `INVARIANTS.md` at the one place the two
/// presentations are allowed to diverge: iPhone drops each row's reset time to
/// keep the bar legible, and takes one column instead of an adaptive count.
@MainActor
@Test func bothLayoutsShowEveryWindowAndDifferOnlyInDensityDetail() {
    #expect(DashboardLayout.denseGrid.showsReset)
    #expect(!DashboardLayout.denseSingleColumn.showsReset)

    // Same provider, same card type, same window count on both — the card has
    // no per-layout filtering, so parity is structural rather than asserted.
    let threeWindows = provider(
        "opencode",
        windows: [window("five_hour", 100), window("weekly", 61), window("monthly", 7)])
    for showsReset in [true, false] {
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

// MARK: - density (TASKS row 24)

/// Resolves `GridItem(.adaptive(minimum:))` the way SwiftUI does, so the test
/// asks about the width a card is *actually* given rather than the minimum it
/// was allowed. The two differ by a lot: at `.compact` a 13" iPad's 1334pt of
/// content seats four 324.5pt columns, not four 320pt ones.
private func resolvedCardWidth(
    contentWidth: CGFloat, minimum: CGFloat, spacing: CGFloat
) -> CGFloat {
    let columns = max(1, floor((contentWidth + spacing) / (minimum + spacing)))
    return (contentWidth - spacing * (columns - 1)) / columns
}

/// Content width for each destination the gate runs, minus `denseGrid`'s 16pt
/// horizontal padding on each side.
private let deviceContentWidths: [(name: String, width: CGFloat, isGrid: Bool)] = [
    ("iPhone portrait", 361, false),
    ("iPad 11\" portrait", 802, true),
    ("iPad 11\" landscape", 1162, true),
    ("iPad 13\" landscape", 1334, true),
]

/// Pins `resolvedCardWidth` to what SwiftUI renders, rather than to itself.
///
/// The helper above is a *reconstruction* of `.adaptive(minimum:)`'s packing
/// rule, and every other width assertion in this file is built on it. A wrong
/// reconstruction would therefore let the whole file pass while describing a
/// layout the app does not produce — the same failure mode as a constant fitted
/// to the number it is later used to justify.
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
    let iPadPortraitContent: CGFloat = 802
    let standard = DashboardDensity.standard.metrics
    let large = DashboardDensity.large.metrics

    let measured: [(minimum: CGFloat, gap: CGFloat, rendered: CGFloat, source: String)] = [
        (standard.gridMinimum, standard.cardGap, 394,
         "densityStandardPadPortraitLight, provider card at y=310pt spans 16.0->410.0"),
        (large.gridMinimum, large.cardGap, 802,
         "densityLargePadPortraitLight, provider card at y=146pt spans 16.0->818.0"),
        (standard.exhaustedMinimumGrid, standard.exhaustedGap, 260.67,
         "densityStandardPadPortraitLight, exhausted cell at y=536pt spans 16.0->276.7"),
        (large.exhaustedMinimumGrid, large.exhaustedGap, 395,
         "densityLargePadPortraitLight, exhausted cell at y=1074pt spans 16.0->411.0"),
    ]

    for (minimum, gap, rendered, source) in measured {
        let predicted = resolvedCardWidth(
            contentWidth: iPadPortraitContent, minimum: minimum, spacing: gap)
        #expect(
            abs(predicted - rendered) < 0.5,
            """
            The packing model this file is built on no longer matches SwiftUI: \
            minimum \(minimum) with gap \(gap) predicts \(predicted)pt, but the \
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
@Test func everyDensityLeavesTheBarRoomToRead() {
    for density in DashboardDensity.allCases {
        let metrics = density.metrics
        for device in deviceContentWidths {
            // Matches `DashboardContent.columns`: compact width is one
            // `.flexible()` column and drops the reset time; regular width is
            // the adaptive grid and keeps it.
            let cardWidth = device.isGrid
                ? resolvedCardWidth(
                    contentWidth: device.width,
                    minimum: metrics.gridMinimum,
                    spacing: metrics.cardGap)
                : device.width
            let barWidth = cardWidth - metrics.cardPadding * 2
                - metrics.fixedColumnWidth(showsReset: device.isGrid)

            #expect(
                barWidth >= DensityMetrics.minimumBarWidth,
                """
                \(density.rawValue) on \(device.name): the bar gets \(barWidth)pt, \
                under the \(DensityMetrics.minimumBarWidth)pt floor. Either the \
                fixed columns grew or gridMinimum did not grow with them.
                """
            )
        }
    }
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

    // The exhausted section's literals, taken from `DashboardView` before that
    // section joined the metrics. These are pinned here because they are the
    // part of compact with no pixel coverage on a phone: the section sits below
    // the fold of every phone baseline, so a regression to these six numbers
    // would show up in no snapshot on the device where they matter most.
    #expect(compact.exhaustedLineGap == 2)
    #expect(compact.exhaustedGap == 8)
    #expect(compact.exhaustedRowHeight == 52)
    #expect(compact.exhaustedCornerRadius == 10)
    #expect(compact.exhaustedMinimumSingleColumn == 170)
    #expect(compact.exhaustedMinimumGrid == 240)
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
        #expect(bigger.exhaustedMinimumSingleColumn > smaller.exhaustedMinimumSingleColumn)
        #expect(bigger.exhaustedMinimumGrid > smaller.exhaustedMinimumGrid)
    }
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
/// The column count is asserted at every phone width rather than at one,
/// because the interesting property is not "how many columns" but "where the
/// count flips" — and `.adaptive` flips it at
/// `content = 2 * (minimum + gap) - gap`. Measured boundaries, in device points:
/// compact flips at 380, standard at 412, large at 474. So compact is two-up on
/// everything but the SE, standard is two-up only on Plus and Pro Max, and large
/// is one column on every iPhone.
///
/// Standard's boundary is the one that was chosen rather than derived, and the
/// first version of this test justified it wrongly — it claimed the reset string
/// forced one column. It does not: at a half-width 393pt phone the cell gives
/// its text 147.5pt and the longest line measures 144.5pt, so two columns would
/// fit. The real constraint is boundary placement. Any minimum small enough to
/// give a 393pt iPhone two columns lands the flip at a 392pt device — between
/// iPhone 15 (390) and iPhone 16 (393), so two phones a user would call the same
/// size would disagree. 185 puts it at 412, in open space between the Pro (402)
/// and the Plus (430).
///
/// Compact's own boundary sits only 5pt above the SE. Note the direction: the SE
/// is the one phone compact leaves at a single column, so a device 5pt wider
/// flips *into* two and gets narrower cells. That is the direction that could
/// truncate, which is why `exhaustedCellsFitTheStringTheyExistToShow` checks the
/// two-column compact cell on every phone above the boundary — and no shipping
/// iPhone falls in the 375–390pt gap in any case. Compact is frozen 1.6.0
/// geometry regardless: recorded here, not chosen.
@Test func theExhaustedGridPacksAsIntendedOnEveryPhone() {
    let expected: [DashboardDensity: [CGFloat]] = [
        //         SE  15  16  Pro  Plus  Max
        .compact: [1, 2, 2, 2, 2, 2],
        .standard: [1, 1, 1, 1, 2, 2],
        .large: [1, 1, 1, 1, 1, 1],
    ]

    for density in DashboardDensity.allCases {
        let m = density.metrics
        for (index, phone) in phoneContentWidths.enumerated() {
            let packed = max(
                1,
                floor(
                    (phone.content + m.exhaustedGap)
                        / (m.exhaustedMinimumSingleColumn + m.exhaustedGap)))
            #expect(
                packed == expected[density]![index],
                """
                \(density.rawValue) packs \(packed) exhausted columns on \
                \(phone.name), expected \(expected[density]![index]). A changed \
                minimum moved the 1→2 boundary across a shipping device.
                """
            )
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

/// Pinned to the default content size category. The question here is whether
/// the geometry fits its own text, and the answer must not move because the
/// simulator's text-size slider did. What Dynamic Type does to these cells is a
/// separate, worse question, recorded in the `…ExtraExtraExtraLarge` baselines.
private func exhaustedFont(_ style: UIFont.TextStyle) -> UIFont {
    UIFont.preferredFont(
        forTextStyle: style,
        compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
}

private func typesetWidth(_ string: String, _ font: UIFont) -> CGFloat {
    (string as NSString).size(withAttributes: [.font: font]).width
}

/// The exhausted cell's job is to name a spent provider and say when it comes
/// back. Both lines are `lineLimit(1)`, so a cell too narrow for them does not
/// wrap or grow — it truncates, and "resets Aug 12, 7:4…" is worse than no
/// reset time at all because it still reads as an answer.
///
/// Asserted against the width the cell is actually *given* at each shipping
/// device width, not against `exhaustedMinimum*`. The minimum is a packing
/// input; `.adaptive` then divides the leftover space among the columns it
/// seated, so the real cell is always wider than the minimum and sometimes much
/// wider. Checking the minimum would be the conservative proxy — and at compact
/// it is the wrong question, since that number is frozen 1.6.0 geometry.
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
        let titleFont = exhaustedFont(titleStyle)
        let resetFont = exhaustedFont(resetStyle)
        let needed = max(
            typesetWidth(longestTitle, titleFont), typesetWidth(longestReset, resetFont))

        // Every phone under the single-column layout's minimum, then every iPad
        // width under the grid's. Both lists in full rather than one width each:
        // the tightest cell is not the one on the narrowest screen. A 390pt
        // iPhone seats two compact columns out of less width than a 393pt one
        // does, so its cell is the smaller of the two, and the SE — narrower
        // than both — drops to one column and gets the widest cell on any phone.
        let surfaces: [(name: String, content: CGFloat, isGrid: Bool)] =
            phoneContentWidths.map { ($0.name, $0.content, false) }
            + deviceContentWidths.filter(\.isGrid).map { ($0.name, $0.width, true) }

        for device in surfaces {
            let minimum = device.isGrid ? m.exhaustedMinimumGrid : m.exhaustedMinimumSingleColumn
            let cellWidth = resolvedCardWidth(
                contentWidth: device.content, minimum: minimum, spacing: m.exhaustedGap)
            let textWidth = cellWidth - m.cardPadding * 2
            #expect(
                textWidth >= needed,
                """
                \(density.rawValue) on \(device.name): the cell gives its text \
                \(textWidth)pt and the longest line needs \(needed)pt, so it \
                truncates. Raise the matching exhausted minimum.
                """
            )
        }

        // A cell is two typeset lines plus its vertical insets. Unlike the width
        // above, falling short here does not truncate: `minHeight` is a floor,
        // so a cell whose text is taller simply grows, as the XXXL baselines
        // show. What the assertion protects is that the metric still *binds* —
        // below this figure `exhaustedRowHeight` stops setting the row height
        // and the grid's cells size to their own content instead, which is a
        // dead number pretending to be a design choice.
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
/// beside in Settings' "Local Display" section. Density is a function of this
/// screen's size and viewing distance, so a phone on compact and an iPad on
/// large is the expected configuration, not a conflict to sync away.
@MainActor
@Test func densityPersistsPerDeviceAndDefaultsToCompact() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-density-pref-\(UUID().uuidString)", isDirectory: true)
    let suite = "gradus-density-pref-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!

    // Unset defaults to compact: an upgrading device sees 1.6.0's geometry
    // until it opts into something else.
    let viewModel = DashboardViewModel(
        cache: FileLocalCacheStore(directory: directory), userDefaults: defaults)
    #expect(viewModel.density == .compact)

    viewModel.density = .large
    #expect(defaults.string(forKey: DashboardViewModel.densityKey) == "large")

    // Survives a relaunch against the same defaults.
    let relaunched = DashboardViewModel(
        cache: FileLocalCacheStore(directory: directory), userDefaults: defaults)
    #expect(relaunched.density == .large)

    // A stored value the enum no longer knows falls back rather than trapping.
    defaults.set("gigantic", forKey: DashboardViewModel.densityKey)
    let unknown = DashboardViewModel(
        cache: FileLocalCacheStore(directory: directory), userDefaults: defaults)
    #expect(unknown.density == .compact)
}

/// Asking for compact explicitly must resolve to the same metrics as not
/// asking at all, since the stored preference defaults to compact.
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
    #expect(viewModel.density == .compact)

    let explicit = DashboardContent(
        viewModel: viewModel, now: fixedNow, layout: .denseGrid, density: .compact)
    let byPreference = DashboardContent(viewModel: viewModel, now: fixedNow, layout: .denseGrid)
    #expect(explicit.metrics == byPreference.metrics)

    // And the override must actually override, or the two densities above
    // would agree for the wrong reason.
    let overridden = DashboardContent(
        viewModel: viewModel, now: fixedNow, layout: .denseGrid, density: .large)
    #expect(overridden.metrics != byPreference.metrics)

    // The preference drives it when there is no override.
    viewModel.density = .large
    #expect(
        DashboardContent(viewModel: viewModel, now: fixedNow, layout: .denseGrid).metrics
            == DensityMetrics.large)
}

/// The two axes must stay independent: density is the user's choice, the reset
/// column is a width consequence. Crossing them is how "large on iPhone"
/// would end up with a reset column it has no room for.
@MainActor
@Test func densityDoesNotDecideTheResetColumn() {
    let viewModel = makeDensityViewModel(providers: [provider("codex", windows: [window("weekly", 50)])])
    for density in DashboardDensity.allCases {
        #expect(
            DashboardContent(
                viewModel: viewModel, now: fixedNow, layout: .denseSingleColumn, density: density
            ).layout.showsReset == false)
        #expect(
            DashboardContent(
                viewModel: viewModel, now: fixedNow, layout: .denseGrid, density: density
            ).layout.showsReset == true)
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
