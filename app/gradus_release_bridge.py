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
import time
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

BUNDLE_ID = "com.zerodelta.gradus.ios"
PROCESSING_POLL_INTERVAL_SECONDS = 30
PROCESSING_TIMEOUT_SECONDS = 30 * 60
# Apple reports a build that still needs an export-compliance answer through
# either field depending on the endpoint, so both are read.  The bridge only
# ever *observes* this state; declaring export compliance is a legal statement
# about the product and stays an attended human action, exactly as
# testflight-assign.py already requires.
_MISSING_COMPLIANCE = frozenset({"MISSING_COMPLIANCE", "MISSINGCOMPLIANCE"})
_FAILED_PROCESSING = frozenset({"FAILED", "INVALID"})
# Hyphenated operation names, camel-cased proof classes.  One mapping so a
# blocked and a passing proof for the same operation can never disagree about
# what class they belong to.
_PROOF_CLASSES = {
    "identity-allocation": "identityAllocation",
    "tester-group": "testerGroup",
    "device-health": "deviceHealth",
}


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
        "operationClass": _PROOF_CLASSES.get(operation, operation),
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


class _ObservationError(RuntimeError):
    """A fixed local classification of an unusable App Store Connect response.

    Every message is chosen in this module and never carries an Apple response
    body, because the string becomes the ``reason`` field of a blocked proof.
    Evidence must not become a place where remote text lands unreviewed.
    """


def _default_client() -> Any:
    """Build the real ASC client, importing lazily so tests need no credentials.

    The import is deferred rather than top-level so an injected client keeps the
    bridge usable -- and importable -- in environments where the broker has not
    supplied a credential environment at all.
    """

    from _asc_api import ASCClient, make_token_provider  # noqa: PLC0415

    return ASCClient(make_token_provider())


def _transport_error_types() -> tuple[type[BaseException], ...]:
    try:
        from _asc_api import ASCError  # noqa: PLC0415
    except ImportError:
        return ()
    return (ASCError,)


def _build_attribute(item: Mapping[str, Any], key: str) -> Any:
    attributes = item.get("attributes")
    return attributes.get(key) if isinstance(attributes, Mapping) else None


def _build_state(item: Mapping[str, Any], key: str) -> str:
    """Normalize one Apple state field to a comparable upper-case token."""

    return str(_build_attribute(item, key) or "").upper().replace(" ", "_")


def _uploaded_identifier_from_proof(candidate: str) -> str | None:
    """Read this candidate's own upload proof for the transport confirmation.

    Downstream operations must describe the build Apple actually accepted, so
    the identifier comes from the recorded upload proof rather than being
    recomputed from the ledger.  A proof belonging to another candidate, or one
    that did not pass, yields nothing instead of a plausible guess.
    """

    proof = _read_json(_proof_path("upload", candidate))
    if proof is None or proof.get("result") != "passed":
        return None
    if proof.get("candidateId") != candidate:
        return None
    identifier = proof.get("uploadedBuildIdentifier")
    if not isinstance(identifier, str) or not identifier.strip():
        return None
    return identifier.strip()


def _resolve_app_id(client: Any) -> str:
    response = client.request("GET", f"/apps?filter[bundleId]={BUNDLE_ID}") or {}
    data = response.get("data") if isinstance(response, Mapping) else None
    if not isinstance(data, list) or len(data) != 1 or not isinstance(data[0], Mapping):
        raise _ObservationError("bundle-id-did-not-resolve-to-one-app")
    app_id = data[0].get("id")
    if not isinstance(app_id, str) or not app_id:
        raise _ObservationError("app-identity-missing")
    return app_id


def _exact_build(client: Any, app_id: str, build: int) -> Mapping[str, Any] | None:
    """Return the single build whose version equals ``build`` exactly.

    Apple's version filter is not an equality guarantee, so the response is
    re-filtered locally.  More than one exact match is ambiguous rather than
    merely surprising: observing the wrong build would attest processing for
    bytes nobody chose, so it fails instead of picking one.
    """

    response = (
        client.request("GET", f"/builds?filter[app]={app_id}&filter[version]={build}&limit=50")
        or {}
    )
    data = response.get("data") if isinstance(response, Mapping) else None
    if not isinstance(data, list):
        raise _ObservationError("malformed-build-response")
    exact = [
        item
        for item in data
        if isinstance(item, Mapping) and str(_build_attribute(item, "version")) == str(build)
    ]
    if len(exact) > 1:
        raise _ObservationError("multiple-builds-matched-candidate")
    return exact[0] if exact else None


