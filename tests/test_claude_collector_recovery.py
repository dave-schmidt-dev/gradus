"""Regression coverage for retrying Claude after legacy producer recovery."""

from __future__ import annotations

import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from io import StringIO
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import gradus.__main__ as main_module
import gradus.snapshot as snapshot
from gradus.providers import ProviderSnapshot
from gradus.snapshot import build_snapshot_v2_payload

BASE = datetime(2026, 10, 2, 12, tzinfo=timezone.utc)


def _claude_payload(error: str, *, attempted_at: str | None = None) -> dict[str, object]:
    return {
        "schema_version": 2,
        "updated_at": BASE.isoformat(),
        "providers": [
            {
                "name": "Claude",
                "ok": False,
                "error": error,
                "data": {},
                "windows": [],
                "observed_at": None,
                "probe_attempted_at": attempted_at,
            }
        ],
    }


class ClaudeCollectorRecoveryTests(unittest.TestCase):
    def test_legacy_claude_marker_is_due_with_or_without_probe_timestamp(self) -> None:
        marker = snapshot.LEGACY_CLAUDE_UNAVAILABLE_ERROR
        for attempted_at in (None, BASE.isoformat()):
            with self.subTest(attempted_at=attempted_at):
                payload = _claude_payload(marker, attempted_at=attempted_at)
                now = BASE + timedelta(seconds=10)
                self.assertEqual(main_module._provider_next_probe_at(payload, "Claude", now), now)

    def test_real_claude_failures_keep_normal_and_rate_limit_backoff(self) -> None:
        now = BASE + timedelta(seconds=10)
        failed = _claude_payload("HTTP 500 provider error", attempted_at=BASE.isoformat())
        auth = _claude_payload("Claude Code session expired", attempted_at=BASE.isoformat())
        limited = _claude_payload("HTTP 429 rate limited", attempted_at=BASE.isoformat())
        self.assertEqual(
            main_module._provider_next_probe_at(failed, "Claude", now),
            BASE + timedelta(seconds=600),
        )
        self.assertEqual(
            main_module._provider_next_probe_at(auth, "Claude", now),
            BASE + timedelta(seconds=600),
        )
        self.assertEqual(
            main_module._provider_next_probe_at(limited, "Claude", now),
            BASE + timedelta(seconds=3600),
        )

    def test_local_credential_failure_is_due_immediately(self) -> None:
        payload = _claude_payload(
            "Claude Code OAuth credentials unavailable "
            "(keychain item has no access token): run `claude auth login`",
            attempted_at=BASE.isoformat(),
        )
        now = BASE + timedelta(seconds=10)
        self.assertEqual(main_module._provider_next_probe_at(payload, "Claude", now), now)

    def test_uncertain_legacy_claude_then_inactive_probes_and_recovers(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp) / "Installed"
            state_dir.mkdir()
            provider = MagicMock()
            prior: dict[str, object] | None = None
            committed: list[dict[str, object]] = []
            initialized: list[set[str] | None] = []

            def initialize(_cwd: str, enabled: set[str] | None, **_kwargs: object):
                initialized.append(enabled)
                return (
                    ([("Claude", provider)], [])
                    if enabled is None or "Claude" in enabled
                    else ([], [])
                )

            def write_versions(snapshots: list[ProviderSnapshot], when: datetime, **kwargs: object):
                nonlocal prior
                prior = build_snapshot_v2_payload(
                    snapshots,
                    when,
                    projected_claude_entry=kwargs.get("projected_claude_entry"),
                )
                committed.append(prior)
                return True, True, True

            def read_prior(path: Path | None = None):
                return prior if path == main_module.SNAPSHOT_V2_PATH else None

            with (
                patch(
                    "gradus.__main__.RUNTIME_PATHS",
                    SimpleNamespace(mode=main_module.INSTALLED_MODE, public_state_root=state_dir),
                ),
                patch("gradus.__main__._snapshot_state_dir", return_value=state_dir),
                patch(
                    "gradus.__main__._legacy_claude_ownership",
                    side_effect=(
                        main_module._LegacyClaudeOwnership.UNCERTAIN,
                        main_module._LegacyClaudeOwnership.INACTIVE,
                    ),
                ),
                patch.dict("gradus.__main__._PROVIDER_REGISTRY", {"Claude": object}, clear=True),
                patch("gradus.__main__.initialize_providers", side_effect=initialize),
                patch("gradus.__main__.read_prior_snapshot", side_effect=read_prior),
                patch(
                    "gradus.__main__.fetch_provider_snapshot",
                    return_value=ProviderSnapshot(name="Claude", ok=True, source="api", data={}),
                ) as fetch,
                patch("gradus.__main__.set_headless"),
                patch("gradus.__main__._write_snapshot_versions", side_effect=write_versions),
                patch("gradus.__main__.sys.stderr", StringIO()),
            ):
                self.assertEqual(main_module._refresh_snapshot_once(tmp, None, False), 0)
                first_claude = next(
                    item for item in committed[0]["providers"] if item["name"] == "Claude"
                )
                self.assertEqual(first_claude["error"], snapshot.LEGACY_CLAUDE_UNAVAILABLE_ERROR)
                self.assertIsNone(first_claude["probe_attempted_at"])
                self.assertEqual(main_module._refresh_snapshot_once(tmp, None, False), 0)

            self.assertEqual(initialized[0], set())  # Claude excluded while ownership is uncertain
            self.assertEqual(initialized[1], None)
            fetch.assert_called_once_with("Claude", provider, False)
            recovered = next(item for item in committed[1]["providers"] if item["name"] == "Claude")
            self.assertTrue(recovered["ok"])
            self.assertIsNone(recovered["error"])

    def test_active_legacy_claude_still_suppresses_direct_probe(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp) / "Installed"
            state_dir.mkdir()
            with (
                patch(
                    "gradus.__main__.RUNTIME_PATHS",
                    SimpleNamespace(mode=main_module.INSTALLED_MODE, public_state_root=state_dir),
                ),
                patch("gradus.__main__._snapshot_state_dir", return_value=state_dir),
                patch(
                    "gradus.__main__._legacy_claude_ownership",
                    return_value=main_module._LegacyClaudeOwnership.ACTIVE,
                ),
                patch.dict("gradus.__main__._PROVIDER_REGISTRY", {"Claude": object}, clear=True),
                patch("gradus.__main__.initialize_providers", return_value=([], [])),
                patch("gradus.__main__.read_prior_snapshot", return_value=None),
                patch("gradus.__main__.fetch_provider_snapshot") as fetch,
                patch("gradus.__main__.set_headless"),
                patch(
                    "gradus.__main__._write_snapshot_versions", return_value=(True, True, True)
                ) as write,
                patch("gradus.__main__.sys.stderr", StringIO()),
            ):
                self.assertEqual(main_module._refresh_snapshot_once(tmp, None, False), 0)

            fetch.assert_not_called()
            self.assertEqual(
                write.call_args.kwargs["projected_claude_entry"]["error"],
                snapshot.LEGACY_CLAUDE_UNAVAILABLE_ERROR,
            )
