# Independent verification: Gradus Claude authentication recovery cadence

Scope per task packet: `.logs/delivery/gradus-claude-auth-backoff-20260902-tasks.md`, Task 1.1.
Diff under review: `README.md`, `gradus/__main__.py`, `tests/test_main.py` (working tree, uncommitted).

## Task 1: Remove the auth-specific one-hour scheduler branch

**Requirements check.** `gradus/__main__.py:99-103` retains `CLAUDE_MIN_PROBE_INTERVAL_SECONDS = 600`
and `CLAUDE_RATE_LIMIT_BACKOFF_SECONDS = 3600`. The removed `CLAUDE_AUTH_FAILURE_BACKOFF_SECONDS`
constant (formerly 3600, formerly `__main__.py:106`) is gone, and `_provider_next_probe_at`
(`gradus/__main__.py:152-187`) no longer branches on `"claude code session expired" in lower_error`
— that branch and constant are both deleted (confirmed via `git diff`). The remaining branch is a
single two-way choice: `CLAUDE_RATE_LIMIT_BACKOFF_SECONDS` (3600) when the error text matches
`"http 429"` / `"rate limited"` / `"rate-limit"`, else `CLAUDE_MIN_PROBE_INTERVAL_SECONDS` (600) for
every other case, including a healthy entry (`error` is `None` → `lower_error == ""`) and an
authentication rejection.

**Clean-room verification — independent derivation of scheduler due times.** Traced
`_provider_next_probe_at` (`gradus/__main__.py:152-187`) and `_claude_probe_is_due`
(`gradus/__main__.py:146-149`) by hand against `TestProviderRefreshSchedule._payload` fixtures
(`tests/test_main.py:1541-1568`), independent of the test assertions:

- Healthy Claude (`ok=True`, `error=None`): `lower_error=""`, matches neither 429 marker →
  interval 600s. `next_due = probe_attempted_at + 600s`.
- Auth rejection (`error="Claude Code session expired: run \`claude auth login\`"`): lowercased
  string contains none of `"http 429"`, `"rate limited"`, `"rate-limit"` → interval 600s. Same
  600s due time as the healthy case.
- HTTP 429 (`error="HTTP 429 rate limited"`): matches `"http 429"` → interval 3600s.
- `provider not enabled` sentinel: short-circuits to `now` before the interval branch is reached
  (`gradus/__main__.py:164-165`), i.e. always immediately due — unaffected by this change, correctly.

This hand derivation matches `test_claude_cooldown_and_rate_limit_backoff_are_preserved`
(`tests/test_main.py:1658-1686`) exactly: 600s for both the normal and the auth-rejection cases,
3600s for the 429 case, immediate for the disabled sentinel. No discrepancy found.

**Blind-spot discovery.** Grepped `gradus/`, `app/`, and `build/` for any other copy of the
removed constant or a duplicate Claude-scheduling branch (`grep -rn CLAUDE_AUTH_FAILURE_BACKOFF`,
`grep -rn "session expired" gradus/*.py gradus/providers/*.py`, `grep -rn 3600 gradus/*.py
gradus/providers/*.py`). The constant survives only in prebuilt artifacts —
`app/build/gradus-runtime/uv-cache/...`, `app/build/gradus-runtime/toolchain/venv/...`,
`build/lib/gradus/__main__.py` — none of which are source; they are stale build outputs from
before this change and are not part of the reviewed diff or the task's file scope. No other
module encodes a second Claude backoff/cooldown timer; `gradus/history.py:74` and
`gradus/snapshot.py:80,95` reference "session expired" only as an unrelated Antigravity keyword
list, not a scheduler. `gradus/providers/claude.py` is untouched by the diff (confirmed via
`git diff --name-only`), so the probe's own request/credential behavior is provably unchanged,
not merely asserted.

## Task 2: Update regression tests for the 600-second auth boundary and preserve the 3,600-second HTTP 429 boundary

**Requirements check.** `test_claude_cooldown_and_rate_limit_backoff_are_preserved`
(`tests/test_main.py:1658-1686`) asserts, for the `expired` fixture, `_provider_next_probe_at(...)
== BASE + timedelta(seconds=600)` (line 1681-1683), `_claude_probe_is_due` is `False` at 599s and
`True` at 600s (lines 1685-1686) — both sides of the new 600s auth boundary are covered. The same
test retains the 429 boundary unchanged: `_provider_next_probe_at(limited, ...) == BASE +
timedelta(seconds=3600)` (1675-1677), `_claude_probe_is_due` `False` at 3599s / `True` at 3600s
(1679-1680) — both sides of the 3600s boundary remain covered.

