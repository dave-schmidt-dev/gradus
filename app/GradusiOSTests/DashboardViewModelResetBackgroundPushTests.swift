import CloudKit
import Foundation
@testable import GradusiOS
import GradusKit
import Testing

@MainActor
private final class RecordingScheduler: ResetNotificationScheduling {
    private(set) var alerts: [ResetAlert] = []

    func scheduleResetNotification(_ alert: ResetAlert) {
        alerts.append(alert)
    }
}

private struct AuthorizedSource: NotificationAuthorizationSource {
    func currentAuthorization() async -> NotificationAuthorization {
        .authorized
    }
}

private struct AvailableAccountSource: AccountStatusSource {
    func currentAccountStatus() async throws -> CKAccountStatus {
        .available
    }
}

private struct SingleFetcher: CloudFetcher {
    let statuses: [ProviderStatus]

    func fetchAll() async throws -> [ProviderStatus] {
        statuses
    }
}

private func codexStatus(percent: Double, observedAt: String) -> ProviderStatus {
    ProviderStatus(
        providerName: "Codex", providerDisplayName: "Codex", ok: true, errorMessage: nil,
        windows: [ProviderWindow(
            id: "five_hour", percentLeft: percent, resetISO: "2026-09-24T11:00:00Z",
            windowHours: 5, paceDelta: nil
        )],
        data: [:], observedAt: observedAt,
        snapshotUpdatedAt: observedAt, publishedAt: Date(timeIntervalSince1970: 1_790_000_000)
    )
}

/// A silent push that cold-launches the app runs before the scene reads the
/// iCloud account or notification permission. The refill must still alert.
@MainActor
@Test func coldBackgroundPushReadsAccountAndPermissionBeforeAlerting() async {
    let defaults = syncIsolatedDefaults()
    let cache = syncTempCache()
    defaults.set(true, forKey: DashboardViewModel.syncEnabledKey)
    let warm = DashboardViewModel(
        cache: cache, fetcher: SingleFetcher(statuses: [codexStatus(percent: 20, observedAt: "2026-09-24T10:00:00Z")]),
        notificationAuthorizationSource: AuthorizedSource(), userDefaults: defaults
    )
    warm.updateAccountStatus(.available)
    warm.setUsageRefillAlertsEnabled(true)
    warm.setShortWindowRefillAlertsEnabled(true)
    #expect(await warm.sync())

    let scheduler = RecordingScheduler()
    let cold = DashboardViewModel(
        cache: cache, accountSource: AvailableAccountSource(),
        zoneChangesFetcher: MockZoneChangesFetcher(outcomes: [
            .success(changed: [codexStatus(percent: 100, observedAt: "2026-09-24T12:00:00Z")],
                     deletedProviderNames: [], newToken: nil)
        ]),
        resetNotificationScheduler: scheduler,
        notificationAuthorizationSource: AuthorizedSource(),
        userDefaults: defaults
    )
    #expect(cold.accountStatus != .available)
    #expect(cold.systemNotificationAuthorization == .notDetermined)

    await cold.handleBackgroundRemoteNotification()

    #expect(scheduler.alerts == [.usageRefill(providerName: "Codex", windowID: "five_hour")])
}
