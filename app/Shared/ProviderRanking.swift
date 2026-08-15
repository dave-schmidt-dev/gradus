import Foundation
import GradusKit

/// Device-local presentation order for dashboard providers. Raw values are
/// persisted only in `UserDefaults`; this type is intentionally separate from
/// `ProviderStatus`, which is encoded into CloudKit records.
public enum ProviderSortOption: String, CaseIterable, Identifiable {
    case mostUrgent
    case resetSoonest
    case nameAZ

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .mostUrgent: "Most urgent"
        case .resetSoonest: "Reset soonest"
        case .nameAZ: "Name A-Z"
        }
    }
}

/// A window is locally urgent when it's depleted (mirrors
/// `GradusKit.percentIsDepleted`) OR its `percentLeft` is at/below the
/// caller-supplied local threshold. Invalid percentages are never urgent
/// candidates, matching `windowWarns`'s own guard.
///
/// Device-local by definition, and must never be confused with the shared,
/// fixed `GradusKit.windowWarns` (Key decision #5,
/// `ios-design-system-2026-08-03.md`) -- which is why this lives here and not
/// in `GradusKit`, whose scope is governed by INV-7.
func localIsUrgent(_ window: ProviderWindow, threshold: Double) -> Bool {
    guard percentIsValid(window.percentLeft) else { return false }
    return percentIsDepleted(window.percentLeft) || window.percentLeft <= threshold
}

/// What ranking needs from a provider, independent of which model carries it.
///
/// This protocol is the reason the file sits in `Shared/` (compiled into both
/// app targets) rather than in `GradusiOS/`, where it started. Keeping it
/// iOS-only is what let the Mac grow its own contradictory order: `ProviderTriage`
/// ranked by signal level, and since a depleted provider is red, the Mac sorted
/// exhausted providers to the *top* -- the exact opposite of `rankedPartition`.
/// One ranking implementation, two conformances, is what keeps that from
/// silently happening again.
///
/// The two models differ in one way that matters: `ProviderStatus` *stores*
/// `isDepleted`/`isWarning` (the Mac publisher stamps them onto the CloudKit
/// record), while `ProviderEntry` stores neither. See each conformance for how
/// it closes that gap.
protocol RankableProvider {
    /// Deterministic final tie-breaker, and the identity shown to the user.
    var rankingName: String { get }
    var rankingWindows: [ProviderWindow] { get }
    /// `false` means the provider's probe failed without retained windows;
    /// carried failures keep their `ok:false` payload for diagnostics but do
    /// not sort as actionable errors while a reading remains available.
    var rankingIsOK: Bool { get }
    /// Whether this provider belongs in the exhausted partition at the bottom.
    var rankingIsDepleted: Bool { get }
    /// Whether this provider belongs in the attention tier within its
    /// partition. Still a conformance point, but no longer a divergence: since
    /// 2026-08-06 both platforms answer with `GradusKit.providerNeedsAttention`
    /// unioned with the caller's local threshold. iOS reads it from the stored
    /// `isWarning` the publisher stamped, the Mac evaluates it directly,
    /// because only `ProviderStatus` carries the field. The two rules used to
    /// differ in both the per-window predicate and the aggregation, which is
    /// how the Mac's "N low" badge and the iPhone's warning count could
    /// disagree about one snapshot.
    func rankingNeedsAttention(localThreshold: Double) -> Bool
}

/// Providers split into the two groups that render differently: active rows
/// carry the full treatment, exhausted rows a minimal one. Both are already
/// sorted; `all` is the flat order for callers that render a single list.
struct RankedProviders<P: RankableProvider> {
    let active: [P]
    let exhausted: [P]

    var all: [P] {
        active + exhausted
    }
}

