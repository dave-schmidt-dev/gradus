# gradus

The 2026-08-10 reliability/accessibility/parity reconciliation is recorded in
the dated Gradus plan under the local `.plans/gradus/` workspace; its live
queue mapping and explicit future exclusions remain in `TASKS.md`.

The latest confirmed internal TestFlight build remains **1.8.0 (20)**.
Candidate **1.9.0-24** reached readiness only: its local preparation attempts
failed before archive creation, signing, artifact verification, or upload, so
Apple never received it. Future candidates use the source-bound local release
gate before archive and signing. App Store submission remains
separately gated; the publication roadmap is in `RELEASE_CHECKLIST.md`, and the
live queue is in `TASKS.md`.

The release owner must review a dated, candidate-current walkthrough before the
TestFlight trigger. `python3 -m release_candidate.walkthrough` binds that
review to the exact source revision, project/artifact digests, version/build,
and route manifest, including onboarding, reachable controls, role/permission
variants, disabled/recovery states, and system-owned sheets. This handoff is
TestFlight-only; App Store submission remains a separate human-gated step.

Gradus has three surfaces over the same usage data: a terminal monitor, a
macOS menu-bar publisher, and an iPhone/iPad consumer. The iOS/iPadOS app
includes a clearly labelled, local-only `Explore Sample` flow so a clean
install is useful without a Mac or pre-existing CloudKit data. Entry is
available from the empty state; the sample dashboard and its sample Settings
variant expose reset and exit controls. Sample entry waits for
live lifecycle work to quiesce, suppresses remote pushes and notifications,
and resumes live mode explicitly after exit.

The terminal surface monitors local `codex`, `claude`, `agy`, `copilot`, `cursor`,
`vibe`, and `opencode go` usage.

Probes provider APIs directly using locally authenticated credentials — no PTY, no CLI scraping. Each provider uses its own HTTP or internal API path, so probes are fast and reliable.

![Warmup screen](docs/screenshots/warmup.png)

![Live dashboard](docs/screenshots/dashboard.png)

## Features

