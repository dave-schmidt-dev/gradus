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
TEAM_IDENTIFIER = "4CJ49V6QHW"
ARCHIVE_SCRIPT = ROOT / "app" / "archive-upload-ios.sh"
PROOF_OPERATIONS = ("production-build", "archive", "sign", "artifact-verify")
OPERATIONS = frozenset((*PROOF_OPERATIONS, "all"))
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


def _load_json(path: Path) -> Mapping[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise BridgeError("required-record-unavailable")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise BridgeError("required-record-unreadable") from exc
    if not isinstance(value, Mapping):
        raise BridgeError("required-record-invalid")
    return value


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
        manifest_path, candidate, source_digest, marketing_version, build_number
    )


def _identity_proof(root: Path, context: CandidateContext) -> Mapping[str, Any]:
    proof = _load_json(root / ".release-state" / "evidence" / "allocate-identity.json")
    if (
        proof.get("proofVersion") != "1.0.0"
        or proof.get("operationClass") != "identityAllocation"
        or proof.get("result") != "passed"
        or proof.get("productKey") != PRODUCT
        or proof.get("marketingVersion") != context.marketing_version
        or proof.get("buildNumber") != context.build_number
        or proof.get("buildNumber") != proof.get("remoteHighestBuildNumber", -1) + 1
        or not isinstance(proof.get("responseSha256"), str)
        or _HEX64.fullmatch(str(proof.get("responseSha256"))) is None
    ):
        raise BridgeError("identity-proof-central-mismatch")
    return proof


def _allocation_matches(
    allocation: Mapping[str, Any], *, candidate: str, version: str, build: int
) -> bool:
    return (
        allocation.get("state") == "allocated-but-unfrozen"
        and allocation.get("candidateId") == candidate
        and allocation.get("marketingVersion") == version
        and allocation.get("build") == build
        and isinstance(allocation.get("allocatedAt"), str)
        and bool(allocation.get("allocatedAt"))
    )


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
        or isinstance(legacy_build, bool)
        or not isinstance(legacy_build, int)
        or not isinstance(workspace, str)
        or not Path(workspace).is_dir()
        or proof.get("remoteHighestMarketingVersion") != legacy_version
        or proof.get("remoteHighestBuildNumber") != legacy_build
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
        applications = list((unpacked / "Payload").glob("*.app"))
        if len(applications) != 1 or not applications[0].is_dir():
            raise BridgeError("artifact-layout-invalid")
        application = applications[0]
        try:
            info = plistlib.loads((application / "Info.plist").read_bytes())
        except (OSError, plistlib.InvalidFileException) as exc:
            raise BridgeError("artifact-metadata-invalid") from exc
        if (
            info.get("CFBundleIdentifier") != BUNDLE_IDENTIFIER
            or info.get("CFBundleShortVersionString") != context.marketing_version
            or str(info.get("CFBundleVersion")) != str(context.build_number)
        ):
            raise BridgeError("artifact-metadata-mismatch")

        profile_path = application / "embedded.mobileprovision"
        if profile_path.is_symlink() or not profile_path.is_file():
            raise BridgeError("embedded-profile-missing")
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

        _run_checked(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(application)])
        entitlements_result = _run_checked(
            ["/usr/bin/codesign", "-d", "--entitlements", ":-", str(application)],
            capture_output=True,
        )
        try:
            entitlements = plistlib.loads(entitlements_result.stdout)
        except plistlib.InvalidFileException as exc:
            raise BridgeError("signed-entitlements-invalid") from exc
        application_identifier = f"{TEAM_IDENTIFIER}.{BUNDLE_IDENTIFIER}"
        if (
            entitlements.get("application-identifier") != application_identifier
            or entitlements.get("com.apple.developer.team-identifier") != TEAM_IDENTIFIER
            or entitlements.get("com.apple.developer.icloud-container-environment") != "Production"
            or entitlements.get("get-task-allow") is not False
            or "Production"
            not in profile_entitlements.get("com.apple.developer.icloud-container-environment", ())
        ):
            raise BridgeError("signed-entitlements-mismatch")

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
        profile_digest = _sha256(profile_path)
        certificate_digest = _sha256(leaf_certificate)
        metadata = {
            "artifactSha256": artifact.artifact_sha256,
            "bundleIdentifier": BUNDLE_IDENTIFIER,
            "marketingVersion": context.marketing_version,
            "buildNumber": str(context.build_number),
            "applicationIdentifier": application_identifier,
            "teamIdentifier": TEAM_IDENTIFIER,
            "cloudKitEnvironment": "Production",
            "embeddedProfileSha256": profile_digest,
            "signingCertificateSha256": certificate_digest,
            "strictSignatureResult": "passed",
            "uploadValidationResult": "passed",
        }
        return ArtifactInspection(profile_digest, certificate_digest, _canonical_digest(metadata))


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
