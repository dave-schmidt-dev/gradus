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

/// iOS-local "locally urgent" predicate (P3/T3.1; the real `@Published`
/// `localWarningThresholdPercent` control that drives `threshold` shipped in
/// Phase 5.2 -- see `DashboardViewModel`). Deliberately lives in `GradusiOS`,
/// not `GradusKit`: it is device-local by definition and must never be
/// confused with the shared, fixed `GradusKit.windowWarns` (Key decision #5,
/// `ios-design-system-2026-08-03.md`) -- that keeps `GradusKit`'s
/// INV-7-governed scope unchanged for this plan.
///
/// A window is locally urgent when it's depleted (mirrors
/// `GradusKit.percentIsDepleted`) OR its `percentLeft` is at/below the
/// caller-supplied local threshold. Invalid percentages are never urgent
/// candidates, matching `windowWarns`'s own guard.
func localIsUrgent(_ window: ProviderWindow, threshold: Double) -> Bool {
    guard percentIsValid(window.percentLeft) else { return false }
    return percentIsDepleted(window.percentLeft) || window.percentLeft <= threshold
}

/// The single, total-order ranking function for the Now screen (P3/T3.1).
/// Four tiers, most urgent first:
///
/// 1. Errored providers (`!provider.ok`).
/// 2. Among `ok` providers, "attention-needed": `provider.isWarning ||
///    provider.windows.contains { localIsUrgent($0, threshold: localThreshold) }`.
///    **This must be the union, never `localIsUrgent` alone and never
///    `isWarning` alone.** Key decision #6 (`ios-design-system-2026-08-03.md`):
///    the adjudicator (Gemini, AJ-1) caught that an earlier draft ranked on
///    `localIsUrgent` alone, on the false claim that it's a superset of
///    `windowWarns`. It isn't: a window with `paceDelta < -0.10` has
///    `isWarning == true` regardless of `percentLeft` (e.g. 50% remaining,
///    burning fast), so a window like that can be `isWarning == true` while
///    `localIsUrgent == false` (its `percentLeft` sits above the local
///    threshold). Ranking on `localIsUrgent` alone would then rank that
///    provider -- which CloudKit already pushed a warning about -- *behind*
///    providers CloudKit never flagged at all. The union fixes this: `isWarning`
///    guarantees anything CloudKit already pushed about is never demoted, and
///    `localIsUrgent` can only ever *add* providers to this tier, never
///    remove one `isWarning` already placed there.
/// 3. `ok` providers with neither flag set.
///
/// Within tiers 2 and 3: ascending by the worst window's `percentLeft` (a
/// provider with `windows == []` sorts last within its tier -- no data to
/// rank by). Final deterministic tie-breaker, applied within every tier
/// (including tier 1, e.g. two errored providers): ascending `providerName`
/// -- the same fallback key `reconcile()` already used before this function
/// existed, so this is a strict superset of prior behavior, not a new
/// sorting philosophy.
func rankProviders(
    _ providers: [ProviderStatus],
    localThreshold: Double,
    sortOption: ProviderSortOption = .mostUrgent
) -> [ProviderStatus] {
    // Keep the active/exhausted split independent of every presentation
    // comparator. This avoids a mode change moving depleted providers back
    // into the active group, while preserving each provider's payload intact.
    let active = providers.filter { !$0.isDepleted }
    let exhausted = providers.filter(\.isDepleted)
    return sortPartition(active, localThreshold: localThreshold, sortOption: sortOption)
        + sortPartition(exhausted, localThreshold: localThreshold, sortOption: sortOption)
}

private func sortPartition(
    _ providers: [ProviderStatus],
    localThreshold: Double,
    sortOption: ProviderSortOption
) -> [ProviderStatus] {
    providers.sorted { lhs, rhs in
        let lhsTier = attentionTier(for: lhs, localThreshold: localThreshold)
        let rhsTier = attentionTier(for: rhs, localThreshold: localThreshold)
        if lhsTier != rhsTier { return lhsTier < rhsTier }

        // No-window providers retain their existing last-within-tier behavior
        // for every local sort mode. There is no invented percent or reset.
        let lhsHasWindows = !lhs.windows.isEmpty
        let rhsHasWindows = !rhs.windows.isEmpty
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

        return lhs.providerName < rhs.providerName
    }
}

/// 0 = errored, 1 = ok + attention-needed, 2 = ok + normal.
private func attentionTier(for provider: ProviderStatus, localThreshold: Double) -> Int {
    guard provider.ok else { return 0 }
    let attentionNeeded =
        provider.isWarning || provider.windows.contains { localIsUrgent($0, threshold: localThreshold) }
    return attentionNeeded ? 1 : 2
}

/// The worst (lowest) `percentLeft` among a provider's windows, or
/// `.infinity` when there are none -- `.infinity` sorts last within any
/// ascending comparison, giving "no data" the correct last-in-tier position
/// without a separate nil-handling branch.
private func worstPercentForRanking(_ provider: ProviderStatus) -> Double {
    provider.windows.map(\.percentLeft).min() ?? .infinity
}

/// The earliest parseable provider reset. Missing or malformed timestamps stay
/// absent so presentation code can sort deterministically without inventing a
/// reset date.
private func earliestResetForRanking(_ provider: ProviderStatus) -> Date? {
    let formatter = ISO8601DateFormatter()
    return provider.windows.compactMap { window in
        window.resetISO.flatMap(formatter.date(from:))
    }.min()
}
