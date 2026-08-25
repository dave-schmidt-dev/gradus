from __future__ import annotations

import hashlib
import json
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

try:
    from app.release_stage_readiness import (
        CONTRACT_REVISION,
        LOCAL_GATE_PROOF_SCHEMA,
        PROOF_VERSION,
        READINESS_PROOF_SCHEMA,
        build_local_gate_proof,
        build_proof,
        execution_closure,
        resolve_canonical_manifest,
        write_proof,
    )
except ModuleNotFoundError:  # Direct pytest execution from app/.
    from release_stage_readiness import (
        CONTRACT_REVISION,
        LOCAL_GATE_PROOF_SCHEMA,
        PROOF_VERSION,
        READINESS_PROOF_SCHEMA,
        build_local_gate_proof,
        build_proof,
        execution_closure,
        resolve_canonical_manifest,
        write_proof,
    )


def test_build_proof_binds_candidate_source_and_manifest_bytes() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        manifest = Path(temporary) / "manifest.json"
        raw = json.dumps(
            {
                "candidateId": "1.8.0-20",
                "sourceSnapshot": {"sha256": "a" * 64},
            },
            sort_keys=True,
        ).encode()
        manifest.write_bytes(raw)

        proof = build_proof(manifest, now=datetime(2026, 8, 18, 3, 0, tzinfo=timezone.utc))

        assert proof == {
            "formatVersion": 2,
            "proofVersion": PROOF_VERSION,
            "proofSchema": READINESS_PROOF_SCHEMA,
            "operationClass": "readiness",
            "requirement": "readiness",
            "candidateId": "1.8.0-20",
            "sourceDigest": "a" * 64,
            "result": "passed",
            "observedAt": "2026-08-18T03:00:00Z",
            "environmentClosureSha256": execution_closure(READINESS_PROOF_SCHEMA, ""),
            "evidenceSha256": hashlib.sha256(raw).hexdigest(),
        }
        assert len(proof["environmentClosureSha256"]) == 64
        assert "expiresAt" not in proof
        assert "issuedAt" not in proof


def test_build_proof_rejects_missing_source_binding() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        manifest = Path(temporary) / "manifest.json"
        manifest.write_text('{"candidateId":"1.8.0-20"}', encoding="utf-8")

        try:
            build_proof(manifest)
        except ValueError as exc:
            assert str(exc) == "readiness-source-invalid"
        else:
            raise AssertionError("missing source binding was accepted")


def test_write_proof_atomically_creates_runner_evidence() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        destination = Path(temporary) / "evidence" / "1.8.0-20" / "readiness.json"
        proof = {"result": "passed", "candidateId": "1.8.0-20"}

        write_proof(destination, proof)

        assert json.loads(destination.read_text(encoding="utf-8")) == proof
        assert destination.stat().st_mode & 0o777 == 0o600
        assert not destination.with_name(".readiness.json.tmp").exists()


def test_build_local_gate_proof_is_typed_and_candidate_source_bound() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        manifest = Path(temporary) / "manifest.json"
        raw = json.dumps(
            {
                "candidateId": "1.8.1-21",
                "sourceSnapshot": {"sha256": "b" * 64},
            },
            sort_keys=True,
        ).encode()
        manifest.write_bytes(raw)

        proof = build_local_gate_proof(
            manifest,
            configuration="Production",
            now=datetime(2026, 8, 19, 12, 0, tzinfo=timezone.utc),
        )

        assert proof == {
            "proofVersion": PROOF_VERSION,
            "proofSchema": LOCAL_GATE_PROOF_SCHEMA,
            "operationClass": "localGate",
            "candidateId": "1.8.1-21",
            "sourceDigest": "b" * 64,
            "result": "passed",
            "observedAt": "2026-08-19T12:00:00Z",
            "configuration": "Production",
            "scope": "authoritative",
            "environmentClosureSha256": execution_closure(LOCAL_GATE_PROOF_SCHEMA, "Production"),
            "evidenceSha256": hashlib.sha256(
                b"\0".join(
                    (
                        LOCAL_GATE_PROOF_SCHEMA.encode("utf-8"),
                        raw,
                        b"Production",
                        b"authoritative",
                    )
                )
            ).hexdigest(),
        }
        assert len(proof["environmentClosureSha256"]) == 64
        assert "expiresAt" not in proof
        assert "issuedAt" not in proof


