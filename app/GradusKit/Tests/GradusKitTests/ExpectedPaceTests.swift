import Foundation
import Testing

@testable import GradusKit

@Test func expectedRemainingUsesRemainingPercentageAndFractionalPace() {
    #expect(expectedRemaining(percentLeft: 72, paceDelta: 0.12) == 60)
    #expect(expectedRemaining(percentLeft: 72, paceDelta: -0.12) == 84)
}

@Test func expectedRemainingClampsToPercentageBounds() {
    #expect(expectedRemaining(percentLeft: 5, paceDelta: 0.2) == 0)
    #expect(expectedRemaining(percentLeft: 95, paceDelta: -0.2) == 100)
}

@Test func expectedRemainingHandlesExactBoundsAndZeroPace() {
    #expect(expectedRemaining(percentLeft: 0, paceDelta: 0) == 0)
    #expect(expectedRemaining(percentLeft: 100, paceDelta: 0) == 100)
    #expect(expectedRemaining(percentLeft: 50, paceDelta: 0) == 50)
    #expect(expectedRemaining(percentLeft: 0, paceDelta: -1) == 100)
    #expect(expectedRemaining(percentLeft: 100, paceDelta: 1) == 0)
}

@Test func expectedRemainingRejectsMissingOrNonFiniteMetadata() {
    #expect(expectedRemaining(percentLeft: nil, paceDelta: 0) == nil)
    #expect(expectedRemaining(percentLeft: 50, paceDelta: nil) == nil)
    #expect(expectedRemaining(percentLeft: .nan, paceDelta: 0) == nil)
    #expect(expectedRemaining(percentLeft: .infinity, paceDelta: 0) == nil)
    #expect(expectedRemaining(percentLeft: 50, paceDelta: .nan) == nil)
    #expect(expectedRemaining(percentLeft: 50, paceDelta: -.infinity) == nil)
}

@Test func expectedRemainingRejectsOutOfRangePercentages() {
    #expect(expectedRemaining(percentLeft: -0.001, paceDelta: 0) == nil)
    #expect(expectedRemaining(percentLeft: 100.001, paceDelta: 0) == nil)
}

@Test func markerIsCenteredOnThePositionItMarks() {
    // Leading edge sits half a marker before the position, so the marker's
    // own center lands on it.
    #expect(markerOffset(fraction: 0.5, barWidth: 200, markerWidth: 3) == 98.5)
    #expect(markerOffset(fraction: 0.25, barWidth: 200, markerWidth: 3) == 48.5)
}

/// The divergence this function exists to end: iOS clamped the marker into its
/// bar and the Mac did not, so a Mac window at 0% or 100% drew half a marker
/// hanging off the end of the bar it was marking.
@Test func markerStaysInsideTheBarAtBothEnds() {
    #expect(markerOffset(fraction: 0, barWidth: 200, markerWidth: 3) == 0)
    #expect(markerOffset(fraction: 1, barWidth: 200, markerWidth: 3) == 197)
    // Out-of-range fractions cannot push it out either. `expectedRemaining`
    // already clamps to 0...100, so this only fires if a future caller feeds
    // the marker something that helper did not produce.
    #expect(markerOffset(fraction: -5, barWidth: 200, markerWidth: 3) == 0)
    #expect(markerOffset(fraction: 5, barWidth: 200, markerWidth: 3) == 197)
}

/// A bar too small to hold the marker is a degenerate layout, but it must not
/// also be a negatively-positioned one.
@Test func markerDoesNotGoNegativeOnADegenerateBar() {
    #expect(markerOffset(fraction: 0.5, barWidth: 2, markerWidth: 3) == 0)
    #expect(markerOffset(fraction: 1, barWidth: 0, markerWidth: 3) == 0)
}
