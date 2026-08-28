import Foundation
import GradusKit
@testable import GradusWidgetSupport
import SnapshotTesting
import SwiftUI
import Testing
import UIKit
import XCTest

private let widgetNow = Date(timeIntervalSince1970: 1_787_483_600)
private let widgetTimeZone = TimeZone(identifier: "America/New_York")!
private final class GradusWidgetTestsBundleToken {}

/// Opt in only while intentionally refreshing these baselines:
/// OTHER_SWIFT_FLAGS='$(inherited) -D WIDGET_SNAPSHOT_RECORD'
private let recordWidgetSnapshots: SnapshotTestingConfiguration.Record = {
    #if WIDGET_SNAPSHOT_RECORD
        return .all
    #else
        return .never
    #endif
}()

private func widgetSnapshot(
    status: WidgetProviderStatus = .warning,
    percentLeft: Double = 17,
    syncAge: TimeInterval = 7 * 60,
    resetDate: Date? = Date(timeIntervalSince1970: 1_788_010_800),
    selectedWindow: Bool = true
) -> WidgetSnapshot {
    WidgetSnapshot(
        phoneSyncDate: widgetNow.addingTimeInterval(-syncAge),
        providerName: "codex",
        providerDisplayName: "Codex",
        status: status,
        selectedWindow: selectedWindow ? WidgetWindowSnapshot(
            id: "weekly",
            label: "Weekly",
            percentLeft: percentLeft,
            signalLevel: .red,
            resetDate: resetDate
        ) : nil
    )
}

private func defaultGradusWidgetTestsBundleResourceURL() -> URL? {
    let bundle = Bundle(for: GradusWidgetTestsBundleToken.self)
    return bundle.resourceURL ?? bundle.bundleURL
}

private func gradusWidgetSnapshotDirectory(
    file: StaticString = #filePath,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    bundleResourceURL: URL? = defaultGradusWidgetTestsBundleResourceURL()
) -> URL {
    if environment["CI_XCODE_CLOUD"]?.uppercased() == "TRUE", let bundleResourceURL {
        return bundleResourceURL
    }
    let fileURL = URL(fileURLWithPath: file.description)
    let testFileName = fileURL.deletingPathExtension().lastPathComponent
    return fileURL
        .deletingLastPathComponent()
        .appendingPathComponent("__Snapshots__", isDirectory: true)
        .appendingPathComponent(testFileName, isDirectory: true)
}

private func assertWidgetSnapshot<Value>(
    of value: @autoclosure () throws -> Value,
    as snapshotting: Snapshotting<Value, some Any>,
    named name: String? = nil,
    record: SnapshotTestingConfiguration.Record? = nil,
    timeout: TimeInterval = 5,
    fileID: StaticString = #fileID,
    file: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line,
    column: UInt = #column
) {
    let directory = gradusWidgetSnapshotDirectory(file: file)
    let failure: String?
    do {
        failure = try verifySnapshot(
            of: value(),
            as: snapshotting,
            named: name,
            record: record,
            snapshotDirectory: directory.path,
            timeout: timeout,
            fileID: fileID,
            file: file,
            testName: testName,
            line: line,
            column: column
        )
    } catch {
        failure = error.localizedDescription
    }

    guard let failure else { return }

    if Test.current != nil {
        Issue.record(
            Comment(rawValue: failure),
            sourceLocation: SourceLocation(
                fileID: fileID.description,
                filePath: file.description,
                line: Int(line),
                column: Int(column)
            )
        )
    } else {
        XCTFail(failure, file: file, line: line)
    }
}

private func widgetView(style: UIUserInterfaceStyle) -> some View {
    GradusSmallWidgetView(entry: GradusWidgetEntry(
        date: widgetNow,
        state: .current(widgetSnapshot())
    ), syncAgeOverride: "synced 7 min, 0 sec ago")
        .environment(\.calendar, Calendar(identifier: .gregorian))
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        .environment(\.timeZone, widgetTimeZone)
        .environment(\.dynamicTypeSize, .large)
        .preferredColorScheme(style == .dark ? .dark : .light)
}

