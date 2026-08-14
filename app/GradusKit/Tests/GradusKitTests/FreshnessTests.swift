import Foundation
@testable import GradusKit
import Testing

@Test func nilObservedAtIsUnknown() {
    #expect(freshness(observedAt: nil, now: Date()) == .unknown)
}

@Test func malformedObservedAtIsUnknown() {
    #expect(freshness(observedAt: "not-a-date", now: Date()) == .unknown)
}

@Test func recentObservationIsFresh() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let observedAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
    #expect(freshness(observedAt: observedAt, now: now) == .fresh)
}

@Test func exactlyAtThresholdIsStale() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let observedAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(-staleThresholdSeconds))
    #expect(freshness(observedAt: observedAt, now: now) == .stale(ageDisplay: "3m"))
}

@Test func staleBucketsMinutesAndHours() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    let fifteenMinutesAgo = ISO8601DateFormatter().string(from: now.addingTimeInterval(-15 * 60))
    #expect(freshness(observedAt: fifteenMinutesAgo, now: now) == .stale(ageDisplay: "15m"))

    let twoHoursAgo = ISO8601DateFormatter().string(from: now.addingTimeInterval(-2 * 3600))
    #expect(freshness(observedAt: twoHoursAgo, now: now) == .stale(ageDisplay: "2h"))
}

@Test func fractionalSecondsObservedAtParses() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let observedAt = formatter.string(from: now.addingTimeInterval(-600))
    #expect(freshness(observedAt: observedAt, now: now) == .stale(ageDisplay: "10m"))
}
