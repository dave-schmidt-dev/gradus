import Foundation

/// What the legacy `local.gradus-snapshot` launchd job is doing, captured
/// before anything changes so a failed cutover can put it back exactly.
///
/// Deliberately three cases rather than a `Bool`: "installed but not loaded" is
/// a state a user can be in, and restoring it as "loaded" would silently start
/// a producer they had stopped.
public enum LegacyJobState: Equatable, Sendable, Codable {
    case absent
    case installedNotLoaded
    case loaded(enabled: Bool)

    /// True whenever the job is bootstrapped into a launchd domain, disabled or
    /// not. A disabled job is still loaded and one `launchctl enable` from
    /// running, which is why the cutover refuses it.
    public var isLoaded: Bool {
        if case .loaded = self {
            return true
        }
        return false
    }
}

/// Existence only. Nothing here opens a plist body, a wrapper script, a cookie
/// jar, or any stored provider credential -- INV-6 keeps that material behind
/// the bridge, and "is the old thing still here" needs none of it.
public struct LegacyRuntimeInventory: Equatable, Sendable {
    public let jobState: LegacyJobState
    public let wrapperPresent: Bool
    public let standaloneBridgePresent: Bool

    public init(jobState: LegacyJobState, wrapperPresent: Bool, standaloneBridgePresent: Bool) {
        self.jobState = jobState
        self.wrapperPresent = wrapperPresent
        self.standaloneBridgePresent = standaloneBridgePresent
    }

    public var needsMigration: Bool {
        jobState != .absent || wrapperPresent || standaloneBridgePresent
    }
}

/// A sibling repository's own statement that it now reads the installed
/// canonical snapshot. The digest is opaque on purpose: this proves *which*
/// file was read, never what was in it.
public struct ConsumerReceipt: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let consumer: String
    public let snapshotPath: String
    public let observedAt: String
    public let snapshotDigest: String

    public init(
        schemaVersion: Int = ConsumerReceipt.supportedSchemaVersion,
        consumer: String,
        snapshotPath: String,
        observedAt: String,
        snapshotDigest: String
    ) {
        self.schemaVersion = schemaVersion
        self.consumer = consumer
        self.snapshotPath = snapshotPath
        self.observedAt = observedAt
        self.snapshotDigest = snapshotDigest
    }
}

/// Why a receipt does not clear the gate. Every case names the consumer and the
/// problem and nothing else -- no path, no command output, no payload -- because
/// this text is persisted in migration state and rendered in Settings.
public enum ReceiptRejection: Equatable, Sendable, Codable {
    case missing(consumer: String)
    case unreadable(consumer: String)
    case unsupportedSchema(consumer: String)
    case wrongSnapshotPath(consumer: String)
    case stale(consumer: String)
    case opaqueDigestMissing(consumer: String)

    public var consumer: String {
        switch self {
        case let .missing(consumer), let .unreadable(consumer),
             let .unsupportedSchema(consumer), let .wrongSnapshotPath(consumer),
             let .stale(consumer), let .opaqueDigestMissing(consumer):
            consumer
        }
    }

    public var explanation: String {
        switch self {
        case let .missing(consumer): "\(consumer) has published no installed-path receipt."
        case let .unreadable(consumer): "\(consumer)'s receipt could not be read."
        case let .unsupportedSchema(consumer): "\(consumer)'s receipt uses an unsupported schema."
        case let .wrongSnapshotPath(consumer): "\(consumer) still reads a non-canonical snapshot path."
        case let .stale(consumer): "\(consumer)'s receipt is older than the freshness window."
        case let .opaqueDigestMissing(consumer): "\(consumer)'s receipt carries no opaque snapshot digest."
        }
    }
}

/// The gate Task 3.2 exists to enforce: the legacy job stays up until every
/// named consumer has proven, recently, that it reads the installed canonical
/// snapshot. A pure function so "would this refuse?" is a test, not a migration.
public enum ConsumerReceiptValidator {
    /// The sibling repositories that read the snapshot this app produces.
    public static let requiredConsumers = ["hermes-publisher", "review-plugin"]

    /// A receipt older than this describes a consumer's *previous* build.
    public static let freshness: TimeInterval = 24 * 60 * 60

    /// 64 lowercase hex characters. Long enough to be a digest, constrained
    /// enough that a path or a token cannot masquerade as one.
    private static let digestLength = 64

    public static func rejections(
        receipts: [String: ConsumerReceipt],
        unreadable: Set<String> = [],
        canonicalSnapshotPath: String,
        now: Date,
        freshness: TimeInterval = ConsumerReceiptValidator.freshness
    ) -> [ReceiptRejection] {
        requiredConsumers.sorted().compactMap { consumer in
            if unreadable.contains(consumer) {
                return .unreadable(consumer: consumer)
            }
            guard let receipt = receipts[consumer] else { return .missing(consumer: consumer) }
            return rejection(for: receipt, consumer: consumer,
                             canonicalSnapshotPath: canonicalSnapshotPath,
                             now: now, freshness: freshness)
        }
    }

    private static func rejection(
        for receipt: ConsumerReceipt,
        consumer: String,
        canonicalSnapshotPath: String,
        now: Date,
        freshness: TimeInterval
    ) -> ReceiptRejection? {
        guard receipt.schemaVersion == ConsumerReceipt.supportedSchemaVersion else {
            return .unsupportedSchema(consumer: consumer)
        }
        guard standardized(receipt.snapshotPath) == standardized(canonicalSnapshotPath) else {
            return .wrongSnapshotPath(consumer: consumer)
        }
        guard isOpaqueDigest(receipt.snapshotDigest) else {
            return .opaqueDigestMissing(consumer: consumer)
        }
        guard let observed = ISO8601DateFormatter().date(from: receipt.observedAt),
              observed <= now.addingTimeInterval(freshness),
              now.timeIntervalSince(observed) <= freshness
        else {
            return .stale(consumer: consumer)
        }
        return nil
    }

