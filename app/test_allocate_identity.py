from __future__ import annotations

import json
from pathlib import Path

import pytest
from allocate_identity import (
    IdentityAllocationError,
    _remote_semver,
    main,
    make_proof,
    read_marketing_version,
    write_proof,
)


class FixtureClient:
    def __init__(self, responses):
        self.responses = iter(responses)
        self.paths = []

    def request(self, method, path):
        assert method == "GET"
        self.paths.append(path)
        return next(self.responses)


def _project(tmp_path: Path, version: str = "1.6.7") -> Path:
    path = tmp_path / "project.yml"
    path.write_text(
        f'name: Gradus\ntargets:\n  GradusiOS:\n    settings:\n      MARKETING_VERSION: "{version}"\n',
        encoding="utf-8",
    )
    return path


def _responses():
    return [
        {"data": [{"id": "app-1", "attributes": {"bundleId": "com.zerodelta.gradus.ios"}}]},
        {
            "data": [
                {
                    "id": "build-7",
                    "attributes": {"version": "7", "processingState": "VALID"},
                    "relationships": {"preReleaseVersion": {"data": {"id": "pre-167"}}},
                },
                {
                    "id": "build-6",
                    "attributes": {"version": "6", "processingState": "VALID"},
                    "relationships": {"preReleaseVersion": {"data": {"id": "pre-166"}}},
                },
            ],
            "included": [
                {
                    "type": "preReleaseVersions",
                    "id": "pre-167",
                    "attributes": {"version": "1.6.7", "platform": "IOS"},
                },
                {
                    "type": "preReleaseVersions",
                    "id": "pre-166",
                    "attributes": {"version": "1.6.6", "platform": "IOS"},
                },
            ],
            "links": {"next": None},
        },
    ]


def test_make_proof_reads_fixed_app_and_build_bindings_without_persisting_response(tmp_path):
    client = FixtureClient(_responses())
    proof = make_proof(
        client,
        product="gradus-ios",
        marketing_version=read_marketing_version(_project(tmp_path)),
        observed_at="2026-08-13T12:00:00Z",
    )

    assert set(proof) == {
        "proofVersion",
        "operationClass",
        "result",
        "marketingVersion",
        "buildNumber",
        "responseSha256",
        "productKey",
        "remoteHighestMarketingVersion",
        "remoteHighestBuildNumber",
        "observedAt",
    }
    assert proof["operationClass"] == "identityAllocation"
    assert proof["result"] == "passed"
    assert proof["marketingVersion"] == "1.6.7"
    assert proof["buildNumber"] == 8
    assert proof["remoteHighestMarketingVersion"] == "1.6.7"
    assert proof["remoteHighestBuildNumber"] == 7
    assert len(proof["responseSha256"]) == 64
    assert "Bearer" not in json.dumps(proof)
    assert len(client.paths) == 2


def test_unsupported_product_and_unbound_response_fail_closed(tmp_path):
    with pytest.raises(IdentityAllocationError, match="product-unsupported"):
        make_proof(FixtureClient([]), product="other", marketing_version="1.6.7")

    responses = _responses()
    responses[1]["data"][0]["relationships"] = {}
    with pytest.raises(IdentityAllocationError, match="build-prerelease-binding-invalid"):
        make_proof(FixtureClient(responses), product="gradus-ios", marketing_version="1.6.7")


def test_remote_abbreviated_version_is_normalized_but_extra_components_fail_closed():
    assert _remote_semver("1.6") == (1, 6, 0)
    assert _remote_semver("1") == (1, 0, 0)
    with pytest.raises(IdentityAllocationError, match="components-4"):
        _remote_semver("1.6.7.1")


def test_write_proof_is_fixed_and_does_not_overwrite(tmp_path):
    destination = tmp_path / ".release-state/evidence/allocate-identity.json"
    proof = {"proofVersion": "1.0.0", "operationClass": "identityAllocation"}
    write_proof(destination, proof)
    assert json.loads(destination.read_text(encoding="utf-8")) == proof
    assert destination.stat().st_mode & 0o777 == 0o400
    with pytest.raises(IdentityAllocationError, match="identity-proof-already-exists"):
        write_proof(destination, proof)

    assert json.loads(destination.read_text(encoding="utf-8")) == proof
    assert destination.stat().st_mode & 0o777 == 0o400


def test_identity_cli_remains_backward_compatible(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project_dir = tmp_path / "app"
    project_dir.mkdir(parents=True, exist_ok=True)
    _project(project_dir)

    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr("allocate_identity.make_token_provider", lambda: None)
    monkeypatch.setattr("allocate_identity.ASCClient", lambda provider: FixtureClient(_responses()))

    status = main(["--product", "gradus-ios"])
    assert status == 0

    evidence_file = tmp_path / ".release-state" / "evidence" / "allocate-identity.json"
    assert evidence_file.is_file()
    proof = json.loads(evidence_file.read_text(encoding="utf-8"))
    assert proof["result"] == "passed"
    assert proof["productKey"] == "gradus-ios"
    assert proof["marketingVersion"] == "1.6.7"
    assert proof["buildNumber"] == 8


def test_cli_artifact_download_mode(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    action_id = "11111111-2222-3333-4444-555555555555"
    out_dir = tmp_path / "downloads"
    artifact_data = b"ZIP_BUNDLE_DATA"

    monkeypatch.setattr("allocate_identity.make_token_provider", lambda: None)
    monkeypatch.setattr(
        "allocate_identity.ASCClient",
        lambda provider: FixtureClient(
            [
                {
                    "data": [
                        {
                            "type": "ciArtifacts",
                            "id": "res-1",
                            "attributes": {
                                "fileType": "RESULT_BUNDLE",
                                "fileName": "Test.xcresult.zip",
                                "fileSize": len(artifact_data),
                                "downloadUrl": "https://example.com/test.zip",
                            },
                        }
                    ]
                }
            ]
        ),
    )

    class MockStream:
        def __init__(self, data):
            self.data = data
            self.offset = 0
            self.status = 200

        def read(self, amt=-1):
            if self.offset >= len(self.data):
                return b""
            chunk = self.data[self.offset :]
            self.offset += len(chunk)
            return chunk

        def close(self):
            pass

    monkeypatch.setattr(
        "xcode_cloud_artifact._default_download_transport",
        lambda req, timeout: MockStream(artifact_data),
    )

    status = main(["--ci-build-action-id", action_id, "--output-dir", str(out_dir)])
    assert status == 0
    downloaded_file = out_dir / "Test.xcresult.zip"
    assert downloaded_file.is_file()
    assert downloaded_file.read_bytes() == artifact_data


def test_cli_rejects_conflicting_and_missing_arguments() -> None:
    # Conflicting arguments
    assert (
        main(
            [
                "--product",
                "gradus-ios",
                "--ci-build-action-id",
                "11111111-2222-3333-4444-555555555555",
            ]
        )
        == 1
    )
    # Missing arguments
    assert main([]) == 1
    # Only action ID without output dir
    assert main(["--ci-build-action-id", "11111111-2222-3333-4444-555555555555"]) == 1
