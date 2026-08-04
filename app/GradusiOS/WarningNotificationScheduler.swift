import Foundation
import GradusKit
import UserNotifications

/// Schedules the one app-visible notification emitted for a provider's
/// false/missing -> true warning transition. Transition detection belongs to
/// `DashboardViewModel`; this seam keeps UserNotifications out of sync tests.
@MainActor
public protocol WarningNotificationScheduling {
    func scheduleWarningNotification(for provider: ProviderStatus)
}

/// Production scheduler for warning notifications. Each request gets a new
/// identifier so a later warning episode is allowed after the provider clears.
@MainActor
public final class LocalWarningNotificationScheduler: WarningNotificationScheduling {
    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func scheduleWarningNotification(for provider: ProviderStatus) {
        let content = UNMutableNotificationContent()
        content.title = "Gradus"
        content.body = String(
            format: NSLocalizedString("WARN_FMT", comment: "Local warning notification"),
            provider.providerDisplayName)
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "gradus-warning-\(UUID().uuidString)", content: content, trigger: nil)
        center.add(request)
    }
}
