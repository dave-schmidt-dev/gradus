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

from .history import append_history_record, query_history
from .providers import (
    ProviderSnapshot,
    fetch_provider_snapshot,
    set_headless,
)
from .providers._base import _PROVIDER_REGISTRY
from .snapshot import (
    SNAPSHOT_PATH,
    SNAPSHOT_V2_PATH,
    STALE_THRESHOLD_SECONDS,
    _is_transient_probe_error,
    build_snapshot_payload,
    build_snapshot_v2_payload,
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
    "Claude": ("cli", "claude login"),
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
    """Open a Terminal window (CLI) or browser (web) to fix an auth error."""
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
                'tell application "Terminal" to activate',
                "-e",
                f'tell application "Terminal" to do script "{target}"',
            ],
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
        "--write-snapshot",
        action="store_true",
        dest="write_snapshot",
        help=(
            "Write a headless capacity snapshot to .state/snapshot.json and exit "
            "(no browser, no notifications)."
        ),
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
    if args.refresh_snapshot and (args.once or args.json or args.write_snapshot):
        parser.error(
            "argument --refresh-snapshot: not allowed with --once, --json, or --write-snapshot"
        )
    if args.verify_refresh_health:
        conflicts = [
            flag
            for flag, enabled in (
                ("--once", args.once),
                ("--json", args.json),
                ("--write-snapshot", args.write_snapshot),
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
                ("--write-snapshot", args.write_snapshot),
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
        future_map = {}
        for name, provider in workers:
            if on_start is not None:
                on_start(name)
            future_map[executor.submit(fetch_provider_snapshot, name, provider, debug)] = name

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


def _write_snapshot_versions(
    snaps: list[ProviderSnapshot],
    when: datetime,
    *,
    on_status: Callable[[str], None] | None = None,
    lock_timeout: float | None = None,
    lock_poll_interval: float = 0.1,
    journal_history: bool = False,
) -> tuple[bool, bool] | tuple[bool, bool, bool]:
    """Write v1 and v2 independently, optionally journaling committed v2."""

    def status(message: str) -> None:
        if on_status is not None:
            on_status(message)

    def writer_progress(schema: str) -> Callable[[str], None] | None:
        if on_status is None:
            return None

        def progress(message: str) -> None:
            status(f"{schema} {message}")

        return progress

    try:
        v1_ok = write_snapshot(
            build_snapshot_payload(snaps, when, prior=read_prior_snapshot(SNAPSHOT_PATH)),
            on_progress=writer_progress("schema-v1"),
            lock_timeout=lock_timeout,
            lock_poll_interval=lock_poll_interval,
        )
    except Exception:  # noqa: BLE001 - persistence must not crash the dashboard
        log.warning("failed to write schema-v1 snapshot")
        v1_ok = False
    status(f"schema-v1 {'persisted' if v1_ok else 'persistence failed'}")

    v2_payload: dict | None = None
    try:
        v2_payload = build_snapshot_v2_payload(
            snaps, when, prior=read_prior_snapshot(SNAPSHOT_V2_PATH)
        )
        v2_ok = write_snapshot(
            v2_payload,
            SNAPSHOT_V2_PATH,
            on_progress=writer_progress("schema-v2"),
            lock_timeout=lock_timeout,
            lock_poll_interval=lock_poll_interval,
        )
    except Exception:  # noqa: BLE001 - persistence must not crash the dashboard
        log.warning("failed to write schema-v2 snapshot")
        v2_ok = False
    status(f"schema-v2 {'persisted' if v2_ok else 'persistence failed'}")

    if not journal_history:
        return v1_ok, v2_ok

    history_ok = False
    if v2_ok and v2_payload is not None:
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
        providers, cleanup = initialize_providers(cwd, enabled_providers)

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
            return updated_at, "provider not healthy"
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
                and (fresh_samples[-1] - fresh_samples[0]).total_seconds() > STALE_THRESHOLD_SECONDS
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
) -> list[ProviderSnapshot]:
    previous_by_name = {snap.name: snap for snap in previous}
    merged: list[ProviderSnapshot] = []
    for snapshot in fresh:
        prior = previous_by_name.get(snapshot.name)
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


_LOG_PATH = Path("/tmp/gradus.log")


def _setup_logging(debug: bool) -> None:
    """Configure file logging with rotation. Always logs WARNING+; --debug adds DEBUG."""
    from logging.handlers import RotatingFileHandler

    handler = RotatingFileHandler(
        _LOG_PATH,
        maxBytes=1_000_000,  # 1 MB
        backupCount=2,  # keep .log, .log.1, .log.2
    )
    handler.setFormatter(
        logging.Formatter(
            "%(asctime)s %(levelname)s %(name)s: %(message)s",
            datefmt="%Y-%m-%d %H:%M:%S",
        )
    )
    root = logging.getLogger()
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
    if getattr(args, "write_snapshot", False) or getattr(args, "json", False):
        # Engage strictly read-only mode BEFORE constructing providers, so their
        # constructors never spawn a browser, refresh a token, or write a cache
        # (INV-2: the headless path has zero side effects). --json is a machine
        # surface (cron/scripts), so it earns the same read-only guarantee as
        # --write-snapshot: an uncached provider reports "auth required" instead
        # of triggering interactive recovery.
        set_headless(True)
    providers, cleanup = initialize_providers(cwd, enabled_providers)
    notified_providers: set[str] = set()

    def _persist_snapshot(snaps: list[ProviderSnapshot], when: datetime) -> None:
        """Persist a router-facing snapshot without ever crashing the dashboard.

        Args:
            snaps: The freshly collected provider snapshots.
            when: The instant the snapshot was captured.
        """
        v1_ok, v2_ok, history_ok = _write_snapshot_versions(snaps, when, journal_history=True)
        if not (v1_ok and v2_ok and history_ok):
            log.warning(
                "snapshot persist partially failed: v1=%s v2=%s history=%s",
                v1_ok,
                v2_ok,
                history_ok,
            )

    def refresh(previous: list[ProviderSnapshot]) -> list[ProviderSnapshot]:
        fresh: list[ProviderSnapshot] = []
        workers = [(name, p) for name, p in providers if hasattr(p, "fetch")]
        executor = ThreadPoolExecutor(max_workers=len(workers) or 1)
        try:
            future_map = {
                executor.submit(fetch_provider_snapshot, name, provider, args.debug): name
                for name, provider in workers
            }
            for future in future_map:
                fresh.append(future.result())
        finally:
            executor.shutdown(wait=False, cancel_futures=True)
        static_names = {snap.name for snap in fresh}
        for snap in previous:
            if snap.name not in static_names and not snap.ok:
                fresh.append(snap)
        return _merge_with_previous(previous, fresh)

    console = Console(theme=THEME)

    try:
        if getattr(args, "write_snapshot", False):
            # Headless snapshot: read-only probe, persist, exit. No warning
            # checks (no notifications). Providers are already headless; the
            # outer `finally` closes them.
            snapshots = collect_snapshots(providers, args.debug)
            v1_ok, v2_ok, history_ok = _write_snapshot_versions(
                snapshots, datetime.now(), journal_history=True
            )
            if v1_ok and v2_ok and history_ok:
                log.info("wrote headless snapshots for %d providers", len(snapshots))
                return 0
            log.warning(
                "headless snapshot write partially failed: v1=%s v2=%s history=%s",
                v1_ok,
                v2_ok,
                history_ok,
            )
            return 1

        if args.json:
            # Read-only/machine-safe (headless engaged above): no warning
            # notifications, matching --write-snapshot.
            updated_at = datetime.now()
            snapshots = collect_snapshots(providers, args.debug)
            sys.stdout.write(render_json(snapshots, updated_at) + "\n")
            sys.stdout.flush()
            return 0

        # --once: block on initial fetch, print dashboard, exit (no alt-screen)
        if args.once:
            snapshots = collect_snapshots(providers, args.debug)
            updated_at = datetime.now()
            _check_warnings(snapshots, notified_providers, updated_at)
            fix_actions = _build_fix_actions(snapshots)
            console.print(build_dashboard(snapshots, updated_at, 0, fix_actions=fix_actions))
            return 0

        # Live interactive mode
        with _cbreak_mode():
            with Live(
                console=console,
                screen=True,
                auto_refresh=False,
            ) as live:
                # Loading phase
                executor = ThreadPoolExecutor(max_workers=1)
                try:
                    future = executor.submit(collect_snapshots, providers, args.debug)
                    started = time.monotonic()
                    while not future.done():
                        live.update(
                            build_loading_screen(
                                "Getting initial usage from Claude, Codex, Antigravity, Copilot, Cursor, Vibe, and OpenCode Go…",
                                datetime.now(),
                                time.monotonic() - started,
                            )
                        )
                        live.refresh()
                        time.sleep(0.12)
                    current = future.result()
                    _check_warnings(current, notified_providers, datetime.now())
                    _persist_snapshot(current, datetime.now())
                finally:
                    executor.shutdown(wait=False, cancel_futures=True)

                # Main refresh loop
                quit_requested = False
                while not quit_requested:
                    updated_at = datetime.now()

                    # Countdown phase with deadline-based drift correction
                    deadline = time.monotonic() + args.interval
                    remaining = args.interval
                    refresh_now = False
                    fix_actions = _build_fix_actions(current)
                    while remaining > 0 and not quit_requested:
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
                    if not refresh_now and remaining > 0:
                        continue

                    # Refresh phase: show updating spinner while fetching
                    refresh_executor = ThreadPoolExecutor(max_workers=1)
                    try:
                        refresh_started = time.monotonic()
                        refresh_future = refresh_executor.submit(refresh, current)
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
                            current = refresh_future.result()
                            _check_warnings(current, notified_providers, datetime.now())
                            _persist_snapshot(current, updated_at)
                    finally:
                        refresh_executor.shutdown(wait=False, cancel_futures=True)

                    if quit_requested:
                        break

    except KeyboardInterrupt:
        return 0
    finally:
        for provider in cleanup:
            provider.close()


if __name__ == "__main__":
    raise SystemExit(main())
