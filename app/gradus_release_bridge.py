#!/usr/bin/env python3
"""Fixed Gradus App Store Connect broker dispatcher.

The broker owns the credential environment; this process owns only the closed
operation vocabulary and candidate/evidence binding.  Unsupported operations
return a typed blocked proof and never guess an Apple API or mutate state.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from collections.abc import Callable, Mapping, Sequence
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

PRODUCT = "gradus-ios"
ROOT = Path(__file__).resolve().parents[1]
EVIDENCE_ROOT = ROOT / ".release-state" / "evidence"
IDENTITY_PROOF = EVIDENCE_ROOT / "allocate-identity.json"
ALLOCATOR = ROOT / "app" / "allocate_identity.py"
ARCHIVE = ROOT / "app" / "archive-upload-ios.sh"
OPERATIONS = (
    "identity-allocation",
    "upload",
    "processing",
    "compliance",
    "tester-group",
    "assignment",
    "notification",
    "device-health",
)
_CANDIDATE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_HEX64 = re.compile(r"^[0-9a-f]{64}$")
_SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")


def _now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _digest(payload: Mapping[str, Any]) -> str:
    encoded = json.dumps(dict(payload), sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def _proof_path(operation: str, candidate: str | None) -> Path:
    if operation == "identity-allocation":
        return IDENTITY_PROOF
    if candidate is None:
        raise ValueError("candidate is required")
    return EVIDENCE_ROOT / candidate / f"{operation}.json"


def _write_json(path: Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    encoded = json.dumps(dict(payload), sort_keys=True, indent=2).encode() + b"\n"
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    descriptor = os.open(temporary, flags, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = -1
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _read_json(path: Path) -> Mapping[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, Mapping) else None


def _blocked(operation: str, candidate: str | None, reason: str) -> int:
    payload: dict[str, Any] = {
        "proofVersion": "1.0.0",
        "operationClass": {
            "identity-allocation": "identityAllocation",
            "tester-group": "testerGroup",
            "device-health": "deviceHealth",
        }.get(operation, operation),
        "result": "blocked",
        "observedAt": _now(),
        "reason": reason,
        "responseSha256": _digest(
            {"operation": operation, "candidateId": candidate, "reason": reason}
        ),
    }
    if candidate is not None:
        payload["candidateId"] = candidate
    path = _proof_path(operation, candidate)
    _write_json(path, payload)
    print(
        json.dumps(
            {"operation": operation, "result": "blocked", "proofPath": str(path.relative_to(ROOT))},
            sort_keys=True,
        )
    )
    return 3


def _validate_candidate(value: str | None) -> str | None:
    if value is None:
        return None
    if not _CANDIDATE.fullmatch(value):
        raise ValueError("candidate is invalid")
    return value


def _candidate_record(candidate: str) -> Mapping[str, Any] | None:
    record = _read_json(ROOT / ".release-state" / "candidate.json")
    if record is None or record.get("candidateId") != candidate:
        return None
    return record


def _identity_proof_valid() -> bool:
    proof = _read_json(IDENTITY_PROOF)
    if proof is None:
        return False
    required = {
        "proofVersion",
        "operationClass",
        "result",
        "marketingVersion",
        "buildNumber",
        "responseSha256",
        "productKey",
        "remoteHighestMarketingVersion",
        "remoteHighestBuildNumber",
        "observedAt",
    }
    remote_version = proof.get("remoteHighestMarketingVersion")
    remote_build = proof.get("remoteHighestBuildNumber")
    return (
        set(proof) == required
        and proof.get("proofVersion") == "1.0.0"
        and proof.get("operationClass") == "identityAllocation"
        and proof.get("result") == "passed"
        and proof.get("productKey") == PRODUCT
        and isinstance(proof.get("buildNumber"), int)
        and proof["buildNumber"] > 0
        and isinstance(proof.get("marketingVersion"), str)
        and _SEMVER.fullmatch(proof["marketingVersion"]) is not None
        and _HEX64.fullmatch(str(proof.get("responseSha256", ""))) is not None
        and (
            remote_version is None
            or (isinstance(remote_version, str) and _SEMVER.fullmatch(remote_version) is not None)
        )
        and isinstance(remote_build, int)
        and not isinstance(remote_build, bool)
        and remote_build >= 0
        and proof["buildNumber"] == remote_build + 1
        and isinstance(proof.get("observedAt"), str)
    )


def dispatch(
    operation: str,
    *,
    product: str,
    candidate: str | None,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> int:
    if product != PRODUCT:
        raise ValueError("product is unsupported")
    candidate = _validate_candidate(candidate)
    if operation == "identity-allocation":
        if candidate is not None:
            raise ValueError("identity allocation does not accept a candidate")
        if _identity_proof_valid():
            print(
                json.dumps(
                    {
                        "operation": operation,
                        "result": "passed",
                        "proofPath": str(IDENTITY_PROOF.relative_to(ROOT)),
                    },
                    sort_keys=True,
                )
            )
            return 0
        result = runner(
            [str(ALLOCATOR), "--product", PRODUCT],
            cwd=ROOT,
            env=dict(os.environ),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0 or not _identity_proof_valid():
            return _blocked(operation, None, "identity-proof-unavailable")
        print(
            json.dumps(
                {
                    "operation": operation,
                    "result": "passed",
                    "proofPath": str(IDENTITY_PROOF.relative_to(ROOT)),
                },
                sort_keys=True,
            )
        )
        return 0
    if candidate is None:
        raise ValueError("candidate is required")
    if operation == "upload":
        record = _candidate_record(candidate)
        if record is None:
            return _blocked(operation, candidate, "candidate-ledger-mismatch")
        result = runner(
            [str(ARCHIVE), "--upload-only", "--candidate", candidate],
            cwd=ROOT,
            env=dict(os.environ),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            shell=False,
        )
        if result.returncode != 0:
            return _blocked(operation, candidate, "upload-not-confirmed")
        return _blocked(operation, candidate, "uploaded-build-identifier-unavailable")
    return _blocked(operation, candidate, "operation-interface-not-yet-authorized")


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="gradus_release_bridge")
    parser.add_argument("--operation", choices=OPERATIONS, required=True)
    parser.add_argument("--product", choices=(PRODUCT,), required=True)
    parser.add_argument("--candidate")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    try:
        args = parse_args(argv)
        return dispatch(args.operation, product=args.product, candidate=args.candidate)
    except (OSError, ValueError) as exc:
        print(f"gradus-release-bridge: {exc}", file=sys.stderr)
        return 64


if __name__ == "__main__":
    raise SystemExit(main())
