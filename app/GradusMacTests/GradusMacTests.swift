import CloudKit
import Foundation
import GradusKit
import Testing

@testable import GradusMac

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
        toSave records: [CKRecord], savePolicy: CKModifyRecordsOperation.RecordSavePolicy
    ) async -> RecordSaveOutcome {
        recordsPerCall.append(records)
        defer { modifyCallCount += 1 }

        guard !scriptedResponses.isEmpty else {
            var results: [CKRecord.ID: Result<CKRecord, Error>] = [:]
            for record in records { results[record.recordID] = .success(record) }
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

private let zoneID = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)

private func status(
    name: String, ok: Bool = true, percentLeft: Double = 80.0, publishedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> ProviderStatus {
    ProviderStatus(
        providerName: name,
        providerDisplayName: name,
        ok: ok,
        errorMessage: nil,
        windows: [ProviderWindow(id: "weekly", percentLeft: percentLeft, resetISO: nil, windowHours: 168.0, paceDelta: nil)],
        data: [:],
        observedAt: "2026-08-02T20:00:00-04:00",
        snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
        publishedAt: publishedAt
    )
}

private func recordID(_ name: String) -> CKRecord.ID {
    CKRecord.ID(recordName: name, zoneID: zoneID)
}

// MARK: - Record mapping (T2a.3)

@Test func makeProviderStatusMapsEntryFieldsIncludingDisplayName() {
    let entry = ProviderEntry(
        name: "Codex", ok: true, error: nil,
        windows: [ProviderWindow(id: "weekly", percentLeft: 40.0, resetISO: nil, windowHours: nil, paceDelta: nil)],
        data: ["weekly_percent_left": .double(40.0)], observedAt: "2026-08-02T20:00:00-04:00")
    let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)

    let mapped = makeProviderStatus(from: entry, snapshotUpdatedAt: "2026-08-02T20:05:00-04:00", publishedAt: publishedAt)

    #expect(mapped.providerName == "Codex")
    #expect(mapped.providerDisplayName == "Codex")  // no separate display-name table — the producer's name IS the display name
    #expect(mapped.observedAt == "2026-08-02T20:00:00-04:00")
    #expect(mapped.snapshotUpdatedAt == "2026-08-02T20:05:00-04:00")
    #expect(mapped.publishedAt == publishedAt)
    #expect(mapped.windows == entry.windows)
    #expect(mapped.data == entry.data)
}

// MARK: - Content-hash save suppression (PM-2)

@Test func identicalContentAcrossTwoPublishesSuppressesSecondSave() async throws {
    let database = MockCloudDatabase()
    let coordinator = PublishCoordinator(database: database, zoneID: zoneID)

    try await coordinator.upsert([status(name: "Codex", publishedAt: Date(timeIntervalSince1970: 1_700_000_000))])
    // Only the timestamp changes between publishes — content is identical.
    try await coordinator.upsert([status(name: "Codex", publishedAt: Date(timeIntervalSince1970: 1_700_000_200))])

    let callCount = await database.modifyCallCount
    #expect(callCount == 1)  // gate: 2 identical builds -> 0 saves on the second
}

@Test func changedContentTriggersASecondSave() async throws {
    let database = MockCloudDatabase()
    let coordinator = PublishCoordinator(database: database, zoneID: zoneID)

    try await coordinator.upsert([status(name: "Codex", percentLeft: 80.0)])
    try await coordinator.upsert([status(name: "Codex", percentLeft: 40.0)])

    let callCount = await database.modifyCallCount
    #expect(callCount == 2)
}

// MARK: - CV-4: partial-write leaves a well-defined state

@Test func partialFailureLeavesSucceededFreshAndFailedAtPrior() async throws {
    let database = MockCloudDatabase()
    await database.setScriptedResponses([
        [
            recordID("A"): .success(CKRecord(recordType: CloudKitConstants.recordType, recordID: recordID("A"))),
            recordID("B"): .failure(CKError(.zoneNotFound)),
        ]
    ])
    let coordinator = PublishCoordinator(database: database, zoneID: zoneID)
    let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)

    try await coordinator.upsert([status(name: "A", publishedAt: publishedAt), status(name: "B", publishedAt: publishedAt)])

    let stateA = await coordinator.publishState(for: "A")
    let stateB = await coordinator.publishState(for: "B")
    #expect(stateA?.lastSuccessfulPublishedAt == publishedAt)
    #expect(stateB?.lastSuccessfulPublishedAt == nil)  // failed: no prior success to keep, stays nil not corrupted

    // Next cycle: A unchanged (suppressed), B retried because its hash was
    // never recorded as saved.
    await database.setScriptedResponses([[:]])  // irrelevant: only B should be submitted
    try await coordinator.upsert([status(name: "A", publishedAt: publishedAt), status(name: "B", publishedAt: publishedAt)])
    let secondCallRecords = await database.recordsPerCall[1]
    #expect(secondCallRecords.map(\.recordID) == [recordID("B")])
}

@Test func zoneNotFoundIsNotRetriedWithinTheSameUpsertCall() async throws {
    let database = MockCloudDatabase()
    await database.setScriptedResponses([[recordID("A"): .failure(CKError(.zoneNotFound))]])
    let coordinator = PublishCoordinator(database: database, zoneID: zoneID)

    try await coordinator.upsert([status(name: "A")])

    let callCount = await database.modifyCallCount
    #expect(callCount == 1)  // no blind retry loop for a non-retryable code
    let state = await coordinator.publishState(for: "A")
    #expect(state?.lastSuccessfulPublishedAt == nil)
}

