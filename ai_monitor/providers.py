"""Provider probes for Codex, Claude, Antigravity, and Cursor usage."""

from __future__ import annotations

import json
import logging
import os
import subprocess
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.padding import PKCS7

from .parsing import (
    AntigravityStatus,
    ClaudeStatus,
    CodexStatus,
    CursorStatus,
    VibeStatus,
)

log = logging.getLogger(__name__)

_HEADLESS = False


def set_headless(value: bool) -> None:
    """Enable or disable strictly read-only headless mode (INV-2).

    In headless mode the providers never spawn a browser, never run a
    Keychain/cookie subprocess, never refresh a token, and never evict or
    write a credential cache. Missing, expired, or rejected credentials surface
    as a truthful auth error instead of triggering any recovery side effect.

    Args:
        value: True to enable read-only headless mode, False to restore the
            default interactive behavior.
    """
    global _HEADLESS
    _HEADLESS = bool(value)


def _is_headless() -> bool:
    """Return True when read-only headless mode is active (INV-2)."""
    return _HEADLESS


@dataclass(slots=True)
class ProviderSnapshot:
    name: str
    ok: bool
    source: str
    data: dict[str, Any] | None = None
    error: str | None = None
    cached_since: datetime | None = None
    debug_detail: str | None = None


class ProbeFailure(RuntimeError):
    """Raised when a provider captured output but parsing still failed."""

    def __init__(self, message: str, raw_text: str) -> None:
        super().__init__(message)
        self.raw_text = raw_text


