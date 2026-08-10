from __future__ import annotations

import hashlib
from datetime import datetime, timezone
from pathlib import Path

import pytest
from release_candidate.validation import ValidationError, validate_candidate_evidence
from release_candidate.version_policy import (
    FixtureASCVersionHistory,
    VersionPolicyError,
    require_new_marketing_version,
)

NOW = datetime(2026, 8, 9, 20, 0, tzinfo=timezone.utc)
SHA = "a" * 64


def evidence(tmp_path):
    walkthrough = tmp_path / "walkthrough.md"
    walkthrough.write_text("candidate")
    walkthrough_sha256 = hashlib.sha256(walkthrough.read_bytes()).hexdigest()
    return {
        "sourceRevision": "abc123",
        "projectSha256": SHA,
        "marketingVersion": "2.0.0",
        "macMarketingVersion": "2.0.0",
        "iosMarketingVersion": "2.0.0",
        "producerBuild": 4,
        "producerEvidenceSha256": SHA,
        "iosBuild": 9,
        "ipaSha256": SHA,
        "walkthroughPath": str(walkthrough),
        "walkthroughSha256": walkthrough_sha256,
        "createdAt": "2026-08-09T19:55:00Z",
        "producerPublishedAt": "2026-08-09T19:55:30Z",
    }


def test_complete_evidence_and_mismatches(tmp_path):
    data = evidence(tmp_path)
    assert validate_candidate_evidence(data, now=NOW).marketing_version == "2.0.0"
    for key, expected in (
        ("sourceRevision", "other"),
        ("projectSha256", "b" * 64),
        ("ipaSha256", "b" * 64),
    ):
        changed = dict(data)
        changed[key] = expected
        with pytest.raises(ValidationError):
            validate_candidate_evidence(
                changed,
                now=NOW,
                expected_source_revision="abc123" if key == "sourceRevision" else None,
                expected_project_sha256=SHA if key == "projectSha256" else None,
                expected_ipa_sha256=SHA if key == "ipaSha256" else None,
            )


def test_missing_stale_and_bad_build_evidence(tmp_path):
    data = evidence(tmp_path)
    for key in ("ipaSha256", "walkthroughPath", "producerBuild"):
        changed = dict(data)
        changed.pop(key)
        with pytest.raises(ValidationError):
            validate_candidate_evidence(changed, now=NOW)
    stale = dict(data)
    stale["producerPublishedAt"] = "2026-08-09T18:00:00Z"
    with pytest.raises(ValidationError):
        validate_candidate_evidence(stale, now=NOW)
    four_component_version = dict(data)
    four_component_version["marketingVersion"] = "2.0.0.1"
    with pytest.raises(ValidationError):
        validate_candidate_evidence(four_component_version, now=NOW)


def test_walkthrough_digest_is_bound_to_exact_file_bytes(tmp_path):
    data = evidence(tmp_path)
    missing = dict(data)
    missing["walkthroughPath"] = str(tmp_path / "missing.md")
    with pytest.raises(ValidationError, match="artifact is unreadable"):
        validate_candidate_evidence(missing, now=NOW)
    changed = dict(data)
    changed["walkthroughSha256"] = SHA
    with pytest.raises(ValidationError, match="walkthrough digest"):
        validate_candidate_evidence(changed, now=NOW)
    Path(data["walkthroughPath"]).write_text("changed")
    with pytest.raises(ValidationError, match="walkthrough digest"):
        validate_candidate_evidence(data, now=NOW)


def pages():
    return [
        {
            "data": [
                {"id": "b2", "attributes": {"version": "1.10.0", "buildNumber": "12"}},
                {"id": "b1", "attributes": {"version": "1.2.0", "buildNumber": "9"}},
            ]
        },
        {"data": [{"id": "b3", "attributes": {"version": "1.10.0", "buildNumber": "13"}}]},
    ]


def test_fixture_history_paginates_and_sorts_numerically():
    history = FixtureASCVersionHistory(pages())
    assert [(b.version, b.build) for b in history.builds()] == [
        ("1.2.0", 9),
        ("1.10.0", 12),
        ("1.10.0", 13),
    ]
    assert history.newest_version() == "1.10.0"


def test_history_rejects_duplicate_malformed_and_live_transport():
    with pytest.raises(VersionPolicyError):
        FixtureASCVersionHistory(
            pages()
            + [{"data": [{"id": "b2", "attributes": {"version": "1.10.0", "buildNumber": 12}}]}]
        ).builds()
    with pytest.raises(VersionPolicyError):
        FixtureASCVersionHistory(
            [{"data": [{"id": "x", "attributes": {"version": "bad", "buildNumber": 1}}]}]
        ).builds()
    with pytest.raises(VersionPolicyError):
        FixtureASCVersionHistory([], transport=object())


def test_version_policy_strict_increase_and_supersedes():
    history = FixtureASCVersionHistory(pages())
    assert require_new_marketing_version(history, "1.11.0") == (1, 11, 0)
    with pytest.raises(VersionPolicyError):
        require_new_marketing_version(history, "1.10.0")
    assert require_new_marketing_version(
        history, "1.10.0", supersedes_reason="release-blocking correction"
    ) == (1, 10, 0)
    with pytest.raises(VersionPolicyError):
        require_new_marketing_version(history, "1.10.0", supersedes_reason="")
