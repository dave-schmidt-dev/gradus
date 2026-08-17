"""Claude provider."""

from __future__ import annotations

import getpass
import json
import math
import subprocess
from typing import Any

from ..parsing import ClaudeStatus
from . import _base
from ._base import (
    ProbeFailure,
    _format_reset_time,
    register,
)


@register("Claude")
class ClaudeHttpProvider:
    _OAUTH_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
    _KEYCHAIN_SERVICE = "Claude Code-credentials"
    _USER_AGENT = "gradus (claude oauth usage probe)"

    def __init__(self) -> None:
        self._access_token: str = ""

    def _acquire(self) -> None:
        if _base._is_headless():
            raise ProbeFailure("auth required: no cached credentials", "")
        if not self._access_token:
            try:
                self._access_token = self._load_keychain_access_token()
            except FileNotFoundError as exc:
                raise ProbeFailure(
                    "Claude Code OAuth credentials unavailable: run `claude auth login`",
                    "",
                ) from exc

    @classmethod
    def _load_keychain_access_token(cls) -> str:
        """Read Claude Code's OAuth token without persisting or logging it."""
        try:
            result = subprocess.run(
                [
                    "security",
                    "find-generic-password",
                    "-w",
                    "-s",
                    cls._KEYCHAIN_SERVICE,
                    "-a",
                    getpass.getuser(),
                ],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise FileNotFoundError("Could not read Claude Code credentials") from exc
        if result.returncode != 0:
            raise FileNotFoundError(
                "Claude Code OAuth credentials unavailable: run `claude auth login`"
            )
        try:
            payload: Any = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise FileNotFoundError("Claude Code credentials are invalid") from exc
        oauth = payload.get("claudeAiOauth") if isinstance(payload, dict) else None
        token = oauth.get("accessToken") if isinstance(oauth, dict) else None
        if not isinstance(token, str) or not token.strip():
            raise FileNotFoundError(
                "Claude Code OAuth credentials unavailable: run `claude auth login`"
            )
        return token.strip()

    def fetch(self) -> ClaudeStatus:
        self._acquire()
        try:
            payload = _base._http_json(
                self._OAUTH_USAGE_URL,
                headers={
                    "Authorization": f"Bearer {self._access_token}",
                    "Accept": "application/json",
                    "User-Agent": self._USER_AGENT,
                },
            )
        except ProbeFailure as exc:
            msg = str(exc)
            if "HTTP 401" in msg or "HTTP 403" in msg:
                self._access_token = ""
                raise ProbeFailure(
                    "Claude Code session expired: run `claude auth login`",
                    "",
                ) from exc
            raise

        if not isinstance(payload, dict):
            raise ProbeFailure("Claude usage response is invalid", "")
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
                utilization = float(val)
            except (TypeError, ValueError):
                return None
            if not math.isfinite(utilization) or not 0 <= utilization <= 100:
                return None
            return 100.0 - utilization

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
