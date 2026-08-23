import CloudKit
import Foundation
@testable import GradusiOS
import GradusKit
import Testing

private enum PublisherTestError: Error {
    case expected
}

private final class RecordingWidgetStore: WidgetSnapshotStore, @unchecked Sendable {
    var snapshot: WidgetSnapshot?
    var failSave = false
    var failClear = false
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    func loadSnapshot() -> WidgetSnapshot? {
        snapshot
    }

    func saveSnapshot(_ snapshot: WidgetSnapshot) throws {
        guard !failSave else { throw PublisherTestError.expected }
        self.snapshot = snapshot
        saveCount += 1
    }

    func clear() throws {
        guard !failClear else { throw PublisherTestError.expected }
        snapshot = nil
        clearCount += 1
    }
}

@MainActor
private final class RecordingTimelineReloader: WidgetTimelineReloading {
    private(set) var reloadCount = 0

    func reloadGradusWidget() {
        reloadCount += 1
    }
}

private final class PublisherCacheStore: LocalCacheStore, @unchecked Sendable {
    var statuses: [ProviderStatus]
    var syncedAt: Date?
    var token: Data?
    var failSave = false
    var failClear = false

    init(statuses: [ProviderStatus] = [], syncedAt: Date? = nil) {
        self.statuses = statuses
        self.syncedAt = syncedAt
    }

    func loadCachedStatuses() -> [ProviderStatus] {
        statuses
    }

    func lastSyncedAt() -> Date? {
        syncedAt
    }

    func saveCachedStatuses(_ statuses: [ProviderStatus], syncedAt: Date) throws {
        guard !failSave else { throw PublisherTestError.expected }
        self.statuses = statuses
        self.syncedAt = syncedAt
    }

    func loadChangeToken() -> Data? {
        token
    }

    func saveChangeToken(_ token: Data?) throws {
        self.token = token
    }

    func clear() throws {
        guard !failClear else { throw PublisherTestError.expected }
        statuses = []
        syncedAt = nil
        token = nil
    }
}

private struct StaticPublisherFetcher: CloudFetcher {
    let result: Result<[ProviderStatus], PublisherTestError>

    func fetchAll() async throws -> [ProviderStatus] {
        try result.get()
    }
}

private func publisherStatus(
    _ name: String,
    percentLeft: Double,
    paceDelta: Double? = 0,
    isWarning: Bool = false,
    isDepleted: Bool = false
) -> ProviderStatus {
    ProviderStatus(
        providerName: name,
        providerDisplayName: name.capitalized,
        ok: true,
        errorMessage: nil,
        windows: [
            ProviderWindow(
                id: "weekly",
                percentLeft: percentLeft,
                resetISO: "2026-08-30T12:00:00Z",
                windowHours: 168,
                paceDelta: paceDelta
            )
        ],
        data: [:],
        observedAt: nil,
        snapshotUpdatedAt: "2026-08-23T12:00:00Z",
        publishedAt: Date(timeIntervalSince1970: 1_787_483_600),
        isWarning: isWarning,
        isDepleted: isDepleted
    )
}

@MainActor
private func makePublisherViewModel(
    cache: LocalCacheStore,
    publisher: WidgetSnapshotPublisher,
    fetcher: CloudFetcher? = nil,
    zoneChangesFetcher: ZoneChangesFetcher? = nil
) -> DashboardViewModel {
    let defaults = syncIsolatedDefaults()
    defaults.set(true, forKey: DashboardViewModel.syncEnabledKey)
    return DashboardViewModel(
        cache: cache,
        fetcher: fetcher,
        zoneChangesFetcher: zoneChangesFetcher,
        liveLifecycleGate: nil,
        widgetSnapshotPublisher: publisher,
        userDefaults: defaults
    )
}

@MainActor
@Test func cachedLiveStartupPublishesFixedProjectionAndPreferencesDeduplicate() {
    let syncedAt = Date(timeIntervalSince1970: 1_787_483_600)
    let cache = PublisherCacheStore(
        statuses: [
            publisherStatus("alpha", percentLeft: 30),
            publisherStatus("beta", percentLeft: 80)
        ],
        syncedAt: syncedAt
    )
    let store = RecordingWidgetStore()
    let reloader = RecordingTimelineReloader()
    let publisher = WidgetSnapshotPublisher(store: store, timelineReloader: reloader)
    let viewModel = makePublisherViewModel(cache: cache, publisher: publisher)

    #expect(store.snapshot?.providerName == "alpha")
    #expect(store.snapshot?.phoneSyncDate == syncedAt)
    #expect(store.snapshot?.status == .ok)
    #expect(reloader.reloadCount == 1)

    viewModel.providerSortOption = .nameAZ
    viewModel.showExhausted = false
    #expect(reloader.reloadCount == 1)

    viewModel.localWarningThresholdPercent = 35
    #expect(store.snapshot?.status == .attention)
    #expect(reloader.reloadCount == 2)

    viewModel.localWarningThresholdPercent = 35
    #expect(reloader.reloadCount == 2)
}

