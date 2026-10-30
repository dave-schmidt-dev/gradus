import CloudKit
import Foundation
@testable import GradusiOS
import GradusKit
import Testing

@Test func zoneReadsRunPromptlyAndHaveBoundedNetworkWaits() {
    let zoneID = CKRecordZone.ID(zoneName: "GradusZone", ownerName: CKCurrentUserDefaultName)
    let operation = CKZoneChangesFetcher.makeOperation(zoneID: zoneID, previousToken: nil)
    #expect(operation.configuration.qualityOfService == .userInitiated)
    #expect(operation.configuration.timeoutIntervalForRequest == 30)
    #expect(operation.configuration.timeoutIntervalForResource == 60)
    #expect(operation.fetchAllChanges)
    #expect(operation.recordZoneIDs == [zoneID])
    #expect(operation.configurationsByRecordZoneID?[zoneID]?.previousServerChangeToken == nil)
}

private actor PresenceSaverProbe {
    private(set) var policies: [CKModifyRecordsOperation.RecordSavePolicy] = []

    func save(record: CKRecord, policy: CKModifyRecordsOperation.RecordSavePolicy) -> CKRecord {
        policies.append(policy)
        return record
    }
}

@Test func devicePresenceRenewalUsesChangedKeysAndChecksSaveResult() async throws {
    let probe = PresenceSaverProbe()
    let zoneID = CKRecordZone.ID(zoneName: "GradusZone", ownerName: CKCurrentUserDefaultName)
    let client = CKDevicePresenceClient(zoneID: zoneID) { record, policy in
        await probe.save(record: record, policy: policy)
    }
    let presence = DevicePresence(
        installationID: UUID().uuidString, displayName: .iPhone, expiresAt: Date().addingTimeInterval(600)
    )

    try await client.upsert(presence)

    let policies = await probe.policies
    #expect(policies.count == 1)
    guard let policy = policies.first else { return }
    if case .changedKeys = policy {
        // The renewal path must preserve the existing record and update only
        // its changed lease fields.
    } else {
        Issue.record("DevicePresence renewal did not use changedKeys")
    }
}
