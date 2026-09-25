import Foundation
import GradusKit
import UserNotifications

/// A local delivery seam. The detector and preferences run in unit tests,
/// while fixtures use no scheduler and never touch UserNotifications.
@MainActor
public protocol ResetNotificationScheduling {
    func scheduleResetNotification(_ alert: ResetAlert)
}

struct ResetNotificationContent: Equatable {
    let title: String
    let body: String

    static func make(for alert: ResetAlert) -> Self {
        switch alert {
        case let .bankedGrant(increase, currentCount):
            return Self(
                title: "New banked resets",
                body: "Codex added \(increase) banked reset\(increase == 1 ? "" : "s"). \(currentCount) available."
            )
        case let .usageRefill(providerName, windowID):
            let window = ProviderWindowLabel.label(for: windowID)
            return Self(title: "Usage refilled", body: "\(providerName) \(window) usage is available again.")
        }
    }
}

@MainActor
public final class LocalResetNotificationScheduler: ResetNotificationScheduling {
    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func scheduleResetNotification(_ alert: ResetAlert) {
        let notification = ResetNotificationContent.make(for: alert)
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        center.add(UNNotificationRequest(
            identifier: "gradus-reset-\(UUID().uuidString)", content: content, trigger: nil
        ))
    }
}
