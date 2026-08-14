# Independent Verification — Internal-TestFlight Candidate Migration

- **Plan**: `.plans/gradus/internal-testflight-candidate-migration-2026-08-09.md` (Tasks 1.1–4.2)
- **Verifier**: independent cross-model pass, 2026-08-09
- **Scope**: local hermetic evidence only. No BWS consumer, ASC endpoint, upload, profile operation, tester/group mutation, or CloudKit action was invoked. No source file was edited. No commit was made. Phase 5 was not executed.

## Verdict

**NOT ACCEPTED**, on two independent grounds.

**First: the tree was under concurrent edit throughout this pass, so "completed" is not a state the work is currently in.** `app/archive-upload-ios.sh` changed three times while I was verifying it (`bc0cc6a3` → `515cc259` → `ce028fa2`), the last edit landing 24 seconds before a timestamp check. `test-archive-upload-ios.sh` also changed mid-pass (`3cc0d3ad` → `cd498ba3`). Line numbers shifted under two of my own tool calls a minute apart. Four findings from my first read were already obsolete by the time I re-checked them and have been withdrawn below. A verifier cannot certify a moving tree; every citation here is pinned to the manifest at the end of this document.

**Second: three defects survive at the pinned digests**, one of them fatal to every normal run of the upload path.

---

## Pinned snapshot

All findings and line citations below were re-confirmed against these exact bytes. Any file edited after this manifest is unverified.

| File | SHA-256 (16) |
|---|---|
| `app/archive-upload-ios.sh` | `ce028fa2b1af684e` |
| `app/testflight-assign.py` | `92a84c3ded83c489` |
| `app/release_candidate/ledger.py` | `ccf54f8c5416d5f6` |
| `app/release_candidate/validation.py` | `120ec11160f6cdc1` |
| `app/release_candidate/version_policy.py` | `8fac6cda960a5320` |
| `app/release_candidate/reconcile.py` | `7118af9fd2d35f1d` |
| `app/release_candidate/walkthrough.py` | `e12f9912dcc0c925` |
| `app/_asc_api.py` | `36bc80c7a1674f50` |
| `app/next-ios-build-number.py` | `6a01815488c5a74b` |
| `app/test-gate.sh` | `e767817d25dbb109` |
| `app/test-gate-selfcheck.sh` | `385a0f23bb20f7d7` |
| `app/test-archive-upload-ios.sh` | `cd498ba3c822fb1c` |

### Withdrawn during the pass

Fixed in the working tree between my first read and my re-check. Recorded so the record is honest about what changed, not to claim credit for the fixes:

- Ledger digest/identity rebinding — `_IMMUTABLE_FIELDS` (`ledger.py:47-49`) is now enforced at `ledger.py:260-262`; re-probe rejected all three fields.
- Walkthrough bound by existence only — `validation.py:115-130` now compares a stored `walkthroughSha256` against the file bytes.
- No candidate-ledger writer / no `uploading` producer — `archive-upload-ios.sh:225-241` and `:566` now write evidence and call `CandidateLedger.prepare`; `:595`, `:612`, `:616` transition through `uploading` → `uploaded_unassigned`.
- Test suite ratifying rebinding — `test_release_candidate.py:42` is now `test_transition_cannot_rewrite_immutable_candidate_tuple`.
- `AttributeError` on an empty supersedes reason — `version_policy.py:80-86` was rewritten while this report was being written; it now raises `VersionPolicyError: supersedes/release-blocking reason must be non-empty text`. Re-probed after the edit.
- Loose walkthrough version grammar — `walkthrough.py:29` is now strict three-part semver (`^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$`), matching the validator.

---

## Task 1.1 — Candidate ledger and state machine

### Requirements Check

| Done-when | Status | Evidence |
|---|---|---|
| Forward-only state machine | Met | `ledger.py:53` — `_TRANSITIONS` is a closed map; no edge returns to an earlier state. Invalid transitions raise at `:243-244`. |
| Atomic, 0600 persistence | Met | `ledger.py:204-211` — `mkstemp` → `fchmod(0o600)` → `fsync` → `os.replace`. |
| Candidate tuple is immutable after binding | Met | `ledger.py:47-49` + `:260-262`. Probed directly: rebinding `candidate_id`, `source_sha256`, or `artifact_sha256` through `transition()` raises `CandidateError: candidate tuple field is immutable`. |
| Records reject secret-shaped material | Met | Key and value regexes reject credential-shaped entries at construction. |
| No replacement build while an upload is unassigned | Met | `ledger.py:329-333`. |
| Metadata extends rather than replaces | Met | `ledger.py:263-264`, `:270-283`. |

