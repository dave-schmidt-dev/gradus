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
            UserDefaults.standard.set(syncEnabled, forKey: Self.syncEnabledKey)
            if !syncEnabled {
                syncOperationID &+= 1
                syncState = .idle
            }
        }
    }
    @Published public var launchAtLoginEnabled: Bool
    @Published public private(set) var syncState: CloudSyncState = .idle
    private var syncOperationID: UInt64 = 0

    static let syncEnabledKey = "iCloudSyncEnabled"

    public init() {
        // Default OFF: usage data leaves the device only on explicit opt-in.
        self.syncEnabled = UserDefaults.standard.bool(forKey: Self.syncEnabledKey)
        self.launchAtLoginEnabled = LaunchAtLoginManager.isEnabled
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

    public func cloudSyncDidSucceed(operationID: UInt64) {
        guard syncEnabled, operationID == syncOperationID else { return }
        syncState = .synced
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
