import CloudKit
import Foundation

extension PublishCoordinator {
    /// Provider buckets that no longer exist. The Mac used to publish a record
    /// for each and never deleted them, so they survive in iCloud and would keep
    /// showing on iPhone and iPad. Deleting the record removes it there too.
    static let retiredProviderNames = ["Codex (Spark)"]

    /// Deletes the records of retired provider buckets once per launch.
    /// Failure is logged and retried on the next launch; it never blocks a
    /// usage publish.
    public func purgeRetiredProviders() async {
        guard !retiredProvidersPurged else { return }
        let recordIDs = Self.retiredProviderNames.map {
            CKRecord.ID(recordName: $0, zoneID: zoneID)
        }
        do {
            try await database.deleteRecords(recordIDs)
            retiredProvidersPurged = true
        } catch {
            GradusLog.publish.warning("could not delete retired provider records: \(error)")
        }
    }
}