### Clean-Room Verification

No findings. The alias normalisation at `ledger.py:245-251` maps snake_case keyword arguments onto the camelCase persisted names *before* the immutability intersection is taken, so the guard cannot be bypassed by choosing the other spelling — the failure mode I probed for and did not find.

### Blind-Spot Discovery

`transition()` still merges `**updates` over the record (`:265`). Immutability covers the six candidate-tuple fields; any field added later is mutable by default unless someone remembers to extend `_IMMUTABLE_FIELDS`. The safe shape is an explicit allowlist of *mutable* fields. Observation, not a defect at these digests.

---

## Task 1.2 — Candidate-bound validation and version policy

### Requirements Check

| Done-when | Status | Evidence |
|---|---|---|
| Strict semver increase required | Met | `version_policy.py:79-82`. |
| Paginated ASC history, numeric build comparison | Met | `version_policy.py:40-70`. |
| Reused build numbers rejected | Met | `next-ios-build-number.py:45-48`. |
| Digest-bound evidence, mismatch rejected | Met | `validation.py:103-130` — source, project, IPA, producer, and walkthrough digests all compared against file bytes. |
| Supersedes / release-blocking escape requires a non-empty reason | Met (fixed mid-pass) | `version_policy.py:80-86`. |

### Clean-Room Verification

No findings survive at the pinned digest. Both defects I found here were fixed while this report was being written and are recorded under *Withdrawn during the pass*: an `AttributeError` in place of `VersionPolicyError` on an empty override reason, and a walkthrough version grammar looser than the validator's. I re-probed both after the edits landed — the empty reason now raises `VersionPolicyError`, and the two grammars now agree.

### Blind-Spot Discovery

The override path is now type-correct but still unaudited: `require_new_marketing_version` accepts any non-whitespace string as justification for shipping a non-increasing marketing version, and nothing records that reason into the candidate ledger or the receipt. The escape hatch is guarded against accident, not against a one-character reason that leaves no trace in the release evidence.

---

## Task 1.3 — Release contract and invariant ownership

### Requirements Check

| Done-when | Status | Evidence |
|---|---|---|
| INV-9 area extended to candidate modules | Met | `INVARIANTS.md` diff names `release_candidate/`, `_asc_api.py`, `testflight-assign.py`. |
| App Store submission excluded in release docs | Met | Stated in `README.md`, `RELEASE_CHECKLIST.md`, `VERSIONING.md`, `TESTING.md`. |
| `.release-state/` ignored | Met | `.gitignore` diff. |
| Agent `bws-run` recipe removed | Met | `README.md` diff; the surviving recipe uses the `bws-secret-exec` broker, consistent with policy. |
| Documented attended commands are runnable | Partly met | See below. |

### Clean-Room Verification

The paths documented at `README.md:427-428` and `RELEASE_CHECKLIST.md:113-114` now have a real producer — `archive-upload-ios.sh:443-444` defaults to exactly `.release-state/candidate.json` and `.release-state/candidate-evidence.json`, and `:225-241` writes the evidence file atomically at 0600. The documentation and the pipeline agree.

They are still not runnable end to end, for reasons owned by other tasks: the upload script aborts before reaching either write (Finding 2.1-A), and even with a ledger present the evidence ages out before assignment can succeed (Finding 3.3-B).

### Blind-Spot Discovery

No document records the interaction between the 600-second producer-evidence freshness window and the 1800-second processing wait. A release owner following `RELEASE_CHECKLIST.md` in order hits an unexplained rejection with no documented remedy — the failure looks like bad evidence rather than an arithmetic impossibility.

---

## Task 2.1 — Source-isolated, evidence-bound archive preparation

### Requirements Check

