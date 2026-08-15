import CloudKit
import Foundation

#if DEBUG
    /// T0.3 hard-seam spike (throwaway): proves CloudKit auth + a real round-trip
    /// against the Development database before any feature code is written.
    /// Invoke with `--cloudkit-spike`; prints PASS/FAIL lines and exits.
    enum CloudKitSpike {
        static func run() async -> Never {
            let container = CKContainer(identifier: "iCloud.com.zerodelta.gradus")
            await verifyAccountStatus(container)

            let database = container.privateCloudDatabase
            let zone = CKRecordZone(zoneName: "GradusZone")
            await saveZone(zone, in: database)

            let recordID = CKRecord.ID(recordName: "spike-provider-status", zoneID: zone.zoneID)
            let record = makeSpikeRecord(recordID: recordID)
            await saveRecord(record, in: database)
            await verifyRoundTrip(recordID: recordID, in: database)
            await cleanUp(recordID: recordID, in: database)

            print("CLOUDKIT SPIKE: ALL PASS")
            exit(0)
        }

        private static func verifyAccountStatus(_ container: CKContainer) async {
            do {
                let status = try await container.accountStatus()
                print("accountStatus: \(status.rawValue) (\(describe(status)))")
                guard status == .available else {
                    print("FAIL: accountStatus is not .available")
                    exit(1)
                }
                print("PASS: accountStatus == .available")
            } catch {
                print("FAIL: accountStatus threw: \(error)")
                exit(1)
            }
        }

        private static func saveZone(_ zone: CKRecordZone, in database: CKDatabase) async {
            do {
                _ = try await database.save(zone)
                print("PASS: saved/confirmed zone GradusZone")
            } catch {
                print("FAIL: zone save threw: \(error)")
                exit(1)
            }
        }

        private static func makeSpikeRecord(recordID: CKRecord.ID) -> CKRecord {
            let record = CKRecord(recordType: "ProviderStatus", recordID: recordID)
            record["providerName"] = "spike-provider" as CKRecordValue
            record["usagePercent"] = 42.0 as CKRecordValue
            record["observedAt"] = Date() as CKRecordValue
            return record
        }

        private static func saveRecord(_ record: CKRecord, in database: CKDatabase) async {
            do {
                _ = try await database.save(record)
                print("PASS: saved ProviderStatus record")
            } catch {
                print("FAIL: record save threw: \(error)")
                exit(1)
            }
        }

        private static func verifyRoundTrip(recordID: CKRecord.ID, in database: CKDatabase) async {
            do {
                let fetched = try await database.record(for: recordID)
                let name = fetched["providerName"] as? String
                let usage = fetched["usagePercent"] as? Double
                guard name == "spike-provider", usage == 42.0 else {
                    print(
                        "FAIL: fetched record fields mismatch: name=\(String(describing: name)) "
                            + "usage=\(String(describing: usage))"
                    )
                    exit(1)
                }
                print("PASS: fetched record round-trips correctly")
            } catch {
                print("FAIL: record fetch threw: \(error)")
                exit(1)
            }
        }

        /// Clean up the spike record/zone so nothing lingers in the user's real DB.
        private static func cleanUp(recordID: CKRecord.ID, in database: CKDatabase) async {
            do {
                _ = try await database.deleteRecord(withID: recordID)
                print("PASS: cleaned up spike record")
            } catch {
                print("WARN: cleanup delete threw (non-fatal): \(error)")
            }
        }

        private static func describe(_ status: CKAccountStatus) -> String {
            switch status {
            case .available: return "available"
            case .noAccount: return "noAccount"
            case .restricted: return "restricted"
            case .couldNotDetermine: return "couldNotDetermine"
            case .temporarilyUnavailable: return "temporarilyUnavailable"
            @unknown default: return "unknown"
            }
        }
    }
#endif
