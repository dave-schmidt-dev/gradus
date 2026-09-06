import Foundation
@testable import GradusRefreshAgentCore
import XCTest

final class RefreshAgentTests: XCTestCase {
    func testSuccessRunsOnlyFixedBridgeThenProducer() throws {
        let fixture = try Fixture(outcomes: [.success, .success])

        XCTAssertEqual(fixture.agent.run(), .success)
        XCTAssertEqual(
            fixture.runner.invocations.map(\.executable),
            [fixture.paths.bridgeExecutable, fixture.paths.runtimeExecutable]
        )
        XCTAssertEqual(
            fixture.runner.invocations[0].arguments,
            ["refresh", "--cache-directory", fixture.paths.privateCacheRoot.path]
        )
        XCTAssertEqual(fixture.runner.invocations[1].arguments, ["--refresh-snapshot"])
        XCTAssertEqual(fixture.runner.invocations[1].environment["GRADUS_RUNTIME_MODE"], "installed")
        XCTAssertEqual(fixture.runner.deadlines, [30, 105])
        XCTAssertEqual(fixture.status.phases.last, .succeeded)
        XCTAssertEqual(fixture.status.statuses.last?.health, .normal)
        XCTAssertEqual(fixture.status.statuses.last?.bridge, .success)
        // Nothing may claim a bridge result before the bridge has run.
        for status in fixture.status.statuses where status.phase == .acquiringLock || status.phase == .bridgeWaiting {
            XCTAssertNil(status.bridge)
        }
        try assertCredentialFree(fixture.status.statuses)
    }

    func testBridgeFailureContinuesToProducerWithDegradedSuccess() throws {
        let fixture = try Fixture(outcomes: [.failure(exitStatus: 1), .success])

        XCTAssertEqual(fixture.agent.run(), .success)
        XCTAssertEqual(fixture.runner.invocations.count, 2)
        XCTAssertEqual(fixture.runner.invocations.last?.executable, fixture.paths.runtimeExecutable)
        XCTAssertTrue(fixture.status.phases.contains(.degraded))
        XCTAssertEqual(fixture.status.statuses.first(where: { $0.phase == .degraded })?.health, .degraded)
        XCTAssertEqual(fixture.status.phases.last, .succeeded)
        XCTAssertEqual(fixture.status.statuses.last?.health, .degraded)
        try assertCredentialFree(fixture.status.statuses)
    }

