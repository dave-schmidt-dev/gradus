#!/usr/bin/env python3
"""Run one explicit argv in a bounded, disposable process group.

The runner deliberately has no shell mode and gives the child no stdin.  Its
only generated diagnostic is category/exit metadata; child stdout and stderr
contents are never copied into that diagnostic.
"""

from __future__ import annotations

import errno
import json
import math
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
from typing import Callable, List, Optional, Sequence, Tuple


TIMEOUT_EXIT = 124
DEFAULT_GRACE = 2.0
DEFAULT_CLEANUP = 2.0
MAX_METADATA_BYTES = 200
_CATEGORY_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")


class RunnerArguments(Exception):
    """An invocation cannot safely be started."""


def _diagnostic(message: str) -> None:
    # Keep all messages fixed-format and free of argv, paths, and child data.
    sys.stderr.write("deadline-runner: %s\n" % message)
    sys.stderr.flush()


def _positive_seconds(raw: str, option: str) -> float:
    try:
        value = float(raw)
    except (TypeError, ValueError):
        raise RunnerArguments("invalid %s" % option)
    if not math.isfinite(value) or value <= 0:
        raise RunnerArguments("invalid %s" % option)
    return value


def _category(raw: str) -> str:
    if not _CATEGORY_RE.fullmatch(raw):
        raise RunnerArguments("invalid category")
    return raw


def _parse(argv: Sequence[str]) -> Tuple[float, float, float, str, Optional[str], Optional[str], Optional[str], List[str]]:
    """Parse options before the required ``--`` argv delimiter."""
    try:
        delimiter = list(argv).index("--")
    except ValueError:
        raise RunnerArguments("missing argv delimiter")

    options = list(argv[:delimiter])
    child = list(argv[delimiter + 1 :])
    if not child or any(not isinstance(arg, str) for arg in child) or not child[0]:
        raise RunnerArguments("missing child argv")

    deadline: Optional[float] = None
    grace = DEFAULT_GRACE
    cleanup = DEFAULT_CLEANUP
    category = "child"
    state_dir: Optional[str] = None
    state_file: Optional[str] = None
    stderr_file: Optional[str] = None

    aliases = {
        "--deadline": "deadline",
        "--deadline-seconds": "deadline",
        "--grace": "grace",
        "--term-grace": "grace",
        "--cleanup": "cleanup",
        "--cleanup-seconds": "cleanup",
        "--cleanup-allowance": "cleanup",
        "--category": "category",
        "--state-dir": "state_dir",
        "--state-file": "state_file",
        "--stderr-file": "stderr_file",
    }
    i = 0
    while i < len(options):
        name = options[i]
        field = aliases.get(name)
        if field is None or i + 1 >= len(options) or options[i + 1] == "--":
            raise RunnerArguments("invalid arguments")
        value = options[i + 1]
        if field == "deadline":
            deadline = _positive_seconds(value, "deadline")
        elif field == "grace":
            grace = _positive_seconds(value, "grace")
        elif field == "cleanup":
            cleanup = _positive_seconds(value, "cleanup")
        elif field == "category":
            category = _category(value)
        elif field == "state_dir":
            if not value:
                raise RunnerArguments("invalid state location")
            if state_dir is not None:
                raise RunnerArguments("duplicate state location")
            state_dir = value
        elif field == "state_file":
            if not value:
                raise RunnerArguments("invalid state location")
            if state_file is not None:
                raise RunnerArguments("duplicate state location")
            state_file = value
        elif field == "stderr_file":
            if not value:
                raise RunnerArguments("invalid stderr location")
            if stderr_file is not None:
                raise RunnerArguments("duplicate stderr location")
            stderr_file = value
        i += 2

    if deadline is None:
        raise RunnerArguments("missing deadline")
    if state_dir is not None and state_file is not None:
        raise RunnerArguments("conflicting state locations")
    return deadline, grace, cleanup, category, state_dir, state_file, stderr_file, child


def _default_state_dir() -> str:
    return os.path.join(tempfile.gettempdir(), "launchd-deadline-runner")


def _safe_state_dir(path: str) -> Optional[str]:
    try:
        os.makedirs(path, mode=0o700, exist_ok=True)
        if not os.path.isdir(path):
            return None
        return path
    except (OSError, ValueError):
        return None


def _pid_group_alive(pgid: int) -> bool:
    if pgid <= 1 or pgid == os.getpgrp():
        return True
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except OSError as exc:
        # EPERM means a process exists but is not signalable by this uid; be
        # conservative and retain cleanup state rather than starting a transfer.
        if exc.errno == errno.ESRCH:
            return False
        return True
    return True


