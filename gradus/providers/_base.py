"""Shared provider utilities."""

from __future__ import annotations

import json
import logging
import os
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

_HEADLESS = False


def _private_cache_path(filename: str) -> Path:
    """Return one provider cache path from the process runtime policy."""
    from ..paths import RUNTIME_PATHS

    return RUNTIME_PATHS.private_cache_path(filename)


def set_headless(value: bool) -> None:
    global _HEADLESS
    _HEADLESS = bool(value)


def _is_headless() -> bool:
    return _HEADLESS


@dataclass(slots=True)
class ProviderSnapshot:
    name: str
    ok: bool
    source: str
    data: dict[str, Any] | None = None
    error: str | None = None
    cached_since: datetime | None = None
    debug_detail: str | None = None


class ProbeFailure(RuntimeError):
    def __init__(self, message: str, raw_text: str) -> None:
        super().__init__(message)
        self.raw_text = raw_text


def _http_json(
    url: str,
    *,
    method: str = "GET",
    headers: dict[str, str] | None = None,
    body: bytes | None = None,
    timeout: int = 15,
) -> dict[str, Any]:
    import urllib.error
    import urllib.request

    from ..tls import default_ssl_context

    req = urllib.request.Request(url, data=body, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=default_ssl_context()) as resp:
            raw = resp.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        try:
            err_body = exc.read().decode("utf-8", errors="replace")
        except Exception:
            err_body = ""
        raise ProbeFailure(f"HTTP {exc.code}", err_body) from exc
    except urllib.error.URLError as exc:
        raise ProbeFailure(f"Network error: {exc.reason}", f"{method} {url}") from exc
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ProbeFailure("Invalid JSON response", raw[:500]) from exc


def _format_reset_time(value: str | int | float | None) -> str | None:
    if value is None:
        return None
    try:
        if isinstance(value, str):
            target = datetime.fromisoformat(value.replace("Z", "+00:00"))
        else:
            secs = float(value) / 1000.0 if float(value) > 1e12 else float(value)
            target = datetime.fromtimestamp(secs, tz=timezone.utc)
        return f"Resets {target.astimezone().strftime('%b %d at %I:%M %p')}"
    except (ValueError, OSError, OverflowError):
        return None


def _debug_dump_path(name: str) -> Path:
    safe_name = name.lower().replace(" ", "_")
    return Path("/tmp") / f"gradus_{safe_name}_capture.txt"


def _write_debug_dump(name: str, raw_text: str) -> None:
    if _is_headless():
        return
    _write_private(_debug_dump_path(name), raw_text, harden_parent=False)


def _write_private(path: Path, text: str, *, harden_parent: bool = True) -> None:
    if _is_headless():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    if harden_parent:
        os.chmod(path.parent, 0o700)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _remove_private(path: Path) -> None:
    if _is_headless():
        return
    try:
        path.unlink(missing_ok=True)
    except OSError as exc:
        log.warning("Failed to delete credential cache at %s: %s", path, exc)


def _harden_existing(path: Path) -> None:
    if _is_headless():
        return
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def _auth_required_message(interactive: str) -> str:
    return "auth required: no cached credentials" if _is_headless() else interactive


def _is_jwt_expired(token: str, leeway_seconds: int = 60) -> bool:
    import base64
    import time

    try:
        payload_b64 = token.split(".")[1]
    except IndexError:
        return False
    padded = payload_b64 + "=" * (-len(payload_b64) % 4)
    try:
        payload = json.loads(base64.urlsafe_b64decode(padded))
    except (ValueError, json.JSONDecodeError):
        return False
    exp = payload.get("exp")
    if not isinstance(exp, (int, float)):
        return False
    return time.time() + leeway_seconds >= exp


class _AuthRejected(Exception):
    """Internal signal: the console rejected the session cookie."""


_PROVIDER_REGISTRY: dict[str, type] = {}


def register(name: str):
    def _decorator(cls):
        _PROVIDER_REGISTRY[name] = cls
        return cls

    return _decorator


_REGISTRATION_ORDER = ("Codex", "Claude", "Antigravity", "Copilot", "Cursor", "OpenCode Go", "Vibe")


def _canonical_providers() -> tuple[str, ...]:
    return tuple(name for name in _REGISTRATION_ORDER if name in _PROVIDER_REGISTRY)


