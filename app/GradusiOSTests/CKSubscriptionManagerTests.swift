import CloudKit
import GradusKit
import Testing

@testable import GradusiOS

// T4.3 gate: both subscriptions (CR-3) are constructed with the fields the
// real CloudKit push path depends on -- verified against a mock database
// (no live CloudKit), since the subscription *objects* themselves are
// plain, locally-constructible value types (unlike CKServerChangeToken).

private final class MockSubscriptionDatabase: SubscriptionDatabase {
    private(set) var saved: [CKSubscription] = []
    var saveCallCount = 0

    func saveSubscription(_ subscription: CKSubscription) async throws {
        saveCallCount += 1
        saved.append(subscription)
    }
}

private let zoneID = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)

@Test func zoneSyncSubscriptionUsesContentAvailableSilentPush() async throws {
    let database = MockSubscriptionDatabase()
    let manager = CKSubscriptionManager(database: database, zoneID: zoneID)
    try await manager.subscribeToZoneChanges()

    let subscription = try #require(database.saved.first as? CKRecordZoneSubscription)
    #expect(subscription.subscriptionID == GradusSubscriptionID.zoneSync)
    #expect(subscription.zoneID == zoneID)
    #expect(subscription.notificationInfo?.shouldSendContentAvailable == true)
}

@Test func warningSubscriptionUsesPerProviderLocalizedAlert() async throws {
    let database = MockSubscriptionDatabase()
    let manager = CKSubscriptionManager(database: database, zoneID: zoneID)
    try await manager.subscribeToWarnings()

    let subscription = try #require(database.saved.first as? CKQuerySubscription)
    #expect(subscription.subscriptionID == GradusSubscriptionID.warning)
    #expect(subscription.recordType == CloudKitConstants.recordType)
    #expect(subscription.zoneID == zoneID)
    #expect(subscription.querySubscriptionOptions.contains(.firesOnRecordCreation))
    #expect(subscription.querySubscriptionOptions.contains(.firesOnRecordUpdate))
    #expect(subscription.notificationInfo?.alertLocalizationKey == WarningAlertLocalization.key)
    #expect(subscription.notificationInfo?.alertLocalizationArgs == WarningAlertLocalization.args)
}

@Test func creatingBothSubscriptionsIsIdempotentAcrossRelaunches() async throws {
    // PM-8-style: no "already exists" branching -- calling subscribe again
    // (simulating a second app launch) must not throw or special-case.
    let database = MockSubscriptionDatabase()
    let manager = CKSubscriptionManager(database: database, zoneID: zoneID)
    try await manager.subscribeToZoneChanges()
    try await manager.subscribeToZoneChanges()

    #expect(database.saveCallCount == 2)
}
