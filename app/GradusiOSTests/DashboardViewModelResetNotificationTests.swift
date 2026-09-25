import Foundation
@testable import GradusiOS
import GradusKit
import Testing
import UIKit

@MainActor
private final class RecordingResetScheduler: ResetNotificationScheduling {
    private(set) var alerts: [ResetAlert] = []

    func scheduleResetNotification(_ alert: ResetAlert) {
        alerts.append(alert)
    }
}

private struct ResetAuthorizationSource: NotificationAuthorizationSource {
    let value: NotificationAuthorization

    func currentAuthorization() async -> NotificationAuthorization {
        value
    }
}

private struct ResetFullFetcher: CloudFetcher {
    let statuses: [ProviderStatus]

    func fetchAll() async throws -> [ProviderStatus] {
        statuses
    }
}

private let resetGeneration = "d7b1af6a-a377-4f37-a318-8d6066cc33a7"
private let resetLowTime = "2026-09-24T10:00:00Z"
private let resetHighTime = "2026-09-24T12:00:00Z"
private let resetDeadline = "2026-09-24T11:00:00Z"

private func resetStatus(
    _ name: String, percent: Double, observedAt: String,
    deadline: String? = resetDeadline, count: Int? = nil,
    countObservedAt: String? = nil
) -> ProviderStatus {
    var data: [String: JSONValue] = [:]
    if let count, let countObservedAt {
        data = [
            "banked_reset_count": .double(Double(count)),
            "banked_reset_generation": .string(resetGeneration),
            "banked_reset_observed_at": .string(countObservedAt)
        ]
    }
    return ProviderStatus(
        providerName: name, providerDisplayName: name, ok: true,
        errorMessage: nil,
        windows: [ProviderWindow(
            id: "five_hour", percentLeft: percent, resetISO: deadline,
            windowHours: 5, paceDelta: nil
        )],
        data: data, observedAt: observedAt,
        snapshotUpdatedAt: observedAt, publishedAt: Date(timeIntervalSince1970: 1_790_000_000)
    )
}

@MainActor
private func resetViewModel(
    defaults: UserDefaults, cache: FileLocalCacheStore,
    scheduler: RecordingResetScheduler?,
    fullFetcher: CloudFetcher? = nil,
    deltaFetcher: ZoneChangesFetcher? = nil,
    authorization: NotificationAuthorization = .authorized
) async -> DashboardViewModel {
    defaults.set(true, forKey: DashboardViewModel.syncEnabledKey)
    let viewModel = DashboardViewModel(
        cache: cache, fetcher: fullFetcher, zoneChangesFetcher: deltaFetcher,
        resetNotificationScheduler: scheduler,
        notificationAuthorizationSource: ResetAuthorizationSource(value: authorization),
        userDefaults: defaults
    )
    viewModel.updateAccountStatus(.available)
    await viewModel.refreshNotificationAuthorization()
    return viewModel
}

@MainActor
@Test func fullAndDeltaSyncDetectRefillsAndLateSameTimestampBankedGrant() async throws {
    let defaults = syncIsolatedDefaults()
    let cache = syncTempCache()
    let scheduler = RecordingResetScheduler()
    let low = [
        resetStatus("Codex", percent: 20, observedAt: resetLowTime, count: 1, countObservedAt: resetLowTime),
        resetStatus("Codex (Spark)", percent: 20, observedAt: resetLowTime),
        resetStatus("Claude", percent: 20, observedAt: resetLowTime)
    ]
    let high = [
        resetStatus("Codex", percent: 100, observedAt: resetHighTime),
        resetStatus("Codex (Spark)", percent: 100, observedAt: resetHighTime,
                    deadline: "2026-09-24T13:00:00Z"),
        resetStatus("Claude", percent: 100, observedAt: resetHighTime,
                    deadline: "2026-09-24T13:00:00Z")
    ]
    let late = resetStatus(
        "Codex", percent: 100, observedAt: resetHighTime,
        count: 2, countObservedAt: resetHighTime
    )
    let delta = MockZoneChangesFetcher(outcomes: [
        .success(changed: high, deletedProviderNames: [], newToken: nil),
        .success(changed: [late], deletedProviderNames: [], newToken: nil)
    ])
    let viewModel = await resetViewModel(
        defaults: defaults, cache: cache, scheduler: scheduler,
        fullFetcher: ResetFullFetcher(statuses: low), deltaFetcher: delta
    )
    viewModel.setBankedResetAlertsEnabled(true)
    viewModel.setUsageRefillAlertsEnabled(true)

    #expect(await viewModel.sync())
    #expect(scheduler.alerts.isEmpty)
    await viewModel.handleRemoteNotification()
    #expect(scheduler.alerts.count == 3)
    #expect(scheduler.alerts.contains(.usageRefill(providerName: "Codex", windowID: "five_hour")))
    #expect(scheduler.alerts.contains(.usageRefill(providerName: "Codex (Spark)", windowID: "five_hour")))
    #expect(scheduler.alerts.contains(.usageRefill(providerName: "Claude", windowID: "five_hour")))
    await viewModel.handleRemoteNotification()
    #expect(scheduler.alerts.count == 4)
    #expect(scheduler.alerts.last == .bankedGrant(increase: 1, currentCount: 2))
    #expect(try viewModel.bankedResetStatus == .current(
        count: 2, observedAt: #require(ResetAlertDetector.parseInstant(resetHighTime))
    ))
}

