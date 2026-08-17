"""Credential-free, bounded history for committed schema-v2 snapshots.

The history envelope is deliberately separate from the router snapshot schemas.
It accepts only an already projected schema-v2 payload and adds fixed safe
provenance plus reduced probe metadata.  Provider credentials and raw probe
payloads never cross this module's boundary.
"""

from __future__ import annotations

import fcntl
import json
import logging
import os
import re
import tempfile
from collections.abc import Iterable, Mapping
from contextlib import contextmanager
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from .providers._base import ProviderSnapshot
from .providers.antigravity import (
    HISTORY_CLAUDE_PROVENANCE,
)
from .providers.antigravity import (
    HISTORY_PROVENANCE as ANTIGRAVITY_PROVENANCE,
)
from .providers.opencode_go import HISTORY_PROVENANCE as OPENCODE_GO_PROVENANCE
from .snapshot import (
    _UNSAFE_JSON,
    SAFE_DATA_KEYS,
    SCHEMA_VERSION_V2,
    _is_headless_deferred_probe,
    _is_transient_probe_error,
    _json_safe_value,
)

log = logging.getLogger(__name__)

HISTORY_SCHEMA_VERSION = 1
HISTORY_DIR = Path(__file__).resolve().parent.parent / ".state" / "history"
HISTORY_LOCK_NAME = ".history.lock"
HISTORY_RETENTION_DAYS = 7

_PARTITION_RE = re.compile(r"^\d{4}-\d{2}-\d{2}\.jsonl$")
_ALLOWED_SNAPSHOT_KEYS = frozenset({"schema_version", "updated_at", "providers"})
_ALLOWED_ENTRY_KEYS = frozenset(
    {"name", "ok", "error", "windows", "data", "observed_at", "probe_attempted_at"}
)
_LEGACY_ENTRY_KEYS = _ALLOWED_ENTRY_KEYS - {"probe_attempted_at"}
_ALLOWED_WINDOW_KEYS = frozenset({"id", "percent_left", "reset_iso", "window_hours", "pace_delta"})
_PROBE_REASONS = frozenset(
    {
        "success",
        "headless_deferred",
        "transient_failure",
        "auth_failure",
        "not_enabled",
        "other_failure",
        "unknown",
    }
)
_CAPACITY_STATES = frozenset({"observed", "carried", "failed", "not_enabled", "invalid"})
_AUTH_MARKERS = (
    "auth",
    "credential",
    "login",
    "authenticate",
    "re-authenticate",
    "session expired",
    "sign in",
    "sign-in",
    "token expired",
)
_SENSITIVE_TEXT_MARKERS = (
    "authorization:",
    "bearer ",
    "access_token=",
    "refresh_token=",
    "cookie=",
    "workspace_id=",
    "account_email=",
)

_PROVENANCE_BY_PROVIDER: dict[str, dict[str, Any]] = {
    "Antigravity": ANTIGRAVITY_PROVENANCE,
    "Antigravity (Claude)": HISTORY_CLAUDE_PROVENANCE,
    # "Codex (Spark)" is intentionally absent: ANTIGRAVITY_PROVENANCE and
    # HISTORY_CLAUDE_PROVENANCE encode the Antigravity/Gemini HTTP probe's
    # own method/endpoint/bucket_family (Task 3.2 research: both entries
    # share HISTORY_ENDPOINT, a Gemini-specific URL). The primary "Codex"
    # entry has no descriptor here either and already falls through to the
    # ``{"provenance_available": False}`` default below, so the synthetic
    # Spark entry sourced from that same Codex probe correctly inherits the
    # same "no provenance" default rather than fabricating an endpoint.
    "OpenCode Go": OPENCODE_GO_PROVENANCE,
}


