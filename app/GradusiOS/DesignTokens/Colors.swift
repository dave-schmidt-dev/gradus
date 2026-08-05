import SwiftUI

/// Design-system color tokens (P1/T1.1): a `Color(hex:)` byte-triplet
/// initializer, the four-tier urgency ramp mirroring the TUI's
/// `bar.green`/`bar.yellow`/`bar.orange`/`bar.red` styles (`gradus/ui.py`
/// `_style_for_percent`), and per-provider brand accent colors.

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

/// Four-tier urgency ramp for a "percent remaining" value, matching the
/// TUI's `_style_for_percent` thresholds byte-for-byte (`gradus/ui.py`):
/// >=70 green, >=40 yellow, >=20 orange, else red.
enum SignalColor {
    static func forPercent(_ percent: Double) -> Color {
        if percent >= 70 {
            return Color(hex: 0x87D787)
        } else if percent >= 40 {
            return Color(hex: 0xFFD75F)
        } else if percent >= 20 {
            return Color(hex: 0xFFAF5F)
        } else {
            return Color(hex: 0xFF5F5F)
        }
    }
}

/// Per-provider brand-accent hues (distinct from the urgency ramp above --
/// these identify a provider, not a percent-remaining state).
///
/// NOTE: these are placeholder values pending the actual Claude Design
/// project hex export. Where possible they're derived from the existing TUI
/// accent theme (`gradus/ui.py` `THEME`/`ACCENT_STYLES`, xterm-256 colors
/// converted to hex via the standard 6x6x6-cube formula) so the iOS app
/// stays visually consistent with the TUI pending the real export:
/// - codex -> `accent.codex` (color 111)
/// - claude -> `accent.claude` (color 219)
/// - antigravity -> `accent.gemini` (color 80; Antigravity's underlying
///   Gemini pools use this key in the TUI, there is no dedicated
///   `accent.antigravity`)
/// - copilot -> `accent.copilot` (color 117)
/// - cursor -> `accent.cursor` (color 214)
/// - vibe -> `accent.vibe` (color 208)
/// - opencode -> `accent.opencode` (color 150)
enum ProviderAccent {
    static let codex = Color(hex: 0x87AFFF)
    static let claude = Color(hex: 0xFFAFFF)
    static let antigravity = Color(hex: 0x5FD7D7)
    static let antigravityClaude = Color(hex: 0xAF87FF)
    static let copilot = Color(hex: 0x87D7FF)
    static let cursor = Color(hex: 0xFFAF00)
    static let vibe = Color(hex: 0xFF8700)
    static let opencode = Color(hex: 0xAFD787)
}
