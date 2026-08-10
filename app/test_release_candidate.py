from __future__ import annotations

import hashlib
import json

import pytest
from release_candidate.ledger import CandidateError, CandidateLedger, CandidateState


def _ledger(tmp_path):
    return CandidateLedger(tmp_path / ".release-state" / "candidate.json")


def _create(ledger):
    return ledger.create(
        "candidate-1", source=b"source", project=b"project", artifact=b"artifact", build=7
    )


def test_create_binds_digests_and_atomic_json(tmp_path):
    ledger = _ledger(tmp_path)
    record = _create(ledger)
    assert record.source_sha256 == hashlib.sha256(b"source").hexdigest()
    assert json.loads(ledger.path.read_text())["state"] == "draft"
    assert not list(ledger.path.parent.glob(".*.candidate.json.*"))


def test_invalid_transitions_are_rejected(tmp_path):
    ledger = _ledger(tmp_path)
    _create(ledger)
    with pytest.raises(CandidateError):
        ledger.transition(CandidateState.ASSIGNED)


def test_missing_evidence_and_digest_mismatch_are_rejected(tmp_path):
    ledger = _ledger(tmp_path)
    with pytest.raises(CandidateError):
        ledger.transition("validated")
    ledger_record = _create(ledger)
    payload = ledger_record.to_dict()
    payload["artifactSha256"] = "0" * 64
    ledger.path.write_text(json.dumps(payload))
    assert ledger.load().artifact_sha256 == "0" * 64
    with pytest.raises(CandidateError):
        ledger.transition("validated", artifactSha256="bad")


def test_transition_cannot_rewrite_immutable_candidate_tuple(tmp_path):
    ledger = _ledger(tmp_path)
    record = _create(ledger)
    immutable_updates = {
        "candidateId": "candidate-2",
        "sourceSha256": "b" * 64,
        "projectSha256": "c" * 64,
        "artifactSha256": "d" * 64,
        "build": 8,
        "marketingVersion": "2.0.0",
    }
    for field, value in immutable_updates.items():
        with pytest.raises(CandidateError):
            ledger.transition(CandidateState.VALIDATED, **{field: value})
    unchanged = ledger.transition(
        CandidateState.VALIDATED,
        candidate_id=record.candidate_id,
        source_sha256=record.source_sha256,
        project_sha256=record.project_sha256,
        artifact_sha256=record.artifact_sha256,
        build=record.build,
    )
    assert unchanged.candidate_id == record.candidate_id
    assert unchanged.state == CandidateState.VALIDATED


def test_transition_only_extends_metadata_and_rejects_replacement(tmp_path):
    ledger = CandidateLedger(tmp_path / "candidate.json")
    ledger.create(
        "candidate-1",
        source=b"source",
        project=b"project",
        artifact=b"artifact",
        metadata={"sourceRevision": "rev"},
    )
    updated = ledger.transition(
        "validated",
        metadata={"walkthroughSha256": "a" * 64, "walkthrough": {"path": "/tmp/walkthrough"}},
    )
    assert updated.metadata == {
        "sourceRevision": "rev",
        "walkthroughSha256": "a" * 64,
        "walkthrough": {"path": "/tmp/walkthrough"},
    }
    with pytest.raises(CandidateError):
        ledger.transition("prepared", metadata={"sourceRevision": "other"})


def test_prepare_is_restart_safe_and_rejects_mismatched_or_uploaded_candidate(tmp_path):
    ledger = _ledger(tmp_path)
    kwargs = {
        "source_sha256": "a" * 64,
        "project_sha256": "b" * 64,
        "artifact_sha256": "c" * 64,
        "build": 42,
        "marketing_version": "1.2.3",
        "metadata": {"sourceRevision": "revision", "walkthroughSha256": "d" * 64},
    }
    assert ledger.prepare("candidate-1", **kwargs).state == CandidateState.PREPARED
    assert ledger.prepare("candidate-1", **kwargs).state == CandidateState.PREPARED
    with pytest.raises(CandidateError, match="tuple mismatch"):
        ledger.prepare("candidate-1", **{**kwargs, "build": 43})
    ledger.transition(CandidateState.UPLOADING)
    ledger.transition(CandidateState.UPLOADED_UNASSIGNED)
    with pytest.raises(CandidateError, match="re-upload"):
        ledger.prepare("candidate-1", **kwargs)


def test_refresh_producer_evidence_preserves_initial_attestation_and_tuple(tmp_path):
    ledger = _ledger(tmp_path)
    kwargs = {
        "source_sha256": "a" * 64,
        "project_sha256": "b" * 64,
        "artifact_sha256": "c" * 64,
        "build": 42,
        "marketing_version": "1.2.3",
        "metadata": {
            "sourceRevision": "revision",
            "producerBuild": 7,
            "producerEvidenceSha256": "d" * 64,
            "producerPublishedAt": "2026-08-09T23:00:00Z",
            "iosBuild": 42,
        },
    }
    ledger.prepare("candidate-1", **kwargs)
    refreshed = ledger.refresh_producer_evidence("e" * 64, "2026-08-09T23:10:00Z")
    assert refreshed.artifact_sha256 == "c" * 64
    assert refreshed.metadata["initialProducerEvidenceSha256"] == "d" * 64
    assert refreshed.metadata["producerEvidenceSha256"] == "e" * 64
    assert refreshed.metadata["producerPublishedAt"] == "2026-08-09T23:10:00Z"


def test_non_integer_build_is_rejected(tmp_path):
    ledger = _ledger(tmp_path)
    with pytest.raises(CandidateError):
        ledger.create("x", source="a", project="b", artifact="c", build="7")


def test_credential_shaped_fields_and_values_are_rejected(tmp_path):
    ledger = _ledger(tmp_path)
    with pytest.raises(CandidateError):
        ledger.create("x", source="a", project="b", artifact="c", metadata={"apiKey": "x"})
    with pytest.raises(CandidateError):
        ledger.create("x", source="a", project="b", artifact="c", metadata={"note": "Bearer abc"})


def test_restart_preserves_uploaded_unassigned_and_rejects_replacement(tmp_path):
    ledger = _ledger(tmp_path)
    _create(ledger)
    for state in ("validated", "prepared", "uploading", "uploaded_unassigned"):
        ledger.transition(state)
    restarted = CandidateLedger(ledger.path)
    assert restarted.load().state == "uploaded_unassigned"
    with pytest.raises(CandidateError):
        restarted.allocate_replacement("candidate-2", source="x", project="y", artifact="z")
