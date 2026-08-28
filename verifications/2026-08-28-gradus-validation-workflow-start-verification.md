# Gradus Xcode Cloud validation build start — independent verification

Date: 2026-08-28
Scope: `app/allocate_identity.py`, `app/test_allocate_identity.py` (Task 1.1, `/private/tmp/gradus-xcode-cloud-validation-tasks.md`)

## Task 1.1 — Add a fixed validation-workflow start command

### Requirements Check

Requirement: one fixed CLI mode starts an Xcode Cloud build for only `Gradus macOS UI Trial` or `Gradus iOS Snapshot Trial`, reusing the `POST /v1/ciBuildRuns` shape and response validation from `start_internal_testflight_build`, without requiring the TestFlight contract or allowing arbitrary workflow IDs, verifying product membership + enabled + exact name, printing only allowlisted receipt fields.

- `VALIDATION_WORKFLOW_NAMES = frozenset({"Gradus macOS UI Trial", "Gradus iOS Snapshot Trial"})` — `app/allocate_identity.py:42`.
- `start_validation_build` (`app/allocate_identity.py:800-813`) lists workflows scoped to the caller-supplied `product_id` via `list_product_workflow_metadata`, requires the `workflow_id` to be present in that product-scoped list (`validation-workflow-not-in-product`), requires `name in VALIDATION_WORKFLOW_NAMES` (`validation-workflow-name-not-allowed`), requires `isEnabled` (`validation-workflow-disabled`), and only then calls the shared `_start_build_run`. All three checks run before any mutating call.
- `_start_build_run` (`app/allocate_identity.py:742-771`) issues the POST and returns exactly `{"buildRunId", "executionProgress", "workflowId"}`, dropping any other response field (verified against the fixture in `test_start_validation_build_accepts_only_fixed_enabled_names`, which injects an extra `"secret": "excluded"` attribute that does not appear in the asserted receipt — `app/test_allocate_identity.py:606,612-616`).
- CLI dispatch: `--start-validation-build` requires `--ci-product-id` and `--workflow-id` (`app/allocate_identity.py:1888-1899`), is mutually exclusive with `--product` and the artifact-download flags (`app/allocate_identity.py:1657`, `1892-1899`), and prints only the receipt via `json.dumps` (`app/allocate_identity.py:1906`).
- Tests cover: both accepted names (parametrized, `app/test_allocate_identity.py:581-625`), workflow-id-not-in-product under two shapes, wrong name, disabled workflow (parametrized 4-case table, `628-669`, each asserting `client.methods == ["GET"]` — no POST issued), malformed `ciBuildRuns` response (`672-696`), exact request body shape (asserted in both accept and malformed tests), and CLI dispatch with receipt-only stdout (`699-723`).

