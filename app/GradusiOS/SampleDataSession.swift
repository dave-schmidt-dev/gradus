import Foundation
import GradusKit

/// Owns the sample cache and preferences independently from the live iCloud
/// cache. It deliberately has no CloudKit, account, subscription, or
/// notification dependencies, so entering this path cannot start live work.
@MainActor
final class SampleDataSession: ObservableObject {
    @Published private(set) var viewModel: DashboardViewModel
    private let cache: FileLocalCacheStore
    private let bundle: Bundle
    private let defaults: UserDefaults
    private let preferencesSuiteName: String

    init(
        directory: URL,
        bundle: Bundle = .main,
        defaults: UserDefaults = UserDefaults(suiteName: SampleDataMode.preferencesSuiteName)!,
        preferencesSuiteName: String = SampleDataMode.preferencesSuiteName
    ) {
        cache = FileLocalCacheStore(directory: directory)
        self.bundle = bundle
        self.defaults = defaults
        self.preferencesSuiteName = preferencesSuiteName
        Self.seed(cache: cache, bundle: bundle)
        viewModel = DashboardViewModel(cache: cache, userDefaults: defaults)
    }

    func reset() {
        try? cache.clear()
        defaults.removePersistentDomain(forName: preferencesSuiteName)
        Self.seed(cache: cache, bundle: bundle)
        viewModel = DashboardViewModel(cache: cache, userDefaults: defaults)
    }

    private static func seed(cache: FileLocalCacheStore, bundle: Bundle) {
        guard let providers = try? SampleDataMode.bundledProviders(bundle: bundle) else { return }
        try? cache.saveCachedStatuses(providers, syncedAt: SampleDataMode.fixedNow)
    }
}
