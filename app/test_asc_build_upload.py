"""Hermetic tests for the in-process App Store Connect build-upload transport.

No test in this file performs real network I/O: every ``ASCClient`` is built
with an injected ``transport`` callable, matching ``test_asc_api.py``'s
convention. These tests are the "fixture-mode dry run" for Task 3.4 --
they exercise the full reserve -> transfer -> commit -> poll flow against an
in-memory fake App Store Connect, with assertions on exactly which HTTP
requests were made and never touching Apple's servers or the filesystem
beyond a throwaway temp .ipa.
"""

from __future__ import annotations

import json

import pytest
from _asc_api import ASCClient, ASCTimeoutError, HTTPResponse, TokenProvider
from asc_build_upload import (
    BUNDLE_ID,
    BuildUploadError,
    commit_build_upload_file,
    main,
    poll_build_upload_state,
    reserve_build_upload,
    reserve_build_upload_file,
    resolve_app_id,
    transfer_chunks,
    upload_build,
)


def _client(transport) -> ASCClient:
    return ASCClient(
        TokenProvider(
            "key-marker", "id-marker", "issuer-marker", encoder=lambda *a, **k: "token-marker"
        ),
        transport=transport,
    )


class Clock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now


def _json(status: int, payload: object) -> HTTPResponse:
    return HTTPResponse(status, {}, json.dumps(payload).encode())


def test_resolve_app_id_requires_exactly_one_matching_bundle() -> None:
    def transport(request, timeout):
        del timeout
        assert "filter[bundleId]=" + BUNDLE_ID in request.full_url
        return _json(200, {"data": [{"id": "999", "attributes": {"bundleId": BUNDLE_ID}}]})

    assert resolve_app_id(_client(transport)) == "999"


def test_resolve_app_id_rejects_ambiguous_response() -> None:
    def transport(request, timeout):
        del request, timeout
        return _json(200, {"data": [{"id": "1"}, {"id": "2"}]})

    with pytest.raises(BuildUploadError, match="app-identity-ambiguous"):
        resolve_app_id(_client(transport))


def test_reserve_build_upload_posts_expected_body_and_is_not_retried() -> None:
    seen = []

    def transport(request, timeout):
        del timeout
        seen.append(request.get_method())
        assert request.full_url.endswith("/buildUploads")
        body = json.loads(request.data)
        assert body["data"]["attributes"] == {
            "cfBundleShortVersionString": "2.1.0",
            "cfBundleVersion": "42",
            "platform": "IOS",
        }
        assert body["data"]["relationships"]["app"]["data"]["id"] == "999"
        return HTTPResponse(500, {}, b"")  # non-2xx: must not be retried (idempotent=False)

    with pytest.raises(Exception):
        reserve_build_upload(_client(transport), "999", "2.1.0", "42")
    assert seen == ["POST"]  # a single attempt, never retried


def test_reserve_build_upload_file_returns_operations() -> None:
    operations = [
        {
            "url": "https://storage.example/part",
            "method": "PUT",
            "requestHeaders": [{"name": "Content-Type", "value": "application/octet-stream"}],
            "offset": 0,
            "length": 10,
            "partNumber": 1,
        }
    ]

    def transport(request, timeout):
        del timeout
        assert request.full_url.endswith("/buildUploadFiles")
        body = json.loads(request.data)
        assert body["data"]["attributes"] == {
            "assetType": "ASSET",
            "fileName": "Gradus.ipa",
            "fileSize": 10,
            "uti": "com.apple.ipa",
        }
        return _json(
            201, {"data": {"id": "file-1", "attributes": {"uploadOperations": operations}}}
        )

    file_id, returned_operations = reserve_build_upload_file(
        _client(transport), "upload-1", "Gradus.ipa", 10
    )
    assert file_id == "file-1"
    assert returned_operations == operations


def test_transfer_chunks_sends_exact_byte_ranges_without_bearer_token(tmp_path) -> None:
    ipa_path = tmp_path / "Gradus.ipa"
    ipa_path.write_bytes(b"0123456789")
    operations = [
        {
            "url": "https://storage.example/part2",
            "method": "PUT",
            "requestHeaders": [{"name": "X-Marker", "value": "second"}],
            "offset": 5,
            "length": 5,
            "partNumber": 2,
        },
        {
            "url": "https://storage.example/part1",
            "method": "PUT",
            "requestHeaders": [{"name": "X-Marker", "value": "first"}],
            "offset": 0,
            "length": 5,
            "partNumber": 1,
        },
    ]
    calls = []

    def transport(request, timeout):
        del timeout
        headers = {name.lower(): value for name, value in request.header_items()}
        assert "authorization" not in headers
        calls.append((request.full_url, headers.get("x-marker"), request.data))
        return HTTPResponse(200, {}, b"")

    progress = []
    transfer_chunks(_client(transport), ipa_path, operations, on_progress=progress.append)

    # Sent in partNumber order (1 before 2) despite the input list being reversed.
    assert calls == [
        ("https://storage.example/part1", "first", b"01234"),
        ("https://storage.example/part2", "second", b"56789"),
    ]
    assert len(progress) == 2
    assert "100.0%" in progress[-1]