| Done-when | Status | Evidence |
|---|---|---|
| Build never edits the checked-out project | Met | `archive-upload-ios.sh:120-127` copies the project root into a workspace; `:457` onward operates on `$candidate_root/app`. The checked-out `project.yml` is never the bump target. |
| Candidate not already in flight | Met | `:451` — `assert_candidate_not_in_flight` refuses to start over an unassigned upload. |
| Producer evidence checked at both irreversible boundaries | **Not met** | See 2.1-B. |
| Injected failures leave the baseline digest unchanged | **Unverified by the suite** | See Blind-Spot. |
| The script runs to completion in the normal case | **Not met — blocker** | See 2.1-A. |

### Clean-Room Verification

**Finding 2.1-A (Blocker).** `archive-upload-ios.sh:133-139`:

```bash
failure_hook() {
  local point="$1"
  [[ "${GRADUS_INJECT_FAILURE:-}" == "$point" ]] && {
    echo "FAIL: injected failure after $point" >&2
    return 97
  }
}
```

In the normal case the `[[ ]]` test is false, the `&&` list is the function's last command, and the function returns 1. The script runs under `set -euo pipefail` (`:24`) and calls `failure_hook allocation` bare at `:458`. Probed against the pinned bytes by extracting the real function and sourcing it under the same shell options: exit 1, and a probe line placed immediately after the call never executes.

Every run therefore aborts at `:458` — after `create_candidate_workspace`'s full `cp -R`, before build allocation, archive, signing, upload, and every ledger write. This **fails closed**: no Apple state is touched, no wrong artifact ships, and the candidate ledger is never created. It does not corrupt anything; it makes the upload path dead. The remaining six hook call sites (`:479`, `:492`, `:532`, `:548`, `:595`, `:620`) carry the same defect, including one *after* a successful `altool` upload, which would report failure on a build that actually shipped.

The fix is one line — `return 0` at the end of the function, or `|| true` at each call site. Described, not applied, per scope.

**Finding 2.1-B (High).** The producer-evidence boundary is structurally inert. `validate_producer_evidence_boundary` (`:362-380`) guards each comparison twice:

```bash
if [[ -n "$expected_source" ]]; then
  actual_source="$(read_evidence_field sourceRevision "$evidence_path" 2>/dev/null || true)"
  [[ -z "$actual_source" || "$actual_source" == "$expected_source" ]] || { ... }
fi
```

Both call sites (`:455`, `:556`) pass `""` as `expected_source`, so the source check never runs at all. The project check runs but treats an absent field as a pass — and `rg` over `app/GradusMac/PublishCoordinator.swift:19-21` shows the producer emits only `producerBuildNumber`, `cloudKitEnvironment`, and `publishedAt`. Neither compared field is ever written. The Done-when criterion "revision/digest-mismatched producer evidence returns non-zero at both irreversible boundaries" is satisfiable only by hand-authored fixtures, never by real producer output.

**Finding 2.1-C (Medium).** The candidate workspace is never cleaned up. The only `trap` in the script is `:602` for `KEY_DIR`; `create_candidate_workspace` (`:120-122`) registers nothing. Every invocation leaks a full project copy, compounded by 2.1-A aborting immediately after the copy. With `GRADUS_CANDIDATE_WORKSPACE` set to a reused directory, a second run's `cp -R "$project_root" "$workspace/project"` copies *into* the existing directory rather than replacing it, producing a nested `project/project` tree.

### Blind-Spot Discovery

`test-archive-upload-ios.sh:271` verifies the injection contract by grepping the script text:

```bash
grep -Eq 'failure_hook (after-allocation|archive|signing|packaging|receipt-persistence|assignment)' "$UPLOAD_SCRIPT" || {
```

It never sets `GRADUS_INJECT_FAILURE` and never executes an injected failure. The alternation also excludes `allocation` — the one hook whose call site kills every run. A criterion checked as text rather than as behaviour is why a fatal defect passed the phase gate green.

---

## Task 2.2 — Build allocation, signing, and credential ordering

### Requirements Check

| Done-when | Status | Evidence |
|---|---|---|
| Credentials checked before irreversible work | Met (static read) | The credential guard precedes allocation, archive, and upload. |
| Entitlements and signing identity verified before archive | Met (static read) | Entitlement and identity checks precede `xcodebuild archive`. |
| Signing key material never lingers | Met | `:602` — `mktemp -d` + `umask 077` + `trap 'rm -rf "$KEY_DIR"' EXIT`, so the `.p8` is removed on success and failure alike. |
| Allocation is monotonic against paginated history | Partly met | See below. |

