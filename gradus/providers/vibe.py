"""Vibe (Mistral) provider."""

from __future__ import annotations

import json
import logging
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.padding import PKCS7

from ..parsing import VibeStatus
from . import _base
from ._base import (
    ProbeFailure,
    _auth_required_message,
    _harden_existing,
    _is_headless,
    _remove_private,
    register,
)

log = logging.getLogger(__name__)


@register("Vibe")
class VibeProvider:
    COOKIE_FILENAME = ".mistral_cookies.json"
    API_URL = "https://console.mistral.ai/api/billing/v2/vibe-usage"
    _CACHE_PATH = Path(__file__).resolve().parent.parent.parent / ".cache" / "vibe_cookies.json"

    def __init__(self, project_root: str) -> None:
        self._project_root = project_root
        self._ory_name = ""
        self._ory_value = ""
        self._csrf = ""

    def _acquire(self) -> None:
        if not self._has_cookies:
            self._load_cookies()

    def _load_cookies(self) -> None:
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
        if not (self._ory_name and self._ory_value and self._csrf):
            return
        try:
            payload = {
                "ory_session_name": self._ory_name,
                "ory_session_value": self._ory_value,
                "csrftoken": self._csrf,
                "cached_at": datetime.now().isoformat(),
            }
            _base._write_private(self._CACHE_PATH, json.dumps(payload))
        except OSError as exc:
            log.warning("Failed to write Vibe cookie cache: %s", exc)

    def _clear_cache(self) -> None:
        _remove_private(self._CACHE_PATH)

    @property
    def _has_cookies(self) -> bool:
        return bool(self._ory_name and self._ory_value and self._csrf)

    @staticmethod
    def _load_cookie_file(cookie_path: Path) -> dict[str, str]:
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
        if _is_headless():
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

        key = hashlib.pbkdf2_hmac(
            "sha1",
            chrome_password.encode("utf-8"),
            b"saltysalt",
            1003,
            dklen=16,
        )

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
        cookies = _base._read_safari_cookies("mistral")
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
        if len(encrypted_value) < 4 or encrypted_value[:3] != b"v10":
            try:
                return encrypted_value.decode("utf-8")
            except UnicodeDecodeError:
                return None

        ciphertext = encrypted_value[3:]
        try:
            decryptor = Cipher(algorithms.AES(key), modes.CBC(b"\x20" * 16)).decryptor()
            padded = decryptor.update(ciphertext) + decryptor.finalize()
            unpadder = PKCS7(128).unpadder()
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
            with urllib.request.urlopen(req, timeout=15) as resp:
                body = resp.read().decode("utf-8")
        except urllib.error.HTTPError as exc:
            if exc.code in (301, 302, 401, 403):
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