def _http_json(
    url: str,
    *,
    method: str = "GET",
    headers: dict[str, str] | None = None,
    body: bytes | None = None,
    timeout: int = 15,
) -> dict[str, Any]:
    """HTTP request returning parsed JSON. Raises ProbeFailure on error."""
    import urllib.error
    import urllib.request

    req = urllib.request.Request(url, data=body, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
            raw = resp.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        # Capture the error body in raw_text so callers can inspect provider-specific
        # error codes (e.g. Codex distinguishes token_invalidated from
        # refresh_token_invalidated, which determines whether a silent refresh helps).
        try:
            err_body = exc.read().decode("utf-8", errors="replace")
        except Exception:  # pragma: no cover - defensive
            err_body = ""
        raise ProbeFailure(f"HTTP {exc.code}", err_body) from exc
    except urllib.error.URLError as exc:
        raise ProbeFailure(f"Network error: {exc.reason}", f"{method} {url}") from exc
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ProbeFailure("Invalid JSON response", raw[:500]) from exc


def _format_reset_time(value: str | int | float | None) -> str | None:
    """Convert ISO 8601 string or epoch seconds/ms to 'Resets Mon DD at HH:MM AM/PM'."""
    if value is None:
        return None
    try:
        if isinstance(value, str):
            target = datetime.fromisoformat(value.replace("Z", "+00:00"))
        else:
            # Epoch milliseconds if > 1e12, else epoch seconds
            secs = float(value) / 1000.0 if float(value) > 1e12 else float(value)
            target = datetime.fromtimestamp(secs, tz=timezone.utc)
        return f"Resets {target.astimezone().strftime('%b %d at %I:%M %p')}"
    except (ValueError, OSError, OverflowError):
        return None


def _debug_dump_path(name: str) -> Path:
    safe_name = name.lower().replace(" ", "_")
    return Path("/tmp") / f"ai_monitor_{safe_name}_capture.txt"


def _write_debug_dump(name: str, raw_text: str) -> None:
    if _HEADLESS:
        return
    # The dump lives in /tmp — a shared, root-owned 1777 dir that must NOT be
    # chmod'd (as a normal user that raises PermissionError and crashes --debug;
    # as root it would strip /tmp's sticky bit machine-wide). The 0600 file mode
    # still keeps the dump contents private, so harden the file but not the dir.
    _write_private(_debug_dump_path(name), raw_text, harden_parent=False)


def _write_private(path: Path, text: str, *, harden_parent: bool = True) -> None:
    """Atomically write `text` to `path` at mode 0600 via tempfile.mkstemp
    (born 0600, independent of umask) + os.replace, so the destination is never
    world-readable even momentarily. Single sanctioned path for all
    credential/secret writes (INV-6).

    When `harden_parent` is True (default — for dedicated credential dirs like
    .cache/ and ~/.codex/), the parent dir is also chmod'd 0700. Pass
    harden_parent=False for a shared dir that must not be chmod'd (e.g. /tmp):
    the 0600 file mode still protects the contents and os.replace onto the final
    name stays symlink-safe.
    """
    if _is_headless():
        # INV-2: read-only mode performs no credential/secret writes.
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    if harden_parent:
        os.chmod(path.parent, 0o700)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=path.name + ".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _remove_private(path: Path) -> None:
    """Delete a credential/cache file, or no-op under headless (INV-2).

    The single sanctioned path for credential-cache eviction. In read-only
    headless mode this is a no-op so a rejected-credential probe never evicts
    the cache. An OSError is logged (a stuck cache file means the next 401 will
    not recover) but never propagates.
    """
    if _is_headless():
        return
    try:
        path.unlink(missing_ok=True)
    except OSError as exc:
        log.warning("Failed to delete credential cache at %s: %s", path, exc)


def _harden_existing(path: Path) -> None:
    """Best-effort chmod an existing credential file to 0600, or no-op under
    headless (INV-2: no filesystem mutation on the read-only path).

    Opportunistic tightening for a cache file just loaded from disk; a failure
    is swallowed because _write_private already guarantees 0600 for files it
    writes.
    """
    if _is_headless():
        return
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def _auth_required_message(interactive: str) -> str:
    """Auth-error text for a missing-credential fetch.

    Under headless (INV-2) return a generic, PII-free string; interactively
    return the actionable sign-in nudge. Both contain an auth keyword so
    _is_auth_error() routes the snapshot to the [n] fix-action CTA.
    """
    return "auth required: no cached credentials" if _is_headless() else interactive


def _is_jwt_expired(token: str, leeway_seconds: int = 60) -> bool:
    """Best-effort check: True if a JWT's `exp` claim is in the past (with leeway)."""
    import base64
    import time

    try:
        payload_b64 = token.split(".")[1]
    except IndexError:
        return False  # not a JWT, let the API decide
    padded = payload_b64 + "=" * (-len(payload_b64) % 4)
    try:
        payload = json.loads(base64.urlsafe_b64decode(padded))
    except (ValueError, json.JSONDecodeError):
        return False
    exp = payload.get("exp")
    if not isinstance(exp, (int, float)):
        return False
    return time.time() + leeway_seconds >= exp


def _read_safari_cookies(host_filter: str) -> dict[str, str]:
    """Parse Safari's Cookies.binarycookies file, return cookies matching host_filter.

    Returns a dict of {cookie_name: cookie_value} for cookies whose URL
    contains host_filter (case-insensitive).
    """
    if _HEADLESS:
        return {}

    import struct

    cookie_file = (
        Path.home()
        / "Library"
        / "Containers"
        / "com.apple.Safari"
        / "Data"
        / "Library"
        / "Cookies"
        / "Cookies.binarycookies"
    )
    if not cookie_file.exists():
        return {}

    try:
        data = cookie_file.read_bytes()
    except OSError:
        return {}

    if len(data) < 8 or data[:4] != b"cook":
        return {}

    num_pages = struct.unpack(">I", data[4:8])[0]
    page_sizes: list[int] = []
    offset = 8
    for _ in range(num_pages):
        if offset + 4 > len(data):
            return {}
        page_sizes.append(struct.unpack(">I", data[offset : offset + 4])[0])
        offset += 4

    cookies: dict[str, str] = {}

    for page_size in page_sizes:
        page_data = data[offset : offset + page_size]
        offset += page_size
        if len(page_data) < 8:
            continue
        cookie_count = struct.unpack("<I", page_data[4:8])[0]
        cookie_offsets: list[int] = []
        co = 8
        for _ in range(cookie_count):
            if co + 4 > len(page_data):
                break
            cookie_offsets.append(struct.unpack("<I", page_data[co : co + 4])[0])
            co += 4

        for c_off in cookie_offsets:
            if c_off + 48 > len(page_data):
                continue
            cookie_data = page_data[c_off:]
            if len(cookie_data) < 48:
                continue

            def _read_cstr(d: bytes, o: int) -> str:
                end = d.index(b"\x00", o) if b"\x00" in d[o:] else len(d)
                return d[o:end].decode("utf-8", errors="replace")

            try:
                url_off = struct.unpack("<I", cookie_data[16:20])[0]
                name_off = struct.unpack("<I", cookie_data[20:24])[0]
                value_off = struct.unpack("<I", cookie_data[28:32])[0]
                url = _read_cstr(cookie_data, url_off)
                name = _read_cstr(cookie_data, name_off)
                value = _read_cstr(cookie_data, value_off)
            except (ValueError, IndexError):
                continue

            if host_filter.lower() in url.lower():
                cookies[name] = value

    return cookies


class VibeProvider:
    """Fetch usage from the Mistral Vibe console API using browser cookies."""

    COOKIE_FILENAME = ".mistral_cookies.json"
    API_URL = "https://console.mistral.ai/api/billing/v2/vibe-usage"
    # See CursorProvider._CACHE_PATH for the rationale: browser cookie files lag
    # behind in-memory state, so we persist the cookies after a successful read.
    _CACHE_PATH = Path(__file__).resolve().parent.parent / ".cache" / "vibe_cookies.json"

    def __init__(self, project_root: str) -> None:
        self._project_root = project_root
        self._ory_name = ""
        self._ory_value = ""
        self._csrf = ""

    def _acquire(self) -> None:
        """Ensure cookies are loaded, idempotently.

        Re-attempts the load whenever cookies are still absent, so a user who
        logs in mid-session is picked up on the next fetch.
        """
        if not self._has_cookies:
            self._load_cookies()

    def _load_cookies(self) -> None:
        """Try all cookie sources; a pure read that never launches a browser.

        When no credentials are available the fields stay empty and fetch()
        surfaces an auth-CTA snapshot; the [n] fix-action opens the login page
        on demand.
        """
        if self._load_from_cache():
            return
        cookies = self._extract_safari_cookies() or self._extract_chrome_cookies()
        if cookies is None:
            cookie_path = Path(self._project_root) / self.COOKIE_FILENAME
            if cookie_path.exists():
                cookies = self._load_cookie_file(cookie_path)
        if cookies:
            self._ory_name = cookies["ory_session_name"]
            self._ory_value = cookies["ory_session_value"]
            self._csrf = cookies["csrftoken"]
            self._save_to_cache()

    def _load_from_cache(self) -> bool:
        """Load cookies from local cache. Returns True if a usable set was loaded."""
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

    def _save_to_cache(self) -> None:
        """Persist current cookies to local cache."""
        if not (self._ory_name and self._ory_value and self._csrf):
            return
        try:
            payload = {
                "ory_session_name": self._ory_name,
                "ory_session_value": self._ory_value,
                "csrftoken": self._csrf,
                "cached_at": datetime.now().isoformat(),
            }
            _write_private(self._CACHE_PATH, json.dumps(payload))
        except OSError as exc:
            log.warning("Failed to write Vibe cookie cache: %s", exc)

    def _clear_cache(self) -> None:
        """Remove the local cookie cache (call when cookies are rejected by the API)."""
        _remove_private(self._CACHE_PATH)

    @property
    def _has_cookies(self) -> bool:
        return bool(self._ory_name and self._ory_value and self._csrf)

    @staticmethod
    def _load_cookie_file(cookie_path: Path) -> dict[str, str]:
        """Load cookies from a manual JSON file."""
        try:
            data = json.loads(cookie_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as exc:
            raise ValueError(f"Failed to read Mistral cookies from {cookie_path}: {exc}") from exc
        ory_name = data.get("ory_session_name", "")
        ory_value = data.get("ory_session_value", "")
        csrf = data.get("csrftoken", "")
        if not ory_name or not ory_value or not csrf:
            raise ValueError(
                f"Mistral cookie file {cookie_path} must contain "
                '"ory_session_name", "ory_session_value", and "csrftoken" keys '
                "with non-empty values."
            )
        return {
            "ory_session_name": ory_name,
            "ory_session_value": ory_value,
            "csrftoken": csrf,
        }

    @staticmethod
    def _extract_chrome_cookies() -> dict[str, str] | None:
        """Try to extract Mistral cookies from Chrome's encrypted cookie store."""
        if _HEADLESS:
            return None

        import hashlib
        import sqlite3 as _sqlite3

        chrome_cookies = (
            Path.home()
            / "Library"
            / "Application Support"
            / "Google"
            / "Chrome"
            / "Default"
            / "Cookies"
        )
        if not chrome_cookies.exists():
            return None

        # Get Chrome's encryption key from macOS Keychain
        try:
            result = subprocess.run(
                [
                    "security",
                    "find-generic-password",
                    "-s",
                    "Chrome Safe Storage",
                    "-w",
                ],
                capture_output=True,
                text=True,
                timeout=5,
                check=True,
            )
            chrome_password = result.stdout.strip()
        except (subprocess.SubprocessError, OSError):
            return None

        # Derive AES key via PBKDF2
        key = hashlib.pbkdf2_hmac(
            "sha1",
            chrome_password.encode("utf-8"),
            b"saltysalt",
            1003,
            dklen=16,
        )

        # Query Chrome's cookie database for mistral.ai cookies
        try:
            conn = _sqlite3.connect(f"file:{chrome_cookies}?mode=ro", uri=True)
            try:
                rows = conn.execute(
                    "SELECT name, encrypted_value FROM cookies "
                    "WHERE host_key LIKE '%mistral.ai%' "
                    "AND (name LIKE 'ory_session_%' OR name = 'csrftoken')"
                ).fetchall()
            finally:
                conn.close()
        except _sqlite3.Error:
            return None

        if not rows:
            return None

        # Decrypt each cookie value
        ory_name = ""
        ory_value = ""
        csrf = ""
        for name, encrypted_value in rows:
            if not encrypted_value:
                continue
            decrypted = VibeProvider._decrypt_chrome_cookie(key, encrypted_value)
            if decrypted is None:
                continue
            if name.startswith("ory_session_"):
                ory_name = name
                ory_value = decrypted
            elif name == "csrftoken":
                csrf = decrypted

        if ory_name and ory_value and csrf:
            log.debug("Extracted Mistral cookies from Chrome automatically")
            return {
                "ory_session_name": ory_name,
                "ory_session_value": ory_value,
                "csrftoken": csrf,
            }
        return None

    @staticmethod
    def _extract_safari_cookies() -> dict[str, str] | None:
        """Try to extract Mistral cookies from Safari's binarycookies store."""
        cookies = _read_safari_cookies("mistral")
        ory_name = next((k for k in cookies if k.startswith("ory_session_")), "")
        ory_value = cookies.get(ory_name, "")
        csrf = cookies.get("csrftoken", "")
        if ory_name and ory_value and csrf:
            log.debug("Extracted Mistral cookies from Safari automatically")
            return {
                "ory_session_name": ory_name,
                "ory_session_value": ory_value,
                "csrftoken": csrf,
            }
        return None

    @staticmethod
    def _decrypt_chrome_cookie(key: bytes, encrypted_value: bytes) -> str | None:
        """Decrypt a Chrome v10-encrypted cookie value in-process (AES-128-CBC).

        Uses `cryptography` rather than shelling out to openssl, so the AES key is
        never placed on any process's argv (visible via `ps`). Matches openssl's
        failure semantics: a wrong key or corrupt ciphertext fails PKCS#7 padding
        validation (the unpadder raises ValueError) and returns None.
        """
        # v10 prefix = macOS AES-128-CBC encryption
        if len(encrypted_value) < 4 or encrypted_value[:3] != b"v10":
            # Unencrypted or unknown format
            try:
                return encrypted_value.decode("utf-8")
            except UnicodeDecodeError:
                return None

        ciphertext = encrypted_value[3:]
        try:
            decryptor = Cipher(algorithms.AES(key), modes.CBC(b"\x20" * 16)).decryptor()
            padded = decryptor.update(ciphertext) + decryptor.finalize()
            unpadder = PKCS7(128).unpadder()  # 128-bit block; validates PKCS#7 padding
            plain = unpadder.update(padded) + unpadder.finalize()
            return plain.decode("utf-8")
        except (ValueError, TypeError, UnicodeDecodeError):
            return None

    def fetch(self) -> VibeStatus:
        import urllib.error
        import urllib.request

        self._acquire()
        if not self._has_cookies:
            raise ProbeFailure(
                _auth_required_message("Vibe session expired: sign in at console.mistral.ai"), ""
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
            with urllib.request.urlopen(req, timeout=15) as resp:  # noqa: S310
                body = resp.read().decode("utf-8")
        except urllib.error.HTTPError as exc:
            if exc.code in (301, 302, 401, 403):
                # Cookies rejected — invalidate cache so next fetch re-reads from Safari/Chrome
                self._ory_name = self._ory_value = self._csrf = ""
                self._clear_cache()
                raise ProbeFailure(
                    "Mistral session expired. Log into console.mistral.ai to refresh.",
                    f"HTTP {exc.code}",
                ) from exc
            raise ProbeFailure(f"Mistral API returned HTTP {exc.code}", str(exc)) from exc
        except urllib.error.URLError as exc:
            raise ProbeFailure(f"Could not reach Mistral API: {exc.reason}", str(exc)) from exc

        try:
            payload = json.loads(body)
        except json.JSONDecodeError as exc:
            raise ProbeFailure("Mistral API returned invalid JSON", body[:500]) from exc

        usage_pct_raw = payload.get("usage_percentage")
        # Mistral returns percentage points already, e.g. 1.08 means 1.08% used.
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

        # Post-2026-05 rebrand, Mistral dropped start_date/end_date. Vibe billing
        # is monthly anchored to the 1st UTC, so derive boundaries from reset_at.
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


class CursorProvider:
    """Fetch credit usage from Cursor's API."""

    _DB_PATH = (
        Path.home()
        / "Library"
        / "Application Support"
        / "Cursor"
        / "User"
        / "globalStorage"
        / "state.vscdb"
    )
    # Safari's Cookies.binarycookies file lags behind Safari's in-memory state, so
    # we persist the token after a successful Safari/DB read. This way we keep
    # working across Safari restarts, ITP cookie purges, and disk-flush delays.
    _CACHE_PATH = Path(__file__).resolve().parent.parent / ".cache" / "cursor_token.json"
    _USAGE_URL = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    _PLAN_URL = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo"
    _TOKEN_URL = "https://api2.cursor.sh/oauth/token"
    _CLIENT_ID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"

    def __init__(self) -> None:
        self._access_token: str | None = None
        self._refresh_token: str | None = None
        self._token_source: str | None = None

    def _acquire(self) -> None:
        """Ensure a token is loaded, idempotently.

        Re-attempts the load whenever no token is present, so a user who logs
        in mid-session is picked up on the next fetch.
        """
        if not self._access_token:
            self._load_token()

    def _load_token(self) -> None:
        """Try all token sources; a pure read that never launches a browser."""
        # Try local cache first — survives Safari restarts and ITP cookie purges
        if self._load_from_cache():
            self._token_source = "cache"
            return

        # Try Safari cookie (WorkosCursorSessionToken = userId::jwt)
        token = self._extract_token_from_safari()
        if token:
            self._access_token = token
            self._token_source = "safari"
            self._save_to_cache()
            return

        # Fall back to Cursor Desktop's local SQLite database
        self._load_from_desktop_db()
        if self._access_token:
            self._token_source = "desktop_db"
            self._save_to_cache()
            return

    def _load_from_cache(self) -> bool:
        """Load tokens from local cache. Returns True if a usable token was loaded."""
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
        """Persist current tokens to local cache."""
        if not self._access_token:
            return
        try:
            payload = {
                "access_token": self._access_token,
                "refresh_token": self._refresh_token,
                "cached_at": datetime.now().isoformat(),
            }
            _write_private(self._CACHE_PATH, json.dumps(payload))
        except OSError as exc:
            log.warning("Failed to write Cursor token cache: %s", exc)

    def _clear_cache(self) -> None:
        """Remove the local token cache (call when the cached token is rejected)."""
        _remove_private(self._CACHE_PATH)

    def _extract_token_from_safari(self) -> str | None:
        """Extract access token from Safari's WorkosCursorSessionToken cookie."""
        import urllib.parse

        cookies = _read_safari_cookies("cursor")
        token_value = cookies.get("WorkosCursorSessionToken", "")
        if token_value:
            decoded = urllib.parse.unquote(token_value)
            parts = decoded.split("::", 1)
            if len(parts) == 2 and parts[1]:
                log.debug("Extracted Cursor token from Safari cookie")
                return parts[1]
        return None

    def _load_from_desktop_db(self) -> None:
        """Load tokens from Cursor Desktop's local SQLite database."""
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
        """Fetch usage and plan data from Cursor's API."""
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
                usage_data = self._api_post(_ur, _ue, self._USAGE_URL)
            elif exc.code == 401:
                # Token rejected — invalidate cache so next fetch re-reads from Safari
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
        except Exception:  # noqa: BLE001
            pass  # plan info is optional

        plan_usage = usage_data.get("planUsage") or {}
        if not isinstance(plan_usage, dict):
            plan_usage = {}
        plan_info = plan_data.get("planInfo") or {}
        if not isinstance(plan_info, dict):
            plan_info = {}
        credit_percent_left: float | None = None

        # Cursor's totalPercentUsed does not consistently match remaining/limit.
        # Prefer the cents-based remaining value when available.
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
        """No-op: no persistent session to clean up."""

    def _api_post(self, ur: Any, ue: Any, url: str) -> dict[str, Any]:
        """POST to a Cursor API endpoint, return parsed JSON."""
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
        with ur.urlopen(req, timeout=15) as resp:  # noqa: S310
            body = resp.read()
        try:
            return json.loads(body)
        except json.JSONDecodeError:
            return {}

    @property
    def _can_refresh(self) -> bool:
        """Token-refresh capability gate: True only when a refresh token exists
        AND we are not in read-only headless mode (INV-2: no token minting)."""
        return bool(self._refresh_token) and not _is_headless()

    def _do_token_refresh(self, ur: Any, ue: Any) -> None:
        """Refresh the access token using the refresh token."""
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
            with ur.urlopen(req, timeout=15) as resp:  # noqa: S310
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
        except Exception as exc:  # noqa: BLE001
            log.warning("Cursor token refresh failed: %s", exc)


class CodexHttpProvider:
    """Fetch Codex usage via OpenAI API using cached credentials."""

    _USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
    _AUTH_PATH = Path.home() / ".codex" / "auth.json"
    # OAuth values extracted from the Codex CLI binary (`strings /opt/homebrew/bin/codex`):
    # the refresh endpoint and the public client_id used for the ChatGPT desktop/CLI app.
    _REFRESH_URL = "https://auth.openai.com/oauth/token"
    _CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"

    def __init__(self) -> None:
        self._access_token: str = ""
        self._refresh_token: str = ""
        self._account_id: str = ""

    def _acquire(self) -> None:
        """Ensure credentials are loaded, idempotently.

        Raises FileNotFoundError if ``~/.codex/auth.json`` is absent — the same
        error that used to be raised at construction time.
        """
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
        return _http_json(
            self._USAGE_URL,
            headers={
                "Authorization": f"Bearer {self._access_token}",
                "Account-Id": self._account_id,
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
        )

    def _refresh_tokens(self) -> bool:
        """Try the OAuth refresh_token grant and persist new tokens on success.

        Returns True if auth.json was updated with new tokens, False if there is no
        refresh_token available. Raises ProbeFailure with the re-auth message if the
        endpoint reports the refresh_token itself is invalidated (user must log in
        interactively).
        """
        if _HEADLESS:
            # Read-only mode (INV-2): never mint or persist new tokens.
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
            resp = _http_json(
                self._REFRESH_URL,
                method="POST",
                headers={
                    "Content-Type": "application/json",
                    "Accept": "application/json",
                },
                body=body,
            )
        except ProbeFailure as exc:
            # Auth0 / OpenAI surface refresh_token_invalidated when the refresh token
            # is itself revoked — at that point only an interactive `codex login` can
            # recover. Any other 4xx/5xx is transient or shape-related; let the caller
            # decide whether to surface or retry.
            if "refresh_token_invalidated" in (exc.raw_text or ""):
                raise ProbeFailure(
                    "Codex session expired: run `codex` to re-authenticate",
                    exc.raw_text,
                ) from exc
            raise
        new_access = resp.get("access_token")
        if not new_access:
            return False
        # Merge into the on-disk file so we don't drop OPENAI_API_KEY, auth_mode, or
        # account_id (the refresh response only returns id/access/refresh tokens).
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
        # Atomic 0600 write via the shared private-write helper (never world-readable).
        _write_private(self._AUTH_PATH, json.dumps(on_disk, indent=2))
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
            # Two recovery paths on 401:
            #   1. The on-disk refresh_token still works -> mint a new access_token
            #      ourselves (silent, the common case after server-side rotation).
            #   2. The user already ran `codex login` since startup -> reload creds
            #      from disk and retry once.
            # If both fail, the user has to re-authenticate interactively.
            refreshed = False
            try:
                refreshed = self._refresh_tokens()
            except ProbeFailure as refresh_exc:
                if "re-authenticate" in str(refresh_exc):
                    raise  # refresh_token itself revoked -> interactive login
                refreshed = False  # transient/other error -> fall through to reload path
            if refreshed:
                # Refresh succeeded; the creds are valid. A failure on THIS retry is
                # not an auth problem: a fresh 401 means the new token was rejected
                # (surface expired); anything else (5xx / network / shape) is
                # transient, so propagate it raw to route to the "(offline)" path.
                try:
                    payload = self._request_usage()
                except ProbeFailure as retry_exc:
                    if "HTTP 401" in str(retry_exc):
                        raise ProbeFailure(str(expired), str(retry_exc)) from retry_exc
                    raise
            else:
                # Reload path: did the user run `codex login` since startup?
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

        five_hour_percent_left: int | None = None
        weekly_percent_left: int | None = None
        five_hour_reset: str | None = None
        weekly_reset: str | None = None
        credits: float | None = None

        # Actual API structure: rate_limit.{primary,secondary}_window.{used_percent,reset_at}
        rate_limit = payload.get("rate_limit") or {}
        primary = rate_limit.get("primary_window") or {}
        secondary = rate_limit.get("secondary_window") or {}

        used_pct = primary.get("used_percent")
        if used_pct is not None:
            try:
                five_hour_percent_left = round(100 - float(used_pct))
            except (TypeError, ValueError):
                pass
        five_hour_reset = _format_reset_time(primary.get("reset_at"))

        used_pct = secondary.get("used_percent")
        if used_pct is not None:
            try:
                weekly_percent_left = round(100 - float(used_pct))
            except (TypeError, ValueError):
                pass
        weekly_reset = _format_reset_time(secondary.get("reset_at"))

        # Credits: credits.balance (may be null)
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
            credits=credits,
            raw_text=raw_text,
        )

    def close(self) -> None:
        pass


class ClaudeHttpProvider:
    """Fetch Claude usage via claude.ai API using Safari browser cookies."""

    _BASE_URL = "https://claude.ai"
    # See CursorProvider._CACHE_PATH for the rationale: Safari's binarycookies file
    # lags behind its in-memory state, so we persist cookies across runs.
    _CACHE_PATH = Path(__file__).resolve().parent.parent / ".cache" / "claude_cookies.json"

    def __init__(self) -> None:
        self._session_key: str = ""
        self._cf_clearance: str = ""
        self._org_id: str = ""

    def _acquire(self) -> None:
        """Ensure cookies are loaded, idempotently.

        Re-attempts the load whenever cookies are still absent, so a user who
        logs in mid-session is picked up on the next fetch.
        """
        if not self._has_cookies:
            self._load_cookies()

    def _load_cookies(self) -> None:
        if self._load_from_cache():
            return
        cookies = _read_safari_cookies("claude")
        self._session_key = cookies.get("sessionKey", "")
        self._cf_clearance = cookies.get("cf_clearance", "")
        self._org_id = cookies.get("lastActiveOrg", "")
        if self._session_key and self._org_id:
            self._save_to_cache()

    def _load_from_cache(self) -> bool:
        """Load cookies from local cache. Returns True if a usable set was loaded."""
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

    def _save_to_cache(self) -> None:
        """Persist current cookies to local cache."""
        if not (self._session_key and self._org_id):
            return
        try:
            payload = {
                "sessionKey": self._session_key,
                "cf_clearance": self._cf_clearance,
                "lastActiveOrg": self._org_id,
                "cached_at": datetime.now().isoformat(),
            }
            _write_private(self._CACHE_PATH, json.dumps(payload))
        except OSError as exc:
            log.warning("Failed to write Claude cookie cache: %s", exc)

    def _clear_cache(self) -> None:
        """Remove the local cookie cache (call when cookies are rejected by the API)."""
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
            payload = _http_json(
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
            # 400 is included because Claude's path validator returns invalid_request_error
            # (not 401/403) when lastActiveOrg in the cookie cache is not a valid UUID — the
            # 2026-05-30 cache-poison scenario. Treating it as a cookie problem evicts the
            # bad cache so the next probe re-reads from Safari.
            if "HTTP 400" in msg or "HTTP 401" in msg or "HTTP 403" in msg:
                self._session_key = self._cf_clearance = self._org_id = ""
                self._clear_cache()
                raise ProbeFailure(
                    "Claude session expired — visit claude.ai to refresh",
                    msg,
                ) from exc
            raise

        raw_text = json.dumps(payload, indent=2, sort_keys=True)

        session_percent_left: int | None = None
        weekly_percent_left: int | None = None
        opus_percent_left: int | None = None
        primary_reset: str | None = None
        secondary_reset: str | None = None
        opus_reset: str | None = None

        # Actual API structure: {five_hour: {utilization, resets_at}, seven_day: {...}, ...}
        # utilization is 0–100 used%; percent_left = 100 - utilization
        def _util(key: str) -> int | None:
            bucket = payload.get(key) or {}
            val = bucket.get("utilization") if isinstance(bucket, dict) else None
            if val is None:
                return None
            try:
                return round(100 - float(val))
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


class AntigravityProvider:
    """Fetch Antigravity (`agy`) grouped quota via the Cloud Code internal API.

    `agy` (the Antigravity CLI) meters usage differently from the legacy Gemini
    per-model quota: it reports quota *groups* (Gemini models; Claude+GPT models),
    each with a 5-hour and a weekly window, via `retrieveUserQuotaSummary`. That
    endpoint is gated to `agy`'s own OAuth client, so the shared
    ``~/.gemini/oauth_creds.json`` token (a different client) is denied — we must
    use `agy`'s token.

    `agy` stores its OAuth token in the macOS Keychain (service ``gemini``,
    account ``antigravity``) as a ``go-keyring-base64:``-wrapped JSON blob. We read
    it **read-only** with respect to `agy`'s *stored* credentials: we never write
    the Keychain and never mint or persist a token ourselves.

    The access token expires roughly hourly, and only `agy` refreshes it — so
    when `agy` isn't running the card would otherwise flip to an auth error until
    the user manually re-runs `agy`. To avoid that toil we *nudge* `agy` to
    refresh its **own** token: on expiry we run ``agy models`` — a non-interactive,
    quota-free authenticated command that makes `agy`'s own OAuth client refresh
    and persist a fresh token to the Keychain — then re-read it. We never handle
    `agy`'s client secret or refresh token; `agy` does its own refresh the proper
    way. The nudge is gated OFF under headless mode (INV-2: no subprocess spawn on
    the read-only path) and cooldown-limited so a dead refresh token can't make us
    spawn `agy` every cycle. If the nudge doesn't clear the expiry we fall back to
    surfacing the "run `agy`" auth error.
    """

    _KEYCHAIN_SERVICE = "gemini"
    _KEYCHAIN_ACCOUNT = "antigravity"
    _KEYCHAIN_PREFIX = "go-keyring-base64:"
    # `agy` talks to the daily mirror, not prod cloudcode-pa; match it.
    _SUMMARY_URL = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
    # Lightweight, non-interactive, quota-free authenticated command that makes
    # `agy` refresh + persist its own Keychain token as a side effect (~1s).
    _REFRESH_TRIGGER_CMD = ("agy", "models")
    # Don't re-spawn the refresh nudge more than once per this window (seconds):
    # if `agy`'s refresh token is itself dead, the nudge can't help and we must
    # not spawn `agy` on every ~120s refresh cycle.
    _REFRESH_COOLDOWN_SECONDS = 300
    # cloudcode-pa rejects the default `Python-urllib/x.y` User-Agent as abuse
    # (403 PERMISSION_DENIED); any real UA is accepted. Identify honestly.
    _USER_AGENT = "ai-monitor (antigravity quota probe)"
    _ACCOUNTS_PATH = Path.home() / ".gemini" / "google_accounts.json"

    def __init__(self) -> None:
        self._token: dict[str, Any] = {}
        # Monotonic timestamp of the last `agy models` refresh nudge (cooldown).
        self._last_refresh_trigger = 0.0

    def _acquire(self) -> None:
        """Ensure a Keychain token is loaded.

        Always re-reads the Keychain (rather than short-circuiting when a
        token is already cached) so we pick up `agy`'s own refreshes — this
        matches fetch()'s existing re-read-every-cycle behavior. Raises
        FileNotFoundError if no usable token is present, same as before.
        """
        if _is_headless():
            # INV-2: reading the Keychain is a subprocess; never spawn it on the
            # read-only path. Surface the same auth error shape as a missing token.
            self._token = {}
            raise FileNotFoundError("auth required: no cached credentials")
        self._token = self._load_keychain_token()
        if not self._token.get("access_token"):
            raise FileNotFoundError("Antigravity token not found in Keychain: run `agy` to sign in")

    @classmethod
    def _load_keychain_token(cls) -> dict[str, Any]:
        """Read and decode `agy`'s Keychain token blob into its oauth2.Token dict.

        Returns the inner ``token`` object ({access_token, refresh_token, expiry,
        token_type}); an empty dict if the item is missing or unreadable.
        """
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
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise FileNotFoundError(f"Could not read Antigravity Keychain item: {exc}") from exc
        if result.returncode != 0:
            raise FileNotFoundError("Antigravity token not found in Keychain: run `agy` to sign in")
        blob = result.stdout.strip()
        if blob.startswith(cls._KEYCHAIN_PREFIX):
            import base64

            payload = blob[len(cls._KEYCHAIN_PREFIX) :]
            try:
                blob = base64.b64decode(payload + "=" * (-len(payload) % 4)).decode("utf-8")
            except (ValueError, UnicodeDecodeError) as exc:
                raise FileNotFoundError(
                    f"Antigravity Keychain blob is not valid base64: {exc}"
                ) from exc
        try:
            outer = json.loads(blob)
        except json.JSONDecodeError as exc:
            raise FileNotFoundError(f"Antigravity Keychain blob is not valid JSON: {exc}") from exc
        token = outer.get("token")
        return token if isinstance(token, dict) else {}

    def _access_token(self) -> str:
        return str(self._token.get("access_token", ""))

    @staticmethod
    def _token_expired(token: dict[str, Any], leeway_seconds: int = 30) -> bool:
        """True if the token's ISO-8601 `expiry` is in the past (with leeway)."""
        expiry = token.get("expiry")
        if not isinstance(expiry, str):
            return False  # unknown expiry — let the API decide
        try:
            target = datetime.fromisoformat(expiry)
        except ValueError:
            return False
        now = datetime.now(target.tzinfo) if target.tzinfo else datetime.now()
        return target.timestamp() <= now.timestamp() + leeway_seconds

    def _trigger_agy_self_refresh(self) -> bool:
        """Nudge `agy` to refresh its OWN Keychain token, then re-read it.

        Runs ``agy models`` — a non-interactive, quota-free authenticated command
        that makes `agy`'s own OAuth client refresh and persist a fresh token to
        the Keychain (~1s) — and returns True if the re-read token is no longer
        expired.

        We never touch `agy`'s credentials ourselves: `agy` refreshes and persists
        its own token via its own OAuth client and secret. Gated OFF in headless
        mode (INV-2: no subprocess spawn on the read-only path) and rate-limited by
        a cooldown so a dead refresh token can't make us spawn `agy` every cycle.
        Any spawn failure (agy not on PATH, timeout, non-zero exit) degrades to
        False and the caller surfaces the "run `agy`" auth error.
        """
        if _is_headless():
            return False
        now = time.monotonic()
        if now - self._last_refresh_trigger < self._REFRESH_COOLDOWN_SECONDS:
            return False
        self._last_refresh_trigger = now
        try:
            result = subprocess.run(
                list(self._REFRESH_TRIGGER_CMD),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=30,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            return False
        if result.returncode != 0:
            # `agy models` couldn't authenticate (e.g. `agy`'s own refresh token is
            # dead): don't claim success on a token it didn't actually refresh, or
            # we'd retry with the same rejected bearer before surfacing the error.
            return False
        # `agy` persists the refreshed token to the Keychain on success; re-read.
        # A failed re-read (missing/unreadable item) degrades to False rather than
        # letting FileNotFoundError escape this bool-returning method.
        try:
            self._token = self._load_keychain_token()
        except FileNotFoundError:
            return False
        # Honest success signal: only True when a usable, non-expired token is
        # actually present after the refresh (guards a malformed/empty re-read).
        return bool(self._token.get("access_token")) and not self._token_expired(self._token)

    def _auth_headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self._access_token()}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": self._USER_AGENT,
        }

    @staticmethod
    def _percent_from_fraction(bucket: dict[str, Any] | None) -> int | None:
        if not bucket:
            return None
        fraction = bucket.get("remainingFraction")
        if fraction is None:
            return None
        try:
            value = float(fraction)
        except (TypeError, ValueError):
            return None
        return max(0, min(100, int(round(value * 100))))

    @staticmethod
    def _find_gemini_group(groups: list[dict[str, Any]]) -> dict[str, Any] | None:
        """Return the Gemini-models quota group (5h + weekly windows)."""
        for group in groups:
            name = str(group.get("displayName", "")).lower()
            buckets = group.get("buckets") or []
            if name.startswith("gemini") or any(
                str(b.get("bucketId", "")).startswith("gemini") for b in buckets
            ):
                return group
        return None

    @classmethod
    def _read_account_email(cls) -> str | None:
        try:
            payload = json.loads(cls._ACCOUNTS_PATH.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None
        active = payload.get("active")
        return active if isinstance(active, str) and "@" in active else None

    def fetch(self) -> AntigravityStatus:
        # Re-read the Keychain each fetch so we pick up `agy`'s own refreshes.
        self._acquire()
        if self._token_expired(self._token) and not self._trigger_agy_self_refresh():
            raise ProbeFailure(
                "Antigravity session expired: run `agy` to re-authenticate",
                "keychain token past expiry",
            )

        try:
            payload = _http_json(
                self._SUMMARY_URL,
                method="POST",
                headers=self._auth_headers(),
                body=b"{}",  # summary RPC requires an empty body; any field -> HTTP 400
            )
        except ProbeFailure as exc:
            # Non-auth failures (network, 400/403/5xx) propagate unchanged so the
            # upstream transient-retry logic can handle them.
            if "401" not in str(exc):
                raise
            # A 401 means the opaque access token was revoked server-side. Nudge
            # `agy` to refresh its own token once and retry; if the nudge or the
            # retry can't recover, surface the actionable "run `agy`" auth error —
            # never a raw "HTTP 401", which wouldn't drive the auth-fix CTA.
            reauth = ProbeFailure(
                "Antigravity session expired: run `agy` to re-authenticate",
                "keychain token past expiry (401)",
            )
            if not self._trigger_agy_self_refresh():
                raise reauth from exc
            try:
                payload = _http_json(
                    self._SUMMARY_URL,
                    method="POST",
                    headers=self._auth_headers(),
                    body=b"{}",
                )
            except ProbeFailure as retry_exc:
                if "401" in str(retry_exc):
                    raise reauth from retry_exc
                raise

        raw_text = json.dumps(payload, indent=2, sort_keys=True)
        groups = payload.get("groups") or []
        if not groups:
            raise ProbeFailure("Antigravity quota response has no groups", raw_text[:500])

        gemini_group = self._find_gemini_group(groups)
        if gemini_group is None:
            raise ProbeFailure("Antigravity quota: no Gemini group found", raw_text[:500])

        buckets = {b.get("window"): b for b in (gemini_group.get("buckets") or [])}
        five_hour = buckets.get("5h")
        weekly = buckets.get("weekly")

        return AntigravityStatus(
            five_hour_percent_left=self._percent_from_fraction(five_hour),
            weekly_percent_left=self._percent_from_fraction(weekly),
            five_hour_reset=_format_reset_time(five_hour.get("resetTime")) if five_hour else None,
            weekly_reset=_format_reset_time(weekly.get("resetTime")) if weekly else None,
            account_email=self._read_account_email(),
            account_tier=None,
            raw_text=raw_text,
        )

    def close(self) -> None:
        pass


def fetch_provider_snapshot(
    name: str, fetcher: Any, debug: bool = False, source: str = "api"
) -> ProviderSnapshot:
    """Wrap provider fetch failures into a display-friendly snapshot."""

    try:
        status = fetcher.fetch()
    except ProbeFailure as exc:
        if debug:
            _write_debug_dump(name, exc.raw_text or "")
        error = str(exc)
        debug_detail = None
        if debug:
            tail = exc.raw_text[-1600:] if exc.raw_text else ""
            dump_hint = f"raw dump: {_debug_dump_path(name)}"
            debug_detail = f"{error}\n\n{dump_hint}\n\n{tail}".strip()
        return ProviderSnapshot(
            name=name, ok=False, source=source, error=error, debug_detail=debug_detail
        )
    except Exception as exc:  # noqa: BLE001
        return ProviderSnapshot(name=name, ok=False, source=source, error=str(exc))
    data = status.to_dict()
    if debug:
        _write_debug_dump(name, str(data.get("raw_text", "")))
    if not debug:
        data.pop("raw_text", None)
    return ProviderSnapshot(name=name, ok=True, source=source, data=data)
