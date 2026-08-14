"""Status dataclasses for Codex, Claude, Antigravity, Cursor, Vibe, and OpenCode Go providers."""

from __future__ import annotations

import math
from dataclasses import asdict, dataclass
from typing import Any


def _clamp_percent(value: object) -> float | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    if not math.isfinite(value):
        return None
    return max(0.0, min(100.0, float(value)))


@dataclass(slots=True)
class CodexStatus:
    credits: float | None
    five_hour_percent_left: float | None
    weekly_percent_left: float | None
    five_hour_reset: str | None
    weekly_reset: str | None
    spark_weekly_percent_left: float | None
    spark_weekly_reset: str | None
    raw_text: str

    def __post_init__(self) -> None:
        for field in (
            "five_hour_percent_left",
            "weekly_percent_left",
            "spark_weekly_percent_left",
        ):
            val = _clamp_percent(getattr(self, field))
            object.__setattr__(self, field, val)
        for field in ("five_hour_reset", "weekly_reset", "spark_weekly_reset"):
            val = getattr(self, field)
            if val is not None and not isinstance(val, str):
                object.__setattr__(self, field, None)
        if not isinstance(self.raw_text, str):
            object.__setattr__(self, "raw_text", str(self.raw_text))

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(slots=True)
class ClaudeStatus:
    session_percent_left: float | None
    weekly_percent_left: float | None
    opus_percent_left: float | None
    primary_reset: str | None
    secondary_reset: str | None
    opus_reset: str | None
    account_email: str | None
    account_organization: str | None
    login_method: str | None
    raw_text: str

    def __post_init__(self) -> None:
        for field in ("session_percent_left", "weekly_percent_left", "opus_percent_left"):
            val = _clamp_percent(getattr(self, field))
            object.__setattr__(self, field, val)
        for field in ("primary_reset", "secondary_reset", "opus_reset"):
            val = getattr(self, field)
            if val is not None and not isinstance(val, str):
                object.__setattr__(self, field, None)
        if not isinstance(self.raw_text, str):
            object.__setattr__(self, "raw_text", str(self.raw_text))

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(slots=True)
class AntigravityStatus:
    """Antigravity (`agy`) grouped quota for Gemini and third-party models.

    `agy` meters usage per group (Gemini models; Claude+GPT models), each with a
    5-hour and a weekly window. The Gemini and third-party values are kept
    independent so a malformed group cannot hide the other group's quota.
    """

    five_hour_percent_left: float | None
    weekly_percent_left: float | None
    five_hour_reset: str | None
    weekly_reset: str | None
    third_party_five_hour_percent_left: float | None
    third_party_weekly_percent_left: float | None
    third_party_five_hour_reset: str | None
    third_party_weekly_reset: str | None
    account_email: str | None
    account_tier: str | None
    raw_text: str

    def __post_init__(self) -> None:
        for field in (
            "five_hour_percent_left",
            "weekly_percent_left",
            "third_party_five_hour_percent_left",
            "third_party_weekly_percent_left",
        ):
            val = _clamp_percent(getattr(self, field))
            object.__setattr__(self, field, val)
        for field in (
            "five_hour_reset",
            "weekly_reset",
            "third_party_five_hour_reset",
            "third_party_weekly_reset",
        ):
            val = getattr(self, field)
            if val is not None and not isinstance(val, str):
                object.__setattr__(self, field, None)
        if not isinstance(self.raw_text, str):
            object.__setattr__(self, "raw_text", str(self.raw_text))

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(slots=True)
class CopilotStatus:
    premium_requests: int | None
    sample_duration_seconds: int | None
    premium_percent_left: float | None
    premium_reset: str | None
    raw_text: str

    def __post_init__(self) -> None:
        for field in ("premium_percent_left",):
            val = _clamp_percent(getattr(self, field))
            object.__setattr__(self, field, val)
        for field in ("premium_reset",):
            val = getattr(self, field)
            if val is not None and not isinstance(val, str):
                object.__setattr__(self, field, None)
        if not isinstance(self.raw_text, str):
            object.__setattr__(self, "raw_text", str(self.raw_text))

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

    def __post_init__(self) -> None:
        for field in ("usage_percent",):
            val = _clamp_percent(getattr(self, field))
            object.__setattr__(self, field, val)
        for field in ("reset_at",):
            val = getattr(self, field)
            if val is not None and not isinstance(val, str):
                object.__setattr__(self, field, None)
        if not isinstance(self.raw_text, str):
            object.__setattr__(self, "raw_text", str(self.raw_text))

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(slots=True)
class OpenCodeGoStatus:
    """OpenCode Go subscription quota from the opencode.ai console.

    The console tracks three dollar-denominated windows ($12 / 5 hours,
    $30 / week, $60 / month, anchored to the subscription date). Percentages
    are remaining capacity (0-100); resets are vendor-display strings.
    """

    five_hour_percent_left: float | None
    five_hour_reset: str | None
    weekly_percent_left: float | None
    weekly_reset: str | None
    monthly_percent_left: float | None
    monthly_reset: str | None
    raw_text: str

    def __post_init__(self) -> None:
        for field in ("five_hour_percent_left", "weekly_percent_left", "monthly_percent_left"):
            val = _clamp_percent(getattr(self, field))
            object.__setattr__(self, field, val)
        for field in ("five_hour_reset", "weekly_reset", "monthly_reset"):
            val = getattr(self, field)
            if val is not None and not isinstance(val, str):
                object.__setattr__(self, field, None)
        if not isinstance(self.raw_text, str):
            object.__setattr__(self, "raw_text", str(self.raw_text))

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

    def __post_init__(self) -> None:
        for field in ("credit_percent_left", "auto_percent_used", "api_percent_used"):
            val = _clamp_percent(getattr(self, field))
            object.__setattr__(self, field, val)
        if not isinstance(self.raw_text, str):
            object.__setattr__(self, "raw_text", str(self.raw_text))

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)
