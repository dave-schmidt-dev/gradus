import Foundation
import Testing

@testable import GradusMac

/// Locks the guard that keeps `xcodebuild test` from running the live publish
/// pipeline.
///
/// This bundle is hosted, so these assertions run *inside* the real app
/// process — `pipelineDisabled` here is literally the value `GradusMacApp.init()`
/// consulted at launch. That is the only way to check it: the guard is
/// evaluated once, before any test code exists, so nothing else can observe
/// whether it actually fired.
///
/// Without it the test host publishes to CloudKit **Production** and reads the
/// snapshot from `~/Documents`, firing a TCC prompt at whoever is at the
/// machine. An earlier version sniffed for XCTest at runtime and silently
/// never fired, because `App.init()` runs before the test bundle is injected.
@Suite("Pipeline guard")
struct PipelineGuardTests {
    @Test func theTestEnvironmentDisablesTheLivePipeline() {
        #expect(
            GradusMacApp.pipelineDisabled,
            """
            The host app started its live pipeline during a test run. \
            GRADUS_DISABLE_PIPELINE is set by the GradusMac scheme's test \
            action in project.yml -- if this fails, the scheme was regenerated \
            without it, or the run used a scheme that does not set it.
            """
        )
    }

    /// The signal has to come from the environment, not from probing XCTest,
    /// so record which one is actually present when this passes.
    @Test func theExplicitEnvironmentVariableIsWhatIsSet() {
        let environment = ProcessInfo.processInfo.environment
        #expect(
            environment["GRADUS_DISABLE_PIPELINE"] == "1",
            "expected the scheme's explicit opt-out; found: \(environment["GRADUS_DISABLE_PIPELINE"] ?? "nil")"
        )
    }
}
