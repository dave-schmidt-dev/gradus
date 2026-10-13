# Gradus motif incorporation guide, approved 2026-10-12

**Status: approved 2026-10-12, not integrated.** Nothing here is in the app
yet. This package is the owner's approved set of four Gradus motif elements
(refresh, gauge, waiting, loading): exported SVGs, contact-strip frames and a
pixel-match record (`verify.json`) beside the machine-readable manifest
[`approved.json`](approved.json), the source of truth for selectors, colors,
motion and asset paths.

**Supersedes:** where this package and the local, untracked draft
`docs/loading-motif/` (2026-10-11) overlap, this package wins; that draft is
not authoritative. Due Good and Argus (accepted 2026-10-11) are unchanged and
are not covered here.

## Approved elements

| id | title | Owner-approved option | Kind | Sizes (px) | Multicolor | Primary asset |
| --- | --- | --- | --- | --- | --- | --- |
| `refresh-opposing-loop-arrows` | Refresh: opposing loop arrows | `"1"`, Opposing loop arrows | static | 20, 64 | no | `assets/refresh-opposing-loop-arrows-64-template.svg` |
| `gauge-classic-dial` | Gauge: classic dial (semicircle + needle) | `"B"`, Classic dial | static | 20, 64 | no | `assets/gauge-classic-dial-64-template.svg` |
| `waiting-dot-rails` | Waiting for first publish: dot travels top, middle, bottom rail in turn | `"rev3"`, Dot travels top, middle, bottom rail in turn | animated | 20, 64 | yes | `assets/waiting-dot-rails-64-dark.svg` |
| `loading-three-rails` | Loading: three fixed rails 100% / 2/3 / 1/3 with moving highlight | `"updated sketch"`, Three fixed rails with moving highlight | animated | 20, 64 | yes | `assets/loading-three-rails-64-dark.svg` |

No element is a stock SF Symbol pick, so no element ships an unbacked symbol
name. Both animated elements are `drivenBy: "css"` and have SVG exports; none is
a `"js"` element and none uses `notExportedAsSvg`, so no HTML/CSS reconstruction
is needed.

## Where each element goes

### refresh-opposing-loop-arrows

new surface: no current call site. The two tokens that own this glyph are
declared but referenced by no view: `Icon.syncing`
(`app/GradusiOS/DesignTokens/Icon.swift:11-13`) and `Icon.refresh`
(`Icon.swift:27-29`), both `Image(systemName: "arrow.clockwise")`. Likely first
host: the trailing controls in `DashboardContent`'s `MobileNavBar`
(`app/GradusiOS/DashboardView.swift:193-210`), which already holds
`IconButton(Icon.settings)` at `DashboardView.swift:205`. The design system's
mobile component card lists `refresh-cw` among its 20 px chrome icons and 44 pt
tap targets (`app/design-system/zero-delta/components/mobile/mobile.card.html:32-33`),
and dashboard refresh is currently only the invisible pull gesture noted at
`app/GradusiOS/DashboardViewModel+Sync.swift:12`. This is not the iCloud retry
glyph `arrow.clockwise.icloud` at `app/GradusiOS/EmptyStateView.swift:60`.

### gauge-classic-dial

Current symbol: `Image(systemName: "gauge")` in the Mac menu-bar status item at
`app/GradusMac/MenuBarBucketLabel.swift:165` and `:172`, and the Settings picker
row `Label("Gauge", systemImage: "gauge")` at
`app/GradusMac/MacSettingsView.swift:111`. The menu bar's spoken text comes from
`MenuBarBucketPresenter` (`MenuBarBucketLabel.swift:98`, `:121`) and must survive
the replacement.

### waiting-dot-rails

Current symbol: the `"hourglass"` case for `.waitingForFirstPublish` at
`app/GradusiOS/EmptyStateView.swift:65`, rendered by
`Image(systemName: iconName)` at `EmptyStateView.swift:45`. Host: the empty-state
branch of `DashboardContent` at `app/GradusiOS/DashboardView.swift:213-219`. The
design system maps hourglass to "waiting for first publish"
(`app/design-system/zero-delta/readme.md:183`). The empty state's title and
message already speak the meaning; apply the motif label to the glyph only where
it stands alone, otherwise mark it decorative to avoid double-speaking.

### loading-three-rails

Current control: `ProgressView("Checking iCloud")` for `.checkingICloud` at
`app/GradusiOS/EmptyStateView.swift:105-109`, inside the same empty-state host
(`DashboardView.swift:213-219`). This is the primary replacement. It does not
replace the in-button `ProgressView()` at `EmptyStateView.swift:24`, the
permission spinner at `app/GradusiOS/SettingsView.swift:176`, or the widget
placeholder (`app/GradusWidget/GradusSmallWidgetView.swift:66-84`, label at
`:83`), which is a redacted layout skeleton, not an activity indicator.

## How to implement each element

UI stack: SwiftUI on both platforms. Assets live in
`app/GradusMac/Assets.xcassets` and `app/GradusiOS/Assets.xcassets`; both hold
only `AppIcon.appiconset` today. Add an imageset per SVG with Preserve Vector
Data so the 64 px geometry stays sharp below 64.

