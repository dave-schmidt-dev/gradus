@testable import GradusiOS
import GradusKit
import SnapshotTesting
import SwiftUI
import XCTest

// T3.5 gate: swift-snapshot-testing regression for the populated dashboard
// (light + dark) and each of the three distinct empty states (CV-5). These
// render `DashboardView`/`EmptyStateView` directly from seeded fixture data
// -- no live CloudKit, no `XCUIApplication` -- mirroring how the Mac side
// snapshots `ProviderListView` standalone (T2b.4). Lives in `GradusiOSTests`
// (a real unit-test bundle), not `GradusiOSUITests` -- a `bundle.ui-testing`
// target doesn't link against the app's compiled code at all, so
// `@testable import GradusiOS` type-checks there but fails at link time.
//
// The suite is split across four files to stay under SwiftLint's
// file_length limit. Every test that calls `assertSnapshot` stays in this
// file: swift-snapshot-testing resolves each test's `__Snapshots__` baseline
// directory from the physical source file of the call site, not the
// enclosing type, so moving an image assertion to a different file would
// silently point it at an empty, wrongly-named baseline directory instead of
// the existing one. This file therefore holds dense-card rendering, ranking,
// pace/truncation coverage, the Sample Data screenshot sizes, and the empty
// states -- everything with pixels to check. DashboardSnapshotTests+SampleData.swift
// and DashboardSnapshotTests+EmptyStates.swift hold their themes' remaining,
// non-image assertions, and DashboardSnapshotFixtures.swift holds shared
// fixtures/helpers all four draw on.

/// P3/T3.3 gate: under the corrected ranking (Key decision #6), `cursor`
/// (errored, tier 1) sorts first -- not `codex` (62%, the highest percent) --
/// so these snapshots assert the errored provider's card renders first, with
/// the rest of `dashboardSampleProviders()` following in ranked order. The hero tile
/// these were written against is gone (INV-12 dense layout); the ranking
/// assertion survives it because ordering, not tile size, is what P3/T3.3
/// gates.
/// Supersedes the old pre-ranking `dashboardRendersPopulatedCards*` pair
/// (deleted here, along with their baselines): same view model, same
/// fixture, now covered by these two under the rewritten `DashboardView`.
///
/// Snapshots `DashboardContent` directly (not `DashboardView`, which wraps
/// it in a `NavigationSplitView`): no navigation chrome to verify here, and
/// rendering `DashboardView` directly through swift-snapshot-testing's
/// offscreen hosting is what caused a SIGSEGV earlier this session (see
/// `DashboardContent`'s doc comment in DashboardView.swift) -- this keeps
/// these tests independent of `DashboardView`'s outer shell entirely.
/// One App Store screenshot size to render the bundled Sample Data dashboard
/// at. Named fields (rather than a tuple) so `testSampleDataDashboardAtAppStoreScreenshotSizes`
/// stays within SwiftLint's large_tuple limit.
private struct SampleDataScreenshotFixture {
    let name: String
    let width: CGFloat
    let height: CGFloat
    let layout: DashboardLayout
    let density: DashboardDensity
}

