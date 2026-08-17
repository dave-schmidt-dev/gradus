import CloudKit
import Foundation
import GradusKit

public typealias DevicePresenceRecordSaver = @Sendable (
    CKRecord, CKModifyRecordsOperation.RecordSavePolicy
) async throws -> CKRecord

/// CloudKit transport for the typed private-zone presence record. Provider
/// records use their own mapper and never pass through this type.
public struct CKDevicePresenceClient: DevicePresenceClient {
    public static let upsertSavePolicy: CKModifyRecordsOperation.RecordSavePolicy = .changedKeys

    private let database: CKDatabase?
    private let zoneID: CKRecordZone.ID
    private let saveRecord: DevicePresenceRecordSaver

    public init(
        database: CKDatabase, zoneID: CKRecordZone.ID,
        saveRecord: DevicePresenceRecordSaver? = nil
    ) {
        self.database = database
        self.zoneID = zoneID
        self.saveRecord = saveRecord ?? { record, policy in
            try await Self.modify(record: record, in: database, savePolicy: policy)
        }
    }

    init(zoneID: CKRecordZone.ID, saveRecord: @escaping DevicePresenceRecordSaver) {
        database = nil
        self.zoneID = zoneID
        self.saveRecord = saveRecord
    }

    public func upsert(_ presence: DevicePresence) async throws {
        let record = try presence.toCKRecord(zoneID: zoneID)
        guard record.recordType == CloudKitConstants.devicePresenceRecordType else {
            throw DevicePresenceMappingError.wrongRecordType
        }
        _ = try await saveRecord(record, Self.upsertSavePolicy)
    }

    public func delete(installationID: String) async throws {
        guard let database else { throw DevicePresenceClientError.databaseUnavailable }
        let probe = DevicePresence(installationID: installationID, displayName: .iPhone, expiresAt: .distantFuture)
        let recordID = try probe.toCKRecord(zoneID: zoneID).recordID
        _ = try await database.deleteRecord(withID: recordID)
    }

    public func fetchAll() async throws -> [DevicePresence] {
        guard let database else { throw DevicePresenceClientError.databaseUnavailable }
        let query = CKQuery(
            recordType: CloudKitConstants.devicePresenceRecordType,
            predicate: NSPredicate(value: true)
        )
        let results = try await database.records(matching: query, inZoneWith: zoneID)
        return results.matchResults.compactMap { _, result in
            guard case let .success(record) = result else { return nil }
            return try? DevicePresence(record: record)
        }
    }

    public func subscribe() async throws {
        guard let database else { throw DevicePresenceClientError.databaseUnavailable }
        let subscription = CKRecordZoneSubscription(
            zoneID: zoneID,
            subscriptionID: CloudKitConstants.devicePresenceSubscriptionID
        )
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        _ = try await database.save(subscription)
    }

    private static func modify(
        record: CKRecord, in database: CKDatabase,
        savePolicy: CKModifyRecordsOperation.RecordSavePolicy
    ) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
            operation.savePolicy = savePolicy
            operation.isAtomic = false

            var recordResult: Result<CKRecord, Error>?
            operation.perRecordSaveBlock = { recordID, result in
                guard recordID == record.recordID else { return }
                recordResult = result
            }
            operation.modifyRecordsResultBlock = { operationResult in
                if let recordResult {
                    continuation.resume(with: recordResult)
                } else {
                    switch operationResult {
                    case .success:
                        continuation.resume(throwing: DevicePresenceClientError.missingSaveResult)
                    case let .failure(error):
                        continuation.resume(throwing: error)
                    }
                }
            }
            database.add(operation)
        }
    }
}

public enum DevicePresenceClientError: Error, Equatable {
    case databaseUnavailable
    case missingSaveResult
}
