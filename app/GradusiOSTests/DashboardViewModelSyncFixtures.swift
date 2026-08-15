import Foundation
@testable import GradusiOS
import GradusKit

// Shared fixtures and helpers for the DashboardViewModelSyncTests suite,
// split across this file, DashboardViewModelSyncTests.swift,
// DashboardViewModelWarningNotificationTests.swift, and
// DashboardViewModelAccountLifecycleTests.swift to keep each file under
// SwiftLint's file_length limit. Helpers used by only one of those files stay
// declared privately in that file instead of here.

final class MockZoneChangesFetcher: ZoneChangesFetcher {
    var outcomes: [ZoneChangesOutcome]
    private(set) var tokensRequested: [Data?] = []

    init(outcomes: [ZoneChangesOutcome]) {
        self.outcomes = outcomes
    }

    func fetchZoneChanges(sinceToken token: Data?) async -> ZoneChangesOutcome {
        tokensRequested.append(token)
        guard !outcomes.isEmpty else { return .failure }
        return outcomes.removeFirst()
    }
}

func makeStatus(_ name: String, isWarning: Bool = false) -> ProviderStatus {
    ProviderStatus(
        providerName: name, providerDisplayName: name, ok: true, errorMessage: nil, windows: [], data: [:],
        observedAt: nil, snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
        publishedAt: Date(timeIntervalSince1970: 1_785_000_000),
        isWarning: isWarning
    )
}

/// A fresh suite per call -- `syncEnabled` persists to `UserDefaults`
/// (T3.2/T3.3), and `.standard` is shared process-wide, so tests that flip
/// it would otherwise leak state into each other under Swift Testing's
/// same-process execution.
///
/// Named `syncIsolatedDefaults` (not `isolatedDefaults`) because other test
/// files in this target each declare their own file-private
/// `isolatedDefaults()` fixture; this one must stay distinct now that it's
/// visible module-wide.
func syncIsolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "gradus-sync-tests-\(UUID().uuidString)")!
}

@MainActor
func makeViewModel(
    cache: LocalCacheStore, fetcher: ZoneChangesFetcher,
    warningNotificationScheduler: WarningNotificationScheduling? = nil,
    userDefaults: UserDefaults = syncIsolatedDefaults()
) -> DashboardViewModel {
    if userDefaults.object(forKey: DashboardViewModel.syncEnabledKey) == nil {
        userDefaults.set(true, forKey: DashboardViewModel.syncEnabledKey)
    }
    if userDefaults.object(forKey: DashboardViewModel.notificationsEnabledKey) == nil {
        userDefaults.set(true, forKey: DashboardViewModel.notificationsEnabledKey)
    }
    let viewModel = DashboardViewModel(
        cache: cache, zoneChangesFetcher: fetcher, warningNotificationScheduler: warningNotificationScheduler,
        userDefaults: userDefaults
    )
    viewModel.syncEnabled = true
    viewModel.updateAccountStatus(.available)
    return viewModel
}

/// Named `syncTempCache` (not `tempCache`) because another test file in this
/// target declares its own file-private `tempCache()` fixture; this one must
/// stay distinct now that it's visible module-wide.
func syncTempCache() -> FileLocalCacheStore {
    FileLocalCacheStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent(
            "gradus-sync-tests-\(UUID().uuidString)", isDirectory: true
        )
    )
}
