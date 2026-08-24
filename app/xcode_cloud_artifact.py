#!/usr/bin/env -S /Users/dave/.local/bin/uv run --with pyjwt --with cryptography python
"""Xcode Cloud artifact discovery and safe download primitives.

This module provides safe, credential-bound discovery of Xcode Cloud build action
artifacts through App Store Connect, and uncredentialed streaming download of
presigned artifact URLs.

Security invariants:
- Credentials and bearer tokens are used only with the official App Store Connect API.
- Presigned download requests never include an Authorization header.
- Raw response bodies, bearer tokens, and presigned URLs are never logged or persisted.
- Artifact file names, sizes, URLs, and action UUIDs are strictly validated before download.
- Artifact files are streamed to a same-directory temporary file and atomically replaced
  only after exact byte size validation.
- Traversal, symlink, malformed, duplicate, and wrong-size responses fail closed
  without replacing the destination.
"""

from __future__ import annotations

import os
import re
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Any, TextIO

from _asc_api import ASCClient

_UUID_REGEX = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)
_OPAQUE_ID_REGEX = re.compile(r"^[A-Za-z0-9-]{1,128}$")
DEFAULT_TIMEOUT_SECONDS = 30.0
DEFAULT_CHUNK_SIZE = 65536
DEFAULT_PROGRESS_INTERVAL_BYTES = 4 * 1024 * 1024


class ArtifactDownloadError(ValueError):
    """Raised when artifact discovery, validation, or download fails."""


def validate_ci_build_action_id(action_id: Any) -> str:
    """Validate that action_id is a valid UUID string."""
    if not isinstance(action_id, str) or not _UUID_REGEX.fullmatch(action_id.strip()):
        raise ArtifactDownloadError("action-id-invalid")
    return action_id.strip()


def validate_artifact_file_name(file_name: Any) -> str:
    """Validate that file_name is a safe, single-component filename without path traversal."""
    if not isinstance(file_name, str) or not file_name:
        raise ArtifactDownloadError("artifact-filename-invalid")
    if (
        os.path.basename(file_name) != file_name
        or file_name in (".", "..")
        or "/" in file_name
        or "\\" in file_name
        or "\0" in file_name
    ):
        raise ArtifactDownloadError("artifact-filename-invalid")
    return file_name


def validate_artifact_file_size(file_size: Any) -> int:
    """Validate that file_size is a positive integer."""
    if isinstance(file_size, bool) or not isinstance(file_size, (int, str)):
        raise ArtifactDownloadError("artifact-size-invalid")
    try:
        size = int(file_size)
    except (ValueError, TypeError):
        raise ArtifactDownloadError("artifact-size-invalid")
    if size <= 0:
        raise ArtifactDownloadError("artifact-size-invalid")
    return size


def validate_artifact_download_url(download_url: Any) -> str:
    """Validate that download_url is a non-empty HTTPS URL."""
    if not isinstance(download_url, str) or not download_url:
        raise ArtifactDownloadError("artifact-url-invalid")
    parsed = urllib.parse.urlparse(download_url)
    if parsed.scheme != "https" or not parsed.netloc:
        raise ArtifactDownloadError("artifact-url-invalid")
    return download_url


def _result_bundles(client: ASCClient, action_id: str) -> list[dict[str, Any]]:
    """Return validated RESULT_BUNDLE records without logging response data.

    Validates action UUID, artifact ID, file name, file size, and HTTPS download URL.
    """
    valid_action_id = validate_ci_build_action_id(action_id)
    path = f"/ciBuildActions/{valid_action_id}/artifacts?fields[ciArtifacts]=fileType,fileName,fileSize,downloadUrl&limit=200"

    payload = client.request("GET", path)
    if not isinstance(payload, Mapping) or not isinstance(payload.get("data"), list):
        raise ArtifactDownloadError("artifact-response-invalid")

    data = payload["data"]
    result_bundles: list[dict[str, Any]] = []

    for item in data:
        if not isinstance(item, Mapping):
            raise ArtifactDownloadError("artifact-response-invalid")
        attributes = item.get("attributes")
        if not isinstance(attributes, Mapping):
            raise ArtifactDownloadError("artifact-response-invalid")
        if attributes.get("fileType") != "RESULT_BUNDLE":
            continue
        artifact_id = item.get("id")
        if not isinstance(artifact_id, str) or not _OPAQUE_ID_REGEX.fullmatch(artifact_id):
            raise ArtifactDownloadError("artifact-id-invalid")
        result_bundles.append(
            {
                "id": artifact_id,
                "fileType": "RESULT_BUNDLE",
                "fileName": validate_artifact_file_name(attributes.get("fileName")),
                "fileSize": validate_artifact_file_size(attributes.get("fileSize")),
                "downloadUrl": validate_artifact_download_url(attributes.get("downloadUrl")),
            }
        )

    return result_bundles


def list_result_bundle_metadata(client: ASCClient, action_id: str) -> list[dict[str, Any]]:
    """List safe RESULT_BUNDLE metadata while omitting every download URL."""
    return [
        {
            "id": bundle["id"],
            "fileType": bundle["fileType"],
            "fileName": bundle["fileName"],
            "fileSize": bundle["fileSize"],
        }
        for bundle in _result_bundles(client, action_id)
    ]


def find_result_bundle(
    client: ASCClient, action_id: str, artifact_id: str | None = None
) -> dict[str, Any]:
    """Select one RESULT_BUNDLE, optionally by its exact opaque artifact ID."""
    result_bundles = _result_bundles(client, action_id)

    if artifact_id is not None:
        if not _OPAQUE_ID_REGEX.fullmatch(artifact_id):
            raise ArtifactDownloadError("artifact-id-invalid")
        result_bundles = [bundle for bundle in result_bundles if bundle["id"] == artifact_id]

    if len(result_bundles) == 0:
        raise ArtifactDownloadError("no-result-bundle")
    if len(result_bundles) > 1:
        raise ArtifactDownloadError("duplicate-result-bundle")

    return result_bundles[0]


