import Foundation
import GradusKit
@testable import GradusMac
import Testing

@MainActor
private final class JoinFixture {
    let directory: URL
    let snapshotURL: URL
    let defaults: UserDefaults
    var displayed: [String] = []
    var committed: [(String, Int?)] = []
    var evaluations: [ResetEvaluation] = []
    var progress: [String?] = []
    var clock = Date(timeIntervalSince1970: 1_800_000_000)

    static let generation = "11111111-1111-4111-8111-111111111111"
    static let timeZero = "2026-09-24T00:00:00Z"
    static let timeOne = "2026-09-24T00:01:00Z"
    static let timeTwo = "2026-09-24T00:02:00Z"

    init(defaults: UserDefaults) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gradus-join-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        snapshotURL = directory.appendingPathComponent("snapshot-v2.json")
        self.defaults = defaults
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func pipeline(_ mode: ResetObservationPipeline.ProducerMode = .installed) -> ResetObservationPipeline {
        ResetObservationPipeline(
            snapshotURL: snapshotURL,
            mode: mode,
            defaults: defaults,
            deviceID: "22222222-2222-4222-8222-222222222222",
            waitInterval: 15,
            now: { [weak self] in self?.clock ?? .distantPast },
            onDisplay: { [weak self] in self?.displayed.append($0.updatedAt) },
            onEvaluation: { [weak self] in self?.evaluations.append($0) },
            onCommit: { [weak self] payload, sidecar in
                self?.committed.append((payload.updatedAt, sidecar?.count))
            },
            onProgress: { [weak self] in self?.progress.append($0) }
        )
    }

    func writeSnapshot(
        _ token: String,
        observedAt: String? = nil,
        probeAttemptedAt: String? = nil,
        percentLeft: Double? = nil,
        resetISO: String? = nil
    ) throws {
        let windows: [[String: Any]] = percentLeft.map { percent in
            [
                "id": "weekly", "percent_left": percent,
                "reset_iso": resetISO ?? Self.timeTwo
            ]
        }.map { [$0] } ?? []
        let provider: [String: Any] = [
            "name": "Codex", "ok": true, "windows": windows, "data": [:],
            "observed_at": observedAt ?? token,
            "probe_attempted_at": probeAttemptedAt ?? token
        ]
        try writeJSON(
            ["schema_version": 2, "updated_at": token, "providers": [provider]],
            to: snapshotURL
        )
    }

    func writeSidecar(_ token: String, observedAt: String? = nil, count: Int) throws {
        try writeJSON(
            [
                "schema_version": 1, "count": count, "generation": Self.generation,
                "snapshot_updated_at": token, "observed_at": observedAt ?? token
            ],
            to: BankedObservation.fileURL(for: snapshotURL)
        )
    }

