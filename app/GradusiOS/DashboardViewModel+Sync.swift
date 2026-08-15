import Foundation
import GradusKit

/// The CloudKit sync/reconciliation paths: push-driven delta sync, full
/// fetch, and the single idempotent live-lifecycle reconciliation that both
/// bootstrap and foreground recovery call through.
extension DashboardViewModel {
    /// Entry point for a push-driven delta sync (T4.1): fetches only what
    /// changed in `GradusZone` since the persisted token and reconciles it
    /// into `providers`, rather than re-fetching everything (`sync()`'s
    /// full-fetch path, used on launch/pull-to-refresh).
    public func handleRemoteNotification() async {
        guard syncEnabled, accountStatus == .available, let zoneChangesFetcher else { return }
        let token = cache.loadChangeToken()
        if let liveLifecycleGate {
            await liveLifecycleGate.withOperation { operationEpoch in
                await self.performIncrementalSync(
                    using: zoneChangesFetcher, token: token, allowRetryOnExpiredToken: true,
                    lifecycleEpoch: operationEpoch
                )
            }
        } else {
            await performIncrementalSync(using: zoneChangesFetcher, token: token, allowRetryOnExpiredToken: true)
        }
    }

    private func performIncrementalSync(
        using fetcher: ZoneChangesFetcher,
        token: Data?,
        allowRetryOnExpiredToken: Bool,
        lifecycleEpoch: LiveLifecycleGate.Epoch? = nil
    ) async {
        if let lifecycleEpoch, let liveLifecycleGate, !liveLifecycleGate.isCurrent(lifecycleEpoch) {
            return
        }
        let result = await fetcher.fetchZoneChanges(sinceToken: token)
        // `LiveLifecycleGate` is re-entrant around the CloudKit await. Sample
        // entry invalidates the epoch while that request is suspended, so a
        // late result must not reconcile providers or persist cache state.
        if let lifecycleEpoch, let liveLifecycleGate, !liveLifecycleGate.isCurrent(lifecycleEpoch) {
            return
        }
        switch result {
        case let .success(changed, deletedProviderNames, newToken):
            reconcile(changed: changed, deletedProviderNames: deletedProviderNames)
            try? cache.saveChangeToken(newToken)
            let syncedAt = Date()
            lastSyncedAt = syncedAt
            try? cache.saveCachedStatuses(allProviders, syncedAt: syncedAt)
        case .changeTokenExpired:
            // PM-3: drop the stale token and do one full refetch from
            // scratch (nil token). Bounded to one retry -- a fetcher that
            // reports `.changeTokenExpired` again for a nil token is broken,
            // not something worth looping on.
            try? cache.saveChangeToken(nil)
            guard allowRetryOnExpiredToken else { return }
            await performIncrementalSync(
                using: fetcher, token: nil, allowRetryOnExpiredToken: false,
                lifecycleEpoch: lifecycleEpoch
            )
        case .zoneNotFound, .zoneDeleted:
            // PM-3: GradusZone is Mac-owned and recreated idempotently on
            // its next publish (T2a.2) -- iOS can't recreate it, so this
            // resets to "waiting for first publish" rather than erroring,
            // and self-heals once the Mac republishes and the next
            // subscription notification arrives.
            allProviders = []
            providers = []
            connectedSource = nil
            connectedSourcePublishedAt = nil
            lastSyncedAt = nil
            try? cache.saveChangeToken(nil)
            try? cache.clear()
        case .failure:
            // Leave state as-is; the next subscription-triggered sync retries.
            break
        }
    }

    private func reconcile(changed: [ProviderStatus], deletedProviderNames: [String]) {
        var byName = Dictionary(uniqueKeysWithValues: allProviders.map { ($0.providerName, $0) })
        for status in changed {
            if status.isWarning, !(byName[status.providerName]?.isWarning ?? false), notificationsEnabled {
                warningNotificationScheduler?.scheduleWarningNotification(
                    for: status, thresholdPercent: localWarningThresholdPercent
                )
            }
            byName[status.providerName] = status
        }
        for name in deletedProviderNames {
            byName.removeValue(forKey: name)
        }
        allProviders = Array(byName.values)
        applyPresentationPreferences()
    }

