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
_UPLOAD_LINE = re.compile(
    r"(?m)^.*Candidate\s+(?P<candidate>[A-Za-z0-9._-]+)\s+build\s+"
    r"(?P<build>[0-9]+)\s+uploaded\b.*$"
)
_UPLOAD_MARKER = re.compile(r"(?im)\buploadedBuildIdentifier\s*[:=]\s*([A-Za-z0-9._() -]+)")


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


_SECRET_ENVIRONMENT_NAMES = (
    "APP_STORE_CONNECT_API_KEY",
    "APP_STORE_CONNECT_KEY_ID",
    "APP_STORE_CONNECT_ISSUER_ID",
)
_DIAGNOSTIC_TAIL_BYTES = 16384


def _redact_secrets(text: str) -> str:
    """Replace broker-injected credential values that appear in child output."""
    for name in _SECRET_ENVIRONMENT_NAMES:
        value = (os.environ.get(name) or "").strip()
        # Short values are not distinctive enough to substitute without
        # corrupting unrelated output.
        if len(value) >= 8:
            text = text.replace(value, f"<redacted:{name}>")
    return text


def _diagnostic_tail(text: str | None) -> str:
    if not text:
        return "(empty)"
    if len(text) <= _DIAGNOSTIC_TAIL_BYTES:
        return text
    return "...<truncated>...\n" + text[-_DIAGNOSTIC_TAIL_BYTES:]


def _persist_operation_diagnostics(
    operation: str,
    candidate: str | None,
    argv: Sequence[str],
    result: subprocess.CompletedProcess[str],
) -> Path | None:
    """Retain a failed child's output so a blocked proof stays diagnosable.

    The release runner sends every operation's stdout and stderr to DEVNULL, so
    a durable file beside the proof is the only channel that survives a failed
    attempt.  This process holds the broker credential environment, so captured
    text is redacted before it is written, is stored 0600, and never reaches
    stdout, which carries the operation's JSON contract.
    """
    if candidate is None:
        return None
    path = EVIDENCE_ROOT / candidate / f"{operation}-failure.log"
    body = (
        f"operation: {operation}\n"
        f"candidate: {candidate}\n"
        f"observedAt: {_now()}\n"
        f"argv: {' '.join(argv)}\n"
        f"exitStatus: {result.returncode}\n"
        f"--- stderr ---\n{_diagnostic_tail(result.stderr)}\n"
        f"--- stdout ---\n{_diagnostic_tail(result.stdout)}\n"
    )
    try:
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(_redact_secrets(body))
    except OSError:
        return None
    return path


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


def _central_candidate_record(candidate: str) -> tuple[Mapping[str, Any], Mapping[str, Any]] | None:
    """Load the central manifest and its immutable artifact attestation."""

    candidate_root = ROOT / ".git" / "release-state" / PRODUCT / "candidates" / candidate
    manifest = _read_json(candidate_root / "manifest.json")
    if manifest is None or manifest.get("candidateId") != candidate:
        return None
    release = manifest.get("release")
    attestation_name = manifest.get("artifactAttestation", {}).get("path")
    if not isinstance(release, Mapping) or not isinstance(attestation_name, str):
        return None
    attestation_path = Path(attestation_name)
    if attestation_path.is_absolute() or ".." in attestation_path.parts:
        return None
    attestation = _read_json(candidate_root / attestation_path)
    if attestation is None or attestation.get("candidateId") != candidate:
        return None
    return manifest, attestation


def _candidate_bindings(candidate: str) -> tuple[str, Mapping[str, Any], str, int, str] | None:
    """Resolve a central candidate to exactly one prepared legacy ledger.

    The old upload script owns the prepared artifact, while the central state
    owns the workflow candidate.  They may use different IDs, but version,
    build, and artifact digest must agree exactly.  Ambiguous or incomplete
    state returns ``None`` so upload remains fail-closed.
    """

    central = _central_candidate_record(candidate)
    if central is None:
        record = _candidate_record(candidate)
        if record is None:
            return None
        version = record.get("marketingVersion")
        build = record.get("build")
        artifact = record.get("artifactSha256")
        if (
            not isinstance(version, str)
            or not _SEMVER.fullmatch(version)
            or isinstance(build, bool)
            or not isinstance(build, int)
            or build < 1
            or not isinstance(artifact, str)
            or not _HEX64.fullmatch(artifact)
        ):
            return None
        return candidate, record, version, build, artifact

    manifest, attestation = central
    release = manifest.get("release")
    version = release.get("marketingVersion") if isinstance(release, Mapping) else None
    raw_build = release.get("buildNumber") if isinstance(release, Mapping) else None
    artifact = attestation.get("artifactSha256")
    try:
        build = int(raw_build)
    except (TypeError, ValueError):
        build = 0
    if (
        not isinstance(version, str)
        or not _SEMVER.fullmatch(version)
        or build < 1
        or not isinstance(raw_build, (str, int))
        or isinstance(raw_build, bool)
        or not isinstance(artifact, str)
        or not _HEX64.fullmatch(artifact)
    ):
        return None

    candidates: list[tuple[str, Mapping[str, Any]]] = []
    ledger_paths = [ROOT / ".release-state" / "candidate.json"]
    ledger_paths.extend((ROOT / ".release-state" / "candidates").glob("*/candidate.json"))
    for path in ledger_paths:
        record = _read_json(path)
        if (
            record is not None
            and record.get("state") == "prepared"
            and record.get("marketingVersion") == version
            and record.get("build") == build
            and record.get("artifactSha256") == artifact
        ):
            candidates.append((str(record.get("candidateId", "")), record))
    if len(candidates) != 1 or not candidates[0][0]:
        return None
    legacy_id, record = candidates[0]
    return legacy_id, record, version, build, artifact


