"""Router-facing capacity snapshot: normalization and atomic persistence.

This module is deliberately side-effect free apart from :func:`write_snapshot`.
It must NOT import :mod:`gradus.providers` or :mod:`gradus.ui` at
runtime to avoid the import cycle ``providers <- snapshot <- ui``. The only
provider type referenced is :class:`ProviderSnapshot`, imported under
``TYPE_CHECKING`` for annotations; all runtime access is duck-typed
(``.name`` / ``.ok`` / ``.data`` / ``.error``).
"""

from __future__ import annotations

import errno
import fcntl
import json
import logging
import math
import os
import re
import tempfile
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from datetime import datetime, timedelta
from enum import Enum
from pathlib import Path
from typing import TYPE_CHECKING, Literal

if TYPE_CHECKING:  # pragma: no cover - typing only, never imported at runtime
    from .providers import ProviderSnapshot

from .providers._base import _canonical_providers

log = logging.getLogger(__name__)

SCHEMA_VERSION = 1
SCHEMA_VERSION_V2 = 2

# Contract-mandated, credential-free state directory (NOT `.cache/`).
SNAPSHOT_PATH = Path(__file__).resolve().parent.parent / ".state" / "snapshot.json"
SNAPSHOT_V2_PATH = Path(__file__).resolve().parent.parent / ".state" / "snapshot-v2.json"
# Credential-free v2 mirror read by the installed menu-bar app. Keeping the
# app out of the Documents-backed repository avoids macOS TCC prompts.
MAC_APP_SNAPSHOT_V2_PATH = (
    Path.home() / "Library" / "Application Support" / "Gradus" / "snapshot-v2.json"
)

# Stop serving cached data after this many seconds (moved from __main__.py).
STALE_THRESHOLD_SECONDS = 300  # 5 minutes
AUTH_GRACE_WINDOW_SECONDS = STALE_THRESHOLD_SECONDS
AUTH_ESCALATION_WINDOW_SECONDS = 600
ANTIGRAVITY_AUTH_RETRY_MESSAGE = "Antigravity refresh retrying; values may be stale"
ANTIGRAVITY_AUTH_ERROR_MARKER = "Antigravity session expired"


def is_antigravity_auth_failure(snapshot: object) -> bool:
    """Return whether a probe is the credential failure eligible for grace."""
    name = getattr(snapshot, "name", None)
    if name != "Antigravity" or getattr(snapshot, "ok", True):
        return False
    if getattr(snapshot, "debug_detail", None) == "auth_failure":
        return True
    error = getattr(snapshot, "error", None)
    if not isinstance(error, str):
        return False
    lower = error.lower()
    return "antigravity" in lower and (
        "session expired" in lower or "re-authenticate" in lower or "run `agy`" in lower
    )


def is_antigravity_auth_retry(error: object) -> bool:
    """Return whether ``error`` is the exact neutral grace marker."""
    return error == ANTIGRAVITY_AUTH_RETRY_MESSAGE


class SnapshotWrite(Enum):
    """The outcome of a :func:`write_snapshot` call.

    This is deliberately not a ``bool``. ``write_snapshot`` has two distinct
    non-error outcomes -- it wrote the caller's payload, or it declined to
    because the file on disk is already newer -- and a caller that needs to
    know which one happened (for example, to decide whether it owns this
    cycle's history journal) cannot recover that from a single flag. Returning
    ``True`` for both is what made a correct no-op read as a persistence
    failure on every cycle of a two-writer race.
    """

    WRITTEN = "written"
    """The payload was atomically committed to the path."""

    SKIPPED_STALE = "skipped_stale"
    """A newer payload is already on disk; the write was correctly declined.

    Not an error. The file is fresher than what this caller offered, so
    whichever writer put it there owns any downstream work for that payload.
    """

    FAILED = "failed"
    """The payload was not committed: lock, serialization, or IO failure."""

    @property
    def persisted(self) -> bool:
        """Whether the path holds this payload or a newer one.

        True for both :attr:`WRITTEN` and :attr:`SKIPPED_STALE`. This is the
        right question for "is the destination healthy"; it is the wrong
        question for "should I do the follow-up work for my payload" -- use
        ``is SnapshotWrite.WRITTEN`` for that.
        """
        return self is not SnapshotWrite.FAILED


def percent_is_valid(percent_left: object) -> bool:
    """Return whether a remaining percentage is finite and within 0-100."""
    return (
        isinstance(percent_left, (int, float))
        and not isinstance(percent_left, bool)
        and math.isfinite(percent_left)
        and 0.0 <= percent_left <= 100.0
    )


#: A remaining percentage strictly below this rounds to zero, so the window is
#: treated as depleted. Stated as a bound rather than as ``round(x) <= 0``
#: deliberately: Python's ``round`` is banker's rounding (``round(0.5) == 0``)
#: while Swift's ``.rounded()`` is half-away-from-zero (``(0.5).rounded() == 1``),
#: so the two spellings disagreed at exactly 0.5 and a provider sitting there
#: was depleted-and-warning on the TUI but neither on Mac/iOS. Because
#: ``percent_is_valid`` bounds the input to 0-100, ``floor(x + 0.5) <= 0`` is
#: exactly ``x < 0.5``, so this form is identical on both platforms with no
#: rounding mode to get wrong. Mirrored by ``depletedPercentCeiling`` in
#: ``app/GradusKit/Sources/GradusKit/WarningPredicate.swift``.
DEPLETED_PERCENT_CEILING = 0.5


def percent_is_depleted(percent_left: object) -> bool:
    """Return whether a normalized remaining percentage rounds down to zero.

    True for anything in ``[0, 0.5)``. Exactly 0.5 is *not* depleted: it
    renders as 1% once rounded, and there is still something left to spend.
    """
    return percent_is_valid(percent_left) and float(percent_left) < DEPLETED_PERCENT_CEILING


#: Pace at or above this is healthy: spending exactly as fast as the clock
#: runs down is what the window is for.
PACE_GREEN_FLOOR = 0.0

#: Drifting behind, but not yet by enough to act on.
PACE_YELLOW_FLOOR = -0.10

#: Burning down more than 25 points faster than the clock. This separates
#: "drifting" from "will run out early" and is the one number here free to be
#: retuned; the other two are pinned by what they mean.
PACE_ORANGE_FLOOR = -0.25


def _percent_fallback_level(percent: float) -> str:
    """Classify by absolute percentage alone, for windows with no usable pace.

    This is the pre-pace ramp, kept only as :func:`signal_level`'s step 3 — it
    is not a public alternative to it. Reaching it means the window has no
    reset timestamp, so there is no evidence about how fast the remaining
    percentage is being spent.

    Mirrors the ``guard let paceDelta`` branch of ``signalLevel`` in
    ``app/GradusKit/Sources/GradusKit/SignalLevel.swift``.
    """
    if percent >= 70:
        return "green"
    if percent >= 40:
        return "yellow"
    if percent >= 20:
        return "orange"
    return "red"


