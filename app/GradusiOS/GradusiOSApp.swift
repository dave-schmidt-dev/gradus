import CloudKit
import GradusKit
import SwiftUI

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
    private let presenceLifecycle: DevicePresenceLifecycle
    private let uiTestFixture: GradusUITestFixture?

    struct CloudKitDependencies {
        let fetcher: CloudFetcher?
        let accountSource: AccountStatusSource?
        let zoneChangesFetcher: ZoneChangesFetcher?
        let subscriptionManager: CKSubscriptionManager?
        let presenceClient: (any DevicePresenceClient)?

        static let offline = CloudKitDependencies(
            fetcher: nil, accountSource: nil, zoneChangesFetcher: nil, subscriptionManager: nil, presenceClient: nil
        )
    }

    // swiftlint:disable:next function_body_length
    init() {
        let uiTestFixture = GradusUITestFixture.current
        self.uiTestFixture = uiTestFixture
        uiTestFixture?.prepare(defaults: .standard)

        // Resolve the required iCloud authority before any delegate, monitor,
        // subscription, or SwiftUI lifecycle reader can start live work.
        _ = RequiredICloudMigration.migrate(
            defaults: .standard, legacyKey: DashboardViewModel.syncEnabledKey
        )

        #if DEBUG
            if CommandLine.arguments.contains("--cloudkit-spike"), CloudKitRuntimeConfiguration.currentValue {
                Task { await CloudKitSpike.run() }
            }
        #endif

        let launchSampleMode = SampleDataMode.isEnabled(
            arguments: CommandLine.arguments, isDebugBuild: Self.isDebugBuild
        )
        // UI fixtures are wholly deterministic. Keep the gate closed from
        // construction onward so no live lifecycle callback can overwrite a
        // fixture before SwiftUI's `.task` takes its UI-testing short path.
        let liveLifecycleGate = LiveLifecycleGate(initiallySuspended: launchSampleMode || uiTestFixture != nil)
        self.liveLifecycleGate = liveLifecycleGate
        _sampleModeActive = State(initialValue: launchSampleMode)
        _sampleSession = StateObject(wrappedValue: SampleDataSession(directory: Self.sampleCacheDirectory()))

        let cache = FileLocalCacheStore(directory: Self.cacheDirectory())
        if uiTestFixture != nil {
            try? cache.clear()
        }
        Self.seedCacheForUITestsIfRequested(into: cache)

        let dependencies = launchSampleMode || Self.isUITesting
            ? CloudKitDependencies.offline
            : Self.makeCloudKitDependencies()
        let warningNotificationScheduler = LocalWarningNotificationScheduler()
        let notificationAuthorizationSource = Self.makeNotificationAuthorizationSource(fixture: uiTestFixture)
        let widgetSnapshotPublisher = Self.makeWidgetSnapshotPublisher(
            isUITesting: Self.isUITesting,
            sampleDataModeEnabled: launchSampleMode
        )

        let viewModel = DashboardViewModel(
            cache: cache, fetcher: dependencies.fetcher, accountSource: dependencies.accountSource,
            zoneChangesFetcher: dependencies.zoneChangesFetcher, subscriptionManager: dependencies.subscriptionManager,
            warningNotificationScheduler: warningNotificationScheduler,
            notificationAuthorizationSource: notificationAuthorizationSource,
            liveLifecycleGate: liveLifecycleGate,
            widgetSnapshotPublisher: widgetSnapshotPublisher
        )
        uiTestFixture?.apply(to: viewModel)
        _viewModel = StateObject(wrappedValue: viewModel)

        // PM-16: mid-session account-status reset (sign-out/switch-account
        // while the app is running), reusing the same actor Phase 2a wired
        // on the Mac side (moved to GradusKit in Phase 3 for exactly this).
        accountMonitor = Self.makeAccountMonitor(
            launchSampleMode: launchSampleMode, accountSource: dependencies.accountSource, viewModel: viewModel
        )
        subscriptionManager = dependencies.subscriptionManager
        presenceLifecycle = DevicePresenceLifecycle(
            client: dependencies.presenceClient,
            eligibility: { @MainActor [weak viewModel] in
                guard let viewModel else { return (false, false) }
                return (
                    liveMode: viewModel.requiredICloudMode.allowsLiveWork,
                    accountAvailable: viewModel.accountStatus == .available
                )
            }
        )

        Self.configureDelegate(
            appDelegate, viewModel: viewModel, liveActivitySuppressed: launchSampleMode || uiTestFixture != nil
        )
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if sampleModeActive {
                    SampleDataDashboard(
                        viewModel: sampleSession.viewModel,
                        now: SampleDataMode.fixedNow,
                        onExit: exitSample,
                        onReset: resetSample
                    )
                } else {
                    DashboardView(
                        viewModel: viewModel,
                        onExploreSample: enterSample,
                        onRetryICloud: retryLiveLifecycle,
                        isSampleEntryInProgress: sampleEntryInProgress,
                        initialWarningAlertsPending: uiTestFixture?.startsWarningAlertRequest ?? false
                    )
                }
            }
            .task {
                if Self.isUITesting {
                    // Fixtures use a deterministic authorization source;
                    // this reads it without performing any live lifecycle
                    // work or prompting for permission.
                    await viewModel.refreshNotificationAuthorization()
                    return
                }
                guard Self.shouldRunLiveLifecycle(
                    isUITesting: Self.isUITesting,
                    sampleDataModeEnabled: sampleModeActive,
                    syncEnabled: viewModel.syncEnabled
                )
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
                if phase == .background {
                    presenceLifecycle.stop()
                    return
                }
                guard phase == .active,
                      Self.shouldRunLiveLifecycle(
                          isUITesting: Self.isUITesting,
                          sampleDataModeEnabled: sampleModeActive,
                          syncEnabled: viewModel.syncEnabled
                      )
                else { return }
                Task {
                    await viewModel.refreshNotificationAuthorization()
                    appDelegate.updateWarningAlertAuthorization(viewModel.systemNotificationAuthorization)
                    await startLiveLifecycle()
                }
            }
            .onChange(of: viewModel.syncEnabled) { enabled in
                guard enabled,
                      Self.shouldRunLiveLifecycle(
                          isUITesting: Self.isUITesting,
                          sampleDataModeEnabled: sampleModeActive,
                          syncEnabled: true
                      )
                else { return }
                Task { await startLiveLifecycle() }
            }
            .onChange(of: viewModel.notificationsEnabled) { enabled in
                // P5/T5.1: re-runs live subscription reconciliation when
                // notifications are flipped on mid-session (e.g. from
                // Settings while sync is already active) -- turning off
                // is handled separately, success-gated, by
                // `DashboardViewModel.setNotificationsEnabled(_:)`
                // itself calling `unsubscribeFromWarnings()` directly.
                appDelegate.setWarningAlertsEnabled(enabled)
                guard enabled,
                      Self.shouldRunLiveLifecycle(
                          isUITesting: Self.isUITesting,
                          sampleDataModeEnabled: sampleModeActive,
                          syncEnabled: viewModel.syncEnabled
                      )
                else { return }
                Task { await reconcileLiveSubscriptions() }
            }
        }
    }
}