def recent_auth_failure_count(
    provider: str = "Antigravity",
    *,
    as_of: datetime | None = None,
    window_seconds: float = 600.0,
    history_dir: Path = HISTORY_DIR,
) -> int:
    """Count prior auth failures in the rolling credential-free window.

    The current probe is intentionally not an argument: callers count only
    records already committed to the journal, then decide how to project the
    current failure. This prevents a healthy/auth alternation from extending
    grace and keeps process restarts subject to the same observation bound.
    """
    if (
        not isinstance(window_seconds, (int, float))
        or isinstance(window_seconds, bool)
        or window_seconds < 0
    ):
        return 0
    current = _utc_now(as_of)
    cutoff = current - timedelta(seconds=float(window_seconds))
    # Only the partitions the window actually spans -- two at most for the
    # default 600s, and only when it straddles UTC midnight. Reading the whole
    # 7-day journal to answer a ten-minute question is what put seconds of
    # blocking JSON parsing on the dashboard's startup path.
    records, status = read_history_evidence(
        history_dir,
        since=cutoff.date(),
        until=current.date(),
    )
    if status not in {"ok", "empty"}:
        return 0
    count = 0
    for record in records:
        timestamp = _history_record_timestamp(record)
        if timestamp is None:
            continue
        timestamp = timestamp.astimezone(timezone.utc)
        if not cutoff < timestamp < current:
            continue
        observations = record.get("observations")
        observation = observations.get(provider) if isinstance(observations, Mapping) else None
        probe = observation.get("probe") if isinstance(observation, Mapping) else None
        if isinstance(probe, Mapping) and probe.get("reason") == "auth_failure":
            count += 1
    return count


def _parse_aware(value: object) -> datetime | None:
    """Parse an ISO timestamp only when it carries a usable offset."""
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (TypeError, ValueError, OverflowError):
        return None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        return None
    return parsed


def _utc_now(value: datetime | None) -> datetime:
    """Return an aware UTC clock value, rejecting naive injected clocks."""
    current = value if value is not None else datetime.now(timezone.utc)
    if current.tzinfo is None or current.utcoffset() is None:
        raise ValueError("history clock must be timezone-aware")
    return current.astimezone(timezone.utc)


def _json_clone(value: object) -> object:
    """Clone a JSON-safe value without permitting non-finite numbers."""
    return json.loads(
        json.dumps(
            value,
            ensure_ascii=True,
            allow_nan=False,
            separators=(",", ":"),
            sort_keys=True,
        )
    )


def _contains_sensitive_text(value: object) -> bool:
    if not isinstance(value, str):
        return False
    lower = value.lower()
    return any(marker in lower for marker in _SENSITIVE_TEXT_MARKERS)


def _valid_snapshot_payload(payload: object) -> dict[str, Any] | None:
    """Return a cloned schema-v2 payload, or ``None`` across the trust boundary."""
    if not isinstance(payload, Mapping):
        return None
    if set(payload) != _ALLOWED_SNAPSHOT_KEYS:
        return None
    if payload.get("schema_version") != SCHEMA_VERSION_V2:
        return None
    updated_at = payload.get("updated_at")
    if _parse_aware(updated_at) is None:
        return None
    providers = payload.get("providers")
    if not isinstance(providers, list):
        return None

    names: set[str] = set()
    for entry in providers:
        if not isinstance(entry, Mapping) or set(entry) not in (
            _ALLOWED_ENTRY_KEYS,
            _LEGACY_ENTRY_KEYS,
        ):
            return None
        name = entry.get("name")
        if not isinstance(name, str) or not name or name in names:
            return None
        names.add(name)
        if not isinstance(entry.get("ok"), bool):
            return None
        error = entry.get("error")
        if error is not None and (
            not isinstance(error, str) or len(error) > 200 or _contains_sensitive_text(error)
        ):
            return None
        windows = entry.get("windows")
        if not isinstance(windows, list):
            return None
        for window in windows:
            if not isinstance(window, Mapping) or not set(window).issubset(_ALLOWED_WINDOW_KEYS):
                return None
            if not isinstance(window.get("id"), str):
                return None
        data = entry.get("data")
        if not isinstance(data, Mapping) or not set(data).issubset(SAFE_DATA_KEYS):
            return None
        observed_at = entry.get("observed_at")
        if observed_at is not None and _parse_aware(observed_at) is None:
            return None
        probe_attempted_at = entry.get("probe_attempted_at")
        if probe_attempted_at is not None and _parse_aware(probe_attempted_at) is None:
            return None

    safe = _json_safe_value(payload)
    if safe is _UNSAFE_JSON or not isinstance(safe, dict):
        return None
    try:
        cloned = _json_clone(safe)
    except (TypeError, ValueError, OverflowError):
        return None
    return cloned if isinstance(cloned, dict) else None


