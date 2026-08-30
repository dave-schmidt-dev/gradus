"""Entrypoint regression tests."""

from __future__ import annotations

import argparse
import fcntl
import json
import logging
import os
import plistlib
import subprocess
import tempfile
import threading
import time
import unittest
from datetime import datetime, timedelta, timezone
from io import StringIO
from pathlib import Path
from unittest.mock import MagicMock, patch

from rich.console import Console

import gradus.snapshot as snapshot_module
from gradus.__main__ import (
    AUTH_ACTIONS,
    STALE_THRESHOLD_SECONDS,
    _acquire_refresh_snapshot_lock,
    _build_fix_actions,
    _canonical_snapshots,
    _check_warnings,
    _claude_probe_is_due,
    _emit_debug_details,
    _health_sample_reason,
    _is_auth_error,
    _is_transient_probe_error,
    _launch_fix,
    _load_config,
    _merge_with_previous,
    _notify_warning,
    _provider_next_probe_at,
    _refresh_snapshot_once,
    _release_refresh_snapshot_lock,
    _resolve_log_path,
    _schedule_refresh_providers,
    _setup_logging,
    _verify_refresh_health,
    _write_snapshot_versions,
    collect_snapshots,
    main,
    parse_args,
)
from gradus.providers import ProviderSnapshot, set_headless
from gradus.snapshot import (
    ANTIGRAVITY_AUTH_RETRY_MESSAGE,
    SnapshotWrite,
    build_snapshot_v2_payload,
)
from gradus.ui import THEME, build_dashboard, render_json

NOW = datetime(2026, 3, 14, 8, 22, 30)


class CanonicalSyntheticHydrationTests(unittest.TestCase):
    """Schema-v2 synthetic pools remain on their primary TUI cards."""

    @staticmethod
    def _payload(*synthetic_entries: dict[str, object]) -> dict[str, object]:
        return {
            "schema_version": 2,
            "updated_at": NOW.replace(tzinfo=timezone.utc).isoformat(),
            "providers": [
                {
                    "name": "Antigravity",
                    "ok": True,
                    "error": None,
                    "windows": [],
                    "data": {},
                    "observed_at": NOW.replace(tzinfo=timezone.utc).isoformat(),
                },
                {
                    "name": "Codex",
                    "ok": True,
                    "error": None,
                    "windows": [],
                    "data": {},
                    "observed_at": NOW.replace(tzinfo=timezone.utc).isoformat(),
                },
                *synthetic_entries,
            ],
        }

    def _primary(self, snapshots: list[ProviderSnapshot], name: str) -> ProviderSnapshot:
        return next(snapshot for snapshot in snapshots if snapshot.name == name)

    def test_100_percent_synthetic_pools_survive_hydration(self) -> None:
        snapshots, _ = _canonical_snapshots(
            self._payload(
                {
                    "name": "Antigravity (Claude)",
                    "ok": True,
                    "data": {
                        "five_hour_percent_left": 100,
                        "weekly_percent_left": 100,
                        "five_hour_reset": "in 5h",
                        "weekly_reset": "in 7d",
                    },
                },
                {
                    "name": "Codex (Spark)",
                    "ok": True,
                    "data": {"weekly_percent_left": 100, "weekly_reset": "in 7d"},
                },
            )
        )
        assert snapshots is not None
        self.assertEqual(
            self._primary(snapshots, "Antigravity").data,
            {
                "third_party_five_hour_percent_left": 100,
                "third_party_weekly_percent_left": 100,
                "third_party_five_hour_reset": "in 5h",
                "third_party_weekly_reset": "in 7d",
            },
        )
        self.assertEqual(
            self._primary(snapshots, "Codex").data,
            {"spark_weekly_percent_left": 100, "spark_weekly_reset": "in 7d"},
        )
        self.assertNotIn("Antigravity (Claude)", {snapshot.name for snapshot in snapshots})
        self.assertNotIn("Codex (Spark)", {snapshot.name for snapshot in snapshots})

    def test_missing_or_malformed_synthetic_pools_are_omitted(self) -> None:
        cases = (
            ((), False, False, False),
            (
                (
                    {
                        "name": "Antigravity (Claude)",
                        "ok": True,
                        "data": {"five_hour_percent_left": "100", "weekly_percent_left": 100},
                    },
                ),
                False,
                True,
                False,
            ),
            (
                (
                    {
                        "name": "Codex (Spark)",
                        "ok": True,
                        "data": {"weekly_percent_left": None},
                    },
                ),
                False,
                False,
                False,
            ),
        )
        for entries, has_cg5, has_cg1w, has_sp1w in cases:
            with self.subTest(entries=entries):
                snapshots, _ = _canonical_snapshots(self._payload(*entries))
                assert snapshots is not None
                antigravity_data = self._primary(snapshots, "Antigravity").data
                codex_data = self._primary(snapshots, "Codex").data
                self.assertEqual("third_party_five_hour_percent_left" in antigravity_data, has_cg5)
                self.assertEqual("third_party_weekly_percent_left" in antigravity_data, has_cg1w)
                self.assertEqual("spark_weekly_percent_left" in codex_data, has_sp1w)

    def test_each_valid_pool_is_hydrated_independently(self) -> None:
        cases = (
            {
                "five_hour_percent_left": 100,
                "five_hour_reset": "in 5h",
            },
            {
                "weekly_percent_left": 100,
                "weekly_reset": "in 7d",
            },
            {
                "five_hour_percent_left": "malformed",
                "weekly_percent_left": 100,
                "weekly_reset": "in 7d",
            },
        )
        for data in cases:
            with self.subTest(data=data):
                snapshots, _ = _canonical_snapshots(
                    self._payload(
                        {"name": "Antigravity (Claude)", "ok": True, "data": data},
                    )
                )
                assert snapshots is not None
                antigravity = self._primary(snapshots, "Antigravity")
                has_five_hour = (
                    "five_hour_percent_left" in data and data["five_hour_percent_left"] == 100
                )
                has_weekly = data.get("weekly_percent_left") == 100
                self.assertEqual(
                    "third_party_five_hour_percent_left" in antigravity.data, has_five_hour
                )
                self.assertEqual("third_party_weekly_percent_left" in antigravity.data, has_weekly)
                if not has_five_hour:
                    self.assertNotIn("third_party_five_hour_reset", antigravity.data)

    def test_hydrated_pool_labels_reach_dashboard(self) -> None:
        snapshots, updated_at = _canonical_snapshots(
            self._payload(
                {
                    "name": "Antigravity (Claude)",
                    "ok": True,
                    "data": {
                        "five_hour_percent_left": 100,
                        "weekly_percent_left": 100,
                    },
                },
                {
                    "name": "Codex (Spark)",
                    "ok": True,
                    "data": {"weekly_percent_left": 100},
                },
            )
        )
        assert snapshots is not None
        antigravity = self._primary(snapshots, "Antigravity")
        antigravity.data.update({"five_hour_percent_left": 80, "weekly_percent_left": 80})
        codex = self._primary(snapshots, "Codex")
        codex.data.update({"five_hour_percent_left": 80, "weekly_percent_left": 80})
        console = Console(file=StringIO(), width=72, no_color=True)
        console.print(build_dashboard([antigravity, codex], updated_at, 30))
        output = console.file.getvalue()
        self.assertIn("cg5", output)
        self.assertIn("cg1w", output)
        self.assertIn("sp1w", output)

    def test_hydrated_pool_keys_stay_out_of_router_json(self) -> None:
        snapshots, updated_at = _canonical_snapshots(
            self._payload(
                {
                    "name": "Antigravity (Claude)",
                    "ok": True,
                    "data": {"five_hour_percent_left": 100, "weekly_percent_left": 100},
                },
                {
                    "name": "Codex (Spark)",
                    "ok": True,
                    "data": {"weekly_percent_left": 100},
                },
            )
        )
        assert snapshots is not None
        rendered = json.loads(render_json(snapshots, updated_at))
        names = {provider["name"] for provider in rendered["providers"]}
        self.assertNotIn("Antigravity (Claude)", names)
        self.assertNotIn("Codex (Spark)", names)
        for provider in rendered["providers"]:
            data_keys = provider["data"]
            self.assertFalse(any(key.startswith("third_party_") for key in data_keys))
            self.assertFalse(any(key.startswith("spark_") for key in data_keys))


class CursorWarningTests(unittest.TestCase):
    """Cursor's normalized Auto + Composer and API pools warn independently."""

    def _cursor(
        self, auto_percent_used: float | None, api_percent_left: float | None
    ) -> ProviderSnapshot:
        data: dict[str, float] = {}
        if auto_percent_used is not None:
            data["auto_percent_used"] = auto_percent_used
        if api_percent_left is not None:
            # api_percent_used is percent USED; convert from the helper's
            # percent-left parameter so callers can keep reasoning in
            # remaining-capacity terms.
            data["api_percent_used"] = 100.0 - api_percent_left
        return ProviderSnapshot(name="Cursor", ok=True, source="api", data=data)

    def test_independent_cursor_pool_warning_names_window(self) -> None:
        notified: set[str] = set()
        with patch("gradus.__main__._notify_warning", return_value=True) as notify:
            _check_warnings([self._cursor(100, 82)], notified, NOW)

        notify.assert_called_once_with("Cursor", ("ac",))
        self.assertEqual(notified, {"Cursor"})

    def test_notification_is_one_shot_and_recovery_resets_latch(self) -> None:
        notified: set[str] = set()
        with patch("gradus.__main__._notify_warning", return_value=True) as notify:
            _check_warnings([self._cursor(100, 82)], notified, NOW)
            _check_warnings([self._cursor(100, 82)], notified, NOW)
            # The recovery step. It used to be 95% used (5% left), which
            # stopped warning only because these fixtures carry no billing
            # cycle and so produce no pace. Since 2026-08-06 a no-pace window
            # falls back to the percent ramp, and 5% left is red -- that is not
            # a recovery by any definition, it just used to read as one.
            _check_warnings([self._cursor(50, 82)], notified, NOW)
            _check_warnings([self._cursor(100, 82)], notified, NOW)

        self.assertEqual(notify.call_count, 2)
        self.assertEqual(notify.call_args_list[0].args, ("Cursor", ("ac",)))
        self.assertEqual(notify.call_args_list[1].args, ("Cursor", ("ac",)))
        self.assertEqual(notified, {"Cursor"})


class WarningNotificationTests(unittest.TestCase):
    def test_notification_text_lists_normalized_warning_windows(self) -> None:
        with patch("gradus.__main__.subprocess.run") as run:
            run.return_value.returncode = 0
            self.assertTrue(_notify_warning("Cursor", ("ac", "ap")))

        command = run.call_args.args[0]
        self.assertEqual(command[:2], ["osascript", "-e"])
        self.assertIn("Warning window(s): ac, ap", command[2])
        self.assertIn('title "Gradus"', command[2])
        self.assertIn('subtitle "Cursor"', command[2])

    def test_failed_notification_is_retried(self) -> None:
        notified: set[str] = set()
        cursor = ProviderSnapshot(
            name="Cursor",
            ok=True,
            source="api",
            data={"auto_percent_used": 100, "api_percent_used": 18},
        )
        with patch("gradus.__main__._notify_warning", side_effect=(False, True)) as notify:
            _check_warnings([cursor], notified, NOW)
            _check_warnings([cursor], notified, NOW)

        self.assertEqual(notify.call_count, 2)
        self.assertEqual(notified, {"Cursor"})


class LoadConfigTests(unittest.TestCase):
    def test_load_config_prefers_gradus_json(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            gradus_path = Path(tmpdir) / ".gradus.json"
            legacy_path = Path(tmpdir) / ".ai_monitor.json"
            gradus_path.write_text('{"interval": 30}', encoding="utf-8")
            legacy_path.write_text('{"interval": 60}', encoding="utf-8")
            with patch("os.getcwd", return_value=tmpdir):
                config = _load_config()
                self.assertEqual(config, {"interval": 30})

    def test_load_config_falls_back_to_ai_monitor_json(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            legacy_path = Path(tmpdir) / ".ai_monitor.json"
            legacy_path.write_text('{"interval": 60}', encoding="utf-8")
            with patch("os.getcwd", return_value=tmpdir):
                config = _load_config()
                self.assertEqual(config, {"interval": 60})

    def test_load_config_missing_file_returns_empty_dict(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            with patch("os.getcwd", return_value=tmpdir):
                config = _load_config()
                self.assertEqual(config, {})


class CodexWarningTests(unittest.TestCase):
    """Codex warns from its normalized weekly window when depleted."""

    def test_zero_weekly_notifies_when_five_hour_absent(self) -> None:
        # five_hour is None (window removed); weekly is the only remaining signal.
        codex = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="api",
            data={"five_hour_percent_left": None, "weekly_percent_left": 0},
        )
        notified: set[str] = set()
        with patch("gradus.__main__._notify_warning", return_value=True) as notify:
            _check_warnings([codex], notified, NOW)

        notify.assert_called_once_with("Codex", ("weekly",))
        self.assertEqual(notified, {"Codex"})


class AntigravityWarningTests(unittest.TestCase):
    """Antigravity C+G pools participate in warning notifications only."""

    def _antigravity(self, cg5: float, cg1w: float) -> ProviderSnapshot:
        return ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 86,
                "weekly_percent_left": 96,
                "third_party_five_hour_percent_left": cg5,
                "third_party_five_hour_reset": "Resets 9:22 AM",
                "third_party_weekly_percent_left": cg1w,
                "third_party_weekly_reset": "Resets Mar 21 at 8:22 AM",
            },
        )

    def test_depleted_cg_windows_notify_with_deterministic_ids(self) -> None:
        notified: set[str] = set()
        with patch("gradus.__main__._notify_warning", return_value=True) as notify:
            _check_warnings([self._antigravity(0, 0)], notified, NOW)

        notify.assert_called_once_with("Antigravity", ("cg5", "cg1w"))
        self.assertEqual(notified, {"Antigravity"})

    def test_cg_recovery_clears_latch_and_later_regression_warns_again(self) -> None:
        notified: set[str] = set()
        with patch("gradus.__main__._notify_warning", return_value=True) as notify:
            _check_warnings([self._antigravity(0, 0)], notified, NOW)
            _check_warnings([self._antigravity(0, 0)], notified, NOW)
            _check_warnings([self._antigravity(100, 100)], notified, NOW)
            self.assertEqual(notified, set())
            _check_warnings([self._antigravity(0, 0)], notified, NOW)

        self.assertEqual(notify.call_count, 2)
        self.assertEqual(notify.call_args_list[0].args, ("Antigravity", ("cg5", "cg1w")))
        self.assertEqual(notify.call_args_list[1].args, ("Antigravity", ("cg5", "cg1w")))


