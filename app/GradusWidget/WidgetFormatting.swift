import Foundation
import GradusKit

enum WidgetFormatting {
    static func percent(_ percentLeft: Double?) -> String {
        percentDisplay(percentLeft)
    }

    static func reset(
        _ resetDate: Date?,
        locale: Locale = Locale(identifier: "en_US_POSIX"),
        timeZone: TimeZone = .current,
        calendar: Calendar = .current
    ) -> String? {
        guard let resetDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("MMMdjm")
        return "resets \(formatter.string(from: resetDate))"
    }

    static func accessibilityLabel(
        snapshot: WidgetSnapshot,
        locale: Locale = Locale(identifier: "en_US_POSIX"),
        timeZone: TimeZone = .current,
        calendar: Calendar = .current
    ) -> String {
        guard snapshot.status != .error, let window = snapshot.selectedWindow else {
            return "\(snapshot.providerDisplayName), usage unavailable"
        }
        var parts = [
            snapshot.providerDisplayName,
            window.label,
            percentDisplay(window.percentLeft, suffix: " percent remaining")
        ]
        if let reset = reset(window.resetDate, locale: locale, timeZone: timeZone, calendar: calendar) {
            parts.append(reset)
        }
        return parts.joined(separator: ", ")
    }
}
