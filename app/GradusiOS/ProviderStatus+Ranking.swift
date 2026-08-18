import Foundation
import GradusKit

enum IOSProviderRetryAccessibility {
    static let retryingLabel = "Antigravity refresh retrying; values may be stale"
    static let reauthenticationLabel = "Antigravity authentication required; run agy to re-authenticate"
    static let claudeRateLimitedLabel = "Claude rate limited; cached values may be stale"
    static let failedRequestLabel = "Unable to refresh provider data"

    private static let httpStatusPatterns = [
        #"(?i)\bHTTP(?:/\d(?:\.\d)?)?\s+[45]\d{2}\b"#,
        #"(?i)\bstatus\s+code\s*[:=]?\s*[45]\d{2}\b"#,
        #"(?i)\bresponse[- ]code\s*[:=]?\s*[45]\d{2}\b"#,
        #"(?i)\b[45]\d{2}\s+(?:HTTP\s+)?(?:status|response)(?:\s+status)?\s+code\b"#,
        #"(?i)\b(?:failed|failure|rejected|denied|forbidden|unauthorized)\b[^\n]{0,40}\b[45]\d{2}\b"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let bareHTTPStatusPattern = try? NSRegularExpression(
        pattern: #"^\(?[45]\d{2}\)?$"#
    )

    /// Raw provider diagnostics remain in `ProviderStatus.errorMessage` for
    /// logs and classification, but status codes are not suitable iOS copy.
    private static func userFacingError(_ error: String) -> String {
        let range = NSRange(error.startIndex..., in: error)
        let trimmed = error.trimmingCharacters(in: .whitespacesAndNewlines)
        let isBareHTTPStatus = bareHTTPStatusPattern?.firstMatch(
            in: trimmed,
            range: NSRange(trimmed.startIndex..., in: trimmed)
        ) != nil
        if isBareHTTPStatus
            || httpStatusPatterns.contains(where: { $0.firstMatch(in: error, range: range) != nil }) {
            return failedRequestLabel
        }
        return error
    }

    static func label(for provider: ProviderStatus) -> String? {
        if isClaudeRateLimited(provider) {
            return claudeRateLimitedLabel
        }
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

    static func isClaudeRateLimited(_ provider: ProviderStatus) -> Bool {
        guard provider.providerName == "Claude", !provider.ok,
              let error = provider.errorMessage?.lowercased()
        else { return false }
        return error.contains("rate limited")
            || error.contains("rate-limit")
            || error.contains("http 429")
    }

    static func isStale(_ provider: ProviderStatus) -> Bool {
        isClaudeRateLimited(provider) && !provider.windows.isEmpty
    }

    /// Only an explicit retry or Claude rate-limit state may quiet a failed
    /// provider when retained windows are present. Other failures keep their
    /// remedy and urgency visible even when cached readings are present.
    static func isCarriedFailure(_ provider: ProviderStatus) -> Bool {
        !provider.windows.isEmpty && (isRetrying(provider) || isClaudeRateLimited(provider))
    }

    /// Returns the user-facing status text for an errored provider. Only the
    /// A carried Claude rate limit uses the fixed stale label; the proven
    /// Antigravity retry state is quiet; all other failures retain diagnostics.
    static func displayLabel(for provider: ProviderStatus) -> String? {
        if isClaudeRateLimited(provider) {
            return claudeRateLimitedLabel
        }
        guard !isCarriedFailure(provider) else { return nil }
        if let actionableLabel = label(for: provider) {
            return actionableLabel
        }
        guard let error = provider.errorMessage else { return "error" }
        return userFacingError(error)
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