`test_claude_cooldown_defers_session_expiry_before_one_hour` was renamed to
`test_claude_cooldown_defers_session_expiry_before_normal_interval`
(`tests/test_main.py:1708`) and its probe time moved from `BASE + timedelta(seconds=3599)` to
`BASE + timedelta(seconds=599)` (`tests/test_main.py:1715`), asserting the deferred status is
still `[("Claude", 1)]` (1 second remaining) one second before the new 600s boundary — this is the
"not yet due" side of the auth boundary exercised through `_schedule_refresh_providers` end to end
(the scheduling wrapper `_refresh_snapshot_once` actually calls), not just the pure function.
`test_rate_limited_claude_is_deferred_safely_before_one_hour` (`tests/test_main.py:1688-1706`) was
left unchanged and still asserts the 429 path defers 1 second before 3600s — correctly untouched,
since HTTP 429 policy was explicitly preserved.

**Clean-room verification.** Ran the phase gate and the task's own quick-check selection:

```
uv run pytest -q tests/test_main.py -k 'claude_cooldown or cooldown_defers_session_expiry or rate_limited_claude'
  → 3 passed, 122 deselected
uv run pytest -q tests/test_main.py tests/test_single_source.py
  → 125 passed, 10 skipped, 25 subtests passed
uv run ruff check gradus/__main__.py tests/test_main.py tests/test_single_source.py
  → All checks passed
git diff --check
  → clean, no output
```

All four commands from the task packet's Phase gate / Quick checks were run directly in this
review session (not taken on report) and passed.

**Blind-spot discovery.** No test still names or numerically encodes 3600 seconds for the auth-
rejection path — grepped `tests/test_main.py` for `CLAUDE_AUTH_FAILURE_BACKOFF` (no hits) and for
`3600` (only the two legitimate 429-boundary tests and the retained rate-limit test reference it).
The "0 seconds" sentinel `provider not enabled` boundary (immediate due) is unit-tested at
`test_every_consumer_visible_provider_is_due_on_each_cycle` for non-Claude providers and at
`test_claude_cooldown_and_rate_limit_backoff_are_preserved` line 1668-1672 for Claude's disabled
case — both sides of every relevant boundary in this function are exercised, not just the two the
task named explicitly.

## Task 3: Update user-facing documentation to match

**Requirements check.** `README.md:72` now reads "...Gradus retries its read-only check on the
normal ten-minute cadence" (previously "...Gradus defers its next read-only retry for one hour so
Claude Code remains the only refresh owner" per `git diff`). This matches the corrected code path
exactly — no claim of a one-hour delay remains for the auth-rejection case.

**Clean-room verification.** Read the surrounding "Known Issues" prose independently
(`README.md:415`): "Probes run at most every 10 minutes and back off for one hour after HTTP 429."
This sentence is still accurate post-change — it describes the 429 case only, which was correctly
preserved at 3600s, and the 10-minute (600s) cadence, which now correctly covers both the healthy
and the auth-rejection cases. No stale "one hour" claim about authentication rejection survives
anywhere in the documentation (grepped `README.md` for "one hour", "session expired", "re-authenticat"
— the only remaining "back off for an hour" reference is scoped explicitly to HTTP 429, correctly).

**Blind-spot discovery.** Checked `HISTORY.md:641-648` (the entry that originally introduced the
one-hour auth backoff, 2026-08-30) — it is a dated past-tense record of the *prior* decision being
reversed now, not current behavioral documentation; the task packet does not ask this verification to
edit history, and it wasn't touched by the reviewed diff, which is correct: `HISTORY.md` is a
append-only past record, and this session's own port of the new entry (if any) is out of this
report's write scope. Checked `INVARIANTS.md:32-44` (INV-2, machine-safe surfaces) and
`INVARIANTS.md:84-111` (INV-6, credential isolation) — neither invariant references a Claude
backoff duration or is affected by a pure scheduling-constant change; both remain accurate as
written, and their gate/rationale text needed no update.

## VERDICT: PASS