def _normalize_provider_name(name: object) -> str:
    if isinstance(name, str) and hasattr(name, "removesuffix"):
        return name.removesuffix(" [HTTP]")
    return str(name)


def _probe_metadata(
    snapshot: ProviderSnapshot | None,
    entry: Mapping[str, Any],
) -> dict[str, Any]:
    """Reduce a current probe to a reason code and upstream-attempt flag."""
    if snapshot is None:
        reason = "not_enabled" if entry.get("error") == "provider not enabled" else "unknown"
        return {"attempted": False, "reason": reason}

    if _is_headless_deferred_probe(snapshot):
        return {"attempted": False, "reason": "headless_deferred"}

    if snapshot.ok:
        if "(cached)" in snapshot.source.lower() or snapshot.cached_since is not None:
            return {"attempted": True, "reason": "transient_failure"}
        return {"attempted": True, "reason": "success"}

    # A graced provider carries the raw probe classification in the internal
    # debug slot while exposing only the neutral consumer marker. The marker is
    # also accepted for restart/replay fixtures where that slot is unavailable.
    if snapshot.debug_detail == "auth_failure" or (
        snapshot.name == "Antigravity"
        and snapshot.error == "Antigravity refresh retrying; values may be stale"
    ):
        return {"attempted": False, "reason": "auth_failure"}
    error = (snapshot.error or "").lower()
    if error.strip() == "provider not enabled":
        return {"attempted": False, "reason": "not_enabled"}
    if any(marker in error for marker in _AUTH_MARKERS):
        return {"attempted": False, "reason": "auth_failure"}
    if _is_transient_probe_error(snapshot):
        return {"attempted": True, "reason": "transient_failure"}
    return {"attempted": False, "reason": "other_failure"}


def _capacity_metadata(
    entry: Mapping[str, Any], updated_at: datetime, *, synthetic: bool
) -> dict[str, Any]:
    """Classify capacity origin without letting a failed probe hide first."""
    result: dict[str, Any] = {"state": "invalid", "observed_at": None, "synthetic": synthetic}
    ok = entry.get("ok")
    if not isinstance(ok, bool):
        return result
    if not ok:
        result["state"] = (
            "not_enabled" if entry.get("error") == "provider not enabled" else "failed"
        )
        return result

    observed_text = entry.get("observed_at")
    observed_at = _parse_aware(observed_text)
    if observed_at is None:
        return result
    result["observed_at"] = observed_text
    if observed_at == updated_at:
        result["state"] = "observed"
    elif observed_at < updated_at:
        result["state"] = "carried"
    return result


