#!/usr/bin/env python3
"""Run the candidate-bound local release test gate."""

from __future__ import annotations

import hashlib
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
from collections.abc import Callable, Mapping
from pathlib import Path, PurePosixPath
from typing import Any, TextIO

from release_prepare_bridge import BridgeError, clear_diagnostic, diagnostic_path
from release_stage_readiness import (
    build_local_gate_proof,
    resolve_canonical_manifest,
    write_proof,
)
from release_stage_readiness import main as write_readiness_proof

ROOT = Path(__file__).resolve().parent.parent
_MAX_RESPONSE_BYTES = 2 * 1024 * 1024
_MAX_ARCHIVE_BYTES = 128 * 1024 * 1024


_HEX64 = re.compile(r"^[0-9a-f]{64}$")
_LEG_LIST = re.compile(r"^[a-z0-9]+(?:[-,][a-z0-9]+)*$")
_DETAIL_PATH = re.compile(r"^[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$")
_MAX_LOG_BYTES = 64 * 1024 * 1024
DIAGNOSTIC_OPERATION = "local-gate"


class LocalGateError(ValueError):
    """A stable, value-free local-gate rejection."""


def read_gate_result(path: Path) -> dict[str, str]:
    """Read the gate's own account of the attempt (failed legs, log, receipts).

    The file is written by ``app/test-gate.sh`` for this one run. Anything
    that does not match its small closed grammar is dropped, never trusted.
    """

    result = {"failed": "", "log": "", "receipts": ""}
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return result
    for line in text.splitlines():
        key, separator, value = line.partition("=")
        if not separator or key not in result:
            continue
        valid = {
            "failed": value == "" or _LEG_LIST.fullmatch(value) is not None,
            "log": value == ""
            or (
                len(value) <= 256
                and _DETAIL_PATH.fullmatch(value) is not None
                and ".." not in Path(value).parts
            ),
            "receipts": value == "" or _HEX64.fullmatch(value) is not None,
        }[key]
        if valid:
            result[key] = value
    return result


def _log_digest(root: Path, relative: str) -> str | None:
    """SHA-256 of the retained attempt log, or None if it is not a plain file."""

    path = root / relative
    try:
        if path.is_symlink() or not path.is_file() or path.stat().st_size > _MAX_LOG_BYTES:
            return None
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError:
        return None


def record_failure_diagnostic(root: Path, candidate_id: str, result: Mapping[str, str]) -> None:
    """Persist the bounded ``release.diagnostic.v1`` for a failed gate attempt.

    It names every failed leg (the gate runs them all) and the attempt log, so
    one failed prepare tells the operator everything to fix in a single pass.
    """

    failed = result.get("failed", "")
    names = [name for name in failed.split(",") if name]
    summary = (
        "Failed gate legs: " + ", ".join(names)
        if names
        else "The local test gate failed before it could list its legs."
    )[:200]
    diagnostic: dict[str, Any] = {
        "schemaVersion": "1.0.0",
        "proofSchema": "release.diagnostic.v1",
        "operationId": DIAGNOSTIC_OPERATION,
        "failureKind": "local-gate-legs-failed" if names else "local-gate-failed",
        "summary": summary,
    }
    log = result.get("log", "")
    digest = _log_digest(root, log) if log else None
    if log and digest is not None:
        diagnostic["detailPath"] = log
        diagnostic["detailSha256"] = digest
    write_proof(diagnostic_path(root, candidate_id, DIAGNOSTIC_OPERATION), diagnostic)


def _json_object(text: str, *, label: str) -> dict[str, Any]:
    if len(text.encode("utf-8")) > _MAX_RESPONSE_BYTES:
        raise LocalGateError(f"{label}-too-large")

    def no_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                raise LocalGateError(f"{label}-duplicate-key")
            value[key] = item
        return value

    try:
        value = json.loads(text, object_pairs_hook=no_duplicates)
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise LocalGateError(f"{label}-invalid") from exc
    if not isinstance(value, dict):
        raise LocalGateError(f"{label}-invalid")
    return value


