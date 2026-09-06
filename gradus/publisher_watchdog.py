"""Keep the macOS CloudKit publisher alive across the producer's launchd cycle.

The Python producer is supervised by launchd and refreshes the snapshot every
120 seconds.  The macOS publisher that copies that snapshot into CloudKit is a
GUI app with no supervisor at all, so when it exits -- crash, user quit, or a
cause that leaves no trace, as on 2026-08-30 -- the snapshot keeps refreshing
while iOS silently freezes on the last publication.

This watchdog closes that gap from inside the already-supervised producer: once
per refresh cycle it compares a fresh snapshot against lagging publish evidence
and relaunches the publisher by absolute path.  It is deliberately narrow --
relaunch is the only action, and only when the publisher is *absent*.  A present
but stale publisher is a wedged app or a CloudKit outage; relaunching cannot fix
either, so that case is reported and left alone.

This is interim scope.  Task 2.4 moves publishing into the supervised background
agent, at which point launchd owns publisher liveness and this module retires.
"""

from __future__ import annotations

import json
import os
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

# The publisher watches this exact file (GradusMacApp.swift `defaultSnapshotPath`)
# and writes its evidence beside it. Both are absolute and mode-independent
# because the *publisher* resolves them that way, not the producer. `Installed/`
# is the one canonical installed-mode public state root, shared with the refresh
# agent and `gradus.paths.installed_runtime_paths`; the bare
# `Gradus/snapshot-v2.json` beside it is the legacy rollback mirror and is
# deliberately not watched.
PUBLISHER_SNAPSHOT = (
    Path.home() / "Library" / "Application Support" / "Gradus" / "Installed" / "snapshot-v2.json"
)
PUBLISHER_EVIDENCE = PUBLISHER_SNAPSHOT.parent / "publish-evidence.json"

# Launch by absolute path, never by name or bundle identifier. The shipped
# wrapper is `Gradus.app` (`GradusMac` survives only as the scheme and archive
# name). Until 2026-09-06 this pointed at the pre-rename `GradusMac.app`, so a
# stale 1.10.0 publisher was kept alive beside the installed one and iOS
# showed whichever record won the race. Identifier-based resolution would
# reintroduce exactly that ambiguity whenever a second bundle claims
# `com.zerodelta.gradus.mac`, so the path stays literal.
PUBLISHER_APP = Path("/Applications/Gradus.app")
PUBLISHER_EXECUTABLE = PUBLISHER_APP / "Contents" / "MacOS" / "Gradus"

# A snapshot older than this means the producer itself is behind; publisher
# liveness is not the problem and the producer's own failure path already
# alarms on it.
SNAPSHOT_FRESH_SECONDS = 300.0
# Two-and-a-half cycles. One missed publish is a scheduling wobble; three is a
# publisher that is not coming back on its own.
PUBLISH_LAG_SECONDS = 300.0
# A crash-looping publisher must stay visible rather than relaunch 720 times a
# day. Past this many launches per hour the watchdog reports and stands down.
MAX_RELAUNCHES_PER_HOUR = 3
STATE_FILENAME = ".publisher-watchdog.json"


@dataclass(frozen=True, slots=True)
class WatchdogDecision:
    """One cycle's verdict. `message` is empty when there is nothing to report."""

    action: str
    message: str

    @property
    def is_quiet(self) -> bool:
        return not self.message


def _read_json(path: Path) -> dict | None:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def _age_seconds(payload: dict | None, key: str, now: float) -> float | None:
    """Seconds since `payload[key]`, or None when it is absent or unparseable."""
    if payload is None:
        return None
    raw = payload.get(key)
    if not isinstance(raw, str) or not raw:
        return None
    try:
        stamp = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    if stamp.tzinfo is None:
        return None
    return now - stamp.timestamp()


