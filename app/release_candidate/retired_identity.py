"""Read-only proof that a centrally retired, unuploaded candidate freed an identity.

The returned build number is only a local allocation hint. The original ASC
observation remains intact, and the central release validator remains the
authority that accepts or rejects the proof.
"""

from __future__ import annotations

import json
import os
import re
import stat
import sys
from collections.abc import Mapping
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

PRODUCT = "gradus-ios"
_SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
_CANDIDATE = re.compile(
    r"^(?P<version>(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))"
    r"-(?P<build>[1-9][0-9]{0,9})$"
)
_HEX64 = re.compile(r"^[0-9a-f]{64}$")
_POSITIVE_INTEGER = re.compile(r"^[1-9][0-9]{0,9}$")
_MAX_CHAIN_LENGTH = 64
_MAX_LEDGER_BYTES = 1024 * 1024
_MAX_LEDGER_RECORDS = 4096
_MAX_MANIFEST_BYTES = 1024 * 1024
_MAX_CANDIDATE_ENTRIES = 256
_ALLOCATION_SUFFIX = ".allocated-but-unfrozen.json"
_MAX_OBSERVATION_AGE_SECONDS = 600
_MAX_FUTURE_SKEW_SECONDS = 30
_UPLOAD_TRANSITIONS = frozenset({"uploadAttemptStarted", "uploaded", "internalTestFlightReceipted"})


def _is_regular_file(path: Path) -> bool:
    try:
        return stat.S_ISREG(path.lstat().st_mode)
    except OSError:
        return False


def _is_directory(path: Path) -> bool:
    try:
        return stat.S_ISDIR(path.lstat().st_mode)
    except OSError:
        return False


def _read_mapping(path: Path, *, max_bytes: int) -> Mapping[str, Any] | None:
    if not _is_regular_file(path):
        return None
    try:
        if path.stat().st_size > max_bytes:
            return None
        encoded = path.read_bytes()
        if len(encoded) > max_bytes:
            return None
        value = json.loads(encoded)
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, Mapping) else None


def _canonical_bytes(value: Mapping[str, Any]) -> bytes:
    return json.dumps(
        dict(value), ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def _git_common_directory(repository_root: Path) -> Path | None:
    """Resolve the checkout's Git common directory, including worktrees."""

    try:
        root = repository_root.resolve(strict=True)
    except (OSError, RuntimeError):
        return None
    if not root.is_dir():
        return None
    git_entry = root / ".git"
    if git_entry.is_symlink():
        return None
    if _is_directory(git_entry):
        return git_entry.resolve()
    if not _is_regular_file(git_entry):
        return None
    try:
        lines = git_entry.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return None
    if len(lines) != 1 or not lines[0].startswith("gitdir: "):
        return None
    git_directory = Path(lines[0][8:])
    if not str(git_directory) or "\x00" in str(git_directory):
        return None
    if not git_directory.is_absolute():
        git_directory = root / git_directory
    if not _is_directory(git_directory):
        return None
    git_directory = git_directory.resolve()
    commondir_file = git_directory / "commondir"
    if not _is_regular_file(commondir_file):
        return None
    try:
        common_value = commondir_file.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError):
        return None
    if not common_value or "\x00" in common_value:
        return None
    common_directory = Path(common_value)
    if not common_directory.is_absolute():
        common_directory = git_directory / common_directory
    if not _is_directory(common_directory):
        return None
    return common_directory.resolve()


