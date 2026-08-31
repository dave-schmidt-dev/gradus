from __future__ import annotations

import io
import json
import tarfile
from pathlib import Path
from types import SimpleNamespace

import pytest

try:
    from app import release_local_gate as gate
except ImportError:
    import release_local_gate as gate


class Runner:
    def __init__(self, *, gate_status: int = 0):
        self.gate_status = gate_status
        self.calls: list[list[str]] = []
        self.call_kwargs: list[dict] = []

    def __call__(self, argv, **kwargs):
        self.calls.append(list(argv))
        self.call_kwargs.append(kwargs)
        if argv == ["bash", "app/test-gate.sh"]:
            return SimpleNamespace(returncode=self.gate_status)
        raise AssertionError(f"unexpected command: {argv}")


def valid_manifest(path: Path) -> Path:
    path.write_text(json.dumps({"candidateId": "1.8.3-24", "sourceSnapshot": {"sha256": "f" * 64}}))
    return path


def run_main(
    tmp_path: Path,
    *,
    gate_status: int = 0,
    proof_result: int = 0,
    current_digest: str = "f" * 64,
    checked_digest: str = "f" * 64,
):
    manifest = valid_manifest(tmp_path / "manifest.json")
    proof_calls: list[list[str]] = []
    stderr = io.StringIO()
    runner = Runner(gate_status=gate_status)

    result = gate.main(
        [],
        runner=runner,
        manifest_resolver=lambda _value, _root, **_kwargs: manifest,
        source_digest_resolver=lambda _root: current_digest,
        git_source_digest_resolver=lambda _root, _runner: checked_digest,
        proof_writer=lambda arguments: proof_calls.append(arguments) or proof_result,
        environ={
            "READINESS_MANIFEST": str(manifest),
            "RELEASE_CONFIGURATION": "Production",
        },
        stderr=stderr,
    )
    return result, proof_calls, runner, stderr.getvalue()


def test_main_runs_streaming_local_gate_then_emits_proof(tmp_path: Path) -> None:
    result, proof_calls, runner, output = run_main(tmp_path)

    assert result == 0
    assert proof_calls == [["--local-gate"]]
    assert runner.calls == [["bash", "app/test-gate.sh"]]
    child_environment = runner.call_kwargs[0]["env"]
    assert "READINESS_MANIFEST" not in child_environment
    assert child_environment["RELEASE_CONFIGURATION"] == "Production"
    assert output.splitlines() == [
        "STATUS local-gate:started",
        "STATUS local-gate:source-binding-succeeded",
        "STATUS local-gate:test-gate-started",
        "STATUS local-gate:test-gate-succeeded",
        "STATUS local-gate:succeeded",
    ]


@pytest.mark.parametrize(
    ("current_digest", "checked_digest", "message"),
    [
        ("e" * 64, "f" * 64, "candidate-source-mismatch"),
        ("f" * 64, "e" * 64, "checked-tree-source-mismatch"),
    ],
)
def test_main_rejects_source_mismatch_before_tests_or_proof(
    tmp_path: Path,
    current_digest: str,
    checked_digest: str,
    message: str,
) -> None:
    result, proof_calls, runner, output = run_main(
        tmp_path,
        current_digest=current_digest,
        checked_digest=checked_digest,
    )

    assert result == 4
    assert proof_calls == []
    assert runner.calls == []
    assert message in output


def test_main_rejects_test_gate_failure_without_proof(tmp_path: Path) -> None:
    result, proof_calls, runner, output = run_main(tmp_path, gate_status=1)

    assert result == 4
    assert proof_calls == []
    assert runner.calls == [["bash", "app/test-gate.sh"]]
    assert "test-gate-failed" in output


def test_main_rejects_proof_writer_failure(tmp_path: Path) -> None:
    result, proof_calls, _runner, output = run_main(tmp_path, proof_result=4)

    assert result == 4
    assert proof_calls == [["--local-gate"]]
    assert "local-gate-proof-failed" in output


def test_main_requires_readiness_manifest(tmp_path: Path) -> None:
    stderr = io.StringIO()
    result = gate.main(
        [],
        runner=Runner(),
        source_digest_resolver=lambda _root: "f" * 64,
        git_source_digest_resolver=lambda _root, _runner: "f" * 64,
        environ={"RELEASE_CONFIGURATION": "Production"},
        stderr=stderr,
        root=tmp_path,
    )

    assert result == 4
    assert "readiness-manifest-unavailable" in stderr.getvalue()


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

    with pytest.raises(gate.LocalGateError, match="git-tree-snapshot-failed"):
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

    with pytest.raises(gate.LocalGateError, match="git-tree-snapshot-failed"):
        gate.git_tree_source_digest(
            tmp_path,
            lambda *_args, **_kwargs: SimpleNamespace(returncode=0, stdout=b"12345"),
        )


@pytest.mark.parametrize(
    "payload",
    [b"not-a-tar", archive_bytes("../escape"), archive_bytes("./app/source.swift")],
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
        gate.LocalGateError,
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
        with pytest.raises(gate.LocalGateError, match="git-tree-archive-invalid"):
            gate._extract_git_archive(archive, tmp_path)


def test_release_adapter_uses_candidate_bound_local_gate() -> None:
    adapter = json.loads((gate.ROOT / ".release/release-adapter.json").read_text())
    operation = next(item for item in adapter["operations"] if item["id"] == "local-gate")
    assert operation["argv"] == ["python3", "app/release_local_gate.py"]
    assert "PYTHONPATH" in operation["environment"]["inputs"]
    assert "cloud" not in json.dumps(operation).lower()
