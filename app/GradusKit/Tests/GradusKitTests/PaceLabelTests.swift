import Foundation
@testable import GradusKit
import Testing

// The shared truth table is the contract; these tests are its Swift half.
// `tests/test_ui.py::PaceLabelTruthTableTests` asserts the same rows against
// the TUI, so a one-sided wording edit fails on both sides.

private struct TruthTableCase {
    let paceDelta: Double?
    let label: String
    let why: String
}

private func loadTruthTable() throws -> [TruthTableCase] {
    let url = try #require(
        Bundle.module.url(forResource: "pace-labels", withExtension: "json"),
        "pace-labels.json is missing from the test bundle -- check the resources list in Package.swift"
    )
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    let cases = try #require(root?["cases"] as? [[String: Any]])
    return cases.map { row in
        TruthTableCase(
            paceDelta: (row["pace_delta"] as? NSNumber)?.doubleValue,
            label: row["label"] as? String ?? "",
            why: row["why"] as? String ?? ""
        )
    }
}

@Test func paceLabelMatchesSharedTruthTable() throws {
    let table = try loadTruthTable()
    #expect(table.count >= 6, "truth table shrank -- boundary coverage was removed")

    for row in table {
        let actual = paceLabel(paceDelta: row.paceDelta)
        #expect(
            actual == row.label,
            "pace=\(String(describing: row.paceDelta)) expected \(row.label), got \(actual). \(row.why)"
        )
    }
}

@Test func missingOrNonFiniteDeltaIsUnavailable() {
    #expect(paceLabel(paceDelta: nil) == "pace unavailable")
    #expect(paceLabel(paceDelta: .nan) == "pace unavailable")
    #expect(paceLabel(paceDelta: .infinity) == "pace unavailable")
}

@Test func paceWindowOverloadAgreesWithScalarForm() {
    let window = ProviderWindow(
        id: "weekly", percentLeft: 20, resetISO: nil, windowHours: 168, paceDelta: -0.28
    )
    #expect(paceLabel(for: window) == paceLabel(paceDelta: -0.28))
}
