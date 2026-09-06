import Foundation
import GradusKit
@testable import GradusMac

// Shared fixtures for the background-agent suites. Split out of
// `BackgroundAgentManagerTests.swift` when the bridge-outcome tests pushed it
// past the 400-line limit.

func provider(
    _ name: String,
    ok: Bool = false,
    error: String?,
    windows: [ProviderWindow] = []
) -> ProviderEntry {
    ProviderEntry(
        name: name,
        ok: ok,
        error: ok ? nil : error,
        windows: windows,
        data: [:],
        observedAt: "2026-08-31T12:00:00Z"
    )
}

func status(
    _ phase: BackgroundAgentStatusFile.Phase,
    health: BackgroundAgentStatusFile.Health = .normal,
    bridge: BackgroundAgentStatusFile.Bridge? = nil
) -> BackgroundAgentStatusFile {
    BackgroundAgentStatusFile(
        phase: phase, health: health, bridge: bridge, sequence: 1, updatedAt: "2026-08-31T12:00:00Z"
    )
}

let agentFixedNow = Date(timeIntervalSince1970: 1_772_000_000)

func resolve(
    registration: BackgroundAgentRegistration = .enabled,
    agentStatus: BackgroundAgentStatusFile? = status(.succeeded),
    ageSeconds: TimeInterval? = 60,
    providers: [ProviderEntry] = []
) -> BackgroundAgentState {
    BackgroundAgentStatusResolver.state(
        registration: registration,
        agentStatus: agentStatus,
        snapshotUpdatedAt: ageSeconds.map { agentFixedNow.addingTimeInterval(-$0) },
        providers: providers,
        now: agentFixedNow
    )
}
