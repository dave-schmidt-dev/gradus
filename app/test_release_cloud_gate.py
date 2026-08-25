from __future__ import annotations

import io
import json
import tarfile
from pathlib import Path
from types import SimpleNamespace

import pytest

try:
    from app import release_cloud_gate as gate
except ImportError:
    import release_cloud_gate as gate


HEAD = "a" * 40
FIRST_PARENT = "b" * 40
TESTED_PARENT = "c" * 40
TREE = "d" * 40


def commit(revision: str, tree: str = TREE, parents: list[str] | None = None) -> dict:
    return {
        "sha": revision,
        "commit": {"tree": {"sha": tree}},
        "parents": [{"sha": parent} for parent in (parents or [])],
    }


def check(name: str, revision: str, *, status: str = "completed", conclusion="success") -> dict:
    return {
        "name": name,
        "head_sha": revision,
        "status": status,
        "conclusion": conclusion,
        "app": {"id": gate.XCODE_CLOUD_APP_ID, "slug": gate.XCODE_CLOUD_APP_SLUG},
    }


def checks(revision: str, names=gate.REQUIRED_CHECKS) -> dict:
    runs = [check(name, revision) for name in names]
    return {"total_count": len(runs), "check_runs": runs}


class Runner:
    def __init__(self, responses: dict[str, object], *, head: str = HEAD, dirty: str = ""):
        self.responses = responses
        self.head = head
        self.dirty = dirty
        self.calls: list[list[str]] = []

    def __call__(self, argv, **_kwargs):
        self.calls.append(list(argv))
        if argv[:3] == ["git", "-C", str(gate.ROOT)]:
            command = argv[3:]
            if command == ["status", "--porcelain=v1", "--untracked-files=all"]:
                return SimpleNamespace(returncode=0, stdout=self.dirty)
            if command == ["rev-parse", "HEAD"]:
                return SimpleNamespace(returncode=0, stdout=self.head + "\n")
        endpoint = argv[-1]
        response = self.responses.get(endpoint)
        if isinstance(response, int):
            return SimpleNamespace(returncode=response, stdout="", stderr="redacted")
        if response is None:
            raise AssertionError(f"unexpected command: {argv}")
        return SimpleNamespace(returncode=0, stdout=json.dumps(response))


def endpoint(revision: str, suffix: str = "") -> str:
    return f"repos/{gate.REPOSITORY}/commits/{revision}{suffix}"


def checks_endpoint(revision: str) -> str:
    return endpoint(revision, "/check-runs?filter=latest&per_page=100")


def test_exact_head_checks_are_accepted() -> None:
    runner = Runner(
        {
            endpoint(HEAD): commit(HEAD),
            checks_endpoint(HEAD): checks(HEAD),
        }
    )
    assert gate.select_evidence_revision(runner, HEAD) == HEAD


def test_identical_tree_merge_second_parent_is_accepted() -> None:
    runner = Runner(
        {
            endpoint(HEAD): commit(HEAD, parents=[FIRST_PARENT, TESTED_PARENT]),
            checks_endpoint(HEAD): checks(HEAD, [gate.REQUIRED_CHECKS[1]]),
            endpoint(TESTED_PARENT): commit(TESTED_PARENT),
            checks_endpoint(TESTED_PARENT): checks(TESTED_PARENT),
        }
    )
    assert gate.select_evidence_revision(runner, HEAD) == TESTED_PARENT


@pytest.mark.parametrize(
    ("head_commit", "parent_commit", "message"),
    [
        (commit(HEAD, parents=[TESTED_PARENT]), None, "required-cloud-checks-missing"),
        (
            commit(HEAD, parents=[FIRST_PARENT, TESTED_PARENT]),
            commit(TESTED_PARENT, tree="e" * 40),
            "tested-source-tree-mismatch",
        ),
    ],
)
def test_ineligible_parent_fallback_fails(head_commit, parent_commit, message) -> None:
    responses = {
        endpoint(HEAD): head_commit,
        checks_endpoint(HEAD): checks(HEAD, []),
    }
    if parent_commit is not None:
        responses[endpoint(TESTED_PARENT)] = parent_commit
    with pytest.raises(gate.CloudGateError, match=message):
        gate.select_evidence_revision(Runner(responses), HEAD)


