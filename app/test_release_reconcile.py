"""Hermetic restart and receipt tests for TestFlight candidate reconciliation."""

from __future__ import annotations

import importlib.util
import json
from datetime import datetime, timezone
from pathlib import Path

import pytest
from release_candidate.ledger import CandidateLedger, CandidateState
from release_candidate.reconcile import (
    FINAL_RECEIPT_FIELDS,
    ReceiptJournal,
    ReconciliationError,
    RemoteCandidateState,
    reconcile_candidate,
)
from release_candidate.validation import CandidateEvidence

_assignment_spec = importlib.util.spec_from_file_location(
    "testflight_assign", Path(__file__).with_name("testflight-assign.py")
)
assert _assignment_spec and _assignment_spec.loader
_assignment_module = importlib.util.module_from_spec(_assignment_spec)
_assignment_spec.loader.exec_module(_assignment_module)
reconcile_assignment_result = _assignment_module.reconcile_assignment_result
run_assignment_with_reconciliation = _assignment_module.run_assignment_with_reconciliation


def digest(letter: str) -> str:
    return letter * 64


def evidence() -> CandidateEvidence:
    moment = datetime(2026, 8, 9, tzinfo=timezone.utc)
    return CandidateEvidence(
        "revision-marker",
        digest("b"),
        "1.6.8",
        17,
        digest("d"),
        42,
        digest("c"),
        "walkthrough-marker",
        digest("e"),
        moment,
        moment,
    )


def uploading_ledger(tmp_path) -> CandidateLedger:
    ledger = CandidateLedger(tmp_path / "candidate.json")
    ledger.create(
        "candidate-marker",
        source_sha256=digest("a"),
        project_sha256=digest("b"),
        artifact_sha256=digest("c"),
        build=42,
        marketing_version="1.6.8",
        metadata={
            "sourceRevision": "revision-marker",
            "producerBuild": 17,
            "producerEvidenceSha256": digest("d"),
            "iosBuild": 42,
            "walkthroughPath": "walkthrough-marker",
            "walkthroughSha256": digest("e"),
        },
    )
    ledger.transition(CandidateState.VALIDATED)
    ledger.transition(CandidateState.PREPARED)
    ledger.transition(CandidateState.UPLOADING)
    return ledger


def remote(*, build: int = 42, assigned: bool = False) -> RemoteCandidateState:
    return RemoteCandidateState(
        build,
        "VALID",
        "group-marker",
        "Internal Testers",
        assigned,
        "2026-08-09T12:00:00Z",
        "2026-11-07T12:00:00Z",
    )


def test_restart_from_uploading_converges_without_replacement_allocation(tmp_path) -> None:
    ledger = uploading_ledger(tmp_path)
    receipt = reconcile_candidate(
        ledger, ReceiptJournal(tmp_path / "receipt.json"), evidence(), remote()
    )
    assert ledger.load().state == CandidateState.UPLOADED_UNASSIGNED
    assert receipt["state"] == CandidateState.UPLOADED_UNASSIGNED
    assert receipt["build"] == 42


def test_remote_mismatch_and_unavailable_have_redacted_receipts(tmp_path, capsys) -> None:
    ledger = uploading_ledger(tmp_path)
    journal = ReceiptJournal(tmp_path / "receipt.json")
    for value in (None, remote(build=99)):
        with pytest.raises(ReconciliationError) as raised:
            reconcile_candidate(ledger, journal, evidence(), value)
        serialized = json.dumps(raised.value.receipt, sort_keys=True) + str(raised.value)
        assert "raw-body-marker" not in serialized
        assert "tester-address-marker" not in serialized
        assert "Bearer" not in serialized
    captured = capsys.readouterr()
    assert captured.out + captured.err == ""
    assert ledger.load().state == CandidateState.UPLOADING


def test_evidence_source_and_walkthrough_mismatch_is_rejected(tmp_path) -> None:
    ledger = uploading_ledger(tmp_path)
    journal = ReceiptJournal(tmp_path / "receipt.json")
    mismatched_source = CandidateEvidence(
        "other-revision",
        digest("b"),
        "1.6.8",
        17,
        digest("d"),
        42,
        digest("c"),
        "walkthrough-marker",
        digest("e"),
        datetime(2026, 8, 9, tzinfo=timezone.utc),
        datetime(2026, 8, 9, tzinfo=timezone.utc),
    )
    with pytest.raises(ReconciliationError) as raised:
        reconcile_candidate(ledger, journal, mismatched_source, remote())
    assert raised.value.error_class == "evidence_mismatch"
    mismatched_walkthrough = CandidateEvidence(
        "revision-marker",
        digest("b"),
        "1.6.8",
        17,
        digest("d"),
        42,
        digest("c"),
        "other-walkthrough",
        digest("e"),
        datetime(2026, 8, 9, tzinfo=timezone.utc),
        datetime(2026, 8, 9, tzinfo=timezone.utc),
    )
    with pytest.raises(ReconciliationError) as raised:
        reconcile_candidate(ledger, journal, mismatched_walkthrough, remote())
    assert raised.value.error_class == "evidence_mismatch"