def build_history_record(
    payload: Mapping[str, Any], snapshots: Iterable[ProviderSnapshot]
) -> dict[str, Any] | None:
    """Build one safe history record from a projected schema-v2 payload."""
    snapshot_payload = _valid_snapshot_payload(payload)
    if snapshot_payload is None:
        return None
    updated_at = _parse_aware(snapshot_payload.get("updated_at"))
    if updated_at is None:
        return None

    by_name = {_normalize_provider_name(snapshot.name): snapshot for snapshot in snapshots}
    provenance: dict[str, Any] = {}
    observations: dict[str, Any] = {}
    for entry in snapshot_payload["providers"]:
        name = entry["name"]
        descriptor = _PROVENANCE_BY_PROVIDER.get(name, {"provenance_available": False})
        provenance[name] = _json_clone(descriptor)
        source_name = {
            "Antigravity (Claude)": "Antigravity",
            "Codex (Spark)": "Codex",
        }.get(name, name)
        observations[name] = {
            "probe": _probe_metadata(by_name.get(source_name), entry),
            "capacity": _capacity_metadata(
                entry,
                updated_at,
                synthetic=name in {"Antigravity (Claude)", "Codex (Spark)"},
            ),
        }

    return {
        "history_schema_version": HISTORY_SCHEMA_VERSION,
        "snapshot": snapshot_payload,
        "provenance": provenance,
        "observations": observations,
    }


def _history_record_timestamp(record: Mapping[str, Any]) -> datetime | None:
    snapshot = record.get("snapshot")
    return _parse_aware(snapshot.get("updated_at")) if isinstance(snapshot, Mapping) else None


def _valid_history_record(record: object) -> dict[str, Any] | None:
    if (
        not isinstance(record, Mapping)
        or record.get("history_schema_version") != HISTORY_SCHEMA_VERSION
        or set(record) != {"history_schema_version", "snapshot", "provenance", "observations"}
    ):
        return None
    snapshot = _valid_snapshot_payload(record.get("snapshot"))
    if snapshot is None:
        return None
    provenance = record.get("provenance")
    observations = record.get("observations")
    if not isinstance(provenance, Mapping) or not isinstance(observations, Mapping):
        return None
    names = {entry["name"] for entry in snapshot["providers"]}
    if set(provenance) != names or set(observations) != names:
        return None
    for name in names:
        expected_provenance = _PROVENANCE_BY_PROVIDER.get(name, {"provenance_available": False})
        if provenance.get(name) != expected_provenance:
            return None
        observation = observations.get(name)
        if not isinstance(observation, Mapping) or set(observation) != {"probe", "capacity"}:
            return None
        probe = observation.get("probe")
        if (
            not isinstance(probe, Mapping)
            or set(probe) != {"attempted", "reason"}
            or not isinstance(probe.get("attempted"), bool)
            or probe.get("reason") not in _PROBE_REASONS
        ):
            return None
        capacity = observation.get("capacity")
        if (
            not isinstance(capacity, Mapping)
            or set(capacity) != {"state", "observed_at", "synthetic"}
            or capacity.get("state") not in _CAPACITY_STATES
            or not isinstance(capacity.get("synthetic"), bool)
        ):
            return None
        observed_at = capacity.get("observed_at")
        if observed_at is not None and _parse_aware(observed_at) is None:
            return None
    try:
        return _json_clone(record)  # type: ignore[return-value]
    except (TypeError, ValueError, OverflowError):
        return None


def _ensure_history_dir(history_dir: Path) -> None:
    if history_dir.is_symlink():
        raise OSError("history directory must not be a symlink")
    history_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    history_dir.chmod(0o700)


@contextmanager
def _history_lock(history_dir: Path, *, exclusive: bool) -> Iterable[None]:
    _ensure_history_dir(history_dir)
    lock_path = history_dir / HISTORY_LOCK_NAME
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(lock_path, flags, 0o600)
    lock_file = os.fdopen(fd, "a+", encoding="utf-8")
    try:
        os.fchmod(lock_file.fileno(), 0o600)
        fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
        try:
            yield
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
    finally:
        lock_file.close()


def _partition_paths(history_dir: Path) -> list[Path]:
    paths: list[Path] = []
    for path in history_dir.iterdir():
        if not _PARTITION_RE.fullmatch(path.name) or path.is_symlink() or not path.is_file():
            continue
        path.chmod(0o600)
        paths.append(path)
    return sorted(paths)


