#!/usr/bin/env python3
"""Emit source-bound local staging readiness for the central release runner."""

from __future__ import annotations

import hashlib
import json
import os
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

_CANDIDATE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
_HEX64 = re.compile(r"^[0-9a-f]{64}$")


def build_proof(manifest_path: Path, *, now: datetime | None = None) -> dict[str, Any]:
    """Build a short-lived proof bound to one immutable candidate manifest."""

    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise ValueError("readiness-manifest-unavailable")
    raw = manifest_path.read_bytes()
    manifest = json.loads(raw)
    candidate_id = manifest.get("candidateId")
    source_digest = manifest.get("sourceSnapshot", {}).get("sha256")
    if not isinstance(candidate_id, str) or not _CANDIDATE.fullmatch(candidate_id):
        raise ValueError("readiness-candidate-invalid")
    if not isinstance(source_digest, str) or not _HEX64.fullmatch(source_digest):
        raise ValueError("readiness-source-invalid")
    issued = now or datetime.now(timezone.utc)
    expires = issued + timedelta(hours=6)
    return {
        "proofVersion": "1.0.0",
        "operationClass": "readiness",
        "candidateId": candidate_id,
        "sourceDigest": source_digest,
        "result": "passed",
        "issuedAt": issued.isoformat().replace("+00:00", "Z"),
        "expiresAt": expires.isoformat().replace("+00:00", "Z"),
        "evidenceSha256": hashlib.sha256(raw).hexdigest(),
    }


def write_proof(destination: Path, proof: dict[str, Any]) -> None:
    """Atomically persist one runner-consumable readiness proof."""

    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.tmp")
    encoded = json.dumps(proof, sort_keys=True, separators=(",", ":")).encode() + b"\n"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = -1
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def main() -> int:
    """Read the declared manifest and persist its candidate-bound proof."""

    value = os.environ.get("READINESS_MANIFEST")
    if not value or "\x00" in value:
        return 4
    root = Path(__file__).resolve().parent.parent
    manifest_path = Path(value).resolve(strict=False)
    expected_root = (root / ".git/release-state/gradus-ios/candidates").resolve()
    try:
        manifest_path.relative_to(expected_root)
        proof = build_proof(manifest_path)
        candidate_id = proof["candidateId"]
        destination = root / ".release-state" / "evidence" / candidate_id / "readiness.json"
        write_proof(destination, proof)
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        return 4
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
