import GradusKit
import SwiftUI

/// The menu bar panel's rendering of `SignalLevel`, where saturation carries
/// severity.
///
/// The canonical ramp holds three of its four steps at full saturation and
/// distinguishes them by hue alone. On a dashboard cell looked at deliberately
/// that is fine. On a panel that is glanced at, with providers stacked down one
/// narrow column, it means every step competes equally for attention and the
/// only way to find the row that matters is to read all of them.
///
/// So saturation is put to work as a second encoding of the same severity the
/// hue already names. `.red` keeps its canonical value untouched and each step
/// below it is progressively washed out, linearly: 100, 75, 50, 25 percent.
/// Hue and lightness stay canonical throughout -- all four steps already sat at
/// L 69%, so lightness was never carrying meaning here and is left alone.
///
/// Two things fall out of that. The eye is drawn in proportion to how bad a
/// window is rather than equally by all four steps, which is the point. And
/// `.yellow` and `.orange` -- only fifteen degrees apart in hue, previously
/// told apart by hue alone -- now differ in saturation as well, so the pair
/// separates better than it did canonically.
///
/// Mac-only, and not a candidate for `Shared/SignalColor.swift`: `rgbHex` is
/// GradusKit's, iOS renders from the same enum, and both Swift suites plus the
/// TUI's `_style_for_signal` are pinned together by `signal-levels.json`.
/// Changing the ramp there would move iOS baselines, which then have to be
/// re-recorded -- `DASHBOARD_SNAPSHOT_RECORD` and friends, on the destination
/// each suite is canonical for. An earlier version of this comment claimed
/// those baselines were "Xcode Cloud-canonical and cannot be re-recorded from
/// here"; that was wrong, and believing it cost four days in 2026-08. They
/// re-record locally and the gate goes green. What actually made them fragile
/// was the unpinned time zone, now fixed in `DashboardSnapshotFixtures.swift`.
enum MenuSignalPalette {
    static func color(for level: SignalLevel) -> Color {
        switch level {
        case .green: Color(hex: 0x9BC39B)
        case .yellow: Color(hex: 0xD7C387)
        case .orange: Color(hex: 0xEBAF73)
        // Canonical `SignalLevel.red`, deliberately unwashed: it is the top of
        // the ramp, so it is the one step nothing is allowed to quiet down.
        case .red: Color(hex: 0xFF5F5F)
        // No ramp value, per `SignalLevel.rgbHex`. Muted rather than washed:
        // "no percentage" is not a step on the ramp.
        case .unknown: .secondary
        }
    }

    static func color(for window: ProviderWindow) -> Color {
        color(for: signalLevel(for: window))
    }
}
