import Foundation
import GradusKit
@testable import GradusMac
import Testing

/// The bridge's typed outcome in the status file is what lets Settings say
/// "grant Full Disk Access" instead of "sign in" when Vibe's cache was never
/// written. These pin that precedence and the copy each outcome earns.
///
/// Regression: 2026-09-06, the installed bridge was denied on every cycle,
/// Vibe reported "session expired", the resolver's auth matcher masked the
/// degraded agent, and Settings offered a sign-in button that did nothing.
@Suite("Background agent bridge outcome")
struct BackgroundAgentBridgeOutcomeTests {
    private static let vibeNoSession =
        "Vibe session unavailable: no Safari session for console.mistral.ai reached the credential bridge"

    @Test func aDeniedBridgeOutranksTheProviderTextItCaused() {
        let state = resolve(
            agentStatus: status(.succeeded, health: .degraded, bridge: .denied),
            providers: [provider("Vibe", error: Self.vibeNoSession)]
        )

        #expect(state == .fullDiskAccessDenied)
        #expect(state.recoveryActions == [.revealCredentialBridge, .openFullDiskAccessSettings])
    }

    @Test func aDeniedBridgeIsNamedEvenWhenNoProviderComplains() {
        // Vibe carried a prior reading, so its row is quiet; the agent is not.
        let state = resolve(agentStatus: status(.succeeded, health: .degraded, bridge: .denied))

        #expect(state == .fullDiskAccessDenied)
    }

    @Test func aSuccessfulBridgeWithNoVibeSessionIsASignInAndNotAGrant() {
        let state = resolve(
            agentStatus: status(.succeeded, health: .normal, bridge: .success),
            providers: [provider("Vibe", error: Self.vibeNoSession)]
        )

        #expect(state == .providerAuthRequired(["Vibe"]))
        #expect(state.recoveryActions.isEmpty)
        #expect(state.explanation.contains("Safari"))
    }

    @Test func nonDeniedBridgeFailuresDoNotOfferTheFullDiskAccessFix() {
        for bridge in [BackgroundAgentStatusFile.Bridge.missing, .malformed, .failed, .timedOut] {
            let state = resolve(agentStatus: status(.succeeded, health: .degraded, bridge: bridge))

            #expect(state == .degraded(bridge), "\(bridge)")
            #expect(state.recoveryActions.isEmpty, "\(bridge)")
            #expect(!state.explanation.lowercased().contains("full disk access"), "\(bridge)")
            #expect(state.explanation.contains("Vibe"), "\(bridge)")
        }
        #expect(resolve(agentStatus: status(.succeeded, health: .degraded, bridge: .missing))
            .explanation.contains("console.mistral.ai"))
    }

    @Test func anInFlightRefreshStillOutranksADeniedBridge() {
        // The bridge result belongs to this cycle's earlier step; while the
        // producer is running the user is owed progress, not a verdict.
        let state = resolve(agentStatus: status(.producerWaiting, health: .degraded, bridge: .denied))

        guard case .refreshing = state else {
            Issue.record("in-flight status was not reported as progress: \(state)")
            return
        }
    }

    @Test func theStatusFileWithABridgeOutcomeMatchesWhatTheAgentWrites() throws {
        // Byte-compatible with `GradusRefreshAgent`'s `AgentStatus` after the
        // bridge has run. `bridge` values are the agent's `AgentBridgeOutcome`
        // raw values; the two binaries share no type.
        let json = """
        {"bridge":"denied","health":"degraded","phase":"succeeded","schemaVersion":1,"sequence":6,\
        "updatedAt":"2026-09-06T12:00:00Z"}
        """
        let decoded = try JSONDecoder().decode(BackgroundAgentStatusFile.self, from: Data(json.utf8))

        #expect(decoded.bridge == .denied)
        #expect(decoded.health == .degraded)
        for raw in ["success", "denied", "missing", "malformed", "failed", "timedOut"] {
            #expect(BackgroundAgentStatusFile.Bridge(rawValue: raw) != nil, Comment(rawValue: raw))
        }
    }

    @Test func theMenuOffersAFixOnlyWhenSettingsHasAButton() {
        #expect(MenuContentView.settingsLinkLabel(.fullDiskAccessDenied) == "Fix in Settings…")
        #expect(MenuContentView.settingsLinkLabel(.notRegistered) == "Fix in Settings…")
        #expect(MenuContentView.settingsLinkLabel(.providerAuthRequired(["Vibe"])) == "Details in Settings…")
        #expect(MenuContentView.settingsLinkLabel(.degraded(.missing)) == "Details in Settings…")
        #expect(MenuContentView.settingsLinkLabel(.refreshing(status(.producerWaiting))) == nil)
        #expect(MenuContentView.settingsLinkLabel(.running(lastRefresh: agentFixedNow)) == nil)
    }
}
