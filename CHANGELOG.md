# Changelog

User-facing release notes for Gradus. Each semantic product version gets one
entry here, including a concise `### TestFlight focus` list. Individual
TestFlight candidate builds and re-upload reasons stay in `HISTORY.md`.

This file is the tester-facing source. It previously claimed the focus text
“is copied into App Store Connect's ‘What to Test’ field”, which nothing ever
did — `testflight-setup.py` has no `betaBuildLocalizations` call. The
sole tester reads this file directly, so the claim was removed rather than
automated: a documented step no tool performs and no gate checks is worse
than an absent one. If the tester list ever grows beyond people with repo
access, the automation becomes worth building.

The `1.4 (8)` through `1.4 (10)` entries are retained as legacy candidate
history from the overnight release train. New releases use
`MAJOR.MINOR.PATCH`; build numbers do not become patch components.

## 1.6.0 — 2026-08-05

The iPhone half of the layout 1.5.0 shipped on iPad. Same artifact, same
version: an iPhone-only or iPad-only release is not a thing (INV-12).

### Changed

- iPhone now uses the same dense layout the iPad got in 1.5.0: every provider
  and every one of its usage windows visible at once, with a bar per window.
  Previously the phone showed a single enlarged "hero" provider and one window
  each for the rest, so seeing a provider's other windows meant opening it.
  The same account could read as healthy on the phone and not on the tablet.
- The four-line connected-computer card at the top of the iPhone screen is
  replaced by the one-line sync status ("synced 5m ago · dm5mbp") already used
  on iPad. The full computer, user, and publish-time detail remains in
  Settings under "Connected Computer".

### Removed

- The per-provider window badges that let you choose which window the main bar
  tracked are gone from the iPhone, along with the enlarged hero provider and
  the separate "Exhausted" section at the bottom. All of these existed to work
  around showing one window per provider; with every window on screen there is
  no longer a window to choose, and an exhausted provider reads as a card whose
  bars are all red, still sorted last.

### TestFlight focus

- On iPhone, confirm every provider and every window is visible with a bar
  each, and that the list is more compact than before rather than less.
- Confirm tapping a provider still opens its detail view.
- Confirm iPhone and iPad now show the same information, differing only in
  column count and the per-row reset time.
- Confirm the sync status line at the top names the publishing Mac, and that
  Settings still shows the full connected-computer detail.

## 1.5.0 — 2026-08-05

First three-component version on this train. The build number is allocated at
upload time and recorded in `HISTORY.md`, not here.

### Added

- iPad now uses a dense two- or three-column layout that shows every provider
  and every usage window at once, with a bar per window. Previously the iPad
  reused the iPhone list, so seeing a provider's other windows meant opening
  each provider in turn and scrolling.
- The iPad header carries a one-line sync status ("synced 5m ago · dm5mbp") in
  place of the four-line connected-computer card.

### Changed

- Usage colors now reflect **pace** rather than percentage remaining, on both
  the Mac and iOS. A window that is 72% full but being spent far faster than
  its reset window now reads red, and a window down to 3% but comfortably
  ahead of pace reads green. Windows with no pace data keep the old
  percentage-based coloring.

### Fixed

- A window sitting at exactly 0.5% is no longer reported as depleted; it
  displays as 1% remaining and is still counted as spendable.

### TestFlight focus

- On iPad, confirm all providers and all of their windows are visible without
  scrolling, in both portrait and landscape.
- Tap a provider card on iPad and confirm it opens that provider's detail view.
- Confirm a nearly-empty provider that is ahead of pace is not colored red, and
  that a fuller provider being spent too fast is.
- Confirm the iPhone layout is unchanged by this release.

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