def signal_level(percent: float | None, pace: float | None) -> str:
    """Classify a window by pace rather than by absolute percentage left.

    Mirrors ``signalLevel`` in ``app/GradusKit/Sources/GradusKit/SignalLevel.swift``.
    The two are held together by the shared truth table at
    ``app/GradusKit/Tests/GradusKitTests/Fixtures/signal-levels.json``, which
    both test suites read.

    Lives here rather than in ``ui.py`` because :func:`window_warns` is defined
    in terms of it and ``ui`` imports ``snapshot``, not the reverse. The Rich
    style mapping stays in ``ui.py``: this function classifies, it does not
    present.

    The rules, in order:

    1. An invalid percentage (missing, non-finite, or outside 0-100 per
       INV-3) is ``unknown``. This is stricter than the pre-pace ramp, which
       returned green for a value like 150.
    2. A depleted percentage is ``red`` regardless of pace — there is nothing
       left to pace.
    3. A missing or non-finite pace falls back to the percent-only ramp so a
       window without a reset timestamp still gets a color.
    4. Otherwise the pace delta selects the step.

    Args:
        percent: Remaining percentage, normalized 0-100.
        pace: ``fraction_left - fraction_of_window_remaining``. Positive is
            ahead of schedule. Not clamped (INV-4).

    Returns:
        One of ``green``, ``yellow``, ``orange``, ``red``, ``unknown``.
    """
    if not percent_is_valid(percent):
        return "unknown"
    if percent_is_depleted(percent):
        return "red"

    pace_is_usable = (
        isinstance(pace, (int, float)) and not isinstance(pace, bool) and math.isfinite(pace)
    )
    if not pace_is_usable:
        return _percent_fallback_level(percent)

    if pace >= PACE_GREEN_FLOOR:
        return "green"
    if pace >= PACE_YELLOW_FLOOR:
        return "yellow"
    if pace >= PACE_ORANGE_FLOOR:
        return "orange"
    return "red"


def window_warns(window: Mapping[str, object]) -> bool:
    """Return whether one normalized window warrants attention.

    Defined as *the ramp said orange or red* — deliberately the same predicate
    that colors the row, not a parallel one. Before 2026-08-06 this was its own
    rule (depleted, or finite pace below -0.10), which agreed with the ramp for
    every window carrying a pace and disagreed for every window without one: a
    19%-left window with no reset timestamp rendered red and raised no alert,
    on the reasoning that there was no evidence to alert on.

    That gap was real but it was not the reason this changed. The two rules
    were also aggregated differently per provider — the Mac asked only about
    its worst-by-percentage window, iOS about any window — so the same snapshot
    could produce a warning count on one platform and not the other. Collapsing
    both onto one predicate with one aggregation
    (:func:`warning_window_ids`) is what makes them agree by construction.

    Invalid percentage values, including booleans, are never candidates.
    """
    percent_left = window.get("percent_left")
    if not percent_is_valid(percent_left):
        return False
    pace = window.get("pace_delta")
    if isinstance(pace, bool) or not isinstance(pace, (int, float)):
        pace = None
    return signal_level(float(percent_left), pace) in ("orange", "red")


def _is_transient_probe_error(snapshot: ProviderSnapshot) -> bool:
    """Return True when a failed probe looks transient (safe to serve stale).

    Duck-typed: reads only ``.ok`` and ``.error`` so no provider import is
    needed. A transient error is one whose message matches a known set of
    retryable markers (rate limits, timeouts, expired tokens, etc.).

    Args:
        snapshot: Any object exposing ``ok`` (bool) and ``error`` (str | None).

    Returns:
        True if the snapshot failed with a transient/retryable error.
    """
    if snapshot.ok or not snapshot.error:
        return False
    message = snapshot.error.lower()
    transient_markers = (
        "rate limited",
        "failed to load usage data",
        "could not load usage data",
        "empty claude output",
        "missing current session",
        "data not available yet",
        "http 429",
        "http 500",
        "http 502",
        "http 503",
        "http 504",
        "token expired",
        "network error",
        "timed out",
        "invalid json",
        "cursor api network error",
    )
    return any(marker in message for marker in transient_markers)


# The exact message a provider emits when it DELIBERATELY declines to probe
# because gradus is running headless (INV-2: the headless --write-snapshot /
# --json path must have zero side effects, so a Keychain-only provider like
# Antigravity refuses to read its credential rather than risk a GUI unlock
# prompt or an `agy` refresh subprocess). Produced ONLY under ``_is_headless()``
# — see ``providers/_base._auth_required_message`` and
# ``AntigravityProvider._acquire`` — so it can never appear on the live/
# interactive probe path. That headless-exclusivity is what makes carrying a
# recent healthy prior's *values* safe here. The failed probe still remains a
# failure with its actionable reason; only the last known-good values and their
# true observation time are retained.
_HEADLESS_DEFERRED_PROBE_MESSAGE = "auth required: no cached credentials"


def _is_headless_deferred_probe(snapshot: ProviderSnapshot) -> bool:
    """Return True when a probe was skipped solely because gradus ran headless.

    Distinct from :func:`_is_transient_probe_error`: this is not a flaky or
    retryable failure but a deliberate headless refusal to touch a credential
    store. The most recent interactive snapshot is the authoritative state for
    such a provider, so it should be carried forward (bounded by
    ``STALE_THRESHOLD_SECONDS``, exactly like a transient failure) rather than
    published as ``ok: false`` — which would otherwise drop the provider out of
    every downstream router's candidate set (e.g. Switchyard fails closed with
    ``no_provider`` when its only permitted provider reads ``ok: false``).

    Args:
        snapshot: Any object exposing ``ok`` (bool) and ``error`` (str | None).

    Returns:
        True if the probe failed solely because it was deferred while headless.
    """
    if snapshot.ok or not snapshot.error:
        return False
    return _HEADLESS_DEFERRED_PROBE_MESSAGE in snapshot.error.lower()


