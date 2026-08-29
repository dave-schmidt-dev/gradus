@testable import GradusiOS
import GradusKit
import SnapshotTesting
import SwiftUI
import Testing
import UIKit

// iPad Option B (David, 2026-08-05: "I like ipad b with bars for each
// bucket"): behavior coverage for the dense layout's routing, card content,
// and header provenance. The pixel coverage lives in
// `DensityLayoutSnapshotTests` below.

private let fixedNow = Date(timeIntervalSince1970: 1_785_000_000)

func window(
    _ id: String, _ percentLeft: Double, pace: Double? = nil, reset: String? = "2026-07-26T09:00:00-04:00"
) -> ProviderWindow {
    ProviderWindow(id: id, percentLeft: percentLeft, resetISO: reset, windowHours: 168, paceDelta: pace)
}

func provider(
    _ name: String,
    windows: [ProviderWindow],
    ok isOK: Bool = true,
    error: String? = nil,
    data: [String: JSONValue] = [:]
) -> ProviderStatus {
    ProviderStatus(
        providerName: name,
        providerDisplayName: name.capitalized,
        ok: isOK,
        errorMessage: error,
        windows: windows,
        data: data,
        observedAt: ISO8601DateFormatter().string(from: fixedNow),
        snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
        publishedAt: fixedNow
    )
}

@MainActor
func makeDensityViewModel(providers: [ProviderStatus], test: String = #function) -> DashboardViewModel {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-density-tests-\(UUID().uuidString)", isDirectory: true)
    let cache = FileLocalCacheStore(directory: directory)
    let defaults = scratchDefaults("density", test)!
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
            == .denseSingleColumn
    )
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
        windows: [window("five_hour", 100), window("weekly", 61), window("monthly", 7)]
    )
    let viewModel = makeDensityViewModel(providers: [threeWindows])

    struct LayoutPresentation {
        let layout: DashboardLayout
        let width: CGFloat
        let expectedReset: Bool
    }

    let presentations: [LayoutPresentation] = [
        LayoutPresentation(layout: .denseSingleColumn, width: 361, expectedReset: false),
        LayoutPresentation(layout: .denseGrid, width: 802, expectedReset: true)
    ]

    for presentation in presentations {
        let dashboard = DashboardContent(
            viewModel: viewModel,
            now: fixedNow,
            layout: presentation.layout,
            density: .compact
        )
        let columns = presentation.layout == .denseSingleColumn
            ? 1
            : maxColumns(
                containerWidth: presentation.width,
                scaledFixedColumnWidth: 0,
                cardPadding: 0,
                cardGap: DashboardDensity.compact.metrics.cardGap,
                minimumBarWidth: DashboardDensity.compact.metrics.gridMinimum
            )
        let showsReset = dashboard.runtimeShowsReset(
            inContentWidth: presentation.width,
            columns: columns,
            scaledFixedColumnWidth: DashboardDensity.compact.metrics.fixedColumnWidth(showsReset: true)
        )
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
        now: fixedNow
    )
    #expect(line.renderedText == "synced 2m ago · dm5mbp")
}

@Test func syncStatusLineDegradesRatherThanFabricating() {
    let source = SyncSource(computerName: "dm5mbp", userName: "dave")
    // No publish timestamp: name only, no invented age.
    #expect(SyncStatusLine(source: source, publishedAt: nil, now: fixedNow).renderedText == "dm5mbp")
    // No source: age only.
    #expect(
        SyncStatusLine(source: nil, publishedAt: fixedNow.addingTimeInterval(-7200), now: fixedNow)
            .renderedText == "synced 2h ago"
    )
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
                window("monthly", 31, pace: -0.04)
            ]
        ),
        now: fixedNow
    )
    #expect(card.visibleWindows.map(\.id) == ["five_hour", "weekly", "monthly"])

    // INV-3 violations are dropped, not drawn as an `unknown`-colored row --
    // at this density a muted row reads as a spent pool, not as missing data.
    let withInvalid = ProviderDensityCard(
        provider: provider("cursor", windows: [window("api", 150), window("auto", 40)]),
        now: fixedNow
    )
    #expect(withInvalid.visibleWindows.map(\.id) == ["auto"])
}

