import Foundation
import GradusKit
@testable import GradusMac
import Testing

// MARK: - Snapshot data validation

private func allProducerKeysData() -> [String: JSONValue] {
    [
        "credits": .double(42),
        "credit_balance": .double(87.75),
        "zen_credit": .double(12.345),
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
        "credit_balance",
        "zen_credit",
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

    #expect(data.count == 26)
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

private func bankedFixture(
    count: Int = 3, snapshotAt: String = "2026-08-02T20:05:00-04:00"
) throws -> BankedObservation {
    let json = """
    {"schema_version":1,"count":\(count),"generation":"01234567-89ab-4cde-8f01-23456789abcd",\
    "snapshot_updated_at":"\(snapshotAt)","observed_at":"2026-08-02T20:00:00-04:00"}
    """
    return try #require(BankedObservation.parse(Data(json.utf8)))
}

@Test func bankedAugmentationRequiresValidatedCodexEvidence() throws {
    let banked = try bankedFixture()
    let raw: [String: JSONValue] = ["credits": .double(42)]
    let augmented = try validatedAugmentedSnapshotData(raw, bankedObservation: banked)
    #expect(augmented["credits"] == .double(42))
    #expect(augmented["banked_reset_count"] == .double(3))
    #expect(augmented["banked_reset_generation"] == .string(banked.generation))
    #expect(augmented["banked_reset_observed_at"] == .string(banked.observedAt))
    #expect(BankedResetEvidence(data: augmented)?.count == 3)
    do {
        _ = try validatedSnapshotData(augmented)
        Issue.record("Expected raw producer allowlist to reject banked data")
    } catch let error as SnapshotDataValidationError {
        guard case let .unsupportedKey(key) = error else {
            Issue.record("Expected an unsupported banked key")
            return
        }
        #expect(Set([
            "banked_reset_count", "banked_reset_generation", "banked_reset_observed_at"
        ]).contains(key))
    }
    #expect(throws: SnapshotDataValidationError.unsupportedKey("unexpected")) {
        try validatedAugmentedSnapshotData(["unexpected": .double(1)], bankedObservation: banked)
    }
}

@Test func bankedAugmentationRejectsMalformedTriples() {
    let valid: [String: JSONValue] = [
        "banked_reset_count": .double(2),
        "banked_reset_generation": .string("01234567-89ab-4cde-8f01-23456789abcd"),
        "banked_reset_observed_at": .string("2026-08-02T20:00:00-04:00")
    ]
    #expect(BankedResetEvidence(data: valid) != nil)
    for badCount in [-1.0, 1.5, 1_000_001.0, Double.infinity] {
        var bad = valid
        bad["banked_reset_count"] = .double(badCount)
        #expect(BankedResetEvidence(data: bad) == nil)
    }
    var bad = valid
    bad["banked_reset_generation"] = .string("01234567-89AB-4CDE-8F01-23456789ABCD")
    #expect(BankedResetEvidence(data: bad) == nil)
    bad = valid
    bad["banked_reset_observed_at"] = .string("2026-08-02T20:00:00")
    #expect(BankedResetEvidence(data: bad) == nil)
}

@Test func repeatedOversizeBankedFallbackHasStableContentHash() throws {
    let banked = try bankedFixture()
    let keys = [
        "credits", "five_hour_reset", "weekly_reset", "primary_reset",
        "secondary_reset", "opus_reset", "reset_at", "start_date"
    ]
    let raw = Dictionary(uniqueKeysWithValues: keys.map {
        ($0, JSONValue.string(String(repeating: "x", count: 4070)))
    })
    #expect(try validatedSnapshotData(raw) == raw)
    #expect(try validatedAugmentedSnapshotData(raw, bankedObservation: banked) == raw)
    let entry = ProviderEntry(
        name: "Codex", ok: true, error: nil, windows: [], data: raw,
        observedAt: "2026-08-02T20:00:00-04:00"
    )
    let first = try makeProviderStatus(
        from: entry, snapshotUpdatedAt: "2026-08-02T20:05:00-04:00",
        publishedAt: Date(timeIntervalSince1970: 100), bankedObservation: banked
    )
    let second = try makeProviderStatus(
        from: entry, snapshotUpdatedAt: "2026-08-02T20:07:00-04:00",
        publishedAt: Date(timeIntervalSince1970: 200),
        bankedObservation: bankedFixture(snapshotAt: "2026-08-02T20:07:00-04:00")
    )
    #expect(first.data == raw)
    #expect(PublishCoordinator.contentHash(for: first) == PublishCoordinator.contentHash(for: second))
}

@Test func mismatchedBankedSidecarDoesNotAugmentRawStatus() throws {
    let banked = try bankedFixture()
    let entry = ProviderEntry(
        name: "Codex", ok: true, error: nil, windows: [], data: [:],
        observedAt: "2026-08-02T20:01:00-04:00"
    )
    let mapped = try makeProviderStatus(
        from: entry, snapshotUpdatedAt: banked.snapshotUpdatedAt,
        publishedAt: Date(), bankedObservation: banked
    )
    #expect(mapped.data.isEmpty)
}
