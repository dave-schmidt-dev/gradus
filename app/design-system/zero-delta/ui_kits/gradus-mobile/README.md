# UI kit — Gradus for iPhone

The mobile app design, not a transcription of the terminal. Same data, same vocabulary, mobile
information architecture.

## What changes from the TUI

| TUI | iPhone |
| --- | --- |
| 5-column rows (label / % / bar / reset / pace) | one headline number per tile, bar under it, reset + pace as a meta line |
| Every window visible at once | worst window headlines the tile; the rest become chips, full set lives in the detail screen |
| Two packed vertical stacks | one full-width column, thumb-reachable, 44px minimum targets |
| Square 1px panels | 10px cards on the flat page surface |
| Glyph bars (▓█░) | capsule bars at 8px |
| Keyboard hints in the footer | tap targets and one trailing control per bar |
| All 7 providers equal | most urgent provider promoted to a hero tile at the top |

## Screens
- **Now** — hero tile for the provider closest to depletion, then every provider ranked by urgency.
- **Provider detail** — every window at full size with absolute reset, countdown and pace, then
  provenance shields (source, schema, observed).
- **Settings** — sync and notifications, warning threshold, publishing Mac, about.
- **Waiting for first publish / Not signed in / iCloud sync off** — the three source empty states.
- **Warning notification** — the banner raised when a provider's warning flag flips.

## Fidelity notes
- Copy, provider names, window ids, thresholds and pace wording are unchanged from the source.
- Ranking by urgency is a mobile-only decision: a phone shows one thing at a time, so the screen
  answers "what is about to run out" before "what is the state of everything".
- The bezel comes from a device-frame starter and is scaffolding, not part of the design system.
