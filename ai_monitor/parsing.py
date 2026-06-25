"""Status dataclasses for Codex, Claude, Gemini, Cursor, and Vibe providers."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Any


@dataclass(slots=True)
class CodexStatus:
    credits: float | None
    five_hour_percent_left: int | None
    weekly_percent_left: int | None
    five_hour_reset: str | None
    weekly_reset: str | None
    raw_text: str

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(slots=True)
class ClaudeStatus:
    session_percent_left: int | None
    weekly_percent_left: int | None
    opus_percent_left: int | None
    primary_reset: str | None
    secondary_reset: str | None
    opus_reset: str | None
    account_email: str | None
    account_organization: str | None
    login_method: str | None
    raw_text: str

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(slots=True)
class GeminiStatus:
    flash_percent_left: int | None
    pro_percent_left: int | None
    flash_reset: str | None
    pro_reset: str | None
    account_email: str | None
    account_tier: str | None
    raw_text: str

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(slots=True)
class VibeStatus:
    usage_percent: float | None
    reset_at: str | None
    payg_enabled: bool | None
    start_date: str | None
    end_date: str | None
    raw_text: str

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(slots=True)
class CursorStatus:
    credit_percent_left: float | None
    auto_percent_used: float | None
    api_percent_used: float | None
    remaining_cents: int | None
    limit_cents: int | None
    plan_name: str | None
    billing_cycle_start: str | None
    billing_cycle_end: str | None
    billing_cycle_end_iso: str | None
    raw_text: str

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)
