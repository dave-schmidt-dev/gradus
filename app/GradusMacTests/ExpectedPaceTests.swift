import GradusKit
import Testing

@testable import GradusMac

@Test func macMarkerFractionMatchesSharedExpectedRemaining() {
    let percentLeft = 62.0
    let paceDelta = -0.05

    let expectedFraction = try! #require(
        expectedRemaining(percentLeft: percentLeft, paceDelta: paceDelta).map { $0 / 100 }
    )

    #expect(
        ProgressBar.expectedRemainingMarkerFraction(
            percentLeft: percentLeft,
            paceDelta: paceDelta
        ) == expectedFraction
    )
}

@Test func macMarkerFractionOmitsMissingOrInvalidPace() {
    #expect(ProgressBar.expectedRemainingMarkerFraction(percentLeft: 62, paceDelta: nil) == nil)
    #expect(ProgressBar.expectedRemainingMarkerFraction(percentLeft: 62, paceDelta: .nan) == nil)
}
