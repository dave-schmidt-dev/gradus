import Foundation
import GradusKit

public enum CloudSyncState: Equatable, Sendable {
    case idle
    case publishing
    case synced
    case failed
}

/// Observable state the menu content view renders from, and the single
/// place the opt-in sync toggle / snapshot data converge. Decoupled from
/// `PublishPipeline`'s CloudKit plumbing so `MenuContentView` can be
/// snapshot-tested from plain fixture data (T2b.1/T2b.4).
@MainActor
public final class PublisherViewModel: ObservableObject {
    @Published public private(set) var providers: [ProviderEntry] = []
    @Published public private(set) var updatedAt: String?
    @Published public var syncEnabled: Bool {
        didSet {
            defaults.set(syncEnabled, forKey: Self.syncEnabledKey)
            if !syncEnabled {
                syncOperationID &+= 1
                syncState = .idle
            }
        }
    }
    @Published public var launchAtLoginEnabled: Bool
    @Published public private(set) var syncState: CloudSyncState = .idle
    /// When the last publish actually succeeded. Persisted, because the state
    /// enum above resets to `.idle` on every launch: a menu-bar agent that has
    /// been running for a week would otherwise claim it had never synced until
    /// the next snapshot changed, which is exactly when a user checks.
    @Published public private(set) var lastSyncedAt: Date?
    private var syncOperationID: UInt64 = 0

    static let syncEnabledKey = "iCloudSyncEnabled"
    static let lastSyncedAtKey = "iCloudLastSyncedAt"

    /// Injectable so tests do not write to the shipping app's own preference
    /// domain. That is not hypothetical: this bundle is hosted, so
    /// `UserDefaults.standard` in a test *is* GradusMac's real preferences, and
    /// an existing sync test silently began stamping a live timestamp into them
    /// the moment `cloudSyncDidSucceed` started persisting one.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Default OFF: usage data leaves the device only on explicit opt-in.
        self.syncEnabled = defaults.bool(forKey: Self.syncEnabledKey)
        self.launchAtLoginEnabled = LaunchAtLoginManager.isEnabled
        // `object(forKey:)` rather than `double(forKey:)` -- the latter returns
        // 0 for a missing key, which would render as 1970 instead of "never".
        self.lastSyncedAt = (defaults.object(forKey: Self.lastSyncedAtKey) as? Double)
            .map { Date(timeIntervalSince1970: $0) }
    }

    public func apply(_ payload: SnapshotPayload) {
        providers = payload.providers
        updatedAt = payload.updatedAt
    }

    @discardableResult
    public func cloudSyncDidStart() -> UInt64? {
        guard syncEnabled else { return nil }
        syncOperationID &+= 1
        syncState = .publishing
        return syncOperationID
    }

    /// - Parameter at: Injectable so tests assert a known timestamp rather
    ///   than racing the clock.
    public func cloudSyncDidSucceed(operationID: UInt64, at date: Date = Date()) {
        guard syncEnabled, operationID == syncOperationID else { return }
        syncState = .synced
        lastSyncedAt = date
        defaults.set(date.timeIntervalSince1970, forKey: Self.lastSyncedAtKey)
    }

    public func cloudSyncDidFail(operationID: UInt64) {
        guard syncEnabled, operationID == syncOperationID else { return }
        syncState = .failed
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginManager.setEnabled(enabled)
            launchAtLoginEnabled = LaunchAtLoginManager.isEnabled
        } catch {
            // Reflect whatever SMAppService actually did rather than assume
            // the requested state took effect.
            launchAtLoginEnabled = LaunchAtLoginManager.isEnabled
        }
    }
}
