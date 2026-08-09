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
    @Published public private(set) var connectedSource: SyncSource?
    @Published public private(set) var connectedSourcePublishedAt: Date?
    @Published public var syncEnabled: Bool {
        didSet { userDefaults.set(syncEnabled, forKey: Self.syncEnabledKey) }
    }
    @Published public private(set) var accountStatus: CKAccountStatus = .couldNotDetermine
    @Published public private(set) var isSyncing = false

    /// P5/T5.1: gates `subscribeToWarnings()` independently of `syncEnabled`
    /// (Key decision #2). Mutated only via `setNotificationsEnabled(_:)` --
    /// toggle-off is success-gated on `unsubscribeFromWarnings()` actually
    /// succeeding, so this can't be a plain `didSet`-persists property like
    /// `syncEnabled`.
    @Published public private(set) var notificationsEnabled: Bool
    /// Set when a toggle-off attempt fails (stale subscription left active
    /// server-side); cleared on the next successful toggle in either
    /// direction. Settings renders this as an inline row error (CR-5).
    @Published public private(set) var notificationsToggleError: String?

    /// Whether iOS will *display* a warning once we schedule one. Read from the
    /// system rather than remembered from the first-launch authorization
    /// request, since permission can be revoked from iOS Settings later.
    ///
    /// Starts `.notDetermined` and is corrected by
    /// `refreshNotificationAuthorization()` on launch and on every return to
    /// the foreground -- the only two moments it can have changed, because
    /// changing it requires leaving the app.
    @Published public private(set) var systemNotificationAuthorization: NotificationAuthorization = .notDetermined

    /// True when our own opt-in is on but iOS will not display the result. The
    /// only state worth surfacing: every warning transition schedules a
    /// notification that is silently dropped, so the feature reads as broken
    /// rather than off.
    ///
    /// Deliberately does *not* imply the toggle should be disabled. The warning
    /// subscription is a silent content-available push whose side effect is
    /// waking the app to sync; that still works while alerts are suppressed, so
    /// turning it off would cost the user something real.
    public var notificationsSuppressedBySystem: Bool {
        notificationsEnabled && systemNotificationAuthorization == .denied
    }

    /// P5/T5.2: iOS-local, per-device "locally urgent" percent-left
    /// threshold (Key decision #1/#5) -- affects local display/ranking
    /// only, never what CloudKit pushes. Plain `didSet`-persists, like
    /// `syncEnabled`: unlike notifications, there's no network call to
    /// gate on.
    @Published public var localWarningThresholdPercent: Double {
        didSet {
            userDefaults.set(localWarningThresholdPercent, forKey: Self.localWarningThresholdPercentKey)
            applyPresentationPreferences()
        }
    }

    /// Device-local dashboard presentation controls. Neither value is part of
    /// `ProviderStatus`, the cached provider payload, or any CloudKit record.
    @Published public var providerSortOption: ProviderSortOption {
        didSet {
            userDefaults.set(providerSortOption.rawValue, forKey: Self.providerSortOptionKey)
            applyPresentationPreferences()
        }
    }
    @Published public var showExhausted: Bool {
        didSet {
            userDefaults.set(showExhausted, forKey: Self.showExhaustedKey)
            applyPresentationPreferences()
        }
    }
    /// `0` is Auto; positive values are explicit feasible column counts. This
    /// remains device-local: a phone and iPad intentionally have different
    /// feasible ranges, so syncing this preference would make one device's
    /// choice invalid on the other.
    @Published public var cardColumnPreference: Int {
        didSet { userDefaults.set(cardColumnPreference, forKey: Self.cardColumnPreferenceKey) }
    }

    /// The currently visible dashboard supplies this transient range from its
    /// own geometry and Dynamic Type environment. It is deliberately not
    /// persisted and never comes from provider data or CloudKit.
    @Published public private(set) var availableCardColumns: Int = 1

    static let syncEnabledKey = "iCloudSyncEnabled"
    static let notificationsEnabledKey = "warningNotificationsEnabled"
    static let localWarningThresholdPercentKey = "localWarningThresholdPercent"
    static let providerSortOptionKey = "providerSortOption"
    static let showExhaustedKey = "showExhausted"
    static let cardColumnPreferenceKey = "dashboardCardColumnPreference"
    private static let defaultLocalWarningThresholdPercent: Double = 20.0

    private let cache: LocalCacheStore
    private let fetcher: CloudFetcher?
    private let accountSource: AccountStatusSource?
    private let zoneChangesFetcher: ZoneChangesFetcher?
    private let subscriptionManager: CKSubscriptionManager?
    private let warningNotificationScheduler: WarningNotificationScheduling?
    private let notificationAuthorizationSource: NotificationAuthorizationSource?
    private let userDefaults: UserDefaults
    private var allProviders: [ProviderStatus] = []

    /// `userDefaults` defaults to `.standard` for production; tests inject
    /// a fresh per-test suite so `syncEnabled` (persisted here) can't leak
    /// state across test cases sharing a process, unlike `.standard`.
    public init(
        cache: LocalCacheStore,
        fetcher: CloudFetcher? = nil,
        accountSource: AccountStatusSource? = nil,
        zoneChangesFetcher: ZoneChangesFetcher? = nil,
        subscriptionManager: CKSubscriptionManager? = nil,
        warningNotificationScheduler: WarningNotificationScheduling? = nil,
        notificationAuthorizationSource: NotificationAuthorizationSource? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.cache = cache
        self.fetcher = fetcher
        self.accountSource = accountSource
        self.zoneChangesFetcher = zoneChangesFetcher
        self.subscriptionManager = subscriptionManager
        self.warningNotificationScheduler = warningNotificationScheduler
        self.notificationAuthorizationSource = notificationAuthorizationSource
        self.userDefaults = userDefaults
        // Default OFF: usage data leaves the device only on explicit opt-in.
        let syncEnabledValue = userDefaults.bool(forKey: Self.syncEnabledKey)
        self.syncEnabled = syncEnabledValue
        // Default ON when sync is on, matching today's implicit behavior
        // (pre-Phase-5, notifications were bundled 1:1 with sync -- there
        // was no separate opt-out). Reads the local `syncEnabledValue`, not
        // `self.syncEnabled` -- a class initializer can't use `self` for
        // any purpose (including reading an already-assigned property)
        // until every stored property has an initial value.
        if userDefaults.object(forKey: Self.notificationsEnabledKey) != nil {
            self.notificationsEnabled = userDefaults.bool(forKey: Self.notificationsEnabledKey)
        } else {
            self.notificationsEnabled = syncEnabledValue
        }
        if userDefaults.object(forKey: Self.localWarningThresholdPercentKey) != nil {
            self.localWarningThresholdPercent = userDefaults.double(forKey: Self.localWarningThresholdPercentKey)
        } else {
            self.localWarningThresholdPercent = Self.defaultLocalWarningThresholdPercent
        }
        self.providerSortOption = ProviderSortOption(rawValue: userDefaults.string(forKey: Self.providerSortOptionKey) ?? "") ?? .mostUrgent
        self.cardColumnPreference = max(0, userDefaults.integer(forKey: Self.cardColumnPreferenceKey))
        if userDefaults.object(forKey: Self.showExhaustedKey) != nil {
            self.showExhausted = userDefaults.bool(forKey: Self.showExhaustedKey)
        } else {
            self.showExhausted = true
        }
        self.allProviders = cache.loadCachedStatuses()
        self.providers = Self.presentedProviders(
            allProviders,
            localThreshold: self.localWarningThresholdPercent,
            sortOption: self.providerSortOption,
            showExhausted: self.showExhausted)
        self.lastSyncedAt = cache.lastSyncedAt()
        updateConnectedSource()
    }

    /// Updates the Settings slider's device-relative range. A stale explicit
    /// preference is preserved rather than rewritten; `DashboardContent`
    /// clamps it against each live geometry pass.
    public func setAvailableCardColumns(_ maximum: Int) {
        availableCardColumns = max(1, maximum)
    }

    /// Resolves Auto (`0`) to the largest feasible count; explicit slider
    /// stops are clamped to the same device-relative range.
    static func resolvedCardColumnCount(preference: Int, maximum: Int) -> Int {
        let maximum = max(1, maximum)
        return preference == 0 ? maximum : min(max(preference, 1), maximum)
    }

    /// P5/T5.1: toggle-on is best-effort/optimistic (mirrors the existing
    /// enable-path semantics of `subscribeToWarnings()`, called via
    /// `GradusiOSApp`'s `.onChange(of: notificationsEnabled)`). Toggle-off
    /// is success-gated (CR-5): `notificationsEnabled` only flips to
    /// `false` once `unsubscribeFromWarnings()` actually succeeds, so the
    /// UI never claims "off" while a stale `CKQuerySubscription` keeps
    /// firing server-side. On failure the value is left untouched (i.e.
    /// still `true`) and `notificationsToggleError` is set for an inline
    /// row message.
    public func setNotificationsEnabled(_ enabled: Bool) async {
        guard enabled != notificationsEnabled else { return }
        if enabled {
            notificationsEnabled = true
            userDefaults.set(true, forKey: Self.notificationsEnabledKey)
            notificationsToggleError = nil
            return
        }
        guard let subscriptionManager else {
            // No live subscription path configured (e.g. a view model built
            // without CloudKit wiring) -- nothing server-side to fail, so
            // there's nothing to gate on.
            notificationsEnabled = false
            userDefaults.set(false, forKey: Self.notificationsEnabledKey)
            notificationsToggleError = nil
            return
        }
        do {
            try await subscriptionManager.unsubscribeFromWarnings()
            notificationsEnabled = false
            userDefaults.set(false, forKey: Self.notificationsEnabledKey)
            notificationsToggleError = nil
        } catch {
            notificationsToggleError = "Couldn't turn off notifications -- check your connection and try again."
        }
    }

    /// Re-reads the system authorization state. Called on launch and on every
    /// foreground transition, since the user can only change it by leaving the
    /// app for iOS Settings.
    ///
    /// No-ops without a source rather than assuming a value: a view model built
    /// for snapshot tests has no UserNotifications wiring, and defaulting to
    /// `.denied` would put a permission warning into every baseline while
    /// defaulting to `.authorized` would assert something unverified.
    /// `.notDetermined` is the honest starting point and stays put.
    public func refreshNotificationAuthorization() async {
        guard let notificationAuthorizationSource else { return }
        systemNotificationAuthorization = await notificationAuthorizationSource.currentAuthorization()
    }

    /// `nil` means "render the populated dashboard" -- there is data (fresh
    /// or offline-stale) to show.
    public var emptyState: DashboardEmptyState? {
        guard providers.isEmpty else { return nil }
        if accountStatus != .available { return .notSignedIn }
        if !syncEnabled { return .syncDisabled }
        return .waitingForFirstPublish
    }

    /// The most urgent provider per `rankProviders`' total order (P3/T3.2).
    /// Always the first element: `providers` is ranked at every one of its
    /// three assignment sites (`init`, `sync()`, `reconcile()`) -- the
    /// `.zoneNotFound`/`.zoneDeleted` reset path assigns `[]` directly, which
    /// is trivially "ranked" (empty), so this invariant holds unconditionally.
    public var heroProvider: ProviderStatus? { providers.first }

    /// All providers other than the hero, still in ranked order.
    public var restProviders: [ProviderStatus] { Array(providers.dropFirst()) }


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
            try? cache.saveCachedStatuses(allProviders, syncedAt: syncedAt)
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
            allProviders = []
            providers = []
            connectedSource = nil
            connectedSourcePublishedAt = nil
            lastSyncedAt = nil
            try? cache.saveChangeToken(nil)
            try? cache.clear()
        case .failure:
            // Leave state as-is; the next subscription-triggered sync retries.
            break
        }
    }

    private func reconcile(changed: [ProviderStatus], deletedProviderNames: [String]) {
        var byName = Dictionary(uniqueKeysWithValues: allProviders.map { ($0.providerName, $0) })
        for status in changed {
            if status.isWarning && !(byName[status.providerName]?.isWarning ?? false), notificationsEnabled {
                warningNotificationScheduler?.scheduleWarningNotification(for: status)
            }
            byName[status.providerName] = status
        }
        for name in deletedProviderNames { byName.removeValue(forKey: name) }
        allProviders = Array(byName.values)
        applyPresentationPreferences()
    }

    private func notifyForWarningTransitions(from previous: [ProviderStatus], to current: [ProviderStatus]) {
        guard notificationsEnabled else { return }
        var previousByName = Dictionary(uniqueKeysWithValues: previous.map { ($0.providerName, $0) })
        for status in current {
            if status.isWarning && !(previousByName[status.providerName]?.isWarning ?? false) {
                warningNotificationScheduler?.scheduleWarningNotification(for: status)
            }
            previousByName[status.providerName] = status
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
        // Compare the complete cached set, not the filtered presentation set,
        // so hiding exhausted providers cannot turn an unchanged warning into
        // a fresh notification on the next full sync.
        notifyForWarningTransitions(from: allProviders, to: fetched)
        allProviders = fetched
        applyPresentationPreferences()
        let syncedAt = Date()
        lastSyncedAt = syncedAt
        try? cache.saveCachedStatuses(allProviders, syncedAt: syncedAt)
    }

    private func applyPresentationPreferences() {
        providers = Self.presentedProviders(
            allProviders,
            localThreshold: localWarningThresholdPercent,
            sortOption: providerSortOption,
            showExhausted: showExhausted)
        updateConnectedSource()
    }

    /// Select the newest source metadata across the complete cached provider
    /// set, not only the filtered presentation set. This keeps the connection
    /// card stable when exhausted providers are hidden locally.
    private func updateConnectedSource() {
        let latest = allProviders
            .filter { $0.syncSource != nil }
            .max {
                if $0.publishedAt != $1.publishedAt {
                    return $0.publishedAt < $1.publishedAt
                }
                return $0.providerName < $1.providerName
            }
        connectedSource = latest?.syncSource
        connectedSourcePublishedAt = latest?.publishedAt
    }

    private static func presentedProviders(
        _ providers: [ProviderStatus],
        localThreshold: Double,
        sortOption: ProviderSortOption,
        showExhausted: Bool
    ) -> [ProviderStatus] {
        rankProviders(providers, localThreshold: localThreshold, sortOption: sortOption)
            .filter { showExhausted || !$0.isDepleted }
    }
}