@pytest.mark.parametrize(
    ("mutate", "message"),
    [
        (lambda runs: runs.append(dict(runs[0])), "github-check-duplicate"),
        (lambda runs: runs[0].update(status="in_progress", conclusion=None), "unsuccessful"),
        (lambda runs: runs[0].update(conclusion="failure"), "unsuccessful"),
        (lambda runs: runs[0].update(head_sha=FIRST_PARENT), "identity-invalid"),
        (lambda runs: runs[0]["app"].update(id=1), "identity-invalid"),
    ],
)
def test_invalid_required_check_evidence_fails(mutate, message) -> None:
    payload = checks(HEAD)
    mutate(payload["check_runs"])
    payload["total_count"] = len(payload["check_runs"])
    runner = Runner(
        {
            endpoint(HEAD): commit(HEAD),
            checks_endpoint(HEAD): payload,
        }
    )
    with pytest.raises(gate.CloudGateError, match=message):
        gate.select_evidence_revision(runner, HEAD)


@pytest.mark.parametrize(
    "payload",
    [
        {"total_count": 2, "check_runs": []},
        {"total_count": "2", "check_runs": []},
        {"total_count": 1, "check_runs": [None]},
    ],
)
def test_malformed_check_response_fails(payload) -> None:
    runner = Runner(
        {
            endpoint(HEAD): commit(HEAD),
            checks_endpoint(HEAD): payload,
        }
    )
    with pytest.raises(gate.CloudGateError, match="github-checks-invalid"):
        gate.select_evidence_revision(runner, HEAD)


def valid_manifest(path: Path) -> Path:
    path.write_text(json.dumps({"candidateId": "1.8.3-24", "sourceSnapshot": {"sha256": "f" * 64}}))
    return path


def run_main(tmp_path: Path, runner: Runner, *, proof_result: int = 0):
    manifest = valid_manifest(tmp_path / "manifest.json")
    proof_calls: list[list[str]] = []
    stderr = io.StringIO()

    def resolver(_value, _root, **_kwargs):
        return manifest

    def proof_writer(arguments):
        proof_calls.append(arguments)
        return proof_result

    result = gate.main(
        [],
        runner=runner,
        manifest_resolver=resolver,
        source_digest_resolver=lambda _root: "f" * 64,
        git_source_digest_resolver=lambda _root, _runner: "f" * 64,
        proof_writer=proof_writer,
        environ={"READINESS_MANIFEST": str(manifest), "RELEASE_CONFIGURATION": "Production"},
        stderr=stderr,
    )
    return result, proof_calls, stderr.getvalue()


def test_main_emits_proof_only_after_cloud_success(tmp_path: Path) -> None:
    runner = Runner(
        {
            endpoint(HEAD): commit(HEAD),
            checks_endpoint(HEAD): checks(HEAD),
        }
    )
    result, proof_calls, output = run_main(tmp_path, runner)
    assert result == 0
    assert proof_calls == [["--local-gate"]]
    assert output.splitlines() == [
        "STATUS cloud-gate:started",
        "STATUS cloud-gate:source-binding",
        "STATUS cloud-gate:checks-succeeded",
        "STATUS cloud-gate:succeeded",
    ]
    gh_calls = [call for call in runner.calls if call[:2] == ["gh", "api"]]
    assert gh_calls
    assert all(call[-1].startswith(f"repos/{gate.REPOSITORY}/") for call in gh_calls)