    static func isOpaqueDigest(_ digest: String) -> Bool {
        digest.count == digestLength && digest.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .standardizedFileURL.path
    }
}

/// Every step the cutover can be waiting in. INV-1: a migration that pauses on
/// a launchd bootout or a producer run has to say so while it waits.
public enum LegacyMigrationPhase: String, Codable, Sendable {
    case idle
    case checkingConsumers
    case preflighting
    case capturingLegacy
    case stoppingLegacy
    case registeringAgent
    case verifyingRefresh
    case verifyingPublish
    case succeeded
    case rollingBack
    case rolledBack
    case blocked
    case failed

    public var progressDescription: String {
        switch self {
        case .idle: "Not started."
        case .checkingConsumers: "Checking that the other tools read the installed snapshot…"
        case .preflighting: "Trying the bundled collector in an isolated copy…"
        case .capturingLegacy: "Recording the current background job so it can be restored…"
        case .stoppingLegacy: "Stopping the old background job…"
        case .registeringAgent: "Registering the bundled background agent…"
        case .verifyingRefresh: "Waiting for three fresh readings…"
        case .verifyingPublish: "Waiting for one successful publish…"
        case .succeeded: "Migration complete."
        case .rollingBack: "Restoring the old background job…"
        case .rolledBack: "Migration failed; the old background job was restored."
        case .blocked: "Migration is waiting on other tools."
        case .failed: "Migration failed."
        }
    }
}

/// Persisted migration state. Typed fields and opaque digests only: no paths,
/// no command output, no cookies, no tokens, no provider payloads.
public struct LegacyMigrationState: Codable, Equatable, Sendable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let phase: LegacyMigrationPhase
    public let sequence: Int
    public let updatedAt: String
    public let priorJobState: LegacyJobState?
    public let consumerDigests: [String: String]
    public let freshSnapshotCount: Int
    public let publishConfirmed: Bool
    public let rejections: [ReceiptRejection]

    public init(
        phase: LegacyMigrationPhase,
        sequence: Int,
        date: Date,
        priorJobState: LegacyJobState? = nil,
        consumerDigests: [String: String] = [:],
        freshSnapshotCount: Int = 0,
        publishConfirmed: Bool = false,
        rejections: [ReceiptRejection] = []
    ) {
        schemaVersion = LegacyMigrationState.supportedSchemaVersion
        self.phase = phase
        self.sequence = sequence
        updatedAt = ISO8601DateFormatter().string(from: date)
        self.priorJobState = priorJobState
        self.consumerDigests = consumerDigests
        self.freshSnapshotCount = freshSnapshotCount
        self.publishConfirmed = publishConfirmed
        self.rejections = rejections
    }
}

/// What the cutover did. `blocked` is a success of the gate, not a failure of
/// the migration: the legacy job is still running and still owns the refresh.
public enum LegacyMigrationOutcome: Equatable, Sendable {
    case notNeeded
    case blocked([ReceiptRejection])
    case migrated
    case rolledBack(LegacyMigrationFailure)
}

public enum LegacyMigrationFailure: String, Equatable, Sendable, Codable {
    case preflightFailed
    case legacyStillRunning
    case agentRegistrationFailed
    case noFreshSnapshots
    case noSuccessfulPublish
    case bothProducersRunning

    public var explanation: String {
        switch self {
        case .preflightFailed: "The bundled collector could not complete a run of its own."
        case .legacyStillRunning: "The old background job did not stop."
        case .agentRegistrationFailed: "The bundled background agent could not be registered."
        case .noFreshSnapshots: "The bundled agent produced no fresh readings."
        case .noSuccessfulPublish: "The bundled agent produced no successful publish."
        case .bothProducersRunning: "The old collector restarted alongside the bundled one."
        }
    }
}

/// What Settings shows about the legacy job. Separate from
/// `LegacyMigrationOutcome` because the UI also has to render "not started" and
/// "in progress", which are not outcomes.
public enum LegacyMigrationPresentation: Equatable, Sendable {
    case notApplicable
    case waitingOnConsumers([ReceiptRejection])
    case ready
    case running(String)
    case migrated
    case rolledBack(LegacyMigrationFailure)

    public var headline: String {
        switch self {
        case .notApplicable: "No legacy background job"
        case .waitingOnConsumers: "Waiting on other tools"
        case .ready: "Ready to move refresh into Gradus"
        case .running: "Moving refresh into Gradus…"
        case .migrated: "Gradus now owns background refresh"
        case .rolledBack: "The move was undone"
        }
    }

    public var explanation: String {
        switch self {
        case .notApplicable:
            "Nothing from the old setup is still running."
        case let .waitingOnConsumers(rejections):
            rejections.map(\.explanation).joined(separator: " ")
                + " The old background job is still running and still updating your usage."
        case .ready:
            "The old background job is still running. Gradus can take over and put it back if anything goes wrong."
        case let .running(step):
            step
        case .migrated:
            "The old background job was stopped, not deleted. Its files are still on this Mac."
        case let .rolledBack(failure):
            failure.explanation + " The old background job was restored exactly as it was; nothing was deleted."
        }
    }

    /// The migrate button is offered in exactly one state. Everything else is
    /// either nothing to do, someone else's turn, or already in flight.
    public var canStartMigration: Bool {
        self == .ready
    }
}