def _build_number(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if 1 <= value <= 9_999_999_999 else None
    if isinstance(value, str) and _POSITIVE_INTEGER.fullmatch(value):
        return int(value)
    return None


def _fresh_remote_observation(proof: Mapping[str, Any]) -> bool:
    observed_at = proof.get("observedAt")
    if not isinstance(observed_at, str):
        return False
    try:
        observed = datetime.fromisoformat(observed_at.replace("Z", "+00:00"))
    except ValueError:
        return False
    if observed.tzinfo is None or observed.utcoffset() is None:
        return False
    age = (datetime.now(timezone.utc) - observed.astimezone(timezone.utc)).total_seconds()
    return -_MAX_FUTURE_SKEW_SECONDS <= age <= _MAX_OBSERVATION_AGE_SECONDS


def _central_readers() -> tuple[Any, Any]:
    """Load the same canonical readers used by the TestFlight wrapper."""

    central_root = Path(__file__).resolve().parents[2].parent / "apple_developer"
    if not _is_directory(central_root / "release_tools"):
        raise ImportError("central release_tools is unavailable")
    central_path = str(central_root)
    if central_path not in sys.path:
        sys.path.insert(0, central_path)
    from release_tools.iterative_release import (  # type: ignore[import-not-found]
        load_candidate_manifest,
        read_candidate_ledger_v2,
    )

    return load_candidate_manifest, read_candidate_ledger_v2


def _verified_manifest(
    candidate_root: Path, candidate_id: str, version: str, build: int
) -> Mapping[str, Any] | None:
    manifest_path = candidate_root / "manifest.json"
    if not _is_regular_file(manifest_path):
        return None
    if _read_mapping(manifest_path, max_bytes=_MAX_MANIFEST_BYTES) is None:
        return None
    try:
        load_candidate_manifest, _ = _central_readers()
        manifest = load_candidate_manifest(manifest_path)
    except Exception:
        return None
    release = manifest.get("release")
    valid = (
        manifest.get("formatVersion") == 2
        and manifest.get("candidateId") == candidate_id
        and manifest.get("productIdentifier") == PRODUCT
        and isinstance(release, Mapping)
        and release.get("marketingVersion") == version
        and _build_number(release.get("buildNumber")) == build
    )
    return manifest if valid else None


def _valid_allocation_record(
    path: Path,
    *,
    candidate_id: str,
    version: str,
    build: int,
    manifest: Mapping[str, Any],
) -> bool:
    record = _read_mapping(path, max_bytes=_MAX_MANIFEST_BYTES)
    if record is None:
        return False
    required = {
        "formatVersion",
        "state",
        "candidateId",
        "productKey",
        "marketingVersion",
        "buildNumber",
        "sourceDigest",
        "adapterDigest",
        "allocationProofSha256",
        "observedAt",
    }
    if set(record) != required:
        return False
    try:
        encoded = path.read_bytes()
        observed = datetime.fromisoformat(str(record["observedAt"]).replace("Z", "+00:00"))
    except (OSError, UnicodeError, ValueError):
        return False
    if observed.tzinfo is None or observed.utcoffset() is None:
        return False
    if encoded != _canonical_bytes(record) + b"\n":
        return False
    source_snapshot = manifest.get("sourceSnapshot")
    adapter = manifest.get("adapter")
    identity = manifest.get("identityAllocation")
    return (
        isinstance(record.get("formatVersion"), int)
        and not isinstance(record.get("formatVersion"), bool)
        and record.get("formatVersion") == 1
        and record.get("state") == "allocated-but-unfrozen"
        and record.get("candidateId") == candidate_id
        and record.get("productKey") == PRODUCT
        and record.get("marketingVersion") == version
        and isinstance(record.get("buildNumber"), int)
        and not isinstance(record.get("buildNumber"), bool)
        and record.get("buildNumber") == build
        and isinstance(source_snapshot, Mapping)
        and record.get("sourceDigest") == source_snapshot.get("sha256")
        and isinstance(adapter, Mapping)
        and record.get("adapterDigest") == adapter.get("sha256")
        and isinstance(identity, Mapping)
        and record.get("allocationProofSha256") == identity.get("proofSha256")
        and all(
            isinstance(record.get(key), str) and _HEX64.fullmatch(record[key]) is not None
            for key in ("sourceDigest", "adapterDigest", "allocationProofSha256")
        )
    )


def _valid_retired_transitions(path: Path, *, terminal: str) -> bool:
    if not _is_regular_file(path):
        return False
    try:
        if path.stat().st_size > _MAX_LEDGER_BYTES:
            return False
        encoded = path.read_bytes()
        if len(encoded) > _MAX_LEDGER_BYTES:
            return False
        lines = encoded.decode("utf-8").splitlines()
        if not lines or len(lines) > _MAX_LEDGER_RECORDS or any(not line for line in lines):
            return False
    except (OSError, UnicodeError):
        return False
    try:
        _, read_candidate_ledger_v2 = _central_readers()
        records = read_candidate_ledger_v2(path.parent)
    except Exception:
        return False
    if not records or len(records) > _MAX_LEDGER_RECORDS:
        return False
    transitions = [record.get("transition") for record in records]
    if not all(isinstance(transition, str) and transition for transition in transitions):
        return False
    return (
        transitions[-1] == terminal
        and "failed" in transitions[:-1]
        and not _UPLOAD_TRANSITIONS.intersection(transitions)
    )


def _contains_upload_or_receipt_evidence(candidate_root: Path) -> bool:
    pending = [candidate_root]
    inspected = 0
    while pending:
        directory = pending.pop()
        try:
            entries = list(os.scandir(directory))
        except OSError:
            return True
        for entry in entries:
            inspected += 1
            if inspected > _MAX_CANDIDATE_ENTRIES or entry.is_symlink():
                return True
            name = entry.name.casefold()
            if name == "receipt.json" or "upload" in name:
                return True
            try:
                if entry.is_dir(follow_symlinks=False):
                    pending.append(Path(entry.path))
                elif not entry.is_file(follow_symlinks=False):
                    return True
            except OSError:
                return True
    return False


def _retired_chain_highest_build(proof: Mapping[str, Any], repository_root: Path) -> int | None:
    version = proof.get("marketingVersion")
    remote_build = proof.get("remoteHighestBuildNumber")
    if (
        not isinstance(version, str)
        or _SEMVER.fullmatch(version) is None
        or isinstance(remote_build, bool)
        or not isinstance(remote_build, int)
        or remote_build < 0
        or not _fresh_remote_observation(proof)
    ):
        return None
    start_build = remote_build + 1
    common_directory = _git_common_directory(repository_root)
    if common_directory is None:
        return None
    release_state_root = common_directory / "release-state"
    if not _is_directory(release_state_root):
        return None
    state_root = release_state_root / PRODUCT
    if not _is_directory(state_root):
        return None
    active_pointer = state_root / "active-candidate.json"
    if os.path.lexists(active_pointer):
        return None
    candidates_root = state_root / "candidates"
    if not _is_directory(candidates_root):
        return None

    prefix = f"{version}-"
    local_builds: set[int] = set()
    allocation_records: dict[int, Path] = {}
    try:
        entries = list(os.scandir(candidates_root))
    except OSError:
        return None
    for entry in entries:
        if not entry.name.startswith(prefix):
            continue
        match = _CANDIDATE.fullmatch(entry.name)
        if match is not None and match.group("version") == version:
            if entry.is_symlink() or not entry.is_dir(follow_symlinks=False):
                return None
            local_builds.add(int(match.group("build")))
            continue
        if not entry.name.endswith(_ALLOCATION_SUFFIX):
            return None
        candidate_id = entry.name[: -len(_ALLOCATION_SUFFIX)]
        match = _CANDIDATE.fullmatch(candidate_id)
        if match is None or match.group("version") != version:
            return None
        if entry.is_symlink() or not entry.is_file(follow_symlinks=False):
            return None
        build = int(match.group("build"))
        if build in allocation_records:
            return None
        allocation_records[build] = Path(entry.path)
    if not local_builds:
        return None
    if not allocation_records.keys() <= local_builds:
        return None
    highest_build = max(local_builds)
    chain_length = highest_build - start_build + 1
    if chain_length < 1 or chain_length > _MAX_CHAIN_LENGTH:
        return None
    if local_builds.intersection(range(start_build, highest_build + 1)) != set(
        range(start_build, highest_build + 1)
    ):
        return None

    verified_manifests: dict[int, Mapping[str, Any]] = {}
    for build, allocation_path in allocation_records.items():
        candidate_id = f"{version}-{build}"
        candidate_root = candidates_root / candidate_id
        manifest = _verified_manifest(candidate_root, candidate_id, version, build)
        if manifest is None or not _valid_allocation_record(
            allocation_path,
            candidate_id=candidate_id,
            version=version,
            build=build,
            manifest=manifest,
        ):
            return None
        verified_manifests[build] = manifest

    for build in range(start_build, highest_build + 1):
        candidate_id = f"{version}-{build}"
        candidate_root = candidates_root / candidate_id
        if not _is_directory(candidate_root):
            return None
        manifest = verified_manifests.get(build) or _verified_manifest(
            candidate_root, candidate_id, version, build
        )
        if manifest is None:
            return None
        terminal = "cancelled" if build == highest_build else "superseded"
        if not _valid_retired_transitions(candidate_root / "transitions.jsonl", terminal=terminal):
            return None
        if _contains_upload_or_receipt_evidence(candidate_root):
            return None
    return highest_build


def retired_candidate_successor_build(
    remote_observation_proof: Mapping[str, Any], repository_root: str | Path
) -> int | None:
    """Return the build after a contiguous, cancelled local chain, or ``None``.

    The proof's remote fields and digest are read-only inputs. A result is
    available only for a fresh remote+1 observation followed by a contiguous
    local chain that ended through the central failed-candidate retirement
    path without crossing any upload or receipt boundary.
    """

    if not isinstance(remote_observation_proof, Mapping):
        return None
    remote_build = remote_observation_proof.get("remoteHighestBuildNumber")
    observed_build = remote_observation_proof.get("buildNumber")
    if (
        isinstance(remote_build, bool)
        or not isinstance(remote_build, int)
        or remote_build < 0
        or isinstance(observed_build, bool)
        or not isinstance(observed_build, int)
        or observed_build < remote_build + 1
        or remote_observation_proof.get("productKey") != PRODUCT
        or remote_observation_proof.get("result") != "passed"
        or remote_observation_proof.get("operationClass") != "identityAllocation"
        or not isinstance(remote_observation_proof.get("responseSha256"), str)
        or _HEX64.fullmatch(remote_observation_proof["responseSha256"]) is None
    ):
        return None
    try:
        highest_build = _retired_chain_highest_build(
            remote_observation_proof, Path(repository_root)
        )
    except (OSError, RuntimeError, ValueError):
        return None
    successor = highest_build + 1 if highest_build is not None else None
    if observed_build == remote_build + 1 or observed_build == successor:
        return successor
    return None
