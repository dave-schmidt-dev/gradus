"""OpenCode Go provider using the local macOS Keychain and Go API."""

from __future__ import annotations

import json
import math
import subprocess
from typing import Any

from ..parsing import OpenCodeGoStatus
from ..tls import default_ssl_context
from ._base import ProbeFailure, _auth_required_message, _format_reset_time, _is_headless, register

USAGE_URL = "https://opencode.ai/zen/go/v1/usage"
HISTORY_PROVENANCE = {
    "provenance_available": True,
    "method": "GET",
    "route_template": USAGE_URL,
    "observation": "host-observed capacity only",
}


@register("OpenCode Go")
class OpenCodeGoProvider:
    """Read Go subscription windows without browser or cookie access."""

    _USAGE_URL = USAGE_URL
    _KEYCHAIN_SERVICE = "OpenCode Go"
    _KEYCHAIN_ACCOUNT = "default"
    _USER_AGENT = "gradus (opencode-go quota probe)"

    def __init__(self) -> None:
        self._api_key = ""

    def _acquire(self) -> None:
        if _is_headless():
            raise ProbeFailure("auth required: no cached credentials", "")
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
        import urllib.error
        import urllib.request

        self._acquire()
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
            with urllib.request.urlopen(req, timeout=15, context=default_ssl_context()) as response:
                payload = json.loads(response.read())
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403):
                self._api_key = ""
                raise ProbeFailure(
                    "OpenCode Go API key rejected: run `opencode /connect`", ""
                ) from exc
            raise ProbeFailure(f"OpenCode Go API error: HTTP {exc.code}", "") from exc
        except urllib.error.URLError as exc:
            raise ProbeFailure(f"OpenCode Go network error: {exc.reason}", "") from exc
        except (TimeoutError, OSError) as exc:
            raise ProbeFailure(f"OpenCode Go network error: {exc}", "") from exc
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
        )

    def close(self) -> None:
        pass