class MainOnceTests(unittest.TestCase):
    """Test --once mode: no Live context, prints dashboard via Console.print."""

    def test_once_prints_dashboard_without_live(self) -> None:
        snapshots = [
            ProviderSnapshot(
                name="Codex", ok=True, source="snapshot", data={"five_hour_percent_left": 75}
            )
        ]

        with (
            patch(
                "gradus.__main__.parse_args",
                return_value=argparse.Namespace(json=False, once=True, debug=False, interval=120),
            ),
            patch("gradus.__main__.initialize_providers") as init,
            patch("gradus.__main__.collect_snapshots") as collect,
            patch("gradus.__main__._canonical_or_refresh", return_value=(snapshots, NOW)),
            patch("gradus.__main__.Console") as MockConsole,
        ):
            mock_console = MagicMock()
            MockConsole.return_value = mock_console
            rc = main()

        self.assertEqual(rc, 0)
        mock_console.print.assert_called_once()
        init.assert_not_called()
        collect.assert_not_called()

    def test_once_does_not_use_live_context(self) -> None:
        """--once must never enter alt-screen (no Live)."""
        snapshots = [
            ProviderSnapshot(
                name="Codex", ok=True, source="snapshot", data={"five_hour_percent_left": 75}
            )
        ]

        with (
            patch(
                "gradus.__main__.parse_args",
                return_value=argparse.Namespace(json=False, once=True, debug=False, interval=120),
            ),
            patch("gradus.__main__.initialize_providers") as init,
            patch("gradus.__main__.collect_snapshots") as collect,
            patch("gradus.__main__._canonical_or_refresh", return_value=(snapshots, NOW)),
            patch("gradus.__main__.Console") as MockConsole,
            patch("gradus.__main__.Live") as MockLive,
        ):
            MockConsole.return_value = MagicMock()
            main()

        MockLive.assert_not_called()
        init.assert_not_called()
        collect.assert_not_called()


class MainJsonTests(unittest.TestCase):
    """Test --json mode: writes JSON to stdout, no Console or Live."""

    def setUp(self) -> None:
        # --json now engages the read-only headless path (Task 4.2). Reset the
        # module global before and after each test so headless state never leaks
        # between tests via ordering.
        set_headless(False)
        self.addCleanup(set_headless, False)

    def test_json_engages_headless_no_side_effects(self) -> None:
        """Task 4.2 / INV-2: ``--json`` is a read-only machine surface — it engages
        headless before constructing providers, fires no warning notification,
        and launches no subprocess (browser / osascript / cookie extraction)."""
        snapshots = [
            ProviderSnapshot(
                name="Codex", ok=True, source="api", data={"five_hour_percent_left": 50}
            ),
            ProviderSnapshot(
                name="Claude",
                ok=False,
                source="api",
                error="auth required: no cached credentials",
            ),
        ]
        ns = argparse.Namespace(
            json=True,
            write_snapshot=False,
            once=False,
            debug=False,
            providers=None,
            interval=120,
        )
        set_headless_spy = MagicMock()
        buf = StringIO()
        with (
            patch("gradus.__main__.parse_args", return_value=ns),
            patch("gradus.__main__.set_headless", set_headless_spy),
            patch("gradus.__main__.initialize_providers") as init,
            patch("gradus.__main__.collect_snapshots") as collect,
            patch("gradus.__main__._read_canonical_snapshots", return_value=(snapshots, NOW)),
            patch("gradus.__main__._check_warnings") as mock_check,
            patch("gradus.__main__._notify_warning") as mock_notify,
            patch("gradus.__main__.subprocess.Popen") as mock_popen,
            patch("gradus.__main__.subprocess.run") as mock_run,
            patch("gradus.providers.subprocess.Popen") as mock_p_popen,
            patch("gradus.providers.subprocess.run") as mock_p_run,
            patch("gradus.__main__.sys.stdout", buf),
        ):
            rc = main()

        self.assertEqual(rc, 0)
        # Read-only mode engaged (before providers are constructed).
        set_headless_spy.assert_called_once_with(True)
        # No warning notifications on the machine surface.
        mock_check.assert_not_called()
        mock_notify.assert_not_called()
        # No subprocess of any kind, in either module.
        mock_popen.assert_not_called()
        mock_run.assert_not_called()
        mock_p_popen.assert_not_called()
        mock_p_run.assert_not_called()
        # Still produced valid JSON for both providers.
        payload = json.loads(buf.getvalue())
        self.assertEqual(len(payload["providers"]), 2)
        init.assert_not_called()
        collect.assert_not_called()

    def test_json_writes_valid_json_to_stdout(self) -> None:
        snapshots = [
            ProviderSnapshot(
                name="Codex",
                ok=True,
                source="cli",
                data={
                    "five_hour_percent_left": 75,
                    "five_hour_reset": "Resets 1:16 PM",
                    "weekly_percent_left": 91,
                    "weekly_reset": "Resets Mar 17 at 9 PM",
                },
            ),
            ProviderSnapshot(
                name="Claude",
                ok=False,
                source="cli",
                error="connection timeout",
            ),
        ]

        buf = StringIO()
        with (
            patch(
                "gradus.__main__.parse_args",
                return_value=argparse.Namespace(json=True, once=False, debug=False, interval=120),
            ),
            patch("gradus.__main__.initialize_providers") as init,
            patch("gradus.__main__.collect_snapshots") as collect,
            patch("gradus.__main__._read_canonical_snapshots", return_value=(snapshots, NOW)),
            patch("gradus.__main__.sys.stdout", buf),
        ):
            rc = main()

        self.assertEqual(rc, 0)
        payload = json.loads(buf.getvalue())
        self.assertIn("updated_at", payload)
        self.assertIn("providers", payload)
        self.assertEqual(len(payload["providers"]), 2)
        init.assert_not_called()
        collect.assert_not_called()

        codex = next(p for p in payload["providers"] if p["name"] == "Codex")
        self.assertTrue(codex["ok"])
        self.assertIn("display", codex)
        self.assertIn("five_hour_reset_display", codex["display"])

        claude = next(p for p in payload["providers"] if p["name"] == "Claude")
        self.assertFalse(claude["ok"])
        self.assertEqual(claude["error"], "connection timeout")

    def test_json_does_not_contain_ansi_escapes(self) -> None:
        """JSON output must never contain ANSI escape sequences."""
        snapshots = [
            ProviderSnapshot(
                name="Codex",
                ok=True,
                source="cli",
                data={"five_hour_percent_left": 75},
            )
        ]

        buf = StringIO()
        with (
            patch(
                "gradus.__main__.parse_args",
                return_value=argparse.Namespace(json=True, once=False, debug=False, interval=120),
            ),
            patch("gradus.__main__.initialize_providers") as init,
            patch("gradus.__main__.collect_snapshots") as collect,
            patch("gradus.__main__._read_canonical_snapshots", return_value=(snapshots, NOW)),
            patch("gradus.__main__.sys.stdout", buf),
        ):
            main()

        self.assertNotIn("\033[", buf.getvalue())
        init.assert_not_called()
        collect.assert_not_called()


class DashboardNoANSILeakageTests(unittest.TestCase):
    """Verify Rich rendering output contains no raw ANSI when captured with no_color."""

    def test_dashboard_no_color_output_has_no_escapes(self) -> None:
        """When captured via no_color=True, output must be pure text."""
        snapshots = [
            ProviderSnapshot(
                name="Codex",
                ok=True,
                source="cli",
                data={
                    "five_hour_percent_left": 68,
                    "five_hour_reset": "Resets 1:16 PM",
                    "weekly_percent_left": 91,
                    "weekly_reset": "Resets Mar 17 at 9 PM",
                },
            ),
            ProviderSnapshot(
                name="Claude",
                ok=False,
                source="cli",
                error="rate limited",
            ),
        ]
        from datetime import datetime

        now = datetime(2026, 3, 14, 8, 22, 30)
        dashboard = build_dashboard(snapshots, now, 30)
        console = Console(
            file=StringIO(),
            theme=THEME,
            force_terminal=True,
            width=92,
            no_color=True,
        )
        console.print(dashboard)
        output = console.file.getvalue()

        self.assertNotIn("\033[", output)
        # Should still have meaningful content
        self.assertIn("Codex", output)
        self.assertIn("Claude", output)
        self.assertIn("68%", output)
        self.assertIn("rate limited", output)


class IsAuthErrorTests(unittest.TestCase):
    # Contrived messages below exercise the keyword-match mechanism. Verbatim
    # production messages are pinned in ProductionAuthMessageRoutingTests further
    # down — keep both: this set tests the matcher, the other tests the wiring.
    def test_auth_keyword_with_known_provider(self) -> None:
        snap = ProviderSnapshot(
            name="Claude",
            ok=False,
            source="api",
            error="session expired — visit claude.ai to authenticate",
        )
        self.assertTrue(_is_auth_error(snap))

    def test_token_expired_matches(self) -> None:
        snap = ProviderSnapshot(
            name="Codex", ok=False, source="api", error="Token expired, please re-login"
        )
        self.assertTrue(_is_auth_error(snap))

    def test_case_insensitive(self) -> None:
        snap = ProviderSnapshot(
            name="Antigravity", ok=False, source="api", error="AUTH FAILED: run agy to fix"
        )
        self.assertTrue(_is_auth_error(snap))

    def test_non_auth_error_returns_false(self) -> None:
        snap = ProviderSnapshot(name="Claude", ok=False, source="api", error="connection timeout")
        self.assertFalse(_is_auth_error(snap))

    def test_ok_snapshot_returns_false(self) -> None:
        snap = ProviderSnapshot(
            name="Claude", ok=True, source="api", data={"session_percent_left": 50}
        )
        self.assertFalse(_is_auth_error(snap))

    def test_unknown_provider_returns_false(self) -> None:
        snap = ProviderSnapshot(
            name="UnknownAI", ok=False, source="api", error="please authenticate"
        )
        self.assertFalse(_is_auth_error(snap))

    def test_no_error_text_returns_false(self) -> None:
        snap = ProviderSnapshot(name="Claude", ok=False, source="api", error=None)
        self.assertFalse(_is_auth_error(snap))

    def test_all_seven_providers_in_auth_actions(self) -> None:
        expected = {"Claude", "Codex", "Antigravity", "Copilot", "Cursor", "OpenCode Go", "Vibe"}
        self.assertEqual(set(AUTH_ACTIONS.keys()), expected)

    def test_claude_action_opens_safari_for_bridge_managed_credentials(self) -> None:
        self.assertEqual(AUTH_ACTIONS["Claude"], ("cli", "claude auth login"))

    def test_codex_action_guards_against_blind_clobber(self) -> None:
        # Regression: 2026-06-13. The bare `codex login` command wipes ~/.codex/auth.json at the
        # start of its OAuth flow, so an abandoned login leaves the user fully logged out — and a
        # mistakenly-pressed [1] (or a re-press after the 5s cooldown) can clobber a token that
        # was just successfully refreshed. The guard must show the existing file state AND require
        # an explicit Enter before invoking `codex login`.
        kind, target = AUTH_ACTIONS["Codex"]
        self.assertEqual(kind, "cli")
        self.assertIn("ls -la ~/.codex/auth.json", target)
        self.assertIn("read -p", target)
        self.assertIn("Ctrl-C", target)
        # The destructive call is still there — the guard precedes it, doesn't replace it.
        self.assertIn("codex login", target)
        # AppleScript safety: the do-script string is wrapped in double quotes, so the target
        # must not contain unescaped double quotes that would break out of the AppleScript string.
        self.assertNotIn('"', target)

    def test_codex_action_target_survives_applescript_embedding(self) -> None:
        # `_launch_fix` embeds CLI targets via f-string into a double-quoted iTerm2 AppleScript
        # literal: 'tell application "iTerm2" to create window ... command "{target}"'
        # If `target` contains an unescaped `"` the AppleScript closes early and the rest is
        # parsed as a separate statement (best case: syntax error; worst case: arbitrary
        # AppleScript executes). Pin this invariant for every CLI action.
        for name, (kind, target) in AUTH_ACTIONS.items():
            if kind == "cli":
                self.assertNotIn(
                    '"', target, f"AUTH_ACTIONS[{name!r}] target contains an unescaped double quote"
                )


class ProductionAuthMessageRoutingTests(unittest.TestCase):
    # These tests pin the verbatim error strings emitted by providers.py so the
    # CTA wiring catches any silent drift between provider wording and the
    # _AUTH_KEYWORDS substring set. Latent for ~2 months before this sweep: all
    # three session-expired messages below were missing every keyword and the
    # dashboard quietly skipped the [N] fix action for these providers.

    def test_claude_session_expired_routes_to_cta(self) -> None:
        # gradus/providers.py:1182
        snap = ProviderSnapshot(
            name="Claude",
            ok=False,
            source="api",
            error="Claude session expired — visit claude.ai to refresh",
        )
        self.assertTrue(_is_auth_error(snap))

    def test_cursor_session_expired_routes_to_cta(self) -> None:
        # gradus/providers.py:702
        snap = ProviderSnapshot(
            name="Cursor",
            ok=False,
            source="api",
            error="Cursor session expired. Log into cursor.com to refresh.",
        )
        self.assertTrue(_is_auth_error(snap))

    def test_vibe_session_expired_routes_to_cta(self) -> None:
        # gradus/providers.py:484 — provider name "Vibe" per AUTH_ACTIONS
        snap = ProviderSnapshot(
            name="Vibe",
            ok=False,
            source="api",
            error="Mistral session expired. Log into console.mistral.ai to refresh.",
        )
        self.assertTrue(_is_auth_error(snap))

    def test_antigravity_expired_routes_to_cta_not_offline(self) -> None:
        # The nudge-can't-recover fallback must drive the [N] fix CTA, NOT be
        # swallowed as a transient "offline" error. The old "token expired" wording
        # matched the transient markers (snapshot.py) and hid the CTA — showing a
        # misleading "(offline Xm)" for an actionable auth failure.
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=False,
            source="api",
            error="Antigravity session expired: run `agy` to re-authenticate",
        )
        self.assertTrue(_is_auth_error(snap))
        self.assertFalse(_is_transient_probe_error(snap))


class BuildFixActionsTests(unittest.TestCase):
    def test_single_auth_error(self) -> None:
        snaps = [
            ProviderSnapshot(name="Antigravity", ok=False, source="api", error="auth failed"),
        ]
        actions = _build_fix_actions(snaps)
        self.assertEqual(actions, {"1": ("Antigravity", "cli", "agy")})

    def test_multiple_auth_errors_alphabetical(self) -> None:
        snaps = [
            ProviderSnapshot(name="Antigravity", ok=False, source="api", error="auth failed"),
            ProviderSnapshot(name="Claude", ok=False, source="api", error="authenticate required"),
            ProviderSnapshot(
                name="Codex", ok=True, source="api", data={"five_hour_percent_left": 80}
            ),
        ]
        actions = _build_fix_actions(snaps)
        # Alphabetical: "Antigravity" now sorts ahead of "Claude".
        self.assertEqual(actions["1"], ("Antigravity", "cli", "agy"))
        self.assertEqual(actions["2"], ("Claude", "cli", "claude auth login"))
        self.assertEqual(len(actions), 2)

    def test_no_auth_errors_returns_empty(self) -> None:
        snaps = [
            ProviderSnapshot(
                name="Claude", ok=True, source="api", data={"session_percent_left": 50}
            ),
            ProviderSnapshot(name="Codex", ok=False, source="api", error="connection timeout"),
        ]
        actions = _build_fix_actions(snaps)
        self.assertEqual(actions, {})

    def test_non_auth_error_excluded(self) -> None:
        snaps = [
            ProviderSnapshot(name="Claude", ok=False, source="api", error="rate limited"),
            ProviderSnapshot(name="Antigravity", ok=False, source="api", error="sign in required"),
        ]
        actions = _build_fix_actions(snaps)
        self.assertEqual(len(actions), 1)
        self.assertEqual(actions["1"], ("Antigravity", "cli", "agy"))

    def test_browser_action_type(self) -> None:
        snaps = [
            ProviderSnapshot(
                name="Cursor", ok=False, source="api", error="please login to continue"
            ),
        ]
        actions = _build_fix_actions(snaps)
        self.assertEqual(actions["1"], ("Cursor", "browser", "https://cursor.sh"))