@pytest.mark.parametrize("dirty", [" M app/file.swift\n", "?? app/new-source.swift\n"])
def test_main_allows_dirty_unscoped_files_when_source_digests_match(
    tmp_path: Path, dirty: str
) -> None:
    runner = Runner(
        {
            endpoint(HEAD): commit(HEAD),
            checks_endpoint(HEAD): checks(HEAD),
        },
        dirty=dirty,
    )
    result, proof_calls, output = run_main(tmp_path, runner)
    assert result == 0
    assert proof_calls == [["--local-gate"]]
    assert "tracked-source-dirty" not in output


def test_main_rejects_candidate_source_mismatch_before_github_or_proof(tmp_path: Path) -> None:
    manifest = valid_manifest(tmp_path / "manifest.json")
    proof_calls: list[list[str]] = []
    stderr = io.StringIO()

    result = gate.main(
        [],
        runner=Runner({}),
        manifest_resolver=lambda _value, _root, **_kwargs: manifest,
        source_digest_resolver=lambda _root: "e" * 64,
        git_source_digest_resolver=lambda _root, _runner: "f" * 64,
        proof_writer=lambda arguments: proof_calls.append(arguments) or 0,
        environ={"READINESS_MANIFEST": str(manifest), "RELEASE_CONFIGURATION": "Production"},
        stderr=stderr,
    )

    assert result == 4
    assert proof_calls == []
    assert "candidate-source-mismatch" in stderr.getvalue()


def test_main_rejects_ignored_in_scope_source_absent_from_checked_tree(
    tmp_path: Path,
) -> None:
    manifest = valid_manifest(tmp_path / "manifest.json")
    proof_calls: list[list[str]] = []
    stderr = io.StringIO()

    result = gate.main(
        [],
        runner=Runner({}),
        manifest_resolver=lambda _value, _root, **_kwargs: manifest,
        source_digest_resolver=lambda _root: "f" * 64,
        git_source_digest_resolver=lambda _root, _runner: "e" * 64,
        proof_writer=lambda arguments: proof_calls.append(arguments) or 0,
        environ={"READINESS_MANIFEST": str(manifest), "RELEASE_CONFIGURATION": "Production"},
        stderr=stderr,
    )

    assert result == 4
    assert proof_calls == []
    assert "checked-tree-source-mismatch" in stderr.getvalue()


def archive_bytes(name: str = "app/source.swift", content: bytes = b"source") -> bytes:
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:") as archive:
        member = tarfile.TarInfo(name)
        member.size = len(content)
        archive.addfile(member, io.BytesIO(content))
    return output.getvalue()


def test_git_tree_source_digest_uses_checked_head_archive(tmp_path: Path, monkeypatch) -> None:
    digest = "f" * 64
    adapter = SimpleNamespace(source_paths=("app",), non_source_paths=())
    observed: list[tuple[Path, tuple[str, ...], tuple[str, ...]]] = []

    def create_source_digest(root, *, declared_paths, excluded_paths):
        assert (root / "app/source.swift").read_bytes() == b"source"
        observed.append((root, tuple(declared_paths), tuple(excluded_paths)))
        return SimpleNamespace(source_digest=digest)

    monkeypatch.setattr(
        gate,
        "_release_snapshot_dependencies",
        lambda _root: (adapter, create_source_digest),
    )
    calls: list[list[str]] = []

    def runner(argv, **_kwargs):
        calls.append(list(argv))
        return SimpleNamespace(returncode=0, stdout=archive_bytes())

    assert gate.git_tree_source_digest(tmp_path, runner) == digest
    assert calls == [["git", "-C", str(tmp_path), "archive", "--format=tar", "HEAD", "--", "app"]]
    assert len(observed) == 1
    assert observed[0][1:] == (("app",), ())