### Static, single ink: refresh and gauge

- Import `assets/<id>-<size>-template.svg` (black ink on transparent, masks keep
  their white/black) as a template imageset; `-dark.svg` and `-light.svg` are the
  settled frames. Tint with the repo token `--text-secondary`; the gallery's `--secondary`
  (`#bcbcbc` dark, `#3d444b` light) is exactly `--text-secondary`
  (`app/design-system/zero-delta/tokens/themes.css:14`, `:54`, resolving to
  `--zd-ink-muted` at `app/design-system/zero-delta/tokens/colors.css:19`). In
  SwiftUI that is `.foregroundStyle(.secondary)`, the idiom already at
  `app/GradusiOS/EmptyStateView.swift:47`.
- Menu-bar gauge: keep the status item a template image and leave it untinted;
  the menu bar supplies its own appearance. For the Settings picker, keep the
  existing "Gauge" text and swap the `systemImage:` argument for the asset (for
  example `Label { Text("Gauge") } icon: { Image("gauge-classic-dial-20-template") }`).
- Replace the `arrow.clockwise` bodies in `Icon.syncing` and `Icon.refresh`
  (`Icon.swift:11-13`, `:27-29`) with the refresh asset rather than adding
  stringly-typed call sites.

### Animated, multicolor: waiting and loading

`assets.template` is empty for both. Use Original rendering with light and dark
appearance variants of the exported SVG, or draw the layers as SwiftUI
`Path`/`Shape` and drive only the moving layer with `TimelineView(.animation)`
or `KeyframeAnimator` per phase; the exported SVG is the settled/reduced-motion
frame, animation not baked in. Both are indeterminate activity only: never
derive or announce a percentage, and respect
`@Environment(\.accessibilityReduceMotion)` via the settled asset.

`waiting-dot-rails`, from `motion.animations[0]`:

- Cycle 5400 ms, linear, infinite. Keep the three rails static and translate only
  the dot.
- 0-1800 ms: translate x 0 -> 44 at y 17; at 1800 ms an instant jump to y 32,
  then x 0 -> 44; at 3600 ms an instant jump to y 47, then x 0 -> 44; loop
  restarts at top-left. The CSS `steps(1, start)` at the 1/3 and 2/3 offsets
  makes those jumps instant.
- Reduced motion (`animation: none`): the dot rests at cx 10, cy 17 at the start
  of the top rail above three empty rails. Render
  `assets/waiting-dot-rails-64-dark.svg` / `-light.svg` unchanged there.
- Colors: track stroke `--empty` (`#808080` / `#b7bdc2`) is `--bar-empty-glyph`
  (`themes.css:37`, `:77`, base `--zd-grey-500` at `colors.css:20`). Dot fill
  `--accent` (`#87d787` / `#0f7b3f`) is `--status-ok` (`themes.css:29`, `:69`,
  base `--zd-green` at `colors.css:26`); the dark value is Swift's canonical
  `SignalLevel.green` (`app/GradusKit/Sources/GradusKit/SignalLevel.swift:43`)
  via `SignalColor.forLevel(_:)` (`app/Shared/SignalColor.swift:21-24`). No
  Swift constant exists for light `#0f7b3f` or either track hex; source them
  from the token file rather than inventing new names.

`loading-three-rails`, from `motion.animations[0]`:

- Cycle 1600 ms, linear, infinite. The rails keep fixed lengths (100%,
  two-thirds, one-third) that never change; only a sheen overlay moves.
- Animate sheen dash offset 0 -> -52 px and opacity 0.56 -> 0.4 on each rail.
  Reduced motion (`animation: none`) rests the highlight dashes (4 on, 48 off)
  at the start of each rail at 56% opacity, lengths unchanged.
- Colors: track stroke `--track` (`#4e4e4e` / `#dfe3e6`) is `--bar-track`
  (`themes.css:36`, `:76`, base `--zd-grey-700` at `colors.css:21`); base rail
  `--accent` maps as above; sheen stroke `--ink` (`#e4e4e4` / `#141419`) is
  `--text-primary` (`themes.css:13`, `:53`, base `--zd-ink` /
  `--zd-terminal-black` at `colors.css:18`, `:5`). The app draws such rails today
  as `.secondary.opacity(...)` fills (`app/GradusiOS/Components/UsageBar.swift:47`,
  `app/GradusMac/ProgressBar.swift:33`), close but not the same value; call the
  difference out rather than silently reusing the opacity idiom.

### Sizes

Use `assets/<id>-20-<theme>.svg` for small or inline placements and
`assets/<id>-64-<theme>.svg` at the design size. Never scale the 64 px asset
down; the 20 px forms may carry their own geometry and heavier strokes. For the
two animated elements, `sizes["20"].markup` records that the 20 px form is the
same markup resized (the page has no separate 20 px markup).

### Accessibility

