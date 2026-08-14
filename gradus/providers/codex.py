"""Codex provider."""

from __future__ import annotations

import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ..parsing import CodexStatus
from . import _base
from ._base import ProbeFailure, _format_reset_time, _is_headless, register
from ._codex_helpers import (
    _classify_codex_windows,
    _codex_percent_left,
    _extract_spark_window,
)

log = logging.getLogger(__name__)


@register("Codex")
class CodexHttpProvider:
    _USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
    _AUTH_PATH = Path.home() / ".codex" / "auth.json"
    _REFRESH_URL = "https://auth.openai.com/oauth/token"
    _CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"

    def __init__(self) -> None:
        self._access_token: str = ""
        self._refresh_token: str = ""
        self._account_id: str = ""

    def _acquire(self) -> None:
        if self._access_token:
            return
        if not self._AUTH_PATH.exists():
            raise FileNotFoundError(f"Codex auth not found: {self._AUTH_PATH}")
        self._load_creds()

    def _load_creds(self) -> None:
        try:
            data = json.loads(self._AUTH_PATH.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise FileNotFoundError(f"Failed to read Codex auth: {exc}") from exc
        tokens = data.get("tokens") or {}
        self._access_token = tokens.get("access_token", "")
        self._refresh_token = tokens.get("refresh_token", "")
        self._account_id = tokens.get("account_id", "")
        if not self._access_token:
            raise FileNotFoundError("Codex auth.json missing tokens.access_token")

    def _request_usage(self) -> dict[str, Any]:
        return _base._http_json(
            self._USAGE_URL,
            headers={
                "Authorization": f"Bearer {self._access_token}",
                "Account-Id": self._account_id,
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
        )

    def _refresh_tokens(self) -> bool:
        if _is_headless():
            return False
        if not self._refresh_token:
            return False
        body = json.dumps(
            {
                "client_id": self._CLIENT_ID,
                "grant_type": "refresh_token",
                "refresh_token": self._refresh_token,
                "scope": "openid profile email",
            }
        ).encode("utf-8")
        try:
            resp = _base._http_json(
                self._REFRESH_URL,
                method="POST",
                headers={
                    "Content-Type": "application/json",
                    "Accept": "application/json",
                },
                body=body,
            )
        except ProbeFailure as exc:
            if "refresh_token_invalidated" in (exc.raw_text or ""):
                raise ProbeFailure(
                    "Codex session expired: run `codex` to re-authenticate",
                    exc.raw_text,
                ) from exc
            raise
        new_access = resp.get("access_token")
        if not new_access:
            return False
        try:
            on_disk = json.loads(self._AUTH_PATH.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            on_disk = {}
        tokens = dict(on_disk.get("tokens") or {})
        tokens["access_token"] = new_access
        if resp.get("id_token"):
            tokens["id_token"] = resp["id_token"]
        if resp.get("refresh_token"):
            tokens["refresh_token"] = resp["refresh_token"]
        on_disk["tokens"] = tokens
        on_disk["last_refresh"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        _base._write_private(self._AUTH_PATH, json.dumps(on_disk, indent=2))
        self._load_creds()
        return True

    def fetch(self) -> CodexStatus:
        self._acquire()
        expired = ProbeFailure("Codex session expired: run `codex` to re-authenticate", "")
        try:
            payload = self._request_usage()
        except ProbeFailure as exc:
            if "HTTP 401" not in str(exc):
                raise
            refreshed = False
            try:
                refreshed = self._refresh_tokens()
            except ProbeFailure as refresh_exc:
                if "re-authenticate" in str(refresh_exc):
                    raise
                refreshed = False
            if refreshed:
                try:
                    payload = self._request_usage()
                except ProbeFailure as retry_exc:
                    if "HTTP 401" in str(retry_exc):
                        raise ProbeFailure(str(expired), str(retry_exc)) from retry_exc
                    raise
            else:
                old_token = self._access_token
                try:
                    self._load_creds()
                except FileNotFoundError:
                    raise ProbeFailure(str(expired), str(exc)) from exc
                if self._access_token == old_token:
                    raise ProbeFailure(str(expired), str(exc)) from exc
                try:
                    payload = self._request_usage()
                except ProbeFailure as retry_exc:
                    if "HTTP 401" in str(retry_exc):
                        raise ProbeFailure(str(expired), str(retry_exc)) from retry_exc
                    raise

        raw_text = json.dumps(payload, indent=2, sort_keys=True)

        five_hour_percent_left: float | None = None
        weekly_percent_left: float | None = None
        five_hour_reset: str | None = None
        weekly_reset: str | None = None
        credits: float | None = None

        rate_limit = payload.get("rate_limit") or {}
        five_hour_win, weekly_win = _classify_codex_windows(
            [rate_limit.get("primary_window"), rate_limit.get("secondary_window")]
        )

        five_hour_percent_left = _codex_percent_left(five_hour_win)
        five_hour_reset = (
            _format_reset_time(five_hour_win.get("reset_at")) if five_hour_win else None
        )
        weekly_percent_left = _codex_percent_left(weekly_win)
        weekly_reset = _format_reset_time(weekly_win.get("reset_at")) if weekly_win else None

        spark_win = _extract_spark_window(payload)
        spark_weekly_percent_left = _codex_percent_left(spark_win)
        spark_reset_at = spark_win.get("reset_at") if spark_win else None
        spark_weekly_reset = (
            _format_reset_time(spark_reset_at)
            if spark_reset_at is None or isinstance(spark_reset_at, (str, int, float))
            else None
        )

        credits_obj = payload.get("credits") or {}
        if isinstance(credits_obj, dict):
            balance = credits_obj.get("balance")
            if balance is not None:
                try:
                    credits = float(balance)
                except (TypeError, ValueError):
                    pass

        return CodexStatus(
            five_hour_percent_left=five_hour_percent_left,
            weekly_percent_left=weekly_percent_left,
            five_hour_reset=five_hour_reset,
            weekly_reset=weekly_reset,
            spark_weekly_percent_left=spark_weekly_percent_left,
            spark_weekly_reset=spark_weekly_reset,
            credits=credits,
            raw_text=raw_text,
        )

    def close(self) -> None:
        pass