@pytest.mark.parametrize(
    ("returncode", "stdout"),
    [(1, b"failure"), (0, b""), (0, "not-bytes")],
)
def test_git_tree_source_digest_rejects_failed_archive(
    tmp_path: Path, monkeypatch, returncode: int, stdout
) -> None:
    adapter = SimpleNamespace(source_paths=("app",), non_source_paths=())
    monkeypatch.setattr(
        gate,
        "_release_snapshot_dependencies",
        lambda _root: (adapter, lambda *_args, **_kwargs: None),
    )

    with pytest.raises(gate.CloudGateError, match="git-tree-snapshot-failed"):
        gate.git_tree_source_digest(
            tmp_path,
            lambda *_args, **_kwargs: SimpleNamespace(returncode=returncode, stdout=stdout),
        )


def test_git_tree_source_digest_rejects_oversized_archive(tmp_path: Path, monkeypatch) -> None:
    adapter = SimpleNamespace(source_paths=("app",), non_source_paths=())
    monkeypatch.setattr(gate, "_MAX_ARCHIVE_BYTES", 4)
    monkeypatch.setattr(
        gate,
        "_release_snapshot_dependencies",
        lambda _root: (adapter, lambda *_args, **_kwargs: None),
    )

    with pytest.raises(gate.CloudGateError, match="git-tree-snapshot-failed"):
        gate.git_tree_source_digest(
            tmp_path,
            lambda *_args, **_kwargs: SimpleNamespace(returncode=0, stdout=b"12345"),
        )


@pytest.mark.parametrize(
    "payload",
    [
        b"not-a-tar",
        archive_bytes("../escape"),
        archive_bytes("./app/source.swift"),
    ],
)
def test_git_tree_source_digest_rejects_unsafe_archive(
    tmp_path: Path, monkeypatch, payload: bytes
) -> None:
    adapter = SimpleNamespace(source_paths=("app",), non_source_paths=())
    monkeypatch.setattr(
        gate,
        "_release_snapshot_dependencies",
        lambda _root: (adapter, lambda *_args, **_kwargs: None),
    )

    with pytest.raises(
        gate.CloudGateError,
        match="git-tree-(snapshot-failed|archive-invalid)",
    ):
        gate.git_tree_source_digest(
            tmp_path,
            lambda *_args, **_kwargs: SimpleNamespace(returncode=0, stdout=payload),
        )


def test_extract_git_archive_rejects_escaping_symlink(tmp_path: Path) -> None:
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:") as archive:
        member = tarfile.TarInfo("app/escape")
        member.type = tarfile.SYMTYPE
        member.linkname = "../../outside"
        archive.addfile(member)
    output.seek(0)

    with tarfile.open(fileobj=output, mode="r:") as archive:
        with pytest.raises(gate.CloudGateError, match="git-tree-archive-invalid"):
            gate._extract_git_archive(archive, tmp_path)


def test_main_rejects_github_failure_without_proof(tmp_path: Path) -> None:
    runner = Runner({endpoint(HEAD): 1})
    result, proof_calls, output = run_main(tmp_path, runner)
    assert result == 4
    assert proof_calls == []
    assert "github-query-failed" in output
    assert "redacted" not in output


def test_main_rejects_proof_writer_failure(tmp_path: Path) -> None:
    runner = Runner(
        {
            endpoint(HEAD): commit(HEAD),
            checks_endpoint(HEAD): checks(HEAD),
        }
    )
    result, proof_calls, output = run_main(tmp_path, runner, proof_result=4)
    assert result == 4
    assert proof_calls == [["--local-gate"]]
    assert "local-gate-proof-failed" in output


def test_release_adapter_uses_cloud_gate_not_local_xcode_gate() -> None:
    adapter = json.loads((gate.ROOT / ".release/release-adapter.json").read_text())
    operation = next(item for item in adapter["operations"] if item["id"] == "local-gate")
    assert operation["argv"] == ["python3", "app/release_cloud_gate.py"]
    assert "app/test-gate.sh" not in json.dumps(operation)
    assert "PYTHONPATH" in operation["environment"]["inputs"]
