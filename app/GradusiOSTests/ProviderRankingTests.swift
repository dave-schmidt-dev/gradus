import Foundation
import GradusKit
import Testing

@testable import GradusiOS

// P3/T3.1 gate: `rankProviders`'s total order (errored -> attention-needed
// -> normal, percent-ascending within tier, providerName tie-break) and
// `localIsUrgent`'s threshold boundary, following `DesignTokensTests.swift`'s
// Swift Testing conventions.

private let fixedDate = Date(timeIntervalSince1970: 1_785_000_000)

private func makeWindow(percentLeft: Double, paceDelta: Double? = nil) -> ProviderWindow {
    ProviderWindow(id: "weekly", percentLeft: percentLeft, resetISO: nil, windowHours: 168, paceDelta: paceDelta)
}

private func makeProvider(
    name: String,
    ok: Bool = true,
    errorMessage: String? = nil,
    windows: [ProviderWindow] = [],
    isWarning: Bool? = nil
) -> ProviderStatus {
    ProviderStatus(
        providerName: name,
        providerDisplayName: name,
        ok: ok,
        errorMessage: errorMessage,
        windows: windows,
        data: [:],
        observedAt: nil,
        snapshotUpdatedAt: "2026-08-02T20:00:00-04:00",
        publishedAt: fixedDate,
        isWarning: isWarning
    )
}

// MARK: - localIsUrgent boundaries

@Test func localIsUrgentAboveThresholdIsFalse() {
    #expect(!localIsUrgent(makeWindow(percentLeft: 21), threshold: 20))
}

@Test func localIsUrgentAtThresholdIsTrue() {
    #expect(localIsUrgent(makeWindow(percentLeft: 20), threshold: 20))
}

@Test func localIsUrgentBelowThresholdIsTrue() {
    #expect(localIsUrgent(makeWindow(percentLeft: 5), threshold: 20))
}

@Test func localIsUrgentDepletedIsTrueRegardlessOfThreshold() {
    #expect(localIsUrgent(makeWindow(percentLeft: 0), threshold: 0))
}

// MARK: - rankProviders tiering

@Test func erroredProviderWithNoWindowsRanksFirstRegardlessOfOthers() {
    let errored = makeProvider(name: "cursor", ok: false, errorMessage: "boom", windows: [])
    let healthy = makeProvider(name: "codex", windows: [makeWindow(percentLeft: 99)])
    let ranked = rankProviders([healthy, errored], localThreshold: 20)
    #expect(ranked.map(\.providerName) == ["cursor", "codex"])
}

@Test func attentionTierUnionPredicateCorrectness() {
    // The exact bug the adjudicator caught: a window whose `isWarning` came
    // from the pace-based trigger (paceDelta < -0.10), not the percent
    // threshold. Constructed via the memberwise init with `isWarning: true`
    // explicit, so it does not depend on `windowWarns` recomputation --
    // the window's own percentLeft (50) sits well above the 20 threshold, so
    // `localIsUrgent` alone would independently evaluate `false` for it.
    let paceWarned = makeProvider(
        name: "antigravity-claude",
        windows: [makeWindow(percentLeft: 50, paceDelta: -0.30)],
        isWarning: true
    )
    #expect(paceWarned.isWarning)
    #expect(!paceWarned.windows.contains { localIsUrgent($0, threshold: 20) })

    let normal = makeProvider(name: "codex", windows: [makeWindow(percentLeft: 45)])

    let ranked = rankProviders([normal, paceWarned], localThreshold: 20)

    // paceWarned must land in tier 2 (attention), ahead of codex's tier 3
    // (normal) -- ranking on `localIsUrgent` alone would have put codex
    // first (45 < 50), which is exactly the regression this fix prevents.
    #expect(ranked.map(\.providerName) == ["antigravity-claude", "codex"])
}

@Test func localThresholdCanOnlyAddToAttentionTierNeverRemove() {
    // A provider with isWarning == true but no window data at all (windows
    // == []) still must not be demoted by a localIsUrgent check that has
    // nothing to evaluate.
    let warned = makeProvider(name: "vibe", windows: [], isWarning: true)
    let normal = makeProvider(name: "codex", windows: [makeWindow(percentLeft: 99)])
    let ranked = rankProviders([normal, warned], localThreshold: 20)
    #expect(ranked.map(\.providerName) == ["vibe", "codex"])
}

// MARK: - percent-ascending within tier, no-data-last

@Test func withinAttentionTierSortsByWorstWindowPercentAscending() {
    let lowest = makeProvider(name: "b", windows: [makeWindow(percentLeft: 5)], isWarning: true)
    let higher = makeProvider(name: "a", windows: [makeWindow(percentLeft: 15)], isWarning: true)
    let ranked = rankProviders([higher, lowest], localThreshold: 20)
    #expect(ranked.map(\.providerName) == ["b", "a"])
}

@Test func noWindowDataSortsLastWithinItsTier() {
    let noData = makeProvider(name: "a", windows: [], isWarning: true)
    let withData = makeProvider(name: "z", windows: [makeWindow(percentLeft: 10)], isWarning: true)
    let ranked = rankProviders([noData, withData], localThreshold: 20)
    #expect(ranked.map(\.providerName) == ["z", "a"])
}

// MARK: - tie-breaker determinism

@Test func equalPercentLeftTieBreaksByProviderNameAscending() {
    let providerZ = makeProvider(name: "zeta", windows: [makeWindow(percentLeft: 50)])
    let providerA = makeProvider(name: "alpha", windows: [makeWindow(percentLeft: 50)])
    let ranked = rankProviders([providerZ, providerA], localThreshold: 20)
    #expect(ranked.map(\.providerName) == ["alpha", "zeta"])
}

@Test func twoErroredProvidersTieBreakByProviderNameAscending() {
    let providerZ = makeProvider(name: "zeta", ok: false, errorMessage: "e")
    let providerA = makeProvider(name: "alpha", ok: false, errorMessage: "e")
    let ranked = rankProviders([providerZ, providerA], localThreshold: 20)
    #expect(ranked.map(\.providerName) == ["alpha", "zeta"])
}

@Test func tieBreakerDeterministicAcrossRepeatedRuns() {
    let providerZ = makeProvider(name: "zeta", windows: [makeWindow(percentLeft: 50)])
    let providerA = makeProvider(name: "alpha", windows: [makeWindow(percentLeft: 50)])
    for _ in 0..<10 {
        let ranked = rankProviders([providerZ, providerA], localThreshold: 20)
        #expect(ranked.map(\.providerName) == ["alpha", "zeta"])
    }
}
