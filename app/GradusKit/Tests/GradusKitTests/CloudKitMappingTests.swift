import CloudKit
import Foundation
@testable import GradusKit
import Testing

private let zoneID = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)

private func sampleStatus(
    ok: Bool = true,
    windows: [ProviderWindow] = [
        ProviderWindow(id: "weekly", percentLeft: 58.0, resetISO: nil, windowHours: 168.0, paceDelta: -0.2)
    ],
    syncSource: SyncSource? = SyncSource(computerName: "Dave's MacBook Pro", userName: "dave")
) -> ProviderStatus {
    ProviderStatus(
        providerName: "Codex",
        providerDisplayName: "Codex",
        ok: ok,
        errorMessage: ok ? nil : "rate limited",
        windows: windows,
        data: ["weekly_percent_left": .double(58.0)],
        observedAt: "2026-08-02T20:00:00-04:00",
        snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
        publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        syncSource: syncSource
    )
}

@Test func roundTripsThroughCKRecord() throws {
    let original = sampleStatus()
    let record = try original.toCKRecord(zoneID: zoneID)
    #expect(record.recordType == CloudKitConstants.recordType)
    #expect(record.recordID.recordName == "Codex")
    #expect(record["sourceComputerName"] as? String == "Dave's MacBook Pro")
    #expect(record["sourceUserName"] as? String == "dave")

    let decoded = try ProviderStatus(record: record)
    #expect(decoded == original)
}

@Test func roundTripsClaudeRateLimitWithoutPromotingRouterFailure() throws {
    let windows = [
        ProviderWindow(id: "five_hour", percentLeft: 42.0, resetISO: nil, windowHours: 5.0, paceDelta: nil),
        ProviderWindow(id: "weekly", percentLeft: 76.0, resetISO: nil, windowHours: 168.0, paceDelta: nil)
    ]
    let original = ProviderStatus(
        providerName: "Claude",
        providerDisplayName: "Claude",
        ok: false,
        errorMessage: "HTTP 429 Too Many Requests",
        windows: windows,
        data: [:],
        observedAt: "2026-08-17T18:00:00Z",
        snapshotUpdatedAt: "2026-08-17T18:00:00Z",
        publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        isWarning: false,
        isDepleted: false
    )

    let decoded = try ProviderStatus(record: original.toCKRecord(zoneID: zoneID))
    #expect(decoded.ok == false)
    #expect(decoded.errorMessage == "HTTP 429 Too Many Requests")
    #expect(decoded.windows == windows)
}

@Test func omitsSyncSourceKeysWhenSyncSourceIsNil() throws {
    let record = try sampleStatus(syncSource: nil).toCKRecord(zoneID: zoneID)

    #expect(record["sourceComputerName"] == nil)
    #expect(record["sourceUserName"] == nil)
    #expect(try ProviderStatus(record: record).syncSource == nil)
}

@Test func decodesLegacyRecordWithoutSyncSource() throws {
    let record = CKRecord(
        recordType: CloudKitConstants.recordType,
        recordID: CKRecord.ID(recordName: "Codex", zoneID: zoneID)
    )
    record["providerName"] = "Codex" as CKRecordValue
    record["providerDisplayName"] = "Codex" as CKRecordValue
    record["ok"] = NSNumber(value: true)
    record["snapshotUpdatedAt"] = "2026-08-02T20:00:00-04:00" as CKRecordValue
    record["publishedAt"] = Date(timeIntervalSince1970: 1_700_000_000) as CKRecordValue

    #expect(try ProviderStatus(record: record).syncSource == nil)
}

@Test func ignoresPartialSyncSourceMetadata() throws {
    let record = CKRecord(
        recordType: CloudKitConstants.recordType,
        recordID: CKRecord.ID(recordName: "Codex", zoneID: zoneID)
    )
    record["providerName"] = "Codex" as CKRecordValue
    record["ok"] = NSNumber(value: true)
    record["snapshotUpdatedAt"] = "2026-08-02T20:00:00-04:00" as CKRecordValue
    record["publishedAt"] = Date(timeIntervalSince1970: 1_700_000_000) as CKRecordValue
    record["sourceComputerName"] = "Dave's MacBook Pro" as CKRecordValue

    #expect(try ProviderStatus(record: record).syncSource == nil)
}

@Test func ignoresPartialSyncSourceMetadataWhenComputerNameIsMissing() throws {
    let record = CKRecord(
        recordType: CloudKitConstants.recordType,
        recordID: CKRecord.ID(recordName: "Codex", zoneID: zoneID)
    )
    record["providerName"] = "Codex" as CKRecordValue
    record["ok"] = NSNumber(value: true)
    record["snapshotUpdatedAt"] = "2026-08-02T20:00:00-04:00" as CKRecordValue
    record["publishedAt"] = Date(timeIntervalSince1970: 1_700_000_000) as CKRecordValue
    record["sourceUserName"] = "dave" as CKRecordValue

    #expect(try ProviderStatus(record: record).syncSource == nil)
}

