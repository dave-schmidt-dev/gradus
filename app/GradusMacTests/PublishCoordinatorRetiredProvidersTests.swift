import CloudKit
import Foundation
import GradusKit
@testable import GradusMac
import Testing

@Test func purgingRetiredProvidersDeletesTheSparkRecordOnce() async {
    let database = MockCloudDatabase()
    let coordinator = PublishCoordinator(database: database, zoneID: zoneID)

    await coordinator.purgeRetiredProviders()
    await coordinator.purgeRetiredProviders()

    let deleted = await database.deletedRecordIDs
    #expect(deleted == [CKRecord.ID(recordName: "Codex (Spark)", zoneID: zoneID)])
}
