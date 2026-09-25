from __future__ import annotations

import hashlib
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import allocate_identity
import gradus_release_bridge
from release_candidate.retired_identity import retired_candidate_successor_build

VERSION = "1.11.0"
REMOTE_VERSION = "1.10.3"


def _proof(*, observed_at: str | None = None) -> dict[str, object]:
    return {
        "proofVersion": "1.0.0",
        "operationClass": "identityAllocation",
        "result": "passed",
        "productKey": "gradus-ios",
        "marketingVersion": VERSION,
        "buildNumber": 36,
        "responseSha256": "a" * 64,
        "remoteHighestMarketingVersion": REMOTE_VERSION,
        "remoteHighestBuildNumber": 35,
        "observedAt": observed_at
        or datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    }


def _write_candidate(
    common_dir: Path,
    build: int,
    *,
    version: str = VERSION,
    failed: bool = True,
    upload_transition: str | None = None,
    terminal: str | None = None,
    malformed_transitions: bool = False,
) -> Path:
    candidate_id = f"{version}-{build}"
    candidate_root = common_dir / "release-state" / "gradus-ios" / "candidates" / candidate_id
    candidate_root.mkdir(parents=True)
    manifest = {
        "formatVersion": 2,
        "candidateId": candidate_id,
        "productIdentifier": "gradus-ios",
        "immutable": True,
        "release": {"frozen": True, "marketingVersion": version, "buildNumber": str(build)},
        "sourceSnapshot": {"sha256": "c" * 64},
        "adapter": {"sha256": "d" * 64},
        "identityAllocation": {"proofSha256": "e" * 64},
        "artifactAttestation": {"candidateId": candidate_id, "sourceDigest": "c" * 64},
    }
    manifest["manifestSha256"] = _digest(manifest)
    (candidate_root / "manifest.json").write_bytes(_canonical_bytes(manifest) + b"\n")
    allocation_record = {
        "formatVersion": 1,
        "state": "allocated-but-unfrozen",
        "candidateId": candidate_id,
        "productKey": "gradus-ios",
        "marketingVersion": version,
        "buildNumber": build,
        "sourceDigest": "c" * 64,
        "adapterDigest": "d" * 64,
        "allocationProofSha256": "e" * 64,
        "observedAt": "2026-09-25T12:00:00Z",
    }
    (candidate_root.parent / f"{candidate_id}.allocated-but-unfrozen.json").write_bytes(
        _canonical_bytes(allocation_record) + b"\n"
    )
    if malformed_transitions:
        (candidate_root / "transitions.jsonl").write_text("{malformed\n", encoding="utf-8")
        return candidate_root
    transitions = [{"transition": "readinessSatisfied"}]
    if failed:
        transitions.extend({"transition": "failed"} for _ in range(4 if build == 38 else 1))
    if upload_transition is not None:
        transitions.append({"transition": upload_transition})
    if terminal is None:
        terminal = "cancelled" if build == 38 else "superseded"
    transitions.append({"transition": terminal})
    _write_transitions(candidate_root, transitions)
    return candidate_root


def _canonical_bytes(value: dict[str, object]) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode(
        "utf-8"
    )


def _digest(value: dict[str, object]) -> str:
    return hashlib.sha256(_canonical_bytes(value)).hexdigest()


def _write_transitions(candidate_root: Path, transitions: list[dict[str, object]]) -> None:
    candidate_id = candidate_root.name
    previous_hash = "0" * 64
    records = []
    for sequence, transition in enumerate(transitions, 1):
        record: dict[str, object] = {
            "formatVersion": 2,
            "sequence": sequence,
            "candidateId": candidate_id,
            "transition": transition["transition"],
            "recordedAt": "2026-09-25T12:00:00Z",
            "previousHash": previous_hash,
            "details": {},
        }
        if record["transition"] == "failed":
            attempt = sum(item["transition"] == "failed" for item in records) + 1
            record["attempt"] = attempt
            record["details"] = {"attempt": attempt}
        record["recordHash"] = _digest(record)
        previous_hash = record["recordHash"]
        records.append(record)
    (candidate_root / "transitions.jsonl").write_bytes(
        b"".join(_canonical_bytes(record) + b"\n" for record in records)
    )


