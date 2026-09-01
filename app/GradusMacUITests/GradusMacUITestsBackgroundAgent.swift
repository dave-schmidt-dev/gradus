import ApplicationServices
import Foundation
import XCTest

/// Background-refresh scenarios live beside the menu scenarios rather than in
/// `GradusMacUITests.swift`: the class is already at its body-length limit, and
/// this is the only group whose fixture outlives the app under test.
extension GradusMacUITests {
    func testRegisteredBackgroundAgentSurvivesQuittingGradusMac() throws {
        let stateFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("gradus-ui-test-agent-\(UUID().uuidString).state")
        try "enabled".write(to: stateFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: stateFile) }

        let fixture = try launchMenuFixture(agentStateFile: stateFile)
        let menuWindow = try waitForElement(
            descendingFrom: fixture.application,
            role: kAXWindowRole as String,
            title: "Gradus UI Test Menu",
            timeout: 10
        )
        try assertBackgroundRefreshSettings(fixture: fixture, menuWindow: menuWindow)

        try terminateRunningFixture()
        runningFixture = nil

        // The whole point of a background agent: quitting the menu app must not
        // take the refresh with it.
        let afterQuit = try String(contentsOf: stateFile, encoding: .utf8)
        XCTAssertEqual(afterQuit.trimmingCharacters(in: .whitespacesAndNewlines), "enabled")

        let relaunched = try launchMenuFixture(agentStateFile: stateFile)
        let relaunchedWindow = try waitForElement(
            descendingFrom: relaunched.application,
            role: kAXWindowRole as String,
            title: "Gradus UI Test Menu",
            timeout: 10
        )
        // A registered agent means the menu has no background-refresh warning
        // to raise, only the ordinary staleness of the fixture's own payload.
        XCTAssertNil(
            findElement(descendingFrom: relaunchedWindow, title: "Background refresh is off")
        )
    }

    /// Split out of the scenario above only to keep one screen's worth of
    /// assertions per function; it is not reused.
    private func assertBackgroundRefreshSettings(
        fixture: RunningFixture,
        menuWindow: AXUIElement
    ) throws {
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
        let monitor = try requiredElement(
            descendingFrom: settingsWindow,
            role: kAXCheckBoxRole as String,
            identifier: "settings-monitor-in-background"
        )
        XCTAssertEqual(attribute(monitor, kAXValueAttribute as String) as Int?, 1)
        // The two controls are separate switches, not one relabelled control,
        // and both labels are present for a reader who cannot see the layout.
        let login = try requiredElement(
            descendingFrom: settingsWindow,
            role: kAXCheckBoxRole as String,
            identifier: "settings-open-menu-at-login"
        )
        XCTAssertNotEqual(monitor, login)
        for label in ["Monitor in Background", "Open Menu at Login"] {
            XCTAssertNotNil(
                findElement(descendingFrom: settingsWindow, title: label),
                "Settings must label \(label)"
            )
        }
        // Health is stated, and it never claims current data from a stale
        // snapshot just because the agent is registered.
        let headline = try requiredElement(
            descendingFrom: settingsWindow, identifier: "settings-agent-headline"
        )
        XCTAssertEqual(
            attribute(headline, kAXValueAttribute as String) as String?,
            "Usage data is out of date"
        )
        _ = try requiredElement(
            descendingFrom: settingsWindow, identifier: "settings-agent-explanation"
        )
        try attachWindowScreenshot(
            window: settingsWindow,
            ownerPID: fixture.pid,
            title: "Gradus Settings",
            name: "Gradus background refresh settings"
        )
    }
}
