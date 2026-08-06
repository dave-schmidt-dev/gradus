import Foundation
import GradusKit

/// Device-local presentation order for dashboard providers. Raw values are
/// persisted only in `UserDefaults`; this type is intentionally separate from
/// `ProviderStatus`, which is encoded into CloudKit records.
public enum ProviderSortOption: String, CaseIterable, Identifiable {
    case mostUrgent
    case resetSoonest
    case nameAZ

    public var id: Self { self }

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
    /// `false` means the provider's probe failed; those sort first.
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

    var all: [P] { active + exhausted }
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
/// Within tiers 2 and 3: by `sortOption` (a provider with no windows sorts
/// last within its tier -- no data to rank by). Final deterministic
/// tie-breaker, applied within every tier including tier 1: ascending
/// `rankingName`.
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
        let lhsTier = attentionTier(for: lhs, localThreshold: localThreshold)
        let rhsTier = attentionTier(for: rhs, localThreshold: localThreshold)
        if lhsTier != rhsTier { return lhsTier < rhsTier }

        // No-window providers retain their existing last-within-tier behavior
        // for every local sort mode. There is no invented percent or reset.
        let lhsHasWindows = !lhs.rankingWindows.isEmpty
        let rhsHasWindows = !rhs.rankingWindows.isEmpty
        if lhsHasWindows != rhsHasWindows { return lhsHasWindows }

        switch sortOption {
        case .mostUrgent:
            let lhsPercent = worstPercentForRanking(lhs)
            let rhsPercent = worstPercentForRanking(rhs)
            if lhsPercent != rhsPercent { return lhsPercent < rhsPercent }
        case .resetSoonest:
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
                break
            }
        case .nameAZ:
            break
        }

        return lhs.rankingName < rhs.rankingName
    }
}

/// 0 = errored, 1 = ok + attention-needed, 2 = ok + normal.
private func attentionTier<P: RankableProvider>(for provider: P, localThreshold: Double) -> Int {
    guard provider.rankingIsOK else { return 0 }
    return provider.rankingNeedsAttention(localThreshold: localThreshold) ? 1 : 2
}

/// The worst (lowest) `percentLeft` among a provider's windows, or
/// `.infinity` when there are none -- `.infinity` sorts last within any
/// ascending comparison, giving "no data" the correct last-in-tier position
/// without a separate nil-handling branch.
private func worstPercentForRanking<P: RankableProvider>(_ provider: P) -> Double {
    provider.rankingWindows.map(\.percentLeft).min() ?? .infinity
}

/// The earliest parseable provider reset. Missing or malformed timestamps stay
/// absent so presentation code can sort deterministically without inventing a
/// reset date.
private func earliestResetForRanking<P: RankableProvider>(_ provider: P) -> Date? {
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
