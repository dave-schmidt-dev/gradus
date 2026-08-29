import Foundation
import GradusKit
@testable import GradusMac
import Testing

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
        paceDelta: Double? = nil,
        resetISO: String? = nil,
        data: [String: JSONValue] = [:]
    ) -> ProviderEntry {
        ProviderEntry(
            name: name,
            ok: ok,
            error: ok ? nil : "probe failed",
            windows: percentLeft.map {
                [ProviderWindow(
                    id: "5h", percentLeft: $0, resetISO: resetISO, windowHours: 5, paceDelta: paceDelta
                )]
            } ?? [],
            data: data,
            observedAt: nil
        )
    }

    /// INV-13's Mac half. The menu must consume the same window contract as
    /// iOS, rather than choosing a primary bucket or rendering malformed data.
    @Test func menuParityContractRetainsEveryValidWindowAndLatestDepletedReset() {
        let fiveHourReset = "2026-08-17T14:55:00-04:00"
        let monthlyReset = "2026-08-23T21:30:00-04:00"
        let windows = [
            ProviderWindow(id: "five_hour", percentLeft: 100, resetISO: fiveHourReset, windowHours: 5, paceDelta: nil),
            ProviderWindow(id: "monthly", percentLeft: 0, resetISO: monthlyReset, windowHours: 720, paceDelta: nil),
            ProviderWindow(id: "malformed", percentLeft: .nan, resetISO: nil, windowHours: nil, paceDelta: nil)
        ]
        let now = Date(timeIntervalSince1970: 1_785_000_000)

        #expect(CrossSurfaceParity.visibleWindows(windows).map(\.id) == ["five_hour", "monthly"])
        #expect(
            CrossSurfaceParity.exhaustedResetLabel(windows, now: now)
                == "resets \(friendlyResetDate(monthlyReset, now: now)!)"
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
                    id: "five_hour", percentLeft: 5, resetISO: nil, windowHours: 5, paceDelta: 0.02
                ),
                ProviderWindow(
                    id: "weekly", percentLeft: 70, resetISO: nil, windowHours: 168, paceDelta: -0.28
                )
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
            provider("Critical", percentLeft: 5, paceDelta: -0.50)
        ]) == ["Broken", "Critical", "Healthy"])
    }

    @Test func rampOrdersWorstFirst() {
        #expect(ranked([
            provider("Green", percentLeft: 80, paceDelta: 0.10),
            provider("Orange", percentLeft: 60, paceDelta: -0.20),
            provider("Yellow", percentLeft: 70, paceDelta: -0.05),
            provider("Red", percentLeft: 40, paceDelta: -0.40)
        ]) == ["Red", "Orange", "Yellow", "Green"])
    }

    @Test func mostUrgentUsesVisibleSignalBeforeRemainingPercentage() {
        #expect(ranked([
            provider("Green", percentLeft: 73, paceDelta: 0.10),
            provider("Yellow", percentLeft: 92, paceDelta: -0.05)
        ]) == ["Yellow", "Green"])
    }

    @Test func alternateSortsOverrideUrgencyTiersWithinActiveProviders() {
        let input = [
            provider(
                "Zulu urgent", percentLeft: 10, paceDelta: -0.40,
                resetISO: "2026-08-10T12:00:00Z"
            ),
            provider(
                "Alpha calm", percentLeft: 90, paceDelta: 0.10,
                resetISO: "2026-08-11T12:00:00Z"
            ),
            provider(
                "Mike reset", percentLeft: 80, paceDelta: 0.10,
                resetISO: "2026-08-09T12:00:00Z"
            )
        ]

        #expect(ranked(input, .nameAZ) == ["Alpha calm", "Mike reset", "Zulu urgent"])
        #expect(ranked(input, .resetSoonest) == ["Mike reset", "Zulu urgent", "Alpha calm"])
    }

    /// Equal-severity rows must not reshuffle between refreshes -- a menu
    /// whose order changes while you read it is worse than an arbitrary but
    /// fixed one.
    @Test func tiesBreakOnPercentageThenNameForStableOrdering() {
        let input = [
            provider("Zulu", percentLeft: 50, paceDelta: 0.10),
            provider("Alpha", percentLeft: 50, paceDelta: 0.10),
            provider("Mike", percentLeft: 20, paceDelta: 0.10)
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
            provider("Broken", ok: false)
        ]) == ["Broken", "Healthy", "Spent"])
    }

    /// A sort mode is a *presentation* choice and must not be able to pull a
    /// depleted provider back up among the actionable ones.
    @Test func depletedStaysLastInEverySortMode() {
        let input = [
            provider("Spent", percentLeft: 0, paceDelta: -0.90),
            provider("Zulu", percentLeft: 60, paceDelta: 0.10),
            provider("Alpha", percentLeft: 80, paceDelta: 0.10)
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
                provider("Healthy", percentLeft: 90, paceDelta: 0.10)
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
                ProviderWindow(id: "weekly", percentLeft: 12, resetISO: nil, windowHours: 168, paceDelta: 0)
            ],
            data: [:],
            observedAt: nil
        )
        #expect(ProviderTriage.worstWindow(entry)?.id == "weekly")
    }

    // MARK: - MenuHeader & Credit Parity

    @Test func menuHeaderReportsUnavailableWhenEmptyAttentionWhenLowAndHealthyWhenClear() {
        #expect(MenuHeader.statusText(providers: []) == "usage unavailable")

        let healthy = [
            provider("Codex", percentLeft: 80, paceDelta: 0.05),
            provider("Claude", percentLeft: 90, paceDelta: 0.10)
        ]
        #expect(MenuHeader.statusText(providers: healthy) == "all healthy")

        let oneLow = [
            provider("Codex", percentLeft: 80, paceDelta: 0.05),
            provider("Broken", ok: false)
        ]
        #expect(MenuHeader.statusText(providers: oneLow) == "1 low")

        let twoLow = [
            provider("Codex", percentLeft: 10, paceDelta: -0.40),
            provider("Broken", ok: false)
        ]
        #expect(MenuHeader.statusText(providers: twoLow) == "2 low")
    }

    @Test func providerRowsShowOptionalCreditParityAndOmitInvalidData() {
        // Valid provider credit summaries
        let opencode = provider("OpenCode Go", percentLeft: 80, data: ["zen_credit": .double(12.345)])
        #expect(providerCreditSummary(opencode) == "Zen credit $12.345")
        #expect(menuProviderCredit(opencode)?.label == "Zen credit")
        #expect(menuProviderCredit(opencode)?.value == "$12.345")

        let codex = provider("Codex", percentLeft: 80, data: ["credits": .double(2500)])
        #expect(providerCreditSummary(codex) == "Credits 2,500")
        #expect(menuProviderCredit(codex)?.label == "Credits")
        #expect(menuProviderCredit(codex)?.value == "2,500")

        let codexInteger = provider("Codex", percentLeft: 80, data: ["credits": .double(125)])
        #expect(providerCreditSummary(codexInteger) == "Credits 125")

        let claude = provider("Claude", percentLeft: 80, data: ["credit_balance": .double(87.75)])
        #expect(providerCreditSummary(claude) == "Credit $87.75")
        #expect(menuProviderCredit(claude)?.label == "Credit")
        #expect(menuProviderCredit(claude)?.value == "$87.75")

        let cursor = provider("Cursor", percentLeft: 80, data: ["credit_balance": .double(5)])
        #expect(providerCreditSummary(cursor) == "Credit $5.00")
        #expect(menuProviderCredit(cursor)?.label == "Credit")
        #expect(menuProviderCredit(cursor)?.value == "$5.00")

        // Missing data
        let missingCredit = provider("Codex", percentLeft: 80)
        #expect(providerCreditSummary(missingCredit) == nil)
        #expect(menuProviderCredit(missingCredit) == nil)

        // Negative data
        let negativeZen = provider("OpenCode Go", percentLeft: 80, data: ["zen_credit": .double(-1.0)])
        #expect(providerCreditSummary(negativeZen) == nil)

        let negativeCredits = provider("Codex", percentLeft: 80, data: ["credits": .double(-100)])
        #expect(providerCreditSummary(negativeCredits) == nil)

        let negativeClaude = provider("Claude", percentLeft: 80, data: ["credit_balance": .double(-5.50)])
        #expect(providerCreditSummary(negativeClaude) == nil)

        // Non-finite data
        let nanCredit = provider("Claude", percentLeft: 80, data: ["credit_balance": .double(.nan)])
        #expect(providerCreditSummary(nanCredit) == nil)

        let infCredit = provider("Cursor", percentLeft: 80, data: ["credit_balance": .double(.infinity)])
        #expect(providerCreditSummary(infCredit) == nil)

        // Provider-mismatched data
        let codexWithZen = provider("Codex", percentLeft: 80, data: ["zen_credit": .double(12.345)])
        #expect(providerCreditSummary(codexWithZen) == nil)

        let codexWithBalance = provider("Codex", percentLeft: 80, data: ["credit_balance": .double(50.0)])
        #expect(providerCreditSummary(codexWithBalance) == nil)

        let claudeWithZen = provider("Claude", percentLeft: 80, data: ["zen_credit": .double(12.345)])
        #expect(providerCreditSummary(claudeWithZen) == nil)

        let claudeWithCredits = provider("Claude", percentLeft: 80, data: ["credits": .double(500)])
        #expect(providerCreditSummary(claudeWithCredits) == nil)

        let cursorWithCredits = provider("Cursor", percentLeft: 80, data: ["credits": .double(500)])
        #expect(providerCreditSummary(cursorWithCredits) == nil)

        let opencodeWithBalance = provider("OpenCode Go", percentLeft: 80, data: ["credit_balance": .double(10.0)])
        #expect(providerCreditSummary(opencodeWithBalance) == nil)

        let unrelated = provider("Vibe", percentLeft: 80, data: ["credit_balance": .double(10.0)])
        #expect(providerCreditSummary(unrelated) == nil)
    }
}
