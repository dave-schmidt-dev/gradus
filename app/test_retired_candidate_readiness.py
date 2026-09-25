from __future__ import annotations

import hashlib
import json
import subprocess
from pathlib import Path

import pytest

try:
    from app import release_prepare_bridge as prepare
except ModuleNotFoundError:  # Direct pytest execution from app/.
    import release_prepare_bridge as prepare


VERSION = "1.11.0"
PREDECESSOR = f"{VERSION}-38"
CANDIDATE = f"{VERSION}-39"


def _canonical(value: dict[str, object]) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _write_manifest(candidate_root: Path, candidate_id: str, build: int) -> Path:
    candidate_root.mkdir(parents=True, exist_ok=True)
    manifest: dict[str, object] = {
        "formatVersion": 2,
        "candidateId": candidate_id,
        "productIdentifier": "gradus-ios",
        "immutable": True,
        "release": {"frozen": True, "marketingVersion": VERSION, "buildNumber": str(build)},
        "sourceSnapshot": {"sha256": "c" * 64},
        "adapter": {"sha256": "d" * 64},
        "identityAllocation": {"proofSha256": "e" * 64},
        "artifactAttestation": {"candidateId": candidate_id, "sourceDigest": "c" * 64},
    }
    manifest["manifestSha256"] = hashlib.sha256(_canonical(manifest)).hexdigest()
    path = candidate_root / "manifest.json"
    path.write_bytes(_canonical(manifest) + b"\n")
    return path


def _write_transitions(
    candidate_root: Path, transitions: list[tuple[str, dict[str, object]]]
) -> str:
    previous_hash = "0" * 64
    records: list[dict[str, object]] = []
    failure_hash = "0" * 64
    for sequence, (transition, details) in enumerate(transitions, 1):
        record: dict[str, object] = {
            "formatVersion": 2,
            "sequence": sequence,
            "candidateId": PREDECESSOR,
            "transition": transition,
            "recordedAt": "2026-09-25T12:00:00Z",
            "previousHash": previous_hash,
            "details": details,
        }
        if transition == "failed":
            record["attempt"] = 1
        record["recordHash"] = hashlib.sha256(_canonical(record)).hexdigest()
        previous_hash = str(record["recordHash"])
        if transition == "failed":
            failure_hash = previous_hash
        records.append(record)
    (candidate_root / "transitions.jsonl").write_bytes(
        b"".join(_canonical(record) + b"\n" for record in records)
    )
    return failure_hash


def _fixture(
    tmp_path: Path,
    *,
    prior: str = PREDECESSOR,
    failure_hash_mode: str = "valid",
    transitions: list[tuple[str, dict[str, object]]] | None = None,
    wrong_train: bool = False,
    tamper_central: bool = False,
    active_predecessor: bool = False,
) -> tuple[Path, prepare.CandidateContext]:
    root = tmp_path / "checkout"
    common = root / ".git"
    candidates = common / "release-state" / "gradus-ios" / "candidates"
    version = "1.12.0" if wrong_train else VERSION
    candidate_id = f"{version}-39"
    predecessor = f"{version}-38"
    predecessor_root = candidates / predecessor
    _write_manifest(predecessor_root, predecessor, 38)
    ledger = transitions or [
        ("readinessSatisfied", {}),
        ("failed", {"attempt": 1}),
        ("cancelled", {"reasonCode": "failed-candidate-retired"}),
    ]
    actual_failure_hash = _write_transitions(predecessor_root, ledger)
    failure_hash = actual_failure_hash
    if failure_hash_mode == "wrong":
        failure_hash = "0" * 64
    elif failure_hash_mode == "missing":
        failure_hash = "1" * 64

    identity = {
        "allocation": {
            "productKey": "gradus-ios",
            "requestedMarketingVersion": version,
            "allocatedBuildNumber": 39,
            "remoteHighestMarketingVersion": "1.10.3",
            "remoteHighestBuildNumber": 35,
            "result": "allocated",
            "observedAt": "2026-09-25T12:00:00Z",
        },
        "reuseAuthorization": {
            "kind": "failed-candidate",
            "priorCandidateId": prior,
            "failureRecordHash": failure_hash,
        },
    }
    encoded_identity = _canonical(identity)
    candidate_root = candidates / candidate_id
    manifest_path = _write_manifest(candidate_root, candidate_id, 39)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["identityAllocation"] = {"proofSha256": hashlib.sha256(encoded_identity).hexdigest()}
    manifest.pop("manifestSha256")
    manifest["manifestSha256"] = hashlib.sha256(_canonical(manifest)).hexdigest()
    manifest_path.write_bytes(_canonical(manifest) + b"\n")
    identity_path = candidate_root / "identity-allocation.json"
    identity_path.write_bytes(encoded_identity)
    context = prepare.load_context(manifest_path, git_common_dir=common)
    if tamper_central:
        identity_path.write_bytes(encoded_identity + b" ")
    active_pointer = common / "release-state" / "gradus-ios" / "active-candidate.json"
    active_pointer.write_text(
        json.dumps({"candidateId": predecessor if active_predecessor else candidate_id}),
        encoding="utf-8",
    )

    legacy_workspace = root / ".release-state" / "candidates" / predecessor
    legacy_workspace.mkdir(parents=True)
    (legacy_workspace / "prepared.txt").write_text("fixture", encoding="utf-8")
    (root / ".release-state" / "candidate.json").write_text(
        json.dumps(
            {
                "candidateId": predecessor,
                "state": "prepared",
                "marketingVersion": version,
                "build": 38,
                "metadata": {"candidateWorkspace": str(legacy_workspace)},
            }
        ),
        encoding="utf-8",
    )
    (root / ".release-state" / "allocated-ios.json").write_text(
        json.dumps(
            {
                "state": "allocated-but-unfrozen",
                "candidateId": predecessor,
                "marketingVersion": version,
                "build": 38,
                "allocatedAt": "2026-09-25T12:00:00Z",
            }
        ),
        encoding="utf-8",
    )
    stale_proof = {
        "proofVersion": "1.0.0",
        "operationClass": "identityAllocation",
        "result": "passed",
        "productKey": "gradus-ios",
        "marketingVersion": version,
        "buildNumber": 39,
        "remoteHighestMarketingVersion": "1.10.3",
        "remoteHighestBuildNumber": 35,
        "observedAt": "2026-09-25T12:00:00Z",
        "responseSha256": "a" * 64,
    }
    proof_path = root / ".release-state" / "evidence" / "allocate-identity.json"
    proof_path.parent.mkdir(parents=True)
    proof_path.write_text(json.dumps(stale_proof), encoding="utf-8")
    return root, context


