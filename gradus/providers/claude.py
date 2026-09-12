"""Claude provider."""

from __future__ import annotations

import datetime
import getpass
import json
import math
import subprocess
from typing import Any, NamedTuple

from ..parsing import ClaudeStatus
from . import _base
from ._base import (
    ProbeFailure,
    _format_reset_time,
    register,
)


def _epoch_ms(value: Any) -> float | None:
    """Coerce a keychain timestamp to epoch milliseconds, or None if unusable."""
    if value is None or isinstance(value, bool):
        return None
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    return parsed if math.isfinite(parsed) else None


class _KeychainCredential(NamedTuple):
    """Claude Code's cached OAuth grant, minus anything that must not be logged.

    `expires_at` / `refresh_expires_at` are epoch milliseconds as Claude Code
    writes them, or None when the payload omits them.
    """

    access_token: str
    expires_at: float | None
    refresh_expires_at: float | None


@register("Claude")
class ClaudeHttpProvider:
    _OAUTH_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
    _KEYCHAIN_SERVICE = "Claude Code-credentials"
    _USER_AGENT = "gradus (claude oauth usage probe)"

    def __init__(self) -> None:
        self._access_token: str = ""

    # Bounded like the keychain read: a hung `claude` process must not hang the probe.
    _AUTH_STATUS_TIMEOUT_SECONDS = 15

    def _acquire(self) -> None:
        if _base._is_headless():
            raise ProbeFailure("auth required: no cached credentials", "")
        if not self._access_token:
            try:
                credential = self._load_keychain_credential()
            except FileNotFoundError as exc:
                raise ProbeFailure(
                    f"Claude Code OAuth credentials unavailable ({exc}): run `claude auth login`",
                    "",
                ) from exc
            credential = self._reject_if_only_stale(credential)
            self._access_token = credential.access_token

    @classmethod
    def _reject_if_only_stale(cls, credential: _KeychainCredential) -> _KeychainCredential:
        """Fail transiently when the cached token is merely stale, not revoked.

        Claude Code refreshes this keychain item lazily -- observed 2026-09-08,
        a token expired at 13:00:05 and was not rewritten until ~13:19 while
        Claude Code was in continuous use. Sending the stale token earns a 401,
        which is indistinguishable at the HTTP layer from a revoked grant, so
        the probe used to tell David to run `claude auth login` for a session
        that was never signed out. With a live refresh token the honest report
        is "wait", and the wording deliberately avoids every substring the Swift
        auth classifiers key on (`session expired`, `re-authenticate`,
        ``login` ``, `auth required`) so the menu does not raise a sign-in
        banner for a grant that needs no sign-in.

        Before giving up, this nudges Claude Code to refresh via
        `_recover_stale_credential` -- observed 2026-09-12, a long-running
        Claude Code session left the keychain item expired for 2+ hours
        because nothing forced a new process to touch it. That recovery is a
        `claude auth status` call, not a model request, so it costs no usage
        credit and needs no polling schedule of its own.

        Gradus does not mint a replacement token itself: the refresh token
        rotates on use (same observation -- its hash changed across the
        refresh), so a third-party consumer that minted a token without
        writing the successor back would revoke Claude Code's own login.
        """
        expires_at = credential.expires_at
        if expires_at is None:
            return credential
        now_ms = datetime.datetime.now().timestamp() * 1000
        if expires_at > now_ms:
            return credential
        refresh_expires_at = credential.refresh_expires_at
        if refresh_expires_at is not None and refresh_expires_at <= now_ms:
            # Nothing left to refresh from: this one really is a sign-in.
            raise ProbeFailure(
                "Claude Code session expired: run `claude auth login`",
                "",
            )
        refreshed = cls._recover_stale_credential()
        if refreshed is not None:
            return refreshed
        # Imported lazily to preserve snapshot.py's provider-import boundary.
        from ..snapshot import CLAUDE_STALE_CREDENTIAL_MESSAGE

        raise ProbeFailure(
            CLAUDE_STALE_CREDENTIAL_MESSAGE,
            "",
        )

    @classmethod
    def _recover_stale_credential(cls) -> _KeychainCredential | None:
        """Best-effort nudge for Claude Code to refresh its own keychain item.

        `claude auth status` is an identity lookup, not a model request -- it
        costs no usage credit, so this can run on every stale hit instead of
        needing a standing poll schedule. Any failure (binary missing,
        offline, still expired) just returns None and lets the caller fall
        back to the existing stale-cache message.
        """
        try:
            result = subprocess.run(
                ["claude", "auth", "status"],
                capture_output=True,
                text=True,
                timeout=cls._AUTH_STATUS_TIMEOUT_SECONDS,
                check=False,
            )
        except (OSError, subprocess.SubprocessError):
            return None
        if result.returncode != 0:
            return None
        try:
            credential = cls._load_keychain_credential()
        except FileNotFoundError:
            return None
        now_ms = datetime.datetime.now().timestamp() * 1000
        if credential.expires_at is not None and credential.expires_at <= now_ms:
            return None
        return credential

    # `security`'s exit status is the OSStatus residue mod 256: errSecItemNotFound
    # (-25300) surfaces as 44, errSecInteractionNotAllowed (-25308) as 36. Both are
    # well short of a soundness guarantee (a delta a future macOS release can move),
    # but the alternative -- one exit code, one message -- is what let a Keychain
    # lock and a real sign-out look identical to David for hours in September 2026.
    _KEYCHAIN_EXIT_ITEM_NOT_FOUND = 44
    _KEYCHAIN_EXIT_INTERACTION_NOT_ALLOWED = 36

    @classmethod
    def _load_keychain_credential(cls) -> _KeychainCredential:
        """Read Claude Code's OAuth grant without persisting or logging it.

        Every failure below reaches the dashboard through the same sign-in
        prompt in `_acquire`, but the raw causes do not share one fix: a
        missing item needs `claude auth login`; a locked or ACL-denied
        Keychain needs the Mac unlocked or the prompt approved, and no login
        will touch it. Each raise carries a short, fixed, secret-free reason
        (never `result.stdout`/`stderr`, which sit next to the actual grant)
        so `_acquire` can show which one fired instead of a single opaque
        string that was true of four different failures at once.
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
                    getpass.getuser(),
                ],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise FileNotFoundError("could not run `security`") from exc
        if result.returncode != 0:
            if result.returncode == cls._KEYCHAIN_EXIT_ITEM_NOT_FOUND:
                raise FileNotFoundError("no keychain item")
            if result.returncode == cls._KEYCHAIN_EXIT_INTERACTION_NOT_ALLOWED:
                raise FileNotFoundError("keychain is locked or unavailable to this session")
            raise FileNotFoundError(f"keychain denied the read, exit {result.returncode}")
        try:
            payload: Any = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise FileNotFoundError("keychain item is not valid JSON") from exc
        oauth = payload.get("claudeAiOauth") if isinstance(payload, dict) else None
        token = oauth.get("accessToken") if isinstance(oauth, dict) else None
        if not isinstance(token, str) or not token.strip():
            raise FileNotFoundError("keychain item has no access token")
        return _KeychainCredential(
            access_token=token.strip(),
            expires_at=_epoch_ms(oauth.get("expiresAt")),
            refresh_expires_at=_epoch_ms(oauth.get("refreshTokenExpiresAt")),
        )

    def fetch(self) -> ClaudeStatus:
        self._acquire()
        try:
            payload = _base._http_json(
                self._OAUTH_USAGE_URL,
                headers={
                    "Authorization": f"Bearer {self._access_token}",
                    "Accept": "application/json",
                    "User-Agent": self._USER_AGENT,
                },
            )
        except ProbeFailure as exc:
            msg = str(exc)
            if "HTTP 401" in msg or "HTTP 403" in msg:
                self._access_token = ""
                raise ProbeFailure(
                    "Claude Code session expired: run `claude auth login`",
                    "",
                ) from exc
            raise

        if not isinstance(payload, dict):
            raise ProbeFailure("Claude usage response is invalid", "")
        raw_text = json.dumps(payload, indent=2, sort_keys=True)

        session_percent_left: float | None = None
        weekly_percent_left: float | None = None
        opus_percent_left: float | None = None
        primary_reset: str | None = None
        secondary_reset: str | None = None
        opus_reset: str | None = None
        credit_balance: float | None = None

        def _util(key: str) -> float | None:
            bucket = payload.get(key) or {}
            val = bucket.get("utilization") if isinstance(bucket, dict) else None
            if val is None:
                return None
            try:
                utilization = float(val)
            except (TypeError, ValueError):
                return None
            if not math.isfinite(utilization) or not 0 <= utilization <= 100:
                return None
            return 100.0 - utilization

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

        extra_usage = payload.get("extra_usage") or {}
        if isinstance(extra_usage, dict) and extra_usage.get("is_enabled") is True:
            monthly_limit = extra_usage.get("monthly_limit")
            used_credits = extra_usage.get("used_credits")
            try:
                limit = float(monthly_limit)
                used = float(used_credits)
            except (TypeError, ValueError):
                pass
            else:
                if math.isfinite(limit) and math.isfinite(used) and limit >= 0 and used >= 0:
                    credit_balance = max(0.0, limit - used)

        if all(
            value is None
            for value in (session_percent_left, weekly_percent_left, opus_percent_left)
        ):
            raise ProbeFailure("Claude usage data not available yet", raw_text)

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
            credit_balance=credit_balance,
        )

    def close(self) -> None:
        pass
