import CloudKit
import Foundation
@testable import GradusiOS
import GradusKit

enum PublisherTestError: Error {
    case expected
}

final class RecordingWidgetStore: WidgetSnapshotStore, @unchecked Sendable {
    var snapshot: WidgetSnapshot?
    var failSave = false
    var failClear = false
    private(set) var saveCount = 0
    private(set) var clearCount = 0

    func loadSnapshot() -> WidgetSnapshot? {
        snapshot
    }

    func saveSnapshot(_ snapshot: WidgetSnapshot) throws {
        guard !failSave else { throw PublisherTestError.expected }
        self.snapshot = snapshot
        saveCount += 1
    }

    func clear() throws {
        guard !failClear else { throw PublisherTestError.expected }
        snapshot = nil
        clearCount += 1
    }
}

@MainActor
final class RecordingTimelineReloader: WidgetTimelineReloading {
    private(set) var reloadCount = 0

    func reloadGradusWidget() {
        reloadCount += 1
    }
}

final class PublisherCacheStore: LocalCacheStore, @unchecked Sendable {
    var statuses: [ProviderStatus]
    var syncedAt: Date?
    var token: Data?
    var failSave = false
    var failClear = false

    init(statuses: [ProviderStatus] = [], syncedAt: Date? = nil) {
        self.statuses = statuses
        self.syncedAt = syncedAt
    }

    func loadCachedStatuses() -> [ProviderStatus] {
        statuses
    }

    func lastSyncedAt() -> Date? {
        syncedAt
    }

    func saveCachedStatuses(_ statuses: [ProviderStatus], syncedAt: Date) throws {
        guard !failSave else { throw PublisherTestError.expected }
        self.statuses = statuses
        self.syncedAt = syncedAt
    }

    func loadChangeToken() -> Data? {
        token
    }

    func saveChangeToken(_ token: Data?) throws {
        self.token = token
    }

    func clear() throws {
        guard !failClear else { throw PublisherTestError.expected }
        statuses = []
        syncedAt = nil
        token = nil
    }
}

struct StaticPublisherFetcher: CloudFetcher {
    let result: Result<[ProviderStatus], PublisherTestError>

    func fetchAll() async throws -> [ProviderStatus] {
        try result.get()
    }
}

func publisherStatus(
    _ name: String,
    percentLeft: Double,
    paceDelta: Double? = 0,
    isWarning: Bool = false,
    isDepleted: Bool = false
) -> ProviderStatus {
    ProviderStatus(
        providerName: name,
        providerDisplayName: name.capitalized,
        ok: true,
        errorMessage: nil,
        windows: [
            ProviderWindow(
                id: "weekly",
                percentLeft: percentLeft,
                resetISO: "2026-08-30T12:00:00Z",
                windowHours: 168,
                paceDelta: paceDelta
            )
        ],
        data: [:],
        observedAt: nil,
        snapshotUpdatedAt: "2026-08-23T12:00:00Z",
        publishedAt: Date(timeIntervalSince1970: 1_787_483_600),
        isWarning: isWarning,
        isDepleted: isDepleted
    )
}

@MainActor
func makePublisherViewModel(
    cache: LocalCacheStore,
    publisher: WidgetSnapshotPublisher,
    fetcher: CloudFetcher? = nil,
    zoneChangesFetcher: ZoneChangesFetcher? = nil,
    accountStatus: CKAccountStatus = .available,
    test: String = #function
) -> DashboardViewModel {
    let defaults = syncIsolatedDefaults(test)
    defaults.set(true, forKey: DashboardViewModel.syncEnabledKey)
    return DashboardViewModel(
        cache: cache,
        fetcher: fetcher,
        zoneChangesFetcher: zoneChangesFetcher,
        liveLifecycleGate: nil,
        widgetSnapshotPublisher: publisher,
        initialAccountStatus: accountStatus,
        userDefaults: defaults
    )
}

func publisherErrorStatusWithoutWindows() -> ProviderStatus {
    ProviderStatus(
        providerName: "errored_no_windows",
        providerDisplayName: "Errored No Windows",
        ok: false,
        errorMessage: "Probe failed",
        windows: [],
        data: [:],
        observedAt: nil,
        snapshotUpdatedAt: "2026-08-23T12:00:00Z",
        publishedAt: Date(timeIntervalSince1970: 1_787_483_600),
        isWarning: false,
        isDepleted: false
    )
}

func publisherInvalidWindowStatus() -> ProviderStatus {
    ProviderStatus(
        providerName: "invalid_window",
        providerDisplayName: "Invalid Window",
        ok: false,
        errorMessage: "Invalid data",
        windows: [
            ProviderWindow(
                id: "bad",
                percentLeft: -5,
                resetISO: nil,
                windowHours: nil,
                paceDelta: nil
            )
        ],
        data: [:],
        observedAt: nil,
        snapshotUpdatedAt: "2026-08-23T12:00:00Z",
        publishedAt: Date(timeIntervalSince1970: 1_787_483_600),
        isWarning: false,
        isDepleted: false
    )
}
