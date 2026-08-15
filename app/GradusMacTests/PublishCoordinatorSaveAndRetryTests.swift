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
