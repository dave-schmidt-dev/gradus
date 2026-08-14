import CloudKit
import Foundation
import GradusKit

public enum RequiredICloudMode: String, Equatable, Sendable {
    case awaitingConfirmation
    case confirmed

    var allowsLiveWork: Bool {
        self == .confirmed
    }
}

/// The account status shown by the dashboard. Temporary uncertainty is kept
/// separate from a confirmed missing or restricted account so recovery copy
/// never sends a user to the wrong settings surface.
public enum ICloudAvailabilityState: Equatable, Sendable {
    case checkingICloud
    case available
    case noAccount
    case restricted
    case tryAgain
}

enum RequiredICloudMigration {
    static let modeKey = "requiredICloudMode"
    static let versionKey = "requiredICloudModeVersion"
    static let currentVersion = 1

    static func migrate(
        defaults: UserDefaults,
        legacyKey: String,
        writeMode: (UserDefaults, RequiredICloudMode) -> Void = { defaults, mode in
            defaults.set(mode.rawValue, forKey: modeKey)
            defaults.set(currentVersion, forKey: versionKey)
        }
    ) -> RequiredICloudMode {
        let mode: RequiredICloudMode = if let stored = defaults.object(forKey: modeKey) as? String,
                                          let storedMode = RequiredICloudMode(rawValue: stored) {
            // The new authority wins if both generations are present. Re-write
            // its version before removing the legacy value so a partial write
            // remains safely re-runnable.
            storedMode
        } else if defaults.object(forKey: legacyKey) == nil {
            .confirmed
        } else {
            defaults.bool(forKey: legacyKey) ? .confirmed : .awaitingConfirmation
        }
        writeMode(defaults, mode)
        guard let committed = defaults.object(forKey: modeKey) as? String,
              RequiredICloudMode(rawValue: committed) == mode,
              defaults.integer(forKey: versionKey) == currentVersion
        else { return mode }
        defaults.removeObject(forKey: legacyKey)
        return mode
    }
}

