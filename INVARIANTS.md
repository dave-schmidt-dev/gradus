# Invariants — gradus

> System contract. The harvest tool reads `area:` globs to map HISTORY bug entries
> to invariants. Per-project convention (commit prefix, invariant refs) is declared
> in this project's CLAUDE.md/README, not globally.

### INV-1 — The router-facing snapshot contains no credential material and no account PII, and lives in the credential-free .state/ dir
area: ["gradus/snapshot.py", "gradus/parsing.py", "gradus/history.py"]
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
  The schema-v2 writer also atomically mirrors that same allowlisted payload to
  ~/Library/Application Support/Gradus/snapshot-v2.json for GradusMac; this is
  a consumer copy, not a router input, and it has the identical safe schema.

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
area: ["gradus/snapshot.py", "tests/test_snapshot.py", "tests/test_ui.py"]
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

### INV-6 — Safari-derived credentials cross one app boundary and stay private at rest
area: ["app/GradusCredentialBridge/**", "gradus/providers/*.py", "launchd/*", "gradus/history.py"]
gate_test: app/GradusCredentialBridgeTests/BridgeTests.swift::testRefreshWritesOnlyAllowedPayloadsWithPrivateModes
threshold: 3
rationale: Safari-derived provider cookies are read only by the Developer-ID-signed
  GradusCredentialBridge.app, which atomically writes the fixed allowlisted cache payloads at
  0600 inside a 0700 .cache directory. Python providers consume those caches only; neither they
  nor the launchd wrapper may read Safari, Chrome, Desktop databases, or a credential file fallback.
  This confines Full Disk Access to ~/Applications/GradusCredentialBridge.app rather than a shared
  Python runtime or shell wrapper. Codex auth.json and debug dumps retain the Python private-write
  helper. The bridge test proves parser allowlists, payload boundaries, and file modes; provider
  tests tripwire prohibited browser paths. Prevents private browser state from becoming available to
  arbitrary Python processes or world-readable at rest.

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

### INV-9 — A cross-platform feature ships its producer and consumer as one compatibility unit
area: ["app/GradusMac/**", "app/GradusiOS/**", "app/GradusKit/**", "app/project.yml", "app/test-gate.sh", "app/archive-upload-ios.sh", "app/release_candidate/**", "app/testflight-assign.py", "app/testflight-setup.py", "app/_asc_api.py", "RELEASE_CHECKLIST.md"]
gate_test: app/test-gate.sh
threshold: 3
rationale: GradusiOS is a consumer of the Mac publisher, not an independent data source. If an iOS
  feature reads a new field, record, behavior, or contract produced by GradusMac, the Mac producer
  must be built, launched, and verified in the matching CloudKit environment before the iOS artifact
  is uploaded. A consumer-only TestFlight release can otherwise look healthy while rendering stale
  records, missing required context, or silently dropping the new feature. The release checklist
  makes the dependency decision explicit, requires both sides to pass their gates, and records the
  producer-publish evidence alongside the consumer upload evidence. The candidate ledger binds source, project,
  artifact, version, producer, iOS, IPA, and walkthrough digests and permits only validated state transitions.
  Preparation and upload are separate operations; upload acceptance is not processing or assignment. Processing,
  compliance, and internal-group assignment require a candidate-bound receipt with the exact build and redacted
  predicates. The iOS archive guard rejects missing, mismatched, wrong-build, or stale machine-written evidence before allocating an iOS build number. A Mac-only local republish does
  not require notarization; a Mac artifact distributed to users still follows the notarization gate.

### INV-10 — Product versions are semantic and Apple build numbers are independent
area: ["VERSIONING.md", "app/project.yml", "app/archive-upload-ios.sh", "CHANGELOG.md", "HISTORY.md"]
gate_test: app/test-gate.sh
threshold: 3
rationale: MARKETING_VERSION is the user-facing MAJOR.MINOR.PATCH product version, while
  CURRENT_PROJECT_VERSION/CFBundleVersion is Apple's monotonically increasing upload identifier.
  One semantic version gets one user-facing changelog entry; superseded candidate builds belong in
  local HISTORY.md. This prevents internal TestFlight retries from becoming misleading product
  releases and prevents small fixes from appearing as large version jumps.

### INV-11 — New features and user-facing UI ship with automated regression coverage
area: ["app/GradusKit/**", "app/GradusMac/**", "app/GradusiOS/**", "app/GradusMacTests/**", "app/GradusiOSTests/**", "app/GradusMacUITests/**", "app/GradusiOSUITests/**", "gradus/**", "tests/**", "TESTING.md"]
gate_test: app/test-gate.sh
threshold: 3
rationale: Every new behavior has a test at the lowest layer that proves it; new SwiftUI appearance has
  snapshot coverage, new interactive workflows have XCUITest/XCUIAutomation coverage, and shared
  producer/consumer behavior has tests on both sides. Tests must be wired into the runner and gate.
  Silent-zero execution is a discriminated failure: each counted gate leg must report at least its
  declared minimum number of tests, and a successful command with no recognized count is not proof.
  Manual-only verification is an explicit exception for physical-device, Apple-account, push-delivery,
  or other automation boundaries and must be recorded with exact steps and a follow-up.

### INV-12 — iPhone and iPad show the same information and ship in the same release
area: ["app/GradusiOS/**", "app/GradusiOSTests/**", "app/GradusiOSUITests/**", "app/test-gate.sh", "CHANGELOG.md"]
gate_test: app/test-gate.sh
threshold: 3
rationale: GradusiOS is one artifact with one version, so a size class is a rendering detail and never
  a feature boundary. The two layouts may differ in density detail — column count, and whether a
  window row carries its reset time — but never in *which* providers or windows are shown, and never
  in whether a workflow exists at all. A change to one size class ships with the other in the same
  release; there is no iPad-only or iPhone-only release. Violated once, 2026-08-05: the iPad gained a
  dense every-window layout in 1.5.0 while the iPhone kept a ranked list showing one window per
  provider behind selection badges, so the same account read as healthy on the phone and not on the
  tablet, and the release notes asked testers to "confirm the iPhone layout is unchanged" — documenting
  the divergence as though it were a decision. Both destinations must be exercised by the gate:
  size-class-gated coverage that runs on only one destination is how this divergence stays invisible.
