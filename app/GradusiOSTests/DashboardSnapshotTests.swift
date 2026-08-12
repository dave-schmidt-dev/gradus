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

private let fixedNow = Date(timeIntervalSince1970: 1_786_219_200) // Matches SampleData.json publication timestamp.

/// Opt in only while intentionally refreshing these baselines:
/// OTHER_SWIFT_FLAGS='$(inherited) -D DASHBOARD_SNAPSHOT_RECORD'
private let dashboardSnapshotRecording: SnapshotTestingConfiguration.Record = {
    #if DASHBOARD_SNAPSHOT_RECORD
        return .all
    #else
        return .never
    #endif
}()

private func sampleProviders() -> [ProviderStatus] {
    [
        ProviderStatus(
            providerName: "codex",
            providerDisplayName: "Codex",
            ok: true,
            errorMessage: nil,
            windows: [
                ProviderWindow(
                    id: "weekly", percentLeft: 62, resetISO: "2026-08-08T05:00:00-04:00", windowHours: 168,
                    paceDelta: -0.05
                ),
            ],
            data: [:],
            observedAt: ISO8601DateFormatter().string(from: fixedNow.addingTimeInterval(-30)),
            snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
            publishedAt: fixedNow,
            syncSource: SyncSource(computerName: "Dave's MacBook Pro", userName: "dave")
        ),
        ProviderStatus(
            providerName: "antigravity-claude",
            providerDisplayName: "Antigravity (Claude)",
            ok: true,
            errorMessage: nil,
            windows: [
                ProviderWindow(
                    id: "weekly", percentLeft: 4, resetISO: "2026-08-05T00:00:00-04:00", windowHours: 168,
                    paceDelta: -0.30
                ),
            ],
            data: [:],
            // Carried-forward and stale: > staleThresholdSeconds old (T3.4/CR-1).
            observedAt: ISO8601DateFormatter().string(from: fixedNow.addingTimeInterval(-900)),
            snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
            publishedAt: fixedNow
        ),
        ProviderStatus(
            providerName: "cursor",
            providerDisplayName: "Cursor",
            ok: false,
            errorMessage: "transient fetch failure",
            windows: [],
            data: [:],
            observedAt: nil,
            snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
            publishedAt: fixedNow
        ),
    ]
}

private func assertSampleProviders(_ providers: [ProviderStatus]) {
    XCTAssertEqual(providers.count, 3)
    XCTAssertTrue(providers.contains { $0.ok && !$0.windows.isEmpty })
    XCTAssertTrue(providers.contains { !$0.ok && $0.windows.isEmpty })
}

private func bundledSampleProviders() throws -> [ProviderStatus] {
    try SampleDataMode.bundledProviders(bundle: Bundle(for: AppDelegate.self))
}

@MainActor
private func makeViewModel(providers: [ProviderStatus], showExhausted: Bool = true) -> DashboardViewModel {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("gradus-snapshot-tests-\(UUID().uuidString)", isDirectory: true)
    let cache = FileLocalCacheStore(directory: directory)
    let defaults = UserDefaults(suiteName: "gradus-dashboard-snapshots-\(UUID().uuidString)")!
    defaults.set(showExhausted, forKey: DashboardViewModel.showExhaustedKey)
    try? cache.saveCachedStatuses(providers, syncedAt: fixedNow)
    return DashboardViewModel(cache: cache, userDefaults: defaults)
}

private func exhaustedProvider(named name: String) -> ProviderStatus {
    ProviderStatus(
        providerName: name,
        providerDisplayName: name.capitalized,
        ok: true,
        errorMessage: nil,
        windows: [
            ProviderWindow(
                id: "weekly", percentLeft: 0, resetISO: "2026-08-05T00:00:00-04:00", windowHours: 168,
                paceDelta: -0.30
            ),
        ],
        data: [:],
        observedAt: ISO8601DateFormatter().string(from: fixedNow),
        snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
        publishedAt: fixedNow
    )
}

