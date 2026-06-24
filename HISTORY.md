# History

## 2026-06-15

- **[bug] Codex card flipped back to `auth error — press [1] to fix` two days after the 06-13 re-auth.** Pressed `[1]` did not silently resolve it: the underlying `~/.codex/auth.json` access_token was server-side revoked (`x-openai-ide-error-code: token_invalidated` from `chatgpt.com/backend-api/wham/usage`) even though the JWT `exp` was 8 days in the future. The Codex CLI itself recovers from this state by silently exchanging its `refresh_token` for a new access_token at `https://auth.openai.com/oauth/token`; aimonitor's provider had no refresh path and just kept replaying the dead token every cycle. In this specific incident the `refresh_token` was *also* revoked (`refresh_token_invalidated`, "Your session has ended. Please log in again."), so only an interactive `codex login` could recover today — but every prior 401 that the provider surfaced may have been one a silent refresh could have fixed. | files: ai_monitor/providers.py
- **[remediation] OAuth refresh_token grant inside `CodexHttpProvider`.** Added `_refresh_tokens()` which POSTs `{client_id: "app_EMoamEEZ73f0CkXaXp7hrann", grant_type: "refresh_token", refresh_token, scope: "openid profile email"}` to `https://auth.openai.com/oauth/token`. Both constants were extracted from `/opt/homebrew/bin/codex` via `strings` (not guessed). On success the new `access_token` / `id_token` / `refresh_token` are *merged* into the on-disk `auth.json` (preserving `auth_mode`, `OPENAI_API_KEY`, and `tokens.account_id`), `last_refresh` is bumped, and the file is written atomically via a sibling tempfile + `chmod 0o600` + `os.replace` so the credentials file is never world-readable even momentarily. On `refresh_token_invalidated` the provider surfaces the existing `Codex session expired: run \`codex\` to re-authenticate` message that drives the `[1]` CTA. On any other 4xx/5xx the existing "reload from disk and retry once" path takes over. `_http_json` now captures the HTTPError response body into `ProbeFailure.raw_text` so callers can branch on provider-specific error codes (previously the body was thrown away — every 401 looked alike). 2 regression tests added: `test_401_with_valid_refresh_token_refreshes_silently` (pins the silent recovery path AND verifies `auth.json` merge preserves unrelated fields AND verifies the new file is still mode 0600) and `test_401_with_invalidated_refresh_token_surfaces_reauth` (pins the "must re-login" branch). 154 tests pass (2 new), ruff clean. | files: ai_monitor/providers.py, tests/test_providers.py, HISTORY.md

## 2026-06-13