@Test func derivesIsWarningFromWindowsWhenNotExplicitlySet() {
    let depleted = sampleStatus(
        windows: [ProviderWindow(id: "weekly", percentLeft: 0.0, resetISO: nil, windowHours: nil, paceDelta: nil)]
    )
    #expect(depleted.isWarning == true)
    #expect(depleted.isDepleted == true)

    let healthy = sampleStatus(
        windows: [ProviderWindow(id: "weekly", percentLeft: 80.0, resetISO: nil, windowHours: nil, paceDelta: 0.1)]
    )
    #expect(healthy.isWarning == false)
    #expect(healthy.isDepleted == false)
}

@Test func derivesCursorDepletionFromIndependentPoolsWhenNotExplicitlySet() throws {
    let windows = [
        ProviderWindow(id: "ac", percentLeft: 0.0, resetISO: nil, windowHours: nil, paceDelta: nil),
        ProviderWindow(id: "ap", percentLeft: 91.0, resetISO: nil, windowHours: nil, paceDelta: nil)
    ]
    let status = ProviderStatus(
        providerName: "Cursor",
        providerDisplayName: "Cursor",
        ok: true,
        errorMessage: nil,
        windows: windows,
        data: [:],
        observedAt: nil,
        snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
        publishedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    #expect(status.isDepleted == false)

    let record = try status.toCKRecord(zoneID: zoneID)
    record["isDepleted"] = nil
    #expect(record["isDepleted"] == nil)
    #expect(try ProviderStatus(record: record).isDepleted == false)
}

@Test func cursorWithOnlyDepletedPresentPoolIsDepleted() {
    let status = ProviderStatus(
        providerName: "Cursor",
        providerDisplayName: "Cursor",
        ok: true,
        errorMessage: nil,
        windows: [
            ProviderWindow(id: "ac", percentLeft: 0.0, resetISO: nil, windowHours: nil, paceDelta: nil)
        ],
        data: [:],
        observedAt: nil,
        snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
        publishedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    #expect(status.isDepleted == true)
}

@Test func decodeToleratesMissingWindowsJSON() throws {
    let record = CKRecord(
        recordType: CloudKitConstants.recordType, recordID: CKRecord.ID(recordName: "Codex", zoneID: zoneID)
    )
    record["providerName"] = "Codex" as CKRecordValue
    record["ok"] = NSNumber(value: true)
    record["snapshotUpdatedAt"] = "2026-08-02T20:00:00-04:00" as CKRecordValue
    record["publishedAt"] = Date(timeIntervalSince1970: 1_700_000_000) as CKRecordValue
    // windowsJSON deliberately absent.

    let decoded = try ProviderStatus(record: record)
    #expect(decoded.windows.isEmpty)
    #expect(decoded.data.isEmpty)
}

@Test func decodeToleratesMalformedWindowsJSON() throws {
    let record = CKRecord(
        recordType: CloudKitConstants.recordType, recordID: CKRecord.ID(recordName: "Codex", zoneID: zoneID)
    )
    record["providerName"] = "Codex" as CKRecordValue
    record["ok"] = NSNumber(value: true)
    record["snapshotUpdatedAt"] = "2026-08-02T20:00:00-04:00" as CKRecordValue
    record["publishedAt"] = Date(timeIntervalSince1970: 1_700_000_000) as CKRecordValue
    record["windowsJSON"] = "{not valid json[" as CKRecordValue
    record["dataJSON"] = "also not json" as CKRecordValue

    let decoded = try ProviderStatus(record: record)
    #expect(decoded.windows.isEmpty)
    #expect(decoded.data.isEmpty)
}

@Test func decodeThrowsOnMissingRequiredIdentityField() throws {
    let record = CKRecord(
        recordType: CloudKitConstants.recordType, recordID: CKRecord.ID(recordName: "Codex", zoneID: zoneID)
    )
    // providerName deliberately absent — this must throw, not silently degrade.
    record["ok"] = NSNumber(value: true)

    #expect(throws: ProviderStatusMappingError.self) {
        try ProviderStatus(record: record)
    }
}

@Test func decodeHonorsExplicitStaleFlagsOverRecomputation() throws {
    // A record whose stored isWarning/isDepleted flags disagree with what the
    // (now-missing) windows would recompute — decode must trust the stored
    // flags rather than silently recomputing from absent data.
    let record = CKRecord(
        recordType: CloudKitConstants.recordType, recordID: CKRecord.ID(recordName: "Codex", zoneID: zoneID)
    )
    record["providerName"] = "Codex" as CKRecordValue
    record["ok"] = NSNumber(value: true)
    record["snapshotUpdatedAt"] = "2026-08-02T20:00:00-04:00" as CKRecordValue
    record["publishedAt"] = Date(timeIntervalSince1970: 1_700_000_000) as CKRecordValue
    // windowsJSON absent -> recomputation would say isWarning == false.
    record["isWarning"] = NSNumber(value: true)
    record["isDepleted"] = NSNumber(value: true)

    let decoded = try ProviderStatus(record: record)
    #expect(decoded.isWarning == true)
    #expect(decoded.isDepleted == true)
}
