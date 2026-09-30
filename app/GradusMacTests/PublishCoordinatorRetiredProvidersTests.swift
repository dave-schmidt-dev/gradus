import CloudKit
import Foundation
import GradusKit
@testable import GradusMac
import Testing

@Test func purgingRetiredProvidersDeletesEachRetiredRecordOnce() async {
    let database = MockCloudDatabase()
    let coordinator = PublishCoordinator(database: database, zoneID: zoneID)

    await coordinator.purgeRetiredProviders()
    await coordinator.purgeRetiredProviders()

    let deleted = await database.deletedRecordIDs
    #expect(
        deleted == ["Codex (Spark)", "Vibe", "Vibe Code"].map {
            CKRecord.ID(recordName: $0, zoneID: zoneID)
        }
    )
}
