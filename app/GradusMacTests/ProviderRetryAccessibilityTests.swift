import GradusKit
@testable import GradusMac
import Testing

@Suite("Provider retry accessibility")
struct ProviderRetryAccessibilityTests {
    private func provider(
        name: String = "Antigravity",
        error: String,
        ok: Bool = false,
        windows: [ProviderWindow] = [
            ProviderWindow(id: "five_hour", percentLeft: 80, resetISO: nil, windowHours: 5, paceDelta: nil)
        ]
    ) -> ProviderEntry {
        ProviderEntry(
            name: name,
            ok: ok,
            error: ok ? nil : error,
            windows: windows,
            data: [:],
            observedAt: "2026-08-10T15:00:00Z"
        )
    }

    @Test func retryingIsDistinctAndNeutral() {
        let provider = provider(error: ProviderRetryAccessibility.retryingLabel)
        #expect(ProviderRetryAccessibility.label(for: provider) == ProviderRetryAccessibility.retryingLabel)
        #expect(ProviderRetryAccessibility.displayLabel(for: provider) == nil)
        #expect(!provider.rankingNeedsAttention(localThreshold: 30))
    }

    @Test func reauthenticationIsActionableAndDistinct() {
        let provider = provider(error: "Antigravity session expired: run `agy` to re-authenticate", windows: [])
        #expect(ProviderRetryAccessibility.label(for: provider) == ProviderRetryAccessibility.reauthenticationLabel)
        #expect(
            ProviderRetryAccessibility.displayLabel(for: provider)
                == ProviderRetryAccessibility.reauthenticationLabel
        )
        #expect(ProviderRetryAccessibility.label(for: provider) != ProviderRetryAccessibility.retryingLabel)
        #expect(provider.rankingNeedsAttention(localThreshold: 30))
    }

    @Test func onlyProvenAntigravityRetrySuppressesRetainedFailure() {
        let retrying = provider(error: ProviderRetryAccessibility.retryingLabel)
        #expect(ProviderRetryAccessibility.isCarriedFailure(retrying))
        #expect(ProviderRetryAccessibility.displayLabel(for: retrying) == nil)
        #expect(retrying.rankingIsOK)

        for name in ["Antigravity", "Copilot"] {
            let timeout = provider(name: name, error: "provider probe timed out")
            #expect(!ProviderRetryAccessibility.isCarriedFailure(timeout))
            #expect(ProviderRetryAccessibility.displayLabel(for: timeout) == "provider probe timed out")
            #expect(!timeout.rankingIsOK)
            #expect(timeout.rankingNeedsAttention(localThreshold: 30))
        }
    }

    @Test func retainedAuthenticationAndStaleFailuresKeepRemediesVisible() {
        let auth = provider(error: "Antigravity session expired: run `agy` to re-authenticate")
        #expect(!ProviderRetryAccessibility.isCarriedFailure(auth))
        #expect(ProviderRetryAccessibility.displayLabel(for: auth) == ProviderRetryAccessibility.reauthenticationLabel)
        #expect(!auth.rankingIsOK)

        let stale = provider(name: "Copilot", error: "stale — offline for 5m")
        #expect(!ProviderRetryAccessibility.isCarriedFailure(stale))
        #expect(ProviderRetryAccessibility.displayLabel(for: stale) == "stale — offline for 5m")
        #expect(!stale.rankingIsOK)
        #expect(stale.rankingNeedsAttention(localThreshold: 30))
    }

    @Test func claudeRateLimitCarriesOnlyRetainedWindowsAndUsesFixedStaleLabel() {
        let rateLimited = provider(
            name: "Claude",
            error: "HTTP 429 Too Many Requests",
            windows: [ProviderWindow(
                id: "weekly", percentLeft: 42, resetISO: nil, windowHours: 168, paceDelta: nil
            )]
        )
        #expect(ProviderRetryAccessibility.isClaudeRateLimited(rateLimited))
        #expect(ProviderRetryAccessibility.isStale(rateLimited))
        #expect(ProviderRetryAccessibility.isCarriedFailure(rateLimited))
        #expect(
            ProviderRetryAccessibility.displayLabel(for: rateLimited)
                == ProviderRetryAccessibility.claudeRateLimitedLabel
        )
        #expect(rateLimited.rankingIsOK)
        #expect(!rateLimited.rankingNeedsAttention(localThreshold: 30))

        let noCachedWindows = provider(name: "Claude", error: "rate limited", windows: [])
        #expect(!ProviderRetryAccessibility.isStale(noCachedWindows))
        #expect(!ProviderRetryAccessibility.isCarriedFailure(noCachedWindows))
        #expect(!noCachedWindows.rankingIsOK)
        #expect(noCachedWindows.rankingNeedsAttention(localThreshold: 30))
    }

    /// Regression for the 2026-08-27 divergence: Python renamed Copilot's
    /// timeout message so its own retention window could find it, and this
    /// surface -- still matching only Antigravity's marker -- ranked the row
    /// as needing attention while printing "showing cached values" in red.
    @Test func copilotTimeoutCarryIsQuietLikeTheAntigravityGrace() {
        let carried = provider(name: "Copilot", error: ProviderRetryAccessibility.copilotRetryLabel)
        #expect(ProviderRetryAccessibility.isRetrying(carried))
        #expect(ProviderRetryAccessibility.isCarriedFailure(carried))
        #expect(ProviderRetryAccessibility.displayLabel(for: carried) == nil)
        #expect(carried.rankingIsOK)
        #expect(!carried.rankingNeedsAttention(localThreshold: 30))
    }

    /// The carry is a *published marker*, not a topic. A bare timeout string --
    /// what every other provider still emits -- keeps its red row, and a
    /// near-miss reword must not be quietly forgiven by a substring match.
    @Test func onlyTheExactPublishedCopilotMarkerEarnsTheCarry() {
        for wording in [
            "Copilot probe timed out",
            "copilot probe timed out; showing cached values",
            "Copilot probe timed out; showing cached values (stale)"
        ] {
            let nearMiss = provider(name: "Copilot", error: wording)
            #expect(!ProviderRetryAccessibility.isRetrying(nearMiss))
            #expect(!ProviderRetryAccessibility.isCarriedFailure(nearMiss))
            #expect(ProviderRetryAccessibility.displayLabel(for: nearMiss) == wording)
            #expect(!nearMiss.rankingIsOK)
        }
    }

    /// Carrying a marker with nothing retained is not a reason to claim health:
    /// `rankingIsOK` requires actual windows, so an empty carry stays out of
    /// the healthy tier even though its text is styled as calm.
    @Test func aCopilotCarryWithNothingRetainedIsNotRankedHealthy() {
        let empty = provider(name: "Copilot", error: ProviderRetryAccessibility.copilotRetryLabel, windows: [])
        #expect(ProviderRetryAccessibility.isRetrying(empty))
        #expect(!ProviderRetryAccessibility.isCarriedFailure(empty))
        #expect(!empty.rankingIsOK)
    }
}
