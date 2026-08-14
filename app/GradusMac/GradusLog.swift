import Foundation
import OSLog

/// GradusMac's logging, with two sinks on purpose.
///
/// `Logger` (the unified log) is primary. It can be read on one timeline with
/// `cloudd`'s own records using the same `log show` invocation
/// `RELEASE_CHECKLIST.md` step 3 already runs, which is the point: the publish
/// story is only complete when the app's *intent* and CloudKit's *outcome* sit
/// side by side. Until now only the second half existed, so a release could
/// confirm successful saves and had no way to see a failed one at all.
///
/// A rotating file is the second sink, because unified-log entries age out of
/// the system store on a schedule nobody controls. A release being audited two
/// weeks later cannot go back and ask what the publisher did.
///
/// ## Why not the repo's `.logs/`
///
/// AGENTS.md asks for a gitignored `.logs/<project>.log`. That is right for the
/// Python tooling, which runs from the checkout, and wrong for this app.
/// GradusMac ships from `/Applications` and the repo lives under `~/Documents`,
/// so a repo-relative log would make a released app request a Documents TCC
/// grant on first launch in order to write into one developer's working copy —
/// the same consent prompt that has already stalled the Mac test gate. Decided
/// with David on 2026-08-06; `~/Library/Logs/` is the platform's answer for a
/// non-sandboxed app and needs no grant. The deviation is recorded in README.md
/// so a later pass doesn't "restore" the convention and reintroduce the prompt.
enum GradusLog {
    /// Matches the app's bundle identifier so `log show --predicate
    /// 'subsystem == "com.zerodelta.gradus"'` finds these next to CloudKit's.
    static let subsystem = "com.zerodelta.gradus"

    /// Publishing to CloudKit: what was saved, what was suppressed by content
    /// hash, and — the reason this file exists — what failed.
    static let publish = GradusLogger(category: "publish")

    /// Reading and decoding the producer's snapshot file.
    static let snapshot = GradusLogger(category: "snapshot")

    /// App lifecycle, settings, and the status item.
    static let app = GradusLogger(category: "app")
}

/// Severity, ordered so the file sink can apply a floor.
///
/// Deliberately not `OSLogType`: that type is not `Comparable` and its
/// `.default` case sits in an order that reads wrong here (`.info` is *less*
/// severe than `.default`). Five explicit steps mapped once, at the boundary.
enum GradusLogLevel: Int, Comparable, Sendable {
    case debug = 0
    case info = 1
    case notice = 2
    case warning = 3
    case error = 4

    static func < (lhs: GradusLogLevel, rhs: GradusLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var osLogType: OSLogType {
        switch self {
        case .debug: .debug
        case .info: .info
        case .notice: .default
        case .warning: .error
        case .error: .fault
        }
    }

    /// Fixed width so the file's level column stays aligned and greppable.
    var fileLabel: String {
        switch self {
        case .debug: "DEBUG  "
        case .info: "INFO   "
        case .notice: "NOTICE "
        case .warning: "WARNING"
        case .error: "ERROR  "
        }
    }
}

/// One category's logger, writing to the unified log and the rotating file.
///
/// A single facade rather than exposing `Logger` alongside a file API: two ways
/// to log is two chances for the interesting line to reach only one sink.
struct GradusLogger: Sendable {
    private let logger: Logger
    private let category: String

    init(category: String) {
        self.category = category
        logger = Logger(subsystem: GradusLog.subsystem, category: category)
    }

    func debug(_ message: String) {
        emit(.debug, message)
    }

    func info(_ message: String) {
        emit(.info, message)
    }

    func notice(_ message: String) {
        emit(.notice, message)
    }

    func warning(_ message: String) {
        emit(.warning, message)
    }

    func error(_ message: String) {
        emit(.error, message)
    }

    private func emit(_ level: GradusLogLevel, _ message: String) {
        // `.public` is explicit and deliberate. os_log redacts interpolated
        // strings by default, which would render every one of these as
        // `<private>` in the exact `log show` output the release checklist
        // reads. Nothing credential-bearing is logged here — INV-7 already
        // forbids the publisher source from referencing a credential path, and
        // these lines carry provider names, counts and CloudKit error codes.
        logger.log(level: level.osLogType, "\(message, privacy: .public)")

        // The level floor applies to the *file* only. The unified log gets
        // every line: `info` and `notice` are where the publish timeline lives,
        // and dropping them to match the file's floor would leave the release
        // checklist reading the same one-sided evidence it reads today. os_log
        // does its own filtering far more cheaply than a file write.
        guard level >= GradusLogFile.minimumLevel else { return }
        GradusLogFile.shared.append(level: level, category: category, message: message)
    }
}

/// The rotating file sink behind `GradusLogger`.
///
/// Serialized on its own queue and failure-tolerant throughout: logging must
/// never be the reason the app misbehaves, so every IO error here is swallowed
/// rather than propagated. The unified log still has the line in that case.
final class GradusLogFile: @unchecked Sendable {
    static let shared = GradusLogFile()

    /// WARNING and above always; everything when debug logging is switched on,
    /// per AGENTS.md. A GUI app has no `--debug` flag, so the switch is the
    /// `GradusDebugLogging` user default (`defaults write com.zerodelta.gradus
    /// GradusDebugLogging -bool YES`) or the `GRADUS_DEBUG_LOGGING` environment
    /// variable for a run from the terminal.
    static var minimumLevel: GradusLogLevel {
        if ProcessInfo.processInfo.environment["GRADUS_DEBUG_LOGGING"] != nil {
            return .debug
        }
        if UserDefaults.standard.bool(forKey: "GradusDebugLogging") {
            return .debug
        }
        return .warning
    }

