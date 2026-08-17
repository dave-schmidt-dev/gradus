"""Focused single-source producer and carried-window regressions."""

from contextlib import nullcontext
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from gradus.__main__ import (
    CLAUDE_MIN_PROBE_INTERVAL_SECONDS,
    CLAUDE_RATE_LIMIT_BACKOFF_SECONDS,
    _canonical_snapshots,
    _CanonicalClaudeCooldown,
    _claude_probe_is_due,
    _refresh_snapshot_once,
    main,
)
from gradus.providers import ProviderSnapshot
from gradus.snapshot import RATE_LIMIT_RETENTION_SECONDS, build_snapshot_v2_payload


def _claude(ok: bool, *, error: str | None = None) -> ProviderSnapshot:
    return ProviderSnapshot(
        name="Claude",
        ok=ok,
        source="api",
        error=error,
        data=None if not ok else {"session_percent_left": 80, "primary_reset": "Resets in 1h"},
    )


def test_rate_limit_retains_windows_fail_closed_and_carries_probe_attempt() -> None:
    now = datetime(2026, 8, 17, 18, 0, tzinfo=timezone.utc)
    healthy = build_snapshot_v2_payload([_claude(True)], now)
    limited_at = now + timedelta(seconds=400)
    limited = build_snapshot_v2_payload(
        [_claude(False, error="HTTP 429")], limited_at, prior=healthy
    )
    entry = next(item for item in limited["providers"] if item["name"] == "Claude")

    assert entry["ok"] is False
    assert entry["windows"]
    assert entry["probe_attempted_at"] == limited_at.isoformat()
    assert not _claude_probe_is_due(
        limited, limited_at + timedelta(seconds=CLAUDE_MIN_PROBE_INTERVAL_SECONDS - 1)
    )
    assert not _claude_probe_is_due(
        limited, limited_at + timedelta(seconds=CLAUDE_RATE_LIMIT_BACKOFF_SECONDS - 1)
    )
    assert _claude_probe_is_due(
        limited, limited_at + timedelta(seconds=CLAUDE_RATE_LIMIT_BACKOFF_SECONDS)
    )

    deferred = build_snapshot_v2_payload(
        [
            ProviderSnapshot(
                name="Claude",
                ok=False,
                source="snapshot",
                data=entry["data"],
                error="Claude probe cooldown; retaining canonical observation",
            )
        ],
        limited_at + timedelta(seconds=120),
        prior=limited,
    )
    deferred_entry = next(item for item in deferred["providers"] if item["name"] == "Claude")
    assert deferred_entry["ok"] is False
    assert deferred_entry["windows"]
    assert deferred_entry["probe_attempted_at"] == entry["probe_attempted_at"]
    assert RATE_LIMIT_RETENTION_SECONDS > CLAUDE_RATE_LIMIT_BACKOFF_SECONDS


def test_tui_hydrates_carried_transient_windows_as_cached_only() -> None:
    now = datetime(2026, 8, 17, 18, 0, tzinfo=timezone.utc)
    healthy = build_snapshot_v2_payload([_claude(True)], now)
    limited = build_snapshot_v2_payload(
        [_claude(False, error="HTTP 429")], now + timedelta(seconds=60), prior=healthy
    )
    hydrated = _canonical_snapshots(limited)
    assert hydrated is not None
    assert [snapshot.name for snapshot in hydrated[0]] == sorted(
        snapshot.name for snapshot in hydrated[0]
    )
    claude = next(snapshot for snapshot in hydrated[0] if snapshot.name == "Claude")
    assert claude.ok is True
    assert claude.error == "HTTP 429"
    assert claude.cached_since is not None
    assert claude.data and claude.data["session_percent_left"] == 80


def test_healthy_claude_cooldown_carries_success_unchanged() -> None:
    now = datetime(2026, 8, 17, 18, 0, tzinfo=timezone.utc)
    healthy = build_snapshot_v2_payload([_claude(True)], now)
    prior = next(item for item in healthy["providers"] if item["name"] == "Claude")
    deferred = build_snapshot_v2_payload(
        [_CanonicalClaudeCooldown(dict(prior["data"])).fetch()],
        now + timedelta(seconds=120),
        prior=healthy,
    )
    current = next(item for item in deferred["providers"] if item["name"] == "Claude")
    assert current["ok"] is True
    assert current["observed_at"] == prior["observed_at"]
    assert current["probe_attempted_at"] == prior["probe_attempted_at"]


def _live_namespace() -> SimpleNamespace:
    return SimpleNamespace(
        history_at=None,
        verify_refresh_health=False,
        refresh_snapshot=False,
        json=False,
        once=False,
        debug=False,
        providers=None,
        interval=1,
    )


