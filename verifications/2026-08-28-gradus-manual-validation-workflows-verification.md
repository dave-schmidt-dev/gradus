# Gradus validation-workflow manual conversion — independent verification

Date: 2026-08-28
Scope: `app/allocate_identity.py`, `app/test_allocate_identity.py` — uncommitted diff adding
`convert_validation_workflow_to_manual` and its `--convert-validation-workflow-to-manual` CLI mode.

## Requirements Check

Contract: allow only the two fixed validation workflow names belonging to the supplied product;
prove the exact current automatic main-branch condition and absence of every other trigger;
atomically PATCH `branchStartCondition` null, the same exact main source as
`manualBranchStartCondition`, and `isEnabled` false; accept the exact already-manual-and-disabled
state idempotently; reject malformed or unproven pre/post states.

- **Allowlist + product membership.** `convert_validation_workflow_to_manual`
  (`app/allocate_identity.py:870-921`) fetches `workflows = list_product_workflow_metadata(client,
  product_id)` (product-scoped URL, `:469`), requires the caller's `workflow_id` to appear in that
  list (`validation-workflow-not-in-product`), then requires `name in VALIDATION_WORKFLOW_NAMES`
  (`validation-workflow-name-not-allowed`, `:42`). This mirrors the pre-existing
  `start_validation_build` gate exactly.
- **Double-sourced name.** The full-attribute detail read in `_validation_workflow_conditions`
  (`:829-850`) re-checks `attributes.get("name") == expected_name` against the *same* name proven
  from the list call, so a workflow-ID collision or a name change between the two GETs is caught
  as `validation-workflow-condition-response-invalid` rather than silently trusted.
- **Proving the exact automatic state.** `_MAIN_BRANCH_SOURCE` (`:43-46`) is the single fixed
  main-branch source literal. `_has_exact_main_source` (`:853-856`) requires the condition to be a
  `Mapping` whose `dict(...)` is *exactly* `{"source": _MAIN_BRANCH_SOURCE}` — no extra keys
  tolerated. "Automatic" requires `branchStartCondition` to equal that literal AND
  `manualBranchStartCondition is None` (`:894-897`).
- **Proving absence of every other trigger.** `_WORKFLOW_START_CONDITION_KEYS` (`:47-56`) lists
  all seven ASC start-condition attributes; `_validation_workflow_conditions` rejects the response
  if any key is missing (`:847`). `convert_validation_workflow_to_manual` then requires the five
  *other* keys (`tagStartCondition`, `pullRequestStartCondition`, `scheduledStartCondition`,
  `manualTagStartCondition`, `manualPullRequestStartCondition`) to all be `None`
  (`:890-892`) before even computing the automatic/manual booleans — this guard runs
  unconditionally, so it also gates the idempotent short-circuit path, not just the mutating path.
- **Idempotent accept of the exact already-converted state.** `manual` requires
  `branchStartCondition is None` AND `manualBranchStartCondition` exactly the fixed main source
  (`:898-900`); combined with `isEnabled is False`, the function returns the fixed receipt with
  zero mutating calls (`:901-902`; test asserts `client.methods == ["GET", "GET"]`, no PATCH —
  `app/test_allocate_identity.py:816-830`).
- **Reject malformed/unproven states.** Any state that is neither exactly-automatic nor
  exactly-manual-and-disabled falls through to `if not automatic: raise
  validation-workflow-start-condition-mismatch` (`:903-904`) — covering wrong branch pattern, any
  of the five other triggers present, manual condition already set but still enabled, and both
  automatic+manual conditions present simultaneously (traced by hand; see Clean-Room section).
- **Atomic PATCH, nothing else touched.** The PATCH body (`:905-916`) sets exactly
  `branchStartCondition: null`, `manualBranchStartCondition: {"source": _MAIN_BRANCH_SOURCE}`,
  `isEnabled: false` — no other attribute keys included, so ASC's partial-update semantics leave
  every other field alone. Issued with `idempotent=False` (`:915`), matching the existing
  `set_workflow_enabled` (`:1132`) and workflow-creation (`:732`) convention for non-retryable
  mutating PATCH/POST calls in this file.
- **Post-state proof.** After the PATCH, the response is re-validated end to end
  (`:917-930`): type/id match, `name` unchanged, `isEnabled is False` exactly,
  all seven condition keys present, `branchStartCondition is None`,
  `manualBranchStartCondition` exactly the fixed main source, and all five other-condition keys
  still `None` — any deviation raises `validation-workflow-conversion-response-invalid` and the
  fixed receipt is only returned once every one of these holds.

All "Done when" elements are present and match the stated contract. No response field beyond the
fixed receipt (`workflowId`, `name`, `isEnabled: "false"`, `startCondition: "manual-main"`) is ever
printed or returned.

**Verdict: PASS.**

## Test Execution

Ran via a validation-runner subagent (blocked from running `python3`/`pytest` directly in this
session by sandbox tool-approval policy):

- `app/test_allocate_identity.py -k convert_validation`: **23 passed**, 0 failed.
- Full `app/test_allocate_identity.py` suite: **79 passed**, 0 failed — no regressions in the
  pre-existing 56 tests.

