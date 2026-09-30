"""Mistral providers: "Vibe Code" (Vibe allowance) and "Vibe" (API allowance)."""

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


class _MistralSessionProvider:
    """Shared Safari-session plumbing for both Mistral allowances.

    Both endpoints authenticate with the same Ory session cookie the credential
    bridge caches, so they share one cache file and one expiry path.
    """

    API_URL = ""
    _EXTRA_HEADERS: dict[str, str] = {}
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

    def _read_body(self) -> str:
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
                **self._EXTRA_HEADERS,
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=15, context=default_ssl_context()) as resp:
                body = resp.read().decode("utf-8")
        except urllib.error.HTTPError as exc:
            if exc.code in (301, 302, 307, 308, 401, 403):
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

        return body

    def close(self) -> None:
        pass


def _monthly_cycle(reset_raw: object) -> tuple[str | None, datetime | None, str | None, str | None]:
    """Return (display reset, reset instant, start ISO, end ISO) for a calendar-month cycle."""
    if not isinstance(reset_raw, str) or not reset_raw:
        return None, None, None, None
    try:
        reset_target = datetime.fromisoformat(reset_raw.replace("Z", "+00:00"))
    except ValueError:
        return reset_raw, None, None, None
    display = f"Resets {reset_target.astimezone().strftime('%b %d at %I:%M %p')}"
    cycle_end_utc = reset_target.astimezone(timezone.utc)
    year = cycle_end_utc.year - (1 if cycle_end_utc.month == 1 else 0)
    month = 12 if cycle_end_utc.month == 1 else cycle_end_utc.month - 1
    start = datetime(year, month, 1, 0, 0, tzinfo=timezone.utc).isoformat()
    return display, reset_target, start, reset_target.isoformat()


def _parse_json(body: str) -> dict:
    try:
        payload = json.loads(body)
    except json.JSONDecodeError as exc:
        raise ProbeFailure("Mistral API returned invalid JSON", body[:500]) from exc
    if not isinstance(payload, dict):
        raise ProbeFailure("Mistral API returned an unexpected payload", body[:500])
    return payload


def _percent_or_none(raw: object) -> float | None:
    return round(float(raw), 4) if isinstance(raw, (int, float)) else None


@register("Vibe Code")
class VibeCodeProvider(_MistralSessionProvider):
    """Included Vibe Code allowance (what ``vibe -p`` bills)."""

    API_URL = "https://console.mistral.ai/api/billing/v2/vibe-usage"

    def fetch(self) -> VibeStatus:
        body = self._read_body()
        payload = _parse_json(body)
        reset_at, reset_target, cycle_start, cycle_end = _monthly_cycle(payload.get("reset_at"))
        start_date = payload.get("start_date")
        end_date = payload.get("end_date")
        if reset_target is not None:
            end_date = end_date or cycle_end
            start_date = start_date or cycle_start
        return VibeStatus(
            usage_percent=_percent_or_none(payload.get("usage_percentage")),
            reset_at=reset_at if reset_at is not None else payload.get("reset_at"),
            payg_enabled=payload.get("payg_enabled"),
            start_date=start_date,
            end_date=end_date,
            raw_text=body,
        )


@register("Vibe")
class VibeApiProvider(_MistralSessionProvider):
    """Included API/Studio allowance (what the Switchyard ``vibe`` target bills).

    Read from the admin console's ``billing.budget`` route, which reports both
    allowances; only ``api_budget`` is used here. ``usage_percentage`` is
    percent used, and the cycle is the calendar month ending at ``reset_at``.
    """

    API_URL = (
        "https://admin.mistral.ai/api/local-trpc/billing.budget"
        "?input=%7B%22json%22%3Anull%2C%22meta%22%3A%7B%22values%22%3A%5B%22undefined%22%5D"
        "%2C%22v%22%3A1%7D%7D"
    )
    _EXTRA_HEADERS = {"x-trpc-source": "nextjs-react"}

    def fetch(self) -> VibeStatus:
        body = self._read_body()
        payload = _parse_json(body)
        try:
            budget = payload["result"]["data"]["json"]["api_budget"]
        except (KeyError, TypeError) as exc:
            raise ProbeFailure("Mistral API budget missing from billing response", "") from exc
        if not isinstance(budget, dict):
            raise ProbeFailure("Mistral API budget missing from billing response", "")
        reset_at, _, start_date, end_date = _monthly_cycle(budget.get("reset_at"))
        return VibeStatus(
            usage_percent=_percent_or_none(budget.get("usage_percentage")),
            reset_at=reset_at,
            payg_enabled=None,
            start_date=start_date,
            end_date=end_date,
            raw_text=body,
        )