def _checkout(tmp_path: Path, *, missing_build: int | None = None) -> tuple[Path, Path]:
    repository_root = tmp_path / "checkout"
    repository_root.mkdir(parents=True)
    common_dir = repository_root / ".git"
    common_dir.mkdir()
    for build in (36, 37, 38):
        if build != missing_build:
            _write_candidate(common_dir, build)
    return repository_root, common_dir


def _write_proof(path: Path, proof: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(proof), encoding="utf-8")


def test_reserves_after_retired_chain_and_preserves_remote_observation(tmp_path: Path) -> None:
    repository_root, _ = _checkout(tmp_path)
    proof = _proof()
    original = dict(proof)

    assert retired_candidate_successor_build(proof, repository_root) == 39
    assert proof == original
    assert proof["remoteHighestBuildNumber"] == 35
    assert proof["remoteHighestMarketingVersion"] == REMOTE_VERSION
    assert proof["responseSha256"] == "a" * 64


def test_rejects_wrong_train_and_missing_intervening_candidate(tmp_path: Path) -> None:
    wrong_train_root, wrong_common = _checkout(tmp_path / "wrong-train")
    (wrong_common / "release-state" / "gradus-ios" / "candidates" / "1.11.0-36").rename(
        wrong_common / "release-state" / "gradus-ios" / "candidates" / "1.10.0-36"
    )
    assert retired_candidate_successor_build(_proof(), wrong_train_root) is None

    missing_root, _ = _checkout(tmp_path / "missing", missing_build=37)
    assert retired_candidate_successor_build(_proof(), missing_root) is None

    wrong_product_root, wrong_product_common = _checkout(tmp_path / "wrong-product")
    manifest_path = (
        wrong_product_common
        / "release-state"
        / "gradus-ios"
        / "candidates"
        / "1.11.0-38"
        / "manifest.json"
    )
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["productIdentifier"] = "com.example.other"
    manifest.pop("manifestSha256")
    manifest["manifestSha256"] = _digest(manifest)
    manifest_path.write_bytes(_canonical_bytes(manifest) + b"\n")
    assert retired_candidate_successor_build(_proof(), wrong_product_root) is None


def test_rejects_missing_failure_and_upload_boundaries(tmp_path: Path) -> None:
    no_failure_root, no_failure_common = _checkout(tmp_path / "no-failure")
    candidate = no_failure_common / "release-state" / "gradus-ios" / "candidates" / "1.11.0-37"
    _write_transitions(
        candidate,
        [{"transition": "readinessSatisfied"}, {"transition": "superseded"}],
    )
    assert retired_candidate_successor_build(_proof(), no_failure_root) is None

    for marker in ("uploadAttemptStarted", "uploaded", "internalTestFlightReceipted"):
        upload_root, upload_common = _checkout(tmp_path / marker)
        candidate = upload_common / "release-state" / "gradus-ios" / "candidates" / "1.11.0-36"
        _write_transitions(
            candidate,
            [
                {"transition": "readinessSatisfied"},
                {"transition": "failed"},
                {"transition": marker},
                {"transition": "superseded"},
            ],
        )
        assert retired_candidate_successor_build(_proof(), upload_root) is None

    receipt_root, receipt_common = _checkout(tmp_path / "receipt")
    candidate = receipt_common / "release-state" / "gradus-ios" / "candidates" / "1.11.0-37"
    (candidate / "receipt.json").write_text("{}", encoding="utf-8")
    assert retired_candidate_successor_build(_proof(), receipt_root) is None

    upload_proof_root, upload_proof_common = _checkout(tmp_path / "upload-proof")
    candidate = upload_proof_common / "release-state" / "gradus-ios" / "candidates" / "1.11.0-38"
    (candidate / "upload-proof.json").write_text("{}", encoding="utf-8")
    assert retired_candidate_successor_build(_proof(), upload_proof_root) is None


