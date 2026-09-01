import Foundation

/// Reads and changes the legacy launchd job. Split behind a protocol because
/// every alternative -- shelling out to `launchctl` from a test, or trusting a
/// developer's own machine to be in the right state -- makes the cutover
/// untestable in exactly the paths that matter.
public protocol LegacyJobControlling: AnyObject {
    func currentState() -> LegacyJobState
    /// Paths of any still-running legacy wrapper or producer process. Empty is
    /// the only value that lets the cutover proceed.
    func runningLegacyProcessPaths() -> [String]
    func bootOut() throws
    /// Puts the job back in exactly the captured state, including "installed
    /// but not loaded". Never creates a job that was absent.
    func restore(_ prior: LegacyJobState) throws
}

/// Runs the bundled producer against a state root that is not the installed one
/// and not the source checkout's, so a preflight can fail without touching
/// anything a user or a consumer reads.
public protocol IsolatedProducerRunning: AnyObject {
    func runPreflight(stateRoot: URL, onStatus: (String) -> Void) -> Bool
}

/// The two facts the cutover has to observe before it can claim success.
public protocol InstalledEvidenceReading: AnyObject {
    func snapshotUpdatedAt() -> Date?
    func lastSuccessfulPublishAt() -> Date?
}

public protocol MigrationStatePersisting: AnyObject {
    func write(_ state: LegacyMigrationState) throws
}

/// Detects the legacy runtime and, when every named consumer has proven it
/// reads the installed canonical snapshot, moves refresh from the legacy
/// launchd job to the bundled agent -- or puts the legacy job back exactly as
/// it found it.
///
/// The migrator cannot delete anything. There is no filesystem-removal
/// dependency on it at all, which is a stronger guarantee than a rule saying it
/// must not: a legacy plist, wrapper, or snapshot mirror survives every path
/// through this type, including rollback.
public final class LegacyRuntimeMigrator {
    /// Long enough for three `StartInterval: 120` runs plus slack, short enough
    /// that a wedged agent rolls back inside one sitting.
    public static let refreshDeadline: TimeInterval = 15 * 60
    public static let requiredFreshSnapshots = 3
    static let pollInterval: TimeInterval = 5

    private let job: LegacyJobControlling
    private let producer: IsolatedProducerRunning
    private let evidence: InstalledEvidenceReading
    private let agent: BackgroundAgentServicing
    private let statePersister: MigrationStatePersisting
    private let receiptsDirectory: URL
    private let canonicalSnapshotPath: String
    private let preflightStateRoot: URL
    private let now: () -> Date
    private let sleep: (TimeInterval) -> Void

    private var sequence = 0

    public init(
        job: LegacyJobControlling,
        producer: IsolatedProducerRunning,
        evidence: InstalledEvidenceReading,
        agent: BackgroundAgentServicing,
        statePersister: MigrationStatePersisting,
        receiptsDirectory: URL,
        canonicalSnapshotPath: String,
        preflightStateRoot: URL,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.job = job
        self.producer = producer
        self.evidence = evidence
        self.agent = agent
        self.statePersister = statePersister
        self.receiptsDirectory = receiptsDirectory
        self.canonicalSnapshotPath = canonicalSnapshotPath
        self.preflightStateRoot = preflightStateRoot
        self.now = now
        self.sleep = sleep
    }

    public func inventory(wrapperURL: URL, standaloneBridgeURL: URL) -> LegacyRuntimeInventory {
        LegacyRuntimeInventory(
            jobState: job.currentState(),
            wrapperPresent: FileManager.default.fileExists(atPath: wrapperURL.path),
            standaloneBridgePresent: FileManager.default.fileExists(atPath: standaloneBridgeURL.path)
        )
    }

    /// The receipt gate on its own, so Settings can show why a cutover is
    /// waiting without starting one.
    public func consumerRejections() -> [ReceiptRejection] {
        var receipts: [String: ConsumerReceipt] = [:]
        var unreadable: Set<String> = []
        for consumer in ConsumerReceiptValidator.requiredConsumers {
            let url = receiptsDirectory.appendingPathComponent("\(consumer).json")
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let receipt = try? JSONDecoder().decode(ConsumerReceipt.self, from: data) else {
                unreadable.insert(consumer)
                continue
            }
            receipts[consumer] = receipt
        }
        return ConsumerReceiptValidator.rejections(
            receipts: receipts,
            unreadable: unreadable,
            canonicalSnapshotPath: canonicalSnapshotPath,
            now: now()
        )
    }