Use `a11yLabel` from `approved.json` when the glyph is the only thing conveying
the state; decorative placements are hidden from accessibility. Exceptions: the
20 px refresh and gauge samples have a null `a11yLabel` and are decorative; the
Mac menu-bar gauge keeps its state-carrying label from `MenuBarBucketLabel.swift:98` / `:121`
instead of the studio label "Option B, semicircular dial with needle"; in
`EmptyStateView` the title and message already speak, so label the composed
element or hide the glyph rather than announcing the same thing twice.

### Element-specific caveats from approved.json

- The flattened SVGs inline computed paints and carry no class, data, var,
  style, text or script; select theme by appearance variant, not by scanning the
  SVG for variables.
- All four have `outsideViewBox: false`, so no standalone-image padding is
  required. All ship both dark and light; none is a single-theme surface.
- Contact-strip cells are padded (glyphs elsewhere overflow their viewBox);
  compare glyph geometry, not cell bounds.
- `verify.json` records that compositor-animated transform frames, the Gradus
  waiting dot by name, can differ from a live render by up to 78 channel levels
  on a few edge pixels (at most 4 pixels above 64, 0.003 percent of a clip). Freezing the live
  element at its computed values reproduces the export; a live raster will not.
  Do not chase those edge pixels when accepting frames.
- Frames were captured with `window.designReview.seek(t, 0)`. Seed 0 shifts
  nothing in this package; the seed-42 546 ms / 42 ms shifts in the conventions
  apply to Wilted and Pantry only.

## Acceptance checks for the implementer

Test setup: `swift-snapshot-testing` image baselines plus XCTest and Swift
Testing, gated by `app/test-gate.sh`. iOS baselines live under
`app/GradusiOSTests/__Snapshots__/<TestFileName>/` and are written through
`assertIOSSnapshot` (`app/GradusiOSTests/DashboardSnapshotFixtures.swift:60-108`,
directory logic at `:7-21`). Mac baselines live under
`app/GradusMacTests/__Snapshots__/` and are compared through
`assertStagedSnapshot` (`app/GradusMacTests/SnapshotTestSupport.swift:55-89`),
which requires the gate's `GRADUS_SNAPSHOT_ROOT` staging (`:5`).

1. Render each element at 20 px and 64 px in dark and light: gauge/menu-bar in
   `app/GradusMacTests` (see `MacSettingsSnapshotTests.swift:175`,
   `MenuContentSnapshotTests.swift:101`); refresh, waiting and loading in
   `app/GradusiOSTests` (see `DashboardSnapshotTests.swift:63-90`).
2. Add a reduced-motion snapshot per animated element: render with
   `.environment(\.accessibilityReduceMotion, true)` and assert it equals the
   settled `-dark` / `-light` asset. No reduced-motion helper exists today; add
   one beside the existing snapshot helpers.
3. Keep the Mac menu-bar label assertions passing
   (`app/GradusMacTests/MenuBarBucketTests.swift:73`, `:126`, `:143`) and add
   equivalent label assertions for the new glyphs; the Mac accessibility harness
   is `app/GradusMacUITests/GradusMacUITestsAccessibility.swift`.
4. Frame-check the animated elements at a few `sampleTimesMs`: `[0, 1800, 3600]`
   for `waiting-dot-rails`, `[0, 900, 1600]` for `loading-three-rails`, against
   `frames/<id>-<theme>.png`, allowing the pixel-match caveat above.
5. Record baselines only with the existing opt-in flags
   (`DashboardSnapshotFixtures.swift:122-128`, `MacSettingsSnapshotTests.swift:10-16`);
   never rewrite or weaken one without inspecting the diff.
6. The GradusiOS-iPhone gate floor is pinned exactly at 232 in
   `COUNTING_LEG_MINIMUMS` (`app/test-gate.sh:90`, policy at `:66-76`); raise it
   deliberately when adding tests there.
7. Screen-seizing UI automation is a release-milestone step only, not per-change
   verification; do not add full-app XCUITest runs here.

## Asset inventory

- `refresh-opposing-loop-arrows`: `assets/refresh-opposing-loop-arrows-20-dark.svg`,
  `-20-light.svg`, `-20-template.svg`, `-64-dark.svg`, `-64-light.svg`,
  `-64-template.svg`; `frames/refresh-opposing-loop-arrows-dark.png`, `-light.png`.
- `gauge-classic-dial`: `assets/gauge-classic-dial-20-dark.svg`, `-20-light.svg`,
  `-20-template.svg`, `-64-dark.svg`, `-64-light.svg`, `-64-template.svg`;
  `frames/gauge-classic-dial-dark.png`, `-light.png`.
- `waiting-dot-rails`: `assets/waiting-dot-rails-20-dark.svg`, `-20-light.svg`,
  `-64-dark.svg`, `-64-light.svg`; `frames/waiting-dot-rails-dark.png`, `-light.png`.
- `loading-three-rails`: `assets/loading-three-rails-20-dark.svg`, `-20-light.svg`,
  `-64-dark.svg`, `-64-light.svg`; `frames/loading-three-rails-dark.png`, `-light.png`.

No `-template.svg` exists for the two animated elements (`assets.template` is
empty in `approved.json`). `verify.json` ships beside this README as the
package's pixel-match record; `approved.json` documents how to read it.
