import Foundation
import GradusKit

enum ProviderRetryAccessibility {
    static let retryingLabel = "Antigravity refresh retrying; values may be stale"
    static let copilotRetryLabel = "Copilot probe timed out; showing cached values"
    static let reauthenticationLabel = "Antigravity authentication required; run agy to re-authenticate"
    static let claudeRateLimitedLabel = "Claude rate limited; cached values may be stale"

    /// Markers a provider's probe publishes to say "this failure is expected and
    /// the values below are the last good reading."  Matched by exact equality
    /// against the same-named constants in `gradus/snapshot.py`, and pinned by
    /// `tests/test_swift_carry_marker_parity.py` -- reworded on one side alone,
    /// the Copilot marker painted a red row whose own text read "showing cached
    /// values" for two commits before anything noticed.
    static let carryLabels: Set<String> = [retryingLabel, copilotRetryLabel]

    static func label(for provider: ProviderEntry) -> String? {
        if isClaudeRateLimited(provider) {
            return claudeRateLimitedLabel
        }
        guard !provider.ok else { return nil }
        if let error = provider.error, carryLabels.contains(error) {
            return error
        }
        guard provider.name == "Antigravity" else { return nil }
        guard let error = provider.error?.lowercased(),
              error.contains("session expired") || error.contains("re-authenticate") || error.contains("run `agy`")
        else { return nil }
        return reauthenticationLabel
    }

    /// True when the provider published one of `carryLabels`.  Named for
    /// Antigravity's auth grace, the first such marker; Copilot's timeout carry
    /// says the same thing to a reader and earns the same quiet treatment.
    static func isRetrying(_ provider: ProviderEntry) -> Bool {
        guard let label = label(for: provider) else { return false }
        return carryLabels.contains(label)
    }

    static func isClaudeRateLimited(_ provider: ProviderEntry) -> Bool {
        guard provider.name == "Claude", !provider.ok,
              let error = provider.error?.lowercased()
        else { return false }
        return error.contains("rate limited")
            || error.contains("rate-limit")
            || error.contains("http 429")
    }

    static func isStale(_ provider: ProviderEntry) -> Bool {
        isClaudeRateLimited(provider) && !provider.windows.isEmpty
    }

    /// Only an explicit retry or Claude rate-limit state may quiet a failed
    /// provider when retained windows are present. Other failures keep their
    /// remedy and urgency visible even when cached readings are present.
    static func isCarriedFailure(_ provider: ProviderEntry) -> Bool {
        !provider.windows.isEmpty && (isRetrying(provider) || isClaudeRateLimited(provider))
    }

    static func displayLabel(for provider: ProviderEntry) -> String? {
        if isClaudeRateLimited(provider) {
            return claudeRateLimitedLabel
        }
        guard !isCarriedFailure(provider) else { return nil }
        return label(for: provider) ?? provider.error ?? "Provider probe failed"
    }
}

/// The Mac ranks the snapshot model, which -- unlike `ProviderStatus` -- has
/// no stored `isWarning`/`isDepleted`. It is the *producer* of those fields,
/// not a consumer of them, so it derives both locally.
extension ProviderEntry: RankableProvider {
    var rankingName: String {
        name
    }

    var rankingWindows: [ProviderWindow] {
        windows
    }

    var rankingIsOK: Bool {
        ok || ProviderRetryAccessibility.isCarriedFailure(self)
    }

    /// Recomputed with exactly the expression `CloudKitMapping` uses as its own
    /// default for the stored field (`windows.contains { percentIsDepleted(...) }`).
    /// Keeping the two literally identical is what makes the Mac's exhausted
    /// partition and the iPhone's contain the same providers -- derive it any
    /// other way and the two apps disagree about the same snapshot.
    var rankingIsDepleted: Bool {
        windows.contains { percentIsDepleted($0.percentLeft) }
    }

    /// The Mac's half of the union documented on `rankedPartition`. It
    /// evaluates `providerNeedsAttention` directly where iOS reads the stored
    /// `isWarning` the publisher stamped with that same function — one rule,
    /// reached two ways, because only one of the two models carries the field.
    /// Unioning the local threshold on top can only add providers to the tier,
    /// never demote one the ramp already placed there.
    func rankingNeedsAttention(localThreshold: Double) -> Bool {
        if ProviderRetryAccessibility.isCarriedFailure(self) {
            return false
        }
        if ProviderRetryAccessibility.isRetrying(self) {
            return false
        }
        return ProviderTriage.needsAttention(self)
            || windows.contains { localIsUrgent($0, threshold: localThreshold) }
    }
}
