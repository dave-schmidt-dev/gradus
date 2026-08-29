#!/usr/bin/env -S /Users/dave/.local/bin/uv run --with pyjwt --with cryptography python
"""In-process App Store Connect build-upload transport.

Replaces ``xcrun altool --upload-package`` and its RAM-backed-volume ``.p8``
ritual with Apple's REST "build uploads" flow (App Store Connect API 4.1,
non-beta: ``buildUploads`` / ``buildUploadFiles``). The private key never
touches disk in any form here -- it is read once from
``APP_STORE_CONNECT_API_KEY`` into memory and used only to sign short-lived
ES256 JWTs, exactly like every other in-process ASC call in this codebase
(see ``_asc_api.TokenProvider``, already used by the ``processing``,
``compliance``, and ``tester-group`` operations in
``gradus_release_bridge.py``).

Flow (every field name and enum value below was confirmed against Apple's
live DocC documentation on 2026-08-21, not recalled from training data):
  1. ``POST /v1/buildUploads``          reserve an upload for this app/version/build
  2. ``POST /v1/buildUploadFiles``       reserve the .ipa asset, get pre-signed PUT URLs
  3. ``PUT <pre-signed url>`` per chunk  transfer the bytes; unauthenticated by design
  4. ``PATCH /v1/buildUploadFiles/{id}`` commit (``"uploaded": true``)
  5. ``GET /v1/buildUploads/{id}``       poll until ``state`` is COMPLETE or FAILED

Residual, honestly-flagged unknowns (see apple_developer 2026-08-21 Task 3.4
report): ``sourceFileChecksums`` on the commit PATCH is documented optional
and is omitted here; whether Apple's downstream TestFlight processing after
a ``buildUploads`` delivery is fully equivalent to an altool/Transporter
delivery is not asserted anywhere in the fetched docs.

Invoked as a subprocess by ``archive-upload-ios.sh``, which owns all
candidate ledger/receipt/reconciliation state; this module owns only the
transport and never mutates release-state files itself.
"""

from __future__ import annotations

import argparse
import sys
import time
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from typing import Any
from urllib.parse import quote

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _asc_api import ASCClient, ASCError, make_token_provider  # noqa: E402

BUNDLE_ID = "com.zerodelta.gradus.ios"
PLATFORM = "IOS"
ASSET_TYPE = "ASSET"
IPA_UTI = "com.apple.ipa"
DEFAULT_INGESTION_TIMEOUT_SECONDS = 10 * 60
DEFAULT_INGESTION_POLL_INTERVAL_SECONDS = 10
_TERMINAL_STATES = frozenset({"COMPLETE", "FAILED"})


class BuildUploadError(RuntimeError):
    """Raised for any non-retryable failure in the build-upload flow."""


def _int_field(mapping: Mapping[str, Any], key: str, *, default: int | None) -> int | None:
    value = mapping.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        return default
    return value


def _resource_id(response: Mapping[str, Any] | None) -> str | None:
    if not isinstance(response, Mapping):
        return None
    data = response.get("data")
    if not isinstance(data, Mapping):
        return None
    resource_id = data.get("id")
    return resource_id if isinstance(resource_id, str) and resource_id else None


def resolve_app_id(client: ASCClient, bundle_id: str = BUNDLE_ID) -> str:
    """Look up the numeric ASC app id for ``bundle_id``.

    Mirrors ``allocate_identity.py``'s ``_one_app`` field for field: a bundle
    ID must resolve to exactly one app before any release step trusts it.
    """
    payload = client.request("GET", f"/apps?filter[bundleId]={quote(bundle_id, safe='')}")
    if not isinstance(payload, Mapping) or not isinstance(payload.get("data"), list):
        raise BuildUploadError("app-response-invalid")
    entries = payload["data"]
    if len(entries) != 1 or not isinstance(entries[0], Mapping):
        raise BuildUploadError("app-identity-ambiguous")
    app_id = entries[0].get("id")
    attributes = entries[0].get("attributes")
    if (
        not isinstance(app_id, str)
        or not app_id
        or not isinstance(attributes, Mapping)
        or attributes.get("bundleId") != bundle_id
    ):
        raise BuildUploadError("app-identity-invalid")
    return app_id


