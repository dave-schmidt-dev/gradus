"""Cursor provider using the local macOS Keychain and Cursor's dashboard API.

The Cursor CLI stores its session in fixed generic-password Keychain items.
Gradus reads them as a consumer only: no browser, no Safari, no Full Disk
Access, and no token refresh or write-back, so a Gradus probe can never
invalidate the CLI's own session.  This is the same transport shape as the
OpenCode Go provider.
"""

from __future__ import annotations

import json
import subprocess
from datetime import datetime, timezone
from typing import Any

from ..parsing import CursorStatus
from ..tls import default_ssl_context
from ._base import ProbeFailure, _auth_required_message, _is_headless, _is_jwt_expired, register

# Cursor is intentionally absent from history.py's _PROVENANCE_BY_PROVIDER, as it
# was before Task 2.3.7: this restore re-enables live capacity, not history capture.
USAGE_URL = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"

_RELOGIN = "Cursor session expired: run `cursor-agent login`"


@register("Cursor")
class CursorProvider:
    """Read Cursor plan usage from the CLI's Keychain session, read-only."""

    _USAGE_URL = USAGE_URL
    _PLAN_URL = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo"
    _KEYCHAIN_SERVICE = "cursor-access-token"
    _KEYCHAIN_ACCOUNT = "cursor-user"

    def __init__(self) -> None:
        self._access_token = ""

    def _acquire(self) -> None:
        if _is_headless():
            raise ProbeFailure("auth required: no cached credentials", "")
        if self._access_token:
            return
        try:
            token = self._load_keychain_token()
        except FileNotFoundError as exc:
            raise ProbeFailure(_auth_required_message(f"Cursor Keychain {exc}"), "") from exc
        if _is_jwt_expired(token):
            raise ProbeFailure(_auth_required_message(_RELOGIN), "")
        self._access_token = token

    @classmethod
    def _load_keychain_token(cls) -> str:
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
            raise FileNotFoundError("Could not read Cursor Keychain item") from exc
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
        token = result.stdout.strip()
        if not token or "\n" in token or "\r" in token:
            raise FileNotFoundError("Cursor Keychain item is invalid")
        return token

    @staticmethod
    def _as_float(value: Any) -> float | None:
        if value is None:
            return None
        try:
            return float(value)
        except (TypeError, ValueError):
            return None

    @staticmethod
    def _as_int(value: Any) -> int | None:
        if value is None:
            return None
        try:
            return int(value)
        except (TypeError, ValueError):
            return None

    @staticmethod
    def _epoch_ms_local(value: Any) -> datetime | None:
        try:
            return datetime.fromtimestamp(int(value) / 1000, tz=timezone.utc).astimezone()
        except (TypeError, ValueError, OSError, OverflowError):
            return None

    def fetch(self) -> CursorStatus:
        import urllib.error as _ue
        import urllib.request as _ur

        self._acquire()
        try:
            usage_data = self._api_post(_ur, self._USAGE_URL)
        except _ue.HTTPError as exc:
            if exc.code in (401, 403):
                self._access_token = ""
                raise ProbeFailure(_RELOGIN, f"HTTP {exc.code}") from exc
            raise ProbeFailure(f"Cursor API error: HTTP {exc.code}", "") from exc
        except (OSError, _ue.URLError) as exc:
            raise ProbeFailure(f"Cursor API network error: {exc}", "") from exc
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise ProbeFailure("Cursor usage response is malformed", "") from exc

        plan_data: dict[str, Any] = {}
        try:
            plan_data = self._api_post(_ur, self._PLAN_URL)
        except Exception:  # noqa: BLE001 - plan detail is optional decoration
            pass

        plan_usage = usage_data.get("planUsage")
        if not isinstance(plan_usage, dict):
            plan_usage = {}
        plan_info = plan_data.get("planInfo")
        if not isinstance(plan_info, dict):
            plan_info = {}

        remaining_cents = self._as_int(plan_usage.get("remaining"))
        limit_cents = self._as_int(plan_usage.get("limit"))
        credit_percent_left: float | None = None
        if remaining_cents is not None and limit_cents is not None and limit_cents > 0:
            credit_percent_left = round((remaining_cents / limit_cents) * 100.0, 2)
        if credit_percent_left is None:
            total_percent_used = self._as_float(plan_usage.get("totalPercentUsed"))
            if total_percent_used is not None:
                credit_percent_left = round(100.0 - total_percent_used, 2)
        if credit_percent_left is None:
            raise ProbeFailure("Cursor usage response schema changed", "")

        billing_cycle_start: str | None = None
        start_dt = self._epoch_ms_local(
            usage_data.get("billingCycleStart") or plan_data.get("billingCycleStart")
        )
        if start_dt is not None:
            billing_cycle_start = start_dt.isoformat()

        billing_cycle_end: str | None = None
        billing_cycle_end_iso: str | None = None
        end_dt = self._epoch_ms_local(
            usage_data.get("billingCycleEnd")
            or plan_data.get("billingCycleEnd")
            or plan_info.get("billingCycleEnd")
        )
        if end_dt is not None:
            billing_cycle_end = f"Resets {end_dt.strftime('%b %d at %I:%M %p')}"
            billing_cycle_end_iso = end_dt.isoformat()

        plan_name = plan_info.get("name") or plan_info.get("planName") or plan_data.get("planName")

        return CursorStatus(
            credit_percent_left=credit_percent_left,
            auto_percent_used=self._as_float(plan_usage.get("autoPercentUsed")),
            api_percent_used=self._as_float(plan_usage.get("apiPercentUsed")),
            remaining_cents=remaining_cents,
            limit_cents=limit_cents,
            plan_name=(plan_name if isinstance(plan_name, str) else None),
            billing_cycle_start=billing_cycle_start,
            billing_cycle_end=billing_cycle_end,
            billing_cycle_end_iso=billing_cycle_end_iso,
            raw_text=json.dumps({"usage": usage_data, "plan": plan_data}, indent=2, sort_keys=True),
        )

    def _api_post(self, ur: Any, url: str) -> dict[str, Any]:
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
        with ur.urlopen(req, timeout=15, context=default_ssl_context()) as resp:
            payload = json.loads(resp.read())
        return payload if isinstance(payload, dict) else {}

    def close(self) -> None:
        pass
