import Foundation
@testable import GradusiOS
import GradusKit
import Testing

// P3/T3.1 gate: `rankProviders`'s total order (errored -> attention-needed
// -> normal, percent-ascending within tier, providerName tie-break) and
// `localIsUrgent`'s threshold boundary, following `DesignTokensTests.swift`'s
// Swift Testing conventions.

private let fixedDate = Date(timeIntervalSince1970: 1_785_000_000)

private func makeWindow(
    percentLeft: Double,
    resetISO: String? = nil,
    paceDelta: Double? = nil
) -> ProviderWindow {
    ProviderWindow(id: "weekly", percentLeft: percentLeft, resetISO: resetISO, windowHours: 168, paceDelta: paceDelta)
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
    for _ in 0 ..< 10 {
        let ranked = rankProviders([providerZ, providerA], localThreshold: 20)
        #expect(ranked.map(\.providerName) == ["alpha", "zeta"])
    }
}

// MARK: - device-local presentation sorts

@Test func sortModesReorderTheCompleteActivePartitionAndKeepExhaustedProvidersLast() {
    let error = makeProvider(name: "error", ok: false, errorMessage: "offline")
    let urgent = makeProvider(
        name: "urgent",
        windows: [makeWindow(percentLeft: 10, resetISO: "2026-08-06T12:00:00Z")],
        isWarning: true
    )
    let resetSoon = makeProvider(
        name: "reset",
        windows: [makeWindow(percentLeft: 80, resetISO: "2026-08-05T12:00:00Z")],
        isWarning: true
    )
    let noData = makeProvider(name: "no-data", windows: [], isWarning: true)
    let normal = makeProvider(
        name: "normal",
        windows: [makeWindow(percentLeft: 50, resetISO: "2026-08-07T12:00:00Z")]
    )
    let exhausted = makeProvider(
        name: "aardvark-exhausted",
        windows: [makeWindow(percentLeft: 0, resetISO: "2026-08-04T12:00:00Z")]
    )
    let providers = [normal, exhausted, resetSoon, noData, urgent, error]

    #expect(rankProviders(providers, localThreshold: 20, sortOption: .mostUrgent).map(\.providerName) == [
        "error", "urgent", "reset", "no-data", "normal", "aardvark-exhausted"
    ])
    #expect(rankProviders(providers, localThreshold: 20, sortOption: .resetSoonest).map(\.providerName) == [
        "reset", "urgent", "normal", "error", "no-data", "aardvark-exhausted"
    ])
    #expect(rankProviders(providers, localThreshold: 20, sortOption: .nameAZ).map(\.providerName) == [
        "error", "no-data", "normal", "reset", "urgent", "aardvark-exhausted"
    ])
}

@Test func nameSortRetainsProviderNameTieBreakerAndNoWindowFallback() {
    let noWindow = makeProvider(name: "zeta", windows: [], isWarning: true)
    let alpha = makeProvider(name: "alpha", windows: [makeWindow(percentLeft: 40)], isWarning: true)
    let beta = makeProvider(name: "beta", windows: [makeWindow(percentLeft: 60)], isWarning: true)

    let ranked = rankProviders([noWindow, beta, alpha], localThreshold: 20, sortOption: .nameAZ)

    #expect(ranked.map(\.providerName) == ["alpha", "beta", "zeta"])
    #expect(noWindow.windows.isEmpty)
    #expect(noWindow.windows.first?.percentLeft == nil)
    #expect(noWindow.windows.first?.resetISO == nil)
}

@Test func mostUrgentUsesVisibleSignalBeforeRemainingPercentage() {
    let green = makeProvider(
        name: "green",
        windows: [makeWindow(percentLeft: 73, paceDelta: 0.10)]
    )
    let yellow = makeProvider(
        name: "yellow",
        windows: [makeWindow(percentLeft: 92, paceDelta: -0.05)]
    )

    #expect(rankProviders([green, yellow], localThreshold: 20, sortOption: .mostUrgent)
        .map(\.providerName) == ["yellow", "green"])
}