class _FakeLive:
    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def update(self, *_args, **_kwargs):
        return None

    def refresh(self):
        return None


def test_live_automatic_interval_does_not_refresh_producer() -> None:
    stdin = SimpleNamespace(isatty=lambda: False)
    canonical = ([], datetime.now(timezone.utc))
    with (
        patch("gradus.__main__.parse_args", return_value=_live_namespace()),
        patch("gradus.__main__._setup_logging"),
        patch("gradus.__main__._load_config", return_value={}),
        patch("gradus.__main__.os.getcwd", return_value="."),
        patch("gradus.__main__.sys.stdin", stdin),
        patch("gradus.__main__._cbreak_mode", return_value=nullcontext()),
        patch("gradus.__main__.Live", return_value=_FakeLive()),
        patch("gradus.__main__._canonical_or_refresh", return_value=canonical),
        patch("gradus.__main__._read_canonical_snapshots", return_value=canonical),
        patch("gradus.__main__._snapshot_signature", return_value=(1, 1)),
        patch("gradus.__main__.build_dashboard"),
        patch("gradus.__main__.time.sleep", side_effect=KeyboardInterrupt),
        patch("gradus.__main__._refresh_snapshot_once") as refresh,
    ):
        assert main() == 0
    refresh.assert_not_called()


def test_live_explicit_r_submits_single_flight_producer() -> None:
    keys = iter(("r", "q"))
    stdin = SimpleNamespace(isatty=lambda: True, read=lambda _count: next(keys))
    canonical = ([], datetime.now(timezone.utc))
    with (
        patch("gradus.__main__.parse_args", return_value=_live_namespace()),
        patch("gradus.__main__._setup_logging"),
        patch("gradus.__main__._load_config", return_value={}),
        patch("gradus.__main__.os.getcwd", return_value="."),
        patch("gradus.__main__.sys.stdin", stdin),
        patch("gradus.__main__.select.select", return_value=([stdin], [], [])),
        patch("gradus.__main__._cbreak_mode", return_value=nullcontext()),
        patch("gradus.__main__.Live", return_value=_FakeLive()),
        patch("gradus.__main__._canonical_or_refresh", return_value=canonical),
        patch("gradus.__main__._read_canonical_snapshots", return_value=canonical),
        patch("gradus.__main__._snapshot_signature", return_value=(1, 1)),
        patch("gradus.__main__.build_dashboard"),
        patch("gradus.__main__._refresh_snapshot_once", return_value=0) as refresh,
    ):
        assert main() is None
    refresh.assert_called_once()


def test_producer_skips_claude_endpoint_during_cooldown() -> None:
    from pathlib import Path
    from tempfile import TemporaryDirectory

    with TemporaryDirectory() as tmp:
        state_dir = Path(tmp) / ".state"
        state_dir.mkdir()
        v1_path = state_dir / "snapshot.json"
        v2_path = state_dir / "snapshot-v2.json"
        committed: dict | None = None

        def read(path: Path | None = None):
            if path is not None and path.name == "snapshot-v2.json":
                return committed
            return None

        def write(payload: dict, *_args, **_kwargs):
            nonlocal committed
            if payload["schema_version"] == 2:
                committed = payload
            from gradus.snapshot import SnapshotWrite

            return SnapshotWrite.WRITTEN

        healthy = _claude(True)
        with (
            patch("gradus.__main__.SNAPSHOT_PATH", v1_path),
            patch("gradus.__main__.SNAPSHOT_V2_PATH", v2_path),
            patch("gradus.__main__._snapshot_state_dir", return_value=state_dir),
            patch(
                "gradus.__main__.initialize_providers", return_value=([("Claude", MagicMock())], [])
            ),
            patch("gradus.__main__.fetch_provider_snapshot", return_value=healthy) as fetch,
            patch("gradus.__main__.read_prior_snapshot", side_effect=read),
            patch("gradus.__main__.write_snapshot", side_effect=write),
            patch("gradus.__main__.append_history_record", return_value=True),
            patch("gradus.__main__._refresh_progress"),
        ):
            assert _refresh_snapshot_once(tmp, None, False) == 0
            first = next(item for item in committed["providers"] if item["name"] == "Claude")
            assert _refresh_snapshot_once(tmp, None, False) == 0
            second = next(item for item in committed["providers"] if item["name"] == "Claude")

        fetch.assert_called_once()
        assert second["ok"] is True
        assert second["observed_at"] == first["observed_at"]
        assert second["probe_attempted_at"] == first["probe_attempted_at"]
