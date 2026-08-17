import XCTest

final class GradusMacUITests: XCTestCase {
    func testMenuFixtureShowsWindowsPlacesExhaustedLastAndOpensSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-menu-fixture"]
        app.launchEnvironment["GRADUS_DISABLE_PIPELINE"] = "1"
        app.launchEnvironment["GRADUS_UI_TEST_MENU_FIXTURE"] = "1"
        app.launch()

        let fixture = app.windows["Gradus UI Test Menu"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 10))

        let codex = fixture.staticTexts["Codex"]
        let cursor = fixture.staticTexts["Cursor"]
        XCTAssertTrue(codex.exists)
        XCTAssertTrue(cursor.exists)
        XCTAssertTrue(fixture.staticTexts["5 Hour"].exists)
        XCTAssertTrue(fixture.staticTexts["Weekly"].exists)
        XCTAssertTrue(fixture.staticTexts["Exhausted"].exists)
        XCTAssertLessThan(codex.frame.minY, cursor.frame.minY)

        let settings = fixture.buttons["Settings…"]
        XCTAssertTrue(settings.exists)
        settings.click()
        let settingsWindow = app.windows["Gradus Settings"]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        XCTAssertFalse(settingsWindow.checkBoxes["Enable iCloud Sync"].exists)
        XCTAssertFalse(settingsWindow.checkBoxes["iCloud Sync"].exists)
    }

    func testMenuFixtureExposesRequiredICloudStatusAndLoginControl() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-menu-fixture"]
        app.launchEnvironment["GRADUS_DISABLE_PIPELINE"] = "1"
        app.launchEnvironment["GRADUS_UI_TEST_MENU_FIXTURE"] = "1"
        app.launch()

        let fixture = app.windows["Gradus UI Test Menu"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 10))

        let login = fixture.checkBoxes["Launch at Login"]
        XCTAssertTrue(login.exists)
        XCTAssertTrue(login.isEnabled)
        XCTAssertFalse(fixture.checkBoxes["Enable iCloud Sync"].exists)
    }
}