def test_execution_closure_is_stable_and_configuration_bound() -> None:
    closure_prod = execution_closure(LOCAL_GATE_PROOF_SCHEMA, "Production")
    closure_prod_repeat = execution_closure(LOCAL_GATE_PROOF_SCHEMA, "Production")
    closure_debug = execution_closure(LOCAL_GATE_PROOF_SCHEMA, "Debug")
    closure_readiness = execution_closure(READINESS_PROOF_SCHEMA, "")
    closure_custom_rev = execution_closure(
        LOCAL_GATE_PROOF_SCHEMA, "Production", contract_revision="custom-rev"
    )

    assert closure_prod == closure_prod_repeat
    assert len(closure_prod) == 64
    assert all(c in "0123456789abcdef" for c in closure_prod)

    assert closure_prod != closure_debug
    assert closure_prod != closure_readiness
    assert closure_prod != closure_custom_rev

    expected_prod = hashlib.sha256(
        b"\0".join(
            (
                LOCAL_GATE_PROOF_SCHEMA.encode("utf-8"),
                b"Production",
                CONTRACT_REVISION.encode("utf-8"),
            )
        )
    ).hexdigest()
    assert closure_prod == expected_prod


def test_gate_emits_candidate_proof_only_after_all_counting_legs_pass() -> None:
    gate = (Path(__file__).resolve().parent / "test-gate.sh").read_text(encoding="utf-8")
    completion = gate.rindex("assert_counting_legs_complete")
    emission = gate.rindex("release_stage_readiness.py --local-gate")
    success = gate.rindex("test-gate.sh: all destinations green")

    assert completion < emission < success
    assert 'if [[ -n "${READINESS_MANIFEST:-}" ]]' in gate[completion:emission]


def test_canonical_manifest_accepts_linked_worktree_git_common_dir() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        base = Path(temporary)
        checkout = base / "worktree"
        common_dir = base / "repository.git"
        checkout.mkdir()
        common_dir.mkdir()
        (checkout / ".git").write_text("gitdir: ../repository.git/worktrees/fixture\n")
        manifest = (
            common_dir
            / "release-state"
            / "gradus-ios"
            / "candidates"
            / "1.8.1-21"
            / "manifest.json"
        )
        manifest.parent.mkdir(parents=True)
        manifest.write_text("{}", encoding="utf-8")

        def runner(argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
            assert argv == [
                "git",
                "-C",
                str(checkout),
                "rev-parse",
                "--path-format=absolute",
                "--git-common-dir",
            ]
            assert kwargs == {"capture_output": True, "text": True, "check": False}
            return subprocess.CompletedProcess(argv, 0, f"{common_dir}\n", "")

        assert (
            resolve_canonical_manifest(str(manifest), checkout, runner=runner) == manifest.resolve()
        )


def test_canonical_manifest_rejects_path_outside_git_common_dir() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        base = Path(temporary)
        checkout = base / "worktree"
        common_dir = base / "repository.git"
        checkout.mkdir()
        common_dir.mkdir()
        manifest = base / "outside" / "1.8.1-21" / "manifest.json"
        manifest.parent.mkdir(parents=True)
        manifest.write_text("{}", encoding="utf-8")

        def runner(argv: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
            return subprocess.CompletedProcess(argv, 0, f"{common_dir}\n", "")

        try:
            resolve_canonical_manifest(str(manifest), checkout, runner=runner)
        except ValueError as exc:
            assert str(exc) == "readiness-manifest-outside-canonical-root"
        else:
            raise AssertionError("manifest outside the Git common directory was accepted")


def load_tests(
    _loader: unittest.TestLoader,
    _tests: unittest.TestSuite,
    _pattern: str | None,
) -> unittest.TestSuite:
    """Expose the existing pytest-style functions to the release unittest gate."""

    functions = [
        value for name, value in globals().items() if name.startswith("test_") and callable(value)
    ]
    return unittest.TestSuite(unittest.FunctionTestCase(function) for function in functions)
