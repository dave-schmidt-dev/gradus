import AppDiagnostics
import Darwin
import Foundation
@testable import GradusKit
import Testing

private func diagnosticsRoot() throws -> URL {
    guard let resolved = realpath(NSTemporaryDirectory(), nil) else { throw DiagnosticsError.io }
    defer { free(resolved) }
    let root = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    return root
}

private func diagnosticsConfiguration(_ root: URL, segmentBytes: Int = 4096,
                                      maxSegments: Int = 8) throws -> DiagnosticsConfiguration {
    let identity = try AppIdentity(project: "gradus", bundleID: "org.example.DiagnosticsTest",
                                   platform: .macos, appVersion: "1.0", build: "1")
    return try DiagnosticsConfiguration(identity: identity, directory: root.appendingPathComponent("spool"),
                                        segmentBytes: segmentBytes, maxSegments: maxSegments)
}

private func diagnosticsEvents(_ root: URL) throws -> [[String: Any]] {
    let spool = root.appendingPathComponent("spool")
    return try FileManager.default.contentsOfDirectory(at: spool, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "ndjson" }
        .flatMap { try Data(contentsOf: $0).split(separator: 10).map {
            try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] ?? [:]
        } }
}

@Test func diagnosticsOperationCountsOnlyExplicitAttemptsAndPreservesUUID() async throws {
    let root = try diagnosticsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let adapter = try GradusDiagnostics(configuration: diagnosticsConfiguration(root))
    let operation = await adapter.operation(.publish)
    #expect(operation.attemptCount == 0)
    operation.finish(.success) // A noop cannot manufacture meaningful progress.
    #expect(await adapter.status()?.queuedCount == 0)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("spool").path))
    operation.attempt()
    operation.attempt()
    operation.finish(.success, count: 2)
    #expect(operation.attemptCount == 2)
    #expect(await adapter.flush() == .persisted)
    #expect(await adapter.status()?.receiptTrust == .unbound)
    let events = try diagnosticsEvents(root)
    #expect(events.count == 3)
    #expect(Set(events.compactMap { $0["operation_id"] as? String }) == [operation.operationID.uuidString.lowercased()])
    #expect(events.allSatisfy { $0["origin"] as? String == "app" })
    #expect(events.allSatisfy { $0["install"] == nil && $0["candidate_id"] == nil })
    let attempts = events.compactMap { ($0["attributes"] as? [String: Any])?["attempt"] as? Int }
    #expect(attempts.sorted() == [1, 2, 2])
    _ = await adapter.shutdown()
}

@Test func diagnosticsSafeErrorsNeverStoreRawMessageDomainOrPath() async throws {
    let root = try diagnosticsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let adapter = try GradusDiagnostics(configuration: diagnosticsConfiguration(root))
    let operation = await adapter.operation(.fetch)
    operation.attempt()
    operation.finish(.failure, error: NSError(domain: "private.invalid.domain", code: 42,
                                              userInfo: [NSLocalizedDescriptionKey: "/private/payload-secret"]))
    #expect(await adapter.flush() == .persisted)
    let events = try diagnosticsEvents(root)
    let encoded = try JSONSerialization.data(withJSONObject: events)
    let text = try #require(String(data: encoded, encoding: .utf8))
    #expect(!text.contains("payload-secret"))
    #expect(!text.contains("private.invalid.domain"))
    let attributes = events.compactMap { $0["attributes"] as? [String: Any] }
    #expect(attributes.contains { $0["error_domain"] as? String == "unknown" && $0["error_code"] as? Int == 42 })
    _ = await adapter.shutdown()
}

