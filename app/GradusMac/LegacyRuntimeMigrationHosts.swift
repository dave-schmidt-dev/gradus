import Foundation

/// The real collaborators for `LegacyRuntimeMigrator`. Each one is thin on
/// purpose: everything worth testing lives in the migrator, and these types
/// exist so the migrator never has to know that `launchctl` is a subprocess.
enum LegacyRuntimePaths {
    static let legacyLabel = "local.gradus-snapshot"

    static func legacyPlist(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist")
    }

    static func legacyWrapper(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".launchd/scripts/gradus_snapshot.sh")
    }

    static func standaloneBridge() -> URL {
        URL(fileURLWithPath: "/Applications/GradusCredentialBridge.app")
    }

    static func receiptsDirectory(installedRoot: URL) -> URL {
        installedRoot.appendingPathComponent("consumer-receipts", isDirectory: true)
    }

    static func migrationState(installedRoot: URL) -> URL {
        installedRoot.appendingPathComponent("migration-state.json")
    }

    /// Not under the installed root and not in the checkout: the preflight has
    /// to be able to fail without a consumer ever seeing its output.
    static func preflightStateRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("gradus-migration-preflight", isDirectory: true)
    }
}

/// `launchctl`-backed legacy job control.
final class LaunchctlLegacyJob: LegacyJobControlling {
    private let plistURL: URL
    private let wrapperURL: URL
    private let domain: String
    private let run: (String, [String]) -> (status: Int32, output: String)

    init(
        plistURL: URL,
        wrapperURL: URL,
        uid: uid_t = getuid(),
        run: @escaping (String, [String]) -> (status: Int32, output: String) = LaunchctlLegacyJob.runProcess
    ) {
        self.plistURL = plistURL
        self.wrapperURL = wrapperURL
        domain = "gui/\(uid)"
        self.run = run
    }

    private var jobTarget: String {
        "\(domain)/\(LegacyRuntimePaths.legacyLabel)"
    }

    func currentState() -> LegacyJobState {
        let installed = FileManager.default.fileExists(atPath: plistURL.path)
        let printed = run("/bin/launchctl", ["print", jobTarget])
        guard printed.status == 0 else {
            return installed ? .installedNotLoaded : .absent
        }
        let disabled = run("/bin/launchctl", ["print-disabled", domain])
        let isDisabled = disabled.output.contains("\"\(LegacyRuntimePaths.legacyLabel)\" => true")
        return .loaded(enabled: !isDisabled)
    }

    /// Matches on the wrapper's own path rather than a provider name, so a
    /// user's unrelated `python` never reads as a legacy producer.
    func runningLegacyProcessPaths() -> [String] {
        let found = run("/usr/bin/pgrep", ["-f", wrapperURL.path])
        guard found.status == 0 else { return [] }
        return found.output
            .split(separator: "\n")
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    func bootOut() throws {
        let result = run("/bin/launchctl", ["bootout", jobTarget])
        // `bootout` on an already-unloaded job is a no-op failure, not an error
        // worth rolling a migration back over.
        guard result.status == 0 || currentState() != .loaded(enabled: true) else {
            throw LegacyJobError.bootOutFailed
        }
    }

    func restore(_ prior: LegacyJobState) throws {
        switch prior {
        case .absent, .installedNotLoaded:
            return
        case let .loaded(enabled):
            guard run("/bin/launchctl", ["bootstrap", domain, plistURL.path]).status == 0 else {
                throw LegacyJobError.restoreFailed
            }
            let verb = enabled ? "enable" : "disable"
            _ = run("/bin/launchctl", [verb, jobTarget])
        }
    }

    enum LegacyJobError: Error {
        case bootOutFailed
        case restoreFailed
    }

    static func runProcess(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

/// Runs the bundled frozen runtime against an isolated `HOME`, with the same
/// scrubbed environment the refresh agent uses.
final class BundledProducerPreflight: IsolatedProducerRunning {
    private let runtimeExecutable: URL
    private let timeout: TimeInterval

    init(runtimeExecutable: URL, timeout: TimeInterval = 180) {
        self.runtimeExecutable = runtimeExecutable
        self.timeout = timeout
    }

    func runPreflight(stateRoot: URL, onStatus: (String) -> Void) -> Bool {
        guard FileManager.default.fileExists(atPath: runtimeExecutable.path) else { return false }
        try? FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = runtimeExecutable
        process.arguments = ["--refresh-snapshot"]
        process.environment = [
            "GRADUS_RUNTIME_MODE": "installed",
            "HOME": stateRoot.path,
            "LANG": "en_US.UTF-8",
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": NSTemporaryDirectory()
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            onStatus("Trying the bundled collector in an isolated copy…")
            Thread.sleep(forTimeInterval: 1)
        }
        if process.isRunning {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }
}

/// Reads the two installed-mode facts the cutover checks. Both are ordinary
/// credential-free public state (INV-1).
final class InstalledEvidenceFiles: InstalledEvidenceReading {
    private let snapshotURL: URL
    private let publishEvidenceURL: URL

    init(snapshotURL: URL, publishEvidenceURL: URL) {
        self.snapshotURL = snapshotURL
        self.publishEvidenceURL = publishEvidenceURL
    }

    func snapshotUpdatedAt() -> Date? {
        timestamp(in: snapshotURL, key: "updatedAt")
    }

    func lastSuccessfulPublishAt() -> Date? {
        guard let object = json(at: publishEvidenceURL),
              object["ok"] as? Bool == true
        else { return nil }
        return timestamp(in: publishEvidenceURL, key: "publishedAt")
    }

    private func timestamp(in url: URL, key: String) -> Date? {
        guard let raw = json(at: url)?[key] as? String else { return nil }
        return ISO8601DateFormatter().date(from: raw)
    }

    private func json(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// Writes typed migration state beside the installed snapshot.
final class FileMigrationStateWriter: MigrationStatePersisting {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func write(_ state: LegacyMigrationState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }
}

/// Builds the migrator against the running bundle. `@MainActor` because the
/// installed snapshot path and its publish-evidence sibling both come from
/// `PublishPipeline`, which owns the one place that path is constructed.
@MainActor
enum LegacyRuntimeMigratorFactory {
    static func make(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        bundleURL: URL = Bundle.main.bundleURL
    ) -> LegacyRuntimeMigrator {
        let snapshotURL = PublishPipeline.defaultSnapshotPath
        let installedRoot = snapshotURL.deletingLastPathComponent()
        return LegacyRuntimeMigrator(
            job: LaunchctlLegacyJob(
                plistURL: LegacyRuntimePaths.legacyPlist(homeDirectory: homeDirectory),
                wrapperURL: LegacyRuntimePaths.legacyWrapper(homeDirectory: homeDirectory)
            ),
            producer: BundledProducerPreflight(
                runtimeExecutable: bundleURL
                    .appendingPathComponent("Contents/Helpers/GradusRuntime.app/Contents/MacOS/GradusRuntime")
            ),
            evidence: InstalledEvidenceFiles(
                snapshotURL: snapshotURL,
                publishEvidenceURL: PublishPipeline.publishEvidencePath(for: snapshotURL)
            ),
            agent: SMAppServiceBackgroundAgent(),
            statePersister: FileMigrationStateWriter(
                fileURL: LegacyRuntimePaths.migrationState(installedRoot: installedRoot)
            ),
            receiptsDirectory: LegacyRuntimePaths.receiptsDirectory(installedRoot: installedRoot),
            canonicalSnapshotPath: snapshotURL.path,
            preflightStateRoot: LegacyRuntimePaths.preflightStateRoot()
        )
    }
}
