// Collaborators the agent runs through: subprocess execution, status
// persistence, the single-instance lock, and public-snapshot preservation.
// Split out of `RefreshAgent.swift` to keep both files inside the 400-line
// limit; each type here is a seam the tests substitute.

import CoreFoundation
import Darwin
import Foundation

protocol SubprocessRunning {
    func run(
        _ invocation: ProcessInvocation,
        deadline: TimeInterval,
        cancelled: @escaping () -> Bool,
        beforeWait: @escaping () -> Bool
    ) -> ProcessOutcome
}

final class FoundationSubprocessRunner: SubprocessRunning {
    private let pollInterval: TimeInterval
    private let terminationGrace: TimeInterval

    init(pollInterval: TimeInterval = 0.1, terminationGrace: TimeInterval = 2) {
        self.pollInterval = pollInterval
        self.terminationGrace = terminationGrace
    }

    func run(
        _ invocation: ProcessInvocation,
        deadline: TimeInterval,
        cancelled: @escaping () -> Bool,
        beforeWait: @escaping () -> Bool
    ) -> ProcessOutcome {
        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.environment = invocation.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return .failure(exitStatus: 1)
        }

        let end = Date().addingTimeInterval(max(0, deadline))
        while process.isRunning {
            if cancelled() {
                terminate(process, exited: exited, beforeWait: beforeWait)
                return .cancelled
            }
            let remaining = end.timeIntervalSinceNow
            if remaining <= 0 {
                terminate(process, exited: exited, beforeWait: beforeWait)
                return .timedOut
            }
            guard beforeWait() else {
                terminate(process, exited: exited, beforeWait: { true })
                return .failure(exitStatus: 1)
            }
            _ = exited.wait(timeout: .now() + min(pollInterval, remaining))
        }
        return process.terminationStatus == 0 ? .success : .failure(exitStatus: process.terminationStatus)
    }

    private func terminate(
        _ process: Process,
        exited: DispatchSemaphore,
        beforeWait: () -> Bool
    ) {
        guard process.isRunning else { return }
        process.terminate()
        guard beforeWait() else {
            kill(process.processIdentifier, SIGKILL)
            return
        }
        if exited.wait(timeout: .now() + terminationGrace) == .timedOut, process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            guard beforeWait() else { return }
            _ = exited.wait(timeout: .now() + terminationGrace)
        }
    }
}

protocol AgentStatusWriting {
    func write(_ status: AgentStatus) throws
}

struct FileAgentStatusWriter: AgentStatusWriting {
    let fileURL: URL

    func write(_ status: AgentStatus) throws {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(status)
        try data.write(to: fileURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

protocol AgentLocking {
    func acquire(_ fileURL: URL) -> AgentLockResult
}

enum AgentLockResult {
    case acquired(AgentLockLease)
    case busy
    case failed
}

final class AgentLockLease {
    private var descriptor: Int32?

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        guard let descriptor else { return }
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
}

struct FileAgentLocker: AgentLocking {
    func acquire(_ fileURL: URL) -> AgentLockResult {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        do {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            return .failed
        }

        let descriptor = open(fileURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return .failed }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            _ = close(descriptor)
            return .failed
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            _ = close(descriptor)
            return .failed
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let isBusy = errno == EWOULDBLOCK || errno == EAGAIN
            _ = close(descriptor)
            return isBusy ? .busy : .failed
        }
        return .acquired(AgentLockLease(descriptor: descriptor))
    }
}

enum SnapshotPrior {
    case missing
    case complete(Data)
    case incomplete
    case invalidSidecar(Data)
}

struct PublicSnapshotPreserver {
    let fileURLs: [URL]

    private func completeSidecar(_ dictionary: [String: Any]) -> Bool {
        guard Set(dictionary.keys) == Set([
            "schema_version", "count", "generation", "snapshot_updated_at", "observed_at"
        ]),
            let schema = dictionary["schema_version"] as? NSNumber,
            schema.intValue == 1, CFGetTypeID(schema) != CFBooleanGetTypeID(),
            !["f", "d"].contains(String(cString: schema.objCType)),
            let count = dictionary["count"] as? NSNumber,
            CFGetTypeID(count) != CFBooleanGetTypeID(),
            !["f", "d"].contains(String(cString: count.objCType)),
            count.doubleValue == Double(count.intValue),
            (0 ... 1_000_000).contains(count.intValue),
            let generation = dictionary["generation"] as? String,
            UUID(uuidString: generation)?.uuidString.lowercased() == generation,
            let snapshotTime = dictionary["snapshot_updated_at"] as? String,
            let observedTime = dictionary["observed_at"] as? String
        else { return false }
        return [snapshotTime, observedTime].allSatisfy { value in
            !value.isEmpty && (value.hasSuffix("Z") ||
                value.range(of: #"[+-]\d\d:\d\d$"#, options: .regularExpression) != nil)
        }
    }

    func capture() -> [URL: SnapshotPrior] {
        Dictionary(uniqueKeysWithValues: fileURLs.map { fileURL in
            guard let data = try? Data(contentsOf: fileURL) else {
                return (fileURL, .missing)
            }
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any],
                  dictionary["schema_version"] is NSNumber,
                  fileURL.lastPathComponent != "banked-observation-v1.json" || completeSidecar(dictionary)
            else {
                return (fileURL, fileURL.lastPathComponent == "banked-observation-v1.json"
                    ? .invalidSidecar(data) : .incomplete)
            }
            return (fileURL, .complete(data))
        })
    }

    func restore(_ priors: [URL: SnapshotPrior]) throws {
        let manager = FileManager.default
        for fileURL in fileURLs {
            switch priors[fileURL] ?? .missing {
            case let .complete(data):
                try data.write(to: fileURL, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            case let .invalidSidecar(data):
                try data.write(to: fileURL, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            case .missing:
                if manager.fileExists(atPath: fileURL.path) {
                    try manager.removeItem(at: fileURL)
                }
            case .incomplete:
                break
            }
        }
    }
}

final class AgentCancellation {
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
