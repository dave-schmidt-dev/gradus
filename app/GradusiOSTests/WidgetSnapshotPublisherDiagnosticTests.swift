import Foundation
@testable import GradusiOS
import GradusKit
import Testing

@MainActor
@Test func containerUnavailableFiresDiagnosticAndReturnsNil() {
    var recorded: [WidgetSnapshotPublisher.Diagnostic] = []
    let customFileManager = FileManager()
    let publisher = WidgetSnapshotPublisher.live(
        fileManager: customFileManager,
        diagnosticHandler: { recorded.append($0) }
    )
    #expect(publisher == nil)
    #expect(recorded == [.containerUnavailable])
}

@MainActor
@Test func saveAndClearFailuresEmitDiagnosticsWithoutAffectingSyncOrReloading() {
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
    var recorded: [WidgetSnapshotPublisher.Diagnostic] = []
    let publisher = WidgetSnapshotPublisher(
        store: store,
        timelineReloader: reloader,
        diagnosticHandler: { recorded.append($0) }
    )

    publisher.synchronize(
        providers: [publisherStatus("replacement", percentLeft: 50)],
        phoneSyncDate: Date(),
        localWarningThreshold: 20
    )
    #expect(store.snapshot == existing)
    #expect(reloader.reloadCount == 0)
    #expect(recorded == [.saveFailed])

    store.failSave = false
    store.failClear = true
    publisher.clear()
    #expect(store.snapshot == existing)
    #expect(reloader.reloadCount == 0)
    #expect(recorded == [.saveFailed, .clearFailed])
}

@MainActor
@Test func widgetSaveFailureEmitsDiagnosticWithoutFailingDashboardSync() async {
    let fetched = publisherStatus("full", percentLeft: 55)
    let store = RecordingWidgetStore()
    store.failSave = true
    let reloader = RecordingTimelineReloader()
    var recorded: [WidgetSnapshotPublisher.Diagnostic] = []
    let publisher = WidgetSnapshotPublisher(
        store: store,
        timelineReloader: reloader,
        diagnosticHandler: { recorded.append($0) }
    )
    let cache = PublisherCacheStore()
    let viewModel = makePublisherViewModel(
        cache: cache,
        publisher: publisher,
        fetcher: StaticPublisherFetcher(result: .success([fetched]))
    )
    viewModel.updateAccountStatus(.available)

    let syncSucceeded = await viewModel.sync()
    #expect(syncSucceeded)
    #expect(viewModel.allProviders.count == 1)
    #expect(viewModel.allProviders.first?.providerName == "full")
    #expect(reloader.reloadCount == 0)
    #expect(recorded == [.saveFailed])
}
