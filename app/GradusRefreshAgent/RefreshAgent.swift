import Darwin
import Foundation

public func runInstalledRefreshAgent(executableURL: URL, homeDirectory: URL) -> Int32 {
    do {
        let cancellation = AgentCancellation()
        let paths = try AgentPaths.installed(
            executableURL: executableURL,
            homeDirectory: homeDirectory
        )
        let agent = RefreshAgent(
            paths: paths,
            runner: FoundationSubprocessRunner(),
            statusWriter: FileAgentStatusWriter(fileURL: paths.statusFile),
            locker: FileAgentLocker(),
            isCancelled: cancellation.isCancelled
        )
        return agent.run().rawValue
    } catch {
        return AgentExit.failed.rawValue
    }
}

private final class AgentCancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var sources: [DispatchSourceSignal] = []

    init() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler { [weak self] in
                self?.lock.lock()
                self?.cancelled = true
                self?.lock.unlock()
            }
            source.resume()
            sources.append(source)
        }
    }

    deinit {
        for source in sources {
            source.cancel()
        }
        signal(SIGTERM, SIG_DFL)
        signal(SIGINT, SIG_DFL)
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

enum AgentExit: Int32 {
    case success = 0
    case failed = 1
    case usage = 64
}

enum AgentPhase: String, Codable {
    case acquiringLock
    case alreadyRunning
    case bridgeWaiting
    case degraded
    case producerWaiting
    case restoringSnapshot
    case succeeded
    case failed
    case cancelled
}

/// Credential-free health reported while the agent completes a refresh.
enum AgentHealth: String, Codable {
    case normal
    case degraded
}

/// What the credential bridge's exit status said, in the same fixed vocabulary
/// its `check` operation prints. Nothing else about the bridge run is kept:
/// no output, no error text, no path. `denied` is the one the UI has to be
/// able to name, because it means "grant Full Disk Access" and nothing a
/// provider's own failure text can say distinguishes it from a signed-out
/// Safari.
enum AgentBridgeOutcome: String, Codable {
    case success
    case denied
    case missing
    case malformed
    case failed
    case timedOut

    /// Exit statuses are pinned by `RefreshAgentBridgeOutcomeTests.testBridgeExitStatusTableIsPinned`
    /// against the bridge's own table; the two binaries share no type.
    init(processOutcome: ProcessOutcome) {
        switch processOutcome {
        case .success: self = .success
        case .timedOut: self = .timedOut
        case .cancelled: self = .failed
        case let .failure(exitStatus):
            switch exitStatus {
            case 65: self = .denied
            case 66: self = .missing
            case 67: self = .malformed
            default: self = .failed
            }
        }
    }
}

struct AgentStatus: Codable, Equatable {
    let schemaVersion: Int
    let phase: AgentPhase
    let health: AgentHealth
    /// Absent until the bridge has run this cycle; present on every status
    /// written after it, including the terminal one.
    let bridge: AgentBridgeOutcome?
    let sequence: Int
    let updatedAt: String

    init(
        phase: AgentPhase,
        health: AgentHealth = .normal,
        bridge: AgentBridgeOutcome? = nil,
        sequence: Int,
        date: Date
    ) {
        schemaVersion = 1
        self.phase = phase
        self.health = health
        self.bridge = bridge
        self.sequence = sequence
        updatedAt = ISO8601DateFormatter().string(from: date)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, phase, health, bridge, sequence, updatedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(phase, forKey: .phase)
        try container.encode(health, forKey: .health)
        try container.encodeIfPresent(bridge, forKey: .bridge)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

struct AgentPaths: Equatable {
    let bundleRoot: URL
    let bridgeExecutable: URL
    let runtimeExecutable: URL
    let publicStateRoot: URL
    let privateCacheRoot: URL
    let statusFile: URL
    let lockFile: URL
    let snapshotFiles: [URL]

    static func installed(executableURL: URL, homeDirectory: URL) throws -> AgentPaths {
        let executable = executableURL.standardizedFileURL.resolvingSymlinksInPath()
        let helpers = executable.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard executable.lastPathComponent == "GradusRefreshAgent",
              helpers.lastPathComponent == "Helpers",
              contents.lastPathComponent == "Contents",
              bundle.pathExtension == "app"
        else {
            throw AgentConfigurationError.invalidBundleLayout
        }

        let appSupport = homeDirectory
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: "Gradus", directoryHint: .isDirectory)
        let publicRoot = appSupport.appending(path: "Installed", directoryHint: .isDirectory)
        let privateRoot = appSupport
            .appending(path: "Private", directoryHint: .isDirectory)
            .appending(path: ".cache", directoryHint: .isDirectory)

        return AgentPaths(
            bundleRoot: bundle,
            bridgeExecutable: helpers
                .appending(path: "GradusCredentialBridge.app/Contents/MacOS/GradusCredentialBridge"),
            runtimeExecutable: helpers
                .appending(path: "GradusRuntime.app/Contents/MacOS/GradusRuntime"),
            publicStateRoot: publicRoot,
            privateCacheRoot: privateRoot,
            statusFile: publicRoot.appending(path: "agent-status.json"),
            lockFile: publicRoot.appending(path: ".refresh-agent.lock"),
            snapshotFiles: [
                publicRoot.appending(path: "snapshot.json"),
                publicRoot.appending(path: "snapshot-v2.json")
            ]
        )
    }
}

enum AgentConfigurationError: Error {
    case invalidBundleLayout
}

struct ProcessInvocation: Equatable {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
}

enum ProcessOutcome: Equatable {
    case success
    /// The child's exit status. Only the bridge's is interpreted, and only
    /// through `AgentBridgeOutcome`; the producer's is success-or-not.
    case failure(exitStatus: Int32)
    case timedOut
    case cancelled
}

struct RefreshAgent {
    let paths: AgentPaths
    let runner: SubprocessRunning
    let statusWriter: AgentStatusWriting
    let locker: AgentLocking
    let bridgeDeadline: TimeInterval
    let producerDeadline: TimeInterval
    let now: () -> Date
    let isCancelled: () -> Bool

    init(
        paths: AgentPaths,
        runner: SubprocessRunning,
        statusWriter: AgentStatusWriting,
        locker: AgentLocking,
        bridgeDeadline: TimeInterval = 30,
        producerDeadline: TimeInterval = 105,
        now: @escaping () -> Date = Date.init,
        isCancelled: @escaping () -> Bool = { false }
    ) {
        self.paths = paths
        self.runner = runner
        self.statusWriter = statusWriter
        self.locker = locker
        self.bridgeDeadline = bridgeDeadline
        self.producerDeadline = producerDeadline
        self.now = now
        self.isCancelled = isCancelled
    }

    // The refresh is a single linear sequence -- lock, bridge, producer,
    // publish -- and every step's failure path has to restore the prior
    // snapshots and emit a distinct phase. Splitting it would mean threading
    // `sequence`, `health`, and the `emit` closure through helpers, which
    // trades one readable pass for shared mutable state.
    // swiftlint:disable:next function_body_length cyclomatic_complexity
    func run() -> AgentExit {
        var sequence = 0
        var health = AgentHealth.normal
        var bridgeResult: AgentBridgeOutcome?
        func emit(_ phase: AgentPhase) -> Bool {
            sequence += 1
            do {
                try statusWriter.write(AgentStatus(
                    phase: phase, health: health, bridge: bridgeResult, sequence: sequence, date: now()
                ))
                return true
            } catch {
                return false
            }
        }

        guard emit(.acquiringLock) else { return .failed }
        let lease: AgentLockLease
        switch locker.acquire(paths.lockFile) {
        case let .acquired(acquired):
            lease = acquired
        case .busy:
            _ = emit(.alreadyRunning)
            return .success
        case .failed:
            _ = emit(.failed)
            return .failed
        }
        defer { withExtendedLifetime(lease) {} }

        let snapshots = PublicSnapshotPreserver(fileURLs: paths.snapshotFiles)
        let priors = snapshots.capture()
        let environment = fixedEnvironment(homeDirectory: paths.publicStateRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent())

        if isCancelled() {
            _ = emit(.cancelled)
            return .failed
        }

        let bridge = ProcessInvocation(
            executable: paths.bridgeExecutable,
            arguments: ["refresh", "--cache-directory", paths.privateCacheRoot.path],
            environment: environment
        )
        guard emit(.bridgeWaiting) else { return .failed }
        let bridgeOutcome = runner.run(
            bridge,
            deadline: bridgeDeadline,
            cancelled: isCancelled,
            beforeWait: { emit(.bridgeWaiting) }
        )
        if bridgeOutcome == .cancelled {
            return finishFailure(bridgeOutcome, emit: emit, snapshots: snapshots, priors: priors)
        }
        bridgeResult = AgentBridgeOutcome(processOutcome: bridgeOutcome)
        if bridgeOutcome != .success {
            health = .degraded
            // Bridge failures are optional Vibe credential degradation. Keep
            // this state typed and credential-free, then let the producer use
            // any credentials/caches that remain available.
            guard emit(.degraded) else { return .failed }
        }

        if isCancelled() {
            return finishFailure(.cancelled, emit: emit, snapshots: snapshots, priors: priors)
        }

        let producer = ProcessInvocation(
            executable: paths.runtimeExecutable,
            arguments: ["--refresh-snapshot"],
            environment: environment
        )
        guard emit(.producerWaiting) else {
            return finishFailure(.failure(exitStatus: 1), emit: emit, snapshots: snapshots, priors: priors)
        }
        let producerOutcome = runner.run(
            producer,
            deadline: producerDeadline,
            cancelled: isCancelled,
            beforeWait: { emit(.producerWaiting) }
        )
        guard producerOutcome == .success else {
            return finishFailure(producerOutcome, emit: emit, snapshots: snapshots, priors: priors)
        }

        guard emit(.succeeded) else {
            try? snapshots.restore(priors)
            return .failed
        }
        return .success
    }

    private func finishFailure(
        _ outcome: ProcessOutcome,
        emit: (AgentPhase) -> Bool,
        snapshots: PublicSnapshotPreserver,
        priors: [URL: SnapshotPrior]
    ) -> AgentExit {
        guard emit(.restoringSnapshot) else { return .failed }
        do {
            try snapshots.restore(priors)
        } catch {
            _ = emit(.failed)
            return .failed
        }
        _ = emit(outcome == .cancelled ? .cancelled : .failed)
        return .failed
    }

    private func fixedEnvironment(homeDirectory: URL) -> [String: String] {
        [
            "GRADUS_RUNTIME_MODE": "installed",
            "HOME": homeDirectory.path,
            "LANG": "en_US.UTF-8",
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": "/tmp"
        ]
    }
}
