import XCTest

/// Lifecycle and alert workflows are launched from deterministic, test-only
/// fixtures. They run unchanged on the dedicated iPhone and iPad destinations
/// in the Phase 3 gate; no fixture calls CloudKit or asks iOS for permission.
final class DashboardXCUITests: XCTestCase {
    private enum Fixture: String {
        case freshAccountDiscovery = "fresh-account-discovery"
        case legacyAwaitingConfirmation = "legacy-awaiting-confirmation"
        case temporaryRetry = "temporary-retry"
        case noAccount = "no-account"
        case restricted
        case warningAlertsOff = "warning-alerts-off"
        case warningAlertsRequesting = "warning-alerts-requesting"
        case warningAlertsDenied = "warning-alerts-denied"
    }

    func testFreshAccountDiscoveryShowsLiveProgress() {
        let app = launch(.freshAccountDiscovery)

        XCTAssertTrue(
            staticText(containing: "Checking your iCloud account. Your cached data remains available.", in: app)
                .waitForExistence(timeout: 5)
        )
        assertExploreSampleControl(in: app)
    }

    func testLegacyConfirmationContinuesIntoAccountDiscovery() {
        let app = launch(.legacyAwaitingConfirmation)

        XCTAssertTrue(app.staticTexts["Continue with iCloud"].waitForExistence(timeout: 5))
        let continueButton = app.buttons["Continue"]
        XCTAssertTrue(continueButton.exists)
        continueButton.tap()
        XCTAssertTrue(element(identifier: "icloud-account-discovery-status", in: app).waitForExistence(timeout: 5))
    }

    func testTemporaryFailureOffersDeterministicRetry() {
        let app = launch(.temporaryRetry)

        XCTAssertTrue(app.staticTexts["Try Again"].waitForExistence(timeout: 5))
        let retry = app.buttons["Try Again"]
        XCTAssertTrue(retry.exists)
        retry.tap()
        XCTAssertTrue(app.staticTexts["Try Again"].waitForExistence(timeout: 5))
    }

    func testNoAccountAndRestrictedRecoveryRemainInApp() {
        for fixture in [Fixture.noAccount, .restricted] {
            let app = launch(fixture)
            let retry = app.buttons["Try Again"]
            XCTAssertTrue(retry.waitForExistence(timeout: 5), "Missing Try Again for \(fixture.rawValue)")
            XCTAssertFalse(app.buttons["Open Settings"].exists)
            XCTAssertFalse(app.buttons["Open iOS Settings"].exists)
            retry.tap()
            XCTAssertTrue(retry.waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    func testExploreSampleIsReachableFromRequiredICloudRecovery() {
        let app = launch(.noAccount)

        assertExploreSampleControl(in: app)
        app.buttons["explore-sample"].tap()
        XCTAssertTrue(staticText(containing: "Local-only sample data", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["sample-data-exit"].exists)
    }

    func testWarningAlertsOffIsExplicitAndSeparateFromICloud() {
        let app = launch(.warningAlertsOff)
        openSettings(in: app)

        let warningAlerts = app.switches["warning-alerts-toggle"]
        XCTAssertTrue(warningAlerts.waitForExistence(timeout: 5))
        XCTAssertEqual(warningAlerts.value as? String, "0")
        XCTAssertFalse(app.switches["Enable iCloud Sync"].exists)
        XCTAssertFalse(app.switches["iCloud Sync"].exists)
        XCTAssertTrue(staticText(containing: "iCloud syncing is unaffected", in: app).exists)
    }

    func testNormalSettingsExplainsWidgetSizingAndOmitsSampleEntry() {
        let app = launch(.noAccount)
        openSettings(in: app)

        XCTAssertFalse(app.buttons["explore-sample-settings"].exists)
        XCTAssertFalse(app.staticTexts["Explore Sample"].exists)
        XCTAssertTrue(app.staticTexts["Dashboard card size"].exists)
        XCTAssertTrue(staticText(containing: "automatic on this device", in: app).exists)
        XCTAssertTrue(staticText(containing: "This screen only chooses providers", in: app).exists)
        XCTAssertTrue(staticText(containing: "iOS Home Screen widget gallery", in: app).exists)
    }

    func testWarningAlertsRequestingShowsProgressWithoutSystemPrompt() {
        let app = launch(.warningAlertsRequesting)
        openSettings(in: app)

        XCTAssertTrue(app.staticTexts["Requesting warning-alert permission…"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["Waiting for your iOS notification choice. iCloud syncing continues either way."].exists
        )
        XCTAssertFalse(app.alerts.firstMatch.exists)
    }

    func testSystemDeniedWarningAlertsExplainRecoveryWithoutChangingICloud() {
        let app = launch(.warningAlertsDenied)
        openSettings(in: app)

        XCTAssertTrue(
            app.staticTexts["iOS is not allowing Gradus to show warning alerts. iCloud syncing is unaffected."]
                .waitForExistence(timeout: 5)
        )
        let settings = app.buttons["Open iOS Settings"]
        XCTAssertTrue(settings.exists)
        XCTAssertTrue(app.switches["warning-alerts-toggle"].exists)
    }

    func testWidgetProvidersCanBeExcludedWithoutHidingDashboardData() {
        let app = launch(.noAccount)
        app.buttons["explore-sample"].tap()
        XCTAssertTrue(staticText(containing: "Local-only sample data", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Sample Cursor"].exists)
        openSettings(in: app)

        let widgetProviders = app.buttons["widget-providers-button"]
        for _ in 0 ..< 4 where !widgetProviders.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(widgetProviders.waitForExistence(timeout: 5))
        XCTAssertTrue(widgetProviders.isHittable)
        widgetProviders.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["Widget Providers"].waitForExistence(timeout: 5))

        let cursor = app.switches["widget-provider-sample-cursor-toggle"]
        XCTAssertTrue(cursor.waitForExistence(timeout: 5))
        XCTAssertEqual(cursor.value as? String, "1")
        cursor.tap()
        XCTAssertEqual(cursor.value as? String, "0")

        let closeWidgetProviders = app.buttons["widget-providers-close"]
        XCTAssertTrue(closeWidgetProviders.waitForExistence(timeout: 5))
        closeWidgetProviders.tap()
        XCTAssertFalse(app.staticTexts["Widget Providers"].waitForExistence(timeout: 2))

        let closeSettings = app.buttons["xmark"]
        XCTAssertTrue(closeSettings.waitForExistence(timeout: 5))
        closeSettings.tap()
        XCTAssertTrue(app.staticTexts["Sample Cursor"].waitForExistence(timeout: 5))
    }

    private func launch(_ fixture: Fixture) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["GRADUS_UITEST_FIXTURE"] = fixture.rawValue
        app.launch()
        return app
    }

    private func openSettings(in app: XCUIApplication) {
        let settings = app.buttons["settings-button"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
    }

    private func assertExploreSampleControl(in app: XCUIApplication) {
        let sample = app.buttons["explore-sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        XCTAssertEqual(sample.label, "Explore Sample")
    }

    private func staticText(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func element(identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
