import CloudKit
import Foundation
@testable import GradusKit
import Testing

private actor PresenceClientStub: DevicePresenceClient {
    var records: [DevicePresence] = []
    var deleted: [String] = []
    var shouldFail = false
    var subscribed = false

    func setRecords(_ records: [DevicePresence]) {
        self.records = records
    }

    func setFailure(_ value: Bool) {
        shouldFail = value
    }

    func upsert(_ presence: DevicePresence) async throws {
        if shouldFail {
            throw CKError(.networkFailure)
        }
        records.removeAll { $0.installationID == presence.installationID }
        records.append(presence)
    }

    func delete(installationID: String) async throws {
        if shouldFail {
            throw CKError(.networkFailure)
        }
        deleted.append(installationID)
        records.removeAll { $0.installationID == installationID }
    }

    func fetchAll() async throws -> [DevicePresence] {
        if shouldFail {
            throw CKError(.networkFailure)
        }
        return records
    }

    func subscribe() async throws {
        if shouldFail {
            throw CKError(.networkFailure)
        }
        subscribed = true
    }
}

private let presenceZone = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)

@Test func presenceRecordContainsOnlyApprovedFieldsAndOpaqueKey() throws {
    let id = "123E4567-E89B-12D3-A456-426614174000"
    let presence = DevicePresence(installationID: id, displayName: .iPhone, expiresAt: Date(timeIntervalSince1970: 100))
    let record = try presence.toCKRecord(zoneID: presenceZone)
    #expect(record.recordType == CloudKitConstants.devicePresenceRecordType)
    #expect(record.recordID.recordName == id)
    #expect(Set(record.allKeys()) == ["displayName", "expiresAt"])
    #expect(try DevicePresence(record: record) == presence)
}

@Test func installationIDIsStableInAppContainerAndGeneratedOnce() throws {
    let defaults = try #require(UserDefaults(suiteName: "presence-id-\(UUID().uuidString)"))
    let generated = LockBox()
    let store = DevicePresenceInstallationStore(defaults: defaults) {
        generated.value += 1
        return "123E4567-E89B-12D3-A456-426614174000"
    }
    let first = store.installationID()
    let second = store.installationID()
    #expect(first == second)
    #expect(generated.value == 1)
}

@Test func duplicateGenericNamesAreRetainedAndExpiredRecordsAreNotVisible() {
    let now = Date(timeIntervalSince1970: 100)
    let records = [
        DevicePresence(
            installationID: "123E4567-E89B-12D3-A456-426614174000", displayName: .iPhone,
            expiresAt: now.addingTimeInterval(60)
        ),
        DevicePresence(
            installationID: "223E4567-E89B-12D3-A456-426614174000", displayName: .iPhone,
            expiresAt: now.addingTimeInterval(120)
        ),
        DevicePresence(
            installationID: "323E4567-E89B-12D3-A456-426614174000", displayName: .iPad,
            expiresAt: now.addingTimeInterval(-1)
        )
    ]
    let active = DevicePresenceDirectory.active(records, at: now)
    #expect(active.count == 2)
    #expect(active.map(\.displayName) == [.iPhone, .iPhone])
}

@Test func mixedZoneDeletionRoutesByObservedRecordType() {
    let presenceID = "123E4567-E89B-12D3-A456-426614174000"
    #expect(
        DevicePresenceDeletionRouter.route(
            recordName: presenceID, recordType: CloudKitConstants.devicePresenceRecordType
        )
            == .presence(presenceID)
    )
    #expect(
        DevicePresenceDeletionRouter.route(recordName: "Codex", recordType: CloudKitConstants.recordType)
            == .provider("Codex")
    )
    #expect(DevicePresenceDeletionRouter.route(recordName: "other", recordType: "Unknown") == nil)
}

@Test func leaseWriterDoesNotPublishOfflineOrDeniedPresence() async {
    let client = PresenceClientStub()
    let writer = DevicePresenceLeaseWriter(
        client: client,
        lease: DevicePresenceLease(
            installationID: "123E4567-E89B-12D3-A456-426614174000", displayName: .iPad
        )
    )
    #expect(await !writer.renew(liveMode: false, accountAvailable: true))
    #expect(await !writer.renew(liveMode: true, accountAvailable: false))
    #expect(await client.records.isEmpty)
}

@Test func directoryDeletesExpiredRecordsAndSubscribes() async {
    let client = PresenceClientStub()
    let now = Date(timeIntervalSince1970: 100)
    await client.setRecords([
        DevicePresence(
            installationID: "123E4567-E89B-12D3-A456-426614174000", displayName: .iPhone,
            expiresAt: now.addingTimeInterval(-1)
        ),
        DevicePresence(
            installationID: "223E4567-E89B-12D3-A456-426614174000", displayName: .iPad,
            expiresAt: now.addingTimeInterval(60)
        )
    ])
    let directory = DevicePresenceDirectoryStore(client: client)
    #expect(await directory.start(now: now))
    #expect(await client.subscribed)
    #expect(await (directory.devices).map(\.displayName) == [.iPad])
    #expect(await client.deleted == ["123E4567-E89B-12D3-A456-426614174000"])
}

@Test func directoryClearsVisibleDevicesWhenAccountIsUnavailable() async {
    let client = PresenceClientStub()
    let directory = DevicePresenceDirectoryStore(client: client)
    await client.setFailure(true)
    #expect(await !directory.refresh())
    #expect(await directory.devices.isEmpty)
}

private final class LockBox: @unchecked Sendable {
    var value = 0
}
