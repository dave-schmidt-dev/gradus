import CloudKit
import Foundation
@testable import GradusiOS
import Testing

@MainActor
@Test func publisherProjectsTheThreeMostUrgentProvidersInStableOrder() {
    let store = RecordingWidgetStore()
    let reloader = RecordingTimelineReloader()
    let publisher = WidgetSnapshotPublisher(store: store, timelineReloader: reloader)

    publisher.synchronize(
        providers: [
            publisherStatus("fourth", percentLeft: 80),
            publisherStatus("second", percentLeft: 20),
            publisherStatus("first", percentLeft: 10),
            publisherStatus("third", percentLeft: 30)
        ],
        phoneSyncDate: Date(timeIntervalSince1970: 1_787_483_600),
        localWarningThreshold: 20
    )

    #expect(store.snapshot?.providers.map(\.providerName) == ["first", "second", "third"])
    #expect(store.snapshot?.providerName == "first")
    #expect(reloader.reloadCount == 1)
}

@MainActor
@Test func widgetProviderExclusionsPersistAndNeverFilterTheDashboard() {
    let syncedAt = Date(timeIntervalSince1970: 1_787_483_600)
    let cache = PublisherCacheStore(
        statuses: [
            publisherStatus("copilot", percentLeft: 5),
            publisherStatus("codex", percentLeft: 50)
        ],
        syncedAt: syncedAt
    )
    let defaults = syncIsolatedDefaults()
    defaults.set(true, forKey: DashboardViewModel.syncEnabledKey)
    let store = RecordingWidgetStore()
    let reloader = RecordingTimelineReloader()
    let publisher = WidgetSnapshotPublisher(store: store, timelineReloader: reloader)
    let viewModel = DashboardViewModel(
        cache: cache,
        liveLifecycleGate: nil,
        widgetSnapshotPublisher: publisher,
        initialAccountStatus: .available,
        userDefaults: defaults
    )

    #expect(store.snapshot?.providerName == "copilot")
    viewModel.setProviderIncludedInWidget("copilot", included: false)
    #expect(store.snapshot?.providerName == "codex")
    #expect(viewModel.providers.map(\.providerName) == ["copilot", "codex"])
    #expect(defaults.stringArray(forKey: DashboardViewModel.widgetExcludedProviderNamesKey) == ["copilot"])

    viewModel.setProviderIncludedInWidget("codex", included: false)
    #expect(store.snapshot == nil)
    #expect(viewModel.providers.count == 2)

    let relaunched = DashboardViewModel(cache: cache, userDefaults: defaults)
    #expect(!relaunched.isProviderIncludedInWidget("copilot"))
    #expect(!relaunched.isProviderIncludedInWidget("codex"))
    #expect(relaunched.providers.count == 2)
}
