import CloudKit
import GradusKit
import SwiftUI

enum CloudKitRuntimeConfiguration {
    /// CloudKit is available on a simulator only when that simulator build
    /// carries the container entitlement. The current generated debug
    /// simulator app does not, so its launch must stay on the offline path.
    static func shouldUseCloudKit(isSimulator: Bool, hasCloudKitEntitlement: Bool) -> Bool {
        !isSimulator || hasCloudKitEntitlement
    }

    /// Device/release builds are signed with `GradusiOS.entitlements`; the
    /// generated simulator debug app is intentionally treated as offline.
    static var currentValue: Bool {
        #if targetEnvironment(simulator)
        return shouldUseCloudKit(isSimulator: true, hasCloudKitEntitlement: false)
        #else
        return shouldUseCloudKit(isSimulator: false, hasCloudKitEntitlement: true)
        #endif
    }
}

enum SampleDataMode {
    static let launchArgument = "--sample-data"
    static let bannerText = "Sample data"
    static let fixedNow = Date(timeIntervalSince1970: 1_785_000_000)

    enum Error: Swift.Error {
        case missingBundledData
    }

    /// This separate parameter makes the Release exclusion testable from the
    /// Debug-built unit-test bundle. The production call below supplies the
    /// compiler-selected value, so a Release artifact cannot enable the mode.
    static func isEnabled(arguments: [String], isDebugBuild: Bool) -> Bool {
        isDebugBuild && arguments.contains(launchArgument)
    }

    static func bundledProviders(bundle: Bundle = .main) throws -> [ProviderStatus] {
        guard let url = bundle.url(forResource: "SampleData", withExtension: "json") else {
            throw Error.missingBundledData
        }
        return try JSONDecoder().decode([ProviderStatus].self, from: Data(contentsOf: url))
    }
}

/// The banner belongs to the screenshot-only launch path rather than Settings:
/// screenshots need an unmistakable marker, while shipped users get no demo
/// entry point at all.
struct SampleDataBanner: View {
    var body: some View {
        Text(SampleDataMode.bannerText)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.yellow, in: Capsule())
            .padding(.top, 8)
            .accessibilityIdentifier("sample-data-banner")
    }
}

struct SampleDataDashboard: View {
    @ObservedObject var viewModel: DashboardViewModel
    let now: Date
    let layout: DashboardLayout?
    let density: DashboardDensity?

    init(
        viewModel: DashboardViewModel,
        now: Date = Date(),
        layout: DashboardLayout? = nil,
        density: DashboardDensity? = nil
    ) {
        self.viewModel = viewModel
        self.now = now
        self.layout = layout
        self.density = density
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SampleDataBanner()
                DashboardContent(viewModel: viewModel, now: now, layout: layout, density: density)
            }
        }
    }
}