def _default_download_transport(request: urllib.request.Request, timeout_seconds: float) -> Any:
    return urllib.request.urlopen(request, timeout=timeout_seconds)


def _read_stream_chunk(stream_resp: Any, chunk_size: int) -> bytes:
    if hasattr(stream_resp, "read"):
        data = stream_resp.read(chunk_size)
        return data if isinstance(data, (bytes, bytearray)) else b""
    if hasattr(stream_resp, "body") and isinstance(stream_resp.body, (bytes, bytearray)):
        if not hasattr(stream_resp, "_offset"):
            setattr(stream_resp, "_offset", 0)
        offset = getattr(stream_resp, "_offset")
        chunk = stream_resp.body[offset : offset + chunk_size]
        setattr(stream_resp, "_offset", offset + len(chunk))
        return bytes(chunk)
    return b""


def download_artifact(
    download_url: str,
    output_dir: Path | str,
    file_name: str,
    expected_size: int,
    *,
    download_transport: Callable[[urllib.request.Request, float], Any] | None = None,
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
    chunk_size: int = DEFAULT_CHUNK_SIZE,
    stderr: TextIO | None = None,
) -> Path:
    """Stream an uncredentialed presigned artifact download to a temporary file and atomically replace destination.

    Progress in bytes is emitted to stderr. The presigned URL is never sent with
    an Authorization header, and no secrets or URLs are logged.
    """
    valid_url = validate_artifact_download_url(download_url)
    valid_name = validate_artifact_file_name(file_name)
    valid_size = validate_artifact_file_size(expected_size)

    if stderr is None:
        stderr = sys.stderr

    out_dir_path = Path(output_dir)
    if not out_dir_path.exists():
        out_dir_path.mkdir(parents=True, exist_ok=True)
    if not out_dir_path.is_dir():
        raise ArtifactDownloadError("output-dir-invalid")

    destination = out_dir_path / valid_name

    # Check for symlink at destination
    if destination.is_symlink() or os.path.islink(destination):
        raise ArtifactDownloadError("destination-is-symlink")

    # Build request - explicitly verify NO Authorization header
    request = urllib.request.Request(valid_url, method="GET")
    if request.has_header("Authorization") or request.has_header("authorization"):
        request.remove_header("Authorization")
        request.remove_header("authorization")

    # Emit initial progress
    stderr.write(f"Downloading {valid_name} (0/{valid_size} bytes)...\n")
    stderr.flush()

    # Create temporary file in the same directory for atomic replace
    temp_file = tempfile.NamedTemporaryFile(
        dir=out_dir_path, prefix=f".{valid_name}.", suffix=".tmp", delete=False
    )
    temp_path = Path(temp_file.name)
    temp_file.close()

    transport = (
        download_transport if download_transport is not None else _default_download_transport
    )

    response = None
    bytes_written = 0
    last_progress_bytes = 0
    try:
        try:
            response = transport(request, timeout_seconds)
        except urllib.error.HTTPError as exc:
            raise ArtifactDownloadError(f"download-http-{exc.code}") from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise ArtifactDownloadError("download-transport-error") from exc

        # Check HTTP status if present on response object
        status = getattr(response, "status", None)
        if status is None and hasattr(response, "getcode"):
            status = response.getcode()
        if status is not None and not (200 <= status <= 299):
            raise ArtifactDownloadError(f"download-http-{status}")

        with open(temp_path, "wb") as out_file:
            while True:
                chunk = _read_stream_chunk(response, chunk_size)
                if not chunk:
                    break
                out_file.write(chunk)
                bytes_written += len(chunk)
                if bytes_written > valid_size:
                    raise ArtifactDownloadError("artifact-size-mismatch")
                if (
                    bytes_written == valid_size
                    or bytes_written - last_progress_bytes >= DEFAULT_PROGRESS_INTERVAL_BYTES
                ):
                    stderr.write(f"Downloading {valid_name}: {bytes_written}/{valid_size} bytes\n")
                    stderr.flush()
                    last_progress_bytes = bytes_written

            out_file.flush()
            os.fsync(out_file.fileno())

        if bytes_written != valid_size:
            raise ArtifactDownloadError("artifact-size-mismatch")

        # Double check destination is not a symlink right before atomic replacement
        if destination.is_symlink() or os.path.islink(destination):
            raise ArtifactDownloadError("destination-is-symlink")

        os.replace(temp_path, destination)
    except Exception:
        try:
            temp_path.unlink(missing_ok=True)
        except OSError:
            pass
        raise
    finally:
        if response is not None and hasattr(response, "close"):
            try:
                response.close()
            except Exception:
                pass

    return destination


def download_ci_build_action_result_bundle(
    client: ASCClient,
    action_id: str,
    output_dir: Path | str,
    *,
    artifact_id: str | None = None,
    download_transport: Callable[[urllib.request.Request, float], Any] | None = None,
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
    stderr: TextIO | None = None,
) -> Path:
    """Discover the single RESULT_BUNDLE artifact for a CI build action and download it safely."""
    bundle = find_result_bundle(client, action_id, artifact_id)
    return download_artifact(
        download_url=bundle["downloadUrl"],
        output_dir=output_dir,
        file_name=bundle["fileName"],
        expected_size=bundle["fileSize"],
        download_transport=download_transport,
        timeout_seconds=timeout_seconds,
        stderr=stderr,
    )