/// init() helpers: pure factories, called in a fixed order from `init()`
/// (fixture prep -> migration -> sample/UI-test seeding -> dependency and
/// view-model construction -> delegate wiring). Kept as static functions
/// rather than reordered so that ordering-sensitive setup stays visible at
/// each call site in `init()`.
extension GradusiOSApp {
    private static func makeNotificationAuthorizationSource(
        fixture: GradusUITestFixture?
    ) -> NotificationAuthorizationSource {
        fixture.map { GradusUITestNotificationAuthorizationSource(authorization: $0.notificationAuthorization) }
            ?? SystemNotificationAuthorizationSource()
    }

    /// PM-16: mid-session account-status reset (sign-out/switch-account while
    /// the app is running), reusing the same actor Phase 2a wired on the Mac
    /// side (moved to GradusKit in Phase 3 for exactly this).
    private static func makeAccountMonitor(
        launchSampleMode: Bool,
        accountSource: AccountStatusSource?,
        viewModel: DashboardViewModel
    ) -> AccountStatusMonitor? {
        guard !launchSampleMode, let accountSource else { return nil }
        return AccountStatusMonitor(
            source: accountSource,
            onChange: { status in
                Task { @MainActor in
                    viewModel.updateAccountStatus(status)
                    guard status == .available else { return }
                    await viewModel.reconcileLiveLifecycle()
                }
            },
            onRefreshFailure: {
                Task { @MainActor in viewModel.accountAvailabilityCheckFailed() }
            }
        )
    }

