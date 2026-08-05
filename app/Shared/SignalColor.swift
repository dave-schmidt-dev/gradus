import GradusKit
import SwiftUI

/// SwiftUI rendering for `GradusKit.SignalLevel`, compiled into both the Mac
/// and iOS targets (the `Shared` source group).
///
/// The split is deliberate: GradusKit owns the *classification* and the four
/// canonical hex values but does not import SwiftUI, so this file owns the
/// `SignalLevel -> Color` step and nothing else. Every decision — thresholds,
/// palette, the depleted and invalid-percentage rules — lives in
/// `GradusKit/SignalLevel.swift`.
///
/// The TUI's counterpart is `_style_for_signal` in `gradus/ui.py`. Because
/// Python and Swift cannot share an implementation today, both test suites
/// read `app/GradusKit/Tests/GradusKitTests/Fixtures/signal-levels.json` so a
/// one-sided edit fails on both sides. See the `[future]` centralization row
/// in `TASKS.md`.
enum SignalColor {
    /// `.unknown` has no ramp color — the percentage is missing or violates
    /// INV-3, so the row renders muted rather than claiming a state.
    static func forLevel(_ level: SignalLevel) -> Color {
        guard let hex = level.rgbHex else { return .secondary }
        return Color(hex: hex)
    }

    /// Colors by pace, not by absolute percentage: a window with 1% left five
    /// minutes before it resets is on pace, and renders as such.
    static func forWindow(_ window: ProviderWindow) -> Color {
        forLevel(signalLevel(for: window))
    }
}

extension Color {
    /// Standard sRGB byte-triplet expansion, e.g. `0x87D787` -> RGB
    /// `0x87`/`0xD7`/`0x87`. No alpha channel (always opaque).
    init(hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255
        let green = Double((hex >> 8) & 0xFF) / 255
        let blue = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }
}