@Test func densityCardShowsProviderSpecificCreditOnlyWhenPresent() {
    let withCredit = provider(
        "opencode", windows: [window("weekly", 61)], data: ["zen_credit": .double(12.345)]
    )
    #expect(
        ProviderDensityCard(provider: withCredit, now: fixedNow).creditSummary
            == "Zen credit $12.345"
    )

    let withoutCredit = provider("opencode", windows: [window("weekly", 61)])
    #expect(ProviderDensityCard(provider: withoutCredit, now: fixedNow).creditSummary == nil)

    let wrongProvider = provider(
        "codex", windows: [window("weekly", 61)], data: ["zen_credit": .double(12.345)]
    )
    #expect(ProviderDensityCard(provider: wrongProvider, now: fixedNow).creditSummary == nil)

    let codex = provider("codex", windows: [], data: ["credits": .double(2500)])
    #expect(ProviderDensityCard(provider: codex, now: fixedNow).creditSummary == "Credits 2,500")

    let cursor = provider("cursor", windows: [], data: ["credit_balance": .double(5)])
    #expect(ProviderDensityCard(provider: cursor, now: fixedNow).creditSummary == "Credit $5.00")

    let claude = provider("claude", windows: [], data: ["credit_balance": .double(87.75)])
    #expect(ProviderDensityCard(provider: claude, now: fixedNow).creditSummary == "Credit $87.75")

    let unrelated = provider("vibe", windows: [], data: ["credit_balance": .double(10)])
    #expect(ProviderDensityCard(provider: unrelated, now: fixedNow).creditSummary == nil)
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
        verticalSpacing: spacing
    )

    #expect(frames.count == heights.count)
    #expect(frames[0].minY == 0)
    #expect(frames[1].minY == 0)
    #expect(frames[0].height == frames[1].height)
    #expect(frames[2].minY == frames[0].maxY + spacing)
    #expect(frames[3].minY == frames[2].minY)
    #expect(frames[2].height == frames[3].height)
    #expect(
        frames[2].minY >= frames[1].maxY,
        "a later source row must never appear above an earlier provider"
    )
}

@Test func singleColumnPlacementRemainsContentDriven() {
    let heights: [CGFloat] = [144, 92, 118, 90]

    #expect(
        ProviderRowBalancedLayout.rowHeights(cardHeights: heights, columns: 1) == heights,
        "iPhone cards must retain their measured content heights"
    )
    #expect(
        ProviderRowBalancedLayout.frames(
            cardHeights: heights,
            columns: 1,
            cardWidth: 361,
            horizontalSpacing: 14,
            verticalSpacing: 14
        ).map(\.height) == heights
    )
}

@Test func providerCardBorderIsFixedStructuralNavy() {
    #expect(ProviderDensityCardStructuralToken.navyHex == 0x00005F)
    #expect(ProviderDensityCardStructuralToken.opacity == 0.55)
}

private struct MeasuredDevice {
    let name: String
    let cardWidth: CGFloat
    let columns: Int
}

/// The solver's column count and card width for one iPad orientation, with
/// the pinned-preference assertion that the fixture depends on inlined here
/// so the caller doesn't have to repeat it per orientation.
private func resolvedColumns(containerWidth: CGFloat, solverMetrics: DensityMetrics, cardGap: CGFloat) -> (
    columns: Int, cardWidth: CGFloat
) {
    let maximum = maxColumns(
        containerWidth: containerWidth,
        scaledFixedColumnWidth: solverMetrics.fixedColumnWidth(showsReset: false),
        cardPadding: solverMetrics.cardPadding,
        cardGap: solverMetrics.cardGap,
        minimumBarWidth: DensityMetrics.minimumBarWidth
    )
    let columns = DashboardViewModel.resolvedCardColumnCount(
        preference: pinnedCardColumnPreference, maximum: maximum
    )
    #expect(columns == maximum)
    let width = cardWidth(containerWidth: containerWidth, columns: columns, cardGap: cardGap)
    return (columns, width)
}

