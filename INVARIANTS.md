# Invariants — ai_monitor

> System contract. The harvest tool reads `area:` globs to map HISTORY bug entries
> to invariants. Per-project convention (commit prefix, invariant refs) is declared
> in this project's CLAUDE.md/README, not globally.

### INV-1 — The router-facing snapshot contains no credential material and no account PII, and lives in the credential-free .state/ dir
area: ["ai_monitor/snapshot.py", "ai_monitor/parsing.py"]
gate_test: tests/test_snapshot.py::test_payload_data_is_safe_allowlist
threshold: 3
rationale: The snapshot.json is read by a separate repo (review-plugin router). It is written to
  ~/Documents/Projects/ai_monitor/.state/snapshot.json — Deliberately NOT under .cache/ (which holds
  auth cookies/tokens); review-plugin's INV-5 forbids the router from reading credential paths, so the
  snapshot must live in a credential-free dir. `data` is a whitelist projection of usage/reset fields
  only — it must never carry cookies, tokens, sessionKey, ory_*, csrftoken, access_token, nor
  account_email/account_organization/login_method/account_tier/raw_text. A denylist would silently
  pass a newly-added Status field; the gate is a POSITIVE allowlist check. Prevents leaking auth or
  personal identity into a cross-repo-readable file.

### INV-2 — The headless (--write-snapshot / launchd) path is strictly read-only with zero side effects
area: ["ai_monitor/providers.py", "ai_monitor/__main__.py"]
gate_test: tests/test_main.py::test_write_snapshot_is_read_only_no_side_effects
threshold: 3
rationale: A router checkpoint / background refresher must never spawn a browser, fire a notification,
  run a cookie-extraction subprocess (Keychain/TCC prompt = a block), refresh a token (rotating a
  refresh-token out from under the user's interactive codex/agy session), or evict a cookie cache the
  GUI TUI relies on. Missing/expired/rejected creds → ok:false. The gate asserts neither
  subprocess.Popen nor subprocess.run runs and no cred/cache file is written, INCLUDING on the
  cached-cred→HTTP-401 recovery path. Prevents the Gap-5 failure and background auth-state churn.

### INV-3 — percent_left is always *remaining*, 0–100, normalized exactly once
area: ["ai_monitor/snapshot.py"]
gate_test: tests/test_snapshot.py::test_vibe_percent_left_is_remaining
threshold: 3
rationale: Vibe's API reports usage_percent (used), converted to 100 − x at one place. A sign flip or
  double-normalization would make the router route toward the MOST depleted provider — the exact
  opposite of correct. Every window's percent_left is remaining capacity.

### INV-4 — pace_delta sign and unit are canonical
area: ["ai_monitor/snapshot.py", "ai_monitor/ui.py"]
gate_test: tests/test_snapshot.py::test_pace_delta_unit_and_sign
threshold: 3
rationale: pace_delta = (percent_left/100) − (time_remaining/window_total): a signed fraction,
  POSITIVE = ahead/healthy, identical convention for session and billing windows, finite (not
  range-clamped). Prevents the 100× points-vs-fraction bug (ui.py had two functions using different
  units) and sign inversion, either of which silently corrupts router routing.

### INV-5 — The snapshot schema is versioned and shaped
area: ["ai_monitor/snapshot.py"]
gate_test: tests/test_snapshot.py::test_payload_matches_contract_schema
threshold: 3
rationale: The router asserts schema_version. The file always carries schema_version + a tz-aware
  updated_at, and every provider entry (all 5 canonical names always present) has a windows[] of the
  documented shape. Breaking changes bump schema_version. Prevents silent schema drift that a
  version-asserting consumer cannot detect.