    // The cutover is one ordered sequence whose every step has a distinct
    // rollback obligation, and each `emit` is a state the UI can be showing at
    // that instant. Splitting it would thread `prior`, `sequence`, and the
    // rollback closure through helpers for no reader's benefit.
    // swiftlint:disable:next function_body_length
    public func migrate(onStatus: (String) -> Void = { _ in }) -> LegacyMigrationOutcome {
        func emit(_ phase: LegacyMigrationPhase, _ state: LegacyMigrationState) {
            onStatus(phase.progressDescription)
            try? statePersister.write(state)
        }
        func advance(
            _ phase: LegacyMigrationPhase,
            prior: LegacyJobState? = nil,
            digests: [String: String] = [:],
            fresh: Int = 0,
            published: Bool = false,
            rejections: [ReceiptRejection] = []
        ) {
            sequence += 1
            emit(phase, LegacyMigrationState(
                phase: phase, sequence: sequence, date: now(), priorJobState: prior,
                consumerDigests: digests, freshSnapshotCount: fresh,
                publishConfirmed: published, rejections: rejections
            ))
        }

        guard job.currentState() != .absent else {
            advance(.succeeded)
            return .notNeeded
        }

        advance(.checkingConsumers)
        let rejections = consumerRejections()
        guard rejections.isEmpty else {
            advance(.blocked, rejections: rejections)
            return .blocked(rejections)
        }
        let digests = recordedDigests()

        advance(.preflighting, digests: digests)
        guard preflightRootIsIsolated(), producer.runPreflight(stateRoot: preflightStateRoot, onStatus: onStatus) else {
            advance(.failed, digests: digests)
            return .rolledBack(.preflightFailed)
        }

        advance(.capturingLegacy, digests: digests)
        let prior = job.currentState()

        advance(.stoppingLegacy, prior: prior, digests: digests)
        do {
            try job.bootOut()
        } catch {
            return rollBack(.legacyStillRunning, prior: prior, digests: digests, advance: advance)
        }
        // Not `!= .loaded(enabled: true)`: a job left loaded-but-disabled is
        // still bootstrapped into the domain, so `launchctl enable` or a logout
        // would start it again alongside the agent. Only "out of the domain
        // entirely" counts as stopped.
        guard job.currentState().isLoaded == false, job.runningLegacyProcessPaths().isEmpty else {
            return rollBack(.legacyStillRunning, prior: prior, digests: digests, advance: advance)
        }

        advance(.registeringAgent, prior: prior, digests: digests)
        do {
            try agent.register()
        } catch {
            return rollBack(.agentRegistrationFailed, prior: prior, digests: digests, advance: advance)
        }

        advance(.verifyingRefresh, prior: prior, digests: digests)
        let fresh = waitForFreshSnapshots(onStatus: onStatus)
        guard fresh >= Self.requiredFreshSnapshots else {
            return rollBack(.noFreshSnapshots, prior: prior, digests: digests, advance: advance)
        }
        guard job.runningLegacyProcessPaths().isEmpty else {
            return rollBack(.bothProducersRunning, prior: prior, digests: digests, advance: advance)
        }

        advance(.verifyingPublish, prior: prior, digests: digests, fresh: fresh)
        guard evidence.lastSuccessfulPublishAt() != nil else {
            return rollBack(.noSuccessfulPublish, prior: prior, digests: digests, advance: advance)
        }

        advance(.succeeded, prior: prior, digests: digests, fresh: fresh, published: true)
        return .migrated
    }

    private func rollBack(
        _ failure: LegacyMigrationFailure,
        prior: LegacyJobState,
        digests: [String: String],
        advance: (LegacyMigrationPhase, LegacyJobState?, [String: String], Int, Bool, [ReceiptRejection]) -> Void
    ) -> LegacyMigrationOutcome {
        advance(.rollingBack, prior, digests, 0, false, [])
        try? agent.unregister()
        try? job.restore(prior)
        advance(.rolledBack, prior, digests, 0, false, [])
        return .rolledBack(failure)
    }

    /// Three *advancing* readings, not three polls that saw the same file. A
    /// snapshot whose timestamp never moves is a stalled agent, not a fresh one.
    private func waitForFreshSnapshots(onStatus: (String) -> Void) -> Int {
        var seen: [Date] = []
        var waited: TimeInterval = 0
        while waited < Self.refreshDeadline, seen.count < Self.requiredFreshSnapshots {
            if let updated = evidence.snapshotUpdatedAt(), updated != seen.last {
                seen.append(updated)
                onStatus("Fresh reading \(seen.count) of \(Self.requiredFreshSnapshots).")
                continue
            }
            sleep(Self.pollInterval)
            // Counted rather than read from `now()`: this loop's own polling is
            // what bounds it, so an injected clock cannot make it spin forever.
            waited += Self.pollInterval
        }
        return seen.count
    }

    /// The preflight must not alias the installed root or the source checkout's
    /// state. Separate roots are what let both modes keep their own
    /// single-flight lock instead of inventing one that spans them.
    private func preflightRootIsIsolated() -> Bool {
        let preflight = preflightStateRoot.standardizedFileURL.path
        let installed = URL(fileURLWithPath: canonicalSnapshotPath)
            .deletingLastPathComponent().standardizedFileURL.path
        return preflight != installed
            && !preflight.hasPrefix(installed + "/")
            && !installed.hasPrefix(preflight + "/")
    }

    private func recordedDigests() -> [String: String] {
        var digests: [String: String] = [:]
        for consumer in ConsumerReceiptValidator.requiredConsumers {
            let url = receiptsDirectory.appendingPathComponent("\(consumer).json")
            guard let data = try? Data(contentsOf: url),
                  let receipt = try? JSONDecoder().decode(ConsumerReceipt.self, from: data)
            else { continue }
            digests[consumer] = receipt.snapshotDigest
        }
        return digests
    }
}
