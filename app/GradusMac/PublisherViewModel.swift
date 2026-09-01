import Foundation
import GradusKit

public enum RequiredICloudMode: String, Equatable, Sendable {
    case awaitingConfirmation
    case confirmed

    var allowsLiveWork: Bool {
        self == .confirmed
    }
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

public enum CloudSyncState: Equatable, Sendable {
    case idle
    case publishing
    case synced
    case failed
}

/// Observable state the menu content view renders from, and the single
/// place the required-iCloud mode / snapshot data converge. Decoupled from
/// `PublishPipeline`'s CloudKit plumbing so `MenuContentView` can be
/// snapshot-tested from plain fixture data (T2b.1/T2b.4).
@MainActor
public final class PublisherViewModel: ObservableObject {
    @Published public private(set) var providers: [ProviderEntry] = []
    @Published public private(set) var updatedAt: String?
    @Published public internal(set) var syncEnabled: Bool {
        didSet {
            guard syncEnabled != oldValue else { return }
            commitRequiredICloudMode(syncEnabled ? .confirmed : .awaitingConfirmation)
            if !syncEnabled {
                syncOperationID &+= 1
                syncState = .idle
            }
        }
    }

    /// "Open Menu at Login" -- the *main app*. Deliberately not the same
    /// switch as `monitorInBackgroundEnabled` below: one puts the menu-bar icon
    /// back after a restart, the other keeps usage current while the app is
    /// closed. Presenting them as one control is what made "Gradus is running"
    /// and "Gradus is refreshing" indistinguishable.
    @Published public var launchAtLoginEnabled: Bool

    /// "Monitor in Background" -- the nested `SMAppService` refresh agent.
    @Published public private(set) var monitorInBackgroundEnabled: Bool
    @Published public private(set) var backgroundAgentState: BackgroundAgentState = .notRegistered

    /// The legacy-runtime cutover, as Settings renders it. Starts at
    /// `.notApplicable` so a Mac that never ran the old job shows nothing.
    @Published public private(set) var legacyMigration: LegacyMigrationPresentation = .notApplicable
    @Published public private(set) var syncState: CloudSyncState = .idle
    /// When the last publish actually succeeded. Persisted, because the state
    /// enum above resets to `.idle` on every launch: a menu-bar agent that has
    /// been running for a week would otherwise claim it had never synced until
    /// the next snapshot changed, which is exactly when a user checks.
    @Published public private(set) var lastSyncedAt: Date?
    @Published public private(set) var requiredICloudMode: RequiredICloudMode
    @Published public private(set) var connectedDevices: [DevicePresence] = []

    /// Device-local display preferences, mirroring `DashboardViewModel`'s on
    /// iOS down to the `UserDefaults` key names. They are deliberately *not*
    /// published to CloudKit: "how I like this Mac's menu sorted" is not a
    /// property of the usage data, and syncing it would let one device
    /// reorder another's list.
    @Published public var providerSortOption: ProviderSortOption {
        didSet {
            defaults.set(providerSortOption.rawValue, forKey: Self.providerSortOptionKey)
            advancePresentationRevision()
        }
    }

    @Published public var localWarningThresholdPercent: Double {
        didSet {
            defaults.set(localWarningThresholdPercent, forKey: Self.localWarningThresholdPercentKey)
            advancePresentationRevision()
        }
    }

    /// Matches `DashboardViewModel.showExhausted`, including its default of
    /// visible: a provider you can't use is still a provider you asked about,
    /// so hiding it is opt-in.
    @Published public var showExhausted: Bool {
        didSet {
            defaults.set(showExhausted, forKey: Self.showExhaustedKey)
            advancePresentationRevision()
        }
    }

    /// Forces the menu's provider subtree to be rebuilt after a device-local
    /// display choice changes. `MenuBarExtra` keeps its window-hosted content
    /// alive while Settings is open; merely updating a child initializer did
    /// not reliably replace that subtree on macOS.
    @Published private(set) var presentationRevision = 0
    private var syncOperationID: UInt64 = 0

    static let syncEnabledKey = "iCloudSyncEnabled"
    static let requiredICloudModeKey = RequiredICloudMigration.modeKey
    static let requiredICloudModeVersionKey = RequiredICloudMigration.versionKey
    static let requiredICloudModeVersion = RequiredICloudMigration.currentVersion
    static let lastSyncedAtKey = "iCloudLastSyncedAt"
    static let providerSortOptionKey = "providerSortOption"
    static let localWarningThresholdPercentKey = "localWarningThresholdPercent"
    /// Deliberately the same key string as `DashboardViewModel.showExhaustedKey`.
    /// The two apps have separate defaults domains so nothing is shared at
    /// runtime, but keeping the names aligned means a reader comparing the two
    /// preference sets sees one concept, not two similar ones.
    static let showExhaustedKey = "showExhausted"

