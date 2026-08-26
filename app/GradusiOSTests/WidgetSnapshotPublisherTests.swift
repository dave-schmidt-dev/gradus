import CloudKit
import Foundation
@testable import GradusiOS
import GradusKit
import Testing

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
    viewModel.commitWarningThreshold()
    #expect(store.snapshot?.status == .attention)
    #expect(reloader.reloadCount == 2)

    viewModel.localWarningThresholdPercent = 35
    viewModel.commitWarningThreshold()
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
    // A second suite: the first view model is still live, and the fixture
    // clears the domain it is handed on the way in.
    let deltaViewModel = makePublisherViewModel(
        cache: cache,
        publisher: publisher,
        zoneChangesFetcher: deltaFetcher,
        test: "\(#function).delta"
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

    // A second suite: `failingViewModel` is still live above.
    let fetchFailureViewModel = makePublisherViewModel(
        cache: PublisherCacheStore(),
        publisher: failedPublisher,
        fetcher: StaticPublisherFetcher(result: .failure(.expected)),
        test: "\(#function).fetchFailure"
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
    // A second suite: `zoneViewModel` is still live above.
    let accountViewModel = makePublisherViewModel(
        cache: PublisherCacheStore(statuses: [cached], syncedAt: syncedAt),
        publisher: accountPublisher,
        test: "\(#function).account"
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

@MainActor
@Test func relaunchAndThresholdAfterAccountLossDoNotResurrectWidget() {
    let cached = publisherStatus("cached", percentLeft: 45)
    let syncedAt = Date(timeIntervalSince1970: 1_787_483_600)
    let cache = PublisherCacheStore(statuses: [cached], syncedAt: syncedAt)

    let store = RecordingWidgetStore()
    let reloader = RecordingTimelineReloader()
    let publisher = WidgetSnapshotPublisher(store: store, timelineReloader: reloader)
    let viewModel = makePublisherViewModel(cache: cache, publisher: publisher)

    #expect(store.snapshot?.providerName == "cached")
    #expect(reloader.reloadCount == 1)

    // Account loss clears the widget snapshot while retaining cache
    viewModel.updateAccountStatus(.noAccount)
    #expect(store.snapshot == nil)
    #expect(reloader.reloadCount == 2)
    #expect(!viewModel.allProviders.isEmpty)

    // Modifying threshold and committing must not resurrect the widget snapshot
    viewModel.localWarningThresholdPercent = 50
    viewModel.commitWarningThreshold()
    #expect(store.snapshot == nil)
    #expect(reloader.reloadCount == 2)

    // Relaunching with retained cache but unconfirmed/non-available account (.couldNotDetermine) must not publish
    let relaunchStore = RecordingWidgetStore()
    let relaunchReloader = RecordingTimelineReloader()
    let relaunchPublisher = WidgetSnapshotPublisher(store: relaunchStore, timelineReloader: relaunchReloader)
    let relaunchDefaults = syncIsolatedDefaults()
    relaunchDefaults.set(true, forKey: DashboardViewModel.syncEnabledKey)
    let relaunchViewModel = DashboardViewModel(
        cache: cache,
        liveLifecycleGate: nil,
        widgetSnapshotPublisher: relaunchPublisher,
        userDefaults: relaunchDefaults
    )
    #expect(relaunchViewModel.accountStatus == .couldNotDetermine)
    #expect(relaunchStore.snapshot == nil)
    #expect(relaunchReloader.reloadCount == 0)

    // Threshold change on relaunch without available account also does not publish
    relaunchViewModel.localWarningThresholdPercent = 60
    relaunchViewModel.commitWarningThreshold()
    #expect(relaunchStore.snapshot == nil)
    #expect(relaunchReloader.reloadCount == 0)
}

@MainActor
@Test func recoveryRepublishesRetainedCacheWithoutRefetch() {
    let cached = publisherStatus("cached", percentLeft: 45)
    let syncedAt = Date(timeIntervalSince1970: 1_787_483_600)
    let cache = PublisherCacheStore(statuses: [cached], syncedAt: syncedAt)

    let store = RecordingWidgetStore()
    let reloader = RecordingTimelineReloader()
    let publisher = WidgetSnapshotPublisher(store: store, timelineReloader: reloader)
    let viewModel = makePublisherViewModel(
        cache: cache,
        publisher: publisher,
        accountStatus: .noAccount
    )

    #expect(store.snapshot == nil)
    #expect(reloader.reloadCount == 0)

    // Becoming available republishes the retained cache immediately
    viewModel.updateAccountStatus(.available)
    #expect(store.snapshot?.providerName == "cached")
    #expect(store.snapshot?.phoneSyncDate == syncedAt)
    #expect(reloader.reloadCount == 1)
}

@MainActor
@Test func disabledSyncClearsProjectionAndReenablingRepublishes() {
    let cached = publisherStatus("cached", percentLeft: 45)
    let syncedAt = Date(timeIntervalSince1970: 1_787_483_600)
    let cache = PublisherCacheStore(statuses: [cached], syncedAt: syncedAt)

    let store = RecordingWidgetStore()
    let reloader = RecordingTimelineReloader()
    let publisher = WidgetSnapshotPublisher(store: store, timelineReloader: reloader)
    let viewModel = makePublisherViewModel(cache: cache, publisher: publisher)

    #expect(store.snapshot?.providerName == "cached")
    #expect(reloader.reloadCount == 1)

    // Disabling sync clears the projection
    viewModel.syncEnabled = false
    #expect(store.snapshot == nil)
    #expect(reloader.reloadCount == 2)

    // Threshold edits while sync is disabled do not publish
    viewModel.localWarningThresholdPercent = 50
    viewModel.commitWarningThreshold()
    #expect(store.snapshot == nil)
    #expect(reloader.reloadCount == 2)

    // Re-enabling sync republishes the retained cache
    viewModel.syncEnabled = true
    #expect(store.snapshot?.providerName == "cached")
    #expect(reloader.reloadCount == 3)
}

@MainActor
@Test func oneReloadPerCommittedThresholdEdit() {
    let cached = publisherStatus("cached", percentLeft: 45)
    let syncedAt = Date(timeIntervalSince1970: 1_787_483_600)
    let cache = PublisherCacheStore(statuses: [cached], syncedAt: syncedAt)

    let store = RecordingWidgetStore()
    let reloader = RecordingTimelineReloader()
    let publisher = WidgetSnapshotPublisher(store: store, timelineReloader: reloader)
    let viewModel = makePublisherViewModel(cache: cache, publisher: publisher)

    #expect(reloader.reloadCount == 1)
    #expect(store.snapshot?.status == .ok)

    // Simulating slider drag: multiple intermediate value changes
    viewModel.localWarningThresholdPercent = 46
    viewModel.localWarningThresholdPercent = 47
    viewModel.localWarningThresholdPercent = 48
    viewModel.localWarningThresholdPercent = 49
    viewModel.localWarningThresholdPercent = 50

    // No intermediate reload fired during slider drag
    #expect(reloader.reloadCount == 1)

    // Editing commits: single write and reload
    viewModel.commitWarningThreshold()
    #expect(reloader.reloadCount == 2)
    #expect(store.snapshot?.status == .attention)
}

@MainActor
@Test func noWindowProviderDoesNotHideProviderWithValidUrgentWindow() {
    let store = RecordingWidgetStore()
    let reloader = RecordingTimelineReloader()
    let publisher = WidgetSnapshotPublisher(store: store, timelineReloader: reloader)

    let erroredWithoutWindows = publisherErrorStatusWithoutWindows()
    let urgentWithWindow = publisherStatus("urgent", percentLeft: 3, isWarning: true)

    let syncDate = Date(timeIntervalSince1970: 1_787_483_600)

    // Errored provider without windows is tier 0 in rankProviders, but must not hide urgentWithWindow
    publisher.synchronize(
        providers: [erroredWithoutWindows, urgentWithWindow],
        phoneSyncDate: syncDate,
        localWarningThreshold: 20
    )

    #expect(store.snapshot?.providerName == "urgent")
    #expect(store.snapshot?.selectedWindow?.percentLeft == 3)
    #expect(reloader.reloadCount == 1)

    // Provider with invalid window also does not hide valid urgent window
    let invalidWindowProvider = publisherInvalidWindowStatus()

    publisher.synchronize(
        providers: [invalidWindowProvider, urgentWithWindow],
        phoneSyncDate: syncDate,
        localWarningThreshold: 20
    )
    #expect(store.snapshot?.providerName == "urgent")

    // When only no-window providers exist, selects the most urgent no-window provider with nil window
    publisher.synchronize(
        providers: [erroredWithoutWindows],
        phoneSyncDate: syncDate,
        localWarningThreshold: 20
    )
    #expect(store.snapshot?.providerName == "errored_no_windows")
    #expect(store.snapshot?.selectedWindow == nil)
    #expect(store.snapshot?.status == .error)
}
