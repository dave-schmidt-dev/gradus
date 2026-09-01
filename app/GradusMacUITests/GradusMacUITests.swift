import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import XCTest

final class GradusMacUITests: XCTestCase {
    // Read from the extensions in `GradusMacUITestsAccessibility.swift` and
    // `GradusMacUITestsBackgroundAgent.swift`, so the fixture plumbing below
    // cannot be file-private.
    static let axWindowNumberAttribute = "AXWindowNumber"
    static var requestedAccessibilityTrust = false

    enum HarnessError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message): message
            }
        }
    }

    struct RunningFixture {
        let process: Process
        let pid: pid_t
        let executablePath: String
        let application: AXUIElement
    }

    var runningFixture: RunningFixture?

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        defer { runningFixture = nil }
        try terminateRunningFixture()
        try super.tearDownWithError()
    }

    func testMenuFixtureShowsWindowsPlacesExhaustedLastAndOpensSettings() throws {
        let fixture = try launchMenuFixture()
        let menuWindow = try waitForElement(
            descendingFrom: fixture.application,
            role: kAXWindowRole as String,
            title: "Gradus UI Test Menu",
            timeout: 10
        )

        let codex = try requiredElement(
            descendingFrom: menuWindow, role: kAXStaticTextRole as String, title: "Codex"
        )
        let cursor = try requiredElement(
            descendingFrom: menuWindow, role: kAXStaticTextRole as String, title: "Cursor"
        )
        _ = try requiredElement(descendingFrom: menuWindow, title: "5 Hour")
        _ = try requiredElement(descendingFrom: menuWindow, title: "Weekly")
        _ = try requiredElement(descendingFrom: menuWindow, title: "Exhausted")
        XCTAssertLessThan(try position(of: codex).y, try position(of: cursor).y)
        try attachWindowScreenshot(
            window: menuWindow,
            ownerPID: fixture.pid,
            title: "Gradus UI Test Menu",
            name: "Gradus menu fixture"
        )

        let settings = try requiredElement(
            descendingFrom: menuWindow, role: kAXButtonRole as String, title: "Settings…"
        )
        try performPress(on: settings)
        let settingsWindow = try waitForElement(
            descendingFrom: fixture.application,
            role: kAXWindowRole as String,
            title: "Gradus Settings",
            timeout: 5
        )
        XCTAssertNil(findElement(descendingFrom: settingsWindow, title: "Enable iCloud Sync"))
        XCTAssertNil(findElement(descendingFrom: settingsWindow, title: "iCloud Sync"))
        try attachWindowScreenshot(
            window: settingsWindow,
            ownerPID: fixture.pid,
            title: "Gradus Settings",
            name: "Gradus Settings window"
        )
    }

    func testMenuFixtureExposesRequiredICloudStatusAndLoginControl() throws {
        let fixture = try launchMenuFixture()
        let menuWindow = try waitForElement(
            descendingFrom: fixture.application,
            role: kAXWindowRole as String,
            title: "Gradus UI Test Menu",
            timeout: 10
        )
        let login = try requiredElement(
            descendingFrom: menuWindow,
            role: kAXCheckBoxRole as String,
            title: "Open Menu at Login"
        )
        // The two controls are deliberately distinct: this one is the main app.
        XCTAssertNil(findElement(descendingFrom: menuWindow, title: "Launch at Login"))
        XCTAssertEqual(attribute(login, kAXEnabledAttribute as String) as Bool?, true)
        XCTAssertNil(findElement(descendingFrom: menuWindow, title: "Enable iCloud Sync"))
    }

    func launchMenuFixture(agentStateFile: URL? = nil) throws -> RunningFixture {
        XCTAssertNil(runningFixture, "Each scenario must own exactly one retained GradusMac PID")
        let executableURL = try builtDebugExecutableURL()
        let executablePath = canonicalPath(executableURL.path)

        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "XCTestBundlePath")
        environment.removeValue(forKey: "XCTestConfigurationFilePath")
        environment["GRADUS_DISABLE_PIPELINE"] = "1"
        environment["GRADUS_UI_TEST_MENU_FIXTURE"] = "1"
        if let agentStateFile {
            // Registration state the harness owns outright. Nothing in this
            // suite may register a real launch agent: `SMAppService.register()`
            // mutates this machine and an approved agent outlives the run.
            environment["GRADUS_UI_TEST_AGENT_STATE"] = agentStateFile.path
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--ui-test-menu-fixture"]
        process.environment = environment
        process.currentDirectoryURL = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        print("STATUS GradusMacAXHarness launching exact Debug executable: \(executablePath)")
        try process.run()
        let pid = process.processIdentifier
        guard pid > 0 else {
            throw HarnessError.failed("Process did not retain a valid GradusMac PID")
        }

        let observedPath = try waitForProcessPath(pid: pid, timeout: 3)
        guard observedPath == executablePath else {
            process.terminate()
            throw HarnessError.failed(
                "Retained PID \(pid) path \(observedPath) did not equal built executable \(executablePath)"
            )
        }

        let fixture = RunningFixture(
            process: process,
            pid: pid,
            executablePath: executablePath,
            application: AXUIElementCreateApplication(pid)
        )
        runningFixture = fixture
        print("STATUS GradusMacAXHarness retained pid=\(pid) identity=verified")
        return fixture
    }

    private func builtDebugExecutableURL() throws -> URL {
        var directory = Bundle(for: type(of: self)).bundleURL
        while directory.path != "/" {
            if directory.lastPathComponent == "Debug" {
                let candidate = directory
                    .appendingPathComponent("GradusMac.app", isDirectory: true)
                    .appendingPathComponent("Contents/MacOS/GradusMac", isDirectory: false)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate.resolvingSymlinksInPath().standardizedFileURL
                }
            }
            directory.deleteLastPathComponent()
        }
        throw HarnessError.failed(
            "Could not resolve built Debug GradusMac from \(Bundle(for: type(of: self)).bundleURL.path)"
        )
    }

    private func waitForProcessPath(pid: pid_t, timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let path = processPath(pid: pid) {
                return path
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        throw HarnessError.failed("proc_pidpath did not resolve retained PID \(pid)")
    }

    private func processPath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = buffer.withUnsafeMutableBytes { bytes in
            proc_pidpath(pid, bytes.baseAddress, UInt32(bytes.count))
        }
        guard count > 0 else { return nil }
        return canonicalPath(String(cString: buffer))
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    func terminateRunningFixture() throws {
        guard let fixture = runningFixture else { return }
        guard fixture.process.processIdentifier == fixture.pid else {
            throw HarnessError.failed("Retained Process changed PID before teardown")
        }

        if fixture.process.isRunning {
            guard processPath(pid: fixture.pid) == fixture.executablePath else {
                throw HarnessError.failed(
                    "Refusing to terminate PID \(fixture.pid) after its executable identity changed"
                )
            }
            print("STATUS GradusMacAXHarness terminating retained pid=\(fixture.pid)")
            fixture.process.terminate()
        }

        let gracefulDeadline = Date().addingTimeInterval(2)
        while fixture.process.isRunning, Date() < gracefulDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if fixture.process.isRunning {
            guard processPath(pid: fixture.pid) == fixture.executablePath else {
                throw HarnessError.failed(
                    "Refusing forced termination after PID \(fixture.pid) identity changed"
                )
            }
            XCTAssertEqual(kill(fixture.pid, SIGKILL), 0, "Could not stop retained GradusMac PID")
        }

        let forcedDeadline = Date().addingTimeInterval(2)
        while fixture.process.isRunning, Date() < forcedDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertFalse(fixture.process.isRunning, "Retained GradusMac PID survived teardown")
    }
}
