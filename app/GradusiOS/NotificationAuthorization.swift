import Foundation
import UserNotifications

/// Whether the *system* will display this app's notifications.
///
/// Distinct from `DashboardViewModel.notificationsEnabled`, and the distinction
/// is the whole point of this type. `notificationsEnabled` is our own opt-in: it
/// governs the `CKQuerySubscription` that produces a warning push at all. This
/// governs whether iOS is willing to show one once it arrives. Either can be off
/// while the other is on, and only one of them is ours to change.
///
/// Collapses `UNAuthorizationStatus`' five cases to the three the UI can act on.
/// `.provisional` and `.ephemeral` both deliver (quietly, and for App Clips
/// respectively), so they read as `authorized` -- treating them as denied would
/// show a "notifications are off" warning to someone who is receiving them.
public enum NotificationAuthorization: Equatable, Sendable {
    /// The user-visible Warning alerts control is off. This is not a system
    /// denial and does not affect remote registration or CloudKit sync.
    case off
    /// Authorization has not been requested yet. The app requests it only
    /// after the user explicitly turns on Warning alerts.
    case notDetermined
    /// A system permission request is currently displayed.
    case requesting
    /// The user declined, or turned the app's notifications off in iOS
    /// Settings. Warnings are scheduled and silently dropped.
    case denied
    case authorized

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .denied: self = .denied
        case .authorized, .provisional, .ephemeral: self = .authorized
        case .notDetermined: self = .notDetermined
        @unknown default:
            // A future case is more likely to be a delivering one than a
            // denial, and the cost of guessing wrong is asymmetric: a false
            // `.denied` tells the user their notifications are broken when
            // they are not, and sends them to Settings to "fix" a working app.
            self = .authorized
        }
    }
}

/// Reads the system authorization state. A protocol for the same reason
/// `WarningNotificationScheduling` is one: `UNUserNotificationCenter` has no
/// injectable state, so a test that wanted to exercise the denied path would
/// otherwise have to change the simulator's own notification settings.
public protocol NotificationAuthorizationSource: Sendable {
    func currentAuthorization() async -> NotificationAuthorization
}

/// Production source. Reads `notificationSettings()` rather than caching the
/// `Bool` that `requestAuthorization` hands back at first launch, because the
/// user can revoke permission from iOS Settings at any point afterwards --
/// which is the case this whole type exists to catch, and the one a cached
/// launch-time answer would always get wrong.
public struct SystemNotificationAuthorizationSource: NotificationAuthorizationSource {
    public init() {}

    public func currentAuthorization() async -> NotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return NotificationAuthorization(settings.authorizationStatus)
    }
}
