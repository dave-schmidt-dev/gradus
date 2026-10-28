"""OpenCode Go provider using OpenCode v2 Console OAuth and legacy macOS Keychain API key."""

from __future__ import annotations

import json
import math
import subprocess
from http.client import HTTPException
from pathlib import Path
from typing import Any

from ..parsing import OpenCodeGoStatus
from ..tls import default_ssl_context
from ._base import (
    ProbeFailure,
    _auth_required_message,
    _format_reset_time,
    _is_headless,
    _source_reset_instant,
    register,
)
from .opencode_oauth import (
    DEFAULT_OPENCODE_DB_PATH,
    NoRedirectHandler,
    OpenCodeOAuthCredential,
    _is_cloudflare_403,
    fetch_console_oauth_status,
    load_opencode_oauth_credential,
)

USAGE_URL = "https://opencode.ai/zen/go/v1/usage"
HISTORY_PROVENANCE = {
    "provenance_available": True,
    "method": "GET",
    "route_template": USAGE_URL,
    "observation": "host-observed capacity only",
}


@register("OpenCode Go")
class OpenCodeGoProvider:
    """Read Go subscription windows from OpenCode Console OAuth or legacy Keychain API key."""

    _USAGE_URL = USAGE_URL
    _KEYCHAIN_SERVICE = "OpenCode Go"
    _KEYCHAIN_ACCOUNT = "default"
    _USER_AGENT = "gradus (opencode-go quota probe)"
    _DB_PATH = DEFAULT_OPENCODE_DB_PATH

    def __init__(self, db_path: Path | str | None = None) -> None:
        self._api_key = ""
        self._oauth_credential: OpenCodeOAuthCredential | None = None
        self._db_path = Path(db_path) if db_path is not None else None

    def _acquire(self) -> None:
        if _is_headless():
            raise ProbeFailure("auth required: no cached credentials", "")
        db_path = self._db_path or self._DB_PATH
        oauth_cred = load_opencode_oauth_credential(db_path)
        self._oauth_credential = oauth_cred
        if oauth_cred is not None:
            return
        if self._api_key:
            return

        try:
            self._api_key = self._load_keychain_api_key()
        except FileNotFoundError as exc:
            raise ProbeFailure(
                _auth_required_message(f"OpenCode Go Keychain {exc}"),
                "",
            ) from exc

    @classmethod
    def _load_keychain_api_key(cls) -> str:
        """Read the fixed generic-password item without persisting or logging it."""
        try:
            result = subprocess.run(
                [
                    "security",
                    "find-generic-password",
                    "-w",
                    "-s",
                    cls._KEYCHAIN_SERVICE,
                    "-a",
                    cls._KEYCHAIN_ACCOUNT,
                ],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise FileNotFoundError("lookup timed out") from exc
        except (OSError, subprocess.SubprocessError) as exc:
            raise FileNotFoundError("Could not read OpenCode Go Keychain item") from exc
        if result.returncode != 0:
            diagnostic = result.stderr.lower()
            if "interaction" in diagnostic:
                reason = "lookup requires interaction"
            elif "locked" in diagnostic:
                reason = "Keychain is locked"
            elif "denied" in diagnostic or "authorization" in diagnostic:
                reason = "Keychain access denied"
            else:
                reason = "item unavailable"
            raise FileNotFoundError(reason)
        key = result.stdout.strip()
        if not key or "\n" in key or "\r" in key:
            raise FileNotFoundError("OpenCode Go Keychain item is invalid")
        return key

    @staticmethod
    def _window(window: Any) -> tuple[float | None, str | None]:
        if not isinstance(window, dict):
            return None, None
        try:
            used = float(window.get("percent"))
        except (TypeError, ValueError):
            used = math.nan
        percent_left = 100.0 - used if math.isfinite(used) and 0 <= used <= 100 else None
        return percent_left, _format_reset_time(window.get("resetsAt"))

    def fetch(self) -> OpenCodeGoStatus:
        self._acquire()
        if self._oauth_credential is not None:
            return fetch_console_oauth_status(self._oauth_credential)
        return self._fetch_legacy_api_key()

    def _fetch_legacy_api_key(self) -> OpenCodeGoStatus:
        import urllib.error
        import urllib.request

        try:
            req = urllib.request.Request(
                self._USAGE_URL,
                headers={
                    "Authorization": f"Bearer {self._api_key}",
                    "Accept": "application/json",
                    "User-Agent": self._USER_AGENT,
                },
                method="GET",
            )
            opener = urllib.request.build_opener(
                urllib.request.HTTPSHandler(context=default_ssl_context()), NoRedirectHandler()
            )
            with opener.open(req, timeout=15) as response:
                raw_bytes = response.read(65537)
                if len(raw_bytes) > 65536:
                    raise ProbeFailure("OpenCode Go usage response too large", "")
                payload = json.loads(raw_bytes.decode("utf-8"))
        except urllib.error.HTTPError as exc:
            if exc.code == 401:
                self._api_key = ""
                raise ProbeFailure(
                    "OpenCode Go API key rejected: run `opencode /connect`", ""
                ) from exc
            if exc.code == 403:
                if _is_cloudflare_403(exc):
                    raise ProbeFailure(
                        "OpenCode Go access blocked (Cloudflare 403)",
                        "",
                    ) from exc
                self._api_key = ""
                raise ProbeFailure(
                    "OpenCode Go API error: HTTP 403 (permission denied)", ""
                ) from exc
            raise ProbeFailure(f"OpenCode Go API error: HTTP {exc.code}", "") from exc
        except urllib.error.URLError as exc:
            raise ProbeFailure("OpenCode Go network error", "") from exc
        except (TimeoutError, OSError, HTTPException) as exc:
            raise ProbeFailure("OpenCode Go network error", "") from exc
        except (json.JSONDecodeError, UnicodeDecodeError, TypeError) as exc:
            raise ProbeFailure("OpenCode Go usage response is malformed", "") from exc

        if not isinstance(payload, dict) or not isinstance(payload.get("usage"), dict):
            raise ProbeFailure("OpenCode Go usage response schema changed", "")
        usage = payload["usage"]
        windows = [self._window(usage.get(name)) for name in ("rolling", "weekly", "monthly")]
        if all(percent is None for percent, _ in windows):
            raise ProbeFailure("OpenCode Go usage response has no recognizable windows", "")
        raw_text = json.dumps({"usage": usage}, indent=2, sort_keys=True)
        return OpenCodeGoStatus(
            five_hour_percent_left=windows[0][0],
            five_hour_reset=windows[0][1],
            weekly_percent_left=windows[1][0],
            weekly_reset=windows[1][1],
            monthly_percent_left=windows[2][0],
            monthly_reset=windows[2][1],
            zen_credit=None,
            raw_text=raw_text,
            source_reset_instants={
                key: instant
                for key, name in (
                    ("five_hour_reset", "rolling"),
                    ("weekly_reset", "weekly"),
                    ("monthly_reset", "monthly"),
                )
                if isinstance(usage.get(name), dict)
                and (instant := _source_reset_instant(usage[name].get("resetsAt")))
            },
        )

    def close(self) -> None:
        pass
