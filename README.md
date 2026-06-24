# ai_monitor

Real-time terminal monitor for local `codex`, `claude`, `gemini`, `copilot`, `cursor`, and `vibe` usage.

Probes provider APIs directly using locally authenticated credentials — no PTY, no CLI scraping. Each provider uses its own HTTP or internal API path, so probes are fast and reliable.

![Warmup screen](docs/screenshots/warmup.png)

![Live dashboard](docs/screenshots/dashboard.png)

## Features

- Monitors Codex usage via the OpenAI usage API
- Monitors Claude usage via the Anthropic account API
- Monitors Gemini usage via the Cloud Code internal quota API (OAuth); the same card also covers Google Antigravity (`agy`), which shares the Gemini request-quota pool. (Antigravity's premium-model credits — Opus, gpt-oss — are metered separately over a Codeium gRPC path with no probeable REST endpoint; see HISTORY.md 2026-05-23.)
- Monitors Copilot premium-request usage via the GitHub Copilot internal API
- Monitors Cursor credit usage via the Cursor Dashboard API
- Monitors Vibe usage via the Mistral billing API
- Refreshes every 120 seconds by default
- Shows Codex and Claude 5-hour and 1-week session usage, reset times, and pace indicators
- Shows Gemini Flash and Pro pool remaining percentages with reset countdowns
- Shows Copilot monthly premium remaining (`month rem`) with a color progress bar, monthly reset (`month reset`), and monthly pace (`month pace`) in the same card style
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
- Gemini: `~/.gemini/oauth_creds.json` present (created by `gemini` sign-in)
- Copilot: `gh` CLI on `PATH` and authenticated (`gh auth login`)
- Cursor: app or browser session authenticated
- Mistral console session authenticated (Safari/Chrome cookie extraction supported)
- `rich>=15.0` (installed automatically via `pip install` or `uv sync`)
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
python3 -m ai_monitor --providers Claude,Codex,Gemini
./monitor --once
```

When `--debug` is enabled, raw captures are written to `/tmp/ai_monitor_*_capture.txt`.

Optional config file (`.ai_monitor.json` in your current working directory):

```json
{
  "providers": ["Claude", "Codex", "Copilot", "Cursor", "Gemini", "Vibe"],
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

Gemini card shows:

- `fl`: Flash pool remaining, reset countdown
- `pr`: Pro pool remaining, reset countdown

Copilot / Cursor / Vibe cards show:

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

## Notes

- Gemini probing calls `loadCodeAssist` before `retrieveUserQuota` to register the session; auth failures surface as a clear re-authenticate message.
- Copilot probing calls the `gh auth token` helper to retrieve a live GitHub token without storing it locally.
- Claude probing reads `~/.claude/` OAuth credentials directly; run `claude login` to refresh if probes fail.
- During each timed refresh, the header switches from `refresh XXs` to a single in-place `updating …` state until all providers complete, then resumes the countdown.
- Live rendering uses the `rich` library's `Live` display with alt-screen mode, eliminating scrollback buffer growth.
- In live mode, press `q` to quit or `r` to trigger an immediate refresh.
- Cursor and Vibe try Safari cookie extraction first; Vibe also supports Chrome cookie extraction. Cookies are cached locally at `.cache/<provider>_cookies.json` (gitignored) to survive Safari disk-sync lag and reduce spurious re-auth prompts; the cache is evicted on API 400/401/403 errors (Claude also returns 400 when a cached `lastActiveOrg` fails its UUID validator).
- Providers below threshold show a `[!]` badge and trigger one-shot macOS notifications until they recover above threshold.
- Vibe uses Mistral's `usage_percentage` field as percent used directly. If Mistral shows `1.08% used`, AI Monitor will render about `99%` remaining after rounding.
- Cursor reads billing-cycle and usage data from the nested `planUsage` payload and treats `limit` / `remaining` as cents, so `2000` means `$20.00` and `1631` means `$16.31` remaining. The Cursor card intentionally shows that included API-spend bucket as `ap`, and the main `% remaining` uses that cents ratio when present and only falls back to `totalPercentUsed` if Cursor omits the spend fields.

## Limitations

- This depends on current local CLI/API behavior across `codex`, `claude`, `gemini`, `copilot`, `cursor`, and `vibe`.
- If any vendor changes its TUI wording or layout, the parser may need to be updated.
- Reset windows are only shown when the CLI output exposes them.
- Terminal rendering can vary across fonts and terminal emulators.
- Copilot currently relies on the status-line remaining percentage signal; if Copilot CLI omits it, `month rem` and `month pace` can still show `n/a`.

## Known Issues

- **Claude `/usage` may return "only available for subscription plans"** even on valid Team or Pro seats. This is a server-side issue where the Anthropic usage API returns empty limit buckets (`five_hour`, `seven_day`, `seven_day_sonnet` are all null). The PTY probe itself works correctly. When the API starts returning data again, the Claude card will populate automatically.
- Gemini prefers a direct internal quota probe and only falls back to PTY `/stats` scraping if that path is unavailable.
- If Gemini falls back to PTY probing and shows a **waiting for authentication** screen, `ai_monitor` now reports that directly. Run `gemini` once and complete sign-in, then rerun the monitor.

## Development

```bash
# Run tests
pytest

# Lint
ruff check ai_monitor/ tests/
```

Project docs:

- **README.md** — setup, usage, architecture overview
- **HISTORY.md** — change log for every session (features, bugs, regressions)
- **TASKS.md** — backlog and in-progress work
- **pyproject.toml** — dependencies (`ruff`, `pytest`) and tool config
