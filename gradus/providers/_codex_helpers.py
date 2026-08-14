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


def _extract_spark_window(payload: dict[str, Any]) -> dict[str, Any] | None:
    """Pull the weekly window for the GPT-5.3-Codex-Spark bucket.

    Spark ships in a top-level ``additional_rate_limits`` array (sibling of
    ``rate_limit``), one element per named bucket. Prefer matching on
    ``metered_feature == "codex_bengalfox"`` (the stable machine key); fall
    back to matching on the display name ``limit_name`` if the feature key is
    absent or doesn't match anything. Every malformed shape degrades to
    ``None`` rather than raising, so a Spark payload change can never crash
    the whole Codex probe.
    """
    entries = payload.get("additional_rate_limits")
    if not isinstance(entries, list):
        return None

    by_feature: dict[str, Any] | None = None
    by_name: dict[str, Any] | None = None
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        if by_feature is None and entry.get("metered_feature") == "codex_bengalfox":
            by_feature = entry
        if by_name is None and entry.get("limit_name") == "GPT-5.3-Codex-Spark":
            by_name = entry

    spark_entry = by_feature if by_feature is not None else by_name
    if spark_entry is None:
        return None

    rate_limit = spark_entry.get("rate_limit")
    if not isinstance(rate_limit, dict):
        return None
    primary_window = rate_limit.get("primary_window")
    if not isinstance(primary_window, dict):
        return None
    return primary_window


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
