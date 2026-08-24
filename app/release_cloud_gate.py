#!/usr/bin/env python3
"""Verify source-bound Xcode Cloud checks for TestFlight staging."""

from __future__ import annotations

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

from release_stage_readiness import (
    build_local_gate_proof,
    resolve_canonical_manifest,
)
from release_stage_readiness import (
    main as write_readiness_proof,
)

REPOSITORY = "dave-schmidt-dev/gradus"
XCODE_CLOUD_APP_ID = 117084
XCODE_CLOUD_APP_SLUG = "xcode-cloud"
REQUIRED_CHECKS = (
    "GradusMac | Gradus macOS UI Trial | Test - macOS",
    "GradusMac | Gradus iOS Snapshot Trial | Test - iOS",
)
ROOT = Path(__file__).resolve().parent.parent
_SHA = re.compile(r"^[0-9a-f]{40}$")
_MAX_RESPONSE_BYTES = 2 * 1024 * 1024
_MAX_ARCHIVE_BYTES = 128 * 1024 * 1024


class CloudGateError(ValueError):
    """A stable, value-free cloud-gate rejection."""


def _json_object(text: str, *, label: str) -> dict[str, Any]:
    if len(text.encode("utf-8")) > _MAX_RESPONSE_BYTES:
        raise CloudGateError(f"{label}-too-large")

    def no_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                raise CloudGateError(f"{label}-duplicate-key")
            value[key] = item
        return value

    try:
        value = json.loads(text, object_pairs_hook=no_duplicates)
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise CloudGateError(f"{label}-invalid") from exc
    if not isinstance(value, dict):
        raise CloudGateError(f"{label}-invalid")
    return value