    /// Small on purpose. These are event lines, not a transcript, and a menu
    /// bar app that runs for weeks should not accumulate an unbounded file in
    /// a directory the user never looks at.
    static let defaultMaxBytes = 512 * 1024
    static let defaultKeptRotations = 2

    /// Redirects the shared sink. Deliberately *not* `GRADUS_LOG_PATH`, which
    /// the Python side already uses for a log **file**: this one names a
    /// **directory**, so honoring the same variable would send the Mac app's
    /// rotation set into a path its owner meant as a single file. Two
    /// different shapes get two different names.
    static let directoryOverrideKey = "GRADUS_MAC_LOG_DIR"

    /// Where the shared sink writes when no directory is injected.
    ///
    /// - Parameters are injectable only so the tests can exercise all three
    ///   branches. Inside a test run the honest answer is always the redirect,
    ///   so without injection two of the three would be untestable.
    static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isTestRun: Bool = GradusLogFile.isRunningUnderTest
    ) -> URL {
        if let override = environment[directoryOverrideKey], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if isTestRun {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("gradus-mac-test-logs", isDirectory: true)
        }
        // `homeDirectoryForCurrentUser`, not `NSHomeDirectory()`. INV-7 gives
        // the snapshot path exactly one construction site, and
        // `snapshotPathHasExactlyOneInjectionPoint` enforces it by counting
        // `NSHomeDirectory()` call sites across GradusMac. A log directory is
        // not a snapshot path, so it is not what that invariant guards — but
        // "unify these two ways of finding $HOME" is a tempting tidy-up that
        // would fail INV-7 from a file with nothing to do with INV-7.
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Gradus", isDirectory: true)
    }

    /// True when this process is hosting a test bundle.
    ///
    /// The Mac test bundle is *hosted*: it is injected into a real GradusMac
    /// process, so `GradusLogFile.shared` in a test is literally the shipping
    /// app's sink — the same reason `PublisherViewModel` has to inject
    /// `UserDefaults`. Without this, the suite writes fabricated failures
    /// ("save failed for A: CKError 26") into the exact file
    /// `RELEASE_CHECKLIST.md` step 3 tells a reviewer to read as evidence
    /// that a release published cleanly. That happened on 2026-08-06, the
    /// first run after the file sink landed.
    ///
    /// Checked at runtime rather than by setting the variable above in the
    /// scheme: the schemes here are generated by XcodeGen, so scheme-level
    /// wiring is one `xcodegen generate` away from quietly disappearing while
    /// still looking configured. This cannot be un-wired by regenerating.
    static var isRunningUnderTest: Bool {
        if NSClassFromString("XCTestCase") != nil {
            return true
        }
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }

    private let directory: URL
    private let maxBytes: Int
    private let keptRotations: Int
    private let queue = DispatchQueue(label: "com.zerodelta.gradus.log", qos: .utility)
    private let formatter: ISO8601DateFormatter

    /// - Parameters:
    ///   - directory: defaults to `defaultDirectory()`. Injectable so tests
    ///     exercise real rotation against a temp directory rather than a mock,
    ///     which cannot fail the way a filesystem does.
    ///   - maxBytes: injectable for the same reason — a test that had to write
    ///     512 KB to observe one rotation would be slow enough that nobody runs
    ///     it, and rotation is the part most likely to be wrong.
    init(
        directory: URL? = nil,
        maxBytes: Int = GradusLogFile.defaultMaxBytes,
        keptRotations: Int = GradusLogFile.defaultKeptRotations
    ) {
        self.directory = directory ?? GradusLogFile.defaultDirectory()
        self.maxBytes = maxBytes
        self.keptRotations = keptRotations
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        self.formatter = formatter
    }

    var fileURL: URL {
        directory.appendingPathComponent("GradusMac.log")
    }

    func append(level: GradusLogLevel, category: String, message: String, at date: Date = Date()) {
        let line = "\(formatter.string(from: date)) \(level.fileLabel) [\(category)] \(message)\n"
        queue.async { [weak self] in
            self?.write(line)
        }
    }

    /// Synchronous drain, for tests: `append` is async, so without this a test
    /// would race the queue and assert against a file that has not been
    /// written yet.
    func flush() {
        queue.sync {}
    }

    private func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)

        rotateIfNeeded(adding: data.count, manager: manager)

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// Rotate *before* the write that would exceed the cap, not after, so the
    /// cap is a real bound rather than one the file is allowed to cross once.
    private func rotateIfNeeded(adding incoming: Int, manager: FileManager) {
        let attributes = try? manager.attributesOfItem(atPath: fileURL.path)
        let currentSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard currentSize > 0, currentSize + incoming > maxBytes else { return }

        // Drop the oldest first; renaming onto an existing path fails.
        try? manager.removeItem(at: rotatedURL(keptRotations))
        for index in stride(from: keptRotations - 1, through: 1, by: -1) {
            try? manager.moveItem(at: rotatedURL(index), to: rotatedURL(index + 1))
        }
        try? manager.moveItem(at: fileURL, to: rotatedURL(1))
    }

    private func rotatedURL(_ index: Int) -> URL {
        directory.appendingPathComponent("GradusMac.log.\(index)")
    }
}