/// The single, total-order ranking function for both platforms' provider
/// lists, partitioned so exhausted providers can be rendered differently.
///
/// Within each partition, three tiers, most urgent first:
///
/// 1. Errored providers (`!rankingIsOK`).
/// 2. Among OK providers, "attention-needed" per `rankingNeedsAttention`.
///    **That must be a union of the platform's own warning signal and the
///    local threshold, never the threshold alone.** Key decision #6
///    (`ios-design-system-2026-08-03.md`): the adjudicator (Gemini, AJ-1)
///    caught an earlier draft ranking on `localIsUrgent` alone, on the false
///    claim that it's a superset of `windowWarns`. It isn't: a window with
///    `paceDelta < -0.10` warns regardless of `percentLeft` (e.g. 50%
///    remaining, burning fast), so it can warn while `localIsUrgent` is
///    `false` (its `percentLeft` sits above the threshold). Ranking on
///    `localIsUrgent` alone would rank a provider the system already warned
///    about *behind* providers it never flagged. The union fixes this: the
///    platform signal guarantees nothing already flagged is demoted, and the
///    threshold can only ever *add* providers to this tier.
/// 3. OK providers with neither flag set.
///
/// `mostUrgent` preserves the three urgency tiers. The other two options are
/// true ordering modes over the complete partition: `resetSoonest` puts a
/// missing reset last, and `nameAZ` is alphabetical. The exhausted partition
/// is still always appended after the active one. "Most urgent" follows the
/// signal the user can see (red through green), then the lowest remaining
/// percentage within the same signal. Final deterministic tie-breaker is
/// ascending `rankingName`.
func rankedPartition<P: RankableProvider>(
    _ providers: [P],
    localThreshold: Double,
    sortOption: ProviderSortOption = .mostUrgent
) -> RankedProviders<P> {
    // Keep the active/exhausted split independent of every presentation
    // comparator. This avoids a mode change moving depleted providers back
    // into the active group, while preserving each provider's payload intact.
    RankedProviders(
        active: sortPartition(
            providers.filter { !$0.rankingIsDepleted },
            localThreshold: localThreshold,
            sortOption: sortOption
        ),
        exhausted: sortPartition(
            providers.filter(\.rankingIsDepleted),
            localThreshold: localThreshold,
            sortOption: sortOption
        )
    )
}

/// `rankedPartition` flattened, for callers rendering one undivided list.
func rankProviders<P: RankableProvider>(
    _ providers: [P],
    localThreshold: Double,
    sortOption: ProviderSortOption = .mostUrgent
) -> [P] {
    rankedPartition(providers, localThreshold: localThreshold, sortOption: sortOption).all
}

private func sortPartition<P: RankableProvider>(
    _ providers: [P],
    localThreshold: Double,
    sortOption: ProviderSortOption
) -> [P] {
    providers.sorted { lhs, rhs in
        // Each comparator returns `nil` when it has no opinion, deferring to
        // the deterministic name tie-break below -- exactly what the old
        // fallthrough-to-the-bottom-of-the-switch did.
        let comparison: Bool? =
            switch sortOption {
            case .mostUrgent:
                compareMostUrgent(lhs, rhs, localThreshold: localThreshold)
            case .resetSoonest:
                compareResetSoonest(lhs, rhs)
            case .nameAZ:
                nil
            }
        return comparison ?? (lhs.rankingName < rhs.rankingName)
    }
}

/// The `mostUrgent` comparator: urgency tier, then windows-present, then
/// visible signal, then worst percentage. `nil` means every one of those
/// tied, so the caller falls back to the name tie-break.
private func compareMostUrgent<P: RankableProvider>(
    _ lhs: P,
    _ rhs: P,
    localThreshold: Double
) -> Bool? {
    let lhsTier = attentionTier(for: lhs, localThreshold: localThreshold)
    let rhsTier = attentionTier(for: rhs, localThreshold: localThreshold)
    if lhsTier != rhsTier {
        return lhsTier < rhsTier
    }

    // Most-urgent has no useful ordering signal for a provider with
    // no windows, so those stay at the end of their urgency tier.
    let lhsHasWindows = !lhs.rankingWindows.isEmpty
    let rhsHasWindows = !rhs.rankingWindows.isEmpty
    if lhsHasWindows != rhsHasWindows {
        return lhsHasWindows
    }

    let lhsSignal = mostUrgentSignalRank(lhs)
    let rhsSignal = mostUrgentSignalRank(rhs)
    if lhsSignal != rhsSignal {
        return lhsSignal > rhsSignal
    }

    let lhsPercent = worstPercentForRanking(lhs)
    let rhsPercent = worstPercentForRanking(rhs)
    if lhsPercent != rhsPercent {
        return lhsPercent < rhsPercent
    }

    return nil
}

