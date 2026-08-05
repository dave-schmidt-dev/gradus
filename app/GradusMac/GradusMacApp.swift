import CloudKit
import GradusKit
import SwiftUI

@main
struct GradusMacApp: App {
    init() {
        #if DEBUG
        if CommandLine.arguments.contains("--cloudkit-spike") {
            Task { await CloudKitSpike.run() }
            return
        }
        if CommandLine.arguments.contains("--t1-7-gate") {
            Task { await T17SeamGate.run() }
            return
        }
        if CommandLine.arguments.contains("--t2-5-schema-gate") {
            Task { await T25SchemaGate.run() }
            return
        }
        #endif
        // `GradusMacTests` is a hosted unit-test bundle, so every
        // `xcodebuild test` run launches this app for real. Without this
        // guard the test host started the live pipeline, which did two things
        // no test should: it read the snapshot out of `~/Documents`, firing a
        // TCC consent prompt at whoever was sitting at the machine (and,
        // because the test host is Development-signed while the installed app
        // is Developer ID, *overwriting* the single TCC grant those two share
        // -- so the installed app then prompted on its next launch, forever
        // alternating), and it published to CloudKit **Production**, writing 9
        // real records during one 2026-08-05 test session. Tests must not
        // mutate the live zone. Verified by `cloudd` log and by decoding the
        // TCC `csreq` before and after a run; see `HISTORY.md`.
        guard !Self.isRunningTests else { return }
        PublishPipeline.shared.start()
    }

    /// True when a test bundle is hosted in this process. Both signals are
    /// checked because they fail in different directions: the environment
    /// variable is absent for UI-test *targets* (which drive a separate app
    /// process and legitimately want the real pipeline), while the class probe
    /// catches any XCTest-injected bundle regardless of how it was launched.
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    var body: some Scene {
        MenuBarExtra("Gradus", systemImage: "gauge") {
            MenuContentView(viewModel: PublishPipeline.shared.viewModel)
        }
        // REQUIRED, not cosmetic. `MenuBarExtra` defaults to `.menu`, which
        // does not render SwiftUI: it translates the content into `NSMenu`
        // items, flattening every stack into one item per `Text`, dropping
        // custom shapes, and replacing colors with menu text styling. The
        // dropdown shipped that way until 2026-08-05, so `MenuContentView`'s
        // usage bars and four-tier ramp had never been drawn once -- the
        // giveaway in a screenshot is the sync toggle rendering as an NSMenu
        // checkmark rather than a switch. The snapshot gate could not catch
        // it: `ProviderListViewSnapshotTests` renders the subview through
        // `ImageRenderer`, where SwiftUI draws normally, so the baselines were
        // correct and green against a path the user never saw.
        .menuBarExtraStyle(.window)
    }
}

/// Holds the long-lived publish pipeline (snapshot watcher → CloudKit
/// publisher) for the app's process lifetime. A `MenuBarExtra` app has no
/// root view that's always mounted to own this (the content closure is
/// only instantiated lazily when the user opens the menu), so it lives as
/// a process-lifetime singleton started from `init()` instead.
@MainActor
final class PublishPipeline {
    static let shared = PublishPipeline()

    private var coordinator: PublishCoordinator?
    private var watcher: SnapshotWatcher?
    private var accountMonitor: AccountStatusMonitor?
    private var started = false

    /// Local display state + the opt-in sync toggle -- the menu content
    /// view's single source of truth.
    let viewModel = PublisherViewModel()

    static let defaultSnapshotPath = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Documents/Projects/gradus/.state/snapshot-v2.json")

    /// `snapshotPath` is the publisher's single injected dependency onto the
    /// filesystem (INV-7) -- defaults to the real snapshot location but is
    /// overridable, so nothing downstream needs to compute or guess a path.
    /// Resolved to `nil` rather than defaulted to the MainActor-isolated
    /// `defaultSnapshotPath` directly: a default-argument expression is
    /// evaluated in a nonisolated context, which Swift 6 mode rejects for a
    /// MainActor-isolated static property.
    func start(snapshotPath: URL? = nil) {
        guard !started else { return }
        started = true

        let snapshotPath = snapshotPath ?? Self.defaultSnapshotPath
        let container = CKContainer(identifier: CloudKitConstants.containerIdentifier)
        let zoneID = CKRecordZone.ID(zoneName: CloudKitConstants.zoneName, ownerName: CKCurrentUserDefaultName)
        let database = CKDatabaseAdapter(database: container.privateCloudDatabase)
        let coordinator = PublishCoordinator(database: database, zoneID: zoneID)
        self.coordinator = coordinator

        // CV-6: gate publishing on account status rather than let a
        // signed-out/restricted account surface as an opaque CloudKit error
        // on every upsert.
        let accountSource = ContainerAccountStatusSource(containerIdentifier: CloudKitConstants.containerIdentifier)
        let accountMonitor = AccountStatusMonitor(source: accountSource) { _ in }
        self.accountMonitor = accountMonitor
        Task { await accountMonitor.start() }

        let viewModel = viewModel
        let watcher = SnapshotWatcher(path: snapshotPath) { payload in
            Task {
                // Local display always reflects the on-device snapshot --
                // only the CloudKit publish is gated on opt-in sync.
                await viewModel.apply(payload)

                guard await viewModel.syncEnabled else { return }
                let status = await accountMonitor.lastKnownStatus
                guard AccountStatusMonitor.publishingState(for: status) == .ready else { return }
                guard let operationID = await viewModel.cloudSyncDidStart() else { return }
                do {
                    let publishedAt = Date()
                    let syncSource = LocalSyncSource.current
                    let statuses = try payload.providers.map {
                        try makeProviderStatus(
                            from: $0,
                            snapshotUpdatedAt: payload.updatedAt,
                            publishedAt: publishedAt,
                            syncSource: syncSource
                        )
                    }
                    try await coordinator.upsert(statuses)
                    await viewModel.cloudSyncDidSucceed(operationID: operationID)
                } catch {
                    // Do not put CloudKit's error description in the UI: it
                    // can include record metadata. The menu exposes a stable,
                    // actionable state without reflecting payload contents.
                    await viewModel.cloudSyncDidFail(operationID: operationID)
                }
            }
        }
        self.watcher = watcher
        Task { await watcher.start() }
    }
}
