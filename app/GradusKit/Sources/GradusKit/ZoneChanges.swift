import Foundation

/// Read side of the delta-sync seam (§6.5/CR-4, T4.1). Deliberately abstract
/// over `Data` tokens, not `CKServerChangeToken` -- the token has no public
/// initializer (can't be constructed in a test), so the real
/// `CKFetchRecordZoneChangesOperation` + `NSKeyedArchiver` bridging lives in
/// the CloudKit adapter (`CKZoneChangesFetcher` in `app/Shared`); this
/// protocol and its outcome are what the testable reconciliation logic
/// (`DashboardViewModel`) actually depends on.
public protocol ZoneChangesFetcher: Sendable {
    func fetchZoneChanges(sinceToken token: Data?) async -> ZoneChangesOutcome
}

/// Every distinct thing a zone-changes fetch can report, including the two
/// PM-3 recovery cases. `GradusZone` is Mac-owned (idempotent creation,
/// T2a.2) -- iOS is consumer-only and cannot recreate it, so `.zoneNotFound`/
/// `.zoneDeleted` are handled as "reset to waiting for first publish," not
/// as "recreate the zone."
public enum ZoneChangesOutcome: Sendable {
    case success(changed: [ProviderStatus], deletedProviderNames: [String], newToken: Data?)
    /// Typed companion for mixed `GradusZone` changes. Provider deletion names
    /// and presence installation IDs never share a routing bucket.
    case successWithPresence(
        changed: [ProviderStatus],
        deletedProviderNames: [String],
        changedPresence: [DevicePresence],
        deletedPresenceInstallationIDs: [String],
        newToken: Data?
    )
    case changeTokenExpired
    case zoneNotFound
    case zoneDeleted
    case failure
}

public extension [ProviderStatus] {
    /// One status per provider name, keeping the last one seen, in the order
    /// each name first appeared. A zone-changes fetch can report the same
    /// record more than once when the Mac republishes mid-fetch, and every
    /// by-name lookup downstream assumes names are unique: on 2026-10-07 a
    /// duplicate reached the iOS cache and `Dictionary(uniqueKeysWithValues:)`
    /// trapped on every push, pinning the dashboard to 39-hour-old data.
    func uniquedByProviderName() -> [ProviderStatus] {
        var latest: [String: ProviderStatus] = [:]
        for status in self {
            latest[status.providerName] = status
        }
        var seen: Set<String> = []
        return map(\.providerName)
            .filter { seen.insert($0).inserted }
            .compactMap { latest[$0] }
    }
}
