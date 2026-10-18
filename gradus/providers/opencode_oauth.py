"""OpenCode Console OAuth authentication and status probe."""

from __future__ import annotations

import json
import math
import sqlite3
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from http.client import HTTPException
from pathlib import Path
from typing import Any

from ..parsing import OpenCodeGoStatus
from ..tls import default_ssl_context
from ._base import ProbeFailure, _format_reset_time

OPENCODE_CONSOLE_DEFAULT_SERVER = "https://opencode.ai/console"
OPENCODE_CONSOLE_STATUS_URL = "https://opencode.ai/console/api/go/status"
OPENCODE_INTEGRATION_ID = "opencode"
DEFAULT_OPENCODE_DB_PATH = Path.home() / ".local" / "share" / "opencode" / "opencode.db"
USER_AGENT = "gradus (opencode-go quota probe)"

MAX_JSON_SIZE = 65536
MAX_BODY_READ = 65536
MAX_ERROR_BODY_READ = 4096


@dataclass(frozen=True)
class OpenCodeOAuthCredential:
    """Read-only container for OpenCode Console OAuth credentials."""

    access: str = field(repr=False)
    expires_ms: int
    server: str
    org_id: str | None = field(default=None, repr=False)


def validate_console_server(server: str | None) -> str:
    """Validate server metadata against exact official Console origin/path."""
    if server is None:
        return OPENCODE_CONSOLE_DEFAULT_SERVER
    if not isinstance(server, str):
        raise ProbeFailure("OpenCode OAuth server is untrusted", "")
    normalized = server.rstrip("/")
    if normalized != OPENCODE_CONSOLE_DEFAULT_SERVER:
        raise ProbeFailure("OpenCode OAuth server is untrusted", "")
    return normalized


