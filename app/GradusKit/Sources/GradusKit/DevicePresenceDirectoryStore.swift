import Foundation

/// Consumer-side directory used by Mac Settings. It intentionally retains no
/// last-seen/history list: only records returned by the current fetch and still
/// inside their lease are exposed.
public actor DevicePresenceDirectoryStore {
    private let client: any DevicePresenceClient
    public private(set) var devices: [DevicePresence] = []

    public init(client: any DevicePresenceClient) {
        self.client = client
    }

    @discardableResult
    public func start(now: Date = Date()) async -> Bool {
        do { try await client.subscribe() } catch { return false }
        return await refresh(now: now)
    }

    @discardableResult
    public func refresh(now: Date = Date()) async -> Bool {
        do {
            let fetched = try await client.fetchAll()
            let expired = DevicePresenceDirectory.expired(fetched, at: now)
            for record in expired {
                _ = try? await client.delete(installationID: record.installationID)
            }
            devices = DevicePresenceDirectory.active(fetched, at: now)
            return true
        } catch {
            // An unavailable account/network must not leave stale presence in
            // the active-device UI. The next subscription/foreground refresh
            // repopulates from CloudKit.
            devices = []
            return false
        }
    }
}
