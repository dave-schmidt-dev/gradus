import Foundation

/// Read-only presentation values derived from the dashboard's ranked state.
public extension DashboardViewModel {
    /// `nil` means "render the populated dashboard" -- there is data (fresh
    /// or offline-stale) to show.
    var emptyState: DashboardEmptyState? {
        guard providers.isEmpty else { return nil }
        if requiredICloudMode == .awaitingConfirmation {
            return .awaitingConfirmation
        }
        switch iCloudAvailability {
        case .checkingICloud: return .checkingICloud
        case .tryAgain: return .tryAgain
        case .noAccount: return .notSignedIn
        case .restricted: return .restricted
        case .available: break
        }
        if !syncEnabled {
            return .syncDisabled
        }
        return .waitingForFirstPublish
    }

    /// The most urgent provider per `rankProviders`' total order (P3/T3.2).
    /// Always the first element: `providers` is ranked at every one of its
    /// three assignment sites (`init`, `sync()`, `reconcile()`) -- the
    /// `.zoneNotFound`/`.zoneDeleted` reset path assigns `[]` directly, which
    /// is trivially "ranked" (empty), so this invariant holds unconditionally.
    var heroProvider: ProviderStatus? {
        providers.first
    }

    /// All providers other than the hero, still in ranked order.
    var restProviders: [ProviderStatus] {
        Array(providers.dropFirst())
    }
}