    func writeStatus(_ phase: String, token: String? = nil, sequence: Int = 1) throws {
        var object: [String: Any] = [
            "schemaVersion": 1, "phase": phase, "health": "normal",
            "sequence": sequence, "updatedAt": Self.timeTwo
        ]
        if let token {
            object["committedSnapshotUpdatedAt"] = token
        }
        try writeJSON(object, to: BackgroundAgentStatusObserver.statusFileURL(for: snapshotURL))
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

private func joinDefaults(_ test: String) throws -> (String, UserDefaults) {
    let suite = "com.zerodelta.gradus.mac.tests.reset-observation.\(test)"
    let defaults = try #require(scratchDefaults(suite))
    return (suite, defaults)
}

@Suite("ResetObservationPipelineTests")
@MainActor
struct ResetObservationPipelineTests {
    @Test func sidecarBeforeTerminalStatusJoinsExactlyOnce() throws {
        let (suite, defaults) = try joinDefaults(#function)
        defer { removeScratchDefaultsSuite(suite, using: defaults) }
        let fixture = try JoinFixture(defaults: defaults)
        let join = fixture.pipeline()
        try fixture.writeStatus("producerWaiting")
        try fixture.writeSnapshot(JoinFixture.timeOne)
        join.snapshotChanged()
        #expect(fixture.displayed == [JoinFixture.timeOne])
        #expect(fixture.committed.isEmpty)

        try fixture.writeSidecar(JoinFixture.timeOne, count: 2)
        join.sidecarChanged()
        #expect(fixture.committed.isEmpty)
        try fixture.writeStatus("succeeded", token: JoinFixture.timeOne, sequence: 2)
        join.statusChanged()
        join.sidecarChanged()
        #expect(fixture.committed.count == 1)
        #expect(fixture.committed.first?.1 == 2)
    }

    @Test func terminalStatusBeforeSidecarAddsCountWithoutSecondUsageEvaluation() throws {
        let (suite, defaults) = try joinDefaults(#function)
        defer { removeScratchDefaultsSuite(suite, using: defaults) }
        let fixture = try JoinFixture(defaults: defaults)
        let join = fixture.pipeline()
        try fixture.writeSnapshot(JoinFixture.timeOne)
        join.snapshotChanged()
        try fixture.writeStatus("succeeded", token: JoinFixture.timeOne)
        join.statusChanged()
        #expect(fixture.committed.count == 1)
        #expect(fixture.committed.first?.1 == nil)

        try fixture.writeSidecar(JoinFixture.timeOne, count: 3)
        join.sidecarChanged()
        #expect(fixture.committed.count == 2)
        #expect(fixture.committed.last?.1 == 3)
        #expect(fixture.evaluations.count == 2)
        let everyEvaluationHasNoAlerts = fixture.evaluations.allSatisfy(\.alerts.isEmpty)
        #expect(everyEvaluationHasNoAlerts)
    }

    @Test func failureAndRollbackDiscardPendingEdge() throws {
        let (suite, defaults) = try joinDefaults(#function)
        defer { removeScratchDefaultsSuite(suite, using: defaults) }
        let fixture = try JoinFixture(defaults: defaults)
        let join = fixture.pipeline()
        try fixture.writeStatus("producerWaiting")
        try fixture.writeSnapshot(JoinFixture.timeOne)
        join.snapshotChanged()
        try fixture.writeSidecar(JoinFixture.timeOne, count: 4)
        try fixture.writeStatus("restoringSnapshot", sequence: 2)
        join.statusChanged()
        try fixture.writeSnapshot(JoinFixture.timeZero)
        try fixture.writeStatus("failed", sequence: 3)
        join.statusChanged()
        #expect(fixture.displayed == [JoinFixture.timeOne, JoinFixture.timeZero])
        #expect(fixture.committed.isEmpty)
        #expect(fixture.evaluations.isEmpty)
    }

    @Test func mismatchedOrOldStatusNeverCommitsInstalledSnapshot() throws {
        let (suite, defaults) = try joinDefaults(#function)
        defer { removeScratchDefaultsSuite(suite, using: defaults) }
        let fixture = try JoinFixture(defaults: defaults)
        let join = fixture.pipeline()
        try fixture.writeSnapshot(JoinFixture.timeTwo)
        try fixture.writeStatus("succeeded", token: JoinFixture.timeOne)
        join.snapshotChanged()
        #expect(fixture.committed.isEmpty)
        try fixture.writeStatus("succeeded", sequence: 2)
        join.statusChanged()
        #expect(fixture.committed.isEmpty)
        try fixture.writeStatus("succeeded", token: JoinFixture.timeTwo, sequence: 3)
        join.statusChanged()
        #expect(fixture.committed.map(\.0) == [JoinFixture.timeTwo])
    }

    @Test func externalTimeoutCommitsOnceAndLateSidecarAugments() throws {
        let (suite, defaults) = try joinDefaults(#function)
        defer { removeScratchDefaultsSuite(suite, using: defaults) }
        let fixture = try JoinFixture(defaults: defaults)
        let join = fixture.pipeline(.external)
        try fixture.writeSnapshot(JoinFixture.timeOne)
        join.snapshotChanged()
        #expect(fixture.committed.isEmpty)
        #expect(fixture.progress.contains { $0 != nil })
        fixture.clock.addTimeInterval(16)
        join.checkTimeout()
        #expect(fixture.committed.count == 1)
        #expect(fixture.committed.first?.1 == nil)
        let lastProgressEventWasClear = fixture.progress.last.map { $0 == nil } == true
        #expect(lastProgressEventWasClear)
        try fixture.writeSidecar(JoinFixture.timeOne, count: 1)
        join.sidecarChanged()
        #expect(fixture.committed.count == 2)
        #expect(fixture.committed.last?.1 == 1)
    }

    @Test func supersededSnapshotAndLateOlderCountPreserveNewUsage() throws {
        let (suite, defaults) = try joinDefaults(#function)
        defer { removeScratchDefaultsSuite(suite, using: defaults) }
        let fixture = try JoinFixture(defaults: defaults)
        let join = fixture.pipeline()
        try fixture.writeStatus("producerWaiting")
        try fixture.writeSnapshot(JoinFixture.timeOne)
        join.snapshotChanged()
        try fixture.writeSnapshot(JoinFixture.timeTwo)
        join.snapshotChanged()
        try fixture.writeStatus("succeeded", token: JoinFixture.timeOne, sequence: 2)
        join.statusChanged()
        #expect(fixture.committed.isEmpty)
        try fixture.writeStatus("succeeded", token: JoinFixture.timeTwo, sequence: 3)
        join.statusChanged()
        #expect(fixture.committed.map(\.0) == [JoinFixture.timeTwo])
        try fixture.writeSidecar(JoinFixture.timeOne, count: 5)
        join.sidecarChanged()
        #expect(fixture.committed.map(\.0) == [JoinFixture.timeTwo])
    }

    @Test func cadenceDeferredSuccessDoesNotConsumeRefillEdge() throws {
        let (suite, defaults) = try joinDefaults(#function)
        defer { removeScratchDefaultsSuite(suite, using: defaults) }
        let fixture = try JoinFixture(defaults: defaults)
        let join = fixture.pipeline()
        try fixture.writeSnapshot(JoinFixture.timeZero, percentLeft: 40, resetISO: JoinFixture.timeOne)
        try fixture.writeStatus("succeeded", token: JoinFixture.timeZero)
        join.snapshotChanged()
        #expect(fixture.evaluations.last?.alerts.isEmpty == true)

        // The cached entry is `ok`, but the producer did not probe it at T1.
        try fixture.writeSnapshot(
            JoinFixture.timeOne, observedAt: JoinFixture.timeZero,
            probeAttemptedAt: JoinFixture.timeZero, percentLeft: 100, resetISO: JoinFixture.timeTwo
        )
        try fixture.writeStatus("succeeded", token: JoinFixture.timeOne, sequence: 2)
        join.snapshotChanged()
        #expect(fixture.evaluations.last?.alerts.isEmpty == true)

        try fixture.writeSnapshot(JoinFixture.timeTwo, percentLeft: 100, resetISO: JoinFixture.timeTwo)
        try fixture.writeStatus("succeeded", token: JoinFixture.timeTwo, sequence: 3)
        join.snapshotChanged()
        #expect(fixture.evaluations.last?.alerts.contains(
            .usageRefill(providerName: "Codex", windowID: "weekly")
        ) == true)
    }

    @Test func matchingSidecarGrantSurvivesNonfreshCodexUsage() throws {
        let (suite, defaults) = try joinDefaults(#function)
        defer { removeScratchDefaultsSuite(suite, using: defaults) }
        let fixture = try JoinFixture(defaults: defaults)
        let join = fixture.pipeline()
        try fixture.writeSnapshot(JoinFixture.timeZero)
        try fixture.writeSidecar(JoinFixture.timeZero, count: 1)
        try fixture.writeStatus("succeeded", token: JoinFixture.timeZero)
        join.snapshotChanged()
        #expect(fixture.evaluations.last?.alerts.isEmpty == true)

        // Usage is carried, but this matching sidecar is a newer count source.
        try fixture.writeSnapshot(
            JoinFixture.timeOne, probeAttemptedAt: JoinFixture.timeZero
        )
        try fixture.writeSidecar(JoinFixture.timeOne, count: 2)
        try fixture.writeStatus("succeeded", token: JoinFixture.timeOne, sequence: 2)
        join.snapshotChanged()
        #expect(fixture.evaluations.last?.alerts == [
            .bankedGrant(increase: 1, currentCount: 2)
        ])

        join.snapshotChanged()
        join.sidecarChanged()
        join.statusChanged()
        #expect(fixture.evaluations.flatMap(\.alerts).filter {
            if case .bankedGrant = $0 {
                return true
            }
            return false
        }.count == 1)
    }

    @Test func replayAfterICloudConfirmationPublishesWithoutReevaluating() throws {
        let (suite, defaults) = try joinDefaults(#function)
        defer { removeScratchDefaultsSuite(suite, using: defaults) }
        let fixture = try JoinFixture(defaults: defaults)
        let join = fixture.pipeline()
        try fixture.writeSnapshot(JoinFixture.timeOne)
        try fixture.writeSidecar(JoinFixture.timeOne, count: 2)
        try fixture.writeStatus("succeeded", token: JoinFixture.timeOne)
        join.snapshotChanged()
        #expect(fixture.committed.count == 1)
        #expect(fixture.evaluations.count == 1)

        join.publishCurrentIfCommitted()
        #expect(fixture.committed.count == 2)
        #expect(fixture.committed.last?.1 == 2)
        #expect(fixture.evaluations.count == 1)
    }
}
