# Invariants — gradus

> System contract. The harvest tool reads `area:` globs to map HISTORY bug entries
> to invariants. Per-project convention (commit prefix, invariant refs) is declared
> in this project's CLAUDE.md/README, not globally.

### INV-1 — The router-facing snapshot contains no credential material and no account PII, and lives in the credential-free .state/ dir
area: ["gradus/snapshot.py", "gradus/parsing.py", "gradus/providers/*.py"]
gate_test: tests/test_snapshot.py::test_payload_data_is_safe_allowlist
threshold: 3
rationale: The snapshot files are read by a separate repo (review-plugin router). They are written to
  ~/Documents/Projects/gradus/.state/snapshot.json and snapshot-v2.json — Deliberately NOT under .cache/ (which holds
  auth cookies/tokens); review-plugin's INV-5 forbids the router from reading credential paths, so the
  snapshot must live in a credential-free dir. `data` is a whitelist projection of usage/reset fields
  only — it must never carry cookies, tokens, sessionKey, ory_*, csrftoken, access_token, nor
  account_email/account_organization/login_method/account_tier/raw_text. A denylist would silently
  pass a newly-added Status field; the gate is a POSITIVE allowlist check. Prevents leaking auth or
  personal identity into a cross-repo-readable file. The `error` field is the one free-text channel
  copied verbatim into the file: it is held to the plain provider message (the raw `--debug` payload
  is diverted to a non-persisted `debug_detail`) and hard-capped at the persistence boundary, pinned
  by the companion gate test_payload_error_carries_no_raw_payload. Hence area now includes providers/*.py,
  where that error string is constructed.

### INV-2 — The headless (--write-snapshot / launchd) path is strictly read-only with zero side effects
area: ["gradus/providers/*.py", "gradus/__main__.py"]
gate_test: tests/test_main.py::test_write_snapshot_is_read_only_no_side_effects
threshold: 3
rationale: A router checkpoint / background refresher must never spawn a browser, fire a notification,
  run a cookie-extraction subprocess (Keychain/TCC prompt = a block), refresh a token (rotating a
  refresh-token out from under the user's interactive codex/agy session), or evict a cookie cache the
  GUI TUI relies on. Missing/expired/rejected creds → ok:false. The gate asserts neither
  subprocess.Popen nor subprocess.run runs and no cred/cache file is written, INCLUDING on the
  cached-cred→HTTP-401 recovery path. Prevents the Gap-5 failure and background auth-state churn.

### INV-3 — percent_left is always *remaining*, 0–100, normalized exactly once
area: ["gradus/snapshot.py"]
gate_test: tests/test_snapshot.py::test_vibe_percent_left_is_remaining
threshold: 3
rationale: Vibe's usage_percent and Cursor Auto + Composer's auto_percent_used are converted from used
to 100 − x at one place. A sign flip or double-normalization would make the router route toward the MOST
depleted provider — the exact opposite of correct. Every window's percent_left is remaining capacity.

### INV-4 — pace_delta sign and unit are canonical
area: ["gradus/snapshot.py", "gradus/ui.py"]
gate_test: tests/test_snapshot.py::test_pace_delta_unit_and_sign
threshold: 3
rationale: pace_delta = (percent_left/100) − (time_remaining/window_total): a signed fraction,
  POSITIVE = ahead/healthy, identical convention for session and billing windows, finite (not
  range-clamped). Prevents the 100× points-vs-fraction bug (ui.py had two functions using different
  units) and sign inversion, either of which silently corrupts router routing.

### INV-5 — The snapshot schema is versioned and shaped
area: ["gradus/snapshot.py"]
gate_test: tests/test_snapshot.py::test_payload_matches_contract_schema
threshold: 3
rationale: The router asserts schema_version. Both versioned files always carry schema_version + a tz-aware
  updated_at, and every provider entry (all 7 canonical names always present) has a windows[] of the
  documented shape. Breaking changes bump schema_version. The snapshot is consumed by
  hermes-publisher's GradusCollector as well as review-plugin; consumers reject unsupported
  schema_version, so incompatible changes to the top-level payload, provider-entry fields, or
  windows[] require a schema bump and coordinated compatibility updates in both consumer projects. Schema v1
  remains at snapshot.json; schema v2 lives at snapshot-v2.json and Cursor's ac/ap windows are numeric or omitted.
  Each file has a path- and schema-specific transient prior. Prevents silent schema drift that a version-asserting
  consumer cannot detect.

### INV-6 — All persisted credential material is written mode 0600 inside a 0700 dir, via an atomic temp-file swap
area: ["gradus/providers/*.py"]
gate_test: tests/test_providers.py::TestCredentialCachePermissions::test_credential_artifacts_are_written_private
threshold: 3
rationale: The provider credential caches (Vibe/Cursor/Claude cookies + tokens) and the Codex auth.json
  hold live sessionKey/ory_*/csrftoken values and access/refresh tokens; the /tmp debug dump holds raw
  vendor bodies. A bare Path.write_text inherits the process umask (0644 = world-readable), exposing
  those secrets to every other local user/process — and, if Desktop&Documents iCloud sync is ever
  enabled on this tree, replicating live credentials to Apple's cloud. A single choke-point,
  `_write_private` (tempfile.mkstemp — born 0600, independent of umask — then chmod + os.replace),
  is the SOLE sanctioned write path for all credential/secret writes, so the mode is never
  world-readable even momentarily and the contract is enforceable at one site. Prevents F1.
