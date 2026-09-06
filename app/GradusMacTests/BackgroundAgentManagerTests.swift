import Foundation
import GradusKit
@testable import GradusMac
import Testing

/// Records what was asked of `SMAppService` without ever touching it.
///
/// Registering a launch agent is a real, persistent mutation of the developer's
/// own machine -- and an approved one survives the test process. Every test in
/// this suite runs against this fake, and `noTestRegistersTheLiveService`
/// tripwires any future test that reaches for the real one.
private final class FakeBackgroundAgentService: BackgroundAgentServicing {
    var registration: BackgroundAgentRegistration
    var registerCount = 0
    var unregisterCount = 0
    var registerError: Error?
    /// What `registration` becomes after a successful `register()`. macOS
    /// answers `requiresApproval` for a first registration, not `enabled`.
    var registrationAfterRegister: BackgroundAgentRegistration = .enabled

    init(registration: BackgroundAgentRegistration = .notRegistered) {
        self.registration = registration
    }

    func register() throws {
        registerCount += 1
        if let registerError {
            throw registerError
        }
        registration = registrationAfterRegister
    }

    func unregister() throws {
        unregisterCount += 1
        registration = .notRegistered
    }
}

private struct AnyError: Error {}

@Suite("Background agent registration")
struct BackgroundAgentRegistrationTests {
    @MainActor
    private func manager(_ service: FakeBackgroundAgentService) -> BackgroundAgentManager {
        BackgroundAgentManager(
            service: service,
            statusFileURL: URL(fileURLWithPath: "/nonexistent/agent-status.json"),
            bridgeURL: URL(fileURLWithPath: "/nonexistent/GradusCredentialBridge.app"),
            now: { agentFixedNow },
            openURL: { _ in },
            revealInFinder: { _ in }
        )
    }

    @MainActor
    @Test func enablingMonitoringRegistersExactlyOnce() {
        let service = FakeBackgroundAgentService()

        #expect(manager(service).setMonitoringEnabled(true) == .enabled)
        #expect(service.registerCount == 1)
        #expect(service.unregisterCount == 0)
    }

    @MainActor
    @Test func firstRegistrationReportsApprovalRatherThanClaimingSuccess() {
        let service = FakeBackgroundAgentService()
        service.registrationAfterRegister = .requiresApproval

        // The toggle must not read "on" while macOS is still holding the agent.
        #expect(manager(service).setMonitoringEnabled(true) == .requiresApproval)
    }

    @MainActor
    @Test func aFailedRegistrationReportsWhatTheServiceActuallySays() {
        let service = FakeBackgroundAgentService()
        service.registerError = AnyError()

        #expect(manager(service).setMonitoringEnabled(true) == .notRegistered)
        #expect(service.registerCount == 1)
    }

    @MainActor
    @Test func disablingMonitoringUnregistersWithoutRegistering() {
        let service = FakeBackgroundAgentService(registration: .enabled)

        #expect(manager(service).setMonitoringEnabled(false) == .notRegistered)
        #expect(service.unregisterCount == 1)
        #expect(service.registerCount == 0)
    }

    @MainActor
    @Test func revealingTheBridgeHappensBeforeOpeningTheSettingsPane() {
        var events: [String] = []
        let service = FakeBackgroundAgentService(registration: .enabled)
        let manager = BackgroundAgentManager(
            service: service,
            statusFileURL: URL(fileURLWithPath: "/nonexistent/agent-status.json"),
            bridgeURL: URL(fileURLWithPath: "/fixture/GradusCredentialBridge.app"),
            now: { agentFixedNow },
            openURL: { events.append("open:\($0.absoluteString)") },
            revealInFinder: { events.append("reveal:\($0.lastPathComponent)") }
        )

        for action in BackgroundAgentState.fullDiskAccessDenied.recoveryActions {
            manager.perform(action)
        }

        #expect(events == [
            "reveal:GradusCredentialBridge.app",
            "open:\(BackgroundAgentManager.fullDiskAccessSettingsURL.absoluteString)"
        ])
    }

    @MainActor
    @Test func theExplanatoryActionNeverRunsAnything() {
        var opened: [URL] = []
        let service = FakeBackgroundAgentService(registration: .enabled)
        let manager = BackgroundAgentManager(
            service: service,
            statusFileURL: URL(fileURLWithPath: "/nonexistent/agent-status.json"),
            bridgeURL: URL(fileURLWithPath: "/nonexistent/GradusCredentialBridge.app"),
            now: { agentFixedNow },
            openURL: { opened.append($0) },
            revealInFinder: { _ in }
        )

        manager.perform(.reinstallApp)

        #expect(opened.isEmpty)
        #expect(service.registerCount == 0)
        #expect(service.unregisterCount == 0)
    }

    @MainActor
    @Test func anUnreadableStatusFileIsAbsentRatherThanHealthy() {
        let service = FakeBackgroundAgentService(registration: .enabled)

        #expect(manager(service).currentStatus() == nil)
    }
}