def _partition_date(path: Path) -> date | None:
    """The UTC date a partition's filename encodes.

    Every record reaches disk through :meth:`HistoryStore.append`, which files
    it by :func:`history_partition_path` -- so a partition named ``D.jsonl``
    holds records whose ``updated_at`` falls on UTC date ``D``. That invariant
    is what lets the readers below open only the partitions a date-bounded
    question can touch instead of parsing the whole 7-day journal.

    Returns:
        The parsed date, or None when the name matches ``_PARTITION_RE``'s
        shape but is not a real calendar date (``2026-13-45.jsonl``). Callers
        treat None as "cannot be date-scoped" and fall back to reading it.
    """
    try:
        return date.fromisoformat(path.stem)
    except ValueError:
        return None


def _read_partition(path: Path) -> tuple[list[dict[str, Any]], bool]:
    path.chmod(0o600)
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    records: list[dict[str, Any]] = []
    incomplete_tail = False
    for index, line in enumerate(lines):
        if not line.strip():
            continue
        try:
            raw = json.loads(line)
        except json.JSONDecodeError:
            if index == len(lines) - 1 and not line.endswith(("\n", "\r")):
                incomplete_tail = True
            continue
        record = _valid_history_record(raw)
        if record is not None:
            records.append(record)
    return records, incomplete_tail


def _read_partition_read_only(path: Path) -> tuple[list[dict[str, Any]], bool]:
    """Read one partition without chmod, locking, or any other mutation."""
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    records: list[dict[str, Any]] = []
    corrupt = False
    for index, line in enumerate(lines):
        if not line.strip():
            continue
        try:
            raw = json.loads(line)
        except json.JSONDecodeError:
            if index == len(lines) - 1 and not line.endswith(("\n", "\r")):
                continue
            corrupt = True
            continue
        record = _valid_history_record(raw)
        if record is None:
            corrupt = True
        else:
            records.append(record)
    return records, corrupt


def _all_records_locked(history_dir: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for path in _partition_paths(history_dir):
        partition_records, _ = _read_partition(path)
        records.extend(partition_records)
    return records


def _record_timestamps(records: Iterable[Mapping[str, Any]]) -> list[datetime]:
    return [
        timestamp
        for record in records
        if (timestamp := _history_record_timestamp(record)) is not None
    ]


def _latest_timestamp_locked(
    history_dir: Path,
    target: Path,
    target_records: list[dict[str, Any]],
) -> datetime | None:
    """The newest committed timestamp, without reading the whole journal.

    Partitions sort by the UTC date they are named for, so the newest record
    on disk lives in the newest non-empty partition (see :func:`_partition_date`).
    Walking back from the newest and stopping at the first partition holding a
    readable record answers the append path's monotonicity question exactly,
    while reading at most one partition the caller had not already read.

    ``target`` is considered alongside the newest partition rather than instead
    of it, so a backdated append is still rejected against the true maximum.

    Args:
        history_dir: The exclusively locked history directory.
        target: The partition the incoming record would be written to.
        target_records: Already-read contents of ``target``, reused as-is.

    Returns:
        The newest timestamp on disk, or None when nothing readable is stored.
    """
    stamps = _record_timestamps(target_records)
    for path in reversed(_partition_paths(history_dir)):
        if path == target:
            # Already represented by `target_records`. An empty target cannot
            # bound anything, so keep walking back to an older partition.
            if stamps:
                break
            continue
        partition_stamps = _record_timestamps(_read_partition(path)[0])
        if partition_stamps:
            stamps.extend(partition_stamps)
            break
    return max(stamps, default=None)


def _write_partition(path: Path, records: list[Mapping[str, Any]]) -> None:
    history_dir = path.parent
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=history_dir)
    temp_path = Path(temp_name)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            fd = -1
            for record in records:
                handle.write(
                    json.dumps(
                        record,
                        ensure_ascii=True,
                        allow_nan=False,
                        separators=(",", ":"),
                        sort_keys=True,
                    )
                )
                handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_path, path)
        path.chmod(0o600)
    finally:
        if fd >= 0:
            os.close(fd)
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass


