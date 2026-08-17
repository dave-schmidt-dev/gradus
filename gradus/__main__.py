"""CLI entrypoint for the AI usage monitor."""

from __future__ import annotations

import argparse
import errno
import fcntl
import inspect
import json
import logging
import math
import os
import select
import stat
import subprocess
import sys
import termios
import time
import tty
from collections.abc import Callable, Mapping
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, as_completed, wait
from contextlib import contextmanager
from dataclasses import replace
from datetime import datetime
from pathlib import Path

from rich.console import Console
from rich.live import Live

from .history import append_history_record, query_history, recent_auth_failure_count
from .providers import (
    ProviderSnapshot,
    fetch_provider_snapshot,
    set_headless,
)
from .providers._base import _PROVIDER_REGISTRY
from .snapshot import (
    ANTIGRAVITY_AUTH_RETRY_MESSAGE,
    CANONICAL_PROVIDERS,
    SNAPSHOT_PATH,
    SNAPSHOT_V2_PATH,
    STALE_THRESHOLD_SECONDS,
    SnapshotWrite,
    _is_transient_probe_error,
    _parse_aware_iso_timestamp,
    build_snapshot_payload,
    build_snapshot_v2_payload,
    is_antigravity_auth_failure,
    read_prior_snapshot,
    warning_membership,
    write_snapshot,
)
from .ui import (
    THEME,
    build_dashboard,
    build_loading_screen,
    render_json,
)

log = logging.getLogger(__name__)

AUTH_ACTIONS: dict[str, tuple[str, str]] = {
    "Claude": ("cli", "claude auth login"),
    # `codex login` is destructive: it wipes ~/.codex/auth.json at the start of the OAuth flow,
    # so an abandoned login (e.g. user dismisses the browser) leaves them fully logged out — even
    # if the previous token was healthy. Guard the [1] shortcut by surfacing the current auth.json
    # state and requiring an explicit Enter before clobbering. See HISTORY.md 2026-06-13.
    "Codex": (
        "cli",
        "ls -la ~/.codex/auth.json 2>&1; "
        "read -p '[Enter] runs codex login (overwrites token), [Ctrl-C] aborts: ' _; "
        "codex login",
    ),
    "Antigravity": ("cli", "agy"),
    "Copilot": ("cli", "gh auth login"),
    "Cursor": ("browser", "https://cursor.sh"),
    "Vibe": ("browser", "https://console.mistral.ai"),
    "OpenCode Go": ("browser", "https://opencode.ai"),
}

_AUTH_KEYWORDS = (
    "auth",
    "credentials",
    "login",
    "authenticate",
    "re-authenticate",
    "session expired",
    "sign in",
    "sign-in",
    "token expired",
)

# Claude's usage endpoint is materially more sensitive to polling than the
# other providers.  The launchd cadence remains 120s, but a Claude probe is
# allowed at most once per ten minutes.  This is producer policy, not a second
# cache: the previous attempt/success timestamps come from snapshot-v2.
CLAUDE_MIN_PROBE_INTERVAL_SECONDS = 600
# A real 429 means the endpoint's rolling allowance has not recovered yet.
# Back off for an hour instead of retrying every normal Claude interval.
CLAUDE_RATE_LIMIT_BACKOFF_SECONDS = 3600


class _CanonicalClaudeCooldown:
    """Return a bounded, fail-closed result without touching Claude."""

    def __init__(self, data: dict[str, object]) -> None:
        self._data = dict(data)

    def fetch(self) -> ProviderSnapshot:
        return ProviderSnapshot(
            name="Claude",
            ok=True,
            source="snapshot",
            data=self._data,
        )


def _canonical_entry(
    payload: Mapping[str, object] | None, name: str
) -> Mapping[str, object] | None:
    if not isinstance(payload, Mapping) or payload.get("schema_version") != 2:
        return None
    entries = payload.get("providers")
    if not isinstance(entries, list):
        return None
    return next(
        (entry for entry in entries if isinstance(entry, Mapping) and entry.get("name") == name),
        None,
    )


def _claude_probe_is_due(payload: Mapping[str, object] | None, now: datetime) -> bool:
    """Return whether the canonical Claude entry is old enough to probe."""
    entry = _canonical_entry(payload, "Claude")
    if entry is None:
        return True
    # This field is advanced only by a real probe.  A cooldown projection is
    # carried through the next payload unchanged, so the 120s producer tick
    # cannot defer Claude forever by moving the top-level snapshot timestamp.
    timestamp = entry.get("probe_attempted_at") or entry.get("observed_at")
    if entry.get("ok") is False and entry.get("error") and not timestamp:
        timestamp = payload.get("updated_at")  # legacy snapshots only
    parsed = _parse_aware_iso_timestamp(timestamp)
    if parsed is None:
        return True
    current = now if now.tzinfo is not None else now.astimezone()
    try:
        age = (current - parsed).total_seconds()
    except (TypeError, ValueError, OverflowError):
        return True
    error = entry.get("error")
    lower_error = error.lower() if isinstance(error, str) else ""
    interval = (
        CLAUDE_RATE_LIMIT_BACKOFF_SECONDS
        if "http 429" in lower_error or "rate limited" in lower_error or "rate-limit" in lower_error
        else CLAUDE_MIN_PROBE_INTERVAL_SECONDS
    )
    return age >= interval


