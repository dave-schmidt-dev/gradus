import GradusKit
import SnapshotTesting
import SwiftUI
import Testing

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

/// The exhausted grid on a phone is the one part of this section no snapshot
/// reaches: at every density the eight active cards push it past the bottom of a
/// 393x852 viewport, so `densityLargePhoneDark` passes without covering a pixel
/// of it. That is worth stating rather than papering over with a snapshot at a
/// height no device has — the section is real, a user scrolls to it, and what
/// can be checked cheaply is the number that decides its shape.
///
/// Two cells per row on a phone at compact, one at standard and large.
///
/// The two-to-one step lands between compact and standard, which is earlier than
/// it does for the cards, and it is the string that puts it there rather than a
/// choice: half of a 361pt phone is 175pt, and "resets Aug 12, 7:46 PM" at
/// `.footnote` plus the cell's insets needs about 179. Buying the second column
/// back would mean shaving the minimum below what the text needs — trading a
/// truncated timestamp for a tidier grid, which is the wrong way round. Compact
/// keeps two because 12pt type still fits in the same half-width.
@Test func theExhaustedGridPacksAsIntendedOnAPhone() {
    let phoneContent: CGFloat = 361
    let expected: [(DashboardDensity, CGFloat)] = [(.compact, 2), (.standard, 1), (.large, 1)]

    for (density, columns) in expected {
        let m = density.metrics
        let packed = max(
            1,
            floor((phoneContent + m.exhaustedGap) / (m.exhaustedMinimumSingleColumn + m.exhaustedGap)))
        #expect(
            packed == columns,
            "\(density.rawValue) packs \(packed) exhausted columns on a phone, expected \(columns)")
    }
}

/// The exhausted grid's minimum is what keeps "resets Aug 12, 7:46 PM" whole,
/// so it has to clear the string's width at that density's font -- not merely
/// be larger than the density below it, which `densitiesAreOrderedOnEveryMeasurement`
/// already covers and which a set of three too-small numbers would also satisfy.
///
/// Measured against the widest label the section renders: the longest provider
/// display name is "Antigravity (Claude)" and the longest reset string is
/// "resets Aug 12, 7:46 PM" (22 characters). At iOS system font metrics a
/// character averages ~0.52em, so the reset line needs roughly
/// `22 * 0.52 * pointSize` plus the cell's horizontal insets.
@Test func exhaustedCellsFitTheStringTheyExistToShow() {
    // (density, title font points, reset font points) for the fonts the three
    // tables actually name.
    let fontPoints: [(DashboardDensity, CGFloat, CGFloat)] = [
        (.compact, 15, 12),  // .subheadline / .caption
        (.standard, 16, 13),  // .callout / .footnote
        (.large, 17, 15),  // .body / .subheadline
    ]

    for (density, titlePoints, resetPoints) in fontPoints {
        let m = density.metrics
        let needed = 22.0 * 0.52 * resetPoints + m.cardPadding * 2
        #expect(
            m.exhaustedMinimumGrid >= needed,
            "\(density.rawValue) truncates the reset time on iPad: needs \(needed)")
        #expect(
            m.exhaustedMinimumSingleColumn >= needed,
            "\(density.rawValue) truncates the reset time on iPhone: needs \(needed)")
        // A cell is two lines plus its vertical insets. Below that the text
        // clips rather than the cell growing, because `minHeight` is a floor
        // and `lineLimit(1)` will not wrap out of it. Line height runs a few
        // points over the nominal size at these sizes.
        let twoLines =
            (titlePoints + 3) + (resetPoints + 3) + m.exhaustedLineGap + m.exhaustedGap * 2
        #expect(
            m.exhaustedRowHeight >= twoLines,
            "\(density.rawValue) clips the cell: needs \(twoLines)")
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
