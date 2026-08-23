import Foundation
import GradusKit

enum WidgetFormatting {
    static func percent(_ percentLeft: Double) -> String {
        "\(Int(max(0, min(100, percentLeft)).rounded(.down)))%"
    }

    static func syncedAge(from syncDate: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(syncDate))
        if seconds < 60 {
            return "synced <1m ago"
        }
        let minutes = Int(seconds / 60)
        if minutes < 60 {
            return "synced \(minutes)m ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "synced \(hours)h ago"
        }
        return "synced \(hours / 24)d ago"
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
        formatter.dateFormat = "MMM d, h:mm a"
        return "resets \(formatter.string(from: resetDate))"
    }

    static func accessibilityLabel(
        snapshot: WidgetSnapshot,
        now: Date,
        locale: Locale = Locale(identifier: "en_US_POSIX"),
        timeZone: TimeZone = .current,
        calendar: Calendar = .current
    ) -> String {
        guard let window = snapshot.selectedWindow else {
            let age = syncedAge(from: snapshot.phoneSyncDate, now: now)
            return "\(snapshot.providerDisplayName), usage unavailable, \(age)"
        }
        var parts = [
            snapshot.providerDisplayName,
            window.label,
            "\(percent(window.percentLeft)) remaining"
        ]
        if let reset = reset(window.resetDate, locale: locale, timeZone: timeZone, calendar: calendar) {
            parts.append(reset)
        }
        parts.append(syncedAge(from: snapshot.phoneSyncDate, now: now))
        return parts.joined(separator: ", ")
    }
}
