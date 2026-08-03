import CloudKit
import Foundation
import GradusKit

/// Read side of the CloudKit seam for iOS (Phase 3) -- queries every
/// `ProviderStatus` record in the shared `GradusZone` of the private
/// database and maps each via `ProviderStatus(record:)` (malformed/missing
/// `windowsJSON`/`dataJSON` degrade rather than throw there, per CV-3).
public struct CKCloudFetcher: CloudFetcher {
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID

    public init(database: CKDatabase, zoneID: CKRecordZone.ID) {
        self.database = database
        self.zoneID = zoneID
    }

    public func fetchAll() async throws -> [ProviderStatus] {
        let query = CKQuery(recordType: CloudKitConstants.recordType, predicate: NSPredicate(value: true))
        let (matchResults, _) = try await database.records(matching: query, inZoneWith: zoneID)
        return matchResults.compactMap { _, result in
            guard case .success(let record) = result else { return nil }
            return try? ProviderStatus(record: record)
        }
    }
}
