import AppKit
@testable import GradusMac
import SnapshotTesting
import SwiftUI
import Testing

/// Opt in only in the explicit recording helper. Ordinary focused and full
/// gates compare against the staged baselines and cannot rewrite checkout files.
/// `OTHER_SWIFT_FLAGS='$(inherited) -D MAC_SETTINGS_SNAPSHOT_RECORD'`
private let macSettingsSnapshotRecording: SnapshotTestingConfiguration.Record = {
    #if MAC_SETTINGS_SNAPSHOT_RECORD
        return .all
    #else
        return .never
    #endif
}()

private let macSettingsSnapshotTimeZoneIsPinned: Bool = {
    let identifier = "America/New_York"
    guard let zone = TimeZone(identifier: identifier) else {
        preconditionFailure("unknown snapshot time zone \(identifier)")
    }
    NSTimeZone.default = zone
    print("GRADUS_EFFECTIVE_TIME_ZONE=\(TimeZone.current.identifier)")
    return TimeZone.current.identifier == identifier
}()

private final class MacSettingsSnapshotAgentService: BackgroundAgentServicing {
    var registration: BackgroundAgentRegistration = .notRegistered
    func register() throws {}
    func unregister() throws {}
}

@MainActor
private final class MacSettingsSnapshotNotificationScheduler: ResetNotificationScheduling {
    var authorizationResult: ResetNotificationAuthorization
    var requestStarted = false
    private var requestStartedContinuation: CheckedContinuation<Void, Never>?
    private var requestContinuation: CheckedContinuation<ResetNotificationAuthorization, Never>?

    init(authorization: ResetNotificationAuthorization) {
        authorizationResult = authorization
    }

    func authorization() async -> ResetNotificationAuthorization {
        authorizationResult
    }

    func requestAuthorization() async -> ResetNotificationAuthorization {
        requestStarted = true
        requestStartedContinuation?.resume()
        requestStartedContinuation = nil
        return await withCheckedContinuation { requestContinuation = $0 }
    }

    func schedule(_: ResetNotificationEvent) {}

    func waitUntilRequestStarted() async {
        guard !requestStarted else { return }
        await withCheckedContinuation { requestStartedContinuation = $0 }
    }

    func completeRequest(_ result: ResetNotificationAuthorization) {
        requestContinuation?.resume(returning: result)
        requestContinuation = nil
    }
}

@MainActor
private final class MacSettingsSnapshotBankedAuthorizer: BankedBackgroundAccessAuthorizing {
    func authorize() async -> Bool {
        false
    }
}

@MainActor
private func makeMacSettingsSnapshotModel(
    suite: String,
    scheduler: MacSettingsSnapshotNotificationScheduler
) -> PublisherViewModel {
    let defaults = scratchDefaults("com.zerodelta.gradus.mac.settings-snapshot.\(suite)")!
    defaults.set(true, forKey: PublisherViewModel.resetGrantAlertsEnabledKey)
    defaults.set(true, forKey: PublisherViewModel.resetRefillAlertsEnabledKey)

    let manager = BackgroundAgentManager(
        service: MacSettingsSnapshotAgentService(),
        statusFileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("gradus-settings-snapshot-agent-absent-\(suite)")
    )
    let model = PublisherViewModel(
        defaults: defaults,
        backgroundAgent: manager,
        resetNotificationScheduler: scheduler,
        bankedAccessAuthorizer: MacSettingsSnapshotBankedAuthorizer()
    )
    // The production initializer reads the host's main-app login item status.
    // The snapshot owns no login-item integration, so fix the displayed value.
    model.launchAtLoginEnabled = false
    return model
}

