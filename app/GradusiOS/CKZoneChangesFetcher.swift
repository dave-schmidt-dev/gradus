import CloudKit
import Foundation
import GradusKit

/// Real `ZoneChangesFetcher` conformance backed by
/// `CKFetchRecordZoneChangesOperation` against `GradusZone` (T4.1/CR-4). The
/// `CKServerChangeToken`<->`Data` bridging uses the exact `NSKeyedArchiver`/
/// `NSKeyedUnarchiver` pattern Apple documents on `CKServerChangeToken`
/// itself -- confirmed by reading the real SDK header, not guessed -- since
/// the token has no public initializer and can't be round-tripped any other
/// way.
public struct CKZoneChangesFetcher: ZoneChangesFetcher {
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    public init(database: CKDatabase, zoneID: CKRecordZone.ID) {
        self.database = database
        self.zoneID = zoneID
    }

    // The CloudKit operation's callbacks and typed routing must stay together.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    public func fetchZoneChanges(sinceToken token: Data?) async -> ZoneChangesOutcome {
        let previousToken = token.flatMap(Self.decodeToken)
        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = previousToken

        var changed: [ProviderStatus] = []
        var deletedProviderNames: [String] = []
        var changedPresence: [DevicePresence] = []
        var deletedPresenceInstallationIDs: [String] = []

        return await withCheckedContinuation { continuation in
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID], configurationsByRecordZoneID: [zoneID: config]
            )
            operation.fetchAllChanges = true

            operation.recordWasChangedBlock = { _, result in
                guard case let .success(record) = result else { return }
                if record.recordType == CloudKitConstants.recordType {
                    if let status = try? ProviderStatus(record: record) {
                        changed.append(status)
                    }
                } else if record.recordType == CloudKitConstants.devicePresenceRecordType,
                          let presence = try? DevicePresence(record: record) {
                    changedPresence.append(presence)
                }
            }
            operation.recordWithIDWasDeletedBlock = { recordID, recordType in
                guard let route = DevicePresenceDeletionRouter.route(
                    recordName: recordID.recordName, recordType: recordType
                ) else { return }
                switch route {
                case let .presence(installationID):
                    deletedPresenceInstallationIDs.append(installationID)
                case let .provider(providerName):
                    deletedProviderNames.append(providerName)
                }
            }

            var zoneOutcome: ZoneChangesOutcome?
            operation.recordZoneFetchResultBlock = { _, result in
                switch result {
                case let .success((serverChangeToken, _, _)):
                    // `serverChangeToken` is non-optional on success --
                    // confirmed empirically (an initial `.flatMap` guess
                    // assuming it was optional crashed the type-checker's
                    // diagnostic engine rather than reporting cleanly;
                    // isolated via a standalone `swiftc -typecheck` probe).
                    let newToken = Self.encodeToken(serverChangeToken)
                    zoneOutcome = .successWithPresence(
                        changed: changed, deletedProviderNames: deletedProviderNames,
                        changedPresence: changedPresence,
                        deletedPresenceInstallationIDs: deletedPresenceInstallationIDs,
                        newToken: newToken
                    )
                case let .failure(error):
                    zoneOutcome = Self.classify(error)
                }
            }

            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: zoneOutcome ?? .failure)
                case let .failure(error):
                    continuation.resume(returning: zoneOutcome ?? Self.classify(error))
                }
            }

            database.add(operation)
        }
    }

    private static func classify(_ error: Error) -> ZoneChangesOutcome {
        guard let ckError = error as? CKError else { return .failure }
        switch ckError.code {
        case .changeTokenExpired: return .changeTokenExpired
        case .zoneNotFound: return .zoneNotFound
        case .userDeletedZone: return .zoneDeleted
        default: return .failure
        }
    }

    private static func decodeToken(_ data: Data) -> CKServerChangeToken? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        let token = coder.decodeObject(of: CKServerChangeToken.self, forKey: Self.tokenCoderKey)
        coder.finishDecoding()
        return token
    }

    private static func encodeToken(_ token: CKServerChangeToken) -> Data? {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        coder.encode(token, forKey: Self.tokenCoderKey)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static let tokenCoderKey = "token"
}