def _safe_probe_error(exc: BaseException) -> str:
    """Map an unexpected probe exception to a surface-safe message.

    Classified by exception **type**, never by message content. The returned
    string is published to CloudKit and rendered verbatim on iPhone and iPad,
    and an exception message can carry a bearer token, a signed URL, or
    subprocess output -- ``AntigravityProvider._load_keychain_token`` embeds
    `security` output directly in a ``FileNotFoundError``. Type names carry no
    such payload. Full text stays on the ``--debug`` channel.

    The wording is deliberate: ``snapshot._is_transient_probe_error`` matches
    the markers ``"timed out"`` and ``"network error"``, so these messages let
    ``_merge_with_previous`` serve the last-known-good reading instead of
    publishing a failure card for a blip that succeeds on the next cycle.

    Args:
        exc: The exception raised by a provider's ``fetch()``/``to_dict()``.

    Returns:
        A message safe to publish, chosen so retryable failures classify as
        transient. Anything unrecognized stays the opaque generic string.
    """
    import subprocess
    import urllib.error

    if isinstance(exc, subprocess.TimeoutExpired):
        # `gh auth token` runs through subprocess and its timeout exception
        # must retain the last-known-good values just like network timeouts.
        return "provider probe timed out"
    if isinstance(exc, TimeoutError):
        # A urllib *read* timeout is a bare TimeoutError, not a URLError, so
        # `_http_json`'s URLError branch never sees it and it lands here. This
        # is the Antigravity "The read operation timed out" case.
        return "provider probe timed out"
    if isinstance(exc, urllib.error.HTTPError):
        # MUST precede the URLError branch: HTTPError is a *subclass* of
        # URLError, so netting URLError first would classify a 401/403 as
        # transient. `_merge_with_previous` would then serve stale data
        # indefinitely and hide a genuine "you need to log in" state -- a
        # silent-staleness failure strictly worse than the failure card this
        # function exists to avoid. A server that answered is not a network
        # problem, so it stays opaque.
        return "provider probe failed"
    if isinstance(exc, (ConnectionError, urllib.error.URLError)):
        # Backstop for any provider that lets a URLError reach the catch-all.
        # Every provider currently handles its own, but this is one `except`
        # clause away from being untrue again, and the failure mode is silent.
        return "provider probe network error"
    return "provider probe failed"


def fetch_provider_snapshot(
    name: str, fetcher: Any, debug: bool = False, source: str = "api"
) -> ProviderSnapshot:
    try:
        status = fetcher.fetch()
        data = status.to_dict()
    except ProbeFailure as exc:
        if debug:
            _write_debug_dump(name, exc.raw_text or "")
        error = str(exc)
        debug_detail = None
        if debug:
            tail = exc.raw_text[-1600:] if exc.raw_text else ""
            # Only name the dump file when one was actually written.
            # `_write_debug_dump` is a no-op under headless (INV-2: --json must
            # have zero side effects), so the hint used
            # to point at a path that does not exist on exactly the paths
            # where a human is most likely to go looking for it.
            dump_hint = "" if _is_headless() else f"raw dump: {_debug_dump_path(name)}"
            debug_detail = "\n\n".join(part for part in (error, dump_hint, tail) if part).strip()
        return ProviderSnapshot(
            name=name, ok=False, source=source, error=error, debug_detail=debug_detail
        )
    except Exception as exc:
        # Log the type unconditionally. Until now this branch swallowed the
        # exception entirely, so a probe that failed here left no trace at all
        # -- the only signal was a generic card on the phone. The message is
        # withheld because AGENTS.md forbids secrets in logs as firmly as on
        # screen; it goes to the --debug channel instead.
        log.warning("provider %s probe raised %s", name, type(exc).__name__)
        if debug:
            log.debug("provider %s probe exception detail", name, exc_info=True)
        return ProviderSnapshot(
            name=name,
            ok=False,
            source=source,
            error=_safe_probe_error(exc),
            debug_detail=str(exc) if debug else None,
        )
    if debug:
        _write_debug_dump(name, str(data.get("raw_text", "")))
    if not debug:
        data.pop("raw_text", None)
    return ProviderSnapshot(name=name, ok=True, source=source, data=data)
