import Foundation

/// Pure functions mirroring `gradus/snapshot.py`'s `percent_is_valid`,
/// `percent_is_depleted`, and `window_warns` (CR-11/INV-3, CV-2). Kept as a
/// single source of truth consumed by both the Mac publisher and iOS
/// consumer so the two apps cannot drift into two definitions of "warning".

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

/// A window warrants an alert only when its remaining percentage is exactly
/// depleted, or its finite pace delta is strictly below -0.10. Invalid
/// percentages are never warning candidates.
public func windowWarns(_ window: ProviderWindow) -> Bool {
    guard percentIsValid(window.percentLeft) else { return false }
    if percentIsDepleted(window.percentLeft) {
        return true
    }
    guard let paceDelta = window.paceDelta, paceDelta.isFinite else { return false }
    return paceDelta < -0.10
}
