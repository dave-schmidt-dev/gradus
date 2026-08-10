"""Redacting, renewable App Store Connect HTTP primitives.

Secrets enter only through the environment supplied by the fixed BWS consumer.
This module never prints or persists credentials, bearer tokens, response bodies,
or tester data.  Callers may inject ``transport``, ``clock``, and ``sleep`` for
hermetic tests; the default transport is the standard-library ``urllib`` path.
"""

from __future__ import annotations

import hashlib
import json
import os
import time
import urllib.error
import urllib.request
from collections.abc import Callable, Mapping
from dataclasses import dataclass

API_BASE = "https://api.appstoreconnect.apple.com/v1"
DEFAULT_TOKEN_TTL_SECONDS = 1190
DEFAULT_TOKEN_RENEWAL_MARGIN_SECONDS = 60
DEFAULT_TIMEOUT_SECONDS = 30.0
DEFAULT_MAX_ATTEMPTS = 3
RETRYABLE_HTTP_STATUSES = frozenset({408, 409, 425, 429})
RECEIPT_FIELD_NAMES = frozenset({"request_id", "error_class", "retryable", "http_status"})


@dataclass(frozen=True)
class TokenRefreshEvent:
    """Non-secret metadata describing a JWT refresh."""

    generation: int
    issued_at: int
    expires_at: int

    def receipt_fields(self) -> dict[str, int]:
        return {
            "generation": self.generation,
            "issued_at": self.issued_at,
            "expires_at": self.expires_at,
        }


class TokenProvider:
    """Caches an ASC JWT and renews it before the configured expiry margin."""

    def __init__(
        self,
        private_key: str,
        key_id: str,
        issuer_id: str,
        *,
        clock: Callable[[], float] = time.time,
        encoder: Callable[..., str] | None = None,
        ttl_seconds: int = DEFAULT_TOKEN_TTL_SECONDS,
        renewal_margin_seconds: int = DEFAULT_TOKEN_RENEWAL_MARGIN_SECONDS,
        on_refresh: Callable[[TokenRefreshEvent], None] | None = None,
    ) -> None:
        if ttl_seconds <= 0 or renewal_margin_seconds < 0 or renewal_margin_seconds >= ttl_seconds:
            raise ValueError("invalid token lifetime configuration")
        self._private_key = private_key
        self._key_id = key_id
        self._issuer_id = issuer_id
        self._clock = clock
        self._encoder = _encode_jwt if encoder is None else encoder
        self._ttl_seconds = ttl_seconds
        self._renewal_margin_seconds = renewal_margin_seconds
        self._on_refresh = on_refresh
        self._token: str | None = None
        self._expires_at = 0
        self._events: list[TokenRefreshEvent] = []

    @classmethod
    def from_environment(cls, **kwargs: object) -> TokenProvider:
        return cls(
            os.environ["APP_STORE_CONNECT_API_KEY"],
            os.environ["APP_STORE_CONNECT_KEY_ID"],
            os.environ["APP_STORE_CONNECT_ISSUER_ID"],
            **kwargs,
        )

    @property
    def refresh_events(self) -> tuple[TokenRefreshEvent, ...]:
        return tuple(self._events)

    def token(self) -> str:
        now = int(self._clock())
        if self._token is None or now >= self._expires_at - self._renewal_margin_seconds:
            expires_at = now + self._ttl_seconds
            token = self._encoder(
                {
                    "iss": self._issuer_id,
                    "iat": now,
                    "exp": expires_at,
                    "aud": "appstoreconnect-v1",
                },
                self._private_key,
                algorithm="ES256",
                headers={"kid": self._key_id, "typ": "JWT"},
            )
            self._token = token.decode() if isinstance(token, bytes) else token
            self._expires_at = expires_at
            event = TokenRefreshEvent(len(self._events) + 1, now, expires_at)
            self._events.append(event)
            if self._on_refresh is not None:
                self._on_refresh(event)
        return self._token


class _StaticTokenProvider:
    def __init__(self, token: str) -> None:
        self._token = token

    def token(self) -> str:
        return self._token


def _encode_jwt(*args: object, **kwargs: object) -> str:
    """Import PyJWT only when a live credential-bearing token is requested."""

    import jwt

    return jwt.encode(*args, **kwargs)


@dataclass(frozen=True)
class HTTPResponse:
    """Transport response shape, intentionally keeping diagnostics out of receipts."""

    status: int
    headers: Mapping[str, str]
    body: bytes


@dataclass(frozen=True)
class ASCOutcome:
    """Only fields permitted in a persisted or displayed ASC receipt."""

    request_id: str | None
    error_class: str
    retryable: bool
    http_status: int | None

    def receipt_fields(self) -> dict[str, str | bool | int | None]:
        return {
            "request_id": self.request_id,
            "error_class": self.error_class,
            "retryable": self.retryable,
            "http_status": self.http_status,
        }


class ASCError(RuntimeError):
    """Base exception whose message intentionally excludes server diagnostics."""

    def __init__(self, outcome: ASCOutcome) -> None:
        self.outcome = outcome
        status = "transport" if outcome.http_status is None else str(outcome.http_status)
        request = "" if outcome.request_id is None else f", request {outcome.request_id}"
        super().__init__(f"ASC {outcome.error_class} (HTTP {status}{request})")

    def receipt_fields(self) -> dict[str, str | bool | int | None]:
        return self.outcome.receipt_fields()