def _release_snapshot_dependencies(root: Path) -> tuple[Any, Callable[..., Any]]:
    try:
        from release_tools.adapter import load_adapter
        from release_tools.source_snapshot import create_source_digest
    except ImportError as exc:
        raise LocalGateError("release-tools-unavailable") from exc
    try:
        document = _json_object(
            (root / ".release/release-adapter.json").read_text(encoding="utf-8"),
            label="adapter",
        )
        adapter = load_adapter(document, repository_root=root)
    except (OSError, ValueError, TypeError) as exc:
        raise LocalGateError("source-snapshot-failed") from exc
    return adapter, create_source_digest


def _valid_source_digest(value: Any) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"^[0-9a-f]{64}$", value):
        raise LocalGateError("source-snapshot-invalid")
    return value


def current_source_digest(root: Path) -> str:
    """Recompute the central release snapshot for the live checkout."""

    adapter, create_source_digest = _release_snapshot_dependencies(root)
    try:
        observation = create_source_digest(
            root,
            declared_paths=adapter.source_paths or None,
            excluded_paths=adapter.non_source_paths,
        )
    except (OSError, ValueError, TypeError) as exc:
        raise LocalGateError("source-snapshot-failed") from exc
    return _valid_source_digest(observation.source_digest)


def _extract_git_archive(archive: tarfile.TarFile, destination: Path) -> None:
    """Extract a validated Git tar without relying on newer tarfile filters."""

    members: list[tuple[tarfile.TarInfo, PurePosixPath]] = []
    names: set[str] = set()
    symlinks: set[str] = set()
    for member in archive.getmembers():
        relative = PurePosixPath(member.name)
        normalized = relative.as_posix()
        if (
            relative.is_absolute()
            or ".." in relative.parts
            or not normalized
            or normalized == "."
            or normalized != member.name.rstrip("/")
            or normalized in names
            or not (member.isdir() or member.isfile() or member.issym())
        ):
            raise LocalGateError("git-tree-archive-invalid")
        names.add(normalized)
        if member.issym():
            link = PurePosixPath(member.linkname)
            if (
                not member.linkname
                or link.is_absolute()
                or ".." in link.parts
                or "\x00" in member.linkname
            ):
                raise LocalGateError("git-tree-archive-invalid")
            symlinks.add(normalized)
        members.append((member, relative))

    for _, relative in members:
        if any(parent.as_posix() in symlinks for parent in relative.parents):
            raise LocalGateError("git-tree-archive-invalid")

    for member, relative in members:
        target = destination.joinpath(*relative.parts)
        if member.isdir():
            target.mkdir(parents=True, exist_ok=True)
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        if member.issym():
            target.symlink_to(member.linkname)
            continue
        source = archive.extractfile(member)
        if source is None:
            raise LocalGateError("git-tree-archive-invalid")
        with source, target.open("xb") as output:
            shutil.copyfileobj(source, output)
        target.chmod(0o755 if member.mode & stat.S_IXUSR else 0o644)


def git_tree_source_digest(root: Path, runner: Callable[..., Any]) -> str:
    """Recompute the central snapshot from only the checked Git HEAD tree."""

    adapter, create_source_digest = _release_snapshot_dependencies(root)
    argv = [
        "git",
        "-C",
        str(root),
        "archive",
        "--format=tar",
        "HEAD",
        "--",
        *(adapter.source_paths or ()),
    ]
    try:
        completed = runner(argv, capture_output=True, check=False, timeout=60)
    except (OSError, subprocess.SubprocessError) as exc:
        raise LocalGateError("git-tree-snapshot-unavailable") from exc
    archive = completed.stdout
    if (
        completed.returncode != 0
        or not isinstance(archive, bytes)
        or not archive
        or len(archive) > _MAX_ARCHIVE_BYTES
    ):
        raise LocalGateError("git-tree-snapshot-failed")

    try:
        with tempfile.TemporaryDirectory(prefix="gradus-release-tree.") as temporary:
            destination = Path(temporary)
            with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as tar:
                _extract_git_archive(tar, destination)
            observation = create_source_digest(
                destination,
                declared_paths=adapter.source_paths or None,
                excluded_paths=adapter.non_source_paths,
            )
    except (OSError, tarfile.TarError, ValueError, TypeError) as exc:
        if isinstance(exc, LocalGateError):
            raise
        raise LocalGateError("git-tree-snapshot-failed") from exc
    return _valid_source_digest(observation.source_digest)