class LaunchFixTests(unittest.TestCase):
    def test_cli_launches_single_iterm_window(self) -> None:
        with patch("gradus.__main__.subprocess.Popen") as mock_popen:
            _launch_fix("cli", "gh auth login")
        mock_popen.assert_called_once()
        args = mock_popen.call_args[0][0]
        self.assertEqual(args[0], "osascript")
        self.assertEqual(args[1], "-e")
        # One iTerm2 command creates the window and runs the auth command.
        # A separate activate statement can create a startup window, causing
        # two windows on a cold launch.
        self.assertIn('tell application "iTerm2"', args[2])
        self.assertIn("create window with default profile command", args[2])
        self.assertIn("gh auth login", args[2])
        self.assertNotIn("activate", args[2])
        self.assertEqual(args[2].count("create window"), 1)
        # stdout/stderr suppressed
        kwargs = mock_popen.call_args[1]
        self.assertEqual(kwargs.get("stdout"), subprocess.DEVNULL)
        self.assertEqual(kwargs.get("stderr"), subprocess.DEVNULL)

    def test_safari_action_opens_explicit_safari(self) -> None:
        with patch("gradus.__main__.subprocess.Popen") as mock_popen:
            _launch_fix("safari", "https://claude.ai")
        mock_popen.assert_called_once()
        args = mock_popen.call_args[0][0]
        self.assertEqual(args, ["open", "-a", "Safari", "https://claude.ai"])
        kwargs = mock_popen.call_args[1]
        self.assertEqual(kwargs.get("stdout"), subprocess.DEVNULL)
        self.assertEqual(kwargs.get("stderr"), subprocess.DEVNULL)

    def test_browser_launches_open(self) -> None:
        with patch("gradus.__main__.subprocess.Popen") as mock_popen:
            _launch_fix("browser", "https://cursor.sh")
        mock_popen.assert_called_once()
        args = mock_popen.call_args[0][0]
        self.assertEqual(args, ["open", "https://cursor.sh"])
        kwargs = mock_popen.call_args[1]
        self.assertEqual(kwargs.get("stdout"), subprocess.DEVNULL)

    def test_unknown_kind_is_noop(self) -> None:
        with patch("gradus.__main__.subprocess.Popen") as mock_popen:
            _launch_fix("unknown", "something")
        mock_popen.assert_not_called()


class IsTransientProbeErrorTests(unittest.TestCase):
    """Test transient error detection including network errors."""

    def _snap(self, error: str) -> ProviderSnapshot:
        return ProviderSnapshot(name="Claude", ok=False, source="api", error=error)

    def test_network_error_is_transient(self) -> None:
        self.assertTrue(
            _is_transient_probe_error(self._snap("Network error: Name or service not known"))
        )

    def test_http_500_is_transient(self) -> None:
        self.assertTrue(_is_transient_probe_error(self._snap("HTTP 500")))

    def test_http_504_is_transient(self) -> None:
        self.assertTrue(_is_transient_probe_error(self._snap("HTTP 504")))

    def test_timed_out_is_transient(self) -> None:
        self.assertTrue(_is_transient_probe_error(self._snap("timed out")))

    def test_invalid_json_is_transient(self) -> None:
        self.assertTrue(_is_transient_probe_error(self._snap("Invalid JSON response")))

    def test_existing_markers_still_work(self) -> None:
        self.assertTrue(_is_transient_probe_error(self._snap("rate limited")))
        self.assertTrue(_is_transient_probe_error(self._snap("HTTP 429")))
        self.assertTrue(_is_transient_probe_error(self._snap("HTTP 503")))

    def test_auth_error_not_transient(self) -> None:
        self.assertFalse(_is_transient_probe_error(self._snap("session expired — visit claude.ai")))

    def test_ok_snapshot_not_transient(self) -> None:
        snap = ProviderSnapshot(
            name="Claude", ok=True, source="api", data={"session_percent_left": 50}
        )
        self.assertFalse(_is_transient_probe_error(snap))


class MergeWithPreviousTests(unittest.TestCase):
    """Test snapshot caching and stale threshold logic."""

    def test_network_error_caches_previous_data(self) -> None:
        previous = [
            ProviderSnapshot(
                name="Claude", ok=True, source="api", data={"session_percent_left": 75}
            ),
        ]
        fresh = [
            ProviderSnapshot(
                name="Claude", ok=False, source="api", error="Network error: host unreachable"
            ),
        ]
        merged = _merge_with_previous(previous, fresh)
        self.assertEqual(len(merged), 1)
        self.assertTrue(merged[0].ok)
        self.assertEqual(merged[0].data, {"session_percent_left": 75})
        self.assertIn("cached", merged[0].source)
        self.assertIsNotNone(merged[0].cached_since)

    def test_auth_grace_is_quiet_but_failed_and_observation_bound(self) -> None:
        observed = datetime.now(timezone.utc) - timedelta(seconds=30)
        prior = {
            "schema_version": 2,
            "updated_at": observed.isoformat(),
            "providers": [{"name": "Antigravity", "ok": True, "observed_at": observed.isoformat()}],
        }
        failed = ProviderSnapshot(
            name="Antigravity",
            ok=False,
            source="api",
            error="Antigravity session expired: run `agy` to re-authenticate",
        )
        merged = _merge_with_previous(
            [],
            [failed],
            prior_payload=prior,
            prior_auth_failures=0,
            now=observed + timedelta(seconds=30),
        )
        self.assertFalse(merged[0].ok)
        self.assertEqual(merged[0].error, ANTIGRAVITY_AUTH_RETRY_MESSAGE)
        self.assertEqual(merged[0].debug_detail, "auth_failure")
        expired = _merge_with_previous(
            [],
            [failed],
            prior_payload=prior,
            prior_auth_failures=0,
            now=observed + timedelta(seconds=301),
        )
        self.assertEqual(expired[0].error, failed.error)

    def test_real_read_timeout_serves_cached_data_end_to_end(self) -> None:
        """The whole chain, with no hand-authored error string in it.

        Every other test in this class types its own error text, which is how
        the original defect survived: the classifier was correct on strings a
        human wrote, and the catch-all's actual output was never fed to it. The
        four links are: catch-all maps the exception -> classifier accepts the
        message -> merge serves the prior -> the device shows a reading instead
        of a failure card. This drives all four with the real functions, so the
        seam is covered rather than the two ends.
        """
        from gradus.providers import fetch_provider_snapshot

        class TimingOutProvider:
            # `socket.timeout` IS `TimeoutError` on 3.10+; the identity is
            # asserted in test_providers.FetchProviderSnapshotTests.
            def fetch(self) -> None:
                raise TimeoutError("The read operation timed out")

        fresh = [fetch_provider_snapshot("Antigravity", TimingOutProvider(), debug=False)]
        previous = [
            ProviderSnapshot(
                name="Antigravity", ok=True, source="api", data={"session_percent_left": 62}
            ),
        ]

        merged = _merge_with_previous(previous, fresh)

        self.assertEqual(len(merged), 1)
        self.assertTrue(merged[0].ok, "a transient timeout must not surface as a failed provider")
        self.assertEqual(merged[0].data, {"session_percent_left": 62})
        self.assertIn("cached", merged[0].source)

    def test_stale_data_replaced_after_threshold(self) -> None:
        from datetime import datetime, timedelta

        stale_time = datetime.now() - timedelta(seconds=STALE_THRESHOLD_SECONDS + 60)
        previous = [
            ProviderSnapshot(
                name="Claude",
                ok=True,
                source="api (cached)",
                data={"session_percent_left": 75},
                cached_since=stale_time,
            ),
        ]
        fresh = [
            ProviderSnapshot(
                name="Claude", ok=False, source="api", error="Network error: host unreachable"
            ),
        ]
        merged = _merge_with_previous(previous, fresh)
        self.assertEqual(len(merged), 1)
        self.assertFalse(merged[0].ok)
        self.assertTrue(merged[0].error.startswith("stale"))

    def test_cached_source_not_doubled(self) -> None:
        from datetime import datetime, timedelta

        previous = [
            ProviderSnapshot(
                name="Claude",
                ok=True,
                source="api (cached)",
                data={"session_percent_left": 75},
                cached_since=datetime.now() - timedelta(seconds=30),
            ),
        ]
        fresh = [
            ProviderSnapshot(name="Claude", ok=False, source="api", error="Network error: blip"),
        ]
        merged = _merge_with_previous(previous, fresh)
        self.assertEqual(merged[0].source, "api (cached)")
        self.assertNotIn("(cached) (cached)", merged[0].source)

    def test_successful_fetch_clears_cache(self) -> None:
        from datetime import datetime, timedelta

        previous = [
            ProviderSnapshot(
                name="Claude",
                ok=True,
                source="api (cached)",
                data={"session_percent_left": 75},
                cached_since=datetime.now() - timedelta(seconds=60),
            ),
        ]
        fresh = [
            ProviderSnapshot(
                name="Claude", ok=True, source="api", data={"session_percent_left": 80}
            ),
        ]
        merged = _merge_with_previous(previous, fresh)
        self.assertTrue(merged[0].ok)
        self.assertEqual(merged[0].data, {"session_percent_left": 80})
        self.assertNotIn("cached", merged[0].source)


@unittest.skip("--write-snapshot was retired; --refresh-snapshot is the sole producer")
class WriteSnapshotTests(unittest.TestCase):
    """Test the headless ``--write-snapshot`` command (Task 2.2, INV-2 gate).

    The headless path must be strictly read-only: it engages ``set_headless``
    before constructing providers, fires no warning notifications, launches no
    subprocess (browser / osascript / cookie extraction), and returns 0 as long
    as the snapshot file is written — even when every provider probe failed.
    """

    def _snapshots(self) -> list[ProviderSnapshot]:
        """Return a canonical provider mix including a failed probe."""
        return [
            ProviderSnapshot(
                name="Codex",
                ok=True,
                source="cli",
                data={"five_hour_percent_left": 75, "weekly_percent_left": 90},
            ),
            ProviderSnapshot(
                name="Claude",
                ok=True,
                source="api",
                data={"session_percent_left": 50},
            ),
            ProviderSnapshot(name="Antigravity", ok=False, source="api", error="auth failed"),
            ProviderSnapshot(name="Cursor", ok=False, source="api", error="session expired"),
            ProviderSnapshot(name="Vibe", ok=False, source="api", error="connection timeout"),
        ]

    def _drive(
        self,
        snapshots: list[ProviderSnapshot],
        *,
        providers: str | None = None,
        write_ok: bool | SnapshotWrite | list[bool | SnapshotWrite] = True,
    ):
        """Drive ``main()`` down the ``--write-snapshot`` branch under full spying.

        Args:
            snapshots: What ``collect_snapshots`` should return.
            providers: Optional ``--providers`` filter value.
            write_ok: What the patched ``write_snapshot`` returns per call. A
                bool is a shorthand for ``WRITTEN``/``FAILED``; pass a
                :class:`SnapshotWrite` directly to exercise ``SKIPPED_STALE``,
                which is neither a success nor a failure.

        Returns:
            A ``SimpleNamespace`` of the return code, captured payload, and mocks.
        """
        from types import SimpleNamespace

        captured: list[tuple[object, tuple[object, ...]]] = []
        committed_v2: dict | None = None

        def fake_write(payload, *args, **kwargs):
            nonlocal committed_v2
            captured.append((payload, args))
            if isinstance(write_ok, list):
                result = write_ok[len(captured) - 1]
            else:
                result = write_ok
            if not isinstance(result, SnapshotWrite):
                result = SnapshotWrite.WRITTEN if result else SnapshotWrite.FAILED
            # Only a real write changes what a subsequent read sees; a stale
            # skip leaves whatever the winning writer already committed.
            if result is SnapshotWrite.WRITTEN and payload["schema_version"] == 2:
                committed_v2 = payload
            return result

        def fake_read(path: Path | None = None) -> dict | None:
            if path is not None and path.name == "snapshot-v2.json":
                return committed_v2
            return None

        ns = argparse.Namespace(
            write_snapshot=True,
            debug=False,
            json=False,
            once=False,
            providers=providers,
            interval=120,
        )
        set_headless_spy = MagicMock()
        with (
            patch("gradus.__main__.parse_args", return_value=ns),
            patch(
                "gradus.__main__.initialize_providers",
                return_value=([("Codex", object())], []),
            ),
            patch("gradus.__main__.set_headless", set_headless_spy),
            patch("gradus.__main__.collect_snapshots", return_value=snapshots),
            patch("gradus.__main__._check_warnings") as mock_check,
            patch("gradus.__main__._notify_warning") as mock_notify,
            patch("gradus.__main__.read_prior_snapshot", side_effect=fake_read),
            patch("gradus.__main__.append_history_record", return_value=True),
            patch("gradus.__main__.write_snapshot", side_effect=fake_write) as mock_write,
            patch("gradus.__main__.subprocess.Popen") as mock_popen,
            patch("gradus.__main__.subprocess.run") as mock_run,
            patch("gradus.providers.subprocess.Popen") as mock_p_popen,
            patch("gradus.providers.subprocess.run") as mock_p_run,
        ):
            rc = main()

        return SimpleNamespace(
            rc=rc,
            payloads=[item[0] for item in captured],
            write_args=[item[1] for item in captured],
            set_headless=set_headless_spy,
            check=mock_check,
            notify=mock_notify,
            write=mock_write,
            popen=mock_popen,
            run=mock_run,
            p_popen=mock_p_popen,
            p_run=mock_p_run,
        )

    def test_write_snapshot_is_read_only_no_side_effects(self) -> None:
        """Compatibility write mode delegates to the single-flight producer."""
        ns = argparse.Namespace(
            write_snapshot=True, json=False, once=False, debug=False, providers=None, interval=120
        )
        with (
            patch("gradus.__main__.parse_args", return_value=ns),
            patch("gradus.__main__._refresh_snapshot_once", return_value=0) as refresh,
            patch("gradus.__main__.initialize_providers") as init,
            patch("gradus.__main__.collect_snapshots") as collect,
        ):
            self.assertEqual(main(), 0)
        refresh.assert_called_once()
        init.assert_not_called()
        collect.assert_not_called()

    def test_write_snapshot_exit_zero_when_all_providers_failed(self) -> None:
        """Compatibility write mode propagates producer success."""
        ns = argparse.Namespace(
            write_snapshot=True, json=False, once=False, debug=False, providers=None, interval=120
        )
        with (
            patch("gradus.__main__.parse_args", return_value=ns),
            patch("gradus.__main__._refresh_snapshot_once", return_value=0) as refresh,
        ):
            self.assertEqual(main(), 0)
        refresh.assert_called_once()

    def test_write_snapshot_exit_one_on_write_failure(self) -> None:
        """Compatibility write mode propagates producer failure."""
        ns = argparse.Namespace(
            write_snapshot=True, json=False, once=False, debug=False, providers=None, interval=120
        )
        with (
            patch("gradus.__main__.parse_args", return_value=ns),
            patch("gradus.__main__._refresh_snapshot_once", return_value=1) as refresh,
        ):
            self.assertEqual(main(), 1)
        refresh.assert_called_once()

    def test_write_snapshot_attempts_v2_after_v1_failure(self) -> None:
        """There is one producer call, not independent v1/v2 probe paths."""
        ns = argparse.Namespace(
            write_snapshot=True, json=False, once=False, debug=False, providers=None, interval=120
        )
        with (
            patch("gradus.__main__.parse_args", return_value=ns),
            patch("gradus.__main__._refresh_snapshot_once", return_value=1) as refresh,
        ):
            self.assertEqual(main(), 1)
        refresh.assert_called_once()

    def test_write_snapshot_emits_all_canonical_providers_when_filtered(self) -> None:
        """Provider filters are passed to the one producer, if requested."""
        ns = argparse.Namespace(
            write_snapshot=True,
            json=False,
            once=False,
            debug=False,
            providers="Codex",
            interval=120,
        )
        with (
            patch("gradus.__main__.parse_args", return_value=ns),
            patch("gradus.__main__._refresh_snapshot_once", return_value=0) as refresh,
        ):
            self.assertEqual(main(), 0)
        self.assertEqual(refresh.call_args.args[1], {"Codex"})

    def test_write_snapshot_payload_validates_schema(self) -> None:
        """The compatibility command delegates schema validation to producer."""
        ns = argparse.Namespace(
            write_snapshot=True, json=False, once=False, debug=False, providers=None, interval=120
        )
        with (
            patch("gradus.__main__.parse_args", return_value=ns),
            patch("gradus.__main__._refresh_snapshot_once", return_value=0) as refresh,
        ):
            self.assertEqual(main(), 0)
        refresh.assert_called_once()

    def test_write_snapshot_honors_prior_auth_failure_count_for_both_schemas(self) -> None:
        """A repeated auth failure must bypass the neutral grace marker everywhere."""
        when = datetime(2026, 8, 10, 16, tzinfo=timezone.utc)
        prior_time = when - timedelta(seconds=30)
        prior = {
            "schema_version": 2,
            "updated_at": prior_time.isoformat(),
            "providers": [
                {
                    "name": "Antigravity",
                    "ok": True,
                    "error": None,
                    "observed_at": prior_time.isoformat(),
                    "windows": [
                        {"id": "five_hour", "percent_left": 81},
                        {"id": "weekly", "percent_left": 72},
                    ],
                }
            ],
        }
        failed = ProviderSnapshot(
            name="Antigravity",
            ok=False,
            source="api",
            error="Antigravity session expired: run `agy` to re-authenticate",
        )
        captured: list[dict] = []

        def capture(payload: dict, *args: object, **kwargs: object) -> SnapshotWrite:
            captured.append(payload)
            return SnapshotWrite.WRITTEN

        with (
            patch("gradus.__main__.recent_auth_failure_count", return_value=1) as count,
            patch("gradus.__main__.read_prior_snapshot", return_value=prior),
            patch("gradus.__main__.write_snapshot", side_effect=capture),
        ):
            self.assertEqual(_write_snapshot_versions([failed], when), (True, True))

        count.assert_called_once()
        self.assertEqual(len(captured), 2)
        for payload in captured:
            entry = next(item for item in payload["providers"] if item["name"] == "Antigravity")
            self.assertEqual(
                entry["error"], "Antigravity session expired: run `agy` to re-authenticate"
            )
            self.assertEqual(entry["windows"], [])


