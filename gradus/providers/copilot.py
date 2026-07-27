"""Copilot provider."""

from __future__ import annotations

import json
import logging
import re
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from ..parsing import CopilotStatus
from . import _base
from ._base import ProbeFailure, _format_reset_time, _is_headless, register

log = logging.getLogger(__name__)


@register("Copilot")
class CopilotHttpProvider:
    _API_URL = "https://api.github.com/copilot_internal/user"

    def __init__(self) -> None:
        if not shutil.which("gh"):
            raise FileNotFoundError("gh not found on PATH")

    def _get_token(self) -> str:
        token = self._read_hosts_yml()
        if token:
            return token
        if _is_headless():
            raise ProbeFailure(
                "Copilot auth required: ~/.config/gh/hosts.yml not found (headless)", ""
            )
        return self._gh_auth_token_subprocess()

    def _read_hosts_yml(self) -> str | None:
        hosts_path = Path.home() / ".config" / "gh" / "hosts.yml"
        if not hosts_path.exists():
            return None
        try:
            text = hosts_path.read_text(encoding="utf-8")
        except OSError:
            return None
        in_github = False
        for line in text.splitlines():
            stripped = line.strip()
            if stripped == "github.com:":
                in_github = True
                continue
            if not stripped or not in_github:
                continue
            if stripped.startswith("-"):
                continue
            if re.match(r"^oauth_token:\s*(\S+)", stripped):
                return re.match(r"^oauth_token:\s*(\S+)", stripped).group(1)
            if not line[0].isspace():
                in_github = False
        return None

    def _gh_auth_token_subprocess(self) -> str:
        try:
            result = subprocess.run(
                ["gh", "auth", "token"],
                capture_output=True,
                text=True,
                timeout=10,
                check=True,
            )
            token = result.stdout.strip()
            if not token:
                raise ProbeFailure("gh auth token returned empty output", "")
            return token
        except subprocess.CalledProcessError as exc:
            raise ProbeFailure(
                "gh auth login required: run `gh auth login`",
                str(exc),
            ) from exc

    @staticmethod
    def _monthly_reset_label() -> str:
        now = datetime.now(timezone.utc)
        year = now.year + (1 if now.month == 12 else 0)
        month = 1 if now.month == 12 else now.month + 1
        reset = datetime(year, month, 1, 0, 0, tzinfo=timezone.utc)
        return f"Resets {reset.astimezone().strftime('%b %d at %I:%M %p')}"

    def fetch(self) -> CopilotStatus:
        token = self._get_token()
        try:
            payload = _base._http_json(
                self._API_URL,
                headers={
                    "Authorization": f"Bearer {token}",
                    "Accept": "application/json",
                },
            )
        except ProbeFailure as exc:
            if "HTTP 401" in str(exc):
                raise ProbeFailure("Copilot auth failed: run `gh auth login`", str(exc)) from exc
            raise

        raw_text = json.dumps(payload, indent=2, sort_keys=True)

        premium_percent_left: float | None = None
        premium_requests: int | None = None
        premium_reset: str | None = None

        quota_snapshots = payload.get("quota_snapshots") or {}
        premium = quota_snapshots.get("premium_interactions") or {}
        if premium:
            if premium.get("unlimited", False):
                premium_percent_left = 100.0
            else:
                pct_remaining = premium.get("percent_remaining")
                if pct_remaining is not None:
                    try:
                        premium_percent_left = round(float(pct_remaining), 2)
                    except (TypeError, ValueError):
                        pass
                remaining = premium.get("remaining")
                if remaining is not None:
                    try:
                        premium_requests = int(remaining)
                    except (TypeError, ValueError):
                        pass

        reset_at = payload.get("quota_reset_date_utc") or payload.get("quota_reset_date")
        premium_reset = _format_reset_time(reset_at) if reset_at else None

        if premium_reset is None:
            premium_reset = self._monthly_reset_label()

        return CopilotStatus(
            premium_percent_left=premium_percent_left,
            premium_requests=premium_requests,
            sample_duration_seconds=None,
            premium_reset=premium_reset,
            raw_text=raw_text,
        )

    def close(self) -> None:
        pass