/// Fixtures whose *displayed number* differs under truncation and rounding, so
/// a dashboard rendered with the old `Int(window.percentLeft)` cannot match
/// this file's baseline.
///
/// Every other percentage in the image suite is a whole number. Those below
/// ten (0, 1, 3, 4, 5) do move -- they gain a decimal -- so a wholesale revert
/// to `Int()` would be caught without this fixture. What no whole number can
/// catch is the defect TASKS row 29 actually described: truncation versus
/// rounding at or above ten, where `Int(47)` and `round(47)` agree and only a
/// fractional value disagrees. `47.8` is that value.
/// Each reset time is derived from its pace rather than picked, on the same
/// `paceDelta == fractionLeft - fractionOfWindowRemaining` identity
/// `paceDivergentProviders` uses -- a fixture whose pace contradicts its own
/// clock would be unreachable in production and a bad thing to pin pixels to.
private func truncationDivergentProviders() -> [ProviderStatus] {
    func provider(_ name: String, percentLeft: Double, paceDelta: Double, resetISO: String)
        -> ProviderStatus
    {
        ProviderStatus(
            providerName: name,
            providerDisplayName: name.capitalized,
            ok: true,
            errorMessage: nil,
            windows: [
                ProviderWindow(
                    id: "weekly", percentLeft: percentLeft, resetISO: resetISO,
                    windowHours: 168, paceDelta: paceDelta
                ),
            ],
            data: [:],
            observedAt: ISO8601DateFormatter().string(from: fixedNow),
            snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
            publishedAt: fixedNow
        )
    }
    return [
        // Rounds to 48, truncates to 47 -- the value David saw disagree
        // between the TUI and the phone.
        provider(
            "codex", percentLeft: 47.8, paceDelta: -0.05, resetISO: "2026-07-29T06:02:14-04:00"
        ),
        // Rounds up across the decimal band to "10.0", truncates to "9.9".
        provider(
            "cursor", percentLeft: 9.97, paceDelta: -0.12, resetISO: "2026-07-27T02:14:34-04:00"
        ),
        // The one that matters most: above the 0.5 depleted ceiling, so this
        // is a LIVE window, but `Int(0.7)` is 0 -- it rendered, and spoke to
        // VoiceOver, as fully exhausted.
        provider(
            "copilot", percentLeft: 0.7, paceDelta: -0.30, resetISO: "2026-07-27T16:54:33-04:00"
        ),
    ]
}

/// Fixtures whose signal level is the *opposite* of what the pre-pace,
/// percent-only ramp produced, so a dashboard rendered with the old ramp
/// cannot match this file's baseline.
///
/// Every other fixture in this file coincidentally agrees under both ramps
/// (62%/-0.05 is yellow either way; 4%/-0.30 and 0%/-0.30 are red either
/// way), which left the dashboard's adoption of the ramp with no pixel
/// coverage at all. These two invert in both directions:
///
/// - `opencode` 3% left, +0.02 pace: nearly empty but the window is nearly
///   over — David's motivating case. Old ramp: red. New: green.
/// - `claude` 72% left, -0.26 pace: plenty left but almost none of the week
///   spent. Old ramp: green. New: red.
///
/// Both are physically reachable: `paceDelta == fractionLeft -
/// fractionOfWindowRemaining`, so the fixtures' reset timestamps are set to
/// the window fraction each pace value implies (1% and 98% of 168h from
/// `fixedNow`) rather than to arbitrary dates that would contradict them.
private func paceDivergentProviders() -> [ProviderStatus] {
    [
        ProviderStatus(
            providerName: "opencode",
            providerDisplayName: "OpenCode",
            ok: true,
            errorMessage: nil,
            windows: [
                ProviderWindow(
                    id: "weekly", percentLeft: 3, resetISO: "2026-07-25T15:00:48-04:00", windowHours: 168,
                    paceDelta: 0.02
                ),
            ],
            data: [:],
            observedAt: ISO8601DateFormatter().string(from: fixedNow),
            snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
            publishedAt: fixedNow
        ),
        ProviderStatus(
            providerName: "claude",
            providerDisplayName: "Claude",
            ok: true,
            errorMessage: nil,
            windows: [
                ProviderWindow(
                    id: "weekly", percentLeft: 72, resetISO: "2026-08-01T09:58:24-04:00", windowHours: 168,
                    paceDelta: -0.26
                ),
            ],
            data: [:],
            observedAt: ISO8601DateFormatter().string(from: fixedNow),
            snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
            publishedAt: fixedNow
        ),
    ]
}

