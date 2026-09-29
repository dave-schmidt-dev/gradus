import CloudKit
import Foundation
import GradusKit
@testable import GradusMac
import Testing

// MARK: - Content-hash save suppression (PM-2)

@Test func identicalContentAcrossTwoPublishesSuppressesSecondSave() async throws {
    let database = MockCloudDatabase()
    let coordinator = PublishCoordinator(database: database, zoneID: zoneID)

    try await coordinator.upsert([status(name: "Codex", publishedAt: Date(timeIntervalSince1970: 1_700_000_000))])
    // Only the timestamp changes between publishes — content is identical.
    try await coordinator.upsert([status(name: "Codex", publishedAt: Date(timeIntervalSince1970: 1_700_000_200))])

    let callCount = await database.modifyCallCount
    #expect(callCount == 1) // gate: 2 identical builds -> 0 saves on the second
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
            recordID("B"): .failure(CKError(.zoneNotFound))
        ]
    ])
    let coordinator = PublishCoordinator(database: database, zoneID: zoneID)
    let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)

    do {
        try await coordinator.upsert([
            status(name: "A", publishedAt: publishedAt), status(name: "B", publishedAt: publishedAt)
        ])
        Issue.record("Expected one failed record to be reported")
    } catch let error as PublishCoordinatorError {
        #expect(error == .recordFailures(1))
    }

    let stateA = await coordinator.publishState(for: "A")
    let stateB = await coordinator.publishState(for: "B")
    #expect(stateA?.lastSuccessfulPublishedAt == publishedAt)
    #expect(stateB?.lastSuccessfulPublishedAt == nil) // failed: no prior success to keep, stays nil not corrupted

    // Next cycle: A unchanged (suppressed), B retried because its hash was
    // never recorded as saved.
    await database.setScriptedResponses([
        [recordID("B"): .success(CKRecord(recordType: CloudKitConstants.recordType, recordID: recordID("B")))]
    ])
    try await coordinator.upsert([
        status(name: "A", publishedAt: publishedAt), status(name: "B", publishedAt: publishedAt)
    ])
    let secondCallRecords = await database.recordsPerCall[1]
    #expect(secondCallRecords.map(\.recordID) == [recordID("B")])
}

@Test func zoneNotFoundIsNotRetriedWithinTheSameUpsertCall() async throws {
    let database = MockCloudDatabase()
    await database.setScriptedResponses([[recordID("A"): .failure(CKError(.zoneNotFound))]])
    let coordinator = PublishCoordinator(database: database, zoneID: zoneID)

    do {
        try await coordinator.upsert([status(name: "A")])
        Issue.record("Expected the failed record to be reported")
    } catch let error as PublishCoordinatorError {
        #expect(error == .recordFailures(1))
    }

    let callCount = await database.modifyCallCount
    #expect(callCount == 1) // no blind retry loop for a non-retryable code
    let state = await coordinator.publishState(for: "A")
    #expect(state?.lastSuccessfulPublishedAt == nil)
}

@Test func genericTransportErrorIsNotRetriedWithinTheSameUpsertCall() async throws {
    let database = MockCloudDatabase()
    await database.setScriptedResponses([[recordID("A"): .failure(CKError(.networkUnavailable))]])
    let coordinator = PublishCoordinator(database: database, zoneID: zoneID)

    do {
        try await coordinator.upsert([status(name: "A")])
        Issue.record("Expected the failed record to be reported")
    } catch let error as PublishCoordinatorError {
        #expect(error == .recordFailures(1))
    }

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
        [recordID("A"): .success(CKRecord(recordType: CloudKitConstants.recordType, recordID: recordID("A")))]
    ])
    let serverRecord = CKRecord(recordType: CloudKitConstants.recordType, recordID: recordID("A"))
    await database.setFetchRecordHandler { _ in serverRecord }
    let coordinator = PublishCoordinator(database: database, zoneID: zoneID)
    let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)

    try await coordinator.upsert([status(name: "A", publishedAt: publishedAt)])

    let callCount = await database.modifyCallCount
    #expect(callCount == 2) // initial attempt + one fetch-merge-resave retry
    let state = await coordinator.publishState(for: "A")
    #expect(state?.lastSuccessfulPublishedAt == publishedAt)
}

// MARK: - zoneBusy / limitExceeded: backoff + retry

