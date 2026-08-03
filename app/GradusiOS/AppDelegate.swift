import UIKit

/// Bridges UIKit's remote-notification delegate callbacks (T4.1/T4.2) into
/// the SwiftUI app -- SwiftUI's `App` protocol has no equivalent hook, so
/// this is wired in via `@UIApplicationDelegateAdaptor`. Both subscriptions
/// (zone-sync `content-available` and the warning `CKQuerySubscription`
/// banner) deliver through this same silent-push path; `onRemoteNotification`
/// always resolves to the same delta sync regardless of which subscription
/// fired, since a fetch picks up whatever changed either way (including the
/// `isWarning` flip that triggered a query notification -- the system
/// banner itself is shown by CloudKit's own alert delivery, not custom code
/// here).
final class AppDelegate: NSObject, UIApplicationDelegate {
    var onRemoteNotification: (() async -> Void)?

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async
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
