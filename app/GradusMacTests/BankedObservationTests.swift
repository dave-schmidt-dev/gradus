import Foundation
@testable import GradusMac
import Testing

private func stagedWriterFixtureURL() throws -> URL {
    let path = try #require(ProcessInfo.processInfo.environment["GRADUS_BANKED_FIXTURE_PATH"]
        .flatMap { $0.hasPrefix("/") ? $0 : nil })
    return URL(fileURLWithPath: path)
}

@Suite("Banked observation public sidecar")
struct BankedObservationTests {
    @Test func parsesRealPythonWriterFixture() throws {
        let observation = try #require(BankedObservation.parse(Data(contentsOf: stagedWriterFixtureURL())))
        #expect(observation.count == 3)
        #expect(observation.generation == "8a596d59-294c-4efc-81a3-0caab767abbb")
        #expect(observation.snapshotUpdatedAt == "2026-09-23T10:00:00-04:00")
        #expect(observation.observedAt == "2026-09-23T10:00:00-04:00")
        #expect(observation.matches(
            snapshotUpdatedAt: "2026-09-23T10:00:00-04:00",
            codexObservedAt: "2026-09-23T10:00:00-04:00"
        ))
        #expect(!observation.matches(
            snapshotUpdatedAt: "2026-09-23T10:01:00-04:00",
            codexObservedAt: "2026-09-23T10:00:00-04:00"
        ))
    }

    @MainActor
    @Test func derivesOnlyPublicSiblingPathsFromInjectedSnapshot() {
        let snapshot = URL(fileURLWithPath: "/tmp/GradusTests/Installed/snapshot-v2.json")
        #expect(BankedObservation.fileURL(for: snapshot).path
            == "/tmp/GradusTests/Installed/banked-observation-v1.json")
        #expect(BackgroundAgentStatusObserver.statusFileURL(for: snapshot).path
            == "/tmp/GradusTests/Installed/agent-status.json")
        let canonical = PublishPipeline.defaultSnapshotPath
        #expect(canonical.path.hasSuffix(
            "/Library/Application Support/Gradus/Installed/snapshot-v2.json"
        ))
        #expect(BankedObservation.fileURL(for: canonical).deletingLastPathComponent()
            == canonical.deletingLastPathComponent())
    }

    @Test func rejectsMissingExtraWrongTypedAndUnboundedFields() throws {
        let fixture = try Data(contentsOf: stagedWriterFixtureURL())
        let original = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        func check(_ edit: (inout [String: Any]) -> Void) throws {
            var object = original
            edit(&object)
            let data = try JSONSerialization.data(withJSONObject: object)
            #expect(BankedObservation.parse(data) == nil)
        }

        try check { $0.removeValue(forKey: "count") }
        try check { $0["account_id"] = "private" }
        try check { $0["schema_version"] = 2 }
        try check { $0["schema_version"] = true }
        try check { $0["count"] = true }
        try check { $0["count"] = "3" }
        try check { $0["count"] = -1 }
        try check { $0["count"] = 1_000_001 }
        try check { $0["count"] = 1.5 }
        try check { $0["generation"] = "not-a-uuid" }
        try check { $0["generation"] = "8A596D59-294C-4EFC-81A3-0CAAB767ABBB" }
        #expect(BankedObservation.parse(Data(repeating: 0x20, count: 4097)) == nil)
    }

    @Test func rejectsNaiveInvalidAndStaleTimestamps() throws {
        let fixture = try Data(contentsOf: stagedWriterFixtureURL())
        let original = try #require(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        func check(_ key: String, _ value: String) throws {
            var object = original
            object[key] = value
            #expect(try BankedObservation.parse(JSONSerialization.data(withJSONObject: object)) == nil)
        }

        try check("observed_at", "2026-09-23T10:00:00")
        try check("observed_at", "yesterday")
        try check("observed_at", "2026-13-23T10:00:00-04:00")
        try check("observed_at", "2026-02-30T10:00:00-04:00")
        try check("observed_at", "2026-09-23T10:00:00+25:00")
        try check("observed_at", "2026-09-23T10:01:00-04:00")
        try check("observed_at", "2026-09-23T09:44:59-04:00")
        try check("snapshot_updated_at", "2026-09-23T10:00:00")
    }
}

@Suite("Banked observation directory watcher")
@MainActor
struct BankedObservationWatcherTests {
    @Test func reportsAtomicReplacementAndRemovalButFiltersSiblingWrites() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GradusBankedWatcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = directory.appendingPathComponent("snapshot-v2.json")
        var counts: [Int?] = []
        let watcher = BankedObservationWatcher(
            snapshotFileURL: snapshot,
            retryDelay: 0.02,
            coalescingDelay: 0.001
        ) { counts.append(BankedObservation.read(from: BankedObservation.fileURL(for: snapshot))?.count) }
        watcher.start()
        #expect(await eventually { counts.count == 1 })
        #expect(counts == [nil])

        let fixture = try stagedWriterFixtureURL()
        let sidecar = watcher.fileURL
        try Data(contentsOf: fixture).write(to: sidecar, options: .atomic)
        #expect(await eventually { counts.contains(3) })
        let countAfterFirstWrite = counts.count

        try Data("sibling".utf8).write(to: directory.appendingPathComponent("other.json"), options: .atomic)
        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(counts.count == countAfterFirstWrite)

        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        object["count"] = 4
        try JSONSerialization.data(withJSONObject: object).write(to: sidecar, options: .atomic)
        #expect(await eventually { counts.contains(4) })

        let countBeforeRemoval = counts.count
        try FileManager.default.removeItem(at: sidecar)
        #expect(await eventually { counts.count > countBeforeRemoval && counts.last == .some(nil) })
        watcher.stop()
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0 ..< 100 {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
}
