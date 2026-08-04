import UIKit
import UserNotifications

/// Bridges UIKit's remote-notification delegate callbacks (T4.1/T4.2) into
/// the SwiftUI app -- SwiftUI's `App` protocol has no equivalent hook, so
/// this is wired in via `@UIApplicationDelegateAdaptor`. Both subscriptions
/// deliver through this same content-available path; the app-side sync
/// decides whether a warning transition warrants a local notification.
final class AppDelegate: NSObject, UIApplicationDelegate {
    var onRemoteNotification: (() async -> Void)?

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
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