def test_transfer_chunks_rejects_a_short_read(tmp_path) -> None:
    ipa_path = tmp_path / "Gradus.ipa"
    ipa_path.write_bytes(b"short")
    operations = [
        {
            "url": "https://storage.example/part1",
            "method": "PUT",
            "requestHeaders": [],
            "offset": 0,
            "length": 999,
            "partNumber": 1,
        }
    ]

    def transport(request, timeout):
        raise AssertionError("must not send a request for an invalid declared range")

    with pytest.raises(BuildUploadError, match="ipa-shorter-than-declared-chunk"):
        transfer_chunks(_client(transport), ipa_path, operations, on_progress=lambda message: None)


def test_commit_build_upload_file_patches_uploaded_true() -> None:
    def transport(request, timeout):
        del timeout
        assert request.get_method() == "PATCH"
        assert request.full_url.endswith("/buildUploadFiles/file-1")
        body = json.loads(request.data)
        assert body["data"] == {
            "type": "buildUploadFiles",
            "id": "file-1",
            "attributes": {"uploaded": True},
        }
        return HTTPResponse(200, {}, b"{}")

    commit_build_upload_file(_client(transport), "file-1")


def test_poll_build_upload_state_returns_on_first_terminal_state() -> None:
    def transport(request, timeout):
        del timeout
        assert request.full_url.endswith("/buildUploads/upload-1")
        return _json(200, {"data": {"id": "upload-1", "attributes": {"state": "COMPLETE"}}})

    assert (
        poll_build_upload_state(_client(transport), "upload-1", sleep=lambda seconds: None)
        == "COMPLETE"
    )


def test_poll_build_upload_state_reports_progress_while_waiting() -> None:
    states = iter(["PROCESSING", "PROCESSING", "COMPLETE"])

    def transport(request, timeout):
        del timeout
        return _json(200, {"data": {"id": "upload-1", "attributes": {"state": next(states)}}})

    progress = []
    result = poll_build_upload_state(
        _client(transport), "upload-1", sleep=lambda seconds: None, on_progress=progress.append
    )
    assert result == "COMPLETE"
    assert len(progress) == 2
    assert all("state=PROCESSING" in message for message in progress)


def test_poll_build_upload_state_times_out_without_hanging() -> None:
    clock = Clock()
    sleeps = []

    def advancing_sleep(seconds: float) -> None:
        sleeps.append(seconds)
        clock.now += seconds

    def transport(request, timeout):
        del request, timeout
        return _json(200, {"data": {"id": "upload-1", "attributes": {"state": "PROCESSING"}}})

    with pytest.raises(BuildUploadError, match="build-upload-state-timeout"):
        poll_build_upload_state(
            _client(transport),
            "upload-1",
            clock=clock,
            sleep=advancing_sleep,
            timeout=25,
            interval=10,
        )
    assert sleeps  # the loop actually waited between polls rather than busy-looping


def test_poll_build_upload_state_stops_immediately_on_failed() -> None:
    def transport(request, timeout):
        del request, timeout
        return _json(200, {"data": {"id": "upload-1", "attributes": {"state": "FAILED"}}})

    assert (
        poll_build_upload_state(_client(transport), "upload-1", sleep=lambda seconds: None)
        == "FAILED"
    )


def test_upload_build_end_to_end_reserve_transfer_commit_poll(tmp_path) -> None:
    """The full flow, in order, against an in-memory fake App Store Connect."""

    ipa_path = tmp_path / "Gradus.ipa"
    ipa_bytes = b"fixture-ipa-bytes"
    ipa_path.write_bytes(ipa_bytes)
    calls = []
    poll_count = {"n": 0}

    def transport(request, timeout):
        del timeout
        method = request.get_method()
        url = request.full_url
        headers = {name.lower(): value for name, value in request.header_items()}
        calls.append((method, url))
        if "apps?filter[bundleId]=" in url:
            return _json(200, {"data": [{"id": "999", "attributes": {"bundleId": BUNDLE_ID}}]})
        if url.endswith("/buildUploads") and method == "POST":
            assert "bearer token-marker" == headers.get("authorization", "").lower()
            return _json(
                201, {"data": {"id": "upload-1", "attributes": {"state": "AWAITING_UPLOAD"}}}
            )
        if url.endswith("/buildUploadFiles") and method == "POST":
            return _json(
                201,
                {
                    "data": {
                        "id": "file-1",
                        "attributes": {
                            "uploadOperations": [
                                {
                                    "url": "https://storage.example/chunk0",
                                    "method": "PUT",
                                    "requestHeaders": [{"name": "X-Fixture", "value": "1"}],
                                    "offset": 0,
                                    "length": len(ipa_bytes),
                                    "partNumber": 1,
                                }
                            ]
                        },
                    },
                },
            )
        if url == "https://storage.example/chunk0" and method == "PUT":
            assert "authorization" not in headers
            assert request.data == ipa_bytes
            return HTTPResponse(200, {}, b"")
        if url.endswith("/buildUploadFiles/file-1") and method == "PATCH":
            return HTTPResponse(200, {}, b"{}")
        if url.endswith("/buildUploads/upload-1") and method == "GET":
            poll_count["n"] += 1
            state = "PROCESSING" if poll_count["n"] == 1 else "COMPLETE"
            return _json(200, {"data": {"id": "upload-1", "attributes": {"state": state}}})
        raise AssertionError(f"unexpected request: {method} {url}")

    progress = []
    build_upload_id = upload_build(
        ipa_path,
        "2.1.0",
        "42",
        client=_client(transport),
        on_progress=progress.append,
        sleep=lambda seconds: None,
    )

    assert build_upload_id == "upload-1"
    assert poll_count["n"] == 2  # polled past a non-terminal state before completing
    methods_in_order = [method for method, _ in calls]
    assert methods_in_order == ["GET", "POST", "POST", "PUT", "PATCH", "GET", "GET"]
    assert any("100.0%" in message for message in progress)
    assert any("Committing upload" in message for message in progress)


