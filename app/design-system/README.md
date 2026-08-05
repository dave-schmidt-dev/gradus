# Zero Delta Design System

The canonical Zero Delta design-system package is preserved in
[`zero-delta/`](zero-delta/). It is the source package supplied on 2026-08-04
and is preserved as the canonical reference for the current GradusiOS release
and future UI work.

It includes the brand rules, design tokens, reusable web/mobile component
references, Gradus UI kit examples, and the Gradus app icon assets. The
package's `SKILL.md` is the implementation guidance for future design work.

## Cross-surface pace marker

The same red expected-pace marker is present on every usage bar in the TUI,
GradusMac, and GradusiOS. The bar continues to show current remaining
capacity, while the thicker marker makes the schedule target readable at a
glance. For a window with a valid `pace_delta`, calculate the
marker position as:

```text
expected_remaining = clamp(percent_left - (pace_delta * 100), 0, 100)
```

`percent_left` is remaining capacity in percentage points and must be finite and
within `0...100`. `pace_delta` is a finite signed fraction, not percentage
points: positive means more capacity remains than the schedule predicts
(ahead/healthy), while negative means less remains (behind). Pace deltas are not
range-clamped. Therefore, the filled bar ending past the marker means remaining
capacity is ahead of expected pace; ending before it means it is behind. Omit the
marker when either input is missing, non-finite, or `percent_left` is outside its
valid range.

## Current release boundary

GradusiOS 1.4 applies the package's signal-ramp icon and the provider-display
rules: active providers are ranked first, exhausted providers are grouped
compactly at the bottom, bucket badges select the headline window, and local
display choices live in Settings. The former cyan urgency border is removed;
status remains encoded by the signal palette and the expected-pace marker.

## Provenance

- Source: `Zero Delta Design System.zip` supplied by David Schmidt
- Archive SHA-256: `e3c1ae9e93157516c5cf90150612973afbe524150600e0ebf73b8ebfb40ab0c8`
- Extracted entries: 143 files
- Shared copy: `/Users/dave/Documents/Projects/apple_developer/design-system/zero-delta/`
