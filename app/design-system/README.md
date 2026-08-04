# Zero Delta Design System

The canonical Zero Delta design-system package is preserved in
[`zero-delta/`](zero-delta/). It is the source package supplied on 2026-08-04
and is intentionally kept separate from the current GradusiOS release.

It includes the brand rules, design tokens, reusable web/mobile component
references, Gradus UI kit examples, and the Gradus app icon assets. The
package's `SKILL.md` is the implementation guidance for future design work.

## Cross-surface pace marker

The next UI pass must add the same thin red expected-pace marker to every
usage bar in the TUI, GradusMac, and GradusiOS. The bar remains current
remaining capacity. For a window with a valid `pace_delta`, calculate the
marker position as:

```text
expected_remaining = clamp(percent_left - (pace_delta * 100), 0, 100)
```

`pace_delta` is positive when more capacity remains than the schedule predicts.
Therefore, the filled bar ending past the marker means under pace; ending before
it means over pace. Omit the marker when the window has no valid pace metadata.

## Current release boundary

GradusiOS 1.3 contains functional sync and notification fixes only. The next
UI version should use this package to replace the placeholder app icon and to
rework the provider-card ranking, warning borders, and compact exhausted-card
layout.

## Provenance

- Source: `Zero Delta Design System.zip` supplied by David Schmidt
- Archive SHA-256: `e3c1ae9e93157516c5cf90150612973afbe524150600e0ebf73b8ebfb40ab0c8`
- Extracted entries: 143 files
- Shared copy: `/Users/dave/Documents/Projects/apple_developer/design-system/zero-delta/`
