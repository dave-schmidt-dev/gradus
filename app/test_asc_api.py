"""Hermetic security and behavior tests for the ASC client."""

from __future__ import annotations

import json
import urllib.error

import pytest
from _asc_api import (
    RECEIPT_FIELD_NAMES,
    ASCClient,
    ASCTimeoutError,
    HTTPResponse,
    PermanentASCError,
    RetryableASCError,
    TokenProvider,
)


class Clock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now


def test_long_poll_refreshes_twice_without_token_material(
    capsys: pytest.CaptureFixture[str],
) -> None:
    clock = Clock()
    events = []
    generated = iter(("token-marker-one", "token-marker-two"))
    provider = TokenProvider(
        "private-key-marker",
        "key-marker",
        "issuer-marker",
        clock=clock,
        encoder=lambda *args, **kwargs: next(generated),
        ttl_seconds=100,
        renewal_margin_seconds=10,
        on_refresh=events.append,
    )
    responses = iter(
        (HTTPResponse(200, {}, b'{"data": []}'), HTTPResponse(200, {}, b'{"data": []}'))
    )

    def transport(request, timeout):
        del request, timeout
        return next(responses)

    client = ASCClient(provider, transport=transport)
    assert client.request("GET", "/builds") == {"data": []}
    clock.now = 91
    assert client.request("GET", "/builds") == {"data": []}

    receipt = json.dumps([event.receipt_fields() for event in events], sort_keys=True)
    captured_output = capsys.readouterr()
    captured = captured_output.out + captured_output.err + receipt
    assert [event.generation for event in events] == [1, 2]
    assert "token-marker" not in captured
    assert "private-key-marker" not in captured
    assert "Bearer" not in captured


def test_receipt_and_output_are_redacted_for_permanent_response(
    capsys: pytest.CaptureFixture[str],
) -> None:
    body_marker = b'{"email":"tester-address-marker","detail":"raw-body-marker"}'

    def transport(request, timeout):
        del request, timeout
        return HTTPResponse(400, {"X-Request-Id": "raw-request-marker"}, body_marker)

    client = ASCClient(
        TokenProvider(
            "key-marker", "id-marker", "issuer-marker", encoder=lambda *a, **k: "token-marker"
        ),
        transport=transport,
    )
    with pytest.raises(PermanentASCError) as raised:
        client.request("GET", "/groups")
    receipt_fields = raised.value.receipt_fields()
    receipt = json.dumps(receipt_fields, sort_keys=True) + str(raised.value)
    captured_output = capsys.readouterr()
    captured = captured_output.out + captured_output.err + receipt
    assert raised.value.outcome.error_class == "http_400"
    assert raised.value.outcome.request_id != "raw-request-marker"
    assert set(receipt_fields) == RECEIPT_FIELD_NAMES
    for forbidden in (
        "tester-address-marker",
        "raw-body-marker",
        "key-marker",
        "token-marker",
        "Bearer",
    ):
        assert forbidden not in captured


def test_retryable_and_permanent_classification_without_post_retry() -> None:
    attempts = []

    def retryable_transport(request, timeout):
        del timeout
        attempts.append(request.method)
        return HTTPResponse(429, {}, b"response-marker")

    client = ASCClient(
        TokenProvider("key", "id", "issuer", encoder=lambda *a, **k: "token"),
        transport=retryable_transport,
        max_attempts=2,
    )
    with pytest.raises(RetryableASCError) as raised:
        client.request("GET", "/builds")
    assert raised.value.outcome.retryable is True
    assert attempts == ["GET", "GET"]

    attempts.clear()
    with pytest.raises(RetryableASCError):
        client.request("POST", "/builds", {"data": {}})
    assert attempts == ["POST"]


def test_timeout_is_nonzero_typed_failure_with_injected_timeout() -> None:
    timeouts = []

    def timeout_transport(request, timeout):
        del request
        timeouts.append(timeout)
        raise TimeoutError("timeout-body-marker")

    client = ASCClient(
        TokenProvider("key", "id", "issuer", encoder=lambda *a, **k: "token"),
        transport=timeout_transport,
        timeout_seconds=2.5,
        max_attempts=2,
    )
    with pytest.raises(ASCTimeoutError) as raised:
        client.request("GET", "/builds")
    assert raised.value.outcome.error_class == "timeout"
    assert timeouts == [2.5, 2.5]


def test_url_error_is_retryable_without_exposing_reason() -> None:
    def transport(request, timeout):
        del request, timeout
        raise urllib.error.URLError("network-detail-marker")

    client = ASCClient(
        TokenProvider("key", "id", "issuer", encoder=lambda *a, **k: "token"),
        transport=transport,
        max_attempts=1,
    )
    with pytest.raises(RetryableASCError) as raised:
        client.request("GET", "/builds")
    assert raised.value.outcome.error_class == "network_error"
