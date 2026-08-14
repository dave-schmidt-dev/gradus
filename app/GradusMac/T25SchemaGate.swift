import CloudKit
import Foundation
import GradusKit

#if DEBUG
    // T2.5 (CV-7/PM-11) schema gate: proves every `ProviderStatus` field is
    // registered with the correct type in whichever CloudKit environment the
    // running binary is entitled for, and that a real save->fetch round-trip
    // works there.
//
    // Run twice, by design:
    //   1. Built with the Debug config (Development entitlements) BEFORE the
//      dev->prod schema promotion, with every optional field populated
//      non-nil -- CloudKit only registers a field's type in schema the
//      first time a non-null value is saved, and earlier spikes (T0.3,
//      T1.7) mostly left `errorMessage`/`observedAt` nil, so this run
//      forces both to register before the schema gets locked in.
    //   2. Built with the Release config (Production entitlements, via
//      `com.apple.developer.icloud-container-environment: Production`)
//      AFTER David deploys the schema in CloudKit Dashboard -- this is the
//      actual PM-11 gate: every field present with the right type in
//      Production, plus a real save+fetch round-trip.
//
    // Invoke with `--t2-5-schema-gate`; prints PASS/FAIL lines and exits.
    enum T25SchemaGate {
        static func run() async -> Never {
            let container = CKContainer(identifier: CloudKitConstants.containerIdentifier)
            let zoneID = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)
            let database = CKDatabaseAdapter(database: container.privateCloudDatabase)

            do {
                try await database.saveZoneIfNeeded(CKRecordZone(zoneID: zoneID))
                print("PASS: GradusZone created/confirmed in this environment")
            } catch {
                print("FAIL: zone save threw: \(error)")
                exit(1)
            }

            let publishedAt = Date()
            // Every field populated non-nil, including the two optionals that
            // earlier spikes left unset, so this run forces their types to
            // register in schema.
            let status = ProviderStatus(
                providerName: "t2-5-schema-gate",
                providerDisplayName: "T2.5 Schema Gate",
                ok: false,
                errorMessage: "schema-gate probe error field",
                windows: [
                    ProviderWindow(
                        id: "5h",
                        percentLeft: 42,
                        resetISO: "2026-08-02T23:00:00Z",
                        windowHours: 5,
                        paceDelta: -0.1
                    )
                ],
                data: ["probe": .string("schema-gate")],
                observedAt: "2026-08-02T00:00:00Z",
                snapshotUpdatedAt: "2026-08-02T00:00:00Z",
                publishedAt: publishedAt,
                isWarning: true,
                isDepleted: false,
                syncSource: SyncSource(computerName: "Schema Gate Mac", userName: "schema-gate")
            )

            let recordID = CKRecord.ID(recordName: status.providerName, zoneID: zoneID)

            do {
                let record = try status.toCKRecord(zoneID: zoneID)
                let outcome = await database.modifyRecords(toSave: [record], savePolicy: .changedKeys)
                guard case .success = outcome.results[recordID] else {
                    if case let .failure(error) = outcome.results[recordID] {
                        print("FAIL: save failed: \(error)")
                    } else {
                        print("FAIL: save produced no result for \(recordID)")
                    }
                    exit(1)
                }
                print("PASS: saved a ProviderStatus with every field populated")
            } catch {
                print("FAIL: toCKRecord/save threw: \(error)")
                exit(1)
            }

            do {
                let record = try await database.fetchRecord(recordID)
                let fetched = try ProviderStatus(record: record)
                // `publishedAt` is compared with a tolerance rather than exact
                // `Date` equality: CloudKit's TIMESTAMP field round-trips at
                // millisecond precision, so a bit-exact comparison against a
                // sub-millisecond `Date()` would spuriously fail.
                var mismatches: [String] = []
                if fetched.providerName != status.providerName {
                    mismatches.append("providerName")
                }
                if fetched.providerDisplayName != status.providerDisplayName {
                    mismatches.append("providerDisplayName")
                }
                if fetched.ok != status.ok {
                    mismatches.append("ok")
                }
                if fetched.errorMessage != status.errorMessage {
                    mismatches.append("errorMessage")
                }
                if fetched.windows != status.windows {
                    mismatches.append("windows")
                }
                if fetched.data != status.data {
                    mismatches.append("data")
                }
                if fetched.observedAt != status.observedAt {
                    mismatches.append("observedAt")
                }
                if fetched.snapshotUpdatedAt != status.snapshotUpdatedAt {
                    mismatches.append("snapshotUpdatedAt")
                }
                if abs(fetched.publishedAt.timeIntervalSince(status.publishedAt)) > 0.01 {
                    mismatches.append("publishedAt")
                }
                if fetched.isWarning != status.isWarning {
                    mismatches.append("isWarning")
                }
                if fetched.isDepleted != status.isDepleted {
                    mismatches.append("isDepleted")
                }
                if fetched.syncSource != status.syncSource {
                    mismatches.append("syncSource")
                }

                guard mismatches.isEmpty else {
                    print("FAIL: fetched ProviderStatus mismatches on: \(mismatches.joined(separator: ", "))")
                    print("  saved:   \(status)")
                    print("  fetched: \(fetched)")
                    exit(1)
                }
                print("PASS: fetched record decodes back to an equivalent ProviderStatus (all 13 fields checked)")
            } catch {
                print("FAIL: fetch/decode threw: \(error)")
                exit(1)
            }

            do {
                _ = try await container.privateCloudDatabase.deleteRecord(withID: recordID)
                print("PASS: cleaned up schema-gate record")
            } catch {
                print("WARN: cleanup delete threw (non-fatal): \(error)")
            }

            print("T2.5 SCHEMA GATE: PASS (all ProviderStatus fields registered; save->fetch round-trips in this environment)")
            exit(0)
        }
    }
#endif