def _observation_passed(
    operation: str,
    candidate: str,
    *,
    uploaded_build_identifier: str,
    observed: Mapping[str, Any],
) -> int:
    """Write a typed passing proof for one read-only observation.

    ``observed`` carries the operation-specific facts.  They are both recorded
    and folded into the digest, so the proof cannot later be reinterpreted as
    describing a different observation than the one that produced its hash.
    """

    payload: dict[str, Any] = {
        "proofVersion": "1.0.0",
        "operationClass": _PROOF_CLASSES.get(operation, operation),
        "candidateId": candidate,
        "uploadedBuildIdentifier": uploaded_build_identifier,
        "result": "passed",
        "observedAt": _now(),
        **dict(observed),
        "responseSha256": _digest(
            {
                "operation": operation,
                "candidateId": candidate,
                "uploadedBuildIdentifier": uploaded_build_identifier,
                **dict(observed),
            }
        ),
    }
    path = _proof_path(operation, candidate)
    _write_json(path, payload)
    print(
        json.dumps(
            {"operation": operation, "result": "passed", "proofPath": str(path.relative_to(ROOT))},
            sort_keys=True,
        )
    )
    return 0


def _tester_group_confirmation() -> tuple[str, str] | None:
    """Read the operator's recorded choice of internal TestFlight group.

    Absent or malformed confirmation is not an error, it is simply an absence
    of authority, so it yields ``None`` and the caller blocks.  The group is
    never inferred from the App Store Connect response: reading a list is not
    the same act as choosing from it.
    """

    record = _read_json(ROOT / ".release" / "tester-group.json")
    if record is None:
        return None
    group_id = record.get("groupId")
    group_name = record.get("groupName")
    if not isinstance(group_id, str) or not group_id.strip():
        return None
    if not isinstance(group_name, str) or not group_name.strip():
        return None
    return group_id.strip(), group_name.strip()


def _internal_groups(client: Any, app_id: str) -> list[Mapping[str, Any]]:
    response = client.request("GET", f"/apps/{app_id}/betaGroups?limit=200") or {}
    data = response.get("data") if isinstance(response, Mapping) else None
    if not isinstance(data, list):
        raise _ObservationError("malformed-tester-group-response")
    groups: list[Mapping[str, Any]] = []
    for group in data:
        if not isinstance(group, Mapping) or not isinstance(group.get("id"), str):
            raise _ObservationError("malformed-tester-group-response")
        if _build_attribute(group, "isInternalGroup"):
            groups.append(group)
    return groups


def _persist_group_choices(candidate: str, groups: Sequence[Mapping[str, Any]]) -> None:
    """Record exactly what an operator needs to confirm one group, and no more.

    Identifiers, display names, and one boolean.  Never members, emails, or any
    other tester data.  It is written to disk rather than only printed so the
    confirmation is made against durable evidence instead of console output
    that has already scrolled away.
    """

    path = _proof_path("tester-group", candidate).with_name("tester-group-choices.json")
    _write_json(
        path,
        {
            "schemaVersion": "1.0.0",
            "candidateId": candidate,
            "observedAt": _now(),
            "internalGroups": [
                {
                    "groupId": group["id"],
                    "groupName": str(_build_attribute(group, "name") or ""),
                    "hasAccessToAllBuilds": bool(_build_attribute(group, "hasAccessToAllBuilds")),
                }
                for group in groups
            ],
        },
    )


def _tester_group(candidate: str, *, client_factory: Callable[[], Any]) -> int:
    """Confirm one internal group; never create, modify, or assign to one.

    Distributing a build is an authority decision, so this operation stops at
    confirmation and leaves the choices behind for whoever makes it.  Matching
    mirrors testflight-assign.py exactly: the app must expose a single internal
    group and the recorded confirmation must match both its identifier and its
    display name, so a renamed or newly added group blocks instead of being
    quietly accepted.
    """

    context = _observation_context("tester-group", candidate)
    if isinstance(context, int):
        return context
    _build, uploaded = context
    try:
        client = client_factory()
        groups = _internal_groups(client, _resolve_app_id(client))
    except _ObservationError as error:
        return _blocked("tester-group", candidate, str(error))
    except _transport_error_types():
        return _blocked("tester-group", candidate, "app-store-connect-request-failed")
    _persist_group_choices(candidate, groups)
    confirmation = _tester_group_confirmation()
    if confirmation is None:
        return _blocked("tester-group", candidate, "tester-group-confirmation-required")
    group_id, group_name = confirmation
    matches = [
        group
        for group in groups
        if group["id"] == group_id and _build_attribute(group, "name") == group_name
    ]
    if len(groups) != 1 or len(matches) != 1:
        return _blocked("tester-group", candidate, "confirmed-tester-group-is-not-the-only-one")
    return _observation_passed(
        "tester-group",
        candidate,
        uploaded_build_identifier=uploaded,
        # The identifier is hashed rather than recorded, because a proof needs
        # to bind the choice, not republish it.
        observed={"groupIdentifierHash": hashlib.sha256(group_id.encode()).hexdigest()},
    )