/// The three distinct empty states the dashboard must never collapse
/// (CV-5) -- each has its own copy, its own fix action, and its own
/// snapshot baseline (T3.3/T3.5).
public enum DashboardEmptyState: Equatable {
    case checkingICloud
    case tryAgain
    /// Not signed in to iCloud at the OS level. The in-app toggle can't fix
    /// this; only a deep link to Settings can.
    case notSignedIn
    /// Signed in, but the in-app "Enable iCloud Sync" toggle is off.
    case syncDisabled
    /// Signed in, but CloudKit access is restricted for this account.
    case restricted
    case awaitingConfirmation
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
    @Published public private(set) var requiredICloudMode: RequiredICloudMode = .confirmed
    @Published public private(set) var iCloudAvailability: ICloudAvailabilityState = .checkingICloud
    @Published public private(set) var liveLifecycleNeedsRetry = false
    @Published public var syncEnabled: Bool {
        didSet {
            guard syncEnabled != oldValue else { return }
            commitRequiredICloudMode(syncEnabled ? .confirmed : .awaitingConfirmation)
        }
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

    /// `0` is Auto; positive values are explicit size stops from Small to
    /// Large. This remains device-local: iPad positions depend on its current
    /// geometry, while a one-column phone is always Automatic.
    @Published public var cardColumnPreference: Int {
        didSet {
            userDefaults.set(cardColumnPreference, forKey: Self.cardColumnPreferenceKey)
            userDefaults.set(Self.cardColumnPreferenceFormatVersion, forKey: Self.cardColumnPreferenceFormatKey)
            pendingLegacyCardColumnPreference = nil
            if cardColumnPreference > 0 {
                userDefaults.removeObject(forKey: Self.deferredCardSizePreferenceKey)
            }
        }
    }

    /// The currently visible dashboard supplies this transient range from its
    /// own geometry and Dynamic Type environment. It is deliberately not
    /// persisted and never comes from provider data or CloudKit.
    @Published public private(set) var availableCardColumns: Int = 1

    static let syncEnabledKey = "iCloudSyncEnabled"
    static let requiredICloudModeKey = RequiredICloudMigration.modeKey
    static let requiredICloudModeVersionKey = RequiredICloudMigration.versionKey
    static let requiredICloudModeVersion = RequiredICloudMigration.currentVersion
    static let notificationsEnabledKey = "warningNotificationsEnabled"
    static let localWarningThresholdPercentKey = "localWarningThresholdPercent"
    static let providerSortOptionKey = "providerSortOption"
    static let showExhaustedKey = "showExhausted"
    static let cardColumnPreferenceKey = "dashboardCardColumnPreference"
    private static let cardColumnPreferenceFormatKey = "dashboardCardSizePreferenceFormat"
    private static let pendingLegacyCardColumnPreferenceKey = "dashboardPendingLegacyCardColumnPreference"
    private static let deferredCardSizePreferenceKey = "dashboardDeferredCardSizePreference"
    private static let cardColumnPreferenceFormatVersion = 1
    private static let defaultLocalWarningThresholdPercent: Double = 20.0

    private let cache: LocalCacheStore
    private let fetcher: CloudFetcher?
    private let accountSource: AccountStatusSource?
    private let zoneChangesFetcher: ZoneChangesFetcher?
    private let subscriptionManager: CKSubscriptionManager?
    private let warningNotificationScheduler: WarningNotificationScheduling?
    private let notificationAuthorizationSource: NotificationAuthorizationSource?
    private let liveLifecycleGate: LiveLifecycleGate?
    private let userDefaults: UserDefaults
    private var allProviders: [ProviderStatus] = []
    private var isReconcilingLiveLifecycle = false
    /// Build 12 stored a direct column count. Keep that value until the first
    /// geometry pass gives us the device's current maximum, then translate it
    /// to the new Small-to-Large stop so an upgrade does not change layout.
    private var pendingLegacyCardColumnPreference: Int?

    /// Internal lifecycle proof for the local sample path: a sample view model
    /// must be constructed without any live CloudKit/account/notification seam.
    var hasLiveLifecycleDependencies: Bool {
        fetcher != nil || accountSource != nil || zoneChangesFetcher != nil || subscriptionManager != nil
            || warningNotificationScheduler != nil || notificationAuthorizationSource != nil
    }

    /// `userDefaults` defaults to `.standard` for production; tests inject
    /// a fresh per-test suite so `syncEnabled` (persisted here) can't leak
    /// state across test cases sharing a process, unlike `.standard`.
    public convenience init(
        cache: LocalCacheStore,
        fetcher: CloudFetcher? = nil,
        accountSource: AccountStatusSource? = nil,
        zoneChangesFetcher: ZoneChangesFetcher? = nil,
        subscriptionManager: CKSubscriptionManager? = nil,
        warningNotificationScheduler: WarningNotificationScheduling? = nil,
        notificationAuthorizationSource: NotificationAuthorizationSource? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.init(
            cache: cache, fetcher: fetcher, accountSource: accountSource,
            zoneChangesFetcher: zoneChangesFetcher, subscriptionManager: subscriptionManager,
            warningNotificationScheduler: warningNotificationScheduler,
            notificationAuthorizationSource: notificationAuthorizationSource,
            liveLifecycleGate: nil, userDefaults: userDefaults
        )
    }

    init(
        cache: LocalCacheStore,
        fetcher: CloudFetcher? = nil,
        accountSource: AccountStatusSource? = nil,
        zoneChangesFetcher: ZoneChangesFetcher? = nil,
        subscriptionManager: CKSubscriptionManager? = nil,
        warningNotificationScheduler: WarningNotificationScheduling? = nil,
        notificationAuthorizationSource: NotificationAuthorizationSource? = nil,
        liveLifecycleGate: LiveLifecycleGate?,
        userDefaults: UserDefaults = .standard
    ) {
        self.cache = cache
        self.fetcher = fetcher
        self.accountSource = accountSource
        self.zoneChangesFetcher = zoneChangesFetcher
        self.subscriptionManager = subscriptionManager
        self.warningNotificationScheduler = warningNotificationScheduler
        self.notificationAuthorizationSource = notificationAuthorizationSource
        self.liveLifecycleGate = liveLifecycleGate
        self.userDefaults = userDefaults
        let migratedMode = RequiredICloudMigration.migrate(
            defaults: userDefaults, legacyKey: Self.syncEnabledKey
        )
        requiredICloudMode = migratedMode
        syncEnabled = migratedMode.allowsLiveWork
        // Warning alerts are optional and fresh installs start off. Existing
        // explicit choices are preserved by the key-presence branch above.
        if userDefaults.object(forKey: Self.notificationsEnabledKey) != nil {
            notificationsEnabled = userDefaults.bool(forKey: Self.notificationsEnabledKey)
        } else {
            notificationsEnabled = false
        }
        if userDefaults.object(forKey: Self.localWarningThresholdPercentKey) != nil {
            localWarningThresholdPercent = userDefaults.double(forKey: Self.localWarningThresholdPercentKey)
        } else {
            localWarningThresholdPercent = Self.defaultLocalWarningThresholdPercent
        }
        providerSortOption = ProviderSortOption(rawValue: userDefaults.string(forKey: Self.providerSortOptionKey) ?? "") ?? .mostUrgent
        let storedCardPreference = max(0, userDefaults.integer(forKey: Self.cardColumnPreferenceKey))
        let deferredLegacyPreference = max(
            0, userDefaults.integer(forKey: Self.pendingLegacyCardColumnPreferenceKey)
        )
        if userDefaults.integer(forKey: Self.cardColumnPreferenceFormatKey) >= Self.cardColumnPreferenceFormatVersion {
            cardColumnPreference = storedCardPreference
            pendingLegacyCardColumnPreference = deferredLegacyPreference > 0
                ? deferredLegacyPreference
                : nil
        } else if storedCardPreference > 0 {
            cardColumnPreference = 0
            pendingLegacyCardColumnPreference = storedCardPreference
            // The old direct-column value is now held in a dedicated pending
            // key. Mark the format so a relaunch does not reinterpret it as a
            // current Small-to-Large stop.
            userDefaults.set(0, forKey: Self.cardColumnPreferenceKey)
            userDefaults.set(Self.cardColumnPreferenceFormatVersion, forKey: Self.cardColumnPreferenceFormatKey)
            userDefaults.set(storedCardPreference, forKey: Self.pendingLegacyCardColumnPreferenceKey)
        } else {
            cardColumnPreference = 0
            pendingLegacyCardColumnPreference = nil
            userDefaults.set(Self.cardColumnPreferenceFormatVersion, forKey: Self.cardColumnPreferenceFormatKey)
            userDefaults.removeObject(forKey: Self.pendingLegacyCardColumnPreferenceKey)
        }
        if userDefaults.object(forKey: Self.showExhaustedKey) != nil {
            showExhausted = userDefaults.bool(forKey: Self.showExhaustedKey)
        } else {
            showExhausted = true
        }
        allProviders = cache.loadCachedStatuses()
        providers = Self.presentedProviders(
            allProviders,
            localThreshold: localWarningThresholdPercent,
            sortOption: providerSortOption,
            showExhausted: showExhausted
        )
        lastSyncedAt = cache.lastSyncedAt()
        updateConnectedSource()
    }

    private func commitRequiredICloudMode(_ mode: RequiredICloudMode) {
        requiredICloudMode = mode
        userDefaults.set(mode.rawValue, forKey: Self.requiredICloudModeKey)
        userDefaults.set(Self.requiredICloudModeVersion, forKey: Self.requiredICloudModeVersionKey)
        guard userDefaults.object(forKey: Self.requiredICloudModeKey) as? String == mode.rawValue,
              userDefaults.integer(forKey: Self.requiredICloudModeVersionKey)
              == Self.requiredICloudModeVersion
        else { return }
        userDefaults.removeObject(forKey: Self.syncEnabledKey)
    }

    /// Confirms the required iCloud setup from the concrete Continue action.
    public func confirmRequiredICloud() {
        syncEnabled = true
    }

    /// Starts the bounded account-discovery window used by the dashboard.
    public func beginAccountAvailabilityCheck() {
        guard requiredICloudMode.allowsLiveWork else { return }
        iCloudAvailability = .checkingICloud
        liveLifecycleNeedsRetry = false
    }

    /// Records a non-sensitive lifecycle failure. The cached dashboard stays
    /// visible and the next foreground/account-available event can retry.
    public func noteLiveLifecycleFailure() {
        liveLifecycleNeedsRetry = true
        if accountStatus != .available {
            iCloudAvailability = .tryAgain
        }
    }

    /// Called by the account monitor after its one bounded bootstrap retry.
    public func accountAvailabilityCheckFailed() {
        guard requiredICloudMode.allowsLiveWork else { return }
        iCloudAvailability = .tryAgain
        liveLifecycleNeedsRetry = true
    }

    /// Updates the Settings slider's device-relative range. A legacy explicit
    /// column count is translated once the current geometry is known;
    /// `DashboardContent` then clamps it against each live geometry pass.
    public func setAvailableCardColumns(_ maximum: Int) {
        let maximum = max(1, maximum)
        availableCardColumns = maximum
        if maximum == 1 {
            // A one-column geometry cannot honor a manual card-size choice.
            // Keep the effective preference on Automatic, but defer the
            // explicit stop so a temporarily narrow iPad restores it when
            // regular geometry returns. Phones remain one-column forever and
            // therefore never expose or apply that deferred stop.
            if let legacyColumns = pendingLegacyCardColumnPreference {
                userDefaults.set(legacyColumns, forKey: Self.pendingLegacyCardColumnPreferenceKey)
            }
            if cardColumnPreference != 0 {
                userDefaults.set(cardColumnPreference, forKey: Self.deferredCardSizePreferenceKey)
                cardColumnPreference = 0
            }
            return
        }
        if let legacyColumns = pendingLegacyCardColumnPreference {
            pendingLegacyCardColumnPreference = nil
            userDefaults.removeObject(forKey: Self.pendingLegacyCardColumnPreferenceKey)
            let clampedColumns = min(max(legacyColumns, 1), maximum)
            cardColumnPreference = max(1, maximum - clampedColumns + 1)
            return
        }
        let deferredPreference = max(
            0, userDefaults.integer(forKey: Self.deferredCardSizePreferenceKey)
        )
        guard cardColumnPreference == 0, deferredPreference > 0 else { return }
        userDefaults.removeObject(forKey: Self.deferredCardSizePreferenceKey)
        cardColumnPreference = min(max(deferredPreference, 1), maximum)
    }

    /// Resolves Auto (`0`) to the largest feasible count; explicit slider
    /// stops are clamped to the same device-relative range.
    nonisolated static func resolvedCardColumnCount(preference: Int, maximum: Int) -> Int {
        resolvedCardColumnCount(preference: preference, maximum: maximum, sizeStops: maximum)
    }

    /// Resolves the persisted slider stop to a column count. The first
    /// explicit stop is the smallest-card presentation (the maximum feasible
    /// column count); later stops remove columns toward Large. A one-column
    /// device has no explicit stops and stays on Automatic.
    nonisolated static func resolvedCardColumnCount(preference: Int, maximum: Int, sizeStops _: Int) -> Int {
        let maximum = max(1, maximum)
        guard preference != 0 else { return maximum }
        let position = min(max(preference, 1), maximum)
        return max(1, maximum - position + 1)
    }

    /// Number of positions offered by the device-relative card-size slider.
    /// A one-column device has no manual size choice: its layout is Automatic.
    nonisolated static func cardSizeStopCount(for maximumColumns: Int) -> Int {
        max(1, maximumColumns)
    }

    /// Maps an explicit slider stop from Small at the left to Large at the
    /// right. Auto (`0`) remains separate and is resolved geometrically.
    nonisolated static func resolvedCardDensity(preference: Int, sizeStops: Int) -> DashboardDensity? {
        guard preference > 0 else { return nil }
        let stops = max(1, sizeStops)
        let position = min(max(preference, 1), stops) - 1
        let index = Int((Double(position) * 2 / Double(max(1, stops - 1))).rounded())
        return DashboardDensity.allCases[min(index, DashboardDensity.allCases.count - 1)]
    }

    nonisolated static func cardSizeLabel(preference: Int, maximumColumns: Int) -> String {
        guard preference != 0, maximumColumns > 1 else { return "Auto" }
        let stops = cardSizeStopCount(for: maximumColumns)
        let density = resolvedCardDensity(preference: preference, sizeStops: stops) ?? .large
        let columns = resolvedCardColumnCount(
            preference: preference, maximum: maximumColumns, sizeStops: stops
        )
        let size = switch density {
        case .compact: "Small"
        case .standard: "Medium"
        case .large: "Large"
        }
        let suffix = columns == 1 ? "1 column" : "\(columns) columns"
        return "\(size) · \(suffix)"
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
        let unsubscribe: () async -> Void = {
            do {
                try await subscriptionManager.unsubscribeFromWarnings()
                self.notificationsEnabled = false
                self.userDefaults.set(false, forKey: Self.notificationsEnabledKey)
                self.notificationsToggleError = nil
            } catch {
                self.notificationsToggleError = "Couldn't turn off notifications -- check your connection and try again."
            }
        }
        if let liveLifecycleGate {
            await liveLifecycleGate.withOperation { _ in await unsubscribe() }
        } else {
            await unsubscribe()
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
        // This is a local UserNotifications read, not live iCloud work. UI
        // fixtures intentionally suspend CloudKit through the lifecycle gate
        // but still need an accurate permission state to render their alert
        // recovery controls deterministically.
        systemNotificationAuthorization = await notificationAuthorizationSource.currentAuthorization()
    }

    /// `nil` means "render the populated dashboard" -- there is data (fresh
    /// or offline-stale) to show.
    public var emptyState: DashboardEmptyState? {
        guard providers.isEmpty else { return nil }
        if requiredICloudMode == .awaitingConfirmation {
            return .awaitingConfirmation
        }
        switch iCloudAvailability {
        case .checkingICloud: return .checkingICloud
        case .tryAgain: return .tryAgain
        case .noAccount: return .notSignedIn
        case .restricted: return .restricted
        case .available: break
        }
        if !syncEnabled {
            return .syncDisabled
        }
        return .waitingForFirstPublish
    }

    /// The most urgent provider per `rankProviders`' total order (P3/T3.2).
    /// Always the first element: `providers` is ranked at every one of its
    /// three assignment sites (`init`, `sync()`, `reconcile()`) -- the
    /// `.zoneNotFound`/`.zoneDeleted` reset path assigns `[]` directly, which
    /// is trivially "ranked" (empty), so this invariant holds unconditionally.
    public var heroProvider: ProviderStatus? {
        providers.first
    }

    /// All providers other than the hero, still in ranked order.
    public var restProviders: [ProviderStatus] {
        Array(providers.dropFirst())
    }

    public func refreshAccountStatus() async {
        guard let accountSource else { return }
        let refresh = {
            if let status = try? await accountSource.currentAccountStatus() {
                self.accountStatus = status
            }
        }
        if let liveLifecycleGate {
            await liveLifecycleGate.withOperation { _ in await refresh() }
        } else {
            await refresh()
        }
    }

    /// Callback target for `AccountStatusMonitor` (PM-16): applies a status
    /// change observed mid-session, including a `.CKAccountChanged` reset,
    /// and kicks a sync when the account newly becomes available.
    public func updateAccountStatus(_ status: CKAccountStatus) {
        accountStatus = status
        switch status {
        case .available:
            iCloudAvailability = .available
            liveLifecycleNeedsRetry = false
        case .noAccount:
            iCloudAvailability = .noAccount
        case .restricted:
            iCloudAvailability = .restricted
        case .couldNotDetermine, .temporarilyUnavailable:
            if !liveLifecycleNeedsRetry {
                iCloudAvailability = .checkingICloud
            }
        @unknown default:
            if !liveLifecycleNeedsRetry {
                iCloudAvailability = .checkingICloud
            }
        }
    }

    /// Entry point for a push-driven delta sync (T4.1): fetches only what
    /// changed in `GradusZone` since the persisted token and reconciles it
    /// into `providers`, rather than re-fetching everything (`sync()`'s
    /// full-fetch path, used on launch/pull-to-refresh).
    public func handleRemoteNotification() async {
        guard syncEnabled, accountStatus == .available, let zoneChangesFetcher else { return }
        let token = cache.loadChangeToken()
        if let liveLifecycleGate {
            await liveLifecycleGate.withOperation { operationEpoch in
                await self.performIncrementalSync(
                    using: zoneChangesFetcher, token: token, allowRetryOnExpiredToken: true,
                    lifecycleEpoch: operationEpoch
                )
            }
        } else {
            await performIncrementalSync(using: zoneChangesFetcher, token: token, allowRetryOnExpiredToken: true)
        }
    }

    private func performIncrementalSync(
        using fetcher: ZoneChangesFetcher,
        token: Data?,
        allowRetryOnExpiredToken: Bool,
        lifecycleEpoch: LiveLifecycleGate.Epoch? = nil
    ) async {
        if let lifecycleEpoch, let liveLifecycleGate, !liveLifecycleGate.isCurrent(lifecycleEpoch) {
            return
        }
        let result = await fetcher.fetchZoneChanges(sinceToken: token)
        // `LiveLifecycleGate` is re-entrant around the CloudKit await. Sample
        // entry invalidates the epoch while that request is suspended, so a
        // late result must not reconcile providers or persist cache state.
        if let lifecycleEpoch, let liveLifecycleGate, !liveLifecycleGate.isCurrent(lifecycleEpoch) {
            return
        }
        switch result {
        case let .success(changed, deletedProviderNames, newToken):
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
            await performIncrementalSync(
                using: fetcher, token: nil, allowRetryOnExpiredToken: false,
                lifecycleEpoch: lifecycleEpoch
            )
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
            if status.isWarning, !(byName[status.providerName]?.isWarning ?? false), notificationsEnabled {
                warningNotificationScheduler?.scheduleWarningNotification(
                    for: status, thresholdPercent: localWarningThresholdPercent
                )
            }
            byName[status.providerName] = status
        }
        for name in deletedProviderNames {
            byName.removeValue(forKey: name)
        }
        allProviders = Array(byName.values)
        applyPresentationPreferences()
    }

    private func notifyForWarningTransitions(from previous: [ProviderStatus], to current: [ProviderStatus]) {
        guard notificationsEnabled else { return }
        var previousByName = Dictionary(uniqueKeysWithValues: previous.map { ($0.providerName, $0) })
        for status in current {
            if status.isWarning, !(previousByName[status.providerName]?.isWarning ?? false) {
                warningNotificationScheduler?.scheduleWarningNotification(
                    for: status, thresholdPercent: localWarningThresholdPercent
                )
            }
            previousByName[status.providerName] = status
        }
    }

    /// Fetches the current CloudKit state and refreshes the offline cache.
    /// No-ops (leaving the last-known/cached state on screen) when sync is
    /// off or the account isn't ready -- CV-6's "distinct state, not silent
    /// failure" applies to the empty-state copy, not to spamming a fetch
    /// that would just fail.
    public func sync() async -> Bool {
        guard syncEnabled, accountStatus == .available, let fetcher else { return false }
        if let liveLifecycleGate {
            return await liveLifecycleGate.withOperation { _ in await self.performSync(using: fetcher) } ?? false
        } else {
            return await performSync(using: fetcher)
        }
    }

    private func performSync(using fetcher: CloudFetcher) async -> Bool {
        isSyncing = true
        defer { isSyncing = false }
        guard let fetched = try? await fetcher.fetchAll() else { return false }
        // Compare the complete cached set, not the filtered presentation set,
        // so hiding exhausted providers cannot turn an unchanged warning into
        // a fresh notification on the next full sync.
        notifyForWarningTransitions(from: allProviders, to: fetched)
        allProviders = fetched
        applyPresentationPreferences()
        let syncedAt = Date()
        lastSyncedAt = syncedAt
        try? cache.saveCachedStatuses(allProviders, syncedAt: syncedAt)
        return true
    }

    /// The single idempotent live-data reconciliation path. Account changes,
    /// bootstrap, and foreground recovery all call this method so fixed
    /// subscription IDs and the cached data converge together.
    public func reconcileLiveLifecycle() async {
        guard requiredICloudMode.allowsLiveWork, syncEnabled, accountStatus == .available else { return }
        guard !isReconcilingLiveLifecycle else { return }
        isReconcilingLiveLifecycle = true
        defer { isReconcilingLiveLifecycle = false }

        var failed = await !sync()
        if let subscriptionManager {
            do { try await subscriptionManager.subscribeToZoneChanges() } catch { failed = true }
            if notificationsEnabled {
                do { try await subscriptionManager.subscribeToWarnings() } catch { failed = true }
            }
        }
        liveLifecycleNeedsRetry = failed
    }

    private func applyPresentationPreferences() {
        providers = Self.presentedProviders(
            allProviders,
            localThreshold: localWarningThresholdPercent,
            sortOption: providerSortOption,
            showExhausted: showExhausted
        )
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
