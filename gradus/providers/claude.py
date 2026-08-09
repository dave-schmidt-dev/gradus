"""Claude provider."""

from __future__ import annotations

import json
from pathlib import Path

from ..parsing import ClaudeStatus
from . import _base
from ._base import (
    ProbeFailure,
    _auth_required_message,
    _format_reset_time,
    _harden_existing,
    _remove_private,
    register,
)


@register("Claude")
class ClaudeHttpProvider:
    _BASE_URL = "https://claude.ai"
    _CACHE_PATH = Path(__file__).resolve().parent.parent.parent / ".cache" / "claude_cookies.json"

    def __init__(self) -> None:
        self._session_key: str = ""
        self._cf_clearance: str = ""
        self._org_id: str = ""

    def _acquire(self) -> None:
        if not self._has_cookies:
            self._load_cookies()

    def _load_cookies(self) -> None:
        self._load_from_cache()

    def _load_from_cache(self) -> bool:
        if not self._CACHE_PATH.exists():
            return False
        try:
            data = json.loads(self._CACHE_PATH.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return False
        session_key = data.get("sessionKey")
        org_id = data.get("lastActiveOrg")
        if not (
            isinstance(session_key, str) and session_key and isinstance(org_id, str) and org_id
        ):
            return False
        self._session_key = session_key
        self._org_id = org_id
        cf = data.get("cf_clearance")
        if isinstance(cf, str):
            self._cf_clearance = cf
        _harden_existing(self._CACHE_PATH)
        return True

    def _clear_cache(self) -> None:
        _remove_private(self._CACHE_PATH)

    @property
    def _has_cookies(self) -> bool:
        return bool(self._session_key and self._org_id)

    def fetch(self) -> ClaudeStatus:
        self._acquire()
        if not self._has_cookies:
            raise ProbeFailure(
                _auth_required_message("Claude session expired: sign in at claude.ai"), ""
            )

        url = f"{self._BASE_URL}/api/organizations/{self._org_id}/usage"
        cookie_parts = [f"sessionKey={self._session_key}"]
        if self._cf_clearance:
            cookie_parts.append(f"cf_clearance={self._cf_clearance}")

        try:
            payload = _base._http_json(
                url,
                headers={
                    "Cookie": "; ".join(cookie_parts),
                    "Accept": "application/json",
                    "Referer": "https://claude.ai/",
                    "Origin": "https://claude.ai",
                    "User-Agent": (
                        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                        "AppleWebKit/605.1.15 (KHTML, like Gecko) "
                        "Version/18.0 Safari/605.1.15"
                    ),
                },
            )
        except ProbeFailure as exc:
            msg = str(exc)
            if "HTTP 400" in msg or "HTTP 401" in msg or "HTTP 403" in msg:
                self._session_key = self._cf_clearance = self._org_id = ""
                self._clear_cache()
                raise ProbeFailure(
                    "Claude session expired — visit claude.ai to refresh",
                    msg,
                ) from exc
            raise

        raw_text = json.dumps(payload, indent=2, sort_keys=True)

        session_percent_left: float | None = None
        weekly_percent_left: float | None = None
        opus_percent_left: float | None = None
        primary_reset: str | None = None
        secondary_reset: str | None = None
        opus_reset: str | None = None

        def _util(key: str) -> float | None:
            bucket = payload.get(key) or {}
            val = bucket.get("utilization") if isinstance(bucket, dict) else None
            if val is None:
                return None
            try:
                return 100.0 - float(val)
            except (TypeError, ValueError):
                return None

        def _reset(key: str) -> str | None:
            bucket = payload.get(key) or {}
            if not isinstance(bucket, dict):
                return None
            return _format_reset_time(bucket.get("resets_at"))

        session_percent_left = _util("five_hour")
        primary_reset = _reset("five_hour")
        weekly_percent_left = _util("seven_day")
        secondary_reset = _reset("seven_day")
        opus_percent_left = _util("seven_day_opus")
        opus_reset = _reset("seven_day_opus")

        return ClaudeStatus(
            session_percent_left=session_percent_left,
            weekly_percent_left=weekly_percent_left,
            opus_percent_left=opus_percent_left,
            primary_reset=primary_reset,
            secondary_reset=secondary_reset,
            opus_reset=opus_reset,
            account_email=None,
            account_organization=None,
            login_method=None,
            raw_text=raw_text,
        )

    def close(self) -> None:
        pass