@Suite("Background agent state")
struct BackgroundAgentStateTests {
    @Test func unregisteredAndUnapprovedStatesOutrankEverythingElse() {
        #expect(resolve(registration: .notRegistered) == .notRegistered)
        #expect(resolve(registration: .requiresApproval) == .requiresApproval)
        #expect(resolve(registration: .notFound) == .notFound)
    }

    @Test func everyInFlightPhaseReportsVisibleProgress() {
        for phase in [
            BackgroundAgentStatusFile.Phase.acquiringLock,
            .bridgeWaiting,
            .producerWaiting,
            .restoringSnapshot
        ] {
            let state = resolve(agentStatus: status(phase))
            guard case let .refreshing(reported) = state else {
                Issue.record("\(phase) did not report progress")
                continue
            }
            #expect(reported.isInFlight)
            #expect(!reported.progressDescription.isEmpty)
            #expect(!state.claimsCurrentData)
        }
    }

    @Test func aHealthyFreshRefreshIsTheOnlyStateThatClaimsCurrentData() {
        let running = resolve()

        #expect(running == .running(lastRefresh: agentFixedNow.addingTimeInterval(-60)))
        #expect(running.claimsCurrentData)
        #expect(running.recoveryActions.isEmpty)
    }

    @Test func staleSnapshotDataNeverReportsAsCurrent() {
        for age in [BackgroundAgentStatusResolver.staleAfter + 1, 86400] {
            let state = resolve(ageSeconds: age)
            #expect(state == .stale(lastRefresh: agentFixedNow.addingTimeInterval(-age)))
            #expect(!state.claimsCurrentData)
        }
        #expect(resolve(ageSeconds: nil) == .stale(lastRefresh: nil))
    }

    @Test func aFailedOrCancelledRunIsStaleRatherThanRunning() {
        for phase in [BackgroundAgentStatusFile.Phase.failed, .cancelled] {
            #expect(!resolve(agentStatus: status(phase)).claimsCurrentData)
        }
    }

    @Test func degradedHealthFromAnOlderAgentNamesTheBridgeWithoutQuotingIt() {
        // No `bridge` field: an agent that predates the typed outcome.
        let state = resolve(agentStatus: status(.succeeded, health: .degraded))

        #expect(state == .degraded(nil))
        #expect(state.explanation.lowercased().contains("credential bridge"))
        #expect(!state.claimsCurrentData)
        #expect(state.recoveryActions.first == .revealCredentialBridge)
    }

    @Test func fullDiskAccessDenialRevealsTheBridgeFirst() {
        let state = resolve(providers: [
            provider("Vibe", error: "bridge denied: Full Disk Access is required")
        ])

        #expect(state == .fullDiskAccessDenied)
        #expect(state.recoveryActions == [.revealCredentialBridge, .openFullDiskAccessSettings])
        #expect(state.explanation.contains("Reveal the bridge first"))
    }

    @Test func providerAuthenticationIsNamedPerProviderAndSorted() {
        let state = resolve(providers: [
            provider("Cursor", error: "Cursor session expired: run `cursor-agent login`"),
            provider("Claude", error: "auth required: no cached credentials"),
            provider("Codex", ok: true, error: nil)
        ])

        #expect(state == .providerAuthRequired(["Claude", "Cursor"]))
        // Signing in happens outside Gradus; a button here could only explain.
        #expect(state.recoveryActions.isEmpty)
        #expect(state.explanation.contains("Claude and Cursor"))
        #expect(state.explanation.contains("Safari for Vibe"))
    }

