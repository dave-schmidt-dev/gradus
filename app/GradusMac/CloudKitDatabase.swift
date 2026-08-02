import CloudKit
import Foundation

/// Outcome of a `CKModifyRecordsOperation` save, one entry per record that
/// was submitted. `CloudPublisher` uses this to leave the coordinator's
/// per-provider state well-defined even when only some records save (CV-4).
public struct RecordSaveOutcome: Sendable {
    public var results: [CKRecord.ID: Result<CKRecord, Error>]

    public init(results: [CKRecord.ID: Result<CKRecord, Error>]) {
        self.results = results
    }
}

/// Thin abstraction over the exact slice of `CKDatabase` the publisher
/// needs, so tests can exercise partial-failure/backoff paths (PM-17)
/// without a live CloudKit connection.
public protocol CloudDatabase: Sendable {
    /// Idempotent zone creation (PM-8): must succeed as a no-op if the zone
    /// already exists — callers can call this on every publish cycle.
    func saveZoneIfNeeded(_ zone: CKRecordZone) async throws

    /// Non-atomic save of `records` with the given save policy. Returns a
    /// per-record result — callers must not assume all-or-nothing.
    func modifyRecords(
        toSave records: [CKRecord], savePolicy: CKModifyRecordsOperation.RecordSavePolicy
    ) async -> RecordSaveOutcome

    /// Fetch the current server copy of a record (used for the
    /// fetch-merge-resave retry on `.serverRecordChanged`).
    func fetchRecord(_ recordID: CKRecord.ID) async throws -> CKRecord
}

/// Production adapter backed by a real `CKDatabase`.
public struct CKDatabaseAdapter: CloudDatabase {
    private let database: CKDatabase

    public init(database: CKDatabase) {
        self.database = database
    }

    public func saveZoneIfNeeded(_ zone: CKRecordZone) async throws {
        // CloudKit has no "zone already exists" error (PM-8) — saving a
        // zone that already exists is itself idempotent at the API level,
        // so this can run unconditionally on every publish cycle.
        _ = try await database.save(zone)
    }

    public func modifyRecords(
        toSave records: [CKRecord], savePolicy: CKModifyRecordsOperation.RecordSavePolicy
    ) async -> RecordSaveOutcome {
        await withCheckedContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
            operation.savePolicy = savePolicy
            operation.isAtomic = false

            var results: [CKRecord.ID: Result<CKRecord, Error>] = [:]
            operation.perRecordSaveBlock = { recordID, result in
                results[recordID] = result
            }
            operation.modifyRecordsResultBlock = { _ in
                // Whether the overall operation reports success or failure,
                // per-record results (or their absence, for records the
                // operation never got to) are what we act on.
                for record in records where results[record.recordID] == nil {
                    results[record.recordID] = .failure(CKError(.internalError))
                }
                continuation.resume(returning: RecordSaveOutcome(results: results))
            }

            database.add(operation)
        }
    }

    public func fetchRecord(_ recordID: CKRecord.ID) async throws -> CKRecord {
        try await database.record(for: recordID)
    }
}
