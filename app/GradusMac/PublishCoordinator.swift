import CloudKit
import Foundation
import GradusKit

/// Per-provider bookkeeping the coordinator uses to decide what to save and
/// to report which providers just crossed into a warning state.
struct ProviderPublishState: Equatable {
    var lastSavedContentHash: String?
    var lastSuccessfulPublishedAt: Date?
    var wasWarning: Bool = false
}

enum PublishCoordinatorError: Error, Equatable {
    case recordFailures(Int)
    case evidenceWriteFailed
}

private struct ProducerPublishEvidence: Encodable {
    let producerBuildNumber: String
    let cloudKitEnvironment: String
    let publishedAt: Date
}

/// Implements `GradusKit.CloudPublisher`: idempotent zone creation (PM-8),
/// content-hash save-suppression (PM-2), non-atomic per-record
/// partial-failure handling with retry/backoff (CV-4/PM-17), and warning
/// 0→1 edge tracking (CR-2, §5.2 — warning computation lives in the
/// publisher).
public actor PublishCoordinator: CloudPublisher {
    private let database: CloudDatabase
    private let zoneID: CKRecordZone.ID
    private let evidencePath: URL?
    private let producerBuildNumber: String?
    private let cloudKitEnvironment: String?
    private var state: [String: ProviderPublishState] = [:]

    /// Providers whose `isWarning` flipped false→true on the most recently
    /// processed `upsert` call — consumed by Phase 4's push trigger. Cleared
    /// and repopulated on every `upsert` call (not accumulated).
    public private(set) var newlyWarningProviders: Set<String> = []

    private static let maxBackoffAttempts = 3
    static let maxRetryDelaySeconds = 60.0

    public init(
        database: CloudDatabase,
        zoneID: CKRecordZone.ID,
        evidencePath: URL? = nil,
        producerBuildNumber: String? = nil,
        cloudKitEnvironment: String? = nil
    ) {
        self.database = database
        self.zoneID = zoneID
        self.evidencePath = evidencePath
        self.producerBuildNumber = producerBuildNumber
        self.cloudKitEnvironment = cloudKitEnvironment
    }

    /// Read-only snapshot of a provider's last known publish state — used by
    /// tests to assert the CV-4 "well-defined state" contract.
    func publishState(for providerName: String) -> ProviderPublishState? {
        state[providerName]
    }

    public func upsert(_ statuses: [ProviderStatus]) async throws {
        try await database.saveZoneIfNeeded(CKRecordZone(zoneID: zoneID))

        var newlyWarning: Set<String> = []
        var toSave: [(status: ProviderStatus, hash: String)] = []
        for status in statuses {
            let hash = Self.contentHash(for: status)
            let previous = state[status.providerName]
            if status.isWarning && !(previous?.wasWarning ?? false) {
                newlyWarning.insert(status.providerName)
            }
            var updated = previous ?? ProviderPublishState()
            updated.wasWarning = status.isWarning
            state[status.providerName] = updated

            if previous?.lastSavedContentHash == hash {
                continue  // PM-2: only the timestamp changed, nothing to save.
            }
            toSave.append((status, hash))
        }
        newlyWarningProviders = newlyWarning

        guard !toSave.isEmpty else {
            try writeProducerEvidenceIfConfigured()
            GradusLog.publish.info(
                "no changes to publish: all \(statuses.count) provider(s) matched their last saved content hash")
            return
        }
        GradusLog.publish.info(
            "publishing \(toSave.count) of \(statuses.count) provider(s); "
                + "\(statuses.count - toSave.count) suppressed by content hash")

        let records = try toSave.map { try $0.status.toCKRecord(zoneID: zoneID) }
        var outcome = await database.modifyRecords(toSave: records, savePolicy: .changedKeys)
        outcome = await retryServerRecordChanged(outcome, toSave: toSave)
        outcome = await retryWithBackoff(outcome, toSave: toSave, attempt: 1)

        var failedRecordCount = 0
        for (status, hash) in toSave {
            let recordID = CKRecord.ID(recordName: status.providerName, zoneID: zoneID)
            guard case .success = outcome.results[recordID] else {
                failedRecordCount += 1
                // The only point where a per-record cause is still known.
                // Everything above has finished retrying it and everything
                // below collapses it into a bare count, so a line not written
                // here is gone for good: the caller receives
                // `recordFailures(n)` and `cloudd` logs only the saves that
                // succeeded. This is the gap RELEASE_CHECKLIST step 3 calls
                // out — "a failed one is still invisible".
                GradusLog.publish.warning(
                    "save failed for \(status.providerName): \(Self.describe(outcome.results[recordID]))")
                continue  // Well-defined state: leave prior lastSavedContentHash/publishedAt untouched.
            }
            var updated = state[status.providerName] ?? ProviderPublishState()
            updated.lastSavedContentHash = hash
            updated.lastSuccessfulPublishedAt = status.publishedAt
            state[status.providerName] = updated
        }
        if failedRecordCount > 0 {
            // Successful records retain their committed state, while the
            // caller receives a sanitized aggregate signal suitable for UI.
            GradusLog.publish.error(
                "publish incomplete: \(failedRecordCount) of \(toSave.count) record(s) failed to save")
            throw PublishCoordinatorError.recordFailures(failedRecordCount)
        }
        try writeProducerEvidenceIfConfigured()
        GradusLog.publish.notice("published \(toSave.count) record(s) successfully")
    }

    private func writeProducerEvidenceIfConfigured() throws {
        guard let evidencePath, let producerBuildNumber, let cloudKitEnvironment else { return }
        do {
            try Self.writeProducerEvidence(
                to: evidencePath,
                producerBuildNumber: producerBuildNumber,
                cloudKitEnvironment: cloudKitEnvironment
            )
        } catch {
            GradusLog.publish.error("published records but could not write producer evidence")
            throw PublishCoordinatorError.evidenceWriteFailed
        }
    }

    private static func writeProducerEvidence(
        to path: URL,
        producerBuildNumber: String,
        cloudKitEnvironment: String
    ) throws {
        let evidence = ProducerPublishEvidence(
            producerBuildNumber: producerBuildNumber,
            cloudKitEnvironment: cloudKitEnvironment,
            publishedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(evidence)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: path, options: .atomic)
    }

    /// Describes a save result for the log by error *code*, not by dumping the
    /// error whole. A `CKError`'s `userInfo` can carry the offending record and
    /// its fields, and these records hold the user's provider usage data —
    /// there is no reason for any of it to reach a log file to explain why a
    /// save failed. That rules out `localizedDescription` too: it is read out
    /// of the same `userInfo` and can carry server-supplied text.
    static func describe(_ result: Result<CKRecord, Error>?) -> String {
        guard let result else { return "no result returned for this record" }
        guard case .failure(let error) = result else { return "success" }
        guard let ckError = error as? CKError else {
            let nsError = error as NSError
            return "\(type(of: error)) (code \(nsError.code), domain \(nsError.domain))"
        }
        return "\(name(for: ckError.code)) (CKError \(ckError.code.rawValue))"
    }

    /// `CKError.Code` is imported from an Objective-C `NS_ENUM`, so it has no
    /// synthesized case names: interpolating it yields
    /// `CKErrorCode(rawValue: 26)` — the number twice and the name never. The
    /// first release-checklist line this ever produced read
    /// `save failed for B: CKError.CKErrorCode(rawValue: 26) (26)`, which
    /// tells a reader at 2am to go look up 26 rather than telling them the
    /// zone is gone.
    ///
    /// Spelled out rather than derived, because the alternative that needs no
    /// table is `localizedDescription`, and that reaches into the `userInfo`
    /// this function exists to stay out of. An unmapped code still prints its
    /// number: honest, and one line short of ideal, rather than wrong.
    private static func name(for code: CKError.Code) -> String {
        switch code {
        case .internalError: return "internalError"
        case .partialFailure: return "partialFailure"
        case .networkUnavailable: return "networkUnavailable"
        case .networkFailure: return "networkFailure"
        case .badContainer: return "badContainer"
        case .serviceUnavailable: return "serviceUnavailable"
        case .requestRateLimited: return "requestRateLimited"
        case .missingEntitlement: return "missingEntitlement"
        case .notAuthenticated: return "notAuthenticated"
        case .permissionFailure: return "permissionFailure"
        case .unknownItem: return "unknownItem"
        case .invalidArguments: return "invalidArguments"
        case .serverRecordChanged: return "serverRecordChanged"
        case .serverRejectedRequest: return "serverRejectedRequest"
        case .assetFileNotFound: return "assetFileNotFound"
        case .assetFileModified: return "assetFileModified"
        case .incompatibleVersion: return "incompatibleVersion"
        case .constraintViolation: return "constraintViolation"
        case .operationCancelled: return "operationCancelled"
        case .changeTokenExpired: return "changeTokenExpired"
        case .batchRequestFailed: return "batchRequestFailed"
        case .zoneBusy: return "zoneBusy"
        case .badDatabase: return "badDatabase"
        case .quotaExceeded: return "quotaExceeded"
        case .zoneNotFound: return "zoneNotFound"
        case .limitExceeded: return "limitExceeded"
        case .userDeletedZone: return "userDeletedZone"
        case .tooManyParticipants: return "tooManyParticipants"
        case .alreadyShared: return "alreadyShared"
        case .referenceViolation: return "referenceViolation"
        case .managedAccountRestricted: return "managedAccountRestricted"
        case .participantMayNeedVerification: return "participantMayNeedVerification"
        case .serverResponseLost: return "serverResponseLost"
        case .assetNotAvailable: return "assetNotAvailable"
        case .accountTemporarilyUnavailable: return "accountTemporarilyUnavailable"
        default: return "unmappedCKErrorCode"
        }
    }

    /// `.serverRecordChanged` means our change tag was stale. Fetch the
    /// current server record (which carries the fresh tag), reapply our
    /// field values onto it, and resave once.
    private func retryServerRecordChanged(
        _ outcome: RecordSaveOutcome, toSave: [(status: ProviderStatus, hash: String)]
    ) async -> RecordSaveOutcome {
        let conflicted = toSave.filter { entry in
            guard case .failure(let error) = outcome.results[CKRecord.ID(recordName: entry.status.providerName, zoneID: zoneID)],
                let ckError = error as? CKError
            else { return false }
            return ckError.code == .serverRecordChanged
        }
        guard !conflicted.isEmpty else { return outcome }

        var merged: [CKRecord] = []
        for entry in conflicted {
            let recordID = CKRecord.ID(recordName: entry.status.providerName, zoneID: zoneID)
            guard let serverRecord = try? await database.fetchRecord(recordID),
                let freshRecord = try? entry.status.toCKRecord(zoneID: zoneID)
            else { continue }
            for key in freshRecord.allKeys() {
                serverRecord[key] = freshRecord[key]
            }
            merged.append(serverRecord)
        }
        guard !merged.isEmpty else { return outcome }

        let retryOutcome = await database.modifyRecords(toSave: merged, savePolicy: .changedKeys)
        var combined = outcome.results
        for (id, result) in retryOutcome.results {
            combined[id] = result
        }
        return RecordSaveOutcome(results: combined)
    }

    /// `.zoneBusy` / `.limitExceeded` / rate limiting carry a
    /// `retryAfterSeconds` hint — sleep that long (or a small exponential
    /// default) and retry the still-failing subset, bounded.
    private func retryWithBackoff(
        _ outcome: RecordSaveOutcome, toSave: [(status: ProviderStatus, hash: String)], attempt: Int
    ) async -> RecordSaveOutcome {
        guard attempt <= Self.maxBackoffAttempts else { return outcome }

        let retryable = toSave.filter { entry in
            guard case .failure(let error) = outcome.results[CKRecord.ID(recordName: entry.status.providerName, zoneID: zoneID)],
                let ckError = error as? CKError
            else { return false }
            return ckError.retryAfterSeconds != nil
                || ckError.code == .zoneBusy || ckError.code == .limitExceeded
        }
        guard !retryable.isEmpty else { return outcome }

        let retryAfterSeconds = retryable.lazy.compactMap { entry -> Double? in
                guard case .failure(let error) = outcome.results[CKRecord.ID(recordName: entry.status.providerName, zoneID: self.zoneID)],
                    let ckError = error as? CKError
                else { return nil }
                return ckError.retryAfterSeconds
            }
        let delaySeconds = Self.retryDelaySeconds(retryAfter: Array(retryAfterSeconds), attempt: attempt)
        try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))

        guard let retryRecords = try? retryable.map({ try $0.status.toCKRecord(zoneID: zoneID) }) else {
            return outcome
        }
        let retryOutcome = await database.modifyRecords(toSave: retryRecords, savePolicy: .changedKeys)
        var combined = outcome.results
        for (id, result) in retryOutcome.results {
            combined[id] = result
        }
        return await retryWithBackoff(RecordSaveOutcome(results: combined), toSave: toSave, attempt: attempt + 1)
    }

    /// Bounds both server-provided hints and the exponential fallback before
    /// converting seconds to nanoseconds. Invalid hints are ignored.
    static func retryDelaySeconds(retryAfter hints: [Double], attempt: Int) -> Double {
        let validHints = hints.filter { $0.isFinite && $0 >= 0 }
        if let longestHint = validHints.max() {
            return min(longestHint, maxRetryDelaySeconds)
        }
        let boundedExponent = min(max(attempt, 0), 10)
        return min(pow(2.0, Double(boundedExponent)), maxRetryDelaySeconds)
    }

    /// Deterministic fingerprint of everything EXCEPT `publishedAt` /
    /// `snapshotUpdatedAt` — those advance every ~120s launchd cycle even
    /// when nothing a human cares about changed (PM-2).
    static func contentHash(for status: ProviderStatus) -> String {
        struct Fingerprint: Encodable {
            let providerName: String
            let providerDisplayName: String
            let ok: Bool
            let errorMessage: String?
            let windows: [ProviderWindow]
            let data: [String: JSONValue]
            let isWarning: Bool
            let isDepleted: Bool
            let observedAt: String?
            let syncSource: SyncSource?
        }
        let fingerprint = Fingerprint(
            providerName: status.providerName,
            providerDisplayName: status.providerDisplayName,
            ok: status.ok,
            errorMessage: status.errorMessage,
            windows: status.windows,
            data: status.data,
            isWarning: status.isWarning,
            isDepleted: status.isDepleted,
            observedAt: status.observedAt,
            syncSource: status.syncSource
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(fingerprint) else {
            // Must never suppress a save we couldn't fingerprint.
            return UUID().uuidString
        }
        return encoded.base64EncodedString()
    }
}