- Monitors Codex usage via the OpenAI usage API
- Monitors Claude usage through Claude Code's OAuth token and Anthropic's structured `https://api.anthropic.com/api/oauth/usage` endpoint — no PTY, terminal scraping, Safari cookies, or status-line cache
- Monitors Antigravity (`agy`) usage via the Cloud Code `retrieveUserQuotaSummary` API — the same grouped quota `agy`'s own Models & Quota panel shows. Authenticates read-only with `agy`'s OAuth token from the macOS Keychain (service `gemini`, account `antigravity`); the monitor never refreshes or rewrites that token, so it can't disturb `agy`'s own auth.
- Monitors Copilot usage via the GitHub REST API (using `gh` CLI credentials)
- Monitors Cursor usage via its dashboard API, authenticating read-only with the Cursor CLI's OAuth token from the macOS Keychain (service `cursor-access-token`, account `cursor-user`); the monitor never refreshes or rewrites that token, so it can't disturb the CLI's own session
- Monitors Vibe usage via the Mistral billing API
- Monitors OpenCode Go usage via its API-key endpoint (5h/1w/monthly quota), without Safari
- Refreshes every 120 seconds by default
- Shows Codex and Claude session-window usage, reset times, and pace indicators. Codex windows are slotted by the API's declared window span, not by position. The Codex 5-hour limit row is hidden entirely when the upstream API omits it (as OpenAI has done since 2026-07) and reappears automatically once the API reports it again.
- Shows Codex (Spark) as a separate quota bucket on the same OpenAI account, with independently duration-classified 5-hour (`sp5h`) and weekly (`sp1w`) rows, reset times, and pace indicators
- Shows Antigravity Gemini-group 5-hour and 1-week quota remaining, reset times, and pace indicators (matching `agy`'s Models & Quota panel), plus Claude+GPT (`cg5`, `cg1w`) rows whenever the canonical v2 snapshot contains valid tracked values. Rows render independently, including at exactly 100%; missing or malformed sibling rows are omitted. The TUI hydrates these rows from the internal `Antigravity (Claude)` synthetic entry at read time.
- Shows Copilot monthly remaining (`mo`), reset, and billing-cycle pace
- Shows Cursor Auto + Composer (`ac`) and API (`ap`) remaining capacity, billing-cycle reset, and pace
- Shows Vibe monthly remaining (`mo`), reset, and billing-cycle pace
- Shows OpenCode Go 5h/1w/monthly remaining quota, reset times, and pace indicators
- Shows compact single-line error cards to reduce vertical noise when a provider is unavailable
- Retains cached usage data during transient network errors with an `(offline Xm)` title indicator; shows a `stale` panel after 5 minutes of continuous failure
- Supports live keyboard shortcuts (`q` quit, `r` refresh now, `s` cycle provider sorting)
- Supports `.gradus.json` (legacy `.ai_monitor.json` also read as a fallback) for provider selection and interval configuration
- Sends one-shot macOS pace/depletion notifications and marks warning providers with a `[!]` badge
- Renders depleted providers as centered 1-line micro-cards paired side-by-side (ratio Cursor:Copilot:Vibe = 2:1:1) at the bottom of the dashboard to conserve vertical space
- Uses a shared provider card renderer so reset labels and pacing rows stay aligned across providers
- Canonicalizes reset displays to one local format across provider-specific strings
- Renders a compact grid dashboard optimized for terminal use
- Exposes `--json` output for scripting and automation, including normalized reset display fields

## Requirements

- Python 3.10+
- Codex: `~/.codex/auth.json` present (created by `codex login`). If the Codex card shows a persistent "session expired" error and the `[1]` re-auth shortcut doesn't unstick it, the server-side session has been revoked (the `codex login` refresh path re-mints a token bound to the same revoked session). Run `codex logout && codex login` for a clean OAuth flow. Codex (Spark) reads from the same authenticated Codex usage response — no separate login or credential is needed.
- Claude: Claude Code authenticated with `claude auth login`; Gradus reads the OAuth access token read-only from the macOS Keychain (service `Claude Code-credentials`) and sends it only to Anthropic's usage endpoint. If Claude Code reports its OAuth session expired, re-authenticate with `claude auth login`; Gradus retries its read-only check on the normal ten-minute cadence.
- Antigravity (`agy`): signed in via `agy` (stores its OAuth token in the macOS Keychain). The monitor reads it read-only; the first read may prompt for Keychain access — choose "Always Allow" so background refreshes stay silent. The token expires ~hourly and only `agy` refreshes it, so when the token lapses the monitor **nudges `agy` to refresh its own token** by running `agy models` (a non-interactive, quota-free authenticated command) and re-reads the Keychain — the card self-heals without manual action. If that nudge can't recover (e.g. `agy` isn't installed on `PATH`, or `agy`'s own refresh token is dead), the card falls back to an auth error; run `agy` to re-authenticate. The nudge is available only to the credential-aware producer, never to reader commands (INV-2).
- Copilot: `gh` CLI authenticated (`gh auth login` or OAuth token present)
- Cursor: signed in via the Cursor CLI (`cursor-agent login`), which stores its session in fixed macOS Keychain items; the monitor reads them read-only. The token is long-lived and only the CLI refreshes it, so when it lapses the card reports an actionable re-login instead of going stale
- Mistral console session authenticated (the macOS credential bridge reads Safari cookies)
- OpenCode Go: API key stored in the fixed macOS Keychain item; authenticate with `opencode /connect`
  The item uses service `OpenCode Go` and account `default`; Gradus reads it transiently and never persists or logs the key. The API exposes rolling, weekly, and monthly windows; Zen credit balance remains unavailable to key-authenticated clients.
- `rich>=15.0` (installed automatically via `pip install` or `uv sync`)
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
python3 -m gradus --refresh-snapshot
python3 -m gradus --verify-refresh-health --duration 360
python3 -m gradus --tls-trust-report
python3 -m gradus --history-at 2026-08-04T12:00:00Z
python3 -m gradus --history-at 2026-08-04T12:00:00Z --history-provider Antigravity --history-max-gap 900
./monitor --once
```

`--tls-trust-report` prints a credential-free JSON description of the trust store
provider probes verify against and never contacts a provider. Every provider HTTPS
call goes through `gradus.tls.default_ssl_context()`, which is the interpreter's
default verifying context plus the pinned `certifi` bundle packaged with Gradus. That
matters for the frozen `GradusRuntime.app`: its python.org OpenSSL is compiled with an
`OPENSSLDIR` that exists only where python.org's installer ran, so without the bundle
the interpreter's own store is empty and every probe fails with
`CERTIFICATE_VERIFY_FAILED` (2026-09-06). The report's `interpreter_ca_certificates`
shows that unaided count; `ca_certificates` is what probes actually use.

When `--debug` is enabled on the credential-aware `--refresh-snapshot` producer, raw captures are written to `/tmp/gradus_*_capture.txt` (mode `0600`, via the same atomic private-write path as the credential caches). Reader commands (`--json`, `--once`, and the TUI) do not probe providers or write debug captures.

The raw payload is **not** written into the router-facing `.state/snapshot-v2.json`: the snapshot's `error` field carries only the plain provider message (bounded and credential-free). The debug-augmented `debug_detail` goes to **stderr** under `--debug`, never into the JSON document — `--json` on stdout is a machine contract consumed by the review-plugin router, and INV-1 keeps raw HTTP bodies and credential material off it (enforced by `test_render_json_data_is_safe_allowlist`). So `gradus --json --debug > out.json` leaves `out.json` parseable while the detail lands on your terminal.

The stderr channel is wired on the non-interactive reader paths (`--json` and `--once`) and the producer path (`--refresh-snapshot`). The live TUI reports through `.logs/gradus.log` while Rich owns the alt screen.

Error strings published to the devices are classified by exception **type**, not message content (`providers/_base._safe_probe_error`): a `TimeoutError` becomes `"provider probe timed out"` and a `ConnectionError` becomes `"provider probe network error"`, both of which the transient classifier recognizes so the last-known-good reading is served instead of a failure card. Exception text itself is never published, because a provider exception can embed subprocess output or a signed URL.

### Logs

Runtime logs go to `.logs/gradus.log` (gitignored, rotating at 1 MB with two backups), anchored to the package directory rather than the working directory — `local.gradus-snapshot` runs from launchd with a cwd gradus does not control. WARNING and above are always recorded; `--debug` adds DEBUG. Set `GRADUS_LOG_PATH` to redirect; the test suite sets it (see `tests/conftest.py`) so pytest's own warnings cannot rotate real production evidence out of the log.

**GradusMac logs elsewhere, on purpose.** The Mac app writes to the unified log under subsystem `com.zerodelta.gradus` and mirrors WARNING and above to `~/Library/Logs/Gradus/GradusMac.log` (rotating at 512 KB, two backups); `defaults write com.zerodelta.gradus GradusDebugLogging -bool YES`, or the `GRADUS_DEBUG_LOGGING` environment variable, lowers that floor to DEBUG. It does **not** use the repo's `.logs/`, which is the convention everywhere else in this project. The app ships from `/Applications` while the repo sits under `~/Documents`, so a repo-relative log would make a released build request a Documents TCC grant on first launch — the same consent prompt that has stalled the Mac test gate — in order to write into one developer's working copy. `~/Library/Logs/` is the platform's answer for a non-sandboxed app and needs no grant. Decided 2026-08-06; please don't "restore" the convention here.

`GRADUS_MAC_LOG_DIR` redirects it — a **directory**, deliberately not the Python side's `GRADUS_LOG_PATH`, which names a **file**; honoring one variable for both shapes would send the Mac app's rotation set into a path its owner meant as a single file. The Mac suite redirects itself without needing the variable: the test bundle is hosted inside a real GradusMac process, so `GradusLogFile.shared` in a test *is* the shipping app's sink, the same trap `PublisherViewModel` injects `UserDefaults` to avoid. The first run after the file sink landed appended ten fabricated `save failed for B: CKError 26` lines to the real log — the file `RELEASE_CHECKLIST.md` step 3 tells a reviewer to read as proof a release published cleanly. Detection is at runtime rather than in the scheme because XcodeGen regenerates the schemes.

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
Below 79 columns the dashboard automatically switches to a compact single/double-line layout: each active provider gets 1–2 lines (max 2 windows per line, continuation lines indented), blank lines separate providers, and exhausted (0%) providers are dropped entirely. Window labels (`5h:`, `1w:`, etc.) show percentage and pace arrows (`↑`/`↓`/`=`). Vibe gets special compact handling converting percent-used to percent-remaining with billing-cycle pace. No `--compact` flag is needed — the switch is fully automatic and responsive to terminal width.

Codex and Claude cards show:

- `5h`: remaining usage for the current 5-hour window, reset time, pace indicator
- `1w`: remaining usage for the current 1-week window, weekly reset time, pace indicator
- `sp5h`: remaining usage for Codex (Spark)'s separate 5-hour window, reset time, pace indicator
- `sp1w`: remaining usage for Codex (Spark)'s separate weekly window (a distinct quota bucket on the same OpenAI account), reset time, pace indicator

Codex's `5h` row is omitted entirely when the API doesn't report that window (as OpenAI has done since 2026-07) and reappears automatically once it does; the same hide-when-absent rule applies independently to `sp5h` and `sp1w`. Codex's `1w` row is always shown.

Antigravity card shows (Gemini model group — the pool `agy` consumes):

- `5h`: remaining quota for the current 5-hour window, reset time, pace indicator
- `1w`: remaining quota for the current 1-week window, weekly reset time, pace indicator

The TUI hydrates the C+G rows from the canonical schema-v2 `Antigravity (Claude)` synthetic entry at read time; it does not add that internal entry as a second card. Each valid tracked percentage produces its `cg5` (5-hour) or `cg1w` (1-week) row, including an exact 100% value. Missing or malformed sibling rows are omitted. C+G rows participate in the same `[!]` badge and one-shot notification warning membership as other rendered windows. Codex (Spark) is hydrated similarly from the canonical `Codex (Spark)` synthetic entry into the primary Codex card.

Copilot / Cursor / Vibe cards show:

- `mo`: monthly remaining percentage, billing-cycle reset, pace indicator
- Cursor: `ac` and `ap` remaining percentages, billing-cycle reset, pace indicator

Reset displays are normalized before rendering:

- Same-day resets render as `HH:MM` (24h)
- Future resets render as `Mon DD HH:MM`
- Relative vendor text like `Resets in 2h 14m` is converted to the same absolute local display

## JSON Output

`--json` prints the canonical, credential-free snapshot and is **machine-safe**: it performs no provider probes, browser launch, token refresh, cache writes, or warning notifications. The `data` block is projected through the same `SAFE_DATA_KEYS` allowlist as the persisted snapshot (no `account_email` or other PII), and normalized reset display fields are added under `display`. Antigravity's Claude+GPT fields and windows, and the TUI-only reconstructed Spark/C+G keys, are deliberately excluded from `--json`; Gemini output remains unchanged. Router-facing `--json` therefore exposes only the canonical safe provider entries, while the TUI may reconstruct internal display fields from those synthetic entries without changing the persisted or router schema.

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

## Router-facing snapshot

A sibling process or router can read `.state/snapshot-v2.json` (schema v2) instantly — no probing, no browser, no credential I/O. The canonical file is credential-free and gitignored (deliberately not `.cache/`, which holds auth cookies/tokens that a consuming router must never read).

There are two canonical public roots, one per runtime mode, and they never alias
(INV-1). Source mode writes `.state/snapshot-v2.json` in the checkout. Installed
mode — everything inside `Gradus.app` — writes
`~/Library/Application Support/Gradus/Installed/snapshot-v2.json`, and that is the
single path the Mac app, the frozen runtime, and `--json` all resolve to, so opening
the menu never requires access to this Documents-backed checkout.

Source mode *additionally* mirrors the same allowlisted payload to
`~/Library/Application Support/Gradus/snapshot-v2.json`. That legacy mirror is not a
router input and is not read by the installed app: it exists only so a rollback to the
retired launchd job has a writable path for one release. Installed mode writes no
mirror. Reading it from the installed pipeline would let a stale snapshot from a dead
producer present as fresh data, so there is deliberately no fallback to it (INV-7).

The explicit credential-aware `--refresh-snapshot` command is the only snapshot
producer, whether it is invoked by the bundled `GradusRefreshAgent` (installed mode,
the normal path) or by the legacy launchd job (source mode, retained for rollback).
The TUI, `--once`, and `--json` read and render the committed snapshot; they never
probe providers or write it.

**Read-only guarantee.** Consumer surfaces never open a browser, spawn a subprocess, refresh a token, evict a cookie cache, or send notifications. The producer writes canonical v2 atomically. History journaling is a separate best-effort output: it is attempted only after a read-back confirms that schema v2 committed, and a history failure never rolls back a valid snapshot.

**Producer coverage.** The credential-aware producer probes every
consumer-visible provider on each cycle, concurrently, and commits one coherent
snapshot. Refresh progress names each safe start/complete state. Claude probes are additionally
limited to one attempt per ten minutes, with a one-hour backoff after HTTP 429;
a 429 retains bounded windows but remains `ok: false` for fail-closed routing.
Snapshot writers use a per-file lock and reject an older payload.

Claude cooldown cycles preserve the prior observation and its original probe
timestamp exactly. A response containing no usable usage buckets is transient,
not a successful empty reading, so it cannot erase valid displayed windows.

**Background refresh (normal path).** Everything the unattended refresh needs ships
inside one Developer-ID-signed bundle, `/Applications/Gradus.app`:

| Nested item | What it is |
| --- | --- |
| `Contents/Helpers/GradusRefreshAgent` | the `SMAppService` agent that supervises one refresh cycle |
| `Contents/Helpers/GradusCredentialBridge.app` | the only code that reads Safari's cookie store |
| `Contents/Helpers/GradusRuntime.app` | the frozen universal2 Python producer (no host Python, no venv) |

Setup is three steps and no shell script:

1. Install the app (`cd app && ./install-mac-local.sh`, or open a distributed build).
2. Open **Gradus → Settings** and turn on **Monitor in Background**. That registers the
   nested agent through `SMAppService`; if macOS holds it, the same panel says so and
   offers **Open Login Items Settings**.
3. When a Safari-backed provider first needs a credential, Settings shows
   *Full Disk Access is denied* with **Reveal Credential Bridge** followed by **Open Full
   Disk Access Settings**. Grant FDA to the revealed
   `Gradus.app/Contents/Helpers/GradusCredentialBridge.app` — **granting it to `Gradus.app`
   itself does nothing**, because the grant is per-executable and the bridge is a separately
   identified nested app (INV-6).

The agent holds its own `~/Library/Application Support/Gradus/Installed/.refresh-agent.lock`
while it runs the bridge and then the frozen producer, each under its own bounded deadline,
and writes credential-free progress to `Installed/agent-status.json` before every subprocess
wait. A denied, missing, malformed, timed-out, or failed bridge is a *degraded success*, not a
failure: the producer still runs against whatever caches remain. The bridge reports which of
those it was through its exit status alone (0 success, 1 failed, 64 usage, 65 denied, 66 missing,
67 malformed), and the agent records that word as `bridge` in `agent-status.json`. A `denied`
bridge is what makes Settings say *Full Disk Access is denied*; without it, a Vibe cache the
bridge never wrote reads as "no session", which is a sign-in problem only when the bridge
succeeded. Producer failure or cancellation restores the prior complete snapshots (INV-8).
Settings renders exactly one of ten states, and only `running` is allowed to claim the data is
current. Its buttons are real actions only: a state Gradus can merely explain (a provider
sign-in, a missing tool, a bridge that will retry) gets the explanation and no button, and the
menu offers *Fix in Settings…* only when such a button exists.

**Legacy launchd job (rollback only, one release).** The `launchd/` templates and
`app/install-credential-bridge.sh` still work and are still tested, but they are no longer the
setup path — they exist so a machine can go back to the previous shape for one release. They
install a standalone `~/Applications/GradusCredentialBridge.app` plus a
`~/Library/LaunchAgents/local.gradus-snapshot.plist` job that invokes the checkout's
`--refresh-snapshot` every ~120 s, writing source-mode state.

- Wrapper: `~/.launchd/scripts/gradus_snapshot.sh`
- Plist: `~/Library/LaunchAgents/local.gradus-snapshot.plist` (StartInterval 120, RunAtLoad, Background)
- Logs: `~/Library/Logs/homelab/gradus-snapshot/`
- Install: `./app/install-credential-bridge.sh`, approve `~/Applications/GradusCredentialBridge.app`
  for Full Disk Access, then `./launchd/install.sh`. It renders both files, idempotently reloads
  the job, and visibly verifies refresh health for six minutes before reporting success.
- Uninstall: `./launchd/install.sh uninstall`.
- After installing or changing the wrapper or plist, run
  `gradus --verify-refresh-health --duration 360` and require a successful result before
  relying on unattended refresh.

The two modes never share a canonical writer and their single-flight locks are deliberately
independent, because serializing the migration requires *verified* legacy quiescence rather than
an inferred one (INV-8).

**Cutover status: not performed.** `LegacyRuntimeMigrator` is implemented, tested, and
currently *refusing*. It moves refresh from the launchd job to the bundled agent only after
every named consumer has produced a receipt proving it reads the installed canonical snapshot,
and after the legacy job is observed quiescent with no running wrapper or producer process; on
any failure it restores the legacy job to exactly the state it found, including "installed but
not loaded". It has no filesystem-removal dependency at all, so no legacy plist, wrapper, or
snapshot mirror can be deleted on any path through it, including rollback. No receipt exists on
any machine yet (`router-consumer-migration`), so this repository still runs the legacy job.

**Publisher watchdog (legacy path only).** launchd supervises the producer; nothing supervises
the macOS CloudKit publisher, which is an ordinary GUI app. When it exits, the snapshot goes on
refreshing while iOS silently freezes on the last publication — that failure ran for fourteen
hours on 2026-08-30. Each successful legacy refresh cycle therefore ends with one bounded
`gradus --publisher-watchdog` check: if the snapshot is fresh, publish evidence is more than
five minutes behind, and no process is running the publisher's exact executable path, it
relaunches `/Applications/Gradus.app` by absolute path. (Until 2026-09-06 it targeted the
pre-rename `GradusMac.app`, which kept a stale 1.10.0 publisher alive beside the installed one
and let iOS show whichever CloudKit record won the race; the installer's quit step now stops
both process names.) A publisher that *is* running but not publishing is a
wedged app or a CloudKit outage, so that case is logged and left alone; repeated relaunches
inside an hour are throttled and reported as a crash loop rather than retried forever. The check
prints only when it has something to say. `--publisher-watchdog` is opt-in and passed only by the
launchd wrapper, so no test, hermetic run, or interactive session can launch an app; set
`GRADUS_DISABLE_PUBLISHER_WATCHDOG=1` to suppress it entirely. It is removed once the cutover
completes and the agent supervises publishing directly.

**Credential bridge.** Neither the agent nor the launchd job reads Safari directly.
`GradusCredentialBridge.app` is the single-purpose, Developer-ID-signed, separately identified
app that reads Safari's cookie jar and atomically refreshes the local caches for the remaining
browser-backed providers at mode `0600` inside a `0700` cache directory; Python only consumes
those caches. Claude, OpenCode Go, and Cursor are Keychain-backed and have no Safari path at
all. Do not grant Full Disk Access to the repository Python, its virtual environment, the
launchd wrapper, `Gradus.app`, or the agent — only the bridge.

Because macOS can invalidate an app-only TCC approval when the installed bundle is replaced,
finish bridge code changes and their automated tests before installing; install and approve the
final bundle once rather than reinstalling during intermediate validation. The bridge may exit
successfully after reading Safari without finding a recognized session, so a missing browser
cache is reported as `credential_bridge cache=missing provider=...` rather than treated as proof
of authentication; a healthy refresh exit alone proves only that the snapshot refresh completed.
`./app/install-credential-bridge.sh --dry-run` builds, signs, and verifies the standalone legacy
bridge without changing `~/Applications`.

**Schema** (`schema_version: 2`):

```json
{
  "schema_version": 2,
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

`.state/snapshot-v2.json` is consumed by hermes-publisher's GradusCollector as well as review-plugin; consumers reject unsupported schema_version. Incompatible changes to top-level payload, provider-entry fields, or windows[] require a schema bump and coordinated compatibility updates in both consumer projects. Schema v2 includes the synthetic `Antigravity (Claude)` entry so the shared third-party pool is visible to consumers. `--json` is a reader presentation of the canonical snapshot and does not select or persist a router schema.

## Credential-free capacity history

Each successful `--refresh-snapshot` run may append the committed schema-v2 payload to `.state/history/YYYY-MM-DD.jsonl`. The history envelope has its own `history_schema_version`, the unchanged snapshot, safe provider provenance, and separate probe/capacity observation metadata. It never stores credentials, raw upstream bodies, account identifiers, or debug text. The directory is mode `0700`; partitions and the lock file are mode `0600`.

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
- Claude's interactive provider reads Claude Code's `claudeAiOauth.accessToken` from the macOS Keychain item `Claude Code-credentials` without persisting or logging it, then calls Anthropic's structured `/api/oauth/usage` endpoint. It maps `five_hour`, `seven_day`, and `seven_day_opus` utilization and reset fields into remaining-capacity windows. The provider never launches Claude, parses a PTY, reads Safari cookies, or consumes a status-line cache. Headless paths report `auth required: no cached credentials`; an expired OAuth session reports `Claude Code session expired: run \`claude auth login\``.
- The live TUI watches the canonical snapshot during its countdown; it does not probe automatically. Full and compact rows append valid supplemental provider credits without turning them into quota windows or alert inputs.
- Live rendering uses the `rich` library's `Live` display with alt-screen mode, eliminating scrollback buffer growth.
- In live mode, press `q` to quit, `r` to trigger an immediate refresh, or `s` to cycle Most urgent, Reset soonest, and Name A-Z. The sort choice is local to this TUI and persists in `.state/tui-settings.json`.
- The macOS credential bridge reads Safari's binary cookie store only for Vibe. Cursor reads the Cursor CLI's OAuth token and OpenCode Go its API key, each from a fixed macOS Keychain item. Claude usage is not part of this bridge: it uses Claude Code's Keychain OAuth token directly.
- **Credential storage.** `GradusCredentialBridge.app` writes only Vibe's Safari-derived `.cache/vibe_cookies.json` at mode `0600` in a `0700` directory via an atomic temporary-file rename; the Vibe provider only reads and opportunistically tightens it. Claude and OpenCode Go credentials remain in fixed macOS Keychain items and are never persisted by Gradus. The Codex `~/.codex/auth.json` continues to use the Python private-write helper. Note that `0600` protects against *other local users*; it does **not** stop iCloud replication. The cache lives under `~/Documents/Projects/gradus/.cache/`; if you ever enable **Desktop & Documents** iCloud sync, exclude this project (or its `.cache/`) from sync so the Vibe session is not copied to Apple's cloud. (Desktop & Documents sync is off by default.)
- A normalized window warns when the usage-signal ramp classifies it **orange or red** — the same rule that colors the row, not a parallel one. In practice that means depleted, or a finite pace delta below `-0.10`, or (for a window whose payload carries no reset timestamp, so no pace can be computed) below 40% remaining. Every window spec defines a pace source, so the third case is a degraded-data path rather than a normal one. `[!]` badges, one-shot macOS notifications, the Mac menu's "N low" count, the iPhone's warning tier and the CloudKit push subscription all read this one predicate, aggregated the same way: a provider warns when **any** of its windows does. iOS warning notifications identify the provider and triggering window, then state the remaining percentage and configured local threshold; the generic provider-warning fallback does not invent a threshold when no valid warning window supplies one. Antigravity's conditional C+G rows (`cg5`, `cg1w`) participate in this membership.
- Vibe uses Mistral's `usage_percentage` field as percent used directly. If Mistral shows `1.08% used`, Gradus will render about `99%` remaining after rounding.
- Cursor's dashboard API is private and undocumented, so the shape it returns can change without notice. Gradus reads it as a consumer only — Keychain token in, usage out, no refresh, no write-back, no browser cookie. A rejected or expired session fails closed with an actionable `cursor-agent login` message rather than a fabricated zero.
- **Keychain boundary, rollback shape, and live validation.** OpenCode Go and Cursor read fixed macOS Keychain generic-password items read-only, with no refresh, no write-back, and no browser cookie; Claude is Keychain-backed the same way. Moving them off Safari is one-way by construction: `GradusCredentialBridge.app` *deletes* any legacy `cursor_token.json` or `opencode_go_cookies.json` it finds and never reads them, so the rollback shape is a new bridge release plus a fresh Full Disk Access grant, not a flag flip on a dormant browser path. Because identity-bound Keychain ACLs cannot be exercised by an unsigned test binary, the automated suite stubs `security` and never touches a live Keychain item: **live signed-Keychain validation is a separate human-executed gate** run against a signed, installed candidate. It sits deliberately outside `app/test-gate.sh` and is tracked as a `RELEASE_CHECKLIST.md` step rather than as a unit test.

## Limitations

- This depends on current local CLI/API behavior across `codex`, `claude`, `agy`, `copilot`, `cursor`, `vibe`, and `opencode.ai`.
- Reset windows are only shown when the provider's structured response exposes them.
- OpenCode Go uses the fixed API-key usage endpoint; no console server-function IDs or browser session are required. Zen credit balance is unavailable through key authentication.

## Known Issues

- **Claude usage requires an explicit credential-aware producer probe.** Gradus reads Claude Code's OAuth token from Keychain and calls Anthropic's structured usage endpoint; consumer surfaces do not access Keychain. Probes run at most every 10 minutes and back off for one hour after HTTP 429. During that backoff, the TUI and apps retain bounded windows with a rate-limited/cached label while canonical v2 remains `ok: false`, so routers fail closed. If the token is missing or expired, authenticate with `claude auth login` and run `--refresh-snapshot`.
- The Antigravity token is minted under `agy`'s own OAuth client, so this path is coupled to `agy`'s internal API. If a future `agy` release changes the Keychain layout or the `retrieveUserQuotaSummary` contract, the card will show an error until the provider is updated.

## Companion apps (macOS/iOS)

`app/` holds the Swift companion apps and iOS widget that mirror this dashboard off-machine:

The canonical Zero Delta design-system source package is preserved at
[`app/design-system/zero-delta/`](app/design-system/zero-delta/). It includes
the shared brand rules, tokens, component references, Gradus UI kits, and the
Gradus app icon assets. GradusiOS 1.4 applies the supplied signal-ramp icon,
active-first provider sorting, compact exhausted grouping, selectable bucket
badges, Settings controls for sorting/visibility, and the shared expected-pace
redline across the TUI, Mac, and iOS surfaces.

- **GradusMac** — the menu-bar app that ships as `Gradus.app`. It reads the credential-free installed canonical snapshot at `~/Library/Application Support/Gradus/Installed/snapshot-v2.json` — the same file its own nested `GradusRefreshAgent` writes — and publishes provider status to a private CloudKit database (`GradusZone`, one record per provider, last-writer-wins). It never touches `.cache/`, any credential path, or the Documents-backed checkout (INV-7) — its only input is the monitor-owned snapshot copy, threaded through a single injected path dependency. Each publish also carries the Mac's user-visible computer name, short local username, and publish timestamp so iOS can show the connected computer and when it last reported; it never sends an email, serial number, path, or credential. The dropdown shows active providers as name + percentage + usage bar (metadata only where it needs attention), appends the same valid supplemental credit text as iOS and the TUI, and follows with a compact exhausted section — name and earliest reset, one line each. With no provider data, its header says `usage unavailable` rather than claiming all providers are healthy. The menu's Settings… row opens a settings window holding the same device-local display preferences iOS has — sort mode, warning threshold, and Show exhausted — alongside the sync and launch-at-login toggles. That window is an `NSWindow` this app builds itself (`SettingsWindow`) rather than SwiftUI's `Settings` scene: on macOS 26.5.2 `showSettingsWindow:` returns `true` and opens nothing, so the idiomatic route fails silently. See `SettingsWindow.swift` for the measurements.
- A failed CloudKit publish records only the safe operation-level error code/name in the Mac log; record contents, localized error text, and other metadata are deliberately excluded. A successful publish updates local evidence that the CloudKit write completed.
  - **Debug safety:** Debug GradusMac builds do not read the snapshot mirror or contact CloudKit unless launched with `GRADUS_ENABLE_PIPELINE=1`. This keeps hosted `xcodebuild test` runs hermetic even when a command bypasses the Xcode scheme; `app/test-gate.sh` additionally exports `GRADUS_DISABLE_PIPELINE=1` for its Mac leg. Release/distribution builds start the pipeline normally.
- Provider ordering is defined **once**, in `app/Shared/ProviderRanking.swift`, which is compiled into both app targets. `rankedPartition()` splits active from exhausted before applying any presentation comparator — so no sort mode can pull a depleted provider back among the actionable ones — then tiers each partition errored → attention-needed → normal and sorts by the chosen mode with a deterministic name tie-break. Each app conforms its own model (`ProviderEntry` on the Mac, `ProviderStatus` on iOS) to `RankableProvider`; the Mac recomputes depletion locally because, unlike the CloudKit model, the snapshot model has no stored `isDepleted`. This lives in `Shared/` rather than `GradusKit` deliberately: the rules are device-local presentation, so putting them in the kit would widen its INV-7-governed scope.
- **GradusiOS** — a fully-featured mobile dashboard (iOS 17+). Implements the "Zero Delta Design System": a hero-ranked "Now" screen, a Provider Detail drill-in showing all windows per provider, and a functional Settings screen with per-device warning-threshold override and notification toggle. No independent data source — renders whatever the Mac last published, kept current via a `CKRecordZoneSubscription` (silent push, delta sync with `CKFetchRecordZoneChangesOperation`) plus a silent `CKQuerySubscription`; the app compares cached warning state and emits one local notification when a provider enters a warning episode. The local-only `Explore Sample` flow uses an isolated sample cache/preferences suite, waits for live operations to quiesce before entry, suppresses remote pushes and notification registration while active, and resumes the live lifecycle only after explicit exit. Uses the shared `rankedPartition()` described above, rendering active providers as full density cards and exhausted ones as compact name + reset cells beneath them.
  - **Design system components**: `ProviderDensityCard` (a provider and every one of its windows, as `WindowRow`s), `ListRow` (generic row with single trailing accessory), `MobileNavBar` (single title + one trailing slot), `IconButton` (44pt minimum tap target). The original `StatTile` — a hero tile plus a compact ranked-list variant, each showing one window per provider behind selection badges — was deleted on 2026-08-06 once both size classes had moved to the dense every-window layout.
  - **Card density** (Settings → Local Display): Automatic is separate from the Small-to-Large size slider, and disables it while selected. Every manual position uses the same `ProviderDensityCard` and still shows all of a provider's windows — larger means bigger rows, never fewer. One-column devices show Automatic only, because a manual stop cannot change their geometry. The measurements live in one `DensityMetrics` value (`DashboardDensity.swift`) that is threaded down rather than re-derived per view, and `.compact` remains 1.6.0's shipped geometry. Small uses more columns; Large uses fewer. Because larger densities scale the row's fixed label/percentage/reset columns as well as its height, the adaptive grid's column minimum is part of the metrics too: at large an 11" iPad seats one column in portrait and two in landscape. Device-local, like the sort and exhausted-visibility preferences beside it — a phone and iPad intentionally keep their own choices. Density governs the exhausted section at the bottom of the dashboard as well as the cards above it: the reason to pick a larger density is that the small type is hard to read, so a screen that scaled its top half and not its bottom would fail the request for exactly the providers it applies to. Those cells stay *relatively* compact at every density — that is a claim about how much screen a spent provider deserves, not about how big its text is. On a phone they sit two-up at compact and one-up from standard onward; the crossover is set by where `.adaptive` flips its column count relative to actual device widths, not by where the reset string stops fitting, and `theExhaustedGridPacksAsIntendedOnEveryPhone` pins the result at all six iPhone sizes. That test predicts phone layout with a reconstruction of `.adaptive`'s packing rule, so the reconstruction itself is pinned to SwiftUI's real output by `theColumnFormulaMatchesWhatSwiftUIActuallyRenders`, which asserts it against four cell widths measured off the committed iPad baselines. Provider Detail is deliberately outside the axis: it is a single provider on a full screen, already drawn at `.title2`/`.headline`/`.subheadline` — larger than any dashboard density — so there is nothing there for the setting to enlarge.
  - **Design tokens** (Phase 1): `Colors.swift` with `SignalColor.forPercent()` (4-tier urgency ramp: `#87D787`/`#FFD75F`/`#FFAF5F`/`#FF5F5F` at ≥70/≥40/≥20/<20) and provider-accent constants; `Icon.swift` bridges SF Symbols to semantic names (offline, syncing, warning, settings, etc.).
  - **Now screen** (Phase 3): hero provider (worst-case first, including errored providers) + ranked list of remaining providers, with active providers before a compact exhausted section and a populated `NavigationStack` root for compact iPhone navigation.
  - **Provider Detail** (Phase 4): all windows per provider rendered at full size, with age metadata.
  - **Settings** (Phase 5): Sync toggle (moved from toolbar), Notifications toggle (independent of sync, unsubscribes from CloudKit on toggle-off with success-gated UI update), local warning-threshold slider, provider sorting, Automatic plus the device-relative Small-to-Large dashboard-card-size slider where multiple columns are possible, Show exhausted, connected-computer details, provider count, and app version. Display preferences are device-local; one-column devices show Automatic only. Widget size is selected in the iOS Home Screen widget gallery; Settings only chooses widget providers.
  - **Window ID labels** (Phase 4): verified against `gradus/snapshot.py`'s `V2_WINDOW_SPECS` (the schema-v2 window specs that actually flow to CloudKit/iOS), with explicit labels for the nine confirmed ids (`five_hour`/`weekly`/`monthly`/`premium`/`cg_five_hour`/`cg_weekly`/`ac`/`ap`/`billing_cycle`) plus legacy `cg5`/`cg1w` aliases, and raw-ID fallback for unknown ids.
- **GradusWidget** — one WidgetKit extension embedded in GradusiOS (`com.zerodelta.gradus.ios.widget`) with `systemSmall` and `systemMedium` layouts and its own dedicated App Store provisioning profile ("Gradus Widget App Store (API-created)"). The release pipeline enforces inside-out nested signing (extension first, containing app second) and strict version/build parity with GradusiOS. The main app writes an atomic, allowlisted JSON projection of up to three providers to `group.com.zerodelta.gradus`; the extension reads only that file and performs no network, CloudKit, notification, or credential work. The small layout shows the most urgent included provider/window; medium shows up to three. iOS Settings can exclude providers from widget ranking without changing the dashboard, alerts, cache, or CloudKit data. Both layouts show remaining percentage, signal rails, and the phone's last successful sync age; the small layout also shows reset time. Missing or invalid data asks the user to open Gradus. Tapping opens the app dashboard. Sample and UI-test fixtures never publish widget data. Physical device acceptance requires verifying both sizes and the add/remove lifecycle on hardware.
- Both apps share `GradusKit`, a CloudKit-free Swift package holding the reconciliation logic and the fixed `windowWarns` threshold, so it can be unit-tested against mocks instead of live CloudKit. `windowWarns` is defined as `signalLevel(...).needsAttention`, and `providerNeedsAttention` aggregates it over every window — one predicate with one aggregation, which is what keeps the Mac's badge and the iPhone's warning count from disagreeing about the same snapshot. Only one of the two models stores the answer: the Mac evaluates it, and stamps it onto each CloudKit record as `isWarning` for iOS and the push subscription to read. The device-local warning threshold is kept out of GradusKit per INV-7 scope — it lives in `app/Shared/` with the ranking rules, where both apps can reach it without widening the kit.
- The expected-pace marker is defined once per concern: `expectedRemaining()` in GradusKit says *where* it goes, and `markerOffset(fraction:barWidth:markerWidth:)` beside it says how that maps to a leading-edge offset. Both apps call both. The offset moved into the kit after the two drifted — iOS clamped the marker inside its bar and the Mac did not, so a Mac window at 0% or 100% drew half a marker hanging off the end. Its colour is shared the same way, as `SignalColor.paceMarker` (`#005FD7`, matching the TUI's `bar.marker`) — deliberately outside the four-tier ramp, because the marker is a reference line rather than a signal level, and blue is the one hue no tier uses. Only the marker's *size* stays per-app, because the two bars are different heights. The TUI shares the colour but not the shape: it draws the marker as one whole cell of the bar's own fill glyph rather than a thin line. That is a constraint of the character grid, not a style choice — a thin stroke there has to change glyph to move within a cell, which changes its width, and can never ink as much of its cell as the fill does, so the terminal background shows through around it. The Swift bars position a real rectangle at a continuous offset and have neither problem.
- Sync is opt-in per device (off by default) and independent per device — pairing two devices doesn't couple them beyond both reading the same published snapshot.

Optional hosted diagnostics:

```bash
git push
gh pr checks --watch
```

The Xcode Cloud workflows `Gradus macOS UI Trial` and `Gradus iOS Snapshot
Trial` may validate a pull-request head after push, but they are optional and
do not provide release authority. Their hosted runners
derive checked-out source and snapshot roots from `CI_WORKSPACE_PATH`; they never
ask a local Mac for Automation Mode. `app/Gradus.xcodeproj` is generated from
`project.yml`, but shared
project/workspace/scheme files are committed so Cloud can build a fresh clone;
per-user Xcode state remains ignored.

Xcode Cloud result bundles can be retrieved without browser automation through
the existing `gradus-app-store-connect` BWS consumer. `allocate_identity.py`
supports metadata-only `--list-result-bundles` and exact `--ci-artifact-id`
selection; downloads keep the ASC bearer token off Apple's presigned artifact
URL and write atomically with bounded stderr progress.

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

### GradusiOS release workflow (profile 2.0 adopted)

Release versioning follows [`VERSIONING.md`](VERSIONING.md): use
`MAJOR.MINOR.PATCH` for product releases, and keep Apple's build number as a
separate upload counter. A new TestFlight build is reserved for a completed,
gate-green release candidate or a release-blocking correction; small
non-blocking tweaks are batched into the next patch release.

**Current release policy:** `app/release_local_gate.py` binds the readiness
manifest to both the current source and checked Git tree, streams
`app/test-gate.sh`, and emits the candidate's local-gate proof only after all
local app tests pass. `app/prepare-testflight-candidate` then performs
production archive and signing, and `app/deploy-testflight --attended` performs
upload, processing, and internal-tester assignment against the Gradus iOS App
Store Connect record. If an active failed pre-upload candidate belongs to the
current marketing version, preparation uses the framework's
successor-correction route. If that candidate belongs to an older marketing
version, the wrapper first retires it through the framework's `retire-failed`
command and then prepares the new train through the ordinary fresh-candidate
route. Both paths preserve the prior candidate ledger and fail closed if its
state cannot be validated.
The readiness operation performs that credential-free legacy-state check
before the expensive local Xcode/UI gate. A delivered but unassigned
predecessor may roll over only when its candidate-local delivery receipt, the
chain-valid central `uploaded` transition for those exact artifact bytes, the
central identity proof, and the legacy allocation all bind the same predecessor.
Readiness and production preparation call one shared predicate, and the successor
must use a greater build number without decreasing the marketing version. The
predecessor is archived from its real state; delivery is never
recorded as assignment. Readiness and production-build failures publish only
schema-validated, bounded diagnostic codes through their declared evidence
paths, never captured subprocess output.
Do not use the `Gradus iOS Internal TestFlight` Cloud workflow for delivery: the
account's Cloud product is attached to the GradusMac app record, so its iOS
builds cannot reach the Gradus AI beta group.

Xcode Cloud validation is optional and non-gating. Its workflows use manual
`main`-branch starts and remain disabled between diagnostics to prevent
automatic billable runs. The credential-brokered
`allocate_identity.py --convert-validation-workflow-to-manual` mode performs the
one-time fail-closed conversion from each workflow's exact name-specific
automatic condition to manual `main`. The `--start-validation-build` mode can
start only those two named, enabled workflows for one attended release. Disable
them again after the runs are accepted. The read-only
`--read-validation-workflow-conditions` diagnostic
emits only those workflows' identity, enabled state, and seven start-condition
fields. `app/release-status` remains the safe read-only status command.

Cloud renders snapshots on whichever simulator its TEST action names, which is
not automatically the one `app/test-gate.sh` pins. The read-only
`--resolve-workflow-toolchain` mode reports that device under
`pinnedDestinations`; `--pin-test-destination` writes it, taking the exact
action name plus `--sim-device-type-id` and `--sim-runtime-id`. The pin reads
the workflow's whole `actions` array and sends it back with only the named TEST
action's destinations replaced, because `PATCH /ciWorkflows` overwrites that
array rather than merging into it, and re-reads afterwards so a rejected or
silently normalised pin fails rather than reporting success. A runtime of
`default` means "latest from the selected Xcode" and is what Apple's own
interface writes; it is a floating value, so it tracks the Xcode pin rather
than a fixed iOS release.

New candidates' readiness and local-gate evidence is content-bound rather than
time-bound: source or proof-contract drift invalidates it; elapsed time alone
does not.

The fixed release entry points are:

- `app/prepare-testflight-candidate` — prepares and stages a candidate; it does
  not upload.
- `app/deploy-testflight --attended` — performs the attended publication
  boundary.
- `app/release-status` — read the current local candidate status.
- `app/release-testflight` — compatibility-only dispatcher for the old
  `--prepare-only` and `--upload` arguments.

Profile 2.0 adoption was proven historically for candidate
`gradus-ios-18-a4acb3118b78faff`. The candidate-bound bridge canary returned
`adoption-authorized` after broker identity lookup, Xcode signing verification,
and App Store Connect reconciliation. That result is historical adoption
evidence, not candidate-current release authority. The fixed preparation and
deployment wrappers derive current authorization and evidence for each
successor candidate.

The legacy `archive-upload-ios.sh`, `testflight-setup.py`, and
`testflight-setup-safe.sh` entry points remain available for compatibility;
they are not additional public release routes. A prepared upload rechecks the
checkout revision and clean status against its candidate record before any
upload work, and source drift fails closed.

The central fleet audit reports Gradus as adopted. Local hooks stay lightweight
and do not run Xcode app automation; the candidate-bound local gate is the
authoritative app-validation path. Optional hosted results remain separate from
candidate-bound canary evidence.

Every semantic product release gets one concise entry in `CHANGELOG.md`. Copy
its release summary and test-focus text into App Store Connect's “What to
Test” field; keep individual candidate-build details and re-upload reasons in
`HISTORY.md`.

The release workflow requires the release-owner-confirmed candidate ID,
internal-group identity, candidate ledger, candidate-specific evidence file,
and a receipt journal inside that candidate's workspace. Assignment records
the workspace-local receipt before transitioning the ledger to `assigned`;
external receipt-journal paths are rejected. Status and long-running release
progress remain visible on their documented output channels.

The source checkout must be clean for upload, local installation, and
notarization. The only allowed untracked path is the exact internal verification
report `verifications/2026-08-09-internal-testflight-candidate-migration-verification.md`.

### Installing Gradus locally

`install-mac-local.sh` archives, exports, signs inside out, audits, installs into
`/Applications`, and relaunches. This is the path for putting a build on this machine;
notarization is only for handing the app to someone else, since Gatekeeper enforces it on
quarantined files and a bundle built here never carries `com.apple.quarantine`.

The shipped wrapper is `Gradus.app`. `GradusMac` survives as the scheme name and the archive
name (`build/GradusMac.xcarchive`); those are internal engineering identifiers and no user ever
sees them.

**Mac UI handoff rule.** After a change to `app/GradusMac/` that needs visual
validation on this Mac, the normal finalization step is `./install-mac-local.sh`
before requesting a screenshot or manual check. Test builds in DerivedData are
not visual-validation artifacts, and a matching marketing/build version does
not prove `/Applications/Gradus.app` contains the current source. Keep the
test gate hermetic; the installer is the explicit post-test handoff that
replaces and relaunches the local app. Do this automatically unless David asks
to defer installation.

```bash
cd app
./test-install-mac-local.sh   # hermetic; every Xcode/system tool faked, never touches /Applications
./install-mac-local.sh --dry-run     # archive, export, verify; stop before installing
./install-mac-local.sh               # the real thing
./install-mac-local.sh --skip-build  # reuse the existing export
```

**Signing.** `exportArchive` does not sign what a run script copied in, so the exported
`Contents/Helpers/GradusRuntime.app` and everything under it arrives ad-hoc — which Apple's
notary service rejects. `sign-mac-bundle.sh` therefore walks an explicit inventory deepest-first
(nested bundles, then loose Mach-O, then the wrapper last) and re-signs every code item with a
secure timestamp and the hardened runtime. `codesign --deep` is never the signing algorithm; it
appears only on the verify side as defense in depth. The re-sign *preserves* each item's existing
entitlement blob rather than rebuilding it from `GradusMacProduction.entitlements`, because Xcode
injects `com.apple.application-identifier` and `com.apple.developer.team-identifier` from the
provisioning profile: the exported wrapper carries six keys where the source file declares four,
and an app rebuilt from the file alone is signed, hardened, timestamped, holds no *extra*
privilege, passes every subset check, and cannot reach CloudKit. `verify-mac-bundle.sh` matches
the wrapper's entitlement set **exactly** for that reason.

**Where the export lives.** The archive stays in `build/`, but the export, the signing pass, and
the audit run under `$TMPDIR/gradus-mac-export` — outside the checkout. `~/Documents` is synced
by the iCloud Drive file provider, which re-stamps `com.apple.FinderInfo` onto `.app` directories
within about two seconds of it being cleared; `codesign` refuses any item carrying that
attribute, and `ditto` would copy it straight into the zip sent to Apple. `GRADUS_EXPORT_ROOT`
overrides the location, and the signer refuses outright — with no override flag — if the
destination turns out to be file-provider managed too.

**Verification.** The audit checks shipped names, the embedded helper inventory, a
bundle-relative LaunchAgent program path, every Mach-O's signature/identity/architecture, file
modes and frozen-runtime drift, quarantine and resource-fork metadata, and the strict deep seal,
then writes `build/gradus-mac-bundle-manifest.json` (code identities, architectures,
entitlements, versions, the source revision, and opaque digests — nothing else). A current build
audits 56 code items.

The bundle is then verified a **second** time after installation, and that is the reason this
script exists rather than a two-line `ditto`: copying into `/Applications` re-applies
`com.apple.provenance`, so a bundle that passed `codesign --verify --deep --strict` on export can
fail it once installed. The new copy is staged beside the old one as `.Gradus.app.incoming`,
stripped and verified *there*, and swapped in by rename only if it passes — a failed verify
leaves the working install untouched rather than having already destroyed it. `INSTALL_DIR`,
`BUILD_DIR`, and `GRADUS_EXPORT_ROOT` override the destination, the archive directory, and the
staging root.

It exports with Developer ID rather than development signing on purpose: the installed app holds the `~/Documents` TCC grant, and that grant records the signing requirement of whichever build was approved. Expect the next Mac test gate after an install to prompt, and run it attended — see the TCC row in `TASKS.md` for why the two signing identities cannot both hold the grant.

### Notarizing Gradus

`notarize-mac.sh` archives, exports, signs inside out, audits, uploads, waits for Apple,
staples, and packages `Gradus.app`. It uses the same signer, the same auditor, and the same
`$TMPDIR` staging as the local installer; the audit runs *before* the zip, so a bundle that fails
it is never uploaded. **Submission is opt-in**: without `--attended` the script stops after the
audit and uploads nothing. The upload stays visible, and the submission ID is recorded before
polling in the gitignored `.state/notary-submissions.tsv` ledger.

`spctl -a -vv -t install` — the Gatekeeper *acceptance* check — runs here, after stapling, where
it means something. It is deliberately not part of the local audit: an un-notarized bundle is
rejected by `spctl` by design, so running it earlier would only produce a failure that proves
nothing.

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
`Gradus.app.zip` jobs even when the local ledger is absent or changing, and
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

### VM profile-free test configuration

The switchyard macOS VM lane runs this project's Xcode tests inside a guest that
has no Apple Development identity, no team membership, and no provisioning
profile. `scripts/vm-test-build.sh` is the entry point that builds under those
constraints and then verifies the result rather than assuming it:

```bash
scripts/vm-test-build.sh GradusMac               # macOS, ad-hoc signed
scripts/vm-test-build.sh GradusCredentialBridge  # macOS, ad-hoc signed
scripts/vm-test-build.sh GradusiOS               # iOS simulator, no overrides needed
```

The macOS schemes build with `CODE_SIGN_IDENTITY=-` and an empty
`DEVELOPMENT_TEAM`, `PROVISIONING_PROFILE_SPECIFIER`, and
`CODE_SIGN_ENTITLEMENTS`. Ad-hoc is not a convenience: `CODE_SIGNING_ALLOWED=NO`
produces an unsigned Mach-O that AMFI SIGKILLs at `exec` on Apple silicon, and
xcodebuild reports that as `Test crashed with signal kill before establishing
connection` — a signing failure wearing a test failure's clothes.

`CODE_SIGN_INJECT_BASE_ENTITLEMENTS` is deliberately *not* overridden. GradusMac's
Debug config already sets it to `NO` so local Mac tests do not depend on a stale
profile; pinning it in the script would make the guest build something the host
never tests. `GradusiOS` needs no overrides at all, because Xcode already signs
simulator products ad-hoc and strips their entitlements. The script still asserts
that every produced bundle is ad-hoc with no `TeamIdentifier`, which is what
catches a target regaining a `DEVELOPMENT_TEAM` later.

There is deliberately **no `VMProfileFreeTest` build configuration**. Do not
hand-edit `app/Gradus.xcodeproj/project.pbxproj`: `xcodegen generate` rebuilds
the committed shared project data from `project.yml`. A script that passes
settings on the command line survives regeneration, and a third configuration
would propagate through every target and SPM dependency to buy nothing this
project needs.

**Capabilities unavailable under this configuration.** Tests that need any of
these cannot run in the VM and must run on the host against a real profile:

| Capability | Entitlement | Effect in the VM |
|---|---|---|
| CloudKit | `com.apple.developer.icloud-services`, `com.apple.developer.icloud-container-identifiers` | No `iCloud.com.zerodelta.gradus` container access; CloudKit calls fail rather than sync |
| Push notifications | `com.apple.developer.aps-environment` | No APNs registration; remote-notification paths are unreachable |
| Full Disk Access (`GradusCredentialBridge`) | TCC grant, keyed to the signature | An ad-hoc bridge is a different signing identity than the host's approved copy, so it holds no FDA grant and cannot read provider credential files |

For `GradusMac` the first two are already absent from Debug builds on the host,
so the VM loses no coverage the host had; the entitlements files
(`GradusMac.entitlements`, `GradusMacProduction.entitlements`,
`GradusiOS.entitlements`) are unchanged and Release keeps its full signing
contract, because the overrides are command-line only.

### Agent validation approvals

During one Gradus implementation, repeated in-scope local validation commands should use one narrow reusable approval before their first run, rather than interrupting for every equivalent invocation. Run validation at the relevant phase boundaries; do not defer it all to the end. Require a separate approval for a new dependency or package source, external writes, destructive actions, or any broader command/scope.

Decision gates follow the G/A/R autonomy contract: `~/.agent/prompts/_shared/gar.md` (Green = do; Amber = do + ledger; Red = human-only). Never end a turn on a recoverable obstacle.

### Project layout

- `gradus/providers/` — provider package:
  - `__init__.py` — re-exports + provider registry
  - `_base.py` — shared utilities, private-file helpers, headless guard
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

Local hooks provide fast feedback, while the candidate-bound local gate provides
authoritative app validation before release preparation.
Python hooks run through [`pre-commit`](https://pre-commit.com) using the project's `uv run`
tools; SwiftLint, SwiftFormat, and ShellCheck are PATH tools with exact versions
enforced by `scripts/check-static-tool-versions.sh`.

One-time bootstrap after cloning:

```bash
uv run pre-commit install   # installs the pre-commit and pre-push hooks
```

- **pre-commit** (fast): `ruff check` + `ruff format --check` on changed Python files,
  plus a fail-closed check requiring SwiftLint 0.65.1, SwiftFormat 0.63.0, and
  ShellCheck 0.11.0,
  plus strict SwiftLint and non-mutating SwiftFormat checks on changed Swift
  files, plus ShellCheck on changed shell scripts. SwiftLint uses the committed `.swiftlint-baseline.json` for the
  existing debt; any new warning or error fails the hook. SwiftFormat uses the
  explicit `.swiftformat` policy and `--cache ignore`; it never rewrites files.
  ShellCheck runs at warning severity, so every finding fails; it never
  rewrites files.
  The hook receives only changed Swift paths, so the current legacy formatting
  debt is not a full-tree waiver and existing sources are not mass-reformatted.
- **pre-push** (~40s): the whole Python suite via `uv run pytest -q`. The hook
  is `always_run` with `pass_filenames: false`, so a push
  containing no Python change still runs it.
- **release gate**: `app/test-gate.sh` runs the local macOS and simulator app
  automation against candidate-bound source. Physical-device acceptance remains
  a separate owner gate. Run it bare — `caffeinate -disu bash app/test-gate.sh`.
  Its three UI legs each take the machine-wide `apple-ui-test-lock` themselves,
  and that lock is not re-entrant, so launching the gate underneath an outer
  hold hangs those legs on a lock their own ancestor owns.

Config lives in `.pre-commit-config.yaml`, with SwiftFormat policy in
`.swiftformat`, Swift source scope and generated directory exclusions in
`.swiftlint.yml`; shell scripts are selected by the ShellCheck hook's
`types: [shell]` filter (the intentional `monitor` shell/Python polyglot is
excluded because ShellCheck cannot parse its Python half). Run the checks manually with
`uv run pre-commit run --all-files`.

Project docs:

- **README.md** — setup, usage, architecture overview
- **HISTORY.md** — change log for every session (features, bugs, regressions)
- **TASKS.md** — backlog and in-progress work
- **pyproject.toml** — dependencies (`ruff`, `pytest`, `pre-commit`) and tool config
- **.pre-commit-config.yaml** — local pre-commit hook definitions
- **scripts/check-static-tool-versions.sh** — fail-closed static-tool version gate
- **.swiftformat** — SwiftFormat version/policy configuration for changed files
- **.swiftlint.yml** / **.swiftlint-baseline.json** — Swift source scope and
  current-debt baseline for the strict pre-commit gate
- **tests/test_shellcheck_gate.py** — ShellCheck hook contract and clean-script
  self-checks
