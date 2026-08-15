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
    // Several `@Published` properties below are `internal(set)` rather than
    // `private(set)`: their writers live in sibling extension files (see the
    // stored-property note further down) and `private`/`private(set)` only
    // reach extensions declared in the *same* file. The public surface --
    // what's writable from outside the GradusiOS module -- is unchanged
    // either way; `internal(set)` is still not writable outside the module.
    @Published public internal(set) var providers: [ProviderStatus] = []
    @Published public internal(set) var lastSyncedAt: Date?
    @Published public internal(set) var connectedSource: SyncSource?
    @Published public internal(set) var connectedSourcePublishedAt: Date?
    @Published public private(set) var requiredICloudMode: RequiredICloudMode = .confirmed
    @Published public internal(set) var iCloudAvailability: ICloudAvailabilityState = .checkingICloud
    @Published public internal(set) var liveLifecycleNeedsRetry = false
    @Published public var syncEnabled: Bool {
        didSet {
            guard syncEnabled != oldValue else { return }
            commitRequiredICloudMode(syncEnabled ? .confirmed : .awaitingConfirmation)
        }
    }

    @Published public internal(set) var accountStatus: CKAccountStatus = .couldNotDetermine
    @Published public internal(set) var isSyncing = false

    /// P5/T5.1: gates `subscribeToWarnings()` independently of `syncEnabled`
    /// (Key decision #2). Mutated only via `setNotificationsEnabled(_:)` --
    /// toggle-off is success-gated on `unsubscribeFromWarnings()` actually
    /// succeeding, so this can't be a plain `didSet`-persists property like
    /// `syncEnabled`.
    @Published public internal(set) var notificationsEnabled: Bool
    /// Set when a toggle-off attempt fails (stale subscription left active
    /// server-side); cleared on the next successful toggle in either
    /// direction. Settings renders this as an inline row error (CR-5).
    @Published public internal(set) var notificationsToggleError: String?

    /// Whether iOS will *display* a warning once we schedule one. Read from the
    /// system rather than remembered from the first-launch authorization
    /// request, since permission can be revoked from iOS Settings later.
    ///
    /// Starts `.notDetermined` and is corrected by
    /// `refreshNotificationAuthorization()` on launch and on every return to
    /// the foreground -- the only two moments it can have changed, because
    /// changing it requires leaving the app.
    @Published public internal(set) var systemNotificationAuthorization: NotificationAuthorization = .notDetermined

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
    ///
    /// `internal(set)`, not `private(set)`: mutated from
    /// `DashboardViewModel+CardLayoutPreference.swift`.
    @Published public internal(set) var availableCardColumns: Int = 1

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
    // Not `private`: read/written by `setAvailableCardColumns(_:)` in
    // `DashboardViewModel+CardLayoutPreference.swift`.
    static let pendingLegacyCardColumnPreferenceKey = "dashboardPendingLegacyCardColumnPreference"
    static let deferredCardSizePreferenceKey = "dashboardDeferredCardSizePreference"
    private static let cardColumnPreferenceFormatVersion = 1
    private static let defaultLocalWarningThresholdPercent: Double = 20.0

    // None of the stored properties below are `private`: every one is read
    // or written from at least one sibling extension file
    // (`DashboardViewModel+CardLayoutPreference.swift`,
    // `DashboardViewModel+Notifications.swift`,
    // `DashboardViewModel+AccountStatus.swift`,
    // `DashboardViewModel+Sync.swift`), and Swift's `private` only reaches
    // extensions declared in the same file. Still module-internal only --
    // nothing here is visible outside GradusiOS.
    let cache: LocalCacheStore
    let fetcher: CloudFetcher?
    let accountSource: AccountStatusSource?
    let zoneChangesFetcher: ZoneChangesFetcher?
    let subscriptionManager: CKSubscriptionManager?
    let warningNotificationScheduler: WarningNotificationScheduling?
    let notificationAuthorizationSource: NotificationAuthorizationSource?
    let liveLifecycleGate: LiveLifecycleGate?
    let userDefaults: UserDefaults
    var allProviders: [ProviderStatus] = []
    var isReconcilingLiveLifecycle = false
    /// Build 12 stored a direct column count. Keep that value until the first
    /// geometry pass gives us the device's current maximum, then translate it
    /// to the new Small-to-Large stop so an upgrade does not change layout.
    var pendingLegacyCardColumnPreference: Int?

    /// Internal lifecycle proof for the local sample path: a sample view model
    /// must be constructed without any live CloudKit/account/notification seam.
    var hasLiveLifecycleDependencies: Bool {
        fetcher != nil || accountSource != nil || zoneChangesFetcher != nil || subscriptionManager != nil
            || warningNotificationScheduler != nil || notificationAuthorizationSource != nil
    }

    private struct CardColumnPreferenceMigration {
        let cardColumnPreference: Int
        let pendingLegacyCardColumnPreference: Int?
    }

    /// Build 12's direct column count, translated to a Small-to-Large stop
    /// (Key decision above `pendingLegacyCardColumnPreference`). A pure
    /// function of `userDefaults` so `init` can assign both resulting
    /// properties directly -- calling this via an instance method instead
    /// would run past `self`'s own initializer and misfire `didSet` on
    /// `cardColumnPreference`.
    private static func migrateCardColumnPreference(
        userDefaults: UserDefaults
    ) -> CardColumnPreferenceMigration {
        let storedCardPreference = max(0, userDefaults.integer(forKey: Self.cardColumnPreferenceKey))
        let deferredLegacyPreference = max(
            0, userDefaults.integer(forKey: Self.pendingLegacyCardColumnPreferenceKey)
        )
        if userDefaults.integer(forKey: Self.cardColumnPreferenceFormatKey) >= Self.cardColumnPreferenceFormatVersion {
            return CardColumnPreferenceMigration(
                cardColumnPreference: storedCardPreference,
                pendingLegacyCardColumnPreference: deferredLegacyPreference > 0 ? deferredLegacyPreference : nil
            )
        } else if storedCardPreference > 0 {
            // The old direct-column value is now held in a dedicated pending
            // key. Mark the format so a relaunch does not reinterpret it as a
            // current Small-to-Large stop.
            userDefaults.set(0, forKey: Self.cardColumnPreferenceKey)
            userDefaults.set(Self.cardColumnPreferenceFormatVersion, forKey: Self.cardColumnPreferenceFormatKey)
            userDefaults.set(storedCardPreference, forKey: Self.pendingLegacyCardColumnPreferenceKey)
            return CardColumnPreferenceMigration(
                cardColumnPreference: 0,
                pendingLegacyCardColumnPreference: storedCardPreference
            )
        } else {
            userDefaults.set(Self.cardColumnPreferenceFormatVersion, forKey: Self.cardColumnPreferenceFormatKey)
            userDefaults.removeObject(forKey: Self.pendingLegacyCardColumnPreferenceKey)
            return CardColumnPreferenceMigration(cardColumnPreference: 0, pendingLegacyCardColumnPreference: nil)
        }
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
        let storedSortOption = userDefaults.string(forKey: Self.providerSortOptionKey) ?? ""
        providerSortOption = ProviderSortOption(rawValue: storedSortOption) ?? .mostUrgent
        let cardPreferenceMigration = Self.migrateCardColumnPreference(userDefaults: userDefaults)
        cardColumnPreference = cardPreferenceMigration.cardColumnPreference
        pendingLegacyCardColumnPreference = cardPreferenceMigration.pendingLegacyCardColumnPreference
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
}
