import Foundation
@testable import GradusMac
import Testing

/// A legacy job that records every request instead of touching launchd.
final class FakeLegacyJob: LegacyJobControlling {
    var state: LegacyJobState
    var runningPaths: [String] = []
    /// Consumed one entry per call, so a test can make the legacy wrapper
    /// reappear at a specific point in the cutover rather than throughout it.
    var runningPathsSequence: [[String]] = []
    var bootOutError: Error?
    var stateAfterBootOut: LegacyJobState = .installedNotLoaded
    private(set) var bootOutCount = 0
    private(set) var restored: [LegacyJobState] = []

    init(state: LegacyJobState) {
        self.state = state
    }

    func currentState() -> LegacyJobState {
        state
    }

    func runningLegacyProcessPaths() -> [String] {
        guard !runningPathsSequence.isEmpty else { return runningPaths }
        return runningPathsSequence.removeFirst()
    }

    func bootOut() throws {
        bootOutCount += 1
        if let bootOutError {
            throw bootOutError
        }
        state = stateAfterBootOut
    }

    func restore(_ prior: LegacyJobState) throws {
        restored.append(prior)
        state = prior
    }
}

final class FakePreflight: IsolatedProducerRunning {
    var succeeds = true
    private(set) var roots: [URL] = []

    func runPreflight(stateRoot: URL, onStatus: (String) -> Void) -> Bool {
        roots.append(stateRoot)
        onStatus("preflight")
        return succeeds
    }
}

final class FakeEvidence: InstalledEvidenceReading {
    var snapshotTimes: [Date?] = []
    var publishTime: Date?
    private var index = 0

    func snapshotUpdatedAt() -> Date? {
        guard index < snapshotTimes.count else { return snapshotTimes.last ?? nil }
        defer { index += 1 }
        return snapshotTimes[index]
    }

    func lastSuccessfulPublishAt() -> Date? {
        publishTime
    }
}

final class FakeAgent: BackgroundAgentServicing {
    var registration: BackgroundAgentRegistration = .notRegistered
    var registerError: Error?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0

    func register() throws {
        registerCount += 1
        if let registerError {
            throw registerError
        }
        registration = .enabled
    }

    func unregister() throws {
        unregisterCount += 1
        registration = .notRegistered
    }
}

extension FakeAgent {
    enum Failure: Error { case refused }
}

final class RecordingStateWriter: MigrationStatePersisting {
    private(set) var written: [LegacyMigrationState] = []

    func write(_ state: LegacyMigrationState) throws {
        written.append(state)
    }
}

struct MigrationFixture {
    let root: URL
    let receipts: URL
    let installedRoot: URL
    let snapshotPath: String
    let preflightRoot: URL

    init(_ label: String) {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gradus-migration-\(label)-\(UUID().uuidString)")
        receipts = root.appendingPathComponent("consumer-receipts")
        installedRoot = root.appendingPathComponent("Installed")
        snapshotPath = installedRoot.appendingPathComponent("snapshot-v2.json").path
        preflightRoot = root.appendingPathComponent("preflight")
        try? FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: installedRoot, withIntermediateDirectories: true)
    }

    func writeReceipt(
        _ consumer: String,
        path: String? = nil,
        observedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        digest: String = String(repeating: "a", count: 64),
        schemaVersion: Int = 1
    ) {
        let receipt = ConsumerReceipt(
            schemaVersion: schemaVersion,
            consumer: consumer,
            snapshotPath: path ?? snapshotPath,
            observedAt: ISO8601DateFormatter().string(from: observedAt),
            snapshotDigest: digest
        )
        let url = receipts.appendingPathComponent("\(consumer).json")
        try? JSONEncoder().encode(receipt).write(to: url)
    }

    func writeAllReceipts(observedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        for consumer in ConsumerReceiptValidator.requiredConsumers {
            writeReceipt(consumer, observedAt: observedAt)
        }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

let migrationNow = Date(timeIntervalSince1970: 1_700_000_600)

func makeMigrator(
    _ fixture: MigrationFixture,
    job: FakeLegacyJob,
    preflight: FakePreflight = FakePreflight(),
    evidence: FakeEvidence = FakeEvidence(),
    agent: FakeAgent = FakeAgent(),
    writer: RecordingStateWriter = RecordingStateWriter()
) -> LegacyRuntimeMigrator {
    LegacyRuntimeMigrator(
        job: job,
        producer: preflight,
        evidence: evidence,
        agent: agent,
        statePersister: writer,
        receiptsDirectory: fixture.receipts,
        canonicalSnapshotPath: fixture.snapshotPath,
        preflightStateRoot: fixture.preflightRoot,
        now: { migrationNow },
        sleep: { _ in }
    )
}

func succeedingEvidence() -> FakeEvidence {
    let evidence = FakeEvidence()
    evidence.snapshotTimes = [
        Date(timeIntervalSince1970: 1),
        Date(timeIntervalSince1970: 2),
        Date(timeIntervalSince1970: 3)
    ]
    evidence.publishTime = Date(timeIntervalSince1970: 4)
    return evidence
}
