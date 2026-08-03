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
        didSet { userDefaults.set(syncEnabled, forKey: Self.syncEnabledKey) }
    }
    @Published public private(set) var accountStatus: CKAccountStatus = .couldNotDetermine
    @Published public private(set) var isSyncing = false

    static let syncEnabledKey = "iCloudSyncEnabled"

    private let cache: LocalCacheStore
    private let fetcher: CloudFetcher?
    private let accountSource: AccountStatusSource?
    private let zoneChangesFetcher: ZoneChangesFetcher?
    private let userDefaults: UserDefaults

    /// `userDefaults` defaults to `.standard` for production; tests inject
    /// a fresh per-test suite so `syncEnabled` (persisted here) can't leak
    /// state across test cases sharing a process, unlike `.standard`.
    public init(
        cache: LocalCacheStore,
        fetcher: CloudFetcher? = nil,
        accountSource: AccountStatusSource? = nil,
        zoneChangesFetcher: ZoneChangesFetcher? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.cache = cache
        self.fetcher = fetcher
        self.accountSource = accountSource
        self.zoneChangesFetcher = zoneChangesFetcher
        self.userDefaults = userDefaults
        // Default OFF: usage data leaves the device only on explicit opt-in.
        self.syncEnabled = userDefaults.bool(forKey: Self.syncEnabledKey)
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

    /// Callback target for `AccountStatusMonitor` (PM-16): applies a status
    /// change observed mid-session, including a `.CKAccountChanged` reset,
    /// and kicks a sync when the account newly becomes available.
    public func updateAccountStatus(_ status: CKAccountStatus) {
        let wasAvailable = accountStatus == .available
        accountStatus = status
        guard !wasAvailable, status == .available, syncEnabled else { return }
        Task { await self.sync() }
    }

    /// Entry point for a push-driven delta sync (T4.1): fetches only what
    /// changed in `GradusZone` since the persisted token and reconciles it
    /// into `providers`, rather than re-fetching everything (`sync()`'s
    /// full-fetch path, used on launch/pull-to-refresh).
    public func handleRemoteNotification() async {
        guard syncEnabled, accountStatus == .available, let zoneChangesFetcher else { return }
        await performIncrementalSync(using: zoneChangesFetcher, token: cache.loadChangeToken(), allowRetryOnExpiredToken: true)
    }

    private func performIncrementalSync(using fetcher: ZoneChangesFetcher, token: Data?, allowRetryOnExpiredToken: Bool) async {
        switch await fetcher.fetchZoneChanges(sinceToken: token) {
        case .success(let changed, let deletedProviderNames, let newToken):
            reconcile(changed: changed, deletedProviderNames: deletedProviderNames)
            try? cache.saveChangeToken(newToken)
            let syncedAt = Date()
            lastSyncedAt = syncedAt
            try? cache.saveCachedStatuses(providers, syncedAt: syncedAt)
        case .changeTokenExpired:
            // PM-3: drop the stale token and do one full refetch from
            // scratch (nil token). Bounded to one retry -- a fetcher that
            // reports `.changeTokenExpired` again for a nil token is broken,
            // not something worth looping on.
            try? cache.saveChangeToken(nil)
            guard allowRetryOnExpiredToken else { return }
            await performIncrementalSync(using: fetcher, token: nil, allowRetryOnExpiredToken: false)
        case .zoneNotFound, .zoneDeleted:
            // PM-3: GradusZone is Mac-owned and recreated idempotently on
            // its next publish (T2a.2) -- iOS can't recreate it, so this
            // resets to "waiting for first publish" rather than erroring,
            // and self-heals once the Mac republishes and the next
            // subscription notification arrives.
            providers = []
            lastSyncedAt = nil
            try? cache.saveChangeToken(nil)
            try? cache.clear()
        case .failure:
            // Leave state as-is; the next subscription-triggered sync retries.
            break
        }
    }

    private func reconcile(changed: [ProviderStatus], deletedProviderNames: [String]) {
        var byName = Dictionary(uniqueKeysWithValues: providers.map { ($0.providerName, $0) })
        for status in changed { byName[status.providerName] = status }
        for name in deletedProviderNames { byName.removeValue(forKey: name) }
        providers = byName.values.sorted { $0.providerName < $1.providerName }
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
