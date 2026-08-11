import GradusKit
import XCTest

// T3.5 gate: a real `XCUIApplication` launch, seeding the on-disk offline
// cache via `launchEnvironment` (read by `GradusiOSApp.init` before the
// first frame -- see GRADUS_UITEST_SEED_JSON) so the dashboard renders real
// provider cards without any live CloudKit round-trip.
final class DashboardXCUITests: XCTestCase {
    func testDashboardRendersProviderCardsFromSeededCache() throws {
        let providers = [
            ProviderStatus(
                providerName: "codex",
                providerDisplayName: "Codex",
                ok: true,
                errorMessage: nil,
                windows: [
                    ProviderWindow(
                        id: "weekly", percentLeft: 62, resetISO: "2026-08-08T05:00:00-04:00", windowHours: 168,
                        paceDelta: -0.05)
                ],
                data: [:],
                observedAt: "2026-08-02T19:59:30-04:00",
                snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
                publishedAt: Date()
            ),
            ProviderStatus(
                providerName: "cursor",
                providerDisplayName: "Cursor",
                ok: false,
                errorMessage: "transient fetch failure",
                windows: [],
                data: [:],
                observedAt: nil,
                snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
                publishedAt: Date()
            ),
        ]
        let seedData = try JSONEncoder().encode(providers)
        let seedJSON = String(data: seedData, encoding: .utf8)!

        let app = XCUIApplication()
        app.launchEnvironment["GRADUS_UITEST_SEED_JSON"] = seedJSON
        app.launch()

        // Two system dialogs can cover the full screen and block every
        // element query below:
        //  - `AppDelegate`'s notification-authorization prompt (T4.2,
        //    unrelated to this phase's ranking work) -- shown once, on the
        //    first launch that hasn't answered it yet.
        //  - An "Apple Account Verification" re-auth dialog, from the
        //    simulator's real, shared signed-in Apple ID needing periodic
        //    re-verification -- entirely orthogonal to this app. Unlike the
        //    notification prompt, this one is NOT one-and-done: it's an
        //    OS-level nag that re-surfaces on its own roughly every 5s even
        //    after being dismissed (confirmed via screen-recording capture
        //    across two separate runs -- gating the app's own CloudKit
        //    calls off under `GRADUS_UITEST_SEED_JSON` made no difference,
        //    so it isn't triggered by anything this app does). A one-shot
        //    dismiss-then-wait therefore races it and flakes; poll for both
        //    dialogs for the duration of the wait instead.
        //
        // `addUIInterruptionMonitor` only fires on the next `tap()`, which
        // never happens here since everything below is otherwise a passive
        // `waitForExistence`/`exists` -- so dismiss directly via springboard
        // queries, which are synchronous and reliable.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func dismissKnownSystemDialogs() {
            for label in ["Allow", "Not Now"] {
                let button = springboard.buttons[label]
                if button.exists {
                    button.tap()
                }
            }
        }

        // P3/T3.3: under `rankProviders`' corrected ranking (Key decision
        // #6), the errored provider (`cursor`, tier 1) sorts first -- never
        // the highest-percent `ok` provider (`codex`, tier 3 here, since it
        // has neither `isWarning` nor a locally-urgent window). The original
        // assertions here waited on "Codex" first with no ordering check at
        // all; that happened to still pass under the old alphabetical/no-sort
        // behavior but asserted nothing about ordering. Wait on "Cursor"
        // first (it sorts first, so it renders on the very first frame once
        // nothing is covering it) and assert its error body ("transient fetch
        // failure") renders, then assert `codex` renders too.
        //
        // The error text came from `StatTile`'s error variant when this was
        // written; since the dense layout (INV-12) it comes from
        // `ProviderDensityCard.swift:48`. The assertion is unchanged because
        // both render `provider.errorMessage` verbatim -- what is being
        // checked is that an errored provider still shows its reason, not
        // which view draws it.
        let deadline = Date().addingTimeInterval(20)
        var foundCursor = false
        repeat {
            dismissKnownSystemDialogs()
            foundCursor = app.staticTexts["Cursor"].waitForExistence(timeout: 1)
        } while !foundCursor && Date() < deadline
        dismissKnownSystemDialogs()

        XCTAssertTrue(foundCursor)
        XCTAssertTrue(app.staticTexts["transient fetch failure"].exists)
        XCTAssertTrue(app.staticTexts["Codex"].exists)
        XCTAssertTrue(app.staticTexts["62%"].exists)

