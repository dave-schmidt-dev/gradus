import Foundation
import GradusKit
@testable import GradusMac
import Testing

// MARK: - Snapshot data validation

private func allProducerKeysData() -> [String: JSONValue] {
    [
        "credits": .double(42),
        "five_hour_percent_left": .double(80),
        "weekly_percent_left": .double(90),
        "five_hour_reset": .string("in 2h"),
        "weekly_reset": .string("in 5d"),
        "session_percent_left": .double(70),
        "opus_percent_left": .double(60),
        "primary_reset": .string("2026-09-01T00:00:00Z"),
        "secondary_reset": .string("2026-09-02T00:00:00Z"),
        "opus_reset": .string("2026-09-03T00:00:00Z"),
        "usage_percent": .double(10),
        "reset_at": .string("2026-09-04T00:00:00Z"),
        "payg_enabled": .bool(true),
        "start_date": .string("2026-08-01T00:00:00Z"),
        "end_date": .string("2026-09-01T00:00:00Z"),
        "monthly_percent_left": .double(50),
        "monthly_reset": .string("in 20d"),
        "auto_percent_used": .double(20),
        "api_percent_used": .double(30),
        "billing_cycle_start": .string("2026-08-01T00:00:00Z"),
        "billing_cycle_end": .string("2026-09-01T00:00:00Z"),
        "billing_cycle_end_iso": .string("2026-09-01T00:00:00Z"),
        "premium_percent_left": .double(40),
        "premium_reset": .string("in 10d")
    ]
}

private func expectedProducerKeys() -> Set<String> {
    [
        "credits",
        "five_hour_percent_left",
        "weekly_percent_left",
        "five_hour_reset",
        "weekly_reset",
        "session_percent_left",
        "opus_percent_left",
        "primary_reset",
        "secondary_reset",
        "opus_reset",
        "usage_percent",
        "reset_at",
        "payg_enabled",
        "start_date",
        "end_date",
        "monthly_percent_left",
        "monthly_reset",
        "auto_percent_used",
        "api_percent_used",
        "billing_cycle_start",
        "billing_cycle_end",
        "billing_cycle_end_iso",
        "premium_percent_left",
        "premium_reset"
    ]
}

@Test func snapshotDataValidationAcceptsExactProducerKeys() throws {
    let data = allProducerKeysData()

    #expect(data.count == 24)
    #expect(Set(data.keys) == expectedProducerKeys())
    #expect(try validatedSnapshotData(data) == data)
}

@Test func snapshotDataValidationRejectsUnknownKeysAndOversizedValues() {
    #expect(throws: SnapshotDataValidationError.unsupportedKey("unexpected")) {
        try validatedSnapshotData(["unexpected": .string("value")])
    }
    #expect(throws: SnapshotDataValidationError.valueTooLarge("credits")) {
        try validatedSnapshotData(["credits": .string(String(repeating: "x", count: 4097))])
    }
    let entry = ProviderEntry(
        name: "Codex", ok: false, error: String(repeating: "x", count: 4097),
        windows: [], data: [:], observedAt: nil
    )
    #expect(throws: SnapshotDataValidationError.errorMessageTooLarge) {
        try makeProviderStatus(from: entry, snapshotUpdatedAt: "2026-08-02T20:05:00-04:00", publishedAt: Date())
    }
}

@Test func snapshotDataValidationRejectsNonFiniteNumbersAndOversizedAggregate() {
    #expect(throws: SnapshotDataValidationError.nonFiniteNumber("credits")) {
        try validatedSnapshotData(["credits": .double(.infinity)])
    }
    let data = Dictionary(uniqueKeysWithValues: [
        "credits", "five_hour_reset", "weekly_reset", "primary_reset",
        "secondary_reset", "opus_reset", "reset_at", "start_date", "end_date"
    ].map { ($0, JSONValue.string(String(repeating: "x", count: 4000))) })
    #expect(throws: SnapshotDataValidationError.aggregateTooLarge) {
        try validatedSnapshotData(data)
    }
}