private func walkthroughWidgetView(state: GradusWidgetEntry.State) -> some View {
    GradusSmallWidgetView(
        entry: GradusWidgetEntry(date: widgetNow, state: state),
        syncAgeOverride: "synced 7 min, 0 sec ago"
    )
    .environment(\.calendar, Calendar(identifier: .gregorian))
    .environment(\.locale, Locale(identifier: "en_US_POSIX"))
    .environment(\.timeZone, widgetTimeZone)
    .environment(\.dynamicTypeSize, .large)
    .preferredColorScheme(.dark)
}

/// Writes deterministic candidate-current widget PNGs only for the walkthrough driver.
@MainActor
@Test func exportWalkthroughWidgetStates() throws {
    guard let destination = ProcessInfo.processInfo.environment["GRADUS_WALKTHROUGH_WIDGET_OUTPUT"] else {
        return
    }
    let states: [(String, GradusWidgetEntry.State)] = [
        ("widget-render-current.png", .current(widgetSnapshot())),
        ("widget-render-empty.png", .empty),
        ("widget-render-unavailable.png", .unavailable)
    ]
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: destination, isDirectory: true),
        withIntermediateDirectories: true
    )
    for (name, state) in states {
        let renderer = ImageRenderer(content: walkthroughWidgetView(state: state))
        renderer.proposedSize = ProposedViewSize(width: 170, height: 170)
        renderer.scale = 3
        let data = try #require(renderer.uiImage?.pngData())
        try data.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name))
    }
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

