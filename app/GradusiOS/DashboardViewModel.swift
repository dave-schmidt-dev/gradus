import CloudKit
import Foundation
import GradusKit

/// The three distinct empty states the dashboard must never collapse
/// (CV-5) -- each has its own copy, its own fix action, and its own
/// snapshot baseline (T3.3/T3.5).
public enum DashboardEmptyState: Equatable {
    /// Not signed in to iCloud at the OS level. The in-app toggle can't fix
    /// this; only a deep link to Settings can.
    case notSignedIn
    /// Signed in, but the in-app "Enable iCloud Sync" toggle is off.
    case syncDisabled
    /// Signed in, toggle on, zero records yet -- waiting for the Mac's
    /// first publish. iOS has no independent data source (§5.4): this
    /// state can only resolve once the Mac writes something.
    case waitingForFirstPublish
}

/// Observable state the dashboard view renders from -- owns the opt-in
/// sync toggle, the offline cache, and the CloudKit fetch, mirroring
/// `PublisherViewModel` on the Mac side. Decoupled from live CloudKit so
/// the view can be snapshot-tested from seeded fixture data (T3.5).
@MainActor
public final class DashboardViewModel: ObservableObject {
    @Published public private(set) var providers: [ProviderStatus] = []
    @Published public private(set) var lastSyncedAt: Date?
    @Published public var syncEnabled: Bool {
        didSet { UserDefaults.standard.set(syncEnabled, forKey: Self.syncEnabledKey) }
    }
    @Published public private(set) var accountStatus: CKAccountStatus = .couldNotDetermine
    @Published public private(set) var isSyncing = false

    static let syncEnabledKey = "iCloudSyncEnabled"

    private let cache: LocalCacheStore
    private let fetcher: CloudFetcher?
    private let accountSource: AccountStatusSource?

    public init(cache: LocalCacheStore, fetcher: CloudFetcher? = nil, accountSource: AccountStatusSource? = nil) {
        self.cache = cache
        self.fetcher = fetcher
        self.accountSource = accountSource
        // Default OFF: usage data leaves the device only on explicit opt-in.
        self.syncEnabled = UserDefaults.standard.bool(forKey: Self.syncEnabledKey)
        self.providers = cache.loadCachedStatuses()
        self.lastSyncedAt = cache.lastSyncedAt()
    }

    /// `nil` means "render the populated dashboard" -- there is data (fresh
    /// or offline-stale) to show.
    public var emptyState: DashboardEmptyState? {
        guard providers.isEmpty else { return nil }
        if accountStatus != .available { return .notSignedIn }
        if !syncEnabled { return .syncDisabled }
        return .waitingForFirstPublish
    }

    public func refreshAccountStatus() async {
        guard let accountSource else { return }
        if let status = try? await accountSource.currentAccountStatus() {
            accountStatus = status
        }
    }

    /// Fetches the current CloudKit state and refreshes the offline cache.
    /// No-ops (leaving the last-known/cached state on screen) when sync is
    /// off or the account isn't ready -- CV-6's "distinct state, not silent
    /// failure" applies to the empty-state copy, not to spamming a fetch
    /// that would just fail.
    public func sync() async {
        guard syncEnabled, accountStatus == .available, let fetcher else { return }
        isSyncing = true
        defer { isSyncing = false }
        guard let fetched = try? await fetcher.fetchAll() else { return }
        providers = fetched
        let syncedAt = Date()
        lastSyncedAt = syncedAt
        try? cache.saveCachedStatuses(fetched, syncedAt: syncedAt)
    }
}
