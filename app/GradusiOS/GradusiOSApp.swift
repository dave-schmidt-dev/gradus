import CloudKit
import GradusKit
import SwiftUI

@main
struct GradusiOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel: DashboardViewModel
    private let accountMonitor: AccountStatusMonitor
    private let subscriptionManager: CKSubscriptionManager

    init() {
        if CommandLine.arguments.contains("--cloudkit-spike") {
            Task { await CloudKitSpike.run() }
        }

        let cache = FileLocalCacheStore(directory: Self.cacheDirectory())
        Self.seedCacheForUITestsIfRequested(into: cache)

        let container = CKContainer(identifier: CloudKitConstants.containerIdentifier)
        let zoneID = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)
        let database = container.privateCloudDatabase
        let fetcher = CKCloudFetcher(database: database, zoneID: zoneID)
        let zoneChangesFetcher = CKZoneChangesFetcher(database: database, zoneID: zoneID)
        let accountSource = ContainerAccountStatusSource(containerIdentifier: CloudKitConstants.containerIdentifier)

        let viewModel = DashboardViewModel(
            cache: cache, fetcher: fetcher, accountSource: accountSource, zoneChangesFetcher: zoneChangesFetcher)
        _viewModel = StateObject(wrappedValue: viewModel)

        self.subscriptionManager = CKSubscriptionManager(
            database: CKSubscriptionDatabaseAdapter(database: database), zoneID: zoneID)

        // PM-16: mid-session account-status reset (sign-out/switch-account
        // while the app is running), reusing the same actor Phase 2a wired
        // on the Mac side (moved to GradusKit in Phase 3 for exactly this).
        self.accountMonitor = AccountStatusMonitor(source: accountSource) { status in
            Task { @MainActor in viewModel.updateAccountStatus(status) }
        }

        appDelegate.onRemoteNotification = {
            await viewModel.handleRemoteNotification()
        }
    }

    var body: some Scene {
        WindowGroup {
            DashboardView(viewModel: viewModel)
                .task {
                    await accountMonitor.start()
                    await viewModel.sync()
                    await subscribeIfEnabled()
                }
                .onChange(of: viewModel.syncEnabled) { enabled in
                    guard enabled else { return }
                    Task { await subscribeIfEnabled() }
                }
        }
    }

    /// Subscription creation is idempotent (PM-8-style, see
    /// `CKSubscriptionManager`) but still gated on opt-in + an available
    /// account -- creating a private-DB subscription with no signed-in user
    /// or before the user has opted in would just fail/leak silently.
    private func subscribeIfEnabled() async {
        guard viewModel.syncEnabled, viewModel.accountStatus == .available else { return }
        try? await subscriptionManager.subscribeToZoneChanges()
        try? await subscriptionManager.subscribeToWarnings()
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