/// Renders every provider's card at the device's resolved width and checks
/// the row-balanced frames they land in obey the row-major placement rule.
@MainActor
private func assertRowBalancedFramesMatchMeasuredContent(
    device: MeasuredDevice, providers: [ProviderStatus], standardMetrics: DensityMetrics
) {
    let heights = providers.map { provider in
        UIHostingController(
            rootView: ProviderDensityCard(
                provider: provider,
                now: fixedNow,
                showsReset: true,
                metrics: standardMetrics
            )
            .environment(\.dynamicTypeSize, .xxxLarge)
            .frame(width: device.cardWidth, alignment: .leading)
        ).sizeThatFits(in: CGSize(width: device.cardWidth, height: 4000)).height
    }
    #expect(heights.allSatisfy { $0 > 0 }, "\(device.name) produced an empty provider card")
    let frames = ProviderRowBalancedLayout.frames(
        cardHeights: heights,
        columns: device.columns,
        cardWidth: device.cardWidth,
        horizontalSpacing: standardMetrics.cardGap,
        verticalSpacing: standardMetrics.cardGap
    )
    #expect(frames.count == providers.count)
    #expect(frames[0].minY == 0)
    for rowStart in stride(from: 0, to: frames.count, by: device.columns) {
        let rowEnd = min(rowStart + device.columns, frames.count)
        let rowFrames = Array(frames[rowStart ..< rowEnd])
        let rowY = rowFrames[0].minY
        #expect(rowFrames.dropFirst().allSatisfy { $0.minY == rowY })
        #expect(rowFrames.dropFirst().allSatisfy { $0.height == rowFrames[0].height })
        if rowStart > 0 {
            #expect(rowY >= frames[rowStart - 1].maxY)
        }
    }
}

@MainActor
@Test func fullFixturePinsPortraitLandscapeMeasurementsAndLargeText() {
    let providers = fullProviderSet()
    #expect(providers.count == 9)
    #expect(providers.reduce(0) { $0 + $1.windows.count } == 15)

    let standard = DashboardDensity.standard.metrics
    let solverMetrics = DashboardDensity.compact.metrics
    let portraitWidth = CGFloat(834) - dashboardHorizontalInset * 2
    let landscapeWidth = CGFloat(1194) - dashboardHorizontalInset * 2
    let portrait = resolvedColumns(
        containerWidth: portraitWidth, solverMetrics: solverMetrics, cardGap: standard.cardGap
    )
    let landscape = resolvedColumns(
        containerWidth: landscapeWidth, solverMetrics: solverMetrics, cardGap: standard.cardGap
    )

    let devices = [
        MeasuredDevice(
            name: "iPad Pro 11-inch (M5) portrait", cardWidth: portrait.cardWidth, columns: portrait.columns
        ),
        MeasuredDevice(
            name: "iPad Pro 11-inch (M5) landscape", cardWidth: landscape.cardWidth, columns: landscape.columns
        )
    ]
    for device in devices {
        assertRowBalancedFramesMatchMeasuredContent(device: device, providers: providers, standardMetrics: standard)
    }
}

/// The iPhone and iPad snapshots may differ in geometry, but never in the
/// provider/window identity set. The sole visual exception owned by this
/// phase is the shared label foreground token from Task 2.1.
@MainActor
@Test func iPhoneAndIPadSemanticSnapshotsHaveExactWindowParity() {
    let providers = fullProviderSet()
    let iPhone = DashboardContent(
        viewModel: makeDensityViewModel(providers: providers, test: "\(#function).iPhone"),
        now: fixedNow,
        layout: .denseSingleColumn,
        density: .standard
    )
    let iPad = DashboardContent(
        viewModel: makeDensityViewModel(providers: providers, test: "\(#function).iPad"),
        now: fixedNow,
        layout: .denseGrid,
        density: .standard
    )

    let expectedProviderNames = Set(providers.map(\.providerName))
    #expect(Set(iPhone.semanticProviderWindowSet.map(\.providerName)) == expectedProviderNames)
    #expect(Set(iPad.semanticProviderWindowSet.map(\.providerName)) == expectedProviderNames)
    #expect(iPhone.semanticProviderWindowSet.count == 9)
    #expect(iPhone.semanticProviderWindowSet.reduce(0) { $0 + $1.windowIDs.count } == 15)
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
        verticalSpacing: 14
    )
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