def parse_reset_target(reset_text: str | None, now: datetime) -> datetime | None:
    """Parse a human reset string into a concrete future ``datetime``.

    Faithful copy of ``gradus.ui._parse_reset_target``. Handles relative
    forms (``in 3h``), ``... on <date>``, ``... at <time>``, and bare
    ``resets <time>`` forms, rolling past instants forward as appropriate.

    Args:
        reset_text: The provider-emitted reset string, or None / ``"n/a"``.
        now: The reference instant used to resolve relative/rolled targets.

    Returns:
        The resolved target datetime, or None when nothing parseable is found.
    """
    if not reset_text or reset_text == "n/a":
        return None
    normalized = re.sub(r"\s+", " ", reset_text).strip()
    lower = normalized.lower()
    target: datetime | None = None
    target_year = now.year
    fragments = normalized.split("(", 1)[0].replace("resets", "").replace("Resets", "").strip()
    fragments = fragments.replace(",", "")
    fragments = re.sub(r"(?i)(\d)(am|pm)\b", r"\1 \2", fragments)
    fragments = re.sub(r"\s+", " ", fragments).strip()

    relative = re.search(
        r"(?i)\bin\s+(?:(?P<days>\d+)d\s*)?(?:(?P<hours>\d+)h\s*)?(?:(?P<minutes>\d+)m)?",
        fragments,
    )
    if relative and any(relative.group(name) for name in ("days", "hours", "minutes")):
        try:
            return now + timedelta(
                days=int(relative.group("days") or 0),
                hours=int(relative.group("hours") or 0),
                minutes=int(relative.group("minutes") or 0),
            )
        except (OverflowError, ValueError):
            return None

    if " on " in lower:
        candidates = [fragments]
        if fragments.lower().startswith("on "):
            candidates.insert(0, fragments[3:].strip())
        for candidate in candidates:
            stamped = f"{candidate} {target_year}"
            for fmt in (
                "%H:%M on %d %b %Y",
                "%I %p on %d %b %Y",
                "%I:%M %p on %d %b %Y",
                "%b %d %H:%M %Y",
                "%b %d %I %p %Y",
                "%b %d %I:%M %p %Y",
            ):
                try:
                    parsed = datetime.strptime(stamped, fmt)
                except ValueError:
                    continue
                target = parsed
                break
            if target is not None:
                break
    elif " at " in lower:
        stamped = f"{fragments} {target_year}"
        for fmt in (
            "%b %d at %H:%M %Y",
            "%b %d at %I %p %Y",
            "%b %d at %I:%M %p %Y",
            "%d %b at %H:%M %Y",
            "%d %b at %I %p %Y",
            "%d %b at %I:%M %p %Y",
        ):
            try:
                parsed = datetime.strptime(stamped, fmt)
            except ValueError:
                continue
            target = parsed
            break
    elif lower.startswith("resets "):
        for fmt in ("%H:%M", "%I %p", "%I:%M %p"):
            try:
                parsed = datetime.strptime(fragments, fmt)
            except ValueError:
                continue
            target = now.replace(hour=parsed.hour, minute=parsed.minute, second=0, microsecond=0)
            if target < now:
                target = target + timedelta(days=1)
            break

    return target


def local_iso(dt: datetime) -> str:
    """Serialize a datetime to an ISO-8601 string that always carries an offset.

    Naive datetimes are assumed to be local wall-clock time and are attached to
    the local timezone; aware datetimes keep their existing offset.

    Args:
        dt: The datetime to serialize.

    Returns:
        An ISO-8601 string with a UTC offset.
    """
    return (dt if dt.tzinfo else dt.astimezone()).isoformat()


def reconcile(a: datetime, b: datetime) -> tuple[datetime, datetime]:
    """Coerce the second datetime's tz-awareness to match the first.

    This is the single tz-reconciliation site used for both reset<->now and
    billing start<->end. ``a`` is authoritative and never modified.

    Args:
        a: The reference datetime whose tz-awareness is authoritative.
        b: The datetime to align to ``a``.

    Returns:
        The pair ``(a, b)`` where ``b`` is naive iff ``a`` is naive.
    """
    if a.tzinfo is None and b.tzinfo is not None:
        b = b.replace(tzinfo=None)
    elif a.tzinfo is not None and b.tzinfo is None:
        b = b.replace(tzinfo=a.tzinfo)
    return a, b


def pace_delta(
    percent_left: float | None,
    reset_dt: datetime | None,
    window_total_seconds: float | None,
    now: datetime,
) -> float | None:
    """Compute the canonical signed pace delta (INV-4).

    The delta is ``fraction_left - fraction_of_window_remaining``. It is a
    signed fraction where POSITIVE means ahead/healthy (more budget left than
    time). It is finite and NOT clamped: a reset rolled far into the future can
    legitimately push it below ``-1``.

    Args:
        percent_left: Remaining budget as a percentage (0-100), or None.
        reset_dt: When the window resets, or None.
        window_total_seconds: Total window length in seconds; None/<=0 -> None.
        now: The reference instant.

    Returns:
        The signed pace fraction, or None when any input is missing/invalid.
    """
    if (
        percent_left is None
        or reset_dt is None
        or not window_total_seconds
        or window_total_seconds <= 0
    ):
        return None
    reset_dt, now = reconcile(reset_dt, now)
    remaining = max(0.0, (reset_dt - now).total_seconds())
    return percent_left / 100.0 - remaining / window_total_seconds


@dataclass(frozen=True, slots=True)
class WindowSpec:
    """Declarative description of one provider usage window.

    Session windows use ``reset_key`` + ``window_hours``; billing windows use
    ``normalize`` + ``start_key`` + ``end_key``.
    """

    window_id: str
    kind: Literal["session", "billing"]
    percent_key: str
    reset_key: str | None = None
    window_hours: float | None = None
    normalize: Literal["remaining", "used"] | None = None
    start_key: str | None = None
    end_key: str | None = None


WINDOW_SPECS: dict[str, tuple[WindowSpec, ...]] = {
    "Codex": (
        WindowSpec(
            "five_hour",
            "session",
            "five_hour_percent_left",
            reset_key="five_hour_reset",
            window_hours=5.0,
        ),
        WindowSpec(
            "weekly", "session", "weekly_percent_left", reset_key="weekly_reset", window_hours=168.0
        ),
    ),
    "Claude": (
        WindowSpec(
            "five_hour",
            "session",
            "session_percent_left",
            reset_key="primary_reset",
            window_hours=5.0,
        ),
        WindowSpec(
            "weekly",
            "session",
            "weekly_percent_left",
            reset_key="secondary_reset",
            window_hours=168.0,
        ),
    ),
    "Antigravity": (
        WindowSpec(
            "five_hour",
            "session",
            "five_hour_percent_left",
            reset_key="five_hour_reset",
            window_hours=5.0,
        ),
        WindowSpec(
            "weekly", "session", "weekly_percent_left", reset_key="weekly_reset", window_hours=168.0
        ),
    ),
    "Cursor": (
        WindowSpec(
            "billing_cycle",
            "billing",
            "credit_percent_left",
            normalize="remaining",
            start_key="billing_cycle_start",
            end_key="billing_cycle_end_iso",
        ),
    ),
    "Vibe": (
        WindowSpec(
            "billing_cycle",
            "billing",
            "usage_percent",
            normalize="used",
            start_key="start_date",
            end_key="end_date",
        ),
    ),
    "Copilot": (
        WindowSpec(
            "premium",
            "billing",
            "premium_percent_left",
            normalize="remaining",
            reset_key="premium_reset",
        ),
    ),
    # The monthly window is anchored to the subscription date (not the calendar
    # month), so 30 days is an approximation of its true 28-31 day length.
    "OpenCode Go": (
        WindowSpec(
            "five_hour",
            "session",
            "five_hour_percent_left",
            reset_key="five_hour_reset",
            window_hours=5.0,
        ),
        WindowSpec(
            "weekly", "session", "weekly_percent_left", reset_key="weekly_reset", window_hours=168.0
        ),
        WindowSpec(
            "monthly",
            "session",
            "monthly_percent_left",
            reset_key="monthly_reset",
            window_hours=720.0,
        ),
    ),
}


