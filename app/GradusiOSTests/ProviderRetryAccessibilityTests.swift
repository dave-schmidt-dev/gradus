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
}