@Test func zoneBusyBacksOffAndRetries() async throws {
    let database = MockCloudDatabase()
    await database.setScriptedResponses([
        [recordID("A"): .failure(CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 0.01]))],
        [recordID("A"): .success(CKRecord(recordType: CloudKitConstants.recordType, recordID: recordID("A")))]
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
        [recordID("A"): .success(CKRecord(recordType: CloudKitConstants.recordType, recordID: recordID("A")))]
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
    ]) // every call (script repeats) fails the same way
    let coordinator = PublishCoordinator(database: database, zoneID: zoneID)

    do {
        try await coordinator.upsert([status(name: "A")])
        Issue.record("Expected the failed record to be reported after retries")
    } catch let error as PublishCoordinatorError {
        #expect(error == .recordFailures(1))
    }

    let callCount = await database.modifyCallCount
    #expect(callCount == 4) // 1 initial + 3 bounded backoff attempts, then give up
    let state = await coordinator.publishState(for: "A")
    #expect(state?.lastSuccessfulPublishedAt == nil)
}

@Test func retryDelayCapsServerHintsAndFallbacks() {
    #expect(PublishCoordinator.retryDelaySeconds(retryAfter: [3600], attempt: 1) == 60)
    #expect(PublishCoordinator.retryDelaySeconds(retryAfter: [-1, .infinity, .nan], attempt: 100) == 60)
    #expect(PublishCoordinator.retryDelaySeconds(retryAfter: [0.25, 2], attempt: 1) == 2)
}

// MARK: - Warning 0->1 edge dedup (CR-2)

@Test func warningEdgeOnlyFiresOnFalseToTrueTransition() async throws {
    let database = MockCloudDatabase()
    let coordinator = PublishCoordinator(database: database, zoneID: zoneID)

    try await coordinator.upsert([status(name: "A", percentLeft: 80.0)]) // not warning
    #expect(await coordinator.newlyWarningProviders.isEmpty)

    try await coordinator.upsert([status(name: "A", percentLeft: 0.0)]) // depleted -> warning, edge fires
    #expect(await coordinator.newlyWarningProviders == ["A"])

    try await coordinator.upsert([status(name: "A", percentLeft: 0.0)]) // still warning, no new edge
    #expect(await coordinator.newlyWarningProviders.isEmpty)

    try await coordinator.upsert([status(name: "A", percentLeft: 80.0)]) // recovers
    #expect(await coordinator.newlyWarningProviders.isEmpty)

    try await coordinator.upsert([status(name: "A", percentLeft: 0.0)]) // re-arms after recovery
    #expect(await coordinator.newlyWarningProviders == ["A"])
}

// MARK: - Latest usage and independent banked evidence under actor reentrancy

private func racedStatus(
    percentLeft: Double, snapshotAt: String, bankedCount: Int? = nil,
    bankedObservedAt: String = "2026-08-02T20:00:00-04:00"
) -> ProviderStatus {
    let base = status(name: "Codex", percentLeft: percentLeft)
    var data: [String: JSONValue] = [:]
    if let bankedCount {
        data = [
            "banked_reset_count": .double(Double(bankedCount)),
            "banked_reset_generation": .string("01234567-89ab-4cde-8f01-23456789abcd"),
            "banked_reset_observed_at": .string(bankedObservedAt)
        ]
    }
    return ProviderStatus(
        providerName: base.providerName, providerDisplayName: base.providerDisplayName,
        ok: base.ok, errorMessage: base.errorMessage, windows: base.windows,
        data: data, observedAt: snapshotAt, snapshotUpdatedAt: snapshotAt,
        publishedAt: base.publishedAt
    )
}

private actor HoldingCloudDatabase: CloudDatabase {
    private(set) var calls: [[CKRecord]] = []
    private var firstStarted = false
    private var firstStartedWaiter: CheckedContinuation<Void, Never>?
    private var firstRelease: CheckedContinuation<Void, Never>?

    func saveZoneIfNeeded(_: CKRecordZone) async throws {}

    func modifyRecords(
        toSave records: [CKRecord], savePolicy _: CKModifyRecordsOperation.RecordSavePolicy
    ) async -> RecordSaveOutcome {
        calls.append(records)
        if calls.count == 1 {
            firstStarted = true
            firstStartedWaiter?.resume()
            await withCheckedContinuation { firstRelease = $0 }
        }
        return RecordSaveOutcome(results: Dictionary(uniqueKeysWithValues: records.map {
            ($0.recordID, Result<CKRecord, Error>.success($0))
        }))
    }

    func fetchRecord(_ id: CKRecord.ID) async throws -> CKRecord {
        CKRecord(recordType: CloudKitConstants.recordType, recordID: id)
    }

    func deleteRecords(_: [CKRecord.ID]) async throws {}

    func waitForFirstSave() async {
        if firstStarted {
            return
        }
        await withCheckedContinuation { firstStartedWaiter = $0 }
    }

    func releaseFirstSave() {
        firstRelease?.resume()
        firstRelease = nil
    }
}

