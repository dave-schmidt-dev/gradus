# Changelog

User-facing release notes for Gradus. Each TestFlight build gets one entry
here, and its concise test-focus text is copied into App Store Connect's
“What to Test” field. Internal implementation details stay in `HISTORY.md`.

## Unreleased

No changes yet.

## 1.4 (10) — 2026-08-04

### Fixed

- Hardened the Home Screen badge reset so stale notification counts are cleared
  through UserNotifications as well as the legacy application badge property.

### TestFlight focus

- Confirm opening Gradus or returning to it clears any stale Home Screen badge.

## 1.4 (9) — 2026-08-04

### Fixed

- The main usage bar now follows the current worst bucket by default; tapping
  an alternate bucket badge explicitly selects it and keeps that choice across
  syncs until the bucket disappears.
- Hardened pace-marker and reset rendering so malformed provider metadata cannot
  crash the dashboard or strip the bar's signal coloring.

### TestFlight focus

- Confirm the main bar changes when an alternate bucket badge is tapped.
- Confirm an unselected provider follows whichever valid bucket is currently
  worst after a refresh.
- Confirm the connected Mac card, compact exhausted section, and red pace
  marker remain visible.

## 1.4 (8) — 2026-08-04

### Fixed

- Fixed the connected-computer card to show the current publishing Mac, local
  user, and friendly publish time.
- Added enough clearance between the usage bar's extended pace marker and its
  alternate-window badges to prevent visual overlap while preserving the
  compact provider spacing.

### TestFlight focus

- Confirm the Connected Mac card shows the current computer and user.
- Tap an alternate-window badge and confirm it sits below, rather than on top
  of, the usage bar.
- Confirm the red pace marker remains visible and the provider list stays
  compact.

## 1.4 (7) — 2026-08-04

### Fixed

- Added a connected-computer card and matching Settings rows showing the Mac
  name and short local username that most recently published the dashboard.
- Cleared the app-icon badge at launch, foreground entry, and activation so a
  stale badge from an earlier build cannot remain on the Home Screen.
- Added the selected bucket label to every main usage bar, reduced provider-row
  vertical padding, and kept exhausted providers in the compact bottom group.
- Made the expected-pace marker thicker and taller across TUI, Mac, and iOS,
  and replaced raw reset ISO strings with friendly local dates and times.

### TestFlight focus

- Confirm the connected Mac card shows the current computer and user.
- Verify the Home Screen badge disappears after opening or returning to
  Gradus.
- Confirm every main bar has a bucket label, the red pace marker is obvious,
  and reset text reads like “Today 10:00 PM” or “Tomorrow 7:30 AM”.
- Confirm the tighter provider list shows more active providers per screen.

## 1.4 (6) — 2026-08-04

### Fixed

- Active providers are sorted first; exhausted providers are grouped compactly
  at the bottom and can be hidden from Settings.
- Bucket badges select the window shown by a provider's main usage bar, with a
  safe fallback when a synced window disappears.
- The expected-pace redline is now shown consistently in the TUI, Mac app, and
  iOS app when pace data is valid.
- Removed the unexplained cyan card borders and fixed the compact navigation
  path that could lead back to a blank screen.
- Replaced the placeholder iOS icon with the supplied Zero Delta signal-ramp
  artwork.
- A stale home-screen badge clears when the app becomes active, and repeated
  ordinary sync updates no longer repeat warning notifications.

### TestFlight focus

- Check sorting and the Show exhausted setting on iPhone and iPad.
- Tap each provider's bucket badges and confirm the headline bar changes.
- Confirm the redline is visible when pace data is present and absent when it
  is not.
- Confirm a Mac publish syncs normally without duplicate warning notifications.

## 1.3 (5) — 2026-08-04

### Fixed

- Improved Mac-to-iOS sync handoff and reduced repeated warning notifications
  during ordinary usage updates.

### TestFlight focus

- Confirm that a Mac publish reaches the iPhone and iPad, and that a warning
  notification appears once per warning episode.
