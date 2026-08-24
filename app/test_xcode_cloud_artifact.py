from __future__ import annotations

import io
from pathlib import Path
from typing import Any

import pytest
from xcode_cloud_artifact import (
    ArtifactDownloadError,
    download_artifact,
    download_ci_build_action_result_bundle,
    find_result_bundle,
    list_result_bundle_metadata,
    validate_artifact_download_url,
    validate_artifact_file_name,
    validate_artifact_file_size,
    validate_ci_build_action_id,
)


class FixtureASCClient:
    def __init__(self, responses: list[dict[str, Any]]) -> None:
        self.responses = iter(responses)
        self.paths: list[str] = []

    def request(self, method: str, path: str) -> dict[str, Any]:
        assert method == "GET"
        self.paths.append(path)
        return next(self.responses)


class StreamingBytesResponse:
    """Mock streaming HTTP response for injected download transport."""

    def __init__(self, data: bytes, chunk_size: int = 256, status: int = 200) -> None:
        self.data = data
        self.chunk_size = chunk_size
        self.status = status
        self.offset = 0
        self.headers = {"content-length": str(len(data))}

    def read(self, amt: int = -1) -> bytes:
        if self.offset >= len(self.data):
            return b""
        read_amt = self.chunk_size if amt <= 0 else min(amt, self.chunk_size)
        chunk = self.data[self.offset : self.offset + read_amt]
        self.offset += len(chunk)
        return chunk

    def close(self) -> None:
        pass


