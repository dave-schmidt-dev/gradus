import Foundation

// Pure functions mirroring `gradus/snapshot.py`'s `percent_is_valid`,
// `percent_is_depleted`, and `window_warns` (CR-11/INV-3, CV-2). Kept as a
// single source of truth consumed by both the Mac publisher and iOS
// consumer so the two apps cannot drift into two definitions of "warning".

/// A remaining percentage is valid iff it is finite and within 0...100
/// (INV-3: normalized once, never negative, never over 100).
public func percentIsValid(_ percentLeft: Double?) -> Bool {
    guard let percentLeft, percentLeft.isFinite else { return false }
    return percentLeft >= 0.0 && percentLeft <= 100.0
}

/// A remaining percentage strictly below this rounds to zero, so the window
/// is treated as depleted.
///
/// Stated as a bound rather than as `.rounded() <= 0` deliberately: Swift's
/// `.rounded()` is half-away-from-zero (`(0.5).rounded() == 1`) while Python's
/// `round` is banker's rounding (`round(0.5) == 0`), so the two spellings
/// disagreed at exactly 0.5 and a provider sitting there was
/// depleted-and-warning on the TUI but neither here. Because `percentIsValid`
/// bounds the input to 0...100, `floor(x + 0.5) <= 0` is exactly `x < 0.5`, so
/// this form is identical on both platforms with no rounding mode to get
/// wrong. Mirrored by `DEPLETED_PERCENT_CEILING` in `gradus/snapshot.py`.
public let depletedPercentCeiling = 0.5

/// A normalized remaining percentage is depleted when it rounds down to zero
/// — anything in `[0, 0.5)`. Exactly 0.5 is *not* depleted: it renders as 1%
/// once rounded, and there is still something left to spend.
public func percentIsDepleted(_ percentLeft: Double?) -> Bool {
    guard percentIsValid(percentLeft), let percentLeft else { return false }
    return percentLeft < depletedPercentCeiling
}

/// A window warrants attention when the ramp classifies it orange or red —
/// deliberately the same predicate that colors the row, not a parallel one.
///
/// Before 2026-08-06 this was its own rule (depleted, or finite pace below
/// -0.10), which agreed with the ramp for every window carrying a pace and
/// disagreed for every window without one: a 19%-left window with no reset
/// timestamp rendered red and raised no alert, on the reasoning that there was
/// no evidence to alert on.
///
/// That gap was real but it was not the reason this changed. The two rules
/// were also aggregated differently per provider — the Mac asked only about
/// its worst-by-percentage window, iOS about any window — so the same snapshot
/// could produce a warning count on one platform and not the other. Collapsing
/// both onto one predicate with one aggregation (`providerNeedsAttention`) is
/// what makes them agree by construction.
///
/// Invalid percentages are never candidates; `signalLevel` returns `.unknown`
/// for them, which is not an attention step.
public func windowWarns(_ window: ProviderWindow) -> Bool {
    signalLevel(for: window).needsAttention
}

/// The one definition of "this provider needs attention": any of its windows
/// does. Both apps' ranking and the publisher's stored `isWarning` field read
/// this, so the Mac's "N low" badge, the iPhone's warning count, and the
/// CloudKit push subscription are answering the same question.
public func providerNeedsAttention(_ windows: [ProviderWindow]) -> Bool {
    windows.contains(where: windowWarns)
}
