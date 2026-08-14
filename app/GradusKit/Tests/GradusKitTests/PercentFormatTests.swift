import Foundation
@testable import GradusKit
import Testing

// The shared truth table is the contract; these tests are its Swift half.
// `tests/test_ui.py::PercentFormatTruthTableTest` asserts the same rows against
// the TUI, so a one-sided formatting edit fails on both sides.

private struct FormatCase {
    let percentLeft: Double?
    let text: String
    let why: String
}

private func loadFormatTable() throws -> [FormatCase] {
    let url = try #require(
        Bundle.module.url(forResource: "percent-format", withExtension: "json"),
        "percent-format.json is missing from the test bundle -- check the resources list in Package.swift"
    )
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    let cases = try #require(root?["cases"] as? [[String: Any]])
    return try cases.map { row in
        let raw = row["percent_left"]
        return try FormatCase(
            percentLeft: (raw == nil || raw is NSNull) ? nil : (raw as? NSNumber)?.doubleValue,
            text: #require(row["text"] as? String),
            why: row["why"] as? String ?? ""
        )
    }
}

@Test func percentTextMatchesSharedTruthTable() throws {
    let table = try loadFormatTable()
    #expect(table.count >= 16, "format table shrank -- boundary coverage was removed")
    for row in table {
        let actual = row.percentLeft.map { percentText($0) } ?? percentMissingText
        #expect(actual == row.text, "percent_left \(String(describing: row.percentLeft)): \(row.why)")
    }
}

/// The defect this formatter exists to prevent.
///
/// `percentIsDepleted` treats <= 0.5 as exhausted, so everything above it is a
/// live window. Under the old `Int(window.percentLeft)` every value in
/// (0.5, 1.0) rendered as "0" -- a live window displayed, and spoken, as an
/// empty one.
@Test func liveWindowsBelowOnePercentAreNeverDisplayedAsZero() {
    // The expected strings are spelled out rather than interpolated from the
    // value under test. `"\(0.7)"` is Swift's shortest-round-trip description,
    // which agrees with `String(format: "%.1f", 0.7)` here but not in general --
    // an expectation rebuilt from its own input cannot catch a formatting change.
    let expected: [(percent: Double, text: String)] = [
        (0.6, "0.6"), (0.7, "0.7"), (0.8, "0.8"), (0.9, "0.9")
    ]
    for row in expected {
        #expect(!percentIsDepleted(row.percent), "\(row.percent) should be a live window")
        #expect(percentText(row.percent) == row.text)
        #expect(percentText(row.percent) != "0", "\(row.percent) must not render as a bare 0")
        #expect(percentDisplay(row.percent) == row.text + "%")
        #expect(
            percentDisplay(row.percent, suffix: " percent remaining")
                == row.text + " percent remaining"
        )
    }
}

/// Remaining budget must never be overstated, which is the whole reason this
/// truncates instead of rounding.
@Test func displayedPercentageNeverExceedsTheActualOne() {
    for thousandths in 0 ... 100_000 {
        let percent = Double(thousandths) / 1000.0
        let shown = Double(percentText(percent)) ?? -1
        #expect(shown <= percent + 1e-9, "\(percent) displayed as \(shown), which claims more headroom than exists")
    }
}

/// A true 9.1 arrives from `100.0 - 90.9` as 9.099999999999994. Without the
/// epsilon the floor drops a digit and the display disagrees with the TUI.
@Test func computedPercentagesDoNotLoseADigitToFloatError() {
    for thousandths in 0 ... 100_000 {
        let used = Double(thousandths) / 1000.0
        let percent = 100.0 - used
        let shown = Double(percentText(percent)) ?? -1
        let places = percent < percentDecimalCeiling ? 1.0 : 0.0
        let step = pow(10.0, -places)
        #expect(percent - shown < step, "\(percent) displayed as \(shown), a full step low")
    }
}

@Test func missingAndNonFiniteReadingsCollapseToOneLabel() {
    #expect(percentDisplay(nil) == percentMissingText)
    #expect(percentDisplay(Double.nan) == percentMissingText)
    #expect(percentDisplay(Double.infinity) == percentMissingText)
    #expect(percentDisplay(nil, suffix: " percent remaining") == percentMissingText)
}
