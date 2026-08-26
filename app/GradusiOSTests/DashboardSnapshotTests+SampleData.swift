@testable import GradusiOS
import GradusKit
import XCTest

// Sample Data mode coverage for DashboardSnapshotTests, split out here to
// keep DashboardSnapshotTests.swift under SwiftLint's file_length limit.
// Shares fixtures with that file via DashboardSnapshotFixtures.swift. The
// screenshot-size image assertion stays in DashboardSnapshotTests.swift
// itself -- see that file's header comment for why.

extension DashboardSnapshotTests {
    func testSampleDataModeKeepsLegacyLaunchArgumentDebugOnly() {
        XCTAssertTrue(SampleDataMode.isEnabled(
            arguments: ["GradusiOS", SampleDataMode.launchArgument], isDebugBuild: true
        ))
        XCTAssertFalse(SampleDataMode.isEnabled(
            arguments: ["GradusiOS", SampleDataMode.launchArgument], isDebugBuild: false
        ))
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
        let defaultsName = scratchSuiteName("sample-session")
        let defaults = try XCTUnwrap(scratchDefaults(named: defaultsName))
        defer { removeScratchDefaultsSuite(defaultsName) }
        let liveStatus = dashboardSampleProviders()[0]
        try liveCache.saveCachedStatuses([liveStatus], syncedAt: dashboardSnapshotFixedNow)

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

        try FileLocalCacheStore(directory: sampleDirectory)
            .saveCachedStatuses([liveStatus], syncedAt: dashboardSnapshotFixedNow)
        session.reset()
        XCTAssertEqual(
            FileLocalCacheStore(directory: sampleDirectory).loadCachedStatuses().map(\.providerName),
            try bundledSampleProviders().map(\.providerName)
        )
        XCTAssertEqual(liveCache.loadCachedStatuses(), [liveStatus])
    }
}
