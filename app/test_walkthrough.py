"""Hermetic tests for screenshot-sealed candidate walkthrough evidence."""

from __future__ import annotations

import hashlib
import json
import struct
import zlib

import pytest
from release_candidate.ledger import CandidateLedger, CandidateState
from release_candidate.walkthrough import (
    WalkthroughError,
    capture_routes,
    default_manifest,
    generate_walkthrough,
    record_owner_review,
    validate_owner_review,
    validate_source_coverage,
)


def _png() -> bytes:
    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
        )

    header = struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress((b"\x00" + b"\x20\x40\x60" * 2) * 2))
        + chunk(b"IEND", b"")
    )


def _candidate(tmp_path):
    artifact = tmp_path / "GradusiOS.ipa"
    artifact.write_bytes(b"candidate-artifact")
    ledger = CandidateLedger(tmp_path / "candidate.json")
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
    screenshots = tmp_path / "screenshots"
    screenshots.mkdir()
    for route in capture_routes():
        (screenshots / route["image"]).write_bytes(_png())
    return ledger, artifact, screenshots


def test_html_contains_every_image_and_candidate_binding(tmp_path):
    ledger, artifact, screenshots = _candidate(tmp_path)
    output = tmp_path / "walkthrough.html"
    result = generate_walkthrough(
        ledger,
        artifact,
        screenshots_path=screenshots,
        output_path=output,
        source_revision="revision-42",
    )
    html = output.read_text(encoding="utf-8")
    record = ledger.load()
    assert result["screenCount"] == len(default_manifest()["screens"])
    assert html.count("data:image/png;base64,") == result["screenCount"]
    for value in (
        record.candidate_id,
        "revision-42",
        record.project_sha256,
        record.artifact_sha256,
    ):
        assert value in html
    assert hashlib.sha256(output.read_bytes()).hexdigest() == result["sha256"]
    assert record.metadata["walkthrough"] == result


def test_zero_screens_and_missing_image_fail_closed(tmp_path):
    ledger, artifact, screenshots = _candidate(tmp_path)
    empty = default_manifest()
    empty["screens"] = []
    with pytest.raises(WalkthroughError, match="at least one screen"):
        generate_walkthrough(
            ledger,
            artifact,
            screenshots_path=screenshots,
            output_path=tmp_path / "empty.html",
            manifest=empty,
        )
    (screenshots / capture_routes()[0]["image"]).unlink()
    with pytest.raises(WalkthroughError, match="walkthrough-image-missing"):
        generate_walkthrough(
            ledger,
            artifact,
            screenshots_path=screenshots,
            output_path=tmp_path / "missing.html",
        )


def test_source_backed_route_and_control_coverage_fails_closed(tmp_path):
    validate_source_coverage()
    with pytest.raises(WalkthroughError, match="source coverage problem"):
        validate_source_coverage(tmp_path)


def test_stale_candidate_source_and_artifact_are_rejected(tmp_path):
    ledger, artifact, screenshots = _candidate(tmp_path)
    with pytest.raises(WalkthroughError, match="source revision mismatch"):
        generate_walkthrough(
            ledger,
            artifact,
            screenshots_path=screenshots,
            output_path=tmp_path / "wrong-source.html",
            source_revision="wrong",
        )
    artifact.write_bytes(b"changed")
    with pytest.raises(WalkthroughError, match="artifact bytes"):
        generate_walkthrough(
            ledger,
            artifact,
            screenshots_path=screenshots,
            output_path=tmp_path / "wrong-artifact.html",
        )


def test_owner_acknowledgement_is_explicit_and_exactly_bound(tmp_path):
    ledger, artifact, screenshots = _candidate(tmp_path)
    output = tmp_path / "walkthrough.html"
    generate_walkthrough(ledger, artifact, screenshots_path=screenshots, output_path=output)
    approval = tmp_path / "walkthrough-owner-review.json"
    with pytest.raises(WalkthroughError, match="missing"):
        validate_owner_review(ledger, approval)
    with pytest.raises(WalkthroughError, match="David"):
        record_owner_review(ledger, approval, reviewed_by="Reviewer")
    proof = record_owner_review(ledger, approval, reviewed_by="David")
    assert validate_owner_review(ledger, approval) == proof
    tampered = json.loads(approval.read_text())
    tampered["artifactSha256"] = "0" * 64
    approval.write_text(json.dumps(tampered), encoding="utf-8")
    with pytest.raises(WalkthroughError, match="does not match"):
        validate_owner_review(ledger, approval)


def test_owner_gate_rejects_stale_candidate_binding(tmp_path):
    ledger, artifact, screenshots = _candidate(tmp_path)
    output = tmp_path / "walkthrough.html"
    generate_walkthrough(ledger, artifact, screenshots_path=screenshots, output_path=output)
    approval = tmp_path / "walkthrough-owner-review.json"
    record_owner_review(ledger, approval, reviewed_by="David")
    record = ledger.load()
    record.metadata["walkthrough"]["projectSha256"] = "0" * 64
    ledger.write(record)
    with pytest.raises(WalkthroughError, match="binding is stale"):
        validate_owner_review(ledger, approval)
