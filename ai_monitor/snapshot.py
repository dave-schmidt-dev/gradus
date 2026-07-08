"""Router-facing capacity snapshot: normalization and atomic persistence.

This module is deliberately side-effect free apart from :func:`write_snapshot`.
It must NOT import :mod:`ai_monitor.providers` or :mod:`ai_monitor.ui` at
runtime to avoid the import cycle ``providers <- snapshot <- ui``. The only
provider type referenced is :class:`ProviderSnapshot`, imported under
``TYPE_CHECKING`` for annotations; all runtime access is duck-typed
(``.name`` / ``.ok`` / ``.data`` / ``.error``).
"""

from __future__ import annotations

import json
import logging
import os
import re
import tempfile
from dataclasses import dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import TYPE_CHECKING, Literal

if TYPE_CHECKING:  # pragma: no cover - typing only, never imported at runtime
    from .providers import ProviderSnapshot

log = logging.getLogger(__name__)

SCHEMA_VERSION = 1

# Contract-mandated, credential-free state directory (NOT `.cache/`).
SNAPSHOT_PATH = Path(__file__).resolve().parent.parent / ".state" / "snapshot.json"

# Stop serving cached data after this many seconds (moved from __main__.py).
STALE_THRESHOLD_SECONDS = 300  # 5 minutes


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


