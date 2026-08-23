import Foundation
import GradusKit
import WidgetKit

@MainActor
protocol WidgetTimelineReloading {
    func reloadGradusWidget()
}

struct SystemWidgetTimelineReloader: WidgetTimelineReloading {
    func reloadGradusWidget() {
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotPublisher.widgetKind)
    }
}

/// Projects live cached dashboard state into the reduced App Group contract.
/// The widget never reads CloudKit or the app's full cache directly.
@MainActor
final class WidgetSnapshotPublisher {
    static let appGroupIdentifier = "group.com.zerodelta.gradus"
    static let widgetKind = "GradusWidget"

    private let store: any WidgetSnapshotStore
    private let timelineReloader: any WidgetTimelineReloading

    init(
        store: any WidgetSnapshotStore,
        timelineReloader: any WidgetTimelineReloading
    ) {
        self.store = store
        self.timelineReloader = timelineReloader
    }

    static func live(fileManager: FileManager = .default) -> WidgetSnapshotPublisher? {
        live(
            fileManager: fileManager,
            timelineReloader: SystemWidgetTimelineReloader()
        )
    }

    static func live(
        fileManager: FileManager,
        timelineReloader: any WidgetTimelineReloading
    ) -> WidgetSnapshotPublisher? {
        guard let directory = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else { return nil }
        return WidgetSnapshotPublisher(
            store: FileWidgetSnapshotStore(directory: directory),
            timelineReloader: timelineReloader
        )
    }

    /// Writes and reloads only when the reduced projection actually changes.
    func synchronize(
        providers: [ProviderStatus],
        phoneSyncDate: Date?,
        localWarningThreshold: Double
    ) {
        guard let phoneSyncDate,
              let provider = fixedMostUrgentProvider(
                  providers, localThreshold: localWarningThreshold
              )
        else {
            clear()
            return
        }

        let snapshot = WidgetSnapshot(
            phoneSyncDate: phoneSyncDate,
            providerName: provider.providerName,
            providerDisplayName: provider.providerDisplayName,
            status: status(for: provider, localWarningThreshold: localWarningThreshold),
            selectedWindow: selectWidgetWindowSnapshot(from: provider.windows)
        )
        guard store.loadSnapshot() != snapshot else { return }
        do {
            try store.saveSnapshot(snapshot)
            timelineReloader.reloadGradusWidget()
        } catch {
            // The prior atomic snapshot remains authoritative. A later live
            // cache commit or preference change will retry publication.
        }
    }

    func clear() {
        guard store.loadSnapshot() != nil else { return }
        do {
            try store.clear()
            timelineReloader.reloadGradusWidget()
        } catch {
            // Do not reload while the prior snapshot may still be present.
        }
    }

    private func status(
        for provider: ProviderStatus,
        localWarningThreshold: Double
    ) -> WidgetProviderStatus {
        guard provider.rankingIsOK else { return .error }
        if provider.rankingIsDepleted {
            return .depleted
        }
        guard provider.rankingNeedsAttention(localThreshold: localWarningThreshold) else {
            return .ok
        }
        return provider.isWarning ? .warning : .attention
    }
}
