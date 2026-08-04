# Zero Delta Design System

The house design system for **Zero Delta LLC** (`zerodelta.dev`) and its sibling personas, and the
system every Zero Delta app is built against. Its first consumer is **Gradus**, a real-time AI usage
tracker for local coding agents (macOS CLI + menu bar app + iOS companion).

## Sources this system was built from

| Source | Kind | What was taken from it |
| --- | --- | --- |
| `uploads/IDENTITY_PROTOCOL.md` | Brand protocol (David M. Schmidt / Z-DELTA, last updated March 2026) | Persona model, the four mandatory UI/UX principles, typography split, anti-slop copy rules |
| `gradus/` (mounted local folder, read-only) | Codebase: Python TUI + Swift companion apps | Exact color theme, layout metrics, component inventory, product copy |
| `gradus/gradus/ui.py` | Terminal renderer | The xterm-256 palette, provider accents, threshold ramp, row/column grammar, panel anatomy |
| `gradus/app/GradusMac/MenuContentView.swift` | SwiftUI menu bar | 260px dropdown, 12px padding, 8px stack spacing, 6px capsule bar |
| `gradus/app/GradusiOS/*.swift` | SwiftUI iOS app | Provider card anatomy, the three empty states and their copy |
| `gradus/README.md`, `plans/*.md`, `INVARIANTS.md` | Product docs | Tone of voice, terminology, feature vocabulary |
| `uploads/zerodeltalogo.png`, `zerodeltalogobw.png`, LinkedIn banner + post | Brand assets | Primary and mono lockups, brand grounds |
| `uploads/zerodave-logo-{dark,light}.svg` | Brand assets | Builder-persona wordmark, exact `#00FFFF` / `#141419` values |
| `uploads/usmc.png`, `usmc-ega.svg` | Verification icons | Example proof-of-work mini-icons |

Domains referenced by the protocol (no design files were provided for them): `daveschmidt.dev`
(master record / bridge), `zerodave.dev` (technical sandbox), `zerodelta.dev` (the business).

## Brand architecture — two sides of one coin

Every surface picks a persona, and the persona picks the variables. Structure never changes.

- **Terminal** (`[data-theme="terminal"]`, the default) — the Builder side. Terminal black
  `#141419` + execution cyan `#00FFFF`. Used by `zerodave.dev` and by **all app surfaces**,
  including Gradus, because the product lives in a terminal.
- **Paper** (`[data-theme="paper"]`) — the Consultant side. Paper white + status green. Used by
  `zerodelta.dev`, proposals, invoices, reports and anything print-bound.
- **Bridge** — a neutral-professional blend for `daveschmidt.dev`: paper surfaces, dark slate text,
  green hover, cyan subtle accents. Compose it from the paper theme plus cyan accents; there is no
  separate theme scope yet.

A card on either side has identical markup and identical spacing. Only the variables flip.

---

## CONTENT FUNDAMENTALS

**Voice.** Engineer to engineer. Declarative, specific, load-bearing. Never markety, never cute.
The product describes exactly what it does and exactly what it refuses to do:
*"Probes provider APIs directly using locally authenticated credentials — no PTY, no CLI scraping."*

