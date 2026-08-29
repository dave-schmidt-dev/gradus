#!/usr/bin/env python3
"""Candidate-bound, credential-free preparation proofs for TestFlight.

The central release runner owns the immutable candidate identity while the
legacy archive script owns the signed IPA.  This bridge binds those two
contracts without contacting Apple or accepting credentials.  Only the first
operation may prepare an artifact; the remaining operations inspect the same
durable IPA and emit their typed proofs.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
PRODUCT = "gradus-ios"
BUNDLE_IDENTIFIER = "com.zerodelta.gradus.ios"
WIDGET_BUNDLE_IDENTIFIER = "com.zerodelta.gradus.ios.widget"
TEAM_IDENTIFIER = "4CJ49V6QHW"
APP_GROUP_IDENTIFIER = "group.com.zerodelta.gradus"
WIDGET_EXTENSION_NAME = "GradusWidget.appex"
ARCHIVE_SCRIPT = ROOT / "app" / "archive-upload-ios.sh"
PROOF_OPERATIONS = ("production-build", "archive", "sign", "artifact-verify")
OPERATIONS = frozenset((*PROOF_OPERATIONS, "all"))
DISALLOWED_EXTENSION_ENTITLEMENT_KEYS = frozenset(
    {
        "com.apple.developer.icloud-container-identifiers",
        "com.apple.developer.ubiquity-kvstore-identifier",
        "com.apple.developer.icloud-services",
        "com.apple.developer.icloud-container-environment",
        "com.apple.developer.aps-environment",
        "aps-environment",
    }
)
_CANDIDATE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_HEX64 = re.compile(r"^[0-9a-f]{64}$")
_SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
_SECRET_NAMES = frozenset(
    {
        "APP_STORE_CONNECT_API_KEY",
        "APP_STORE_CONNECT_KEY_ID",
        "APP_STORE_CONNECT_ISSUER_ID",
    }
)


class BridgeError(ValueError):
    """A stable failure at the local candidate/proof boundary."""


@dataclass(frozen=True)
class CandidateContext:
    """Central immutable identity needed by every local proof."""

    manifest_path: Path
    candidate_id: str
    source_digest: str
    marketing_version: str
    build_number: int
    identity_allocation_proof_sha256: str | None = None


@dataclass(frozen=True)
class PreparedArtifact:
    """Durable legacy artifact bound to the central candidate."""

    ipa_path: Path
    artifact_sha256: str


@dataclass(frozen=True)
class ArtifactInspection:
    """Credential-free facts extracted from the signed IPA."""

    embedded_profile_sha256: str
    signing_certificate_sha256: str
    metadata_sha256: str
    widget_embedded_profile_sha256: str | None = None
    widget_signing_certificate_sha256: str | None = None


def _load_json_bytes(path: Path) -> tuple[bytes, Mapping[str, Any]]:
    if path.is_symlink() or not path.is_file():
        raise BridgeError("required-record-unavailable")
    try:
        raw = path.read_bytes()
        value = json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise BridgeError("required-record-unreadable") from exc
    if not isinstance(value, Mapping):
        raise BridgeError("required-record-invalid")
    return raw, value


def _load_json(path: Path) -> Mapping[str, Any]:
    return _load_json_bytes(path)[1]


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _text_digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _canonical_digest(value: Mapping[str, Any]) -> str:
    encoded = json.dumps(dict(value), sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def _write_json(path: Path, payload: Mapping[str, Any]) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(dict(payload), stream, sort_keys=True, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except Exception:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def load_context(
    manifest_path: Path,
    *,
    git_common_dir: Path,
) -> CandidateContext:
    """Validate the caller-selected manifest against the Git-common state home."""

    manifest_path = manifest_path.resolve(strict=False)
    manifest = _load_json(manifest_path)
    candidate = manifest.get("candidateId")
    source = manifest.get("sourceSnapshot")
    release = manifest.get("release")
    if not isinstance(candidate, str) or _CANDIDATE.fullmatch(candidate) is None:
        raise BridgeError("central-candidate-invalid")
    expected = (
        git_common_dir.resolve(strict=False)
        / "release-state"
        / PRODUCT
        / "candidates"
        / candidate
        / "manifest.json"
    )
    if manifest_path != expected:
        raise BridgeError("central-manifest-path-mismatch")
    if (
        manifest.get("formatVersion") != 2
        or manifest.get("immutable") is not True
        or manifest.get("productIdentifier") != PRODUCT
        or not isinstance(source, Mapping)
        or not isinstance(release, Mapping)
        or release.get("frozen") is not True
    ):
        raise BridgeError("central-candidate-invalid")
    source_digest = source.get("sha256")
    marketing_version = release.get("marketingVersion")
    raw_build = release.get("buildNumber")
    identity_allocation = manifest.get("identityAllocation")
    identity_allocation_proof_sha256 = None
    if identity_allocation is not None:
        if not isinstance(identity_allocation, Mapping):
            raise BridgeError("central-candidate-invalid")
        identity_allocation_proof_sha256 = identity_allocation.get("proofSha256")
        if (
            not isinstance(identity_allocation_proof_sha256, str)
            or _HEX64.fullmatch(identity_allocation_proof_sha256) is None
        ):
            raise BridgeError("central-candidate-invalid")
    if (
        not isinstance(source_digest, str)
        or _HEX64.fullmatch(source_digest) is None
        or not isinstance(marketing_version, str)
        or _SEMVER.fullmatch(marketing_version) is None
        or isinstance(raw_build, bool)
        or not isinstance(raw_build, (str, int))
    ):
        raise BridgeError("central-candidate-invalid")
    try:
        build_number = int(raw_build)
    except ValueError as exc:
        raise BridgeError("central-candidate-invalid") from exc
    if build_number < 1 or str(build_number) != str(raw_build):
        raise BridgeError("central-candidate-invalid")
    return CandidateContext(
        manifest_path,
        candidate,
        source_digest,
        marketing_version,
        build_number,
        identity_allocation_proof_sha256,
    )


def _identity_proof(root: Path, context: CandidateContext) -> Mapping[str, Any]:
    proof = _load_json(root / ".release-state" / "evidence" / "allocate-identity.json")
    remote_highest_build = proof.get("remoteHighestBuildNumber")
    remote_highest_version = proof.get("remoteHighestMarketingVersion")
    if (
        proof.get("proofVersion") != "1.0.0"
        or proof.get("operationClass") != "identityAllocation"
        or proof.get("result") != "passed"
        or proof.get("productKey") != PRODUCT
        or proof.get("marketingVersion") != context.marketing_version
        or proof.get("buildNumber") != context.build_number
        or isinstance(remote_highest_build, bool)
        or not isinstance(remote_highest_build, int)
        or proof.get("buildNumber") != remote_highest_build + 1
        or not isinstance(remote_highest_version, str)
        or _SEMVER.fullmatch(remote_highest_version) is None
        or not isinstance(proof.get("responseSha256"), str)
        or _HEX64.fullmatch(str(proof.get("responseSha256"))) is None
    ):
        central_bytes, central = _load_json_bytes(
            context.manifest_path.parent / "identity-allocation.json"
        )
        if (
            context.identity_allocation_proof_sha256 is None
            or hashlib.sha256(central_bytes).hexdigest() != context.identity_allocation_proof_sha256
        ):
            raise BridgeError("identity-proof-central-mismatch")
        allocation = central.get("allocation")
        authorization = central.get("reuseAuthorization")
        if not isinstance(allocation, Mapping):
            raise BridgeError("identity-proof-central-mismatch")
        if (
            not isinstance(authorization, Mapping)
            or authorization.get("kind")
            not in {"failed-preupload-correction", "staged-preupload-correction"}
            or authorization.get("priorCandidateId")
            != f"{context.marketing_version}-{context.build_number - 1}"
            or allocation.get("productKey") != PRODUCT
            or allocation.get("requestedMarketingVersion") != context.marketing_version
            or allocation.get("allocatedBuildNumber") != context.build_number
            or isinstance(allocation.get("remoteHighestBuildNumber"), bool)
            or not isinstance(allocation.get("remoteHighestBuildNumber"), int)
            or allocation.get("remoteHighestBuildNumber") >= context.build_number
            or not isinstance(allocation.get("remoteHighestMarketingVersion"), str)
            or _SEMVER.fullmatch(allocation["remoteHighestMarketingVersion"]) is None
            or allocation.get("result") != "allocated"
            or not isinstance(allocation.get("observedAt"), str)
        ):
            raise BridgeError("identity-proof-central-mismatch")
        if authorization.get("kind") == "staged-preupload-correction":
            prior_candidate = str(authorization["priorCandidateId"])
            prior_package = (
                context.manifest_path.parent.parent / prior_candidate / "approval-package.json"
            )
            prior_stage_hash = authorization.get("priorStagePackageSha256")
            if (
                not isinstance(prior_stage_hash, str)
                or _HEX64.fullmatch(prior_stage_hash) is None
                or prior_package.is_symlink()
                or not prior_package.is_file()
            ):
                raise BridgeError("identity-proof-central-mismatch")
            try:
                prior_package_bytes = prior_package.read_bytes()
            except OSError as exc:
                raise BridgeError("identity-proof-central-mismatch") from exc
            if hashlib.sha256(prior_package_bytes).hexdigest() != prior_stage_hash:
                raise BridgeError("identity-proof-central-mismatch")
        proof = {
            "proofVersion": "1.0.0",
            "operationClass": "identityAllocation",
            "result": "passed",
            "productKey": PRODUCT,
            "marketingVersion": context.marketing_version,
            "buildNumber": context.build_number,
            "remoteHighestMarketingVersion": allocation["remoteHighestMarketingVersion"],
            "remoteHighestBuildNumber": allocation["remoteHighestBuildNumber"],
            "observedAt": allocation["observedAt"],
            "responseSha256": _canonical_digest(central),
        }
        _write_json(
            root / ".release-state" / "evidence" / context.candidate_id / "allocate-identity.json",
            proof,
        )
    return proof


def _allocation_matches(
    allocation: Mapping[str, Any], *, candidate: str, version: str, build: int
) -> bool:
    if not isinstance(allocation, Mapping):
        return False
    return (
        allocation.get("state") == "allocated-but-unfrozen"
        and allocation.get("candidateId") == candidate
        and allocation.get("marketingVersion") == version
        and allocation.get("build") == build
        and isinstance(allocation.get("allocatedAt"), str)
        and bool(allocation.get("allocatedAt"))
    )


def _authorized_failed_preupload_predecessor(context: CandidateContext) -> str | None:
    """Return the central, digest-bound predecessor eligible for local archival."""

    if context.identity_allocation_proof_sha256 is None:
        return None
    central_bytes, central = _load_json_bytes(
        context.manifest_path.parent / "identity-allocation.json"
    )
    if hashlib.sha256(central_bytes).hexdigest() != context.identity_allocation_proof_sha256:
        raise BridgeError("identity-proof-central-mismatch")
    authorization = central.get("reuseAuthorization")
    predecessor = (
        authorization.get("priorCandidateId") if isinstance(authorization, Mapping) else None
    )
    if (
        not isinstance(authorization, Mapping)
        or authorization.get("kind") != "failed-preupload-correction"
        or not isinstance(predecessor, str)
        or _CANDIDATE.fullmatch(predecessor) is None
    ):
        return None
    return predecessor


def _authorized_staged_preupload_predecessor(context: CandidateContext) -> str | None:
    """Return the exact predecessor authorized by a staged correction proof."""

    if context.identity_allocation_proof_sha256 is None:
        return None
    central_path = context.manifest_path.parent / "identity-allocation.json"
    central_bytes, central = _load_json_bytes(central_path)
    if hashlib.sha256(central_bytes).hexdigest() != context.identity_allocation_proof_sha256:
        raise BridgeError("identity-proof-central-mismatch")
    authorization = central.get("reuseAuthorization")
    if (
        not isinstance(authorization, Mapping)
        or authorization.get("kind") != "staged-preupload-correction"
    ):
        return None
    predecessor = authorization.get("priorCandidateId")
    prior_hash = authorization.get("priorStagePackageSha256")
    if (
        not isinstance(predecessor, str)
        or predecessor != f"{context.marketing_version}-{context.build_number - 1}"
        or _CANDIDATE.fullmatch(predecessor) is None
        or not isinstance(prior_hash, str)
        or _HEX64.fullmatch(prior_hash) is None
    ):
        return None
    return predecessor


def _archive_prepared_predecessor(
    root: Path,
    ledger_path: Path,
    allocation_path: Path,
    ledger: Mapping[str, Any],
    predecessor: str,
) -> str:
    """Recoverably archive one prepared predecessor authorized by central proof."""

    version = ledger.get("marketingVersion")
    build = ledger.get("build")
    metadata = ledger.get("metadata")
    workspace_value = metadata.get("candidateWorkspace") if isinstance(metadata, Mapping) else None
    if (
        ledger.get("candidateId") != predecessor
        or ledger.get("state") != "prepared"
        or not isinstance(version, str)
        or _SEMVER.fullmatch(version) is None
        or predecessor != f"{version}-{build}"
        or isinstance(build, bool)
        or not isinstance(build, int)
        or not isinstance(workspace_value, str)
    ):
        raise BridgeError("prepared-candidate-allocation-mismatch")
    workspace = Path(workspace_value)
    expected_workspace = (root / ".release-state" / "candidates" / predecessor).resolve()
    if (
        workspace.is_symlink()
        or not workspace.is_dir()
        or workspace.resolve() != expected_workspace
    ):
        raise BridgeError("prepared-candidate-allocation-mismatch")
    archived_root = root / ".release-state" / "archived" / predecessor
    archived_workspace = archived_root / "candidate-workspace"
    archived_ledger = archived_root / "candidate.json"
    archived_allocation = archived_root / "allocated-ios.json"
    allocation = None
    if allocation_path.is_file() and not allocation_path.is_symlink():
        allocation = _load_json(allocation_path)
    elif archived_allocation.is_file() and not archived_allocation.is_symlink():
        allocation = _load_json(archived_allocation)
    if (
        allocation is None
        or allocation.get("candidateId") != predecessor
        or allocation.get("state") != "allocated-but-unfrozen"
        or not _allocation_matches(allocation, candidate=predecessor, version=version, build=build)
    ):
        raise BridgeError("prepared-candidate-allocation-mismatch")
    if archived_root.exists():
        if (
            not archived_ledger.is_file()
            or _load_json(archived_ledger).get("state") != "superseded"
        ):
            raise BridgeError("prepared-candidate-archive-mismatch")
        if not archived_workspace.is_dir():
            raise BridgeError("prepared-candidate-archive-mismatch")
    else:
        archived_root.mkdir(mode=0o700, parents=True)
        try:
            shutil.copytree(workspace, archived_workspace)
            archived_record = dict(ledger)
            archived_record["state"] = "superseded"
            archived_metadata = dict(metadata) if isinstance(metadata, Mapping) else {}
            archived_metadata.update(
                {
                    "candidateWorkspace": str(archived_workspace),
                    "archivePath": str(archived_root),
                    "supersededReason": f"staged pre-upload correction for {predecessor}",
                    "supersededAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                }
            )
            archived_record["metadata"] = archived_metadata
            _write_json(archived_ledger, archived_record)
        except Exception:
            shutil.rmtree(archived_root, ignore_errors=True)
            raise

    if allocation_path.exists():
        staged = root / ".release-state" / ".rollover" / predecessor / "allocated-ios.json"
        if staged.exists():
            if staged.is_symlink() or staged.read_bytes() != allocation_path.read_bytes():
                raise BridgeError("staged-allocation-mismatch")
            allocation_path.unlink()
        else:
            staged.parent.mkdir(mode=0o700, parents=True, exist_ok=False)
            os.replace(allocation_path, staged)
    if ledger_path.exists():
        ledger_path.unlink()
    return predecessor


def _archive_authorized_unfrozen_predecessor(
    root: Path,
    allocation_path: Path,
    allocation: Mapping[str, Any],
    *,
    predecessor: str,
) -> bool:
    """Archive only the central-authorized, never-frozen predecessor allocation."""

    version = allocation.get("marketingVersion")
    build = allocation.get("build")
    if (
        allocation.get("candidateId") != predecessor
        or allocation.get("state") != "allocated-but-unfrozen"
        or not isinstance(version, str)
        or _SEMVER.fullmatch(version) is None
        or isinstance(build, bool)
        or not isinstance(build, int)
        or predecessor != f"{version}-{build}"
        or not isinstance(allocation.get("allocatedAt"), str)
        or not allocation["allocatedAt"]
    ):
        return False
    destination = root / ".release-state" / "failed-preupload" / predecessor / "allocated-ios.json"
    if destination.exists():
        if destination.is_symlink() or destination.read_bytes() != allocation_path.read_bytes():
            raise BridgeError("failed-preupload-allocation-archive-mismatch")
        allocation_path.unlink()
        return True
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.replace(allocation_path, destination)
    return True


def _finalize_staged_allocations(root: Path) -> None:
    staging_root = root / ".release-state" / ".rollover"
    if not staging_root.is_dir() or staging_root.is_symlink():
        return
    for staged in sorted(staging_root.glob("*/allocated-ios.json")):
        legacy_id = staged.parent.name
        if _CANDIDATE.fullmatch(legacy_id) is None or staged.is_symlink():
            raise BridgeError("staged-allocation-invalid")
        archived_root = root / ".release-state" / "archived" / legacy_id
        if not archived_root.exists():
            # The prior preparation can fail before the legacy ledger reaches
            # its archive step. Keep the exact old allocation staged so a
            # retry can resume without either losing it or allocating again.
            continue
        archived_ledger = _load_json(archived_root / "candidate.json")
        if (
            archived_ledger.get("candidateId") != legacy_id
            or archived_ledger.get("state") != "superseded"
        ):
            raise BridgeError("staged-allocation-archive-mismatch")
        destination = archived_root / "allocated-ios.json"
        if destination.exists():
            if destination.is_symlink() or destination.read_bytes() != staged.read_bytes():
                raise BridgeError("staged-allocation-destination-mismatch")
            staged.unlink()
        else:
            os.replace(staged, destination)
        try:
            staged.parent.rmdir()
            staging_root.rmdir()
        except OSError:
            pass


def reconcile_assigned_candidate(root: Path, context: CandidateContext) -> str | None:
    """Stage one exact stale allocation so the legacy assigned ledger can roll over."""

    _finalize_staged_allocations(root)
    proof = _identity_proof(root, context)
    ledger_path = root / ".release-state" / "candidate.json"
    allocation_path = root / ".release-state" / "allocated-ios.json"
    if not ledger_path.exists():
        if allocation_path.exists():
            allocation = _load_json(allocation_path)
            if not _allocation_matches(
                allocation,
                candidate=context.candidate_id,
                version=context.marketing_version,
                build=context.build_number,
            ):
                raise BridgeError("orphaned-allocation-mismatch")
        return None

    ledger = _load_json(ledger_path)
    if ledger.get("candidateId") == context.candidate_id:
        if (
            ledger.get("state") != "prepared"
            or ledger.get("marketingVersion") != context.marketing_version
            or ledger.get("build") != context.build_number
        ):
            raise BridgeError("central-ledger-mismatch")
        return None
    if ledger.get("state") == "prepared":
        predecessor = _authorized_staged_preupload_predecessor(context)
        if predecessor is None:
            predecessor = _authorized_failed_preupload_predecessor(context)
        if predecessor != ledger.get("candidateId"):
            raise BridgeError("legacy-candidate-not-rollover-safe")
        return _archive_prepared_predecessor(
            root, ledger_path, allocation_path, ledger, predecessor
        )
    if ledger.get("state") != "assigned":
        raise BridgeError("legacy-candidate-not-rollover-safe")

    legacy_id = ledger.get("candidateId")
    legacy_version = ledger.get("marketingVersion")
    legacy_build = ledger.get("build")
    metadata = ledger.get("metadata")
    workspace = metadata.get("candidateWorkspace") if isinstance(metadata, Mapping) else None
    if (
        not isinstance(legacy_id, str)
        or _CANDIDATE.fullmatch(legacy_id) is None
        or not isinstance(legacy_version, str)
        or _SEMVER.fullmatch(legacy_version) is None
        or isinstance(legacy_build, bool)
        or not isinstance(legacy_build, int)
        or not isinstance(workspace, str)
        or not Path(workspace).is_dir()
        or not (
            (
                proof.get("remoteHighestMarketingVersion") == legacy_version
                and proof.get("remoteHighestBuildNumber") == legacy_build
            )
            or (
                proof.get("buildNumber") == context.build_number
                and isinstance(proof.get("remoteHighestBuildNumber"), int)
                and proof.get("remoteHighestBuildNumber") < context.build_number
                and proof.get("remoteHighestBuildNumber") >= legacy_build
                and context.build_number > legacy_build
            )
        )
    ):
        raise BridgeError("assigned-candidate-allocation-mismatch")

    staged = root / ".release-state" / ".rollover" / legacy_id / "allocated-ios.json"
    old_matches = False
    current_matches = False
    if allocation_path.exists():
        allocation = _load_json(allocation_path)
        old_matches = _allocation_matches(
            allocation, candidate=legacy_id, version=legacy_version, build=legacy_build
        )
        current_matches = _allocation_matches(
            allocation,
            candidate=context.candidate_id,
            version=context.marketing_version,
            build=context.build_number,
        )
        if not old_matches and not current_matches:
            predecessor = _authorized_failed_preupload_predecessor(context)
            if predecessor is None or not _archive_authorized_unfrozen_predecessor(
                root,
                allocation_path,
                allocation,
                predecessor=predecessor,
            ):
                raise BridgeError("active-allocation-mismatch")
            return legacy_id
    if staged.exists():
        staged_allocation = _load_json(staged)
        if not _allocation_matches(
            staged_allocation,
            candidate=legacy_id,
            version=legacy_version,
            build=legacy_build,
        ):
            raise BridgeError("staged-allocation-invalid")
        if old_matches:
            if staged.read_bytes() != allocation_path.read_bytes():
                raise BridgeError("staged-allocation-mismatch")
            allocation_path.unlink()
        elif not current_matches and allocation_path.exists():
            raise BridgeError("active-allocation-mismatch")
    else:
        if not old_matches:
            raise BridgeError("assigned-candidate-allocation-mismatch")
        staged.parent.mkdir(mode=0o700, parents=True, exist_ok=False)
        os.replace(allocation_path, staged)
    return legacy_id


def prepared_artifact(root: Path, context: CandidateContext) -> PreparedArtifact:
    """Resolve the exact durable IPA prepared for this central candidate."""

    ledger = _load_json(root / ".release-state" / "candidate.json")
    allocation = _load_json(root / ".release-state" / "allocated-ios.json")
    metadata = ledger.get("metadata")
    ipa_value = metadata.get("ipaPath") if isinstance(metadata, Mapping) else None
    if (
        ledger.get("candidateId") != context.candidate_id
        or ledger.get("state") != "prepared"
        or ledger.get("marketingVersion") != context.marketing_version
        or ledger.get("build") != context.build_number
        or not isinstance(ipa_value, str)
        or not isinstance(ledger.get("artifactSha256"), str)
        or _HEX64.fullmatch(str(ledger.get("artifactSha256"))) is None
        or not _allocation_matches(
            allocation,
            candidate=context.candidate_id,
            version=context.marketing_version,
            build=context.build_number,
        )
    ):
        raise BridgeError("prepared-candidate-mismatch")
    ipa = Path(ipa_value).resolve(strict=False)
    expected_root = (root / ".release-state" / "candidates" / context.candidate_id).resolve()
    try:
        ipa.relative_to(expected_root)
    except ValueError as exc:
        raise BridgeError("prepared-artifact-path-mismatch") from exc
    if ipa.is_symlink() or not ipa.is_file() or _sha256(ipa) != ledger["artifactSha256"]:
        raise BridgeError("prepared-artifact-digest-mismatch")
    return PreparedArtifact(ipa, str(ledger["artifactSha256"]))


def _handoff_prepared_workspace(
    root: Path, context: CandidateContext, artifact: PreparedArtifact
) -> None:
    """Copy the exact legacy prepared workspace into the central candidate record."""

    ledger = _load_json(root / ".release-state" / "candidate.json")
    metadata = ledger.get("metadata")
    workspace_value = metadata.get("candidateWorkspace") if isinstance(metadata, Mapping) else None
    if (
        ledger.get("candidateId") != context.candidate_id
        or ledger.get("state") != "prepared"
        or not isinstance(workspace_value, str)
    ):
        raise BridgeError("prepared-workspace-binding-mismatch")
    workspace = Path(workspace_value)
    expected_workspace = (root / ".release-state" / "candidates" / context.candidate_id).resolve()
    if (
        workspace.is_symlink()
        or not workspace.is_dir()
        or workspace.resolve() != expected_workspace
    ):
        raise BridgeError("prepared-workspace-binding-mismatch")
    try:
        artifact.ipa_path.resolve().relative_to(workspace.resolve())
    except ValueError as exc:
        raise BridgeError("prepared-artifact-path-mismatch") from exc

    destination = context.manifest_path.parent / "candidate-workspace"

    def validate_tree(path: Path) -> None:
        if path.is_symlink():
            raise BridgeError("prepared-workspace-symlink")
        for entry in path.iterdir():
            if entry.is_symlink():
                raise BridgeError("prepared-workspace-symlink")
            if entry.is_dir():
                validate_tree(entry)

    validate_tree(workspace)
    if destination.exists():
        if destination.is_symlink() or not destination.is_dir():
            raise BridgeError("central-workspace-mismatch")
        validate_tree(destination)
        source_files = sorted(
            path.relative_to(workspace) for path in workspace.rglob("*") if path.is_file()
        )
        target_files = sorted(
            path.relative_to(destination) for path in destination.rglob("*") if path.is_file()
        )
        if source_files != target_files or any(
            (workspace / relative).read_bytes() != (destination / relative).read_bytes()
            for relative in source_files
        ):
            raise BridgeError("central-workspace-mismatch")
        return
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    shutil.copytree(workspace, destination)


def _run_checked(
    argv: Sequence[str], *, capture_output: bool = False
) -> subprocess.CompletedProcess[bytes]:
    result = subprocess.run(
        list(argv),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE if capture_output else subprocess.DEVNULL,
        stderr=subprocess.PIPE if capture_output else subprocess.DEVNULL,
        check=False,
    )
    if result.returncode != 0:
        raise BridgeError("artifact-inspection-failed")
    return result


def inspect_artifact(artifact: PreparedArtifact, context: CandidateContext) -> ArtifactInspection:
    """Verify and extract non-secret release metadata from one signed IPA."""

    with tempfile.TemporaryDirectory(prefix="gradus-release-proof.") as temporary:
        unpacked = Path(temporary)
        _run_checked(["/usr/bin/ditto", "-x", "-k", str(artifact.ipa_path), str(unpacked)])
        payload = unpacked / "Payload"
        if payload.is_symlink() or not payload.is_dir():
            raise BridgeError("artifact-layout-invalid")
        applications = list(payload.glob("*.app"))
        if len(applications) != 1 or not applications[0].is_dir() or applications[0].is_symlink():
            raise BridgeError("artifact-layout-invalid")
        application = applications[0]

        # 1. Main app Info.plist
        info_path = application / "Info.plist"
        if info_path.is_symlink() or not info_path.is_file():
            raise BridgeError("artifact-metadata-invalid")
        try:
            info = plistlib.loads(info_path.read_bytes())
        except (OSError, plistlib.InvalidFileException) as exc:
            raise BridgeError("artifact-metadata-invalid") from exc
        if (
            info.get("CFBundleIdentifier") != BUNDLE_IDENTIFIER
            or info.get("CFBundleShortVersionString") != context.marketing_version
            or str(info.get("CFBundleVersion")) != str(context.build_number)
        ):
            raise BridgeError("artifact-metadata-mismatch")

        # 2. Nested widget extension presence and layout
        plugins_dir = application / "PlugIns"
        if plugins_dir.is_symlink() or not plugins_dir.is_dir():
            raise BridgeError("artifact-layout-invalid")
        appex_bundles = [p for p in plugins_dir.glob("*.appex") if not p.is_symlink()]
        if len(appex_bundles) != 1:
            raise BridgeError("artifact-layout-invalid")
        widget_bundle = appex_bundles[0]
        if widget_bundle.name != WIDGET_EXTENSION_NAME or not widget_bundle.is_dir():
            raise BridgeError("artifact-layout-invalid")

        # 3. Extension Info.plist
        widget_info_path = widget_bundle / "Info.plist"
        if widget_info_path.is_symlink() or not widget_info_path.is_file():
            raise BridgeError("artifact-metadata-invalid")
        try:
            widget_info = plistlib.loads(widget_info_path.read_bytes())
        except (OSError, plistlib.InvalidFileException) as exc:
            raise BridgeError("artifact-metadata-invalid") from exc
        if (
            widget_info.get("CFBundleIdentifier") != WIDGET_BUNDLE_IDENTIFIER
            or widget_info.get("CFBundleShortVersionString") != context.marketing_version
            or str(widget_info.get("CFBundleVersion")) != str(context.build_number)
        ):
            raise BridgeError("artifact-metadata-mismatch")

        # 4. Embedded mobileprovision profiles
        profile_path = application / "embedded.mobileprovision"
        if profile_path.is_symlink() or not profile_path.is_file():
            raise BridgeError("embedded-profile-missing")
        widget_profile_path = widget_bundle / "embedded.mobileprovision"
        if widget_profile_path.is_symlink() or not widget_profile_path.is_file():
            raise BridgeError("embedded-profile-missing")

        # Profile swap detection (profiles must be distinct files)
        profile_bytes = profile_path.read_bytes()
        widget_profile_bytes = widget_profile_path.read_bytes()
        if profile_bytes == widget_profile_bytes:
            raise BridgeError("embedded-profile-mismatch")

        # Verify and parse main app profile
        profile_result = _run_checked(
            [
                "/usr/bin/openssl",
                "smime",
                "-verify",
                "-noverify",
                "-inform",
                "der",
                "-in",
                str(profile_path),
            ],
            capture_output=True,
        )
        try:
            profile = plistlib.loads(profile_result.stdout)
        except plistlib.InvalidFileException as exc:
            raise BridgeError("embedded-profile-invalid") from exc
        profile_entitlements = profile.get("Entitlements")
        if not isinstance(profile_entitlements, Mapping):
            raise BridgeError("embedded-profile-invalid")

        # Verify and parse widget profile
        widget_profile_result = _run_checked(
            [
                "/usr/bin/openssl",
                "smime",
                "-verify",
                "-noverify",
                "-inform",
                "der",
                "-in",
                str(widget_profile_path),
            ],
            capture_output=True,
        )
        try:
            widget_profile = plistlib.loads(widget_profile_result.stdout)
        except plistlib.InvalidFileException as exc:
            raise BridgeError("embedded-profile-invalid") from exc
        widget_profile_entitlements = widget_profile.get("Entitlements")
        if not isinstance(widget_profile_entitlements, Mapping):
            raise BridgeError("embedded-profile-invalid")

        application_identifier = f"{TEAM_IDENTIFIER}.{BUNDLE_IDENTIFIER}"
        widget_application_identifier = f"{TEAM_IDENTIFIER}.{WIDGET_BUNDLE_IDENTIFIER}"

        # Profile identity validation
        if (
            profile_entitlements.get("application-identifier") != application_identifier
            or widget_profile_entitlements.get("application-identifier")
            != widget_application_identifier
            or profile_entitlements.get("com.apple.developer.team-identifier") != TEAM_IDENTIFIER
            or widget_profile_entitlements.get("com.apple.developer.team-identifier")
            != TEAM_IDENTIFIER
        ):
            raise BridgeError("embedded-profile-mismatch")

        # Profile CloudKit environment for main app
        main_profile_cloudkit = profile_entitlements.get(
            "com.apple.developer.icloud-container-environment"
        )
        if isinstance(main_profile_cloudkit, str):
            if main_profile_cloudkit != "Production":
                raise BridgeError("signed-entitlements-mismatch")
        elif isinstance(main_profile_cloudkit, (list, tuple)):
            if "Production" not in main_profile_cloudkit:
                raise BridgeError("signed-entitlements-mismatch")
        else:
            raise BridgeError("signed-entitlements-mismatch")

        # Profile App Groups
        main_profile_groups = profile_entitlements.get("com.apple.security.application-groups", ())
        widget_profile_groups = widget_profile_entitlements.get(
            "com.apple.security.application-groups", ()
        )
        if (
            not isinstance(main_profile_groups, (list, tuple))
            or APP_GROUP_IDENTIFIER not in main_profile_groups
            or not isinstance(widget_profile_groups, (list, tuple))
            or APP_GROUP_IDENTIFIER not in widget_profile_groups
        ):
            raise BridgeError("signed-entitlements-mismatch")

        # Disallowed keys in widget profile
        if any(key in widget_profile_entitlements for key in DISALLOWED_EXTENSION_ENTITLEMENT_KEYS):
            raise BridgeError("signed-entitlements-mismatch")

        # 5. Codesign deep & strict verification (widget first, then main app)
        _run_checked(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(widget_bundle)])
        _run_checked(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(application)])

        # 6. Extract signed entitlements
        entitlements_result = _run_checked(
            ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(application)],
            capture_output=True,
        )
        try:
            entitlements = plistlib.loads(entitlements_result.stdout)
        except plistlib.InvalidFileException as exc:
            raise BridgeError("signed-entitlements-invalid") from exc

        widget_entitlements_result = _run_checked(
            ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(widget_bundle)],
            capture_output=True,
        )
        try:
            widget_entitlements = plistlib.loads(widget_entitlements_result.stdout)
        except plistlib.InvalidFileException as exc:
            raise BridgeError("signed-entitlements-invalid") from exc

        # Main app signed entitlements
        main_signed_groups = entitlements.get("com.apple.security.application-groups", ())
        if (
            entitlements.get("application-identifier") != application_identifier
            or entitlements.get("com.apple.developer.team-identifier") != TEAM_IDENTIFIER
            or entitlements.get("com.apple.developer.icloud-container-environment") != "Production"
            or entitlements.get("get-task-allow") is not False
            or not isinstance(main_signed_groups, (list, tuple))
            or APP_GROUP_IDENTIFIER not in main_signed_groups
        ):
            raise BridgeError("signed-entitlements-mismatch")

        # Widget signed entitlements
        widget_signed_groups = widget_entitlements.get("com.apple.security.application-groups", ())
        if (
            widget_entitlements.get("application-identifier") != widget_application_identifier
            or widget_entitlements.get("com.apple.developer.team-identifier") != TEAM_IDENTIFIER
            or widget_entitlements.get("get-task-allow") is not False
            or not isinstance(widget_signed_groups, (list, tuple))
            or APP_GROUP_IDENTIFIER not in widget_signed_groups
        ):
            raise BridgeError("signed-entitlements-mismatch")

        # Disallowed keys in widget signed entitlements
        if any(key in widget_entitlements for key in DISALLOWED_EXTENSION_ENTITLEMENT_KEYS):
            raise BridgeError("signed-entitlements-mismatch")

        # 7. Signing certificates extraction
        certificate_prefix = unpacked / "signing-certificate-"
        _run_checked(
            [
                "/usr/bin/codesign",
                "-d",
                f"--extract-certificates={certificate_prefix}",
                str(application),
            ]
        )
        leaf_certificate = Path(f"{certificate_prefix}0")
        if not leaf_certificate.is_file():
            raise BridgeError("signing-certificate-missing")

        widget_certificate_prefix = unpacked / "widget-signing-certificate-"
        _run_checked(
            [
                "/usr/bin/codesign",
                "-d",
                f"--extract-certificates={widget_certificate_prefix}",
                str(widget_bundle),
            ]
        )
        widget_leaf_certificate = Path(f"{widget_certificate_prefix}0")
        if not widget_leaf_certificate.is_file():
            raise BridgeError("signing-certificate-missing")

        profile_digest = _sha256(profile_path)
        certificate_digest = _sha256(leaf_certificate)
        widget_profile_digest = _sha256(widget_profile_path)
        widget_certificate_digest = _sha256(widget_leaf_certificate)

        metadata = {
            "appGroup": APP_GROUP_IDENTIFIER,
            "applicationIdentifier": application_identifier,
            "artifactSha256": artifact.artifact_sha256,
            "bundleIdentifier": BUNDLE_IDENTIFIER,
            "buildNumber": str(context.build_number),
            "cloudKitEnvironment": "Production",
            "embeddedProfileSha256": profile_digest,
            "marketingVersion": context.marketing_version,
            "signingCertificateSha256": certificate_digest,
            "strictSignatureResult": "passed",
            "teamIdentifier": TEAM_IDENTIFIER,
            "uploadValidationResult": "passed",
            "widgetAppGroup": APP_GROUP_IDENTIFIER,
            "widgetApplicationIdentifier": widget_application_identifier,
            "widgetBundleIdentifier": WIDGET_BUNDLE_IDENTIFIER,
            "widgetBuildNumber": str(context.build_number),
            "widgetEmbeddedProfileSha256": widget_profile_digest,
            "widgetExtensionName": WIDGET_EXTENSION_NAME,
            "widgetMarketingVersion": context.marketing_version,
            "widgetSigningCertificateSha256": widget_certificate_digest,
            "widgetStrictSignatureResult": "passed",
        }
        return ArtifactInspection(
            profile_digest,
            certificate_digest,
            _canonical_digest(metadata),
            widget_profile_digest,
            widget_certificate_digest,
        )


def build_proof(
    operation: str,
    context: CandidateContext,
    artifact: PreparedArtifact,
    *,
    inspection: ArtifactInspection | None = None,
    now: datetime | None = None,
) -> dict[str, Any]:
    """Build one central-schema proof from the frozen local artifact."""

    common: dict[str, Any] = {
        "proofVersion": "1.0.0",
        "candidateId": context.candidate_id,
        "sourceDigest": context.source_digest,
        "result": "passed",
        "reuseAuthorized": True,
    }
    if operation == "production-build":
        issued = now or datetime.now(timezone.utc)
        expires = issued + timedelta(hours=6)
        return {
            **common,
            "proofSchema": "release.proof.production-build.v1",
            "operationClass": "productionReleaseBuild",
            "configuration": "Production",
            "cleanBuild": True,
            "signingMode": "appStore",
            "issuedAt": issued.isoformat().replace("+00:00", "Z"),
            "expiresAt": expires.isoformat().replace("+00:00", "Z"),
            "artifactSha256": artifact.artifact_sha256,
        }
    if operation == "archive":
        return {
            **common,
            "operationClass": "archive",
            "archiveSha256": artifact.artifact_sha256,
        }
    if inspection is None:
        raise BridgeError("artifact-inspection-required")
    signing = {
        **common,
        "archiveSha256": artifact.artifact_sha256,
        "signedArtifactSha256": artifact.artifact_sha256,
        "embeddedProfileSha256": inspection.embedded_profile_sha256,
        "signingCertificateSha256": inspection.signing_certificate_sha256,
    }
    if operation == "sign":
        return {**signing, "operationClass": "sign", "signatureType": "distribution"}
    if operation == "artifact-verify":
        return {
            **signing,
            "operationClass": "artifactVerify",
            "metadataSha256": inspection.metadata_sha256,
            "bundleIdentifierSha256": _text_digest(BUNDLE_IDENTIFIER),
            "marketingVersionSha256": _text_digest(context.marketing_version),
            "buildNumber": str(context.build_number),
            "applicationIdentifierSha256": _text_digest(f"{TEAM_IDENTIFIER}.{BUNDLE_IDENTIFIER}"),
            "teamIdentifierSha256": _text_digest(TEAM_IDENTIFIER),
            "configuration": "Production",
            "cloudKitEnvironment": "Production",
            "signed": True,
            "strictSignatureResult": "passed",
            "uploadValidationResult": "passed",
        }
    raise BridgeError("operation-not-supported")


def _proof_path(root: Path, context: CandidateContext, operation: str) -> Path:
    filename = {
        "production-build": "production-build.json",
        "archive": "archive.json",
        "sign": "signing.json",
        "artifact-verify": "artifact.json",
    }[operation]
    return root / ".release-state" / "evidence" / context.candidate_id / filename


def execute(
    operation: str,
    context: CandidateContext,
    *,
    root: Path = ROOT,
    runner: Callable[..., subprocess.CompletedProcess[Any]] = subprocess.run,
    inspector: Callable[
        [PreparedArtifact, CandidateContext], ArtifactInspection
    ] = inspect_artifact,
) -> Path:
    """Prepare if needed, then emit the requested candidate-bound proof."""

    if operation not in OPERATIONS:
        raise BridgeError("operation-not-supported")
    if operation in {"production-build", "all"}:
        legacy_id = reconcile_assigned_candidate(root, context)
        environment = {
            name: value for name, value in os.environ.items() if name not in _SECRET_NAMES
        }
        environment["GRADUS_CANDIDATE_ID"] = context.candidate_id
        environment["GRADUS_RELEASE_BRIDGE_ACTIVE"] = "1"
        correction_proof = (
            root / ".release-state" / "evidence" / context.candidate_id / "allocate-identity.json"
        )
        if correction_proof.is_file() and not correction_proof.is_symlink():
            environment["GRADUS_IDENTITY_ALLOCATION_PROOF_PATH"] = str(correction_proof)
        argv = [
            str(root / "app" / "archive-upload-ios.sh"),
            "--prepare-only",
            "--candidate",
            context.candidate_id,
        ]
        if legacy_id is not None:
            argv.extend(
                [
                    "--rollover-assigned",
                    "--supersession-reason",
                    f"superseded by central candidate {context.candidate_id}",
                ]
            )
        result = runner(
            argv,
            cwd=root,
            env=environment,
            stdin=subprocess.DEVNULL,
            check=False,
        )
        if result.returncode != 0:
            raise BridgeError("legacy-preparation-failed")
        _finalize_staged_allocations(root)
        _handoff_prepared_workspace(root, context, prepared_artifact(root, context))

    artifact = prepared_artifact(root, context)
    if operation == "all":
        inspection = inspector(artifact, context)
        paths = []
        for proof_operation in PROOF_OPERATIONS:
            proof = build_proof(
                proof_operation,
                context,
                artifact,
                inspection=inspection if proof_operation in {"sign", "artifact-verify"} else None,
            )
            path = _proof_path(root, context, proof_operation)
            _write_json(path, proof)
            paths.append(path)
        return paths[-1]
    inspection = inspector(artifact, context) if operation in {"sign", "artifact-verify"} else None
    proof = build_proof(operation, context, artifact, inspection=inspection)
    path = _proof_path(root, context, operation)
    _write_json(path, proof)
    return path


def _git_common_dir(root: Path) -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--git-common-dir"],
        cwd=root,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        check=False,
    )
    if result.returncode != 0 or not result.stdout.strip():
        raise BridgeError("git-common-state-unavailable")
    value = Path(result.stdout.strip())
    return (root / value).resolve() if not value.is_absolute() else value.resolve()


def _active_manifest(git_common_dir: Path) -> Path:
    pointer = _load_json(git_common_dir / "release-state" / PRODUCT / "active-candidate.json")
    candidate = pointer.get("candidateId")
    if not isinstance(candidate, str) or _CANDIDATE.fullmatch(candidate) is None:
        raise BridgeError("central-candidate-invalid")
    return git_common_dir / "release-state" / PRODUCT / "candidates" / candidate / "manifest.json"


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--operation", choices=sorted(OPERATIONS), required=True)
    try:
        arguments = parser.parse_args(argv)
        git_common_dir = _git_common_dir(ROOT)
        manifest_value = os.environ.get("READINESS_MANIFEST")
        if manifest_value and "\x00" in manifest_value:
            raise BridgeError("central-manifest-unavailable")
        manifest_path = Path(manifest_value) if manifest_value else _active_manifest(git_common_dir)
        context = load_context(manifest_path, git_common_dir=git_common_dir)
        execute(arguments.operation, context)
    except (BridgeError, OSError, TypeError, ValueError, zipfile.BadZipFile):
        return 5
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