def _prune_locked(history_dir: Path, now: datetime) -> None:
    cutoff = _utc_now(now) - timedelta(days=HISTORY_RETENTION_DAYS)
    for path in _partition_paths(history_dir):
        # Only the partition the cutoff lands in, and any older, can hold an
        # expired record (see `_partition_date`): a partition dated after the
        # cutoff's date starts at a midnight later than the cutoff itself, so
        # every record in it is retained and reading it can only ever be a
        # no-op rewrite. Skipping those is what keeps prune -- which runs on
        # every single append -- off the whole-journal read path.
        #
        # The tradeoff: a torn final line in a skipped partition is no longer
        # rewritten away on the next append, only once that partition ages past
        # the cutoff. Every reader already tolerates one -- `_read_partition`
        # drops an unparseable tail -- so this costs tidiness, not correctness.
        partition_date = _partition_date(path)
        if partition_date is not None and partition_date > cutoff.date():
            continue
        records, incomplete_tail = _read_partition(path)
        retained = [
            record
            for record in records
            if (timestamp := _history_record_timestamp(record)) is not None and timestamp >= cutoff
        ]
        if not retained:
            path.unlink()
        elif incomplete_tail or len(retained) != len(records):
            _write_partition(path, retained)


def history_partition_path(updated_at: datetime, history_dir: Path = HISTORY_DIR) -> Path:
    """Return the UTC date partition for an aware snapshot timestamp."""
    parsed = _utc_now(updated_at)
    return history_dir / f"{parsed.date().isoformat()}.jsonl"


class HistoryStore:
    """Private date-partitioned history store with monotonic append semantics."""

    def __init__(self, history_dir: Path = HISTORY_DIR) -> None:
        self.history_dir = Path(history_dir)

    def append(
        self,
        payload: Mapping[str, Any],
        snapshots: Iterable[ProviderSnapshot],
        *,
        committed_payload: Mapping[str, Any] | None = None,
        now: datetime | None = None,
    ) -> bool:
        """Append only when the candidate equals the committed v2 payload."""
        if committed_payload is not None and payload != committed_payload:
            return False
        record = build_history_record(payload, snapshots)
        if record is None:
            return False
        timestamp = _history_record_timestamp(record)
        if timestamp is None:
            return False
        try:
            retention_now = _utc_now(now)
        except ValueError:
            return False
        try:
            with _history_lock(self.history_dir, exclusive=True):
                # Read the target first so the monotonicity check can reuse it
                # rather than re-deriving the newest timestamp from the whole
                # journal. Appending to the newest partition is the common
                # case, and there the check then costs no extra read.
                target = history_partition_path(timestamp, self.history_dir)
                target_records: list[dict[str, Any]] = []
                if target.exists() and not target.is_symlink():
                    target_records, _ = _read_partition(target)

                latest_timestamp = _latest_timestamp_locked(
                    self.history_dir, target, target_records
                )
                if latest_timestamp is not None and timestamp <= latest_timestamp:
                    return False

                target_records.append(record)
                _write_partition(target, target_records)
                _prune_locked(self.history_dir, retention_now)
            return True
        except (OSError, TypeError, ValueError, json.JSONDecodeError):
            log.warning("history append failed")
            return False

    def records(self) -> list[dict[str, Any]]:
        """Read valid records while tolerating a crashed final JSONL line."""
        try:
            with _history_lock(self.history_dir, exclusive=False):
                records = _all_records_locked(self.history_dir)
        except (OSError, TypeError, ValueError, json.JSONDecodeError):
            return []
        return sorted(
            records,
            key=lambda record: (
                _history_record_timestamp(record) or datetime.min.replace(tzinfo=timezone.utc)
            ),
        )

    def prune(self, *, now: datetime | None = None) -> bool:
        """Apply the seven-day rolling boundary without appending a record."""
        try:
            with _history_lock(self.history_dir, exclusive=True):
                _prune_locked(self.history_dir, now or datetime.now(timezone.utc))
            return True
        except (OSError, TypeError, ValueError, json.JSONDecodeError):
            return False


