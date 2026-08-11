import CloudKit
import GradusKit
import SwiftUI

/// Serializes live lifecycle work with the local sample transition.
///
/// The epoch invalidates a suspended operation before it can start its next
/// seam call. The active-operation count lets sample entry wait for a call
/// already in flight to return before the sample UI becomes visible.
@MainActor
final class LiveLifecycleGate {
    typealias Epoch = UInt64

    private(set) var isSuspended: Bool
    private var epoch: Epoch = 0
    private var activeOperations = 0
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []

    init(initiallySuspended: Bool = false) {
        self.isSuspended = initiallySuspended
    }

    var isLive: Bool { !isSuspended }

    func begin() -> Epoch? {
        guard !isSuspended else { return nil }
        activeOperations += 1
        return epoch
    }

    func finish() {
        guard activeOperations > 0 else { return }
        activeOperations -= 1
        guard activeOperations == 0 else { return }
        let waiters = quiescenceWaiters
        quiescenceWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func isCurrent(_ operationEpoch: Epoch) -> Bool {
        !isSuspended && operationEpoch == epoch
    }

    func withOperation<T>(_ operation: (Epoch) async -> T) async -> T? {
        guard let operationEpoch = begin() else { return nil }
        defer { finish() }
        return await operation(operationEpoch)
    }

    /// Invalidates new work immediately, then waits for calls that started
    /// before this transition to finish. The caller may safely present local
    /// sample data after this returns.
    func suspend() async {
        if isSuspended {
            guard activeOperations > 0 else { return }
            await withCheckedContinuation { continuation in
                quiescenceWaiters.append(continuation)
            }
            return
        }
        isSuspended = true
        epoch &+= 1
        guard activeOperations > 0 else { return }
        await withCheckedContinuation { continuation in
            quiescenceWaiters.append(continuation)
        }
    }

    func resume() {
        isSuspended = false
        epoch &+= 1
    }
}

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
    static let bannerText = "Explore Sample"
    static let bannerDetail = "Local-only sample data"
    /// Pinned to the bundled fixture's publication timestamp so reset labels
    /// and age indicators are deterministic without aging between launches.
    static let fixedNow = Date(timeIntervalSince1970: 1_786_219_200)
    static let storageDirectoryName = "Sample"
    static let preferencesSuiteName = "com.zerodelta.gradus.sample-preferences"

    enum Error: Swift.Error {
        case missingBundledData
    }

    /// The legacy launch argument remains Debug-only; the normal shipped path
    /// enters through the visible Explore Sample controls instead.
    static func isEnabled(arguments: [String], isDebugBuild: Bool) -> Bool {
        isDebugBuild && arguments.contains(launchArgument)
    }

    static func bundledProviders(bundle: Bundle = .main) throws -> [ProviderStatus] {
        guard let url = bundle.url(forResource: "SampleData", withExtension: "json") else {
            throw Error.missingBundledData
        }
        return try JSONDecoder().decode([ProviderStatus].self, from: Data(contentsOf: url))
    }

    static func storageDirectory(baseDirectory: URL) -> URL {
        baseDirectory.appendingPathComponent(storageDirectoryName, isDirectory: true)
    }
}

/// Owns the sample cache and preferences independently from the live iCloud
/// cache. It deliberately has no CloudKit, account, subscription, or
/// notification dependencies, so entering this path cannot start live work.
@MainActor
final class SampleDataSession: ObservableObject {
    @Published private(set) var viewModel: DashboardViewModel
    private let cache: FileLocalCacheStore
    private let bundle: Bundle
    private let defaults: UserDefaults
    private let preferencesSuiteName: String

    init(
        directory: URL,
        bundle: Bundle = .main,
        defaults: UserDefaults = UserDefaults(suiteName: SampleDataMode.preferencesSuiteName)!,
        preferencesSuiteName: String = SampleDataMode.preferencesSuiteName
    ) {
        self.cache = FileLocalCacheStore(directory: directory)
        self.bundle = bundle
        self.defaults = defaults
        self.preferencesSuiteName = preferencesSuiteName
        Self.seed(cache: cache, bundle: bundle)
        self.viewModel = DashboardViewModel(cache: cache, userDefaults: defaults)
    }

    func reset() {
        try? cache.clear()
        defaults.removePersistentDomain(forName: preferencesSuiteName)
        Self.seed(cache: cache, bundle: bundle)
        viewModel = DashboardViewModel(cache: cache, userDefaults: defaults)
    }

