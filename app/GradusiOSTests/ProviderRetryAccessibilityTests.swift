import Foundation
import GradusKit
import Testing

@testable import GradusiOS

@Suite("Provider retry accessibility")
struct ProviderRetryAccessibilityTests {
    private func provider(error: String) -> ProviderStatus {
        ProviderStatus(
            providerName: "Antigravity",
            providerDisplayName: "Antigravity",
            ok: false,
            errorMessage: error,
            windows: [ProviderWindow(id: "five_hour", percentLeft: 80, resetISO: nil, windowHours: 5, paceDelta: nil)],
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
        #expect(IOSProviderRetryAccessibility.displayLabel(for: provider) == IOSProviderRetryAccessibility.retryingLabel)
        #expect(SyncStatusLine.providerRetryAccessibilityLabel(for: provider) == IOSProviderRetryAccessibility.retryingLabel)
        #expect(!provider.rankingNeedsAttention(localThreshold: 30))
    }

    @Test func reauthenticationIsActionableAndDistinct() {
        let provider = provider(error: "Antigravity session expired: run `agy` to re-authenticate")
        #expect(IOSProviderRetryAccessibility.label(for: provider) == IOSProviderRetryAccessibility.reauthenticationLabel)
        #expect(IOSProviderRetryAccessibility.displayLabel(for: provider) == IOSProviderRetryAccessibility.reauthenticationLabel)
        #expect(IOSProviderRetryAccessibility.label(for: provider) != IOSProviderRetryAccessibility.retryingLabel)
        #expect(provider.rankingNeedsAttention(localThreshold: 30))
    }

    @Test func ordinaryFailuresKeepTheirDiagnosticText() {
        let provider = provider(error: "transient fetch failure")
        #expect(IOSProviderRetryAccessibility.displayLabel(for: provider) == "transient fetch failure")
        #expect(!IOSProviderRetryAccessibility.isRetrying(provider))
    }
}