@MainActor
private func macSettingsSnapshotImage(
    model: PublisherViewModel,
    colorScheme: ColorScheme
) -> NSImage {
    #expect(macSettingsSnapshotTimeZoneIsPinned)
    let size = CGSize(width: 460, height: 1600)
    let content = MacSettingsView(viewModel: model)
        .environment(\.colorScheme, colorScheme)
        .frame(width: size.width, height: size.height)
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.backgroundColor = .windowBackgroundColor
    window.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    window.contentView = NSHostingView(rootView: content)
    window.setContentSize(NSSize(width: size.width, height: size.height))
    defer {
        window.orderOut(nil)
        window.close()
    }

    // A window-backed host renders native Form controls and text. ImageRenderer
    // substitutes placeholder glyphs for AppKit-backed Toggle controls here.
    window.makeKeyAndOrderFront(nil)
    window.displayIfNeeded()
    guard let view = window.contentView else {
        fatalError("Mac Settings snapshot window has no content view")
    }
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    let bounds = view.bounds
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(bounds.width),
        pixelsHigh: Int(bounds.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Could not allocate a Mac Settings snapshot bitmap")
    }
    representation.size = bounds.size
    view.cacheDisplay(in: bounds, to: representation)
    let image = NSImage(size: bounds.size)
    image.addRepresentation(representation)
    #expect(image.size == size)
    return image
}

@MainActor
private func assertMacSettingsSnapshot(
    suite: String,
    testName: String,
    authorization: ResetNotificationAuthorization,
    colorScheme: ColorScheme
) async {
    let scheduler = MacSettingsSnapshotNotificationScheduler(authorization: authorization)
    let model = makeMacSettingsSnapshotModel(suite: suite, scheduler: scheduler)
    await model.refreshResetNotificationAuthorization()
    #expect(model.resetGrantAlertsEnabled)
    #expect(model.resetRefillAlertsEnabled)
    #expect(model.resetNotificationAuthorization == authorization)
    #expect(model.bankedCreditStatusText == "Unavailable")
    let image = macSettingsSnapshotImage(model: model, colorScheme: colorScheme)
    assertStagedSnapshot(
        of: image, as: .image, record: macSettingsSnapshotRecording, testName: testName
    )
}

@MainActor
private func assertMacSettingsRequestingSnapshot(
    suite: String,
    testName: String,
    colorScheme: ColorScheme
) async {
    let scheduler = MacSettingsSnapshotNotificationScheduler(authorization: .notDetermined)
    let model = makeMacSettingsSnapshotModel(suite: suite, scheduler: scheduler)
    // Explicit opt-in enters the same permission-request path as the Settings
    // toggle. Both preferences are already on in this deterministic fixture.
    let request = Task { await model.setResetGrantAlertsEnabled(true) }
    await scheduler.waitUntilRequestStarted()
    #expect(scheduler.requestStarted)
    #expect(model.resetNotificationAuthorization == .requesting)
    let image = macSettingsSnapshotImage(model: model, colorScheme: colorScheme)
    assertStagedSnapshot(
        of: image, as: .image, record: macSettingsSnapshotRecording, testName: testName
    )
    scheduler.completeRequest(.denied)
    await request.value
}

@MainActor
@Test func macSettingsResetAlertsOnLight() async {
    await assertMacSettingsSnapshot(
        suite: #function, testName: #function, authorization: .authorized, colorScheme: .light
    )
}

@MainActor
@Test func macSettingsResetAlertsOnDark() async {
    await assertMacSettingsSnapshot(
        suite: #function, testName: #function, authorization: .authorized, colorScheme: .dark
    )
}

@MainActor
@Test func macSettingsResetAlertsRequestingLight() async {
    await assertMacSettingsRequestingSnapshot(suite: #function, testName: #function, colorScheme: .light)
}

@MainActor
@Test func macSettingsResetAlertsRequestingDark() async {
    await assertMacSettingsRequestingSnapshot(suite: #function, testName: #function, colorScheme: .dark)
}

@MainActor
@Test func macSettingsResetAlertsDeniedLight() async {
    await assertMacSettingsSnapshot(
        suite: #function, testName: #function, authorization: .denied, colorScheme: .light
    )
}

@MainActor
@Test func macSettingsResetAlertsDeniedDark() async {
    await assertMacSettingsSnapshot(
        suite: #function, testName: #function, authorization: .denied, colorScheme: .dark
    )
}
