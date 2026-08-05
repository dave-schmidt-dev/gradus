import GradusKit
import XCTest

/// iPad Option B's interactive coverage: the dense grid actually routes on a
/// real regular-width device, every window renders without a drill-in, and
/// tapping a card pushes Provider Detail.
///
/// This complements `DensityLayoutSnapshotTests`, which renders
/// `DashboardContent` with `layout: .denseGrid` passed in explicitly. That
/// proves the *layout* draws correctly but says nothing about whether the real
/// app ever selects it — the size-class derivation, the `NavigationStack`, and
/// the tap-to-push wiring are all outside a snapshot's reach. Only a launched
/// app on an actual iPad exercises those.
///
/// Runs on the iPad destination `test-gate.sh` adds for `GradusiOSUITests`.
/// It self-skips on the iPhone destination, where the dense grid correctly
/// never renders. That skip is the one soft spot here: drop the iPad
/// destination from the gate and this file goes silently green everywhere
/// instead of failing, so the gate step is named explicitly in `test-gate.sh`
/// to make its absence visible in the log.
final class DensityLayoutXCUITests: XCTestCase {
    /// A provider with three windows. In the compact layout `StatTile` shows
    /// one window and hides the rest behind badges, so "all three visible at
    /// once" is exactly the claim Option B makes and the compact layout fails.
    private func seedJSON() throws -> String {
        let providers = [
            ProviderStatus(
                providerName: "opencode",
                providerDisplayName: "OpenCode Go",
                ok: true,
                errorMessage: nil,
                windows: [
                    ProviderWindow(
                        id: "five_hour", percentLeft: 100, resetISO: "2026-08-08T05:00:00-04:00",
                        windowHours: 5, paceDelta: 0.30),
                    ProviderWindow(
                        id: "weekly", percentLeft: 61, resetISO: "2026-08-08T20:00:00-04:00",
                        windowHours: 168, paceDelta: -0.12),
                    ProviderWindow(
                        id: "monthly", percentLeft: 7, resetISO: "2026-08-23T21:30:00-04:00",
                        windowHours: 720, paceDelta: -0.42),
                ],
                data: [:],
                observedAt: "2026-08-02T19:59:30-04:00",
                snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
                publishedAt: Date()
            ),
            ProviderStatus(
                providerName: "codex",
                providerDisplayName: "Codex",
                ok: true,
                errorMessage: nil,
                windows: [
                    ProviderWindow(
                        id: "weekly", percentLeft: 76, resetISO: "2026-08-08T09:19:00-04:00",
                        windowHours: 168, paceDelta: -0.05)
                ],
                data: [:],
                observedAt: "2026-08-02T19:59:30-04:00",
                snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
                publishedAt: Date()
            ),
        ]
        return String(data: try JSONEncoder().encode(providers), encoding: .utf8)!
    }

    func testDenseCardShowsEveryWindowAndPushesProviderDetail() throws {
        try XCTSkipUnless(
            UIDevice.current.userInterfaceIdiom == .pad,
            "The dense grid only renders at regular horizontal size class.")

        let app = XCUIApplication()
        app.launchEnvironment["GRADUS_UITEST_SEED_JSON"] = try seedJSON()
        app.launch()

        // Same two system dialogs `DashboardXCUITests` documents: the
        // notification-authorization prompt and the simulator's self-resurfacing
        // Apple Account verification nag. Poll rather than dismiss once.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func dismissKnownSystemDialogs() {
            for label in ["Allow", "Not Now"] {
                let button = springboard.buttons[label]
                if button.exists { button.tap() }
            }
        }

        let card = app.otherElements["provider-card-opencode"]
        let deadline = Date().addingTimeInterval(20)
        var foundCard = false
        repeat {
            dismissKnownSystemDialogs()
            foundCard = card.waitForExistence(timeout: 1)
        } while !foundCard && Date() < deadline
        dismissKnownSystemDialogs()

        // The card identifier only exists in `ProviderDensityCard`, so finding
        // it proves the app chose `.denseGrid` on its own from the size class --
        // no test override involved.
        XCTAssertTrue(foundCard, "Dense provider card did not render on iPad")

        // `WindowRow` is `.accessibilityElement(children: .ignore)`, so its four
        // Text views collapse into one element carrying `spokenLabel`
        // ("Weekly, 61 percent remaining, resets ..."). Querying
        // `staticTexts["Weekly"]` would find nothing even when the row renders
        // correctly, so match on the label prefix instead.
        func rowExists(labeled prefix: String) -> Bool {
            let predicate = NSPredicate(format: "label BEGINSWITH %@", prefix)
            return card.descendants(matching: .any).matching(predicate).firstMatch.exists
        }

        XCTAssertTrue(rowExists(labeled: "5 Hour, 100 percent"), "5 Hour row missing")
        XCTAssertTrue(rowExists(labeled: "Weekly, 61 percent"), "Weekly row missing")
        XCTAssertTrue(rowExists(labeled: "Monthly, 7 percent"), "Monthly row missing")

        // `descendants(matching: .any)` is a broad query, and the three
        // assertions above would pass just as happily against a predicate that
        // matched everything. These two prove it actually discriminates: a
        // window this provider does not have, and the right window at the wrong
        // value, must both be absent.
        XCTAssertFalse(rowExists(labeled: "Premium,"), "row query matches windows that aren't there")
        XCTAssertFalse(rowExists(labeled: "Weekly, 62 percent"), "row query ignores the percentage")

        // The second provider is a peer card, not a badge or a drill-in.
        XCTAssertTrue(app.otherElements["provider-card-codex"].exists)

        card.tap()
        XCTAssertTrue(
            app.staticTexts["OpenCode Go"].waitForExistence(timeout: 5),
            "Tapping a dense card did not push Provider Detail")
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.exists)
        app.navigationBars.buttons.firstMatch.tap()

        XCTAssertTrue(app.staticTexts["Gradus"].waitForExistence(timeout: 5))
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }
}