/// The `resetSoonest` comparator: earliest reset first, missing reset last.
/// `nil` means both sides tied (equal resets, or both missing), so the
/// caller falls back to the name tie-break.
private func compareResetSoonest<P: RankableProvider>(_ lhs: P, _ rhs: P) -> Bool? {
    let lhsReset = earliestResetForRanking(lhs)
    let rhsReset = earliestResetForRanking(rhs)
    switch (lhsReset, rhsReset) {
    case let (lhsReset?, rhsReset?) where lhsReset != rhsReset:
        return lhsReset < rhsReset
    case (nil, .some):
        return false
    case (.some, nil):
        return true
    default:
        return nil
    }
}

/// Sort highest visible severity first without making a yellow row a warning.
/// Warning eligibility and presentation order answer different questions:
/// yellow does not notify, but it is still more urgent than green when the
/// user explicitly chooses the "Most urgent" display order.
private func mostUrgentSignalRank(_ provider: some RankableProvider) -> Int {
    provider.rankingWindows.map { window in
        switch signalLevel(for: window) {
        case .red: 4
        case .orange: 3
        case .yellow: 2
        case .green: 1
        case .unknown: 0
        }
    }.max() ?? 0
}

/// 0 = errored, 1 = ok + attention-needed, 2 = ok + normal.
private func attentionTier(for provider: some RankableProvider, localThreshold: Double) -> Int {
    guard provider.rankingIsOK else { return 0 }
    return provider.rankingNeedsAttention(localThreshold: localThreshold) ? 1 : 2
}

/// The worst (lowest) `percentLeft` among a provider's windows, or
/// `.infinity` when there are none -- `.infinity` sorts last within any
/// ascending comparison, giving "no data" the correct last-in-tier position
/// without a separate nil-handling branch.
private func worstPercentForRanking(_ provider: some RankableProvider) -> Double {
    provider.rankingWindows.map(\.percentLeft).min() ?? .infinity
}

/// The earliest parseable provider reset. Missing or malformed timestamps stay
/// absent so presentation code can sort deterministically without inventing a
/// reset date.
private func earliestResetForRanking(_ provider: some RankableProvider) -> Date? {
    let formatter = ISO8601DateFormatter()
    return provider.rankingWindows.compactMap { window in
        window.resetISO.flatMap(formatter.date(from:))
    }.min()
}

/// "resets Tue 8:00 PM" for the soonest window to come back -- the one thing
/// worth saying about a provider with nothing left to spend.
///
/// Note this is the *earliest* reset, not the worst window. An active row
/// surfaces the window closest to depletion, because that is what constrains
/// you; an exhausted provider is constrained by whichever window frees up
/// first. Different questions, usually different windows.
///
/// Shared so the Mac menu's exhausted row and the iOS exhausted cell say the
/// same words about the same provider.
func earliestResetLabel(_ windows: [ProviderWindow], now: Date) -> String? {
    // Minimum is taken over the parsed `Date`, never over the rendered label:
    // "Tue 8:00 PM" sorts before "Wed 3:00 AM" lexicographically but also
    // before "Mon 9:00 AM", so comparing display strings picks the wrong
    // window roughly whenever two windows land on different weekdays.
    let formatter = ISO8601DateFormatter()
    let earliest = windows
        .compactMap(\.resetISO)
        .compactMap { iso in formatter.date(from: iso).map { (date: $0, iso: iso) } }
        .min { $0.date < $1.date }
    guard let iso = earliest?.iso, let label = friendlyResetDate(iso, now: now) else {
        return nil
    }
    return "resets \(label)"
}
