import Foundation

/// Owns one mobile installation's foreground lease. CloudKit failures are
/// returned as `false`; the Mac's expiry filter remains authoritative when a
/// client disappears without a background callback.
public actor DevicePresenceLeaseWriter {
    private let client: any DevicePresenceClient
    private let lease: DevicePresenceLease

    public init(client: any DevicePresenceClient, lease: DevicePresenceLease) {
        self.client = client
        self.lease = lease
    }

    @discardableResult
    public func renew(
        now: Date = Date(),
        liveMode: Bool,
        accountAvailable: Bool,
        sampleMode: Bool = false,
        migrationRecovery: Bool = false
    ) async -> Bool {
        guard liveMode, accountAvailable, !sampleMode, !migrationRecovery else { return false }
        do {
            try await client.upsert(lease.presence(now: now))
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    public func remove() async -> Bool {
        do {
            try await client.delete(installationID: lease.installationID)
            return true
        } catch {
            return false
        }
    }
}
