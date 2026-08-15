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
}
