import CloudKit
import GradusKit
import SwiftUI

@main
struct GradusMacApp: App {
    init() {
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
        PublishPipeline.shared.start()
    }

    var body: some Scene {
        MenuBarExtra("Gradus", systemImage: "gauge") {
            MenuContentView(viewModel: PublishPipeline.shared.viewModel)
        }
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
                let publishedAt = Date()
                let statuses = payload.providers.map {
                    makeProviderStatus(from: $0, snapshotUpdatedAt: payload.updatedAt, publishedAt: publishedAt)
                }
                try? await coordinator.upsert(statuses)
            }
        }
        self.watcher = watcher
        Task { await watcher.start() }
    }
}