WARNING_WINDOW_SPECS = {
    **WINDOW_SPECS,
    # These pools are intentionally alert-only until snapshot schema v2. The
    # v1 router payload remains billing_cycle-only for Cursor.
    #
    # ``ap`` is sourced from ``api_percent_used`` (Cursor's real API/
    # third-party pool percent-used) rather than ``credit_percent_left``
    # (a dollar-spend meter, not a usage pool — conflating the two produced
    # a misleading "ap" row). Window IDs are kept as ``ac``/``ap`` rather
    # than renamed: these WindowSpecs are reused verbatim as
    # V2_WINDOW_SPECS["Cursor"] below, so the IDs double as the persisted
    # schema-v2 window IDs INV-5 documents as part of the versioned
    # contract consumed by hermes-publisher and review-plugin. Renaming
    # them would be an incompatible windows[] change requiring a schema
    # bump plus coordinated updates in both consumer repos (out of scope
    # here) — see HISTORY.md 2026-07-16 for the full note.
    "Cursor": (
        WindowSpec(
            "ac",
            "billing",
            "auto_percent_used",
            normalize="used",
            start_key="billing_cycle_start",
            end_key="billing_cycle_end_iso",
        ),
        WindowSpec(
            "ap",
            "billing",
            "api_percent_used",
            normalize="used",
            start_key="billing_cycle_start",
            end_key="billing_cycle_end_iso",
        ),
    ),
    # C+G quota buckets are interactive alert state only. Router v1/v2
    # snapshots intentionally continue to expose Antigravity's Gemini pools.
    "Antigravity": (
        *WINDOW_SPECS["Antigravity"],
        WindowSpec(
            "cg5",
            "session",
            "third_party_five_hour_percent_left",
            reset_key="third_party_five_hour_reset",
            window_hours=5.0,
        ),
        WindowSpec(
            "cg1w",
            "session",
            "third_party_weekly_percent_left",
            reset_key="third_party_weekly_reset",
            window_hours=168.0,
        ),
    ),
}

# Schema v2 keeps every non-Cursor window byte-for-byte compatible with v1,
# while publishing Cursor's two actual capacity pools independently.
V2_WINDOW_SPECS = {
    **WINDOW_SPECS,
    "Cursor": WARNING_WINDOW_SPECS["Cursor"],
}

# Task A.1: the same third_party_* fields WARNING_WINDOW_SPECS["Antigravity"]
# already sources for its interactive-only cg5/cg1w alert windows, but under
# the standard five_hour/weekly window-id convention every other v1/v2
# provider entry uses — this tuple is what the synthetic "Antigravity
# (Claude)" entry's OWN windows are built from. Registered below under both
# V2_WINDOW_SPECS and WARNING_WINDOW_SPECS (Task A.2) so CR-6 retention
# validation and interactive-alert lookups both resolve correctly for the
# synthetic name.
THIRD_PARTY_WINDOW_SPECS: tuple[WindowSpec, ...] = (
    WindowSpec(
        "five_hour",
        "session",
        "third_party_five_hour_percent_left",
        reset_key="third_party_five_hour_reset",
        window_hours=5.0,
    ),
    WindowSpec(
        "weekly",
        "session",
        "third_party_weekly_percent_left",
        reset_key="third_party_weekly_reset",
        window_hours=168.0,
    ),
)

V2_WINDOW_SPECS["Antigravity (Claude)"] = THIRD_PARTY_WINDOW_SPECS
WARNING_WINDOW_SPECS["Antigravity (Claude)"] = THIRD_PARTY_WINDOW_SPECS