@MainActor
@Test func missingAndStaleBankedKeysStayUnavailableUntilLaterIncrease() async {
    let defaults = syncIsolatedDefaults()
    let cache = syncTempCache()
    let scheduler = RecordingResetScheduler()
    let initial = resetStatus("Codex", percent: 20, observedAt: resetLowTime,
                              count: 2, countObservedAt: resetLowTime)
    let later = "2026-09-24T13:00:00Z"
    let delta = MockZoneChangesFetcher(outcomes: [
        .success(changed: [resetStatus("Codex", percent: 30, observedAt: resetHighTime)],
                 deletedProviderNames: [], newToken: nil),
        .success(changed: [resetStatus("Codex", percent: 35, observedAt: later,
                                       count: 2, countObservedAt: resetLowTime)],
                 deletedProviderNames: [], newToken: nil),
        .success(changed: [resetStatus("Codex", percent: 40,
                                       observedAt: "2026-09-24T14:00:00Z", count: 3,
                                       countObservedAt: "2026-09-24T14:00:00Z")],
                 deletedProviderNames: [], newToken: nil)
    ])
    let viewModel = await resetViewModel(
        defaults: defaults, cache: cache, scheduler: scheduler,
        fullFetcher: ResetFullFetcher(statuses: [initial]), deltaFetcher: delta
    )
    viewModel.setBankedResetAlertsEnabled(true)
    #expect(await viewModel.sync())
    await viewModel.handleRemoteNotification()
    #expect(viewModel.bankedResetStatus == .unavailable(
        lastObservedCount: 2, lastObservedAt: ResetAlertDetector.parseInstant(resetLowTime)
    ))
    await viewModel.handleRemoteNotification()
    #expect(scheduler.alerts.isEmpty)
    #expect(viewModel.bankedResetStatus == .unavailable(
        lastObservedCount: 2, lastObservedAt: ResetAlertDetector.parseInstant(resetLowTime)
    ))
    await viewModel.handleRemoteNotification()
    #expect(scheduler.alerts == [.bankedGrant(increase: 1, currentCount: 3)])
}

@MainActor
@Test func replayAndRestartKeepRefillCursorAndAllowSecondRealLowEdge() async {
    let defaults = syncIsolatedDefaults()
    let cache = syncTempCache()
    let scheduler = RecordingResetScheduler()
    let low = resetStatus("Codex", percent: 20, observedAt: resetLowTime)
    let firstHigh = resetStatus("Codex", percent: 100, observedAt: resetHighTime)
    let delta = MockZoneChangesFetcher(outcomes: [
        .success(changed: [low], deletedProviderNames: [], newToken: nil),
        .success(changed: [firstHigh], deletedProviderNames: [], newToken: nil),
        .success(changed: [firstHigh], deletedProviderNames: [], newToken: nil)
    ])
    let first = await resetViewModel(defaults: defaults, cache: cache, scheduler: scheduler, deltaFetcher: delta)
    first.setUsageRefillAlertsEnabled(true)
    await first.handleRemoteNotification()
    await first.handleRemoteNotification()
    await first.handleRemoteNotification()
    #expect(scheduler.alerts.count == 1)

    let secondDelta = MockZoneChangesFetcher(outcomes: [
        .success(changed: [resetStatus("Codex", percent: 10,
                                       observedAt: "2026-09-24T13:00:00Z")],
                 deletedProviderNames: [], newToken: nil),
        .success(changed: [resetStatus("Codex", percent: 99,
                                       observedAt: "2026-09-24T14:00:00Z")],
                 deletedProviderNames: [], newToken: nil)
    ])
    let restarted = await resetViewModel(
        defaults: defaults, cache: cache, scheduler: scheduler, deltaFetcher: secondDelta
    )
    #expect(restarted.usageRefillAlertsEnabled)
    await restarted.handleRemoteNotification()
    await restarted.handleRemoteNotification()
    #expect(scheduler.alerts.count == 2)
}

