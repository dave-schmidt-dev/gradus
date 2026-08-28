# Gradus `convert_validation_workflow_to_manual` live-condition conversion — verification

Date: 2026-08-28
Scope: uncommitted diff to `app/allocate_identity.py` and `app/test_allocate_identity.py` (`convert_validation_workflow_to_manual`, `_has_exact_live_automatic_condition`, and the two new fixed condition constants only). Source and tests were read-only for this review; nothing was edited.

## Contract recap

- **Gradus macOS UI Trial**: convertible only from `branchStartCondition: null` + exact `pullRequestStartCondition == {autoCancel:true, destination:{isAllMatch:true,patterns:[]}, filesAndFoldersRule:null, source:{isAllMatch:true,patterns:[]}}`.
- **Gradus iOS Snapshot Trial**: convertible only from exact `branchStartCondition == {autoCancel:false, filesAndFoldersRule:null, source:{isAllMatch:true,patterns:[]}}` + `pullRequestStartCondition: null`.
- Both pre-states require `isEnabled == false` and every other trigger key (`tagStartCondition`, `scheduledStartCondition`, `manualBranchStartCondition`, `manualTagStartCondition`, `manualPullRequestStartCondition`) `null`.
- PATCH must atomically null both `branchStartCondition` and `pullRequestStartCondition`, set the fixed `manualBranchStartCondition` (main-only source), and keep `isEnabled: false`.
- An already-manual-disabled workflow (exact fixed manual shape, both automatic keys null, all other triggers null) is idempotent — no PATCH.
- Cross-name shapes, variants (changed values or extra keys), mixed triggers (both automatic keys populated), and malformed pre/post states must all be rejected before/after the single PATCH.

## Code trace

`app/allocate_identity.py:902-990`.

- `_has_exact_live_automatic_condition(name, attributes)` gates on `isEnabled is False` and all five non-automatic trigger keys being `None`, then dispatches by `name`: macOS requires `branchStartCondition is None` and `pullRequestStartCondition == _MACOS_UI_TRIAL_PULL_REQUEST_CONDITION`; iOS requires the mirror image. Both constants (`allocate_identity.py:47-58`) are exact literal transcriptions of the contract's dicts — confirmed key-by-key against the task text.
- Because Python dict equality (`==`) requires identical key sets and values, any extra key, missing key, or changed value in the live condition fails the match — this is what rejects "variants/extras" without separate code.
- `convert_validation_workflow_to_manual` computes `manual` (branch/pullRequest both `None`, `manualBranchStartCondition` exactly the fixed main source, and the four remaining trigger keys `None` — all 7 `_WORKFLOW_START_CONDITION_KEYS` covered) and returns the idempotent receipt only when `manual and isEnabled is False`. This manual-shape check is identical for both workflow names, correctly reflecting that the manual target state doesn't depend on which trial it is.
- Otherwise it requires `_has_exact_live_automatic_condition(name, attributes)`, or raises `validation-workflow-start-condition-mismatch` before any mutating call.
- The PATCH body (`allocate_identity.py:963-968`) unconditionally nulls both `branchStartCondition` and `pullRequestStartCondition` in the same request body as setting `manualBranchStartCondition` and `isEnabled: false` — one PATCH, atomic per Apple's JSON:API semantics, regardless of which of the two automatic keys actually held data pre-patch.
- The post-patch check (`allocate_identity.py:976-989`) re-verifies `name`, `isEnabled is False`, both automatic keys `None`, the manual key exactly the fixed main source, and the four other trigger keys `None` — same 7-key coverage as the pre-state checks — raising `validation-workflow-conversion-response-invalid` on any mismatch (including a mocked malformed/successful-looking response).

No path returns a receipt or issues a PATCH without passing through both the pre-state gate and (for the mutating path) the post-state gate.

## Test coverage

New/changed tests (`app/test_allocate_identity.py`):

- `test_convert_validation_workflow_to_manual_uses_exact_patch` (parametrized both names) — now seeds from `_live_validation_conditions(name)` (the real per-name live shape) instead of a generic main-branch fixture, and asserts the PATCH body includes `pullRequestStartCondition: None` alongside the pre-existing fields.
- `test_convert_validation_workflow_to_manual_rejects_cross_name_live_shape` — macOS workflow record carrying the iOS live shape and vice versa; both rejected pre-PATCH.
- `test_convert_validation_workflow_to_manual_rejects_live_shape_variants` — per name, a changed boolean value and an injected extra key in the relevant condition dict; both rejected pre-PATCH.
- `test_convert_validation_workflow_to_manual_rejects_mixed_live_triggers` — per name, both automatic keys populated simultaneously (the other name's shape grafted onto the valid one); rejected pre-PATCH.
- `test_convert_validation_workflow_to_manual_rejects_unproven_patch_response` — pre-state switched to the real macOS live shape; malformed-response table unchanged and still exercises the post-patch gate.

Ran:
```
uv run pytest app/test_allocate_identity.py -k convert_validation_workflow_to_manual -q
```
→ **32 passed**, 0 failed.

```
uv run pytest app/test_allocate_identity.py -q
```
→ **97 passed**, 0 failed (no collateral breakage in the rest of the module).

## Non-blocking observations (not part of this diff, not required to fix)

- `test_convert_validation_workflow_to_manual_rejects_pre_patch_state` and `test_convert_validation_workflow_to_manual_is_idempotent_without_patch` are pre-existing tests this diff did not touch. The former's default fixture (`isEnabled=True`, `branchStartCondition=main-source`) is no longer a valid live shape for either name under the new contract, so several of its per-field overrides now get rejected for a different (compound) reason than each row's isolated intent — they still correctly assert rejection, just with reduced isolation. The latter only exercises the idempotent path for the macOS name, not iOS, though the code path is name-agnostic. Both are coverage-precision nits, not defects, and out of scope per "do not modify tests."

## Verdict

**PASS.** The revision correctly implements the exact per-name live pre-conditions, atomic dual-key nulling PATCH, fixed manual-main post-state, and idempotency, and rejects cross-name shapes, variants/extras, mixed triggers, and malformed pre/post states. No credentials or environment values were read or exposed during this review (all evidence is static code/test inspection plus a local pytest run against fixture data).
