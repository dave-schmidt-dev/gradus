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

    /// Checked in install order. The standalone bridge ships to the user's own
    /// `~/Applications` -- that is where this machine's copy is -- but a
    /// hand-placed `/Applications` copy is just as much a legacy runtime, and
    /// missing it would hide the whole Settings section.
    static func standaloneBridge(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let candidates = [
            homeDirectory.appendingPathComponent("Applications/GradusCredentialBridge.app"),
            URL(fileURLWithPath: "/Applications/GradusCredentialBridge.app")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates[0]
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
        return .loaded(enabled: !Self.isDisabled(in: disabled.output))
    }

    /// `launchctl print-disabled` prints `"label" => disabled` on this OS, not
    /// the `=> true` an earlier release used, and omits the label entirely when
    /// it has never been toggled -- which means enabled. Parsed against all
    /// three so a restore never re-enables a job the user had switched off.
    static func isDisabled(in printed: String) -> Bool {
        let quoted = "\"\(LegacyRuntimePaths.legacyLabel)\""
        for line in printed.split(separator: "\n") where line.contains(quoted) {
            let value = line
                .split(separator: ">", maxSplits: 1, omittingEmptySubsequences: false)
                .last?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return value == "disabled" || value == "true"
        }
        return false
    }

    /// Matches on the wrapper's own path rather than a provider name, so a
    /// user's unrelated `python` never reads as a legacy producer.
    ///
    /// Two patterns, not one. The wrapper `exec`s nothing -- it spawns the
    /// producer as `<venv>/python3 -m gradus --refresh-snapshot` and waits -- so
    /// a producer orphaned by a killed wrapper matches neither the wrapper path
    /// nor the bundled runtime, and a wrapper-only check would report the legacy
    /// runtime stopped while it was still writing snapshots.
    func runningLegacyProcessPaths() -> [String] {
        var found: [String] = []
        for pattern in [wrapperURL.path, Self.legacyProducerPattern] {
            // `--` because the producer pattern starts with a dash, which
            // `pgrep` would otherwise read as its own option and reject.
            let result = run("/usr/bin/pgrep", ["-f", "--", pattern])
            guard result.status == 0 else { continue }
            for line in result.output.split(separator: "\n") {
                let entry = String(line)
                if !entry.isEmpty, !found.contains(entry) {
                    found.append(entry)
                }
            }
        }
        return found
    }

    /// The legacy producer's own command line. Deliberately not `gradus
    /// --refresh-snapshot`, which the bundled `GradusRuntime --refresh-snapshot`
    /// would also match: stopping the legacy job must not read as "still
    /// running" because the new agent has started working.
    static let legacyProducerPattern = "-m gradus --refresh-snapshot"

    func bootOut() throws {
        let result = run("/bin/launchctl", ["bootout", jobTarget])
        // `bootout` on an already-unloaded job is a no-op failure, not an error
        // worth rolling a migration back over. Disabled-but-loaded is still
        // loaded, so it is not an acceptable outcome here.
        guard result.status == 0 || currentState().isLoaded == false else {
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

    /// The producer's installed-mode tree, relative to its `HOME`. It creates
    /// only the leaf of each with a bare `mkdir` -- deliberately, so the lock
    /// cannot be reached through a symlinked parent -- so handing it an empty
    /// directory as `HOME` makes that `mkdir` fail with ENOENT and the refresh
    /// exit 1 before probing anything. Measured 2026-09-01: an empty root gave
    /// `refresh: lock unavailable`, exit 1, every time; the same run with these
    /// three directories present completed and exited 0 with no provider sign-ins at
    /// all. Without them the preflight could never pass, so `migrate()` was
    /// unreachable past its first step on any real machine.
    static let producerStateDirectories = [
        "Library/Application Support/Gradus/Installed",
        "Library/Application Support/Gradus/Private/.cache",
        "Library/Logs/Gradus"
    ]

    func runPreflight(stateRoot: URL, onStatus: (String) -> Void) -> Bool {
        guard FileManager.default.fileExists(atPath: runtimeExecutable.path) else { return false }
        for directory in Self.producerStateDirectories {
            try? FileManager.default.createDirectory(
                at: stateRoot.appendingPathComponent(directory), withIntermediateDirectories: true
            )
        }
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

    /// `updated_at`, because the snapshot is written by the Python producer and
    /// `gradus.history` allows exactly `schema_version`, `updated_at`,
    /// `providers`. The camelCase spelling is accepted too so a future
    /// Swift-authored snapshot does not silently read as "never refreshed" --
    /// which is the failure that matters here, since the cutover rolls back
    /// when it cannot see three fresh readings.
    func snapshotUpdatedAt() -> Date? {
        timestamp(in: snapshotURL, keys: ["updated_at", "updatedAt"])
    }

    /// The publisher writes no `ok` field: a `publish-evidence.json` exists only
    /// after a publish succeeded, so its presence *is* the success. An explicit
    /// `ok: false` still counts as a failure, for a writer that adds one later.
    func lastSuccessfulPublishAt() -> Date? {
        guard let object = json(at: publishEvidenceURL) else { return nil }
        if let ok = object["ok"] as? Bool, !ok {
            return nil
        }
        return timestamp(in: publishEvidenceURL, keys: ["publishedAt", "published_at"])
    }

    private func timestamp(in url: URL, keys: [String]) -> Date? {
        guard let object = json(at: url) else { return nil }
        let formatter = ISO8601DateFormatter()
        for key in keys {
            if let raw = object[key] as? String, let date = formatter.date(from: raw) {
                return date
            }
        }
        return nil
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
