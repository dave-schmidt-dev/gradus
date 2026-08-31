@testable import GradusiOS
import GradusKit
import XCTest

/// Regression guard for the 2026-08-31 snapshot mismatch.
///
/// For four days the iOS gate failed nine `DashboardSnapshotTests` methods on
/// this machine while the committed baselines were green elsewhere. The cause
/// was not the code under test, the simulator model, or a stale baseline: every
/// baseline that draws a reset time had the *recording host's* time zone baked
/// into it, because `friendlyResetDate` resolves through `Calendar.current` and
/// nothing pinned the process default. The same fixture instant renders as two
/// different strings three hours apart, so the images could never agree across
/// hosts in different zones.
///
/// These tests fail the moment the pin is removed, changed, or stops taking
/// effect -- each of which would silently reintroduce host-dependent baselines.
final class SnapshotTimeZoneTests: XCTestCase {
    /// The pin must actually be applied to the process, not merely declared.
    func testSnapshotRenderingIsPinnedToAFixedTimeZone() {
        XCTAssertTrue(snapshotTimeZoneIsPinned)
        XCTAssertEqual(NSTimeZone.default.identifier, snapshotTimeZoneIdentifier)
        // `Calendar.current` is the one that matters: it is what
        // `friendlyResetDate` resolves through. Deliberately *not* asserted on
        // `TimeZone.current`, which was measured on 2026-08-31 to keep
        // reporting the host zone ("America/New_York") even with
        // `NSTimeZone.default` set -- a Foundation quirk, and irrelevant here
        // so long as the calendar the rendering path uses is pinned.
        XCTAssertEqual(Calendar.current.timeZone.identifier, snapshotTimeZoneIdentifier)
    }

    /// The specific string the committed baselines encode. Asserting the
    /// rendered label rather than just the zone is what makes this a regression
    /// test for the actual failure: a future change to `friendlyResetDate`'s
    /// formatting would break the baselines the same way, and the zone check
    /// alone would not catch it.
    func testExhaustedResetLabelRendersInThePinnedZone() {
        XCTAssertTrue(snapshotTimeZoneIsPinned)
        XCTAssertEqual(
            friendlyResetDate("2026-08-05T00:00:00-04:00", now: dashboardSnapshotFixedNow),
            "Aug 5, 12:00 AM"
        )
    }

    /// Documents the trap directly: the identical instant renders differently
    /// under an unpinned host, which is exactly what a developer sees if the
    /// pin regresses. Uses an explicit calendar rather than mutating the
    /// process default, so it cannot leak into other tests.
    func testTheSameInstantRendersDifferentlyInAnotherZone() throws {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        XCTAssertEqual(
            friendlyResetDate(
                "2026-08-05T00:00:00-04:00",
                now: dashboardSnapshotFixedNow,
                calendar: pacific
            ),
            "Aug 4, 9:00 PM"
        )
    }
}
