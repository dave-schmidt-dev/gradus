// Test doubles for the refresh agent's collaborators: a status writer that
// records what it was asked to persist, a runner that replays scripted
// outcomes, an always-granting lock, and the fixture that wires them to a
// throwaway bundle layout. Split out of `RefreshAgentTests.swift` to keep it
// inside the 400-line limit.

import Foundation
@testable import GradusRefreshAgentCore
import XCTest

final class RecordingStatusWriter: AgentStatusWriting {
    var statuses: [AgentStatus] = []
    var phases: [AgentPhase] {
        statuses.map(\.phase)
    }

    func write(_ status: AgentStatus) throws {
        statuses.append(status)
    }
}

final class ScriptedRunner: SubprocessRunning {
    var outcomes: [ProcessOutcome]
    let waitsPerInvocation: Int
    var invocations: [ProcessInvocation] = []
    var deadlines: [TimeInterval] = []
    var waitPhases: [AgentPhase] = []
    var onInvocation: ((Int) -> Void)?
    private let status: RecordingStatusWriter

    init(outcomes: [ProcessOutcome], waitsPerInvocation: Int, status: RecordingStatusWriter) {
        self.outcomes = outcomes
        self.waitsPerInvocation = waitsPerInvocation
        self.status = status
    }

    func run(
        _ invocation: ProcessInvocation,
        deadline: TimeInterval,
        cancelled _: @escaping () -> Bool,
        beforeWait: @escaping () -> Bool
    ) -> ProcessOutcome {
        let index = invocations.count
        invocations.append(invocation)
        deadlines.append(deadline)
        onInvocation?(index)
        for _ in 0 ..< waitsPerInvocation {
            XCTAssertTrue(beforeWait())
            waitPhases.append(status.phases.last ?? .failed)
        }
        return outcomes.removeFirst()
    }
}

struct FixedLocker: AgentLocking {
    let result: AgentLockResult
    func acquire(_: URL) -> AgentLockResult {
        result
    }
}

final class Fixture {
    let root: URL
    let paths: AgentPaths
    let status = RecordingStatusWriter()
    let runner: ScriptedRunner
    let agent: RefreshAgent

    init(
        outcomes: [ProcessOutcome],
        lockResult: AgentLockResult? = nil,
        waitsPerInvocation: Int = 1,
        useFileStatusWriter: Bool = false,
        failingStatusPhase: AgentPhase? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let app = root.appending(path: "Gradus.app", directoryHint: .isDirectory)
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        paths = try AgentPaths.installed(
            executableURL: app.appending(path: "Contents/Helpers/GradusRefreshAgent"),
            homeDirectory: home
        )
        runner = ScriptedRunner(outcomes: outcomes, waitsPerInvocation: waitsPerInvocation, status: status)
        let writer: AgentStatusWriting = useFileStatusWriter
            ? FileAgentStatusWriter(fileURL: paths.statusFile)
            : FailingStatusWriter(base: status, failingPhase: failingStatusPhase)
        let descriptor = open("/dev/null", O_RDONLY)
        agent = RefreshAgent(
            paths: paths,
            runner: runner,
            statusWriter: writer,
            locker: FixedLocker(result: lockResult ?? .acquired(AgentLockLease(descriptor: descriptor))),
            bridgeDeadline: 30,
            producerDeadline: 105,
            now: { Date(timeIntervalSince1970: 1_788_000_000) }
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func writeSnapshot(schema: Int, value: String) throws -> Data {
        try writeSnapshot(at: 1, schema: schema, value: value)
    }

    @discardableResult
    func writeSnapshot(at index: Int, schema: Int, value: String) throws -> Data {
        try FileManager.default.createDirectory(at: paths.publicStateRoot, withIntermediateDirectories: true)
        let data = Data("{\"schema_version\":\(schema),\"value\":\"\(value)\"}".utf8)
        try data.write(to: paths.snapshotFiles[index])
        return data
    }
}

final class FailingStatusWriter: AgentStatusWriting {
    let base: RecordingStatusWriter
    let failingPhase: AgentPhase?

    init(base: RecordingStatusWriter, failingPhase: AgentPhase?) {
        self.base = base
        self.failingPhase = failingPhase
    }

    func write(_ status: AgentStatus) throws {
        if status.phase == failingPhase {
            throw NSError(domain: "RefreshAgentTests", code: 1)
        }
        try base.write(status)
    }
}

/// Every status the agent writes must stay inside the fixed, credential-free
/// shape. Shared by the suites so the tripwire is one definition.
func assertCredentialFree(
    _ statuses: [AgentStatus],
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let encoded = try JSONEncoder().encode(statuses)
    let text = try XCTUnwrap(String(bytes: encoded, encoding: .utf8)).lowercased()
    for forbidden in ["cookie", "token", "secret", "account", "safari", "keychain"] {
        XCTAssertFalse(
            text.contains(forbidden),
            "credential-bearing status: \(forbidden)",
            file: file,
            line: line
        )
    }
    let objects = try XCTUnwrap(
        JSONSerialization.jsonObject(with: encoded) as? [[String: Any]],
        file: file,
        line: line
    )
    let allowedKeys = Set(["schemaVersion", "phase", "health", "sequence", "updatedAt"])
    let allowedBridgeValues = Set(["success", "denied", "missing", "malformed", "failed", "timedOut"])
    for object in objects {
        XCTAssertEqual(
            Set(object.keys).subtracting(["bridge"]),
            allowedKeys,
            "unexpected status field could expose a raw bridge error",
            file: file,
            line: line
        )
        if let bridge = object["bridge"] {
            XCTAssertTrue(
                allowedBridgeValues.contains(bridge as? String ?? ""),
                "bridge outcome outside the fixed vocabulary: \(bridge)",
                file: file,
                line: line
            )
        }
    }
}