def _observation_context(operation: str, candidate: str) -> tuple[int, str] | int:
    """Resolve the build number and upload confirmation both observers need."""

    binding = _candidate_bindings(candidate)
    if binding is None:
        return _blocked(operation, candidate, "candidate-ledger-mismatch")
    _legacy, _record, _marketing_version, build, _artifact = binding
    uploaded = _uploaded_identifier_from_proof(candidate)
    if uploaded is None:
        return _blocked(operation, candidate, "uploaded-build-identifier-unavailable")
    return build, uploaded


def _processing(
    candidate: str,
    *,
    client_factory: Callable[[], Any],
    clock: Callable[[], float],
    sleep: Callable[[float], None],
    timeout: float,
    interval: float,
) -> int:
    """Wait for Apple to finish processing the uploaded build, then attest it.

    This only ever reads.  A build that Apple has not yet indexed is not a
    failure, so the loop keeps waiting; a build Apple has rejected is terminal
    and blocks immediately rather than burning the full timeout.
    """

    context = _observation_context("processing", candidate)
    if isinstance(context, int):
        return context
    build, uploaded = context
    try:
        client = client_factory()
        app_id = _resolve_app_id(client)
        deadline = clock() + timeout
        while True:
            item = _exact_build(client, app_id, build)
            if item is not None:
                state = _build_state(item, "processingState")
                if state in _FAILED_PROCESSING:
                    return _blocked("processing", candidate, f"build-processing-{state.lower()}")
                if state == "VALID":
                    return _observation_passed(
                        "processing",
                        candidate,
                        uploaded_build_identifier=uploaded,
                        observed={
                            "processingState": state,
                            "complianceState": _build_state(item, "complianceState"),
                        },
                    )
            if clock() >= deadline:
                return _blocked("processing", candidate, "processing-not-confirmed-before-timeout")
            sleep(interval)
    except _ObservationError as error:
        return _blocked("processing", candidate, str(error))
    except _transport_error_types():
        return _blocked("processing", candidate, "app-store-connect-request-failed")


def _compliance(candidate: str, *, client_factory: Callable[[], Any]) -> int:
    """Attest that Apple is not withholding the build for export compliance.

    Observational by construction: when Apple wants an export-compliance answer
    the operation blocks and names the attended action.  Answering on Apple's
    export-compliance form is a legal declaration about the product and is not
    a decision this bridge is authorized to make on anyone's behalf.
    """

    context = _observation_context("compliance", candidate)
    if isinstance(context, int):
        return context
    build, uploaded = context
    try:
        client = client_factory()
        item = _exact_build(client, _resolve_app_id(client), build)
    except _ObservationError as error:
        return _blocked("compliance", candidate, str(error))
    except _transport_error_types():
        return _blocked("compliance", candidate, "app-store-connect-request-failed")
    if item is None:
        return _blocked("compliance", candidate, "build-not-indexed")
    processing_state = _build_state(item, "processingState")
    compliance_state = _build_state(item, "complianceState")
    if processing_state in _MISSING_COMPLIANCE or compliance_state in _MISSING_COMPLIANCE:
        return _blocked("compliance", candidate, "export-compliance-attention-required")
    if processing_state in _FAILED_PROCESSING:
        return _blocked("compliance", candidate, f"build-processing-{processing_state.lower()}")
    if processing_state != "VALID":
        return _blocked("compliance", candidate, "processing-not-confirmed")
    return _observation_passed(
        "compliance",
        candidate,
        uploaded_build_identifier=uploaded,
        observed={"processingState": processing_state, "complianceState": compliance_state},
    )


def dispatch(
    operation: str,
    *,
    product: str,
    candidate: str | None,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
    client: Any | None = None,
    clock: Callable[[], float] = time.monotonic,
    sleep: Callable[[float], None] = time.sleep,
    timeout: float = PROCESSING_TIMEOUT_SECONDS,
    interval: float = PROCESSING_POLL_INTERVAL_SECONDS,
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
    if operation in ("processing", "compliance", "tester-group"):
        # Resolved lazily inside the observers so a candidate that fails the
        # local ledger or upload-proof checks never causes a credential to be
        # requested at all.  Blocking is a local decision; it should not need
        # Apple, and it should not need a key.
        factory = (lambda: client) if client is not None else _default_client
        if operation == "processing":
            return _processing(
                candidate,
                client_factory=factory,
                clock=clock,
                sleep=sleep,
                timeout=timeout,
                interval=interval,
            )
        if operation == "compliance":
            return _compliance(candidate, client_factory=factory)
        return _tester_group(candidate, client_factory=factory)
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
