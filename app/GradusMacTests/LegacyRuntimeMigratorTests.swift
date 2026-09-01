import Foundation
@testable import GradusMac
import Testing

@Suite("Legacy consumer receipt gate")
struct ConsumerReceiptGateTests {
    @Test func aMissingReceiptRejectsBeforeAnythingIsTouched() {
        let fixture = MigrationFixture("missing")
        defer { fixture.cleanUp() }
        fixture.writeReceipt("hermes-publisher")
        let job = FakeLegacyJob(state: .loaded(enabled: true))
        let preflight = FakePreflight()
        let migrator = makeMigrator(fixture, job: job, preflight: preflight)

        let outcome = migrator.migrate()

        #expect(outcome == .blocked([.missing(consumer: "review-plugin")]))
        #expect(job.bootOutCount == 0)
        #expect(preflight.roots.isEmpty)
        #expect(job.currentState() == .loaded(enabled: true))
    }

    @Test func aStaleReceiptRejectsBeforeLegacyShutdown() {
        let fixture = MigrationFixture("stale")
        defer { fixture.cleanUp() }
        fixture.writeAllReceipts(observedAt: Date(timeIntervalSince1970: 1))
        let job = FakeLegacyJob(state: .loaded(enabled: true))
        let migrator = makeMigrator(fixture, job: job)

        let outcome = migrator.migrate()

        #expect(outcome == .blocked([
            .stale(consumer: "hermes-publisher"), .stale(consumer: "review-plugin")
        ]))
        #expect(job.bootOutCount == 0)
    }

    @Test func aConsumerStillReadingTheLegacyMirrorRejects() {
        let fixture = MigrationFixture("wrongpath")
        defer { fixture.cleanUp() }
        fixture.writeAllReceipts()
        fixture.writeReceipt("review-plugin", path: "/tmp/legacy/snapshot-v2.json")
        let job = FakeLegacyJob(state: .loaded(enabled: true))
        let migrator = makeMigrator(fixture, job: job)

        #expect(migrator.migrate() == .blocked([.wrongSnapshotPath(consumer: "review-plugin")]))
        #expect(job.bootOutCount == 0)
    }

    @Test func aReceiptWithoutAnOpaqueDigestRejects() {
        let fixture = MigrationFixture("digest")
        defer { fixture.cleanUp() }
        fixture.writeAllReceipts()
        fixture.writeReceipt("review-plugin", digest: "not-a-digest")
        let job = FakeLegacyJob(state: .loaded(enabled: true))

        #expect(makeMigrator(fixture, job: job).migrate()
            == .blocked([.opaqueDigestMissing(consumer: "review-plugin")]))
    }

    @Test func anUnreadableReceiptIsRejectedRatherThanIgnored() {
        let fixture = MigrationFixture("unreadable")
        defer { fixture.cleanUp() }
        fixture.writeAllReceipts()
        try? Data("{ not json".utf8)
            .write(to: fixture.receipts.appendingPathComponent("review-plugin.json"))
        let job = FakeLegacyJob(state: .loaded(enabled: true))

        #expect(makeMigrator(fixture, job: job).migrate()
            == .blocked([.unreadable(consumer: "review-plugin")]))
    }

    /// A rejection is rendered in Settings and persisted, so it must name the
    /// consumer and the problem and carry nothing else.
    @Test func rejectionTextCarriesNoPathOrPayload() {
        let rejections: [ReceiptRejection] = [
            .missing(consumer: "review-plugin"),
            .unreadable(consumer: "review-plugin"),
            .unsupportedSchema(consumer: "review-plugin"),
            .wrongSnapshotPath(consumer: "review-plugin"),
            .stale(consumer: "review-plugin"),
            .opaqueDigestMissing(consumer: "review-plugin")
        ]
        for rejection in rejections {
            #expect(!rejection.explanation.isEmpty)
            #expect(!rejection.explanation.contains("/"))
            #expect(rejection.explanation.contains(rejection.consumer))
        }
    }
}

@Suite("Legacy runtime cutover")
struct LegacyRuntimeCutoverTests {
    @Test func anAbsentLegacyJobNeedsNoMigration() {
        let fixture = MigrationFixture("absent")
        defer { fixture.cleanUp() }
        let job = FakeLegacyJob(state: .absent)
        let preflight = FakePreflight()

        #expect(makeMigrator(fixture, job: job, preflight: preflight).migrate() == .notNeeded)
        #expect(preflight.roots.isEmpty)
        #expect(job.bootOutCount == 0)
    }

    @Test func preflightRunsInAnIsolatedRootBeforeTheLegacyJobIsTouched() {
        let fixture = MigrationFixture("preflight")
        defer { fixture.cleanUp() }
        fixture.writeAllReceipts()
        let job = FakeLegacyJob(state: .loaded(enabled: true))
        let preflight = FakePreflight()

        _ = makeMigrator(
            fixture, job: job, preflight: preflight, evidence: succeedingEvidence()
        ).migrate()

        #expect(preflight.roots == [fixture.preflightRoot])
        // Nonaliasing: the preflight root is neither the installed root nor
        // inside it, so both modes keep their own single-flight lock.
        #expect(!fixture.preflightRoot.path.hasPrefix(fixture.installedRoot.path))
    }