def main(
    argv: list[str] | None = None,
    *,
    runner: Callable[..., Any] = subprocess.run,
    manifest_resolver: Callable[..., Path] = resolve_canonical_manifest,
    source_digest_resolver: Callable[[Path], str] = current_source_digest,
    git_source_digest_resolver: Callable[[Path, Callable[..., Any]], str] = (
        git_tree_source_digest
    ),
    proof_writer: Callable[[list[str]], int] = write_readiness_proof,
    root: Path = ROOT,
    environ: Mapping[str, str] = os.environ,
    stderr: TextIO = sys.stderr,
) -> int:
    """Validate candidate source, stream the local test gate, and emit proof."""

    arguments = sys.argv[1:] if argv is None else argv
    if arguments:
        return 64
    stderr.write("STATUS local-gate:started\n")
    stderr.flush()
    try:
        manifest_value = environ.get("READINESS_MANIFEST", "")
        if not manifest_value or "\x00" in manifest_value:
            raise LocalGateError("readiness-manifest-unavailable")
        manifest = manifest_resolver(manifest_value, root, runner=runner)
        candidate_proof = build_local_gate_proof(
            manifest,
            configuration=environ.get("RELEASE_CONFIGURATION", ""),
        )
        if source_digest_resolver(root) != candidate_proof["sourceDigest"]:
            raise LocalGateError("candidate-source-mismatch")
        if git_source_digest_resolver(root, runner) != candidate_proof["sourceDigest"]:
            raise LocalGateError("checked-tree-source-mismatch")
        stderr.write("STATUS local-gate:source-binding-succeeded\n")
        stderr.write("STATUS local-gate:test-gate-started\n")
        stderr.flush()
        candidate_id = str(candidate_proof["candidateId"])
        test_gate_environment = dict(environ)
        test_gate_environment.pop("READINESS_MANIFEST", None)
        with tempfile.TemporaryDirectory(prefix="gradus-local-gate.") as scratch:
            result_path = Path(scratch) / "gate-result"
            test_gate_environment["GRADUS_GATE_RESULT_FILE"] = str(result_path)
            try:
                completed = runner(
                    ["bash", "app/test-gate.sh", "--release", candidate_id],
                    cwd=root,
                    check=False,
                    env=test_gate_environment,
                )
            except (OSError, subprocess.SubprocessError) as exc:
                raise LocalGateError("test-gate-unavailable") from exc
            gate_result = read_gate_result(result_path)
        if completed.returncode != 0:
            try:
                record_failure_diagnostic(root, candidate_id, gate_result)
            except (BridgeError, OSError, ValueError):
                pass
            raise LocalGateError("test-gate-failed")
        if not gate_result["receipts"]:
            raise LocalGateError("leg-receipts-unavailable")
        try:
            clear_diagnostic(root, candidate_id, DIAGNOSTIC_OPERATION)
        except (BridgeError, OSError):
            pass
        stderr.write("STATUS local-gate:test-gate-succeeded\n")
        stderr.flush()
        if proof_writer(["--local-gate", f"--leg-receipts-sha256={gate_result['receipts']}"]) != 0:
            raise LocalGateError("local-gate-proof-failed")
    except (LocalGateError, OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
        code = str(exc) if isinstance(exc, LocalGateError) else "local-gate-invalid"
        stderr.write(f"release-local-gate: {code}\nSTATUS local-gate:failed\n")
        stderr.flush()
        return 4
    stderr.write("STATUS local-gate:succeeded\n")
    stderr.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