    /// Matches `DashboardViewModel.defaultLocalWarningThresholdPercent`. A
    /// different default here would mean the same provider counts as "low" on
    /// the phone and not on the Mac, which is the class of drift this whole
    /// change exists to remove.
    public static let defaultLocalWarningThresholdPercent: Double = 20.0

    /// Injectable so tests do not write to the shipping app's own preference
    /// domain. That is not hypothetical: this bundle is hosted, so
    /// `UserDefaults.standard` in a test *is* GradusMac's real preferences, and
    /// an existing sync test silently began stamping a live timestamp into them
    /// the moment `cloudSyncDidSucceed` started persisting one.
    private let defaults: UserDefaults
    private let backgroundAgent: BackgroundAgentManager

    /// `nil` on a Mac with no legacy runtime and in every fixture, which is why
    /// the whole section disappears rather than rendering an empty state.
    private let legacyMigrator: LegacyRuntimeMigrator?
    private let legacyWrapperURL: URL
    private let legacyBridgeURL: URL

    /// `backgroundAgent` resolves to `nil` rather than defaulting to a live
    /// manager directly: a default-argument expression is evaluated in a
    /// nonisolated context, which Swift 6 rejects for a MainActor-isolated
    /// type. Same reason `PublishPipeline.start(snapshotPath:)` takes an
    /// optional.
    public init(
        defaults: UserDefaults = .standard,
        backgroundAgent: BackgroundAgentManager? = nil,
        legacyMigrator: LegacyRuntimeMigrator? = nil,
        legacyWrapperURL: URL? = nil,
        legacyBridgeURL: URL? = nil
    ) {
        let backgroundAgent = backgroundAgent ?? BackgroundAgentManager()
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.defaults = defaults
        self.backgroundAgent = backgroundAgent
        self.legacyMigrator = legacyMigrator
        self.legacyWrapperURL = legacyWrapperURL ?? LegacyRuntimePaths.legacyWrapper(homeDirectory: home)
        self.legacyBridgeURL = legacyBridgeURL ?? LegacyRuntimePaths.standaloneBridge()
        monitorInBackgroundEnabled = backgroundAgent.isMonitoringEnabled
        let migratedMode = RequiredICloudMigration.migrate(
            defaults: defaults, legacyKey: Self.syncEnabledKey
        )
        requiredICloudMode = migratedMode
        syncEnabled = migratedMode.allowsLiveWork
        launchAtLoginEnabled = LaunchAtLoginManager.isEnabled
        // `object(forKey:)` rather than `double(forKey:)` -- the latter returns
        // 0 for a missing key, which would render as 1970 instead of "never".
        lastSyncedAt = (defaults.object(forKey: Self.lastSyncedAtKey) as? Double)
            .map { Date(timeIntervalSince1970: $0) }
        providerSortOption = ProviderSortOption(
            rawValue: defaults.string(forKey: Self.providerSortOptionKey) ?? ""
        ) ?? .mostUrgent
        // Same `object(forKey:)` guard as the timestamp above, for the same
        // reason: `double(forKey:)` returns 0 for a missing key, which would
        // silently mean "warn me about nothing" instead of the 20% default.
        if defaults.object(forKey: Self.localWarningThresholdPercentKey) != nil {
            localWarningThresholdPercent =
                defaults.double(forKey: Self.localWarningThresholdPercentKey)
        } else {
            localWarningThresholdPercent = Self.defaultLocalWarningThresholdPercent
        }
        // And again: `bool(forKey:)` returns false for a missing key, which
        // would make a fresh install default to *hiding* exhausted providers.
        if defaults.object(forKey: Self.showExhaustedKey) != nil {
            showExhausted = defaults.bool(forKey: Self.showExhaustedKey)
        } else {
            showExhausted = true
        }
    }

    /// Confirms the required iCloud setup from the concrete Continue action.
    public func confirmRequiredICloud() {
        syncEnabled = true
    }

    private func commitRequiredICloudMode(_ mode: RequiredICloudMode) {
        requiredICloudMode = mode
        defaults.set(mode.rawValue, forKey: Self.requiredICloudModeKey)
        defaults.set(Self.requiredICloudModeVersion, forKey: Self.requiredICloudModeVersionKey)
        guard defaults.object(forKey: Self.requiredICloudModeKey) as? String == mode.rawValue,
              defaults.integer(forKey: Self.requiredICloudModeVersionKey)
              == Self.requiredICloudModeVersion
        else { return }
        defaults.removeObject(forKey: Self.syncEnabledKey)
    }