- **[bug] Codex card stuck on "session expired" forever after pressing `[1]` to re-authenticate.** `CodexHttpProvider.__init__` reads `~/.codex/auth.json` once at app startup and caches `_access_token` in memory; the provider instance lives in the `providers` list for the entire `aimonitor` session (see `__main__.py:155-161`). When the cached token expired and the user ran `codex login`, the fresh token landed on disk but the running process kept holding the stale one. The existing 401 handler set `self._access_token = ""` with a comment "Clear cached token so next init reloads" — but `__init__` is only called at startup, so "next init" never happens. Every subsequent cycle sent `Authorization: Bearer ` (empty), got another 401, and the error never cleared until `aimonitor` was restarted. The Gemini provider gets this right at `providers.py:1310-1319` ("Re-read creds from disk — user may have re-authenticated externally"); Codex didn't. | files: ai_monitor/providers.py
- **[remediation] Reload `~/.codex/auth.json` on 401 and retry once.** Extracted `_request_usage()` helper, then in `fetch()`'s 401 branch: (1) call `_load_creds()` to re-read the file; (2) if reload fails (`FileNotFoundError`), surface the `re-authenticate` error; (3) if the reloaded token is byte-identical to the cached one, short-circuit and surface the error without a wasted retry HTTP call; (4) if the reloaded token differs, retry the request once. Mirrors the Gemini pattern at `providers.py:1310-1316`. 3 regression tests added to `CodexHttpProviderTests`: `test_401_reloads_auth_json_and_retries` (fresh token → retry succeeds), `test_401_with_unchanged_auth_json_surfaces_reauth_error` (same token → exactly one HTTP call, surface re-auth), and the existing `test_401_raises_probe_failure` continues to pass. 150 tests pass (3 new), ruff clean. | files: ai_monitor/providers.py, tests/test_providers.py, HISTORY.md
- **[bug] Codex card still showed "session expired" after the in-memory-cache fix shipped and the user pressed `[1]` to launch `codex login`.** The fix above handles the case where aimonitor is holding a stale in-memory token — but the user's `auth.json` was actually being kept up to date by `codex`'s refresh-token path (file mtime updated, `last_refresh` advanced, JWT decoded as structurally valid: `iss=auth.openai.com`, `aud=api.openai.com/v1`, passkey-MFA, `exp` 10 days out). The token was nonetheless rejected by `chatgpt.com/backend-api/wham/usage` with HTTP 401 `code: "token_invalidated"`. Driving the codex 0.139.0 app-server directly with the same token via `codex app-server --stdio` and calling JSON-RPC `account/rateLimits/read` reproduced the **byte-identical** error — confirming the endpoint is still correct (codex itself still hits `wham/usage`) and the issue is server-side session revocation, not a URL or schema change. The `codex login` shortcut that aimonitor's `[1]` keypress launches sometimes takes the refresh-token path instead of a fresh OAuth flow, which re-mints an access_token bound to the *same* invalidated session — hence "I pressed 1 and fixed it" repeatedly without recovery. A full `codex logout && codex login` (or equivalently a fresh browser sign-in) bound a new session; the immediate next probe returned HTTP 200 with the expected payload shape (`rate_limit.primary_window.used_percent`, `rate_limit.secondary_window.used_percent`, `credits.balance`). No code change was needed for recovery — only the user re-auth. | files: ai_monitor/providers.py (no change), README.md
- **[bug] Codex card flipped back to auth error ~80 min after the successful 12:20 re-auth.** `~/.codex/auth.json` was missing entirely (not stale, not rejected — deleted). `codex doctor` confirmed `auth: ✗ no Codex credentials were found`. The trail in `~/.codex/log/codex-login.log`: `16:20:18Z oauth token exchange succeeded` (the good login), then `16:22:44Z starting browser login flow` with **no matching `received login callback` entry**. A second `codex login` started 2 min after the first one's success but was abandoned mid-browser-flow. The codex CLI wipes the existing token at the start of an OAuth flow (clean-slate), so an abandoned login leaves the user fully logged out. The 5-second cooldown in `_launch_fix` (`__main__.py:86`) only blocks rapid double-presses; anything past 5 s is fair game. Almost certainly a stray `[1]` keypress in aimonitor's dashboard fired the destructive `codex login` while the previous one's browser was still open. | files: ai_monitor/__main__.py
- **[remediation] Guard the `[1]` Codex shortcut against blind clobber.** Changed `AUTH_ACTIONS["Codex"]` from bare `codex login` to `ls -la ~/.codex/auth.json 2>&1; read -p '[Enter] runs codex login (overwrites token), [Ctrl-C] aborts: ' _; codex login`. The user now sees the current auth.json state (mtime + size, or "No such file or directory") AND has to explicitly press Enter before the destructive login fires. Ctrl-C aborts cleanly without touching credentials. Two regression tests added to `IsAuthErrorTests`: `test_codex_action_guards_against_blind_clobber` (pins the guard shape) and `test_codex_action_target_survives_applescript_embedding` (pins the invariant that no CLI AUTH_ACTION target contains an unescaped `"` that would break out of the AppleScript do-script literal — caught the gotcha in the embedding path `__main__.py:103`). 152 tests pass (2 new), ruff clean. | files: ai_monitor/__main__.py, tests/test_main.py, HISTORY.md
- **[research] Verified Codex internal endpoint and response shape against upstream source.** `openai/codex` v0.139.0 still uses `GET https://chatgpt.com/backend-api/wham/usage` for `account/rateLimits/read`. Response shape verified in `codex-rs/protocol/src/protocol.rs` (`RateLimitSnapshot { primary, secondary, credits, individual_limit, rate_limit_reached_type, ... }`, `RateLimitWindow { used_percent: f64, window_minutes, resets_at }`, `CreditsSnapshot { has_credits, unlimited, balance: Option<String> }`) — aimonitor's existing parser at `CodexHttpProvider.fetch` already maps these correctly. Audited alternative routes during the diagnosis: `/api/codex/usage` exists in the binary but returns 403 Cloudflare challenge to non-browser callers; `auth.openai.com/.../whoami` returns 401 `auth_token_type_not_allowed` for the ChatGPT-tier token; the WebSocket `wss://chatgpt.com/backend-api/...` Responses API exposes rate-limit info only as response headers (`x-codex-active-limit`, `x-codex-rate-limit-reached-type`, `x-codex-credits-balance`), not as a polling endpoint. Conclusion: no migration to Safari-cookie auth or alternate endpoints is warranted — Bearer-token-only against `wham/usage` is still the right path. A future hardening option would be to drive `codex app-server --stdio` JSON-RPC instead of direct HTTP, which would make aimonitor resilient to future server-side endpoint moves at the cost of a ~200-500ms `codex` subprocess spawn per refresh. Not done now. | files: HISTORY.md
- **[upstream] OpenAI-side `token_invalidated` against a freshly-minted full-OAuth token, ~90 min after the morning fix worked.** At 13:49 EDT the user ran a complete browser `codex login` (verified in `~/.codex/log/codex-login.log`: `17:49:27Z received login callback ... state_valid=true`, `17:49:28Z oauth token exchange succeeded status=200 OK`). The resulting JWT in `auth.json` is structurally identical to the 12:20 EDT token that worked end-to-end (same `aud=https://api.openai.com/v1`, `chatgpt_plan_type=team`, `chatgpt_account_id`, `amr=[pop, mfa, urn:openai:amr:passkey]`, 10-day exp). Probed `chatgpt.com/backend-api/wham/usage` immediately after the login completed: **HTTP 401 `token_invalidated`**. Driving the official `codex` CLI's own `codex app-server --stdio` and calling JSON-RPC `account/rateLimits/read` against the same just-minted token reproduced the **byte-identical error** — confirming the failure is not aimonitor's, not the in-memory cache fix's, not the `[1]` clobber-guard's, and not a refresh-vs-fresh-login distinction. The official codex CLI itself cannot fetch usage from this account in this state. Rules out: aimonitor code, URL drift, schema drift, in-memory caching, the morning's clobber-by-abandoned-login pattern. Most likely cause: an OpenAI account-level flag or server-side `/wham/usage` outage scoped to this account/Team — possibly triggered by the rapid login/relogin sequence earlier in the day, possibly an unrelated incident. Recovery is upstream-dependent; user will retry later. No aimonitor code change is appropriate — the dashboard correctly surfaces the auth error as long as the server returns 401, and any "swallow this error" patch would mask real future auth failures. | files: HISTORY.md (log only, no code change)

## 2026-06-02

