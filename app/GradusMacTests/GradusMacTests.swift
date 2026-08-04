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

@Test func makeProviderStatusMapsEntryFieldsIncludingDisplayName() throws {
    let entry = ProviderEntry(
        name: "Codex", ok: true, error: nil,
        windows: [ProviderWindow(id: "weekly", percentLeft: 40.0, resetISO: nil, windowHours: nil, paceDelta: nil)],
        data: ["weekly_percent_left": .double(40.0)], observedAt: "2026-08-02T20:00:00-04:00")
    let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)

    let mapped = try makeProviderStatus(from: entry, snapshotUpdatedAt: "2026-08-02T20:05:00-04:00", publishedAt: publishedAt)

    #expect(mapped.providerName == "Codex")
    #expect(mapped.providerDisplayName == "Codex")  // no separate display-name table — the producer's name IS the display name
    #expect(mapped.observedAt == "2026-08-02T20:00:00-04:00")
    #expect(mapped.snapshotUpdatedAt == "2026-08-02T20:05:00-04:00")
    #expect(mapped.publishedAt == publishedAt)
    #expect(mapped.windows == entry.windows)
    #expect(mapped.data == entry.data)
}

@Test func snapshotDataValidationAcceptsExactProducerKeys() throws {
    let data: [String: JSONValue] = [
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
        "premium_reset": .string("in 10d"),
    ]

    let expectedProducerKeys: Set<String> = [
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
        "premium_reset",
    ]

    #expect(data.count == 24)
    #expect(Set(data.keys) == expectedProducerKeys)
    #expect(try validatedSnapshotData(data) == data)
}

@Test func snapshotDataValidationRejectsUnknownKeysAndOversizedValues() {
    #expect(throws: SnapshotDataValidationError.unsupportedKey("unexpected")) {
        try validatedSnapshotData(["unexpected": .string("value")])
    }
    #expect(throws: SnapshotDataValidationError.valueTooLarge("credits")) {
        try validatedSnapshotData(["credits": .string(String(repeating: "x", count: 4_097))])
    }
    let entry = ProviderEntry(
        name: "Codex", ok: false, error: String(repeating: "x", count: 4_097),
        windows: [], data: [:], observedAt: nil)
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
        "secondary_reset", "opus_reset", "reset_at", "start_date", "end_date",
    ].map { ($0, JSONValue.string(String(repeating: "x", count: 4_000))) })
    #expect(throws: SnapshotDataValidationError.aggregateTooLarge) {
        try validatedSnapshotData(data)
    }
}

@Test @MainActor func cloudSyncFailureIsVisibleAndClearsWhenDisabled() throws {
    let defaults = UserDefaults.standard
    let priorValue = defaults.object(forKey: PublisherViewModel.syncEnabledKey)
    defer {
        if let priorValue {
            defaults.set(priorValue, forKey: PublisherViewModel.syncEnabledKey)
        } else {
            defaults.removeObject(forKey: PublisherViewModel.syncEnabledKey)
        }
    }

    let viewModel = PublisherViewModel()
    viewModel.syncEnabled = true
    let operationID = try #require(viewModel.cloudSyncDidStart())
    #expect(viewModel.syncState == .publishing)
    viewModel.cloudSyncDidFail(operationID: operationID)
    #expect(viewModel.syncState == .failed)
    viewModel.syncEnabled = false
    #expect(viewModel.syncState == .idle)
}

@Test @MainActor func staleCloudSyncCompletionsCannotOverwriteCurrentOrDisabledState() throws {
    let defaults = UserDefaults.standard
    let priorValue = defaults.object(forKey: PublisherViewModel.syncEnabledKey)
    defer {
        if let priorValue {
            defaults.set(priorValue, forKey: PublisherViewModel.syncEnabledKey)
        } else {
            defaults.removeObject(forKey: PublisherViewModel.syncEnabledKey)
        }
    }

    let viewModel = PublisherViewModel()
    viewModel.syncEnabled = true
    let olderOperation = try #require(viewModel.cloudSyncDidStart())
    let currentOperation = try #require(viewModel.cloudSyncDidStart())

    viewModel.cloudSyncDidFail(operationID: olderOperation)
    #expect(viewModel.syncState == .publishing)
    viewModel.cloudSyncDidSucceed(operationID: currentOperation)
    #expect(viewModel.syncState == .synced)

    let disabledOperation = try #require(viewModel.cloudSyncDidStart())
    viewModel.syncEnabled = false
    viewModel.cloudSyncDidFail(operationID: disabledOperation)
    #expect(viewModel.syncState == .idle)
}

@Test @MainActor func cloudSyncCannotStartAfterSyncWasDisabled() {
    let defaults = UserDefaults.standard
    let priorValue = defaults.object(forKey: PublisherViewModel.syncEnabledKey)
    defer {
        if let priorValue {
            defaults.set(priorValue, forKey: PublisherViewModel.syncEnabledKey)
        } else {
            defaults.removeObject(forKey: PublisherViewModel.syncEnabledKey)
        }
    }

    let viewModel = PublisherViewModel()
    viewModel.syncEnabled = false

    #expect(viewModel.cloudSyncDidStart() == nil)
    #expect(viewModel.syncState == .idle)
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

    do {
        try await coordinator.upsert([status(name: "A", publishedAt: publishedAt), status(name: "B", publishedAt: publishedAt)])
        Issue.record("Expected one failed record to be reported")
    } catch let error as PublishCoordinatorError {
        #expect(error == .recordFailures(1))
    }

    let stateA = await coordinator.publishState(for: "A")
    let stateB = await coordinator.publishState(for: "B")
    #expect(stateA?.lastSuccessfulPublishedAt == publishedAt)
    #expect(stateB?.lastSuccessfulPublishedAt == nil)  // failed: no prior success to keep, stays nil not corrupted

    // Next cycle: A unchanged (suppressed), B retried because its hash was
    // never recorded as saved.
    await database.setScriptedResponses([
        [recordID("B"): .success(CKRecord(recordType: CloudKitConstants.recordType, recordID: recordID("B")))]
    ])
    try await coordinator.upsert([status(name: "A", publishedAt: publishedAt), status(name: "B", publishedAt: publishedAt)])
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
    #expect(callCount == 1)  // no blind retry loop for a non-retryable code
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

    do {
        try await coordinator.upsert([status(name: "A")])
        Issue.record("Expected the failed record to be reported after retries")
    } catch let error as PublishCoordinatorError {
        #expect(error == .recordFailures(1))
    }

    let callCount = await database.modifyCallCount
    #expect(callCount == 4)  // 1 initial + 3 bounded backoff attempts, then give up
    let state = await coordinator.publishState(for: "A")
    #expect(state?.lastSuccessfulPublishedAt == nil)
}

@Test func retryDelayCapsServerHintsAndFallbacks() {
    #expect(PublishCoordinator.retryDelaySeconds(retryAfter: [3_600], attempt: 1) == 60)
    #expect(PublishCoordinator.retryDelaySeconds(retryAfter: [-1, .infinity, .nan], attempt: 100) == 60)
    #expect(PublishCoordinator.retryDelaySeconds(retryAfter: [0.25, 2], attempt: 1) == 2)
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