def _build_windows(
    snapshot: ProviderSnapshot,
    now: datetime,
    specs_by_provider: Mapping[str, tuple[WindowSpec, ...]],
) -> list[dict]:
    """Normalize a provider snapshot into router-facing window dicts (Gap-3).

    Each window is isolated so malformed metadata in one pool cannot suppress
    its siblings.

    Args:
        snapshot: The provider snapshot to normalize.
        now: The reference instant for pace/reset computation.

    Returns:
        A list of ``{"id", "percent_left", "reset_iso", "window_hours",
        "pace_delta"}`` dicts, or ``[]`` when the snapshot is unusable.
    """
    if not snapshot.ok or not isinstance(snapshot.data, Mapping):
        return []
    provider_name = (
        snapshot.name.removesuffix(" [HTTP]")
        if hasattr(snapshot.name, "removesuffix")
        else snapshot.name
    )
    specs = specs_by_provider.get(provider_name)
    if not specs:
        return []
    data = snapshot.data
    windows: list[dict] = []
    for spec in specs:
        # A malformed sibling must never hide an otherwise valid/depleted
        # capacity pool. Each spec is therefore isolated deliberately.
        try:
            if spec.kind == "session":
                raw = data.get(spec.percent_key)
                pct = float(raw) if percent_is_valid(raw) else None
                if pct is None:
                    # Window absent (e.g. Codex 5h after OpenAI's 2026-07 removal).
                    # Emitting a null-percent window would violate the router
                    # contract (percent_left is always numeric); omit it instead.
                    continue
                reset_raw = data.get(spec.reset_key) if spec.reset_key else None
                target = parse_reset_target(str(reset_raw) if reset_raw is not None else None, now)
                reset_iso = local_iso(target) if target else None
                window_hours = spec.window_hours
                delta = pace_delta(pct, target, (window_hours or 0.0) * 3600.0, now)
                windows.append(
                    {
                        "id": spec.window_id,
                        "percent_left": pct,
                        "reset_iso": reset_iso,
                        "window_hours": window_hours,
                        "pace_delta": delta,
                    }
                )
            else:  # billing
                raw = data.get(spec.percent_key)
                if spec.normalize == "used":
                    # INV-3: the single normalization point for billing usage
                    # reported as used (Vibe and Cursor Auto + Composer).
                    pct = 100.0 - float(raw) if percent_is_valid(raw) else None
                else:
                    pct = float(raw) if percent_is_valid(raw) else None
                if pct is None:
                    # Billing windows also require a numeric remaining percent.
                    # A missing source value must omit the window, never emit
                    # ``percent_left: null`` in the v1 router payload.
                    continue
                start_raw = data.get(spec.start_key) if spec.start_key else None
                end_raw = data.get(spec.end_key) if spec.end_key else None
                start_iso = start_raw if isinstance(start_raw, str) else None
                end_iso = end_raw if isinstance(end_raw, str) else None
                if start_iso and end_iso:
                    try:
                        start = datetime.fromisoformat(start_iso)
                        end = datetime.fromisoformat(end_iso)
                    except ValueError:
                        # Capacity remains usable even when Cursor's billing
                        # boundaries are malformed; omit only pace metadata.
                        window_hours = None
                        reset_iso = None
                        delta = None
                    else:
                        start, end = reconcile(start, end)
                        total_seconds = (end - start).total_seconds()
                        window_hours = max(1.0, total_seconds) / 3600.0
                        reset_iso = end_iso
                        delta = pace_delta(pct, end, total_seconds, now)
                elif spec.reset_key and data.get(spec.reset_key):
                    reset_raw = str(data[spec.reset_key])
                    target = parse_reset_target(reset_raw, now)
                    start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
                    if target:
                        start, target = reconcile(start, target)
                        if target > start:
                            total_seconds = (target - start).total_seconds()
                            window_hours = total_seconds / 3600.0
                            reset_iso = local_iso(target)
                            delta = pace_delta(pct, target, total_seconds, now)
                        else:
                            window_hours = None
                            reset_iso = local_iso(target)
                            delta = None
                    else:
                        window_hours = None
                        reset_iso = None
                        delta = None
                else:
                    window_hours = None
                    reset_iso = end_iso if end_iso else None
                    delta = None
                windows.append(
                    {
                        "id": spec.window_id,
                        "percent_left": pct,
                        "reset_iso": reset_iso,
                        "window_hours": window_hours,
                        "pace_delta": delta,
                    }
                )
        except Exception:  # noqa: BLE001 - one provider field must not hide siblings
            log.debug(
                "failed to normalize %s window %s", snapshot.name, spec.window_id, exc_info=True
            )
    return windows


def build_windows(snapshot: ProviderSnapshot, now: datetime) -> list[dict]:
    """Normalize a snapshot into the stable router v1 window records."""
    return _build_windows(snapshot, now, WINDOW_SPECS)


def normalized_warning_windows(snapshot: ProviderSnapshot, now: datetime) -> list[dict]:
    """Normalize windows for in-process UI and alert evaluation.

    Unlike :func:`build_windows`, Cursor receives independent ``ac`` and
    ``ap`` records, and Antigravity includes C+G ``cg5`` and ``cg1w`` records.
    This interactive state is deliberately not persisted.
    """
    return _build_windows(snapshot, now, WARNING_WINDOW_SPECS)


def build_v2_windows(snapshot: ProviderSnapshot, now: datetime) -> list[dict]:
    """Normalize a snapshot into schema-v2 router window records."""
    return _build_windows(snapshot, now, V2_WINDOW_SPECS)


def warning_window_ids(snapshot: ProviderSnapshot, now: datetime) -> tuple[str, ...]:
    """Return the warning window IDs for one provider snapshot."""
    return tuple(
        str(window["id"])
        for window in normalized_warning_windows(snapshot, now)
        if window_warns(window)
    )


def warning_membership(
    snapshots: list[ProviderSnapshot], now: datetime
) -> dict[str, tuple[str, ...]]:
    """Return warning window membership keyed by provider name."""
    return {snapshot.name: warning_window_ids(snapshot, now) for snapshot in snapshots}


# INV-1 allowlist: only these usage/reset fields ever leave the process. Any
# identity/credential field (account_email, tokens, raw_text, ...) is dropped.
SAFE_DATA_KEYS = frozenset(
    {
        "credits",
        "five_hour_percent_left",
        "weekly_percent_left",
        "five_hour_reset",
        "weekly_reset",
        "session_percent_left",
        "opus_percent_left",
        "primary_reset",
        "secondary_reset",
        "opus_reset",
        "usage_percent",
        "reset_at",
        "payg_enabled",
        "start_date",
        "end_date",
        "monthly_percent_left",
        "monthly_reset",
        "auto_percent_used",
        "api_percent_used",
        "billing_cycle_start",
        "billing_cycle_end",
        "billing_cycle_end_iso",
        "premium_percent_left",
        "premium_reset",
    }
)


def project_data(snapshot: ProviderSnapshot) -> dict:
    """Project a snapshot's data down to the INV-1 safe allowlist.

    Args:
        snapshot: The provider snapshot whose ``data`` is being projected.

    Returns:
        A new dict containing only keys present in :data:`SAFE_DATA_KEYS`.
    """
    data = snapshot.data if isinstance(snapshot.data, Mapping) else {}
    return {
        key: value
        for key, raw_value in data.items()
        if key in SAFE_DATA_KEYS and (value := _json_safe_value(raw_value)) is not _UNSAFE_JSON
    }


_UNSAFE_JSON = object()


def _json_safe_value(value: object) -> object:
    """Return a strictly JSON-safe value or a sentinel for unsafe input."""
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, float):
        return value if math.isfinite(value) else _UNSAFE_JSON
    if isinstance(value, list):
        values = [_json_safe_value(item) for item in value]
        return values if _UNSAFE_JSON not in values else _UNSAFE_JSON
    if isinstance(value, Mapping) and all(isinstance(key, str) for key in value):
        result = {key: _json_safe_value(item) for key, item in value.items()}
        return result if _UNSAFE_JSON not in result.values() else _UNSAFE_JSON
    return _UNSAFE_JSON