def test_rejects_active_pointer_stale_observation_malformed_ledger_and_empty_chain(
    tmp_path: Path,
) -> None:
    active_root, active_common = _checkout(tmp_path / "active")
    pointer = active_common / "release-state" / "gradus-ios" / "active-candidate.json"
    pointer.write_text('{"candidateId":"1.11.0-38"}', encoding="utf-8")
    assert retired_candidate_successor_build(_proof(), active_root) is None

    stale_root, _ = _checkout(tmp_path / "stale")
    stale = _proof(
        observed_at=(datetime.now(timezone.utc) - timedelta(minutes=11))
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )
    assert retired_candidate_successor_build(stale, stale_root) is None

    malformed_root, malformed_common = _checkout(tmp_path / "malformed")
    candidate = malformed_common / "release-state" / "gradus-ios" / "candidates" / "1.11.0-38"
    (candidate / "transitions.jsonl").write_text("{bad json\n", encoding="utf-8")
    assert retired_candidate_successor_build(_proof(), malformed_root) is None

    empty_root = tmp_path / "empty-checkout"
    empty_root.mkdir()
    (empty_root / ".git").mkdir()
    assert retired_candidate_successor_build(_proof(), empty_root) is None


def test_resolves_git_common_directory_for_worktrees(tmp_path: Path) -> None:
    repository_root = tmp_path / "worktree"
    repository_root.mkdir()
    common_dir = tmp_path / "repository.git"
    common_dir.mkdir()
    worktree_git_dir = common_dir / "worktrees" / "worker"
    worktree_git_dir.mkdir(parents=True)
    (worktree_git_dir / "commondir").write_text("../..\n", encoding="utf-8")
    (repository_root / ".git").write_text(f"gitdir: {worktree_git_dir}\n", encoding="utf-8")
    for build in (36, 37, 38):
        _write_candidate(common_dir, build)

    assert retired_candidate_successor_build(_proof(), repository_root) == 39


def test_allocator_uses_retired_helper_without_live_credentials(
    tmp_path: Path, monkeypatch
) -> None:
    repository_root, common_dir = _checkout(tmp_path)
    app_dir = repository_root / "app"
    app_dir.mkdir()
    (app_dir / "project.yml").write_text(
        'targets:\n  GradusiOS:\n    settings:\n      MARKETING_VERSION: "1.11.0"\n',
        encoding="utf-8",
    )

    class FixtureClient:
        def __init__(self, _provider: object) -> None:
            self.responses = iter(
                [
                    {
                        "data": [
                            {
                                "id": "app-1",
                                "attributes": {"bundleId": "com.zerodelta.gradus.ios"},
                            }
                        ]
                    },
                    {
                        "data": [
                            {
                                "type": "builds",
                                "id": "build-35",
                                "attributes": {"version": "35"},
                                "relationships": {
                                    "preReleaseVersion": {"data": {"id": "prerelease-1"}}
                                },
                            }
                        ],
                        "included": [
                            {
                                "type": "preReleaseVersions",
                                "id": "prerelease-1",
                                "attributes": {"version": REMOTE_VERSION, "platform": "IOS"},
                            }
                        ],
                        "links": {"next": None},
                    },
                ]
            )

        def request(self, method: str, _path: str) -> dict[str, object]:
            assert method == "GET"
            return next(self.responses)

    monkeypatch.chdir(repository_root)
    monkeypatch.setattr(allocate_identity, "make_token_provider", lambda: None)
    monkeypatch.setattr(allocate_identity, "ASCClient", FixtureClient)
    assert allocate_identity.main(["--product", "gradus-ios"]) == 0

    proof = json.loads(
        (repository_root / ".release-state" / "evidence" / "allocate-identity.json").read_text(
            encoding="utf-8"
        )
    )
    assert proof["buildNumber"] == 39
    assert proof["remoteHighestBuildNumber"] == 35
    assert proof["remoteHighestMarketingVersion"] == REMOTE_VERSION
    assert proof["responseSha256"]
    assert common_dir.is_dir()


def test_bridge_validates_advanced_broker_proof_through_same_helper(
    tmp_path: Path, monkeypatch
) -> None:
    repository_root, _ = _checkout(tmp_path)
    proof_path = repository_root / "identity.json"
    proof = _proof()
    proof["buildNumber"] = 39
    _write_proof(proof_path, proof)
    monkeypatch.setattr(gradus_release_bridge, "ROOT", repository_root)
    monkeypatch.setattr(gradus_release_bridge, "IDENTITY_PROOF", proof_path)

    assert gradus_release_bridge._identity_proof_valid(marketing_version=VERSION)
