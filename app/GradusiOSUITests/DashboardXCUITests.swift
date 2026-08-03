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

        XCTAssertTrue(app.staticTexts["Codex"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["62%"].exists)
        XCTAssertTrue(app.staticTexts["Cursor"].exists)
        XCTAssertTrue(app.staticTexts["transient fetch failure"].exists)
    }
}
