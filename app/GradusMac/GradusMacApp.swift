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
        PublishPipeline.shared.start()
    }

    var body: some Scene {
        MenuBarExtra("Gradus", systemImage: "gauge") {
            Text("Gradus")
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

    private static let snapshotPath = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Documents/Projects/gradus/.state/snapshot-v2.json")

    func start() {
        guard !started else { return }
        started = true

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

        let watcher = SnapshotWatcher(path: Self.snapshotPath) { payload in
            Task {
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
