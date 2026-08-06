import GradusKit
import XCTest

/// The dense layout's interactive coverage, on **both** size classes: every
/// window renders without a drill-in, and tapping a card pushes Provider
/// Detail.
///
/// This complements `DensityLayoutSnapshotTests`, which renders
/// `DashboardContent` with a layout passed in explicitly. That proves the
/// *layout* draws correctly but says nothing about whether the real app ever
/// selects it — the size-class derivation, the `NavigationStack`, and the
/// tap-to-push wiring are all outside a snapshot's reach. Only a launched app
/// exercises those.
///
/// Deliberately **not** gated on `userInterfaceIdiom == .pad`. It was, while
/// the dense grid rendered only at regular width; now that both size classes
/// use it (INV-12), running unskipped on the iPhone destination is what proves
/// the compact path actually reaches the same layout rather than merely being
/// configured to. A skip here would let the two size classes drift back apart
/// while the suite stayed green — which is exactly how they drifted the first
/// time.
///
/// The iPad destination in `test-gate.sh` still earns its place: it is the only
/// one where the adaptive column count resolves to more than one, so it is the
/// only destination that can catch a regression in multi-column layout.
final class DensityLayoutXCUITests: XCTestCase {
    /// A provider with three windows. Both layouts must show all three at
    /// once — that is the parity claim INV-12 makes, and the claim the
    /// superseded `StatTile` list failed by hiding all but one behind badges.
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
        // "7.0", not "7": below ten the spoken label carries a decimal, because
        // whole-number truncation would speak a live sub-1% window as "0
        // percent remaining" (2026-08-06). Values at or above ten are unchanged,
        // which is why only this row gained a decimal.
        XCTAssertTrue(rowExists(labeled: "Monthly, 7.0 percent"), "Monthly row missing")

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
