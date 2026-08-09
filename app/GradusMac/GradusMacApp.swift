import CloudKit
import GradusKit
import Security
import SwiftUI

@main
struct GradusMacApp: App {
    @State private var isMenuBarInserted: Bool

    init() {
        _isMenuBarInserted = State(initialValue: !Self.isTestHost())
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
        // `xcodebuild test` run launches this app for real. A Debug host must
        // never start the live pipeline by default: doing so reads the local
        // snapshot and can mutate
        // CloudKit. A developer debugging the live pipeline must opt in with
        // GRADUS_ENABLE_PIPELINE=1; distribution builds remain live by
        // default. This is deliberately a fail-closed code boundary, not a
        // convention in an Xcode scheme that an ad-hoc test command can miss.
        guard !Self.pipelineDisabled else { return }
        PublishPipeline.shared.start()
    }

    /// True when this launch must not run the live pipeline.
    ///
    /// A test can supply `GRADUS_DISABLE_PIPELINE=1`; that remains useful for
    /// Release-like test artifacts. Debug builds also fail closed unless a
    /// human explicitly sets `GRADUS_ENABLE_PIPELINE=1`. Runtime XCTest
    /// detection alone is insufficient because `App.init()` runs before the
    /// test bundle is injected. `XCTestConfigurationFilePath` remains a
    /// secondary signal for test launches outside the scheme.
    static var pipelineDisabled: Bool {
        pipelineDisabled(environment: ProcessInfo.processInfo.environment)
    }

    static func pipelineDisabled(environment: [String: String]) -> Bool {
        if environment["GRADUS_DISABLE_PIPELINE"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil {
            return true
        }

        #if DEBUG
        return environment["GRADUS_ENABLE_PIPELINE"] != "1"
        #else
        return false
        #endif
    }

    /// Hosted unit tests launch this application binary. They must not create
    /// a status item: the test host has its pipeline disabled and can outlive
    /// `xcodebuild`, leaving the user a real-looking but permanently empty
    /// Gradus menu instead of the signed app's live one.
    static func isTestHost(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }

    var body: some Scene {
        MenuBarExtra("Gradus", systemImage: "gauge", isInserted: $isMenuBarInserted) {
            MenuBarContentRoot(viewModel: PublishPipeline.shared.viewModel)
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
        }
        .menuBarExtraStyle(.window)

        // No `Settings` scene here on purpose. Declaring one is the idiomatic
        // way to get a preferences window, and on macOS 26.5.2 nothing opens
        // it: `showSettingsWindow:` returns true and does nothing, the pre-13
        // `showPreferencesWindow:` no longer resolves at all, and neither
        // changes when the app is promoted out of `.accessory` first. The
        // window is built directly instead -- see `SettingsWindow`, which
        // carries the measurements. A declared-but-unreachable scene would
        // read as working code.
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
        .appendingPathComponent("Library/Application Support/Gradus/snapshot-v2.json")

    private static func signedCloudKitEnvironment() -> String {
        guard let task = SecTaskCreateFromSelf(nil),
            let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-container-environment" as CFString,
                nil
            ) as? String,
            !value.isEmpty
        else {
            // The Debug entitlement omits this optional key, which means the
            // app is using CloudKit's Development environment.
            return "Development"
        }
        return value
    }

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
        guard let producerBuildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        else {
            GradusLog.app.error("could not resolve signed producer metadata; publishing disabled")
            return
        }
        let cloudKitEnvironment = Self.signedCloudKitEnvironment()
        let evidencePath = snapshotPath
            .deletingLastPathComponent()
            .appendingPathComponent("publish-evidence.json")
        let coordinator = PublishCoordinator(
            database: database,
            zoneID: zoneID,
            evidencePath: evidencePath,
            producerBuildNumber: producerBuildNumber,
            cloudKitEnvironment: cloudKitEnvironment
        )
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
