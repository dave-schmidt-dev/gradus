#!/usr/bin/env python3
"""Attended internal-TestFlight assignment; no group or tester provisioning."""

from __future__ import annotations

import argparse
import json
import sys
import time
from collections.abc import Callable
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
    apps = client.request("GET", f"/apps?filter[bundleId]={bundle_id}") or {}
    app_data = apps.get("data")
    if not isinstance(app_data, list) or len(app_data) != 1 or not isinstance(app_data[0], dict):
        raise AssignmentError("bundle ID did not resolve to exactly one app")
    app_id = app_data[0].get("id")
    if not isinstance(app_id, str) or not app_id:
        raise AssignmentError("ASC app identity is missing")
    groups = client.request("GET", f"/apps/{app_id}/betaGroups?limit=200") or {}
    if not isinstance(groups, dict) or not isinstance(groups.get("data"), list):
        raise AssignmentError("malformed ASC internal-group response")
    find_exact_internal_group(groups["data"], group_id, group_name)
    deadline = clock() + timeout
    selected: dict[str, Any] | None = None
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
    assigned = client.request("GET", f"/betaGroups/{group_id}/builds?limit=200") or {}
    if not isinstance(assigned, dict) or not isinstance(assigned.get("data"), list):
        raise AssignmentError("malformed ASC group-build response")
    if any(isinstance(item, dict) and item.get("id") == build_id for item in assigned["data"]):
        already = True
    elif not permit_assignment:
        already = False
    else:
        client.request(
            "POST",
            f"/betaGroups/{group_id}/relationships/builds",
            {"data": [{"type": "builds", "id": build_id}]},
            idempotent=False,
        )
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
        return CandidateEvidence.from_mapping(data)
    except ValidationError as exc:
        raise AssignmentError("candidate evidence is invalid") from exc


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
        evidence = _load_evidence(args.evidence)
        journal = ReceiptJournal(args.receipt_journal)
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
        print(f"FAIL: {_safe_failure_class(exc)}", file=sys.stderr)
        return 1
    print(
        json.dumps(
            {key: value for key, value in result.items() if key in ALLOWED_RECEIPT_KEYS},
            sort_keys=True,
        )
    )
    return 0
