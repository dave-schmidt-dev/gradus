# Changelog

User-facing release notes for Gradus. Each semantic product version gets one
entry here, including a concise `### TestFlight focus` list. This file is the
tester-facing source for that list. Individual TestFlight candidate builds and
re-upload reasons stay in `HISTORY.md`.

The `1.4 (8)` through `1.4 (10)` entries are retained as legacy candidate
history from the overnight release train. New releases use
`MAJOR.MINOR.PATCH`; build numbers do not become patch components.

## 1.10.3 — 2026-09-05

### Fixed

- Carries the Cursor independent-pool correction and supersedes the uploaded
  but unassigned 1.10.2 candidate after release-adapter reconciliation was
  repaired.

### TestFlight focus

- Confirm Cursor remains active when Auto/Composer is depleted and API usage
  remains available.
- Confirm Cursor appears exhausted when both pools are depleted.

## 1.10.2 — 2026-09-05

### Fixed

- Cursor is no longer reported exhausted while either its Auto/Composer or API
  pool still has capacity.

### TestFlight focus

- Confirm Cursor remains active when Auto/Composer is depleted and API usage
  remains available.
- Confirm Cursor appears exhausted when both pools are depleted.

## 1.10.1 — 2026-08-29

### Fixed

- Clarified widget sizing and removed the normal Settings Explore Sample path.

### TestFlight focus

- In the iOS widget gallery, select the actual small and medium Gradus widgets
  and confirm each renders the expected provider layout.
- Filter providers in Settings and confirm the widget follows that filtering.

## 1.10.0 — 2026-08-29

### Added

- Provider cards show optional account credits when a provider reports them,
  including Codex and Claude-compatible data without inventing unavailable
  balances.
- Settings can exclude selected providers from widgets without hiding them from
  the Gradus dashboard.
- A medium Home Screen widget shows up to three eligible providers, ranked by
  urgency, alongside the existing single-provider small widget.

### TestFlight focus

- Confirm available credits match the provider source and providers without a
  reported balance do not show a fabricated value.
- Exclude and restore providers in Settings, then confirm the widget updates
  while the dashboard remains unchanged.
- Add both small and medium widgets; confirm the small widget shows one urgent
  provider and the medium widget shows up to three in the expected order.

## 1.9.0 — 2026-08-23

### Added

- A small iPhone/iPad Home Screen widget shows the most urgent provider usage
  window, remaining percentage, reset time, and age of the phone's last sync.
  Tapping it opens Gradus. Empty or unavailable data directs the user back to
  the app without exposing stale or sample usage.

### TestFlight focus

- Add the small Gradus widget after opening the app once and confirm its
  provider, percentage, reset, and sync age match the dashboard's live data.
- Confirm the widget remains readable in light/dark mode and larger text, and
  that tapping it opens the Gradus dashboard.

## 1.8.1 — 2026-08-19

### Added

- iPhone and iPad dashboard and provider-detail cards now show a quantitative
  pace figure (for example "12% ahead") below each window's bar, matching the
  Mac menu bar and terminal dashboard.

### Fixed

- On iPad, Automatic density picked the richest layout that fit compact
  width first, then never widened further in landscape — leaving roughly
  half the screen unused. It now picks the richest rung the available width
  supports and that rung's own maximum column count.

### TestFlight focus

- On iPad, rotate to landscape with Automatic density selected and confirm
  cards use the full width instead of stopping at a narrow column count.
- On the dashboard and provider detail screens, confirm each window shows a
  pace percentage under its bar, and that it matches the Mac menu bar for the
  same account.

## 1.8.0 — 2026-08-17

### Added

- Mac Settings now shows recently active iPhone and iPad consumers, using
  short-lived private presence records so stale devices disappear automatically.

- A new "Codex (Spark)" card tracks a separate weekly quota bucket on your
  Codex account, alongside the existing Codex card. It shows its own
  remaining percentage, reset time, and pace, independent of Codex's own
  weekly window — no separate sign-in is needed.

- A device-relative card-size slider on iPad widths that can form multiple
  columns, under Settings → Local Display. Automatic is explicit; while it is
  selected, the manual slider is disabled. Small is at the left and uses more
  columns, while Large is at the right and uses fewer. One-column devices show
  Automatic only rather than an inert slider. Every position shows every
  provider window, and the choice is stored per device like sort order and the
  exhausted-provider toggle. Existing column-count preferences are migrated
  without changing their layout.

### Fixed

- Provider refresh failures on iPhone and iPad now use actionable language
  instead of exposing raw HTTP status codes.

- The terminal dashboard again restores the separate Antigravity Claude and
  Codex Spark quota buckets from the canonical snapshot without extra provider calls.

- If you declined notification permission — or turned Gradus' notifications off
  in iOS Settings later — the app's own Notifications toggle still showed "on"
  and gave no hint that nothing would ever appear. Settings now says so, and
  offers a button that takes you straight to the right place in iOS Settings.
  It appears right away if you decline the permission prompt on first launch,
  and clears itself as soon as you come back. Note that turning notifications
  off at the iOS level does not stop syncing: the wording says so, because
  those are genuinely separate.

- The Mac menu bar, the iPhone's "N low" badge, and push notifications now agree
  on which providers need attention. They used two different rules against the
  same data: the Mac asked whether a provider's *worst* window was in trouble,
  the phone asked whether *any* window was, and with no pace data one of them
  fell back to a percentage ramp the other ignored. A provider could show a red
  bar on the phone and nothing in the menu bar, off the same sync.

- Usage percentages no longer truncate at large text sizes. A full provider cannot
  read as nearly exhausted because its percent column ran out of room.

- The terminal dashboard's Codex `5h` row briefly showed as `n/a` instead of
  disappearing when OpenAI's API doesn't report that window (which it hasn't
  since 2026-07). It's hidden again until OpenAI restores the window, matching
  how the new Codex (Spark) `sp1w` row already behaves.

### TestFlight focus

- On iPad, confirm Automatic disables the manual slider; turn it off and move
  Small to Large, confirming columns and cards change without losing a provider
  window. On iPhone, confirm Settings shows Automatic · 1 column with no manual
  slider.
- Confirm the selected position survives quitting and reopening the app, and is
  stored separately on each device.
- At large text sizes, confirm every displayed percentage remains fully legible.
- Confirm the low-provider count in the iPhone badge matches what the Mac menu
  bar shows at the same moment.

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
