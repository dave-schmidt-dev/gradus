# Invariants — gradus

> System contract. The harvest tool reads `area:` globs to map HISTORY bug entries
> to invariants. Per-project convention (commit prefix, invariant refs) is declared
> in this project's CLAUDE.md/README, not globally.

### INV-1 — The router-facing snapshot contains no credential material and no account PII, and lives in the credential-free .state/ dir
area: ["gradus/snapshot.py", "gradus/parsing.py", "gradus/providers/*.py", "gradus/history.py"]
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
  where that error string is constructed. The history writer accepts only an existing, validated schema-v2
  payload plus fixed provider-owned safe provenance descriptors; it does not widen the allowlist or persist raw
  upstream data.

### INV-2 — The machine-safe (--json / --write-snapshot) paths have zero credential side effects
area: ["gradus/providers/*.py", "gradus/__main__.py"]
gate_test: tests/test_main.py::test_write_snapshot_is_read_only_no_side_effects
threshold: 3
rationale: Machine-readable --json and headless --write-snapshot surfaces must never spawn a browser,
  fire a notification, run a cookie-extraction subprocess (Keychain/TCC prompt = a block), refresh a
  token, or evict a cookie cache the GUI TUI relies on. Missing/expired/rejected creds → ok:false.
  The gate asserts neither subprocess.Popen nor subprocess.run runs and no cred/cache file is written,
  INCLUDING on the cached-cred→HTTP-401 recovery path. --write-snapshot writes only its declared v1/v2
  snapshot outputs plus the credential-free history journal after schema-v2 read-back; --json and historical
  queries are read-only. Credential-aware launchd refresh is governed by INV-8.

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
  Each file has a path- and schema-specific transient prior. The history envelope has an independent
  history_schema_version and is not a replacement or redirect for either router schema. Prevents silent schema
  drift that a version-asserting consumer cannot detect.

### INV-6 — All persisted credential material is written mode 0600 inside a 0700 dir, via an atomic temp-file swap
area: ["gradus/providers/*.py", "gradus/history.py"]
gate_test: tests/test_providers.py::TestCredentialCachePermissions::test_credential_artifacts_are_written_private
threshold: 3
rationale: The provider credential caches (Vibe/Cursor/Claude cookies + tokens) and the Codex auth.json
  hold live sessionKey/ory_*/csrftoken values and access/refresh tokens; the /tmp debug dump holds raw
  vendor bodies. A bare Path.write_text inherits the process umask (0644 = world-readable), exposing
  those secrets to every other local user/process — and, if Desktop&Documents iCloud sync is ever
  enabled on this tree, replicating live credentials to Apple's cloud. A single choke-point,
  `_write_private` (tempfile.mkstemp — born 0600, independent of umask — then chmod + os.replace),
  is the SOLE sanctioned write path for all credential/secret writes, so the mode is never
  world-readable even momentarily and the contract is enforceable at one site. The credential-free history
  directory and partitions also default to 0700/0600 as defense in depth, although history rejects
  credential-like fields and stores no credential material. Prevents F1.

### INV-7 — The CloudKit publisher takes its snapshot data through a single injected snapshot-path dependency, and its source references no credential path
area: ["app/GradusMac/**", "app/GradusKit/**"]
gate_test: app/GradusMacTests/INV7Tests.swift::snapshotPathHasExactlyOneInjectionPoint, publisherSourceReferencesNoCredentialPath
threshold: 3
rationale: The Mac app runs on the same machine holding live credentials in `.cache/`. The single-dependency
  shape keeps the off-device publish boundary as tight as the Python producer's and forecloses the obvious
  "just read the cookies directly" regression. Honest scope (CR-13): this wording is deliberately narrowed
  to what the test actually proves. It is a grep tripwire against a hardcoded credential-path string plus a
  structural check that the snapshot path is constructed at exactly one call site
  (`PublishPipeline.defaultSnapshotPath` in GradusMacApp.swift) and threaded through `start(snapshotPath:)` —
  not a proof that every filesystem read in GradusMac is confined to that one path. PM-15's fs_usage
  runtime canary check is deferred beta-hardening, not this gate.

### INV-8 — Credential-aware background refresh is explicit, single-flight, and progress-visible
area: ["gradus/__main__.py", "gradus/providers/*.py", "launchd/*"]
gate_test: tests/test_main.py::TestCredentialAwareRefresh::test_refresh_is_explicit_single_flight_progress_visible_and_one_probe
threshold: 3
rationale: Only the explicit --refresh-snapshot command may use non-headless provider behavior for
  unattended observation. It acquires one private single-flight lock before provider initialization,
  reports safe progress through provider and persistence waits, and never routes --json or
  --write-snapshot through credential-aware behavior. One Antigravity probe supplies both the direct
  entry and the schema-v2 Antigravity (Claude) synthetic projection; no second credential request is
  implied. Overlap, lock failure, safe status, and one-probe behavior are binary-tested.
