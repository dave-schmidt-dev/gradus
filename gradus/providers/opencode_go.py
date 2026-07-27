"""OpenCode Go provider."""

from __future__ import annotations

import json
import logging
import time
import urllib.request
from datetime import datetime
from pathlib import Path
from typing import Any

from ..parsing import OpenCodeGoStatus
from . import _base
from ._base import (
    ProbeFailure,
    _auth_required_message,
    _AuthRejected,
    _format_reset_time,
    _harden_existing,
    _remove_private,
    register,
)
from ._seroval import _seroval_decode

log = logging.getLogger(__name__)


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(
        self, req: Any, fp: Any, code: int, msg: str, headers: Any, newurl: str
    ) -> None:
        return None


@register("OpenCode Go")
class OpenCodeGoProvider:
    _SERVER_URL = "https://opencode.ai/_server"
    _WORKSPACES_FN_ID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
    _CACHE_PATH = (
        Path(__file__).resolve().parent.parent.parent / ".cache" / "opencode_go_cookies.json"
    )
    _USER_AGENT = "gradus (opencode-go quota probe)"

    def __init__(self) -> None:
        self._auth_cookie = ""
        self._workspace_id = ""

    def _acquire(self) -> None:
        if not self._auth_cookie:
            self._load_cookie()

    def _load_cookie(self) -> None:
        if self._load_from_cache():
            return
        cookies = _base._read_safari_cookies("opencode")
        auth = cookies.get("auth", "")
        if auth:
            self._auth_cookie = auth
            self._save_to_cache()

    def _load_from_cache(self) -> bool:
        if not self._CACHE_PATH.exists():
            return False
        try:
            data = json.loads(self._CACHE_PATH.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return False
        auth = data.get("auth")
        if not (isinstance(auth, str) and auth):
            return False
        self._auth_cookie = auth
        _harden_existing(self._CACHE_PATH)
        return True

    def _save_to_cache(self) -> None:
        if not self._auth_cookie:
            return
        try:
            payload = {
                "auth": self._auth_cookie,
                "cached_at": datetime.now().isoformat(),
            }
            _base._write_private(self._CACHE_PATH, json.dumps(payload))
        except OSError as exc:
            log.warning("Failed to write OpenCode Go cookie cache: %s", exc)

    def _clear_cache(self) -> None:
        _remove_private(self._CACHE_PATH)

    def _call_server_fn(self, fn_id: str, arg: str | None) -> Any:
        import urllib.error
        import urllib.request

        headers = {
            "X-Server-Id": fn_id,
            "X-Server-Instance": "server-fn:0",
            "Cookie": f"auth={self._auth_cookie}",
            "Accept": "application/json",
            "User-Agent": self._USER_AGENT,
        }
        body: bytes | None = None
        if arg is not None:
            headers["Content-Type"] = "text/plain"
            headers["X-Start-Type"] = "1"
            body = arg.encode("utf-8")
        req = urllib.request.Request(self._SERVER_URL, data=body, headers=headers, method="POST")
        opener = urllib.request.build_opener(_NoRedirectHandler)
        try:
            with opener.open(req, timeout=15) as resp:
                if resp.headers.get("Location"):
                    raise _AuthRejected("redirect to sign-in")
                raw = resp.read()
        except urllib.error.HTTPError as exc:
            if exc.code in (301, 302, 303, 307, 308, 401, 403):
                raise _AuthRejected(f"HTTP {exc.code}") from exc
            raise ProbeFailure(
                f"OpenCode Go probe failed (HTTP {exc.code}) — console build may have changed",
                f"HTTP {exc.code}",
            ) from exc
        except urllib.error.URLError as exc:
            raise ProbeFailure(
                f"Could not reach opencode.ai: {exc.reason}", f"POST {self._SERVER_URL}"
            ) from exc
        return _seroval_decode(raw)

    @staticmethod
    def _window_fields(window: Any) -> tuple[float | None, str | None]:
        if not isinstance(window, dict):
            return None, None
        used = window.get("usagePercent")
        percent_left: float | None = None
        if isinstance(used, (int, float)) and not isinstance(used, bool):
            percent_left = max(0.0, 100.0 - float(used))
        reset: str | None = None
        reset_in = window.get("resetInSec")
        if isinstance(reset_in, (int, float)) and not isinstance(reset_in, bool):
            reset = _format_reset_time(time.time() + float(reset_in))
        return percent_left, reset

    def _fetch_subscription(self, workspace_id: str) -> dict[str, Any] | None:
        import re
        import urllib.error
        import urllib.request

        req = urllib.request.Request(
            f"https://opencode.ai/workspace/{workspace_id}/go",
            headers={"Cookie": f"auth={self._auth_cookie}", "User-Agent": self._USER_AGENT},
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            if "auth.opencode.ai" in resp.url or "/auth/authorize" in resp.url:
                raise _AuthRejected("redirect to sign-in")
            html = resp.read().decode("utf-8", errors="replace")

        def _extract_usage(name: str) -> dict[str, Any] | None:
            m = re.search(
                rf"{name}:\$R\[\d+\]=\{{status:\"([^\"]+)\",resetInSec:(\d+),usagePercent:(\d+)\}}",
                html,
            )
            if m:
                return {
                    "status": m.group(1),
                    "resetInSec": int(m.group(2)),
                    "usagePercent": int(m.group(3)),
                }
            return None

        rolling = _extract_usage("rollingUsage")
        weekly = _extract_usage("weeklyUsage")
        monthly = _extract_usage("monthlyUsage")
        if rolling or weekly or monthly:
            return {
                "rollingUsage": rolling,
                "weeklyUsage": weekly,
                "monthlyUsage": monthly,
            }
        return None

    def fetch(self) -> OpenCodeGoStatus:
        self._acquire()
        if not self._auth_cookie:
            raise ProbeFailure(
                _auth_required_message("OpenCode Go session expired: sign in at opencode.ai"),
                "",
            )

        expired = ProbeFailure(
            "OpenCode Go session expired. Sign in at opencode.ai to refresh.",
            "console rejected the session cookie",
        )
        try:
            workspaces = self._call_server_fn(self._WORKSPACES_FN_ID, None)
        except _AuthRejected as exc:
            self._auth_cookie = ""
            self._workspace_id = ""
            self._clear_cache()
            raise expired from exc

        if workspaces is None:
            self._auth_cookie = ""
            self._workspace_id = ""
            self._clear_cache()
            raise expired
        if not isinstance(workspaces, list):
            raise ProbeFailure(
                "OpenCode Go workspaces response changed shape",
                json.dumps(workspaces, default=str)[:500],
            )

        ids = [
            str(ws["id"])
            for ws in workspaces
            if isinstance(ws, dict) and isinstance(ws.get("id"), str) and ws["id"]
        ]
        if self._workspace_id in ids:
            ids.remove(self._workspace_id)
            ids.insert(0, self._workspace_id)

        import urllib.error

        subscription: dict[str, Any] | None = None
        for workspace_id in ids:
            try:
                result = self._fetch_subscription(workspace_id)
            except _AuthRejected as exc:
                self._auth_cookie = ""
                self._workspace_id = ""
                self._clear_cache()
                raise ProbeFailure(
                    "OpenCode Go session expired. Sign in at opencode.ai to refresh.",
                    str(exc),
                ) from exc
            except (urllib.error.URLError, urllib.error.HTTPError):
                continue
            if isinstance(result, dict) and result:
                subscription = result
                self._workspace_id = workspace_id
                break

        raw_text = json.dumps(
            {"workspaces": workspaces, "subscription": subscription},
            indent=2,
            sort_keys=True,
            default=str,
        )

        if subscription is None:
            raise ProbeFailure(
                "No OpenCode Go subscription found",
                raw_text[:500],
            )

        five_hour_percent_left, five_hour_reset = self._window_fields(
            subscription.get("rollingUsage")
        )
        weekly_percent_left, weekly_reset = self._window_fields(subscription.get("weeklyUsage"))
        monthly_percent_left, monthly_reset = self._window_fields(subscription.get("monthlyUsage"))

        if (
            five_hour_percent_left is None
            and weekly_percent_left is None
            and monthly_percent_left is None
        ):
            raise ProbeFailure(
                "OpenCode Go usage response has no recognizable windows",
                raw_text[:500],
            )

        return OpenCodeGoStatus(
            five_hour_percent_left=five_hour_percent_left,
            five_hour_reset=five_hour_reset,
            weekly_percent_left=weekly_percent_left,
            weekly_reset=weekly_reset,
            monthly_percent_left=monthly_percent_left,
            monthly_reset=monthly_reset,
            raw_text=raw_text,
        )

    def close(self) -> None:
        pass
