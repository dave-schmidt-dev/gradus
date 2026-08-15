import Foundation
@testable import GradusKit
import Testing

// The shared truth table is the contract; these tests are its Swift half.
// `tests/test_ui.py::SignalLevelTruthTableTest` asserts the same rows against
// the TUI, so a one-sided ramp edit fails on both sides.

private struct TruthTableCase {
    let percentLeft: Double?
    let paceDelta: Double?
    let level: SignalLevel
    let why: String

    /// `null` -> nil, `"nan"` -> NaN, number -> itself. JSON has no non-finite
    /// literal, hence the string sentinel.
    static func number(_ raw: Any?) -> Double? {
        if raw == nil || raw is NSNull {
            return nil
        }
        if let text = raw as? String, text == "nan" {
            return Double.nan
        }
        return (raw as? NSNumber)?.doubleValue
    }
}

private func loadTruthTable() throws -> [TruthTableCase] {
    let url = try #require(
        Bundle.module.url(forResource: "signal-levels", withExtension: "json"),
        "signal-levels.json is missing from the test bundle -- check the resources list in Package.swift"
    )
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    let cases = try #require(root?["cases"] as? [[String: Any]])
    return try cases.map { row in
        try TruthTableCase(
            percentLeft: TruthTableCase.number(row["percent_left"]),
            paceDelta: TruthTableCase.number(row["pace_delta"]),
            level: #require(SignalLevel(rawValue: row["level"] as? String ?? "")),
            why: row["why"] as? String ?? ""
        )
    }
}

@Test func signalLevelMatchesSharedTruthTable() throws {
    let table = try loadTruthTable()
    #expect(table.count >= 15, "truth table shrank -- boundary coverage was removed")

    for row in table {
        let actual = signalLevel(percentLeft: row.percentLeft, paceDelta: row.paceDelta)
        #expect(
            actual == row.level,
            """
            percent=\(String(describing: row.percentLeft)) \
            pace=\(String(describing: row.paceDelta)) \
            expected \(row.level.rawValue), got \(actual.rawValue). \(row.why)
            """
        )
    }
}

/// The property that lets a color and a notification never contradict each
/// other: "orange or worse" is exactly `windowWarns`. Asserted over the whole
/// truth table so a future threshold change that breaks the correspondence
/// cannot pass silently.
///
/// This used to skip rows with no pace, because there the two genuinely
/// differed — the ramp fell back to percentage and `windowWarns` returned
/// false, so a window could render red and stay silent. Since 2026-08-06
/// `windowWarns` *is* this property, and the absence of a guard here is what
/// pins that.
///
/// Note the assertion spells out `.orange || .red` rather than calling
/// `SignalLevel.needsAttention`, which is what `windowWarns` is built from.
/// Reusing that property would make this test agree with the implementation by
/// construction and stop it from noticing a step being added to or dropped
/// from the attention set.
@Test func orangeOrWorseEqualsWindowWarns() throws {
    var checkedWithoutPace = 0
    for row in try loadTruthTable() {
        guard let percentLeft = row.percentLeft else { continue }
        if row.paceDelta == nil || !(row.paceDelta ?? 0).isFinite {
            checkedWithoutPace += 1
        }

        let window = ProviderWindow(
            id: "truth-table", percentLeft: percentLeft, resetISO: nil,
            windowHours: nil, paceDelta: row.paceDelta
        )
        let alarming = row.level == .orange || row.level == .red
        #expect(
            windowWarns(window) == alarming,
            """
            pace=\(String(describing: row.paceDelta)) percent=\(percentLeft): windowWarns and the \
            \(row.level.rawValue) ramp disagree
            """
        )
    }
    #expect(
        checkedWithoutPace > 0,
        "the fixture no longer covers a window without pace, which is the case this property used to fail on"
    )
}

/// A provider is in trouble when *any* of its windows is, not when its
/// worst-by-percentage one is.
///
/// The Mac asked the second question until 2026-08-06 while iOS asked the
/// first, which is how one snapshot could produce a warning count on the phone
/// and none in the menu bar. The fixture below is the discriminating case: the
/// lowest-percentage window is comfortably on pace, and the window in trouble
/// is the one with the most left.
@Test func providerAttentionAsksAboutEveryWindowNotJustTheWorst() {
    // Both are physically reachable, which for pace means
    // `paceDelta == fractionLeft - fractionOfWindowRemaining` has to land on a
    // non-negative remaining-time ratio. 5%/+0.02 is 97% of the window elapsed
    // with a sliver of budget left -- an ordinary pre-reset state. 70%/-0.28
    // is 2% elapsed with 30% already spent -- a burst at the start of a weekly
    // window. 80%/-0.5 would have needed the reset rolled 1.3 window-lengths
    // into the future, which is a data anomaly rather than a state to pin a
    // rule on.
    let calmButNearlyEmpty = ProviderWindow(
        id: "five_hour", percentLeft: 5, resetISO: nil, windowHours: 5, paceDelta: 0.02
    )
    let fullButBurning = ProviderWindow(
        id: "weekly", percentLeft: 70, resetISO: nil, windowHours: 168, paceDelta: -0.28
    )

    #expect(!windowWarns(calmButNearlyEmpty))
    #expect(windowWarns(fullButBurning))
    #expect(providerNeedsAttention([calmButNearlyEmpty, fullButBurning]))
    // Order must not matter: a worst-window rule would answer differently
    // depending on which one it happened to pick.
    #expect(providerNeedsAttention([fullButBurning, calmButNearlyEmpty]))
    #expect(!providerNeedsAttention([calmButNearlyEmpty]))
    #expect(!providerNeedsAttention([]))
}

@Test func unknownIsTheOnlyLevelWithoutAColor() {
    for level in SignalLevel.allCases {
        #expect((level.rgbHex == nil) == (level == .unknown))
    }
}

/// Locks the exact sRGB values. These are the ones the TUI theme and the
/// pre-existing iOS `SignalColor` used, so the ramp changed meaning without
/// changing palette.
@Test func rampHexValuesAreCanonical() {
    #expect(SignalLevel.green.rgbHex == 0x87D787)
    #expect(SignalLevel.yellow.rgbHex == 0xFFD75F)
    #expect(SignalLevel.orange.rgbHex == 0xFFAF5F)
    #expect(SignalLevel.red.rgbHex == 0xFF5F5F)
}

@Test func windowOverloadAgreesWithScalarForm() {
    let window = ProviderWindow(
        id: "weekly", percentLeft: 20, resetISO: nil, windowHours: 168, paceDelta: -0.6
    )
    #expect(signalLevel(for: window) == .red)
    #expect(signalLevel(for: window) == signalLevel(percentLeft: 20, paceDelta: -0.6))
}