def _valid_record(record: object) -> Optional[Tuple[int, int, str]]:
    if not isinstance(record, dict):
        return None
    pid = record.get("pid")
    pgid = record.get("pgid")
    category = record.get("category")
    if (
        not isinstance(pid, int)
        or isinstance(pid, bool)
        or pid <= 1
        or not isinstance(pgid, int)
        or isinstance(pgid, bool)
        or pgid <= 1
        or not isinstance(category, str)
        or not _CATEGORY_RE.fullmatch(category)
    ):
        return None
    return pid, pgid, category


def _read_record(path: str) -> Optional[Tuple[int, int, str]]:
    try:
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        fd = os.open(path, flags)
        with os.fdopen(fd, "r", encoding="ascii") as stream:
            return _valid_record(json.load(stream))
    except (OSError, ValueError, TypeError, json.JSONDecodeError):
        return None


def _check_conflicts(state_dir: str) -> bool:
    try:
        entries = list(os.scandir(state_dir))
    except OSError:
        return True
    for entry in entries:
        if not entry.is_file(follow_symlinks=False) or not entry.name.startswith("cleanup-") or not entry.name.endswith(".json"):
            continue
        record = _read_record(entry.path)
        if record is None:
            continue
        _, pgid, category = record
        if _pid_group_alive(pgid):
            _diagnostic("cleanup-conflict category=%s" % category)
            return True
        try:
            os.unlink(entry.path)
        except OSError:
            pass
    return False