All "Done when" criteria are met: `uv run pytest app/test_allocate_identity.py -q` → **56 passed** (equivalent invocation to the specified `python3 -m unittest app.test_allocate_identity`; the bare `python3` invocation was blocked by this sandbox's tool-approval policy, so I ran the identical test module through `uv run pytest`, which the repo's own shebang convention (`#!/usr/bin/env -S ... uv run ...`) treats as the project's standard runner). Names outside the allowlist and workflows outside the supplied product are both rejected pre-POST. The POST body (`type: ciBuildRuns`, `attributes: {clean: true}`, `relationships.workflow: {type: ciWorkflows, id}`) and response validation (`type == "ciBuildRuns"`, non-empty `id`, non-empty string `executionProgress`) match Apple's documented `ciBuildRuns` create contract — corroborated independently via web search (title/relationship shape, `executionProgress` enum `PENDING`/`RUNNING`/`COMPLETE`) since Apple's live doc page is JS-rendered and returned no body text to WebFetch. This is the same shape already exercised elsewhere in the file (`read_build_run_status`, `list_workflow_build_runs` both read `executionProgress`/`completionStatus` off resources of type `ciBuildRuns`), so the request/response contract is internally consistent with the rest of the module, not merely new.

**Verdict: PASS.**

### Clean-Room Verification

Independently derived (not from the report) whether a workflow outside the two-item allowlist, or a workflow belonging to a different Cloud product, can reach the POST:

- Outside-allowlist name: `selected["name"] not in VALIDATION_WORKFLOW_NAMES` raises before `_start_build_run` runs. Confirmed by test parametrization row `("workflow-1", "workflow-1", "Release", True, "name-not-allowed")` (`app/test_allocate_identity.py:639`), and independently by hand-tracing `start_validation_build`: the only path to `_start_build_run` is after both the membership and name checks pass with no early return that skips them.
- Wrong product: `list_product_workflow_metadata(client, product_id)` is scoped by `product_id` in the URL itself (`/ciProducts/{product_id}/workflows`, `app/allocate_identity.py:456`). A `workflow_id` that belongs to a different Cloud product will not appear in that GET's `data`, so `selected is None` and `validation-workflow-not-in-product` is raised. Confirmed by test rows `("unknown", ...)` and `("other-product-workflow", ...)` (`app/test_allocate_identity.py:631-638`), both asserting `client.methods == ["GET"]`.
- Disabled workflow: `not selected["isEnabled"]` raises `validation-workflow-disabled` before POST (row `("workflow-1", "workflow-1", "Gradus macOS UI Trial", False, "disabled")`).
- Traced the CLI path end to end: `main()` → `args.start_validation_build` branch → `start_validation_build(ASCClient(...), product_id=args.ci_product_id, workflow_id=args.workflow_id)`. There is no code path in `main()` that calls `_start_build_run` directly or bypasses `start_validation_build`'s checks. `--start-validation-build` is registered only once in the parser (`app/allocate_identity.py:1583-1587`) and dispatched only once (`1888`).
- Ran the malformed-response test manually against the reasoning: if Apple ever returned a `ciBuildRuns` payload with an empty/missing `id` or `executionProgress`, `_start_build_run` raises `{error_prefix}-build-start-response-invalid` before returning — confirmed live by `test_start_validation_build_rejects_malformed_response` (`app/test_allocate_identity.py:672-696`).

No unauthorized path found. The allowlist is enforced entirely in-process (not delegated to Apple), and every gate happens before the single mutating `POST`.

**Verdict: PASS.**

### Blind-Spot Discovery

- `list_workflow_metadata`/`list_product_workflow_metadata` already fail closed on ambiguous or malformed workflow-list entries (duplicate IDs, non-bool `isEnabled`, non-string `name`) — `start_validation_build` inherits this for free since it calls the same lister; no separate re-validation was needed or missing.
- `product_id` itself is caller-supplied and unchecked against "is this actually a Gradus-owned Cloud product." This is consistent with every other product-scoped function in the file (`start_internal_testflight_build`, `create_internal_testflight_workflow` take the same untrusted `product_id`) and is outside this task's stated scope (the task's own acceptance criterion is "belongs to the supplied Cloud product," not "the supplied product is Gradus's"). Not a regression introduced by this change — flagging only as a pre-existing, unchanged trust boundary, not a defect in Task 1.1.
- The refactor of `start_internal_testflight_build` (git diff) is a pure structural extraction: the TestFlight-specific checks (`name`, `isEnabled`, `hasManualStart`, exact `archiveActions` list) are unchanged in content and order, and the POST/validation body moved into `_start_build_run` byte-for-byte except for the error-message prefix becoming a parameter (`testflight-build-start-response-invalid` → `f"{error_prefix}-build-start-response-invalid"`, which still resolves to the identical string for the TestFlight caller). `test_start_internal_testflight_build_checks_contract_before_posting` (`app/test_allocate_identity.py:531-578`) still passes unmodified, confirming behavior preservation.
- No secret material appears in the receipt or in any raised `IdentityAllocationError` string — all error labels are static/enum-shaped tags, never raw response bodies (consistent with the module's existing `_asc_error_label` pattern used elsewhere for ASC-transport errors).
- `--start-validation-build` was checked against the "cannot combine with `--product`" guard list — present (`app/allocate_identity.py:1657`) — and against the "does not accept artifact options" guard, present per-branch (`1892-1899`), matching the pattern used by every other mutating/listing flag in `main()`.
- Test coverage gap (minor, non-blocking): there is no test asserting `--start-validation-build` is itself rejected when combined with `--product` (the shared guard-list test coverage for this combination doesn't appear to exist for any of the individual flags in that list, so this is consistent with existing test density elsewhere in the file, not a new gap specific to this task).

**Verdict: PASS**, no blocking findings.

## Verdict block

- Task 1.1 (fixed, allowlisted validation-workflow build-start command): **PASS**
- `uv run pytest app/test_allocate_identity.py -q`: 56 passed, 0 failed
- No arbitrary-workflow or cross-product start path found
- Existing internal-TestFlight contract checks (name/enabled/manual-start/archive-action shape) unchanged
- POST body and response validation match Apple's documented `ciBuildRuns` contract and the module's own internal usage elsewhere
- No live API calls made; no files edited by this verification
