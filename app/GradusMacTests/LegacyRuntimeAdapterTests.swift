import Foundation
@testable import GradusMac
import Testing

/// The three real collaborators the migrator talks to. Everything above them is
/// covered by fakes, which is exactly why these need their own tests: a fake
/// agrees with whatever the adapter believes, so a wrong key name or a wrong
/// `launchctl` output shape stays green all the way to a live cutover and then
/// rolls it back for a reason nobody can see.
///
/// Every fixture below is a verbatim copy of a real file or a real command's
/// output on a machine running the legacy job.
@Suite("Legacy runtime adapters")
struct LegacyRuntimeAdapterTests {
    private func scratchRoot(_ label: String) -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gradus-adapter-\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Installed evidence

    /// `gradus.history` allows exactly `schema_version`, `updated_at`,
    /// `providers`, and the producer writes all three in snake_case. Reading
    /// `updatedAt` returned nil forever, so `waitForFreshSnapshots` could never
    /// count a reading and every real cutover would have ended in
    /// `.rolledBack(.noFreshSnapshots)` with the agent registered and working.
    @Test func snapshotTimestampIsReadFromTheProducersOwnKey() throws {
        let root = scratchRoot("snapshot-keys")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = root.appendingPathComponent("snapshot-v2.json")
        try Data("""
        {"schema_version": 2, "updated_at": "2026-09-01T01:45:12Z", "providers": []}
        """.utf8).write(to: snapshot)
        let evidence = InstalledEvidenceFiles(
            snapshotURL: snapshot, publishEvidenceURL: root.appendingPathComponent("absent.json")
        )

        let read = try #require(evidence.snapshotUpdatedAt())
        #expect(read == ISO8601DateFormatter().date(from: "2026-09-01T01:45:12Z"))
    }

