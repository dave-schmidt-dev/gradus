import CloudKit
import Foundation
import GradusKit

/// Thin abstraction over subscription save, mirroring `CloudDatabase` (Mac's
/// T2a.2) so subscription creation is testable without a live CloudKit
/// connection.
public protocol SubscriptionDatabase: Sendable {
    func saveSubscription(_ subscription: CKSubscription) async throws
    func deleteSubscription(withID subscriptionID: CKSubscription.ID) async throws
}

public struct CKSubscriptionDatabaseAdapter: SubscriptionDatabase {
    private let database: CKDatabase

    public init(database: CKDatabase) {
        self.database = database
    }

    public func saveSubscription(_ subscription: CKSubscription) async throws {
        _ = try await database.save(subscription)
    }

    public func deleteSubscription(withID subscriptionID: CKSubscription.ID) async throws {
        _ = try await database.deleteSubscription(withID: subscriptionID)
    }
}

public enum GradusSubscriptionID {
    public static let zoneSync = "gradus-zone-sync"
    public static let warning = "gradus-warning"
}

/// Localization key/args for the Plan A warning banner (§6.4/B-3/T4.2):
/// `alertLocalizationArgs` substitutes *top-level* `ProviderStatus` record
/// field values into the format string bundled at this key in
/// `Localizable.strings` -- confirmed against the real `CKSubscription.h`
/// (`alertLocalizationKey`/`alertLocalizationArgs: [CKRecord.FieldKey]`),
/// not guessed.
public enum WarningAlertLocalization {
    public static let key = "WARN_FMT"
    public static let args: [CKRecord.FieldKey] = ["providerDisplayName"]
}

/// Two distinct subscriptions (CR-3): a zone subscription drives dashboard
/// sync on *any* `GradusZone` change; a query subscription is the
/// user-visible warning banner. A `CKRecordZoneSubscription` on the single
/// fixed `GradusZone` is used instead of the plan's literal
/// `CKDatabaseSubscription` wording -- deliberately: a database subscription
/// only reports "the database changed" and needs a second
/// `CKFetchDatabaseChangesOperation` round-trip to learn which zone, then a
/// per-zone token; with exactly one zone, a zone subscription reports "this
/// zone changed" directly and matches T3.2's single persisted-token model.
public struct CKSubscriptionManager: Sendable {
    private let database: SubscriptionDatabase
    private let zoneID: CKRecordZone.ID

    public init(database: SubscriptionDatabase, zoneID: CKRecordZone.ID) {
        self.database = database
        self.zoneID = zoneID
    }

    /// Idempotent (same reasoning as T2a.2's zone creation, PM-8): saving a
    /// subscription with an existing ID updates it in place, so this can
    /// run unconditionally on every launch/relaunch.
    public func subscribeToZoneChanges() async throws {
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: GradusSubscriptionID.zoneSync)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        try await database.saveSubscription(subscription)
    }

    public func subscribeToWarnings() async throws {
        let predicate = NSPredicate(format: "isWarning == 1")
        let subscription = CKQuerySubscription(
            recordType: CloudKitConstants.recordType,
            predicate: predicate,
            subscriptionID: GradusSubscriptionID.warning,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate])
        subscription.zoneID = zoneID
        let info = CKSubscription.NotificationInfo()
        info.alertLocalizationKey = WarningAlertLocalization.key
        info.alertLocalizationArgs = WarningAlertLocalization.args
        info.shouldBadge = true
        subscription.notificationInfo = info
        try await database.saveSubscription(subscription)
    }

    /// P5/T5.1: the disable-path counterpart to `subscribeToWarnings()`,
    /// delete-by-ID (mirroring the save-by-ID idempotency pattern above).
    /// Unlike the enable path (best-effort, `try?` at call sites), this is
    /// deliberately allowed to throw -- callers success-gate the
    /// user-visible "notifications off" state on this actually succeeding
    /// (Key decision #2, `ios-design-system-2026-08-03.md`), so a stale
    /// server-side `CKQuerySubscription` never keeps firing while the UI
    /// claims it's off.
    public func unsubscribeFromWarnings() async throws {
        try await database.deleteSubscription(withID: GradusSubscriptionID.warning)
    }
}
