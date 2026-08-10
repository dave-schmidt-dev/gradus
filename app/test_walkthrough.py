"""Hermetic tests for candidate-current walkthrough evidence."""

from __future__ import annotations

import hashlib
import json
from datetime import date

import pytest
from release_candidate.ledger import CandidateLedger, CandidateState
from release_candidate.walkthrough import (
    WalkthroughError,
    default_manifest,
    generate_walkthrough,
    validate_manifest,
)


def _sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _candidate(tmp_path):
    artifact = tmp_path / "GradusiOS.ipa"
    artifact.write_bytes(b"candidate-artifact")
    ledger = CandidateLedger(tmp_path / ".release-state" / "candidate.json")
    ledger.create(
        "candidate-42",
        source=b"source",
        project=b"project",
        artifact=artifact.read_bytes(),
        build=42,
        marketing_version="1.6.8",
        metadata={"sourceRevision": "revision-42"},
    )
    ledger.transition(CandidateState.VALIDATED)
    ledger.transition(CandidateState.PREPARED)
    return ledger, artifact


def test_current_walkthrough_is_dated_hashed_and_bound_to_ledger(tmp_path):
    ledger, artifact = _candidate(tmp_path)
    output = tmp_path / "walkthrough.md"
    result = generate_walkthrough(
        ledger,
        artifact,
        source_revision="revision-42",
        output_path=output,
        generated_on=date(2026, 8, 9),
    )
    assert result["artifactSha256"] == _sha(artifact)
    assert result["walkthroughSha256"] == _sha(output)
    assert result["generatedOn"] == "2026-08-09"
    record = ledger.load()
    assert record.metadata["walkthrough"]["sha256"] == result["walkthroughSha256"]
    assert record.metadata["walkthroughSha256"] == result["walkthroughSha256"]
    text = output.read_text()
    assert "Onboarding" in text and "Reachable screens and controls" in text
    assert "Role and permission differences" in text and "System-owned sheets" in text
    assert "App Store submission and public release are excluded" in text


def test_missing_coverage_and_mismatched_tuple_fail_without_claim(tmp_path):
    ledger, artifact = _candidate(tmp_path)
    with pytest.raises(WalkthroughError):
        generate_walkthrough(
            ledger, artifact, source_revision="wrong", output_path=tmp_path / "wrong.md"
        )
    with pytest.raises(WalkthroughError):
        generate_walkthrough(
            ledger,
            artifact,
            candidate={
                "candidateId": "candidate-42",
                "sourceRevision": "revision-42",
                "projectSha256": ledger.load().project_sha256,
                "artifactSha256": "0" * 64,
                "build": 42,
                "marketingVersion": "1.6.8",
            },
            output_path=tmp_path / "wrong-artifact.md",
        )
    manifest = default_manifest()
    manifest["states"] = [state for state in manifest["states"] if state["id"] != "recovery"]
    with pytest.raises(WalkthroughError):
        generate_walkthrough(
            ledger,
            artifact,
            source_revision="revision-42",
            manifest=manifest,
            output_path=tmp_path / "incomplete.md",
        )
    assert not (tmp_path / "wrong.md").exists()


def test_duplicate_controls_and_terminal_candidates_are_rejected(tmp_path):
    ledger, artifact = _candidate(tmp_path)
    manifest = json.loads(json.dumps(default_manifest()))
    manifest["screens"][0]["controls"].append(manifest["screens"][0]["controls"][0])
    with pytest.raises(WalkthroughError):
        validate_manifest(manifest)
    ledger.transition(CandidateState.FAILED)
    with pytest.raises(WalkthroughError):
        generate_walkthrough(
            ledger, artifact, source_revision="revision-42", output_path=tmp_path / "failed.md"
        )


def test_walkthrough_rejects_non_semver_marketing_version(tmp_path):
    ledger = CandidateLedger(tmp_path / ".release-state" / "candidate.json")
    artifact = tmp_path / "artifact.bin"
    artifact.write_bytes(b"candidate-artifact")
    ledger.create(
        "candidate-43",
        source=b"source",
        project=b"project",
        artifact=artifact.read_bytes(),
        build=43,
        marketing_version="1.2.3.4",
        metadata={"sourceRevision": "revision-43"},
    )
    with pytest.raises(WalkthroughError, match="marketing version"):
        generate_walkthrough(
            ledger,
            artifact,
            source_revision="revision-43",
            output_path=tmp_path / "invalid-version.md",
        )