def _run_text(
    runner: Callable[..., Any], argv: list[str], *, label: str, allow_empty: bool = False
) -> str:
    try:
        completed = runner(
            argv,
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise CloudGateError(f"{label}-unavailable") from exc
    if completed.returncode != 0 or not isinstance(completed.stdout, str):
        raise CloudGateError(f"{label}-failed")
    value = completed.stdout.strip()
    if (not value and not allow_empty) or "\x00" in value:
        raise CloudGateError(f"{label}-invalid")
    return value


def _git(runner: Callable[..., Any], root: Path, *arguments: str, allow_empty: bool = False) -> str:
    return _run_text(
        runner,
        ["git", "-C", str(root), *arguments],
        label="git",
        allow_empty=allow_empty,
    )


def _github_json(runner: Callable[..., Any], endpoint: str, *, label: str) -> dict[str, Any]:
    if not endpoint.startswith(f"repos/{REPOSITORY}/") or any(
        character in endpoint for character in ("\n", "\r", "\x00")
    ):
        raise CloudGateError("github-endpoint-invalid")
    text = _run_text(
        runner,
        [
            "gh",
            "api",
            "--method",
            "GET",
            "-H",
            "Accept: application/vnd.github+json",
            "-H",
            "X-GitHub-Api-Version: 2022-11-28",
            endpoint,
        ],
        label="github-query",
    )
    return _json_object(text, label=label)


def _commit_metadata(runner: Callable[..., Any], revision: str) -> tuple[str, list[str]]:
    if not _SHA.fullmatch(revision):
        raise CloudGateError("source-revision-invalid")
    value = _github_json(
        runner,
        f"repos/{REPOSITORY}/commits/{revision}",
        label="github-commit",
    )
    commit = value.get("commit")
    tree = commit.get("tree") if isinstance(commit, Mapping) else None
    tree_sha = tree.get("sha") if isinstance(tree, Mapping) else None
    parents = value.get("parents")
    if (
        value.get("sha") != revision
        or not isinstance(tree_sha, str)
        or not _SHA.fullmatch(tree_sha)
    ):
        raise CloudGateError("github-commit-invalid")
    if not isinstance(parents, list):
        raise CloudGateError("github-commit-invalid")
    parent_shas: list[str] = []
    for parent in parents:
        parent_sha = parent.get("sha") if isinstance(parent, Mapping) else None
        if not isinstance(parent_sha, str) or not _SHA.fullmatch(parent_sha):
            raise CloudGateError("github-commit-invalid")
        parent_shas.append(parent_sha)
    return tree_sha, parent_shas


def _check_state(runner: Callable[..., Any], revision: str) -> tuple[set[str], set[str]]:
    if not _SHA.fullmatch(revision):
        raise CloudGateError("source-revision-invalid")
    value = _github_json(
        runner,
        f"repos/{REPOSITORY}/commits/{revision}/check-runs?filter=latest&per_page=100",
        label="github-checks",
    )
    runs = value.get("check_runs")
    total = value.get("total_count")
    if (
        not isinstance(runs, list)
        or isinstance(total, bool)
        or not isinstance(total, int)
        or total != len(runs)
    ):
        raise CloudGateError("github-checks-invalid")

    found: set[str] = set()
    successful: set[str] = set()
    for run in runs:
        if not isinstance(run, Mapping):
            raise CloudGateError("github-checks-invalid")
        name = run.get("name")
        if name not in REQUIRED_CHECKS:
            continue
        if name in found:
            raise CloudGateError("github-check-duplicate")
        found.add(str(name))
        app = run.get("app")
        if (
            run.get("head_sha") != revision
            or not isinstance(app, Mapping)
            or app.get("id") != XCODE_CLOUD_APP_ID
            or app.get("slug") != XCODE_CLOUD_APP_SLUG
        ):
            raise CloudGateError("github-check-identity-invalid")
        if run.get("status") != "completed" or run.get("conclusion") != "success":
            raise CloudGateError("github-check-unsuccessful")
        successful.add(str(name))
    return found, successful


def select_evidence_revision(runner: Callable[..., Any], head: str) -> str:
    """Return the exact checked commit or an identical-tree merge second parent."""

    head_tree, parents = _commit_metadata(runner, head)
    found, successful = _check_state(runner, head)
    required = set(REQUIRED_CHECKS)
    if successful == required:
        return head
    if successful != found or len(parents) != 2:
        raise CloudGateError("required-cloud-checks-missing")

    tested_parent = parents[1]
    parent_tree, _ = _commit_metadata(runner, tested_parent)
    if parent_tree != head_tree:
        raise CloudGateError("tested-source-tree-mismatch")
    _, parent_successful = _check_state(runner, tested_parent)
    if parent_successful != required:
        raise CloudGateError("required-cloud-checks-missing")
    return tested_parent


def _release_snapshot_dependencies(root: Path) -> tuple[Any, Callable[..., Any]]:
    try:
        from release_tools.adapter import load_adapter
        from release_tools.source_snapshot import create_source_digest
    except ImportError as exc:
        raise CloudGateError("release-tools-unavailable") from exc
    adapter_path = root / ".release/release-adapter.json"
    try:
        document = _json_object(adapter_path.read_text(encoding="utf-8"), label="adapter")
        adapter = load_adapter(document, repository_root=root)
    except (OSError, ValueError, TypeError) as exc:
        raise CloudGateError("source-snapshot-failed") from exc
    return adapter, create_source_digest


def _valid_source_digest(value: Any) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"^[0-9a-f]{64}$", value):
        raise CloudGateError("source-snapshot-invalid")
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
        raise CloudGateError("source-snapshot-failed") from exc
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
            raise CloudGateError("git-tree-archive-invalid")
        names.add(normalized)
        if member.issym():
            link = PurePosixPath(member.linkname)
            if (
                not member.linkname
                or link.is_absolute()
                or ".." in link.parts
                or "\x00" in member.linkname
            ):
                raise CloudGateError("git-tree-archive-invalid")
            symlinks.add(normalized)
        members.append((member, relative))

    for _, relative in members:
        if any(parent.as_posix() in symlinks for parent in relative.parents):
            raise CloudGateError("git-tree-archive-invalid")

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
            raise CloudGateError("git-tree-archive-invalid")
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
        raise CloudGateError("git-tree-snapshot-unavailable") from exc
    archive = completed.stdout
    if (
        completed.returncode != 0
        or not isinstance(archive, bytes)
        or not archive
        or len(archive) > _MAX_ARCHIVE_BYTES
    ):
        raise CloudGateError("git-tree-snapshot-failed")

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
        if isinstance(exc, CloudGateError):
            raise
        raise CloudGateError("git-tree-snapshot-failed") from exc
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
    """Validate cloud checks and emit the existing runner-compatible proof."""

    arguments = sys.argv[1:] if argv is None else argv
    if arguments:
        return 64
    stderr.write("STATUS cloud-gate:started\n")
    stderr.flush()
    try:
        manifest_value = environ.get("READINESS_MANIFEST", "")
        if not manifest_value or "\x00" in manifest_value:
            raise CloudGateError("readiness-manifest-unavailable")
        manifest = manifest_resolver(manifest_value, root, runner=runner)
        candidate_proof = build_local_gate_proof(
            manifest,
            configuration=environ.get("RELEASE_CONFIGURATION", ""),
        )
        if source_digest_resolver(root) != candidate_proof["sourceDigest"]:
            raise CloudGateError("candidate-source-mismatch")
        stderr.write("STATUS cloud-gate:source-binding\n")
        stderr.flush()
        if git_source_digest_resolver(root, runner) != candidate_proof["sourceDigest"]:
            raise CloudGateError("checked-tree-source-mismatch")
        if _git(
            runner,
            root,
            "status",
            "--porcelain=v1",
            "--untracked-files=all",
            allow_empty=True,
        ):
            raise CloudGateError("tracked-source-dirty")
        head = _git(runner, root, "rev-parse", "HEAD")
        if not _SHA.fullmatch(head):
            raise CloudGateError("source-revision-invalid")
        select_evidence_revision(runner, head)
        stderr.write("STATUS cloud-gate:checks-succeeded\n")
        stderr.flush()
        if proof_writer(["--local-gate"]) != 0:
            raise CloudGateError("local-gate-proof-failed")
    except (CloudGateError, OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
        code = str(exc) if isinstance(exc, CloudGateError) else "cloud-gate-invalid"
        stderr.write(f"release-cloud-gate: {code}\nSTATUS cloud-gate:failed\n")
        stderr.flush()
        return 4
    stderr.write("STATUS cloud-gate:succeeded\n")
    stderr.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
