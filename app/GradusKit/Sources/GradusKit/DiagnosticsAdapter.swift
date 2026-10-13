import AppDiagnostics
import CloudKit
import Darwin
import Foundation
import os

/// Content-free availability; never substitutes invented app identity.
public enum DiagnosticsUnavailable: String, Sendable {
    case identity, isolatedRun, storage, invalidEvent
}

public enum DiagnosticsAction: Sendable {
    case publish, fetch, zone
}

public enum DiagnosticsCompletion: Sendable {
    case success, failure, cancelled, timeout, unknown
}

private struct DiagnosticsAdmissionSnapshot: Sendable {
    let last: AdmissionResult?
    let refused: Int
    let invalid: Int
    let attempts: Int
}

/// Shared admission counters use one short lock; storage remains solely SDK-owned.
private final class DiagnosticsAdmissions: @unchecked Sendable {
    private let lock = NSLock()
    private var last: AdmissionResult?
    private var refused = 0
    private var invalid = 0
    private var attempts = 0
    private var warned = false
    private let warningObserver: @Sendable () -> Void
    private static let availabilityLog = Logger(subsystem: "com.zerodelta.gradus", category: "diagnostics")

    init(warningObserver: @escaping @Sendable () -> Void = {
        availabilityLog.warning("Diagnostics capture unavailable or admission refused")
    }) {
        self.warningObserver = warningObserver
    }

    /// One fixed warning per adapter. Invoke the observer outside the counter lock.
    func warnOnce() {
        lock.lock()
        let shouldWarn = !warned
        warned = true
        lock.unlock()
        if shouldWarn {
            warningObserver()
        }
    }

    var snapshot: DiagnosticsAdmissionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return DiagnosticsAdmissionSnapshot(last: last, refused: refused, invalid: invalid, attempts: attempts)
    }

    func attempted() {
        lock.lock()
        attempts += 1
        lock.unlock()
    }

    func capture(_ result: AdmissionResult?) {
        lock.lock()
        let refusedAdmission: Bool
        if let result {
            last = result
            refusedAdmission = result == .queueFull || result == .failed || result == .closed
        } else {
            invalid += 1
            refusedAdmission = true
        }
        if refusedAdmission {
            refused += 1
        }
        lock.unlock()
        if refusedAdmission {
            warnOnce()
        }
    }
}

/// Immutable SDK reference plus lock-owned counter/terminal state. This handle performs
/// bounded synchronous admission only; its unchecked Sendable invariant excludes disk I/O.
public final class GradusDiagnosticsOperation: @unchecked Sendable {
    public let operationID = UUID()
    private let logger: DiagnosticsLogger?
    private let admissions: DiagnosticsAdmissions
    private let action: DiagnosticsAction
    private let lock = NSLock()
    private var attempts = 0
    private var finished = false

    fileprivate init(logger: DiagnosticsLogger?, admissions: DiagnosticsAdmissions, action: DiagnosticsAction) {
        self.logger = logger
        self.admissions = admissions
        self.action = action
    }

    public var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    /// Call immediately before invoking transport. No await, filesystem access or actor hop.
    public func attempt(report: Bool = true) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        attempts += 1
        let current = attempts
        lock.unlock()
        admissions.attempted()
        if report {
            emit(attempt: current, completion: nil)
        }
    }

    /// Exactly one terminal per logical operation. Suppressed steady-state zone calls
    /// still increment actual invocation counters, and their failures always report.
    public func finish(_ completion: DiagnosticsCompletion, count: Int = 0,
                       error: Error? = nil, report: Bool = true) {
        lock.lock()
        guard attempts > 0, !finished else { lock.unlock(); return }
        finished = true
        let current = attempts
        lock.unlock()
        guard report else { return }
        let value = error as NSError?
        let cancelled = error is CancellationError || (error as? CKError)?.code == .operationCancelled
            || (value?.domain == NSURLErrorDomain && value?.code == URLError.cancelled.rawValue)
        emit(attempt: current, completion: cancelled ? .cancelled : completion, count: count, error: error)
    }

    private func emit(attempt: Int, completion: DiagnosticsCompletion?, count: Int = 0, error: Error? = nil) {
        guard let logger else { return }
        guard let event = diagnosticsEvent(attempt: attempt, completion: completion, count: count, error: error) else {
            admissions.capture(nil)
            return
        }
        admissions.capture(logger.record(event))
    }

    private func diagnosticsEvent(attempt: Int,
                                  completion: DiagnosticsCompletion?, count: Int, error: Error?) -> DiagnosticEvent? {
        let component: Component = action == .zone ? .storage : .sync
        let kind: EventKind = action == .zone ? .storage : .network
        var attributes: [Attribute] = [.subsystem(component), .attempt(Int64(attempt))]
        var severity = Severity.info
        if let completion {
            let outcome: Outcome
            switch completion {
            case .success: outcome = .success
            case .unknown: outcome = .unknown
            case .failure: outcome = .failure; severity = .warn
            case .cancelled: outcome = .cancelled
            case .timeout: outcome = .timeout; severity = .error
            }
            attributes += [.outcome(outcome), .count(Int64(count))]
        }
        if let error, completion != .cancelled {
            attributes += diagnosticsErrorAttributes(error)
        }
        return try? DiagnosticEvent(severity: severity, kind: kind, attributes: attributes,
                                    operationID: operationID, component: component)
    }
}

