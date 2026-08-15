import Foundation
@testable import GradusKit
import Testing

private func window(percentLeft: Double, paceDelta: Double? = nil) -> ProviderWindow {
    ProviderWindow(
        id: "test", percentLeft: percentLeft, resetISO: nil, windowHours: nil, paceDelta: paceDelta
    )
}

// CV-2: generated truth table over the percent_left / pace_delta combinations
// that decide `window_warns` in gradus/snapshot.py. Restates the rule rather
// than calling the ramp, so the two apps cannot silently drift apart and so a
// change to `signalLevel` has to be made here deliberately.
//
// The `paceDelta == nil` branch is the part that changed on 2026-08-06: it
// used to contribute `false` unconditionally, and now falls through to the
// percent-only ramp (70/40/20), which is what `signalLevel` does with a window
// that has no reset timestamp.
private struct WarnsTruthTableCase: Sendable {
    let percentLeft: Double
    let paceDelta: Double?
    let expectWarns: Bool
}

private let truthTable: [WarnsTruthTableCase] = {
    func fallbackWarns(_ percentLeft: Double) -> Bool {
        percentLeft < 40
    }

    var cases: [WarnsTruthTableCase] = []
    for percentLeft in [0.0, 0.4, 1.0, 50.0, 99.0, 100.0] {
        let depleted = percentLeft < 0.5
        for paceDelta in [Double?.none, -0.5, -0.10, -0.099, 0.0, 0.5] {
            let warns: Bool = if depleted {
                true
            } else if let paceDelta, paceDelta.isFinite {
                paceDelta < -0.10
            } else {
                fallbackWarns(percentLeft)
            }
            cases.append(WarnsTruthTableCase(percentLeft: percentLeft, paceDelta: paceDelta, expectWarns: warns))
        }
    }
    return cases
}()

@Test(arguments: truthTable)
private func windowWarnsMatchesGeneratedTruthTable(_ testCase: WarnsTruthTableCase) {
    let w = window(percentLeft: testCase.percentLeft, paceDelta: testCase.paceDelta)
    #expect(windowWarns(w) == testCase.expectWarns)
}

@Test func invalidPercentNeverWarns() {
    #expect(windowWarns(window(percentLeft: .nan, paceDelta: -5.0)) == false)
    #expect(windowWarns(window(percentLeft: .infinity, paceDelta: -5.0)) == false)
    #expect(windowWarns(window(percentLeft: -1.0, paceDelta: -5.0)) == false)
    #expect(windowWarns(window(percentLeft: 101.0, paceDelta: -5.0)) == false)
}

/// A non-finite pace is treated as *no* pace, so the percent ramp decides.
/// That is not the same as "never warns": at 50% the fallback says yellow, at
/// 19% it says red. Before 2026-08-06 both of these were silent.
@Test func invalidPaceFallsBackToThePercentRamp() {
    #expect(windowWarns(window(percentLeft: 50.0, paceDelta: .nan)) == false)
    #expect(windowWarns(window(percentLeft: 50.0, paceDelta: .infinity)) == false)
    #expect(windowWarns(window(percentLeft: 19.0, paceDelta: .nan)) == true)
    #expect(windowWarns(window(percentLeft: 19.0, paceDelta: nil)) == true)
}

@Test func exactlyAtDepletedRoundingBoundary() {
    // 0.4 rounds to 0 -> depleted -> warns even with no adverse pace.
    #expect(percentIsDepleted(0.4) == true)
    #expect(windowWarns(window(percentLeft: 0.4, paceDelta: nil)) == true)
    // 0.6 rounds to 1 -> not depleted.
    #expect(percentIsDepleted(0.6) == false)
}

/// The boundary is exclusive, and both languages must agree on it.
///
/// This was the one input where they didn't: `round(0.5) == 0` in Python
/// (banker's rounding) but `(0.5).rounded() == 1` in Swift, so a provider at
/// exactly 0.5% was depleted-and-warning on the TUI and neither here. Both
/// sides now compare against `depletedPercentCeiling` / the Python
/// `DEPLETED_PERCENT_CEILING` instead of rounding at all.
@Test func depletionCeilingIsExclusiveAndRoundingModeFree() {
    #expect(percentIsDepleted(0.5) == false)
    // Carries a healthy pace on purpose. With no pace the ramp falls back to
    // percentage and calls 0.5% red, so `paceDelta: nil` would warn whether or
    // not the ceiling were exclusive and would assert nothing about depletion.
    #expect(windowWarns(window(percentLeft: 0.5, paceDelta: 0.2)) == false)
    #expect(percentIsDepleted(depletedPercentCeiling.nextDown) == true)
    #expect(percentIsDepleted(0.0) == true)
}

@Test func percentIsValidRejectsOutOfBounds() {
    #expect(percentIsValid(0.0) == true)
    #expect(percentIsValid(100.0) == true)
    #expect(percentIsValid(-0.001) == false)
    #expect(percentIsValid(100.001) == false)
    #expect(percentIsValid(nil) == false)
    #expect(percentIsValid(.nan) == false)
}
