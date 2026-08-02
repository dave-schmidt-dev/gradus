import Foundation
import GradusKit

/// Observable state the menu content view renders from, and the single
/// place the opt-in sync toggle / snapshot data converge. Decoupled from
/// `PublishPipeline`'s CloudKit plumbing so `MenuContentView` can be
/// snapshot-tested from plain fixture data (T2b.1/T2b.4).
@MainActor
public final class PublisherViewModel: ObservableObject {
    @Published public private(set) var providers: [ProviderEntry] = []
    @Published public private(set) var updatedAt: String?
    @Published public var syncEnabled: Bool {
        didSet { UserDefaults.standard.set(syncEnabled, forKey: Self.syncEnabledKey) }
    }
    @Published public var launchAtLoginEnabled: Bool

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