def _uploaded_build_identifier(
    stdout: str | None, *, legacy_candidate: str, marketing_version: str, build: int
) -> str | None:
    """Extract a transport confirmation and normalize it to ``version (build)``."""

    output = stdout or ""
    markers = _UPLOAD_MARKER.findall(output)
    if markers:
        if len(set(markers)) != 1:
            return None
        return markers[0].strip() or None
    matches = list(_UPLOAD_LINE.finditer(output))
    if len(matches) != 1:
        return None
    match = matches[0]
    if match.group("candidate") != legacy_candidate or int(match.group("build")) != build:
        return None
    return f"{marketing_version} ({build})"


def _upload_passed(
    candidate: str,
    *,
    artifact: str,
    uploaded_build_identifier: str,
    legacy_candidate: str,
    marketing_version: str,
    build: int,
) -> int:
    payload: dict[str, Any] = {
        "proofVersion": "1.0.0",
        "operationClass": "upload",
        "candidateId": candidate,
        "signedArtifactSha256": artifact,
        "result": "passed",
        "uploadedBuildIdentifier": uploaded_build_identifier,
        "responseSha256": _digest(
            {
                "operation": "upload",
                "candidateId": candidate,
                "legacyCandidateId": legacy_candidate,
                "marketingVersion": marketing_version,
                "buildNumber": build,
                "signedArtifactSha256": artifact,
                "uploadedBuildIdentifier": uploaded_build_identifier,
            }
        ),
    }
    path = _proof_path("upload", candidate)
    _write_json(path, payload)
    print(
        json.dumps(
            {"operation": "upload", "result": "passed", "proofPath": str(path.relative_to(ROOT))},
            sort_keys=True,
        )
    )
    return 0


def _current_marketing_version() -> str:
    """Read the GradusiOS marketing version from the fixed project manifest."""

    text = (ROOT / "app" / "project.yml").read_text(encoding="utf-8")
    target = re.search(r"(?m)^  GradusiOS:\s*$", text)
    if target is None:
        raise ValueError("GradusiOS marketing version is unavailable")
    section = text[target.end() :]
    next_target = re.search(r"(?m)^  [A-Za-z0-9_]+:\s*$", section)
    if next_target is not None:
        section = section[: next_target.start()]
    matches = re.findall(r'(?m)^        MARKETING_VERSION: "([^"]+)"\s*$', section)
    if len(matches) != 1 or _SEMVER.fullmatch(matches[0]) is None:
        raise ValueError("GradusiOS marketing version is unavailable")
    return matches[0]


def _identity_proof_valid(*, marketing_version: str) -> bool:
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
        and proof.get("marketingVersion") == marketing_version
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


def _archive_identity_proof() -> None:
    """Move one consumed or stale operation proof into a content-addressed archive."""

    if not IDENTITY_PROOF.exists():
        return
    if IDENTITY_PROOF.is_symlink() or not IDENTITY_PROOF.is_file():
        raise ValueError("identity proof is not a regular file")
    encoded = IDENTITY_PROOF.read_bytes()
    digest = hashlib.sha256(encoded).hexdigest()
    archive = EVIDENCE_ROOT / "archive" / f"allocate-identity-{digest}.json"
    archive.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    try:
        descriptor = os.open(archive, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        if archive.read_bytes() != encoded:
            raise ValueError("identity proof archive mismatch")
    else:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
    IDENTITY_PROOF.unlink()


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
        marketing_version = _current_marketing_version()
        if _identity_proof_valid(marketing_version=marketing_version):
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
        _archive_identity_proof()
        result = runner(
            [str(ALLOCATOR), "--product", PRODUCT],
            cwd=ROOT,
            env=dict(os.environ),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0 or not _identity_proof_valid(marketing_version=marketing_version):
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
        binding = _candidate_bindings(candidate)
        if binding is None:
            return _blocked(operation, candidate, "candidate-ledger-mismatch")
        legacy_candidate, _record, marketing_version, build, artifact = binding
        result = runner(
            [str(ARCHIVE), "--upload-only", "--candidate", legacy_candidate],
            cwd=ROOT,
            env=dict(os.environ),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            shell=False,
        )
        if result.returncode != 0:
            _persist_operation_diagnostics(
                operation,
                candidate,
                [str(ARCHIVE), "--upload-only", "--candidate", legacy_candidate],
                result,
            )
            return _blocked(operation, candidate, "upload-not-confirmed")
        uploaded = _uploaded_build_identifier(
            result.stdout,
            legacy_candidate=legacy_candidate,
            marketing_version=marketing_version,
            build=build,
        )
        if uploaded is None:
            _persist_operation_diagnostics(
                operation,
                candidate,
                [str(ARCHIVE), "--upload-only", "--candidate", legacy_candidate],
                result,
            )
            return _blocked(operation, candidate, "uploaded-build-identifier-unavailable")
        return _upload_passed(
            candidate,
            artifact=artifact,
            uploaded_build_identifier=uploaded,
            legacy_candidate=legacy_candidate,
            marketing_version=marketing_version,
            build=build,
        )
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
