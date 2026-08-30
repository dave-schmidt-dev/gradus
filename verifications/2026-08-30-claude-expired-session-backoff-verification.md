# Gradus Claude expired-session backoff — independent verification

Date: 2026-08-30
Scope: `gradus/__main__.py`, `tests/test_main.py`, `README.md` (and context from `gradus/providers/claude.py`, `INVARIANTS.md`)

## Task 1 — Add an explicit one-hour backoff for `claude code session expired`

### Requirements Check
- Constant `CLAUDE_AUTH_FAILURE_BACKOFF_SECONDS = 3600` is defined at [`gradus/__main__.py:105`](../gradus/__main__.py#L105).
- In `_provider_next_probe_at` ([`gradus/__main__.py:184-190`](../gradus/__main__.py#L184-L190)), `lower_error` matches substring `"claude code session expired"` and applies `CLAUDE_AUTH_FAILURE_BACKOFF_SECONDS` (3600s), preceding the rate-limit check (`CLAUDE_RATE_LIMIT_BACKOFF_SECONDS = 3600`) and the default Claude probe interval (`CLAUDE_MIN_PROBE_INTERVAL_SECONDS = 600`).
- The error string originates in [`gradus/providers/claude.py:93-96`](../gradus/providers/claude.py#L93-L96), where HTTP 401/403 errors from `https://api.anthropic.com/api/oauth/usage` raise `ProbeFailure("Claude Code session expired: run `claude auth login`", "")`.
- Case-insensitivity is ensured via `lower_error = error.lower() if isinstance(error, str) else ""` ([`gradus/__main__.py:183`](../gradus/__main__.py#L183)).

**Verdict: PASS.**

### Clean-Room Verification
- Independently analyzed all branches of `_provider_next_probe_at` ([`gradus/__main__.py:154-191`](../gradus/__main__.py#L154-L191)):
  1. Non-Claude provider: returns `now` (0s cooldown).
  2. Missing entry / unparseable timestamp: returns `now`.
  3. `entry.get("error") == "provider not enabled"`: returns `now` immediately (prevents newly re-enabled providers from being locked out).
  4. `"claude code session expired" in lower_error`: returns `parsed + timedelta(seconds=3600)`.
  5. `"http 429" in lower_error or "rate limited" in lower_error or "rate-limit" in lower_error`: returns `parsed + timedelta(seconds=3600)`.
  6. Any other Claude error / success: returns `parsed + timedelta(seconds=600)`.
- Timestamp persistence: `parsed` is derived from `entry.get("probe_attempted_at") or entry.get("observed_at")` ([`gradus/__main__.py:171`](../gradus/__main__.py#L171)). Because cooldown projections carry prior entries without touching Claude, the 120s producer tick preserves the original attempt timestamp without sliding the window forward infinitely.

**Verdict: PASS.**

### Blind-Spot Discovery
- Missing vs Expired credentials: When Claude Code credentials are completely missing from Keychain, [`gradus/providers/claude.py:37`](../gradus/providers/claude.py#L37) produces `"Claude Code OAuth credentials unavailable: run `claude auth login`"`. This deliberately falls through to the 10-minute probe interval (`CLAUDE_MIN_PROBE_INTERVAL_SECONDS`) rather than the 1-hour backoff. This distinction is correct: a missing token requires no network probe (it fails locally in `_acquire` before HTTP dispatch), whereas an expired token hits Anthropic's OAuth endpoint with a stale bearer token and warrants backoff.
- In-memory token clearing: On HTTP 401/403, `self._access_token = ""` is cleared in [`gradus/providers/claude.py:92`](../gradus/providers/claude.py#L92), ensuring that once the 1-hour backoff elapses, the provider re-reads the Keychain rather than reusing stale memory state.

**Verdict: PASS.**

---

## Task 2 — Add focused regression coverage for retry boundary and fetch suppression

### Requirements Check
- `test_claude_cooldown_and_rate_limit_backoff_are_preserved` ([`tests/test_main.py:1646-1675`](../tests/test_main.py#L1646-L1675)) checks boundary timestamps for normal (599s / 600s), HTTP 429 rate-limited (3599s / 3600s), OAuth session-expired (3599s / 3600s), and synthetic disabled (0s).
- `test_claude_cooldown_defers_session_expiry_before_one_hour` ([`tests/test_main.py:1696-1713`](../tests/test_main.py#L1696-L1713)) checks that `_schedule_refresh_providers` at `BASE + timedelta(seconds=3599)` defers the provider, emits `("Claude", 1)` remaining to the progress callback, returns `source == "snapshot"`, and asserts `fetch_provider_snapshot.assert_not_called()`.

**Verdict: PASS.**

### Clean-Room Verification
- Executed isolated clean-room script exercising `_schedule_refresh_providers` and `collect_snapshots`:
  - At `T + 3599s`: `fetch_provider_snapshot` was not called (call count = 0), `snapshots[0].source == "snapshot"`, deferred wait reported as 1s.
  - At `T + 3600s`: real provider was scheduled and `fetch_provider_snapshot` was invoked (call count = 1).
- Ran focused test suite: `uv run pytest -v tests/test_main.py -k "TestProviderRefreshSchedule"` → 7 passed in 0.08s.
- Ran full test suite: `uv run pytest tests/test_main.py tests/test_providers.py tests/test_snapshot.py tests/test_ui.py` → 608 passed, 10 skipped in 2.50s.

**Verdict: PASS.**

### Blind-Spot Discovery
- In `test_claude_cooldown_defers_session_expiry_before_one_hour` ([`tests/test_main.py:1696-1713`](../tests/test_main.py#L1696-L1713)), the test exercises the behavioral composition of `_schedule_refresh_providers` wrapping the provider in `_CanonicalClaudeCooldown` and `collect_snapshots` resolving it from snapshot cache without network dispatch. The test does not just compare integers; it executes the scheduling pipeline.

**Verdict: PASS.**

---

## Task 3 — Update README recovery guidance

### Requirements Check
- [`README.md:73`](../README.md#L73) updated:
  `Claude: Claude Code authenticated with claude auth login; Gradus reads the OAuth access token read-only from the macOS Keychain (service Claude Code-credentials) and sends it only to Anthropic's usage endpoint. If Claude Code reports its OAuth session expired, re-authenticate with claude auth login; Gradus defers its next read-only retry for one hour so Claude Code remains the only refresh owner.`
- Guidance matches existing CLI and TUI actions in [`gradus/__main__.py:65`](../gradus/__main__.py#L65) (`AUTH_ACTIONS["Claude"] = ("cli", "claude auth login")`) and [`README.md:351`](../README.md#L351).

**Verdict: PASS.**

### Clean-Room Verification
- Verified that all documentation references across [`README.md`](../README.md), [`gradus/__main__.py`](../gradus/__main__.py), and [`gradus/providers/claude.py`](../gradus/providers/claude.py) consistently prescribe `claude auth login`.
- Verified that Gradus takes no credential ownership: Claude Code alone performs OAuth exchanges and refreshes; Gradus only reads the access token from Keychain.

**Verdict: PASS.**

### Blind-Spot Discovery
- Contrast with Antigravity: While Antigravity implements an active CLI nudge via `agy models` to self-heal its token ([`README.md:74`](../README.md#L74)), Claude Code has no non-interactive headless refresh hook. The README explicitly documents that Gradus defers its read-only retry for one hour so Claude Code remains the sole refresh owner.

**Verdict: PASS.**

---

## §Spot-Checks Summary

1. **Retry Timing Derivation:**
   - Ordinary Claude probe / error: `600s` (10 minutes) via `CLAUDE_MIN_PROBE_INTERVAL_SECONDS`.
   - Claude OAuth session expired (`"claude code session expired"`): `3600s` (1 hour) via `CLAUDE_AUTH_FAILURE_BACKOFF_SECONDS`.
   - Claude HTTP 429 (`"http 429"`, `"rate limited"`, `"rate-limit"`): `3600s` (1 hour) via `CLAUDE_RATE_LIMIT_BACKOFF_SECONDS`.
   - Synthetic disabled (`"provider not enabled"`): `0s` (immediately due).
   - Non-Claude providers: `0s` (due on every 120s producer cycle).
2. **Fetch Suppression Proof:**
   - Proved via automated clean-room execution: At $T+3599\text{s}$, `fetch_provider_snapshot` call count is 0 (`source == "snapshot"`, deferred 1s). At $T+3600\text{s}$, `fetch_provider_snapshot` call count is 1.
3. **Credential Non-Mutation & Refresh Token Isolation:**
   - [`gradus/providers/claude.py:42-76`](../gradus/providers/claude.py#L42-L76) reads only `claudeAiOauth.accessToken` from the Keychain. No `refreshToken` is read, persisted, or logged. No Keychain modification commands are executed.
4. **Behavioral Test Coverage:**
   - Tests in [`tests/test_main.py:1646-1713`](../tests/test_main.py#L1646-L1713) verify due-time calculations, status notification reporting, and execution suppression through `collect_snapshots`.
5. **CLI Contract Consistency:**
   - `README.md`, `AUTH_ACTIONS`, and `ProbeFailure` messages uniformly reference `claude auth login`.

---

## Verdict Block

- Task 1 (Explicit 1-hour backoff on expired Claude session): **PASS**
- Task 2 (Regression coverage for retry boundary and fetch suppression): **PASS**
- Task 3 (README recovery guidance update): **PASS**
- Spot-checks 1–5: **PASS**
- Quality checks: `ruff check`, `ruff format --check`, and 608 unit/integration tests all pass cleanly with zero regressions.
