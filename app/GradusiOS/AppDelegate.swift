import UIKit
import UserNotifications

/// Bridges UIKit's remote-notification delegate callbacks (T4.1/T4.2) into
/// the SwiftUI app -- SwiftUI's `App` protocol has no equivalent hook, so
/// this is wired in via `@UIApplicationDelegateAdaptor`. Both subscriptions
/// deliver through this same content-available path; the app-side sync
/// decides whether a warning transition warrants a local notification.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Set while the local sample flow is active. This blocks remote pushes
    /// from reaching the live view model; sample mode has no live lifecycle.
    var liveActivitySuppressed = CommandLine.arguments.contains(SampleDataMode.launchArgument)
    var onRemoteNotification: (() async -> Void)?
    var onRemoteRegistrationFailure: (() -> Void)?

    /// Fires once the first-launch permission prompt has been answered,
    /// whichever way it went.
    ///
    /// Without this, a first-launch *denial* stays invisible: the app's
    /// `.task` reads the authorization state concurrently with the prompt
    /// being answered, so it sees `.notDetermined`, and the only other read
    /// is a `scenePhase` return to `.active` -- which a permission alert does
    /// not necessarily produce, since the app never leaves the foreground for
    /// it. A user who taps "Don't Allow" would otherwise see no warning in
    /// Settings until some unrelated background/foreground cycle. This
    /// notifies rather than passing the prompt's own `granted` flag along, so
    /// the displayed state still comes from `notificationSettings()` on every
    /// read instead of a cached copy of one moment's answer.
    var onAuthorizationResolved: (() -> Void)?

    /// The app's alert choice is deliberately separate from APNs registration.
    /// `off` is the default for a fresh install; a permission request is only
    /// started after the Warning alerts control is enabled.
    private(set) var warningAlertAuthorization: NotificationAuthorization = .off

    private let clearBadge: (UIApplication) -> Void
    private let liveModeEnabled: () -> Bool
    private let registerForRemoteNotifications: @MainActor (UIApplication) -> Void

    /// Requests notification authorization and calls back once the prompt has
    /// been answered. Injected so the launch path can be exercised in a unit
    /// test without a real prompt (which no test can answer) and without a
    /// real APNs registration attempt.
    private let requestNotificationAuthorization: (UIApplication, @escaping (Bool) -> Void) -> Void
    private var liveLifecycleStarted = false
    private var warningAlertIntentGeneration: UInt64 = 0
    private var warningAlertsEnabled = false
    private var remoteRegistrationStarted = false
    private var remoteRegistrationFailed = false

    private static let systemNotificationAuthorizationRequest:
        (UIApplication, @escaping (Bool) -> Void) -> Void = { _, resolved in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
                DispatchQueue.main.async {
                    UNUserNotificationCenter.current().getNotificationSettings { settings in
                        DispatchQueue.main.async { resolved(settings.authorizationStatus != .denied) }
                    }
                }
            }
        }

    override init() {
        // AppDelegate is constructed before the SwiftUI App initializer. Run
        // the synchronous migration here too so launch cannot interpret the
        // legacy Boolean before the required-iCloud authority is committed.
        _ = RequiredICloudMigration.migrate(
            defaults: .standard, legacyKey: DashboardViewModel.syncEnabledKey
        )
        clearBadge = { application in
            // `setBadgeCount` is the modern notification-center API, while
            // `applicationIconBadgeNumber` clears a stale badge left by an
            // earlier app version immediately. Both are needed because a
            // foreground transition can otherwise leave the SpringBoard
            // icon out of sync with UserNotifications' count.
            application.applicationIconBadgeNumber = 0
            UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
        }
        requestNotificationAuthorization = Self.systemNotificationAuthorizationRequest
        registerForRemoteNotifications = { application in
            application.registerForRemoteNotifications()
        }
        liveModeEnabled = {
            RequiredICloudMigration.migrate(
                defaults: .standard, legacyKey: DashboardViewModel.syncEnabledKey
            ).allowsLiveWork
        }
        super.init()
    }

    init(
        clearBadge: @escaping () -> Void,
        requestNotificationAuthorization: @escaping (UIApplication, @escaping (Bool) -> Void) -> Void = { _, _ in },
        liveModeEnabled: @escaping () -> Bool = { true },
        registerForRemoteNotifications: @escaping @MainActor (UIApplication) -> Void = { application in
            application.registerForRemoteNotifications()
        }
    ) {
        self.clearBadge = { _ in clearBadge() }
        self.requestNotificationAuthorization = requestNotificationAuthorization
        self.liveModeEnabled = liveModeEnabled
        self.registerForRemoteNotifications = registerForRemoteNotifications
        super.init()
    }

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // A fresh install starts live, but alert presentation is an explicit
        // Warning alerts choice and must not delay remote registration.
        guard liveModeEnabled() else { return true }
        beginLiveLifecycle(application)
        return true
    }

    /// Starts the live notification side of the app lifecycle after an
    /// explicit live-mode choice. Idempotent because launch and the sample
    /// exit transition can both reach this boundary.
    func beginLiveLifecycle() {
        beginLiveLifecycle(UIApplication.shared)
    }

    func beginLiveLifecycle(_ application: UIApplication) {
        guard !liveActivitySuppressed, !liveLifecycleStarted else { return }
        liveLifecycleStarted = true
        clearBadge(application)
        registerIfLive(application: application)
    }

    /// Kept as a compatibility seam for the sample transition. Alert consent
    /// is no longer part of live lifecycle quiescence, so this never waits.
    func awaitAuthorizationResolution() async {}

    /// Applies the current user-visible Warning alerts choice. Every request
    /// carries a generation, so a late system completion cannot restore an
    /// older choice after the user has tapped the control again.
    func setWarningAlertsEnabled(
        _ enabled: Bool,
        knownAuthorization: NotificationAuthorization? = nil,
        application: UIApplication? = nil
    ) {
        let application = application ?? UIApplication.shared
        warningAlertIntentGeneration &+= 1
        let generation = warningAlertIntentGeneration
        warningAlertsEnabled = enabled
        guard enabled else {
            warningAlertAuthorization = .off
            return
        }
        if let knownAuthorization {
            warningAlertAuthorization = knownAuthorization
        }

        switch warningAlertAuthorization {
        case .authorized, .denied, .requesting:
            return
        case .off, .notDetermined:
            warningAlertAuthorization = .requesting
        }

        requestNotificationAuthorization(application) { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self,
                      warningAlertIntentGeneration == generation,
                      warningAlertsEnabled
                else { return }
                warningAlertAuthorization = granted ? .authorized : .denied
                onAuthorizationResolved?()
            }
        }
    }

    /// Keeps the delegate's recovery state synchronized with the authoritative
    /// `notificationSettings()` read performed by the view model.
    func updateWarningAlertAuthorization(_ authorization: NotificationAuthorization) {
        guard warningAlertsEnabled else {
            warningAlertAuthorization = .off
            return
        }
        guard warningAlertAuthorization != .requesting else { return }
        warningAlertAuthorization = authorization
    }

    private func registerIfLive(application: UIApplication) {
        guard !liveActivitySuppressed, !remoteRegistrationStarted else { return }
        remoteRegistrationStarted = true
        remoteRegistrationFailed = false
        registerForRemoteNotifications(application)
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        guard !liveActivitySuppressed else { return }
        clearBadge(application)
        if remoteRegistrationFailed {
            registerIfLive(application: application)
        }
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        guard !liveActivitySuppressed else { return }
        clearBadge(application)
    }

    func application(_: UIApplication, didReceiveRemoteNotification _: [AnyHashable: Any]) async
        -> UIBackgroundFetchResult {
        await handleRemoteNotificationOnMainActor()
    }

    private func handleRemoteNotificationOnMainActor() async -> UIBackgroundFetchResult {
        guard !liveActivitySuppressed else { return .noData }
        await onRemoteNotification?()
        return .newData
    }

    func application(_: UIApplication, didFailToRegisterForRemoteNotificationsWithError _: Error) {
        // Keep the error non-sensitive. Foreground entry retries once per
        // lifecycle opportunity; on-demand sync remains available meanwhile.
        remoteRegistrationStarted = false
        remoteRegistrationFailed = true
        onRemoteRegistrationFailure?()
    }
}