    @Test func aCamelCaseSnapshotIsStillReadable() throws {
        let root = scratchRoot("snapshot-camel")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = root.appendingPathComponent("snapshot-v2.json")
        try Data(#"{"schemaVersion": 2, "updatedAt": "2026-09-01T01:45:12Z"}"#.utf8).write(to: snapshot)

        #expect(InstalledEvidenceFiles(
            snapshotURL: snapshot, publishEvidenceURL: root
        ).snapshotUpdatedAt() != nil)
    }

    @Test func anAbsentSnapshotReadsAsNoReading() {
        let root = scratchRoot("snapshot-absent")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(InstalledEvidenceFiles(
            snapshotURL: root.appendingPathComponent("nope.json"),
            publishEvidenceURL: root.appendingPathComponent("nope.json")
        ).snapshotUpdatedAt() == nil)
    }

    /// The real file, byte for byte. It carries no `ok` field -- it exists only
    /// because a publish succeeded -- so requiring one made
    /// `verifyingPublish` unreachable and rolled every cutover back.
    @Test func aRealPublishEvidenceFileCountsAsASuccessfulPublish() throws {
        let root = scratchRoot("publish-real")
        defer { try? FileManager.default.removeItem(at: root) }
        let evidenceURL = root.appendingPathComponent("publish-evidence.json")
        try Data("""
        {"cloudKitEnvironment":"Production","producerBuildNumber":"18",\
        "projectSha256":"6a180f631e3397275993728ea82695397d800a0ad7907d6e0eed4968b32083a1",\
        "publishedAt":"2026-09-01T01:49:19Z",\
        "sourceRevision":"559659c03c9fcb4ad9eecf7a9b5344de488a3a66"}
        """.utf8).write(to: evidenceURL)
        let evidence = InstalledEvidenceFiles(
            snapshotURL: root.appendingPathComponent("absent.json"), publishEvidenceURL: evidenceURL
        )

        #expect(evidence.lastSuccessfulPublishAt()
            == ISO8601DateFormatter().date(from: "2026-09-01T01:49:19Z"))
    }

    @Test func anExplicitFailureFlagStillMeansNoPublish() throws {
        let root = scratchRoot("publish-not-ok")
        defer { try? FileManager.default.removeItem(at: root) }
        let evidenceURL = root.appendingPathComponent("publish-evidence.json")
        try Data(#"{"ok": false, "publishedAt": "2026-09-01T01:49:19Z"}"#.utf8).write(to: evidenceURL)

        #expect(InstalledEvidenceFiles(
            snapshotURL: root, publishEvidenceURL: evidenceURL
        ).lastSuccessfulPublishAt() == nil)
    }

    // MARK: - launchctl

    /// Verbatim `launchctl print-disabled gui/501` output. The shape is
    /// `=> enabled` / `=> disabled` on this OS, not the `=> true` an earlier
    /// release printed; parsing for `=> true` read every disabled job as
    /// enabled, so a rollback would have re-enabled a job the user had
    /// deliberately switched off.
    @Test func printDisabledIsParsedInTheShapeThisOSPrints() {
        let disabled = """
        \tdisabled services = {
        \t\t"local.gradus-snapshot" => disabled
        \t\t"com.zerodelta.gradus.refresh-agent" => enabled
        \t}
        """
        let enabled = disabled.replacingOccurrences(of: "\"local.gradus-snapshot\" => disabled",
                                                    with: "\"local.gradus-snapshot\" => enabled")

        #expect(LaunchctlLegacyJob.isDisabled(in: disabled))
        #expect(!LaunchctlLegacyJob.isDisabled(in: enabled))
        // The legacy label really is absent from this machine's output: a job
        // never toggled is not listed at all, and that means enabled.
        #expect(!LaunchctlLegacyJob.isDisabled(in: "\t\t\"com.other.job\" => disabled"))
    }

    /// The pre-2026 spelling, kept accepted so a machine on an older macOS does
    /// not read a disabled job as enabled.
    @Test func theOlderBooleanSpellingIsStillUnderstood() {
        #expect(LaunchctlLegacyJob.isDisabled(in: "\t\t\"local.gradus-snapshot\" => true"))
        #expect(!LaunchctlLegacyJob.isDisabled(in: "\t\t\"local.gradus-snapshot\" => false"))
    }

    @Test func aLoadedJobReportsItsEnabledStateFromPrintDisabled() {
        let job = LaunchctlLegacyJob(
            plistURL: URL(fileURLWithPath: "/nonexistent/local.gradus-snapshot.plist"),
            wrapperURL: URL(fileURLWithPath: "/nonexistent/gradus_snapshot.sh"),
            uid: 501,
            run: { _, arguments in
                arguments.contains("print-disabled")
                    ? (0, "\t\t\"local.gradus-snapshot\" => disabled")
                    : (0, "gui/501/local.gradus-snapshot = {}")
            }
        )

        #expect(job.currentState() == .loaded(enabled: false))
        #expect(job.currentState().isLoaded)
    }

    /// The wrapper spawns `<venv>/python3 -m gradus --refresh-snapshot` and
    /// waits, so a producer orphaned by a killed wrapper matches only the second
    /// pattern. Missing it would let the cutover proceed while the legacy
    /// producer was still writing the snapshot the new agent had just claimed.
    @Test func anOrphanedProducerStillCountsAsTheLegacyRuntimeRunning() {
        var patterns: [String] = []
        let job = LaunchctlLegacyJob(
            plistURL: URL(fileURLWithPath: "/nonexistent/plist"),
            wrapperURL: URL(fileURLWithPath: "/Users/x/.launchd/scripts/gradus_snapshot.sh"),
            run: { _, arguments in
                let pattern = arguments.last ?? ""
                patterns.append(pattern)
                return pattern == LaunchctlLegacyJob.legacyProducerPattern ? (0, "4821\n") : (1, "")
            }
        )

        #expect(job.runningLegacyProcessPaths() == ["4821"])
        #expect(patterns == [
            "/Users/x/.launchd/scripts/gradus_snapshot.sh",
            LaunchctlLegacyJob.legacyProducerPattern
        ])
    }

    /// `pgrep` reads a dash-leading pattern as its own options and exits 2, so
    /// the producer pattern has to arrive after `--`. Without it the second
    /// check silently never matches, which is the same blindness as not having
    /// it at all.
    @Test func aDashLeadingPatternIsPassedAfterAnEndOfOptionsMarker() {
        var invocations: [[String]] = []
        let job = LaunchctlLegacyJob(
            plistURL: URL(fileURLWithPath: "/nonexistent/plist"),
            wrapperURL: URL(fileURLWithPath: "/nonexistent/wrapper.sh"),
            run: { _, arguments in
                invocations.append(arguments)
                return (1, "")
            }
        )

        _ = job.runningLegacyProcessPaths()

        #expect(LaunchctlLegacyJob.legacyProducerPattern.hasPrefix("-"))
        for invocation in invocations {
            #expect(invocation.dropLast().contains("--"))
        }
    }

    /// A bundled `GradusRuntime --refresh-snapshot` is the *new* runtime doing
    /// its job. If the legacy pattern matched it, the cutover would report the
    /// legacy runtime as still running the moment the agent started working.
    @Test func theProducerPatternDoesNotMatchTheBundledRuntime() {
        let bundled = "/Applications/Gradus.app/Contents/Helpers"
            + "/GradusRuntime.app/Contents/MacOS/GradusRuntime --refresh-snapshot"
        #expect(!bundled.contains(LaunchctlLegacyJob.legacyProducerPattern))
        #expect("/Users/x/gradus/.venv/bin/python3 -m gradus --refresh-snapshot"
            .contains(LaunchctlLegacyJob.legacyProducerPattern))
    }

    // MARK: - Preflight

    /// Measured, not assumed: an empty isolated `HOME` made the producer exit 1
    /// with `refresh: lock unavailable` before it probed anything, because it
    /// creates its state directory with a bare `mkdir` that fails on a missing
    /// parent. A preflight that can never pass makes every step of `migrate()`
    /// after it unreachable, and the Settings copy would have said the bundled
    /// collector could not produce a snapshot on a machine where it can.
    @Test func thePreflightBuildsTheProducersStateTreeUnderTheIsolatedRoot() {
        let root = scratchRoot("preflight-tree")
        defer { try? FileManager.default.removeItem(at: root) }
        let stateRoot = root.appendingPathComponent("isolated")
        // A real executable path, so the preflight gets past its own guard and
        // reaches the directory work; `/usr/bin/true` then exits 0.
        let preflight = BundledProducerPreflight(
            runtimeExecutable: URL(fileURLWithPath: "/usr/bin/true"), timeout: 30
        )

        #expect(preflight.runPreflight(stateRoot: stateRoot) { _ in })

        for directory in BundledProducerPreflight.producerStateDirectories {
            #expect(
                FileManager.default.fileExists(
                    atPath: stateRoot.appendingPathComponent(directory).path
                ),
                "the producer creates only the leaf of \(directory) and fails on a missing parent"
            )
        }
    }

    @Test func anAbsentRuntimeFailsThePreflightWithoutTouchingTheDisk() {
        let root = scratchRoot("preflight-absent")
        defer { try? FileManager.default.removeItem(at: root) }
        let stateRoot = root.appendingPathComponent("isolated")
        let preflight = BundledProducerPreflight(
            runtimeExecutable: root.appendingPathComponent("GradusRuntime")
        )

        #expect(!preflight.runPreflight(stateRoot: stateRoot) { _ in })
        #expect(!FileManager.default.fileExists(atPath: stateRoot.path))
    }

    // MARK: - Standalone bridge

    /// The standalone bridge installs to the user's own `~/Applications`, which
    /// is where this machine's copy is. Looking only in `/Applications` made
    /// `standaloneBridgePresent` a permanent false, so a Mac with the legacy
    /// bridge but no legacy job would have been told it had nothing to migrate.
    @Test func theStandaloneBridgeIsFoundInTheUsersOwnApplications() throws {
        let home = scratchRoot("bridge-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let bridge = home.appendingPathComponent("Applications/GradusCredentialBridge.app")
        try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)

        // Compared by path: `appendingPathComponent` consults the file system,
        // so the adapter's URL -- built after the directory exists -- carries a
        // trailing slash the test's does not.
        #expect(LegacyRuntimePaths.standaloneBridge(homeDirectory: home).path == bridge.path)
    }

    @Test func anAbsentBridgeStillYieldsACheckablePath() {
        let home = scratchRoot("bridge-none")
        defer { try? FileManager.default.removeItem(at: home) }

        let resolved = LegacyRuntimePaths.standaloneBridge(homeDirectory: home)
        #expect(!FileManager.default.fileExists(atPath: resolved.path))
        #expect(resolved.lastPathComponent == "GradusCredentialBridge.app")
    }
}
