#!/usr/bin/env python3
"""Emit source-bound local staging readiness for the central release runner."""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

_CANDIDATE = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
_HEX64 = re.compile(r"^[0-9a-f]{64}$")


def resolve_canonical_manifest(
    value: str,
    root: Path,
    *,
    runner: Any = subprocess.run,
) -> Path:
    """Resolve a candidate manifest beneath the checkout's Git common dir."""

    declared = Path(value)
    if declared.is_symlink():
        raise ValueError("readiness-manifest-unavailable")
    completed = runner(
        [
            "git",
            "-C",
            str(root),
            "rev-parse",
            "--path-format=absolute",
            "--git-common-dir",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    common_value = completed.stdout.strip() if completed.returncode == 0 else ""
    if not common_value or "\n" in common_value or "\x00" in common_value:
        raise ValueError("git-common-dir-unavailable")
    common_declared = Path(common_value)
    if not common_declared.is_absolute():
        raise ValueError("git-common-dir-unavailable")
    common_dir = common_declared.resolve(strict=True)
    if not common_dir.is_dir():
        raise ValueError("git-common-dir-unavailable")

    manifest_path = declared.resolve(strict=False)
    candidate_root = (common_dir / "release-state/gradus-ios/candidates").resolve(strict=False)
    try:
        relative = manifest_path.relative_to(candidate_root)
    except ValueError as exc:
        raise ValueError("readiness-manifest-outside-canonical-root") from exc
    if len(relative.parts) != 2 or relative.parts[1] != "manifest.json":
        raise ValueError("readiness-manifest-invalid-path")
    return manifest_path


def _manifest_binding(manifest_path: Path) -> tuple[bytes, str, str]:
    """Return validated immutable candidate-manifest binding fields."""

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
    return raw, candidate_id, source_digest


PROOF_VERSION = "2.0.0"
CONTRACT_REVISION = "2.0.0"
READINESS_PROOF_SCHEMA = "release.proof.readiness.v2"
LOCAL_GATE_PROOF_SCHEMA = "release.proof.local-gate.v2"


def execution_closure(
    proof_schema: str,
    configuration: str = "",
    *,
    contract_revision: str = CONTRACT_REVISION,
) -> str:
    """Compute the deterministic SHA-256 execution-closure discriminator."""

    if not isinstance(proof_schema, str) or not proof_schema:
        raise ValueError("invalid-proof-schema")
    if not isinstance(configuration, str):
        raise ValueError("invalid-configuration")
    if not isinstance(contract_revision, str) or not contract_revision:
        raise ValueError("invalid-contract-revision")
    payload = b"\0".join(
        (
            proof_schema.encode("utf-8"),
            configuration.encode("utf-8"),
            contract_revision.encode("utf-8"),
        )
    )
    return hashlib.sha256(payload).hexdigest()


def build_proof(
    manifest_path: Path,
    *,
    configuration: str = "",
    now: datetime | None = None,
    contract_revision: str = CONTRACT_REVISION,
) -> dict[str, Any]:
    """Build a typed v2 proof bound to one immutable candidate manifest."""

    raw, candidate_id, source_digest = _manifest_binding(manifest_path)
    observed = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    closure = execution_closure(
        READINESS_PROOF_SCHEMA,
        configuration,
        contract_revision=contract_revision,
    )
    return {
        "proofVersion": PROOF_VERSION,
        "proofSchema": READINESS_PROOF_SCHEMA,
        "operationClass": "readiness",
        "candidateId": candidate_id,
        "sourceDigest": source_digest,
        "result": "passed",
        "observedAt": observed.isoformat().replace("+00:00", "Z"),
        "environmentClosureSha256": closure,
        "evidenceSha256": hashlib.sha256(raw).hexdigest(),
    }


def build_local_gate_proof(
    manifest_path: Path,
    *,
    configuration: str,
    now: datetime | None = None,
    contract_revision: str = CONTRACT_REVISION,
) -> dict[str, Any]:
    """Build the authoritative local-gate proof after every gate leg passed."""

    raw, candidate_id, source_digest = _manifest_binding(manifest_path)
    if not configuration or any(character.isspace() for character in configuration):
        raise ValueError("local-gate-configuration-invalid")
    observed = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
    closure = execution_closure(
        LOCAL_GATE_PROOF_SCHEMA,
        configuration,
        contract_revision=contract_revision,
    )
    evidence = b"\0".join(
        (
            LOCAL_GATE_PROOF_SCHEMA.encode("utf-8"),
            raw,
            configuration.encode("utf-8"),
            b"authoritative",
        )
    )
    return {
        "proofVersion": PROOF_VERSION,
        "proofSchema": LOCAL_GATE_PROOF_SCHEMA,
        "operationClass": "localGate",
        "candidateId": candidate_id,
        "sourceDigest": source_digest,
        "result": "passed",
        "observedAt": observed.isoformat().replace("+00:00", "Z"),
        "configuration": configuration,
        "scope": "authoritative",
        "environmentClosureSha256": closure,
        "evidenceSha256": hashlib.sha256(evidence).hexdigest(),
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


def main(argv: list[str] | None = None) -> int:
    """Read the declared manifest and persist its candidate-bound proof."""

    arguments = sys.argv[1:] if argv is None else argv
    if arguments not in ([], ["--local-gate"]):
        return 64
    local_gate = arguments == ["--local-gate"]
    value = os.environ.get("READINESS_MANIFEST")
    if not value or "\x00" in value:
        return 4
    root = Path(__file__).resolve().parent.parent
    try:
        manifest_path = resolve_canonical_manifest(value, root)
        configuration = os.environ.get("RELEASE_CONFIGURATION", "")
        if local_gate:
            proof = build_local_gate_proof(
                manifest_path,
                configuration=configuration,
            )
        else:
            proof = build_proof(
                manifest_path,
                configuration=configuration,
            )
        candidate_id = proof["candidateId"]
        proof_name = "local-gate.json" if local_gate else "readiness.json"
        destination = root / ".release-state" / "evidence" / candidate_id / proof_name
        write_proof(destination, proof)
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        return 4
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
