import UIKit
import UserNotifications

/// Bridges UIKit's remote-notification delegate callbacks (T4.1/T4.2) into
/// the SwiftUI app -- SwiftUI's `App` protocol has no equivalent hook, so
/// this is wired in via `@UIApplicationDelegateAdaptor`. Both subscriptions
/// deliver through this same content-available path; the app-side sync
/// decides whether a warning transition warrants a local notification.
final class AppDelegate: NSObject, UIApplicationDelegate {
    var onRemoteNotification: (() async -> Void)?

    private let clearBadge: (UIApplication) -> Void

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
        super.init()
    }

    init(clearBadge: @escaping () -> Void) {
        self.clearBadge = { _ in clearBadge() }
        super.init()
    }

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        clearBadge(application)
        // The app-side warning notification is visible only after this local
        // authorization succeeds. Both CloudKit subscriptions are silent
        // content-available pushes and never display alerts themselves.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        }
        return true
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        clearBadge(application)
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        clearBadge(application)
    }

    nonisolated func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
        -> UIBackgroundFetchResult
    {
        await onRemoteNotification?()
        return .newData
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // No device token this session -- push-driven sync/alerts won't
        // fire, but the opt-in toggle's on-demand `sync()` still works.
    }
}
