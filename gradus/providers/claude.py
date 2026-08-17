"""Claude provider."""

from __future__ import annotations

import errno
import json
import logging
import os
import pty
import re
import select
import signal
import subprocess
import time
import uuid
from pathlib import Path
from uuid import UUID

from ..parsing import ClaudeStatus
from . import _base
from ._base import (
    ProbeFailure,
    _auth_required_message,
    _format_reset_time,
    _harden_existing,
    _is_headless,
    _remove_private,
    register,
)


@register("Claude")
class ClaudeHttpProvider:
    _BASE_URL = "https://claude.ai"
    _CACHE_PATH = Path(__file__).resolve().parent.parent.parent / ".cache" / "claude_cookies.json"
    _ORGANIZATIONS_URL = f"{_BASE_URL}/api/organizations"
    _CLI_CANDIDATES = (Path("/opt/homebrew/bin/claude"), Path("/usr/local/bin/claude"))
    _CLI_TIMEOUT_SECONDS = 12.0
    _CLI_OUTPUT_LIMIT = 64 * 1024
    _CLI_SEND_DELAY_SECONDS = 2.0
    _ANSI_RE = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")
    _PERCENT_RE = re.compile(r"(?<![A-Za-z0-9])(?P<value>\d{1,3}(?:\.\d+)?)\s*%")

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

    @classmethod
    def _cli_path(cls) -> Path | None:
        return next(
            (path for path in cls._CLI_CANDIDATES if path.is_file() and os.access(path, os.X_OK)),
            None,
        )

    @classmethod
    def _strip_cli_terminal_text(cls, raw: bytes) -> str:
        text = cls._ANSI_RE.sub("", raw.decode("utf-8", errors="replace"))
        text = text.replace("\x08", "")
        return "\n".join(part.strip() for part in text.replace("\r", "\n").splitlines())

    @classmethod
    def _parse_cli_usage(cls, raw: bytes) -> ClaudeStatus | None:
        """Parse the screen-reader usage rows without retaining the panel."""
        lines = cls._strip_cli_terminal_text(raw).splitlines()
        buckets: dict[str, tuple[float, str | None]] = {}
        current: str | None = None
        for index, line in enumerate(lines):
            lowered = line.lower()
            if "current session" in lowered:
                current = "session"
            elif "current week" in lowered and "all models" in lowered:
                current = "weekly"
            elif "current week" in lowered and "opus" in lowered:
                current = "opus"
            elif "current week" in lowered:
                current = None
            if current is None:
                continue
            percent_match = cls._PERCENT_RE.search(line)
            reset: str | None = None
            for candidate in lines[index : min(index + 4, len(lines))]:
                if "reset" in candidate.lower():
                    reset = re.sub(r"[^A-Za-z0-9%:.,+()/ -]", " ", candidate)
                    reset = re.sub(r"\s+", " ", reset).strip()[:120] or None
                    break
            if percent_match is None:
                for candidate in lines[index + 1 : min(index + 3, len(lines))]:
                    percent_match = cls._PERCENT_RE.search(candidate)
                    if percent_match is not None:
                        break
            if percent_match is None or current in buckets:
                continue
            value = float(percent_match.group("value"))
            if not 0 <= value <= 100:
                continue
            # Claude's panel reports utilization ("used"); Gradus exposes
            # remaining capacity, matching the web API provider contract.
            context = " ".join(lines[index : min(index + 3, len(lines))]).lower()
            if "used" in context and "left" not in context:
                value = 100.0 - value
            buckets[current] = (value, reset)
            current = None

        session = buckets.get("session")
        weekly = buckets.get("weekly")
        if session is None or weekly is None:
            return None
        opus = buckets.get("opus")
        parsed = {
            "source": "claude-cli-usage",
            "session_percent_left": session[0],
            "weekly_percent_left": weekly[0],
            "opus_percent_left": opus[0] if opus else None,
            "primary_reset": session[1],
            "secondary_reset": weekly[1],
            "opus_reset": opus[1] if opus else None,
        }
        return ClaudeStatus(
            session_percent_left=session[0],
            weekly_percent_left=weekly[0],
            opus_percent_left=opus[0] if opus else None,
            primary_reset=session[1],
            secondary_reset=weekly[1],
            opus_reset=opus[1] if opus else None,
            account_email=None,
            account_organization=None,
            login_method=None,
            raw_text=json.dumps(parsed, sort_keys=True),
        )

    @staticmethod
    def _cli_usage_complete(status: ClaudeStatus | None) -> bool:
        return status is not None

    @classmethod
    def _fetch_cli_usage(cls) -> ClaudeStatus | None:
        """Read Claude's local `/usage` panel through a bounded no-tools PTY."""
        cli_path = cls._cli_path()
        if cli_path is None:
            return None
        argv = [
            str(cli_path),
            "--ax-screen-reader",
            "--safe-mode",
            "--permission-mode",
            "dontAsk",
            "--tools",
            "",
            "--no-chrome",
            "--session-id",
            str(uuid.uuid4()),
        ]
        master_fd, slave_fd = pty.openpty()
        try:
            process = subprocess.Popen(
                argv,
                stdin=slave_fd,
                stdout=slave_fd,
                stderr=slave_fd,
                cwd="/tmp",
                env={**os.environ, "TERM": "dumb"},
                start_new_session=True,
            )
        except BaseException:
            os.close(master_fd)
            os.close(slave_fd)
            raise
        os.close(slave_fd)
        output = bytearray()
        started = time.monotonic()
        usage_sent = False
        try:
            while time.monotonic() - started < cls._CLI_TIMEOUT_SECONDS:
                ready, _, _ = select.select([master_fd], [], [], 0.25)
                if ready:
                    try:
                        chunk = os.read(
                            master_fd,
                            min(8192, cls._CLI_OUTPUT_LIMIT - len(output)),
                        )
                    except OSError as exc:
                        if exc.errno == errno.EIO:
                            break
                        raise
                    if not chunk:
                        break
                    output.extend(chunk)
                    if len(output) >= cls._CLI_OUTPUT_LIMIT:
                        break
                elapsed = time.monotonic() - started
                if not usage_sent and elapsed >= cls._CLI_SEND_DELAY_SECONDS:
                    os.write(master_fd, b"/usage\r")
                    usage_sent = True
                if usage_sent:
                    parsed = cls._parse_cli_usage(bytes(output))
                    if cls._cli_usage_complete(parsed):
                        break
        finally:
            try:
                os.close(master_fd)
            except OSError:
                pass
            cls._terminate_cli_process(process)
        return cls._parse_cli_usage(bytes(output))

    @staticmethod
    def _terminate_cli_process(process: subprocess.Popen[bytes]) -> None:
        """Terminate and reap the isolated CLI process group."""
        if process.poll() is not None:
            return
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=1.0)
            return
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            return
        process.wait(timeout=1.0)

    @classmethod
    def _fetch_cli_usage_safely(cls) -> ClaudeStatus | None:
        """Return local CLI usage without exposing fallback diagnostics."""
        if _is_headless():
            return None
        try:
            return cls._fetch_cli_usage()
        except (OSError, RuntimeError, ValueError) as exc:
            cls._log.warning("Claude CLI usage fallback unavailable: %s", type(exc).__name__)
            return None

    @property
    def _has_cookies(self) -> bool:
        return bool(self._session_key)

    def fetch(self) -> ClaudeStatus:
        self._acquire()
        if not self._session_key:
            cli_status = self._fetch_cli_usage_safely()
            if cli_status is not None:
                return cli_status
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
                cli_status = self._fetch_cli_usage_safely()
                if cli_status is not None:
                    return cli_status
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
