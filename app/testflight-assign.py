#!/usr/bin/env python3
"""Attended internal-TestFlight assignment; no group or tester provisioning."""

from __future__ import annotations

import argparse
import json
import sys
import time
from collections.abc import Callable
from datetime import timedelta
from pathlib import Path
from typing import Any

from _asc_api import ASCClient, ASCError, make_token_provider
from release_candidate.ledger import CandidateError, CandidateLedger, CandidateState
from release_candidate.reconcile import (
    ReceiptJournal,
    ReconciliationError,
    RemoteCandidateState,
    reconcile_candidate,
)
from release_candidate.validation import CandidateEvidence, ValidationError

DEFAULT_BUNDLE_ID = "com.zerodelta.gradus.ios"
POLL_INTERVAL_SECONDS = 30
POLL_TIMEOUT_SECONDS = 30 * 60
MISSING_COMPLIANCE_STATES = frozenset({"MISSING_COMPLIANCE", "MISSINGCOMPLIANCE"})
ALLOWED_RECEIPT_KEYS = frozenset(
    {
        "candidate_id",
        "build",
        "group_id",
        "group_name",
        "processing_state",
        "assigned",
        "available_at",
        "expires_at",
    }
)


class AssignmentError(RuntimeError):
    """Raised before an unsafe or ambiguous assignment request."""


def _attrs(item: dict[str, Any]) -> dict[str, Any]:
    attrs = item.get("attributes", item)
    if not isinstance(attrs, dict):
        raise AssignmentError("malformed ASC resource")
    return attrs


def find_exact_internal_group(
    groups: list[dict[str, Any]], group_id: str, group_name: str
) -> dict[str, Any]:
    internal = []
    for group in groups:
        if not isinstance(group, dict) or not isinstance(group.get("id"), str):
            raise AssignmentError("malformed internal group response")
        attrs = _attrs(group)
        if attrs.get("isInternalGroup"):
            internal.append(group)
    matches = [
        group
        for group in internal
        if group["id"] == group_id and _attrs(group).get("name") == group_name
    ]
    if len(internal) != 1 or len(matches) != 1:
        raise AssignmentError("exact internal group confirmation did not match exactly one group")
    return matches[0]


def classify_build(build: dict[str, Any], expected_build: str) -> str:
    attrs = _attrs(build)
    if str(attrs.get("version")) != expected_build:
        raise AssignmentError("ASC returned a different build version")
    state = str(attrs.get("processingState", "")).upper().replace(" ", "_")
    if state in {"FAILED", "INVALID"}:
        raise AssignmentError(f"build processing failed: {state}")
    if (
        state in MISSING_COMPLIANCE_STATES
        or str(attrs.get("complianceState", "")).upper().replace(" ", "_")
        in MISSING_COMPLIANCE_STATES
    ):
        raise AssignmentError("Missing Compliance requires attended Apple export-compliance action")
    return state


def build_availability_metadata(build: dict[str, Any]) -> dict[str, str | None]:
    """Return only receipt-safe availability and expiry values from one build."""

    attrs = _attrs(build)
    available = attrs.get("uploadedDate")
    expires = attrs.get("expirationDate")
    return {
        "available_at": available if isinstance(available, str) else None,
        "expires_at": expires if isinstance(expires, str) else None,
    }


def confirm_exact_build(client: Any, build_id: str, expected_build: str) -> dict[str, Any]:
    """Re-read the immutable ASC build resource before any assignment mutation."""

    response = client.request("GET", f"/builds/{build_id}") or {}
    data = response.get("data")
    if not isinstance(data, dict) or data.get("id") != build_id:
        raise AssignmentError("exact ASC build resource was not found")
    if str(_attrs(data).get("version")) != expected_build:
        raise AssignmentError("exact ASC build version changed during processing")
    state = classify_build(data, expected_build)
    if state != "VALID":
        raise AssignmentError(f"exact build is not VALID: {state}")
    if _attrs(data).get("expired") is True:
        raise AssignmentError("exact build is expired")
    encryption = _attrs(data).get("usesNonExemptEncryption")
    print(
        "    Exact build flags: "
        f"encryption_answered={encryption is True or encryption is False} "
        f"encryption_exempt={encryption is False}",
        file=sys.stderr,
        flush=True,
    )
    return data


