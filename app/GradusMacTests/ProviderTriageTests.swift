import GradusKit
import Testing

@testable import GradusMac

/// Locks the menu's ordering and its "needs attention" rule.
///
/// Both are easy to break silently: a broken sort still renders every
/// provider, and a broken attention rule still renders every row -- the menu
/// just stops putting the urgent one first, or starts showing the metadata
/// line on all eight and undoes the density work. Neither shows up as a
/// failure in a snapshot of a healthy fixture.
@Suite("Provider triage")
struct ProviderTriageTests {
    private func provider(
        _ name: String,
        ok: Bool = true,
        percentLeft: Double? = nil,
        paceDelta: Double? = nil
    ) -> ProviderEntry {
        ProviderEntry(
            name: name,
            ok: ok,
            error: ok ? nil : "probe failed",
            windows: percentLeft.map {
                [ProviderWindow(
                    id: "5h", percentLeft: $0, resetISO: nil, windowHours: 5, paceDelta: paceDelta
                )]
            } ?? [],
            data: [:],
            observedAt: nil
        )
    }

    // MARK: - needsAttention

    @Test func healthyPaceDoesNotNeedAttention() {
        #expect(!ProviderTriage.needsAttention(provider("Codex", percentLeft: 72, paceDelta: 0.05)))
    }

    /// Yellow is deliberately *not* attention: `windowWarns` alerts at
    /// `paceDelta < -0.10`, which is orange-or-worse, so a yellow row that
    /// expanded here would disagree with the notification.
    @Test func yellowDoesNotNeedAttention() {
        #expect(!ProviderTriage.needsAttention(provider("Claude", percentLeft: 50, paceDelta: -0.05)))
    }

    @Test func orangeAndRedNeedAttention() {
        #expect(ProviderTriage.needsAttention(provider("Cursor", percentLeft: 50, paceDelta: -0.20)))
        #expect(ProviderTriage.needsAttention(provider("Vibe", percentLeft: 50, paceDelta: -0.40)))
    }

    @Test func failedProviderNeedsAttention() {
        #expect(ProviderTriage.needsAttention(provider("Copilot", ok: false)))
    }

    /// The rule that makes this a *pace* ramp rather than a percentage
    /// threshold: nearly empty but consuming slower than the clock is fine,
    /// and flagging it would cry wolf every time a window neared its reset.
    @Test func nearlyEmptyButAheadOfPaceIsNotAttention() {
        #expect(!ProviderTriage.needsAttention(provider("OpenCode Go", percentLeft: 3, paceDelta: 0.10)))
    }

    /// Depletion overrides pace -- there is nothing left to pace.
    @Test func depletedNeedsAttentionRegardlessOfPace() {
        #expect(ProviderTriage.needsAttention(provider("Cursor", percentLeft: 0, paceDelta: 0.50)))
    }

    @Test func providerWithNoWindowsDoesNotNeedAttention() {
        #expect(!ProviderTriage.needsAttention(provider("Empty")))
    }

    // MARK: - sorted

    @Test func failuresSortAboveEverything() {
        let sorted = ProviderTriage.sorted([
            provider("Healthy", percentLeft: 90, paceDelta: 0.10),
            provider("Broken", ok: false),
            provider("Critical", percentLeft: 5, paceDelta: -0.50),
        ])
        #expect(sorted.map(\.name) == ["Broken", "Critical", "Healthy"])
    }

    @Test func rampOrdersWorstFirst() {
        let sorted = ProviderTriage.sorted([
            provider("Green", percentLeft: 80, paceDelta: 0.10),
            provider("Orange", percentLeft: 60, paceDelta: -0.20),
            provider("Yellow", percentLeft: 70, paceDelta: -0.05),
            provider("Red", percentLeft: 40, paceDelta: -0.40),
        ])
        #expect(sorted.map(\.name) == ["Red", "Orange", "Yellow", "Green"])
    }

    /// Equal-severity rows must not reshuffle between refreshes -- a menu
    /// whose order changes while you read it is worse than an arbitrary but
    /// fixed one.
    @Test func tiesBreakOnPercentageThenNameForStableOrdering() {
        let input = [
            provider("Zulu", percentLeft: 50, paceDelta: 0.10),
            provider("Alpha", percentLeft: 50, paceDelta: 0.10),
            provider("Mike", percentLeft: 20, paceDelta: 0.10),
        ]
        #expect(ProviderTriage.sorted(input).map(\.name) == ["Mike", "Alpha", "Zulu"])
        #expect(ProviderTriage.sorted(input.reversed()).map(\.name) == ["Mike", "Alpha", "Zulu"])
    }

    @Test func worstWindowIsTheOneClosestToDepletion() {
        let entry = ProviderEntry(
            name: "Multi",
            ok: true,
            error: nil,
            windows: [
                ProviderWindow(id: "5h", percentLeft: 80, resetISO: nil, windowHours: 5, paceDelta: 0),
                ProviderWindow(id: "weekly", percentLeft: 12, resetISO: nil, windowHours: 168, paceDelta: 0),
            ],
            data: [:],
            observedAt: nil
        )
        #expect(ProviderTriage.worstWindow(entry)?.id == "weekly")
    }
}
