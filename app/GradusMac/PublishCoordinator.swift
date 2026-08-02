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

/// Implements `GradusKit.CloudPublisher`: idempotent zone creation (PM-8),
/// content-hash save-suppression (PM-2), non-atomic per-record
/// partial-failure handling with retry/backoff (CV-4/PM-17), and warning
/// 0→1 edge tracking (CR-2, §5.2 — warning computation lives in the
/// publisher).
public actor PublishCoordinator: CloudPublisher {
    private let database: CloudDatabase
    private let zoneID: CKRecordZone.ID
    private var state: [String: ProviderPublishState] = [:]

    /// Providers whose `isWarning` flipped false→true on the most recently
    /// processed `upsert` call — consumed by Phase 4's push trigger. Cleared
    /// and repopulated on every `upsert` call (not accumulated).
    public private(set) var newlyWarningProviders: Set<String> = []

    private static let maxBackoffAttempts = 3

    public init(database: CloudDatabase, zoneID: CKRecordZone.ID) {
        self.database = database
        self.zoneID = zoneID
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

        guard !toSave.isEmpty else { return }

        let records = try toSave.map { try $0.status.toCKRecord(zoneID: zoneID) }
        var outcome = await database.modifyRecords(toSave: records, savePolicy: .changedKeys)
        outcome = await retryServerRecordChanged(outcome, toSave: toSave)
        outcome = await retryWithBackoff(outcome, toSave: toSave, attempt: 1)

        for (status, hash) in toSave {
            let recordID = CKRecord.ID(recordName: status.providerName, zoneID: zoneID)
            guard case .success = outcome.results[recordID] else {
                continue  // Well-defined state: leave prior lastSavedContentHash/publishedAt untouched.
            }
            var updated = state[status.providerName] ?? ProviderPublishState()
            updated.lastSavedContentHash = hash
            updated.lastSuccessfulPublishedAt = status.publishedAt
            state[status.providerName] = updated
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

        let delaySeconds =
            retryable.lazy.compactMap { entry -> Double? in
                guard case .failure(let error) = outcome.results[CKRecord.ID(recordName: entry.status.providerName, zoneID: self.zoneID)],
                    let ckError = error as? CKError
                else { return nil }
                return ckError.retryAfterSeconds
            }.max() ?? pow(2.0, Double(attempt))
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
            observedAt: status.observedAt
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
func makeProviderStatus(from entry: ProviderEntry, snapshotUpdatedAt: String, publishedAt: Date) -> ProviderStatus {
    ProviderStatus(
        providerName: entry.name,
        providerDisplayName: entry.name,
        ok: entry.ok,
        errorMessage: entry.error,
        windows: entry.windows,
        data: entry.data,
        observedAt: entry.observedAt,
        snapshotUpdatedAt: snapshotUpdatedAt,
        publishedAt: publishedAt
    )
}