    @Test func aFailedPreflightNeverStopsTheLegacyJob() {
        let fixture = MigrationFixture("preflight-fail")
        defer { fixture.cleanUp() }
        fixture.writeAllReceipts()
        let job = FakeLegacyJob(state: .loaded(enabled: true))
        let preflight = FakePreflight()
        preflight.succeeds = false

        #expect(makeMigrator(fixture, job: job, preflight: preflight).migrate()
            == .rolledBack(.preflightFailed))
        #expect(job.bootOutCount == 0)
        #expect(job.currentState() == .loaded(enabled: true))
    }

    @Test func aSurvivingLegacyProcessRollsBackBeforeTheAgentIsRegistered() {
        let fixture = MigrationFixture("survivor")
        defer { fixture.cleanUp() }
        fixture.writeAllReceipts()
        let job = FakeLegacyJob(state: .loaded(enabled: true))
        job.runningPaths = ["/Users/someone/.launchd/scripts/gradus_snapshot.sh"]
        let agent = FakeAgent()

        #expect(makeMigrator(fixture, job: job, agent: agent).migrate()
            == .rolledBack(.legacyStillRunning))
        #expect(agent.registerCount == 0)
        #expect(job.restored == [.loaded(enabled: true)])
    }

    @Test func aHappyCutoverRegistersTheAgentAndKeepsExactlyOneProducer() {
        let fixture = MigrationFixture("happy")
        defer { fixture.cleanUp() }
        fixture.writeAllReceipts()
        let job = FakeLegacyJob(state: .loaded(enabled: true))
        let agent = FakeAgent()

        #expect(makeMigrator(fixture, job: job, evidence: succeedingEvidence(), agent: agent).migrate()
            == .migrated)
        #expect(agent.registration == .enabled)
        #expect(job.currentState() == .installedNotLoaded)
        #expect(job.runningLegacyProcessPaths().isEmpty)
        #expect(job.restored.isEmpty)
    }

    @Test func aLegacyProducerReappearingAfterCutoverRollsBack() {
        let fixture = MigrationFixture("both")
        defer { fixture.cleanUp() }
        fixture.writeAllReceipts()
        let job = FakeLegacyJob(state: .loaded(enabled: true))
        let agent = FakeAgent()
        let evidence = succeedingEvidence()
        // The wrapper is gone at shutdown and comes back only after the agent
        // has produced its readings: exactly the overlap the cutover refuses.
        job.runningPathsSequence = [[], ["/Users/someone/.launchd/scripts/gradus_snapshot.sh"]]
        let migrator = makeMigrator(fixture, job: job, evidence: evidence, agent: agent)

        #expect(migrator.migrate() == .rolledBack(.bothProducersRunning))
        #expect(agent.unregisterCount == 1)
        #expect(job.restored == [.loaded(enabled: true)])
    }

    @Test func agentRegistrationFailureRestoresTheExactPriorState() {
        for prior in [LegacyJobState.loaded(enabled: true), .loaded(enabled: false)] {
            let fixture = MigrationFixture("registerfail")
            defer { fixture.cleanUp() }
            fixture.writeAllReceipts()
            let job = FakeLegacyJob(state: prior)
            let agent = FakeAgent()
            agent.registerError = FakeAgent.Failure.refused

            #expect(makeMigrator(fixture, job: job, agent: agent).migrate()
                == .rolledBack(.agentRegistrationFailed))
            #expect(job.restored == [prior])
            #expect(job.currentState() == prior)
        }
    }

    @Test func aStalledAgentRollsBackRatherThanClaimingCutover() {
        let fixture = MigrationFixture("stalled")
        defer { fixture.cleanUp() }
        fixture.writeAllReceipts()
        let job = FakeLegacyJob(state: .loaded(enabled: true))
        let evidence = FakeEvidence()
        evidence.snapshotTimes = [Date(timeIntervalSince1970: 1)]
        let agent = FakeAgent()

        #expect(makeMigrator(fixture, job: job, evidence: evidence, agent: agent).migrate()
            == .rolledBack(.noFreshSnapshots))
        #expect(agent.unregisterCount == 1)
        #expect(job.restored == [.loaded(enabled: true)])
    }

    @Test func noPublishMeansNoCutover() {
        let fixture = MigrationFixture("nopublish")
        defer { fixture.cleanUp() }
        fixture.writeAllReceipts()
        let job = FakeLegacyJob(state: .loaded(enabled: true))
        let evidence = succeedingEvidence()
        evidence.publishTime = nil

        #expect(makeMigrator(fixture, job: job, evidence: evidence).migrate()
            == .rolledBack(.noSuccessfulPublish))
        #expect(job.restored == [.loaded(enabled: true)])
    }
}

