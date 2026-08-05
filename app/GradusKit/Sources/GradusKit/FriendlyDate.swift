import Foundation

/// Turns an ISO-8601 reset timestamp into compact local-time UI copy.
/// Invalid values are returned unchanged so a malformed provider payload is
/// visible rather than silently replaced with a fabricated date.
public func friendlyResetDate(
    _ resetISO: String?,
    now: Date = Date(),
    calendar: Calendar = .current
) -> String? {
    guard let resetISO else { return nil }
    guard let date = parseISO8601Date(resetISO) else { return resetISO }
    return friendlyDateLabel(date, now: now, calendar: calendar)
}

/// Formats a date using the same compact day/time copy used for reset
/// timestamps. This is also used for the connected-Mac publish timestamp.
public func friendlyDateLabel(
    _ date: Date,
    now: Date = Date(),
    calendar: Calendar = .current
) -> String {
    let dayOffset = calendar.dateComponents(
        [.day],
        from: calendar.startOfDay(for: now),
        to: calendar.startOfDay(for: date)
    ).day

    if dayOffset == 0 {
        return format(date, as: "'Today' h:mm a", calendar: calendar)
    }
    if dayOffset == 1 {
        return format(date, as: "'Tomorrow' h:mm a", calendar: calendar)
    }
    if let dayOffset, (2...6).contains(dayOffset) {
        return format(date, as: "EEE h:mm a", calendar: calendar)
    }
    return format(date, as: "MMM d, h:mm a", calendar: calendar)
}

private func parseISO8601Date(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}

private func format(_ date: Date, as pattern: String, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = pattern
    return formatter.string(from: date)
}