### Clean-Room Verification

Everything in this task sits downstream of `failure_hook allocation` at `:458`, so **none of it is reachable at runtime today**. The ordering above is verified by reading only. I did not observe it execute and am not asserting it was exercised.

**Finding 2.2-A (Medium).** `next-ios-build-number.py:45-48` rejects any build value appearing more than once anywhere in the fetched history:

```python
if value < 1 or item["id"] in seen_ids or value in seen_builds:
    raise BuildHistoryError("duplicate or invalid ASC build entry")
```

App Store Connect permits the same build number under different marketing versions. A legitimate history containing `1.2.0 (7)` and `1.3.0 (7)` makes allocation refuse to run. This fails closed rather than allocating a colliding number, so it is an availability defect, not a safety one — but it will fire on a real account eventually, and the failure message will point at Apple rather than at this rule.

### Blind-Spot Discovery

No test drives `archive-upload-ios.sh` end to end against a stubbed `xcodebuild`/`altool`. Every assertion in the upload suite is a text grep or an isolated-helper check, which is how 2.1-A, 2.1-B, and 2.1-C all survived a green gate at once.

---

## Task 3.1 — Renewable, redacted ASC client

### Requirements Check

| Done-when | Status | Evidence |
|---|---|---|
| Output allowlisted, never raw | Met | `_asc_api.py` — `ASCOutcome.receipt_fields` is an explicit allowlist enforced at construction, so a caller cannot widen it downstream. |
| Request identifiers redacted | Met | `req_<sha256[:12]>`; no raw path, token, or key material reaches a log line. |
| Token renewed during bounded polling | Met | `TokenProvider` renews at `now >= expires_at - renewal_margin_seconds`; covered by `test_asc_api.py`. |
| Retries only where safe | Met | `retry_allowed = method == "GET" if idempotent is None else idempotent` — default-deny for anything not an explicit GET, with retryable/permanent classification separated. |
| Forbidden mutations unreachable | Met | No tester, user, profile, or delete route exists in the client. |

### Clean-Room Verification

No findings. This is the strongest module in the change. The redaction boundary is enforced where the object is built rather than where it is printed, and the retry policy is default-deny rather than default-allow — both are the correct direction for the failure mode each guards.

### Blind-Spot Discovery

The allowlist protects receipts; exception paths are not inside it. A transport-level error string from the underlying HTTP layer surfaces as-is. Nothing observed carries credential material today — an unguarded seam, not a defect.

---

## Task 3.2 — Assignment-only TestFlight boundary

### Requirements Check

| Done-when | Status | Evidence |
|---|---|---|
| Exactly one confirmed internal group bound | Met | `testflight-assign.py:116-119` + `find_exact_internal_group`. Zero, multiple, renamed, and mismatched groups all raise before any POST (`testflight-setup-tests.py:43-50`). |
| Missing Compliance is a human gate | Met | `testflight-assign.py:57-58`. |
| Tester/group/profile mutation unreachable | Met | No `betaTesters`, `/users`, `/profiles`, `DELETE`, `appStoreVersions`, `betaAppReviewSubmission`, or `submitForReview` route exists anywhere in `app/`. |
| Assignment requires candidate, evidence, and journal paths | Met | `testflight-assign.py:195-204` and the CLI argument set. |
| Assignment waits for the exact build to be VALID | **Not met — blocker** | See below. |

### Clean-Room Verification

**Finding 3.2-A (Blocker).** `testflight-assign.py:122-139`:

```python
while clock() <= deadline:
    ...
    if exact:
        selected = exact[0]
        state = classify_build(selected, build)
        if state == "VALID":
            break
    if clock() >= deadline:
        raise AssignmentError("timed out waiting for exact build processing")
    sleep(interval)
if selected is None or selected.get("id") is None:
    raise AssignmentError("exact build was not indexed before timeout")
```

The mid-loop raise fires only when the deadline has already passed *at that instant*. If `sleep(interval)` carries the clock past the deadline, the `while` condition simply goes false and control leaves the loop with `selected` holding a **`PROCESSING`** build. `selected` is not `None`, so the guard at `:138-139` passes and execution continues to the assignment POST at `:151`.

Reproduced against the pinned bytes with a fake clock (`timeout=45`, `interval=30`, build permanently `PROCESSING`, clock ticks `0, 10, 20, 50`): no exception, a real `POST /betaGroups/group-1/relationships/builds` issued, and the returned receipt read `processing_state: 'VALID'`.

