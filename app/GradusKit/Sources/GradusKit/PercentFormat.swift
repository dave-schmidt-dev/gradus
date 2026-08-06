import Foundation

/// How a remaining-budget percentage is written on every surface.
///
/// Mirrors `gradus/ui.py`'s `_percent_str` / `_format_percent_value`. The
/// shared truth table at `Tests/GradusKitTests/Fixtures/percent-format.json`
/// is read by both suites, so a one-sided change to either fails on both.
///
/// Vends the number alone. The `%` suffix and the spoken "percent remaining"
/// phrasing belong to the call site, the same way `SignalLevel` vends
/// `rgbHex` and leaves `Color(hex:)` to each app.

/// Largest percentage still drawn with a decimal place.
///
/// Not cosmetic. `percentIsDepleted` treats <= 0.5 as exhausted, so a window
/// at 0.6 is live -- and `Int(0.6)` is `0`, which reads (and, through
/// VoiceOver, speaks) as exhausted. A decimal below 10 is what keeps a live
/// window from being displayed as an empty one.
public let percentDecimalCeiling: Double = 10.0

/// Absorbs the float error in `100.0 - used`, which lands a true 9.1 at
/// 9.099999999999994 and would floor it to 9.0. Measured over the realistic
/// producer range: 40 affected values below 10, 123 overall.
private let truncationEpsilon: Double = 1e-9

/// Truncate toward zero at `places` decimals, without losing a digit to the
/// float error in the caller's arithmetic.
private func truncated(_ value: Double, places: Int) -> Double {
    let scale = pow(10.0, Double(places))
    return (value * scale + truncationEpsilon).rounded(.down) / scale
}

/// The displayed number for a remaining percentage, without a `%`.
///
/// Truncates rather than rounds: this is remaining budget, so rounding up
/// would claim more headroom than exists (47.8 -> "47", never "48").
public func percentText(_ percentLeft: Double) -> String {
    guard percentLeft.isFinite else { return percentMissingText }
    if percentLeft < percentDecimalCeiling {
        return String(format: "%.1f", truncated(percentLeft, places: 1))
    }
    return String(Int(truncated(percentLeft, places: 0)))
}

/// What every surface shows where there is no reading at all.
public let percentMissingText = "n/a"

/// A whole percentage label, suffix included, with no reading handled once.
///
/// The suffix is a parameter rather than a hard-coded `%` because the spoken
/// form is the one that most needs this function: VoiceOver reading "0 percent
/// remaining" for a live window is the same defect as showing "0%", with no
/// visual context to soften it.
///
///     percentDisplay(window.percentLeft)                            // "0.6%"
///     percentDisplay(window.percentLeft, suffix: " percent remaining")
public func percentDisplay(_ percentLeft: Double?, suffix: String = "%") -> String {
    guard let percentLeft, percentLeft.isFinite else { return percentMissingText }
    return percentText(percentLeft) + suffix
}
