import CloudKit
import Foundation
import GradusKit

#if DEBUG
    /// T1.7 Phase-1 exit gate (PM-14, real Dev DB, not mocked): proves the
    /// CloudPublisher write path built in Phase 2a round-trips a real
    /// `ProviderStatus` through the actual production mapping/adapter code
    /// (not ad-hoc fields) against the live Development database.
    ///
    /// Only exercises save (CloudPublisher) -> fetch. The subscribe ->
    /// receive-change third of the original gate wording needs a conforming
    /// CloudSubscriber, which doesn't exist yet (CKQuerySubscription +
    /// remote-notification registration is Phase 4/T4.1-T4.2 territory) --
    /// deferred for the same reason T0.3(c)'s silent-push spike was deferred.
    ///
    /// Invoke with `--t1-7-gate`; prints PASS/FAIL lines and exits.
    enum T17SeamGate {
        static func run() async -> Never {
            let container = CKContainer(identifier: CloudKitConstants.containerIdentifier)
            let zoneID = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)
            let database = CKDatabaseAdapter(database: container.privateCloudDatabase)
            let coordinator = PublishCoordinator(database: database, zoneID: zoneID)
            let status = seamGateStatus()
            let recordID = CKRecord.ID(recordName: status.providerName, zoneID: zoneID)

            await upsertStatus(status, coordinator: coordinator)
            await verifyFetch(status, recordID: recordID, database: database, zoneID: zoneID)
            await cleanUpRecord(recordID, container: container)

            print(
                "T1.7 SEAM GATE: PASS (save->fetch proven on real Dev DB; "
                    + "subscribe->receive-change deferred to Phase 4)"
            )
            exit(0)
        }

        private static func seamGateStatus() -> ProviderStatus {
            ProviderStatus(
                providerName: "t1-7-seam-gate",
                providerDisplayName: "T1.7 Seam Gate",
                ok: true,
                errorMessage: nil,
                windows: [],
                data: [:],
                observedAt: "2026-08-02T00:00:00Z",
                snapshotUpdatedAt: "2026-08-02T00:00:00Z",
                publishedAt: Date(),
                isWarning: false,
                isDepleted: false
            )
        }

        private static func upsertStatus(_ status: ProviderStatus, coordinator: PublishCoordinator) async {
            do {
                try await coordinator.upsert([status])
            } catch {
                print("FAIL: CloudPublisher.upsert threw: \(error)")
                exit(1)
            }
        }

        /// upsert() intentionally swallows per-record failures (CV-4's
        /// partial-write contract) -- if the fetch below fails, re-save
        /// directly through the adapter to surface the real per-record error.
        private static func diagnoseSaveFailure(
            status: ProviderStatus,
            recordID: CKRecord.ID,
            zoneID: CKRecordZone.ID,
            database: CKDatabaseAdapter
        ) async {
            let record = try? status.toCKRecord(zoneID: zoneID)
            guard let record else { return }
            let outcome = await database.modifyRecords(toSave: [record], savePolicy: .changedKeys)
            if case let .failure(error) = outcome.results[recordID] {
                print("DIAGNOSIS: direct modifyRecords per-record result: \(error)")
            } else if case .success = outcome.results[recordID] {
                print(
                    "DIAGNOSIS: direct modifyRecords reported success this time "
                        + "(was the first save actually applied?)"
                )
            } else {
                print("DIAGNOSIS: no per-record result at all for \(recordID)")
            }
        }

        private static func verifyFetch(
            _ status: ProviderStatus,
            recordID: CKRecord.ID,
            database: CKDatabaseAdapter,
            zoneID: CKRecordZone.ID
        ) async {
            do {
                let record = try await database.fetchRecord(recordID)
                let fetched = try ProviderStatus(record: record)
                guard fetched.providerName == status.providerName,
                      fetched.providerDisplayName == status.providerDisplayName,
                      fetched.ok == status.ok
                else {
                    print("FAIL: fetched ProviderStatus fields mismatch: \(fetched)")
                    exit(1)
                }
                print("PASS: fetched record decodes back to an equivalent ProviderStatus via the real mapping code")
            } catch {
                print("FAIL: fetch/decode threw: \(error)")
                await diagnoseSaveFailure(status: status, recordID: recordID, zoneID: zoneID, database: database)
                exit(1)
            }
        }

        private static func cleanUpRecord(_ recordID: CKRecord.ID, container: CKContainer) async {
            do {
                _ = try await container.privateCloudDatabase.deleteRecord(withID: recordID)
                print("PASS: cleaned up seam-gate record")
            } catch {
                print("WARN: cleanup delete threw (non-fatal): \(error)")
            }
        }
    }
#endif
