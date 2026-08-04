import CloudKit
import Foundation
import GradusKit
import Testing

@testable import GradusiOS

// T4.3 gate: both subscriptions (CR-3) are constructed with the fields the
// real CloudKit push path depends on -- verified against a mock database
// (no live CloudKit), since the subscription *objects* themselves are
// plain, locally-constructible value types (unlike CKServerChangeToken).
//
// P5/T5.1 gate (added below the original T4.3 tests): `unsubscribeFromWarnings()`
// removes the subscription by ID, and a failed delete leaves
// `DashboardViewModel.notificationsEnabled` at `true` -- the success-gated
// toggle-off behavior from CR-5, exercised end-to-end through the real
// `DashboardViewModel.setNotificationsEnabled(_:)` against this same mock.

private struct MockDeleteError: Error {}

private final class MockSubscriptionDatabase: SubscriptionDatabase {
    private(set) var saved: [CKSubscription] = []
    var saveCallCount = 0
    private(set) var deletedSubscriptionIDs: [CKSubscription.ID] = []
    var deleteError: Error?

    func saveSubscription(_ subscription: CKSubscription) async throws {
        saveCallCount += 1
        saved.append(subscription)
    }

    func deleteSubscription(withID subscriptionID: CKSubscription.ID) async throws {
        if let deleteError {
            throw deleteError
        }
        deletedSubscriptionIDs.append(subscriptionID)
    }
}

/// A fresh suite per call, matching `DashboardViewModelSyncTests.swift`'s
/// `isolatedDefaults()` -- `.standard` is shared process-wide and these
/// tests persist `notificationsEnabled`/`syncEnabled`.
private func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "gradus-subscription-manager-tests-\(UUID().uuidString)")!
}

private func tempCache() -> FileLocalCacheStore {
    FileLocalCacheStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent(
            "gradus-subscription-manager-tests-\(UUID().uuidString)", isDirectory: true))
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

@Test func warningSubscriptionUsesSilentContentAvailablePush() async throws {
    let database = MockSubscriptionDatabase()
    let manager = CKSubscriptionManager(database: database, zoneID: zoneID)
    try await manager.subscribeToWarnings()

    let subscription = try #require(database.saved.first as? CKQuerySubscription)
    #expect(subscription.subscriptionID == GradusSubscriptionID.warning)
    #expect(subscription.recordType == CloudKitConstants.recordType)
    #expect(subscription.zoneID == zoneID)
    #expect(subscription.querySubscriptionOptions.contains(.firesOnRecordCreation))
    #expect(subscription.querySubscriptionOptions.contains(.firesOnRecordUpdate))
    #expect(subscription.notificationInfo?.shouldSendContentAvailable == true)
    #expect(subscription.notificationInfo?.alertLocalizationKey == nil)
    #expect(subscription.notificationInfo?.alertLocalizationArgs == nil)
    #expect(subscription.notificationInfo?.shouldBadge == false)
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

@Test func unsubscribeFromWarningsRemovesTheSubscriptionByID() async throws {
    let database = MockSubscriptionDatabase()
    let manager = CKSubscriptionManager(database: database, zoneID: zoneID)
    try await manager.unsubscribeFromWarnings()

    #expect(database.deletedSubscriptionIDs == [GradusSubscriptionID.warning])
}

@MainActor
@Test func failedUnsubscribeLeavesNotificationsEnabledTrue() async throws {
    let database = MockSubscriptionDatabase()
    database.deleteError = MockDeleteError()
    let manager = CKSubscriptionManager(database: database, zoneID: zoneID)

    let defaults = isolatedDefaults()
    defaults.set(true, forKey: DashboardViewModel.notificationsEnabledKey)
    let viewModel = DashboardViewModel(cache: tempCache(), subscriptionManager: manager, userDefaults: defaults)
    #expect(viewModel.notificationsEnabled)

    await viewModel.setNotificationsEnabled(false)

    #expect(viewModel.notificationsEnabled)
    #expect(viewModel.notificationsToggleError != nil)
    #expect(database.deletedSubscriptionIDs.isEmpty)
}

@MainActor
@Test func successfulUnsubscribeFlipsNotificationsEnabledFalse() async throws {
    let database = MockSubscriptionDatabase()
    let manager = CKSubscriptionManager(database: database, zoneID: zoneID)

    let defaults = isolatedDefaults()
    defaults.set(true, forKey: DashboardViewModel.notificationsEnabledKey)
    let viewModel = DashboardViewModel(cache: tempCache(), subscriptionManager: manager, userDefaults: defaults)

    await viewModel.setNotificationsEnabled(false)

    #expect(!viewModel.notificationsEnabled)
    #expect(viewModel.notificationsToggleError == nil)
    #expect(database.deletedSubscriptionIDs == [GradusSubscriptionID.warning])
}