That literal is the compounding half. `:153` hardcodes the field:

```python
return {..., "processing_state": "VALID", "assigned": already or permit_assignment, ...}
```

and `build_availability_metadata` (`:62-71`) returns only `uploadedDate` and `expirationDate`, so the build's real `processingState` reaches the receipt by no path at all. The receipt asserts a fact it never observed, and it is the durable record.

**Finding 3.2-B (Low).** `"assigned": already or permit_assignment` reports the caller's *intent*, not the POST outcome. The ASC client raises on error responses so this is accurate in practice today, but the field is not evidence of the mutation it names.

### Blind-Spot Discovery

The coverage is inverted relative to production likelihood. `testflight-setup-tests.py:62-67` drives the timeout with `clock=lambda: 2, timeout=0, interval=0` — a constant clock that guarantees the *mid-loop* raise. In production (`POLL_TIMEOUT_SECONDS = 30 * 60`, `POLL_INTERVAL_SECONDS = 30`, plus per-request latency) the loop condition is far more likely to be the branch that goes false. The tested path is the unlikely one; the untested path is the expected one. My first probe used a tick sequence that reproduced the *tested* branch and appeared to clear the code — the defect only surfaced when the clock advanced the way a real 30-second sleep does.

`testflight-setup-tests.py:72` also lists `'"POST", " /betaGroups'` among forbidden source markers. The space after the comma cannot match the real call at `:151` (`client.request("POST", f"/betaGroups/...")`) regardless of what the file contains. That assertion is vacuous — it would pass against a file doing exactly what it forbids.

---

## Task 3.3 — Restart and remote-state reconciliation

### Requirements Check

| Done-when | Status | Evidence |
|---|---|---|
| Reconcile before and after mutation | Met | `testflight-assign.py:156-193`; `reconcile.py:175-200`. |
| Receipt journal atomic and idempotency-keyed | Met | `reconcile.py:71-113` (same temp-file-plus-`os.replace` discipline as the ledger), keyed by `candidate_idempotency_key` (`:115`). |
| Receipt fields allowlisted | Met | `reconcile.py:18` `FINAL_RECEIPT_FIELDS`, with exact-set equality enforced at `:85` and `:90`. |
| An uncertain upload is never re-uploaded | Met | The journal refuses a second upload while an in-flight entry exists; `archive-upload-ios.sh:612-617` preserves the candidate and requires reconciliation instead of retrying. |
| Remote state validated before advancing | **Not met** | See below. |

### Clean-Room Verification

**Finding 3.3-A (High).** `reconcile.py:203` requires `remote.processing_state.upper() != "VALID"` to reject. In isolation the check is right. In the assembled system it is vacuous: `testflight-assign.py:153` is the sole producer of that field and it is a string literal. The check can never fail — and via 3.2-A it will actively certify a `PROCESSING` build as VALID and write that into the durable receipt journal. The reconciler is not wrong; it is fed a constant.

**Finding 3.3-B (Blocker).** The freshness window makes attended assignment arithmetically unreachable. `validation.py:101` defaults `max_producer_age = timedelta(seconds=600)` and enforces it at `:120`; `testflight-assign.py:195-204` calls `CandidateEvidence.from_mapping(data)` with no override. The processing wait is `POLL_TIMEOUT_SECONDS = 30 * 60` (`:20`). Confirmed directly: evidence stamped 20 minutes earlier is refused.

There is no correct human workaround. Waiting for processing guarantees the evidence ages out; regenerating the evidence to pass means restamping `publishedAt` to a time the publish did not occur, falsifying the artifact the check exists to trust. The window and the wait have to be reconciled in code — either a longer window for the assignment step or an evidence age measured at preparation rather than at assignment.

### Blind-Spot Discovery

`test_release_reconcile.py:29-31` builds `CandidateEvidence` through the constructor rather than `from_mapping`, bypassing freshness validation entirely, and feeds `reconcile_candidate` a hand-built `RemoteCandidateState` rather than the output of `assign_candidate`. Both 3.3-A and 3.3-B live exactly in the seams the unit tests stub out — the suite is green because it never connects the two modules it is reconciling.

---

## Task 4.1 — Canonical gate wiring

