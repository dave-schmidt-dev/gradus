"""Status dataclasses for Codex, Claude, Antigravity, Cursor, and Vibe providers."""

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
class AntigravityStatus:
    """Antigravity (`agy`) grouped quota for Gemini and third-party models.

    `agy` meters usage per group (Gemini models; Claude+GPT models), each with a
    5-hour and a weekly window. The Gemini and third-party values are kept
    independent so a malformed group cannot hide the other group's quota.
    """

    five_hour_percent_left: int | None
    weekly_percent_left: int | None
    five_hour_reset: str | None
    weekly_reset: str | None
    third_party_five_hour_percent_left: float | None
    third_party_weekly_percent_left: float | None
    third_party_five_hour_reset: str | None
    third_party_weekly_reset: str | None
    account_email: str | None
    account_tier: str | None
    raw_text: str

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(slots=True)
class CopilotStatus:
    premium_requests: int | None
    sample_duration_seconds: int | None
    premium_percent_left: float | None
    premium_reset: str | None
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
