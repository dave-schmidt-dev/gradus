"""Redacted, restart-safe reconciliation for an internal-TestFlight candidate."""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .ledger import CandidateError, CandidateLedger, CandidateRecord, CandidateState
from .validation import CandidateEvidence

FINAL_RECEIPT_FIELDS = frozenset(
    {
        "candidate_id",
        "idempotency_key",
        "state",
        "build",
        "processing_state",
        "group_id",
        "group_name",
        "assigned",
        "source_sha256",
        "project_sha256",
        "artifact_sha256",
        "producer_evidence_sha256",
        "walkthrough_sha256",
        "available_at",
        "expires_at",
        "reconciled_at",
    }
)


class ReconciliationError(RuntimeError):
    """A safe reconciliation failure with a receipt suitable for local inspection."""

    def __init__(self, error_class: str, receipt: Mapping[str, Any]) -> None:
        self.error_class = error_class
        self.receipt = dict(receipt)
        super().__init__(f"candidate reconciliation failed: {error_class}")


@dataclass(frozen=True)
class RemoteCandidateState:
    """Allowlisted ASC facts required to reconcile one candidate build."""

    build: int
    processing_state: str
    group_id: str
    group_name: str
    assigned: bool
    available_at: str
    expires_at: str

    def __post_init__(self) -> None:
        if isinstance(self.build, bool) or not isinstance(self.build, int) or self.build < 1:
            raise ValueError("remote build must be a positive integer")
        if (
            not isinstance(self.processing_state, str)
            or not self.processing_state.strip()
            or not isinstance(self.group_id, str)
            or not self.group_id.strip()
            or not isinstance(self.group_name, str)
            or not self.group_name.strip()
        ):
            raise ValueError("remote state is incomplete")
        if (
            not isinstance(self.assigned, bool)
            or not isinstance(self.available_at, str)
            or not self.available_at.strip()
            or not isinstance(self.expires_at, str)
            or not self.expires_at.strip()
        ):
            raise ValueError("remote availability metadata is incomplete")