### Requirements Check

| Done-when | Status | Evidence |
|---|---|---|
| All candidate suites declared and counted | Met | `test-gate.sh:11-51` — `EXPECTED_COUNTING_LEG_COUNT=11` with four parallel arrays (names, reporters, floors `2 2 2 2 2 6 5 5 5 5 3`, sources). |
| Declarations cross-checked | Met | `test-gate.sh:56-70` — all four arrays must agree in length and every floor must be a positive integer. |
| Counts parsed, not assumed | Met | `assert_counting_leg` tees each leg and extracts the reporter's own count for `swift-testing`, `pytest`, and `xctest`; zero, absent, and below-floor counts all fail. |
| A deleted leg fails the gate | Met | `test-gate-selfcheck.sh` asserts declaration consistency, source existence, a counted invocation per source, all three reporter forms, and the deleted-leg failure. |
| Live progress | Met | Per-leg output is streamed, not buffered to the end. |
| Simulator cleanup | Met | Shutdown trap. |

### Clean-Room Verification

No defect found. The four-array declaration with a length cross-check, per-reporter count extraction, minimum floors, and a self-check that deletes a leg to prove the gate notices is a stronger construction than the code it guards.

Legs I executed locally against current bytes, all green:

- 6 candidate pytest suites — **36 passed**
- root `uv run pytest -q` — 562 passed, 219 subtests
- `swift test --package-path GradusKit` — 64 tests, exit 0
- `test-gate-selfcheck.sh` — exit 0
- `test-archive-upload-ios.sh` — exit 0 (its `FAIL:`-shaped lines are intentional negative-case assertions)
- uncounted hermetic legs `test-notary-scripts.sh`, `test-install-mac-local.sh`, `test-install-credential-bridge.sh` — all PASS

Legs I did **not** execute: the three UI legs `GradusMac`, `GradusiOS-iPhone`, `GradusiOS-iPad`. The reported host blocker is corroborated — `ioreg -n Root -d1 -a` shows `CGSSessionScreenIsLocked = true` at verification time. **That is corroboration of the blocker, not a pass.** All three UI legs remain unverified and nothing here should be read otherwise.

### Blind-Spot Discovery

Counted-ness proves a suite ran and met a volume floor; it cannot prove the assertions inside are meaningful. Task 3.2's unmatchable forbidden-marker string and Task 2.1's grep-for-`failure_hook` both sit inside legs that count green. Every defect in this report survived the floors.

---

## Task 4.2 — Candidate-current walkthrough generator and documentation

### Requirements Check

| Done-when | Status | Evidence |
|---|---|---|
| Generator is candidate-bound | Met | `walkthrough.py:81` — `CandidateTuple` stamps candidate ID, source/project/artifact digests, build, and marketing version into the output. |
| Fails closed without a candidate | Met | Executed `python3 -m release_candidate.walkthrough` from `app/` with no ledger: `walkthrough: candidate ledger is missing`, exit 1. |
| Walkthrough digest bound to validation | Met | `validation.py:115-130` — the generated file's SHA-256 is compared against the recorded `walkthroughSha256`. |
| Manifest structurally validated | Met | `walkthrough.py:182` — required sections present, no duplicate IDs, every control's role and state reference resolves. |
| Coverage complete for the shipping app | **Not met** | See below. |

### Clean-Room Verification

**Finding 4.2-A (High).** `default_manifest()` (`walkthrough.py:127-171`) is a hardcoded inventory and `validate_manifest` checks it only against *itself*. Nothing compares it to the app. Against source, Mac coverage is incomplete:

- `mac-menu` omits the **Launch at Login** toggle (`GradusMac/MenuContentView.swift:271`) and the per-provider dropdown rows (`MenuContentView.swift:258`).
- `mac-settings` declares only `mac-sort` and `mac-show-exhausted`, omitting **Enable iCloud Sync** (`GradusMac/MacSettingsView.swift:35`), **Launch at Login** (`:44`), the **Warning Threshold** slider (`:66`), and the **About** section (`:78`).

iOS is closer but not complete: the Settings **close** control (`GradusiOS/SettingsView.swift:41`), the conditional **Connected Computer** section (`:58`), and the **About** section (`:200`) are absent from `ios-settings`.