- **[bug] Claude card showed `HTTP 400` instead of usage data.** The 2026-05-30 cookie-cache work landed `ClaudeHttpProviderTests._make_provider` in `tests/test_providers.py`, which mocks `_read_safari_cookies` to return fixture values (`sessionKey="sk-ant-test"`, `cf_clearance="cf_test"`, `lastActiveOrg="org-123"`) but does not patch `_CACHE_PATH`. Pre-commit test runs therefore wrote those fixtures into the repo's real `.cache/claude_cookies.json`. On every subsequent app launch `_load_from_cache` returned the fixtures and Safari was never consulted, so the probe URL became `https://claude.ai/api/organizations/org-123/usage` — which Claude rejects with HTTP 400 (`invalid_request_error`, Pydantic UUID validation on `path.organization_uuid`). | files: tests/test_providers.py, ai_monitor/providers.py
- **[bug] HTTP 400 was sticky because the eviction handler only matched 401/403.** `ClaudeHttpProvider.fetch` cleared the cookie cache only when the API returned 401 or 403; the new 400 path therefore had no self-heal. Recovery required manually deleting `.cache/claude_cookies.json`. | files: ai_monitor/providers.py
- **[bug] Auth-fix CTA was silently broken for Claude, Cursor, and Vibe session-expired errors.** `_AUTH_KEYWORDS` in `ai_monitor/__main__.py` did not include the phrase `"session expired"`, but all three providers raise messages like `"Claude session expired — visit claude.ai to refresh"` / `"Cursor session expired. Log into cursor.com to refresh."` / `"Mistral session expired. Log into console.mistral.ai to refresh."` — none of which match any other keyword either. The dashboard therefore did not surface the `[N] fix <Name>` CTA for these errors. Latent since the 2026-04-16 auth-fix-actions work. | files: ai_monitor/__main__.py
- **[bug] `IsAuthErrorTests.test_auth_keyword_with_known_provider` paraphrased the production string.** The fixture said `"session expired — visit claude.ai to authenticate"` (contains `authenticate`); production says `"refresh"`. The test passed for the wrong reason and gave false assurance that the CTA was wired up correctly. | files: tests/test_main.py
- **[bug] `VibeProviderTests` and `CursorProviderTests` write through to the real cache during construction.** Both call `VibeProvider(".")` / `CursorProvider()` without patching `_CACHE_PATH`; their constructors read real Safari cookies and call `_save_to_cache` against the production cache path. Not a poisoning vector today because the tests don't mock the cookie reader to return fakes, but a foot-gun for any future test that does — exactly the trap `ClaudeHttpProviderTests` fell into. | files: tests/test_providers.py
- **[bug] README cache-eviction line listed only 401/403.** `README.md:148` documented eviction on `401/403`; after the 400 fix it would have been inaccurate. | files: README.md
- **[remediation] Full bug sweep of the cookie-cache / auth-CTA surface.** (1) Added `setUp`/`tearDown` patching `_CACHE_PATH` to a tempfile in `ClaudeHttpProviderTests`, `VibeProviderTests`, and `CursorProviderTests` — production cache is no longer touched by any provider test. (2) Added `"HTTP 400"` to the cache-eviction condition in `ClaudeHttpProvider.fetch` so a bad-UUID `lastActiveOrg` self-evicts and the next refresh re-reads Safari; new `test_400_clears_cache` regression test added to `ClaudeCookieCacheTests`. Verified by live probe that Claude reserves 400 strictly for URL/path validation and uses 403 for auth issues, so no thrash risk. (3) Added `"session expired"` to `_AUTH_KEYWORDS` in `ai_monitor/__main__.py` so Claude/Cursor/Vibe session-expired messages route through the auth-fix CTA. (4) Added `ProductionAuthMessageRoutingTests` to `tests/test_main.py` pinning the three verbatim provider strings, so any future wording drift fails loudly. (5) Deleted the poisoned `.cache/claude_cookies.json`; verified end-to-end that the provider repopulates it with real-shape values (sessionKey > 16 chars, lastActiveOrg matches UUID format) and the Claude card recovers. (6) Updated `README.md:148` to mention `400/401/403`. 148 tests pass (4 new), ruff clean. | files: tests/test_providers.py, tests/test_main.py, ai_monitor/providers.py, ai_monitor/__main__.py, README.md, HISTORY.md

## 2026-05-30