def test_assigned_receipt_is_complete_and_restart_idempotent(tmp_path) -> None:
    ledger = uploading_ledger(tmp_path)
    journal = ReceiptJournal(tmp_path / "receipt.json")
    first = reconcile_candidate(ledger, journal, evidence(), remote(assigned=True))
    second = reconcile_candidate(ledger, journal, evidence(), remote(assigned=True))
    assert ledger.load().state == CandidateState.ASSIGNED
    assert set(first) == FINAL_RECEIPT_FIELDS
    assert first["processing_state"] == "VALID"
    assert first["group_id"] == "group-marker"
    assert first["group_name"] == "Internal Testers"
    assert first["producer_evidence_sha256"] == digest("d")
    assert first["artifact_sha256"] == digest("c")
    assert first["walkthrough_sha256"] == digest("e")
    assert first["available_at"] and first["expires_at"]
    assert second["idempotency_key"] == first["idempotency_key"]


def test_assignment_bridge_accepts_only_allowlisted_remote_facts(tmp_path) -> None:
    ledger = uploading_ledger(tmp_path)
    result = {
        "candidate_id": "candidate-marker",
        "build": 42,
        "processing_state": "VALID",
        "group_id": "group-marker",
        "group_name": "Internal Testers",
        "assigned": True,
        "available_at": "2026-08-09T12:00:00Z",
        "expires_at": "2026-11-07T12:00:00Z",
        "raw_body": "ignored-marker",
    }
    receipt = reconcile_assignment_result(
        ledger, ReceiptJournal(tmp_path / "receipt.json"), evidence(), result
    )
    serialized = json.dumps(receipt, sort_keys=True)
    assert receipt["state"] == CandidateState.ASSIGNED
    assert "ignored-marker" not in serialized


def test_existing_journal_mismatch_returns_redacted_failure(tmp_path) -> None:
    ledger = uploading_ledger(tmp_path)
    journal = ReceiptJournal(tmp_path / "receipt.json")
    reconcile_candidate(ledger, journal, evidence(), remote())
    with pytest.raises(ReconciliationError) as raised:
        reconcile_candidate(
            ledger,
            journal,
            evidence(),
            RemoteCandidateState(
                42,
                "VALID",
                "other-group",
                "Internal Testers",
                False,
                "2026-08-09T12:00:00Z",
                "2026-11-07T12:00:00Z",
            ),
        )
    serialized = json.dumps(raised.value.receipt, sort_keys=True) + str(raised.value)
    assert raised.value.error_class == "journal_remote_mismatch"
    assert "raw-body-marker" not in serialized


class ReconciliationClient:
    def __init__(self) -> None:
        self.assigned = False
        self.requests = []

    def request(self, method, path, body=None, **kwargs):
        del kwargs
        self.requests.append((method, path, body))
        if path.startswith("/apps?"):
            return {"data": [{"id": "app-marker", "attributes": {}}]}
        if path == "/apps/app-marker/betaGroups?limit=200":
            return {
                "data": [
                    {
                        "id": "group-marker",
                        "attributes": {"name": "Internal Testers", "isInternalGroup": True},
                    }
                ]
            }
        if path.startswith("/builds?"):
            return {
                "data": [
                    {
                        "id": "build-marker",
                        "attributes": {
                            "version": "42",
                            "processingState": "VALID",
                            "uploadedDate": "2026-08-09T12:00:00Z",
                            "expirationDate": "2026-11-07T12:00:00Z",
                        },
                    }
                ]
            }
        if path == "/builds/build-marker":
            return {
                "data": {
                    "id": "build-marker",
                    "attributes": {
                        "version": "42",
                        "processingState": "VALID",
                        "expired": False,
                        "uploadedDate": "2026-08-09T12:00:00Z",
                        "expirationDate": "2026-11-07T12:00:00Z",
                    },
                }
            }
        if path == "/betaGroups/group-marker/builds?limit=200":
            return {"data": [{"id": "build-marker"}]} if self.assigned else {"data": []}
        if method == "POST" and path == "/betaGroups/group-marker/relationships/builds":
            self.assigned = True
            return None
        raise AssertionError("unexpected request")


def test_assignment_cli_workflow_reconciles_before_and_after_post(tmp_path) -> None:
    ledger = uploading_ledger(tmp_path)
    client = ReconciliationClient()
    receipt = run_assignment_with_reconciliation(
        client,
        ledger=ledger,
        journal=ReceiptJournal(tmp_path / "receipt.json"),
        evidence=evidence(),
        candidate_id="candidate-marker",
        build="42",
        group_id="group-marker",
        group_name="Internal Testers",
    )
    assert ledger.load().state == CandidateState.ASSIGNED
    assert receipt["assigned"] is True
    post = [request for request in client.requests if request[0] == "POST"]
    assert len(post) == 1


def test_assignment_workflow_rejects_ledger_identity_before_remote_call(tmp_path) -> None:
    ledger = uploading_ledger(tmp_path)
    client = ReconciliationClient()
    with pytest.raises(_assignment_module.AssignmentError):
        run_assignment_with_reconciliation(
            client,
            ledger=ledger,
            journal=ReceiptJournal(tmp_path / "receipt.json"),
            evidence=evidence(),
            candidate_id="wrong-candidate",
            build="42",
            group_id="group-marker",
            group_name="Internal Testers",
        )
    assert client.requests == []
