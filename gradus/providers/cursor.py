"""Cursor provider."""

from __future__ import annotations

import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from ..parsing import CursorStatus
from . import _base
from ._base import (
    ProbeFailure,
    _auth_required_message,
    _harden_existing,
    _is_headless,
    _is_jwt_expired,
    _remove_private,
    register,
)

log = logging.getLogger(__name__)


@register("Cursor")
class CursorProvider:
    _DB_PATH = (
        Path.home()
        / "Library"
        / "Application Support"
        / "Cursor"
        / "User"
        / "globalStorage"
        / "state.vscdb"
    )
    _CACHE_PATH = Path(__file__).resolve().parent.parent.parent / ".cache" / "cursor_token.json"
    _USAGE_URL = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    _PLAN_URL = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo"
    _TOKEN_URL = "https://api2.cursor.sh/oauth/token"
    _CLIENT_ID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"

    def __init__(self) -> None:
        self._access_token: str | None = None
        self._refresh_token: str | None = None
        self._token_source: str | None = None

    def _acquire(self) -> None:
        if not self._access_token:
            self._load_token()

    def _load_token(self) -> None:
        if self._load_from_cache():
            self._token_source = "cache"
            return

        token = self._extract_token_from_safari()
        if token:
            self._access_token = token
            self._token_source = "safari"
            self._save_to_cache()
            return

        self._load_from_desktop_db()
        if self._access_token:
            self._token_source = "desktop_db"
            self._save_to_cache()
            return

    def _load_from_cache(self) -> bool:
        if not self._CACHE_PATH.exists():
            return False
        try:
            data = json.loads(self._CACHE_PATH.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return False
        access = data.get("access_token")
        if not isinstance(access, str) or not access:
            return False
        if _is_jwt_expired(access):
            return False
        self._access_token = access
        refresh = data.get("refresh_token")
        if isinstance(refresh, str) and refresh:
            self._refresh_token = refresh
        _harden_existing(self._CACHE_PATH)
        return True

    def _save_to_cache(self) -> None:
        if not self._access_token:
            return
        try:
            payload = {
                "access_token": self._access_token,
                "refresh_token": self._refresh_token,
                "cached_at": datetime.now().isoformat(),
            }
            _base._write_private(self._CACHE_PATH, json.dumps(payload))
        except OSError as exc:
            log.warning("Failed to write Cursor token cache: %s", exc)

    def _clear_cache(self) -> None:
        _remove_private(self._CACHE_PATH)

    def _extract_token_from_safari(self) -> str | None:
        import urllib.parse

        cookies = _base._read_safari_cookies("cursor")
        token_value = cookies.get("WorkosCursorSessionToken", "")
        if token_value:
            decoded = urllib.parse.unquote(token_value)
            parts = decoded.split("::", 1)
            if len(parts) == 2 and parts[1]:
                log.debug("Extracted Cursor token from Safari cookie")
                return parts[1]
        return None

    def _load_from_desktop_db(self) -> None:
        import sqlite3 as _sqlite3

        if not self._DB_PATH.exists():
            return
        try:
            conn = _sqlite3.connect(f"file:{self._DB_PATH}?mode=ro", uri=True)
            try:
                row = conn.execute(
                    "SELECT value FROM cursorDiskKV WHERE key = 'cursorAuth/accessToken'"
                ).fetchone()
                self._access_token = row[0] if row else None
                row = conn.execute(
                    "SELECT value FROM cursorDiskKV WHERE key = 'cursorAuth/refreshToken'"
                ).fetchone()
                self._refresh_token = row[0] if row else None
            finally:
                conn.close()
        except _sqlite3.Error:
            return

    def fetch(self) -> CursorStatus:
        import urllib.error as _ue
        import urllib.request as _ur

        self._acquire()
        if not self._access_token:
            raise ProbeFailure(
                _auth_required_message("Cursor session expired: sign in at cursor.com/settings"),
                "",
            )

        usage_data: dict[str, Any] = {}
        plan_data: dict[str, Any] = {}

        try:
            usage_data = self._api_post(_ur, _ue, self._USAGE_URL)
        except _ue.HTTPError as exc:
            if exc.code == 401 and self._can_refresh:
                self._do_token_refresh(_ur, _ue)
                # The retry needs its own handlers. It runs *inside* this
                # `except HTTPError` block, so the sibling `except (OSError,
                # URLError)` below cannot catch anything it raises -- an
                # exception here escapes `fetch` entirely and lands in
                # `fetch_provider_snapshot`'s catch-all, which flattens it to
                # the opaque "provider probe failed". That cost two things: a
                # network blip on the retry classified as a hard failure, and a
                # 401 that survived the refresh (a genuinely dead session)
                # reported as a generic error instead of an actionable one.
                try:
                    usage_data = self._api_post(_ur, _ue, self._USAGE_URL)
                except _ue.HTTPError as retry_exc:
                    if retry_exc.code == 401:
                        self._access_token = None
                        self._clear_cache()
                        raise ProbeFailure(
                            "Cursor session expired. Log into cursor.com to refresh.",
                            f"HTTP {retry_exc.code}",
                        ) from retry_exc
                    raise ProbeFailure(
                        f"Cursor API error: HTTP {retry_exc.code}", ""
                    ) from retry_exc
                except (OSError, _ue.URLError) as retry_exc:
                    raise ProbeFailure(f"Cursor API network error: {retry_exc}", "") from retry_exc
            elif exc.code == 401:
                self._access_token = None
                self._clear_cache()
                raise ProbeFailure(
                    "Cursor session expired. Log into cursor.com to refresh.",
                    f"HTTP {exc.code}",
                ) from exc
            else:
                raise ProbeFailure(f"Cursor API error: HTTP {exc.code}", "") from exc
        except (OSError, _ue.URLError) as exc:
            raise ProbeFailure(f"Cursor API network error: {exc}", "") from exc

        try:
            plan_data = self._api_post(_ur, _ue, self._PLAN_URL)
        except Exception:
            pass

        plan_usage = usage_data.get("planUsage") or {}
        if not isinstance(plan_usage, dict):
            plan_usage = {}
        plan_info = plan_data.get("planInfo") or {}
        if not isinstance(plan_info, dict):
            plan_info = {}
        credit_percent_left: float | None = None

        raw_remaining = plan_usage.get("remaining")
        raw_limit = plan_usage.get("limit")
        if raw_remaining is not None and raw_limit is not None:
            try:
                remaining = int(raw_remaining)
                limit = int(raw_limit)
                if limit > 0:
                    credit_percent_left = round((remaining / limit) * 100.0, 2)
            except (TypeError, ValueError):
                pass
        if credit_percent_left is None:
            total_percent_used = plan_usage.get("totalPercentUsed")
            if total_percent_used is not None:
                try:
                    credit_percent_left = round(100.0 - float(total_percent_used), 2)
                except (TypeError, ValueError):
                    pass

        auto_percent_used: float | None = None
        raw_auto = plan_usage.get("autoPercentUsed")
        if raw_auto is not None:
            try:
                auto_percent_used = float(raw_auto)
            except (TypeError, ValueError):
                pass

        api_percent_used: float | None = None
        raw_api = plan_usage.get("apiPercentUsed")
        if raw_api is not None:
            try:
                api_percent_used = float(raw_api)
            except (TypeError, ValueError):
                pass

        remaining_cents: int | None = None
        raw_remaining = plan_usage.get("remaining")
        if raw_remaining is not None:
            try:
                remaining_cents = int(raw_remaining)
            except (TypeError, ValueError):
                pass

        limit_cents: int | None = None
        raw_limit = plan_usage.get("limit")
        if raw_limit is not None:
            try:
                limit_cents = int(raw_limit)
            except (TypeError, ValueError):
                pass

        billing_cycle_start: str | None = None
        raw_start = usage_data.get("billingCycleStart") or plan_data.get("billingCycleStart")
        if raw_start is not None:
            try:
                ms = int(raw_start)
                start_dt = datetime.fromtimestamp(ms / 1000, tz=timezone.utc)
                billing_cycle_start = start_dt.astimezone().isoformat()
            except (TypeError, ValueError):
                pass

        billing_cycle_end: str | None = None
        billing_cycle_end_iso: str | None = None
        raw_end = usage_data.get("billingCycleEnd") or plan_data.get("billingCycleEnd")
        if raw_end is not None:
            try:
                ms = int(raw_end)
                target = datetime.fromtimestamp(ms / 1000, tz=timezone.utc)
                billing_cycle_end = f"Resets {target.astimezone().strftime('%b %d at %I:%M %p')}"
                billing_cycle_end_iso = target.astimezone().isoformat()
            except (TypeError, ValueError):
                pass

        plan_name = plan_info.get("name") or plan_info.get("planName") or plan_data.get("planName")

        raw_text = json.dumps(
            {"usage": usage_data, "plan": plan_data},
            indent=2,
            sort_keys=True,
        )
        return CursorStatus(
            credit_percent_left=credit_percent_left,
            auto_percent_used=auto_percent_used,
            api_percent_used=api_percent_used,
            remaining_cents=remaining_cents,
            limit_cents=limit_cents,
            plan_name=(plan_name if isinstance(plan_name, str) else None),
            billing_cycle_start=billing_cycle_start,
            billing_cycle_end=billing_cycle_end,
            billing_cycle_end_iso=billing_cycle_end_iso,
            raw_text=raw_text,
        )

    def close(self) -> None:
        pass

    def _api_post(self, ur: Any, ue: Any, url: str) -> dict[str, Any]:
        req = ur.Request(
            url,
            data=b"{}",
            headers={
                "Authorization": f"Bearer {self._access_token}",
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1",
            },
            method="POST",
        )
        with ur.urlopen(req, timeout=15) as resp:
            body = resp.read()
        try:
            return json.loads(body)
        except json.JSONDecodeError:
            return {}

    @property
    def _can_refresh(self) -> bool:
        return bool(self._refresh_token) and not _is_headless()

    def _do_token_refresh(self, ur: Any, ue: Any) -> None:
        payload = json.dumps(
            {
                "grant_type": "refresh_token",
                "client_id": self._CLIENT_ID,
                "refresh_token": self._refresh_token,
            }
        ).encode()
        req = ur.Request(
            self._TOKEN_URL,
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with ur.urlopen(req, timeout=15) as resp:
                body = json.loads(resp.read())
            new_token = body.get("access_token")
            if new_token:
                self._access_token = new_token
                new_refresh = body.get("refresh_token")
                if isinstance(new_refresh, str) and new_refresh:
                    self._refresh_token = new_refresh
                self._save_to_cache()
                log.debug("Cursor access token refreshed successfully")
            else:
                log.warning("Cursor token refresh response missing access_token")
        except Exception as exc:
            log.warning("Cursor token refresh failed: %s", exc)
