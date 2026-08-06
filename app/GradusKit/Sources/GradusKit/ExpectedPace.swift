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

/// Leading-edge offset for a marker of `markerWidth` centered on `fraction` of
/// a bar `barWidth` wide, kept inside the bar at both ends.
///
/// Shared because the two apps had already drifted: iOS clamped the marker into
/// its bar and the Mac did not, so a Mac window at 0% or 100% drew half a marker
/// hanging off the end of the thing it was marking.
///
/// Centering is what makes the marker *mean* the position it sits at, and
/// clamping gives up to `markerWidth / 2` of that back — 1.5pt, under 1% of a
/// typical bar. It is worth it because the two positions clamping affects are
/// the two where the reading is unambiguous anyway: a marker pinned to either
/// end can only mean that end.
///
/// A bar narrower than the marker clamps to zero rather than going negative,
/// which is a degenerate layout either way but not a mispositioned one.
public func markerOffset(fraction: Double, barWidth: Double, markerWidth: Double) -> Double {
    let centered = barWidth * min(max(fraction, 0), 1) - markerWidth / 2
    return min(max(centered, 0), max(barWidth - markerWidth, 0))
}
