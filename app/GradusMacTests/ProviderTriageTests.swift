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

    /// The Mac-side half of the 2026-08-06 unification: attention asks about
    /// every window, not just the worst-by-percentage one.
    ///
    /// This fixture is the case the old rule got wrong. `worstWindow` picks
    /// `five_hour` at 5%, which is comfortably on pace and green, so the menu
    /// showed nothing while iOS -- which had always asked about any window --
    /// counted this provider as warning. Same snapshot, two answers.
    @Test func attentionAsksAboutEveryWindowNotJustTheWorst() {
        let multiWindow = ProviderEntry(
            name: "Codex",
            ok: true,
            error: nil,
            windows: [
                // Physically reachable pace values -- see the note on
                // `providerAttentionAsksAboutEveryWindowNotJustTheWorst` in
                // GradusKitTests for why 80%/-0.5 would not be.
                ProviderWindow(
                    id: "five_hour", percentLeft: 5, resetISO: nil, windowHours: 5, paceDelta: 0.02),
                ProviderWindow(
                    id: "weekly", percentLeft: 70, resetISO: nil, windowHours: 168, paceDelta: -0.28),
            ],
            data: [:],
            observedAt: nil
        )

        #expect(ProviderTriage.worstWindow(multiWindow)?.id == "five_hour")
        #expect(ProviderTriage.needsAttention(multiWindow))
    }

    // MARK: - ordering (shared `rankedPartition`)

    /// The Mac's threshold default, so these assertions describe what ships
    /// rather than an arbitrary number.
    private let threshold = PublisherViewModel.defaultLocalWarningThresholdPercent

    private func ranked(_ providers: [ProviderEntry], _ option: ProviderSortOption = .mostUrgent) -> [String] {
        rankProviders(providers, localThreshold: threshold, sortOption: option).map(\.name)
    }

    @Test func failuresSortAboveEverything() {
        #expect(ranked([
            provider("Healthy", percentLeft: 90, paceDelta: 0.10),
            provider("Broken", ok: false),
            provider("Critical", percentLeft: 5, paceDelta: -0.50),
        ]) == ["Broken", "Critical", "Healthy"])
    }

    @Test func rampOrdersWorstFirst() {
        #expect(ranked([
            provider("Green", percentLeft: 80, paceDelta: 0.10),
            provider("Orange", percentLeft: 60, paceDelta: -0.20),
            provider("Yellow", percentLeft: 70, paceDelta: -0.05),
            provider("Red", percentLeft: 40, paceDelta: -0.40),
        ]) == ["Red", "Orange", "Yellow", "Green"])
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
        #expect(ranked(input) == ["Mike", "Alpha", "Zulu"])
        #expect(ranked(input.reversed()) == ["Mike", "Alpha", "Zulu"])
    }

    // MARK: - exhausted partition

    /// The regression this whole change exists to prevent. The old
    /// `ProviderTriage.sorted` ranked by signal level, and a depleted provider
    /// is red -- so "Spent" sorted **first**, above providers the user could
    /// still act on, while iOS put it last. Nothing caught it: every row still
    /// rendered, just in the opposite order from the other app.
    @Test func depletedSortsLastDespiteBeingRed() {
        #expect(ranked([
            provider("Spent", percentLeft: 0, paceDelta: -0.90),
            provider("Healthy", percentLeft: 90, paceDelta: 0.10),
            provider("Broken", ok: false),
        ]) == ["Broken", "Healthy", "Spent"])
    }

    /// A sort mode is a *presentation* choice and must not be able to pull a
    /// depleted provider back up among the actionable ones.
    @Test func depletedStaysLastInEverySortMode() {
        let input = [
            provider("Spent", percentLeft: 0, paceDelta: -0.90),
            provider("Zulu", percentLeft: 60, paceDelta: 0.10),
            provider("Alpha", percentLeft: 80, paceDelta: 0.10),
        ]
        for option in ProviderSortOption.allCases {
            #expect(ranked(input, option).last == "Spent", "sort mode \(option.rawValue)")
        }
    }

    @Test func partitionSeparatesExhaustedFromActive() {
        let split = rankedPartition(
            [
                provider("Spent", percentLeft: 0, paceDelta: -0.90),
                provider("AlsoSpent", percentLeft: 0.4, paceDelta: 0),
                provider("Healthy", percentLeft: 90, paceDelta: 0.10),
            ],
            localThreshold: threshold
        )
        #expect(split.active.map(\.name) == ["Healthy"])
        // Ordered within the partition too: 0% is worse than 0.4%, and the
        // exhausted group is sorted by the same comparator as the active one.
        #expect(split.exhausted.map(\.name) == ["Spent", "AlsoSpent"])
    }

    /// `percentIsDepleted`'s boundary, restated against the Mac's own model:
    /// exactly 0.5 renders as 1% once rounded and still has something to
    /// spend, so it stays active. Recomputing depletion from windows here (the
    /// Mac has no stored `isDepleted`) is the seam where the two platforms
    /// could drift apart, so it gets its own assertion.
    @Test func depletionBoundaryMatchesTheSharedPredicate() {
        #expect(provider("Edge", percentLeft: 0.5).rankingIsDepleted == false)
        #expect(provider("Edge", percentLeft: 0.49).rankingIsDepleted == true)
        #expect(provider("NoWindows").rankingIsDepleted == false)
    }

    /// The local threshold may only ever *add* providers to the attention
    /// tier. If raising it could clear a pace warning the shared ramp already
    /// raised, the setting would be a way to silence real alerts.
    @Test func thresholdOnlyAddsToAttentionNeverRemoves() {
        let paceWarned = provider("Burning", percentLeft: 50, paceDelta: -0.40)
        #expect(paceWarned.rankingNeedsAttention(localThreshold: 0))
        #expect(paceWarned.rankingNeedsAttention(localThreshold: 100))

        let calm = provider("Calm", percentLeft: 50, paceDelta: 0.10)
        #expect(!calm.rankingNeedsAttention(localThreshold: 20))
        #expect(calm.rankingNeedsAttention(localThreshold: 50))
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

    // MARK: - displayWindow

    /// Multi-window fixtures for the display rule. Pace values here are all
    /// physically reachable — `paceDelta` is `fraction_left` minus
    /// `fraction_of_window_remaining`, so e.g. 50% left at -0.40 means 90% of
    /// the window still to run and half the budget already gone. An impossible
    /// pace would still classify and still pass, while describing a snapshot
    /// the app can never produce.
    private func windows(
        _ specs: [(id: String, percentLeft: Double, paceDelta: Double?)]
    ) -> ProviderEntry {
        ProviderEntry(
            name: "Multi",
            ok: true,
            error: nil,
            windows: specs.map {
                ProviderWindow(
                    id: $0.id, percentLeft: $0.percentLeft, resetISO: nil,
                    windowHours: 5, paceDelta: $0.paceDelta
                )
            },
            data: [:],
            observedAt: nil
        )
    }

    /// Row 36. The same fixture as `attentionAsksAboutEveryWindowNotJustTheWorst`,
    /// asking the follow-up question: having decided this provider warrants
    /// attention, which window does the row put on screen? Before this rule it
    /// drew `five_hour` — 5% left, on pace, green — so the menu alerted and then
    /// showed a healthy window with "2% ahead" underneath it.
    @Test func displayWindowShowsTheWindowThatTriggeredAttention() {
        let entry = windows([
            ("five_hour", 5, 0.02),   // green: nearly spent, but on pace
            ("weekly", 70, -0.28),    // red: plenty left, burning far too fast
        ])

        #expect(ProviderTriage.worstWindow(entry)?.id == "five_hour")
        #expect(ProviderTriage.displayWindow(entry)?.id == "weekly")
    }

    /// Severity outranks depletion. This is the only case where the new rule
    /// and the old one disagree on a provider whose windows all warn, so it is
    /// the assertion that actually pins the ordering.
    @Test func displayWindowPrefersSeverityOverDepletion() {
        let entry = windows([
            ("low_but_orange", 10, -0.15),  // orange, and the worst by percentage
            ("high_but_red", 50, -0.40),    // red
        ])

        #expect(ProviderTriage.worstWindow(entry)?.id == "low_but_orange")
        #expect(ProviderTriage.displayWindow(entry)?.id == "high_but_red")
    }

    /// Within one severity step the rule falls back to depletion, which is what
    /// keeps this change small: two red windows are the common multi-window
    /// warning shape, and for them the row shows exactly what it always did.
    @Test func displayWindowBreaksSeverityTiesByDepletion() {
        let entry = windows([
            ("red_higher", 30, -0.30),
            ("red_lower", 5, -0.30),
        ])

        #expect(ProviderTriage.worstWindow(entry)?.id == "red_lower")
        #expect(ProviderTriage.displayWindow(entry)?.id == "red_lower")
    }

    /// Nothing warns, so there is no triggering window and the calm row is
    /// unchanged. Without this the rule could quietly start returning nil and
    /// collapse every healthy row to the "no window data" branch.
    @Test func displayWindowFallsBackToWorstWhenNothingWarns() {
        let entry = windows([
            ("healthy_high", 80, 0.30),
            ("healthy_low", 45, 0.05),
        ])

        #expect(ProviderTriage.worstWindow(entry)?.id == "healthy_low")
        #expect(ProviderTriage.displayWindow(entry)?.id == "healthy_low")
    }

    @Test func displayWindowIsNilOnlyWhenThereAreNoWindows() {
        #expect(ProviderTriage.displayWindow(provider("Empty")) == nil)
    }
}