@Test func diagnosticsCapacityRefusalPreservesKeylessBytesAndReportsLoss() async throws {
    let root = try diagnosticsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let adapter = try GradusDiagnostics(configuration: diagnosticsConfiguration(
        root,
        segmentBytes: 512,
        maxSegments: 1
    ))
    let operation = await adapter.operation(.fetch)
    operation.attempt()
    #expect(await adapter.flush() == .persisted)
    let before = try diagnosticsEvents(root)
    operation.attempt()
    #expect(await adapter.flush() == .refused)
    let status = await adapter.status()
    #expect(status?.uncertain == false)
    #expect((status?.refusedCount ?? 0) > 0)
    #expect(status?.receiptTrust == .unbound)
    #expect(try diagnosticsEvents(root).count == before.count)
    _ = await adapter.shutdown()
}

@Test func diagnosticsZoneAndPublishHaveIndependentLogicalOperations() async throws {
    let root = try diagnosticsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let adapter = try GradusDiagnostics(configuration: diagnosticsConfiguration(root))
    let zone = await adapter.operation(.zone)
    let publish = await adapter.operation(.publish)
    zone.attempt()
    zone.finish(.success)
    #expect(publish.attemptCount == 0)
    #expect(zone.operationID != publish.operationID)
    #expect(await adapter.flush() == .persisted)
    let events = try diagnosticsEvents(root)
    #expect(events.allSatisfy { $0["kind"] as? String == "storage" })
    _ = await adapter.shutdown()
}

@Test func diagnosticsCancellationRemainsCancelledAndAdmissionIsDistinct() async throws {
    let root = try diagnosticsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let adapter = try GradusDiagnostics(configuration: diagnosticsConfiguration(root))
    let operation = await adapter.operation(.fetch)
    // Isolate terminal cancellation admission; attempt-event emission is covered by the operation-count test.
    operation.attempt(report: false)
    operation.finish(.failure, error: CancellationError())
    #expect(await adapter.lastAdmission == .admitted)
    #expect(await adapter.flush() == .persisted)
    let events = try diagnosticsEvents(root)
    #expect(events.contains { ($0["attributes"] as? [String: Any])?["outcome"] as? String == "cancelled" })
    #expect(events.allSatisfy { ($0["attributes"] as? [String: Any])?["error_domain"] == nil
            && ($0["attributes"] as? [String: Any])?["error_code"] == nil
    })
    _ = await adapter.shutdown()
}

@Test func diagnosticsDefaultAndDirectFixtureNeverInitializeNormalStorage() async {
    let adapter = GradusDiagnostics()
    _ = await adapter.operation(.fetch)
    let adapterUnavailable: DiagnosticsUnavailable? = await adapter.unavailable
    let adapterStatus: DiagnosticsStatus? = await adapter.status()
    #expect(adapterUnavailable == .isolatedRun)
    #expect(adapterStatus == nil)
    let direct = GradusDiagnostics(environment: ["GRADUS_UI_TEST_MENU_FIXTURE": "1"], isTestRun: false)
    _ = await direct.operation(.fetch)
    let directUnavailable: DiagnosticsUnavailable? = await direct.unavailable
    let directStatus: DiagnosticsStatus? = await direct.status()
    #expect(directUnavailable == .isolatedRun)
    #expect(directStatus == nil)
}

@Test func diagnosticsURLCancellationAndTerminalAreOnceOnly() async throws {
    let root = try diagnosticsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let adapter = try GradusDiagnostics(configuration: diagnosticsConfiguration(root))
    let operation = await adapter.operation(.fetch)
    operation.attempt()
    operation.finish(.failure, error: URLError(.cancelled))
    operation.finish(.success)
    operation.attempt()
    #expect(operation.attemptCount == 1)
    #expect(await adapter.flush() == .persisted)
    let events = try diagnosticsEvents(root)
    #expect(events.count == 2)
    #expect(events.filter { ($0["attributes"] as? [String: Any])?["outcome"] != nil }.count == 1)
    #expect(events.contains { ($0["attributes"] as? [String: Any])?["outcome"] as? String == "cancelled" })
    #expect(events.allSatisfy { ($0["attributes"] as? [String: Any])?["error_domain"] == nil
            && ($0["attributes"] as? [String: Any])?["error_code"] == nil
    })
    _ = await adapter.shutdown()
}