def _canonical_snapshots(payload: object) -> tuple[list[ProviderSnapshot], datetime] | None:
    """Hydrate primary provider views from one validated v2 payload."""
    if not isinstance(payload, Mapping) or payload.get("schema_version") != 2:
        return None
    updated_at = _parse_aware_iso_timestamp(payload.get("updated_at"))
    entries = payload.get("providers")
    if updated_at is None or not isinstance(entries, list):
        return None
    by_name = {
        entry.get("name"): entry
        for entry in entries
        if isinstance(entry, Mapping) and isinstance(entry.get("name"), str)
    }
    snapshots: list[ProviderSnapshot] = []

    def carried_failure(entry: Mapping[str, object], data: Mapping[str, object]) -> bool:
        error = entry.get("error")
        observed_at = _parse_aware_iso_timestamp(entry.get("observed_at"))
        windows = entry.get("windows")
        if (
            not isinstance(error, str)
            or observed_at is None
            or not isinstance(windows, list)
            or not windows
            or any(not isinstance(window, Mapping) for window in windows)
        ):
            return False
        probe = ProviderSnapshot(
            name=str(entry.get("name", "")),
            ok=False,
            source="snapshot",
            data=dict(data),
            error=error,
        )
        return _is_transient_probe_error(probe)

    for name in CANONICAL_PROVIDERS():
        entry = by_name.get(name)
        if not isinstance(entry, Mapping):
            snapshots.append(
                ProviderSnapshot(
                    name=name, ok=False, source="snapshot", error="snapshot unavailable"
                )
            )
            continue
        data = entry.get("data")
        safe_data = dict(data) if isinstance(data, Mapping) else None
        ok = entry.get("ok") is True
        observed_at = _parse_aware_iso_timestamp(entry.get("observed_at"))
        if not ok and safe_data and carried_failure(entry, safe_data):
            # The persisted router entry deliberately remains ok:false.  The
            # TUI can still show its retained windows, marked offline, by
            # projecting the same sanitized data into its display model.
            snapshots.append(
                ProviderSnapshot(
                    name=name,
                    ok=True,
                    source="snapshot (cached)",
                    data=safe_data,
                    error=entry.get("error") if isinstance(entry.get("error"), str) else None,
                    cached_since=observed_at,
                )
            )
            continue
        snapshots.append(
            ProviderSnapshot(
                name=name,
                ok=ok,
                source="snapshot",
                data=safe_data,
                error=entry.get("error") if isinstance(entry.get("error"), str) else None,
            )
        )
    # Preserve the established TUI order. Canonical payload order is a schema
    # concern; display order historically came from the alphabetically sorted
    # probe results and should not change when the TUI becomes a pure reader.
    snapshots.sort(key=lambda item: item.name)
    return snapshots, updated_at


def _read_canonical_snapshots() -> tuple[list[ProviderSnapshot], datetime] | None:
    return _canonical_snapshots(read_prior_snapshot(SNAPSHOT_V2_PATH))


def _snapshot_signature() -> tuple[int, int] | None:
    """Return a cheap change token for the atomically replaced SOT file."""
    try:
        stat_result = SNAPSHOT_V2_PATH.stat()
    except OSError:
        return None
    return stat_result.st_mtime_ns, stat_result.st_size


def _canonical_or_refresh(
    cwd: str,
    enabled_providers: set[str] | None,
    debug: bool,
) -> tuple[list[ProviderSnapshot], datetime] | None:
    """Read the SOT, making one producer refresh when an interactive surface has none."""
    current = _read_canonical_snapshots()
    if current is not None:
        return current
    _refresh_snapshot_once(cwd, enabled_providers, debug)
    return _read_canonical_snapshots()


def _is_auth_error(snapshot: ProviderSnapshot) -> bool:
    """Return True if the snapshot is an auth error with a known fix action."""
    if snapshot.ok or not snapshot.error:
        return False
    if snapshot.name not in AUTH_ACTIONS:
        return False
    lower = snapshot.error.lower()
    return any(kw in lower for kw in _AUTH_KEYWORDS)


def _build_fix_actions(
    snapshots: list[ProviderSnapshot],
) -> dict[str, tuple[str, str, str]]:
    """Map number keys '1'-'9' to (provider_name, kind, target) for auth-errored providers."""
    auth_errored = sorted(s.name for s in snapshots if _is_auth_error(s))
    actions: dict[str, tuple[str, str, str]] = {}
    for i, name in enumerate(auth_errored[:9], start=1):
        kind, target = AUTH_ACTIONS[name]
        actions[str(i)] = (name, kind, target)
    return actions


_last_fix_launch: dict[str, float] = {}
_FIX_COOLDOWN = 5.0  # seconds