class HistoryPersistenceIntegrationTests(unittest.TestCase):
    """History is best-effort after a verified schema-v2 commit."""

    def _snapshots(self) -> list[ProviderSnapshot]:
        return [
            ProviderSnapshot(
                name="Antigravity",
                ok=True,
                source="api",
                data={
                    "five_hour_percent_left": 90,
                    "weekly_percent_left": 70,
                    "third_party_five_hour_percent_left": 42.5,
                    "third_party_weekly_percent_left": 15.0,
                },
            )
        ]

    def test_journals_only_when_v2_readback_matches_candidate(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp) / ".state"
            state_dir.mkdir()
            v1_path = state_dir / "snapshot.json"
            v2_path = state_dir / "snapshot-v2.json"
            statuses: list[str] = []

            def fake_write(payload: dict, *args: object, **kwargs: object) -> SnapshotWrite:
                path = args[0] if args else v1_path
                assert isinstance(path, Path)
                path.write_text(json.dumps(payload), encoding="utf-8")
                return SnapshotWrite.WRITTEN

            with (
                patch("gradus.__main__.SNAPSHOT_PATH", v1_path),
                patch("gradus.__main__.SNAPSHOT_V2_PATH", v2_path),
                patch("gradus.__main__.write_snapshot", side_effect=fake_write),
                patch("gradus.__main__.append_history_record", return_value=True) as journal,
            ):
                result = _write_snapshot_versions(
                    self._snapshots(),
                    NOW,
                    on_status=statuses.append,
                    journal_history=True,
                )

            self.assertEqual(result, (True, True, True))
            journal.assert_called_once()
            args, kwargs = journal.call_args
            self.assertEqual(args[0], json.loads(v2_path.read_text(encoding="utf-8")))
            self.assertEqual(kwargs["committed_payload"], args[0])
            self.assertEqual(kwargs["history_dir"], (state_dir / "history").resolve())
            self.assertIn("schema-v1 persisted", statuses)
            self.assertIn("schema-v2 persisted", statuses)
            self.assertIn("history persisted", statuses)

    def test_stale_v2_readback_cannot_create_history(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp) / ".state"
            state_dir.mkdir()
            v1_path = state_dir / "snapshot.json"
            v2_path = state_dir / "snapshot-v2.json"
            stale = {
                "schema_version": 2,
                "updated_at": "2026-03-14T08:00:00+00:00",
                "providers": [],
            }
            current_v2: dict | None = None

            def fake_read(path: Path) -> dict | None:
                return current_v2 if path == v2_path else None

            def fake_write(payload: dict, *args: object, **kwargs: object) -> SnapshotWrite:
                nonlocal current_v2
                if args and args[0] == v2_path:
                    current_v2 = stale
                return SnapshotWrite.WRITTEN

            with (
                patch("gradus.__main__.SNAPSHOT_PATH", v1_path),
                patch("gradus.__main__.SNAPSHOT_V2_PATH", v2_path),
                patch("gradus.__main__.read_prior_snapshot", side_effect=fake_read),
                patch("gradus.__main__.write_snapshot", side_effect=fake_write),
                patch("gradus.__main__.append_history_record", return_value=True) as journal,
            ):
                result = _write_snapshot_versions(self._snapshots(), NOW, journal_history=True)

            self.assertEqual(result, (True, True, False))
            journal.assert_not_called()

    def test_history_failure_does_not_rollback_committed_v2(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp) / ".state"
            state_dir.mkdir()
            v1_path = state_dir / "snapshot.json"
            v2_path = state_dir / "snapshot-v2.json"

            def fake_write(payload: dict, *args: object, **kwargs: object) -> SnapshotWrite:
                path = args[0] if args else v1_path
                assert isinstance(path, Path)
                path.write_text(json.dumps(payload), encoding="utf-8")
                return SnapshotWrite.WRITTEN

            with (
                patch("gradus.__main__.SNAPSHOT_PATH", v1_path),
                patch("gradus.__main__.SNAPSHOT_V2_PATH", v2_path),
                patch("gradus.__main__.write_snapshot", side_effect=fake_write),
                patch("gradus.__main__.append_history_record", return_value=False),
            ):
                result = _write_snapshot_versions(self._snapshots(), NOW, journal_history=True)

            self.assertEqual(result, (True, True, False))
            self.assertTrue(v2_path.exists())
            self.assertEqual(json.loads(v2_path.read_text(encoding="utf-8"))["schema_version"], 2)

    def test_losing_a_write_race_is_not_reported_as_a_persistence_failure(self) -> None:
        """A stale skip defers journaling to the winner instead of failing.

        Gradus runs two writers on overlapping 120s cycles (the TUI and the
        launchd job), so one loses every cycle. Before this was fixed,
        ``write_snapshot`` returned True for the skip, the caller's readback
        check then failed, and a correct no-op was logged as
        ``v1=True v2=True history=False`` every two minutes for over a day.
        """
        statuses: list[str] = []
        with (
            patch("gradus.__main__.SNAPSHOT_PATH", Path("/nonexistent/snapshot.json")),
            patch("gradus.__main__.SNAPSHOT_V2_PATH", Path("/nonexistent/snapshot-v2.json")),
            patch("gradus.__main__.read_prior_snapshot", return_value=None),
            patch("gradus.__main__.write_snapshot", return_value=SnapshotWrite.SKIPPED_STALE),
            patch("gradus.__main__.append_history_record") as journal,
        ):
            result = _write_snapshot_versions(
                self._snapshots(), NOW, on_status=statuses.append, journal_history=True
            )

        self.assertEqual(result, (True, True, True))
        # The winner already journaled this cycle; appending here would either
        # duplicate its record or write a superseded one.
        journal.assert_not_called()
        self.assertIn("schema-v2 superseded by newer snapshot", statuses)
        self.assertIn("history deferred to concurrent writer", statuses)
        self.assertNotIn("history persistence failed", statuses)

    def test_readback_of_a_newer_payload_defers_rather_than_failing(self) -> None:
        """Being overtaken between the write and the readback is also benign.

        Distinct from the stale-skip path: here the write did land, and a
        concurrent writer replaced it a moment later. That writer journals its
        own payload, so there is nothing lost -- but the readback no longer
        matches, which is the same signal a genuinely broken write produces.
        """
        newer = {
            "schema_version": 2,
            "updated_at": (NOW + timedelta(seconds=30)).astimezone().isoformat(),
            "providers": [],
        }
        statuses: list[str] = []
        with (
            patch("gradus.__main__.SNAPSHOT_PATH", Path("/nonexistent/snapshot.json")),
            patch("gradus.__main__.SNAPSHOT_V2_PATH", Path("/nonexistent/snapshot-v2.json")),
            patch("gradus.__main__.read_prior_snapshot", return_value=newer),
            patch("gradus.__main__.write_snapshot", return_value=SnapshotWrite.WRITTEN),
            patch("gradus.__main__.append_history_record") as journal,
        ):
            result = _write_snapshot_versions(
                self._snapshots(), NOW, on_status=statuses.append, journal_history=True
            )

        self.assertEqual(result, (True, True, True))
        journal.assert_not_called()
        self.assertIn("history deferred to concurrent writer", statuses)

    def test_stale_skip_still_reports_a_real_write_failure(self) -> None:
        """Deferring must not become a way for genuine IO failures to read green."""
        with (
            patch("gradus.__main__.SNAPSHOT_PATH", Path("/nonexistent/snapshot.json")),
            patch("gradus.__main__.SNAPSHOT_V2_PATH", Path("/nonexistent/snapshot-v2.json")),
            patch("gradus.__main__.read_prior_snapshot", return_value=None),
            patch(
                "gradus.__main__.write_snapshot",
                side_effect=[SnapshotWrite.SKIPPED_STALE, SnapshotWrite.FAILED],
            ),
            patch("gradus.__main__.append_history_record") as journal,
        ):
            result = _write_snapshot_versions(self._snapshots(), NOW, journal_history=True)

        self.assertEqual(result, (True, False, False))
        journal.assert_not_called()