private func diagnosticsErrorAttributes(_ error: Error) -> [Attribute] {
    let value = error as NSError
    let domain: ErrorDomain = switch value.domain {
    case "CKErrorDomain": .cloudKit
    case NSURLErrorDomain: .url
    case NSPOSIXErrorDomain: .posix
    case NSCocoaErrorDomain: .cocoa
    case NSOSStatusErrorDomain: .osStatus
    default: .unknown
    }
    var attributes: [Attribute] = [.errorDomain(domain)]
    if (-2_147_483_648 ... 2_147_483_647).contains(value.code) {
        attributes.append(.errorCode(Int64(value.code)))
    }
    return attributes
}

/// Lazy private keyless capture. Filesystem setup and canonicalization run on this actor,
/// never during app construction or synchronous caller admission. Extensions have no hooks.
public actor GradusDiagnostics {
    public static let shared = GradusDiagnostics()
    private var logger: DiagnosticsLogger?
    private let injected: DiagnosticsConfiguration?
    private let environment: [String: String]
    private let isTestRun: Bool
    private var initialized = false
    public private(set) var unavailable: DiagnosticsUnavailable?
    private let admissions: DiagnosticsAdmissions
    public var refusedAdmissions: Int {
        admissions.snapshot.refused
    }

    public var lastAdmission: AdmissionResult? {
        admissions.snapshot.last
    }

    public var invalidEventCount: Int {
        admissions.snapshot.invalid
    }

    public var actualAttemptCount: Int {
        admissions.snapshot.attempts
    }

    public init(configuration: DiagnosticsConfiguration? = nil) {
        admissions = DiagnosticsAdmissions()
        injected = configuration
        environment = ProcessInfo.processInfo.environment
        isTestRun = ProcessInfo.processInfo.processName == "swiftpm-testing-helper"
            || NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
            || CommandLine.arguments.first.map { $0.contains(".xctest/") || $0.hasSuffix(".xctest") } == true
    }

    init(configuration: DiagnosticsConfiguration, warningObserver: @escaping @Sendable () -> Void) {
        admissions = DiagnosticsAdmissions(warningObserver: warningObserver)
        injected = configuration
        environment = [:]
        isTestRun = false
    }

    init(environment: [String: String], isTestRun: Bool,
         warningObserver: @escaping @Sendable () -> Void = {}) {
        admissions = DiagnosticsAdmissions(warningObserver: warningObserver)
        injected = nil
        self.environment = environment
        self.isTestRun = isTestRun
    }

    /// Prepare off the main actor before entering a lifecycle gate or invoking transport.
    public func operation(_ action: DiagnosticsAction) -> GradusDiagnosticsOperation {
        initialize()
        return GradusDiagnosticsOperation(logger: logger, admissions: admissions, action: action)
    }

    private func initialize() {
        guard !initialized else { return }
        initialized = true
        if let injected {
            logger = DiagnosticsLogger(configuration: injected)
            return
        }
        guard environment["GRADUS_UI_TEST_MENU_FIXTURE"] != "1",
              !isTestRun,
              environment["XCTestConfigurationFilePath"] == nil,
              environment["XCTestBundlePath"] == nil else {
            unavailable = .isolatedRun
            return
        }
        guard let identity = Self.productionIdentity() else {
            unavailable = .identity
            admissions.warnOnce()
            return
        }
        do {
            guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                         in: .userDomainMask).first else {
                unavailable = .storage
                admissions.warnOnce()
                initialized = false
                return
            }
            let parent = support.appendingPathComponent("GradusDiagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard let resolved = realpath(parent.path, nil) else {
                unavailable = .storage
                admissions.warnOnce()
                initialized = false
                return
            }
            defer { free(resolved) }
            let directory = URL(fileURLWithPath: String(cString: resolved))
                .appendingPathComponent("spool", isDirectory: true)
            let verbose = environment["GRADUS_DEBUG_LOGGING"] != nil
                || UserDefaults.standard.bool(forKey: "GradusDebugLogging")
            unavailable = nil
            logger = try DiagnosticsLogger(configuration: DiagnosticsConfiguration(
                identity: identity, directory: directory, includeVerbose: verbose
            ))
        } catch {
            unavailable = .storage
            admissions.warnOnce()
            initialized = false
        }
    }

    private static func productionIdentity() -> AppIdentity? {
        let bundle = Bundle.main
        guard let bundleID = bundle.bundleIdentifier,
              let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return nil }
        #if os(macOS)
            let platform = Platform.macos
        #else
            let platform = Platform.ios
        #endif
        return try? AppIdentity(project: "gradus", bundleID: bundleID,
                                platform: platform, appVersion: version, build: build)
    }

    /// Artifact failure is separate from acknowledged CloudKit business success.
    public func artifactFailure(_ error: Error) {
        initialize()
        guard let logger else { return }
        let attributes: [Attribute] = [.code(.storageFailure), .subsystem(.storage), .outcome(.failure)]
            + diagnosticsErrorAttributes(error)
        guard let event = try? DiagnosticEvent(severity: .warn, kind: .storage,
                                               attributes: attributes, component: .storage) else {
            admissions.capture(nil)
            return
        }
        admissions.capture(logger.record(event))
    }

    /// Admission is not persistence; callers can inspect loss, capacity, uncertainty and trust.
    public func status() -> DiagnosticsStatus? {
        logger?.status
    }

    public func flush() async -> PersistenceResult? {
        guard let logger else { return nil }
        return await logger.flush()
    }

    public func sealedSegments() async throws -> [SegmentDescriptor] {
        guard let logger else { return [] }
        return try await logger.sealedSegments()
    }

    public func shutdown() async -> PersistenceResult? {
        guard let logger else { return nil }
        return await logger.shutdown()
    }
}