def append_history_record(
    payload: Mapping[str, Any],
    snapshots: Iterable[ProviderSnapshot],
    *,
    committed_payload: Mapping[str, Any] | None = None,
    history_dir: Path = HISTORY_DIR,
    now: datetime | None = None,
) -> bool:
    """Functional wrapper used by the persistence integration."""
    return HistoryStore(history_dir).append(
        payload,
        snapshots,
        committed_payload=committed_payload,
        now=now,
    )


def read_history_records(history_dir: Path = HISTORY_DIR) -> list[dict[str, Any]]:
    """Functional read wrapper for future historical-query code."""
    return HistoryStore(history_dir).records()


def _partition_in_range(path: Path, since: date | None, until: date | None) -> bool:
    """Whether a partition's date can contribute to a ``[since, until]`` read."""
    partition_date = _partition_date(path)
    if partition_date is None:
        # Not a real calendar date, so it cannot be excluded on date grounds.
        # Read it rather than silently drop records a caller asked for.
        return True
    if since is not None and partition_date < since:
        return False
    return until is None or partition_date <= until


def read_history_evidence(
    history_dir: Path = HISTORY_DIR,
    *,
    since: date | None = None,
    until: date | None = None,
) -> tuple[list[dict[str, Any]], str]:
    """Read history without creating or changing any filesystem object.

    Returns ``(records, status)`` where status is one of ``missing``, ``empty``,
    ``ok``, or ``corrupt``.  An incomplete final JSONL line is intentionally
    tolerated and does not make an otherwise readable partition corrupt.

    Args:
        history_dir: The journal directory to read.
        since: When set, skip partitions dated before this UTC date.
        until: When set, skip partitions dated after this UTC date.

    Bounding the read scopes ``corrupt`` to the requested dates too, which is
    the honest answer for a bounded question: a caller asking about a
    ten-minute window is answered from the partitions that window touches
    rather than being zeroed by damage a week away from it. Left unset, the
    read covers the whole journal exactly as before.
    """
    history_dir = Path(history_dir)
    try:
        if history_dir.is_symlink() or not history_dir.is_dir():
            return [], "missing"
        paths = sorted(
            path
            for path in history_dir.iterdir()
            if _PARTITION_RE.fullmatch(path.name)
            and not path.is_symlink()
            and path.is_file()
            and _partition_in_range(path, since, until)
        )
        if not paths:
            return [], "empty"
        records: list[dict[str, Any]] = []
        corrupt = False
        for path in paths:
            partition_records, partition_corrupt = _read_partition_read_only(path)
            records.extend(partition_records)
            corrupt = corrupt or partition_corrupt
    except (OSError, UnicodeError, TypeError, ValueError, json.JSONDecodeError):
        return [], "corrupt"
    records.sort(
        key=lambda record: (
            _history_record_timestamp(record) or datetime.min.replace(tzinfo=timezone.utc)
        )
    )
    return records, "corrupt" if corrupt else "ok"