def load_opencode_oauth_credential(
    db_path: Path | str | None = None,
    *,
    now_ms: float | None = None,
) -> OpenCodeOAuthCredential | None:
    """Load active OpenCode OAuth credential from SQLite store read-only.

    Returns None if OAuth is absent (no DB, table missing, or no active credential),
    which authorizes legacy Keychain API-key fallback. Raises ProbeFailure for
    actionable OAuth conditions (expired, ambiguous multiple active, untrusted server).
    """
    path = DEFAULT_OPENCODE_DB_PATH if db_path is None else Path(db_path)
    if not path.is_file():
        return None

    uri = path.resolve().as_uri() + "?mode=ro"
    try:
        conn = sqlite3.connect(uri, uri=True, timeout=1.0)
    except (sqlite3.DatabaseError, OSError) as exc:
        raise ProbeFailure("OpenCode OAuth database unavailable", "") from exc

    try:
        cursor = conn.cursor()
        cursor.execute("PRAGMA query_only = ON")
        if (
            cursor.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='credential'"
            ).fetchone()
            is None
        ):
            return None
        cursor.execute(
            "SELECT id, value, active FROM credential WHERE integration_id = ? AND active = 1 LIMIT 2",
            (OPENCODE_INTEGRATION_ID,),
        )
        rows = cursor.fetchall()
    except (sqlite3.DatabaseError, OSError) as exc:
        raise ProbeFailure("OpenCode OAuth database unavailable", "") from exc
    finally:
        conn.close()

    active_rows = [row for row in rows if row[2] in (1, "1", True)]
    if not active_rows:
        return None
    if len(active_rows) > 1:
        raise ProbeFailure(
            "OpenCode OAuth credential selection ambiguous: multiple active credentials",
            "",
        )

    _, value_raw, _ = active_rows[0]
    if not isinstance(value_raw, str) or len(value_raw) > MAX_JSON_SIZE:
        raise ProbeFailure("OpenCode OAuth credential is malformed", "")

    try:
        data = json.loads(value_raw)
    except (json.JSONDecodeError, RecursionError) as exc:
        raise ProbeFailure("OpenCode OAuth credential is malformed", "") from exc

    if not isinstance(data, dict):
        raise ProbeFailure("OpenCode OAuth credential is malformed", "")

    if data.get("type") != "oauth":
        return None

    access = data.get("access")
    if (
        not isinstance(access, str)
        or not access
        or not access.isascii()
        or any(c.isspace() or ord(c) < 32 for c in access)
    ):
        raise ProbeFailure("OpenCode OAuth credential is missing access token", "")

    expires = data.get("expires")
    try:
        expiry_is_finite = isinstance(expires, (int, float)) and math.isfinite(expires)
    except OverflowError:
        expiry_is_finite = False
    if isinstance(expires, bool) or not isinstance(expires, (int, float)) or not expiry_is_finite:
        raise ProbeFailure("OpenCode OAuth credential has invalid expiry", "")

    metadata = data.get("metadata")
    if metadata is not None and not isinstance(metadata, dict):
        raise ProbeFailure("OpenCode OAuth credential is malformed", "")

    server = metadata.get("server") if isinstance(metadata, dict) else None
    validated_server = validate_console_server(server)

    org_id = metadata.get("orgID") if isinstance(metadata, dict) else None
    if not isinstance(org_id, str):
        org_id = None
    elif not org_id or not org_id.isascii() or any(c.isspace() or ord(c) < 32 for c in org_id):
        raise ProbeFailure("OpenCode OAuth workspace metadata is malformed", "")

    current_time = (time.time() * 1000.0) if now_ms is None else float(now_ms)
    if float(expires) <= current_time:
        raise ProbeFailure("OpenCode OAuth token expired: open OpenCode to refresh", "")

    return OpenCodeOAuthCredential(
        access=access,
        expires_ms=int(expires),
        server=validated_server,
        org_id=org_id,
    )


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Deny redirects to prevent leaking bearer tokens or following untrusted hosts."""

    def redirect_request(
        self,
        req: urllib.request.Request,
        _fp: Any,
        code: int,
        msg: str,
        headers: Any,
        _newurl: str,
    ) -> None:
        return None


def _is_cloudflare_403(exc: urllib.error.HTTPError) -> bool:
    """Identify Cloudflare browser-signature blocks from bounded response data."""
    try:
        body = exc.read(MAX_ERROR_BODY_READ)
    except Exception:
        body = b""
    if not body:
        return False
    lower = body.lower()
    if b"error 1010" in lower or b"error-1010" in lower or b"browser signature" in lower:
        return True
    try:
        data = json.loads(body.decode("utf-8", errors="replace"))
        if isinstance(data, dict):
            type_val = str(data.get("type", "")).lower()
            title_val = str(data.get("title", "")).lower()
            detail_val = str(data.get("detail", "")).lower()
            if "1010" in type_val or "cloudflare" in type_val:
                return True
            if "error 1010" in title_val:
                return True
            if "browser signature" in detail_val:
                return True
    except Exception:
        pass
    return False


def _parse_oauth_meter(
    meter: Any,
    fallback_reset: Any = None,
) -> tuple[float | None, str | None]:
    """Parse and strictly validate a meter window (usedMicroCents / limitMicroCents)."""
    if not isinstance(meter, dict):
        return None, None
    used_raw = meter.get("usedMicroCents")
    limit_raw = meter.get("limitMicroCents")

    if isinstance(used_raw, bool) or isinstance(limit_raw, bool):
        return None, None
    if not isinstance(used_raw, (int, float, str)) or not isinstance(limit_raw, (int, float, str)):
        return None, None
    try:
        used_raw, limit_raw = float(used_raw), float(limit_raw)
    except (ValueError, OverflowError):
        return None, None
    if not math.isfinite(used_raw) or not math.isfinite(limit_raw):
        return None, None
    if limit_raw <= 0 or used_raw < 0:
        return None, None

    used_ratio = float(used_raw) / float(limit_raw)
    percent_left = round(max(0.0, min(100.0, (1.0 - used_ratio) * 100.0)), 2)

    reset_val = (
        meter.get("resetsAt")
        or meter.get("resetAt")
        or meter.get("reset")
        or meter.get("endsAt")
        or fallback_reset
    )
    reset_str = _format_reset_time(reset_val)
    return percent_left, reset_str


def parse_console_status_payload(payload: Any) -> OpenCodeGoStatus:
    """Map Console OAuth status JSON response into OpenCodeGoStatus."""
    if not isinstance(payload, dict):
        raise ProbeFailure("OpenCode OAuth response is malformed", "")
    if "access" not in payload:
        raise ProbeFailure("OpenCode OAuth response schema changed", "")
    access = payload.get("access")
    if access is None:
        raise ProbeFailure("OpenCode Go subscription unavailable: no active subscription", "")
    if not isinstance(access, dict):
        raise ProbeFailure("OpenCode OAuth response schema changed", "")

    meters = access.get("meters")
    if not isinstance(meters, dict):
        raise ProbeFailure("OpenCode OAuth response schema changed", "")

    five_hour_meter = meters.get("fiveHour") or meters.get("five_hour")
    p_5h, r_5h = _parse_oauth_meter(five_hour_meter)

    week_meter = meters.get("week") or meters.get("weekly")
    p_week, r_week = _parse_oauth_meter(week_meter)

    month_meter = meters.get("month") or meters.get("monthly")
    p_month, r_month = _parse_oauth_meter(month_meter, fallback_reset=access.get("endsAt"))

    if p_5h is None and p_week is None and p_month is None:
        raise ProbeFailure("OpenCode Go usage response has no recognizable windows", "")

    return OpenCodeGoStatus(
        five_hour_percent_left=p_5h,
        five_hour_reset=r_5h,
        weekly_percent_left=p_week,
        weekly_reset=r_week,
        monthly_percent_left=p_month,
        monthly_reset=r_month,
        zen_credit=None,
        raw_text="",
    )


def fetch_console_oauth_status(
    credential: OpenCodeOAuthCredential,
    *,
    timeout: int = 15,
    opener: urllib.request.OpenerDirector | None = None,
) -> OpenCodeGoStatus:
    """Fetch status from OpenCode Console OAuth endpoint."""
    server = validate_console_server(credential.server)
    url = f"{server}/api/go/status"

    headers = {
        "Authorization": f"Bearer {credential.access}",
        "Accept": "application/json",
        "User-Agent": USER_AGENT,
    }
    if credential.org_id:
        headers["x-org-id"] = credential.org_id

    req = urllib.request.Request(url, headers=headers, method="GET")

    if opener is None:
        opener = urllib.request.build_opener(
            urllib.request.HTTPSHandler(context=default_ssl_context()),
            NoRedirectHandler(),
        )

    try:
        with opener.open(req, timeout=timeout) as resp:
            raw_bytes = resp.read(MAX_BODY_READ + 1)
            if len(raw_bytes) > MAX_BODY_READ:
                raise ProbeFailure("OpenCode OAuth usage response too large", "")
            payload = json.loads(raw_bytes.decode("utf-8"))
    except urllib.error.HTTPError as exc:
        if exc.code in (301, 302, 303, 307, 308):
            raise ProbeFailure("OpenCode OAuth API redirected: redirects denied", "") from exc
        if exc.code == 401:
            raise ProbeFailure(
                "OpenCode OAuth session expired or revoked: reconnect OpenCode Console",
                "",
            ) from exc
        if exc.code == 403:
            if _is_cloudflare_403(exc):
                raise ProbeFailure(
                    "OpenCode Go access blocked (Cloudflare 403)",
                    "",
                ) from exc
            raise ProbeFailure(
                "OpenCode OAuth API error: HTTP 403 (permission denied)", ""
            ) from exc
        raise ProbeFailure(f"OpenCode OAuth API error: HTTP {exc.code}", "") from exc
    except urllib.error.URLError as exc:
        raise ProbeFailure("OpenCode OAuth network error", "") from exc
    except (TimeoutError, OSError, HTTPException) as exc:
        raise ProbeFailure("OpenCode OAuth network error", "") from exc
    except (json.JSONDecodeError, UnicodeDecodeError, TypeError) as exc:
        raise ProbeFailure("OpenCode OAuth usage response is malformed", "") from exc

    return parse_console_status_payload(payload)
