import Foundation
@testable import GradusiOS
import GradusKit
import Testing

// Warning-notification content and scheduling coverage, split out of
// DashboardViewModelSyncTests.swift to keep that file under SwiftLint's
// file_length limit. Shares fixtures with it via
// DashboardViewModelSyncFixtures.swift.

@MainActor
private final class RecordingWarningNotificationScheduler: WarningNotificationScheduling {
    private(set) var scheduledProviders: [String] = []

    func scheduleWarningNotification(for provider: ProviderStatus, thresholdPercent _: Double) {
        scheduledProviders.append(provider.providerName)
    }
}

@Test func warningNotificationNamesProviderWindowAndThreshold() {
    let provider = ProviderStatus(
        providerName: "opencode-go", providerDisplayName: "OpenCode Go", ok: true,
        errorMessage: nil,
        windows: [
            ProviderWindow(id: "five_hour", percentLeft: 20, resetISO: nil, windowHours: 5, paceDelta: nil),
            ProviderWindow(id: "weekly", percentLeft: 80, resetISO: nil, windowHours: 168, paceDelta: nil)
        ], data: [:], observedAt: nil, snapshotUpdatedAt: "2026-08-11T12:00:00Z",
        publishedAt: Date(timeIntervalSince1970: 1_786_000_000), isWarning: true
    )

    let content = WarningNotificationContent.make(for: provider, thresholdPercent: 25)

    #expect(content?.title == "OpenCode Go 5 Hour warning")
    #expect(content?.body == "20% remaining, below your 25% warning threshold.")
}

@Test func providerWarningWithoutALocallyReachedThresholdDoesNotClaimOne() {
    let provider = ProviderStatus(
        providerName: "opencode-go", providerDisplayName: "OpenCode Go", ok: true,
        errorMessage: nil,
        windows: [
            ProviderWindow(id: "five_hour", percentLeft: 62, resetISO: nil, windowHours: 5, paceDelta: -0.20)
        ], data: [:], observedAt: nil, snapshotUpdatedAt: "2026-08-11T12:00:00Z",
        publishedAt: Date(timeIntervalSince1970: 1_786_000_000), isWarning: true
    )

    let content = WarningNotificationContent.make(for: provider, thresholdPercent: 25)

    #expect(content?.title == "OpenCode Go warning")
    #expect(content?.body == "A provider warning was reported. Open Gradus for details.")
}

@MainActor
@Test func nonWarningUpdateDoesNotScheduleNotification() async {
    let cache = syncTempCache()
    let scheduler = RecordingWarningNotificationScheduler()
    let fetcher = MockZoneChangesFetcher(outcomes: [
        .success(changed: [makeStatus("opencode-go")], deletedProviderNames: [], newToken: nil)
    ])
    let viewModel = makeViewModel(cache: cache, fetcher: fetcher, warningNotificationScheduler: scheduler)

    await viewModel.handleRemoteNotification()

    #expect(scheduler.scheduledProviders.isEmpty)
}

@MainActor
@Test func firstWarningSchedulesOneLocalNotification() async {
    let cache = syncTempCache()
    let scheduler = RecordingWarningNotificationScheduler()
    let fetcher = MockZoneChangesFetcher(outcomes: [
        .success(changed: [makeStatus("codex", isWarning: true)], deletedProviderNames: [], newToken: nil)
    ])
    let viewModel = makeViewModel(cache: cache, fetcher: fetcher, warningNotificationScheduler: scheduler)

    await viewModel.handleRemoteNotification()

    #expect(scheduler.scheduledProviders == ["codex"])
}

@MainActor
@Test func repeatedWarningUpdateDoesNotScheduleAnotherLocalNotification() async {
    let cache = syncTempCache()
    try? cache.saveCachedStatuses([makeStatus("codex")], syncedAt: Date())
    let scheduler = RecordingWarningNotificationScheduler()
    let warning = makeStatus("codex", isWarning: true)
    let fetcher = MockZoneChangesFetcher(outcomes: [
        .success(changed: [warning], deletedProviderNames: [], newToken: nil),
        .success(changed: [warning], deletedProviderNames: [], newToken: nil)
    ])
    let viewModel = makeViewModel(cache: cache, fetcher: fetcher, warningNotificationScheduler: scheduler)

    await viewModel.handleRemoteNotification()
    await viewModel.handleRemoteNotification()

    #expect(scheduler.scheduledProviders == ["codex"])
}

@MainActor
@Test func clearThenWarningSchedulesANewLocalNotification() async {
    let cache = syncTempCache()
    try? cache.saveCachedStatuses([makeStatus("codex")], syncedAt: Date())
    let scheduler = RecordingWarningNotificationScheduler()
    let fetcher = MockZoneChangesFetcher(outcomes: [
        .success(changed: [makeStatus("codex", isWarning: true)], deletedProviderNames: [], newToken: nil),
        .success(changed: [makeStatus("codex")], deletedProviderNames: [], newToken: nil),
        .success(changed: [makeStatus("codex", isWarning: true)], deletedProviderNames: [], newToken: nil)
    ])
    let viewModel = makeViewModel(cache: cache, fetcher: fetcher, warningNotificationScheduler: scheduler)

    await viewModel.handleRemoteNotification()
    await viewModel.handleRemoteNotification()
    await viewModel.handleRemoteNotification()

    #expect(scheduler.scheduledProviders == ["codex", "codex"])
}

@MainActor
@Test func warningNotificationIsGatedByNotificationsPreference() async {
    let defaults = syncIsolatedDefaults()
    defaults.set(false, forKey: DashboardViewModel.notificationsEnabledKey)
    let cache = syncTempCache()
    try? cache.saveCachedStatuses([makeStatus("codex")], syncedAt: Date())
    let scheduler = RecordingWarningNotificationScheduler()
    let fetcher = MockZoneChangesFetcher(outcomes: [
        .success(changed: [makeStatus("codex", isWarning: true)], deletedProviderNames: [], newToken: nil)
    ])
    let viewModel = makeViewModel(
        cache: cache, fetcher: fetcher, warningNotificationScheduler: scheduler, userDefaults: defaults
    )

    await viewModel.handleRemoteNotification()

    #expect(scheduler.scheduledProviders.isEmpty)
}

@MainActor
@Test func handleRemoteNotificationNoOpsWhenSyncDisabled() async {
    let cache = syncTempCache()
    let fetcher = MockZoneChangesFetcher(outcomes: [
        .success(changed: [makeStatus("codex")], deletedProviderNames: [], newToken: nil)
    ])
    let defaults = syncIsolatedDefaults()
    defaults.set(false, forKey: DashboardViewModel.syncEnabledKey)
    let viewModel = DashboardViewModel(cache: cache, zoneChangesFetcher: fetcher, userDefaults: defaults)
    viewModel.updateAccountStatus(.available)
    // Legacy false requires confirmation and must not start live work.
    await viewModel.handleRemoteNotification()

    #expect(viewModel.providers.isEmpty)
    #expect(fetcher.tokensRequested.isEmpty)
}