def reserve_build_upload(client: ASCClient, app_id: str, marketing_version: str, build: str) -> str:
    body = {
        "data": {
            "type": "buildUploads",
            "attributes": {
                "cfBundleShortVersionString": marketing_version,
                "cfBundleVersion": str(build),
                "platform": PLATFORM,
            },
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }
    }
    # Not idempotent: retrying a reserve after an ambiguous failure could
    # create a second buildUpload record for the same build.
    response = client.request("POST", "/buildUploads", body, idempotent=False)
    upload_id = _resource_id(response)
    if upload_id is None:
        raise BuildUploadError("build-upload-reservation-invalid")
    return upload_id


def reserve_build_upload_file(
    client: ASCClient, build_upload_id: str, file_name: str, file_size: int
) -> tuple[str, list[Mapping[str, Any]]]:
    body = {
        "data": {
            "type": "buildUploadFiles",
            "attributes": {
                "assetType": ASSET_TYPE,
                "fileName": file_name,
                "fileSize": file_size,
                "uti": IPA_UTI,
            },
            "relationships": {
                "buildUpload": {"data": {"type": "buildUploads", "id": build_upload_id}}
            },
        }
    }
    response = client.request("POST", "/buildUploadFiles", body, idempotent=False)
    file_id = _resource_id(response)
    operations: Any = None
    if isinstance(response, Mapping):
        data = response.get("data")
        if isinstance(data, Mapping):
            attributes = data.get("attributes")
            if isinstance(attributes, Mapping):
                operations = attributes.get("uploadOperations")
    if file_id is None or not isinstance(operations, list) or not operations:
        raise BuildUploadError("build-upload-file-reservation-invalid")
    return file_id, operations


def transfer_chunks(
    client: ASCClient,
    ipa_path: Path,
    operations: Sequence[Mapping[str, Any]],
    *,
    on_progress: Callable[[str], None],
) -> None:
    """PUT every Apple-issued chunk, in ``partNumber`` order, with live progress.

    A blocking multi-minute network transfer with no output is exactly the
    "silent wait" this codebase's progress-visibility rule exists to forbid;
    altool's own streamed output satisfied it incidentally, so the
    replacement must satisfy it explicitly.
    """
    ordered = sorted(operations, key=lambda op: _int_field(op, "partNumber", default=0) or 0)
    total = len(ordered)
    total_bytes = sum(_int_field(op, "length", default=0) or 0 for op in ordered)
    sent_bytes = 0
    with ipa_path.open("rb") as handle:
        for index, operation in enumerate(ordered, start=1):
            url = operation.get("url")
            method = operation.get("method")
            headers = operation.get("requestHeaders")
            offset = _int_field(operation, "offset", default=None)
            length = _int_field(operation, "length", default=None)
            if (
                not isinstance(url, str)
                or not url
                or not isinstance(method, str)
                or not method
                or not isinstance(headers, list)
                or offset is None
                or length is None
            ):
                raise BuildUploadError("upload-operation-descriptor-invalid")
            handle.seek(offset)
            chunk = handle.read(length)
            if len(chunk) != length:
                raise BuildUploadError("ipa-shorter-than-declared-chunk")
            client.upload_bytes(url, method, headers, chunk, idempotent=True)
            sent_bytes += length
            percent = (sent_bytes / total_bytes * 100.0) if total_bytes else 100.0
            on_progress(
                f"Uploading part {index}/{total} ({percent:.1f}%, {sent_bytes}/{total_bytes} bytes)..."
            )


def commit_build_upload_file(client: ASCClient, file_id: str) -> None:
    body = {
        "data": {
            "type": "buildUploadFiles",
            "id": file_id,
            "attributes": {"uploaded": True},
        }
    }
    # Not idempotent: committing twice is not a transfer retry, it's a
    # second, unrequested state transition.
    client.request("PATCH", f"/buildUploadFiles/{quote(file_id, safe='')}", body, idempotent=False)