The global policy requires "every reachable screen and interactive control." A manifest validated only for internal consistency will keep reporting complete coverage as the UI grows — the drift is silent by construction.

Correctly excluded, and worth recording: sample-data mode is Debug-gated (`GradusiOSApp.swift:36`, `isDebugBuild && arguments.contains(launchArgument)`), so its banner and dashboard are unreachable in a Release candidate and rightly absent.

### Blind-Spot Discovery

The walkthrough is now digest-bound (`validation.py:128-130`), which closes the staleness hole. What remains open is the other direction: nothing checks that the manifest the generator used describes the app the candidate was built from. The document is provably *the one that was generated*; it is not provably *current*.

App Store submission and external testing are excluded as specified — `rg` finds no `appStoreVersions`, `betaAppReviewSubmission`, `submitForReview`, or `betaTesters` route in `app/`.

---

## Findings summary

### Blockers

1. **`archive-upload-ios.sh:133-139` + `:458`** — `failure_hook` returns 1 in every non-injected run; under `set -euo pipefail` the script aborts before allocation. Empirically reproduced at digest `ce028fa2`. Fails closed, no Apple state touched, but the upload path is dead and six further call sites carry the same defect — including one after a successful upload. One-line fix.
2. **`testflight-assign.py:122-153`** — a still-`PROCESSING` build can be POSTed to the internal group, and the receipt hardcodes `processing_state: "VALID"`. Empirically reproduced at digest `92a84c3d`. Currently masked by blockers 1 and 3; it goes live the moment they are fixed.
3. **600s evidence freshness vs 1800s processing wait** (`validation.py:101/:120`, `testflight-assign.py:20/:195-204`) — attended assignment is arithmetically unreachable, with no honest human workaround.

### High

- `archive-upload-ios.sh:362-380` + `:455`/`:556` — producer-evidence source/project comparison is structurally unreachable; `expected_source` is passed empty and the producer never emits either field.
- `reconcile.py:203` — remote processing check is vacuous because its sole feed is a literal.
- `walkthrough.py:127-171` — manifest validated only against itself; six Mac controls and three iOS elements unlisted.

### Medium / Low

`archive-upload-ios.sh:120-122` (workspace never cleaned; reused workspace nests) · `next-ios-build-number.py:45-48` (rejects ASC-legal cross-version duplicate builds) · `testflight-assign.py:153` (`assigned` reports intent, not outcome).

### What holds

Task 1.1 (ledger and state machine), Task 3.1 (redacted renewable ASC client), and Task 4.1 (gate wiring) are sound; I found no defect in any of them. Source isolation, atomic persistence with 0600, candidate-tuple immutability, the forward-only transition map, exact-group binding, Missing Compliance as a human gate, journal idempotency, signing-key shredding, and the App Store / external-tester exclusion are all correctly implemented.

### The pattern behind the blockers

Every blocker shares one shape: the acceptance criterion was checked as text rather than as behaviour. `failure_hook` was verified by grep — with `allocation` excluded from the alternation. The forbidden POST route was verified by a string that cannot match. The reconciler was verified against a hand-built input that never touches the code producing it. Fixing the three blockers matters less than closing that gap, because it is what allowed a green 11-leg gate to certify a pipeline that cannot run.

---

## Snapshot integrity

Digests were taken before the analysis, after it, and again after this report was drafted. Four files changed across those snapshots: `archive-upload-ios.sh` twice (`bc0cc6a3` → `515cc259` → `ce028fa2`), `test-archive-upload-ios.sh` once (`3cc0d3ad` → `cd498ba3`), and — during the drafting itself — `version_policy.py` (`6dd3e738` → `8fac6cda`) and `walkthrough.py` (`6129483c` → `e12f9912`), each of which fixed a defect this report had just recorded. All other files were byte-identical across every snapshot. Every finding above was re-confirmed against the final digests, and both surviving blockers were re-probed against those exact bytes.

Fixes are landing faster than a verification pass can complete. That is the finding behind the finding: this work is mid-implementation, not ready for a completion check.

**Re-verification is required against a frozen tree before any acceptance decision.** If work continued after `ce028fa2`, this document describes a state that no longer exists.

## Scope statement

No BWS consumer, App Store Connect endpoint, upload, profile operation, tester/group mutation, or CloudKit action was invoked. No source file was edited. No commit was made. Phase 5 remains human-owned and was not executed.