def _project_antigravity_claude_data(snapshot: ProviderSnapshot) -> dict:
    """Project the third-party (Claude) bucket into the synthetic entry's
    data, under the same key names project_data() uses for a primary
    entry's five_hour/weekly headroom (Task A.3).

    A DEDICATED projection, not a reuse of SAFE_DATA_KEYS/project_data():
    ``snapshot.data`` holds BOTH the Gemini and third-party buckets under
    the SAME ProviderSnapshot, so adding raw third_party_* key names to
    SAFE_DATA_KEYS would leak them into the PRIMARY "Antigravity" entry's
    data too (project_data(snapshot) is called on that exact same object
    for that entry). Mapping to the standard five_hour_percent_left/
    weekly_percent_left/*_reset names instead keeps the two entries' data
    namespaces independent, and — since those names are already in
    SAFE_DATA_KEYS — keeps _sanitize_prior_entry's
    ``set(data).issubset(SAFE_DATA_KEYS)`` check passing for CR-6 retention.
    """
    data = snapshot.data if isinstance(snapshot.data, Mapping) else {}
    field_map = {
        "third_party_five_hour_percent_left": "five_hour_percent_left",
        "third_party_weekly_percent_left": "weekly_percent_left",
        "third_party_five_hour_reset": "five_hour_reset",
        "third_party_weekly_reset": "weekly_reset",
    }
    return {
        out_key: value
        for raw_key, out_key in field_map.items()
        if raw_key in data and (value := _json_safe_value(data[raw_key])) is not _UNSAFE_JSON
    }


def CANONICAL_PROVIDERS() -> tuple[str, ...]:
    return _canonical_providers()


def _sanitize_prior_entry(
    name: str,
    entry: object,
    *,
    allowed_window_ids: frozenset[str],
    fallback_observed_at: str | None = None,
    allow_carried_failure: bool = False,
) -> dict | None:
    """Return a fresh, schema-valid retained entry or ``None``.

    Prior snapshots cross a persistence trust boundary. Retained entries must
    have exactly the canonical provider shape and are rebuilt rather than
    reused so unrecognized metadata and mutable caller-owned values cannot
    cross into the new snapshot.

    ``observed_at`` (P-BUG-1) is required going forward, but a prior written
    before this fix landed will have the old 5-key shape with no
    ``observed_at`` at all. That legacy shape is still accepted, falling back
    to ``fallback_observed_at`` (the prior payload's own top-level
    ``updated_at``) so the very first run after deploy doesn't drop
    carry-forward retention outright.
    """
    required_entry_keys = {"name", "ok", "error", "windows", "data", "observed_at"}
    legacy_entry_keys = required_entry_keys - {"observed_at"}
    if not isinstance(entry, dict):
        return None
    entry_keys = set(entry)
    if entry_keys == required_entry_keys:
        observed_at = entry.get("observed_at")
    elif entry_keys == legacy_entry_keys:
        observed_at = fallback_observed_at
    else:
        return None
    if not isinstance(observed_at, str) or _parse_aware_iso_timestamp(observed_at) is None:
        return None
    is_healthy_entry = entry["ok"] is True and entry["error"] is None
    is_carried_failure = (
        allow_carried_failure and entry["ok"] is False and isinstance(entry["error"], str)
    )
    if entry["name"] != name or not (is_healthy_entry or is_carried_failure):
        return None
    data = entry.get("data")
    windows = entry.get("windows")
    if (
        not isinstance(data, dict)
        or not set(data).issubset(SAFE_DATA_KEYS)
        or any(_json_safe_value(value) is _UNSAFE_JSON for value in data.values())
    ):
        return None
    if not isinstance(windows, list):
        return None
    required_keys = {"id", "percent_left", "reset_iso", "window_hours", "pace_delta"}
    sanitized_windows: list[dict] = []
    for window in windows:
        if not isinstance(window, dict) or set(window) != required_keys:
            return None
        window_id = window["id"]
        percent_left = window["percent_left"]
        reset_iso = window["reset_iso"]
        window_hours = window["window_hours"]
        pace = window["pace_delta"]
        if (
            not isinstance(window_id, str)
            or window_id not in allowed_window_ids
            or not percent_is_valid(percent_left)
            or (reset_iso is not None and not isinstance(reset_iso, str))
            or (
                window_hours is not None
                and (
                    not isinstance(window_hours, (int, float))
                    or isinstance(window_hours, bool)
                    or not math.isfinite(window_hours)
                    or window_hours <= 0
                )
            )
            or (
                pace is not None
                and (
                    not isinstance(pace, (int, float))
                    or isinstance(pace, bool)
                    or not math.isfinite(pace)
                )
            )
        ):
            return None
        sanitized_windows.append(
            {
                "id": window_id,
                "percent_left": percent_left,
                "reset_iso": reset_iso,
                "window_hours": window_hours,
                "pace_delta": pace,
            }
        )
    return {
        "name": name,
        "ok": True,
        "error": None,
        "windows": sanitized_windows,
        "data": {key: _json_safe_value(value) for key, value in data.items()},
        "observed_at": observed_at,
    }


def _parse_aware_iso_timestamp(value: object) -> datetime | None:
    """Return an aware ISO-8601 timestamp, or ``None`` for invalid input."""
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value)
        return parsed if parsed.tzinfo is not None and parsed.utcoffset() is not None else None
    except (TypeError, ValueError, OverflowError):
        return None


def _is_fresh_retained_entry(entry: Mapping[str, object], publish_time: datetime) -> bool:
    """Return whether a retained entry is fresh at the new publish time."""
    observed_at = _parse_aware_iso_timestamp(entry.get("observed_at"))
    if observed_at is None or publish_time.tzinfo is None or publish_time.utcoffset() is None:
        return False
    try:
        age = (publish_time - observed_at).total_seconds()
    except (TypeError, ValueError, OverflowError):
        return False
    return 0 <= age < STALE_THRESHOLD_SECONDS


def _failure_with_retained_values(retained_entry: Mapping[str, object], error: str | None) -> dict:
    """Return stale values without hiding the failure that caused them.

    ``_sanitize_prior_entry`` establishes that the retained values came from a
    healthy observation. A new failed probe must not inherit that entry's
    ``ok: true`` / ``error: null`` state, though: consumers need both the last
    known-good values and the provider-authored remedy for why they are stale.
    """
    return {
        **retained_entry,
        "ok": False,
        "error": error,
    }


