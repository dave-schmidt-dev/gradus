"""Credential-free, atomic Codex banked-count sidecar contract."""

from __future__ import annotations

import json
import os
import tempfile
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

MAX_BANKED_COUNT = 1_000_000
SIDECAR_NAME = "banked-observation-v1.json"


@dataclass(frozen=True, repr=False, slots=True)
class BankedCandidate:
    """Private in-memory result from the final successful usage GET."""

    count: int
    user_id: str = field(repr=False)
    account_id: str | None = field(repr=False)
    observed_at: datetime


def bounded_count(value: object) -> int | None:
    """Reject bool, fractions, text, negatives, and implausibly large counts."""
    return value if type(value) is int and 0 <= value <= MAX_BANKED_COUNT else None


def aware_iso(value: object) -> bool:
    if not isinstance(value, str) or not value:
        return False
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    return parsed.tzinfo is not None and parsed.utcoffset() is not None


def validated_sidecar(value: object) -> dict[str, object] | None:
    """Accept the complete public sidecar shape, with no extra fields."""
    if not isinstance(value, dict) or set(value) != {
        "schema_version",
        "count",
        "generation",
        "snapshot_updated_at",
        "observed_at",
    }:
        return None
    if type(value["schema_version"]) is not int or value["schema_version"] != 1:
        return None
    if bounded_count(value["count"]) is None:
        return None
    try:
        if str(uuid.UUID(value["generation"])) != value["generation"]:
            return None
    except (ValueError, TypeError, AttributeError):
        return None
    if not aware_iso(value["snapshot_updated_at"]) or not aware_iso(value["observed_at"]):
        return None
    return value


def write_sidecar(
    path: Path, *, count: int, generation: str, snapshot_updated_at: str, observed_at: str
) -> dict[str, object]:
    """Write one validated sidecar by atomic 0600 replacement."""
    value = validated_sidecar(
        {
            "schema_version": 1,
            "count": count,
            "generation": generation,
            "snapshot_updated_at": snapshot_updated_at,
            "observed_at": observed_at,
        }
    )
    if value is None:
        raise ValueError("invalid banked observation")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        return value
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
