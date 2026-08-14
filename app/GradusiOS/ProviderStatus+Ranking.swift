import Foundation
import GradusKit

enum IOSProviderRetryAccessibility {
    static let retryingLabel = "Antigravity refresh retrying; values may be stale"
    static let reauthenticationLabel = "Antigravity authentication required; run agy to re-authenticate"

    static func label(for provider: ProviderStatus) -> String? {
        guard provider.providerName == "Antigravity", !provider.ok else { return nil }
        if provider.errorMessage == retryingLabel {
            return retryingLabel
        }
        guard let error = provider.errorMessage?.lowercased(),
              error.contains("session expired") || error.contains("re-authenticate") || error.contains("run `agy`")
        else { return nil }
        return reauthenticationLabel
    }

    static func isRetrying(_ provider: ProviderStatus) -> Bool {
        label(for: provider) == retryingLabel
    }

    /// Only the explicitly-proven Antigravity retry state may quiet a failed
    /// provider with retained windows. Other failures keep their remedy and
    /// urgency visible even when cached readings are present.
    static func isCarriedFailure(_ provider: ProviderStatus) -> Bool {
        isRetrying(provider)
    }

    /// Returns the user-facing status text for an errored provider. Only the
    /// proven retry state is quiet; all other failures retain diagnostics.
    static func displayLabel(for provider: ProviderStatus) -> String? {
        guard !isCarriedFailure(provider) else { return nil }
        return label(for: provider) ?? provider.errorMessage ?? "error"
    }
}

/// iOS ranks the CloudKit model, which arrives with `isWarning`/`isDepleted`
/// already stamped on it by the Mac publisher. Both are read straight through
/// rather than recomputed: the publisher's answer is the one the push
/// notification was sent about, and recomputing here could disagree with it.
extension ProviderStatus: RankableProvider {
    var rankingName: String {
        providerName
    }

    var rankingWindows: [ProviderWindow] {
        windows
    }

    var rankingIsOK: Bool {
        ok || IOSProviderRetryAccessibility.isCarriedFailure(self)
    }

    var rankingIsDepleted: Bool {
        isDepleted
    }

    /// The union documented on `rankedPartition` (Key decision #6): the stored
    /// `isWarning` guarantees anything CloudKit already pushed about is never
    /// demoted, and the local threshold can only ever add to this tier.
    ///
    /// Since 2026-08-06 the stored field carries `providerNeedsAttention`, the
    /// same function the Mac evaluates locally — so reading it through here is
    /// no longer a *different* answer from the Mac's, just a cheaper one.
    func rankingNeedsAttention(localThreshold: Double) -> Bool {
        if IOSProviderRetryAccessibility.isCarriedFailure(self) {
            return false
        }
        if IOSProviderRetryAccessibility.isRetrying(self) {
            return false
        }
        return isWarning || windows.contains { localIsUrgent($0, threshold: localThreshold) }
    }
}