def _build_snapshot_payload(
    snapshots: list[ProviderSnapshot],
    updated_at: datetime,
    *,
    prior: dict | None = None,
    schema_version: int,
    specs_by_provider: Mapping[str, tuple[WindowSpec, ...]],
    prior_auth_failures: int = 0,
) -> dict:
    """Build one versioned router-facing snapshot payload.

    Providers always appear in :func:`CANONICAL_PROVIDERS` order. Missing
    providers are emitted as disabled entries. For failed-but-transient probes
    a fresh prior entry may be retained to avoid flapping (CR-6).

    Args:
        snapshots: The freshly probed provider snapshots.
        updated_at: The instant this payload is being built.
        prior: A previously persisted payload dict, or None.

    Returns:
        A dict with ``schema_version``, ``updated_at`` (offset-aware ISO), and
        ``providers`` (a list of exactly seven entries — Codex, Claude,
        Antigravity, Copilot, Cursor, OpenCode Go, and Vibe; schema v2 adds
        an eighth, "Antigravity (Claude)", synthesized from the same
        Antigravity probe).
    """
    updated_at_iso = local_iso(updated_at)
    updated_at_aware = updated_at if updated_at.tzinfo else updated_at.astimezone()
    by_name = {
        (s.name.removesuffix(" [HTTP]") if hasattr(s.name, "removesuffix") else s.name): s
        for s in snapshots
    }

    prior_by_name: dict[str, dict] = {}
    prior_updated: datetime | None = None
    if isinstance(prior, Mapping) and prior.get("schema_version") == schema_version:
        try:
            prior_by_name = {p["name"]: p for p in prior.get("providers", [])}
        except Exception:  # noqa: BLE001 - malformed prior is best-effort
            prior_by_name = {}
        prior_updated = _parse_aware_iso_timestamp(prior.get("updated_at"))
    # Legacy-prior fallback (P-BUG-1): a prior written before this fix has no
    # per-entry observed_at. Falling back to the prior payload's own
    # top-level updated_at keeps carry-forward working on the first run
    # after deploy instead of silently dropping retention.
    fallback_observed_at = local_iso(prior_updated) if prior_updated is not None else None

    providers: list[dict] = []

    def _antigravity_claude_entry(snap: ProviderSnapshot | None) -> dict:
        """Synthesize the schema-v2 "Antigravity (Claude)" entry (Task A.1).

        Mirrors the primary Antigravity entry's shape from the SAME probe —
        no second lookup, no second fetch, no Keychain re-read. Its windows
        are built from the third-party (Claude) bucket's fields under the
        standard ``five_hour``/``weekly`` window IDs.
        """
        if snap is None:
            return {
                "name": "Antigravity (Claude)",
                "ok": False,
                "error": "provider not enabled",
                "windows": [],
                "data": {},
                "observed_at": None,
            }
        if snap.ok:
            return {
                "name": "Antigravity (Claude)",
                "ok": True,
                "error": None,
                "windows": _build_windows(
                    snap, updated_at, {"Antigravity": THIRD_PARTY_WINDOW_SPECS}
                ),
                "data": _project_antigravity_claude_data(snap),
                "observed_at": updated_at_iso,
            }
        # ok is False: default to a fresh failure entry, but carry a recent
        # healthy prior entry's values for transient errors (CR-6 anti-flap)
        # without losing the current failure — mirrors the primary Antigravity
        # entry's retention logic below. Now that
        # V2_WINDOW_SPECS["Antigravity (Claude)"] is registered (Task A.2),
        # specs_by_provider.get(...) resolves to THIRD_PARTY_WINDOW_SPECS
        # instead of an empty tuple, so retained entries validate correctly.
        entry: dict = {
            "name": "Antigravity (Claude)",
            "ok": False,
            "error": snap.error[:200] if snap.error else snap.error,
            "windows": [],
            "data": _project_antigravity_claude_data(snap),
            "observed_at": None,
        }
        auth_grace = is_antigravity_auth_failure(snap) and prior_auth_failures == 0
        if _is_transient_probe_error(snap) or _is_headless_deferred_probe(snap) or auth_grace:
            prior_entry = prior_by_name.get("Antigravity (Claude)")
            retained_entry = _sanitize_prior_entry(
                "Antigravity (Claude)",
                prior_entry,
                allowed_window_ids=frozenset(
                    spec.window_id for spec in specs_by_provider.get("Antigravity (Claude)", ())
                ),
                fallback_observed_at=fallback_observed_at,
                allow_carried_failure=not auth_grace,
            )
            if retained_entry is not None and _is_fresh_retained_entry(
                retained_entry, updated_at_aware
            ):
                entry = _failure_with_retained_values(
                    retained_entry,
                    ANTIGRAVITY_AUTH_RETRY_MESSAGE if auth_grace else entry["error"],
                )
            else:
                auth_grace = False
        if auth_grace and entry["error"] != ANTIGRAVITY_AUTH_RETRY_MESSAGE:
            # No prior values means the router must still expose the failed
            # state; only the user-facing wording is neutralized during grace.
            entry["error"] = ANTIGRAVITY_AUTH_RETRY_MESSAGE
        return entry

    for name in CANONICAL_PROVIDERS():
        snap = by_name.get(name)
        if snap is None:
            providers.append(
                {
                    "name": name,
                    "ok": False,
                    "error": "provider not enabled",
                    "windows": [],
                    "data": {},
                    "observed_at": None,
                }
            )
            if schema_version == SCHEMA_VERSION_V2 and name == "Antigravity":
                providers.append(_antigravity_claude_entry(snap))
            continue
        if snap.ok:
            providers.append(
                {
                    "name": name,
                    "ok": True,
                    "error": None,
                    "windows": _build_windows(snap, updated_at, specs_by_provider),
                    "data": project_data(snap),
                    "observed_at": updated_at_iso,
                }
            )
            if schema_version == SCHEMA_VERSION_V2 and name == "Antigravity":
                providers.append(_antigravity_claude_entry(snap))
            continue
        # ok is False: default to a fresh failure entry, but carry a recent
        # healthy prior entry's values for transient errors (CR-6 anti-flap)
        # without losing the current failure or its remedy.
        entry: dict = {
            "name": name,
            "ok": False,
            # error is copied verbatim into the router-facing snapshot, so it must
            # stay bounded and credential-free (INV-1). Cap defends every error path
            # (debug-augmented, generic-exception, provider-authored). Provider error
            # messages must never embed credentials/tokens.
            "error": snap.error[:200] if snap.error else snap.error,
            "windows": [],
            "data": project_data(snap),
            "observed_at": None,
        }
        auth_grace = is_antigravity_auth_failure(snap) and prior_auth_failures == 0
        if _is_transient_probe_error(snap) or _is_headless_deferred_probe(snap) or auth_grace:
            prior_entry = prior_by_name.get(name)
            retained_entry = _sanitize_prior_entry(
                name,
                prior_entry,
                allowed_window_ids=frozenset(
                    spec.window_id for spec in specs_by_provider.get(name, ())
                ),
                fallback_observed_at=fallback_observed_at,
                allow_carried_failure=not auth_grace,
            )
            if retained_entry is not None and _is_fresh_retained_entry(
                retained_entry, updated_at_aware
            ):
                entry = _failure_with_retained_values(
                    retained_entry,
                    ANTIGRAVITY_AUTH_RETRY_MESSAGE if auth_grace else entry["error"],
                )
            else:
                auth_grace = False
        if auth_grace and entry["error"] != ANTIGRAVITY_AUTH_RETRY_MESSAGE:
            entry["error"] = ANTIGRAVITY_AUTH_RETRY_MESSAGE
        providers.append(entry)
        if schema_version == SCHEMA_VERSION_V2 and name == "Antigravity":
            providers.append(_antigravity_claude_entry(snap))

    return {
        "schema_version": schema_version,
        "updated_at": updated_at_iso,
        "providers": providers,
    }