- **[bug] Cursor panel demands re-auth despite an active Safari session.** Each time `aimonitor` started after Safari ITP / session-cookie cleanup cleared `WorkosCursorSessionToken` from `~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies`, `CursorProvider._extract_token_from_safari` returned `None`. Even after pressing `[1]` to re-open `cursor.com` (which re-issues the cookie in Safari's in-memory store), Safari does not promptly flush to the on-disk binarycookies file, so subsequent refresh ticks within the same `aimonitor` session still saw an empty cookie. Only a full quit + restart picked the token up — by then Safari had finally flushed. | files: ai_monitor/providers.py
- **[remediation] Cache the Cursor access token locally so we survive Safari disk-sync lag.** Added `CursorProvider._load_from_cache` / `_save_to_cache` / `_clear_cache` and a `_is_jwt_expired` helper. `_load_token` now tries the cache first (skipping expired JWTs via 60s leeway); a successful Safari/desktop-DB read writes through to the cache, and a 401 from the API evicts the cache so the next probe re-reads from Safari. Cache lives at `<project>/.cache/cursor_token.json` and is gitignored. Refresh-token flow also writes the new token through to the cache. 9 regression tests added covering cache-hit, expired-cache fallback, Safari-write-through, 401 eviction, and JWT expiry edge cases. | files: ai_monitor/providers.py, tests/test_providers.py, .gitignore
- **[remediation] Extend the same cookie cache to Claude and Vibe.** Both providers read Safari (Claude) or Safari/Chrome (Vibe) cookies and have the identical disk-sync-lag failure mode as Cursor. Added `_load_from_cache` / `_save_to_cache` / `_clear_cache` to `ClaudeHttpProvider` and `VibeProvider`. Claude caches `sessionKey` + `cf_clearance` + `lastActiveOrg` at `<project>/.cache/claude_cookies.json`; Vibe caches the three Ory cookies at `<project>/.cache/vibe_cookies.json`. Unlike Cursor these tokens are not JWTs, so there's no pre-flight expiry check — cache validity relies on the 401/403 eviction path (Claude `cf_clearance` in particular is short-lived). Both providers now clear the cache on auth-rejection HTTP codes. 6 regression tests added (cache-hit, write-through, 401/403 eviction for each provider). | files: ai_monitor/providers.py, tests/test_providers.py

## 2026-05-29

- **Pace cell adapts to narrow terminals.** Added `PaceLabel`, a Rich renderable that swaps the verbose pace text for arrow notation when `console.width < 93` (the 2-panel grid threshold below which the 12-char pace column truncates). Mapping: `under +Npt` → `↑Npt`, `over -Npt` → `↓Npt`, `on pace` → `=`, `n/a` → `—`. Up arrow = remaining capacity is above the expected trend (good), down arrow = below trend (bad). Style/colour is preserved across both forms. 5 tests added covering each mapping at both widths. | files: ai_monitor/ui.py, tests/test_ui.py
- **[bug] Vibe pace shown as `n/a` after Mistral's 2026-05-27 Le Chat → Vibe rebrand.** Mistral's `console.mistral.ai/api/billing/v2/vibe-usage` endpoint dropped `start_date` and `end_date` from the response (new shape: `usage_percentage`, `quota_changed_this_month`, `payg_enabled`, `reset_at`). `_billing_cycle_pace_label` requires both boundaries and short-circuited to `n/a`. Captured live payload via temporary `_write_debug_dump` on the success path to confirm the new shape. | files: ai_monitor/providers.py
- **[remediation] Derive Vibe cycle boundaries client-side when the API omits them.** Since Vibe billing is monthly and `reset_at` always lands at the 1st of the month UTC, `start_date` is derived as "first of the previous month UTC" relative to `reset_at`, and `end_date` is set to the parsed `reset_at`. Server-provided values still take precedence when present, preserving existing test fixture. Regression test added with the live post-rebrand payload. | files: ai_monitor/providers.py, tests/test_providers.py

## 2026-05-23

- **Antigravity (`agy`) CLI re-probed; quota model fully characterized.** The `agy` 1.0.1 CLI is now installed at `~/.local/bin/agy` (a real arm64 binary, not the broken Homebrew wrapper from the 2026-05-19 entry). Traced its live network and credential behavior to decide how to surface its usage. Findings:
  - **Gemini models share one pool with the Gemini card.** `agy` authenticates `consumer` tier via the shared `~/.gemini/oauth_creds.json` token and reads Gemini quota from `:retrieveUserQuota`. Direct probes of prod `cloudcode-pa` and `daily-cloudcode-pa` returned **byte-identical** buckets/fractions/reset times (e.g. `gemini-3.1-pro-preview` = 0.827, reset `2026-05-24T21:47:04Z` on both). The `daily-` host is a staging mirror; `agy` still uses it. So `agy`'s Gemini usage is *already* tracked by the existing `GeminiHttpProvider` — a separate card would duplicate it.
  - **Premium models (Claude Opus, gpt-oss) are NOT probeable via REST.** `agy`'s server is the Codeium/Exafunction engine (`/exa.cascade`, `/exa.seat`, `com.exafunction.codeium`, `x-codeium-csrf-token`, `use_ai_credits`/`credit_amount` protobuf fields). The only quota RPC on the Cloud Code backend is `:retrieveUserQuota`, which returns **Gemini models only** — no Claude/GPT buckets. A live `agy` prompt confirmed the actual inference never hits a logged googleapis URL; it goes through the local language-server **gRPC** (random localhost port, e.g. 58721) to the Codeium backend, authenticated by `agy`'s own **Keychain** credential (`ChainedAuth: via keyring`), not `oauth_creds.json`. Premium-model usage is metered as Codeium-style **AI credits** with no plaintext REST/JSON endpoint a lightweight probe can replicate.
  - Note: the 2026-05-19 claim that the quota endpoint "changed to `:fetchAvailableModels`" was wrong. `:retrieveUserQuota` is still the quota source; `:fetchAvailableModels` lists models and 403s a Gemini-tier token because `agy` calls it with its broader Keychain token.
- **Decision: relabel, don't build a separate provider.** Renamed the Gemini card title to `Gemini · Antigravity` (display-only; the `Gemini` provider key stays canonical for config/dispatch/thresholds) to reflect the shared pool — see `ui.py` `DISPLAY_TITLES`. Did **not** build an Opus/gpt-oss credit probe: it would require a gRPC client, reverse-engineered `exa.*` protos, and `agy`'s Keychain secret — a fragile, undocumented integration that breaks ai_monitor's uniform "HTTP GET → JSON → parse" provider pattern. Regression test added (`test_gemini_panel_shows_flash_and_pro` now asserts `Antigravity` in the rendered title). Revisit only if Google exposes a REST credits endpoint for premium models.

## 2026-05-19

- **Gemini CLI → Antigravity CLI transition mapped.** Google announced today that `gemini` CLI stops serving Google AI Pro, Ultra, and free OAuth tier on **2026-06-18**. Enterprise and paid API key users keep access. ai_monitor's `GeminiHttpProvider` is unaffected because it talks directly to `cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` with `~/.gemini/oauth_creds.json` — the announcement deprecates the CLI client, not the backend API.
- **Antigravity CLI architecture probed.** Installed `Antigravity.app` v2.0.0 via Homebrew cask, signed in once, and traced its real network behavior before uninstalling. Findings worth recording for the future provider port:
  - Antigravity hits `https://daily-cloudcode-pa.googleapis.com` (Google's daily/staging mirror), not the prod `cloudcode-pa` host. Same backend behavior for `retrieveUserQuota` on both hosts confirmed by direct probe with the existing Gemini OAuth token.
  - Quota endpoint changed from `:retrieveUserQuota` (returns `buckets[]`) to `:fetchAvailableModels`. Same response field names (`modelId`, `remainingFraction`, `resetTime`) inferred from server error messages and the language server's request log.
  - OAuth uses a different `client_id` (`1071006060591-tmhssin2h21lcre235vtolojh4g403ep`) and two extra scopes Gemini CLI doesn't request: `cclog` and `experimentsandconfigs`. A Gemini-tier token gets HTTP 403 on `fetchAvailableModels` even though it gets HTTP 200 on `retrieveUserQuota` on the same host.
  - Tokens are stored encrypted in `~/Library/Application Support/Antigravity/User/globalStorage/state.vscdb`, decrypted via Electron's `safeStorage` with the key in Keychain entry `Antigravity Safe Storage`. No plaintext `~/.antigravity/oauth_creds.json` equivalent.
  - The `agy` CLI binary `/opt/homebrew/bin/agy` (Homebrew cask v1.23.2) is shipped broken — wrapper points to `Resources/app/bin/antigravity`, but the actual binary is `Contents/MacOS/Antigravity`. The Go `language_server` at `Resources/bin/language_server` is the component that talks to Google's API.
  - Filesystem conflict: Antigravity writes into `~/.gemini/antigravity{,-ide,-backup}/` alongside Gemini CLI's `~/.gemini/oauth_creds.json`. Matches `google-gemini/gemini-cli#16058`.
- **Decision: postpone Antigravity provider implementation until upstream stabilizes.** Required signals before reattempting: working `agy` CLI from Homebrew, published per-tier quota numbers, Antigravity moving from `daily-cloudcode-pa` to prod `cloudcode-pa`. See `TASKS.md` for the tracking item with the 2026-06-18 deadline.

## 2026-04-23

- **Graceful network error handling**: network blips (DNS failure, connection refused, timeout, HTTP 500/504) no longer wipe provider usage data. Transient error detection now covers `"network error"`, `"timed out"`, `"invalid json"`, `"http 500"`, `"http 504"`, and `"cursor api network error"` in addition to the existing markers.
- **Offline indicator in panel title**: when cached data is being served during a transient outage, the panel title shows `(offline <1m)` / `(offline 3m)` in yellow text and the panel border switches to yellow.
- **Stale data threshold**: after 5 minutes of continuous cache (no successful refresh), the cached data is removed and replaced with a yellow `stale — offline for Xm` panel so users aren't misled by outdated numbers.
- **Source dedup fix**: the `(cached)` suffix in `source` no longer doubles up on repeated transient failures (was `"api (cached) (cached)"`).
- Subtitle cached badge removed when title already shows offline status (avoids redundancy).
- 12 new tests covering transient error detection, merge caching, stale threshold, source dedup, and UI rendering for offline/stale panels.

## 2026-04-21

- **Cursor panel cleanup**: removed the extra `pl <plan>` row from the Cursor card. Cursor still parses `plan_name` from the API payload for JSON/debug visibility, but the TUI now shows only the included API-spend row (`ap`) so the panel stays compact and avoids low-value frame clutter.
- **Cursor label cleanup**: renamed the Cursor row label from `mo` to `ap` so the panel reflects the metric it actually tracks: the included API-spend bucket from Cursor's `remaining` / `limit` fields, not Cursor's ambiguous mixed "Total" usage percentage.
- Updated the README Cursor output description and tightened UI coverage so the Cursor panel no longer renders `pl` or `pro` in normal or depleted states.
- **Cursor credit-percent fix**: changed Cursor remaining-percentage math to prefer `planUsage.remaining / planUsage.limit` over `planUsage.totalPercentUsed`. On April 21, 2026, the live Cursor payload reported `remaining=1629`, `limit=2000`, and `totalPercentUsed=4.1`; the cents ratio yields about `81.45%` remaining while `100 - totalPercentUsed` incorrectly rendered about `95.9%`.
- Added provider coverage for both paths: cents-based percentage as the primary calculation and `totalPercentUsed` as a fallback when Cursor omits `remaining`/`limit`.

## 2026-04-19

- **Vibe usage fix**: corrected Mistral `usage_percentage` parsing. The billing API already returns percentage points (`1.08` means `1.08% used`), but AI Monitor multiplied by 100 again and then inverted it, which could drive the Vibe card to `0%` remaining incorrectly.
- Added provider coverage for the real Mistral API shape and updated the Vibe UI test expectation to match the corrected remaining percentage.
- **Cursor payload cleanup**: updated Cursor parsing to read `totalPercentUsed`, `autoPercentUsed`, and `apiPercentUsed` from `usage.planUsage`, and to read plan metadata from `plan.planInfo`. The main `% remaining` calculation was already correct via `remaining / limit`, but nested metadata now matches the live API shape too.
- Added Cursor provider coverage for the current nested `planUsage` and `planInfo` response structure.

## 2026-04-16 (session 6)

- **Auth fix actions**: When a provider reports an auth error, the dashboard card now shows `auth error — press [N] to fix` instead of the raw error text, and the footer gains `[N] fix <Name>` entries. Pressing the number key opens a new Terminal.app window (CLI auth: `claude login`, `codex login`, `gemini`, `gh auth login`) or the default browser (web auth: Cursor, Vibe). Non-auth errors are unchanged.
- Added `AUTH_ACTIONS` table, `_is_auth_error()`, `_build_fix_actions()`, `_launch_fix()` to `__main__.py`.
- Added `auth_fix_key` parameter to `build_provider_panel()` and `fix_actions` parameter to `build_dashboard()` in `ui.py`.
- 25 new tests covering auth detection, fix action mapping, launch behavior, panel CTA rendering, and footer hints.
- **Gemini token refresh fix**: `_maybe_refresh()` was missing `client_id` and `client_secret` in the refresh request body, so every token refresh silently failed and Gemini showed an auth error after the 1-hour token expiry. OAuth client credentials are now read from `~/.gemini/oauth_creds.json` and auto-extracted from the installed Gemini CLI bundle on first run.
- **Stale creds fix**: `_maybe_refresh()` now re-reads `~/.gemini/oauth_creds.json` from disk when the token is expired, so external re-authentication (via `gemini` CLI) is picked up without restarting the monitor.
- **Launch fix debounce**: `_launch_fix()` now has a 5-second cooldown per target to prevent multiple Terminal windows from opening on key repeat.
- **Launch fix stdout suppression**: `_launch_fix()` redirects `osascript`/`open` stdout/stderr to DEVNULL and sends `activate` before `do script` so Terminal comes to the foreground.
- **File logging**: added `RotatingFileHandler` to `/tmp/ai_monitor.log` (1 MB, 2 backups). WARNING+ always, DEBUG with `--debug`. Captures token refresh failures, cookie extraction, and other previously silent operations.
- 97 tests pass.

## 2026-04-16 (session 5)

- **PTY removal**: deleted all PTY-based provider classes (`CodexProvider`, `ClaudeProvider`, `GeminiProvider`, `CopilotProvider`), `pty_session.py`, and the 3 PTY helpers (`TRUST_PROMPTS`, `_is_empty_or_echo`, `_is_terminal_probe_noise`). HTTP providers are now the only probes.
- **`parsing.py` gutted**: removed all parse functions (`parse_codex_status`, `parse_claude_status`, `parse_gemini_status`, `parse_copilot_status`) and their supporting helpers. File is now ~92 lines of dataclasses only.
- **`GeminiHttpProvider` static methods**: migrated `_find_bucket`, `_percent_from_fraction`, `_read_gemini_account_email` directly onto `GeminiHttpProvider`; replaced `_reset_from_iso` (relative countdown) with `_format_reset_time` (absolute local timestamp) to match all other providers.
- **`CopilotHttpProvider._monthly_reset_label`**: added to `CopilotHttpProvider` and removed the cross-class `CopilotProvider._monthly_reset_label()` call.
- **`__main__.py` simplified**: removed `--compare` flag, `_build_compare_table()`, and all `if compare:` branches; `initialize_providers()` no longer has a `compare` param; provider names drop `[HTTP]` suffix.
- **`source` tag**: changed default in `fetch_provider_snapshot` from `"cli"` to `"api"`; static init errors also tag `source="api"`.
- **Tests**: deleted `test_parsing.py` (tested deleted parse functions); removed 5 PTY-specific test methods from `test_providers.py`; rewrote `test_copilot_monthly_reset_label_uses_local_time` to use `CopilotHttpProvider`.
- Net reduction: ~1,500 lines removed. 70 tests pass.

## 2026-04-16 (session 4)

- **HTTP API probes**: Added direct HTTP provider classes for all 4 PTY-based providers (`CopilotHttpProvider`, `CodexHttpProvider`, `ClaudeHttpProvider`, `GeminiHttpProvider`). Each calls the provider's own REST API using locally cached auth tokens/cookies, returning the same status dataclass as the PTY provider.
  - Copilot: `gh auth token` → GitHub internal API (`/copilot_internal/user`)
  - Codex: `~/.codex/auth.json` → OpenAI wham usage API
  - Claude: Safari cookies (`sessionKey`, `cf_clearance`, `lastActiveOrg`) → `claude.ai/api/organizations/{org_id}/usage`
  - Gemini: `~/.gemini/oauth_creds.json` (with auto-refresh) → `cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
- **Shared helpers**: `_http_json()` (stdlib urllib wrapper, maps HTTP errors to `ProbeFailure`) and `_format_reset_time()` (unifies ISO/epoch-sec/epoch-ms → `"Resets Mon DD at HH:MM AM/PM"` across providers).
- **`--compare` flag**: runs PTY and HTTP probes side-by-side, prints a delta table after `--once` output.
- **Transient error patterns**: `_is_transient_probe_error()` now recognizes `"http 429"`, `"http 502"`, `"http 503"`, `"token expired"` so cached snapshots survive HTTP rate-limit storms the same way PTY errors do.
- **`fetch_provider_snapshot()` source param**: accepts `source="api"` so HTTP snapshots are tagged differently from PTY ones.
- Added 20 unit tests for the new helpers and all 4 HTTP providers.

## 2026-04-16 (session 3)

- **Dashboard label consistency**: all provider window labels shortened to 2 chars (`5h`, `1w`, `mo`, `fl`, `pr`). Gemini `flash`/`pro` → `fl`/`pr`; Copilot/Cursor/Vibe `1mo` → `mo`; Cursor `plan` → `pl`. Column 1 pinned to `max_width=2` in the table layout.
- **Percent format**: all providers now display integer-only percentages (`99%` not `99.1%`). `_format_percent_value` simplified; Copilot/Cursor/Vibe previously used `.1f` format which consumed an extra column character and shortened their progress bars.
- **Pace format**: `_billing_cycle_pace_label` now returns integer point labels (`over -5pt`) matching `_pace_label`, eliminating the 2-char discrepancy that shortened Copilot/Vibe/Cursor bars.
- **Progress bar width standardised**: reset (col 4) and pace (col 5) columns pinned to `min_width=12, max_width=12`. Combined with the label and percent fixes, all provider bars are now the same width regardless of content variation between providers.
- **Empty/depleted view**: when a provider has no usable capacity (Codex/Claude: EITHER 5h or 1w at 0%; Copilot/Cursor/Vibe: mo at 0%; Gemini: BOTH fl AND pr at 0%), all rows replace bar+pace with `0%  until <reset_time>`. Non-depleted windows in a blocked provider show the blocking window's reset time. Implemented via `_is_empty_window`, `_provider_is_empty`, and `_add_empty_view`; 9 tests cover all provider-specific trigger logic.
- **Empty bar colour**: empty bar segments (`░`) now use `bar.empty` (`color(244)`, mid-light grey) instead of `shadow` (`color(239)`, dark grey), clearly distinguishing unused capacity from used.
- **Quit during refresh bug fixed**: the refresh-phase polling loop now uses `select.select` with a 0.12s timeout to check for `q`/`Q` keypresses, matching the countdown phase. Previously `time.sleep(0.12)` blocked keyboard input until the fetch completed.
- 64 tests pass.

## 2026-04-16 (session 2)

- Dashboard UI overhaul — all providers now use a unified 5-column row layout (`label | % | bar | reset | pace`) so progress bars align visually across all panels in the 2-column grid.
- Collapsed windowed providers (Claude, Codex, Gemini) from 2 rows per window to 1: reset time and pace indicator now appear inline on the same row as the usage bar.
- Collapsed monthly providers (Copilot, Cursor, Vibe) from 3 rows to 1: same inline layout.
- Label changes: `"5h session"` → `"5h"`, `"1w session"` → `"1w"`, `"flash pool"` → `"flash"`, `"pro pool"` → `"pro"`, `"month rem"` / `"credit rem"` → `"1mo"` (consistent cycle-length notation across all providers).
- Pace values simplified: `"under pace +15pt"` → `"under +15pt"`, `"over pace -5pt"` → `"over -5pt"`.
- Switched all times to 24h format — AM/PM removed everywhere (display and header).
- Header: day-of-week dropped, `"Refreshing in Xs"` → `"↻ Xs"` with pipe divider, `"Last Updated:"` label kept.
- Footer: `[Ctrl-C] exit · --json --debug` removed, leaving only `[q] quit  [r] refresh`.
- Provider panel borders now use each provider's accent color (pink=Claude, blue=Codex, teal=Gemini, cyan=Copilot, orange=Cursor, amber=Vibe) instead of flat grey.
- Gemini windows given approximate `window_hours` (24h flash, 720h pro) to enable pace calculation.
- Extracted `_pace_style()` helper to eliminate 4 identical if/elif/else pace-color blocks.
- All test assertions updated for new labels, 24h times, and header format; 55 tests pass.

## 2026-04-16

- Fixed keyboard shortcut hints in dashboard footer: replaced invisible `dim text.muted` styling with `Text.assemble` using cyan color on key labels (`[q]`, `[r]`, `[Ctrl-C]`). Color-only styles are correctly stripped by `no_color=True` rendering so ANSI regression tests continue to pass.
- Tightened dashboard header: collapsed into a single line (`AI Usage Monitor | Last Updated: <timestamp> | Refreshing in <N>s`), removed redundant subtitle line, timestamp rendered in yellow for contrast, refresh state uses "Refreshing in Xs" / "Refreshing Xs" language.
- Removed "live" badge from provider panel subtitles — present data implies live; only show "cached Xm" when data is actually stale.
- Removed redundant `<Provider> usage` subtitle text from all provider panels — provider name in the panel title is sufficient.
- Cursor and Vibe panels are now always sorted last in the grid so their compact (3-row) size pairs them together rather than being mixed with taller providers.
- Normalized reset times for Copilot, Cursor, and Vibe to system local time (was UTC). All three now use `target.astimezone().strftime('%b %d at %I:%M %p')` so the display is consistent with Claude, Codex, and Gemini. The `at` notation also lets `_parse_reset_target` parse the string, enabling `_format_reset_display` to compress same-day times to clock-only format.

## 2026-04-15

- Extracted a shared Safari `Cookies.binarycookies` parser and reused it for both Cursor and Vibe auth cookie flows.
- Added generalized billing-cycle pace logic and wired pace rows for Cursor (`credit pace`) and Vibe (`month pace`).
- Removed the Vibe `pay-as-you-go` row from the dashboard card to reduce visual noise.
- Collapsed provider error cards to a compact single-line message panel.
- Added live keyboard shortcuts: `q` quits immediately and `r` triggers an immediate refresh.
- Added optional `.ai_monitor.json` configuration (`providers`, `interval`, `threshold`) plus `--providers` CLI override filtering.
- Added threshold notifications (macOS `osascript`) with one-shot crossing semantics and automatic reset when recovered.
- Added a `[!]` low-usage badge in provider titles when remaining percentage is below the configured threshold.
- Replaced ~280 lines of hand-rolled ANSI escape code rendering with Python's `rich` library (`Live`, `Panel`, `Table.grid`, custom `PercentageBar` renderable). This eliminates the persistent scrollback buffer growth bug that 6+ prior fix attempts using raw ANSI sequences could not fully resolve.
- Added `rich>=15.0` as the first runtime dependency.
- `--once` mode now prints directly via `Console.print` without entering alt-screen (no flash).
- `--json` mode writes directly to `sys.stdout` with explicit flush (no Rich dependency in JSON path).
- Live interactive mode uses `Live(screen=True, auto_refresh=False)` with manual refresh for precise countdown control.
- Countdown loop uses deadline-based drift correction instead of accumulating `time.sleep(1)` calls.
- Fixed pre-existing `refresh()` closure bug where the inner function referenced the wrong `snapshots` variable from outer scope instead of its `previous` parameter.
- Removed all ANSI constants, old PALETTE dict, and ~30 hand-rolled rendering functions (`write_screen`, `enter_alt_screen`, `leave_alt_screen`, `countdown_sleep`, `_card`, `_merge_columns`, `_progress_bar`, etc.).
- Rewrote test suite from ANSI string assertions to Rich Console capture pattern; test count increased from 29 to 42.
- Fixed missing leading `/` in `aimonitor` alias in `~/.zshrc` that prevented the alias from resolving.
- Reorganized `~/.zshrc` into labeled sections (PATH, Completion, AI/LLM Tools, Projects, System/Infra).
- Updated write_screen tests to document the always-full-clear invariant.

## 2026-04-14

- Replaced absolute-home/alternate-screen repainting with cursor-relative redraw (`cursor-up + clear-to-end`) to keep startup/countdown/refresh animations in-place on terminals that ignore or partially implement those older control paths.
- Added regressions for repaint control-sequence behavior, including multi-line cursor-up redraw between frames.
- Reworked terminal repainting so dashboard updates now clear and redraw in-place via `write_screen(..., repaint=True)`, preventing downward frame accumulation during startup, countdown, and refresh updates.
- Restored live startup spinner timing and live countdown updates after the repaint regression fixes.
- Added regressions for startup animation, countdown tick rendering, and TTY repaint escape behavior.
- Fixed the refresh-loop regression that repeatedly repainted the full dashboard at 10Hz during provider updates; refresh now shows a single in-place `updating` state until the probe batch finishes.
- Switched Copilot monthly reset semantics to UTC midnight (first day of next month, `UTC`) to match GitHub premium reset behavior.
- Added a Copilot `month rem` color progress bar so Copilot remaining usage visually matches the other provider cards.
- Refined the Copilot card to monthly semantics (`month rem`, `month reset`, `month pace`) and switched remaining display to one decimal place.
- Added Copilot monthly pace calculation against expected month progress, plus monthly reset normalization to first-of-month local midnight.
- Updated the live refresh loop to show an explicit `updating …` header state while provider probes are running, then restore the countdown when refresh completes.
- Confirmed Copilot probing remains passive status-line sampling only (no prompt send path that would consume premium requests).
- Improved Gemini probe failures by detecting the CLI "Waiting for authentication..." screen and surfacing a direct sign-in instruction instead of a generic stats-panel parse error.
- Added provider helper tests to cover Gemini authentication-wait detection.
- Fixed Gemini direct quota probing for bundled Gemini CLI installs (for example Homebrew v0.37.x), restoring Flash/Pro usage without relying on `/stats` PTY scraping.
- Fixed Claude usage parsing for compressed single-line panels so 5h/1w percentages and reset fields no longer collapse into one mixed value.
- Hardened Codex probing against transient PTY control-sequence noise and added a startup warmup/retry path so `/status` reliably captures full 5h and weekly limits.
- Added a fourth provider card for GitHub Copilot by probing interactive status-line premium request signals.
- Added Copilot parser coverage and UI coverage so premium request, remaining percentage, and pace rows render consistently with the existing dashboard style.

## 2026-03-14

- Added Gemini CLI support by probing `/stats` and rendering compact Flash and Pro pool cards.
- Reworked the dashboard into a compact two-column grid so three providers still fit in smaller terminal windows.
- Tightened row and card widths to reduce right-edge wrapping in split view.
- Fixed `NameError: name 're' is not defined` crash on startup by adding missing `import re` to `ui.py`.
- Refactored provider card rendering through a shared spec-driven row builder so Claude and Codex use the same metric/reset/pace text pipeline.
- Added UI regression tests to keep shared provider card labels aligned as new providers are added.
- Canonicalized reset date/time formatting across provider strings, including relative, 24-hour, and vendor-specific reset text variants.
- Added normalized reset display fields to `--json` output so scripts can reuse the same canonical formatting as the TUI.
- Replaced Gemini PTY scraping with a direct internal quota probe against the installed Gemini CLI so Gemini cards no longer depend on `/stats` terminal rendering.
- Added a dedicated Claude warmup phase before sending `/usage` to handle folder trust prompts and startup output.
- Added early empty-output detection for all providers so blank PTY responses trigger a retry instead of a parse failure.
- Added debug dump support (`--debug`) that writes raw PTY captures to `/tmp/ai_monitor_*_capture.txt`.
- Added provider regression coverage for Gemini's mixed log-plus-JSON stdout shape.
- Confirmed Claude PTY probing works correctly; current `/usage` failures are a server-side Anthropic API issue returning empty limit data for Team seats, not a transport problem.

## 2026-03-13

- Added initial PTY-based terminal monitor for Codex and Claude usage.
- Mirrored the core local probing strategy used by `steipete/CodexBar`.
- Added parser tests and basic project documentation.
- Reworked the plain text output into a styled terminal dashboard with progress bars and reset countdowns.
- Added a `monitor` command entrypoint and repo-local launcher script.
- Tightened the dashboard layout with fixed compact card widths to preserve split view and avoid right-edge border wrapping.
- Standardized Claude and Codex dashboard wording around shared 5-hour and 1-week session windows, and removed the unused Codex credits row.
- Added GitHub-ready repo hygiene with a `.gitignore`, richer README documentation, and checked-in screenshots.
- Added an MIT license for public GitHub distribution.
- Kept the last good provider snapshot on transient probe failures so temporary Claude usage errors do not replace the live card immediately.
- Added a `cached` badge so reused provider snapshots are visible in the dashboard.
- Added cached age display so reused provider snapshots show how stale they are.
- Increased the default refresh interval from 60 seconds to 120 seconds while keeping `--interval` as an override.
