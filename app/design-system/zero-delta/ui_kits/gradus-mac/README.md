# UI kit — Gradus for Mac (menu bar)

Recreation of `app/GradusMac/MenuContentView.swift`: a `MenuBarExtra` dropdown, 260px wide,
with one compact row per provider plus a settings section.

## Screens
- **Status item + dropdown** — click the status item to open or close the popover.
- **No snapshot data yet** — turn sync off; the row list collapses to the single empty line the
  Swift view renders.

## Fidelity notes
- Literal SwiftUI values: `.frame(width: 260)`, `.padding(12)`, `VStack(spacing: 8)`,
  `.padding(.vertical, 2)` per row, 6px capsule bar.
- Each row surfaces only the window closest to depletion — the menu never lists every window.
- Mac chrome (menu bar strip, blur, shadow) is scaffolding for the kit, not part of the design system.