def diagnose_relationship_targets(client: Any, group_id: str, build_id: str) -> None:
    """Emit only boolean target checks after an unexpected mutation 404."""

    group_app: str | None = None
    build_app: str | None = None
    group_all_builds = False
    existing_group_assignment = False
    beta_detail_present = False
    internal_beta_state: str | None = None
    try:
        group = client.request("GET", f"/betaGroups/{group_id}") or {}
        data = group.get("data")
        if isinstance(data, dict):
            group_all_builds = _attrs(data).get("hasAccessToAllBuilds") is True
        relation = client.request("GET", f"/betaGroups/{group_id}/relationships/app") or {}
        data = relation.get("data")
        if isinstance(data, dict) and isinstance(data.get("id"), str):
            group_app = data["id"]
    except ASCError:
        pass
    try:
        detail_link = (
            client.request("GET", f"/builds/{build_id}/relationships/buildBetaDetail") or {}
        )
        beta_detail_present = isinstance(detail_link.get("data"), dict)
        detail_id = (
            detail_link.get("data", {}).get("id")
            if isinstance(detail_link.get("data"), dict)
            else None
        )
        if isinstance(detail_id, str) and detail_id:
            detail = client.request("GET", f"/buildBetaDetails/{detail_id}") or {}
            detail_data = detail.get("data")
            if isinstance(detail_data, dict):
                value = _attrs(detail_data).get("internalBuildState")
                if isinstance(value, str):
                    internal_beta_state = value
    except ASCError:
        pass
    try:
        relation = client.request("GET", f"/builds/{build_id}/relationships/app") or {}
        data = relation.get("data")
        if isinstance(data, dict) and isinstance(data.get("id"), str):
            build_app = data["id"]
    except ASCError:
        pass
    try:
        relation = client.request("GET", f"/builds/{build_id}/relationships/betaGroups") or {}
        entries = relation.get("data")
        if isinstance(entries, list):
            existing_group_assignment = any(
                isinstance(entry, dict) and entry.get("id") == group_id for entry in entries
            )
    except ASCError:
        pass
    print(
        "    404 target check: "
        f"group_app_present={group_app is not None} "
        f"build_app_present={build_app is not None} "
        f"same_app={group_app is not None and group_app == build_app} "
        f"group_all_builds={group_all_builds} "
        f"build_group_relationship_present={existing_group_assignment} "
        f"beta_detail_present={beta_detail_present} "
        f"internal_beta_state={internal_beta_state or 'unknown'}",
        file=sys.stderr,
        flush=True,
    )


def add_build_to_group(client: Any, group_id: str, build_id: str) -> None:
    """Add one build, using Apple's build-side route when group-side is unavailable."""

    body = {"data": [{"type": "builds", "id": build_id}]}
    try:
        client.request(
            "POST",
            f"/betaGroups/{group_id}/relationships/builds",
            body,
            idempotent=False,
        )
    except ASCError as error:
        if error.outcome.error_class != "http_404":
            raise
        # Apple exposes the equivalent mutation from the build resource. Some
        # internal groups accept only this build-side route even though their
        # group-side relationship is readable.
        diagnose_relationship_targets(client, group_id, build_id)
        print(
            "==> Retrying assignment through the build relationship route",
            file=sys.stderr,
            flush=True,
        )
        client.request(
            "POST",
            f"/builds/{build_id}/relationships/betaGroups",
            {"data": [{"type": "betaGroups", "id": group_id}]},
            idempotent=False,
        )


def reconcile_assignment_result(
    ledger: CandidateLedger,
    journal: ReceiptJournal,
    evidence: CandidateEvidence,
    result: dict[str, Any],
) -> dict[str, Any]:
    """Persist the post-assignment ASC observation through the reconciler.

    The assignment client returns only allowlisted facts, so this bridge cannot
    pass raw ASC resources, tester data, or HTTP diagnostics into local state.
    """

    record = ledger.load()
    if record is None:
        raise ReconciliationError("candidate_missing", {"error_class": "candidate_missing"})
    if result.get("candidate_id") != record.candidate_id:
        raise ReconciliationError("candidate_id_mismatch", {"error_class": "candidate_id_mismatch"})
    try:
        remote = RemoteCandidateState(
            build=result.get("build"),
            processing_state=result.get("processing_state"),
            group_id=result.get("group_id"),
            group_name=result.get("group_name"),
            assigned=result.get("assigned"),
            available_at=result.get("available_at"),
            expires_at=result.get("expires_at"),
        )
    except (TypeError, ValueError) as exc:
        raise ReconciliationError(
            "remote_observation_invalid", {"error_class": "remote_observation_invalid"}
        ) from exc
    return reconcile_candidate(ledger, journal, evidence, remote)


