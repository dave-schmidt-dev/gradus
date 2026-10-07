"""Freshness gating for the ``--json`` reader surface.

``gradus --json`` renders whatever the launchd-owned producer last persisted.
That file can be hours or days old when the producer stops, and a provider's
usage cycle can end between refreshes. This module marks both cases
``ok: false`` so a router never treats stale or expired capacity as usable.
"""

from __future__ import annotations

from dataclasses import replace
from datetime import datetime

from .providers._base import ProviderSnapshot
from .snapshot import STALE_THRESHOLD_SECONDS, _parse_aware_iso_timestamp

_STALE_SOURCE = "snapshot (stale)"


def mark_unfresh(
    snapshots: list[ProviderSnapshot],
    updated_at: datetime,
    now: datetime,
) -> list[ProviderSnapshot]:
    """Return snapshots downgraded when their persisted values cannot be trusted.

    A snapshot older than ``STALE_THRESHOLD_SECONDS`` is stale: every provider
    is reported ``ok: false`` under the stale source, because the persisted
    values say nothing about current capacity. Otherwise an ``ok`` provider
    whose usage cycle already ended is reported ``ok: false`` while awaiting
    the next refresh. Input snapshots are never mutated.

    Args:
        snapshots: Persisted provider snapshots read from the v2 file.
        updated_at: Instant at which the v2 snapshot file was last written.
        now: Current instant used for both freshness checks.

    Returns:
        New snapshot objects; providers that need no change are returned
        as-is.
    """
    if _is_stale(updated_at, now):
        return [_mark_stale(snapshot, updated_at) for snapshot in snapshots]
    return [_mark_ended_cycle(snapshot, now) for snapshot in snapshots]


def _is_stale(updated_at: datetime, now: datetime) -> bool:
    """Return whether the snapshot is too old, or its age cannot be established."""
    try:
        age = (now - updated_at).total_seconds()
    except TypeError:
        # A naive timestamp cannot be compared with the aware clock; fail closed.
        return True
    return age >= STALE_THRESHOLD_SECONDS


def _mark_stale(snapshot: ProviderSnapshot, updated_at: datetime) -> ProviderSnapshot:
    """Return a copy of ``snapshot`` flagged as coming from a stale file."""
    if snapshot.ok:
        return replace(
            snapshot,
            ok=False,
            source=_STALE_SOURCE,
            error=f"snapshot stale: last updated {updated_at.isoformat()}",
        )
    return replace(snapshot, source=_STALE_SOURCE)


def _mark_ended_cycle(snapshot: ProviderSnapshot, now: datetime) -> ProviderSnapshot:
    """Return a copy of ``snapshot`` flagged when its usage cycle has ended."""
    if not snapshot.ok:
        return snapshot
    end_date = (snapshot.data or {}).get("end_date")
    end_instant = _parse_aware_iso_timestamp(end_date)
    if end_instant is None or end_instant > now:
        return snapshot
    return replace(
        snapshot,
        ok=False,
        error=f"usage cycle ended {end_date}; awaiting refresh",
    )