Test coverage traced against the contract: both allowlisted names (parametrized), wrong workflow
ID, disallowed name, non-main branch pattern, each of the five "other trigger" keys individually
present (7 parametrized rejection cases, all asserting no PATCH issued), two shapes of malformed
detail-read response, the idempotent already-converted-and-disabled path (no PATCH), six shapes of
unproven/malformed post-PATCH response (all raising before the receipt is returned), the exact
PATCH body, and CLI dispatch (success path + both missing-ID combinations).

## Clean-Room Verification

Independently hand-traced (not copied from the diff's own test list) whether any state reaches a
PATCH or a returned receipt without being provably one of the two contracted states:

- **Manual-but-enabled** (`manualBranchStartCondition` = fixed source, `branchStartCondition`
  null, `isEnabled: True`): `manual` is `True` but the idempotent-accept `and isEnabled is False`
  fails; `automatic` is `False` because `branchStartCondition` is not the fixed source ⇒ falls to
  `if not automatic: raise` — rejected. No test row exercises this exact combination directly
  (existing rows cover manual-present-but-not-idempotent via the post-PATCH-response table, not
  the pre-state table), confirmed correct by hand-trace of `:894-904`, not by an existing test —
  flagged below as a coverage gap, not a logic defect.
- **Both automatic and manual conditions present simultaneously**: `automatic` requires
  `manualBranchStartCondition is None` (false here) and `manual` requires
  `branchStartCondition is None` (false here) ⇒ both `False` ⇒ rejected. No dedicated test row;
  same category of gap as above.
- **Extra key inside the `source` object** (e.g. an `excludedPatterns` field ASC might add):
  `_has_exact_main_source` uses `dict(condition) == {"source": _MAIN_BRANCH_SOURCE}`,
  a full dict equality — any additional key anywhere in the structure fails the comparison and the
  state is treated as unproven ⇒ fail-closed by construction, not merely by test.
- **TOCTOU between the list call, the detail-read call, and the PATCH**: the function does not use
  an ETag/If-Match precondition on the PATCH — a concurrent external change between the detail
  read and the PATCH could theoretically be silently overwritten by the unconditional PATCH body.
  This is not a regression introduced by this diff: `set_workflow_enabled` and
  `create_internal_testflight_workflow` share the identical unconditioned-PATCH/POST pattern
  already in this file, and the post-PATCH response re-validation (`:917-930`) still guarantees
  the *returned receipt* only reflects a state that was actually proven server-side, so no false
  success can be reported even under a race. Non-blocking, pre-existing pattern.
- **CLI symmetry**: `--convert-validation-workflow-to-manual` requires both `--ci-product-id` and
  `--workflow-id` (`:1985-1990`), rejects the same four artifact-option flags as
  `--start-validation-build` (`:1992-2001`), and is included in the `--product`
  mutual-exclusion list (`:1779`). Byte-for-byte structural match to the adjacent
  `start_validation_build` block; confirmed by test
  `test_convert_validation_workflow_to_manual_cli_requires_both_ids`
  (`app/test_allocate_identity.py:1006-1017`).
- **No credential/secret exposure**: the receipt and every `IdentityAllocationError` string are
  static enum-shaped tags (e.g. `"validation-workflow-start-condition-mismatch"`), never raw ASC
  response bodies; `ASCError` handling in the CLI prints only `exc.outcome.error_class`
  (`:2066-2069`), matching the module's existing `_asc_error_label`-style convention. No live API
  calls were made during this review.

**Verdict: PASS**, no blocking findings.

## Findings

- **Non-blocking test-coverage gap**: no explicit test row for "manual condition already set but
  workflow still enabled" or "both automatic and manual conditions present." Both are correctly
  rejected by the current logic per hand-trace above, but a future refactor of the
  `automatic`/`manual` boolean logic (`:894-904`) would not be caught by the existing suite if it
  regressed only these two combinations. Recommend adding both rows to the existing
  `test_convert_validation_workflow_to_manual_rejects_pre_patch_state` parametrization in a
  follow-up change (not required to ship this diff — logic is already correct, only the test net
  has a hole).
- No other issues found. Source and tests were not modified by this review.

The two non-blocking coverage cases were added after review. The focused file
then passed 80 tests plus Ruff check/format.

## Verdict block

- `convert_validation_workflow_to_manual` (allowlisted, product-scoped, exact-state-proven manual
  conversion with atomic PATCH and idempotent accept): **PASS**
- `app/test_allocate_identity.py -k convert_validation`: 23 passed, 0 failed
- Full `app/test_allocate_identity.py`: 79 passed, 0 failed, no regressions
- No arbitrary-workflow, cross-product, unproven-pre-state, or unproven-post-state path found
- PATCH body touches only `branchStartCondition`, `manualBranchStartCondition`, `isEnabled`;
  response re-validation proves the exact post-state before any receipt is returned
- One non-blocking test-coverage gap noted (two logically-correct-but-untested rejection
  combinations); no blocking findings
- No live API calls made; no files edited by this verification
