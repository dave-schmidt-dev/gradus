# ai_monitor

Real-time terminal monitor for local `codex`, `claude`, `agy`, `cursor`, and `vibe` usage.

Probes provider APIs directly using locally authenticated credentials — no PTY, no CLI scraping. Each provider uses its own HTTP or internal API path, so probes are fast and reliable.

![Warmup screen](docs/screenshots/warmup.png)

![Live dashboard](docs/screenshots/dashboard.png)

## Features

- Monitors Codex usage via the OpenAI usage API
- Monitors Claude usage via the Anthropic account API
- Monitors Antigravity (`agy`) usage via the Cloud Code `retrieveUserQuotaSummary` API — the same grouped quota `agy`'s own Models & Quota panel shows. Authenticates read-only with `agy`'s OAuth token from the macOS Keychain (service `gemini`, account `antigravity`); the monitor never refreshes or rewrites that token, so it can't disturb `agy`'s own auth.
- Monitors Cursor credit usage via the Cursor Dashboard API
- Monitors Vibe usage via the Mistral billing API
- Refreshes every 120 seconds by default
- Shows Codex and Claude 5-hour and 1-week session usage, reset times, and pace indicators
- Shows Antigravity Gemini-group 5-hour and 1-week quota remaining, reset times, and pace indicators (matching `agy`'s Models & Quota panel)
- Shows Cursor included API-spend remaining, reset, and billing-cycle pace
- Shows Vibe monthly remaining (`month rem`), reset, and billing-cycle pace
- Shows compact single-line error cards to reduce vertical noise when a provider is unavailable
- Retains cached usage data during transient network errors with an `(offline Xm)` title indicator; shows a `stale` panel after 5 minutes of continuous failure
- Supports live keyboard shortcuts (`q` quit, `r` refresh now)
- Supports `.ai_monitor.json` for provider selection, interval, and threshold configuration
- Sends one-shot macOS threshold notifications and marks low providers with a `[!]` badge
- Uses a shared provider card renderer so reset labels and pacing rows stay aligned across providers
- Canonicalizes reset displays to one local format across provider-specific strings
- Renders a compact grid dashboard optimized for terminal use
- Exposes `--json` output for scripting and automation, including normalized reset display fields

## Requirements

- Python 3.10+
- Codex: `~/.codex/auth.json` present (created by `codex login`). If the Codex card shows a persistent "session expired" error and the `[1]` re-auth shortcut doesn't unstick it, the server-side session has been revoked (the `codex login` refresh path re-mints a token bound to the same revoked session). Run `codex logout && codex login` for a clean OAuth flow.
- Claude: `~/.claude/` credentials present (created by `claude login`)
- Antigravity (`agy`): signed in via `agy` (stores its OAuth token in the macOS Keychain). The monitor reads it read-only; the first read may prompt for Keychain access — choose "Always Allow" so background refreshes stay silent. The token expires ~hourly and only `agy` refreshes it, so when the token lapses the monitor **nudges `agy` to refresh its own token** by running `agy models` (a non-interactive, quota-free authenticated command) and re-reads the Keychain — the card self-heals without manual action. If that nudge can't recover (e.g. `agy` isn't installed on `PATH`, or `agy`'s own refresh token is dead), the card falls back to an auth error; run `agy` to re-authenticate. The nudge runs only in the interactive TUI, never on the read-only `--write-snapshot`/headless path (INV-2).
- Cursor: app or browser session authenticated
- Mistral console session authenticated (Safari/Chrome cookie extraction supported)
- `rich>=15.0` (installed automatically via `pip install` or `uv sync`)
- `cryptography>=42` (installed automatically; used to decrypt Chrome `v10` cookies in-process so the AES key is never placed on a subprocess command line)
- A terminal that supports ANSI color

## Run

```bash
python3 -m ai_monitor
./monitor
```

Useful options:

```bash
python3 -m ai_monitor --once
python3 -m ai_monitor --interval 30
python3 -m ai_monitor --interval 60
python3 -m ai_monitor --json
python3 -m ai_monitor --debug
python3 -m ai_monitor --providers Claude,Codex,Antigravity
python3 -m ai_monitor --write-snapshot
./monitor --once
```

When `--debug` is enabled, raw captures are written to `/tmp/ai_monitor_*_capture.txt` (mode `0600`, via the same atomic private-write path as the credential caches). The raw payload is **not** written into the router-facing `.state/snapshot.json`: the snapshot's `error` field carries only the plain provider message (bounded and credential-free), while the debug-augmented detail is surfaced separately as `debug_detail` in `--json` output for local scripting.

Optional config file (`.ai_monitor.json` in your current working directory):

```json
{
  "providers": ["Claude", "Codex", "Cursor", "Antigravity", "Vibe"],
  "interval": 120,
  "threshold": 20
}
```

## How It Works

1. On startup, initialize one HTTP provider per enabled service.
2. Probe each provider's API endpoint using local credentials (OAuth tokens, cookie jars, etc.).
3. Parse the structured JSON response to extract usage percentages and reset timestamps.
4. Re-render the dashboard on the chosen refresh interval and watch for threshold crossings.

## Output

All provider cards use a unified 5-column row layout: `label | % | bar | reset | pace`.
When a provider's usable capacity hits 0%, all rows switch to a depleted view showing
`0%  until <reset_time>` with no bar or pace.

Codex and Claude cards show:

- `5h`: remaining usage for the current 5-hour window, reset time, pace indicator
- `1w`: remaining usage for the current 1-week window, weekly reset time, pace indicator

Antigravity card shows (Gemini model group — the pool `agy` consumes):

- `5h`: remaining quota for the current 5-hour window, reset time, pace indicator
- `1w`: remaining quota for the current 1-week window, weekly reset time, pace indicator

Cursor / Vibe cards show:

- `mo`: monthly remaining percentage, billing-cycle reset, pace indicator
- `ap`: Cursor included API-spend remaining percentage, billing-cycle reset, pace indicator

Reset displays are normalized before rendering:

- Same-day resets render as `HH:MM` (24h)
- Future resets render as `Mon DD HH:MM`
- Relative vendor text like `Resets in 2h 14m` is converted to the same absolute local display

## JSON Output

`--json` preserves the raw provider payload under `data` and adds normalized reset display fields under `display`.

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

A sibling process or router can read `.state/snapshot.json` instantly — no probing, no browser, no credential I/O. The file is credential-free and gitignored (deliberately not `.cache/`, which holds auth cookies/tokens that a consuming router must never read).

Two events write the snapshot: the TUI on every refresh cycle, and `python3 -m ai_monitor --write-snapshot` as a one-shot headless run.

**Read-only guarantee.** The `--write-snapshot` path never opens a browser, spawns a subprocess, refreshes a token, evicts a cookie cache, or sends notifications. Providers with missing or expired credentials surface as `ok: false`; the file is still written and the process exits 0. Exit 1 means the file write itself failed.

**Headless coverage.** Codex and any provider whose `.cache/` cookie file is still warm run headlessly — reading a cached cookie file is a benign read, allowed. Antigravity is always `ok: false` headless: its only credential is an OAuth token read via a `security` subprocess, which the read-only path forbids. A running TUI covers it.

**launchd refresher (manual install).** A ~120 s background job keeps the snapshot current without the TUI running.

- Wrapper: `~/.launchd/scripts/ai_monitor_snapshot.sh`
- Plist: `~/Library/LaunchAgents/local.ai-monitor-snapshot.plist` (StartInterval 120, RunAtLoad, Background)
- Logs: `~/Library/Logs/homelab/ai-monitor-snapshot/`
- Install: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.ai-monitor-snapshot.plist`
- Uninstall: `launchctl bootout gui/$(id -u)/local.ai-monitor-snapshot`

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

All 5 canonical providers are always present (Codex, Claude, Antigravity, Cursor, Vibe); a not-enabled or filtered provider appears as `ok: false, error: "provider not enabled"`. `percent_left` is always remaining (0–100). `pace_delta` is a signed fraction — positive means healthy (remaining capacity ahead of expected consumption rate), unclamped.

## Notes

- Antigravity probing reads `agy`'s Keychain token and POSTs an empty body to `retrieveUserQuotaSummary` (the endpoint rejects a non-empty body with HTTP 400 and the default `Python-urllib` User-Agent with HTTP 403; the provider sets an explicit User-Agent). On an expired token it first nudges `agy` to refresh its own token via `agy models`, then re-reads the Keychain; only if that fails does it surface the "run `agy`" re-authenticate message. The monitor never handles `agy`'s client secret or refresh token — `agy` refreshes its own token via its own OAuth client — so the read-only-toward-`agy`'s-stored-credentials guarantee holds.
- Claude probing reads `~/.claude/` OAuth credentials directly; run `claude login` to refresh if probes fail.
- During each timed refresh, the header switches from `refresh XXs` to a single in-place `updating …` state until all providers complete, then resumes the countdown.
- Live rendering uses the `rich` library's `Live` display with alt-screen mode, eliminating scrollback buffer growth.
- In live mode, press `q` to quit or `r` to trigger an immediate refresh.
- Cursor and Vibe try Safari cookie extraction first; Vibe also supports Chrome cookie extraction. Cookies are cached locally at `.cache/<provider>_cookies.json` (gitignored) to survive Safari disk-sync lag and reduce spurious re-auth prompts; the cache is evicted on API 400/401/403 errors (Claude also returns 400 when a cached `lastActiveOrg` fails its UUID validator).
- **Credential storage.** The `.cache/` credential files (provider cookies/tokens) and the Codex `~/.codex/auth.json` are written mode `0600` inside a `0700` directory via a single atomic private-write helper — a `tempfile.mkstemp` temp file (born `0600`, independent of umask) swapped in with `os.replace`, so the file is never world-readable, even momentarily. Pre-existing caches are also tightened to `0600` opportunistically on the next interactive (non-headless) read. Note that `0600` protects against *other local users*; it does **not** stop iCloud replication. The caches live under `~/Documents/Projects/ai_monitor/.cache/`; if you ever enable **Desktop & Documents** iCloud sync, exclude this project (or its `.cache/`) from sync — e.g. a `.nosync`-suffixed directory is not synced — so live credentials are not copied to Apple's cloud. (Desktop & Documents sync is off by default.)
- Providers below threshold show a `[!]` badge and trigger one-shot macOS notifications until they recover above threshold.
- Vibe uses Mistral's `usage_percentage` field as percent used directly. If Mistral shows `1.08% used`, AI Monitor will render about `99%` remaining after rounding.
- Cursor reads billing-cycle and usage data from the nested `planUsage` payload and treats `limit` / `remaining` as cents, so `2000` means `$20.00` and `1631` means `$16.31` remaining. The Cursor card intentionally shows that included API-spend bucket as `ap`, and the main `% remaining` uses that cents ratio when present and only falls back to `totalPercentUsed` if Cursor omits the spend fields.

## Limitations

- This depends on current local CLI/API behavior across `codex`, `claude`, `agy`, `cursor`, and `vibe`.
- If any vendor changes its TUI wording or layout, the parser may need to be updated.
- Reset windows are only shown when the CLI output exposes them.
- Terminal rendering can vary across fonts and terminal emulators.

## Known Issues

- **Claude `/usage` may return "only available for subscription plans"** even on valid Team or Pro seats. This is a server-side issue where the Anthropic usage API returns empty limit buckets (`five_hour`, `seven_day`, `seven_day_sonnet` are all null). The PTY probe itself works correctly. When the API starts returning data again, the Claude card will populate automatically.
- The Antigravity card tracks only the Gemini model group (the pool `agy` actually consumes). The Claude+GPT group `agy` also reports is intentionally not shown — it sits idle at 100% for this account and would just add noise.
- The Antigravity token is minted under `agy`'s own OAuth client, so this path is coupled to `agy`'s internal API. If a future `agy` release changes the Keychain layout or the `retrieveUserQuotaSummary` contract, the card will show an error until the provider is updated.

## Development

```bash
# Run tests
uv run pytest

# Lint + format check
uv run ruff check ai_monitor/ tests/
uv run ruff format --check ai_monitor/ tests/
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