@main
struct GradusiOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel: DashboardViewModel
    @Environment(\.scenePhase) private var scenePhase
    private let accountMonitor: AccountStatusMonitor?
    private let subscriptionManager: CKSubscriptionManager?
    private let sampleDataModeEnabled: Bool

    private struct CloudKitDependencies {
        let fetcher: CloudFetcher?
        let accountSource: AccountStatusSource?
        let zoneChangesFetcher: ZoneChangesFetcher?
        let subscriptionManager: CKSubscriptionManager?

        static let offline = CloudKitDependencies(
            fetcher: nil, accountSource: nil, zoneChangesFetcher: nil, subscriptionManager: nil)
    }

    init() {
        #if DEBUG
        if CommandLine.arguments.contains("--cloudkit-spike"), CloudKitRuntimeConfiguration.currentValue {
            Task { await CloudKitSpike.run() }
        }
        #endif

        let cache = FileLocalCacheStore(directory: Self.cacheDirectory())
        Self.seedCacheForUITestsIfRequested(into: cache)
        let sampleDataModeEnabled = Self.seedSampleDataIfRequested(into: cache)
        self.sampleDataModeEnabled = sampleDataModeEnabled

        let dependencies = Self.makeCloudKitDependencies()
        let warningNotificationScheduler = LocalWarningNotificationScheduler()

        let viewModel = DashboardViewModel(
            cache: cache, fetcher: dependencies.fetcher, accountSource: dependencies.accountSource,
            zoneChangesFetcher: dependencies.zoneChangesFetcher, subscriptionManager: dependencies.subscriptionManager,
            warningNotificationScheduler: warningNotificationScheduler,
            notificationAuthorizationSource: SystemNotificationAuthorizationSource())
        _viewModel = StateObject(wrappedValue: viewModel)

        self.subscriptionManager = dependencies.subscriptionManager

        // PM-16: mid-session account-status reset (sign-out/switch-account
        // while the app is running), reusing the same actor Phase 2a wired
        // on the Mac side (moved to GradusKit in Phase 3 for exactly this).
        if !sampleDataModeEnabled, let accountSource = dependencies.accountSource {
            self.accountMonitor = AccountStatusMonitor(source: accountSource) { status in
                Task { @MainActor in viewModel.updateAccountStatus(status) }
            }
        } else {
            self.accountMonitor = nil
        }

        appDelegate.onRemoteNotification = {
            guard !sampleDataModeEnabled else { return }
            await viewModel.handleRemoteNotification()
        }

        appDelegate.onAuthorizationResolved = {
            guard !sampleDataModeEnabled else { return }
            Task { await viewModel.refreshNotificationAuthorization() }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if sampleDataModeEnabled {
                    SampleDataDashboard(viewModel: viewModel, now: SampleDataMode.fixedNow)
                } else {
                    DashboardView(viewModel: viewModel)
                }
            }
                .task {
                    guard Self.shouldRunLiveLifecycle(
                        isUITesting: Self.isUITesting,
                        sampleDataModeEnabled: sampleDataModeEnabled)
                    else { return }
                    await viewModel.refreshNotificationAuthorization()
                    await accountMonitor?.start()
                    await viewModel.sync()
                    await subscribeIfEnabled()
                }
                .onChange(of: scenePhase) { phase in
                    // The only way to change notification permission is to
                    // leave for iOS Settings and come back, so `.active` is
                    // exactly when the cached answer can have gone stale --
                    // and re-reading it on every foreground is what makes the
                    // Settings deep link above self-clearing.
                    guard phase == .active,
                          Self.shouldRunLiveLifecycle(
                              isUITesting: Self.isUITesting,
                              sampleDataModeEnabled: sampleDataModeEnabled)
                    else { return }
                    Task { await viewModel.refreshNotificationAuthorization() }
                }
                .onChange(of: viewModel.syncEnabled) { enabled in
                    guard enabled,
                          Self.shouldRunLiveLifecycle(
                              isUITesting: Self.isUITesting,
                              sampleDataModeEnabled: sampleDataModeEnabled)
                    else { return }
                    Task { await subscribeIfEnabled() }
                }
                .onChange(of: viewModel.notificationsEnabled) { enabled in
                    // P5/T5.1: re-runs `subscribeIfEnabled()` when
                    // notifications are flipped on mid-session (e.g. from
                    // Settings while sync is already active) -- turning off
                    // is handled separately, success-gated, by
                    // `DashboardViewModel.setNotificationsEnabled(_:)`
                    // itself calling `unsubscribeFromWarnings()` directly.
                    guard enabled,
                          Self.shouldRunLiveLifecycle(
                              isUITesting: Self.isUITesting,
                              sampleDataModeEnabled: sampleDataModeEnabled)
                    else { return }
                    Task { await subscribeIfEnabled() }
                }
        }
    }

    /// Subscription creation is idempotent (PM-8-style, see
    /// `CKSubscriptionManager`) but still gated on opt-in + an available
    /// account -- creating a private-DB subscription with no signed-in user
    /// or before the user has opted in would just fail/leak silently.
    /// P5/T5.1: `subscribeToWarnings()` additionally gates on
    /// `notificationsEnabled` -- the zone-sync subscription (silent,
    /// drives the offline cache) is independent of the user-visible warning
    /// opt-out and still runs whenever sync is on.
    private func subscribeIfEnabled() async {
        guard !sampleDataModeEnabled else { return }
        guard viewModel.syncEnabled, viewModel.accountStatus == .available else { return }
        guard let subscriptionManager else { return }
        try? await subscriptionManager.subscribeToZoneChanges()
        guard viewModel.notificationsEnabled else { return }
        try? await subscriptionManager.subscribeToWarnings()
    }

    private static func makeCloudKitDependencies() -> CloudKitDependencies {
        guard CloudKitRuntimeConfiguration.currentValue else { return .offline }

        let container = CKContainer(identifier: CloudKitConstants.containerIdentifier)
        let zoneID = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)
        let database = container.privateCloudDatabase
        let fetcher = CKCloudFetcher(database: database, zoneID: zoneID)
        let zoneChangesFetcher = CKZoneChangesFetcher(database: database, zoneID: zoneID)
        let accountSource = ContainerAccountStatusSource(containerIdentifier: CloudKitConstants.containerIdentifier)
        let subscriptionManager = CKSubscriptionManager(
            database: CKSubscriptionDatabaseAdapter(database: database), zoneID: zoneID)
        return CloudKitDependencies(
            fetcher: fetcher, accountSource: accountSource, zoneChangesFetcher: zoneChangesFetcher,
            subscriptionManager: subscriptionManager)
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

    /// Screenshot-only sample data is compiled out of Release behavior even
    /// when a caller supplies the launch argument. There is deliberately no
    /// user-facing toggle or Settings entry point.
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

    static func shouldRunLiveLifecycle(isUITesting: Bool, sampleDataModeEnabled: Bool) -> Bool {
        !isUITesting && !sampleDataModeEnabled
    }

    private static var isDebugBuild: Bool {
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
    private static var isUITesting: Bool {
        ProcessInfo.processInfo.environment["GRADUS_UITEST_SEED_JSON"] != nil
    }
}