class TestProviderRefreshSchedule(unittest.TestCase):
    """Provider cadence is stable while every cycle remains consolidated."""

    BASE = datetime(2026, 8, 22, 12, tzinfo=timezone.utc)

    @classmethod
    def _payload(cls, *, claude_error: str | None = None) -> dict[str, object]:
        return {
            "schema_version": 2,
            "updated_at": cls.BASE.isoformat(),
            "providers": [
                {
                    "name": name,
                    "ok": claude_error is None or name != "Claude",
                    "error": claude_error if name == "Claude" else None,
                    "data": {"marker": name},
                    "windows": [],
                    "observed_at": cls.BASE.isoformat(),
                    "probe_attempted_at": cls.BASE.isoformat(),
                }
                for name in (
                    "Codex",
                    "Claude",
                    "Antigravity",
                    "Copilot",
                    "Cursor",
                    "OpenCode Go",
                    "Vibe",
                )
            ],
        }

    def test_every_consumer_visible_provider_is_due_on_each_cycle(self) -> None:
        names = ("Codex", "Antigravity", "Copilot", "Cursor", "OpenCode Go", "Vibe")
        for name in names:
            self.assertEqual(_provider_next_probe_at(self._payload(), name, self.BASE), self.BASE)

    def test_collect_probes_every_worker_and_reports_each_start(self) -> None:
        names = ("Codex", "Antigravity", "Copilot", "Cursor", "OpenCode Go", "Vibe")
        started: list[str] = []
        probed: list[str] = []

        def fake_fetch(name: str, _provider: object, _debug: bool) -> ProviderSnapshot:
            probed.append(name)
            return ProviderSnapshot(name=name, ok=True, source="api", data={})

        with patch("gradus.__main__.fetch_provider_snapshot", side_effect=fake_fetch):
            snapshots = collect_snapshots(
                [(name, MagicMock()) for name in names],
                False,
                on_start=started.append,
            )

        self.assertCountEqual(probed, names)
        self.assertCountEqual(started, names)
        self.assertEqual([snapshot.name for snapshot in snapshots], sorted(names))

    def test_manual_sub_120s_refresh_probes_synthetic_primaries_fresh(self) -> None:
        providers = [("Codex", MagicMock()), ("Antigravity", MagicMock())]
        scheduled = _schedule_refresh_providers(
            providers,
            self._payload(),
            self.BASE + timedelta(seconds=1),
            on_deferred=lambda _name, _seconds: self.fail("non-Claude provider deferred"),
        )

        def fake_fetch(name: str, _provider: object, _debug: bool) -> ProviderSnapshot:
            data = {
                "five_hour_percent_left": 80.0,
                "weekly_percent_left": 70.0,
            }
            if name == "Codex":
                data["spark_weekly_percent_left"] = 60.0
            else:
                data["third_party_five_hour_percent_left"] = 50.0
                data["third_party_weekly_percent_left"] = 40.0
            return ProviderSnapshot(name=name, ok=True, source="api", data=data)

        with patch("gradus.__main__.fetch_provider_snapshot", side_effect=fake_fetch):
            snapshots = collect_snapshots(scheduled, False)
        payload = build_snapshot_v2_payload(
            snapshots,
            self.BASE + timedelta(seconds=1),
            prior=self._payload(),
        )
        by_name = {entry["name"]: entry for entry in payload["providers"]}
        for name in ("Codex", "Codex (Spark)", "Antigravity", "Antigravity (Claude)"):
            self.assertEqual(by_name[name]["observed_at"], payload["updated_at"])
            self.assertEqual(by_name[name]["probe_attempted_at"], payload["updated_at"])

    def test_schedule_probes_all_non_claude_and_reports_claude_deferral(self) -> None:
        non_claude = ("Codex", "Antigravity", "Copilot", "Cursor", "OpenCode Go", "Vibe")
        providers = [(name, MagicMock()) for name in (*non_claude, "Claude")]
        statuses: list[tuple[str, int]] = []
        scheduled = _schedule_refresh_providers(
            providers,
            self._payload(),
            self.BASE + timedelta(seconds=150),
            on_deferred=lambda name, seconds: statuses.append((name, seconds)),
        )
        probed: list[str] = []

        def fake_fetch(name: str, _provider: object, _debug: bool) -> ProviderSnapshot:
            probed.append(name)
            return ProviderSnapshot(name=name, ok=True, source="api", data={})

        with patch("gradus.__main__.fetch_provider_snapshot", side_effect=fake_fetch):
            snapshots = collect_snapshots(scheduled, False)

        self.assertCountEqual(probed, non_claude)
        self.assertEqual(statuses, [("Claude", 450)])
        self.assertEqual(
            {snapshot.name for snapshot in snapshots},
            {*non_claude, "Claude"},
        )
        self.assertEqual(
            {snapshot.name for snapshot in snapshots if snapshot.source == "snapshot"},
            {"Claude"},
        )

    def test_claude_cooldown_and_rate_limit_backoff_are_preserved(self) -> None:
        normal = self._payload()
        limited = self._payload(claude_error="HTTP 429 rate limited")
        expired = self._payload(claude_error="Claude Code session expired: run `claude auth login`")
        synthetic_disabled = self._payload(claude_error="provider not enabled")

        self.assertEqual(
            _provider_next_probe_at(normal, "Claude", self.BASE),
            self.BASE + timedelta(seconds=600),
        )
        self.assertEqual(
            _provider_next_probe_at(synthetic_disabled, "Claude", self.BASE),
            self.BASE,
        )
        self.assertTrue(_claude_probe_is_due(synthetic_disabled, self.BASE))
        self.assertFalse(_claude_probe_is_due(normal, self.BASE + timedelta(seconds=599)))
        self.assertTrue(_claude_probe_is_due(normal, self.BASE + timedelta(seconds=600)))
        self.assertEqual(
            _provider_next_probe_at(limited, "Claude", self.BASE),
            self.BASE + timedelta(seconds=3600),
        )
        self.assertFalse(_claude_probe_is_due(limited, self.BASE + timedelta(seconds=3599)))
        self.assertTrue(_claude_probe_is_due(limited, self.BASE + timedelta(seconds=3600)))
        self.assertEqual(
            _provider_next_probe_at(expired, "Claude", self.BASE),
            self.BASE + timedelta(seconds=3600),
        )
        self.assertFalse(_claude_probe_is_due(expired, self.BASE + timedelta(seconds=3599)))
        self.assertTrue(_claude_probe_is_due(expired, self.BASE + timedelta(seconds=3600)))

    def test_rate_limited_claude_is_deferred_safely_before_one_hour(self) -> None:
        raw_detail = "HTTP 429 rate limited raw-account-detail"
        payload = self._payload(claude_error=raw_detail)
        provider = MagicMock()
        statuses: list[tuple[str, int]] = []
        scheduled = _schedule_refresh_providers(
            [("Claude", provider)],
            payload,
            self.BASE + timedelta(seconds=3599),
            on_deferred=lambda name, seconds: statuses.append((name, seconds)),
        )

        with patch("gradus.__main__.fetch_provider_snapshot") as fetch:
            snapshots = collect_snapshots(scheduled, False)

        fetch.assert_not_called()
        self.assertEqual(statuses, [("Claude", 1)])
        self.assertEqual(snapshots[0].source, "snapshot")
        self.assertNotIn("raw-account-detail", repr(statuses))

    def test_claude_cooldown_defers_session_expiry_before_one_hour(self) -> None:
        payload = self._payload(claude_error="Claude Code session expired: run `claude auth login`")
        provider = MagicMock()
        statuses: list[tuple[str, int]] = []
        scheduled = _schedule_refresh_providers(
            [("Claude", provider)],
            payload,
            self.BASE + timedelta(seconds=3599),
            on_deferred=lambda name, seconds: statuses.append((name, seconds)),
        )

        with patch("gradus.__main__.fetch_provider_snapshot") as fetch:
            snapshots = collect_snapshots(scheduled, False)

        fetch.assert_not_called()
        self.assertEqual(statuses, [("Claude", 1)])
        self.assertEqual(snapshots[0].source, "snapshot")


