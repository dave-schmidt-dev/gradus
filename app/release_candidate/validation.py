"""Deterministic, non-network validation for a release candidate tuple."""

from __future__ import annotations

import hashlib
import re
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


class ValidationError(ValueError):
    """Raised when candidate evidence is absent, stale, or inconsistent."""


_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_VERSION = re.compile(r"^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$")


def sha256_file(path: str | Path) -> str:
    """Return a file digest without retaining its contents."""
    digest = hashlib.sha256()
    try:
        with Path(path).open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as exc:
        raise ValidationError(f"artifact is unreadable: {path}") from exc
    return digest.hexdigest()


def _value(data: Mapping[str, Any], *names: str) -> Any:
    for name in names:
        if name in data:
            return data[name]
    return None


def _required_text(data: Mapping[str, Any], label: str, *names: str) -> str:
    value = _value(data, *names)
    if not isinstance(value, str) or not value.strip():
        raise ValidationError(f"missing {label}")
    return value.strip()


def _sha(data: Mapping[str, Any], label: str, *names: str) -> str:
    value = _required_text(data, label, *names)
    if not _SHA256.fullmatch(value):
        raise ValidationError(f"{label} is not a SHA-256 digest")
    return value


def _positive_int(data: Mapping[str, Any], label: str, *names: str) -> int:
    value = _value(data, *names)
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise ValidationError(f"{label} must be an integer")
    if isinstance(value, str) and (not value.isdigit() or value.startswith("0")):
        raise ValidationError(f"{label} must be a positive integer")
    result = int(value)
    if result < 1:
        raise ValidationError(f"{label} must be a positive integer")
    return result


def _timestamp(data: Mapping[str, Any], label: str, *names: str) -> datetime:
    raw = _required_text(data, label, *names)
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ValidationError(f"{label} is not an ISO-8601 timestamp") from exc
    if parsed.tzinfo is None:
        raise ValidationError(f"{label} must include a timezone")
    return parsed.astimezone(timezone.utc)


def _version(data: Mapping[str, Any], label: str, *names: str) -> str:
    value = _required_text(data, label, *names)
    if not _VERSION.fullmatch(value):
        raise ValidationError(f"{label} must be MAJOR.MINOR.PATCH numeric text")
    return value


@dataclass(frozen=True)
class CandidateEvidence:
    """The complete non-secret evidence tuple required before preparation."""

    source_revision: str
    project_sha256: str
    marketing_version: str
    producer_build: int
    producer_evidence_sha256: str
    ios_build: int
    ipa_sha256: str
    walkthrough_path: str
    walkthrough_sha256: str
    created_at: datetime
    producer_published_at: datetime

    @classmethod
    def from_mapping(
        cls,
        data: Mapping[str, Any],
        *,
        now: datetime | None = None,
        max_producer_age: timedelta = timedelta(seconds=600),
        expected_source_revision: str | None = None,
        expected_project_sha256: str | None = None,
        expected_ipa_sha256: str | None = None,
    ) -> CandidateEvidence:
        if not isinstance(data, Mapping):
            raise ValidationError("candidate evidence must be an object")
        source = _required_text(data, "source revision", "sourceRevision", "source_revision")
        project = _sha(data, "project digest", "projectSha256", "project_sha256")
        version = _version(data, "marketing version", "marketingVersion", "marketing_version")
        mac_version = _value(data, "macMarketingVersion", "mac_marketing_version")
        ios_version = _value(data, "iosMarketingVersion", "ios_marketing_version")
        if (
            mac_version is not None
            and mac_version != version
            or ios_version is not None
            and ios_version != version
        ):
            raise ValidationError("Mac and iOS marketing versions must match")
        producer_build = _positive_int(data, "producer build", "producerBuild", "producer_build")
        producer_digest = _sha(
            data, "producer evidence digest", "producerEvidenceSha256", "producer_evidence_sha256"
        )
        ios_build = _positive_int(data, "iOS build", "iosBuild", "ios_build")
        ipa = _sha(data, "IPA digest", "ipaSha256", "ipa_sha256")
        walkthrough_path = _required_text(
            data, "walkthrough path", "walkthroughPath", "walkthrough_path"
        )
        walkthrough = _sha(data, "walkthrough digest", "walkthroughSha256", "walkthrough_sha256")
        created = _timestamp(data, "created timestamp", "createdAt", "created_at")
        published = _timestamp(
            data,
            "producer publish timestamp",
            "producerPublishedAt",
            "producer_published_at",
            "publishedAt",
            "published_at",
        )
        reference = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
        if published > reference or reference - published > max_producer_age:
            raise ValidationError("producer evidence is stale or from the future")
        if expected_source_revision is not None and source != expected_source_revision:
            raise ValidationError("source revision mismatch")
        if expected_project_sha256 is not None and project != expected_project_sha256:
            raise ValidationError("project digest mismatch")
        if expected_ipa_sha256 is not None and ipa != expected_ipa_sha256:
            raise ValidationError("IPA digest mismatch")
        actual_walkthrough = sha256_file(walkthrough_path)
        if actual_walkthrough != walkthrough:
            raise ValidationError("walkthrough digest does not match file bytes")
        return cls(
            source,
            project,
            version,
            producer_build,
            producer_digest,
            ios_build,
            ipa,
            walkthrough_path,
            walkthrough,
            created,
            published,
        )


def validate_candidate_evidence(data: Mapping[str, Any], **kwargs: Any) -> CandidateEvidence:
    """Validate and return a typed evidence tuple; never contacts ASC."""
    return CandidateEvidence.from_mapping(data, **kwargs)
