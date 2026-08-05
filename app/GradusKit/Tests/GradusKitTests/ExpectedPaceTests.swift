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