def assign_candidate(
    client: Any,
    *,
    candidate_id: str,
    build: str,
    group_id: str,
    group_name: str,
    bundle_id: str = DEFAULT_BUNDLE_ID,
    clock: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
    timeout: float = POLL_TIMEOUT_SECONDS,
    interval: float = POLL_INTERVAL_SECONDS,
    permit_assignment: bool = True,
) -> dict[str, Any]:
    if not candidate_id or not build.isdigit() or int(build) < 1 or not group_id or not group_name:
        raise AssignmentError(
            "candidate, positive build, group ID, and group display name are required"
        )
    print("==> Resolving the Gradus App Store Connect app", file=sys.stderr, flush=True)
    apps = client.request("GET", f"/apps?filter[bundleId]={bundle_id}") or {}
    app_data = apps.get("data")
    if not isinstance(app_data, list) or len(app_data) != 1 or not isinstance(app_data[0], dict):
        raise AssignmentError("bundle ID did not resolve to exactly one app")
    app_id = app_data[0].get("id")
    if not isinstance(app_id, str) or not app_id:
        raise AssignmentError("ASC app identity is missing")
    print("==> Confirming the exact internal TestFlight group", file=sys.stderr, flush=True)
    groups = client.request("GET", f"/apps/{app_id}/betaGroups?limit=200") or {}
    if not isinstance(groups, dict) or not isinstance(groups.get("data"), list):
        raise AssignmentError("malformed ASC internal-group response")
    confirmed_group = find_exact_internal_group(groups["data"], group_id, group_name)
    deadline = clock() + timeout
    selected: dict[str, Any] | None = None
    print(f"==> Waiting for exact build {build} to process", file=sys.stderr, flush=True)
    while clock() <= deadline:
        response = (
            client.request("GET", f"/builds?filter[app]={app_id}&filter[version]={build}&limit=50")
            or {}
        )
        builds = response.get("data")
        if not isinstance(builds, list):
            raise AssignmentError("malformed ASC build response")
        exact = [
            item
            for item in builds
            if isinstance(item, dict) and str(_attrs(item).get("version")) == build
        ]
        if len(exact) > 1:
            raise AssignmentError("multiple ASC builds matched the exact candidate build")
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
    build_id = selected["id"]
    if not isinstance(build_id, str) or not build_id:
        raise AssignmentError("ASC build identity is missing")
    print("==> Verifying the exact processed build resource", file=sys.stderr, flush=True)
    selected = confirm_exact_build(client, build_id, build)
    if _attrs(confirmed_group).get("hasAccessToAllBuilds") is True:
        print(
            "==> Confirmed group grants access to all builds; no relationship mutation required",
            file=sys.stderr,
            flush=True,
        )
        return {
            "candidate_id": candidate_id,
            "build": int(build),
            "group_id": group_id,
            "group_name": group_name,
            "processing_state": "VALID",
            "assigned": True,
            "already_assigned": True,
            **build_availability_metadata(selected),
        }
    print("==> Checking existing group/build assignment", file=sys.stderr, flush=True)
    assigned = client.request("GET", f"/betaGroups/{group_id}/builds?limit=200") or {}
    if not isinstance(assigned, dict) or not isinstance(assigned.get("data"), list):
        raise AssignmentError("malformed ASC group-build response")
    if any(isinstance(item, dict) and item.get("id") == build_id for item in assigned["data"]):
        already = True
    elif not permit_assignment:
        already = False
    else:
        print(
            "==> Assigning the exact build to the confirmed internal group",
            file=sys.stderr,
            flush=True,
        )
        add_build_to_group(client, group_id, build_id)
        already = False
    return {
        "candidate_id": candidate_id,
        "build": int(build),
        "group_id": group_id,
        "group_name": group_name,
        "processing_state": "VALID",
        "assigned": already or permit_assignment,
        "already_assigned": already,
        **build_availability_metadata(selected),
    }


