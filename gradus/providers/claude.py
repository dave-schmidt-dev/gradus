"""Claude provider."""

from __future__ import annotations

import json
import logging
import math
import time
from pathlib import Path
from uuid import UUID

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
    _STATUS_CACHE_PATH = (
        Path(__file__).resolve().parent.parent.parent / ".state" / "claude-usage.json"
    )
    _STATUS_CACHE_MAX_AGE_SECONDS = 300
    _ORGANIZATIONS_URL = f"{_BASE_URL}/api/organizations"

    _log = logging.getLogger(__name__)

    def __init__(self) -> None:
        self._session_key: str = ""
        self._cf_clearance: str = ""
        self._org_id: str = ""
        self._cache_needs_org_persist = False

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
        if not isinstance(session_key, str) or not session_key.startswith("sk-ant-"):
            return False
        self._session_key = session_key
        org_id = data.get("lastActiveOrg")
        if isinstance(org_id, str):
            self._org_id = self._normalize_org_id(org_id) or ""
        self._cache_needs_org_persist = not bool(self._org_id)
        cf = data.get("cf_clearance")
        if isinstance(cf, str):
            self._cf_clearance = cf
        _harden_existing(self._CACHE_PATH)
        return True

    def _clear_cache(self) -> None:
        _remove_private(self._CACHE_PATH)

    @staticmethod
    def _normalize_org_id(value: str) -> str | None:
        try:
            return str(UUID(value.strip()))
        except (AttributeError, ValueError):
            return None

    def _resolve_org_id(self) -> str:
        headers = {
            "Cookie": f"sessionKey={self._session_key}",
            "Accept": "application/json",
            "Referer": "https://claude.ai/",
            "Origin": "https://claude.ai",
            "User-Agent": (
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/605.1.15 (KHTML, like Gecko) "
                "Version/18.0 Safari/605.1.15"
            ),
        }
        try:
            payload = _base._http_json(self._ORGANIZATIONS_URL, headers=headers)
        except ProbeFailure as exc:
            # Never retain a response body here: an error response can contain
            # account or credential material.
            message = str(exc)
            status = next(
                (code for code in (400, 401, 403) if message.startswith(f"HTTP {code}")),
                None,
            )
            safe_message = (
                f"HTTP {status}" if status is not None else "Claude organizations request failed"
            )
            raise ProbeFailure(safe_message, "") from exc

        if not isinstance(payload, list):
            raise ProbeFailure("Claude organizations response is invalid", "")
        organizations: list[tuple[str, set[str]]] = []
        for organization in payload:
            if not isinstance(organization, dict):
                raise ProbeFailure("Claude organizations response is invalid", "")
            raw_id = organization.get("uuid")
            if not isinstance(raw_id, str):
                raise ProbeFailure("Claude organizations response is invalid", "")
            normalized = self._normalize_org_id(raw_id)
            if normalized is None:
                raise ProbeFailure("Claude organizations response is invalid", "")
            capabilities = organization.get("capabilities", [])
            if capabilities is None:
                capabilities = []
            if not isinstance(capabilities, list) or not all(
                isinstance(capability, str) for capability in capabilities
            ):
                raise ProbeFailure("Claude organizations response is invalid", "")
            organizations.append((normalized, {capability.lower() for capability in capabilities}))

        unique: dict[str, set[str]] = {}
        for organization_id, capabilities in organizations:
            unique.setdefault(organization_id, capabilities)
        if not unique:
            raise ProbeFailure("Claude organization is unavailable", "")

        if len(unique) == 1:
            return next(iter(unique))

        chat_ids = [
            organization_id
            for organization_id, capabilities in unique.items()
            if "chat" in capabilities
        ]
        if len(chat_ids) == 1:
            return chat_ids[0]

        non_api_ids = [
            organization_id
            for organization_id, capabilities in unique.items()
            if capabilities != {"api"}
        ]
        if len(non_api_ids) == 1:
            return non_api_ids[0]

        if len(unique) > 1:
            raise ProbeFailure("Claude organization selection is ambiguous", "")
        raise ProbeFailure("Claude organization is unavailable", "")

    def _persist_resolved_org(self) -> None:
        if not self._cache_needs_org_persist or not self._org_id:
            return
        try:
            data = json.loads(self._CACHE_PATH.read_text(encoding="utf-8"))
            if not isinstance(data, dict):
                return
            data["lastActiveOrg"] = self._org_id
            _base._write_private(self._CACHE_PATH, json.dumps(data, sort_keys=True))
            self._cache_needs_org_persist = False
        except (OSError, TypeError, ValueError) as exc:
            # Usage remains usable if a cache update races another writer; never
            # turn this into a credential-bearing diagnostic.
            self._log.warning(
                "Claude organization cache update unavailable: %s", type(exc).__name__
            )

    @property
    def _has_cookies(self) -> bool:
        return bool(self._session_key)

    def _load_status_cache(self) -> ClaudeStatus | None:
        """Return a recent credential-free Claude status-line sample."""
        try:
            payload = json.loads(self._STATUS_CACHE_PATH.read_text(encoding="utf-8"))
            if not isinstance(payload, dict) or payload.get("schema_version") != 1:
                return None
            observed_at = payload.get("observed_at")
            if (
                not isinstance(observed_at, (int, float))
                or isinstance(observed_at, bool)
                or not math.isfinite(float(observed_at))
            ):
                return None
            age = time.time() - float(observed_at)
            if not 0 <= age < self._STATUS_CACHE_MAX_AGE_SECONDS:
                return None

            def _values(name: str) -> tuple[float | None, str | None]:
                raw = payload.get(name)
                if raw is None:
                    return None, None
                if not isinstance(raw, dict):
                    raise ValueError
                used = raw.get("used_percentage")
                if (
                    not isinstance(used, (int, float))
                    or isinstance(used, bool)
                    or not math.isfinite(float(used))
                    or not 0 <= float(used) <= 100
                ):
                    raise ValueError
                reset = raw.get("resets_at")
                if reset is not None and (
                    not isinstance(reset, (int, float))
                    or isinstance(reset, bool)
                    or not math.isfinite(float(reset))
                    or float(reset) <= 0
                ):
                    raise ValueError
                return 100.0 - float(used), _format_reset_time(reset)

            session_percent_left, primary_reset = _values("five_hour")
            weekly_percent_left, secondary_reset = _values("seven_day")
            if session_percent_left is None and weekly_percent_left is None:
                return None
            return ClaudeStatus(
                session_percent_left=session_percent_left,
                weekly_percent_left=weekly_percent_left,
                opus_percent_left=None,
                primary_reset=primary_reset,
                secondary_reset=secondary_reset,
                opus_reset=None,
                account_email=None,
                account_organization=None,
                login_method=None,
                raw_text=json.dumps(payload, sort_keys=True),
            )
        except (OSError, json.JSONDecodeError, ValueError):
            return None

    def fetch(self) -> ClaudeStatus:
        cached_status = self._load_status_cache()
        if cached_status is not None:
            return cached_status
        self._acquire()
        if not self._session_key:
            raise ProbeFailure(
                _auth_required_message("Claude session expired: sign in at claude.ai"), ""
            )

        try:
            if not self._org_id:
                self._org_id = self._resolve_org_id()
                self._persist_resolved_org()

            url = f"{self._BASE_URL}/api/organizations/{self._org_id}/usage"
            cookie_parts = [f"sessionKey={self._session_key}"]
            if self._cf_clearance:
                cookie_parts.append(f"cf_clearance={self._cf_clearance}")
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