@MainActor
@Test func nilDeadlineRefillUsesSourceTimeAndAlertsOnlyOnce() async {
    let defaults = syncIsolatedDefaults()
    let cache = syncTempCache()
    let scheduler = RecordingResetScheduler()
    let delta = MockZoneChangesFetcher(outcomes: [
        .success(changed: [resetStatus("Claude", percent: 15, observedAt: resetLowTime)],
                 deletedProviderNames: [], newToken: nil),
        .success(changed: [resetStatus("Claude", percent: 100,
                                       observedAt: resetHighTime, deadline: nil)],
                 deletedProviderNames: [], newToken: nil),
        .success(changed: [resetStatus("Claude", percent: 10,
                                       observedAt: "2026-09-24T13:00:00Z")],
                 deletedProviderNames: [], newToken: nil),
        .success(changed: [resetStatus("Claude", percent: 100,
                                       observedAt: "2026-09-24T14:00:00Z", deadline: nil)],
                 deletedProviderNames: [], newToken: nil)
    ])
    let viewModel = await resetViewModel(defaults: defaults, cache: cache,
                                         scheduler: scheduler, deltaFetcher: delta)
    viewModel.setUsageRefillAlertsEnabled(true)
    for _ in 0 ..< 4 {
        await viewModel.handleRemoteNotification()
    }
    #expect(scheduler.alerts == [.usageRefill(providerName: "Claude", windowID: "five_hour")])
}

@MainActor
@Test func delayedDeliveryDoesNotUseDeviceClockForElapsedDeadline() async {
    let defaults = syncIsolatedDefaults()
    let cache = syncTempCache()
    let scheduler = RecordingResetScheduler()
    let oldDeadline = "2026-09-24T12:00:00Z"
    let delta = MockZoneChangesFetcher(outcomes: [
        .success(changed: [resetStatus("Claude", percent: 20,
                                       observedAt: resetLowTime, deadline: oldDeadline)],
                 deletedProviderNames: [], newToken: nil),
        // Delivered long after noon on this device, but the source saw the
        // high reading at 11:00, before its prior noon deadline.
        .success(changed: [resetStatus("Claude", percent: 100,
                                       observedAt: "2026-09-24T11:00:00Z",
                                       deadline: "2026-09-24T13:00:00Z")],
                 deletedProviderNames: [], newToken: nil),
        .success(changed: [resetStatus("Claude", percent: 15,
                                       observedAt: "2026-09-24T12:30:00Z",
                                       deadline: "2026-09-24T13:00:00Z")],
                 deletedProviderNames: [], newToken: nil),
        .success(changed: [resetStatus("Claude", percent: 100,
                                       observedAt: "2026-09-24T14:00:00Z",
                                       deadline: "2026-09-24T15:00:00Z")],
                 deletedProviderNames: [], newToken: nil)
    ])
    let viewModel = await resetViewModel(defaults: defaults, cache: cache,
                                         scheduler: scheduler, deltaFetcher: delta)
    viewModel.setUsageRefillAlertsEnabled(true)
    await viewModel.handleRemoteNotification()
    await viewModel.handleRemoteNotification()
    #expect(scheduler.alerts.isEmpty)
    await viewModel.handleRemoteNotification()
    await viewModel.handleRemoteNotification()
    #expect(scheduler.alerts == [.usageRefill(providerName: "Claude", windowID: "five_hour")])
}

