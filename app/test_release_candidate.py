from __future__ import annotations

import hashlib
import json
from pathlib import Path

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


def test_assigned_rollover_archives_workspace_and_creates_fresh_candidate(tmp_path):
    ledger = _ledger(tmp_path)
    workspace = tmp_path / ".release-state" / "candidates" / "candidate-1"
    workspace.mkdir(parents=True)
    (workspace / "candidate-evidence.json").write_text('{"candidateId":"candidate-1"}\n')
    (workspace / "receipt.json").write_text('{"candidate_id":"candidate-1"}\n')
    ledger.prepare(
        "candidate-1",
        source_sha256="a" * 64,
        project_sha256="b" * 64,
        artifact_sha256="c" * 64,
        build=7,
        marketing_version="1.2.3",
        metadata={
            "candidateWorkspace": str(workspace),
            "receiptJournalPath": str(workspace / "receipt.json"),
        },
    )
    ledger.transition(CandidateState.UPLOADING)
    ledger.transition(CandidateState.UPLOADED_UNASSIGNED)
    ledger.transition(CandidateState.ASSIGNED)

    replacement_workspace = tmp_path / ".release-state" / "candidates" / "candidate-2"
    replacement = ledger.prepare(
        "candidate-2",
        source_sha256="d" * 64,
        project_sha256="e" * 64,
        artifact_sha256="f" * 64,
        build=8,
        marketing_version="1.2.3",
        metadata={"candidateWorkspace": str(replacement_workspace)},
        supersedes_reason="release-blocking correction",
        archive_root=tmp_path / ".release-state" / "archived",
    )

    assert replacement.state == CandidateState.PREPARED
    assert ledger.load().candidate_id == "candidate-2"
    archived = tmp_path / ".release-state" / "archived" / "candidate-1"
    archived_record = CandidateLedger(archived / "candidate.json").load()
    assert archived_record.state == CandidateState.SUPERSEDED
    assert archived_record.metadata["supersededReason"] == "release-blocking correction"
    assert archived_record.metadata["archivedReceiptJournalPath"].endswith(
        "candidate-workspace/receipt.json"
    )
    assert (archived / "candidate-workspace" / "candidate-evidence.json").is_file()
    assert (archived / "candidate-workspace" / "receipt.json").is_file()


def test_assigned_rollover_requires_explicit_reason_and_archive_root(tmp_path):
    ledger = _ledger(tmp_path)
    workspace = tmp_path / "candidate"
    workspace.mkdir()
    ledger.prepare(
        "candidate-1",
        source_sha256="a" * 64,
        project_sha256="b" * 64,
        artifact_sha256="c" * 64,
        build=7,
        marketing_version="1.2.3",
        metadata={"candidateWorkspace": str(workspace)},
    )
    for state in (
        CandidateState.UPLOADING,
        CandidateState.UPLOADED_UNASSIGNED,
        CandidateState.ASSIGNED,
    ):
        ledger.transition(state)
    with pytest.raises(CandidateError, match="explicit supersession reason"):
        ledger.prepare(
            "candidate-2",
            source_sha256="d" * 64,
            project_sha256="e" * 64,
            artifact_sha256="f" * 64,
            build=8,
            marketing_version="1.2.3",
            metadata={},
        )


@pytest.mark.parametrize("reason", ["", "   ", "bad\nreason", "x" * 501])
def test_assigned_rollover_rejects_invalid_reason(tmp_path, reason):
    ledger = _ledger(tmp_path)
    workspace = tmp_path / "candidate"
    workspace.mkdir()
    ledger.prepare(
        "candidate-1",
        source_sha256="a" * 64,
        project_sha256="b" * 64,
        artifact_sha256="c" * 64,
        build=7,
        marketing_version="1.2.3",
        metadata={"candidateWorkspace": str(workspace)},
    )
    for state in (
        CandidateState.UPLOADING,
        CandidateState.UPLOADED_UNASSIGNED,
        CandidateState.ASSIGNED,
    ):
        ledger.transition(state)
    with pytest.raises(CandidateError):
        ledger.archive_assigned(tmp_path / ".release-state" / "archived", reason)


def test_assigned_rollover_rejects_archive_collision(tmp_path):
    ledger = _ledger(tmp_path)
    workspace = tmp_path / "candidate"
    workspace.mkdir()
    ledger.prepare(
        "candidate-1",
        source_sha256="a" * 64,
        project_sha256="b" * 64,
        artifact_sha256="c" * 64,
        build=7,
        marketing_version="1.2.3",
        metadata={"candidateWorkspace": str(workspace)},
    )
    for state in (
        CandidateState.UPLOADING,
        CandidateState.UPLOADED_UNASSIGNED,
        CandidateState.ASSIGNED,
    ):
        ledger.transition(state)
    archive_root = tmp_path / ".release-state" / "archived"
    (archive_root / "candidate-1").mkdir(parents=True)
    with pytest.raises(CandidateError, match="archive already exists"):
        ledger.archive_assigned(archive_root, "release-blocking correction")
    assert ledger.load().state == CandidateState.ASSIGNED


def test_archive_failure_after_active_unlink_preserves_archive(tmp_path, monkeypatch):
    ledger = _ledger(tmp_path)
    workspace = tmp_path / "candidate"
    workspace.mkdir()
    ledger.prepare(
        "candidate-1",
        source_sha256="a" * 64,
        project_sha256="b" * 64,
        artifact_sha256="c" * 64,
        build=7,
        marketing_version="1.2.3",
        metadata={"candidateWorkspace": str(workspace)},
    )
    for state in (
        CandidateState.UPLOADING,
        CandidateState.UPLOADED_UNASSIGNED,
        CandidateState.ASSIGNED,
    ):
        ledger.transition(state)
    original_unlink = Path.unlink

    def unlink_then_fail(path, *args, **kwargs):
        original_unlink(path, *args, **kwargs)
        raise OSError("simulated post-unlink failure")

    monkeypatch.setattr(Path, "unlink", unlink_then_fail)
    archive_root = tmp_path / ".release-state" / "archived"
    with pytest.raises(OSError, match="post-unlink"):
        ledger.archive_assigned(archive_root, "release-blocking correction")
    archived = archive_root / "candidate-1"
    assert (archived / "candidate.json").is_file()
    assert not ledger.path.exists()
