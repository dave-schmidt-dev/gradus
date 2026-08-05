import Foundation

/// Returns the expected remaining capacity for a valid usage window.
///
/// `percentLeft` is remaining capacity in percentage points (`0...100`), while
/// `paceDelta` is a finite signed fraction: positive means remaining capacity
/// is ahead of the expected schedule and negative means it is behind. The
/// fraction is converted to percentage points before subtraction. Invalid or
/// absent metadata returns `nil`; finite pace deltas are intentionally not
/// range-clamped because the snapshot contract does not impose a range on them.
public func expectedRemaining(percentLeft: Double?, paceDelta: Double?) -> Double? {
    guard percentIsValid(percentLeft), let percentLeft,
          let paceDelta, paceDelta.isFinite
    else {
        return nil
    }

    return min(max(percentLeft - (paceDelta * 100), 0), 100)
}