def _query_provider_result(record: Mapping[str, Any], name: str) -> dict[str, Any] | None:
    snapshot = record.get("snapshot")
    if not isinstance(snapshot, Mapping):
        return None
    entry = next(
        (
            candidate
            for candidate in snapshot.get("providers", [])
            if isinstance(candidate, Mapping) and candidate.get("name") == name
        ),
        None,
    )
    if not isinstance(entry, Mapping):
        return None
    observations = record.get("observations")
    observation = observations.get(name) if isinstance(observations, Mapping) else None
    if not isinstance(observation, Mapping):
        observation = {}
    probe = observation.get("probe")
    capacity = observation.get("capacity")
    if not isinstance(probe, Mapping):
        probe = {"attempted": False, "reason": "invalid"}
    if not isinstance(capacity, Mapping):
        capacity = {"state": "invalid", "observed_at": None, "synthetic": False}
    provenance = record.get("provenance")
    descriptor = provenance.get(name) if isinstance(provenance, Mapping) else None
    if not isinstance(descriptor, Mapping):
        descriptor = {"provenance_available": False}
    return {
        "name": name,
        "ok": entry.get("ok"),
        "error": entry.get("error"),
        "windows": entry.get("windows", []),
        "observed_at": entry.get("observed_at"),
        "capacity_origin": _json_clone(descriptor),
        "probe_attempted": probe.get("attempted") is True,
        "probe_reason": probe.get("reason", "invalid"),
        "synthetic": capacity.get("synthetic") is True,
        "capacity_state": capacity.get("state", "invalid"),
    }


def query_history(
    requested_at: Iterable[object],
    *,
    providers: Iterable[str] | None = None,
    max_gap: float | None = None,
    history_dir: Path = HISTORY_DIR,
) -> dict[str, Any]:
    """Return nearest-prior evidence for repeatable historical timestamps."""
    records, history_status = read_history_evidence(history_dir)
    provider_filter = list(dict.fromkeys(providers or []))
    if max_gap is not None and (max_gap < 0 or max_gap != max_gap):
        max_gap = None

    results: list[dict[str, Any]] = []
    for raw_requested in requested_at:
        requested = _parse_aware(raw_requested)
        base: dict[str, Any] = {
            "requested_at": raw_requested,
            "verified": False,
        }
        if requested is None:
            base["reason"] = "invalid_requested_timestamp"
            results.append(base)
            continue

        base["requested_at"] = requested.isoformat()
        prior = [
            record
            for record in records
            if (timestamp := _history_record_timestamp(record)) is not None
            and timestamp <= requested
        ]
        if not prior:
            base["reason"] = {
                "missing": "no_prior_record",
                "empty": "no_prior_record",
                "corrupt": "corrupt_history",
                "ok": "no_prior_record",
            }.get(history_status, "no_prior_record")
            results.append(base)
            continue

        record = max(prior, key=lambda candidate: _history_record_timestamp(candidate))
        snapshot = record["snapshot"]
        updated_at = _history_record_timestamp(record)
        assert updated_at is not None
        distance_seconds = (requested - updated_at).total_seconds()
        base.update(
            {
                "reason": "matched",
                "verified": history_status == "ok",
                "distance_seconds": distance_seconds,
                "updated_at": snapshot["updated_at"],
                "providers": {},
            }
        )
        selected_names = provider_filter or [
            entry["name"]
            for entry in snapshot.get("providers", [])
            if isinstance(entry, Mapping) and isinstance(entry.get("name"), str)
        ]
        missing_names: list[str] = []
        for name in selected_names:
            provider_result = _query_provider_result(record, name)
            if provider_result is None:
                missing_names.append(name)
            else:
                base["providers"][name] = provider_result
        if history_status == "corrupt":
            base["reason"] = "corrupt_history"
        elif missing_names:
            base["reason"] = "provider_not_found"
        elif max_gap is not None and distance_seconds > max_gap:
            base["reason"] = "max_gap_exceeded"
            base["verified"] = False
        else:
            base["verified"] = True
        if missing_names:
            base["missing_providers"] = missing_names
            base["verified"] = False
        results.append(base)

    return {
        "executor_auth_verified": False,
        "history_schema_version": HISTORY_SCHEMA_VERSION,
        "history_status": history_status,
        "results": results,
    }


__all__ = [
    "HISTORY_DIR",
    "HISTORY_LOCK_NAME",
    "HISTORY_RETENTION_DAYS",
    "HISTORY_SCHEMA_VERSION",
    "HistoryStore",
    "append_history_record",
    "build_history_record",
    "history_partition_path",
    "query_history",
    "recent_auth_failure_count",
    "read_history_evidence",
    "read_history_records",
]