@MainActor
@Test func fullAndDeltaCacheCommitsPublish() async {
    let store = RecordingWidgetStore()
    let reloader = RecordingTimelineReloader()
    let publisher = WidgetSnapshotPublisher(store: store, timelineReloader: reloader)
    let cache = PublisherCacheStore()
    let fetched = publisherStatus("full", percentLeft: 55)
    let viewModel = makePublisherViewModel(
        cache: cache,
        publisher: publisher,
        fetcher: StaticPublisherFetcher(result: .success([fetched]))
    )
    viewModel.updateAccountStatus(.available)

    #expect(await viewModel.sync())
    #expect(store.snapshot?.providerName == "full")
    #expect(reloader.reloadCount == 1)

    let deltaFetcher = MockZoneChangesFetcher(outcomes: [
        .success(
            changed: [publisherStatus("delta", percentLeft: 10, isWarning: true)],
            deletedProviderNames: ["full"],
            newToken: Data([1])
        )
    ])
    let deltaViewModel = makePublisherViewModel(
        cache: cache,
        publisher: publisher,
        zoneChangesFetcher: deltaFetcher
    )
    deltaViewModel.updateAccountStatus(.available)
    await deltaViewModel.handleRemoteNotification()
    #expect(store.snapshot?.providerName == "delta")
    #expect(reloader.reloadCount == 2)
}

@MainActor
@Test func failedFetchAndCacheCommitDoNotReload() async {
    let fetched = publisherStatus("full", percentLeft: 55)
    let failedStore = RecordingWidgetStore()
    let failedReloader = RecordingTimelineReloader()
    let failedPublisher = WidgetSnapshotPublisher(
        store: failedStore,
        timelineReloader: failedReloader
    )
    let failingCache = PublisherCacheStore()
    failingCache.failSave = true
    let failingViewModel = makePublisherViewModel(
        cache: failingCache,
        publisher: failedPublisher,
        fetcher: StaticPublisherFetcher(result: .success([fetched]))
    )
    failingViewModel.updateAccountStatus(.available)
    _ = await failingViewModel.sync()
    #expect(failedStore.snapshot == nil)
    #expect(failedReloader.reloadCount == 0)

    let fetchFailureViewModel = makePublisherViewModel(
        cache: PublisherCacheStore(),
        publisher: failedPublisher,
        fetcher: StaticPublisherFetcher(result: .failure(.expected))
    )
    fetchFailureViewModel.updateAccountStatus(.available)
    #expect(await !fetchFailureViewModel.sync())
    #expect(failedReloader.reloadCount == 0)
}

@MainActor
@Test func writeAndClearFailuresNeverReloadStaleWidgetState() {
    let existing = WidgetSnapshot(
        phoneSyncDate: Date(timeIntervalSince1970: 1_787_483_600),
        providerName: "existing",
        providerDisplayName: "Existing",
        status: .ok
    )
    let store = RecordingWidgetStore()
    store.snapshot = existing
    store.failSave = true
    let reloader = RecordingTimelineReloader()
    let publisher = WidgetSnapshotPublisher(store: store, timelineReloader: reloader)

    publisher.synchronize(
        providers: [publisherStatus("replacement", percentLeft: 50)],
        phoneSyncDate: Date(),
        localWarningThreshold: 20
    )
    #expect(store.snapshot == existing)
    #expect(reloader.reloadCount == 0)

    store.failSave = false
    store.failClear = true
    publisher.clear()
    #expect(store.snapshot == existing)
    #expect(reloader.reloadCount == 0)
}

@MainActor
@Test func zoneAndAccountLossClearCommittedWidgetSnapshots() async {
    let cached = publisherStatus("cached", percentLeft: 45)
    let syncedAt = Date(timeIntervalSince1970: 1_787_483_600)

    let zoneStore = RecordingWidgetStore()
    let zoneReloader = RecordingTimelineReloader()
    let zonePublisher = WidgetSnapshotPublisher(
        store: zoneStore,
        timelineReloader: zoneReloader
    )
    let zoneCache = PublisherCacheStore(statuses: [cached], syncedAt: syncedAt)
    let zoneViewModel = makePublisherViewModel(
        cache: zoneCache,
        publisher: zonePublisher,
        zoneChangesFetcher: MockZoneChangesFetcher(outcomes: [.zoneDeleted])
    )
    zoneViewModel.updateAccountStatus(.available)
    await zoneViewModel.handleRemoteNotification()
    #expect(zoneStore.snapshot == nil)
    #expect(zoneReloader.reloadCount == 2)

    let accountStore = RecordingWidgetStore()
    let accountReloader = RecordingTimelineReloader()
    let accountPublisher = WidgetSnapshotPublisher(
        store: accountStore,
        timelineReloader: accountReloader
    )
    let accountViewModel = makePublisherViewModel(
        cache: PublisherCacheStore(statuses: [cached], syncedAt: syncedAt),
        publisher: accountPublisher
    )
    accountViewModel.updateAccountStatus(.noAccount)
    #expect(accountStore.snapshot == nil)
    #expect(accountReloader.reloadCount == 2)
}

@Test func sampleAndUITestModesNeverConstructLiveWidgetPublisher() {
    #expect(!GradusiOSApp.shouldCreateWidgetPublisher(
        isUITesting: true,
        sampleDataModeEnabled: false
    ))
    #expect(!GradusiOSApp.shouldCreateWidgetPublisher(
        isUITesting: false,
        sampleDataModeEnabled: true
    ))
    #expect(GradusiOSApp.shouldCreateWidgetPublisher(
        isUITesting: false,
        sampleDataModeEnabled: false
    ))
}
