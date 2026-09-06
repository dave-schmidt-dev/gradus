// Collaborators the agent runs through: subprocess execution, status
// persistence, the single-instance lock, and public-snapshot preservation.
// Split out of `RefreshAgent.swift` to keep both files inside the 400-line
// limit; each type here is a seam the tests substitute.

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
}

struct PublicSnapshotPreserver {
    let fileURLs: [URL]

    func capture() -> [URL: SnapshotPrior] {
        Dictionary(uniqueKeysWithValues: fileURLs.map { fileURL in
            guard let data = try? Data(contentsOf: fileURL) else {
                return (fileURL, .missing)
            }
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any],
                  dictionary["schema_version"] is NSNumber
            else {
                return (fileURL, .incomplete)
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