    private static func seed(cache: FileLocalCacheStore, bundle: Bundle) {
        guard let providers = try? SampleDataMode.bundledProviders(bundle: bundle) else { return }
        try? cache.saveCachedStatuses(providers, syncedAt: SampleDataMode.fixedNow)
    }
}

/// The banner makes the local-only state and its reversible controls visible
/// on both iPhone and iPad, including in screenshot/test builds.
struct SampleDataBanner: View {
    /// A minimum keeps the marker legible at standard text sizes; there is no
    /// upper bound so Dynamic Type can expand the banner instead of clipping
    /// its disclosure or controls.
    static let minimumHeight: CGFloat = 60
    static let maximumHeight: CGFloat? = nil

    let onExit: () -> Void
    let onReset: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SampleDataMode.bannerText)
                    .font(.caption.weight(.semibold))
                Text(SampleDataMode.bannerDetail)
                    .font(.caption2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("sample-data-banner")
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Reset", action: onReset)
                .accessibilityIdentifier("sample-data-reset")
            Button("Exit", action: onExit)
                .accessibilityIdentifier("sample-data-exit")
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: Self.minimumHeight, maxHeight: Self.maximumHeight)
        .background(.yellow)
    }
}

struct SampleDataDashboard: View {
    @ObservedObject var viewModel: DashboardViewModel
    let now: Date
    let layout: DashboardLayout?
    let density: DashboardDensity?
    let onExit: () -> Void
    let onReset: () -> Void

    init(
        viewModel: DashboardViewModel,
        now: Date = Date(),
        layout: DashboardLayout? = nil,
        density: DashboardDensity? = nil,
        onExit: @escaping () -> Void = {},
        onReset: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.now = now
        self.layout = layout
        self.density = density
        self.onExit = onExit
        self.onReset = onReset
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SampleDataBanner(onExit: onExit, onReset: onReset)
                DashboardContent(
                    viewModel: viewModel, now: now, layout: layout, density: density,
                    isSampleMode: true, onExitSample: onExit, onResetSample: onReset)
            }
        }
    }
}

