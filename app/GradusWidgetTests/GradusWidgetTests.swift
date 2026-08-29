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

private func mediumWidgetSnapshot() -> WidgetSnapshot {
    let providers = [
        ("codex", "Codex", 17.0, SignalLevel.red),
        ("claude", "Claude", 42.0, SignalLevel.orange),
        ("opencode-go", "OpenCode Go", 68.0, SignalLevel.yellow)
    ].map { item in
        let (name, displayName, percentLeft, signalLevel) = item
        return WidgetProviderSnapshot(
            providerName: name,
            providerDisplayName: displayName,
            status: .attention,
            selectedWindow: WidgetWindowSnapshot(
                id: "weekly",
                label: "Weekly",
                percentLeft: percentLeft,
                signalLevel: signalLevel
            )
        )
    }
    return WidgetSnapshot(
        phoneSyncDate: widgetNow.addingTimeInterval(-7 * 60),
        providers: providers
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

private func mediumWidgetView(style: UIUserInterfaceStyle) -> some View {
    GradusMediumWidgetView(entry: GradusWidgetEntry(
        date: widgetNow,
        state: .current(mediumWidgetSnapshot())
    ), syncAgeOverride: "synced 7 min ago")
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

@Test func galleryMetadataSupportsSmallAndMediumFamilies() {
    #expect(GradusWidgetMetadata.kind == "GradusWidget")
    #expect(GradusWidgetMetadata.displayName == "Gradus")
    #expect(GradusWidgetMetadata.galleryDescription == "Your most urgent provider usage at a glance.")
    #expect(GradusWidgetMetadata.supportedFamilies == [.systemSmall, .systemMedium])
}

@Test func aValidSecondaryProviderKeepsTheMediumSnapshotCurrent() {
    let snapshot = WidgetSnapshot(
        phoneSyncDate: widgetNow,
        providers: [
            WidgetProviderSnapshot(
                providerName: "broken", providerDisplayName: "Broken", status: .error
            ),
            mediumWidgetSnapshot().providers[0]
        ]
    )
    let provider = WidgetTimelineProvider(snapshotLoader: { snapshot }, now: { widgetNow })
    #expect(provider.entry() == GradusWidgetEntry(date: widgetNow, state: .current(snapshot)))
}

@Test func placeholderEntryPreservesPlaceholderState() {
    let entry = GradusWidgetEntry(date: widgetNow, state: .placeholder)
    #expect(entry.state == .placeholder)
}

@Test func widgetRailHeightIsUniformTwelvePoints() {
    #expect(GradusSmallWidgetView.railHeight == 12)
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

@MainActor
@Test func gradusMediumWidgetCurrentLight() {
    assertWidgetSnapshot(
        of: mediumWidgetView(style: .light),
        as: .image(
            layout: .fixed(width: 364, height: 170),
            traits: UITraitCollection(userInterfaceStyle: .light)
        ),
        record: recordWidgetSnapshots,
        testName: "gradusMediumWidgetCurrentLight"
    )
}

@MainActor
@Test func gradusMediumWidgetCurrentDark() {
    assertWidgetSnapshot(
        of: mediumWidgetView(style: .dark),
        as: .image(
            layout: .fixed(width: 364, height: 170),
            traits: UITraitCollection(userInterfaceStyle: .dark)
        ),
        record: recordWidgetSnapshots,
        testName: "gradusMediumWidgetCurrentDark"
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
