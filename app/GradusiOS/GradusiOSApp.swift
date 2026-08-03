import CloudKit
import GradusKit
import SwiftUI

@main
struct GradusiOSApp: App {
    @StateObject private var viewModel: DashboardViewModel

    init() {
        if CommandLine.arguments.contains("--cloudkit-spike") {
            Task { await CloudKitSpike.run() }
        }

        let cache = FileLocalCacheStore(directory: Self.cacheDirectory())
        Self.seedCacheForUITestsIfRequested(into: cache)

        let container = CKContainer(identifier: CloudKitConstants.containerIdentifier)
        let zoneID = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)
        let fetcher = CKCloudFetcher(database: container.privateCloudDatabase, zoneID: zoneID)
        let accountSource = ContainerAccountStatusSource(containerIdentifier: CloudKitConstants.containerIdentifier)

        _viewModel = StateObject(
            wrappedValue: DashboardViewModel(cache: cache, fetcher: fetcher, accountSource: accountSource))
    }

    var body: some Scene {
        WindowGroup {
            DashboardView(viewModel: viewModel)
                .task {
                    await viewModel.refreshAccountStatus()
                    await viewModel.sync()
                }
        }
    }

    private static func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Gradus", isDirectory: true)
    }

    /// T3.5's XCUITest asserts the dashboard renders from a seeded offline
    /// cache without needing a live CloudKit round-trip in CI. The XCUITest
    /// passes fixture JSON via `launchEnvironment`; this writes it straight
    /// into the on-disk cache before the view model's `init` reads it, so
    /// the very first frame already shows seeded data.
    private static func seedCacheForUITestsIfRequested(into cache: FileLocalCacheStore) {
        guard let seedJSON = ProcessInfo.processInfo.environment["GRADUS_UITEST_SEED_JSON"],
            let data = seedJSON.data(using: .utf8),
            let seeded = try? JSONDecoder().decode([ProviderStatus].self, from: data)
        else { return }
        try? cache.saveCachedStatuses(seeded, syncedAt: Date())
    }
}