/// Maps a decoded `ProviderEntry` (GradusKit's Python-mirroring model) to
/// the CloudKit-facing `ProviderStatus`. `providerDisplayName` is the same
/// string as `name` — the Python producer already emits human-readable
/// names ("Codex", "Antigravity (Claude)", ...), there is no separate
/// display-name table.
enum SnapshotDataValidationError: Error, Equatable {
    case unsupportedKey(String)
    case nonFiniteNumber(String)
    case valueTooLarge(String)
    case errorMessageTooLarge
    case aggregateTooLarge
}

private let snapshotDataAllowedKeys: Set<String> = [
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

private let snapshotDataMaxStringBytes = 4_096
private let snapshotDataMaxAggregateBytes = 32_768
private let snapshotErrorMaxBytes = 4_096

func validatedSnapshotData(_ data: [String: JSONValue]) throws -> [String: JSONValue] {
    for (key, value) in data {
        guard snapshotDataAllowedKeys.contains(key) else {
            throw SnapshotDataValidationError.unsupportedKey(key)
        }
        switch value {
        case .string(let string):
            guard string.utf8.count <= snapshotDataMaxStringBytes else {
                throw SnapshotDataValidationError.valueTooLarge(key)
            }
        case .double(let number):
            guard number.isFinite else {
                throw SnapshotDataValidationError.nonFiniteNumber(key)
            }
        case .bool, .null:
            break
        }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let encoded = try? encoder.encode(data), encoded.count <= snapshotDataMaxAggregateBytes else {
        throw SnapshotDataValidationError.aggregateTooLarge
    }
    return data
}

func makeProviderStatus(
    from entry: ProviderEntry,
    snapshotUpdatedAt: String,
    publishedAt: Date,
    syncSource: SyncSource? = nil
) throws -> ProviderStatus {
    if let error = entry.error, error.utf8.count > snapshotErrorMaxBytes {
        throw SnapshotDataValidationError.errorMessageTooLarge
    }
    return ProviderStatus(
        providerName: entry.name,
        providerDisplayName: entry.name,
        ok: entry.ok,
        errorMessage: entry.error,
        windows: entry.windows,
        data: try validatedSnapshotData(entry.data),
        observedAt: entry.observedAt,
        snapshotUpdatedAt: snapshotUpdatedAt,
        publishedAt: publishedAt,
        syncSource: syncSource
    )
}