class RetryableASCError(ASCError):
    """A request may be retried when its operation is declared idempotent."""


class PermanentASCError(ASCError):
    """A request must not be retried automatically."""


class ASCTimeoutError(RetryableASCError):
    """A finite transport timeout expired."""


Transport = Callable[[urllib.request.Request, float], HTTPResponse]


def _redacted_request_id(headers: Mapping[str, str] | None) -> str | None:
    if not headers:
        return None
    normalized = {str(key).lower(): str(value) for key, value in headers.items()}
    raw = normalized.get("x-request-id") or normalized.get("x-apple-request-uuid")
    if not raw:
        return None
    return "req_" + hashlib.sha256(raw.encode("utf-8")).hexdigest()[:12]


def _http_error(status: int, headers: Mapping[str, str] | None = None) -> ASCError:
    retryable = status in RETRYABLE_HTTP_STATUSES or 500 <= status <= 599
    error_class = f"http_{status}" if 400 <= status <= 599 else "unexpected_status"
    outcome = ASCOutcome(_redacted_request_id(headers), error_class, retryable, status)
    return RetryableASCError(outcome) if retryable else PermanentASCError(outcome)


def _transport_error(error_class: str, *, timeout: bool = False) -> ASCError:
    outcome = ASCOutcome(None, error_class, True, None)
    return ASCTimeoutError(outcome) if timeout else RetryableASCError(outcome)


def _default_transport(request: urllib.request.Request, timeout_seconds: float) -> HTTPResponse:
    with urllib.request.urlopen(request, timeout=timeout_seconds) as response:
        return HTTPResponse(response.status, dict(response.headers.items()), response.read())


class ASCClient:
    """Injectable ASC JSON client with bounded retries and safe exceptions."""

    def __init__(
        self,
        token_provider: TokenProvider | _StaticTokenProvider,
        *,
        transport: Transport = _default_transport,
        timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
        max_attempts: int = DEFAULT_MAX_ATTEMPTS,
        sleep: Callable[[float], None] = time.sleep,
        retry_delay_seconds: float = 0.0,
    ) -> None:
        if timeout_seconds <= 0:
            raise ValueError("timeout_seconds must be positive")
        if max_attempts <= 0:
            raise ValueError("max_attempts must be positive")
        self._token_provider = token_provider
        self._transport = transport
        self._timeout_seconds = timeout_seconds
        self._max_attempts = max_attempts
        self._sleep = sleep
        self._retry_delay_seconds = retry_delay_seconds

    def request(
        self,
        method: str,
        path: str,
        body: dict | None = None,
        *,
        idempotent: bool | None = None,
    ) -> dict | None:
        method = method.upper()
        retry_allowed = method == "GET" if idempotent is None else idempotent
        url = path if path.startswith("http") else f"{API_BASE}{path}"
        payload = json.dumps(body).encode() if body is not None else None
        for attempt in range(self._max_attempts):
            request = urllib.request.Request(url, data=payload, method=method)
            request.add_header("Authorization", f"Bearer {self._token_provider.token()}")
            if payload is not None:
                request.add_header("Content-Type", "application/json")
            try:
                response = self._transport(request, self._timeout_seconds)
                if not 200 <= response.status <= 299:
                    raise _http_error(response.status, response.headers)
                try:
                    return json.loads(response.body) if response.body else None
                except (TypeError, ValueError) as error:
                    del error
                    raise PermanentASCError(
                        ASCOutcome(None, "invalid_response", False, response.status)
                    )
            except urllib.error.HTTPError as error:
                failure = _http_error(error.code, error.headers)
            except TimeoutError:
                failure = _transport_error("timeout", timeout=True)
            except urllib.error.URLError:
                failure = _transport_error("network_error")
            except ASCError as caught:
                failure = caught
            if (
                not failure.outcome.retryable
                or not retry_allowed
                or attempt + 1 >= self._max_attempts
            ):
                raise failure
            if self._retry_delay_seconds:
                self._sleep(self._retry_delay_seconds)
        raise AssertionError("retry loop exhausted unexpectedly")


def make_token_provider(**kwargs: object) -> TokenProvider:
    """Create the renewable provider used by new long-lived ASC workflows."""

    return TokenProvider.from_environment(**kwargs)


def make_token() -> str:
    """Compatibility helper for existing callers that expect a one-shot token string."""

    return make_token_provider().token()


def call(
    token: str | TokenProvider,
    method: str,
    path: str,
    body: dict | None = None,
    *,
    transport: Transport = _default_transport,
    timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
    max_attempts: int = DEFAULT_MAX_ATTEMPTS,
    sleep: Callable[[float], None] = time.sleep,
    retry_delay_seconds: float = 0.0,
    idempotent: bool | None = None,
) -> dict | None:
    """Compatibility entry point; accepts either a legacy token or TokenProvider."""

    provider = token if isinstance(token, TokenProvider) else _StaticTokenProvider(token)
    return ASCClient(
        provider,
        transport=transport,
        timeout_seconds=timeout_seconds,
        max_attempts=max_attempts,
        sleep=sleep,
        retry_delay_seconds=retry_delay_seconds,
    ).request(method, path, body, idempotent=idempotent)
