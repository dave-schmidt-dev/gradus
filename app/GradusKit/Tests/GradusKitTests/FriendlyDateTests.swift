import Foundation
import Testing

@testable import GradusKit

private var easternCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: -4 * 60 * 60)!
    return calendar
}

private let fixedNow = ISO8601DateFormatter().date(from: "2026-08-04T20:00:00-04:00")!

@Test func friendlyResetDateUsesTodayAndTomorrowLabels() {
    let calendar = easternCalendar

    #expect(
        friendlyResetDate("2026-08-04T22:00:00-04:00", now: fixedNow, calendar: calendar)
            == "Today 10:00 PM"
    )
    #expect(
        friendlyResetDate("2026-08-05T07:30:00-04:00", now: fixedNow, calendar: calendar)
            == "Tomorrow 7:30 AM"
    )
}

@Test func friendlyResetDateUsesWeekdayAndDateForLaterResets() {
    let calendar = easternCalendar

    #expect(
        friendlyResetDate("2026-08-07T09:15:00-04:00", now: fixedNow, calendar: calendar)
            == "Fri 9:15 AM"
    )
    #expect(
        friendlyResetDate("2026-08-12T09:15:00-04:00", now: fixedNow, calendar: calendar)
            == "Aug 12, 9:15 AM"
    )
}

@Test func friendlyResetDatePreservesMalformedAndMissingValues() {
    let calendar = easternCalendar

    #expect(friendlyResetDate(nil, now: fixedNow, calendar: calendar) == nil)
    #expect(
        friendlyResetDate("not-a-date", now: fixedNow, calendar: calendar) == "not-a-date"
    )
}
