import Foundation
import Testing

@testable import GradusMac

/// Covers the file sink, which is the half of `GradusLog` that can be wrong
/// quietly.
///
/// The unified-log half either appears in `log show` or does not, and the
/// release checklist reads it directly. The file has a size cap, a rotation
/// order and a level floor, and every one of those failing looks identical
/// from the outside: a log that is present and merely missing something.
@Suite("Gradus log file")
struct GradusLogTests {
    /// Each test gets its own directory so rotation counts can't bleed between
    /// them, and so nothing here touches the real `~/Library/Logs/Gradus`.
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GradusLogTests-\(UUID().uuidString)", isDirectory: true)
        return url
    }

    private func contents(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    @Test func writesLevelCategoryAndMessageOnOneLine() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = GradusLogFile(directory: directory)
        file.append(level: .warning, category: "publish", message: "save failed for Codex")
        file.flush()

        let written = contents(file.fileURL)
        #expect(written.contains("WARNING"))
        #expect(written.contains("[publish]"))
        #expect(written.contains("save failed for Codex"))
        #expect(written.hasSuffix("\n"))
        // One event is one line: a multi-line entry would break `grep` on this
        // file, which is the only way anyone will read it.
        #expect(written.split(separator: "\n").count == 1)
    }

    /// The directory does not exist on a fresh install, and the first thing the
    /// app ever logs may be the failure it most needs to record.
    @Test func createsItsDirectoryOnFirstWrite() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!FileManager.default.fileExists(atPath: directory.path))

        let file = GradusLogFile(directory: directory)
        file.append(level: .error, category: "publish", message: "first line")
        file.flush()

        #expect(FileManager.default.fileExists(atPath: file.fileURL.path))
        #expect(contents(file.fileURL).contains("first line"))
    }

    @Test func appendsRatherThanTruncating() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = GradusLogFile(directory: directory)
        file.append(level: .warning, category: "app", message: "first")
        file.append(level: .warning, category: "app", message: "second")
        file.flush()

        let written = contents(file.fileURL)
        #expect(written.contains("first"))
        #expect(written.contains("second"))
        #expect(written.split(separator: "\n").count == 2)
    }

    /// Rotation happens *before* the write that would cross the cap, so the cap
    /// is a real bound. Rotating afterwards would let the file exceed it by one
    /// line every cycle, which on a long-running menu bar app is the difference
    /// between a bound and a suggestion.
    @Test func rotatesBeforeExceedingTheCap() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Calibrate the cap against a real line instead of guessing its length.
        // The first version of this test assumed ~70 bytes when the timestamp
        // format actually yields 46, so four lines never reached the cap, no
        // rotation happened, and the test was asserting nothing about the
        // behavior it is named for.
        let probeDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: probeDirectory) }
        let probe = GradusLogFile(directory: probeDirectory)
        probe.append(level: .warning, category: "publish", message: "line 0")
        probe.flush()
        let lineBytes =
            ((try? FileManager.default.attributesOfItem(atPath: probe.fileURL.path))?[.size]
                as? NSNumber)?.intValue ?? 0
        #expect(lineBytes > 0, "probe wrote nothing; the rest of this test would be vacuous")

        // Room for two lines but not three, so the third rotates. Every message
        // below is the same length, which keeps that exact.
        let cap = lineBytes * 2 + 1
        let file = GradusLogFile(directory: directory, maxBytes: cap, keptRotations: 2)
        for index in 1...4 {
            file.append(level: .warning, category: "publish", message: "line \(index)")
        }
        file.flush()

        let rotated = directory.appendingPathComponent("GradusMac.log.1")
        #expect(FileManager.default.fileExists(atPath: rotated.path))

        let liveSize =
            (try? FileManager.default.attributesOfItem(atPath: file.fileURL.path))?[.size]
            as? NSNumber
        #expect((liveSize?.intValue ?? .max) <= cap)

        // Nothing is lost in the move: every line is still somewhere.
        let everything = contents(file.fileURL) + contents(rotated)
        for index in 1...4 {
            #expect(everything.contains("line \(index)"))
        }
    }

    /// Rotation must drop the oldest file rather than fail. `moveItem` onto an
    /// existing path throws, so a rotation that forgot to remove `.2` first
    /// would silently stop rotating once it filled up — the failure would look
    /// like a log that had simply stopped growing.
    @Test func keepsOnlyTheConfiguredNumberOfRotations() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = GradusLogFile(directory: directory, maxBytes: 120, keptRotations: 2)
        for index in 1...12 {
            file.append(level: .warning, category: "publish", message: "line \(index)")
        }
        file.flush()

        let manager = FileManager.default
        #expect(manager.fileExists(atPath: directory.appendingPathComponent("GradusMac.log").path))
        #expect(manager.fileExists(atPath: directory.appendingPathComponent("GradusMac.log.1").path))
        #expect(manager.fileExists(atPath: directory.appendingPathComponent("GradusMac.log.2").path))
        #expect(!manager.fileExists(atPath: directory.appendingPathComponent("GradusMac.log.3").path))

        let all = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(all.count == 3, "expected live + 2 rotations, found \(all.sorted())")
    }

    // MARK: - level floor

    @Test func levelsAreOrderedBySeverity() {
        #expect(GradusLogLevel.debug < .info)
        #expect(GradusLogLevel.info < .notice)
        #expect(GradusLogLevel.notice < .warning)
        #expect(GradusLogLevel.warning < .error)
    }

    /// AGENTS.md: WARNING+ always, DEBUG when debug logging is on. A GUI app
    /// has no `--debug` flag, so the switch is a user default.
    @Test func defaultFloorIsWarningAndTheDebugDefaultLowersIt() {
        let key = "GradusDebugLogging"
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        #expect(GradusLogFile.minimumLevel == .warning)

        defaults.set(true, forKey: key)
        #expect(GradusLogFile.minimumLevel == .debug)
    }
}
