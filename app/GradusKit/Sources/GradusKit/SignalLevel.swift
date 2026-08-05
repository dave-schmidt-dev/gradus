import Foundation

/// The four-step usage signal ramp, plus "no opinion".
///
/// Mirrors `gradus/ui.py`'s `_style_for_signal`. The two implementations are
/// held together by `Tests/GradusKitTests/Fixtures/signal-levels.json`, which
/// both test suites read — see that file's header for why the ramp is
/// duplicated rather than shared.
public enum SignalLevel: String, Sendable, CaseIterable, Codable {
    case green
    case yellow
    case orange
    case red
    /// The percentage is missing or violates INV-3. Surfaces render this as
    /// their muted/secondary color rather than picking a ramp step.
    case unknown

    /// The canonical sRGB value for this level, or `nil` for `.unknown`
    /// (whose color is surface-specific: `text.muted` in the TUI, `.secondary`
    /// in SwiftUI).
    ///
    /// GradusKit deliberately does not import SwiftUI, so this vends the raw
    /// value and each app applies its own `Color(hex:)`. That keeps exactly
    /// one copy of these four constants in the Swift half — before this
    /// existed, iOS held them in `DesignTokens/Colors.swift` and the Mac had
    /// no ramp at all.
    public var rgbHex: UInt32? {
        switch self {
        case .green: return 0x87D787
        case .yellow: return 0xFFD75F
        case .orange: return 0xFFAF5F
        case .red: return 0xFF5F5F
        case .unknown: return nil
        }
    }
}

/// Pace at or above this value is healthy. Consuming exactly as fast as the
/// clock runs down is fine — that is what the window is for.
private let paceGreenFloor = 0.0

/// Matches `windowWarns` / `window_warns`, which alert at `paceDelta < -0.10`.
/// Because this bound is inclusive, "orange or worse" and "warns" are the same
/// predicate for every window with a finite pace, so a colored row and a
/// notification can never disagree. (They can differ when pace is absent — see
/// `signalLevel` below.)
private let paceYellowFloor = -0.10

/// Burning down more than 25 points faster than the clock. Unlike
/// `paceYellowFloor` this bound is not derived from an existing predicate; it
/// was chosen to separate "drifting" from "will run out early" and is the one
/// number here free to be retuned.
private let paceOrangeFloor = -0.25

/// Classify a window by how its consumption compares to the time remaining,
/// not by how much is left in absolute terms.
///
/// The rules, in order:
///
/// 1. An invalid percentage (missing, non-finite, or outside 0...100 per
///    INV-3) yields `.unknown`. Note this is stricter than the ramp it
///    replaced, which happily returned green for `150`.
/// 2. A depleted percentage yields `.red` no matter how good the pace is.
///    There is nothing left to pace.
/// 3. A missing or non-finite pace falls back to the legacy percent-only
///    ramp (70/40/20) so a window without a reset timestamp still gets a
///    color. This is the one case where "orange or worse" is not equivalent
///    to `windowWarns`: 19% with no pace renders red but raises no alert,
///    because there is no evidence to alert on.
/// 4. Otherwise the pace delta selects the step.
///
/// - Parameters:
///   - percentLeft: Remaining percentage, normalized 0...100.
///   - paceDelta: `fraction_left - fraction_of_window_remaining`. Positive is
///     ahead of schedule. Not clamped (INV-4).
public func signalLevel(percentLeft: Double?, paceDelta: Double?) -> SignalLevel {
    guard percentIsValid(percentLeft), let percentLeft else { return .unknown }
    if percentIsDepleted(percentLeft) { return .red }

    guard let paceDelta, paceDelta.isFinite else {
        if percentLeft >= 70 { return .green }
        if percentLeft >= 40 { return .yellow }
        if percentLeft >= 20 { return .orange }
        return .red
    }

    if paceDelta >= paceGreenFloor { return .green }
    if paceDelta >= paceYellowFloor { return .yellow }
    if paceDelta >= paceOrangeFloor { return .orange }
    return .red
}

/// Convenience overload for the common case of coloring a whole window.
public func signalLevel(for window: ProviderWindow) -> SignalLevel {
    signalLevel(percentLeft: window.percentLeft, paceDelta: window.paceDelta)
}
