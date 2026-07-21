# gradus

Real-time terminal monitor for local `codex`, `claude`, `agy`, `copilot`, `cursor`, and `vibe` usage.

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
- Refreshes every 120 seconds by default
- Shows Codex and Claude session-window usage, reset times, and pace indicators. Codex windows are slotted by the API's declared window span, not by position — so when OpenAI removed the Codex 5-hour limit (2026-07) the card automatically shows just the 1-week window, and the 5-hour row reappears on its own if OpenAI restores it (no code change)
- Shows Antigravity Gemini-group 5-hour and 1-week quota remaining, reset times, and pace indicators (matching `agy`'s Models & Quota panel), plus conditional Claude+GPT (`cg5`, `cg1w`) group activation when at least one valid C+G remaining percentage is below 100%. Rows render independently: each valid C+G row below 100% appears; exact-100%, missing, or malformed sibling rows are omitted.
- Shows Copilot monthly remaining (`mo`), reset, and billing-cycle pace
- Shows Cursor Auto + Composer and API remaining capacity, reset, and billing-cycle pace
- Shows Vibe monthly remaining (`mo`), reset, and billing-cycle pace
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
./monitor --once
```

When `--debug` is enabled, raw captures are written to `/tmp/gradus_*_capture.txt` (mode `0600`, via the same atomic private-write path as the credential caches). The raw payload is **not** written into the router-facing `.state/snapshot.json`: the snapshot's `error` field carries only the plain provider message (bounded and credential-free), while the debug-augmented detail is surfaced separately as `debug_detail` in `--json` output for local scripting.

Optional config file (`.gradus.json` in your current working directory; legacy `.ai_monitor.json` also read as a fallback):

```json
{
  "providers": ["Claude", "Codex", "Copilot", "Cursor", "Antigravity", "Vibe"],
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

At safe widths, dashboard cards are packed into two independently measured vertical
stacks with a one-cell horizontal gutter and no empty vertical-row gutter. The
two-column layout holds down to 79 columns — the width at which two bar-less cards
still fit a full `reset` and `pace` cell — so a narrowing terminal shrinks the usage
bars to nothing and stays compact instead of stacking early and re-widening the bars.
Below 79 columns the dashboard falls back to one column.

Codex and Claude cards show:

- `5h`: remaining usage for the current 5-hour window, reset time, pace indicator
- `1w`: remaining usage for the current 1-week window, weekly reset time, pace indicator

For Codex the `5h` row is shown only while OpenAI's API reports a sub-day window; after the 2026-07 removal of the 5-hour limit the Codex card shows just the `1w` row. The row is not rendered as `n/a` — it is omitted, and returns automatically if the window comes back.

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

Two events write the snapshot: the TUI on every refresh cycle, and `python3 -m gradus --write-snapshot` as a one-shot headless run.

**Read-only guarantee.** The `--write-snapshot` path never opens a browser, spawns a subprocess, refreshes a token, evicts a cookie cache, or sends notifications. Providers with missing or expired credentials surface as `ok: false`. It writes v1 first and v2 second; each file is independently atomic, so a partial failure is logged and exits 1 while the successful sibling remains current.

**Headless coverage.** Codex and any provider whose `.cache/` cookie file is still warm run headlessly — reading a cached cookie file is a benign read, allowed. Antigravity is always `ok: false` headless: its only credential is an OAuth token read via a `security` subprocess, which the read-only path forbids. A running TUI covers it.

**launchd refresher (manual install).** A ~120 s background job keeps the snapshot current without the TUI running.

- Wrapper: `~/.launchd/scripts/gradus_snapshot.sh`
- Plist: `~/Library/LaunchAgents/local.gradus-snapshot.plist` (StartInterval 120, RunAtLoad, Background)
- Logs: `~/Library/Logs/homelab/gradus-snapshot/`
- Install: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.gradus-snapshot.plist`
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

All 6 canonical providers are always present (Codex, Claude, Antigravity, Copilot, Cursor, Vibe); a not-enabled or filtered provider appears as `ok: false, error: "provider not enabled"`. `percent_left` is always remaining (0–100). `pace_delta` is a signed fraction — positive means healthy (remaining capacity ahead of expected consumption rate), unclamped.

In this v1 router snapshot, Cursor emits at most one `billing_cycle` window, sourced from its numeric `credit_percent_left` remaining percentage. Schema v2 preserves every non-Cursor window and instead publishes Cursor's independent numeric `ac` (Auto + Composer, from `autoPercentUsed`) and `ap` (API pool, from `apiPercentUsed`) windows, omitting either unavailable pool. Consumers may roll back by selecting the v1 path/version; retain v1 until all consumers have migrated.

`.state/snapshot.json` is consumed by hermes-publisher's GradusCollector as well as review-plugin; consumers reject unsupported schema_version; incompatible changes to top-level payload, provider-entry fields, or windows[] require schema bump and coordinated compatibility updates in both consumer projects. Antigravity's Claude+GPT fields and windows are deliberately excluded from router snapshot v1/v2 schemas, so the Gemini snapshot contract remains unchanged. `--json` remains schema-agnostic local/debug output and does not select or persist either router schema.

## Notes

- Antigravity probing reads `agy`'s Keychain token and POSTs an empty body to `retrieveUserQuotaSummary` (the endpoint rejects a non-empty body with HTTP 400 and the default `Python-urllib` User-Agent with HTTP 403; the provider sets an explicit User-Agent). On an expired token it first nudges `agy` to refresh its own token via `agy models`, then re-reads the Keychain; only if that fails does it surface the "run `agy`" re-authenticate message. The monitor never handles `agy`'s client secret or refresh token — `agy` refreshes its own token via its own OAuth client — so the read-only-toward-`agy`'s-stored-credentials guarantee holds.
- Claude probing reads `~/.claude/` OAuth credentials directly; run `claude login` to refresh if probes fail.
- During each timed refresh, the header switches from `refresh XXs` to a single in-place `updating …` state until all providers complete, then resumes the countdown.
- Live rendering uses the `rich` library's `Live` display with alt-screen mode, eliminating scrollback buffer growth.
- In live mode, press `q` to quit or `r` to trigger an immediate refresh.
- Cursor and Vibe try Safari cookie extraction first; Vibe also supports Chrome cookie extraction. Cookies are cached locally at `.cache/<provider>_cookies.json` (gitignored) to survive Safari disk-sync lag and reduce spurious re-auth prompts; the cache is evicted on API 400/401/403 errors (Claude also returns 400 when a cached `lastActiveOrg` fails its UUID validator).
- **Credential storage.** The `.cache/` credential files (provider cookies/tokens) and the Codex `~/.codex/auth.json` are written mode `0600` inside a `0700` directory via a single atomic private-write helper — a `tempfile.mkstemp` temp file (born `0600`, independent of umask) swapped in with `os.replace`, so the file is never world-readable, even momentarily. Pre-existing caches are also tightened to `0600` opportunistically on the next interactive (non-headless) read. Note that `0600` protects against *other local users*; it does **not** stop iCloud replication. The caches live under `~/Documents/Projects/gradus/.cache/`; if you ever enable **Desktop & Documents** iCloud sync, exclude this project (or its `.cache/`) from sync — e.g. a `.nosync`-suffixed directory is not synced — so live credentials are not copied to Apple's cloud. (Desktop & Documents sync is off by default.)
- A normalized window warns when it is exactly depleted or its finite pace delta is below `-0.10`; `[!]` badges and one-shot macOS notifications use the same provider-level warning membership. Notifications name the warning window IDs. Antigravity's conditional C+G rows (`cg5`, `cg1w`) participate in this membership. Cursor's `ac` and `ap` pools are evaluated independently in-process and in schema v2, while v1 continues to publish only its `billing_cycle` window.
- Vibe uses Mistral's `usage_percentage` field as percent used directly. If Mistral shows `1.08% used`, Gradus will render about `99%` remaining after rounding.
- Cursor reads billing-cycle and usage data from the nested `planUsage` payload. `planUsage` carries three numbers but Cursor only has two real usage pools: `autoPercentUsed` (first-party Auto + Composer) and `apiPercentUsed` (API/third-party pool) are both percent-USED for their own pool; `remaining`/`limit` cents are a dollar-denominated spend meter, not a third pool. The card shows Cursor's two real usage pools: `ac` is the Auto + Composer pool, converted from `autoPercentUsed` (percent used) to remaining capacity; `ap` is the API pool, converted from `apiPercentUsed` (percent used) to remaining capacity the same way. The cents-derived dollar meter (`credit_percent_left`) is computed by the provider and retained as internal metadata, but is no longer displayed, alert-evaluated, or persisted/projected — it doesn't belong under "ap" or any capacity window. Neither `--json` nor the v1/v2 router snapshots emit `credit_percent_left` any longer; the v1 `billing_cycle` window remains sourced from it internally (unchanged), but it no longer appears in the projected `data` block.

## Limitations

- This depends on current local CLI/API behavior across `codex`, `claude`, `agy`, `copilot`, `cursor`, and `vibe`.
- If any vendor changes its TUI wording or layout, the parser may need to be updated.
- Reset windows are only shown when the CLI output exposes them.
- Terminal rendering can vary across fonts and terminal emulators.

## Known Issues

- **Claude `/usage` may return "only available for subscription plans"** even on valid Team or Pro seats. This is a server-side issue where the Anthropic usage API returns empty limit buckets (`five_hour`, `seven_day`, `seven_day_sonnet` are all null). The PTY probe itself works correctly. When the API starts returning data again, the Claude card will populate automatically.
- The Antigravity token is minted under `agy`'s own OAuth client, so this path is coupled to `agy`'s internal API. If a future `agy` release changes the Keychain layout or the `retrieveUserQuotaSummary` contract, the card will show an error until the provider is updated.

## Development

```bash
# Run tests
uv run pytest

# Lint + format check
uv run ruff check gradus/ tests/
uv run ruff format --check gradus/ tests/
```

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