def poll_build_upload_state(
    client: ASCClient,
    build_upload_id: str,
    *,
    clock: Callable[[], float] = time.time,
    sleep: Callable[[float], None] = time.sleep,
    timeout: float = DEFAULT_INGESTION_TIMEOUT_SECONDS,
    interval: float = DEFAULT_INGESTION_POLL_INTERVAL_SECONDS,
    on_progress: Callable[[str], None] = lambda message: None,
) -> str:
    """Poll ``buildUploads/{id}`` until Apple reports COMPLETE or FAILED.

    This is transfer ingestion only (did Apple receive and accept the bytes
    as a well-formed package) -- distinct from, and much faster than, the
    post-ingestion review-style processing the existing ``processing``
    operation already polls for via ``Build.attributes.processingState``.
    """
    started = clock()
    deadline = started + timeout
    while True:
        response = client.request("GET", f"/buildUploads/{quote(build_upload_id, safe='')}")
        state = None
        if isinstance(response, Mapping):
            data = response.get("data")
            if isinstance(data, Mapping):
                attributes = data.get("attributes")
                if isinstance(attributes, Mapping):
                    raw_state = attributes.get("state")
                    state = raw_state.get("state") if isinstance(raw_state, Mapping) else raw_state
        if not isinstance(state, str) or not state:
            raise BuildUploadError("build-upload-state-unreadable")
        if state in _TERMINAL_STATES:
            return state
        on_progress(
            f"Waiting for Apple to finish ingesting the upload "
            f"(state={state}, {int(clock() - started)}s elapsed)..."
        )
        if clock() >= deadline:
            raise BuildUploadError("build-upload-state-timeout")
        sleep(interval)


def upload_build(
    ipa_path: Path,
    marketing_version: str,
    build: str,
    *,
    client: ASCClient | None = None,
    bundle_id: str = BUNDLE_ID,
    on_progress: Callable[[str], None] = lambda message: None,
    ingestion_timeout_seconds: float = DEFAULT_INGESTION_TIMEOUT_SECONDS,
    ingestion_poll_interval_seconds: float = DEFAULT_INGESTION_POLL_INTERVAL_SECONDS,
    clock: Callable[[], float] = time.time,
    sleep: Callable[[float], None] = time.sleep,
) -> str:
    """Upload ``ipa_path`` via Apple's REST build-uploads flow.

    Returns the ``buildUploads`` resource id on success. Raises
    ``BuildUploadError`` on any failure, including Apple reporting the
    ingested bytes as invalid (``state: FAILED``) -- callers must not treat a
    successful HTTP transfer as a successful delivery until this returns.
    """
    if client is None:
        client = ASCClient(make_token_provider())
    app_id = resolve_app_id(client, bundle_id)
    on_progress(f"Reserving build upload for {marketing_version} ({build})...")
    build_upload_id = reserve_build_upload(client, app_id, marketing_version, build)
    file_size = ipa_path.stat().st_size
    on_progress(f"Reserving upload for {ipa_path.name} ({file_size} bytes)...")
    file_id, operations = reserve_build_upload_file(
        client, build_upload_id, ipa_path.name, file_size
    )
    transfer_chunks(client, ipa_path, operations, on_progress=on_progress)
    on_progress("Committing upload...")
    commit_build_upload_file(client, file_id)
    on_progress("Waiting for Apple to confirm ingestion...")
    state = poll_build_upload_state(
        client,
        build_upload_id,
        clock=clock,
        sleep=sleep,
        timeout=ingestion_timeout_seconds,
        interval=ingestion_poll_interval_seconds,
        on_progress=on_progress,
    )
    if state != "COMPLETE":
        raise BuildUploadError(f"build-upload-state-{state.lower()}")
    return build_upload_id


def _parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Upload an .ipa to App Store Connect.")
    parser.add_argument("--ipa-path", required=True, type=Path)
    parser.add_argument("--marketing-version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--bundle-id", default=BUNDLE_ID)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    if not args.ipa_path.is_file():
        print(f"FAIL: ipa not found at {args.ipa_path}", file=sys.stderr)
        return 1

    def on_progress(message: str) -> None:
        print(message, flush=True)

    try:
        build_upload_id = upload_build(
            args.ipa_path,
            args.marketing_version,
            args.build,
            bundle_id=args.bundle_id,
            on_progress=on_progress,
        )
    except (BuildUploadError, ASCError) as error:
        print(f"FAIL: transport failed: {error}", file=sys.stderr)
        return 1
    # Kept in the "Delivery UUID: <value>" shape archive-upload-ios.sh's
    # receipt writer already knows how to parse. That field is optional
    # metadata on the receipt -- never part of the delivery-adoption match
    # (candidateId + build + artifactSha256 + result) -- so this is safe
    # even if Apple's buildUploads id format never matches the old sed
    # pattern the receipt writer inherited from altool's own output.
    print(f"Delivery UUID: {build_upload_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