    func testProducerFailureRestoresPriorSnapshot() throws {
        let fixture = try Fixture(outcomes: [.success, .failure(exitStatus: 1)])
        let prior = try fixture.writeSnapshot(schema: 2, value: "prior")
        fixture.runner.onInvocation = { invocationIndex in
            if invocationIndex == 1 {
                try? Data("{\"schema_version\":2,\"value\":\"new\"}".utf8)
                    .write(to: fixture.paths.snapshotFiles[1])
            }
        }

        XCTAssertEqual(fixture.agent.run(), .failed)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.snapshotFiles[1]), prior)
    }

    func testProducerCancellationRestoresPriorCompleteSnapshots() throws {
        let fixture = try Fixture(outcomes: [.success, .cancelled])
        let firstPrior = try fixture.writeSnapshot(at: 0, schema: 1, value: "v1-prior")
        let secondPrior = try fixture.writeSnapshot(at: 1, schema: 2, value: "v2-prior")
        fixture.runner.onInvocation = { invocationIndex in
            guard invocationIndex == 1 else { return }
            try? Data("partial".utf8).write(to: fixture.paths.snapshotFiles[0])
            try? Data("partial".utf8).write(to: fixture.paths.snapshotFiles[1])
        }

        XCTAssertEqual(fixture.agent.run(), .failed)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.snapshotFiles[0]), firstPrior)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.snapshotFiles[1]), secondPrior)
        XCTAssertEqual(fixture.status.phases.last, .cancelled)
    }

    func testBridgeCancellationRestoresPriorCompleteSnapshots() throws {
        let fixture = try Fixture(outcomes: [.cancelled])
        let firstPrior = try fixture.writeSnapshot(at: 0, schema: 1, value: "v1-prior")
        let secondPrior = try fixture.writeSnapshot(at: 1, schema: 2, value: "v2-prior")
        fixture.runner.onInvocation = { invocationIndex in
            guard invocationIndex == 0 else { return }
            try? Data("partial".utf8).write(to: fixture.paths.snapshotFiles[0])
            try? Data("partial".utf8).write(to: fixture.paths.snapshotFiles[1])
        }

        XCTAssertEqual(fixture.agent.run(), .failed)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.snapshotFiles[0]), firstPrior)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.snapshotFiles[1]), secondPrior)
        XCTAssertEqual(fixture.status.phases.last, .cancelled)
    }

    func testBridgeTimeoutContinuesToProducerWithDegradedSuccess() throws {
        let fixture = try Fixture(outcomes: [.timedOut, .success])

        XCTAssertEqual(fixture.agent.run(), .success)
        XCTAssertEqual(fixture.runner.invocations.count, 2)
        XCTAssertEqual(fixture.runner.invocations.last?.executable, fixture.paths.runtimeExecutable)
        XCTAssertEqual(fixture.status.phases.last, .succeeded)
        XCTAssertEqual(fixture.status.statuses.last?.health, .degraded)
        XCTAssertEqual(fixture.status.statuses.last?.bridge, .timedOut)
        try assertCredentialFree(fixture.status.statuses)
    }

    func testCancellationStopsBeforeProducer() throws {
        let fixture = try Fixture(outcomes: [.cancelled])

        XCTAssertEqual(fixture.agent.run(), .failed)
        XCTAssertEqual(fixture.runner.invocations.count, 1)
        XCTAssertEqual(fixture.status.phases.last, .cancelled)
    }

    func testFinalStatusWriteFailureRestoresPriorCompleteSnapshots() throws {
        let fixture = try Fixture(outcomes: [.success, .success], failingStatusPhase: .succeeded)
        let firstPrior = try fixture.writeSnapshot(at: 0, schema: 1, value: "v1-prior")
        let secondPrior = try fixture.writeSnapshot(at: 1, schema: 2, value: "v2-prior")
        fixture.runner.onInvocation = { invocationIndex in
            guard invocationIndex == 1 else { return }
            try? Data("partial".utf8).write(to: fixture.paths.snapshotFiles[0])
            try? Data("partial".utf8).write(to: fixture.paths.snapshotFiles[1])
        }

        XCTAssertEqual(fixture.agent.run(), .failed)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.snapshotFiles[0]), firstPrior)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.snapshotFiles[1]), secondPrior)
    }

    func testConcurrentInvocationReturnsWithoutLaunchingHelpers() throws {
        let fixture = try Fixture(outcomes: [], lockResult: .busy)

        XCTAssertEqual(fixture.agent.run(), .success)
        XCTAssertTrue(fixture.runner.invocations.isEmpty)
        XCTAssertEqual(fixture.status.phases, [.acquiringLock, .alreadyRunning])
    }

    func testMalformedStatusIsAtomicallyReplacedByStructuredStatus() throws {
        let fixture = try Fixture(outcomes: [.success, .success], useFileStatusWriter: true)
        try FileManager.default.createDirectory(at: fixture.paths.publicStateRoot, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: fixture.paths.statusFile)

        XCTAssertEqual(fixture.agent.run(), .success)
        let decoded = try JSONDecoder().decode(AgentStatus.self, from: Data(contentsOf: fixture.paths.statusFile))
        XCTAssertEqual(decoded.phase, .succeeded)
        XCTAssertEqual(decoded.schemaVersion, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.paths.statusFile.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testPriorCompleteSnapshotsSurviveProducerFailureByteForByte() throws {
        let fixture = try Fixture(outcomes: [.success, .failure(exitStatus: 1)])
        let firstPrior = try fixture.writeSnapshot(at: 0, schema: 1, value: "v1-prior")
        let secondPrior = try fixture.writeSnapshot(at: 1, schema: 2, value: "v2-prior")
        fixture.runner.onInvocation = { invocationIndex in
            guard invocationIndex == 1 else { return }
            for fileURL in fixture.paths.snapshotFiles {
                try? Data("partial".utf8).write(to: fileURL)
            }
        }

        XCTAssertEqual(fixture.agent.run(), .failed)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.snapshotFiles[0]), firstPrior)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.snapshotFiles[1]), secondPrior)
    }

    func testCredentialFreeProgressPrecedesEverySubprocessWait() throws {
        let fixture = try Fixture(outcomes: [.success, .success], waitsPerInvocation: 3)

        XCTAssertEqual(fixture.agent.run(), .success)
        XCTAssertEqual(fixture.runner.waitPhases, [
            .bridgeWaiting, .bridgeWaiting, .bridgeWaiting,
            .producerWaiting, .producerWaiting, .producerWaiting
        ])
        let encoded = try JSONEncoder().encode(fixture.status.statuses)
        let statusText = try XCTUnwrap(String(bytes: encoded, encoding: .utf8)).lowercased()
        for forbidden in ["cookie", "token", "secret", "account", "safari", "keychain"] {
            XCTAssertFalse(statusText.contains(forbidden))
        }
    }

    func testInstalledPathsAreFixedBundleRelativeAndNonaliasing() throws {
        let root = URL(fileURLWithPath: "/Applications/Gradus.app")
        let paths = try AgentPaths.installed(
            executableURL: root.appending(path: "Contents/Helpers/GradusRefreshAgent"),
            homeDirectory: URL(fileURLWithPath: "/Users/fixture")
        )

        let helperRoot = "/Applications/Gradus.app/Contents/Helpers"
        XCTAssertEqual(
            paths.bridgeExecutable.path,
            helperRoot + "/GradusCredentialBridge.app/Contents/MacOS/GradusCredentialBridge"
        )
        XCTAssertEqual(
            paths.runtimeExecutable.path,
            helperRoot + "/GradusRuntime.app/Contents/MacOS/GradusRuntime"
        )
        XCTAssertEqual(
            paths.lockFile.path,
            "/Users/fixture/Library/Application Support/Gradus/Installed/.refresh-agent.lock"
        )
        XCTAssertNotEqual(paths.publicStateRoot, paths.privateCacheRoot)
    }

    func testSMAppServiceRelativeArgumentZeroUsesAbsoluteBundleExecutableURL() throws {
        let relativeArgumentZero = "Contents/Helpers/GradusRefreshAgent"
        XCTAssertFalse(relativeArgumentZero.hasPrefix("/"))

        let appSourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "GradusRefreshAgent/GradusRefreshAgentApp.swift")
        let appSource = try String(contentsOf: appSourceURL, encoding: .utf8)

        XCTAssertTrue(appSource.contains("Bundle.main.executableURL"))
        XCTAssertFalse(appSource.contains("URL(fileURLWithPath: CommandLine.arguments[0])"))
    }

    func testSourceHasNoCredentialCloudOrArbitraryCommandSurface() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "GradusRefreshAgent", directoryHint: .isDirectory)
        let source = try FileManager.default.contentsOfDirectory(at: sourceRoot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        let forbiddenSurfaces = [
            "import Security", "Keychain", "Cookies.binarycookies",
            "CloudKit", "CKContainer", "ProcessInfo.processInfo.arguments"
        ]
        for forbidden in forbiddenSurfaces {
            XCTAssertFalse(source.contains(forbidden), "forbidden source surface: \(forbidden)")
        }
        XCTAssertTrue(source.contains("CommandLine.arguments.count == 1"))
        XCTAssertFalse(source.contains("dropFirst()"))
    }

    func testLaunchAgentPlistUsesOnlyBundleProgram() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "GradusMac/Resources/com.zerodelta.gradus.refresh-agent.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])

        XCTAssertEqual(plist["BundleProgram"] as? String, "Contents/Helpers/GradusRefreshAgent")
        XCTAssertNil(plist["Program"])
        XCTAssertNil(plist["ProgramArguments"])
        let text = try XCTUnwrap(String(bytes: data, encoding: .utf8)).lowercased()
        for forbidden in ["/users/", "documents", "python", "/bin/sh", ".venv"] {
            XCTAssertFalse(text.contains(forbidden))
        }
    }
}