    public func apply(_ payload: SnapshotPayload) {
        providers = payload.providers
        updatedAt = payload.updatedAt
        refreshBackgroundAgentState()
    }

    /// The ISO timestamp the producer stamped, as a `Date`. Absent rather than
    /// defaulted: an unparseable timestamp must read as "no known refresh", not
    /// as 1970 (which would be reported as stale, correctly, but for the wrong
    /// reason) and never as now.
    public var updatedAtDate: Date? {
        updatedAt.flatMap(ISO8601DateFormatter().date(from:))
    }

    /// Recomputes the one state the setup/health UI renders. Called after every
    /// snapshot, every toggle, and every recovery action, so nothing on screen
    /// can outlive the condition that produced it.
    public func refreshBackgroundAgentState() {
        monitorInBackgroundEnabled = backgroundAgent.isMonitoringEnabled
        backgroundAgentState = backgroundAgent.state(
            providers: providers,
            snapshotUpdatedAt: updatedAtDate
        )
    }

    /// Reflects what `SMAppService` actually reports afterwards. A first
    /// registration lands on `requiresApproval`, and a toggle that snapped to
    /// "on" there would be claiming a refresh that macOS is still holding.
    public func setMonitorInBackground(_ enabled: Bool) {
        _ = backgroundAgent.setMonitoringEnabled(enabled)
        refreshBackgroundAgentState()
    }

    public func performBackgroundAgentRecovery(_ action: BackgroundAgentRecovery) {
        backgroundAgent.perform(action)
        refreshBackgroundAgentState()
    }

    /// Reads the legacy runtime and the consumer gate without changing either.
    ///
    /// Synchronous, and called when Settings opens rather than on every
    /// snapshot: it shells out to `launchctl` twice, which is fast but is not
    /// free, and nothing about a new provider reading changes whether the old
    /// launchd job exists.
    public func refreshLegacyMigration() {
        guard let legacyMigrator else {
            legacyMigration = .notApplicable
            return
        }
        if case .running = legacyMigration {
            return
        }
        let inventory = legacyMigrator.inventory(
            wrapperURL: legacyWrapperURL, standaloneBridgeURL: legacyBridgeURL
        )
        guard inventory.needsMigration else {
            legacyMigration = .notApplicable
            return
        }
        let rejections = legacyMigrator.consumerRejections()
        legacyMigration = rejections.isEmpty ? .ready : .waitingOnConsumers(rejections)
    }

    /// Runs the cutover off the main actor and reports every step it waits in
    /// (INV-1). Refuses to start from any state but `.ready`, so a second click
    /// cannot start a second migration.
    public func startLegacyMigration() {
        guard let legacyMigrator, legacyMigration.canStartMigration else { return }
        legacyMigration = .running(LegacyMigrationPhase.checkingConsumers.progressDescription)
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = legacyMigrator.migrate { step in
                Task { @MainActor [weak self] in self?.legacyMigration = .running(step) }
            }
            await MainActor.run { [weak self] in
                self?.applyMigrationOutcome(outcome)
            }
        }
    }

    private func applyMigrationOutcome(_ outcome: LegacyMigrationOutcome) {
        switch outcome {
        case .notNeeded: legacyMigration = .notApplicable
        case let .blocked(rejections): legacyMigration = .waitingOnConsumers(rejections)
        case .migrated: legacyMigration = .migrated
        case let .rolledBack(failure): legacyMigration = .rolledBack(failure)
        }
        refreshBackgroundAgentState()
    }

    public func updateConnectedDevices(_ devices: [DevicePresence]) {
        connectedDevices = devices
    }

    private func advancePresentationRevision() {
        presentationRevision &+= 1
    }

    @discardableResult
    public func cloudSyncDidStart() -> UInt64? {
        guard requiredICloudMode.allowsLiveWork else { return nil }
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
        GradusLog.publish.warning("cloud sync failed (operation \(operationID))")
        syncState = .failed
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginManager.setEnabled(enabled)
            launchAtLoginEnabled = LaunchAtLoginManager.isEnabled
        } catch {
            // Reflect whatever SMAppService actually did rather than assume
            // the requested state took effect. The UI silently snapping back
            // to the old value is the only signal a user ever got; the reason
            // was discarded here.
            GradusLog.app.warning(
                "could not set launch-at-login to \(enabled): \(error.localizedDescription)"
            )
            launchAtLoginEnabled = LaunchAtLoginManager.isEnabled
        }
    }
}
