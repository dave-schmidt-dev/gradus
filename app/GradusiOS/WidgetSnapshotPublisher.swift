import Foundation
import GradusKit
import OSLog
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

    enum Diagnostic: Equatable, Sendable {
        case containerUnavailable
        case saveFailed
        case clearFailed
    }

    private static let logger = Logger(subsystem: "com.zerodelta.gradus", category: "WidgetSnapshotPublisher")

    private let store: any WidgetSnapshotStore
    private let timelineReloader: any WidgetTimelineReloading
    private let diagnosticHandler: ((Diagnostic) -> Void)?

    init(
        store: any WidgetSnapshotStore,
        timelineReloader: any WidgetTimelineReloading,
        diagnosticHandler: ((Diagnostic) -> Void)? = nil
    ) {
        self.store = store
        self.timelineReloader = timelineReloader
        self.diagnosticHandler = diagnosticHandler
    }

    static func live(
        fileManager: FileManager = .default,
        diagnosticHandler: ((Diagnostic) -> Void)? = nil
    ) -> WidgetSnapshotPublisher? {
        live(
            fileManager: fileManager,
            timelineReloader: SystemWidgetTimelineReloader(),
            diagnosticHandler: diagnosticHandler
        )
    }

    static func live(
        fileManager: FileManager,
        timelineReloader: any WidgetTimelineReloading,
        diagnosticHandler: ((Diagnostic) -> Void)? = nil
    ) -> WidgetSnapshotPublisher? {
        guard let directory = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            recordDiagnostic(.containerUnavailable, handler: diagnosticHandler)
            return nil
        }
        return WidgetSnapshotPublisher(
            store: FileWidgetSnapshotStore(directory: directory),
            timelineReloader: timelineReloader,
            diagnosticHandler: diagnosticHandler
        )
    }

    /// Writes and reloads only when the reduced projection actually changes.
    func synchronize(
        providers: [ProviderStatus],
        phoneSyncDate: Date?,
        localWarningThreshold: Double
    ) {
        guard let phoneSyncDate,
              let provider = selectProvider(
                  from: providers,
                  localWarningThreshold: localWarningThreshold
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
            Self.recordDiagnostic(.saveFailed, handler: diagnosticHandler)
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
            Self.recordDiagnostic(.clearFailed, handler: diagnosticHandler)
            // Do not reload while the prior snapshot may still be present.
        }
    }

    private static func recordDiagnostic(
        _ diagnostic: Diagnostic,
        handler: ((Diagnostic) -> Void)?
    ) {
        handler?(diagnostic)
        switch diagnostic {
        case .containerUnavailable:
            logger.error("Gradus widget App Group container is unavailable")
        case .saveFailed:
            logger.error("Gradus widget snapshot save failed")
        case .clearFailed:
            logger.error("Gradus widget snapshot clear failed")
        }
    }

    private func selectProvider(
        from providers: [ProviderStatus],
        localWarningThreshold: Double
    ) -> ProviderStatus? {
        let ranked = fixedMostUrgentRankedProviders(
            providers,
            localThreshold: localWarningThreshold
        )
        return ranked.first { selectWidgetWindow(from: $0.windows) != nil } ?? ranked.first
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
