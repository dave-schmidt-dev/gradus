import CloudKit
import Foundation
import GradusKit
@testable import GradusMac
import Testing

// MARK: - Mock CloudDatabase (CV-4 / PM-17)

/// Scripted, in-memory `CloudDatabase` so partial-failure/retry/backoff
/// paths can be exercised without a live CloudKit connection. Each call to
/// `modifyRecords` consumes the next scripted response (the last one
/// repeats if calls exceed the script length); default (no script) is
/// "everything succeeds."
actor MockCloudDatabase: CloudDatabase {
    private(set) var savedZones: [CKRecordZone] = []
    private(set) var modifyCallCount = 0
    private(set) var recordsPerCall: [[CKRecord]] = []
    private var scriptedResponses: [[CKRecord.ID: Result<CKRecord, Error>]] = []
    private var fetchRecordHandler: (@Sendable (CKRecord.ID) throws -> CKRecord)?

    func saveZoneIfNeeded(_ zone: CKRecordZone) async throws {
        savedZones.append(zone)
    }

    func modifyRecords(
        toSave records: [CKRecord], savePolicy _: CKModifyRecordsOperation.RecordSavePolicy
    ) async -> RecordSaveOutcome {
        recordsPerCall.append(records)
        defer { modifyCallCount += 1 }

        guard !scriptedResponses.isEmpty else {
            var results: [CKRecord.ID: Result<CKRecord, Error>] = [:]
            for record in records {
                results[record.recordID] = .success(record)
            }
            return RecordSaveOutcome(results: results)
        }
        let index = min(modifyCallCount, scriptedResponses.count - 1)
        return RecordSaveOutcome(results: scriptedResponses[index])
    }

    func fetchRecord(_ recordID: CKRecord.ID) async throws -> CKRecord {
        if let handler = fetchRecordHandler {
            return try handler(recordID)
        }
        return CKRecord(recordType: CloudKitConstants.recordType, recordID: recordID)
    }

    func setFetchRecordHandler(_ handler: @escaping @Sendable (CKRecord.ID) throws -> CKRecord) {
        fetchRecordHandler = handler
    }

    func setScriptedResponses(_ responses: [[CKRecord.ID: Result<CKRecord, Error>]]) {
        scriptedResponses = responses
    }
}

// MARK: - Fixtures

// Shared across the PublishCoordinator suites split out of this file --
// `internal` (not `private`) so those sibling files can use them too.

let zoneID = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)

func status(
    name: String, ok: Bool = true, percentLeft: Double = 80.0,
    publishedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> ProviderStatus {
    ProviderStatus(
        providerName: name,
        providerDisplayName: name,
        ok: ok,
        errorMessage: nil,
        windows: [
            ProviderWindow(id: "weekly", percentLeft: percentLeft, resetISO: nil, windowHours: 168.0, paceDelta: nil)
        ],
        data: [:],
        observedAt: "2026-08-02T20:00:00-04:00",
        snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
        publishedAt: publishedAt
    )
}

func recordID(_ name: String) -> CKRecord.ID {
    CKRecord.ID(recordName: name, zoneID: zoneID)
}

// MARK: - Record mapping (T2a.3)

@Test func makeProviderStatusMapsEntryFieldsIncludingDisplayName() throws {
    let entry = ProviderEntry(
        name: "Codex", ok: true, error: nil,
        windows: [ProviderWindow(id: "weekly", percentLeft: 40.0, resetISO: nil, windowHours: nil, paceDelta: nil)],
        data: ["weekly_percent_left": .double(40.0)], observedAt: "2026-08-02T20:00:00-04:00"
    )
    let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)

    let mapped = try makeProviderStatus(
        from: entry, snapshotUpdatedAt: "2026-08-02T20:05:00-04:00", publishedAt: publishedAt
    )

    #expect(mapped.providerName == "Codex")
    // no separate display-name table — the producer's name IS the display name
    #expect(mapped.providerDisplayName == "Codex")
    #expect(mapped.observedAt == "2026-08-02T20:00:00-04:00")
    #expect(mapped.snapshotUpdatedAt == "2026-08-02T20:05:00-04:00")
    #expect(mapped.publishedAt == publishedAt)
    #expect(mapped.windows == entry.windows)
    #expect(mapped.data == entry.data)
}

@Test func makeProviderStatusPreservesFailureMetadataAndSyncSource() throws {
    let entry = ProviderEntry(
        name: "Copilot", ok: false, error: "provider probe timed out",
        windows: [], data: ["payg_enabled": .bool(false)], observedAt: nil
    )
    let syncSource = SyncSource(computerName: "Build Mac", userName: "runner")

    let mapped = try makeProviderStatus(
        from: entry,
        snapshotUpdatedAt: "2026-08-02T20:05:00-04:00",
        publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
        syncSource: syncSource
    )

    #expect(mapped.ok == false)
    #expect(mapped.errorMessage == "provider probe timed out")
    #expect(mapped.observedAt == nil)
    #expect(mapped.data == entry.data)
    #expect(mapped.syncSource == syncSource)
}