@Test func genericTransportErrorIsNotRetriedWithinTheSameUpsertCall() async throws {
    let database = MockCloudDatabase()
    await database.setScriptedResponses([[recordID("A"): .failure(CKError(.networkUnavailable))]])
    let coordinator = PublishCoordinator(database: database, zoneID: zoneID)

    try await coordinator.upsert([status(name: "A")])

    let callCount = await database.modifyCallCount
    #expect(callCount == 1)
    let state = await coordinator.publishState(for: "A")
    #expect(state?.lastSuccessfulPublishedAt == nil)
}

// MARK: - serverRecordChanged: fetch-merge-resave retry

@Test func serverRecordChangedRetriesOnceViaFetchMergeResave() async throws {
    let database = MockCloudDatabase()
    await database.setScriptedResponses([
        [recordID("A"): .failure(CKError(.serverRecordChanged))],
        [recordID("A"): .success(CKRecord(recordType: CloudKitConstants.recordType, recordID: recordID("A")))],
    ])
    let serverRecord = CKRecord(recordType: CloudKitConstants.recordType, recordID: recordID("A"))
    await database.setFetchRecordHandler({ _ in serverRecord })
    let coordinator = PublishCoordinator(database: database, zoneID: zoneID)
    let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)

    try await coordinator.upsert([status(name: "A", publishedAt: publishedAt)])

    let callCount = await database.modifyCallCount
    #expect(callCount == 2)  // initial attempt + one fetch-merge-resave retry
    let state = await coordinator.publishState(for: "A")
    #expect(state?.lastSuccessfulPublishedAt == publishedAt)
}

// MARK: - zoneBusy / limitExceeded: backoff + retry

@Test func zoneBusyBacksOffAndRetries() async throws {
    let database = MockCloudDatabase()
    await database.setScriptedResponses([
        [recordID("A"): .failure(CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 0.01]))],
        [recordID("A"): .success(CKRecord(recordType: CloudKitConstants.recordType, recordID: recordID("A")))],
    ])
    let coordinator = PublishCoordinator(database: database, zoneID: zoneID)
    let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)

    try await coordinator.upsert([status(name: "A", publishedAt: publishedAt)])

    let callCount = await database.modifyCallCount
    #expect(callCount == 2)
    let state = await coordinator.publishState(for: "A")
    #expect(state?.lastSuccessfulPublishedAt == publishedAt)
}

@Test func limitExceededBacksOffAndRetries() async throws {
    let database = MockCloudDatabase()
    await database.setScriptedResponses([
        [recordID("A"): .failure(CKError(.limitExceeded, userInfo: [CKErrorRetryAfterKey: 0.01]))],
        [recordID("A"): .success(CKRecord(recordType: CloudKitConstants.recordType, recordID: recordID("A")))],
    ])
    let coordinator = PublishCoordinator(database: database, zoneID: zoneID)
    let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)

    try await coordinator.upsert([status(name: "A", publishedAt: publishedAt)])

    let callCount = await database.modifyCallCount
    #expect(callCount == 2)
    let state = await coordinator.publishState(for: "A")
    #expect(state?.lastSuccessfulPublishedAt == publishedAt)
}

@Test func backoffGivesUpAfterMaxAttemptsAndStaysFailed() async throws {
    let database = MockCloudDatabase()
    await database.setScriptedResponses([
        [recordID("A"): .failure(CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 0.01]))]
    ])  // every call (script repeats) fails the same way
    let coordinator = PublishCoordinator(database: database, zoneID: zoneID)

    try await coordinator.upsert([status(name: "A")])

    let callCount = await database.modifyCallCount
    #expect(callCount == 4)  // 1 initial + 3 bounded backoff attempts, then give up
    let state = await coordinator.publishState(for: "A")
    #expect(state?.lastSuccessfulPublishedAt == nil)
}

// MARK: - Warning 0->1 edge dedup (CR-2)

@Test func warningEdgeOnlyFiresOnFalseToTrueTransition() async throws {
    let database = MockCloudDatabase()
    let coordinator = PublishCoordinator(database: database, zoneID: zoneID)

    try await coordinator.upsert([status(name: "A", percentLeft: 80.0)])  // not warning
    #expect(await coordinator.newlyWarningProviders.isEmpty)

    try await coordinator.upsert([status(name: "A", percentLeft: 0.0)])  // depleted -> warning, edge fires
    #expect(await coordinator.newlyWarningProviders == ["A"])

    try await coordinator.upsert([status(name: "A", percentLeft: 0.0)])  // still warning, no new edge
    #expect(await coordinator.newlyWarningProviders.isEmpty)

    try await coordinator.upsert([status(name: "A", percentLeft: 80.0)])  // recovers
    #expect(await coordinator.newlyWarningProviders.isEmpty)

    try await coordinator.upsert([status(name: "A", percentLeft: 0.0)])  // re-arms after recovery
    #expect(await coordinator.newlyWarningProviders == ["A"])
}

// MARK: - Placeholder retained from initial scaffold

@Test func placeholder() {
    #expect(true)
}
