import Foundation
import GradusKit
@testable import GradusWidgetSupport
import SnapshotTesting
import SwiftUI
import Testing
import UIKit

private let widgetNow = Date(timeIntervalSince1970: 1_787_483_600)
private let widgetTimeZone = TimeZone(identifier: "America/New_York")!
private let recordWidgetSnapshots: SnapshotTestingConfiguration.Record = .never

private func widgetSnapshot(
    percentLeft: Double = 17,
    syncAge: TimeInterval = 7 * 60,
    resetDate: Date? = Date(timeIntervalSince1970: 1_788_010_800),
    selectedWindow: Bool = true
) -> WidgetSnapshot {
    WidgetSnapshot(
        phoneSyncDate: widgetNow.addingTimeInterval(-syncAge),
        providerName: "codex",
        providerDisplayName: "Codex",
        status: .warning,
        selectedWindow: selectedWindow ? WidgetWindowSnapshot(
            id: "weekly",
            label: "Weekly",
            percentLeft: percentLeft,
            signalLevel: .red,
            resetDate: resetDate
        ) : nil
    )
}

private func widgetView(style: UIUserInterfaceStyle) -> some View {
    GradusSmallWidgetView(entry: GradusWidgetEntry(
        date: widgetNow,
        state: .current(widgetSnapshot())
    ))
    .environment(\.calendar, Calendar(identifier: .gregorian))
    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
    .environment(\.timeZone, widgetTimeZone)
    .environment(\.dynamicTypeSize, .large)
    .preferredColorScheme(style == .dark ? .dark : .light)
}

@Test func missingAndMalformedSnapshotsRenderEmpty() throws {
    let missing = WidgetTimelineProvider(snapshotLoader: { nil }, now: { widgetNow })
    #expect(missing.entry() == GradusWidgetEntry(date: widgetNow, state: .empty))

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "gradus-widget-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    let store = FileWidgetSnapshotStore(directory: directory)
    try Data("not-json".utf8).write(to: store.snapshotFileURL)
    let malformed = WidgetTimelineProvider(snapshotLoader: store.loadSnapshot, now: { widgetNow })
    #expect(malformed.entry().state == .empty)
}

@Test func snapshotWithoutSelectedWindowRendersUnavailable() {
    let provider = WidgetTimelineProvider(
        snapshotLoader: { widgetSnapshot(selectedWindow: false) },
        now: { widgetNow }
    )
    #expect(provider.entry().state == .unavailable)
}

@Test func validSnapshotRendersCurrentEntry() {
    let snapshot = widgetSnapshot()
    let provider = WidgetTimelineProvider(snapshotLoader: { snapshot }, now: { widgetNow })
    #expect(provider.entry() == GradusWidgetEntry(date: widgetNow, state: .current(snapshot)))
}

@Test func timelineRequestsNoEarlierThanThirtyMinutes() {
    let provider = WidgetTimelineProvider(snapshotLoader: { widgetSnapshot() }, now: { widgetNow })
    let timeline = provider.timeline()
    #expect(timeline.policy == .after(widgetNow.addingTimeInterval(30 * 60)))
    #expect(timeline.entries.count == 1)
}

@Test func galleryMetadataAndFamilyStaySmallOnly() {
    #expect(GradusWidgetMetadata.kind == "GradusWidget")
    #expect(GradusWidgetMetadata.displayName == "Gradus")
    #expect(GradusWidgetMetadata.galleryDescription == "Your most urgent usage window at a glance.")
    #expect(GradusWidgetMetadata.supportedFamilies == [.systemSmall])
}

@Test func percentageAndAgeFormattingAreBounded() {
    #expect(WidgetFormatting.percent(17.9) == "17%")
    #expect(WidgetFormatting.percent(-4) == "0%")
    #expect(WidgetFormatting.percent(140) == "100%")
    #expect(WidgetFormatting.syncedAge(from: widgetNow.addingTimeInterval(-59), now: widgetNow) == "synced <1m ago")
    let twoHoursAgo = widgetNow.addingTimeInterval(-2 * 3600)
    let threeDaysAgo = widgetNow.addingTimeInterval(-3 * 86400)
    #expect(WidgetFormatting.syncedAge(from: twoHoursAgo, now: widgetNow) == "synced 2h ago")
    #expect(WidgetFormatting.syncedAge(from: threeDaysAgo, now: widgetNow) == "synced 3d ago")
}

@Test func resetCopyHandlesPresentAndMissingDates() {
    let calendar = Calendar(identifier: .gregorian)
    #expect(WidgetFormatting.reset(
        Date(timeIntervalSince1970: 1_788_010_800),
        timeZone: widgetTimeZone,
        calendar: calendar
    ) == "resets Aug 29, 9:40 AM")
    #expect(WidgetFormatting.reset(nil, timeZone: widgetTimeZone, calendar: calendar) == nil)
}

@Test func accessibilityNamesProviderWindowPercentResetAndSyncAge() {
    let label = WidgetFormatting.accessibilityLabel(
        snapshot: widgetSnapshot(),
        now: widgetNow,
        timeZone: widgetTimeZone,
        calendar: Calendar(identifier: .gregorian)
    )
    #expect(label.contains("Codex"))
    #expect(label.contains("Weekly"))
    #expect(label.contains("17% remaining"))
    #expect(label.contains("resets"))
    #expect(label.contains("synced 7m ago"))
}

@MainActor
@Test func gradusSmallWidgetCurrentLight() {
    assertSnapshot(
        of: widgetView(style: .light),
        as: .image(
            layout: .fixed(width: 170, height: 170),
            traits: UITraitCollection(userInterfaceStyle: .light)
        ),
        record: recordWidgetSnapshots,
        testName: "gradusSmallWidgetCurrentLight"
    )
}

@MainActor
@Test func gradusSmallWidgetCurrentDark() {
    assertSnapshot(
        of: widgetView(style: .dark),
        as: .image(
            layout: .fixed(width: 170, height: 170),
            traits: UITraitCollection(userInterfaceStyle: .dark)
        ),
        record: recordWidgetSnapshots,
        testName: "gradusSmallWidgetCurrentDark"
    )
}