    @MainActor
    private static func configureDelegate(
        _ delegate: AppDelegate,
        viewModel: DashboardViewModel,
        liveActivitySuppressed: Bool
    ) {
        delegate.liveActivitySuppressed = liveActivitySuppressed
        delegate.onRemoteNotification = {
            guard !delegate.liveActivitySuppressed else { return }
            await viewModel.handleRemoteNotification()
        }

        delegate.onAuthorizationResolved = {
            guard !delegate.liveActivitySuppressed else { return }
            Task {
                await viewModel.refreshNotificationAuthorization()
                delegate.updateWarningAlertAuthorization(viewModel.systemNotificationAuthorization)
            }
        }
        delegate.onRemoteRegistrationFailure = {
            Task { @MainActor in viewModel.noteLiveLifecycleFailure() }
        }
    }
}

/// Live lifecycle sequencing: (re-)entering the required live-iCloud path,
/// subscribing after alert selection, and the sample-mode enter/exit/reset
/// transitions.
extension GradusiOSApp {
    /// Subscription creation is idempotent (PM-8-style, see
    /// `CKSubscriptionManager`) but still gated on required live mode and an
    /// available account. Creating a private-DB subscription with no signed-in
    /// user would just fail/leak silently.
    /// P5/T5.1: `subscribeToWarnings()` additionally gates on
    /// `notificationsEnabled` -- the zone-sync subscription (silent,
    /// drives the offline cache) is independent of the user-visible warning
    /// opt-out and still runs whenever sync is on.
    private func reconcileLiveSubscriptions() async {
        guard !sampleModeActive else { return }
        await viewModel.reconcileLiveLifecycle()
    }

    /// Re-enters the same live sequence after leaving the local sample. This
    /// is explicit because changing the sample state is not guaranteed to
    /// recreate the surrounding scene task.
    private func startLiveLifecycle() async {
        guard !sampleModeActive, liveLifecycleGate.isLive else { return }
        viewModel.beginAccountAvailabilityCheck()
        await liveLifecycleGate.withOperation { operationEpoch in
            guard liveLifecycleGate.isCurrent(operationEpoch) else { return }
            appDelegate.beginLiveLifecycle()
            await appDelegate.awaitAuthorizationResolution()
        }
        await viewModel.refreshNotificationAuthorization()
        appDelegate.setWarningAlertsEnabled(
            viewModel.notificationsEnabled,
            knownAuthorization: viewModel.systemNotificationAuthorization
        )
        appDelegate.updateWarningAlertAuthorization(viewModel.systemNotificationAuthorization)
        guard !sampleModeActive, liveLifecycleGate.isLive else { return }
        await liveLifecycleGate.withOperation { operationEpoch in
            guard liveLifecycleGate.isCurrent(operationEpoch) else { return }
            await accountMonitor?.stopObserving()
            guard liveLifecycleGate.isCurrent(operationEpoch) else { return }
            await accountMonitor?.start()
        }
        guard !sampleModeActive, liveLifecycleGate.isLive else { return }
        guard !sampleModeActive, liveLifecycleGate.isLive else { return }
        await viewModel.reconcileLiveLifecycle()
        presenceLifecycle.start(
            liveMode: viewModel.requiredICloudMode.allowsLiveWork,
            accountAvailable: viewModel.accountStatus == .available,
            sampleMode: sampleModeActive
        )
    }

    /// The iCloud recovery controls call this rather than mutating the legacy
    /// Boolean. It re-enters account discovery, the account monitor,
    /// and live reconciliation after the user has corrected their Apple
    /// Account or connectivity outside the app.
    private func retryLiveLifecycle() {
        guard Self.shouldRunLiveLifecycle(
            isUITesting: Self.isUITesting,
            sampleDataModeEnabled: sampleModeActive,
            syncEnabled: viewModel.syncEnabled
        )
        else { return }
        Task { await startLiveLifecycle() }
    }

    private func enterSample() {
        guard !sampleModeActive, !sampleEntryInProgress else { return }
        sampleEntryInProgress = true
        appDelegate.liveActivitySuppressed = true
        presenceLifecycle.stop()
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
}
