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

/// A normalized remaining percentage is depleted when it is zero or rounds
/// to zero.
public func percentIsDepleted(_ percentLeft: Double?) -> Bool {
    guard percentIsValid(percentLeft), let percentLeft else { return false }
    return percentLeft.rounded() <= 0
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
