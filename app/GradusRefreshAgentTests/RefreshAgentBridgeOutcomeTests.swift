import Foundation
@testable import GradusRefreshAgentCore
import XCTest

/// The bridge's exit status is the only thing the agent learns about it, and
/// the typed `bridge` field is the only thing the agent passes on. These pin
/// both mappings so Settings can name a Full Disk Access denial instead of
/// inferring it from a provider's failure text.
final class RefreshAgentBridgeOutcomeTests: XCTestCase {
    func testBridgeFailureClassesAllContinueToProducerAndAreNamed() throws {
        // The bridge exposes only a credential-free exit status. Denied,
        // missing, and malformed Safari state all degrade the same way, but
        // the status file names which one so the UI can say "grant Full Disk
        // Access" rather than guess from a provider's failure text.
        let expectations: [(Int32, AgentBridgeOutcome)] = [
            (65, .denied), (66, .missing), (67, .malformed), (1, .failed), (64, .failed), (2, .failed)
        ]
        for (exitStatus, expected) in expectations {
            let fixture = try Fixture(outcomes: [.failure(exitStatus: exitStatus), .success])

            XCTAssertEqual(fixture.agent.run(), .success, "\(exitStatus)")
            XCTAssertEqual(fixture.runner.invocations.count, 2, "\(exitStatus)")
            XCTAssertEqual(fixture.runner.invocations.last?.executable, fixture.paths.runtimeExecutable)
            XCTAssertEqual(fixture.status.phases.last, .succeeded, "\(exitStatus)")
            XCTAssertEqual(fixture.status.statuses.last?.health, .degraded, "\(exitStatus)")
            XCTAssertEqual(fixture.status.statuses.last?.bridge, expected, "\(exitStatus)")
            XCTAssertEqual(
                fixture.status.statuses.first(where: { $0.phase == .degraded })?.bridge, expected, "\(exitStatus)"
            )
            try assertCredentialFree(fixture.status.statuses)
        }
    }

    func testBridgeExitStatusTableIsPinned() {
        // Mirrors `CredentialBridgeExitStatus` in GradusCredentialBridgeCore
        // (0 success, 1 failed, 64 usage, 65 denied, 66 missing, 67 malformed).
        // The agent must not import the bridge to learn this; the bridge's own
        // test pins the same numbers from its side.
        XCTAssertEqual(AgentBridgeOutcome(processOutcome: .success), .success)
        XCTAssertEqual(AgentBridgeOutcome(processOutcome: .failure(exitStatus: 1)), .failed)
        XCTAssertEqual(AgentBridgeOutcome(processOutcome: .failure(exitStatus: 64)), .failed)
        XCTAssertEqual(AgentBridgeOutcome(processOutcome: .failure(exitStatus: 65)), .denied)
        XCTAssertEqual(AgentBridgeOutcome(processOutcome: .failure(exitStatus: 66)), .missing)
        XCTAssertEqual(AgentBridgeOutcome(processOutcome: .failure(exitStatus: 67)), .malformed)
        XCTAssertEqual(AgentBridgeOutcome(processOutcome: .timedOut), .timedOut)
        XCTAssertEqual(AgentBridgeOutcome(processOutcome: .cancelled), .failed)
    }
}