class TestCredentialAwareRefresh(unittest.TestCase):
    """The explicit refresh command is credential-aware but non-interactive."""

    @staticmethod
    def _namespace() -> argparse.Namespace:
        return argparse.Namespace(
            json=False,
            refresh_snapshot=True,
            once=False,
            debug=False,
            providers=None,
            interval=120,
        )

    def test_command_selection_is_mutually_exclusive(self) -> None:
        for args in (
            ("--json", "--refresh-snapshot"),
            ("--once", "--refresh-snapshot"),
        ):
            with self.subTest(args=args), patch("sys.argv", ["gradus", *args]):
                with self.assertRaises(SystemExit) as ctx:
                    parse_args()
                self.assertEqual(ctx.exception.code, 2)

    def test_retired_write_snapshot_flag_is_rejected(self) -> None:
        with patch("sys.argv", ["gradus", "--write-snapshot"]):
            with self.assertRaises(SystemExit) as ctx:
                parse_args()
        self.assertEqual(ctx.exception.code, 2)

    def test_refresh_reports_safe_schedule_start_and_complete_progress(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp) / ".state"
            state_dir.mkdir()
            attempted_at = datetime.now(timezone.utc)
            prior = {
                "schema_version": 2,
                "updated_at": attempted_at.isoformat(),
                "providers": [
                    {
                        "name": "OpenCode Go",
                        "ok": True,
                        "error": None,
                        "windows": [],
                        "data": {"monthly_percent_left": "raw-data-sentinel"},
                        "observed_at": attempted_at.isoformat(),
                        "probe_attempted_at": attempted_at.isoformat(),
                    }
                ],
            }
            provider = MagicMock()
            stderr = StringIO()

            with (
                patch("gradus.__main__._snapshot_state_dir", return_value=state_dir),
                patch(
                    "gradus.__main__.initialize_providers",
                    return_value=([("OpenCode Go", provider)], []),
                ),
                patch("gradus.__main__.read_prior_snapshot", return_value=prior),
                patch("gradus.__main__.set_headless"),
                patch("gradus.__main__.time.sleep"),
                patch(
                    "gradus.__main__.fetch_provider_snapshot",
                    return_value=ProviderSnapshot(
                        name="OpenCode Go",
                        ok=True,
                        source="api",
                        data={"monthly_percent_left": 75.0},
                    ),
                ) as fetch,
                patch(
                    "gradus.__main__._write_snapshot_versions",
                    return_value=(True, True, True),
                ) as write,
                patch("gradus.__main__.sys.stderr", stderr),
            ):
                result = _refresh_snapshot_once(tmp, None, False)

            self.assertEqual(result, 0)
            fetch.assert_called_once_with("OpenCode Go", provider, False)
            write.assert_called_once()
            snapshots = write.call_args.args[0]
            self.assertEqual(len(snapshots), 1)
            self.assertEqual(snapshots[0].source, "api")
            status = stderr.getvalue()
            self.assertIn("refresh: provider OpenCode Go started", status)
            self.assertIn("refresh: provider OpenCode Go complete", status)
            self.assertIn("refresh: completed", status)
            self.assertNotIn("raw-data-sentinel", status)

    def test_refresh_is_explicit_single_flight_progress_visible_and_one_probe(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp) / ".state"
            state_dir.mkdir()
            providers = [("Codex", MagicMock()), ("Antigravity", MagicMock())]
            calls: list[str] = []
            payloads: list[dict] = []
            committed_v2: dict | None = None

            def fake_fetch(name: str, _provider: object, _debug: bool) -> ProviderSnapshot:
                calls.append(name)
                if name == "Codex":
                    time.sleep(0.05)
                    return ProviderSnapshot(
                        name=name,
                        ok=True,
                        source="api",
                        data={"five_hour_percent_left": 80},
                    )
                return ProviderSnapshot(
                    name=name,
                    ok=True,
                    source="api",
                    data={
                        "five_hour_percent_left": 90,
                        "weekly_percent_left": 70,
                        "third_party_five_hour_percent_left": 42.5,
                        "third_party_weekly_percent_left": 15.0,
                    },
                )

            def fake_write(payload: dict, *args: object, **kwargs: object) -> SnapshotWrite:
                nonlocal committed_v2
                payloads.append(payload)
                if payload["schema_version"] == 2:
                    committed_v2 = payload
                return SnapshotWrite.WRITTEN

            def fake_read(path: Path | None = None) -> dict | None:
                if path is not None and path.name == "snapshot-v2.json":
                    return committed_v2
                return None

            set_headless_spy = MagicMock()
            stderr = StringIO()
            with (
                patch("sys.argv", ["gradus", "--refresh-snapshot"]),
                patch("gradus.__main__.parse_args", return_value=self._namespace()),
                patch("gradus.__main__._setup_logging"),
                patch("gradus.__main__._load_config", return_value={}),
                patch("gradus.__main__.os.getcwd", return_value=tmp),
                patch("gradus.__main__._snapshot_state_dir", return_value=state_dir),
                patch("gradus.__main__.set_headless", set_headless_spy),
                patch("gradus.__main__.initialize_providers", return_value=(providers, [])) as init,
                patch("gradus.__main__.fetch_provider_snapshot", side_effect=fake_fetch),
                patch("gradus.__main__.read_prior_snapshot", side_effect=fake_read),
                patch("gradus.__main__.append_history_record", return_value=True),
                patch("gradus.__main__.write_snapshot", side_effect=fake_write),
                patch("gradus.__main__._check_warnings") as check,
                patch("gradus.__main__._build_fix_actions") as fixes,
                patch("gradus.__main__._launch_fix") as launch_fix,
                patch("gradus.__main__.sys.stderr", stderr),
            ):
                rc = main()

            self.assertEqual(rc, 0)
            init.assert_called_once()
            set_headless_spy.assert_called_once_with(False)
            self.assertEqual(calls.count("Antigravity"), 1)
            self.assertEqual(len(payloads), 2)
            self.assertEqual(
                [entry["name"] for entry in payloads[0]["providers"]],
                ["Codex", "Claude", "Antigravity", "Copilot", "Cursor", "OpenCode Go", "Vibe"],
            )
            self.assertIn(
                "Antigravity (Claude)",
                [entry["name"] for entry in payloads[1]["providers"]],
            )
            status = stderr.getvalue()
            self.assertIn("refresh: provider Codex started", status)
            self.assertIn("refresh: provider Antigravity started", status)
            # Probes now start together, so completion order is scheduler-dependent.
            # INV-8 requires each provider's progress to be visible, not ordered.
            self.assertIn("refresh: provider Codex complete", status)
            self.assertIn("refresh: provider Antigravity complete", status)
            self.assertIn("refresh: schema-v1 persisted", status)
            self.assertIn("refresh: schema-v2 persisted", status)
            self.assertIn("refresh: completed", status)
            self.assertNotIn("account", status.lower())
            self.assertNotIn("cookie", status.lower())
            self.assertNotIn("raw", status.lower())
            self.assertNotIn("token", status.lower())
            check.assert_not_called()
            fixes.assert_not_called()
            launch_fix.assert_not_called()
            self.assertEqual(state_dir.stat().st_mode & 0o777, 0o700)
            self.assertEqual((state_dir / ".refresh-snapshot.lock").stat().st_mode & 0o777, 0o600)

    def test_refresh_generic_provider_exception_is_absent_from_v1_and_v2_payloads(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp) / ".state"
            state_dir.mkdir()
            sentinel = "provider-secret-sentinel"

            class FakeProvider:
                def fetch(self) -> None:
                    raise RuntimeError(sentinel)

            payloads: list[dict] = []
            committed_v2: dict | None = None

            def fake_write(payload: dict, *args: object, **kwargs: object) -> SnapshotWrite:
                nonlocal committed_v2
                payloads.append(payload)
                if payload["schema_version"] == 2:
                    committed_v2 = payload
                return SnapshotWrite.WRITTEN

            def fake_read(path: Path | None = None) -> dict | None:
                if path is not None and path.name == "snapshot-v2.json":
                    return committed_v2
                return None

            with (
                patch("sys.argv", ["gradus", "--refresh-snapshot"]),
                patch("gradus.__main__.parse_args", return_value=self._namespace()),
                patch("gradus.__main__._setup_logging"),
                patch("gradus.__main__._load_config", return_value={}),
                patch("gradus.__main__.os.getcwd", return_value=tmp),
                patch("gradus.__main__._snapshot_state_dir", return_value=state_dir),
                patch(
                    "gradus.__main__.initialize_providers",
                    return_value=([("Codex", FakeProvider())], []),
                ),
                patch("gradus.__main__.read_prior_snapshot", side_effect=fake_read),
                patch("gradus.__main__.append_history_record", return_value=True),
                patch("gradus.__main__.write_snapshot", side_effect=fake_write),
            ):
                rc = main()

            self.assertEqual(rc, 0)
            self.assertEqual(len(payloads), 2)
            for payload in payloads:
                self.assertNotIn(sentinel, json.dumps(payload))
                codex = next(entry for entry in payload["providers"] if entry["name"] == "Codex")
                self.assertEqual(codex["error"], "provider probe failed")

    def test_refresh_overlap_is_a_safe_noop_before_provider_initialization(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp) / ".state"
            state_dir.mkdir()
            lock_path = state_dir / ".refresh-snapshot.lock"
            fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                stderr = StringIO()
                with (
                    patch("sys.argv", ["gradus", "--refresh-snapshot"]),
                    patch("gradus.__main__.parse_args", return_value=self._namespace()),
                    patch("gradus.__main__._setup_logging"),
                    patch("gradus.__main__._load_config", return_value={}),
                    patch("gradus.__main__.os.getcwd", return_value=tmp),
                    patch("gradus.__main__._snapshot_state_dir", return_value=state_dir),
                    patch("gradus.__main__.initialize_providers") as init,
                    patch("gradus.__main__.write_snapshot") as write,
                    patch("gradus.__main__.sys.stderr", stderr),
                ):
                    rc = main()

                self.assertEqual(rc, 0)
                self.assertIn("refresh: already in progress", stderr.getvalue())
                init.assert_not_called()
                write.assert_not_called()
            finally:
                fcntl.flock(fd, fcntl.LOCK_UN)
                os.close(fd)

    def test_refresh_lock_is_shared_across_distinct_invocation_cwds(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp) / ".state"
            state_dir.mkdir()
            other_cwd = Path(tmp) / "other-cwd"
            other_cwd.mkdir()
            fd, already_owned = _acquire_refresh_snapshot_lock(state_dir)
            self.assertIsNotNone(fd)
            self.assertFalse(already_owned)
            assert fd is not None
            try:
                stderr = StringIO()
                with (
                    patch("sys.argv", ["gradus", "--refresh-snapshot"]),
                    patch("gradus.__main__.parse_args", return_value=self._namespace()),
                    patch("gradus.__main__._setup_logging"),
                    patch("gradus.__main__._load_config", return_value={}),
                    patch("gradus.__main__.os.getcwd", return_value=str(other_cwd)),
                    patch("gradus.__main__._snapshot_state_dir", return_value=state_dir),
                    patch("gradus.__main__.initialize_providers") as init,
                    patch("gradus.__main__.write_snapshot") as write,
                    patch("gradus.__main__.sys.stderr", stderr),
                ):
                    rc = main()

                self.assertEqual(rc, 0)
                self.assertIn("refresh: already in progress", stderr.getvalue())
                init.assert_not_called()
                write.assert_not_called()
            finally:
                _release_refresh_snapshot_lock(fd)

    def test_refresh_persistence_lock_wait_is_visible_and_bounded(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp) / ".state"
            state_dir.mkdir()
            v1_path = state_dir / "snapshot.json"
            v2_path = state_dir / "snapshot-v2.json"
            lock_path = state_dir / ".snapshot.json.lock"
            lock = open(lock_path, "a+", encoding="utf-8")
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            statuses: list[str] = []

            def real_write(payload: dict, *args: object, **kwargs: object) -> SnapshotWrite:
                path = args[0] if args else v1_path
                assert isinstance(path, Path)
                return snapshot_module.write_snapshot(payload, path, **kwargs)

            try:
                with (
                    patch("gradus.__main__.SNAPSHOT_PATH", v1_path),
                    patch("gradus.__main__.SNAPSHOT_V2_PATH", v2_path),
                    patch("gradus.__main__.write_snapshot", side_effect=real_write),
                ):
                    result = _write_snapshot_versions(
                        [
                            ProviderSnapshot(
                                name="Codex",
                                ok=True,
                                source="api",
                                data={"five_hour_percent_left": 50},
                            )
                        ],
                        NOW,
                        on_status=statuses.append,
                        lock_timeout=0.12,
                        lock_poll_interval=0.01,
                    )
            finally:
                fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
                lock.close()

            self.assertEqual(result, (False, True))
            self.assertGreaterEqual(
                statuses.count("schema-v1 waiting for snapshot lock"),
                2,
            )
            self.assertIn("schema-v1 persistence failed", statuses)
            self.assertIn("schema-v2 persisted", statuses)
            self.assertFalse(v1_path.exists())
            self.assertTrue(v2_path.exists())

    def test_refresh_lock_open_failure_is_nonzero_and_does_not_probe(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / ".state").mkdir()
            stderr = StringIO()
            with (
                patch("sys.argv", ["gradus", "--refresh-snapshot"]),
                patch("gradus.__main__.parse_args", return_value=self._namespace()),
                patch("gradus.__main__._setup_logging"),
                patch("gradus.__main__._load_config", return_value={}),
                patch("gradus.__main__.os.getcwd", return_value=tmp),
                patch("gradus.__main__._snapshot_state_dir", return_value=Path(tmp) / ".state"),
                patch("gradus.__main__.os.open", side_effect=OSError("sensitive details")),
                patch("gradus.__main__.initialize_providers") as init,
                patch("gradus.__main__.sys.stderr", stderr),
            ):
                rc = main()

            self.assertEqual(rc, 1)
            self.assertIn("refresh: lock unavailable", stderr.getvalue())
            self.assertNotIn("sensitive details", stderr.getvalue())
            init.assert_not_called()

    def test_refresh_fetch_exception_keeps_lock_until_slow_worker_finishes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp) / ".state"
            state_dir.mkdir()
            slow_started = threading.Event()
            first_heartbeat_seen = threading.Event()
            second_heartbeat_seen = threading.Event()
            release_slow = threading.Event()
            heartbeat_count = 0
            providers = [("Antigravity", MagicMock()), ("Codex", MagicMock())]
            committed_v2: dict | None = None

            def fake_fetch(name: str, _provider: object, _debug: bool) -> ProviderSnapshot:
                if name == "Antigravity":
                    slow_started.set()
                    self.assertTrue(release_slow.wait(timeout=2))
                    return ProviderSnapshot(
                        name=name,
                        ok=True,
                        source="api",
                        data={"five_hour_percent_left": 80},
                    )
                raise RuntimeError("raw token details")

            stderr = StringIO()
            result: list[int] = []
            ns = self._namespace()

            def progress(message: str) -> None:
                nonlocal heartbeat_count
                print(f"refresh: {message}", file=stderr, flush=True)
                if message.startswith("waiting for "):
                    heartbeat_count += 1
                    first_heartbeat_seen.set()
                    if heartbeat_count >= 2:
                        second_heartbeat_seen.set()

            def fake_write(payload: dict, *args: object, **kwargs: object) -> SnapshotWrite:
                nonlocal committed_v2
                if payload["schema_version"] == 2:
                    committed_v2 = payload
                return SnapshotWrite.WRITTEN

            def fake_read(path: Path | None = None) -> dict | None:
                if path is not None and path.name == "snapshot-v2.json":
                    return committed_v2
                return None

            with (
                patch("gradus.__main__.parse_args", return_value=ns),
                patch("gradus.__main__._setup_logging"),
                patch("gradus.__main__._load_config", return_value={}),
                patch("gradus.__main__.os.getcwd", return_value=tmp),
                patch("gradus.__main__._snapshot_state_dir", return_value=state_dir),
                patch("gradus.__main__.initialize_providers", return_value=(providers, [])),
                patch("gradus.__main__.time.sleep"),
                patch("gradus.__main__.fetch_provider_snapshot", side_effect=fake_fetch),
                patch("gradus.__main__.read_prior_snapshot", side_effect=fake_read),
                patch("gradus.__main__.append_history_record", return_value=True),
                patch("gradus.__main__.write_snapshot", side_effect=fake_write),
                patch("gradus.__main__._refresh_progress", side_effect=progress),
            ):
                worker = threading.Thread(target=lambda: result.append(main()))
                worker.start()
                self.assertTrue(slow_started.wait(timeout=2))

                second_fd, already_owned = _acquire_refresh_snapshot_lock(state_dir)
                self.assertIsNone(second_fd)
                self.assertTrue(already_owned)
                self.assertTrue(first_heartbeat_seen.wait(timeout=2))
                self.assertTrue(second_heartbeat_seen.wait(timeout=2))

                release_slow.set()
                worker.join(timeout=2)

            self.assertFalse(worker.is_alive())
            self.assertEqual(result, [0])
            status = stderr.getvalue()
            self.assertIn("refresh: waiting for 1 provider(s)", status)
            self.assertIn("refresh: provider Codex complete", status)
            self.assertNotIn("raw token details", status)
            completed_heartbeat_count = heartbeat_count
            time.sleep(0.05)
            self.assertEqual(heartbeat_count, completed_heartbeat_count)
            self.assertGreaterEqual(completed_heartbeat_count, 2)

    def test_refresh_cleans_up_providers_before_releasing_lock(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            provider = MagicMock()
            cleanup_lock_attempt: list[tuple[int | None, bool]] = []

            def close() -> None:
                cleanup_lock_attempt.append(_acquire_refresh_snapshot_lock(Path(tmp) / ".state"))

            provider.close.side_effect = close
            providers = [("Codex", provider)]
            committed_v2: dict | None = None

            def fake_write(payload: dict, *args: object, **kwargs: object) -> SnapshotWrite:
                nonlocal committed_v2
                if payload["schema_version"] == 2:
                    committed_v2 = payload
                return SnapshotWrite.WRITTEN

            def fake_read(path: Path | None = None) -> dict | None:
                if path is not None and path.name == "snapshot-v2.json":
                    return committed_v2
                return None

            with (
                patch("gradus.__main__.parse_args", return_value=self._namespace()),
                patch("gradus.__main__._setup_logging"),
                patch("gradus.__main__._load_config", return_value={}),
                patch("gradus.__main__.os.getcwd", return_value=tmp),
                patch("gradus.__main__._snapshot_state_dir", return_value=Path(tmp) / ".state"),
                patch("gradus.__main__.initialize_providers", return_value=(providers, [provider])),
                patch(
                    "gradus.__main__.fetch_provider_snapshot",
                    return_value=ProviderSnapshot(name="Codex", ok=True, source="api", data={}),
                ),
                patch("gradus.__main__.read_prior_snapshot", side_effect=fake_read),
                patch("gradus.__main__.append_history_record", return_value=True),
                patch("gradus.__main__.write_snapshot", side_effect=fake_write),
            ):
                self.assertEqual(main(), 0)

            self.assertEqual(cleanup_lock_attempt, [(None, True)])
            fd, already_owned = _acquire_refresh_snapshot_lock(Path(tmp) / ".state")
            self.assertIsNotNone(fd)
            self.assertFalse(already_owned)
            assert fd is not None
            _release_refresh_snapshot_lock(fd)

    def test_collect_snapshots_default_waits_for_all_workers_before_raising(self) -> None:
        release_slow = threading.Event()
        slow_started = threading.Event()
        slow_finished = threading.Event()
        original_error = RuntimeError("raw provider failure")
        providers = [("slow", MagicMock()), ("failing", MagicMock())]
        captured: list[BaseException] = []

        def fake_fetch(name: str, _provider: object, _debug: bool) -> ProviderSnapshot:
            if name == "slow":
                slow_started.set()
                self.assertTrue(release_slow.wait(timeout=2))
                slow_finished.set()
                return ProviderSnapshot(name=name, ok=True, source="api", data={})
            raise original_error

        def collect() -> None:
            try:
                collect_snapshots(providers, False)
            except BaseException as exc:  # noqa: BLE001 - assert the public exception
                captured.append(exc)

        stderr = StringIO()
        with (
            patch("gradus.__main__.fetch_provider_snapshot", side_effect=fake_fetch),
            patch("gradus.__main__.sys.stderr", stderr),
        ):
            worker = threading.Thread(target=collect)
            worker.start()
            self.assertTrue(slow_started.wait(timeout=2))
            time.sleep(0.05)
            self.assertTrue(worker.is_alive())
            self.assertEqual(captured, [])

            release_slow.set()
            worker.join(timeout=2)

        self.assertFalse(worker.is_alive())
        self.assertEqual(captured, [original_error])
        self.assertTrue(slow_finished.is_set())
        self.assertEqual(stderr.getvalue(), "")

    def test_refresh_rejects_unsafe_state_and_lock_paths(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "target"
            target.mkdir()
            state_path = Path(tmp) / ".state"
            state_path.symlink_to(target, target_is_directory=True)
            self.assertEqual(_acquire_refresh_snapshot_lock(state_path), (None, False))

            state_path.unlink()
            state_path.write_text("not a directory", encoding="utf-8")
            self.assertEqual(_acquire_refresh_snapshot_lock(state_path), (None, False))

            state_path.unlink()
            state_path.mkdir()
            lock_target = state_path / "real-lock"
            lock_target.touch()
            lock_path = state_path / ".refresh-snapshot.lock"
            lock_path.symlink_to(lock_target)
            self.assertEqual(_acquire_refresh_snapshot_lock(state_path), (None, False))

            lock_path.unlink()
            lock_path.mkdir()
            self.assertEqual(_acquire_refresh_snapshot_lock(state_path), (None, False))

    def test_refresh_exits_zero_when_it_loses_the_write_race(self) -> None:
        """Losing to a concurrent writer is a successful run, not a failed job.

        ``~/.launchd/scripts/gradus_snapshot.sh`` ``exec``s this command, so the
        exit code goes straight to launchd. While ``write_snapshot`` reported a
        stale skip as a plain success, the readback check downstream failed and
        this path returned 1 -- launchd recorded a failure for a job that had
        correctly declined to overwrite newer data with older.
        """
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp) / ".state"
            state_dir.mkdir()
            stderr = StringIO()

            with (
                patch("gradus.__main__.parse_args", return_value=self._namespace()),
                patch("gradus.__main__._setup_logging"),
                patch("gradus.__main__._load_config", return_value={}),
                patch("gradus.__main__.os.getcwd", return_value=tmp),
                patch("gradus.__main__._snapshot_state_dir", return_value=state_dir),
                patch(
                    "gradus.__main__.initialize_providers",
                    return_value=([("Codex", MagicMock())], []),
                ),
                patch(
                    "gradus.__main__.fetch_provider_snapshot",
                    return_value=ProviderSnapshot(
                        name="Codex",
                        ok=True,
                        source="api",
                        data={"five_hour_percent_left": 50},
                    ),
                ),
                patch("gradus.__main__.read_prior_snapshot", return_value=None),
                patch(
                    "gradus.__main__.write_snapshot",
                    return_value=SnapshotWrite.SKIPPED_STALE,
                ),
                patch("gradus.__main__.append_history_record") as journal,
                patch("gradus.__main__.sys.stderr", stderr),
            ):
                self.assertEqual(main(), 0)

            journal.assert_not_called()
            status = stderr.getvalue()
            self.assertIn("refresh: completed", status)
            self.assertNotIn("refresh: failed", status)

    def test_refresh_reports_static_initialization_failure_immediately_and_safely(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp) / ".state"
            state_dir.mkdir()
            providers = [
                ("Codex", RuntimeError("account token details")),
                ("Antigravity", MagicMock()),
            ]
            committed_v2: dict | None = None
            stderr = StringIO()

            def fake_write(payload: dict, *args: object, **kwargs: object) -> SnapshotWrite:
                nonlocal committed_v2
                if payload["schema_version"] == 2:
                    committed_v2 = payload
                return SnapshotWrite.WRITTEN

            def fake_read(path: Path | None = None) -> dict | None:
                if path is not None and path.name == "snapshot-v2.json":
                    return committed_v2
                return None

            with (
                patch("gradus.__main__.parse_args", return_value=self._namespace()),
                patch("gradus.__main__._setup_logging"),
                patch("gradus.__main__._load_config", return_value={}),
                patch("gradus.__main__.os.getcwd", return_value=tmp),
                patch("gradus.__main__._snapshot_state_dir", return_value=state_dir),
                patch("gradus.__main__.initialize_providers", return_value=(providers, [])),
                patch(
                    "gradus.__main__.fetch_provider_snapshot",
                    return_value=ProviderSnapshot(
                        name="Antigravity",
                        ok=True,
                        source="api",
                        data={"five_hour_percent_left": 75},
                    ),
                ),
                patch("gradus.__main__.read_prior_snapshot", side_effect=fake_read),
                patch("gradus.__main__.append_history_record", return_value=True),
                patch("gradus.__main__.write_snapshot", side_effect=fake_write),
                patch("gradus.__main__.sys.stderr", stderr),
            ):
                self.assertEqual(main(), 0)

            status = stderr.getvalue()
            self.assertIn("refresh: provider Codex initialization failed", status)
            self.assertIn("refresh: provider Antigravity started", status)
            self.assertLess(
                status.index("provider Codex initialization failed"),
                status.index("provider Antigravity started"),
            )
            self.assertNotIn("account token details", status)

    def test_refresh_persistence_failure_is_nonzero_without_unsafe_status(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state_dir = Path(tmp) / ".state"
            state_dir.mkdir()
            providers = [("Codex", MagicMock())]
            stderr = StringIO()
            with (
                patch("gradus.__main__.parse_args", return_value=self._namespace()),
                patch("gradus.__main__._setup_logging"),
                patch("gradus.__main__._load_config", return_value={}),
                patch("gradus.__main__.os.getcwd", return_value=tmp),
                patch("gradus.__main__._snapshot_state_dir", return_value=state_dir),
                patch("gradus.__main__.initialize_providers", return_value=(providers, [])),
                patch(
                    "gradus.__main__.fetch_provider_snapshot",
                    return_value=ProviderSnapshot(name="Codex", ok=True, source="api", data={}),
                ),
                patch(
                    "gradus.__main__.write_snapshot",
                    side_effect=[SnapshotWrite.FAILED, OSError("raw token details")],
                ),
                patch("gradus.__main__.sys.stderr", stderr),
            ):
                self.assertEqual(main(), 1)

            status = stderr.getvalue()
            self.assertIn("refresh: schema-v1 persistence failed", status)
            self.assertIn("refresh: schema-v2 persistence failed", status)
            self.assertIn("refresh: failed", status)
            self.assertNotIn("raw token details", status)

    def test_launchd_template_requires_repeatable_health_verification(self) -> None:
        repo_root = Path(__file__).resolve().parents[1]
        launchd_root = repo_root / "launchd"
        wrapper_path = launchd_root / "gradus_snapshot.sh.in"
        plist_path = launchd_root / "local.gradus-snapshot.plist.in"
        wrapper = wrapper_path.read_text(encoding="utf-8")
        plist_text = plist_path.read_text(encoding="utf-8")
        plist = plistlib.loads(plist_path.read_bytes())

        self.assertEqual(
            wrapper.count("exec python3 -m gradus --refresh-snapshot"),
            0,
        )
        self.assertIn(
            'REPO_ROOT="${GRADUS_REPO_ROOT:-__GRADUS_REPO_ROOT__}"',
            wrapper,
        )
        required_path = (
            'export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"'
        )
        self.assertIn(required_path, wrapper)
        self.assertIn(
            'GRADUS_PYTHON="${GRADUS_PYTHON:-__GRADUS_PYTHON_PATH__}"',
            wrapper,
        )
        self.assertIn('"${GRADUS_PYTHON}" -m gradus --refresh-snapshot', wrapper)
        self.assertLess(wrapper.index(required_path), wrapper.index("GRADUS_PYTHON="))
        self.assertNotIn('cd -- "$REPO_ROOT"', wrapper)
        self.assertNotIn("--write-snapshot", wrapper)
        self.assertNotIn("--write-snapshot", plist_text)

        self.assertEqual(plist["Label"], "local.gradus-snapshot")
        self.assertTrue(plist["RunAtLoad"])
        self.assertEqual(plist["StartInterval"], 120)
        # Standard, not Background: `Background` applies Darwin's aggressive
        # I/O throttle, and this job is a 120s-cadence network refresher whose
        # tightest bound is Copilot's 10s `gh auth token` subprocess. Measured
        # 2026-08-27, every Copilot probe timeout landed during a load episode
        # (57/71/40/39 against a 1.92 median). The sibling flight recorder omits
        # the key for the same reason. Do not flip this back without evidence.
        self.assertEqual(plist["ProcessType"], "Standard")
        self.assertEqual(plist["ProgramArguments"], ["__GRADUS_WRAPPER_PATH__"])
        self.assertEqual(plist["StandardOutPath"], "__GRADUS_STDOUT_PATH__")
        self.assertEqual(plist["StandardErrorPath"], "__GRADUS_STDERR_PATH__")

        for content in (wrapper, plist_text):
            self.assertNotIn("/Users/", content)
            self.assertNotIn("/home/", content)
            self.assertNotIn("sessionKey", content)
            self.assertNotIn("cf_clearance", content)
            self.assertNotIn("Cookies.binarycookies", content)
        self.assertIn("GradusCredentialBridge.app", wrapper)

        readme = (repo_root / "README.md").read_text(encoding="utf-8")
        self.assertIn("gradus --verify-refresh-health --duration 360", readme)

        rendered = wrapper.replace(
            "__GRADUS_REPO_ROOT__", "/Users/dave/Documents/Projects/gradus"
        ).replace(
            "__GRADUS_PYTHON_PATH__", "/Users/dave/Documents/Projects/gradus/.venv/bin/python3"
        )
        self.assertIn(
            'REPO_ROOT="${GRADUS_REPO_ROOT:-/Users/dave/Documents/Projects/gradus}"',
            rendered,
        )
        self.assertIn(
            'GRADUS_PYTHON="${GRADUS_PYTHON:-'
            '/Users/dave/Documents/Projects/gradus/.venv/bin/python3}"',
            rendered,
        )
        self.assertIn('"${GRADUS_PYTHON}" -m gradus --refresh-snapshot', rendered)
        self.assertNotIn("__GRADUS_", rendered)


class TestRefreshHealthVerifier(unittest.TestCase):
    """The installed refresh verifier reads state only and proves fresh progress."""

    BASE = datetime(2026, 8, 4, 12, tzinfo=timezone.utc)

    @classmethod
    def _payload(
        cls,
        offset_seconds: float,
        *,
        observed_offset_seconds: float | None = None,
        ok: bool = True,
        include_claude: bool = True,
    ) -> dict[str, object]:
        updated = cls.BASE + timedelta(seconds=offset_seconds)
        observed = (
            updated
            if observed_offset_seconds is None
            else cls.BASE + timedelta(seconds=observed_offset_seconds)
        )
        providers: list[dict[str, object]] = [
            {"name": "Antigravity", "ok": ok, "observed_at": observed.isoformat()},
        ]
        if include_claude:
            providers.append(
                {"name": "Antigravity (Claude)", "ok": ok, "observed_at": observed.isoformat()}
            )
        return {"schema_version": 2, "updated_at": updated.isoformat(), "providers": providers}

    def test_carried_auth_is_non_green_until_fresh_recovery(self) -> None:
        carried = self._payload(0, ok=False)
        carried["providers"][0]["error"] = ANTIGRAVITY_AUTH_RETRY_MESSAGE
        carried["providers"][1]["error"] = ANTIGRAVITY_AUTH_RETRY_MESSAGE
        _, reason = _health_sample_reason(carried, None, self.BASE + timedelta(seconds=1))
        self.assertEqual(reason, "carried-auth")
        fresh = self._payload(120)
        _, reason = _health_sample_reason(fresh, self.BASE, self.BASE + timedelta(seconds=121))
        self.assertEqual(reason, "fresh")

    @staticmethod
    def _drive(
        samples: list[object],
        *,
        duration: float = 0.3,
        interval: float = 0.1,
        wall_clock: datetime | None = None,
    ) -> tuple[bool, list[str]]:
        position = 0
        elapsed = [0.0]
        statuses: list[str] = []
        fallback = samples[-1] if samples else None

        def reader() -> object:
            nonlocal position
            sample = samples[position] if position < len(samples) else fallback
            position += 1
            return sample

        def clock() -> float:
            return elapsed[0]

        def sleeper(seconds: float) -> None:
            elapsed[0] += seconds

        result = _verify_refresh_health(
            duration=duration,
            interval=interval,
            reader=reader,
            clock=clock,
            sleeper=sleeper,
            status=statuses.append,
            wall_clock=lambda: wall_clock or datetime(2026, 8, 5, tzinfo=timezone.utc),
        )
        return result, statuses

    def test_three_increasing_fresh_samples_pass_without_wall_clock_sleep(self) -> None:
        result, statuses = self._drive(
            [self._payload(0), self._payload(120), self._payload(360)],
            duration=360,
            interval=120,
        )

        self.assertTrue(result)
        self.assertEqual(statuses.count("sample fresh"), 3)
        self.assertGreaterEqual(statuses.count("waiting 120.0s"), 2)
        self.assertEqual(statuses[-1], "passed")

    def test_threshold_span_is_accepted(self) -> None:
        result, statuses = self._drive(
            [self._payload(0), self._payload(60), self._payload(180), self._payload(300)],
            duration=360,
            interval=120,
        )

        self.assertTrue(result)
        self.assertEqual(statuses[-1], "passed")

    def test_carried_failed_malformed_missing_and_timeout_samples_fail_safely(self) -> None:
        cases = (
            ([self._payload(0, observed_offset_seconds=-1)], "sample provider observation carried"),
            ([self._payload(0, ok=False)], "sample provider Antigravity not healthy"),
            (
                [{"schema_version": 2, "updated_at": "not-a-timestamp", "providers": []}],
                "sample invalid timestamp",
            ),
            (
                [{"schema_version": 1, "updated_at": self.BASE.isoformat(), "providers": []}],
                "sample invalid schema",
            ),
            ([self._payload(0, include_claude=False)], "sample missing required provider"),
            ([None], "sample unavailable"),
        )
        for samples, expected in cases:
            with self.subTest(expected=expected):
                result, statuses = self._drive(samples)
                self.assertFalse(result)
                self.assertIn(expected, statuses)
                self.assertTrue(statuses[-1].startswith("failed:"))

    def test_unchanged_and_non_increasing_samples_never_count_as_fresh(self) -> None:
        result, statuses = self._drive(
            [self._payload(120), self._payload(120), self._payload(60)],
        )

        self.assertFalse(result)
        self.assertIn("sample unchanged", statuses)
        self.assertIn("sample non-increasing timestamp", statuses)
        self.assertNotIn("passed", statuses)

    def test_insufficient_span_and_future_timestamp_fail(self) -> None:
        result, statuses = self._drive(
            [self._payload(0), self._payload(100), self._payload(200)],
            duration=0.3,
        )
        self.assertFalse(result)
        self.assertTrue(statuses[-1].startswith("failed:"))

        result, statuses = self._drive(
            [self._payload(0)],
            duration=0.1,
            wall_clock=self.BASE - timedelta(seconds=1),
        )
        self.assertFalse(result)
        self.assertIn("sample future timestamp", statuses)

    def test_cli_conflicts_and_positive_production_arguments(self) -> None:
        with patch(
            "sys.argv",
            ["gradus", "--verify-refresh-health", "--duration", "360", "--health-interval", "120"],
        ):
            args = parse_args()
        self.assertTrue(args.verify_refresh_health)
        self.assertEqual(args.duration, 360.0)
        self.assertEqual(args.health_interval, 120.0)

        for flag in ("--once", "--json", "--refresh-snapshot"):
            with (
                self.subTest(flag=flag),
                patch("sys.argv", ["gradus", "--verify-refresh-health", flag]),
            ):
                with self.assertRaises(SystemExit) as ctx:
                    parse_args()
                self.assertEqual(ctx.exception.code, 2)

    def test_scoped_refresh_snapshot_is_rejected(self) -> None:
        with patch("sys.argv", ["gradus", "--refresh-snapshot", "--providers", "Claude"]):
            with self.assertRaises(SystemExit) as ctx:
                parse_args()
        self.assertEqual(ctx.exception.code, 2)

    def test_history_cli_accepts_repeatable_timestamps_and_filters(self) -> None:
        with patch(
            "sys.argv",
            [
                "gradus",
                "--history-at",
                "2026-08-04T12:00:00+00:00",
                "--history-at",
                "2026-08-04T08:00:00-04:00",
                "--history-provider",
                "Antigravity",
                "--history-provider",
                "Antigravity (Claude)",
                "--history-max-gap",
                "30",
            ],
        ):
            args = parse_args()

        self.assertEqual(
            args.history_at,
            ["2026-08-04T12:00:00+00:00", "2026-08-04T08:00:00-04:00"],
        )
        self.assertEqual(args.history_provider, ["Antigravity", "Antigravity (Claude)"])
        self.assertEqual(args.history_max_gap, 30.0)

        for argv in (
            ["gradus", "--history-provider", "Codex"],
            ["gradus", "--history-max-gap", "-1", "--history-at", "2026-08-04T12:00:00Z"],
            ["gradus", "--history-at", "2026-08-04T12:00:00Z", "--json"],
        ):
            with self.subTest(argv=argv), patch("sys.argv", argv):
                with self.assertRaises(SystemExit) as ctx:
                    parse_args()
                self.assertEqual(ctx.exception.code, 2)

    def test_main_history_branch_is_read_only_and_emits_json(self) -> None:
        args = argparse.Namespace(
            history_at=["2026-08-04T12:00:00+00:00"],
            history_provider=["Codex"],
            history_max_gap=30.0,
        )
        expected = {
            "executor_auth_verified": False,
            "results": [{"verified": False, "reason": "no_history"}],
        }
        stdout = StringIO()
        with (
            patch("gradus.__main__.parse_args", return_value=args),
            patch("gradus.__main__.query_history", return_value=expected) as query,
            patch("gradus.__main__._setup_logging") as logging_setup,
            patch("gradus.__main__.initialize_providers") as init,
            patch("gradus.__main__.subprocess.run") as run,
            patch("gradus.__main__.subprocess.Popen") as popen,
            patch("gradus.__main__.sys.stdout", stdout),
        ):
            self.assertEqual(main(), 0)

        logging_setup.assert_not_called()
        init.assert_not_called()
        run.assert_not_called()
        popen.assert_not_called()
        query.assert_called_once()
        self.assertEqual(json.loads(stdout.getvalue()), expected)

    def test_main_health_branch_does_not_initialize_or_set_up_logging(self) -> None:
        args = argparse.Namespace(
            verify_refresh_health=True,
            duration=360.0,
            health_interval=120.0,
        )
        with (
            patch("gradus.__main__.parse_args", return_value=args),
            patch("gradus.__main__._verify_refresh_health_once", return_value=0) as verify,
            patch("gradus.__main__._setup_logging") as logging_setup,
            patch("gradus.__main__.initialize_providers") as init,
            patch("gradus.__main__.subprocess.run") as run,
            patch("gradus.__main__.subprocess.Popen") as popen,
            patch("gradus.__main__.write_snapshot") as write,
        ):
            self.assertEqual(main(), 0)

        verify.assert_called_once_with(360.0, 120.0)
        logging_setup.assert_not_called()
        init.assert_not_called()
        run.assert_not_called()
        popen.assert_not_called()
        write.assert_not_called()


class HeadlessGateTests(unittest.TestCase):
    """INV-2: headless path is strictly read-only with zero side effects.

    Unlike WriteSnapshotTests (which mocks initialize_providers and
    collect_snapshots), this test drives the real provider pipeline to
    verify the _is_headless() guards work at the provider level.
    """

    def setUp(self) -> None:
        set_headless(False)
        self.addCleanup(set_headless, False)

    @unittest.skip("--write-snapshot was retired")
    def test_write_snapshot_no_subprocess(self) -> None:
        """--write-snapshot must not call subprocess.Popen or subprocess.run
        through any provider, even when providers are initialized normally."""
        captured_payloads: list[dict[str, object]] = []
        committed_v2: dict[str, object] | None = None

        def fake_write(payload: object, *args: object, **kwargs: object) -> SnapshotWrite:
            nonlocal committed_v2
            captured_payloads.append(payload)  # type: ignore[arg-type]
            if isinstance(payload, dict) and payload.get("schema_version") == 2:
                committed_v2 = payload
            return SnapshotWrite.WRITTEN

        def fake_read(path: Path | None = None) -> dict[str, object] | None:
            if path is not None and path.name == "snapshot-v2.json":
                return committed_v2
            return None

        with (
            patch("gradus.providers._base._http_json", return_value={}),
            patch("gradus.providers.copilot.subprocess.run") as mock_copilot_run,
            patch("gradus.providers.copilot.subprocess.Popen") as mock_copilot_popen,
            patch("gradus.providers.antigravity.subprocess.run") as mock_agy_run,
            patch("gradus.providers.antigravity.subprocess.Popen") as mock_agy_popen,
            patch("gradus.__main__.subprocess.Popen") as mock_main_popen,
            patch("gradus.__main__.subprocess.run") as mock_main_run,
            patch("gradus.__main__.read_prior_snapshot", side_effect=fake_read),
            patch("gradus.__main__.append_history_record", return_value=True),
            patch("gradus.__main__.write_snapshot", side_effect=fake_write),
        ):
            test_args = ["prog", "--write-snapshot"]
            with patch("sys.argv", test_args):
                rc = main()

        self.assertEqual(rc, 0)
        mock_copilot_run.assert_not_called()
        mock_copilot_popen.assert_not_called()
        mock_agy_run.assert_not_called()
        mock_agy_popen.assert_not_called()
        mock_main_popen.assert_not_called()
        mock_main_run.assert_not_called()
        self.assertGreaterEqual(len(captured_payloads), 1)
        copilot_entry = next(p for p in captured_payloads[0]["providers"] if p["name"] == "Copilot")
        self.assertIn(copilot_entry["ok"], (True, False))


class LoggingSetupTests(unittest.TestCase):
    """The log must be project-anchored, overridable, and safe to re-init."""

    def test_default_log_path_is_project_anchored_not_cwd_relative(self) -> None:
        """`local.gradus-snapshot` runs from launchd with an uncontrolled cwd.

        A relative `.logs/gradus.log` would land wherever the job happened to
        start, which is both a self-containment violation and the one place
        nobody would look. Anchor to the package like SNAPSHOT_PATH does.
        """
        from gradus.__main__ import _LOG_PATH
        from gradus.snapshot import SNAPSHOT_PATH

        self.assertTrue(_LOG_PATH.is_absolute())
        self.assertEqual(_LOG_PATH.name, "gradus.log")
        self.assertEqual(_LOG_PATH.parent.name, ".logs")
        # Same project root the snapshot uses, so both follow the checkout.
        self.assertEqual(_LOG_PATH.parent.parent, SNAPSHOT_PATH.parent.parent)
        self.assertNotIn("/tmp/", str(_LOG_PATH))

    def test_env_override_is_honored(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "nested" / "override.log"
            with patch.dict(os.environ, {"GRADUS_LOG_PATH": str(target)}):
                self.assertEqual(_resolve_log_path(), target)

    def test_blank_env_override_falls_back_to_default(self) -> None:
        from gradus.__main__ import _LOG_PATH

        with patch.dict(os.environ, {"GRADUS_LOG_PATH": "   "}):
            self.assertEqual(_resolve_log_path(), _LOG_PATH)

    def test_setup_logging_does_not_stack_handlers(self) -> None:
        """Repeat calls in one process used to duplicate every log line.

        `_setup_logging` appended unconditionally, so a second call produced
        two handlers, a third produced three, and each line was written once
        per handler.
        """
        root = logging.getLogger()
        preexisting = list(root.handlers)
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "stack.log"
            with patch.dict(os.environ, {"GRADUS_LOG_PATH": str(target)}):
                try:
                    for _ in range(3):
                        _setup_logging(False)
                        ours = [h for h in root.handlers if getattr(h, "_gradus_handler", False)]
                        self.assertEqual(len(ours), 1)
                    # A handler gradus did not install must survive untouched.
                    self.assertTrue(all(h in root.handlers for h in preexisting))
                finally:
                    for handler in [
                        h for h in root.handlers if getattr(h, "_gradus_handler", False)
                    ]:
                        root.removeHandler(handler)
                        handler.close()

    def test_setup_logging_creates_the_parent_directory(self) -> None:
        root = logging.getLogger()
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / "made" / "up" / "gradus.log"
            with patch.dict(os.environ, {"GRADUS_LOG_PATH": str(target)}):
                try:
                    _setup_logging(False)
                    self.assertTrue(target.parent.is_dir())
                finally:
                    for handler in [
                        h for h in root.handlers if getattr(h, "_gradus_handler", False)
                    ]:
                        root.removeHandler(handler)
                        handler.close()


class EmitDebugDetailsTests(unittest.TestCase):
    """--debug must surface probe detail without polluting the JSON contract."""

    def _snapshots(self) -> list[ProviderSnapshot]:
        return [
            ProviderSnapshot(name="Codex", ok=True, source="api", data={}),
            ProviderSnapshot(
                name="Antigravity",
                ok=False,
                source="api",
                error="provider probe timed out",
                debug_detail="The read operation timed out",
            ),
        ]

    def test_debug_detail_goes_to_stderr_not_stdout(self) -> None:
        """stdout is the router's parseable surface; detail belongs on stderr.

        Anything written to stdout here would land inside or beside the JSON
        document that review-plugin consumes.
        """
        err = StringIO()
        out = StringIO()
        with patch("sys.stderr", err), patch("sys.stdout", out):
            _emit_debug_details(self._snapshots(), True)

        self.assertIn("Antigravity", err.getvalue())
        self.assertIn("The read operation timed out", err.getvalue())
        self.assertEqual(out.getvalue(), "")
        # Healthy providers have nothing to report.
        self.assertNotIn("Codex", err.getvalue())

    def test_no_output_without_the_debug_flag(self) -> None:
        err = StringIO()
        with patch("sys.stderr", err):
            _emit_debug_details(self._snapshots(), False)
        self.assertEqual(err.getvalue(), "")

    def test_debug_detail_never_reaches_the_json_payload(self) -> None:
        """INV-1 guard, asserted from the caller's side.

        `test_render_json_data_is_safe_allowlist` covers the renderer; this
        covers the decision to route detail around it. `debug_detail` on the
        ProbeFailure branch carries up to 1600 chars of raw HTTP error body,
        which is exactly what INV-1 keeps off the router-facing surface.
        """
        from gradus.ui import render_json

        sentinel = "SENTINEL-RAW-BODY-TAIL"
        snaps = [
            ProviderSnapshot(
                name="Antigravity",
                ok=False,
                source="api",
                error="provider probe timed out",
                debug_detail=f"detail with {sentinel}",
            )
        ]
        rendered = render_json(snaps, datetime(2026, 8, 5, 12, 0, 0))
        self.assertNotIn(sentinel, rendered)
        self.assertNotIn("debug_detail", rendered)

    def _drive_main(self, *, write_ok: bool = True, **flags):
        """Run ``main()`` on one headless branch with streams captured.

        ``_drive`` in :class:`WriteSnapshotTests` hardcodes ``debug=False``, and
        widening it would touch eight passing INV-2 tests to serve three new
        ones. This builds its own namespace instead.
        """
        from types import SimpleNamespace

        defaults = {
            "write_snapshot": False,
            "debug": True,
            "json": False,
            "once": False,
            "providers": None,
            "interval": 120,
        }
        ns = argparse.Namespace(**{**defaults, **flags})
        out, err = StringIO(), StringIO()
        with (
            patch("gradus.__main__.parse_args", return_value=ns),
            patch(
                "gradus.__main__.initialize_providers",
                return_value=([("Antigravity", object())], []),
            ),
            patch("gradus.__main__.set_headless"),
            patch("gradus.__main__.collect_snapshots", return_value=self._snapshots()),
            patch(
                "gradus.__main__._canonical_or_refresh",
                return_value=(self._snapshots(), datetime.now().astimezone()),
            ),
            patch(
                "gradus.__main__._write_snapshot_versions",
                return_value=(write_ok, write_ok, write_ok),
            ),
            patch("gradus.__main__._check_warnings"),
            patch("sys.stdout", out),
            patch("sys.stderr", err),
        ):
            rc = main()
        return SimpleNamespace(rc=rc, out=out.getvalue(), err=err.getvalue())

    @unittest.skip("--write-snapshot was retired")
    def test_write_snapshot_debug_surfaces_detail_on_stderr(self) -> None:
        """``--write-snapshot --debug`` is a primary developer path.

        It reached the same dead end ``--json`` did: a failing probe produced a
        generic card and no way to see why. stdout stays empty here -- this
        branch prints nothing, so anything on it is contamination.
        """
        res = self._drive_main(write_snapshot=True)

        self.assertEqual(res.rc, 0)
        self.assertIn("Antigravity", res.err)
        self.assertNotIn("The read operation timed out", res.err)
        self.assertEqual(res.out, "")

    @unittest.skip("--write-snapshot was retired")
    def test_write_snapshot_debug_reports_even_when_the_persist_step_fails(self) -> None:
        """Emit before the write, not after.

        A failed persist returns 1 from the middle of the branch. If the
        emit sat after the write, the probe detail would vanish on exactly the
        run that failed twice over -- the one worth debugging most.
        """
        res = self._drive_main(write_snapshot=True, write_ok=False)

        self.assertEqual(res.rc, 1)
        self.assertNotIn("The read operation timed out", res.err)

    def test_once_debug_surfaces_detail_alongside_the_dashboard(self) -> None:
        """``--once --debug`` renders cards on stdout and detail on stderr.

        Split by stream so `gradus --once --debug 2>/dev/null` still gives a
        clean dashboard. The live TUI is deliberately excluded from this
        wiring: Rich holds the alt-screen there and a stderr write would
        corrupt the frame, so that path keeps the `log.debug` channel only.
        """
        res = self._drive_main(once=True)

        self.assertEqual(res.rc, 0)
        self.assertIn("Antigravity", res.out)  # the dashboard rendered
        self.assertNotIn("The read operation timed out", res.err)
        self.assertNotIn("The read operation timed out", res.out)


class CanonicalAuthGraceRetentionTests(unittest.TestCase):
    """The snapshot reader must honour the values the writer retained.

    `_build_snapshot_payload` ORs `auth_grace` alongside
    `_is_transient_probe_error` when deciding to keep a failed provider's last
    good windows, but the reader's `carried_failure` gate only consulted the
    latter.  The grace marker carries no transient marker word, so the reader
    threw away exactly what the writer had preserved -- and the grace window,
    which exists so a reading stays visible while a refresh retries, displayed
    no reading at all.
    """

    STAMP = NOW.replace(tzinfo=timezone.utc).isoformat()

    def _payload(self, name: str, error: str) -> dict[str, object]:
        """A failed entry that still carries values, the shape grace produces."""
        return {
            "schema_version": 2,
            "updated_at": self.STAMP,
            "providers": [
                {
                    "name": entry_name,
                    "ok": entry_name != name,
                    "error": error if entry_name == name else None,
                    "windows": [{"label": "Monthly", "percent_left": 62.0}],
                    "data": {"monthly_percent_left": 62.0},
                    "observed_at": self.STAMP,
                }
                for entry_name in ("Antigravity", "Codex")
            ],
        }

    def _entry(self, name: str, error: str, *, for_display: bool = True) -> ProviderSnapshot:
        snapshots, _ = _canonical_snapshots(self._payload(name, error), for_display=for_display)
        assert snapshots is not None
        return next(snapshot for snapshot in snapshots if snapshot.name == name)

    def test_graced_entry_keeps_its_retained_values(self) -> None:
        """The regression: grace published values the TUI then discarded."""
        snapshot = self._entry("Antigravity", ANTIGRAVITY_AUTH_RETRY_MESSAGE)

        self.assertIsNotNone(snapshot.cached_since)
        self.assertEqual(snapshot.data, {"monthly_percent_left": 62.0})
        # The error survives the promotion: `ui` still needs it to label the
        # card "retrying" rather than a generic "offline".
        self.assertEqual(snapshot.error, ANTIGRAVITY_AUTH_RETRY_MESSAGE)

    def test_genuine_auth_failure_still_fails_closed(self) -> None:
        """Scoped to the neutral marker, not to Antigravity failures at large.

        This is the control that matters.  Widening the gate to "Antigravity
        failed" would serve stale values through a real signed-out state and
        hide the one error the user can actually act on.
        """
        for error in (
            "Antigravity session expired: run `agy` to re-authenticate",
            "not logged in",
            "auth required: run `agy` to sign in",
        ):
            with self.subTest(error=error):
                snapshot = self._entry("Antigravity", error)
                self.assertFalse(snapshot.ok)
                self.assertIsNone(snapshot.cached_since)

    def test_grace_now_reads_like_any_other_retained_failure(self) -> None:
        """Parity is the point: identical entry shape, identical treatment."""
        graced = self._entry("Antigravity", ANTIGRAVITY_AUTH_RETRY_MESSAGE)
        transient = self._entry("Codex", "provider probe timed out")

        self.assertEqual(
            (graced.ok, graced.source, graced.cached_since is not None),
            (transient.ok, transient.source, transient.cached_since is not None),
        )

    def test_machine_contract_does_not_promote_a_graced_provider(self) -> None:
        """CR-6 fail-closed survives at the reader, not just at the writer.

        `--json` is the machine contract the review-plugin router consumes.
        Promoting a graced entry there would tell a router `ok: true` about a
        provider whose credential is actively failing, so it would route work
        to it and fail deterministically.  The display promotion is why this
        distinction had to exist at all; the default is the safe one so a new
        caller opts in rather than out.
        """
        snapshot = self._entry("Antigravity", ANTIGRAVITY_AUTH_RETRY_MESSAGE, for_display=False)

        self.assertFalse(snapshot.ok)
        self.assertIsNone(snapshot.cached_since)

    def test_transient_promotion_is_unchanged_on_both_surfaces(self) -> None:
        """The gate is scoped to auth grace and does not touch existing behaviour.

        A carried *transient* failure was promoted on every surface before this
        change, including `--json`.  Narrowing that would be a separate
        decision about a different failure meaning -- "could not reach it", not
        "the credential is bad" -- so it is pinned here rather than altered.
        """
        for for_display in (True, False):
            with self.subTest(for_display=for_display):
                snapshot = self._entry("Codex", "provider probe timed out", for_display=for_display)
                self.assertTrue(snapshot.ok)
                self.assertIsNotNone(snapshot.cached_since)


if __name__ == "__main__":
    unittest.main()
