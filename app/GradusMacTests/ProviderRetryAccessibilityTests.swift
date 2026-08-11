import GradusKit
import Testing

@testable import GradusMac

@Suite("Provider retry accessibility")
struct ProviderRetryAccessibilityTests {
    private func provider(error: String, ok: Bool = false) -> ProviderEntry {
        ProviderEntry(
            name: "Antigravity",
            ok: ok,
            error: ok ? nil : error,
            windows: [ProviderWindow(id: "five_hour", percentLeft: 80, resetISO: nil, windowHours: 5, paceDelta: nil)],
            data: [:],
            observedAt: "2026-08-10T15:00:00Z"
        )
    }

    @Test func retryingIsDistinctAndNeutral() {
        let provider = provider(error: ProviderRetryAccessibility.retryingLabel)
        #expect(ProviderRetryAccessibility.label(for: provider) == ProviderRetryAccessibility.retryingLabel)
        #expect(!provider.rankingNeedsAttention(localThreshold: 30))
    }

    @Test func reauthenticationIsActionableAndDistinct() {
        let provider = provider(error: "Antigravity session expired: run `agy` to re-authenticate")
        #expect(ProviderRetryAccessibility.label(for: provider) == ProviderRetryAccessibility.reauthenticationLabel)
        #expect(ProviderRetryAccessibility.label(for: provider) != ProviderRetryAccessibility.retryingLabel)
        #expect(provider.rankingNeedsAttention(localThreshold: 30))
    }
}
