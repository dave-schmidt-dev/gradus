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

    private let clearBadge: (UIApplication) -> Void
    private let liveModeEnabled: () -> Bool
    private let registerForRemoteNotifications: @MainActor (UIApplication) -> Void

    /// Requests notification authorization and calls back once the prompt has
    /// been answered. Injected so the launch path can be exercised in a unit
    /// test without a real prompt (which no test can answer) and without a
    /// real APNs registration attempt.
    private let requestNotificationAuthorization: (UIApplication, @escaping () -> Void) -> Void
    private var notificationAuthorizationStarted = false
    private var authorizationRequestResolved = false
    private var remoteRegistrationStarted = false
    private var authorizationResolutionWaiters: [CheckedContinuation<Void, Never>] = []

    private static let systemNotificationAuthorizationRequest: (UIApplication, @escaping () -> Void) -> Void = {
        application, resolved in
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            DispatchQueue.main.async {
                resolved()
            }
        }
    }

    override init() {
        self.clearBadge = { application in
            // `setBadgeCount` is the modern notification-center API, while
            // `applicationIconBadgeNumber` clears a stale badge left by an
            // earlier app version immediately. Both are needed because a
            // foreground transition can otherwise leave the SpringBoard
            // icon out of sync with UserNotifications' count.
            application.applicationIconBadgeNumber = 0
            UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
        }
        self.requestNotificationAuthorization = Self.systemNotificationAuthorizationRequest
        self.registerForRemoteNotifications = { application in
            application.registerForRemoteNotifications()
        }
        self.liveModeEnabled = {
            UserDefaults.standard.bool(forKey: DashboardViewModel.syncEnabledKey)
        }
        super.init()
    }

    init(
        clearBadge: @escaping () -> Void,
        requestNotificationAuthorization: @escaping (UIApplication, @escaping () -> Void) -> Void = { _, _ in },
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
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // A fresh install starts with sync disabled. Defer all notification
        // prompting/registration until the user explicitly enables live mode;
        // an existing opt-in keeps the prior launch behavior.
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
        guard !liveActivitySuppressed, !notificationAuthorizationStarted else { return }
        notificationAuthorizationStarted = true
        clearBadge(application)
        // The app-side warning notification is visible only after this local
        // authorization succeeds. Both CloudKit subscriptions are silent
        // content-available pushes and never display alerts themselves.
        requestNotificationAuthorization(application) { [weak self] in
            // Read the closure at call time rather than capturing it: the
            // prompt resolves long after launch, and the SwiftUI `App`'s
            // init is what assigns this.
            Task { @MainActor [weak self] in
                self?.resolveAuthorizationRequest(application)
            }
        }
    }

    /// Waits for the authorization request started by `beginLiveLifecycle()`.
    /// Keeping this pending until the callback returns makes notification
    /// authorization and APNs registration part of the same quiescence
    /// boundary as CloudKit work during sample entry.
    func awaitAuthorizationResolution() async {
        guard notificationAuthorizationStarted, !authorizationRequestResolved else {
            if authorizationRequestResolved { registerIfLive(application: .shared) }
            return
        }
        await withCheckedContinuation { continuation in
            authorizationResolutionWaiters.append(continuation)
        }
    }

    private func resolveAuthorizationRequest(_ application: UIApplication) {
        guard !authorizationRequestResolved else { return }
        authorizationRequestResolved = true
        registerIfLive(application: application)
        let waiters = authorizationResolutionWaiters
        authorizationResolutionWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func registerIfLive(application: UIApplication) {
        guard !liveActivitySuppressed, !remoteRegistrationStarted else { return }
        remoteRegistrationStarted = true
        registerForRemoteNotifications(application)
        onAuthorizationResolved?()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        guard !liveActivitySuppressed else { return }
        clearBadge(application)
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        guard !liveActivitySuppressed else { return }
        clearBadge(application)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
        -> UIBackgroundFetchResult
    {
        await handleRemoteNotificationOnMainActor()
    }

    private func handleRemoteNotificationOnMainActor() async -> UIBackgroundFetchResult {
        guard !liveActivitySuppressed else { return .noData }
        await onRemoteNotification?()
        return .newData
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No device token this session -- push-driven sync/alerts won't
        // fire, but the opt-in toggle's on-demand `sync()` still works.
    }
}