def test_readiness_and_production_archive_accept_exact_failed_candidate_lineage(
    tmp_path: Path,
) -> None:
    root, context = _fixture(tmp_path)

    assert prepare.readiness_preflight(root, context) == PREDECESSOR
    proof = prepare._identity_proof(root, context, persist=False)
    assert proof["buildNumber"] == 39
    assert proof["remoteHighestBuildNumber"] == 35

    assert prepare.reconcile_assigned_candidate(root, context) == PREDECESSOR
    archived = root / ".release-state" / "archived" / PREDECESSOR
    assert json.loads((archived / "candidate.json").read_text())["state"] == "superseded"
    assert not (root / ".release-state" / "candidate.json").exists()


def test_first_production_build_attempt_uses_archived_predecessor_rollover_flag(
    tmp_path: Path,
) -> None:
    root, context = _fixture(tmp_path)
    calls: list[list[str]] = []

    def runner(argv: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 1, "", "")

    with pytest.raises(prepare.BridgeError, match="legacy-preparation-failed"):
        prepare.execute("production-build", context, root=root, runner=runner)

    assert len(calls) == 1
    assert "--rollover-assigned" in calls[0]
    assert "--rollover-uploaded" not in calls[0]


def test_production_build_without_legacy_ledger_uses_no_rollover_flag(tmp_path: Path) -> None:
    root, context = _fixture(tmp_path)
    (root / ".release-state" / "candidate.json").unlink()
    (root / ".release-state" / "allocated-ios.json").unlink()
    calls: list[list[str]] = []

    def runner(argv: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
        calls.append(argv)
        return subprocess.CompletedProcess(argv, 1, "", "")

    with pytest.raises(prepare.BridgeError, match="legacy-preparation-failed"):
        prepare.execute("production-build", context, root=root, runner=runner)

    assert len(calls) == 1
    assert "--rollover-assigned" not in calls[0]
    assert "--rollover-uploaded" not in calls[0]


@pytest.mark.parametrize(
    ("case", "options"),
    [
        ("wrong prior", {"prior": "1.11.0-37"}),
        ("wrong hash", {"failure_hash_mode": "wrong"}),
        (
            "missing failure",
            {
                "failure_hash_mode": "missing",
                "transitions": [
                    ("readinessSatisfied", {}),
                    ("cancelled", {"reasonCode": "failed-candidate-retired"}),
                ],
            },
        ),
        (
            "upload attempt",
            {
                "transitions": [
                    ("readinessSatisfied", {}),
                    ("failed", {"attempt": 1}),
                    ("uploadAttemptStarted", {}),
                    ("cancelled", {"reasonCode": "failed-candidate-retired"}),
                ]
            },
        ),
        (
            "wrong terminal",
            {
                "transitions": [
                    ("readinessSatisfied", {}),
                    ("failed", {"attempt": 1}),
                    ("superseded", {"reasonCode": "failed-candidate-retired"}),
                ]
            },
        ),
        ("wrong train", {"wrong_train": True}),
        ("active predecessor", {"active_predecessor": True}),
        ("tampered central proof", {"tamper_central": True}),
    ],
)
def test_readiness_rejects_untrusted_failed_candidate_lineage(
    tmp_path: Path, case: str, options: dict[str, object]
) -> None:
    root, context = _fixture(tmp_path, **options)

    with pytest.raises(prepare.BridgeError):
        prepare.readiness_preflight(root, context)
