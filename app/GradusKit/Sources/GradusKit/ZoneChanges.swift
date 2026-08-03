import Foundation

/// Read side of the delta-sync seam (§6.5/CR-4, T4.1). Deliberately abstract
/// over `Data` tokens, not `CKServerChangeToken` -- the token has no public
/// initializer (can't be constructed in a test), so the real
/// `CKFetchRecordZoneChangesOperation` + `NSKeyedArchiver` bridging lives in
/// the platform-specific adapter (`CKZoneChangesFetcher` in GradusiOS); this
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
    case changeTokenExpired
    case zoneNotFound
    case zoneDeleted
    case failure
}
