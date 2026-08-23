import CloudKit
import Foundation

/// The iCloud account-availability lifecycle: the bounded discovery window
/// the dashboard runs on launch/foreground, and the account-change callback
/// `AccountStatusMonitor` (PM-16) drives mid-session.
public extension DashboardViewModel {
    /// Confirms the required iCloud setup from the concrete Continue action.
    func confirmRequiredICloud() {
        syncEnabled = true
    }

    /// Starts the bounded account-discovery window used by the dashboard.
    func beginAccountAvailabilityCheck() {
        guard requiredICloudMode.allowsLiveWork else { return }
        iCloudAvailability = .checkingICloud
        liveLifecycleNeedsRetry = false
    }

    /// Records a non-sensitive lifecycle failure. The cached dashboard stays
    /// visible and the next foreground/account-available event can retry.
    func noteLiveLifecycleFailure() {
        liveLifecycleNeedsRetry = true
        if accountStatus != .available {
            iCloudAvailability = .tryAgain
        }
    }

    /// Called by the account monitor after its one bounded bootstrap retry.
    func accountAvailabilityCheckFailed() {
        guard requiredICloudMode.allowsLiveWork else { return }
        iCloudAvailability = .tryAgain
        liveLifecycleNeedsRetry = true
    }

    func refreshAccountStatus() async {
        guard let accountSource else { return }
        let refresh = {
            if let status = try? await accountSource.currentAccountStatus() {
                self.updateAccountStatus(status)
            }
        }
        if let liveLifecycleGate {
            await liveLifecycleGate.withOperation { _ in await refresh() }
        } else {
            await refresh()
        }
    }

    /// Callback target for `AccountStatusMonitor` (PM-16): applies a status
    /// change observed mid-session, including a `.CKAccountChanged` reset,
    /// and kicks a sync when the account newly becomes available.
    func updateAccountStatus(_ status: CKAccountStatus) {
        accountStatus = status
        switch status {
        case .available:
            iCloudAvailability = .available
            liveLifecycleNeedsRetry = false
            synchronizeWidgetSnapshot()
        case .noAccount:
            iCloudAvailability = .noAccount
            clearWidgetSnapshot()
        case .restricted:
            iCloudAvailability = .restricted
            clearWidgetSnapshot()
        case .couldNotDetermine, .temporarilyUnavailable:
            if !liveLifecycleNeedsRetry {
                iCloudAvailability = .checkingICloud
            }
            clearWidgetSnapshot()
        @unknown default:
            if !liveLifecycleNeedsRetry {
                iCloudAvailability = .checkingICloud
            }
            clearWidgetSnapshot()
        }
    }
}