def _artifact_response(
    bundles: list[dict[str, Any]],
    other_artifacts: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    data = []
    for i, b in enumerate(bundles):
        data.append(
            {
                "type": "ciArtifacts",
                "id": f"result-bundle-{i + 1}",
                "attributes": {
                    "fileType": "RESULT_BUNDLE",
                    "fileName": b.get("fileName", "Test-GradusiOS.xcresult.zip"),
                    "fileSize": b.get("fileSize", 1024),
                    "downloadUrl": b.get(
                        "downloadUrl",
                        "https://developer-build-artifacts.apple.com/download/result.zip?token=secret123",
                    ),
                },
            }
        )
    if other_artifacts:
        for i, o in enumerate(other_artifacts):
            data.append(
                {
                    "type": "ciArtifacts",
                    "id": f"other-artifact-{i + 1}",
                    "attributes": o,
                }
            )
    return {"data": data}


def test_selects_exactly_one_result_bundle() -> None:
    action_id = "11111111-2222-3333-4444-555555555555"

    # Exactly one RESULT_BUNDLE (along with other artifact types)
    single_bundle = [
        {
            "fileName": "Gradus.xcresult.zip",
            "fileSize": 2048,
            "downloadUrl": "https://example.com/gradus.zip",
        }
    ]
    other_artifacts = [
        {
            "fileType": "ARCHIVE",
            "fileName": "Gradus.xcarchive.zip",
            "fileSize": 4096,
            "downloadUrl": "https://example.com/archive.zip",
        },
        {
            "fileType": "LOG",
            "fileName": "build.log",
            "fileSize": 512,
            "downloadUrl": "https://example.com/log.txt",
        },
    ]
    client = FixtureASCClient([_artifact_response(single_bundle, other_artifacts)])
    result = find_result_bundle(client, action_id)
    assert result["fileType"] == "RESULT_BUNDLE"
    assert result["fileName"] == "Gradus.xcresult.zip"
    assert result["fileSize"] == 2048
    assert result["downloadUrl"] == "https://example.com/gradus.zip"
    assert client.paths == [
        f"/ciBuildActions/{action_id}/artifacts?fields[ciArtifacts]=fileType,fileName,fileSize,downloadUrl&limit=200"
    ]

    # Zero RESULT_BUNDLE entries
    client_empty = FixtureASCClient([_artifact_response([], other_artifacts)])
    with pytest.raises(ArtifactDownloadError, match="no-result-bundle"):
        find_result_bundle(client_empty, action_id)

    # Duplicate (multiple) RESULT_BUNDLE entries
    two_bundles = [
        {
            "fileName": "Gradus1.xcresult.zip",
            "fileSize": 1024,
            "downloadUrl": "https://example.com/1.zip",
        },
        {
            "fileName": "Gradus2.xcresult.zip",
            "fileSize": 1024,
            "downloadUrl": "https://example.com/2.zip",
        },
    ]
    client_duplicate = FixtureASCClient([_artifact_response(two_bundles)])
    with pytest.raises(ArtifactDownloadError, match="duplicate-result-bundle"):
        find_result_bundle(client_duplicate, action_id)


def test_lists_safe_metadata_and_selects_an_exact_artifact() -> None:
    action_id = "11111111-2222-3333-4444-555555555555"
    bundles = [
        {
            "fileName": "Phone.xcresult.zip",
            "fileSize": 100,
            "downloadUrl": "https://example.com/phone.zip?token=secret-phone",
        },
        {
            "fileName": "Aggregate.xcresult.zip",
            "fileSize": 200,
            "downloadUrl": "https://example.com/all.zip?token=secret-all",
        },
    ]
    metadata_client = FixtureASCClient([_artifact_response(bundles)])
    metadata = list_result_bundle_metadata(metadata_client, action_id)
    assert metadata == [
        {
            "id": "result-bundle-1",
            "fileType": "RESULT_BUNDLE",
            "fileName": "Phone.xcresult.zip",
            "fileSize": 100,
        },
        {
            "id": "result-bundle-2",
            "fileType": "RESULT_BUNDLE",
            "fileName": "Aggregate.xcresult.zip",
            "fileSize": 200,
        },
    ]
    assert "downloadUrl" not in repr(metadata)
    assert "secret-" not in repr(metadata)

    selection_client = FixtureASCClient([_artifact_response(bundles)])
    selected = find_result_bundle(selection_client, action_id, "result-bundle-1")
    assert selected["fileName"] == "Phone.xcresult.zip"
    assert selected["downloadUrl"].endswith("secret-phone")

    missing_client = FixtureASCClient([_artifact_response(bundles)])
    with pytest.raises(ArtifactDownloadError, match="no-result-bundle"):
        find_result_bundle(missing_client, action_id, "result-bundle-9")


def test_download_emits_safe_progress_and_path(tmp_path: Path) -> None:
    action_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    expected_data = b"X" * 1024
    bundle = [
        {
            "fileName": "Test.xcresult.zip",
            "fileSize": 1024,
            "downloadUrl": "https://example.com/download/test.zip?signature=secret_sig",
        }
    ]
    client = FixtureASCClient([_artifact_response(bundle)])

    recorded_requests = []

    def mock_download_transport(request, timeout):
        recorded_requests.append(request)
        return StreamingBytesResponse(expected_data, chunk_size=256)

    stderr_buffer = io.StringIO()
    dest = download_ci_build_action_result_bundle(
        client,
        action_id=action_id,
        output_dir=tmp_path,
        download_transport=mock_download_transport,
        stderr=stderr_buffer,
    )

    # Destination path returned and verified
    assert dest == tmp_path / "Test.xcresult.zip"
    assert dest.is_file()
    assert dest.read_bytes() == expected_data

    # Progress emitted to stderr
    stderr_output = stderr_buffer.getvalue()
    assert "Downloading Test.xcresult.zip (0/1024 bytes)..." in stderr_output
    assert "Downloading Test.xcresult.zip: 1024/1024 bytes" in stderr_output
    assert stderr_output.count("Downloading Test.xcresult.zip") == 2

    # No secret URL or signature in stderr
    assert "secret_sig" not in stderr_output
    assert "https://" not in stderr_output
    assert "downloadUrl" not in stderr_output

    # Request has no Authorization header
    assert len(recorded_requests) == 1
    req = recorded_requests[0]
    assert not req.has_header("Authorization")
    assert not req.has_header("authorization")
    assert "Authorization" not in req.headers
    assert "authorization" not in req.headers


def test_uncredentialed_download_request_has_no_auth_header_and_no_secret_printed(
    tmp_path: Path,
) -> None:
    download_url = "https://cdn.apple.com/artifacts/build.zip?auth=secret_token"
    file_name = "build.xcresult.zip"
    data = b"HELLO_WORLD_DATA"
    captured_requests = []

    def transport(req, timeout):
        captured_requests.append(req)
        return StreamingBytesResponse(data, chunk_size=4)

    stderr_buf = io.StringIO()
    dest = download_artifact(
        download_url=download_url,
        output_dir=tmp_path,
        file_name=file_name,
        expected_size=len(data),
        download_transport=transport,
        stderr=stderr_buf,
    )

    assert dest.read_bytes() == data
    assert len(captured_requests) == 1
    req = captured_requests[0]
    assert not req.has_header("Authorization")
    assert not req.has_header("authorization")
    assert "Authorization" not in req.headers
    assert "authorization" not in req.headers
    assert "Bearer" not in str(req.headers)

    stderr_text = stderr_buf.getvalue()
    assert "secret_token" not in stderr_text
    assert "cdn.apple.com" not in stderr_text


def test_atomic_replacement_fails_without_replacing_destination_on_partial_download(
    tmp_path: Path,
) -> None:
    dest = tmp_path / "target.xcresult.zip"
    dest.write_bytes(b"ORIGINAL_VALID_CONTENT")

    # Only 500 bytes provided when 1000 expected
    partial_data = b"P" * 500

    def partial_transport(req, timeout):
        return StreamingBytesResponse(partial_data, chunk_size=100)

    stderr_buf = io.StringIO()
    with pytest.raises(ArtifactDownloadError, match="artifact-size-mismatch"):
        download_artifact(
            download_url="https://example.com/art.zip",
            output_dir=tmp_path,
            file_name="target.xcresult.zip",
            expected_size=1000,
            download_transport=partial_transport,
            stderr=stderr_buf,
        )

    # Destination was NOT replaced
    assert dest.read_bytes() == b"ORIGINAL_VALID_CONTENT"

    # Temporary files were cleaned up
    tmp_files = list(tmp_path.glob(".*.tmp"))
    assert tmp_files == []


def test_atomic_replacement_fails_without_replacing_destination_on_wrong_size(
    tmp_path: Path,
) -> None:
    dest = tmp_path / "target.xcresult.zip"
    dest.write_bytes(b"ORIGINAL_VALID_CONTENT")

    # 1200 bytes provided when 1000 expected
    oversized_data = b"O" * 1200

    def oversized_transport(req, timeout):
        return StreamingBytesResponse(oversized_data, chunk_size=200)

    stderr_buf = io.StringIO()
    with pytest.raises(ArtifactDownloadError, match="artifact-size-mismatch"):
        download_artifact(
            download_url="https://example.com/art.zip",
            output_dir=tmp_path,
            file_name="target.xcresult.zip",
            expected_size=1000,
            download_transport=oversized_transport,
            stderr=stderr_buf,
        )

    # Destination was NOT replaced
    assert dest.read_bytes() == b"ORIGINAL_VALID_CONTENT"

    # Temporary files were cleaned up
    tmp_files = list(tmp_path.glob(".*.tmp"))
    assert tmp_files == []


def test_atomic_replacement_fails_without_replacing_destination_on_duplicate_bundles(
    tmp_path: Path,
) -> None:
    dest = tmp_path / "Gradus.xcresult.zip"
    dest.write_bytes(b"ORIGINAL_VALID_CONTENT")

    action_id = "12345678-1234-1234-1234-123456789abc"
    two_bundles = [
        {
            "fileName": "Gradus.xcresult.zip",
            "fileSize": 100,
            "downloadUrl": "https://example.com/1.zip",
        },
        {
            "fileName": "Gradus.xcresult.zip",
            "fileSize": 100,
            "downloadUrl": "https://example.com/2.zip",
        },
    ]
    client = FixtureASCClient([_artifact_response(two_bundles)])

    with pytest.raises(ArtifactDownloadError, match="duplicate-result-bundle"):
        download_ci_build_action_result_bundle(
            client,
            action_id=action_id,
            output_dir=tmp_path,
        )

    # Destination was NOT replaced
    assert dest.read_bytes() == b"ORIGINAL_VALID_CONTENT"


def test_atomic_replacement_fails_without_replacing_destination_on_malformed_inputs(
    tmp_path: Path,
) -> None:
    dest = tmp_path / "valid.xcresult.zip"
    dest.write_bytes(b"ORIGINAL_VALID_CONTENT")

    # Invalid action UUID
    with pytest.raises(ArtifactDownloadError, match="action-id-invalid"):
        validate_ci_build_action_id("not-a-uuid")

    with pytest.raises(ArtifactDownloadError, match="action-id-invalid"):
        validate_ci_build_action_id("12345; rm -rf /")

    # Invalid download URLs (HTTP, FTP, empty)
    with pytest.raises(ArtifactDownloadError, match="artifact-url-invalid"):
        validate_artifact_download_url("http://insecure.com/file.zip")

    with pytest.raises(ArtifactDownloadError, match="artifact-url-invalid"):
        validate_artifact_download_url("ftp://server.com/file.zip")

    with pytest.raises(ArtifactDownloadError, match="artifact-url-invalid"):
        validate_artifact_download_url("")

    # Invalid size
    with pytest.raises(ArtifactDownloadError, match="artifact-size-invalid"):
        validate_artifact_file_size(0)

    with pytest.raises(ArtifactDownloadError, match="artifact-size-invalid"):
        validate_artifact_file_size(-100)

    with pytest.raises(ArtifactDownloadError, match="artifact-size-invalid"):
        validate_artifact_file_size("not-a-number")

    with pytest.raises(ArtifactDownloadError, match="artifact-size-invalid"):
        validate_artifact_file_size(True)

    # Ensure destination is untouched
    assert dest.read_bytes() == b"ORIGINAL_VALID_CONTENT"


def test_atomic_replacement_fails_without_replacing_destination_on_path_traversal(
    tmp_path: Path,
) -> None:
    dest = tmp_path / "safe.zip"
    dest.write_bytes(b"ORIGINAL_VALID_CONTENT")

    traversal_names = [
        "../../etc/passwd",
        "../escape.zip",
        "/absolute/path.zip",
        "subdir/file.zip",
        "subdir\\file.zip",
        ".",
        "..",
        "file\0with_null.zip",
    ]

    for name in traversal_names:
        with pytest.raises(ArtifactDownloadError, match="artifact-filename-invalid"):
            validate_artifact_file_name(name)

        with pytest.raises(ArtifactDownloadError, match="artifact-filename-invalid"):
            download_artifact(
                download_url="https://example.com/file.zip",
                output_dir=tmp_path,
                file_name=name,
                expected_size=100,
            )

    assert dest.read_bytes() == b"ORIGINAL_VALID_CONTENT"


def test_atomic_replacement_fails_without_replacing_destination_on_symlink(tmp_path: Path) -> None:
    target_sensitive = tmp_path / "sensitive_target.txt"
    target_sensitive.write_bytes(b"SENSITIVE_DATA_DO_NOT_OVERWRITE")

    symlink_dest = tmp_path / "artifact.xcresult.zip"
    symlink_dest.symlink_to(target_sensitive)

    download_data = b"NEW_DOWNLOAD_BYTES"

    def mock_transport(req, timeout):
        return StreamingBytesResponse(download_data, chunk_size=10)

    with pytest.raises(ArtifactDownloadError, match="destination-is-symlink"):
        download_artifact(
            download_url="https://example.com/artifact.zip",
            output_dir=tmp_path,
            file_name="artifact.xcresult.zip",
            expected_size=len(download_data),
            download_transport=mock_transport,
        )

    # Sensitive target is completely untouched
    assert target_sensitive.read_bytes() == b"SENSITIVE_DATA_DO_NOT_OVERWRITE"
    # Symlink is still a symlink
    assert symlink_dest.is_symlink()


def test_download_transport_http_error_handling(tmp_path: Path) -> None:
    def failing_transport(req, timeout):
        return StreamingBytesResponse(b"", status=403)

    with pytest.raises(ArtifactDownloadError, match="download-http-403"):
        download_artifact(
            download_url="https://example.com/artifact.zip",
            output_dir=tmp_path,
            file_name="test.zip",
            expected_size=100,
            download_transport=failing_transport,
        )
