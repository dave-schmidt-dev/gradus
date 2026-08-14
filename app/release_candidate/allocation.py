"""Durable, non-secret identity allocation records.

The ASC build number is allocated before the source/candidate freeze.  A crash
in that small window must be resumable without asking ASC for another number.
This module intentionally stores only public identity and digest metadata.
"""

from __future__ import annotations

import json
import os
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .ledger import CandidateError

ALLOCATION_STATE = "allocated-but-unfrozen"


@dataclass(frozen=True)
class AllocatedIdentity:
    """An ASC identity persisted before the source is frozen."""

    candidate_id: str
    build: int
    marketing_version: str
    allocated_at: str
    state: str = ALLOCATION_STATE

    def to_dict(self) -> dict[str, Any]:
        return {
            "candidateId": self.candidate_id,
            "build": self.build,
            "marketingVersion": self.marketing_version,
            "allocatedAt": self.allocated_at,
            "state": self.state,
        }


def _validate(data: dict[str, Any]) -> AllocatedIdentity:
    if data.get("state") != ALLOCATION_STATE:
        raise CandidateError("identity allocation record is not resumable")
    candidate_id = data.get("candidateId")
    version = data.get("marketingVersion")
    allocated_at = data.get("allocatedAt")
    build = data.get("build")
    if (
        not isinstance(candidate_id, str)
        or not candidate_id.strip()
        or isinstance(build, bool)
        or not isinstance(build, int)
        or build < 1
        or not isinstance(version, str)
        or not version.strip()
        or not isinstance(allocated_at, str)
        or not allocated_at.strip()
    ):
        raise CandidateError("identity allocation record is malformed")
    return AllocatedIdentity(candidate_id, build, version, allocated_at)


def load(path: str | Path) -> AllocatedIdentity | None:
    """Read an allocated-before-freeze record, if present."""

    record_path = Path(path)
    if not record_path.exists():
        return None
    try:
        with record_path.open(encoding="utf-8") as stream:
            data = json.load(stream)
    except (OSError, json.JSONDecodeError) as exc:
        raise CandidateError("identity allocation record is unreadable") from exc
    if not isinstance(data, dict):
        raise CandidateError("identity allocation record is malformed")
    return _validate(data)


def persist(
    path: str | Path,
    *,
    candidate_id: str,
    build: int,
    marketing_version: str,
    allocated_at: str | None = None,
) -> AllocatedIdentity:
    """Atomically persist one allocation, rejecting a different retry."""

    record_path = Path(path)
    existing = load(record_path)
    timestamp = allocated_at or datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    candidate = AllocatedIdentity(candidate_id, build, marketing_version, timestamp)
    if existing is not None:
        if existing != candidate:
            raise CandidateError("a different identity is already allocated; reconcile it first")
        return existing
    if build < 1 or not candidate_id or not marketing_version:
        raise CandidateError("identity allocation requires candidate, build, and version")
    record_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{record_path.name}.", dir=record_path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(candidate.to_dict(), stream, sort_keys=True, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, record_path)
        directory_fd = os.open(record_path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise
    return candidate


def reconcile(path: str | Path, *, candidate_id: str, build: int) -> AllocatedIdentity:
    """Confirm an exact remote identity before allowing a resumed freeze."""

    record = load(path)
    if record is None:
        raise CandidateError("identity allocation record is missing")
    if record.candidate_id != candidate_id or record.build != build:
        raise CandidateError("allocated identity does not match the candidate")
    return record
