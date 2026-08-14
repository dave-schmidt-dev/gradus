import SwiftUI

// Per-provider brand accent colors.
//
// `Color(hex:)` and the `SignalColor` usage ramp used to live here too; both
// moved to `app/Shared/SignalColor.swift` when the Mac app adopted the same
// ramp, so there is one copy compiled into both targets rather than a
// per-platform pair.

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
