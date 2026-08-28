import XCTest

/// Captures one deterministic, action-complete walkthrough state per run.
final class WalkthroughCaptureXCUITests: XCTestCase {
    func testWalkthroughCapture() throws {
        let env = ProcessInfo.processInfo.environment
        let route = try XCTUnwrap(env["GRADUS_WALKTHROUGH_FIXTURE"])
        let marker = try XCTUnwrap(env["GRADUS_WALKTHROUGH_MARKER"])
        let destination = try XCTUnwrap(env["GRADUS_WALKTHROUGH_SCREENSHOT"])
        let app = XCUIApplication()
        app.launchArguments += ["-AppleInterfaceStyle", "Dark"]
        app.launchEnvironment["GRADUS_UITEST_FIXTURE"] = appFixture(for: route)
        if route == "settings-automatic-result" || route == "settings-card-size-result" {
            app.launchEnvironment["GRADUS_UITEST_CARD_COLUMNS"] = "3"
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        prepare(route: route, in: app)
        let expected = markerElement(route: route, marker: marker, app: app)
        XCTAssertTrue(expected.waitForExistence(timeout: 30), "Missing capture marker \(marker)")
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: destination))
    }

    // This is the fixed route-to-fixture inventory for the release walkthrough.
    // swiftlint:disable:next cyclomatic_complexity
    private func appFixture(for route: String) -> String {
        if route == "sample-entry-progress" || route == "settings-explore-progress" {
            return "sample-entry-in-progress"
        }
        if route.hasPrefix("widget-system-") {
            return "no-account"
        }
        if route.hasPrefix("sample-") {
            return "no-account"
        }
        if route.hasPrefix("settings-requesting") {
            return "warning-alerts-requesting"
        }
        if route.hasPrefix("settings-denied") {
            return "warning-alerts-denied"
        }
        if route == "settings-alert-off-result" {
            return "warning-alerts-allowed"
        }
        if route == "settings-denied-handoff" {
            return "warning-alerts-denied"
        }
        if route.hasPrefix("settings-") {
            return "warning-alerts-off"
        }
        switch route {
        case "legacy-continue-result": return "legacy-awaiting-confirmation"
        case "temporary-retry-result": return "temporary-retry"
        case "no-account-retry-result": return "no-account"
        case "restricted-retry-result": return "restricted"
        default: return route
        }
    }

    // Each switch branch performs the interaction represented by one inventory route.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func prepare(route: String, in app: XCUIApplication) {
        switch route {
        case "legacy-continue-result": tap("Continue", in: app)
        case "temporary-retry-result", "no-account-retry-result", "restricted-retry-result": tap("Try Again", in: app)
        case "sample-entry-progress": break
        case "sample-dashboard": enterSample(in: app)
        case "sample-provider-detail": enterSample(in: app); tap("provider-card-sample-codex", in: app)
        case "sample-provider-back":
            enterSample(in: app); tap("provider-card-sample-codex", in: app)
            let backButton = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(backButton.waitForExistence(timeout: 10))
            backButton.tap()
        case "sample-reset-result": enterSample(in: app); tap("sample-data-reset", in: app)
        case "sample-exit-result": enterSample(in: app); tap("sample-data-exit", in: app)
        case "sample-settings", "sample-settings-reset", "sample-settings-exit":
            enterSample(in: app); openSettings(in: app)
            if route == "sample-settings-reset" {
                tap("sample-data-reset-settings", in: app)
            }
            if route == "sample-settings-exit" {
                tap("sample-data-exit-settings", in: app)
            }
        case "settings-off", "settings-requesting", "settings-denied": openSettings(in: app)
        case "settings-close-result":
            openSettings(in: app)
            let closeButton = app.buttons.firstMatch
            XCTAssertTrue(closeButton.waitForExistence(timeout: 10))
            closeButton.tap()
        case "settings-sort-result": openSettings(in: app); tap("Name A-Z", in: app)
        case "settings-sort-reset-result": openSettings(in: app); tap("Reset soonest", in: app)
        case "settings-automatic-result": openSettings(in: app); tap("Automatic", in: app)
        case "settings-card-size-disabled":
            openSettings(in: app); reveal(app.staticTexts["Automatic · 1 column"], in: app)
        case "settings-card-size-result":
            openSettings(in: app); tap("Automatic", in: app)
            slider("Card size", in: app).adjust(toNormalizedSliderPosition: 1)
        case "settings-show-exhausted-result": openSettings(in: app); tap("show-exhausted-toggle", in: app)
        case "settings-hide-exhausted-result":
            openSettings(in: app); tap("show-exhausted-toggle", in: app); tap("show-exhausted-toggle", in: app)
        case "settings-threshold-result":
            openSettings(in: app)
            slider("warning-threshold-slider", in: app).adjust(toNormalizedSliderPosition: 0.75)
        case "settings-warning-permission-sheet", "settings-warning-deny-result", "settings-warning-allow-result":
            openSettings(in: app); tap("warning-alerts-toggle", in: app)
            let alert = permissionAlert(in: app); XCTAssertTrue(alert.waitForExistence(timeout: 10))
            if route == "settings-warning-deny-result" {
                alert.buttons["Don’t Allow"].tap()
            }
            if route == "settings-warning-allow-result" {
                alert.buttons["Allow"].tap()
            }
            if route != "settings-warning-permission-sheet" {
                app.terminate()
                app.launchEnvironment["GRADUS_UITEST_FIXTURE"] = route == "settings-warning-deny-result"
                    ? "warning-alerts-denied"
                    : "warning-alerts-allowed"
                app.launch(); XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30)); openSettings(in: app)
            }
        case "settings-denied-handoff":
            openSettings(in: app); tap("Open iOS Settings", in: app)
            let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
            XCTAssertTrue(settings.wait(for: .runningForeground, timeout: 30))
        case "settings-explore-progress": openSettings(in: app)
        case "settings-explore-result": openSettings(in: app); tap("explore-sample-settings", in: app)
        case "settings-alert-off-result": openSettings(in: app); tap("warning-alerts-toggle", in: app)
        case "widget-system-gallery": openWidgetGallery(app: app)
        case "widget-system-add": openGradusWidgetAddSurface(app: app)
        case "widget-system-tap":
            openGradusWidgetAddSurface(app: app)
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let addWidget = addWidgetButton(in: springboard)
            XCTAssertTrue(addWidget.waitForExistence(timeout: 10)); addWidget.tap()
            if springboard.buttons["Done"].waitForExistence(timeout: 5) {
                springboard.buttons["Done"].tap()
            }
            let widget = springboard.otherElements.matching(
                NSPredicate(format: "label CONTAINS %@", "Gradus")
            ).firstMatch
            XCTAssertTrue(widget.waitForExistence(timeout: 10)); widget.tap()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 30))
        default: break
        }
    }

    private func markerElement(route: String, marker: String, app: XCUIApplication) -> XCUIElement {
        if route == "settings-warning-permission-sheet" {
            return permissionAlert(in: app)
        }
        if route == "settings-denied-handoff" {
            return XCUIApplication(bundleIdentifier: "com.apple.Preferences").otherElements.firstMatch
        }
        if route == "widget-system-add" {
            return addWidgetButton(in: XCUIApplication(bundleIdentifier: "com.apple.springboard"))
        }
        if route == "widget-system-gallery" {
            return XCUIApplication(bundleIdentifier: "com.apple.springboard").descendants(matching: .any)[marker]
        }
        if route == "sample-entry-progress" || route == "settings-explore-progress" {
            let identifier = route == "sample-entry-progress" ? "explore-sample" : "explore-sample-settings"
            return app.buttons.matching(identifier: identifier)
                .matching(NSPredicate(format: "value == %@", "In progress"))
                .firstMatch
        }
        return app.descendants(matching: .any)[marker]
    }

    private func enterSample(in app: XCUIApplication) {
        tap("explore-sample", in: app)
    }

    private func openSettings(in app: XCUIApplication) {
        tap("settings-button", in: app)
    }

    private func openWidgetGallery(app: XCUIApplication) {
        app.terminate()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.activate()
        let namedIcons = springboard.icons.matching(
            NSPredicate(format: "identifier IN %@ OR label IN %@", ["Gradus", "GradusiOS"], ["Gradus", "GradusiOS"])
        )
        let icon = namedIcons.firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 15)); icon.press(forDuration: 1.2)
        tap("Edit Home Screen", in: springboard)
        tap("Edit", in: springboard)
        tap("Add Widget", in: springboard)
    }

    private func openGradusWidgetAddSurface(app: XCUIApplication) {
        openWidgetGallery(app: app)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let search = springboard.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("Gradus")
        let result = springboard.cells.matching(
            NSPredicate(format: "label IN %@", ["Gradus", "GradusiOS"])
        ).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10)); result.tap()
    }

    private func tap(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier]
        if button.waitForExistence(timeout: 2) {
            button.tap()
            return
        }
        let toggle = app.switches[identifier]
        if toggle.waitForExistence(timeout: 2) {
            toggle.tap()
            return
        }
        for _ in 0 ..< 5 {
            app.swipeUp()
            if button.waitForExistence(timeout: 1) {
                button.tap()
                return
            }
            if toggle.exists {
                toggle.tap()
                return
            }
        }
        let element = app.descendants(matching: .any)[identifier].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 6), "Missing action \(identifier)")
        element.tap()
    }

    private func slider(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let element = app.sliders[identifier]
        if element.waitForExistence(timeout: 2) {
            return element
        }
        for _ in 0 ..< 5 {
            app.swipeUp()
            if element.waitForExistence(timeout: 1) {
                return element
            }
        }
        XCTFail("Missing slider \(identifier)")
        return element
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        if element.waitForExistence(timeout: 2) {
            return
        }
        for _ in 0 ..< 5 {
            app.swipeUp()
            if element.waitForExistence(timeout: 1) {
                return
            }
        }
        XCTFail("Missing walkthrough state \(element)")
    }

    private func permissionAlert(in app: XCUIApplication) -> XCUIElement {
        let appAlert = app.alerts.firstMatch
        if appAlert.waitForExistence(timeout: 2) {
            return appAlert
        }
        return XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
    }

    private func addWidgetButton(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Add Widget")).firstMatch
    }
}
