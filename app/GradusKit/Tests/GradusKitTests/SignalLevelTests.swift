import Foundation
import Testing

@testable import GradusKit

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
        if raw == nil || raw is NSNull { return nil }
        if let text = raw as? String, text == "nan" { return Double.nan }
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
        TruthTableCase(
            percentLeft: TruthTableCase.number(row["percent_left"]),
            paceDelta: TruthTableCase.number(row["pace_delta"]),
            level: try #require(SignalLevel(rawValue: row["level"] as? String ?? "")),
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
/// other: with a finite pace, "orange or worse" is exactly `windowWarns`.
/// Asserted over the truth table so a future threshold change that breaks the
/// correspondence cannot pass silently.
@Test func orangeOrWorseEqualsWindowWarnsWhenPaceIsKnown() throws {
    for row in try loadTruthTable() {
        guard let percentLeft = row.percentLeft, percentLeft.isFinite,
            let paceDelta = row.paceDelta, paceDelta.isFinite
        else { continue }

        let window = ProviderWindow(
            id: "truth-table", percentLeft: percentLeft, resetISO: nil,
            windowHours: nil, paceDelta: paceDelta
        )
        let alarming = row.level == .orange || row.level == .red
        #expect(
            windowWarns(window) == alarming,
            "pace=\(paceDelta) percent=\(percentLeft): windowWarns and the \(row.level.rawValue) ramp disagree"
        )
    }
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