    private func notifyForWarningTransitions(from previous: [ProviderStatus], to current: [ProviderStatus]) {
        guard notificationsEnabled else { return }
        var previousByName = Dictionary(uniqueKeysWithValues: previous.map { ($0.providerName, $0) })
        for status in current {
            if status.isWarning, !(previousByName[status.providerName]?.isWarning ?? false) {
                warningNotificationScheduler?.scheduleWarningNotification(
                    for: status, thresholdPercent: localWarningThresholdPercent
                )
            }
            previousByName[status.providerName] = status
        }
    }

    /// Fetches the current CloudKit state and refreshes the offline cache.
    /// No-ops (leaving the last-known/cached state on screen) when sync is
    /// off or the account isn't ready -- CV-6's "distinct state, not silent
    /// failure" applies to the empty-state copy, not to spamming a fetch
    /// that would just fail.
    public func sync() async -> Bool {
        guard syncEnabled, accountStatus == .available, let fetcher else { return false }
        if let liveLifecycleGate {
            return await liveLifecycleGate.withOperation { _ in await self.performSync(using: fetcher) } ?? false
        } else {
            return await performSync(using: fetcher)
        }
    }

    private func performSync(using fetcher: CloudFetcher) async -> Bool {
        isSyncing = true
        defer { isSyncing = false }
        guard let fetched = try? await fetcher.fetchAll() else { return false }
        // Compare the complete cached set, not the filtered presentation set,
        // so hiding exhausted providers cannot turn an unchanged warning into
        // a fresh notification on the next full sync.
        notifyForWarningTransitions(from: allProviders, to: fetched)
        allProviders = fetched
        applyPresentationPreferences()
        let syncedAt = Date()
        lastSyncedAt = syncedAt
        try? cache.saveCachedStatuses(allProviders, syncedAt: syncedAt)
        return true
    }

    /// The single idempotent live-data reconciliation path. Account changes,
    /// bootstrap, and foreground recovery all call this method so fixed
    /// subscription IDs and the cached data converge together.
    public func reconcileLiveLifecycle() async {
        guard requiredICloudMode.allowsLiveWork, syncEnabled, accountStatus == .available else { return }
        guard !isReconcilingLiveLifecycle else { return }
        isReconcilingLiveLifecycle = true
        defer { isReconcilingLiveLifecycle = false }

        var failed = await !sync()
        if let subscriptionManager {
            do { try await subscriptionManager.subscribeToZoneChanges() }
            catch { failed = true }
            if notificationsEnabled {
                do { try await subscriptionManager.subscribeToWarnings() }
                catch { failed = true }
            }
        }
        liveLifecycleNeedsRetry = failed
    }

    /// Not `private`: also called directly from the `localWarningThresholdPercent`/
    /// `providerSortOption`/`showExhausted` `didSet`s in `DashboardViewModel.swift`.
    func applyPresentationPreferences() {
        providers = Self.presentedProviders(
            allProviders,
            localThreshold: localWarningThresholdPercent,
            sortOption: providerSortOption,
            showExhausted: showExhausted
        )
        updateConnectedSource()
    }

    /// Select the newest source metadata across the complete cached provider
    /// set, not only the filtered presentation set. This keeps the connection
    /// card stable when exhausted providers are hidden locally.
    ///
    /// Not `private`: also called directly from `init` in
    /// `DashboardViewModel.swift`.
    func updateConnectedSource() {
        let latest = allProviders
            .filter { $0.syncSource != nil }
            .max {
                if $0.publishedAt != $1.publishedAt {
                    return $0.publishedAt < $1.publishedAt
                }
                return $0.providerName < $1.providerName
            }
        connectedSource = latest?.syncSource
        connectedSourcePublishedAt = latest?.publishedAt
    }

    /// Not `private`: also called directly from `init` in
    /// `DashboardViewModel.swift`.
    static func presentedProviders(
        _ providers: [ProviderStatus],
        localThreshold: Double,
        sortOption: ProviderSortOption,
        showExhausted: Bool
    ) -> [ProviderStatus] {
        rankProviders(providers, localThreshold: localThreshold, sortOption: sortOption)
            .filter { showExhausted || !$0.isDepleted }
    }
}
