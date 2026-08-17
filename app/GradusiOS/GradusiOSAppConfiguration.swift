import CloudKit
import Foundation
import GradusKit

/// Static configuration and environment helpers: CloudKit dependency wiring,
/// on-disk cache locations, UI-test/sample-data seeding, and the launch-mode
/// predicates the scene and lifecycle methods gate on.
extension GradusiOSApp {
    static func makeCloudKitDependencies() -> CloudKitDependencies {
        guard CloudKitRuntimeConfiguration.currentValue else { return .offline }

        let container = CKContainer(identifier: CloudKitConstants.containerIdentifier)
        let zoneID = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)
        let database = container.privateCloudDatabase
        let fetcher = CKCloudFetcher(database: database, zoneID: zoneID)
        let zoneChangesFetcher = CKZoneChangesFetcher(database: database, zoneID: zoneID)
        let accountSource = ContainerAccountStatusSource(containerIdentifier: CloudKitConstants.containerIdentifier)
        let subscriptionManager = CKSubscriptionManager(
            database: CKSubscriptionDatabaseAdapter(database: database), zoneID: zoneID
        )
        let presenceClient = CKDevicePresenceClient(database: database, zoneID: zoneID)
        return CloudKitDependencies(
            fetcher: fetcher, accountSource: accountSource, zoneChangesFetcher: zoneChangesFetcher,
            subscriptionManager: subscriptionManager, presenceClient: presenceClient
        )
    }

    static func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Gradus", isDirectory: true)
    }

    static func sampleCacheDirectory() -> URL {
        SampleDataMode.storageDirectory(baseDirectory: cacheDirectory())
    }

    /// T3.5's XCUITest asserts the dashboard renders from a seeded offline
    /// cache without needing a live CloudKit round-trip in CI. The XCUITest
    /// passes fixture JSON via `launchEnvironment`; this writes it straight
    /// into the on-disk cache before the view model's `init` reads it, so
    /// the very first frame already shows seeded data.
    static func seedCacheForUITestsIfRequested(into cache: FileLocalCacheStore) {
        guard let seedJSON = ProcessInfo.processInfo.environment["GRADUS_UITEST_SEED_JSON"],
              let data = seedJSON.data(using: .utf8),
              let seeded = try? JSONDecoder().decode([ProviderStatus].self, from: data)
        else { return }
        try? cache.saveCachedStatuses(seeded, syncedAt: Date())
    }

    /// Legacy launch-argument seeding remains available for Debug screenshot
    /// launches. The shipped user path uses `SampleDataSession` instead.
    static func seedSampleDataIfRequested(
        into cache: FileLocalCacheStore,
        arguments: [String] = CommandLine.arguments,
        isDebugBuild: Bool = Self.isDebugBuild,
        bundle: Bundle = .main
    ) -> Bool {
        guard SampleDataMode.isEnabled(arguments: arguments, isDebugBuild: isDebugBuild),
              let providers = try? SampleDataMode.bundledProviders(bundle: bundle)
        else { return false }

        guard (try? cache.saveCachedStatuses(providers, syncedAt: SampleDataMode.fixedNow)) != nil else { return false }
        return true
    }

    static func shouldRunLiveLifecycle(
        isUITesting: Bool,
        sampleDataModeEnabled: Bool,
        syncEnabled: Bool = true
    ) -> Bool {
        !isUITesting && !sampleDataModeEnabled && syncEnabled
    }

    static var isDebugBuild: Bool {
        #if DEBUG
            true
        #else
            false
        #endif
    }

    /// True whenever a UITest has seeded the offline cache (see above). Also
    /// gates `accountMonitor.start()`/`sync()`/subscription creation off of a
    /// real, live CloudKit round-trip: on the shared dev simulator, the
    /// signed-in Apple ID genuinely needs periodic re-verification, so a real
    /// `CKContainer.accountStatus()` call (inside `AccountStatusMonitor.start()`)
    /// surfaces a full-screen, OS-level "Apple Account Verification" dialog
    /// that's unrelated to app correctness and can recur mid-test (observed:
    /// it reappeared after being dismissed once). This is a genuine,
    /// independent OS-level nag on the shared simulator's real signed-in
    /// Apple ID -- confirmed to resurface roughly every 5s on its own,
    /// unrelated to any particular view lifecycle event (an earlier
    /// hypothesis blaming `NavigationSplitView` collapse transitions
    /// rerunning `.task` was investigated and ruled out: the dialog kept
    /// recurring even with CloudKit calls gated off entirely). Fixture data
    /// from `GRADUS_UITEST_SEED_JSON` already renders the dashboard fully
    /// from the on-disk cache with no CloudKit involvement at all, so
    /// skipping these calls under UI tests removes a source of flakiness
    /// without weakening what's under test.
    static var isUITesting: Bool {
        ProcessInfo.processInfo.environment["GRADUS_UITEST_SEED_JSON"] != nil
            || GradusUITestFixture.current != nil
    }
}