@Test func errorStatusSnapshotRendersUnavailable() {
    let provider = WidgetTimelineProvider(
        snapshotLoader: { widgetSnapshot(status: .error, selectedWindow: true) },
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

@Test func percentageFormattingPreservesSubOnePercentAndMissingValues() {
    #expect(WidgetFormatting.percent(17.9) == "17%")
    #expect(WidgetFormatting.percent(0.7) == "0.7%")
    #expect(WidgetFormatting.percent(0.6) == "0.6%")
    #expect(WidgetFormatting.percent(0.0) == "0.0%")
    #expect(WidgetFormatting.percent(100.0) == "100%")
    #expect(WidgetFormatting.percent(nil) == "n/a")
    #expect(WidgetFormatting.percent(Double.nan) == "n/a")
    #expect(WidgetFormatting.percent(Double.infinity) == "n/a")
}

@Test func resetCopyHandlesPresentAndMissingDates() {
    let calendar = Calendar(identifier: .gregorian)
    let resetDate = Date(timeIntervalSince1970: 1_788_010_800)
    let usReset = WidgetFormatting.reset(
        resetDate,
        locale: Locale(identifier: "en_US"),
        timeZone: widgetTimeZone,
        calendar: calendar
    )
    #expect(usReset?.contains("Aug 29") == true)
    #expect(usReset?.contains("9:40") == true)
    #expect(usReset?.contains("AM") == true)

    let gbReset = WidgetFormatting.reset(
        resetDate,
        locale: Locale(identifier: "en_GB"),
        timeZone: widgetTimeZone,
        calendar: calendar
    )
    #expect(gbReset?.contains("29 Aug") == true)
    #expect(gbReset?.contains("09:40") == true)

    let deReset = WidgetFormatting.reset(
        resetDate,
        locale: Locale(identifier: "de_DE"),
        timeZone: widgetTimeZone,
        calendar: calendar
    )
    #expect(deReset?.contains("29") == true)
    #expect(deReset?.contains("Aug") == true)
    #expect(deReset?.contains("09:40") == true)

    #expect(WidgetFormatting.reset(nil, timeZone: widgetTimeZone, calendar: calendar) == nil)
}

@Test func accessibilityNamesProviderWindowPercentAndResetWithoutStaleSyncAge() {
    let label = WidgetFormatting.accessibilityLabel(
        snapshot: widgetSnapshot(),
        locale: Locale(identifier: "en_US"),
        timeZone: widgetTimeZone,
        calendar: Calendar(identifier: .gregorian)
    )
    #expect(label.contains("Codex"))
    #expect(label.contains("Weekly"))
    #expect(label.contains("17 percent remaining"))
    #expect(label.contains("resets"))
    #expect(!label.contains("synced"))

    // Sub-1 percent accessibility label
    let subOneLabel = WidgetFormatting.accessibilityLabel(
        snapshot: widgetSnapshot(percentLeft: 0.7),
        locale: Locale(identifier: "en_US"),
        timeZone: widgetTimeZone,
        calendar: Calendar(identifier: .gregorian)
    )
    #expect(subOneLabel.contains("0.7 percent remaining"))
    #expect(!subOneLabel.contains("0 percent remaining"))
    #expect(!subOneLabel.contains("synced"))

    // Error status accessibility label
    let errorLabel = WidgetFormatting.accessibilityLabel(
        snapshot: widgetSnapshot(status: .error),
        locale: Locale(identifier: "en_US"),
        timeZone: widgetTimeZone,
        calendar: Calendar(identifier: .gregorian)
    )
    #expect(errorLabel == "Codex, usage unavailable")

    // Missing window accessibility label
    let noWindowLabel = WidgetFormatting.accessibilityLabel(
        snapshot: widgetSnapshot(selectedWindow: false),
        locale: Locale(identifier: "en_US"),
        timeZone: widgetTimeZone,
        calendar: Calendar(identifier: .gregorian)
    )
    #expect(noWindowLabel == "Codex, usage unavailable")
}

@Test func placeholderEntryPreservesPlaceholderState() {
    let entry = GradusWidgetEntry(date: widgetNow, state: .placeholder)
    #expect(entry.state == .placeholder)
}

@Test func widgetRailHeightIsUniformTwelvePoints() {
    #expect(GradusSmallWidgetView.railHeight == 12)
}

@Test func resetFormattingHandlesFractionalSecondDates() {
    let fractionalDate = Date(timeIntervalSince1970: 1_788_010_800.456)
    let calendar = Calendar(identifier: .gregorian)
    let reset = WidgetFormatting.reset(
        fractionalDate,
        locale: Locale(identifier: "en_US"),
        timeZone: widgetTimeZone,
        calendar: calendar
    )
    #expect(reset != nil)
    #expect(reset?.contains("Aug 29") == true)
    #expect(reset?.contains("9:40") == true)
    #expect(reset?.contains("AM") == true)
}

@MainActor
@Test func viewRendersWithoutCrashingForErrorOrMissingWindow() {
    let errorEntry = GradusWidgetEntry(
        date: widgetNow,
        state: .current(widgetSnapshot(status: .error, selectedWindow: true))
    )
    let errorView = GradusSmallWidgetView(entry: errorEntry)
    _ = errorView.body

    let nilWindowEntry = GradusWidgetEntry(
        date: widgetNow,
        state: .current(widgetSnapshot(selectedWindow: false))
    )
    let nilWindowView = GradusSmallWidgetView(entry: nilWindowEntry)
    _ = nilWindowView.body

    let placeholderEntry = GradusWidgetEntry(
        date: widgetNow,
        state: .placeholder
    )
    let placeholderView = GradusSmallWidgetView(entry: placeholderEntry)
    _ = placeholderView.body
}

@MainActor
@Test func gradusSmallWidgetCurrentLight() {
    assertWidgetSnapshot(
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
    assertWidgetSnapshot(
        of: widgetView(style: .dark),
        as: .image(
            layout: .fixed(width: 170, height: 170),
            traits: UITraitCollection(userInterfaceStyle: .dark)
        ),
        record: recordWidgetSnapshots,
        testName: "gradusSmallWidgetCurrentDark"
    )
}

@Test func widgetSnapshotDirectoryUsesBundleRootWhenRunningInXcodeCloud() {
    let selected = gradusWidgetSnapshotDirectory(
        file: #filePath,
        environment: ["CI_XCODE_CLOUD": "TRUE"],
        bundleResourceURL: URL(fileURLWithPath: "/tmp/GradusWidgetTests.bundle", isDirectory: true)
    )
    #expect(selected.path == "/tmp/GradusWidgetTests.bundle")
}

@Test func widgetSnapshotDirectoryUsesSourceRelativeSnapshotsWhenNotInCloud() {
    let selected = gradusWidgetSnapshotDirectory(
        file: #filePath,
        environment: [:]
    )
    let testFileName = URL(fileURLWithPath: #filePath.description).deletingPathExtension().lastPathComponent
    #expect(selected.path.hasSuffix("/__Snapshots__/\(testFileName)"))
}