        app.staticTexts["Cursor"].tap()
        XCTAssertTrue(app.staticTexts["transient fetch failure"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.exists)
        app.navigationBars.buttons.firstMatch.tap()

        XCTAssertTrue(app.staticTexts["Gradus"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Codex"].exists)
    }

    func testSettingsControlsUpdateLocalDisplayAndSyncPreferences() throws {
        let providers = [
            ProviderStatus(
                providerName: "active",
                providerDisplayName: "Active",
                ok: true,
                errorMessage: nil,
                windows: [
                    ProviderWindow(
                        id: "weekly", percentLeft: 72,
                        resetISO: "2026-08-12T05:00:00-04:00", windowHours: 168,
                        paceDelta: 0.05)
                ],
                data: [:], observedAt: "2026-08-10T12:00:00-04:00",
                snapshotUpdatedAt: "2026-08-10T12:00:00-04:00", publishedAt: Date()),
            ProviderStatus(
                providerName: "spent",
                providerDisplayName: "Spent",
                ok: true,
                errorMessage: nil,
                windows: [
                    ProviderWindow(
                        id: "monthly", percentLeft: 0,
                        resetISO: "2026-08-31T23:59:00-04:00", windowHours: 720,
                        paceDelta: -0.5)
                ],
                data: [:], observedAt: "2026-08-10T12:00:00-04:00",
                snapshotUpdatedAt: "2026-08-10T12:00:00-04:00", publishedAt: Date()),
        ]
        let app = XCUIApplication()
        app.launchEnvironment["GRADUS_UITEST_SEED_JSON"] = String(
            data: try JSONEncoder().encode(providers), encoding: .utf8)!
        app.launch()

        dismissSystemDialogsIfPresent(for: app)
        XCTAssertTrue(app.staticTexts["Active"].waitForExistence(timeout: 10))

        let dashboardSettings = app.buttons.firstMatch
        XCTAssertTrue(dashboardSettings.exists)
        dashboardSettings.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))

        let sortName = app.buttons["Name A-Z"]
        XCTAssertTrue(sortName.waitForExistence(timeout: 5))
        sortName.tap()

        // `ListRow.toggle` deliberately hides the Toggle label, so SwiftUI's
        // accessibility tree exposes these controls as unlabeled switches.
        // Settings renders them in the fixed section order: sync, warnings,
        // exhausted visibility. Indexing that contract is more precise than
        // matching an identifier the production view does not provide.
        let showExhausted = app.switches.element(boundBy: 2)
        XCTAssertTrue(showExhausted.exists)
        let initialShowExhausted = switchIsOn(showExhausted)
        showExhausted.tap()
        XCTAssertNotEqual(switchIsOn(showExhausted), initialShowExhausted)
        showExhausted.tap()
        XCTAssertEqual(switchIsOn(showExhausted), initialShowExhausted)

        let sync = app.switches.element(boundBy: 0)
        XCTAssertTrue(sync.exists)
        let initialSync = switchIsOn(sync)
        sync.tap()
        XCTAssertNotEqual(switchIsOn(sync), initialSync)

        let notifications = app.switches.element(boundBy: 1)
        XCTAssertTrue(notifications.exists)
        let initialNotifications = switchIsOn(notifications)
        notifications.tap()
        let notificationState = NSPredicate(
            format: "value == %@", initialNotifications ? "0" : "1")
        expectation(for: notificationState, evaluatedWith: notifications)
        waitForExpectations(timeout: 5)
        XCTAssertNotEqual(switchIsOn(notifications), initialNotifications)

        let threshold = app.sliders.firstMatch
        XCTAssertTrue(threshold.exists)
        let initialThreshold = elementValue(threshold)
        let initialThresholdPercent = Int(initialThreshold.dropLast()) ?? 50
        threshold.adjust(toNormalizedSliderPosition: initialThresholdPercent <= 50 ? 1.0 : 0.0)
        XCTAssertNotEqual(elementValue(threshold), initialThreshold)
    }

    private func dismissSystemDialogsIfPresent(for app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Not Now"] where springboard.buttons[label].exists {
            springboard.buttons[label].tap()
        }
        _ = app
    }

    private func switchIsOn(_ element: XCUIElement) -> Bool {
        (element.value as? String) == "1"
    }

    private func elementValue(_ element: XCUIElement) -> String {
        element.value as? String ?? String(describing: element.value)
    }
}
