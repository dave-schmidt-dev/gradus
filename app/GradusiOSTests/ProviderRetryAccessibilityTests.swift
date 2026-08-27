import Foundation
@testable import GradusiOS
import GradusKit
import Testing

@Suite("Provider retry accessibility")
struct ProviderRetryAccessibilityTests {
    private func provider(
        name: String = "Antigravity",
        error: String,
        windows: [ProviderWindow] = [
            ProviderWindow(id: "five_hour", percentLeft: 80, resetISO: nil, windowHours: 5, paceDelta: nil)
        ]
    ) -> ProviderStatus {
        ProviderStatus(
            providerName: name,
            providerDisplayName: name,
            ok: false,
            errorMessage: error,
            windows: windows,
            data: [:],
            observedAt: "2026-08-10T15:00:00Z",
            snapshotUpdatedAt: "2026-08-10T15:00:00Z",
            publishedAt: Date(timeIntervalSince1970: 0),
            isWarning: true
        )
    }

    @Test func retryingIsDistinctAndNeutral() {
        let provider = provider(error: IOSProviderRetryAccessibility.retryingLabel)
        #expect(IOSProviderRetryAccessibility.label(for: provider) == IOSProviderRetryAccessibility.retryingLabel)
        #expect(IOSProviderRetryAccessibility.displayLabel(for: provider) == nil)
        #expect(
            SyncStatusLine.providerRetryAccessibilityLabel(for: provider)
                == IOSProviderRetryAccessibility.retryingLabel
        )
        #expect(!provider.rankingNeedsAttention(localThreshold: 30))
    }

    @Test func reauthenticationIsActionableAndDistinct() {
        let provider = provider(error: "Antigravity session expired: run `agy` to re-authenticate", windows: [])
        #expect(
            IOSProviderRetryAccessibility.label(for: provider)
                == IOSProviderRetryAccessibility.reauthenticationLabel
        )
        #expect(
            IOSProviderRetryAccessibility.displayLabel(for: provider)
                == IOSProviderRetryAccessibility.reauthenticationLabel
        )
        #expect(IOSProviderRetryAccessibility.label(for: provider) != IOSProviderRetryAccessibility.retryingLabel)
        #expect(provider.rankingNeedsAttention(localThreshold: 30))
    }

    @Test func ordinaryFailuresKeepTheirDiagnosticText() {
        let provider = provider(error: "transient fetch failure", windows: [])
        #expect(IOSProviderRetryAccessibility.displayLabel(for: provider) == "transient fetch failure")
        #expect(!IOSProviderRetryAccessibility.isRetrying(provider))
    }

    @Test(arguments: [
        "HTTP 403 Forbidden",
        "request failed with status code: 500",
        "upstream response-code 502",
        "503 response status code",
        "403",
        "upstream rejected (401)"
    ])
    func rawHTTPStatusCodesAreNotShownInUserFacingCopy(_ error: String) {
        let provider = provider(error: error, windows: [])
        #expect(
            IOSProviderRetryAccessibility.displayLabel(for: provider)
                == IOSProviderRetryAccessibility.failedRequestLabel
        )
        #expect(provider.errorMessage == error)
    }

    @Test(arguments: [
        "offline for 500 minutes",
        "service on port 500 failed"
    ])
    func unrelatedNumbersRemainSafeDiagnosticCopy(_ error: String) {
        let provider = provider(error: error, windows: [])
        #expect(IOSProviderRetryAccessibility.displayLabel(for: provider) == error)
        #expect(provider.errorMessage == error)
    }

    @Test func onlyProvenAntigravityRetrySuppressesRetainedFailure() {
        let retrying = provider(error: IOSProviderRetryAccessibility.retryingLabel)
        #expect(IOSProviderRetryAccessibility.isCarriedFailure(retrying))
        #expect(IOSProviderRetryAccessibility.displayLabel(for: retrying) == nil)
        #expect(retrying.rankingIsOK)

        for name in ["Antigravity", "Copilot"] {
            let timeout = provider(name: name, error: "provider probe timed out")
            #expect(!IOSProviderRetryAccessibility.isCarriedFailure(timeout))
            #expect(IOSProviderRetryAccessibility.displayLabel(for: timeout) == "provider probe timed out")
            #expect(!timeout.rankingIsOK)
            #expect(timeout.rankingNeedsAttention(localThreshold: 30))
        }
    }

    @Test func retainedAuthenticationAndStaleFailuresKeepRemediesVisible() {
        let auth = provider(error: "Antigravity session expired: run `agy` to re-authenticate")
        #expect(!IOSProviderRetryAccessibility.isCarriedFailure(auth))
        #expect(
            IOSProviderRetryAccessibility.displayLabel(for: auth)
                == IOSProviderRetryAccessibility.reauthenticationLabel
        )
        #expect(!auth.rankingIsOK)

        let stale = provider(name: "Copilot", error: "stale — offline for 5m")
        #expect(!IOSProviderRetryAccessibility.isCarriedFailure(stale))
        #expect(IOSProviderRetryAccessibility.displayLabel(for: stale) == "stale — offline for 5m")
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
        #expect(IOSProviderRetryAccessibility.isClaudeRateLimited(rateLimited))
        #expect(IOSProviderRetryAccessibility.isStale(rateLimited))
        #expect(IOSProviderRetryAccessibility.isCarriedFailure(rateLimited))
        #expect(
            IOSProviderRetryAccessibility.displayLabel(for: rateLimited)
                == IOSProviderRetryAccessibility.claudeRateLimitedLabel
        )
        #expect(rateLimited.rankingIsOK)
        #expect(!rateLimited.rankingNeedsAttention(localThreshold: 30))

        let noCachedWindows = provider(name: "Claude", error: "rate limited", windows: [])
        #expect(!IOSProviderRetryAccessibility.isStale(noCachedWindows))
        #expect(!IOSProviderRetryAccessibility.isCarriedFailure(noCachedWindows))
        #expect(!noCachedWindows.rankingIsOK)
        #expect(noCachedWindows.rankingNeedsAttention(localThreshold: 30))
    }

    /// Regression for the 2026-08-27 divergence: Python renamed Copilot's
    /// timeout message so its own retention window could find it, and this
    /// surface -- still matching only Antigravity's marker -- ranked the row
    /// as needing attention while printing "showing cached values" in red.
    @Test func copilotTimeoutCarryIsQuietLikeTheAntigravityGrace() {
        let carried = provider(name: "Copilot", error: IOSProviderRetryAccessibility.copilotRetryLabel)
        #expect(IOSProviderRetryAccessibility.isRetrying(carried))
        #expect(IOSProviderRetryAccessibility.isCarriedFailure(carried))
        #expect(IOSProviderRetryAccessibility.displayLabel(for: carried) == nil)
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
            #expect(!IOSProviderRetryAccessibility.isRetrying(nearMiss))
            #expect(!IOSProviderRetryAccessibility.isCarriedFailure(nearMiss))
            #expect(IOSProviderRetryAccessibility.displayLabel(for: nearMiss) == wording)
            #expect(!nearMiss.rankingIsOK)
        }
    }

    /// Carrying a marker with nothing retained is not a reason to claim health:
    /// `rankingIsOK` requires actual windows, so an empty carry stays out of
    /// the healthy tier even though its text is styled as calm.
    @Test func aCopilotCarryWithNothingRetainedIsNotRankedHealthy() {
        let empty = provider(name: "Copilot", error: IOSProviderRetryAccessibility.copilotRetryLabel, windows: [])
        #expect(IOSProviderRetryAccessibility.isRetrying(empty))
        #expect(!IOSProviderRetryAccessibility.isCarriedFailure(empty))
        #expect(!empty.rankingIsOK)
    }
}