private actor DiagnosticsSuspendedFetch {
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func fetch() async {
        started = true
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        waiter?.resume(); waiter = nil
    }
}

@Test func diagnosticsAttemptIsObservableWhileFetchRemainsSuspended() async throws {
    let root = try diagnosticsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let adapter = try GradusDiagnostics(configuration: diagnosticsConfiguration(root))
    let operation = await adapter.operation(.fetch)
    let fetcher = DiagnosticsSuspendedFetch()
    let task = Task {
        operation.attempt()
        await fetcher.fetch()
        operation.finish(.success)
    }
    while await !(fetcher.started) {
        await Task.yield()
    }
    #expect(await adapter.flush() == .persisted)
    let before = try diagnosticsEvents(root)
    #expect(before.count == 1)
    #expect((before.first?["attributes"] as? [String: Any])?["outcome"] == nil)
    await fetcher.release()
    await task.value
    #expect(await adapter.flush() == .persisted)
    #expect(try diagnosticsEvents(root).count == 2)
    _ = await adapter.shutdown()
}

@Test func diagnosticsSuppressedZoneStillCountsCallsAndFailureReports() async throws {
    let root = try diagnosticsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let adapter = try GradusDiagnostics(configuration: diagnosticsConfiguration(root))
    for _ in 0 ..< 10 {
        let operation = await adapter.operation(.zone)
        operation.attempt(report: false)
        operation.finish(.success, report: false)
    }
    #expect(await adapter.actualAttemptCount == 10)
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("spool").path))
    let failed = await adapter.operation(.zone)
    failed.attempt(report: false)
    failed.finish(.failure, error: URLError(.notConnectedToInternet))
    #expect(await adapter.actualAttemptCount == 11)
    #expect(await adapter.flush() == .persisted)
    #expect(try diagnosticsEvents(root).count == 1)
    _ = await adapter.shutdown()
}

/// Test observer counts only a signal; production warning contains no supplied content.
private final class DiagnosticsWarningCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func observed() {
        lock.lock(); value += 1; lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

@Test func diagnosticsClosedAdmissionWarnsExactlyOnceAndIsolationIsSilent() async throws {
    let root = try diagnosticsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let observer = DiagnosticsWarningCounter()
    let adapter = try GradusDiagnostics(configuration: diagnosticsConfiguration(root),
                                        warningObserver: { observer.observed() })
    let first = await adapter.operation(.fetch)
    _ = await adapter.shutdown()
    first.attempt()
    first.finish(.failure)
    let second = await adapter.operation(.publish)
    second.attempt()
    #expect(await adapter.refusedAdmissions == 3)
    #expect(await adapter.lastAdmission == .closed)
    #expect(observer.count == 1)
    let isolated = GradusDiagnostics(environment: [:], isTestRun: true,
                                     warningObserver: { observer.observed() })
    _ = await isolated.operation(.fetch)
    #expect(await isolated.unavailable == .isolatedRun)
    #expect(observer.count == 1)
}

@Test func diagnosticsExpectedWaitingIsInformationalUnknown() async throws {
    let root = try diagnosticsRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let adapter = try GradusDiagnostics(configuration: diagnosticsConfiguration(root))
    let operation = await adapter.operation(.fetch)
    operation.attempt()
    operation.finish(.unknown)
    #expect(await adapter.flush() == .persisted)
    let events = try diagnosticsEvents(root)
    #expect(events.allSatisfy { $0["severity"] as? String == "INFO" })
    #expect(events.contains { ($0["attributes"] as? [String: Any])?["outcome"] as? String == "unknown" })
    #expect(events.allSatisfy { ($0["attributes"] as? [String: Any])?["error_domain"] == nil })
    _ = await adapter.shutdown()
}
