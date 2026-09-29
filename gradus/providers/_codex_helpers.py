"""Codex rate-limit window helpers."""

from __future__ import annotations

from typing import Any

_CODEX_WEEKLY_MIN_SECONDS = 86_400


def _codex_percent_left(window: dict[str, Any] | None) -> float | None:
    if not isinstance(window, dict):
        return None
    used_pct = window.get("used_percent")
    if used_pct is None:
        return None
    try:
        return 100.0 - float(used_pct)
    except (TypeError, ValueError):
        return None


def _classify_codex_windows(
    windows: list[Any],
) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    five_hour: dict[str, Any] | None = None
    weekly: dict[str, Any] | None = None
    for index, window in enumerate(windows):
        if not isinstance(window, dict):
            continue
        span = window.get("limit_window_seconds")
        if isinstance(span, (int, float)):
            is_weekly = span >= _CODEX_WEEKLY_MIN_SECONDS
        else:
            is_weekly = index != 0
        if is_weekly:
            if weekly is None:
                weekly = window
        elif five_hour is None:
            five_hour = window
    return five_hour, weekly