def test_upload_build_raises_when_apple_reports_failed_ingestion(tmp_path) -> None:
    ipa_path = tmp_path / "Gradus.ipa"
    ipa_path.write_bytes(b"x")

    def transport(request, timeout):
        del timeout
        url = request.full_url
        method = request.get_method()
        if "apps?filter[bundleId]=" in url:
            return _json(200, {"data": [{"id": "999", "attributes": {"bundleId": BUNDLE_ID}}]})
        if url.endswith("/buildUploads") and method == "POST":
            return _json(
                201, {"data": {"id": "upload-1", "attributes": {"state": "AWAITING_UPLOAD"}}}
            )
        if url.endswith("/buildUploadFiles") and method == "POST":
            return _json(
                201,
                {
                    "data": {
                        "id": "file-1",
                        "attributes": {
                            "uploadOperations": [
                                {
                                    "url": "https://storage.example/chunk0",
                                    "method": "PUT",
                                    "requestHeaders": [],
                                    "offset": 0,
                                    "length": 1,
                                    "partNumber": 1,
                                }
                            ]
                        },
                    }
                },
            )
        if method == "PUT":
            return HTTPResponse(200, {}, b"")
        if method == "PATCH":
            return HTTPResponse(200, {}, b"{}")
        if method == "GET" and url.endswith("/buildUploads/upload-1"):
            return _json(200, {"data": {"id": "upload-1", "attributes": {"state": "FAILED"}}})
        raise AssertionError(f"unexpected request: {method} {url}")

    with pytest.raises(BuildUploadError, match="build-upload-state-failed"):
        upload_build(ipa_path, "2.1.0", "42", client=_client(transport), sleep=lambda seconds: None)


def test_main_reports_failure_without_leaking_credentials(tmp_path, monkeypatch, capsys) -> None:
    missing_ipa = tmp_path / "missing.ipa"
    monkeypatch.setattr(
        "sys.argv",
        [
            "asc_build_upload.py",
            "--ipa-path",
            str(missing_ipa),
            "--marketing-version",
            "2.1.0",
            "--build",
            "42",
        ],
    )
    exit_code = main()
    captured = capsys.readouterr()
    assert exit_code == 1
    assert "FAIL: ipa not found" in captured.err
    assert "AuthKey" not in captured.out and "AuthKey" not in captured.err


def test_main_never_prints_the_api_key_on_transport_timeout(tmp_path, monkeypatch, capsys) -> None:
    ipa_path = tmp_path / "Gradus.ipa"
    ipa_path.write_bytes(b"x")

    def timeout_transport(request, timeout):
        del request, timeout
        raise TimeoutError("timeout-body-marker")

    monkeypatch.setenv("APP_STORE_CONNECT_API_KEY", "fixture-private-key-marker")
    monkeypatch.setenv("APP_STORE_CONNECT_KEY_ID", "fixture-key-id")
    monkeypatch.setenv("APP_STORE_CONNECT_ISSUER_ID", "fixture-issuer")
    monkeypatch.setattr(
        "asc_build_upload.make_token_provider", lambda: TokenProvider.from_environment()
    )
    monkeypatch.setattr("asc_build_upload.ASCClient", lambda provider: _client(timeout_transport))
    monkeypatch.setattr(
        "sys.argv",
        [
            "asc_build_upload.py",
            "--ipa-path",
            str(ipa_path),
            "--marketing-version",
            "2.1.0",
            "--build",
            "42",
        ],
    )

    exit_code = main()
    captured = capsys.readouterr()
    assert exit_code == 1
    assert "FAIL: transport failed:" in captured.err
    for forbidden in (
        "fixture-private-key-marker",
        "fixture-key-id",
        "fixture-issuer",
        "timeout-body-marker",
    ):
        assert forbidden not in captured.out
        assert forbidden not in captured.err
    assert ASCTimeoutError  # imported and available for future direct-raise assertions