class ReceiptJournal:
    """Atomic snapshot journal keyed by the deterministic candidate idempotency key."""

    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)

    def load(self) -> dict[str, Any] | None:
        if not self.path.exists():
            return None
        try:
            with self.path.open(encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, json.JSONDecodeError) as exc:
            raise ReconciliationError(
                "journal_unavailable", {"error_class": "journal_unavailable"}
            ) from exc
        if not isinstance(data, dict) or set(data) != FINAL_RECEIPT_FIELDS:
            raise ReconciliationError("journal_malformed", {"error_class": "journal_malformed"})
        return data

    def write(self, receipt: Mapping[str, Any]) -> None:
        if set(receipt) != FINAL_RECEIPT_FIELDS:
            raise ReconciliationError(
                "receipt_fields_invalid", {"error_class": "receipt_fields_invalid"}
            )
        payload = json.dumps(dict(receipt), sort_keys=True, indent=2) + "\n"
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(prefix=f".{self.path.name}.", dir=self.path.parent)
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, self.path)
            directory = os.open(self.path.parent, os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        except Exception:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
            raise


def candidate_idempotency_key(record: CandidateRecord) -> str:
    """Derive a non-secret key that cannot be reused for another candidate tuple."""

    if record.build is None:
        raise CandidateError("candidate build is required for reconciliation")
    material = f"{record.candidate_id}:{record.build}:{record.artifact_sha256}".encode()
    return hashlib.sha256(material).hexdigest()


def _receipt(
    record: CandidateRecord,
    evidence: CandidateEvidence,
    remote: RemoteCandidateState | None,
    *,
    state: str,
    now: datetime,
) -> dict[str, Any]:
    return {
        "candidate_id": record.candidate_id,
        "idempotency_key": candidate_idempotency_key(record),
        "state": state,
        "build": record.build,
        "processing_state": None if remote is None else remote.processing_state,
        "group_id": None if remote is None else remote.group_id,
        "group_name": None if remote is None else remote.group_name,
        "assigned": False if remote is None else remote.assigned,
        "source_sha256": record.source_sha256,
        "project_sha256": record.project_sha256,
        "artifact_sha256": record.artifact_sha256,
        "producer_evidence_sha256": evidence.producer_evidence_sha256,
        "walkthrough_sha256": evidence.walkthrough_sha256,
        "available_at": None if remote is None else remote.available_at,
        "expires_at": None if remote is None else remote.expires_at,
        "reconciled_at": now.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
    }


def _reject(
    record: CandidateRecord, evidence: CandidateEvidence, error_class: str, now: datetime
) -> ReconciliationError:
    receipt = _receipt(record, evidence, None, state=record.state, now=now)
    receipt["processing_state"] = error_class
    return ReconciliationError(error_class, receipt)


def _evidence_matches_record(record: CandidateRecord, evidence: CandidateEvidence) -> bool:
    """Require the full local evidence tuple, including source and walkthrough, to agree."""

    if record.marketing_version != evidence.marketing_version:
        return False
    metadata = record.metadata or {}
    expected_metadata = {
        "sourceRevision": evidence.source_revision,
        "producerBuild": evidence.producer_build,
        "producerEvidenceSha256": evidence.producer_evidence_sha256,
        "iosBuild": evidence.ios_build,
        "walkthroughPath": evidence.walkthrough_path,
        "walkthroughSha256": evidence.walkthrough_sha256,
    }
    return all(metadata.get(key) == value for key, value in expected_metadata.items())


def reconcile_candidate(
    ledger: CandidateLedger,
    journal: ReceiptJournal,
    evidence: CandidateEvidence,
    remote: RemoteCandidateState | None,
    *,
    now: datetime | None = None,
) -> dict[str, Any]:
    """Reconcile candidate, ASC facts, and the durable receipt without allocation.

    Calling this after a restarted ``uploading`` attempt can only converge to an
    existing uploaded build; it never creates a build or replacement candidate.
    """

    timestamp = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    record = ledger.load()
    if record is None:
        raise ReconciliationError("candidate_missing", {"error_class": "candidate_missing"})
    if record.build is None or evidence.ios_build != record.build:
        raise _reject(record, evidence, "build_mismatch", timestamp)
    if (
        evidence.project_sha256 != record.project_sha256
        or evidence.ipa_sha256 != record.artifact_sha256
    ):
        raise _reject(record, evidence, "evidence_mismatch", timestamp)
    if not _evidence_matches_record(record, evidence):
        raise _reject(record, evidence, "evidence_mismatch", timestamp)
    if remote is None:
        raise _reject(record, evidence, "remote_unavailable", timestamp)
    if remote.build != record.build:
        raise _reject(record, evidence, "remote_build_mismatch", timestamp)
    if remote.processing_state.upper() != "VALID":
        raise _reject(record, evidence, "remote_processing_mismatch", timestamp)

    existing = journal.load()
    expected_key = candidate_idempotency_key(record)
    if existing is not None:
        expected_receipt_facts = {
            "candidate_id": record.candidate_id,
            "idempotency_key": expected_key,
            "build": record.build,
            "processing_state": remote.processing_state,
            "group_id": remote.group_id,
            "group_name": remote.group_name,
            "assigned": remote.assigned,
            "artifact_sha256": record.artifact_sha256,
            "producer_evidence_sha256": evidence.producer_evidence_sha256,
            "walkthrough_sha256": evidence.walkthrough_sha256,
            "available_at": remote.available_at,
            "expires_at": remote.expires_at,
        }
        progressing_assignment = (
            existing["state"] == CandidateState.UPLOADED_UNASSIGNED
            and existing["assigned"] is False
            and remote.assigned is True
        )
        comparison_fields = set(expected_receipt_facts)
        if progressing_assignment:
            comparison_fields.remove("assigned")
        if any(existing[field] != expected_receipt_facts[field] for field in comparison_fields):
            raise _reject(record, evidence, "journal_remote_mismatch", timestamp)

    if record.state == CandidateState.UPLOADING:
        record = ledger.transition(CandidateState.UPLOADED_UNASSIGNED)
    if remote.assigned and record.state == CandidateState.UPLOADED_UNASSIGNED:
        record = ledger.transition(CandidateState.ASSIGNED)
    elif not remote.assigned and record.state == CandidateState.ASSIGNED:
        raise _reject(record, evidence, "remote_assignment_mismatch", timestamp)
    elif record.state not in {CandidateState.UPLOADED_UNASSIGNED, CandidateState.ASSIGNED}:
        raise _reject(record, evidence, "candidate_state_mismatch", timestamp)

    receipt = _receipt(record, evidence, remote, state=record.state, now=timestamp)
    journal.write(receipt)
    return receipt
