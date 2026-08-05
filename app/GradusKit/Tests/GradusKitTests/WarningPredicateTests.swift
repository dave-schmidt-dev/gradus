import Foundation
import Testing

@testable import GradusKit

private func window(percentLeft: Double, paceDelta: Double? = nil) -> ProviderWindow {
    ProviderWindow(
        id: "test", percentLeft: percentLeft, resetISO: nil, windowHours: nil, paceDelta: paceDelta)
}

// CV-2: generated truth table over the percent_left / pace_delta combinations
// that decide `window_warns` in gradus/snapshot.py. Mirrors the Python
// predicate exactly so the two apps cannot silently drift apart.
private let truthTable: [(percentLeft: Double, paceDelta: Double?, expectWarns: Bool)] = {
    var cases: [(Double, Double?, Bool)] = []
    for percentLeft in [0.0, 0.4, 1.0, 50.0, 99.0, 100.0] {
        let depleted = percentLeft.rounded() <= 0
        for paceDelta in [Optional<Double>.none, -0.5, -0.10, -0.099, 0.0, 0.5] {
            let paceWarns = paceDelta.map { $0 < -0.10 } ?? false
            cases.append((percentLeft, paceDelta, depleted || paceWarns))
        }
    }
    return cases
}()

@Test(arguments: truthTable)
func windowWarnsMatchesGeneratedTruthTable(
    _ testCase: (percentLeft: Double, paceDelta: Double?, expectWarns: Bool)
) {
    let w = window(percentLeft: testCase.percentLeft, paceDelta: testCase.paceDelta)
    #expect(windowWarns(w) == testCase.expectWarns)
}

@Test func invalidPercentNeverWarns() {
    #expect(windowWarns(window(percentLeft: .nan, paceDelta: -5.0)) == false)
    #expect(windowWarns(window(percentLeft: .infinity, paceDelta: -5.0)) == false)
    #expect(windowWarns(window(percentLeft: -1.0, paceDelta: -5.0)) == false)
    #expect(windowWarns(window(percentLeft: 101.0, paceDelta: -5.0)) == false)
}

@Test func invalidPaceNeverWarnsWhenNotDepleted() {
    #expect(windowWarns(window(percentLeft: 50.0, paceDelta: .nan)) == false)
    #expect(windowWarns(window(percentLeft: 50.0, paceDelta: .infinity)) == false)
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
    #expect(windowWarns(window(percentLeft: 0.5, paceDelta: nil)) == false)
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