def _launch_fix(kind: str, target: str) -> None:
    """Open iTerm2, Safari, or the default browser to fix an auth error."""
    now = time.monotonic()
    key = f"{kind}:{target}"
    if now - _last_fix_launch.get(key, 0) < _FIX_COOLDOWN:
        return
    _last_fix_launch[key] = now
    if kind == "cli":
        subprocess.Popen(
            [
                "osascript",
                "-e",
                f'tell application "iTerm2" to create window with default profile command "{target}"',
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    elif kind == "safari":
        subprocess.Popen(
            ["open", "-a", "Safari", target],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    elif kind == "browser":
        subprocess.Popen(
            ["open", target],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Monitor Codex, Claude, Antigravity, Copilot, Cursor, and Vibe usage in real time."
    )
    parser.add_argument("--interval", type=int, default=120, help="Refresh interval in seconds.")
    parser.add_argument(
        "--duration",
        type=float,
        default=360.0,
        help="Health-verification duration in seconds (used with --verify-refresh-health).",
    )
    parser.add_argument(
        "--health-interval",
        type=float,
        default=120.0,
        help="Health-verification poll interval in seconds (used with --verify-refresh-health).",
    )
    parser.add_argument("--once", action="store_true", help="Fetch one snapshot and exit.")
    parser.add_argument(
        "--json",
        action="store_true",
        help=(
            "Print JSON instead of the live dashboard. Read-only/machine-safe: "
            "no browser, token refresh, cache writes, or notifications; uncached "
            "providers report 'auth required'."
        ),
    )
    parser.add_argument(
        "--debug", action="store_true", help="Show full exception strings from probes."
    )
    parser.add_argument(
        "--providers",
        type=str,
        default=None,
        help="Comma-separated list of providers to enable (e.g. Claude,Codex,Antigravity).",
    )
    parser.add_argument(
        "--refresh-snapshot",
        action="store_true",
        dest="refresh_snapshot",
        help=(
            "Refresh credential-aware router snapshots once and exit; this command may "
            "access authenticated provider sessions."
        ),
    )
    parser.add_argument(
        "--verify-refresh-health",
        action="store_true",
        dest="verify_refresh_health",
        help=(
            "Read-only verify that refresh snapshots are fresh and advancing, then exit; "
            "never initializes providers."
        ),
    )
    parser.add_argument(
        "--history-at",
        action="append",
        dest="history_at",
        metavar="AWARE-ISO",
        help="Read the nearest prior credential-free history record; repeatable.",
    )
    parser.add_argument(
        "--history-provider",
        action="append",
        dest="history_provider",
        metavar="NAME",
        help="Limit historical output to this provider; repeatable.",
    )
    parser.add_argument(
        "--history-max-gap",
        type=float,
        default=None,
        metavar="SECONDS",
        help="Mark historical evidence unverified when its match is farther away.",
    )
    args = parser.parse_args()
    if args.refresh_snapshot and (args.once or args.json):
        parser.error("argument --refresh-snapshot: not allowed with --once or --json")
    if args.verify_refresh_health:
        conflicts = [
            flag
            for flag, enabled in (
                ("--once", args.once),
                ("--json", args.json),
                ("--refresh-snapshot", args.refresh_snapshot),
            )
            if enabled
        ]
        if conflicts:
            parser.error(
                "argument --verify-refresh-health: not allowed with " + ", ".join(conflicts)
            )
        if args.duration <= 0:
            parser.error("argument --duration: must be greater than zero")
        if args.health_interval <= 0:
            parser.error("argument --health-interval: must be greater than zero")
    if args.history_provider and not args.history_at:
        parser.error("argument --history-provider requires --history-at")
    if args.history_max_gap is not None and not args.history_at:
        parser.error("argument --history-max-gap requires --history-at")
    if args.history_at:
        conflicts = [
            flag
            for flag, enabled in (
                ("--once", args.once),
                ("--json", args.json),
                ("--refresh-snapshot", args.refresh_snapshot),
                ("--verify-refresh-health", args.verify_refresh_health),
            )
            if enabled
        ]
        if conflicts:
            parser.error("argument --history-at: not allowed with " + ", ".join(conflicts))
        if args.history_max_gap is not None and (
            not math.isfinite(args.history_max_gap) or args.history_max_gap < 0
        ):
            parser.error("argument --history-max-gap: must be a finite non-negative number")
    return args


def _load_config() -> dict[str, object]:
    """Load .gradus.json or .ai_monitor.json from CWD if it exists."""
    config_path = Path(os.getcwd()) / ".gradus.json"
    if not config_path.exists():
        config_path = Path(os.getcwd()) / ".ai_monitor.json"
    if not config_path.exists():
        return {}
    try:
        payload = json.loads(config_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}
    return payload if isinstance(payload, dict) else {}


def initialize_providers(
    cwd: str, enabled: set[str] | None = None
) -> tuple[list[tuple[str, object]], list[object]]:
    providers: list[tuple[str, object]] = []
    cleanup: list[object] = []

    for name, provider_cls in _PROVIDER_REGISTRY.items():
        if enabled is not None and name not in enabled:
            continue
        try:
            sig = inspect.signature(provider_cls.__init__)
            if "cwd" in sig.parameters:
                instance = provider_cls(cwd=cwd)
            elif "project_root" in sig.parameters:
                instance = provider_cls(project_root=cwd)
            else:
                instance = provider_cls()
            providers.append((name, instance))
            cleanup.append(instance)
        except Exception as exc:  # noqa: BLE001
            providers.append((name, exc))

    return providers, cleanup


def collect_snapshots(
    providers: list[tuple[str, object]],
    debug: bool,
    *,
    on_start: Callable[[str], None] | None = None,
    on_complete: Callable[[ProviderSnapshot], None] | None = None,
    on_waiting: Callable[[int], None] | None = None,
    safe_errors: bool = False,
) -> list[ProviderSnapshot]:
    snapshots: list[ProviderSnapshot] = []
    workers: list[tuple[str, object]] = [
        (name, provider) for name, provider in providers if hasattr(provider, "fetch")
    ]
    static_errors = [
        (name, provider) for name, provider in providers if not hasattr(provider, "fetch")
    ]

    for name, error in static_errors:
        snapshot = ProviderSnapshot(
            name=name,
            ok=False,
            source="api",
            error="provider initialization failed" if safe_errors else str(error),
        )
        if safe_errors:
            log.warning("provider initialization failed")
        snapshots.append(snapshot)
        if on_complete is not None:
            on_complete(snapshot)

    executor = ThreadPoolExecutor(max_workers=max(1, len(workers)))
    try:

        def fetch_one(name: str, provider: object) -> ProviderSnapshot:
            if isinstance(provider, _CanonicalClaudeCooldown):
                return provider.fetch()
            return fetch_provider_snapshot(name, provider, debug)

        future_map = {}
        for name, provider in workers:
            if on_start is not None:
                on_start(name)
            future_map[executor.submit(fetch_one, name, provider)] = name

        def consume(future: object) -> None:
            """Consume one completed future without exposing provider errors."""
            name = future_map[future]
            try:
                snapshot = future.result()  # type: ignore[union-attr]
            except Exception:  # noqa: BLE001 - never leak provider exception text
                if not safe_errors:
                    raise
                log.warning("provider fetch failed")
                snapshot = ProviderSnapshot(
                    name=name,
                    ok=False,
                    source="api",
                    error="provider fetch failed",
                )
            snapshots.append(snapshot)
            if on_complete is not None:
                on_complete(snapshot)

        if on_waiting is None:
            for future in as_completed(future_map):
                consume(future)
        else:
            pending = set(future_map)
            while pending:
                completed, pending = wait(
                    pending,
                    timeout=0.25,
                    return_when=FIRST_COMPLETED,
                )
                if not completed:
                    on_waiting(len(pending))
                    continue
                for future in completed:
                    consume(future)
    finally:
        # Every submitted provider must be quiescent before callers can close
        # providers or release a refresh lock.
        executor.shutdown(wait=True, cancel_futures=True)

    snapshots.sort(key=lambda item: item.name)
    return snapshots


def _committed_is_newer(committed: object, payload: Mapping[str, object]) -> bool:
    """Whether ``committed`` carries a strictly newer ``updated_at`` than ``payload``.

    Used to tell a lost write-race (benign: another writer put a fresher
    snapshot on disk and owns its history entry) apart from a readback that is
    simply wrong (not benign: nothing journals that cycle). Anything that does
    not parse cleanly as a newer timestamp is treated as not-newer, so an
    unreadable readback fails loudly rather than silently.
    """
    if not isinstance(committed, Mapping):
        return False
    committed_at = _parse_aware_iso_timestamp(committed.get("updated_at"))
    payload_at = _parse_aware_iso_timestamp(payload.get("updated_at"))
    if committed_at is None or payload_at is None:
        return False
    return committed_at > payload_at


def _write_status(result: SnapshotWrite) -> str:
    """Render a write outcome for the INV-1 progress channel.

    A stale skip gets its own wording: "persisted" would claim this payload is
    on disk when a newer one is, and "persistence failed" would report a
    correct no-op as an error.
    """
    if result is SnapshotWrite.WRITTEN:
        return "persisted"
    if result is SnapshotWrite.SKIPPED_STALE:
        return "superseded by newer snapshot"
    return "persistence failed"


def _write_snapshot_versions(
    snaps: list[ProviderSnapshot],
    when: datetime,
    *,
    on_status: Callable[[str], None] | None = None,
    lock_timeout: float | None = None,
    lock_poll_interval: float = 0.1,
    journal_history: bool = False,
) -> tuple[bool, bool] | tuple[bool, bool, bool]:
    """Write v1 and v2 independently, optionally journaling committed v2.

    Each returned flag means "this destination is healthy", which is true both
    when this call committed the payload and when it correctly declined to
    because a concurrent writer had already put a *newer* one there. Gradus
    runs two writers on overlapping 120s cycles (the TUI and the launchd
    ``local.gradus-snapshot`` job), so one of them loses the race every cycle;
    losing is a correct no-op, not a failure, and must not be reported as one.
    Only :attr:`SnapshotWrite.FAILED` -- a lock, serialization, or IO error --
    is a failure.

    History is journaled only for a payload this call actually wrote. When the
    v2 write is skipped as stale, the writer that won owns that payload's
    journal entry and appending here would duplicate it.
    """

    def status(message: str) -> None:
        if on_status is not None:
            on_status(message)

    def writer_progress(schema: str) -> Callable[[str], None] | None:
        if on_status is None:
            return None

        def progress(message: str) -> None:
            status(f"{schema} {message}")

        return progress

    history_now = when if when.tzinfo is not None else when.astimezone()
    try:
        prior_auth_failures = recent_auth_failure_count(
            "Antigravity",
            as_of=history_now,
            window_seconds=600,
            history_dir=Path(SNAPSHOT_V2_PATH).resolve().parent / "history",
        )
    except (OSError, TypeError, ValueError):
        prior_auth_failures = 0

    try:
        v1_result = write_snapshot(
            build_snapshot_payload(
                snaps,
                when,
                prior=read_prior_snapshot(SNAPSHOT_PATH),
                prior_auth_failures=prior_auth_failures,
            ),
            # Passed explicitly. `write_snapshot`'s default binds `snapshot.py`'s
            # module-level SNAPSHOT_PATH at import, so omitting it made the read
            # above honor a patched `__main__.SNAPSHOT_PATH` while this write
            # ignored it -- a caller that believed it was redirected to a temp
            # dir would silently write the real one. v2 already passes its path.
            SNAPSHOT_PATH,
            on_progress=writer_progress("schema-v1"),
            lock_timeout=lock_timeout,
            lock_poll_interval=lock_poll_interval,
        )
    except Exception:  # noqa: BLE001 - persistence must not crash the dashboard
        log.warning("failed to write schema-v1 snapshot")
        v1_result = SnapshotWrite.FAILED
    v1_ok = v1_result.persisted
    status(f"schema-v1 {_write_status(v1_result)}")

    v2_payload: dict | None = None
    try:
        v2_payload = build_snapshot_v2_payload(
            snaps,
            when,
            prior=read_prior_snapshot(SNAPSHOT_V2_PATH),
            prior_auth_failures=prior_auth_failures,
        )
        v2_result = write_snapshot(
            v2_payload,
            SNAPSHOT_V2_PATH,
            on_progress=writer_progress("schema-v2"),
            lock_timeout=lock_timeout,
            lock_poll_interval=lock_poll_interval,
        )
    except Exception:  # noqa: BLE001 - persistence must not crash the dashboard
        log.warning("failed to write schema-v2 snapshot")
        v2_result = SnapshotWrite.FAILED
    v2_ok = v2_result.persisted
    status(f"schema-v2 {_write_status(v2_result)}")

    if not journal_history:
        return v1_ok, v2_ok

    if v2_result is SnapshotWrite.SKIPPED_STALE:
        # A concurrent writer committed a newer payload; it journals that one.
        # Appending ours here would either duplicate its record or write a
        # superseded one, so deferring is the correct outcome -- report it as
        # healthy rather than as a lost history entry.
        log.info("deferring history append: newer snapshot already committed by another writer")
        status("history deferred to concurrent writer")
        return v1_ok, v2_ok, True

    history_ok = False
    if v2_result is SnapshotWrite.WRITTEN and v2_payload is not None:
        committed_v2 = read_prior_snapshot(SNAPSHOT_V2_PATH)
        if committed_v2 == v2_payload:
            try:
                history_ok = append_history_record(
                    v2_payload,
                    snaps,
                    committed_payload=committed_v2,
                    history_dir=Path(SNAPSHOT_V2_PATH).resolve().parent / "history",
                )
            except Exception:  # noqa: BLE001 - history must not crash persistence callers
                log.warning("failed to append snapshot history")
        elif _committed_is_newer(committed_v2, v2_payload):
            # We committed, then a concurrent writer replaced the file with a
            # newer payload before this read. That writer journals its own.
            log.info("deferring history append: snapshot superseded after write")
            status("history deferred to concurrent writer")
            return v1_ok, v2_ok, True
        else:
            # The readback is neither our payload nor a newer one, so the write
            # did not take effect the way it was reported. Nobody journals this
            # cycle -- that is a real failure and must not be filed under the
            # benign concurrent-writer case above.
            log.warning(
                "history append skipped: committed snapshot is neither the payload "
                "just written nor a newer one"
            )
    status(f"history {'persisted' if history_ok else 'persistence failed'}")
    return v1_ok, v2_ok, history_ok


_REFRESH_LOCK_NAME = ".refresh-snapshot.lock"
_REFRESH_SNAPSHOT_LOCK_TIMEOUT_SECONDS = 2.0
_REFRESH_SNAPSHOT_LOCK_POLL_INTERVAL_SECONDS = 0.1


def _snapshot_state_dir() -> Path:
    """Return the resolved state directory for the production snapshot path."""
    return Path(SNAPSHOT_PATH).resolve().parent


def _acquire_refresh_snapshot_lock(
    state_dir: str | os.PathLike[str],
) -> tuple[int | None, bool]:
    """Acquire the refresh lock, returning ``(fd, already_owned)``."""
    state_fd: int | None = None
    fd: int | None = None
    try:
        try:
            os.mkdir(state_dir, 0o700)
        except FileExistsError:
            pass
        directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        directory_flags |= getattr(os, "O_NOFOLLOW", 0)
        state_fd = os.open(state_dir, directory_flags)
        if not stat.S_ISDIR(os.fstat(state_fd).st_mode):
            return None, False
        os.fchmod(state_fd, 0o700)
        lock_flags = os.O_RDWR | os.O_CREAT | os.O_NONBLOCK
        lock_flags |= getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(_REFRESH_LOCK_NAME, lock_flags, 0o600, dir_fd=state_fd)
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            os.close(fd)
            fd = None
            return None, False
        os.fchmod(fd, 0o600)
    except OSError:
        if fd is not None:
            os.close(fd)
            fd = None
        return None, False
    finally:
        if state_fd is not None:
            try:
                os.close(state_fd)
            except OSError:
                pass

    if fd is None:
        return None, False

    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        already_owned = exc.errno in (errno.EACCES, errno.EAGAIN)
        os.close(fd)
        return None, already_owned
    return fd, False


def _release_refresh_snapshot_lock(fd: int) -> None:
    """Release and close a refresh lock descriptor."""
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


def _refresh_progress(message: str) -> None:
    """Emit one credential-free refresh status line."""
    print(f"refresh: {message}", file=sys.stderr, flush=True)


def _refresh_snapshot_once(
    cwd: str,
    enabled_providers: set[str] | None,
    debug: bool,
    *,
    lock_timeout: float | None = None,
    lock_poll_interval: float | None = None,
) -> int:
    """Run one explicit credential-aware, single-flight snapshot refresh."""
    lock_fd, already_owned = _acquire_refresh_snapshot_lock(_snapshot_state_dir())
    if already_owned:
        _refresh_progress("already in progress")
        return 0
    if lock_fd is None:
        _refresh_progress("lock unavailable")
        return 1

    cleanup: list[object] = []
    try:
        _refresh_progress("started")
        # This explicit mode is the only command path allowed to retain the
        # credential-aware provider/session behavior.
        set_headless(False)
        prior_payload = read_prior_snapshot(SNAPSHOT_V2_PATH)
        providers, cleanup = initialize_providers(cwd, enabled_providers)
        # launchd owns the producer cadence.  Claude additionally gets a
        # provider-specific backoff derived from the canonical snapshot, so a
        # 120s tick never replays a just-rate-limited OAuth request.  The
        # synthetic result is still fed through the normal snapshot builder,
        # which preserves sanitized windows and keeps ok=false for routing.
        probe_time = datetime.now().astimezone()
        if not _claude_probe_is_due(prior_payload, probe_time):
            claude_entry = _canonical_entry(prior_payload, "Claude")
            claude_data = claude_entry.get("data") if isinstance(claude_entry, Mapping) else {}
            if not isinstance(claude_data, Mapping):
                claude_data = {}
            providers = [(name, provider) for name, provider in providers if name != "Claude"]
            providers.append(("Claude", _CanonicalClaudeCooldown(dict(claude_data))))

        def provider_complete(snapshot: ProviderSnapshot) -> None:
            # Provider names come from the fixed registry. Do not echo arbitrary
            # provider/error data to the status surface.
            name = snapshot.name if snapshot.name in _PROVIDER_REGISTRY else "provider"
            if snapshot.error == "provider initialization failed":
                _refresh_progress(f"provider {name} initialization failed")
            else:
                _refresh_progress(f"provider {name} complete")

        def provider_start(name: str) -> None:
            safe_name = name if name in _PROVIDER_REGISTRY else "provider"
            _refresh_progress(f"provider {safe_name} started")

        snapshots = collect_snapshots(
            providers,
            debug,
            on_start=provider_start,
            on_complete=provider_complete,
            on_waiting=lambda pending: _refresh_progress(f"waiting for {pending} provider(s)"),
            safe_errors=True,
        )
        v1_ok, v2_ok, history_ok = _write_snapshot_versions(
            snapshots,
            datetime.now(),
            on_status=_refresh_progress,
            lock_timeout=(
                _REFRESH_SNAPSHOT_LOCK_TIMEOUT_SECONDS if lock_timeout is None else lock_timeout
            ),
            lock_poll_interval=(
                _REFRESH_SNAPSHOT_LOCK_POLL_INTERVAL_SECONDS
                if lock_poll_interval is None
                else lock_poll_interval
            ),
            journal_history=True,
        )
        success = v1_ok and v2_ok and history_ok
        _refresh_progress("completed" if success else "failed")
        return 0 if success else 1
    except Exception:  # noqa: BLE001 - the CLI emits only a safe terminal status
        log.warning("credential-aware snapshot refresh failed")
        _refresh_progress("failed")
        return 1
    finally:
        for provider in cleanup:
            try:
                provider.close()
            except Exception:  # noqa: BLE001 - always release the single-flight lock
                log.warning("provider cleanup failed")
        _release_refresh_snapshot_lock(lock_fd)


_HEALTH_REQUIRED_PROVIDERS = ("Antigravity", "Antigravity (Claude)")


def _read_health_snapshot() -> object:
    """Read the v2 snapshot for health verification without exposing errors."""
    try:
        with SNAPSHOT_V2_PATH.open(encoding="utf-8") as snapshot_file:
            return json.load(snapshot_file)
    except (OSError, ValueError):
        return None


def _parse_health_timestamp(value: object) -> datetime | None:
    """Parse one aware ISO timestamp, rejecting naive or malformed values."""
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        return None
    return parsed


def _health_sample_reason(
    payload: object,
    previous_updated_at: datetime | None,
    now: datetime,
) -> tuple[datetime | None, str]:
    """Return a safe reason for one health sample and its parsed timestamp."""
    if not isinstance(payload, Mapping):
        return None, "unavailable"
    if payload.get("schema_version") != 2:
        return None, "invalid schema"

    updated_at = _parse_health_timestamp(payload.get("updated_at"))
    if updated_at is None:
        return None, "invalid timestamp"
    if previous_updated_at is not None:
        if updated_at == previous_updated_at:
            return updated_at, "unchanged"
        if updated_at < previous_updated_at:
            return updated_at, "non-increasing timestamp"

    current_time = now if now.tzinfo is not None else now.astimezone()
    if updated_at > current_time:
        return updated_at, "future timestamp"

    entries = payload.get("providers")
    if not isinstance(entries, list):
        return updated_at, "missing providers"
    by_name = {
        entry.get("name"): entry
        for entry in entries
        if isinstance(entry, Mapping) and isinstance(entry.get("name"), str)
    }
    selected = [by_name.get(name) for name in _HEALTH_REQUIRED_PROVIDERS]
    if any(not isinstance(entry, Mapping) for entry in selected):
        return updated_at, "missing required provider"

    for entry in selected:
        assert isinstance(entry, Mapping)
        if entry.get("ok") is not True:
            if (
                entry.get("name") == "Antigravity"
                and entry.get("error") == ANTIGRAVITY_AUTH_RETRY_MESSAGE
            ):
                observed_at = _parse_health_timestamp(entry.get("observed_at"))
                if observed_at is not None and observed_at <= updated_at:
                    return updated_at, "carried-auth"
            # Names come from the fixed required-provider set rather than the
            # provider's error text: this line is written to a non-private
            # launchd log and must remain diagnostic without leaking details.
            name = entry.get("name")
            assert isinstance(name, str)
            return updated_at, f"provider {name} not healthy"
        observed_at = _parse_health_timestamp(entry.get("observed_at"))
        if observed_at is None:
            return updated_at, "provider observation unavailable"
        if observed_at != updated_at:
            return updated_at, "provider observation carried"
        if observed_at > current_time:
            return updated_at, "future observation"
    return updated_at, "fresh"


def _refresh_health_progress(message: str) -> None:
    """Emit one credential-free health-verification status line."""
    print(f"refresh-health: {message}", file=sys.stderr, flush=True)


def _verify_refresh_health(
    *,
    duration: float,
    interval: float,
    reader: Callable[[], object] = _read_health_snapshot,
    clock: Callable[[], float] = time.monotonic,
    sleeper: Callable[[float], None] = time.sleep,
    status: Callable[[str], None] = _refresh_health_progress,
    wall_clock: Callable[[], datetime] | None = None,
) -> bool:
    """Verify three fresh, advancing Agy samples over the stale threshold."""
    if duration <= 0 or interval <= 0:
        status("failed: invalid verifier configuration")
        return False

    started = clock()
    deadline = started + duration
    previous_updated_at: datetime | None = None
    fresh_samples: list[datetime] = []
    read_wall_clock = wall_clock or (lambda: datetime.now().astimezone())
    last_reason = "no sample"

    while True:
        try:
            payload = reader()
            now = read_wall_clock()
            updated_at, reason = _health_sample_reason(payload, previous_updated_at, now)
        except Exception:  # noqa: BLE001 - health output must remain safe
            updated_at, reason = None, "unavailable"

        if updated_at is not None and (
            previous_updated_at is None or updated_at > previous_updated_at
        ):
            previous_updated_at = updated_at
        last_reason = reason
        status(f"sample {reason}")

        if reason == "fresh" and updated_at is not None:
            fresh_samples.append(updated_at)
            if (
                len(fresh_samples) >= 3
                and (fresh_samples[-1] - fresh_samples[0]).total_seconds()
                >= STALE_THRESHOLD_SECONDS
            ):
                status("passed")
                return True

        remaining = deadline - clock()
        if remaining <= 0:
            break
        wait_seconds = min(interval, remaining)
        status(f"waiting {wait_seconds:.1f}s")
        sleeper(wait_seconds)

    status(f"failed: {last_reason}")
    return False


def _verify_refresh_health_once(duration: float, interval: float) -> int:
    """Run the read-only health verifier and return a process exit code."""
    return 0 if _verify_refresh_health(duration=duration, interval=interval) else 1


def _merge_with_previous(
    previous: list[ProviderSnapshot],
    fresh: list[ProviderSnapshot],
    *,
    prior_payload: Mapping[str, object] | None = None,
    prior_auth_failures: int = 0,
    now: datetime | None = None,
) -> list[ProviderSnapshot]:
    """Merge transient cache state and bounded Antigravity auth grace."""
    previous_by_name = {snap.name: snap for snap in previous}
    publish_time = now or datetime.now().astimezone()
    if publish_time.tzinfo is None or publish_time.utcoffset() is None:
        publish_time = publish_time.astimezone()

    def auth_prior_is_fresh(name: str) -> bool:
        if not isinstance(prior_payload, Mapping):
            return False
        entries = prior_payload.get("providers")
        if not isinstance(entries, list):
            return False
        prior = next(
            (
                entry
                for entry in entries
                if isinstance(entry, Mapping) and entry.get("name") == name
            ),
            None,
        )
        if not isinstance(prior, Mapping) or prior.get("ok") is not True:
            return False
        observed_at = _parse_aware_iso_timestamp(prior.get("observed_at"))
        if observed_at is None:
            return False
        try:
            age = (publish_time - observed_at).total_seconds()
        except (TypeError, ValueError, OverflowError):
            return False
        return 0 <= age < STALE_THRESHOLD_SECONDS

    merged: list[ProviderSnapshot] = []
    for snapshot in fresh:
        prior = previous_by_name.get(snapshot.name)
        if (
            is_antigravity_auth_failure(snapshot)
            and prior_auth_failures == 0
            and auth_prior_is_fresh("Antigravity")
        ):
            merged.append(
                replace(
                    snapshot,
                    error=ANTIGRAVITY_AUTH_RETRY_MESSAGE,
                    debug_detail="auth_failure",
                )
            )
            continue
        if prior and prior.ok and _is_transient_probe_error(snapshot):
            cached_since = prior.cached_since or datetime.now()
            stale_seconds = (datetime.now() - cached_since).total_seconds()
            if stale_seconds >= STALE_THRESHOLD_SECONDS:
                age_min = int(stale_seconds // 60)
                merged.append(replace(snapshot, error=f"stale — offline for {age_min}m"))
                continue
            source = prior.source if "(cached)" in prior.source else f"{prior.source} (cached)"
            merged.append(replace(prior, source=source, cached_since=cached_since))
            continue
        if snapshot.ok and snapshot.cached_since is not None:
            merged.append(replace(snapshot, cached_since=None))
            continue
        merged.append(snapshot)
    merged.sort(key=lambda item: item.name)
    return merged


def _notify_warning(provider_name: str, window_ids: tuple[str, ...]) -> bool:
    """Send a macOS notification naming every warning window.

    Returns:
        True only when ``osascript`` accepts the notification.
    """
    try:
        result = subprocess.run(
            [
                "osascript",
                "-e",
                f'display notification "Warning window(s): {", ".join(window_ids)}" '
                f'with title "Gradus" subtitle "{provider_name}"',
            ],
            capture_output=True,
            timeout=5,
            check=False,
        )
        return result.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def _check_warnings(
    snapshots: list[ProviderSnapshot],
    notified_providers: set[str],
    now: datetime,
) -> None:
    """Notify once per provider while any normalized window warns."""
    membership = warning_membership(snapshots, now)
    for snap in snapshots:
        window_ids = membership[snap.name]
        if window_ids:
            if snap.name not in notified_providers:
                if _notify_warning(snap.name, window_ids):
                    notified_providers.add(snap.name)
        else:
            notified_providers.discard(snap.name)


@contextmanager
def _cbreak_mode():
    """Put stdin in cbreak mode for single-keypress reading. No-op if not a TTY."""
    if not sys.stdin.isatty():
        yield
        return
    fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(fd)
    try:
        tty.setcbreak(fd)
        yield
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)


# Anchored to the package's own directory, exactly like SNAPSHOT_PATH, NOT to
# the cwd. `local.gradus-snapshot` runs from launchd with a working directory
# gradus does not control, so a relative `.logs/gradus.log` would scatter log
# files wherever the job happened to start -- and the one place it would never
# be is where someone would look for it.
_LOG_PATH = Path(__file__).resolve().parent.parent / ".logs" / "gradus.log"

# Set by the test suite so pytest's own WARNING traffic cannot rotate real
# production evidence out of the log. An env var rather than an "am I running
# under pytest?" sniff: the override is a behavior a test can assert on, and
# a detection branch is not.
_LOG_PATH_ENV_VAR = "GRADUS_LOG_PATH"


def _resolve_log_path() -> Path:
    """The log file to write, honoring the test-suite override.

    Returns:
        ``$GRADUS_LOG_PATH`` when set and non-empty, else the project-anchored
        default.
    """
    override = os.environ.get(_LOG_PATH_ENV_VAR, "").strip()
    return Path(override) if override else _LOG_PATH


def _emit_debug_details(snapshots: list[ProviderSnapshot], debug: bool) -> None:
    """Write probe failure detail to stderr and the DEBUG log under ``--debug``.

    ``--debug``'s help text promises "Show full exception strings from probes",
    and until now nothing read ``ProviderSnapshot.debug_detail`` at all --
    recovering the Antigravity read-timeout required calling the internal
    wrapper by hand from a Python one-liner.

    Deliberately **stderr, not the JSON payload**. ``--json`` on stdout is a
    machine contract consumed by the review-plugin router, and INV-1 keeps
    credential material and raw HTTP bodies off it;
    ``test_render_json_data_is_safe_allowlist`` enforces that ``debug_detail``
    never appears there. ``debug_detail`` on the ``ProbeFailure`` branch
    carries the last 1600 chars of the raw error body, which is precisely what
    that invariant exists to exclude. Writing to stderr keeps stdout parseable
    and gives the human the detail on the same terminal.

    Args:
        snapshots: The cycle's snapshots; only failed ones carry detail.
        debug: The ``--debug`` flag. No output at all when False.
    """
    if not debug:
        return
    for snap in snapshots:
        if snap.ok or not snap.debug_detail:
            continue
        log.debug("provider %s debug detail: %s", snap.name, snap.debug_detail)
        sys.stderr.write(f"[debug] {snap.name}: {snap.debug_detail}\n")
    sys.stderr.flush()


def _setup_logging(debug: bool) -> None:
    """Configure file logging with rotation. Always logs WARNING+; --debug adds DEBUG.

    Idempotent per destination: calling this twice in one process replaces the
    gradus handler rather than stacking a second one. It previously appended
    unconditionally, so every repeat call in a process silently doubled each
    log line.
    """
    from logging.handlers import RotatingFileHandler

    path = _resolve_log_path()
    path.parent.mkdir(parents=True, exist_ok=True)

    root = logging.getLogger()
    for existing in [h for h in root.handlers if getattr(h, "_gradus_handler", False)]:
        root.removeHandler(existing)
        existing.close()

    handler = RotatingFileHandler(
        path,
        maxBytes=1_000_000,  # 1 MB
        backupCount=2,  # keep .log, .log.1, .log.2
    )
    handler._gradus_handler = True  # type: ignore[attr-defined]
    handler.setFormatter(
        logging.Formatter(
            "%(asctime)s %(levelname)s %(name)s: %(message)s",
            datefmt="%Y-%m-%d %H:%M:%S",
        )
    )
    root.setLevel(logging.DEBUG if debug else logging.WARNING)
    root.addHandler(handler)


def _history_query_once(
    requested_at: list[str], providers: list[str] | None, max_gap: float | None
) -> int:
    """Emit read-only historical evidence before any provider initialization."""
    result = query_history(
        requested_at,
        providers=providers,
        max_gap=max_gap,
        history_dir=Path(SNAPSHOT_V2_PATH).resolve().parent / "history",
    )
    sys.stdout.write(json.dumps(result, ensure_ascii=True, separators=(",", ":")) + "\n")
    sys.stdout.flush()
    return 0


def main() -> int:
    args = parse_args()
    if getattr(args, "history_at", None):
        return _history_query_once(
            args.history_at,
            getattr(args, "history_provider", None),
            getattr(args, "history_max_gap", None),
        )
    if getattr(args, "verify_refresh_health", False):
        return _verify_refresh_health_once(args.duration, args.health_interval)
    _setup_logging(args.debug)
    config = _load_config()
    enabled_providers: set[str] | None = None
    provider_override = getattr(args, "providers", None)
    if provider_override:
        enabled_providers = {name.strip() for name in provider_override.split(",") if name.strip()}
    elif isinstance(config.get("providers"), list):
        configured = {
            str(name).strip() for name in config.get("providers", []) if str(name).strip()
        }
        enabled_providers = configured or None
    if config.get("interval") and not any(arg.startswith("--interval") for arg in sys.argv[1:]):
        try:
            args.interval = int(config["interval"])
        except (TypeError, ValueError):
            pass
    cwd = os.getcwd()
    if getattr(args, "refresh_snapshot", False):
        return _refresh_snapshot_once(cwd, enabled_providers, args.debug)

    # Every user-facing surface reads the same launchd-owned v2 snapshot.
    # Provider initialization is intentionally absent here: only the explicit
    # single-flight producer above may perform authenticated probes.
    if getattr(args, "json", False):
        set_headless(True)
        canonical = _read_canonical_snapshots()
        if canonical is None:
            sys.stdout.write(render_json([], datetime.now().astimezone()) + "\n")
        else:
            snapshots, updated_at = canonical
            sys.stdout.write(render_json(snapshots, updated_at) + "\n")
        sys.stdout.flush()
        return 0
    if getattr(args, "once", False):
        canonical = _canonical_or_refresh(cwd, enabled_providers, args.debug)
        if canonical is None:
            snapshots, updated_at = [], datetime.now().astimezone()
        else:
            snapshots, updated_at = canonical
        console = Console(theme=THEME)
        _check_warnings(snapshots, set(), updated_at)
        console.print(
            build_dashboard(snapshots, updated_at, 0, fix_actions=_build_fix_actions(snapshots))
        )
        return 0

    # Normal interactive mode has no provider objects at all.  Keep these
    # empty for the defensive cleanup below; only --refresh-snapshot initializes
    # authenticated providers.
    cleanup: list[object] = []
    notified_providers: set[str] = set()
    # `_check_warnings` shells out to `osascript` per newly warning provider,
    # each a blocking call with a 5s timeout. On the render thread that is a
    # stall the user sees as a frozen frame. One worker, not more: serialized
    # submissions keep `notified_providers` single-threaded, so the "only mark
    # notified once osascript accepted it" retry rule still holds.
    notify_executor = ThreadPoolExecutor(max_workers=1)

    console = Console(theme=THEME)

    try:
        # Live interactive mode: hydrate and watch the canonical snapshot.
        with _cbreak_mode():
            with Live(
                console=console,
                screen=True,
                auto_refresh=False,
            ) as live:
                started = time.monotonic()
                load_executor = ThreadPoolExecutor(max_workers=1)
                load_future = load_executor.submit(
                    _canonical_or_refresh, cwd, enabled_providers, args.debug
                )
                try:
                    while not load_future.done():
                        live.update(
                            build_loading_screen(
                                "Waiting for canonical usage snapshot…",
                                datetime.now(),
                                time.monotonic() - started,
                            )
                        )
                        live.refresh()
                        time.sleep(0.12)
                    canonical = load_future.result()
                finally:
                    load_executor.shutdown(wait=True, cancel_futures=True)
                if canonical is None:
                    current, updated_at = [], datetime.now().astimezone()
                else:
                    current, updated_at = canonical
                snapshot_signature = _snapshot_signature()

                # Main refresh loop
                quit_requested = False
                while not quit_requested:
                    # Countdown phase with deadline-based drift correction
                    deadline = time.monotonic() + args.interval
                    remaining = args.interval
                    refresh_now = False
                    fix_actions = _build_fix_actions(current)
                    while remaining > 0 and not quit_requested:
                        watched = _read_canonical_snapshots()
                        new_signature = _snapshot_signature()
                        if watched is not None and new_signature != snapshot_signature:
                            current, updated_at = watched
                            snapshot_signature = new_signature
                            notify_executor.submit(
                                _check_warnings, current, notified_providers, datetime.now()
                            )
                        live.update(
                            build_dashboard(
                                current,
                                updated_at,
                                remaining,
                                fix_actions=fix_actions,
                            )
                        )
                        live.refresh()
                        sleep_until = deadline - remaining + 1
                        wait_time = max(0.0, sleep_until - time.monotonic())
                        if sys.stdin.isatty():
                            readable, _, _ = select.select([sys.stdin], [], [], wait_time)
                            if readable:
                                key = sys.stdin.read(1)
                                if key in ("q", "Q"):
                                    quit_requested = True
                                    break
                                if key in ("r", "R"):
                                    refresh_now = True
                                    break
                                if key in fix_actions:
                                    _, kind, target = fix_actions[key]
                                    _launch_fix(kind, target)
                        else:
                            time.sleep(wait_time)
                        remaining -= 1

                    if quit_requested:
                        break
                    # Launchd owns the normal cadence.  The TUI only submits
                    # the producer for an explicit ``r``; when the countdown
                    # expires, restart the watch/countdown and wait for the
                    # canonical file to advance.
                    if not refresh_now:
                        continue

                    # Refresh phase: ask the existing single-flight producer;
                    # this thread never initializes providers or probes APIs.
                    refresh_executor = ThreadPoolExecutor(max_workers=1)
                    try:
                        refresh_started = time.monotonic()
                        refresh_future = refresh_executor.submit(
                            _refresh_snapshot_once, cwd, enabled_providers, args.debug
                        )
                        while not refresh_future.done():
                            live.update(
                                build_dashboard(
                                    current,
                                    datetime.now(),
                                    0,
                                    updating=True,
                                    update_elapsed=time.monotonic() - refresh_started,
                                    fix_actions=fix_actions,
                                )
                            )
                            live.refresh()
                            if sys.stdin.isatty():
                                readable, _, _ = select.select([sys.stdin], [], [], 0.12)
                                if readable:
                                    key = sys.stdin.read(1)
                                    if key in ("q", "Q"):
                                        quit_requested = True
                                        break
                            else:
                                time.sleep(0.12)
                        if not quit_requested:
                            refresh_future.result()
                            watched = _read_canonical_snapshots()
                            if watched is not None:
                                current, updated_at = watched
                                snapshot_signature = _snapshot_signature()
                                notify_executor.submit(
                                    _check_warnings, current, notified_providers, datetime.now()
                                )
                    finally:
                        refresh_executor.shutdown(wait=False, cancel_futures=True)

                    if quit_requested:
                        break

    except KeyboardInterrupt:
        return 0
    finally:
        # Not cancel_futures: a queued warning is the user's notification, and
        # dropping it silently is worse than the brief wait an in-flight
        # osascript costs on the way out.
        notify_executor.shutdown(wait=False)
        for provider in cleanup:
            provider.close()


if __name__ == "__main__":
    raise SystemExit(main())