def run_assignment_with_reconciliation(
    client: Any,
    *,
    ledger: CandidateLedger,
    journal: ReceiptJournal,
    evidence: CandidateEvidence,
    candidate_id: str,
    build: str,
    group_id: str,
    group_name: str,
) -> dict[str, Any]:
    """Reconcile pre- and post-assignment observations before reporting success."""

    record = ledger.load()
    if not build.isdigit() or int(build) < 1:
        raise AssignmentError("candidate build is invalid")
    if record is None or record.candidate_id != candidate_id or record.build != int(build):
        raise AssignmentError("candidate identity does not match the local ledger")
    if record.state not in {
        CandidateState.UPLOADING,
        CandidateState.UPLOADED_UNASSIGNED,
        CandidateState.ASSIGNED,
    }:
        raise AssignmentError("candidate is not eligible for assignment reconciliation")

    observation = assign_candidate(
        client,
        candidate_id=candidate_id,
        build=build,
        group_id=group_id,
        group_name=group_name,
        permit_assignment=False,
    )
    receipt = reconcile_assignment_result(ledger, journal, evidence, observation)
    if receipt["state"] == CandidateState.ASSIGNED:
        return receipt
    if receipt["state"] != CandidateState.UPLOADED_UNASSIGNED:
        raise AssignmentError("candidate reconciliation did not reach an assignable state")

    assign_candidate(
        client, candidate_id=candidate_id, build=build, group_id=group_id, group_name=group_name
    )
    confirmed = assign_candidate(
        client,
        candidate_id=candidate_id,
        build=build,
        group_id=group_id,
        group_name=group_name,
        permit_assignment=False,
    )
    return reconcile_assignment_result(ledger, journal, evidence, confirmed)


def _load_evidence(path: str) -> CandidateEvidence:
    try:
        with Path(path).open(encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise AssignmentError("candidate evidence is unavailable") from exc
    try:
        # Upload preparation already enforced the producer-evidence freshness
        # boundary. Assignment may legitimately wait longer than that window
        # for Apple's processing queue; the persisted candidate tuple remains
        # bound by its source/project/IPA/walkthrough digests and must not be
        # rewritten with a newer producer observation.
        return CandidateEvidence.from_mapping(data, max_producer_age=timedelta.max)
    except ValidationError as exc:
        raise AssignmentError("candidate evidence is invalid") from exc


def _resolve_receipt_journal_path(ledger: CandidateLedger, requested: str) -> Path:
    """Require the assignment receipt journal to live in the candidate workspace."""

    record = ledger.load()
    if record is None:
        raise AssignmentError("candidate ledger is missing")
    workspace_value = (record.metadata or {}).get("candidateWorkspace")
    if not isinstance(workspace_value, str) or not workspace_value.strip():
        raise AssignmentError("candidate workspace is missing from the ledger")
    workspace = Path(workspace_value).expanduser().resolve()
    journal = Path(requested).expanduser().resolve()
    try:
        journal.relative_to(workspace)
    except ValueError as exc:
        raise AssignmentError("receipt journal must be inside the candidate workspace") from exc
    if journal == workspace:
        raise AssignmentError("receipt journal must be a file inside the candidate workspace")
    if journal.exists() and not journal.is_file():
        raise AssignmentError("receipt journal must be a regular file")
    if not journal.parent.is_dir():
        raise AssignmentError("receipt journal parent directory is invalid")
    return journal


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidate_id")
    parser.add_argument("build")
    parser.add_argument("--group-id", required=True)
    parser.add_argument("--group-name", required=True)
    parser.add_argument("--ledger", required=True)
    parser.add_argument("--evidence", required=True)
    parser.add_argument("--receipt-journal", required=True)
    return parser.parse_args()


def _safe_failure_class(error: Exception) -> str:
    if isinstance(error, ReconciliationError):
        return error.error_class
    if isinstance(error, ASCError):
        return error.outcome.error_class
    if isinstance(error, CandidateError):
        return "candidate_invalid"
    if isinstance(error, AssignmentError):
        return "assignment_invalid"
    return "assignment_failed"


def main() -> int:
    args = parse_args()
    try:
        ledger = CandidateLedger(args.ledger)
        receipt_path = _resolve_receipt_journal_path(ledger, args.receipt_journal)
        ledger.extend_metadata({"receiptJournalPath": str(receipt_path)})
        evidence = _load_evidence(args.evidence)
        journal = ReceiptJournal(receipt_path)
        result = run_assignment_with_reconciliation(
            ASCClient(make_token_provider()),
            ledger=ledger,
            journal=journal,
            evidence=evidence,
            candidate_id=args.candidate_id,
            build=args.build,
            group_id=args.group_id,
            group_name=args.group_name,
        )
    except (ASCError, AssignmentError, CandidateError, ReconciliationError) as exc:
        failure_class = _safe_failure_class(exc)
        if isinstance(exc, AssignmentError):
            # AssignmentError messages are fixed local classifications, never
            # raw ASC bodies; retain the reason so an attended Apple gate is
            # actionable instead of a generic non-zero exit.
            print(f"FAIL: {failure_class} ({exc})", file=sys.stderr)
        else:
            print(f"FAIL: {failure_class}", file=sys.stderr)
        return 1
    print(
        json.dumps(
            {key: value for key, value in result.items() if key in ALLOWED_RECEIPT_KEYS},
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