def parse_reset_target(reset_text: str | None, now: datetime) -> datetime | None:
    """Parse a human reset string into a concrete future ``datetime``.

    Faithful copy of ``ai_monitor.ui._parse_reset_target``. Handles relative
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
        return now + timedelta(
            days=int(relative.group("days") or 0),
            hours=int(relative.group("hours") or 0),
            minutes=int(relative.group("minutes") or 0),
        )

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
                if target < now:
                    target = target.replace(year=target_year + 1)
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
            if target < now:
                target = target.replace(year=target_year + 1)
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
}


def build_windows(snapshot: ProviderSnapshot, now: datetime) -> list[dict]:
    """Normalize a provider snapshot into router-facing window dicts (Gap-3).

    The whole body is wrapped in ``try/except`` so a single provider's bad data
    can never crash the payload; on any error an empty list is returned.

    Args:
        snapshot: The provider snapshot to normalize.
        now: The reference instant for pace/reset computation.

    Returns:
        A list of ``{"id", "percent_left", "reset_iso", "window_hours",
        "pace_delta"}`` dicts, or ``[]`` when the snapshot is unusable.
    """
    try:
        if not snapshot.ok or not snapshot.data:
            return []
        specs = WINDOW_SPECS.get(snapshot.name)
        if not specs:
            return []
        data = snapshot.data
        windows: list[dict] = []
        for spec in specs:
            if spec.kind == "session":
                raw = data.get(spec.percent_key)
                pct = float(raw) if isinstance(raw, (int, float)) else None
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
                    # INV-3: the SINGLE place Vibe usage is inverted to remaining.
                    pct = max(0.0, 100.0 - float(raw)) if isinstance(raw, (int, float)) else None
                else:
                    pct = float(raw) if isinstance(raw, (int, float)) else None
                start_raw = data.get(spec.start_key) if spec.start_key else None
                end_raw = data.get(spec.end_key) if spec.end_key else None
                start_iso = start_raw if isinstance(start_raw, str) else None
                end_iso = end_raw if isinstance(end_raw, str) else None
                if start_iso and end_iso:
                    start = datetime.fromisoformat(start_iso)  # may raise -> []
                    end = datetime.fromisoformat(end_iso)  # may raise -> []
                    start, end = reconcile(start, end)
                    total_seconds = (end - start).total_seconds()
                    window_hours = max(1.0, total_seconds) / 3600.0
                    reset_iso = end_iso
                    delta = pace_delta(pct, end, total_seconds, now)
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
        return windows
    except Exception:  # noqa: BLE001 - deliberate: one bad provider must not crash
        return []


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
        "credit_percent_left",
        "auto_percent_used",
        "api_percent_used",
        "remaining_cents",
        "limit_cents",
        "billing_cycle_start",
        "billing_cycle_end",
        "billing_cycle_end_iso",
    }
)


def project_data(snapshot: ProviderSnapshot) -> dict:
    """Project a snapshot's data down to the INV-1 safe allowlist.

    Args:
        snapshot: The provider snapshot whose ``data`` is being projected.

    Returns:
        A new dict containing only keys present in :data:`SAFE_DATA_KEYS`.
    """
    return {k: v for k, v in (snapshot.data or {}).items() if k in SAFE_DATA_KEYS}


CANONICAL_PROVIDERS = ("Codex", "Claude", "Antigravity", "Cursor", "Vibe")


def build_snapshot_payload(
    snapshots: list[ProviderSnapshot],
    updated_at: datetime,
    *,
    prior: dict | None = None,
) -> dict:
    """Build the full router-facing snapshot payload for all providers.

    Providers always appear in :data:`CANONICAL_PROVIDERS` order. Missing
    providers are emitted as disabled entries. For failed-but-transient probes
    a fresh prior entry may be retained to avoid flapping (CR-6).

    Args:
        snapshots: The freshly probed provider snapshots.
        updated_at: The instant this payload is being built.
        prior: A previously persisted payload dict, or None.

    Returns:
        A dict with ``schema_version``, ``updated_at`` (offset-aware ISO), and
        ``providers`` (a list of exactly five entries).
    """
    updated_at_iso = local_iso(updated_at)
    updated_at_aware = updated_at if updated_at.tzinfo else updated_at.astimezone()
    by_name = {s.name: s for s in snapshots}

    prior_by_name: dict[str, dict] = {}
    prior_updated: datetime | None = None
    if prior:
        try:
            prior_by_name = {p["name"]: p for p in prior.get("providers", [])}
        except Exception:  # noqa: BLE001 - malformed prior is best-effort
            prior_by_name = {}
        try:
            prior_updated = datetime.fromisoformat(prior["updated_at"])
        except Exception:  # noqa: BLE001 - malformed prior is best-effort
            prior_updated = None

    providers: list[dict] = []
    for name in CANONICAL_PROVIDERS:
        snap = by_name.get(name)
        if snap is None:
            providers.append(
                {
                    "name": name,
                    "ok": False,
                    "error": "provider not enabled",
                    "windows": [],
                    "data": {},
                }
            )
            continue
        if snap.ok:
            providers.append(
                {
                    "name": name,
                    "ok": True,
                    "error": None,
                    "windows": build_windows(snap, updated_at),
                    "data": project_data(snap),
                }
            )
            continue
        # ok is False: default to a fresh failure entry, but retain a recent
        # healthy prior entry for transient errors (CR-6 anti-flap).
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
        }
        if _is_transient_probe_error(snap):
            prior_entry = prior_by_name.get(name)
            if (
                prior_entry
                and prior_entry.get("ok")
                and prior_updated is not None
                and 0
                <= (updated_at_aware - prior_updated).total_seconds()
                < STALE_THRESHOLD_SECONDS
            ):
                entry = prior_entry
        providers.append(entry)

    return {
        "schema_version": SCHEMA_VERSION,
        "updated_at": updated_at_iso,
        "providers": providers,
    }


def write_snapshot(payload: dict, path: Path = SNAPSHOT_PATH) -> bool:
    """Atomically persist a payload to ``path``. Never raises.

    Writes to a unique temp file (safe under concurrent writers), fsyncs, then
    ``os.replace`` for atomicity. On any failure the temp file is unlinked
    best-effort and False is returned.

    Args:
        payload: The JSON-serializable payload to persist.
        path: The destination path (defaults to :data:`SNAPSHOT_PATH`).

    Returns:
        True on success, False on any error.
    """
    path = Path(path)
    tmp: str | None = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=path.parent, prefix="snapshot.", suffix=".tmp")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(payload, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        return True
    except Exception:  # noqa: BLE001 - persistence must never crash the caller
        log.warning("failed to write snapshot to %s", path, exc_info=True)
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        return False


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