def _publisher_is_running(executable: Path) -> bool:
    """True when a process is running that exact executable path.

    Matched on the full path so a differently-located build of the same app --
    a DerivedData copy, or a pre-rename `GradusMac.app` -- never reads as a
    healthy publisher.
    """
    try:
        result = subprocess.run(
            ["/usr/bin/pgrep", "-f", f"^{executable}$"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError, subprocess.TimeoutExpired):
        # Unknown liveness must not authorize a launch: assume it is up.
        return True
    return result.returncode == 0 and bool(result.stdout.strip())


def _recent_relaunches(state_path: Path, now: float) -> list[float]:
    payload = _read_json(state_path)
    stamps = payload.get("relaunched_at") if payload else None
    if not isinstance(stamps, list):
        return []
    return [
        float(value)
        for value in stamps
        if isinstance(value, (int, float))
        and not isinstance(value, bool)
        and 0 < now - float(value) < 3600
    ]


def _record_relaunch(state_path: Path, stamps: list[float], now: float) -> None:
    try:
        state_path.parent.mkdir(parents=True, exist_ok=True)
        state_path.write_text(
            json.dumps({"relaunched_at": [*stamps, now]}, indent=2), encoding="utf-8"
        )
    except OSError:
        # Losing the throttle record must not block a relaunch that is needed;
        # the worst case is one extra launch attempt next cycle.
        pass


def _launch(app: Path) -> tuple[bool, str]:
    try:
        result = subprocess.run(
            ["/usr/bin/open", "-g", str(app)],
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.SubprocessError, subprocess.TimeoutExpired) as exc:
        return False, type(exc).__name__
    if result.returncode != 0:
        return False, f"open exited {result.returncode}"
    return True, ""


def evaluate(
    *,
    now: float | None = None,
    snapshot_path: Path = PUBLISHER_SNAPSHOT,
    evidence_path: Path = PUBLISHER_EVIDENCE,
    app_path: Path = PUBLISHER_APP,
    executable_path: Path = PUBLISHER_EXECUTABLE,
    state_path: Path | None = None,
    launch: bool = True,
) -> WatchdogDecision:
    """Decide whether the publisher needs relaunching, and act when it does.

    Args:
        now: Unix timestamp to evaluate against; defaults to the current time.
        snapshot_path: The snapshot file the publisher watches.
        evidence_path: The publish-evidence file the publisher writes.
        app_path: Bundle to launch, by absolute path.
        executable_path: Exact executable a live publisher must be running.
        state_path: Relaunch-throttle record; defaults beside the snapshot.
        launch: When False, decide but never spawn (used by tests).

    Returns:
        A :class:`WatchdogDecision` whose `message` is empty when the pipeline is
        healthy and there is nothing worth writing to the producer's log.
    """
    now = time.time() if now is None else now
    state_path = state_path or (snapshot_path.parent / STATE_FILENAME)

    snapshot_age = _age_seconds(_read_json(snapshot_path), "updated_at", now)
    if snapshot_age is None:
        return WatchdogDecision(
            "snapshot_unreadable",
            f"publisher watchdog: cannot read {snapshot_path.name}; skipping liveness check.",
        )
    if snapshot_age > SNAPSHOT_FRESH_SECONDS:
        # The producer is behind, so the publisher having nothing new to publish
        # is correct behavior rather than a fault. Stay quiet: the producer's own
        # failure path owns this.
        return WatchdogDecision("snapshot_stale", "")

    evidence = _read_json(evidence_path)
    publish_age = _age_seconds(evidence, "publishedAt", now)
    # A missing or unparseable evidence file against a fresh snapshot means the
    # publisher has never published or lost its record: treat it as lagging.
    if publish_age is not None and publish_age <= PUBLISH_LAG_SECONDS:
        return WatchdogDecision("healthy", "")

    lag = "never" if publish_age is None else f"{int(publish_age)}s"
    if _publisher_is_running(executable_path):
        return WatchdogDecision(
            "running_but_stale",
            f"publisher watchdog: publisher is running but has not published for {lag} "
            f"(snapshot {int(snapshot_age)}s old). Not relaunching -- a live process that "
            "is not publishing is a wedged app or a CloudKit outage, which a relaunch "
            "cannot fix. Check Gradus in the menu bar.",
        )

    recent = _recent_relaunches(state_path, now)
    if len(recent) >= MAX_RELAUNCHES_PER_HOUR:
        return WatchdogDecision(
            "throttled",
            f"publisher watchdog: publisher absent and {lag} behind, but it has already "
            f"been relaunched {len(recent)} times this hour. Standing down -- this is a "
            "crash loop, not a one-off exit.",
        )

    if not app_path.exists():
        return WatchdogDecision(
            "app_missing",
            f"publisher watchdog: publisher absent and {lag} behind, but {app_path} "
            "does not exist. Cannot relaunch.",
        )

    if not launch:
        return WatchdogDecision(
            "would_relaunch", f"publisher watchdog: would relaunch {app_path.name} ({lag} behind)."
        )

    launched, failure = _launch(app_path)
    if not launched:
        return WatchdogDecision(
            "launch_failed",
            f"publisher watchdog: relaunch of {app_path.name} failed ({failure}).",
        )
    _record_relaunch(state_path, recent, now)
    return WatchdogDecision(
        "relaunched",
        f"publisher watchdog: publisher was not running and CloudKit was {lag} behind a "
        f"fresh snapshot; relaunched {app_path.name}.",
    )


def main() -> int:
    """Run one watchdog cycle, printing only when there is something to report.

    Returns 0 unless the watchdog tried to act and could not; the producer treats
    a nonzero result as advisory and never fails its own refresh over it.
    """
    if os.environ.get("GRADUS_DISABLE_PUBLISHER_WATCHDOG") == "1":
        return 0
    decision = evaluate()
    if not decision.is_quiet:
        print(decision.message, flush=True)
    return 1 if decision.action in {"launch_failed", "app_missing"} else 0
