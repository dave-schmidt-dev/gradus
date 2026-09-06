"""Vibe (Mistral) provider."""

from __future__ import annotations

import json
from datetime import datetime, timezone

from ..parsing import VibeStatus
from ..tls import default_ssl_context
from ._base import (
    ProbeFailure,
    _auth_required_message,
    _harden_existing,
    _private_cache_path,
    _remove_private,
    register,
)


@register("Vibe")
class VibeProvider:
    API_URL = "https://console.mistral.ai/api/billing/v2/vibe-usage"
    _CACHE_PATH = _private_cache_path("vibe_cookies.json")

    def __init__(self, project_root: str) -> None:
        self._ory_name = ""
        self._ory_value = ""
        self._csrf = ""

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
        ory_name = data.get("ory_session_name")
        ory_value = data.get("ory_session_value")
        csrf = data.get("csrftoken")
        if not (
            isinstance(ory_name, str)
            and ory_name
            and isinstance(ory_value, str)
            and ory_value
            and isinstance(csrf, str)
            and csrf
        ):
            return False
        self._ory_name = ory_name
        self._ory_value = ory_value
        self._csrf = csrf
        _harden_existing(self._CACHE_PATH)
        return True

    def _clear_cache(self) -> None:
        _remove_private(self._CACHE_PATH)

    @property
    def _has_cookies(self) -> bool:
        return bool(self._ory_name and self._ory_value and self._csrf)

    def fetch(self) -> VibeStatus:
        import urllib.error
        import urllib.request

        self._acquire()
        if not self._has_cookies:
            # No cache means the credential bridge wrote nothing: either it
            # could not read Safari (Full Disk Access) or Safari holds no
            # console.mistral.ai session. Only the bridge's own typed outcome
            # can tell those apart, so this text must not claim "expired".
            raise ProbeFailure(
                _auth_required_message(
                    "Vibe session unavailable: no Safari session for console.mistral.ai reached "
                    "the credential bridge; Settings names the cause"
                ),
                "",
            )

        cookie_header = f"{self._ory_name}={self._ory_value}; csrftoken={self._csrf}"
        req = urllib.request.Request(
            self.API_URL,
            headers={
                "Cookie": cookie_header,
                "x-csrftoken": self._csrf,
                "Accept": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=15, context=default_ssl_context()) as resp:
                body = resp.read().decode("utf-8")
        except urllib.error.HTTPError as exc:
            if exc.code in (301, 302, 401, 403):
                self._ory_name = self._ory_value = self._csrf = ""
                self._clear_cache()
                raise ProbeFailure(
                    "Mistral session expired: sign in at console.mistral.ai in Safari",
                    f"HTTP {exc.code}",
                ) from exc
            raise ProbeFailure(f"Mistral API returned HTTP {exc.code}", str(exc)) from exc
        except urllib.error.URLError as exc:
            # Speaks the `_is_transient_probe_error` vocabulary deliberately --
            # see the same fix in `opencode_go._call_server_fn`. `exc.reason` is
            # a socket-level errno, not vendor text, so it carries no credential
            # material and is safe on the published surface.
            raise ProbeFailure(f"Mistral API network error: {exc.reason}", str(exc)) from exc

        try:
            payload = json.loads(body)
        except json.JSONDecodeError as exc:
            raise ProbeFailure("Mistral API returned invalid JSON", body[:500]) from exc

        usage_pct_raw = payload.get("usage_percentage")
        usage_percent = round(float(usage_pct_raw), 4) if usage_pct_raw is not None else None
        reset_raw = payload.get("reset_at")
        reset_at = reset_raw
        reset_target: datetime | None = None
        if reset_raw:
            try:
                reset_target = datetime.fromisoformat(reset_raw.replace("Z", "+00:00"))
                reset_at = f"Resets {reset_target.astimezone().strftime('%b %d at %I:%M %p')}"
            except ValueError:
                pass

        start_date = payload.get("start_date")
        end_date = payload.get("end_date")
        if reset_target is not None:
            if not end_date:
                end_date = reset_target.isoformat()
            if not start_date:
                cycle_end_utc = reset_target.astimezone(timezone.utc)
                year = cycle_end_utc.year - (1 if cycle_end_utc.month == 1 else 0)
                month = 12 if cycle_end_utc.month == 1 else cycle_end_utc.month - 1
                start_date = datetime(year, month, 1, 0, 0, tzinfo=timezone.utc).isoformat()

        return VibeStatus(
            usage_percent=usage_percent,
            reset_at=reset_at,
            payg_enabled=payload.get("payg_enabled"),
            start_date=start_date,
            end_date=end_date,
            raw_text=body,
        )

    def close(self) -> None:
        pass
