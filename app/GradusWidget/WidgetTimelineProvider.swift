import Foundation
import GradusKit
import WidgetKit

public enum GradusWidgetMetadata {
    public static let kind = "GradusWidget"
    public static let displayName = "Gradus"
    public static let galleryDescription = "Your most urgent usage window at a glance."
    public static let supportedFamilies: [WidgetFamily] = [.systemSmall]
}

public struct GradusWidgetEntry: TimelineEntry, Equatable {
    public enum State: Equatable {
        case placeholder
        case empty
        case unavailable
        case current(WidgetSnapshot)
    }

    public let date: Date
    public let state: State

    public init(date: Date, state: State) {
        self.date = date
        self.state = state
    }
}

public struct WidgetTimelineProvider: TimelineProvider {
    public static let appGroupIdentifier = "group.com.zerodelta.gradus"
    public static let refreshInterval: TimeInterval = 30 * 60

    private let snapshotLoader: () -> WidgetSnapshot?
    private let now: () -> Date

    public init(
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.now = now
        guard let directory = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            snapshotLoader = { nil }
            return
        }
        let store = FileWidgetSnapshotStore(directory: directory)
        snapshotLoader = store.loadSnapshot
    }

    public init(
        snapshotLoader: @escaping () -> WidgetSnapshot?,
        now: @escaping () -> Date
    ) {
        self.snapshotLoader = snapshotLoader
        self.now = now
    }

    public func placeholder(in _: Context) -> GradusWidgetEntry {
        GradusWidgetEntry(date: now(), state: .placeholder)
    }

    public func getSnapshot(in context: Context, completion: @escaping (GradusWidgetEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry())
    }

    public func getTimeline(in _: Context, completion: @escaping (Timeline<GradusWidgetEntry>) -> Void) {
        completion(timeline())
    }

    public func timeline() -> Timeline<GradusWidgetEntry> {
        let entry = entry()
        return Timeline(
            entries: [entry],
            policy: .after(entry.date.addingTimeInterval(Self.refreshInterval))
        )
    }

    public func entry() -> GradusWidgetEntry {
        let date = now()
        guard let snapshot = snapshotLoader() else {
            return GradusWidgetEntry(date: date, state: .empty)
        }
        guard snapshot.status != .error, snapshot.selectedWindow != nil else {
            return GradusWidgetEntry(date: date, state: .unavailable)
        }
        return GradusWidgetEntry(date: date, state: .current(snapshot))
    }
}
