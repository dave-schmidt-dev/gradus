import Foundation

/// Human-readable pace text: "N% ahead" / "N% behind" / "on pace".
///
/// Mirrors `gradus/ui.py`'s `_format_pace_delta`. The two implementations are
/// held together by `Tests/GradusKitTests/Fixtures/pace-labels.json`, which
/// both test suites read -- see that file's header, and `SignalLevel.swift`
/// for the same pattern applied to color.
///
/// The "on pace" band here is +/-1 point, tighter than the TUI's +/-5 --
/// that difference is deliberate and the fixture does not attempt to erase
/// it, only the wording once a surface decides to show a number.
public func paceLabel(paceDelta: Double?) -> String {
    guard let paceDelta, paceDelta.isFinite else { return "pace unavailable" }
    let points = Int(abs(paceDelta * 100).rounded())
    if points < 1 {
        return "on pace"
    }
    return "\(points)% \(paceDelta > 0 ? "ahead" : "behind")"
}

/// Convenience overload for the common case of labeling a whole window.
public func paceLabel(for window: ProviderWindow) -> String {
    paceLabel(paceDelta: window.paceDelta)
}
