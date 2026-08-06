# gradus

Real-time terminal monitor for local `codex`, `claude`, `agy`, `copilot`, `cursor`, `vibe`, and `opencode go` usage.

Probes provider APIs directly using locally authenticated credentials — no PTY, no CLI scraping. Each provider uses its own HTTP or internal API path, so probes are fast and reliable.

![Warmup screen](docs/screenshots/warmup.png)

![Live dashboard](docs/screenshots/dashboard.png)

## Features

- Monitors Codex usage via the OpenAI usage API
- Monitors Claude usage via the Anthropic account API
- Monitors Antigravity (`agy`) usage via the Cloud Code `retrieveUserQuotaSummary` API — the same grouped quota `agy`'s own Models & Quota panel shows. Authenticates read-only with `agy`'s OAuth token from the macOS Keychain (service `gemini`, account `antigravity`); the monitor never refreshes or rewrites that token, so it can't disturb `agy`'s own auth.
- Monitors Copilot usage via the GitHub REST API (using `gh` CLI credentials)
- Monitors Cursor credit usage via the Cursor Dashboard API
- Monitors Vibe usage via the Mistral billing API
- Monitors OpenCode Go usage via the opencode.ai SolidStart console (5h/1w/monthly quota)
- Refreshes every 120 seconds by default
- Shows Codex and Claude session-window usage, reset times, and pace indicators. Codex windows are slotted by the API's declared window span, not by position. The Codex 5-hour limit row is permanently visible and will display as `n/a` when omitted by the upstream API, ensuring immediate visibility upon restoration.
- Shows Antigravity Gemini-group 5-hour and 1-week quota remaining, reset times, and pace indicators (matching `agy`'s Models & Quota panel), plus conditional Claude+GPT (`cg5`, `cg1w`) group activation when at least one valid C+G remaining percentage is below 100%. Rows render independently: each valid C+G row below 100% appears; exact-100%, missing, or malformed sibling rows are omitted.
- Shows Copilot monthly remaining (`mo`), reset, and billing-cycle pace
- Shows Cursor Auto + Composer and API remaining capacity, reset, and billing-cycle pace
- Shows Vibe monthly remaining (`mo`), reset, and billing-cycle pace
- Shows OpenCode Go 5h/1w/monthly remaining quota, reset times, and pace indicators
- Shows compact single-line error cards to reduce vertical noise when a provider is unavailable
- Retains cached usage data during transient network errors with an `(offline Xm)` title indicator; shows a `stale` panel after 5 minutes of continuous failure
- Supports live keyboard shortcuts (`q` quit, `r` refresh now)
- Supports `.gradus.json` (legacy `.ai_monitor.json` also read as a fallback) for provider selection and interval configuration
- Sends one-shot macOS pace/depletion notifications and marks warning providers with a `[!]` badge
- Renders depleted providers as centered 1-line micro-cards paired side-by-side (ratio Cursor:Copilot:Vibe = 2:1:1) at the bottom of the dashboard to conserve vertical space
- Uses a shared provider card renderer so reset labels and pacing rows stay aligned across providers
- Canonicalizes reset displays to one local format across provider-specific strings
- Renders a compact grid dashboard optimized for terminal use
- Exposes `--json` output for scripting and automation, including normalized reset display fields

## Requirements

- Python 3.10+
- Codex: `~/.codex/auth.json` present (created by `codex login`). If the Codex card shows a persistent "session expired" error and the `[1]` re-auth shortcut doesn't unstick it, the server-side session has been revoked (the `codex login` refresh path re-mints a token bound to the same revoked session). Run `codex logout && codex login` for a clean OAuth flow.
- Claude: `~/.claude/` credentials present (created by `claude login`)
- Antigravity (`agy`): signed in via `agy` (stores its OAuth token in the macOS Keychain). The monitor reads it read-only; the first read may prompt for Keychain access — choose "Always Allow" so background refreshes stay silent. The token expires ~hourly and only `agy` refreshes it, so when the token lapses the monitor **nudges `agy` to refresh its own token** by running `agy models` (a non-interactive, quota-free authenticated command) and re-reads the Keychain — the card self-heals without manual action. If that nudge can't recover (e.g. `agy` isn't installed on `PATH`, or `agy`'s own refresh token is dead), the card falls back to an auth error; run `agy` to re-authenticate. The nudge runs only in the interactive TUI, never on the read-only `--write-snapshot`/headless path (INV-2).
- Copilot: `gh` CLI authenticated (`gh auth login` or OAuth token present)
- Cursor: app or browser session authenticated
- Mistral console session authenticated (Safari/Chrome cookie extraction supported)
- OpenCode Go: opencode.ai console session authenticated (Safari `auth` cookie)
- `rich>=15.0` (installed automatically via `pip install` or `uv sync`)
- `cryptography>=42` (installed automatically; used to decrypt Chrome `v10` cookies in-process so the AES key is never placed on a subprocess command line)
- A terminal that supports ANSI color

## Run

```bash
python3 -m gradus
./monitor
```

Useful options:

```bash
python3 -m gradus --once
python3 -m gradus --interval 30
python3 -m gradus --interval 60
python3 -m gradus --json
python3 -m gradus --debug
python3 -m gradus --providers Claude,Codex,Copilot,Antigravity
python3 -m gradus --write-snapshot
python3 -m gradus --refresh-snapshot
python3 -m gradus --verify-refresh-health --duration 360
python3 -m gradus --history-at 2026-08-04T12:00:00Z
python3 -m gradus --history-at 2026-08-04T12:00:00Z --history-provider Antigravity --history-max-gap 900
./monitor --once
```

When `--debug` is enabled, raw captures are written to `/tmp/gradus_*_capture.txt` (mode `0600`, via the same atomic private-write path as the credential caches) — except under headless (`--json`, `--write-snapshot`), where INV-2 forbids the side effect and no capture file is written.

The raw payload is **not** written into the router-facing `.state/snapshot.json`: the snapshot's `error` field carries only the plain provider message (bounded and credential-free). The debug-augmented `debug_detail` goes to **stderr** under `--debug`, never into the JSON document — `--json` on stdout is a machine contract consumed by the review-plugin router, and INV-1 keeps raw HTTP bodies and credential material off it (enforced by `test_render_json_data_is_safe_allowlist`). So `gradus --json --debug > out.json` leaves `out.json` parseable while the detail lands on your terminal.

The stderr channel is wired on all three non-interactive paths — `--json`, `--write-snapshot`, and `--once` — so `2>/dev/null` always gives you the clean surface and `2>&1` always gives you the diagnosis. On `--write-snapshot` the detail is emitted *before* the persist step, so a run that both probes badly and fails to write still reports why. The live TUI is deliberately excluded: Rich holds the alt-screen there and a stderr write would corrupt the frame, so that path reports through `.logs/gradus.log` only.

Error strings published to the devices are classified by exception **type**, not message content (`providers/_base._safe_probe_error`): a `TimeoutError` becomes `"provider probe timed out"` and a `ConnectionError` becomes `"provider probe network error"`, both of which the transient classifier recognizes so the last-known-good reading is served instead of a failure card. Exception text itself is never published, because a provider exception can embed subprocess output or a signed URL.

### Logs

Runtime logs go to `.logs/gradus.log` (gitignored, rotating at 1 MB with two backups), anchored to the package directory rather than the working directory — `local.gradus-snapshot` runs from launchd with a cwd gradus does not control. WARNING and above are always recorded; `--debug` adds DEBUG. Set `GRADUS_LOG_PATH` to redirect; the test suite sets it (see `tests/conftest.py`) so pytest's own warnings cannot rotate real production evidence out of the log.

Optional config file (`.gradus.json` in your current working directory; legacy `.ai_monitor.json` also read as a fallback):

```json
{
  "providers": ["Claude", "Codex", "Copilot", "Cursor", "Antigravity", "OpenCode Go", "Vibe"],
  "interval": 120
}
```

## How It Works

1. On startup, initialize one HTTP provider per enabled service.
2. Probe each provider's API endpoint using local credentials (OAuth tokens, cookie jars, etc.).
3. Parse the structured JSON response to extract usage percentages and reset timestamps.
4. Re-render the dashboard on the chosen refresh interval and evaluate normalized pace/depletion warnings.

## Output

Normal usage rows use a responsive, percentage-first layout: `label | % | bar | reset | pace`.
The bar consumes the flexible space and can shrink to zero before any percentage is
cropped, so integer values such as `0%`, `87%`, and `100%` remain readable at narrow
card widths. Depleted rows use a separate `0% until <reset_time>` layout with no bar;
generic status cards and error/auth cards likewise remain readable as key/value or
message layouts rather than being forced through usage-bar columns.

Percentages **truncate, never round**, and every surface — TUI, Mac, iOS, iPad —
uses the same rule. Truncation is the correct direction for a remaining budget:
rounding up would claim headroom that does not exist, so `47.8` reads as `47%`
rather than `48%`. Below 10% the value keeps one decimal, which is correctness
rather than decoration — a window is only "exhausted" at or under 0.5%, so
whole-number truncation would print a live window at 0.7% as `0%`. The rule is
implemented twice (`_percent_str` in Python, `GradusKit.percentText` in Swift)
and pinned by a truth table both test suites read; see TESTING.md.

At safe widths, dashboard cards are packed into two independently measured vertical
stacks with a one-cell horizontal gutter and no empty vertical-row gutter. The
two-column layout holds down to 79 columns — the width at which two bar-less cards
still fit a full `reset` and `pace` cell — so a narrowing terminal shrinks the usage
bars to nothing and stays compact instead of stacking early and re-widening the bars.
Below 79 columns the dashboard automatically switches to a compact single/double-line layout: each active provider gets 1–2 lines (max 2 windows per line, continuation lines indented), blank lines separate providers, and exhausted (0%) providers are dropped entirely. Window labels (`5h:`, `1w:`, `ac:`, etc.) show percentage and pace arrows (`↑`/`↓`/`=`). Cursor and Vibe get special compact handling converting percent-used to percent-remaining with billing-cycle pace. No `--compact` flag is needed — the switch is fully automatic and responsive to terminal width.

Codex and Claude cards show:

- `5h`: remaining usage for the current 5-hour window, reset time, pace indicator
- `1w`: remaining usage for the current 1-week window, weekly reset time, pace indicator

For Codex the `5h` row is permanently visible; if OpenAI's API ceases to report a sub-day window, it gracefully renders as `n/a` rather than omitting the row entirely. This ensures immediate visibility if and when the window is restored.

Antigravity card shows (Gemini model group — the pool `agy` consumes):

- `5h`: remaining quota for the current 5-hour window, reset time, pace indicator
- `1w`: remaining quota for the current 1-week window, weekly reset time, pace indicator

When the Claude+GPT group has at least one valid remaining percentage below 100%, the group activates. Rows render independently: each valid C+G percentage below 100% produces its `cg5` (5-hour) or `cg1w` (1-week) row; exact-100%, missing, or malformed sibling rows are omitted. If both valid C+G percentages are exactly 100%, that idle group is omitted. C+G rows participate in the same `[!]` badge and one-shot notification warning membership as other rendered windows.

Copilot / Cursor / Vibe cards show:

- `mo`: monthly remaining percentage, billing-cycle reset, pace indicator
- `ac`: Cursor Auto + Composer remaining percentage, derived from `autoPercentUsed`
- `ap`: Cursor API pool remaining percentage, derived from `apiPercentUsed`

Reset displays are normalized before rendering:

- Same-day resets render as `HH:MM` (24h)
- Future resets render as `Mon DD HH:MM`
- Relative vendor text like `Resets in 2h 14m` is converted to the same absolute local display

## JSON Output

`--json` prints a read-only snapshot and is **machine-safe** — like `--write-snapshot`, it engages the headless path (no browser launch, token refresh, cache writes, or warning notifications), and a provider without cached credentials reports `auth required` rather than triggering interactive recovery. The `data` block is projected through the same `SAFE_DATA_KEYS` allowlist as the persisted snapshot (no `account_email` or other PII), and normalized reset display fields are added under `display`. Antigravity's Claude+GPT fields and windows are deliberately excluded from `--json`; Gemini output remains unchanged.

Example:

```json
{
  "updated_at": "2026-03-14T08:22:30",
  "providers": [
    {
      "name": "Codex",
      "ok": true,
      "source": "api",
      "data": {
        "five_hour_reset": "Resets 13:16",
        "weekly_reset": "Resets on Mar 18, 9:00AM"
      },
      "display": {
        "five_hour_reset_display": "1:16 PM",
        "weekly_reset_display": "Mar 18 9:00 AM"
      },
      "error": null
    }
  ]
}
```

## Router-facing snapshot (`--write-snapshot`)

A sibling process or router can read `.state/snapshot.json` (schema v1) or `.state/snapshot-v2.json` (schema v2) instantly — no probing, no browser, no credential I/O. Both files are credential-free and gitignored (deliberately not `.cache/`, which holds auth cookies/tokens that a consuming router must never read).

The TUI writes the snapshot on every refresh cycle. The one-shot `--write-snapshot` path and the explicit credential-aware `--refresh-snapshot` observer also write it when invoked. All three persistence paths journal the committed schema-v2 result to the local history store.

**Read-only guarantee.** The `--write-snapshot` path never opens a browser, spawns a subprocess, refreshes a token, evicts a cookie cache, or sends notifications. Providers with missing or expired credentials surface as `ok: false`. It writes v1 first and v2 second; each file is independently atomic, so a partial failure is logged and exits 1 while the successful sibling remains current. History journaling is a separate best-effort output: it is attempted only after a read-back confirms that schema v2 committed, and a history failure never rolls back a valid snapshot.

**Headless coverage.** Codex and any provider whose `.cache/` cookie file is still warm run headlessly — reading a cached cookie file is a benign read, allowed. Antigravity's only credential is an OAuth token read via a `security` subprocess, which the read-only path forbids, so a headless probe reports `auth required: no cached credentials`. When a recent healthy interactive snapshot exists, headless writes carry it forward, including the schema-v2 `Antigravity (Claude)` synthetic entry. Snapshot writers use a per-file lock and reject an older payload, so a slower background refresh cannot replace newer TUI data. Run the TUI once after a fresh install or when the prior snapshot has expired to seed the shared Agy buckets.

**launchd refresher (manual install).** A ~120 s background job keeps the snapshot current without the TUI running.

The repository-owned templates in `launchd/` invoke the explicit credential-aware
`--refresh-snapshot` observer. After installing or changing the wrapper or plist,
run `gradus --verify-refresh-health --duration 360` and require a successful result
before relying on unattended refresh.

- Wrapper: `~/.launchd/scripts/gradus_snapshot.sh`
- Plist: `~/Library/LaunchAgents/local.gradus-snapshot.plist` (StartInterval 120, RunAtLoad, Background)
- Logs: `~/Library/Logs/homelab/gradus-snapshot/`
- Render and install from the repository checkout (the wrapper template requires the explicit repository-root replacement):

  ```bash
  cd /Users/dave/Documents/Projects/gradus
  GRADUS_REPO="$PWD"
  GRADUS_PYTHON="$GRADUS_REPO/.venv/bin/python3"
  GRADUS_WRAPPER="$HOME/.launchd/scripts/gradus_snapshot.sh"
  GRADUS_PLIST="$HOME/Library/LaunchAgents/local.gradus-snapshot.plist"
  GRADUS_LOG_DIR="$HOME/Library/Logs/homelab/gradus-snapshot"
  mkdir -p "$(dirname "$GRADUS_WRAPPER")" "$(dirname "$GRADUS_PLIST")" "$GRADUS_LOG_DIR"
  sed -e "s|__GRADUS_REPO_ROOT__|$GRADUS_REPO|g" \
      -e "s|__GRADUS_PYTHON_PATH__|$GRADUS_PYTHON|g" \
      launchd/gradus_snapshot.sh.in > "$GRADUS_WRAPPER"
  chmod 755 "$GRADUS_WRAPPER"
  sed -e "s|__GRADUS_WRAPPER_PATH__|$GRADUS_WRAPPER|g" \
      -e "s|__GRADUS_STDOUT_PATH__|$GRADUS_LOG_DIR/stdout.log|g" \
      -e "s|__GRADUS_STDERR_PATH__|$GRADUS_LOG_DIR/stderr.log|g" \
      launchd/local.gradus-snapshot.plist.in > "$GRADUS_PLIST"
  plutil -lint "$GRADUS_PLIST"
  GRADUS_DOMAIN="gui/$(id -u)"
  if launchctl print "$GRADUS_DOMAIN/local.gradus-snapshot" >/dev/null 2>&1; then
    launchctl bootout "$GRADUS_DOMAIN/local.gradus-snapshot"
  fi
  launchctl bootstrap "$GRADUS_DOMAIN" "$GRADUS_PLIST"
  gradus --verify-refresh-health --duration 360
  ```
- Uninstall: `launchctl bootout gui/$(id -u)/local.gradus-snapshot`

**Schema** (`schema_version: 1`):

```json
{
  "schema_version": 1,
  "updated_at": "<tz-aware ISO 8601>",
  "providers": [
    {
      "name": "Codex",
      "ok": true,
      "error": null,
      "windows": [
        {
          "id": "five_hour",
          "percent_left": 74,
          "reset_iso": "2026-07-05T18:30:00+00:00",
          "window_hours": 5,
          "pace_delta": 0.12
        }
      ],
      "data": { "...PII-scrubbed usage/reset fields only..." }
    }
  ]
}
```

All 7 canonical providers are always present (Codex, Claude, Antigravity, Copilot, Cursor, OpenCode Go, Vibe); a not-enabled or filtered provider appears as `ok: false, error: "provider not enabled"`. `percent_left` is always remaining (0–100). `pace_delta` is a signed fraction — positive means healthy (remaining capacity ahead of expected consumption rate), unclamped.

In this v1 router snapshot, Cursor emits at most one `billing_cycle` window, sourced from its numeric `credit_percent_left` remaining percentage. Schema v2 preserves every non-Cursor window and instead publishes Cursor's independent numeric `ac` (Auto + Composer, from `autoPercentUsed`) and `ap` (API pool, from `apiPercentUsed`) windows, omitting either unavailable pool. Consumers may roll back by selecting the v1 path/version; retain v1 until all consumers have migrated.

`.state/snapshot.json` is consumed by hermes-publisher's GradusCollector as well as review-plugin; consumers reject unsupported schema_version; incompatible changes to top-level payload, provider-entry fields, or windows[] require schema bump and coordinated compatibility updates in both consumer projects. Antigravity's Claude+GPT fields and windows remain excluded from router snapshot v1, while schema v2 includes the synthetic `Antigravity (Claude)` entry so the shared third-party pool is visible to v2 consumers. `--json` remains schema-agnostic local/debug output and does not select or persist either router schema.

## Credential-free capacity history

Each successful TUI refresh, `--write-snapshot`, or `--refresh-snapshot` run may append the committed schema-v2 payload to `.state/history/YYYY-MM-DD.jsonl`. The history envelope has its own `history_schema_version`, the unchanged snapshot, safe provider provenance, and separate probe/capacity observation metadata. It never stores credentials, raw upstream bodies, account identifiers, or debug text. The directory is mode `0700`; partitions and the lock file are mode `0600`.

History is retained for seven days using the observation timestamp, written with a private lock and atomic partition replacement. Appends reject duplicate or backward timestamps; an incomplete final JSONL line is recoverable on the next append. History is best effort and never makes a committed snapshot appear uncommitted. The stored provenance identifies the Antigravity Gemini direct pool, the shared `3p-*` Claude/GPT pool with its `Sonnet target only` downstream policy, and the host-observed OpenCode Go route. These descriptors document capacity origin; they do not prove executor credentials, model liveness, or downstream routing success.

Historical queries are read-only and initialize no providers, credentials, logging, subprocesses, or network calls:

```bash
python3 -m gradus --history-at 2026-08-04T12:00:00Z
python3 -m gradus --history-at 2026-08-04T12:00:00Z \
  --history-at 2026-08-04T13:00:00-04:00 \
  --history-provider Antigravity --history-max-gap 900
```

The compact JSON result reports `history_status`, the nearest prior observation, its distance, each provider's `capacity_state` (`observed`, `carried`, `failed`, `not_enabled`, or `invalid`), probe outcome, synthetic status, and safe provenance. A result is marked `verified: false` when there is no prior record, the requested gap exceeds `--history-max-gap`, the history is corrupt, or the provider is absent. `executor_auth_verified` is always `false`: this feature reports observed capacity history, not proof that an executor can authenticate or serve a requested model. Times before history was introduced are therefore unverified rather than inferred.

## Notes

- Antigravity probing reads `agy`'s Keychain token and POSTs an empty body to `retrieveUserQuotaSummary` (the endpoint rejects a non-empty body with HTTP 400 and the default `Python-urllib` User-Agent with HTTP 403; the provider sets an explicit User-Agent). On an expired token it first nudges `agy` to refresh its own token via `agy models`, then re-reads the Keychain; only if that fails does it surface the "run `agy`" re-authenticate message. The monitor never handles `agy`'s client secret or refresh token — `agy` refreshes its own token via its own OAuth client — so the read-only-toward-`agy`'s-stored-credentials guarantee holds.
- Claude probing reads `~/.claude/` OAuth credentials directly; run `claude login` to refresh if probes fail.
- During each timed refresh, the header switches from `refresh XXs` to a single in-place `updating …` state until all providers complete, then resumes the countdown.
- Live rendering uses the `rich` library's `Live` display with alt-screen mode, eliminating scrollback buffer growth.
- In live mode, press `q` to quit or `r` to trigger an immediate refresh.
- Cursor and Vibe try Safari cookie extraction first; Vibe also supports Chrome cookie extraction. Cookies are cached locally at `.cache/<provider>_cookies.json` (gitignored) to survive Safari disk-sync lag and reduce spurious re-auth prompts; the cache is evicted on API 400/401/403 errors (Claude also returns 400 when a cached `lastActiveOrg` fails its UUID validator).
- **Credential storage.** The `.cache/` credential files (provider cookies/tokens) and the Codex `~/.codex/auth.json` are written mode `0600` inside a `0700` directory via a single atomic private-write helper — a `tempfile.mkstemp` temp file (born `0600`, independent of umask) swapped in with `os.replace`, so the file is never world-readable, even momentarily. Pre-existing caches are also tightened to `0600` opportunistically on the next interactive (non-headless) read. Note that `0600` protects against *other local users*; it does **not** stop iCloud replication. The caches live under `~/Documents/Projects/gradus/.cache/`; if you ever enable **Desktop & Documents** iCloud sync, exclude this project (or its `.cache/`) from sync — e.g. a `.nosync`-suffixed directory is not synced — so live credentials are not copied to Apple's cloud. (Desktop & Documents sync is off by default.)
- A normalized window warns when the usage-signal ramp classifies it **orange or red** — the same rule that colors the row, not a parallel one. In practice that means depleted, or a finite pace delta below `-0.10`, or (for a window whose payload carries no reset timestamp, so no pace can be computed) below 40% remaining. Every window spec defines a pace source, so the third case is a degraded-data path rather than a normal one. `[!]` badges, one-shot macOS notifications, the Mac menu's "N low" count, the iPhone's warning tier and the CloudKit push subscription all read this one predicate, aggregated the same way: a provider warns when **any** of its windows does. Notifications name the warning window IDs. Antigravity's conditional C+G rows (`cg5`, `cg1w`) participate in this membership. Cursor's `ac` and `ap` pools are evaluated independently in-process and in schema v2, while v1 continues to publish only its `billing_cycle` window.
- Vibe uses Mistral's `usage_percentage` field as percent used directly. If Mistral shows `1.08% used`, Gradus will render about `99%` remaining after rounding.
- Cursor reads billing-cycle and usage data from the nested `planUsage` payload. `planUsage` carries three numbers but Cursor only has two real usage pools: `autoPercentUsed` (first-party Auto + Composer) and `apiPercentUsed` (API/third-party pool) are both percent-USED for their own pool; `remaining`/`limit` cents are a dollar-denominated spend meter, not a third pool. The card shows Cursor's two real usage pools: `ac` is the Auto + Composer pool, converted from `autoPercentUsed` (percent used) to remaining capacity; `ap` is the API pool, converted from `apiPercentUsed` (percent used) to remaining capacity the same way. The cents-derived dollar meter (`credit_percent_left`) is computed by the provider and retained as internal metadata, but is no longer displayed, alert-evaluated, or persisted/projected — it doesn't belong under "ap" or any capacity window. Neither `--json` nor the v1/v2 router snapshots emit `credit_percent_left` any longer; the v1 `billing_cycle` window remains sourced from it internally (unchanged), but it no longer appears in the projected `data` block.

## Limitations

- This depends on current local CLI/API behavior across `codex`, `claude`, `agy`, `copilot`, `cursor`, `vibe`, and `opencode.ai`.
- If any vendor changes its TUI wording or layout, the parser may need to be updated.
- Reset windows are only shown when the CLI output exposes them.
- Terminal rendering can vary across fonts and terminal emulators.
- OpenCode Go uses content-hash server-function IDs from the deployed opencode.ai console build. If opencode rebuilds the console, these hashes change and the probe returns an error until the IDs are updated in the provider. The probe gracefully surfaces this as a clear error message.

## Known Issues

- **Claude `/usage` may return "only available for subscription plans"** even on valid Team or Pro seats. This is a server-side issue where the Anthropic usage API returns empty limit buckets (`five_hour`, `seven_day`, `seven_day_sonnet` are all null). The PTY probe itself works correctly. When the API starts returning data again, the Claude card will populate automatically.
- The Antigravity token is minted under `agy`'s own OAuth client, so this path is coupled to `agy`'s internal API. If a future `agy` release changes the Keychain layout or the `retrieveUserQuotaSummary` contract, the card will show an error until the provider is updated.

## Companion apps (macOS/iOS)

`app/` holds a Swift companion pair that mirrors this dashboard off-machine:

The canonical Zero Delta design-system source package is preserved at
[`app/design-system/zero-delta/`](app/design-system/zero-delta/). It includes
the shared brand rules, tokens, component references, Gradus UI kits, and the
Gradus app icon assets. GradusiOS 1.4 applies the supplied signal-ramp icon,
active-first provider sorting, compact exhausted grouping, selectable bucket
badges, Settings controls for sorting/visibility, and the shared expected-pace
redline across the TUI, Mac, and iOS surfaces.

- **GradusMac** — a menu-bar app that reads the same `.state/snapshot.json`/`snapshot-v2.json` this CLI writes and publishes provider status to a private CloudKit database (`GradusZone`, one record per provider, last-writer-wins). It never touches `.cache/` or any credential path (INV-7) — its only input is the credential-free snapshot file, threaded through a single injected path dependency. Each publish also carries the Mac's user-visible computer name, short local username, and publish timestamp so iOS can show the connected computer and when it last reported; it never sends an email, serial number, path, or credential. The dropdown shows active providers as name + percentage + usage bar (metadata only where it needs attention) followed by a compact exhausted section — name and earliest reset, one line each. The menu's Settings… row opens a settings window holding the same device-local display preferences iOS has — sort mode, warning threshold, and Show exhausted — alongside the sync and launch-at-login toggles. That window is an `NSWindow` this app builds itself (`SettingsWindow`) rather than SwiftUI's `Settings` scene: on macOS 26.5.2 `showSettingsWindow:` returns `true` and opens nothing, so the idiomatic route fails silently. See `SettingsWindow.swift` for the measurements.
- Provider ordering is defined **once**, in `app/Shared/ProviderRanking.swift`, which is compiled into both app targets. `rankedPartition()` splits active from exhausted before applying any presentation comparator — so no sort mode can pull a depleted provider back among the actionable ones — then tiers each partition errored → attention-needed → normal and sorts by the chosen mode with a deterministic name tie-break. Each app conforms its own model (`ProviderEntry` on the Mac, `ProviderStatus` on iOS) to `RankableProvider`; the Mac recomputes depletion locally because, unlike the CloudKit model, the snapshot model has no stored `isDepleted`. This lives in `Shared/` rather than `GradusKit` deliberately: the rules are device-local presentation, so putting them in the kit would widen its INV-7-governed scope.
- **GradusiOS** — a fully-featured mobile dashboard (iOS 17+). Implements the "Zero Delta Design System": a hero-ranked "Now" screen, a Provider Detail drill-in showing all windows per provider, and a functional Settings screen with per-device warning-threshold override and notification toggle. No independent data source — renders whatever the Mac last published, kept current via a `CKRecordZoneSubscription` (silent push, delta sync with `CKFetchRecordZoneChangesOperation`) plus a silent `CKQuerySubscription`; the app compares cached warning state and emits one local notification when a provider enters a warning episode. Uses the shared `rankedPartition()` described above, rendering active providers as full density cards and exhausted ones as compact name + reset cells beneath them.
  - **Design system components** (Phase 2): `StatTile` (hero tile + compact ranked-list variant), `ListRow` (generic row with single trailing accessory), `MobileNavBar` (replaces ad-hoc toolbar), `IconButton` (44pt minimum tap target).
  - **Design tokens** (Phase 1): `Colors.swift` with `SignalColor.forPercent()` (4-tier urgency ramp: `#87D787`/`#FFD75F`/`#FFAF5F`/`#FF5F5F` at ≥70/≥40/≥20/<20) and provider-accent constants; `Icon.swift` bridges SF Symbols to semantic names (offline, syncing, warning, settings, etc.).
  - **Now screen** (Phase 3): hero provider (worst-case first, including errored providers) + ranked list of remaining providers, with active providers before a compact exhausted section and a populated `NavigationStack` root for compact iPhone navigation.
  - **Provider Detail** (Phase 4): all windows per provider rendered at full size, with age metadata.
  - **Settings** (Phase 5): Sync toggle (moved from toolbar), Notifications toggle (independent of sync, unsubscribes from CloudKit on toggle-off with success-gated UI update), local warning-threshold slider, provider sorting, Show exhausted, connected-computer details, provider count, and app version. Display preferences are device-local.
  - **Window ID labels** (Phase 4): verified against `gradus/snapshot.py`'s `V2_WINDOW_SPECS` (the schema-v2 window specs that actually flow to CloudKit/iOS), with explicit labels for the nine confirmed ids (`five_hour`/`weekly`/`monthly`/`premium`/`cg_five_hour`/`cg_weekly`/`ac`/`ap`/`billing_cycle`) plus legacy `cg5`/`cg1w` aliases, and raw-ID fallback for unknown ids.
- Both apps share `GradusKit`, a CloudKit-free Swift package holding the reconciliation logic and the fixed `windowWarns` threshold, so it can be unit-tested against mocks instead of live CloudKit. `windowWarns` is defined as `signalLevel(...).needsAttention`, and `providerNeedsAttention` aggregates it over every window — one predicate with one aggregation, which is what keeps the Mac's badge and the iPhone's warning count from disagreeing about the same snapshot. Only one of the two models stores the answer: the Mac evaluates it, and stamps it onto each CloudKit record as `isWarning` for iOS and the push subscription to read. The device-local warning threshold is kept out of GradusKit per INV-7 scope — it lives in `app/Shared/` with the ranking rules, where both apps can reach it without widening the kit.
- The expected-pace marker is defined once per concern: `expectedRemaining()` in GradusKit says *where* it goes, and `markerOffset(fraction:barWidth:markerWidth:)` beside it says how that maps to a leading-edge offset. Both apps call both. The offset moved into the kit after the two drifted — iOS clamped the marker inside its bar and the Mac did not, so a Mac window at 0% or 100% drew half a marker hanging off the end. Its colour is shared the same way, as `SignalColor.paceMarker` (`#005FD7`, matching the TUI's `bar.marker`) — deliberately outside the four-tier ramp, because the marker is a reference line rather than a signal level, and blue is the one hue no tier uses. Only the marker's *size* stays per-app, because the two bars are different heights. The TUI shares the colour but not the shape: it draws the marker as one whole cell of the bar's own fill glyph rather than a thin line. That is a constraint of the character grid, not a style choice — a thin stroke there has to change glyph to move within a cell, which changes its width, and can never ink as much of its cell as the fill does, so the terminal background shows through around it. The Swift bars position a real rectangle at a continuous offset and have neither problem.
- Sync is opt-in per device (off by default) and independent per device — pairing two devices doesn't couple them beyond both reading the same published snapshot.

Build/test (requires Xcode + `xcodegen`, pinned version in `app/.xcode-version`):

```bash
cd app
bash test-gate.sh   # boots the pinned simulator, runs GradusMac + GradusiOS unit/UI tests
```

### App icons

The two platforms need **different artwork for the same design**, and the Mac
icon is generated rather than hand-maintained:

```bash
swift app/make-mac-appicon.swift   # idempotent; rewrites only what changed
```

iOS masks a square 1024 image into the app shape at render time, so
`GradusiOS/…/icon-1024.png` is full-bleed and opaque to its corners. macOS does
no masking — the artwork must supply its own rounded shape and margin, or it
renders as a hard-cornered tile beside every other app. The generator draws the
same design (geometry mirrored from `design-system/…/gradus-app-icon.svg`) into
the centre 824 of a 1024 canvas behind a continuous-corner rounded rect.

Both the grid and the corner radius were measured against macOS 26.5.2's own
icons rather than taken from documentation: Calculator, Notes, Reminders and
Safari agree exactly on 824-in-1024, and a curve fit against Notes at 1024 puts
the radius at **214.5** (RMS 0.30px, max deviation 1px). The widely-quoted
185.4 is pre-Big Sur and scores RMS ~13px against the current shape. Re-fit
before assuming these hold on a future macOS.

Two macOS-specific traps, both silent:

- **The single-1024 entry that works for iOS compiles to nothing on macOS** —
  no `Assets.car`, no `CFBundleIconName`, and no build error. macOS needs the
  full `idiom: mac` ladder (16→512 at 1x/2x), which is why the two
  `Contents.json` files differ.
- **A target with no `ASSETCATALOG_COMPILER_APPICON_NAME` builds clean with no
  icon at all.** GradusMac shipped that way until 2026-08-05; `LSUIElement`
  hides it (a menu-bar agent has no Dock icon) but Finder, Login Items,
  notifications, and TCC permission prompts all showed the generic placeholder.

`GradusMacTests/AppIconTests.swift` locks all three properties against the built
bundle — plist keys, a decodable `AppIcon.icns`, and a transparent corner (the
assertion that fails if anyone copies the iOS square across).

Gradus follows [`TESTING.md`](TESTING.md): every new feature and user-facing
UI element needs automated regression coverage in the same change. Swift
Testing/XCTest cover logic and integration, snapshot tests cover important
visual states, and XCUITest covers interactive iOS workflows. The full gate
must discover and pass the new tests.

Project docs for the Swift side live at the repo root alongside the Python ones (`INVARIANTS.md`, `ledger.yaml`) — INV-7 covers the CloudKit publisher's credential isolation.

Cross-platform changes follow [`RELEASE_CHECKLIST.md`](RELEASE_CHECKLIST.md)
and INV-9: when GradusiOS depends on a new GradusMac-published field or
behavior, both sides are built and tested together, the matching Mac binary is
launched locally to verify the publish, and only then is the iOS build uploaded.
The Mac does not need notarization for that local republish; a Mac artifact
distributed to users still requires the notarization workflow.

### Deploying GradusiOS

Release versioning follows [`VERSIONING.md`](VERSIONING.md): use
`MAJOR.MINOR.PATCH` for product releases, and keep Apple's build number as a
separate upload counter. A new TestFlight build is reserved for a completed,
gate-green release candidate or a release-blocking correction; small
non-blocking tweaks are batched into the next patch release.

```bash
cd app
./test-gate.sh                                    # must be green first
# set the next semantic MARKETING_VERSION before the release gate when the
# product release changes; archive-upload-ios.sh owns the build counter
bws-secret-exec app-store-connect-upload --        # archives, codesigns, uploads; auto-bumps CURRENT_PROJECT_VERSION only
# Human-terminal compatibility path remains available:
# bws-run -- ./archive-upload-ios.sh
bws-secret-exec app-store-connect-testflight-setup -- <build>  # waits for processing and assigns the build to Internal Testers
```

Every semantic product release gets one concise entry in `CHANGELOG.md`. Copy
its release summary and test-focus text into App Store Connect's “What to
Test” field; keep individual candidate-build details and re-upload reasons in
`HISTORY.md`.

`archive-upload-ios.sh` prints the exact fixed-consumer follow-up command (with the build number it just uploaded) as its last line.

### Notarizing GradusMac

`notarize-mac.sh` archives, Developer-ID signs, verifies, uploads, waits for Apple, staples, and packages GradusMac. The upload stays visible, and the submission ID is recorded before polling in the gitignored `.state/notary-submissions.tsv` ledger.

```bash
cd app
./test-notary-scripts.sh   # hermetic; fake Apple/Xcode tools, never submits
./notary-status.sh         # one live check of every locally tracked submission
./notary-status.sh --watch # poll while pending; stop on acceptance or terminal failure
./notary-status.sh --monitor --interval 30  # leave a live dashboard running until Ctrl-C
./notarize-mac.sh          # creates and submits a new build; run only after review
```

The status command prints its Apple check time, status source, submission name, full ID, creation time, and current state. Exit `0` means all displayed submissions are `Accepted`; in one-shot mode, `2` means at least one is still `In Progress`; `3` means a terminal non-accepted result; `4` means no tracked or matching submission was returned. Usage, dependency, and `notarytool`/profile failures use `64`, `69`, and `70`. Watch mode polls while submissions remain pending, then exits when all are accepted or as soon as any terminal failure appears.

If polling is interrupted, resume the existing submission without uploading again:

```bash
./notary-status.sh --watch --id SUBMISSION_UUID
```

For a dashboard that should stay open while Apple processes the queue, use
`--monitor`. It refreshes Apple history every cycle, discovers newly submitted
`GradusMac.app.zip` jobs even when the local ledger is absent or changing, and
keeps running through empty, accepted, pending, terminal, and transient request
failures. `--interval SECONDS` controls the delay. Interactive Terminal output
redraws in place; redirected stdout emits complete ANSI-free snapshots. Press
Ctrl-C (or send TERM) to stop.

A sandboxed agent may not see the login-Keychain profile even when it exists. `notary-status.sh` reports that case explicitly; run it in Terminal or approve an outside-sandbox, read-only check rather than recreating `gradus-notary`.

## Development

```bash
# Run tests
uv run pytest

# Lint + format check
uv run ruff check gradus/ tests/
uv run ruff format --check gradus/ tests/
```

### Project layout

- `gradus/providers/` — provider package:
  - `__init__.py` — re-exports + provider registry
  - `_base.py` — shared utilities, credential mgmt, headless guard
  - `_codex_helpers.py` — Codex window helpers
  - `_seroval.py` — SolidStart seroval decoder
  - `antigravity.py`, `claude.py`, `codex.py`, `copilot.py`, `cursor.py`, `opencode_go.py`, `vibe.py`
- `gradus/parsing.py` — status dataclasses
- `gradus/snapshot.py` — snapshot normalization and persistence
- `gradus/ui.py` — terminal dashboard
- `gradus/__main__.py` — CLI entry, provider registry iteration
- `tests/test_providers.py` — provider unit tests
- `tests/test_snapshot.py` — normalization tests
- `tests/test_snapshot_property.py` — Hypothesis property tests
- `tests/test_ui.py` — UI tests
- `tests/test_main.py` — CLI and integration tests

### Git hooks (enforcement)

This project has **no CI** — the local git hooks *are* the gate. They run through
[`pre-commit`](https://pre-commit.com) using `repo: local` entries, so every hook
shells out to the same `uv run` tools declared in `pyproject.toml` (no second,
framework-managed copy that could drift out of version parity).

One-time bootstrap after cloning:

```bash
uv run pre-commit install   # installs both pre-commit and pre-push hooks
```

- **pre-commit** (fast): `ruff check` + `ruff format --check` on changed Python files.
- **pre-push** (heavier): the full `pytest` suite (~0.2s), so nothing lands on the
  remote without the gate tests passing.

Config lives in `.pre-commit-config.yaml`. Run the checks manually with
`uv run pre-commit run --all-files`.

Project docs:

- **README.md** — setup, usage, architecture overview
- **HISTORY.md** — change log for every session (features, bugs, regressions)
- **TASKS.md** — backlog and in-progress work
- **pyproject.toml** — dependencies (`ruff`, `pytest`, `pre-commit`) and tool config
- **.pre-commit-config.yaml** — local pre-commit/pre-push hook definitions