def _write_cleanup_record(state_dir: Optional[str], state_file: Optional[str], pid: int, pgid: int, category: str) -> bool:
    location = state_file
    if location is None:
        if state_dir is None:
            state_dir = _default_state_dir()
        state_dir = _safe_state_dir(state_dir)
        if state_dir is None:
            return False
        # The name is opaque and contains only the safe numeric identifiers.
        location = os.path.join(state_dir, "cleanup-%d-%d.json" % (pid, pgid))
    else:
        parent = os.path.dirname(location) or "."
        if _safe_state_dir(parent) is None:
            return False
    record = {"pid": pid, "pgid": pgid, "category": category}
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        fd = os.open(location, flags, 0o600)
        with os.fdopen(fd, "w", encoding="ascii") as stream:
            json.dump(record, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
        return True
    except (OSError, TypeError, ValueError):
        return False


def _set_nonblocking(stream: object) -> None:
    try:
        os.set_blocking(stream.fileno(), False)  # type: ignore[attr-defined]
    except (AttributeError, OSError):
        pass


def _open_stderr_file(path: str) -> object:
    """Open an explicit regular-file stderr sink without following symlinks."""
    parent = os.path.dirname(path) or "."
    if not os.path.isdir(parent):
        raise RunnerArguments("invalid stderr location")
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    try:
        fd = os.open(path, flags, 0o600)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            os.close(fd)
            raise RunnerArguments("invalid stderr location")
        return os.fdopen(fd, "ab", buffering=0)
    except RunnerArguments:
        raise
    except (OSError, ValueError):
        raise RunnerArguments("invalid stderr location")


def _drain_stderr(stream: object, count: int) -> int:
    """Drain a small bounded amount so a noisy child cannot fill the pipe."""
    if stream is None:
        return count
    try:
        fd = stream.fileno()  # type: ignore[attr-defined]
    except AttributeError:
        return count
    for _ in range(8):
        try:
            chunk = os.read(fd, 4096)
        except (BlockingIOError, InterruptedError, OSError):
            break
        if not chunk:
            break
        count = min(MAX_METADATA_BYTES, count + len(chunk))
    return count


def _kill_group(pgid: int, sig: int) -> bool:
    if pgid <= 1 or pgid == os.getpgrp():
        return False
    try:
        os.killpg(pgid, sig)
    except ProcessLookupError:
        return True
    except OSError as exc:
        return exc.errno == errno.ESRCH
    return True


def _wait_bounded(
    process: object,
    pgid: int,
    seconds: float,
    stderr_count: int,
    group_must_exit: bool = True,
    group_alive: Callable[[int], bool] = _pid_group_alive,
    clock: Callable[[], float] = time.monotonic,
    sleeper: Callable[[float], None] = time.sleep,
) -> Tuple[Optional[int], bool, int]:
    """Poll direct child and group for at most ``seconds``; never wait()."""
    end = clock() + seconds
    while True:
        stderr_count = _drain_stderr(getattr(process, "stderr", None), stderr_count)
        returncode = process.poll()  # type: ignore[attr-defined]
        group_exists = group_alive(pgid)
        if returncode is not None and (not group_must_exit or not group_exists):
            return returncode, False, stderr_count
        remaining = end - clock()
        if remaining <= 0:
            return returncode, group_exists, stderr_count
        sleeper(min(0.05, remaining))


def run(
    argv: Sequence[str],
    *,
    popen_factory: Callable[..., object] = subprocess.Popen,
    group_alive: Callable[[int], bool] = _pid_group_alive,
    kill_group: Callable[[int, int], bool] = _kill_group,
    clock: Callable[[], float] = time.monotonic,
    sleeper: Callable[[float], None] = time.sleep,
) -> int:
    deadline, grace, cleanup, category, requested_state_dir, state_file, stderr_file, child = _parse(argv)
    state_dir = requested_state_dir
    if state_dir is not None:
        state_dir = _safe_state_dir(state_dir)
        if state_dir is None:
            raise RunnerArguments("invalid state location")
        if _check_conflicts(state_dir):
            return TIMEOUT_EXIT
    elif state_file is not None:
        parent = os.path.dirname(state_file) or "."
        parent = _safe_state_dir(parent)
        if parent is None:
            raise RunnerArguments("invalid state location")
        # A caller-provided state file is checked directly, without scanning
        # its parent (which may contain unrelated application state).
        record = _read_record(state_file) if os.path.exists(state_file) else None
        if record is not None and group_alive(record[1]):
            _diagnostic("cleanup-conflict category=%s" % record[2])
            return TIMEOUT_EXIT
        if record is not None:
            try:
                os.unlink(state_file)
            except OSError:
                pass
    else:
        state_dir = _safe_state_dir(_default_state_dir())
        if state_dir is None or _check_conflicts(state_dir):
            return TIMEOUT_EXIT

    stderr_target: object = subprocess.PIPE
    if stderr_file is not None:
        stderr_target = _open_stderr_file(stderr_file)
    try:
        process = popen_factory(
            child,
            shell=False,
            start_new_session=True,
            stdin=subprocess.DEVNULL,
            stdout=None,
            stderr=stderr_target,
            close_fds=True,
        )
    except (OSError, ValueError, TypeError):
        if stderr_file is not None:
            stderr_target.close()  # type: ignore[attr-defined]
        _diagnostic("launch-failed category=%s" % category)
        return 127

    pid = int(getattr(process, "pid", 0))
    if pid <= 1:
        if stderr_file is not None:
            stderr_target.close()  # type: ignore[attr-defined]
        _diagnostic("launch-failed category=%s" % category)
        return 127
    try:
        pgid = os.getpgid(pid)
    except OSError:
        # start_new_session makes pid the group leader.  Keeping this fallback
        # also permits a very short-lived child to be cleaned up safely.
        pgid = pid
    _set_nonblocking(getattr(process, "stderr", None))

    started = clock()
    stderr_count = 0
    returncode, group_left, stderr_count = _wait_bounded(
        process, pgid, deadline, stderr_count, group_must_exit=True, group_alive=group_alive, clock=clock, sleeper=sleeper
    )
    if returncode is not None and not group_left:
        if stderr_file is not None:
            stderr_target.close()  # type: ignore[attr-defined]
        return returncode

    # The deadline elapsed, or the direct child exited while a descendant kept
    # the fresh process group alive.  TERM then KILL are each followed by a
    # finite poll window.  No wait()/communicate() call is allowed here.
    kill_group(pgid, signal.SIGTERM)
    returncode, group_left, stderr_count = _wait_bounded(
        process, pgid, grace, stderr_count, group_must_exit=True, group_alive=group_alive, clock=clock, sleeper=sleeper
    )
    if returncode is None or group_left:
        kill_group(pgid, signal.SIGKILL)
        returncode, group_left, stderr_count = _wait_bounded(
            process, pgid, cleanup, stderr_count, group_must_exit=True, group_alive=group_alive, clock=clock, sleeper=sleeper
        )

    if returncode is None or group_left or group_alive(pgid):
        _write_cleanup_record(state_dir, state_file, pid, pgid, category)
        if stderr_file is not None:
            stderr_target.close()  # type: ignore[attr-defined]
        _diagnostic(
            "timeout category=%s pid=%d pgid=%d cleanup=%s stderr-bytes=%d"
            % (category, pid, pgid, "unconfirmed-cleanup" if group_left or returncode is None else "confirmed", stderr_count)
        )
        return TIMEOUT_EXIT

    # A descendant-only cleanup completed after the direct child had already
    # exited.  Preserve that ordinary child status; only a deadline timeout is
    # represented by the reserved status.
    if returncode is not None and clock() - started < deadline:
        if stderr_file is not None:
            stderr_target.close()  # type: ignore[attr-defined]
        return returncode
    if stderr_file is not None:
        stderr_target.close()  # type: ignore[attr-defined]
    _diagnostic("timeout category=%s pid=%d pgid=%d cleanup=confirmed stderr-bytes=%d" % (category, pid, pgid, stderr_count))
    return TIMEOUT_EXIT


def main(argv: Optional[Sequence[str]] = None) -> int:
    try:
        return run(list(sys.argv[1:] if argv is None else argv))
    except RunnerArguments as exc:
        # Do not print the exception: option values can contain paths or other
        # caller data.  The fixed category is enough for launchd diagnostics.
        _diagnostic("invalid-arguments")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
