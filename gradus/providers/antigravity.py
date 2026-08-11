"""Antigravity provider."""

from __future__ import annotations

import json
import logging
import math
import subprocess
import time
from datetime import datetime
from pathlib import Path
from typing import Any

from ..parsing import AntigravityStatus
from . import _base
from ._base import ProbeFailure, _format_reset_time, _is_headless, register

log = logging.getLogger(__name__)

HISTORY_ENDPOINT = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
# These strings are part of the credential-free producer/consumer contract.
AUTH_REAUTHENTICATION_ERROR = "Antigravity session expired: run `agy` to re-authenticate"
AUTH_FAILURE_REASON = "auth_failure"
HISTORY_PROVENANCE = {
    "provenance_available": True,
    "method": "POST",
    "endpoint": HISTORY_ENDPOINT,
    "bucket_family": "gemini-*",
    "projection": "direct",
}
HISTORY_CLAUDE_PROVENANCE = {
    "provenance_available": True,
    "method": "POST",
    "endpoint": HISTORY_ENDPOINT,
    "bucket_family": "3p-*",
    "projection": "synthetic",
    "upstream_pool": "Claude and GPT models",
    "downstream_policy": "Sonnet target only",
}


@register("Antigravity")
class AntigravityProvider:
    _KEYCHAIN_SERVICE = "gemini"
    _KEYCHAIN_ACCOUNT = "antigravity"
    _KEYCHAIN_PREFIX = "go-keyring-base64:"
    _SUMMARY_URL = HISTORY_ENDPOINT
    _REFRESH_TRIGGER_CMD = ("agy", "models")
    _REFRESH_COOLDOWN_SECONDS = 300
    _USER_AGENT = "gradus (antigravity quota probe)"
    _ACCOUNTS_PATH = Path.home() / ".gemini" / "google_accounts.json"

    def __init__(self) -> None:
        self._token: dict[str, Any] = {}
        self._last_refresh_trigger = 0.0

    def _acquire(self) -> None:
        if _is_headless():
            self._token = {}
            raise FileNotFoundError("auth required: no cached credentials")
        self._token = self._load_keychain_token()
        if not self._token.get("access_token"):
            raise FileNotFoundError("Antigravity token not found in Keychain: run `agy` to sign in")

    @classmethod
    def _load_keychain_token(cls) -> dict[str, Any]:
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
        expiry = token.get("expiry")
        if not isinstance(expiry, str):
            return False
        try:
            target = datetime.fromisoformat(expiry)
        except ValueError:
            return False
        now = datetime.now(target.tzinfo) if target.tzinfo else datetime.now()
        return target.timestamp() <= now.timestamp() + leeway_seconds

    def _trigger_agy_self_refresh(self) -> bool:
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
            return False
        try:
            self._token = self._load_keychain_token()
        except FileNotFoundError:
            return False
        return bool(self._token.get("access_token")) and not self._token_expired(self._token)

    def _auth_headers(self) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self._access_token()}",
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": self._USER_AGENT,
        }

    @staticmethod
    def _percent_from_fraction(bucket: dict[str, Any] | None) -> float | None:
        if not bucket:
            return None
        fraction = bucket.get("remainingFraction")
        if isinstance(fraction, bool) or fraction is None:
            return None
        try:
            value = float(fraction)
        except (TypeError, ValueError):
            return None
        if not math.isfinite(value) or not 0 <= value <= 1:
            return None
        return value * 100

    @staticmethod
    def _third_party_percent_from_fraction(bucket: dict[str, Any] | None) -> float | None:
        if not bucket:
            return None
        fraction = bucket.get("remainingFraction")
        if isinstance(fraction, bool) or fraction is None:
            return None
        try:
            value = float(fraction)
        except (TypeError, ValueError):
            return None
        if not math.isfinite(value) or not 0 <= value <= 1:
            return None
        return value * 100

    @staticmethod
    def _find_group_by_bucket_prefix(
        groups: list[dict[str, Any]], bucket_prefix: str
    ) -> dict[str, Any] | None:
        for group in groups:
            if not isinstance(group, dict):
                continue
            buckets = group.get("buckets")
            if not isinstance(buckets, list):
                continue
            if any(
                isinstance(bucket, dict)
                and str(bucket.get("bucketId", "")).startswith(bucket_prefix)
                for bucket in buckets
            ):
                return group
        return None

    @staticmethod
    def _buckets_by_window(
        group: dict[str, Any] | None, bucket_prefix: str
    ) -> dict[str, dict[str, Any]]:
        if not group:
            return {}
        buckets = group.get("buckets")
        if not isinstance(buckets, list):
            return {}
        return {
            bucket["window"]: bucket
            for bucket in buckets
            if (
                isinstance(bucket, dict)
                and isinstance(bucket.get("window"), str)
                and isinstance(bucket.get("bucketId"), str)
                and bucket["bucketId"].startswith(bucket_prefix)
            )
        }

    @staticmethod
    def _third_party_reset_time(bucket: dict[str, Any] | None) -> str | None:
        if not bucket:
            return None
        try:
            return _format_reset_time(bucket.get("resetTime"))
        except (TypeError, ValueError, OSError, OverflowError):
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
        self._acquire()
        if self._token_expired(self._token) and not self._trigger_agy_self_refresh():
            raise ProbeFailure(
                AUTH_REAUTHENTICATION_ERROR,
                "keychain token past expiry",
            )

        try:
            payload = _base._http_json(
                self._SUMMARY_URL,
                method="POST",
                headers=self._auth_headers(),
                body=b"{}",
            )
        except ProbeFailure as exc:
            if "401" not in str(exc):
                raise
            reauth = ProbeFailure(
                AUTH_REAUTHENTICATION_ERROR,
                "keychain token past expiry (401)",
            )
            if not self._trigger_agy_self_refresh():
                raise reauth from exc
            try:
                payload = _base._http_json(
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

        gemini_group = self._find_group_by_bucket_prefix(groups, "gemini-")
        if gemini_group is None:
            raise ProbeFailure("Antigravity quota: no Gemini group found", raw_text[:500])

        gemini_buckets = self._buckets_by_window(gemini_group, "gemini-")
        five_hour = gemini_buckets.get("5h")
        weekly = gemini_buckets.get("weekly")
        third_party_buckets = self._buckets_by_window(
            self._find_group_by_bucket_prefix(groups, "3p-"), "3p-"
        )
        third_party_five_hour = third_party_buckets.get("5h")
        third_party_weekly = third_party_buckets.get("weekly")

        return AntigravityStatus(
            five_hour_percent_left=self._percent_from_fraction(five_hour),
            weekly_percent_left=self._percent_from_fraction(weekly),
            five_hour_reset=_format_reset_time(five_hour.get("resetTime")) if five_hour else None,
            weekly_reset=_format_reset_time(weekly.get("resetTime")) if weekly else None,
            third_party_five_hour_percent_left=self._third_party_percent_from_fraction(
                third_party_five_hour
            ),
            third_party_weekly_percent_left=self._third_party_percent_from_fraction(
                third_party_weekly
            ),
            third_party_five_hour_reset=self._third_party_reset_time(third_party_five_hour),
            third_party_weekly_reset=self._third_party_reset_time(third_party_weekly),
            account_email=self._read_account_email(),
            account_tier=None,
            raw_text=raw_text,
        )

    def close(self) -> None:
        pass
