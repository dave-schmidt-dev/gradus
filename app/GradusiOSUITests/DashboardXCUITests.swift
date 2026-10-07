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
        case resetAlertsOff = "reset-alerts-off"
        case resetAlertsOn = "reset-alerts-on"
        case resetAlertsRequesting = "reset-alerts-requesting"
        case resetAlertsDenied = "reset-alerts-denied"
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
        let app = launch(.noAccount, cardColumns: 3)
        openSettings(in: app)

        XCTAssertFalse(app.buttons["explore-sample-settings"].exists)
        XCTAssertFalse(app.staticTexts["Explore Sample"].exists)
        let dashboardCardSize = app.staticTexts["Dashboard card size"]
        for _ in 0 ..< 6 where !dashboardCardSize.exists {
            app.swipeUp()
        }
        XCTAssertTrue(dashboardCardSize.exists)
        let automatic = app.switches["Automatic"]
        for _ in 0 ..< 6 where !automatic.exists {
            app.swipeUp()
        }
        XCTAssertTrue(automatic.waitForExistence(timeout: 5))
        XCTAssertEqual(automatic.value as? String, "1")
        assertStaticTextAfterScrolling(containing: "This screen only chooses providers", in: app)
        assertStaticTextAfterScrolling(containing: "iOS Home Screen widget gallery", in: app)
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

    func testResetAlertsOffExplainsIndependentControlsAndMobileDelivery() {
        let app = launch(.resetAlertsOff)
        openSettings(in: app)

        assertResetAlertSwitches(in: app, expectedValue: "0")
        openResetAlertInfo(in: app)
        XCTAssertTrue(
            staticText(containing: "Claude banked resets are unavailable to Gradus.", in: app)
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            staticText(containing: "On iPhone and iPad, delivery may wait until you open Gradus.", in: app)
                .waitForExistence(timeout: 3)
        )
    }

    func testResetAlertsOnShowsBothEnabled() {
        let app = launch(.resetAlertsOn)
        openSettings(in: app)

        assertResetAlertSwitches(in: app, expectedValue: "1")
        openResetAlertInfo(in: app)
        XCTAssertTrue(
            staticText(containing: "Claude banked resets are unavailable to Gradus.", in: app)
                .waitForExistence(timeout: 3)
        )
    }

    func testResetAlertsRequestingShowsProgressWithoutSystemPrompt() {
        let app = launch(.resetAlertsRequesting)
        openSettings(in: app)

        XCTAssertTrue(elementAfterScrolling(identifier: "reset-alerts-banked-toggle", in: app))
        XCTAssertTrue(elementAfterScrolling(identifier: "reset-alerts-refill-toggle", in: app))
        let banked = app.switches["reset-alerts-banked-toggle"]
        let refilled = app.switches["reset-alerts-refill-toggle"]
        XCTAssertTrue(banked.waitForExistence(timeout: 2))
        XCTAssertTrue(refilled.waitForExistence(timeout: 2))
        XCTAssertFalse(banked.isEnabled)
        XCTAssertFalse(refilled.isEnabled)
        XCTAssertTrue(elementAfterScrolling(identifier: "reset-alerts-permission-requesting", in: app))
        XCTAssertFalse(permissionAlert(in: app).exists)
    }

    func testResetAlertsDeniedShowsRecovery() {
        let app = launch(.resetAlertsDenied)
        openSettings(in: app)

        // Top to bottom: scrolling only moves down, so the toggles above the
        // permission row must be found before it.
        XCTAssertTrue(elementAfterScrolling(identifier: "reset-alerts-banked-toggle", in: app))
        XCTAssertTrue(elementAfterScrolling(identifier: "reset-alerts-refill-toggle", in: app))
        XCTAssertTrue(elementAfterScrolling(identifier: "reset-alerts-permission-denied", in: app))
        XCTAssertTrue(app.buttons["Open iOS Settings"].exists)
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

    private func launch(_ fixture: Fixture, cardColumns: Int? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["GRADUS_UITEST_FIXTURE"] = fixture.rawValue
        if let cardColumns {
            app.launchEnvironment["GRADUS_UITEST_CARD_COLUMNS"] = String(cardColumns)
        }
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

    private func assertStaticTextAfterScrolling(containing text: String, in app: XCUIApplication) {
        let element = staticText(containing: text, in: app)
        for _ in 0 ..< 4 where !element.exists {
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 2), "Missing Settings copy containing: \(text)")
    }

    private func openResetAlertInfo(in app: XCUIApplication) {
        XCTAssertTrue(elementAfterScrolling(identifier: "reset-alerts-info-button", in: app))
        element(identifier: "reset-alerts-info-button", in: app).tap()
    }

    private func assertResetAlertSwitches(in app: XCUIApplication, expectedValue: String) {
        for identifier in ["reset-alerts-banked-toggle", "reset-alerts-refill-toggle"] {
            XCTAssertTrue(elementAfterScrolling(identifier: identifier, in: app))
            XCTAssertEqual(app.switches[identifier].value as? String, expectedValue)
        }
    }

    private func permissionAlert(in app: XCUIApplication) -> XCUIElement {
        let appAlert = app.alerts.firstMatch
        if appAlert.waitForExistence(timeout: 2) {
            return appAlert
        }
        return XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
    }

    private func elementAfterScrolling(identifier: String, in app: XCUIApplication) -> Bool {
        let target = element(identifier: identifier, in: app)
        for _ in 0 ..< 6 where !target.exists {
            app.swipeUp()
        }
        return target.waitForExistence(timeout: 2)
    }

    private func element(identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