@Suite("Legacy migration state and file safety")
struct LegacyMigrationStateTests {
    @Test func migrationDeletesNoLegacyFile() throws {
        let fixture = MigrationFixture("nodelete")
        defer { fixture.cleanUp() }
        fixture.writeAllReceipts()
        let plist = fixture.root.appendingPathComponent("local.gradus-snapshot.plist")
        let wrapper = fixture.root.appendingPathComponent("gradus_snapshot.sh")
        let mirror = fixture.root.appendingPathComponent("snapshot-v2.json")
        for url in [plist, wrapper, mirror] {
            try Data("legacy".utf8).write(to: url)
        }
        let job = FakeLegacyJob(state: .loaded(enabled: true))
        let evidence = FakeEvidence()
        evidence.snapshotTimes = [Date(timeIntervalSince1970: 1)]

        _ = makeMigrator(fixture, job: job, evidence: evidence).migrate()

        for url in [plist, wrapper, mirror] {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func persistedStateCarriesTypedFieldsAndOpaqueDigestsOnly() throws {
        let fixture = MigrationFixture("typed")
        defer { fixture.cleanUp() }
        fixture.writeAllReceipts()
        let writer = RecordingStateWriter()
        _ = makeMigrator(
            fixture, job: FakeLegacyJob(state: .loaded(enabled: true)),
            evidence: succeedingEvidence(), writer: writer
        ).migrate()

        #expect(!writer.written.isEmpty)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for state in writer.written {
            let text = try #require(String(bytes: encoder.encode(state), encoding: .utf8))
            #expect(!text.contains("/"))
            for digest in state.consumerDigests.values {
                #expect(ConsumerReceiptValidator.isOpaqueDigest(digest))
            }
        }
        #expect(writer.written.last?.phase == .succeeded)
        #expect(writer.written.last?.freshSnapshotCount == LegacyRuntimeMigrator.requiredFreshSnapshots)
    }

    /// INV-1: every wait in the cutover names itself while it waits.
    @Test func everyPhaseEmitsVisibleProgress() {
        let fixture = MigrationFixture("progress")
        defer { fixture.cleanUp() }
        fixture.writeAllReceipts()
        var statuses: [String] = []
        _ = makeMigrator(
            fixture, job: FakeLegacyJob(state: .loaded(enabled: true)), evidence: succeedingEvidence()
        ).migrate { statuses.append($0) }

        #expect(statuses.contains(LegacyMigrationPhase.checkingConsumers.progressDescription))
        #expect(statuses.contains(LegacyMigrationPhase.stoppingLegacy.progressDescription))
        #expect(statuses.contains(LegacyMigrationPhase.verifyingRefresh.progressDescription))
        #expect(statuses.contains("Fresh reading 3 of 3."))
        for phase in [
            LegacyMigrationPhase.idle, .preflighting, .capturingLegacy, .registeringAgent,
            .verifyingPublish, .succeeded, .rollingBack, .rolledBack, .blocked, .failed
        ] {
            #expect(!phase.progressDescription.isEmpty)
        }
    }

    /// Running the same migration twice must land in the same terminal state,
    /// byte for byte, or "did it already run?" becomes a judgement call.
    @Test func repeatedMigrationAndRollbackAreByteIdentical() throws {
        func terminalState(_ label: String, blocked: Bool) throws -> Data {
            let fixture = MigrationFixture(label)
            defer { fixture.cleanUp() }
            if blocked {
                fixture.writeAllReceipts(observedAt: Date(timeIntervalSince1970: 1))
            } else {
                fixture.writeAllReceipts()
            }
            let writer = RecordingStateWriter()
            let evidence = blocked ? FakeEvidence() : succeedingEvidence()
            _ = makeMigrator(
                fixture, job: FakeLegacyJob(state: .loaded(enabled: true)),
                evidence: evidence, writer: writer
            ).migrate()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(#require(writer.written.last))
        }

        for blocked in [true, false] {
            let first = try terminalState("repeat-a-\(blocked)", blocked: blocked)
            let second = try terminalState("repeat-b-\(blocked)", blocked: blocked)
            #expect(first == second)
        }
    }

    @Test func inventoryReportsPresenceWithoutOpeningAnything() throws {
        let fixture = MigrationFixture("inventory")
        defer { fixture.cleanUp() }
        let wrapper = fixture.root.appendingPathComponent("gradus_snapshot.sh")
        try Data("legacy".utf8).write(to: wrapper)
        let migrator = makeMigrator(fixture, job: FakeLegacyJob(state: .loaded(enabled: false)))

        let inventory = migrator.inventory(
            wrapperURL: wrapper,
            standaloneBridgeURL: fixture.root.appendingPathComponent("absent.app")
        )

        #expect(inventory.jobState == .loaded(enabled: false))
        #expect(inventory.wrapperPresent)
        #expect(!inventory.standaloneBridgePresent)
        #expect(inventory.needsMigration)
    }
}