    @Test func aProviderOwnedPrerequisiteIsDistinctFromAnAuthFailure() {
        let state = resolve(providers: [
            provider("OpenCode Go", error: "Keychain item unavailable")
        ])

        #expect(state == .prerequisiteMissing(["OpenCode Go"]))
        #expect(state.recoveryActions.isEmpty)
        #expect(state.explanation.contains("OpenCode Go"))
    }

    @Test func aCarriedFailureIsNotAnActionableState() {
        // The provider's own probe already said this reading is expected-stale
        // and still good, so the health UI must stay quiet about it.
        let state = resolve(providers: [
            provider("Antigravity", error: ProviderRetryAccessibility.retryingLabel)
        ])

        #expect(state.claimsCurrentData)
    }

    @Test func everyStateAnswersWithCopyAndAnActionOrDeliberatelyNeitherOne() {
        // States Settings can only explain: the fix happens outside Gradus
        // (a sign-in, a tool install, Safari itself) or on the next refresh.
        // Each is listed here on purpose; a new explanation-only state is a
        // decision, not a default.
        let explanationOnly: [BackgroundAgentState] = [
            .providerAuthRequired(["Cursor"]),
            .prerequisiteMissing(["Vibe"]),
            .degraded(.missing), .degraded(.malformed), .degraded(.failed), .degraded(.timedOut)
        ]
        let states: [BackgroundAgentState] = explanationOnly + [
            .notRegistered, .requiresApproval, .notFound,
            .refreshing(status(.bridgeWaiting)),
            .fullDiskAccessDenied,
            .degraded(nil), .degraded(.denied),
            .stale(lastRefresh: nil),
            .running(lastRefresh: agentFixedNow)
        ]

        for state in states {
            #expect(!state.headline.isEmpty)
            #expect(!state.explanation.isEmpty)
            let mayHaveNoAction = state.claimsCurrentData
                || state == .refreshing(status(.bridgeWaiting))
                || explanationOnly.contains(state)
            #expect(!state.recoveryActions.isEmpty || mayHaveNoAction, "\(state)")
            // The converse: an explanation-only state must not grow a button
            // that does nothing when pressed.
            if explanationOnly.contains(state) {
                #expect(state.recoveryActions.isEmpty, "\(state)")
            }
        }
    }

    @Test func theStatusFileShapeMatchesWhatTheAgentWrites() throws {
        // Byte-compatible with `GradusRefreshAgent`'s `AgentStatus`; the agent
        // and this decoder are separate binaries with no shared type.
        let json = """
        {"schemaVersion":1,"phase":"producerWaiting","health":"normal","sequence":4,\
        "updatedAt":"2026-08-31T12:00:00Z"}
        """
        let decoded = try JSONDecoder().decode(
            BackgroundAgentStatusFile.self, from: Data(json.utf8)
        )

        #expect(decoded.phase == .producerWaiting)
        #expect(decoded.health == .normal)
        #expect(decoded.bridge == nil)
        #expect(decoded.sequence == 4)
        #expect(decoded.isInFlight)
    }
}

@Suite("Background agent default paths")
@MainActor
struct BackgroundAgentDefaultPathTests {
    /// The agent writes its status beside the snapshot it produces
    /// (`AgentPaths.installed`). Deriving it here rather than rebuilding the
    /// directory is also what keeps INV-7's single-injection-point test green.
    @Test func statusFileSitsBesideTheInstalledCanonicalSnapshot() {
        let snapshot = PublishPipeline.defaultSnapshotPath
        #expect(
            BackgroundAgentManager.defaultStatusFileURL
                == snapshot.deletingLastPathComponent().appendingPathComponent("agent-status.json")
        )
        #expect(snapshot.path.hasSuffix("Library/Application Support/Gradus/Installed/snapshot-v2.json"))
    }

    /// The reveal affordance has to point at the bridge inside *this* bundle,
    /// because a user cannot find a nested helper on their own.
    @Test func credentialBridgeIsResolvedInsideTheRunningBundle() {
        let bridge = BackgroundAgentManager.defaultCredentialBridgeURL
        #expect(bridge.path.hasPrefix(Bundle.main.bundleURL.path))
        #expect(bridge.path.hasSuffix("Contents/Helpers/GradusCredentialBridge.app"))
    }
}