@main
struct GradusiOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel: DashboardViewModel
    @StateObject private var sampleSession: SampleDataSession
    @State private var sampleModeActive: Bool
    @State private var sampleEntryInProgress = false
    @Environment(\.scenePhase) private var scenePhase
    private let liveLifecycleGate: LiveLifecycleGate
    private let accountMonitor: AccountStatusMonitor?
    private let subscriptionManager: CKSubscriptionManager?

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

        let launchSampleMode = SampleDataMode.isEnabled(arguments: CommandLine.arguments, isDebugBuild: Self.isDebugBuild)
        let liveLifecycleGate = LiveLifecycleGate(initiallySuspended: launchSampleMode)
        self.liveLifecycleGate = liveLifecycleGate
        _sampleModeActive = State(initialValue: launchSampleMode)
        _sampleSession = StateObject(wrappedValue: SampleDataSession(directory: Self.sampleCacheDirectory()))

        let cache = FileLocalCacheStore(directory: Self.cacheDirectory())
        Self.seedCacheForUITestsIfRequested(into: cache)

        let dependencies = launchSampleMode ? CloudKitDependencies.offline : Self.makeCloudKitDependencies()
        let warningNotificationScheduler = LocalWarningNotificationScheduler()

        let viewModel = DashboardViewModel(
            cache: cache, fetcher: dependencies.fetcher, accountSource: dependencies.accountSource,
            zoneChangesFetcher: dependencies.zoneChangesFetcher, subscriptionManager: dependencies.subscriptionManager,
            warningNotificationScheduler: warningNotificationScheduler,
            notificationAuthorizationSource: SystemNotificationAuthorizationSource(),
            liveLifecycleGate: liveLifecycleGate)
        _viewModel = StateObject(wrappedValue: viewModel)

        // PM-16: mid-session account-status reset (sign-out/switch-account
        // while the app is running), reusing the same actor Phase 2a wired
        // on the Mac side (moved to GradusKit in Phase 3 for exactly this).
        let accountMonitor: AccountStatusMonitor?
        if !launchSampleMode, let accountSource = dependencies.accountSource {
            accountMonitor = AccountStatusMonitor(source: accountSource) { status in
                Task { @MainActor in viewModel.updateAccountStatus(status) }
            }
        } else {
            accountMonitor = nil
        }
        self.accountMonitor = accountMonitor
        self.subscriptionManager = dependencies.subscriptionManager

        let delegate = appDelegate
        delegate.liveActivitySuppressed = launchSampleMode
        delegate.onRemoteNotification = {
            guard !delegate.liveActivitySuppressed else { return }
            await viewModel.handleRemoteNotification()
        }

        delegate.onAuthorizationResolved = {
            guard !delegate.liveActivitySuppressed else { return }
            Task { await viewModel.refreshNotificationAuthorization() }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if sampleModeActive {
                    SampleDataDashboard(
                        viewModel: sampleSession.viewModel,
                        now: SampleDataMode.fixedNow,
                        onExit: exitSample,
                        onReset: resetSample)
                } else {
                    DashboardView(
                        viewModel: viewModel,
                        onExploreSample: enterSample,
                        isSampleEntryInProgress: sampleEntryInProgress)
                }
                }
                .task {
                    guard Self.shouldRunLiveLifecycle(
                        isUITesting: Self.isUITesting,
                        sampleDataModeEnabled: sampleModeActive,
                        syncEnabled: viewModel.syncEnabled)
                    else { return }
                    await startLiveLifecycle()
                }
                .onChange(of: sampleModeActive) { active in
                    appDelegate.liveActivitySuppressed = active
                    guard !active, !Self.isUITesting else { return }
                    liveLifecycleGate.resume()
                    Task { await startLiveLifecycle() }
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
                              sampleDataModeEnabled: sampleModeActive,
                              syncEnabled: viewModel.syncEnabled)
                    else { return }
                    Task { await viewModel.refreshNotificationAuthorization() }
                }
                .onChange(of: viewModel.syncEnabled) { enabled in
                    guard enabled,
                          Self.shouldRunLiveLifecycle(
                              isUITesting: Self.isUITesting,
                              sampleDataModeEnabled: sampleModeActive,
                              syncEnabled: true)
                    else { return }
                    Task { await startLiveLifecycle() }
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
                              sampleDataModeEnabled: sampleModeActive,
                              syncEnabled: viewModel.syncEnabled)
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
        guard !sampleModeActive else { return }
        guard viewModel.syncEnabled, viewModel.accountStatus == .available else { return }
        guard let subscriptionManager else { return }
        await liveLifecycleGate.withOperation { operationEpoch in
            guard liveLifecycleGate.isCurrent(operationEpoch) else { return }
            try? await subscriptionManager.subscribeToZoneChanges()
            guard liveLifecycleGate.isCurrent(operationEpoch), viewModel.notificationsEnabled else { return }
            try? await subscriptionManager.subscribeToWarnings()
        }
    }

    /// Re-enters the same live sequence after leaving the local sample. This
    /// is explicit because changing the sample state is not guaranteed to
    /// recreate the surrounding scene task.
    private func startLiveLifecycle() async {
        guard !sampleModeActive, liveLifecycleGate.isLive else { return }
        await liveLifecycleGate.withOperation { operationEpoch in
            guard liveLifecycleGate.isCurrent(operationEpoch) else { return }
            appDelegate.beginLiveLifecycle()
            await appDelegate.awaitAuthorizationResolution()
        }
        await viewModel.refreshNotificationAuthorization()
        guard !sampleModeActive, liveLifecycleGate.isLive else { return }
        await liveLifecycleGate.withOperation { operationEpoch in
            guard liveLifecycleGate.isCurrent(operationEpoch) else { return }
            await accountMonitor?.stopObserving()
            guard liveLifecycleGate.isCurrent(operationEpoch) else { return }
            await accountMonitor?.start()
        }
        guard !sampleModeActive, liveLifecycleGate.isLive else { return }
        await viewModel.sync()
        guard !sampleModeActive, liveLifecycleGate.isLive else { return }
        await subscribeIfEnabled()
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

    private static func sampleCacheDirectory() -> URL {
        SampleDataMode.storageDirectory(baseDirectory: cacheDirectory())
    }

    private func enterSample() {
        guard !sampleModeActive, !sampleEntryInProgress else { return }
        sampleEntryInProgress = true
        appDelegate.liveActivitySuppressed = true
        Task { @MainActor in
            defer {
                sampleEntryInProgress = false
                if !sampleModeActive {
                    appDelegate.liveActivitySuppressed = false
                    liveLifecycleGate.resume()
                }
            }
            await liveLifecycleGate.suspend()
            guard !Task.isCancelled else { return }
            await accountMonitor?.stopObserving()
            guard !Task.isCancelled else { return }
            sampleModeActive = true
        }
    }

    private func exitSample() {
        sampleModeActive = false
        appDelegate.liveActivitySuppressed = false
        liveLifecycleGate.resume()
    }

    private func resetSample() {
        sampleSession.reset()
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