@MainActor
@Test func resetConsentAndSystemAuthorizationGateDeliveryIndependently() async {
    let defaults = syncIsolatedDefaults()
    let cache = syncTempCache()
    let scheduler = RecordingResetScheduler()
    let delta = MockZoneChangesFetcher(outcomes: [
        .success(changed: [resetStatus("Codex", percent: 20, observedAt: resetLowTime,
                                       count: 1, countObservedAt: resetLowTime)],
                 deletedProviderNames: [], newToken: nil),
        .success(changed: [resetStatus("Codex", percent: 100, observedAt: resetHighTime,
                                       count: 2, countObservedAt: resetHighTime)],
                 deletedProviderNames: [], newToken: nil)
    ])
    let viewModel = await resetViewModel(
        defaults: defaults, cache: cache, scheduler: scheduler,
        deltaFetcher: delta, authorization: .denied
    )
    #expect(!viewModel.bankedResetAlertsEnabled && !viewModel.usageRefillAlertsEnabled)
    viewModel.setBankedResetAlertsEnabled(true)
    #expect(viewModel.resetAlertsSuppressedBySystem)
    await viewModel.handleRemoteNotification()
    await viewModel.handleRemoteNotification()
    #expect(scheduler.alerts.isEmpty)
    #expect(defaults.bool(forKey: DashboardViewModel.bankedResetAlertsEnabledKey))
    #expect(!defaults.bool(forKey: DashboardViewModel.usageRefillAlertsEnabledKey))
    #expect(ResetNotificationContent.make(for: .bankedGrant(increase: 1, currentCount: 2)).title
        == "New banked resets")
    #expect(ResetNotificationContent.make(for: .usageRefill(
        providerName: "Claude", windowID: "five_hour"
    )).title == "Usage refilled")
}

@MainActor
@Test func authorizedResetDeliveryRespectsEachIndependentOptIn() async {
    let defaults = syncIsolatedDefaults()
    let cache = syncTempCache()
    let scheduler = RecordingResetScheduler()
    let times = (10 ... 15).map { String(format: "2026-09-24T%02d:00:00Z", $0) }
    let statuses = [
        resetStatus("Codex", percent: 20, observedAt: times[0], count: 1, countObservedAt: times[0]),
        resetStatus("Codex", percent: 100, observedAt: times[1], count: 2, countObservedAt: times[1]),
        resetStatus("Codex", percent: 20, observedAt: times[2], count: 2, countObservedAt: times[2]),
        resetStatus("Codex", percent: 100, observedAt: times[3], count: 3, countObservedAt: times[3]),
        resetStatus("Codex", percent: 20, observedAt: times[4], count: 3, countObservedAt: times[4]),
        resetStatus("Codex", percent: 100, observedAt: times[5], count: 4, countObservedAt: times[5])
    ]
    let delta = MockZoneChangesFetcher(outcomes: statuses.map {
        .success(changed: [$0], deletedProviderNames: [], newToken: nil)
    })
    let viewModel = await resetViewModel(
        defaults: defaults, cache: cache, scheduler: scheduler, deltaFetcher: delta
    )

    await viewModel.handleRemoteNotification()
    await viewModel.handleRemoteNotification()
    #expect(scheduler.alerts.isEmpty)

    viewModel.setUsageRefillAlertsEnabled(true)
    await viewModel.handleRemoteNotification()
    await viewModel.handleRemoteNotification()
    #expect(scheduler.alerts == [.usageRefill(providerName: "Codex", windowID: "five_hour")])

    viewModel.setUsageRefillAlertsEnabled(false)
    viewModel.setBankedResetAlertsEnabled(true)
    await viewModel.handleRemoteNotification()
    await viewModel.handleRemoteNotification()
    #expect(scheduler.alerts == [
        .usageRefill(providerName: "Codex", windowID: "five_hour"),
        .bankedGrant(increase: 1, currentCount: 4)
    ])
}

@MainActor
@Test func secondResetOptInKeepsSharedPermissionRequestLive() async {
    var completions: [(Bool) -> Void] = []
    let delegate = AppDelegate(
        clearBadge: {},
        requestNotificationAuthorization: { _, completion in completions.append(completion) }
    )

    delegate.setWarningAlertsEnabled(true, knownAuthorization: .notDetermined)
    delegate.setWarningAlertsEnabled(true, knownAuthorization: .notDetermined)
    #expect(completions.count == 1)
    #expect(delegate.warningAlertAuthorization == .requesting)

    delegate.setWarningAlertsEnabled(false)
    completions[0](true)
    #expect(delegate.warningAlertAuthorization == .off)

    delegate.setWarningAlertsEnabled(true, knownAuthorization: .notDetermined)
    #expect(completions.count == 2)
    completions[1](true)
    for _ in 0 ..< 1000 where delegate.warningAlertAuthorization == .requesting {
        await Task.yield()
    }
    #expect(delegate.warningAlertAuthorization == .authorized)
}
