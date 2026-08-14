import Foundation

/// Offline last-synced cache + persisted CloudKit change-token bytes
/// (T3.2). The change token is stored as opaque `Data` -- the real
/// `CKServerChangeToken` <-> `Data` archiving happens at the Phase-4
/// `CKFetchRecordZoneChangesOperation` call site (the only place that can
/// actually produce or consume a real token); this store only owns
/// persistence, so it's testable now with synthetic `Data`.
public protocol LocalCacheStore: Sendable {
    func loadCachedStatuses() -> [ProviderStatus]
    func lastSyncedAt() -> Date?
    func saveCachedStatuses(_ statuses: [ProviderStatus], syncedAt: Date) throws

    func loadChangeToken() -> Data?
    func saveChangeToken(_ token: Data?) throws

    func clear() throws
}

private struct CachePayload: Codable {
    let statuses: [ProviderStatus]
    let syncedAt: Date
}

/// Disk-backed implementation: JSON files in a caller-supplied directory
/// (the app injects its Application Support directory; tests inject a temp
/// directory instead of touching the real filesystem location).
public final class FileLocalCacheStore: LocalCacheStore {
    private let cacheFileURL: URL
    private let tokenFileURL: URL

    public init(directory: URL) {
        cacheFileURL = directory.appendingPathComponent("last-synced-cache.json")
        tokenFileURL = directory.appendingPathComponent("change-token.data")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func loadCachedStatuses() -> [ProviderStatus] {
        loadPayload()?.statuses ?? []
    }

    public func lastSyncedAt() -> Date? {
        loadPayload()?.syncedAt
    }

    public func saveCachedStatuses(_ statuses: [ProviderStatus], syncedAt: Date) throws {
        let payload = CachePayload(statuses: statuses, syncedAt: syncedAt)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: cacheFileURL, options: .atomic)
    }

    public func loadChangeToken() -> Data? {
        try? Data(contentsOf: tokenFileURL)
    }

    public func saveChangeToken(_ token: Data?) throws {
        guard let token else {
            try? FileManager.default.removeItem(at: tokenFileURL)
            return
        }
        try token.write(to: tokenFileURL, options: .atomic)
    }

    public func clear() throws {
        try? FileManager.default.removeItem(at: cacheFileURL)
        try? FileManager.default.removeItem(at: tokenFileURL)
    }

    private func loadPayload() -> CachePayload? {
        guard let data = try? Data(contentsOf: cacheFileURL) else { return nil }
        return try? JSONDecoder().decode(CachePayload.self, from: data)
    }
}