final class DashboardSnapshotTests: XCTestCase {
    /// Recorded at 393x852 — a real iPhone 16 in points, not the old 390x600.
    /// The height matters now: these assert what a phone actually shows without
    /// scrolling, and a 600pt canvas quietly flattered a layout whose whole claim
    /// is density.
    @MainActor
    func testDashboardRendersDenseCardsCompactLight() {
        let providers = dashboardSampleProviders()
        assertSampleProviders(providers)
        let viewModel = makeViewModel(providers: providers)
        XCTAssertEqual(viewModel.heroProvider?.providerName, "cursor")
        let view = DashboardContent(viewModel: viewModel, now: dashboardSnapshotFixedNow, layout: .denseSingleColumn)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 852), traits: UITraitCollection(userInterfaceStyle: .light)),
            record: dashboardSnapshotRecording,
            testName: "dashboardRendersDenseCardsCompactLight"
        )
    }

    @MainActor
    func testDashboardRendersDenseCardsCompactDark() {
        let providers = dashboardSampleProviders()
        assertSampleProviders(providers)
        let viewModel = makeViewModel(providers: providers)
        XCTAssertEqual(viewModel.heroProvider?.providerName, "cursor")
        let view = DashboardContent(viewModel: viewModel, now: dashboardSnapshotFixedNow, layout: .denseSingleColumn)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 852), traits: UITraitCollection(userInterfaceStyle: .dark)),
            record: dashboardSnapshotRecording,
            testName: "dashboardRendersDenseCardsCompactDark"
        )
    }

    @MainActor
    func testDashboardColorsByPaceNotByPercentageRemaining() {
        // Assert the inversion at the classifier before trusting the pixels: if
        // these two ever stop disagreeing with the percent ramp, the snapshot
        // below silently stops proving anything.
        XCTAssertEqual(signalLevel(percentLeft: 3, paceDelta: 0.02), .green)
        XCTAssertEqual(signalLevel(percentLeft: 3, paceDelta: nil), .red)
        XCTAssertEqual(signalLevel(percentLeft: 72, paceDelta: -0.26), .red)
        XCTAssertEqual(signalLevel(percentLeft: 72, paceDelta: nil), .green)

        let providers = paceDivergentProviders()
        let levels = Set(providers.flatMap(\.windows).map(signalLevel(for:)))
        XCTAssertTrue(levels.contains(.green))
        XCTAssertTrue(levels.contains(.red))
        let viewModel = makeViewModel(providers: providers)
        let view = DashboardContent(viewModel: viewModel, now: dashboardSnapshotFixedNow, layout: .denseSingleColumn)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 400), traits: UITraitCollection(userInterfaceStyle: .light)),
            record: dashboardSnapshotRecording,
            testName: "dashboardColorsByPaceNotByPercentageRemaining"
        )
    }

    /// The pixel half of the shared percent-format contract.
    ///
    /// `GradusKitTests/PercentFormatTests` and `tests/test_ui.py` both assert the
    /// formatter directly; this asserts that the dashboard actually *uses* it. The
    /// distinction is not academic -- the pace ramp shipped with a green suite and
    /// no pixel coverage because every fixture happened to agree under both rules
    /// (see `paceDivergentProviders`), and every percentage in this file was a
    /// whole number until these three were added.
    @MainActor
    func testDashboardTruncatesPercentagesRatherThanRounding() {
        // Assert the formatter's disagreement with the old rule before trusting
        // the pixels: if these ever stop diverging, the baseline below silently
        // stops proving anything.
        XCTAssertEqual(percentText(47.8), "47")
        XCTAssertNotEqual(percentText(47.8), "48")
        XCTAssertEqual(percentText(9.97), "9.9")
        // The live-window case. 0.7 is above the depleted ceiling, so this row is
        // not in the exhausted section -- yet `Int(0.7)` would print it as "0%".
        XCTAssertFalse(percentIsDepleted(0.7))
        XCTAssertEqual(percentText(0.7), "0.7")

        let providers = truncationDivergentProviders()
        XCTAssertTrue(
            providers.flatMap(\.windows).contains {
                percentText($0.percentLeft) != String(Int($0.percentLeft.rounded()))
            }
        )
        let viewModel = makeViewModel(providers: providers)
        let view = DashboardContent(viewModel: viewModel, now: dashboardSnapshotFixedNow, layout: .denseSingleColumn)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 520), traits: UITraitCollection(userInterfaceStyle: .light)),
            record: dashboardSnapshotRecording,
            testName: "dashboardTruncatesPercentagesRatherThanRounding"
        )
    }

    @MainActor
    func testDashboardSeparatesActiveProvidersBeforeCompactExhaustedSection() {
        let providers = dashboardSampleProviders()
        assertSampleProviders(providers)
        let viewModel = makeViewModel(providers: providers + [
            exhaustedProvider(named: "vibe"),
            exhaustedProvider(named: "copilot")
        ])

        for sortOption in ProviderSortOption.allCases {
            viewModel.providerSortOption = sortOption
            let active = viewModel.providers.filter { !$0.isDepleted }
            let exhausted = viewModel.providers.filter(\.isDepleted)
            XCTAssertEqual(active.count, 3)
            XCTAssertEqual(exhausted.count, 2)
            XCTAssertEqual(viewModel.providers, active + exhausted)
        }
    }

    /// Task 4.2 (Spark bucket plan): "Codex (Spark)" is a fully independent
    /// provider entry, not a display variant of "Codex" -- it must rank on
    /// its own `percentLeft` rather than inherit Codex's, and must not trip
    /// the Antigravity-only retry guard. Providers are constructed in
    /// Spark-first order so a correct result can only come from ranking, not
    /// from preserving input order or falling back to name adjacency.
    @MainActor
    func testCodexSparkRanksByItsOwnPercentAndDoesNotTriggerAntigravityGuard() {
        let codex = ProviderStatus(
            providerName: "codex",
            providerDisplayName: "Codex",
            ok: true,
            errorMessage: nil,
            windows: [
                ProviderWindow(id: "weekly", percentLeft: 10, resetISO: nil, windowHours: 168, paceDelta: nil)
            ],
            data: [:],
            observedAt: ISO8601DateFormatter().string(from: dashboardSnapshotFixedNow),
            snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
            publishedAt: dashboardSnapshotFixedNow
        )
        let codexSpark = ProviderStatus(
            providerName: "codex-spark",
            providerDisplayName: "Codex (Spark)",
            ok: true,
            errorMessage: nil,
            windows: [
                ProviderWindow(id: "weekly", percentLeft: 90, resetISO: nil, windowHours: 168, paceDelta: nil)
            ],
            data: [:],
            observedAt: ISO8601DateFormatter().string(from: dashboardSnapshotFixedNow),
            snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
            publishedAt: dashboardSnapshotFixedNow
        )

        let viewModel = makeViewModel(providers: [codexSpark, codex])
        viewModel.providerSortOption = .mostUrgent

        // Codex (10%, attention-needed) must rank ahead of Spark (90%, not
        // attention-needed) -- if Spark had silently inherited Codex's 10%,
        // both would land in the same tier and this would be free to fail.
        XCTAssertEqual(viewModel.providers.map(\.providerName), ["codex", "codex-spark"])

        // The order assertion alone is not discriminating: providerName sorts
        // "codex" < "codex-spark" too, so a name tie-break would produce the
        // same order even if percent ranking were broken. Assert the tier
        // split directly -- with paceDelta nil, signalLevel is percent-driven,
        // so this only passes if each provider ranked on its own percentLeft.
        guard let rankedCodex = viewModel.providers.first(where: { $0.providerName == "codex" }),
              let rankedSpark = viewModel.providers.first(where: { $0.providerName == "codex-spark" })
        else {
            XCTFail("expected both codex and codex-spark in ranked providers")
            return
        }
        XCTAssertTrue(rankedCodex.isWarning)
        XCTAssertFalse(rankedSpark.isWarning)

        XCTAssertNil(IOSProviderRetryAccessibility.label(for: codexSpark))
    }

    /// The view-level half of that gate, and the half that was missing.
    ///
    /// The assertion above checks the order `DashboardViewModel` produces, which
    /// is necessary and was demonstrably not sufficient: the compact exhausted
    /// cell was deleted once already while view-model assertions stayed green,
    /// because nothing rendered the view and looked at what came out (TASKS row
    /// 21). A snapshot is what makes "these two providers render as small cells
    /// under a header, not as full density cards" a thing that can fail.
    ///
    /// Both widths, because the treatments diverged here before: the phone is
    /// where a full card for a spent provider actually pushes actionable rows off
    /// screen, and the iPad is where it's least noticeable and so most likely to
    /// silently regress.
    @MainActor
    func testDashboardRendersExhaustedProvidersAsCompactCells() {
        let providers = dashboardSampleProviders()
        assertSampleProviders(providers)
        let viewModel = makeViewModel(providers: providers + [
            exhaustedProvider(named: "vibe"),
            exhaustedProvider(named: "copilot")
        ])

        assertSnapshot(
            of: DashboardContent(
                viewModel: viewModel,
                now: dashboardSnapshotFixedNow,
                layout: .denseSingleColumn,
                density: .compact
            ),
            as: .image(layout: .fixed(width: 393, height: 760), traits: UITraitCollection(userInterfaceStyle: .light)),
            record: dashboardSnapshotRecording,
            testName: "exhaustedCompactCellsPhone"
        )

        assertSnapshot(
            of: DashboardContent(
                viewModel: viewModel,
                now: dashboardSnapshotFixedNow,
                layout: .denseGrid,
                density: .compact
            ),
            as: .image(layout: .fixed(width: 1024, height: 600), traits: UITraitCollection(userInterfaceStyle: .light)),
            record: dashboardSnapshotRecording,
            testName: "exhaustedCompactCellsPad"
        )
    }

    @MainActor
    func testDashboardHidesExhaustedCellsWhenPreferenceIsOff() {
        let providers = dashboardSampleProviders()
        assertSampleProviders(providers)
        let viewModel = makeViewModel(
            providers: providers + [exhaustedProvider(named: "vibe")],
            showExhausted: false
        )

        XCTAssertTrue(viewModel.providers.allSatisfy { !$0.isDepleted })
        XCTAssertFalse(viewModel.providers.contains { $0.providerName == "vibe" })
    }

    /// Screenshot fixtures exercise the same bundled payload and banner used by
    /// the normal Explore Sample path. Each supported App Store device class gets a
    /// distinct frame so a marker or populated card cannot be cropped away.
    @MainActor
    func testSampleDataDashboardAtAppStoreScreenshotSizes() throws {
        XCTAssertEqual(SampleDataMode.fixedNow, dashboardSnapshotFixedNow)
        let providers = try bundledSampleProviders()
        XCTAssertFalse(providers.isEmpty)
        XCTAssertTrue(providers.allSatisfy { $0.providerDisplayName.hasPrefix("Sample ") })
        XCTAssertTrue(providers.allSatisfy { !$0.windows.isEmpty })

        let snapshots: [SampleDataScreenshotFixture] = [
            SampleDataScreenshotFixture(
                name: "sampleDataDashboardIPhone", width: 393, height: 852,
                layout: .denseSingleColumn, density: .compact
            ),
            SampleDataScreenshotFixture(
                name: "sampleDataDashboardIPhoneLarge", width: 430, height: 932,
                layout: .denseSingleColumn, density: .compact
            ),
            SampleDataScreenshotFixture(
                name: "sampleDataDashboardIPad", width: 1024, height: 1366,
                layout: .denseGrid, density: .compact
            )
        ]
        for fixture in snapshots {
            let viewModel = makeViewModel(providers: providers)
            assertSnapshot(
                of: SampleDataDashboard(
                    viewModel: viewModel,
                    now: dashboardSnapshotFixedNow,
                    layout: fixture.layout,
                    density: fixture.density
                ),
                as: .image(
                    layout: .fixed(width: fixture.width, height: fixture.height),
                    traits: UITraitCollection(userInterfaceStyle: .light)
                ),
                record: dashboardSnapshotRecording,
                testName: fixture.name
            )
        }
    }

    @MainActor
    func testEmptyStateNotSignedIn() {
        let view = EmptyStateView(state: .notSignedIn)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 390, height: 400)),
            record: dashboardSnapshotRecording,
            testName: "emptyStateNotSignedIn"
        )
    }

    @MainActor
    func testEmptyStateSyncDisabled() {
        let view = EmptyStateView(state: .syncDisabled)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 390, height: 400)),
            record: dashboardSnapshotRecording,
            testName: "emptyStateSyncDisabled"
        )
    }

    @MainActor
    func testEmptyStateWaitingForFirstPublish() {
        let view = EmptyStateView(state: .waitingForFirstPublish)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 390, height: 400)),
            record: dashboardSnapshotRecording,
            testName: "emptyStateWaitingForFirstPublish"
        )
    }
}