@Test func delayedOlderSaveCannotFinishAfterNewerUsageAndLateBankedEvidence() async throws {
    let database = HoldingCloudDatabase()
    let coordinator = PublishCoordinator(database: database, zoneID: zoneID)
    let olderSnapshotAt = "2026-08-02T20:00:00-04:00"
    let newerSnapshotAt = "2026-08-02T20:02:00-04:00"

    let first = Task { try await coordinator.upsert([racedStatus(percentLeft: 80, snapshotAt: olderSnapshotAt)]) }
    await database.waitForFirstSave()
    let newer = Task { try await coordinator.upsert([racedStatus(percentLeft: 30, snapshotAt: newerSnapshotAt)]) }
    let late = Task {
        try await coordinator.upsert([racedStatus(percentLeft: 80, snapshotAt: olderSnapshotAt, bankedCount: 5)])
    }
    // Give the queued calls a chance to enter the actor while the first
    // CloudKit call is held. Final assertions are valid for either ordering.
    await Task.yield()
    await database.releaseFirstSave()
    try await first.value
    try await newer.value
    try await late.value

    let calls = await database.calls
    let lastRecord = try #require(calls.last?.first)
    #expect(lastRecord["snapshotUpdatedAt"] as? String == newerSnapshotAt)
    let decoded = try ProviderStatus(record: lastRecord)
    #expect(decoded.windows.first?.percentLeft == 30)
    #expect(decoded.data["banked_reset_count"] == .double(5))
    #expect(decoded.data["banked_reset_observed_at"] == .string(olderSnapshotAt))
}

@Test func staleUsageArrivalDoesNotReplaceSavedNewerSnapshot() async throws {
    let database = MockCloudDatabase()
    let coordinator = PublishCoordinator(database: database, zoneID: zoneID)
    let olderSnapshotAt = "2026-08-02T20:00:00-04:00"
    let newerSnapshotAt = "2026-08-02T20:02:00-04:00"
    try await coordinator.upsert([racedStatus(percentLeft: 30, snapshotAt: newerSnapshotAt)])
    try await coordinator.upsert([racedStatus(percentLeft: 80, snapshotAt: olderSnapshotAt)])
    #expect(await database.modifyCallCount == 1)
    let savedState = await coordinator.publishState(for: "Codex")
    #expect(savedState?.lastSavedContentHash
        == PublishCoordinator.contentHash(for: racedStatus(percentLeft: 30, snapshotAt: newerSnapshotAt)))
}

@Test func backoffRetryCompletesBeforeNewerSnapshotSave() async throws {
    let database = MockCloudDatabase()
    await database.setScriptedResponses([
        [recordID("Codex"): .failure(CKError(.zoneBusy, userInfo: [CKErrorRetryAfterKey: 0.05]))],
        [recordID("Codex"): .success(CKRecord(recordType: CloudKitConstants.recordType, recordID: recordID("Codex")))],
        [recordID("Codex"): .success(CKRecord(recordType: CloudKitConstants.recordType, recordID: recordID("Codex")))]
    ])
    let coordinator = PublishCoordinator(database: database, zoneID: zoneID)
    let olderSnapshotAt = "2026-08-02T20:00:00-04:00"
    let newerSnapshotAt = "2026-08-02T20:02:00-04:00"
    let older = Task { try await coordinator.upsert([racedStatus(percentLeft: 80, snapshotAt: olderSnapshotAt)]) }
    // Wait for the first response so the newer observation arrives during
    // bounded backoff, independent of Task scheduling order.
    for _ in 0 ..< 100 {
        if await database.modifyCallCount > 0 {
            break
        }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(await database.modifyCallCount == 1)
    let newer = Task { try await coordinator.upsert([racedStatus(percentLeft: 30, snapshotAt: newerSnapshotAt)]) }
    try await older.value
    try await newer.value
    let calls = await database.recordsPerCall
    #expect(calls.count == 3)
    let lastRecord = try #require(calls.last?.first)
    #expect(lastRecord["snapshotUpdatedAt"] as? String == newerSnapshotAt)
}
