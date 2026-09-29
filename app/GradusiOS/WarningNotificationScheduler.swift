import Foundation
import GradusKit
import UserNotifications

/// Schedules the one app-visible notification emitted for a provider's
/// false/missing -> true warning transition. Transition detection belongs to
/// `DashboardViewModel`; this seam keeps UserNotifications out of sync tests.
@MainActor
public protocol WarningNotificationScheduling {
    func scheduleWarningNotification(for provider: ProviderStatus, thresholdPercent: Double)
}

struct WarningNotificationContent: Equatable {
    let title: String
    let body: String

    static func make(for provider: ProviderStatus, thresholdPercent: Double) -> Self? {
        let validWindows = provider.windows.filter { percentIsValid($0.percentLeft) }
        guard let window = validWindows
            .filter({ windowWarns($0) || localIsUrgent($0, threshold: thresholdPercent) })
            .min(by: Self.windowOrdering)
        else {
            return Self(
                title: String(
                    format: NSLocalizedString(
                        "WARN_PROVIDER_TITLE_FMT", value: "%@ warning",
                        comment: "Provider-level local warning notification title"
                    ),
                    provider.providerDisplayName
                ),
                body: NSLocalizedString(
                    "WARN_PROVIDER_BODY", value: "A provider warning was reported. Open Gradus for details.",
                    comment: "Provider-level local warning notification body"
                )
            )
        }

        let windowLabel = ProviderWindowLabel.label(for: window.id)
        let remaining = percentageText(window.percentLeft)
        return Self(
            title: String(
                format: NSLocalizedString(
                    "WARN_TITLE_FMT", value: "%@ %@ warning", comment: "Local warning notification title"
                ),
                provider.providerDisplayName, windowLabel
            ),
            body: String(
                format: NSLocalizedString(
                    "WARN_BODY_PACE_FMT", value: "%@, %@%% remaining.",
                    comment: "Local warning notification body: pace label, then percent remaining"
                ),
                paceLabel(for: window), remaining
            )
        )
    }

    /// Most behind pace first; a window with no pace sorts after every window
    /// that has one, then by least remaining.
    private static func windowOrdering(_ lhs: ProviderWindow, _ rhs: ProviderWindow) -> Bool {
        let lhsPace = lhs.paceDelta.flatMap { $0.isFinite ? $0 : nil }
        let rhsPace = rhs.paceDelta.flatMap { $0.isFinite ? $0 : nil }
        if lhsPace != rhsPace {
            guard let lhsPace else { return false }
            guard let rhsPace else { return true }
            return lhsPace < rhsPace
        }
        if lhs.percentLeft != rhs.percentLeft {
            return lhs.percentLeft < rhs.percentLeft
        }
        return lhs.id < rhs.id
    }

    private static func percentageText(_ value: Double) -> String {
        guard value.rounded() != value else { return String(Int(value)) }
        var text = String(format: "%.2f", value)
        while text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text
    }
}

/// Production scheduler for warning notifications. Each request gets a new
/// identifier so a later warning episode is allowed after the provider clears.
@MainActor
public final class LocalWarningNotificationScheduler: WarningNotificationScheduling {
    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func scheduleWarningNotification(for provider: ProviderStatus, thresholdPercent: Double) {
        guard let notification = WarningNotificationContent.make(
            for: provider, thresholdPercent: thresholdPercent
        ) else { return }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "gradus-warning-\(UUID().uuidString)", content: content, trigger: nil
        )
        center.add(request)
    }
}