**Person.** UI copy addresses the user as **you** ("Turn on iCloud sync to see usage data from your
Mac."). Docs and READMEs are impersonal and imperative ("Run `codex logout && codex login` for a
clean OAuth flow."). **I** appears nowhere in product surfaces.

**Casing.**
- Screen titles and button labels: Title Case — `Waiting for First Publish`, `Enable iCloud Sync`,
  `Quit Gradus`, `Open Settings`.
- Data, statuses, errors, key hints: lowercase, no trailing period — `auth required`,
  `stale 7m`, `cached 12m`, `state database not found`, `[r] refresh`, `updating …`.
- Wordmarks: all caps with wide tracking — `ZERO DELTA` / `IT CONSULTANCY`.
- Provider names are verbatim, always: `Codex`, `Claude`, `Antigravity`, `Copilot`, `Cursor`,
  `Vibe`, `OpenCode Go`. Never "AI providers", never a made-up short form.

**Terminology (use these exact words).** window (`5h`, `1w`, `mo`, `ac`, `ap`, `cg5`, `cg1w`),
remaining (never "used"), reset, pace, depleted, stale, cached, offline, snapshot, provider, probe.
Percentages in the UI are **always remaining capacity** — that is a product invariant, not a
preference.

**Sentence shapes that recur.**
- Empty state: cause as the title, then one sentence that names the fix.
  `iCloud Sync Is Off` / "Turn on iCloud sync to see usage data from your Mac."
- Error: `error: <lowercase message>` truncated with an ellipsis at ~60 characters.
- Auth failure: `auth error — press [1] to fix`.
- Depleted window: `0% until Apr 01 00:00`.
- Pace: exactly four forms — `under +38pt`, `on pace`, `over -23pt`, `n/a`.

**Honesty rules (from the protocol and the codebase).**
- Show `n/a` when data is genuinely absent; never hide a row to look tidier, and never invent a
  number. *"Pace is not computable without a known window length. Show 'pace n/a' — this is honest,
  not a gap."*
- No unsubstantiated claims. No throughput metrics, no specific military units.
- Name exact tooling ("OpenAI Codex", "GitHub Copilot"); never list a model family as a tool.
- No phone numbers or physical addresses on public surfaces.

**Anti-slop constraints (mandatory).**
- **No em-dashes** in brand and marketing prose; use a single dash or a semicolon. (The Gradus
  engineering README predates this rule and still contains them — the protocol wins for anything
  new and public.)
- **No emoji.** Anywhere. Ever.
- No exclamation points, no "seamlessly", "effortlessly", "supercharge", "delightful".
- Alt and title text must be specific and actionable: `title="View Zero Delta LLC Consulting
  Services"`, never `title="zerodelta.dev"`.
- Skills and metadata are rendered as two-tone shield badges, not comma-separated lists.

---

## VISUAL FOUNDATIONS

**Color.** One structural ground, one persona accent, one signal ramp, and a fixed hue per provider.
The signal ramp is not decorative — it is a threshold function from `ui.py`: remaining ≥ 70 green
`#87D787`, ≥ 40 yellow `#FFD75F`, ≥ 20 orange `#FFAF5F`, below 20 red `#FF5F5F`. Yellow doubles as
"cached / stale", red doubles as "error / over pace", cyan `#87D7FF` is reserved for reset times and
keyboard keys. Provider hues (Codex blue, Claude pink, Antigravity teal, Copilot sky, Cursor amber,
Vibe orange, OpenCode green) identify a provider and are never reused as status colors. At most two
background values live on a surface: page and card.

**Type.** Two faces, split by content type, per protocol principle II. Inter carries every sentence
a human reads; monospace carries every number, date, provider name, key, path and status. Scale:
46 / 34 / 26 / 20 / 17 / 15 / 13 / 12 / 11 / 10. Body is 15px at 1.55; dense data rows are 13px.
Tracking is wide (0.06em) for eyebrows and wider (0.14em) for the wordmark subline. High contrast
only — no grey-on-grey, ever; every pairing clears WCAG AA at its rendered size. `--text-muted`
(#9A9AA2 terminal, #585F66 paper) is the floor for 11-12px metadata; the darker `--zd-grey-500`
is a bar/track value and must never carry text.

**Layout.** Terminal surfaces sit on a character grid: 1-column (8px) internal padding, 1-column
gutters, cards packed into the shorter of two vertical stacks rather than a row-major grid. Cards
are fixed-width so stack heights are comparable. Content degrades by shrinking the flexible element
(the bar) to zero before any text is cropped; below the two-column floor the whole layout switches
to one line per provider. Apple surfaces use the literal SwiftUI numbers: 260px menu width, 12px
padding, 8px stack gap, 2px row padding, 6px (menu) / 8px (iOS) bar heights, 44px empty-state glyph.

**Mobile layout.** A phone shows one thing at a time, so mobile surfaces do not transcribe the TUI's
five-column row. One full-width column; the most urgent item is promoted to a `hero` tile at the
top; a tile carries one headline number, its capsule bar, secondary windows as chips, and one mono
meta line; the full set of windows lives one tap deeper. Tap targets are 44px minimum, one trailing
control per row, 10px card corners, 24px page gutters, and the page scrolls under a large title.

**Backgrounds.** Flat. No gradients, no hero images, no illustration, no texture, no pattern. The
only imagery in the brand is the logo lockup on its dark slate ground (`assets/brand/`), which is
photographic-metal and used at brand scale only — never behind UI. Imagery vibe when it exists:
cool, desaturated, near-monochrome slate; a faint print grain on the paper side. Never warm.

**Depth.** Depth is a 1px border plus a one-step surface value change. Terminal panels have no
shadow at all. Off-terminal chrome (the menu bar popover, an iOS banner) gets exactly one soft
ambient shadow `--shadow-menu`. No inner shadows, no glows, no colored halos on accents.

**Corners.** Terminal panels are square (`--radius-none`) — that is the aesthetic, not an oversight.
Buttons and badges 4px, app cards 8px, sheets 10px, capsule bars pill. Nothing else rounds.

**Cards.** A card is: 1px border in the provider accent (or steel when generic), square corners,
flat card surface, title inset into the top border, optional badge inset bottom-left, rows stacked
2px apart. Failure recolors the border yellow (stale/offline) or red (error) — the border, not the
fill.

**Motion.** Functional only. Bars and toggles move in 180ms on `cubic-bezier(.2,0,.2,1)`; the
warmup spinner steps every 80ms; the refresh countdown flips in place to `updating …`. No entrance
animations on data, no bounce, no spring, no parallax, no skeleton shimmer — a refresh replaces
values in place so the user's eye stays on the row it was reading.

**Hover.** Buttons and rows shift value, never hue: a hairline border brightens, a link moves from
cyan-blue to the persona accent. Links are dashed-underlined and stay underlined on hover.
**Press.** A short opacity dip (~0.7). No scaling, no translation, no color inversion.
**Focus.** A 2px accent ring (`--shadow-focus`); never remove the outline.

**Transparency and blur.** Reserved for OS chrome only (the macOS menu bar strip, an overlay
scrim). Never on a card, never behind data — a translucent panel over a busy terminal is
unreadable, which the legibility principle forbids.

**Borders and dividers.** `--border-hairline` for structure, provider accent or steel for panels,
`--border-strong` (2px) only for a print rule on the paper side. Dividers are 1px full-bleed lines,
not padded insets.

---

## ICONOGRAPHY

**The product's icon system is unicode glyphs in the mono face.** That is not a shortcut; the CLI is
the flagship surface and it can only draw characters. The full working set: `↻` refresh, `↑` under
pace, `↓` over pace, `=` on pace, `█` `▓` bar fill, `░` bar empty, `·` unknown, `[!]` warning,
`[q]` `[r]` `[1]` key hints, `—` n/a, `│` panel edge, `…` truncation, `⠋⠙⠹⠸` spinner frames.
Use them in web surfaces too — they are brand-authentic and need no dependency.

**Mobile and web chrome uses Lucide, pinned.** No icon font, sprite sheet or SVG icon set exists in
the codebase, and nothing was drawn to fill the gap. `components/mobile/Icon.jsx` fetches
`lucide-static@0.492.0` icons once and inlines them, so they inherit `color` instead of shipping a
recoloured copy. **Flagged substitution** — swap the CDN base in `ICON_CDN` if you license a set.

**Apple surfaces use SF Symbols**, referenced by name in the Swift source. Apple does not license
them for redistribution, so none were copied into `assets/`; `Icon.jsx` exports `SF_TO_LUCIDE`, the
fixed pairing between the two, and `<Icon name="icloud.slash">` resolves through it. Keep both sides
of a pair in sync when you add an icon:

| SF Symbol (Swift) | Lucide (web) | Used for |
| --- | --- | --- |
| `icloud.slash` / `icloud` | `cloud-off` / `cloud` | sync off, sync on |
| `wifi.slash` | `wifi-off` | offline / stale provider |
| `hourglass` | `hourglass` | waiting for first publish |
| `person.crop.circle.badge.exclamationmark` | `user-x` | not signed in to iCloud |
| `exclamationmark.triangle.fill` | `triangle-alert` | warning banner, depleted provider |
| `bell` | `bell` | notification settings |
| `gearshape` | `settings` | settings entry point |
| `arrow.clockwise` | `refresh-cw` | refresh now |
| `chevron.left` / `chevron.right` | `chevron-left` / `chevron-right` | back, drill-in |
| `laptopcomputer` / `iphone` | `laptop` / `smartphone` | publishing Mac, this device |
| `clock`, `checkmark.circle`, `list.bullet`, `info.circle` | `clock`, `circle-check`, `list`, `info` | metadata rows |

**Icon rules.**
- **Chrome only.** Navigation, settings, notifications, empty states. Data keeps mono glyphs — never
  put an icon in a usage row, and never replace `[!]` with a warning triangle inside a card.
- Sizes: 16 inline, 20 default chrome, 24 nav bar, 44 empty-state glyph. Tap targets are 44px
  (`IconButton`), never the icon box itself.
- Colour is inherited, so tint by wrapping, not by passing a hex.
- Vendor stroke is 2px. The brand would prefer a 1.5px hairline; the vendor files are used as
  shipped — **known compromise**, revisit if a licensed set arrives.
- Every `IconButton` needs a `label` that states the action ("Open Gradus settings"), per the
  descriptive-accessibility principle.

**Mini-icons (proof of work).** Protocol principle IV: every listed company, institution or
organization gets a crisp 16×16 or 32×32 icon beside its name, from a **local** static file (never a
remote favicon API — rate limits and broken images), always `object-fit: contain`. `assets/icons/`
holds the two supplied examples (`usmc.png`, `usmc-ega.svg`). Provider identity in Gradus is carried
by the accent hue and the verbatim name, not by vendor logos.

**Emoji are never used.** Not in UI, not in docs, not in commit messages.

---

## What is here

### Foundations
`styles.css` (the only file consumers link) imports every token file:

- `tokens/colors.css` — brand core, persona accents, signal ramp, provider accents, neutrals
- `tokens/typography.css` — faces, size scale, weights, tracking
- `tokens/spacing.css` — spacing scale, terminal cell grid, Apple surface metrics
- `tokens/borders.css` — hairlines and radii
- `tokens/elevation.css` — the two shadows and the hairline inset
- `tokens/motion.css` — durations, easing, spinner cadence, refresh interval
- `tokens/themes.css` — the `terminal` / `paper` semantic aliases (use these, not the raw `--zd-*`)
- `tokens/fonts.css` — webfont loading

`guidelines/*.card.html` — 22 specimen cards (Brand, Colors, Type, Spacing, Foundations) rendered
in the Design System tab.

### Components
`components/core/` — **Button**, **Toggle**, **Shield**, **MiniIcon**, **DeepLink**
`components/data/` — **UsageBar**, **UsageRow**, **PaceIndicator**, **ProviderCard**, **StatusBadge**
`components/layout/` — **Panel**, **HeaderBar**, **FooterHint**, **ErrorCard**, **EmptyState**
`components/mobile/` — **MobileNavBar**, **StatTile**, **ListRow**, **Icon**, **IconButton**

Each directory has a `*.card.html` showing its states, and each component has a `.d.ts` props
contract plus a `.prompt.md` with usage rules.

**Inventory provenance.** Every component maps to something the sources define: the TUI's panel,
percentage bar, pace cell, usage/depleted/generic rows, error and auth cards, header, footer hints
and freshness badges; the SwiftUI toggles, buttons, provider rows and empty states; the protocol's
shield badges, mini-icons and dashed deep links. Nothing else was added — no Tabs, Modal, Avatar or
Toast, because the products have none.

**Intentional additions**
- `--font-mono-ui` alongside the protocol's `Courier New`: dense app data needs a UI-metric mono
  (SF Mono / Menlo), which is what the terminal actually renders. `--font-mono` remains the brand
  face for prose-adjacent metadata.
- `Panel` was factored out of `ProviderCard` / `ErrorCard` so both share one border-and-title
  anatomy, matching how `ui.py` shares one panel builder.
- `components/mobile/` (MobileNavBar, StatTile, ListRow, Icon, IconButton) exists because the iOS
  source is a bare `List` of cards with no mobile design of its own. These are the mobile
  counterparts of the TUI grammar, not new product ideas: StatTile is ProviderCard for one thumb,
  ListRow is the SwiftUI settings row, Icon is the SF Symbol bridge.

### UI kits
- `ui_kits/gradus-cli/` — the terminal dashboard: live, warming up, auth failure, depleted micro
  cards, and the sub-79-column compact layout. `r` refreshes, `q` quits.
- `ui_kits/gradus-mac/` — the menu bar status item and its 260px dropdown, including the
  no-snapshot state.
- `ui_kits/gradus-mobile/` — **the iPhone app**: Now (hero + ranked providers), provider detail,
  settings, the three empty states and the warning banner. Tap a tile to drill in. Its README has a
  TUI-to-phone translation table.
- `ui_kits/providers.js` — shared fixture data shaped like `.state/snapshot-v2.json`.

### Assets
`assets/logos/` — Zero Delta primary (dark) and mono lockups, zerodave wordmarks (light + dark),
Gradus app icon **sketch** (`gradus-app-icon.svg` ramp, `-mono.svg` cyan) — see caveat 6
`assets/brand/` — LinkedIn banner and post grounds
`assets/icons/` — supplied verification mini-icons
`assets/reference/` — original Gradus TUI screenshots (reference only, not brand assets)

### Root files
`styles.css` · `readme.md` · `SKILL.md` · `thumbnail.html` · `tokens/` · `guidelines/` ·
`components/` · `ui_kits/` · `assets/`

---

## Open questions / flagged substitutions

1. **Status green is inferred.** The protocol names "Status Green" but gives no hex.
   `--zd-status-green: #0F7B3F` was chosen to clear AA on paper white. **Confirm or replace.**
2. **No font binaries were supplied.** Inter loads from Google Fonts; `Courier New` is a system
   face. Send real files (or confirm the Google-hosted route) and `tokens/fonts.css` gets rewritten
   with `@font-face` rules.
3. **No logo mark was drawn.** Only supplied artwork is used. The Zero Delta lockup exists as raster
   only (PNG) — a vector version would let it scale into UI chrome and favicons.
4. **SF Symbols and Lucide are substitutions** in web mocks (see ICONOGRAPHY).
6. **The Gradus app icon is a sketch, not artwork.** No icon existed in the codebase. It is three
   capsule bars descending the signal ramp (green, yellow, red) on terminal black — the product's
   own grammar at icon scale, drawn with plain rectangles so it stays legible at 29px. It is a
   placeholder for a designed mark: **send real artwork and it gets replaced.** Squircle masking is
   applied by iOS; the SVG is a full-bleed square.
7. **No design files exist for the three websites.** `zerodave.dev`, `zerodelta.dev` and
   `daveschmidt.dev` have tokens and rules here but no UI kit; the bridge theme is described, not
   yet coded as a scope.