/// P3/T3.3 gate: under the corrected ranking (Key decision #6), `cursor`
/// (errored, tier 1) sorts first -- not `codex` (62%, the highest percent) --
/// so these snapshots assert the errored provider's card renders first, with
/// the rest of `sampleProviders()` following in ranked order. The hero tile
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
final class DashboardSnapshotTests: XCTestCase {
    /// Recorded at 393x852 — a real iPhone 16 in points, not the old 390x600.
    /// The height matters now: these assert what a phone actually shows without
    /// scrolling, and a 600pt canvas quietly flattered a layout whose whole claim
    /// is density.
    @MainActor
    func testDashboardRendersDenseCardsCompactLight() {
        let providers = sampleProviders()
        assertSampleProviders(providers)
        let viewModel = makeViewModel(providers: providers)
        XCTAssertEqual(viewModel.heroProvider?.providerName, "cursor")
        let view = DashboardContent(viewModel: viewModel, now: fixedNow, layout: .denseSingleColumn)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 852), traits: UITraitCollection(userInterfaceStyle: .light)),
            record: dashboardSnapshotRecording,
            testName: "dashboardRendersDenseCardsCompactLight"
        )
    }

    @MainActor
    func testDashboardRendersDenseCardsCompactDark() {
        let providers = sampleProviders()
        assertSampleProviders(providers)
        let viewModel = makeViewModel(providers: providers)
        XCTAssertEqual(viewModel.heroProvider?.providerName, "cursor")
        let view = DashboardContent(viewModel: viewModel, now: fixedNow, layout: .denseSingleColumn)
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
        let view = DashboardContent(viewModel: viewModel, now: fixedNow, layout: .denseSingleColumn)
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
        let view = DashboardContent(viewModel: viewModel, now: fixedNow, layout: .denseSingleColumn)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 520), traits: UITraitCollection(userInterfaceStyle: .light)),
            record: dashboardSnapshotRecording,
            testName: "dashboardTruncatesPercentagesRatherThanRounding"
        )
    }

    @MainActor
    func testDashboardSeparatesActiveProvidersBeforeCompactExhaustedSection() {
        let providers = sampleProviders()
        assertSampleProviders(providers)
        let viewModel = makeViewModel(providers: providers + [
            exhaustedProvider(named: "vibe"),
            exhaustedProvider(named: "copilot"),
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
        let providers = sampleProviders()
        assertSampleProviders(providers)
        let viewModel = makeViewModel(providers: providers + [
            exhaustedProvider(named: "vibe"),
            exhaustedProvider(named: "copilot"),
        ])

        assertSnapshot(
            of: DashboardContent(
                viewModel: viewModel,
                now: fixedNow,
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
                now: fixedNow,
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
        let providers = sampleProviders()
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
        XCTAssertEqual(SampleDataMode.fixedNow, fixedNow)
        let providers = try bundledSampleProviders()
        XCTAssertFalse(providers.isEmpty)
        XCTAssertTrue(providers.allSatisfy { $0.providerDisplayName.hasPrefix("Sample ") })
        XCTAssertTrue(providers.allSatisfy { !$0.windows.isEmpty })

        let snapshots: [(String, CGFloat, CGFloat, DashboardLayout, DashboardDensity)] = [
            ("sampleDataDashboardIPhone", 393, 852, .denseSingleColumn, .compact),
            ("sampleDataDashboardIPhoneLarge", 430, 932, .denseSingleColumn, .compact),
            ("sampleDataDashboardIPad", 1024, 1366, .denseGrid, .compact),
        ]
        for (name, width, height, layout, density) in snapshots {
            let viewModel = makeViewModel(providers: providers)
            assertSnapshot(
                of: SampleDataDashboard(
                    viewModel: viewModel,
                    now: fixedNow,
                    layout: layout,
                    density: density
                ),
                as: .image(
                    layout: .fixed(width: width, height: height),
                    traits: UITraitCollection(userInterfaceStyle: .light)
                ),
                record: dashboardSnapshotRecording,
                testName: name
            )
        }
    }

    func testSampleDataModeKeepsLegacyLaunchArgumentDebugOnly() {
        XCTAssertTrue(SampleDataMode.isEnabled(arguments: ["GradusiOS", SampleDataMode.launchArgument], isDebugBuild: true))
        XCTAssertFalse(SampleDataMode.isEnabled(arguments: ["GradusiOS", SampleDataMode.launchArgument], isDebugBuild: false))
        XCTAssertFalse(SampleDataMode.isEnabled(arguments: ["GradusiOS"], isDebugBuild: true))
    }

    func testFreshInstallDefersLiveLifecycleUntilSyncIsEnabled() {
        XCTAssertFalse(GradusiOSApp.shouldRunLiveLifecycle(
            isUITesting: false, sampleDataModeEnabled: false, syncEnabled: false
        ))
        XCTAssertTrue(GradusiOSApp.shouldRunLiveLifecycle(
            isUITesting: false, sampleDataModeEnabled: false, syncEnabled: true
        ))
    }

    func testSampleDataModeDisablesLiveLifecycle() {
        XCTAssertFalse(GradusiOSApp.shouldRunLiveLifecycle(isUITesting: false, sampleDataModeEnabled: true))
        XCTAssertFalse(GradusiOSApp.shouldRunLiveLifecycle(isUITesting: true, sampleDataModeEnabled: false))
        XCTAssertTrue(GradusiOSApp.shouldRunLiveLifecycle(isUITesting: false, sampleDataModeEnabled: false))
    }

    func testSampleDataBannerUsesFixedLabel() {
        XCTAssertEqual(SampleDataMode.bannerText, "Explore Sample")
        XCTAssertEqual(SampleDataMode.bannerDetail, "Local-only sample data")
        XCTAssertEqual(SampleDataBanner.minimumHeight, 60)
        XCTAssertNil(SampleDataBanner.maximumHeight)
    }

    @MainActor
    func testSampleDataSessionIsolatedAndResettable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gradus-sample-session-\(UUID().uuidString)", isDirectory: true)
        let liveDirectory = root.appendingPathComponent("Live", isDirectory: true)
        let sampleDirectory = SampleDataMode.storageDirectory(baseDirectory: root)
        let liveCache = FileLocalCacheStore(directory: liveDirectory)
        let defaultsName = "gradus-sample-session-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let liveStatus = sampleProviders()[0]
        try liveCache.saveCachedStatuses([liveStatus], syncedAt: fixedNow)

        let session = SampleDataSession(
            directory: sampleDirectory,
            bundle: Bundle(for: AppDelegate.self),
            defaults: defaults,
            preferencesSuiteName: defaultsName
        )
        XCTAssertFalse(session.viewModel.hasLiveLifecycleDependencies)
        XCTAssertFalse(sampleDirectory == liveDirectory)
        XCTAssertFalse(session.viewModel.providers.isEmpty)
        XCTAssertEqual(liveCache.loadCachedStatuses(), [liveStatus])

        try FileLocalCacheStore(directory: sampleDirectory).saveCachedStatuses([liveStatus], syncedAt: fixedNow)
        session.reset()
        XCTAssertEqual(
            FileLocalCacheStore(directory: sampleDirectory).loadCachedStatuses().map(\.providerName),
            try bundledSampleProviders().map(\.providerName)
        )
        XCTAssertEqual(liveCache.loadCachedStatuses(), [liveStatus])
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

    func testICloudRecoveryActionsDoNotOpenAppSettings() {
        XCTAssertEqual(EmptyStateView.actionTitle(for: .notSignedIn), "Try Again")
        XCTAssertEqual(EmptyStateView.actionTitle(for: .tryAgain), "Try Again")
        XCTAssertEqual(EmptyStateView.actionTitle(for: .restricted), "Try Again")
        XCTAssertEqual(EmptyStateView.actionTitle(for: .syncDisabled), "Continue")
        XCTAssertEqual(EmptyStateView.actionTitle(for: .awaitingConfirmation), "Continue")
    }

    /// The temporary-unavailable state stays separate from confirmed no-account
    /// and restricted states. These state-level assertions complement the image
    /// baselines without requiring a live CloudKit account in a snapshot test.
    func testTemporaryUnavailableAndRestrictedICloudRecoveryActionsStayDistinct() {
        XCTAssertEqual(DashboardContent.iCloudRecoveryAction(for: .tryAgain), .retryLiveLifecycle)
        XCTAssertEqual(DashboardContent.iCloudRecoveryAction(for: .notSignedIn), .retryLiveLifecycle)
        XCTAssertEqual(DashboardContent.iCloudRecoveryAction(for: .restricted), .retryLiveLifecycle)
        XCTAssertNotEqual(DashboardContent.iCloudRecoveryAction(for: .tryAgain), .confirmRequiredICloud)
    }

    @MainActor
    func testICloudRetryStartsFreshLifecycle() {
        let viewModel = makeViewModel(providers: [])
        var retryCount = 0
        let dashboard = DashboardContent(
            viewModel: viewModel,
            now: fixedNow,
            layout: .denseSingleColumn,
            onRetryICloud: { retryCount += 1 }
        )

        XCTAssertEqual(DashboardContent.iCloudRecoveryAction(for: .awaitingConfirmation), .confirmRequiredICloud)
        XCTAssertEqual(DashboardContent.iCloudRecoveryAction(for: .tryAgain), .retryLiveLifecycle)
        XCTAssertEqual(DashboardContent.iCloudRecoveryAction(for: .notSignedIn), .retryLiveLifecycle)
        XCTAssertEqual(DashboardContent.iCloudRecoveryAction(for: .restricted), .retryLiveLifecycle)

        dashboard.performICloudRecovery(for: .notSignedIn)

        XCTAssertEqual(retryCount, 1)
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