def build_snapshot_payload(
    snapshots: list[ProviderSnapshot],
    updated_at: datetime,
    *,
    prior: dict | None = None,
    prior_auth_failures: int = 0,
) -> dict:
    """Build the stable schema-v1 router snapshot payload."""
    return _build_snapshot_payload(
        snapshots,
        updated_at,
        prior=prior,
        schema_version=SCHEMA_VERSION,
        specs_by_provider=WINDOW_SPECS,
        prior_auth_failures=prior_auth_failures,
    )


def build_snapshot_v2_payload(
    snapshots: list[ProviderSnapshot],
    updated_at: datetime,
    *,
    prior: dict | None = None,
    prior_auth_failures: int = 0,
) -> dict:
    """Build the parallel schema-v2 router snapshot payload."""
    return _build_snapshot_payload(
        snapshots,
        updated_at,
        prior=prior,
        schema_version=SCHEMA_VERSION_V2,
        specs_by_provider=V2_WINDOW_SPECS,
        prior_auth_failures=prior_auth_failures,
    )


def write_snapshot(
    payload: dict,
    path: Path = SNAPSHOT_PATH,
    *,
    on_progress: Callable[[str], None] | None = None,
    lock_timeout: float | None = None,
    lock_poll_interval: float = 0.1,
) -> SnapshotWrite:
    """Atomically persist a payload to ``path``. Never raises.

    Writes to a unique temp file (safe under concurrent writers), fsyncs, then
    ``os.replace`` for atomicity. By default, lock acquisition remains blocking
    for compatibility with existing callers. Callers may provide a finite
    ``lock_timeout`` and progress callback for bounded, visible waits. On any
    failure the temp file is unlinked best-effort and False is returned. An
    incoming payload with a missing, malformed, or naive ``updated_at`` is
    rejected when the current snapshot has a valid timestamp; when no valid
    current timestamp exists, the candidate is allowed for first-write recovery.

    Args:
        payload: The JSON-serializable payload to persist.
        path: The destination path (defaults to :data:`SNAPSHOT_PATH`).
        on_progress: Optional callback receiving the safe message
            ``"waiting for snapshot lock"`` while a bounded lock wait retries.
        lock_timeout: Maximum seconds to wait for the per-snapshot lock. None
            preserves the original unbounded blocking behavior.
        lock_poll_interval: Maximum seconds between bounded lock attempts.

    Returns:
        :class:`SnapshotWrite` -- ``WRITTEN`` if this payload was committed,
        ``SKIPPED_STALE`` if a newer payload was already on disk and the write
        was correctly declined, ``FAILED`` on any error. Callers deciding
        whether to do follow-up work for *their* payload (history journaling,
        publishing) must check for ``WRITTEN`` specifically; ``SKIPPED_STALE``
        means another writer owns that payload and its follow-up work.
    """
    path = Path(path)
    tmp: str | None = None
    lock_path = path.with_name(f".{path.name}.lock")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(lock_path, "a+", encoding="utf-8") as lock:
            os.chmod(lock_path, 0o600)
            if not _acquire_snapshot_lock(
                lock,
                on_progress=on_progress,
                lock_timeout=lock_timeout,
                lock_poll_interval=lock_poll_interval,
            ):
                return SnapshotWrite.FAILED
            try:
                incoming_updated_at = _parse_aware_iso_timestamp(payload.get("updated_at"))
                current = read_prior_snapshot(path)
                current_updated_at = _parse_aware_iso_timestamp(
                    current.get("updated_at") if isinstance(current, Mapping) else None
                )
                if incoming_updated_at is None and current_updated_at is not None:
                    log.warning("refusing snapshot write with invalid updated_at to %s", path)
                    return SnapshotWrite.FAILED
                if (
                    incoming_updated_at is not None
                    and current_updated_at is not None
                    and current_updated_at > incoming_updated_at
                ):
                    log.info("skipping stale snapshot write to %s", path)
                    return SnapshotWrite.SKIPPED_STALE

                fd, tmp = tempfile.mkstemp(dir=path.parent, prefix="snapshot.", suffix=".tmp")
                with os.fdopen(fd, "w", encoding="utf-8") as f:
                    json.dump(payload, f, indent=2, allow_nan=False)
                    f.flush()
                    os.fsync(f.fileno())
                os.replace(tmp, path)
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        result = SnapshotWrite.WRITTEN
    except Exception:  # noqa: BLE001 - persistence must never crash the caller
        log.warning("failed to write snapshot to %s", path, exc_info=True)
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        return SnapshotWrite.FAILED

    if path == SNAPSHOT_V2_PATH:
        mirror_result = write_snapshot(payload, MAC_APP_SNAPSHOT_V2_PATH)
        if mirror_result is SnapshotWrite.FAILED:
            # The canonical router snapshot is already durable. Keep that
            # success result while logging a retryable Mac-consumer failure.
            log.warning("failed to mirror schema-v2 snapshot for GradusMac")

    return result


def _acquire_snapshot_lock(
    lock: object,
    *,
    on_progress: Callable[[str], None] | None,
    lock_timeout: float | None,
    lock_poll_interval: float,
) -> bool:
    """Acquire a snapshot lock, optionally with a bounded visible wait."""
    fileno = lock.fileno()  # type: ignore[union-attr]
    if lock_timeout is None:
        fcntl.flock(fileno, fcntl.LOCK_EX)
        return True

    deadline = time.monotonic() + max(0.0, lock_timeout)
    interval = max(0.0, lock_poll_interval)
    while True:
        try:
            fcntl.flock(fileno, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except OSError as exc:
            if exc.errno not in (errno.EACCES, errno.EAGAIN):
                raise
            if on_progress is not None:
                on_progress("waiting for snapshot lock")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            if interval:
                time.sleep(min(interval, remaining))


def read_prior_snapshot(path: Path = SNAPSHOT_PATH) -> dict | None:
    """Best-effort read of a previously persisted snapshot payload.

    Args:
        path: The path to read (defaults to :data:`SNAPSHOT_PATH`).

    Returns:
        The parsed payload dict, or None on any OS/parse error.
    """
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None
