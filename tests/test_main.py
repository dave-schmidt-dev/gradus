"""Entrypoint regression tests."""

from __future__ import annotations

import argparse
import json
import subprocess
import unittest
from io import StringIO
from unittest.mock import MagicMock, patch

from rich.console import Console

from ai_monitor.__main__ import (
    AUTH_ACTIONS,
    STALE_THRESHOLD_SECONDS,
    _build_fix_actions,
    _is_auth_error,
    _is_transient_probe_error,
    _launch_fix,
    _merge_with_previous,
    main,
)
from ai_monitor.providers import ProviderSnapshot
from ai_monitor.ui import THEME, build_dashboard


class MainOnceTests(unittest.TestCase):
    """Test --once mode: no Live context, prints dashboard via Console.print."""

    def test_once_prints_dashboard_without_live(self) -> None:
        snapshots = [
            ProviderSnapshot(
                name="Codex",
                ok=True,
                source="cli",
                data={"five_hour_percent_left": 75},
            )
        ]

        with (
            patch(
                "ai_monitor.__main__.parse_args",
                return_value=argparse.Namespace(json=False, once=True, debug=False, interval=120),
            ),
            patch("ai_monitor.__main__.initialize_providers", return_value=([], [])),
            patch("ai_monitor.__main__.collect_snapshots", return_value=snapshots),
            patch("ai_monitor.__main__.Console") as MockConsole,
        ):
            mock_console = MagicMock()
            MockConsole.return_value = mock_console
            rc = main()

        self.assertEqual(rc, 0)
        mock_console.print.assert_called_once()

    def test_once_does_not_use_live_context(self) -> None:
        """--once must never enter alt-screen (no Live)."""
        snapshots = [
            ProviderSnapshot(
                name="Codex",
                ok=True,
                source="cli",
                data={"five_hour_percent_left": 75},
            )
        ]

        with (
            patch(
                "ai_monitor.__main__.parse_args",
                return_value=argparse.Namespace(json=False, once=True, debug=False, interval=120),
            ),
            patch("ai_monitor.__main__.initialize_providers", return_value=([], [])),
            patch("ai_monitor.__main__.collect_snapshots", return_value=snapshots),
            patch("ai_monitor.__main__.Console") as MockConsole,
            patch("ai_monitor.__main__.Live") as MockLive,
        ):
            MockConsole.return_value = MagicMock()
            main()

        MockLive.assert_not_called()


class MainJsonTests(unittest.TestCase):
    """Test --json mode: writes JSON to stdout, no Console or Live."""

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
                "ai_monitor.__main__.parse_args",
                return_value=argparse.Namespace(json=True, once=False, debug=False, interval=120),
            ),
            patch("ai_monitor.__main__.initialize_providers", return_value=([], [])),
            patch("ai_monitor.__main__.collect_snapshots", return_value=snapshots),
            patch("ai_monitor.__main__.sys.stdout", buf),
        ):
            rc = main()

        self.assertEqual(rc, 0)
        payload = json.loads(buf.getvalue())
        self.assertIn("updated_at", payload)
        self.assertIn("providers", payload)
        self.assertEqual(len(payload["providers"]), 2)

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
                "ai_monitor.__main__.parse_args",
                return_value=argparse.Namespace(json=True, once=False, debug=False, interval=120),
            ),
            patch("ai_monitor.__main__.initialize_providers", return_value=([], [])),
            patch("ai_monitor.__main__.collect_snapshots", return_value=snapshots),
            patch("ai_monitor.__main__.sys.stdout", buf),
        ):
            main()

        self.assertNotIn("\033[", buf.getvalue())


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
            name="Gemini", ok=False, source="api", error="AUTH FAILED: run gemini to fix"
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

    def test_all_five_providers_in_auth_actions(self) -> None:
        expected = {"Claude", "Codex", "Gemini", "Cursor", "Vibe"}
        self.assertEqual(set(AUTH_ACTIONS.keys()), expected)

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
        # `_launch_fix` embeds the target via f-string into a double-quoted AppleScript literal:
        #   'tell application "Terminal" to do script "{target}"'
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
        # ai_monitor/providers.py:1182
        snap = ProviderSnapshot(
            name="Claude",
            ok=False,
            source="api",
            error="Claude session expired — visit claude.ai to refresh",
        )
        self.assertTrue(_is_auth_error(snap))

    def test_cursor_session_expired_routes_to_cta(self) -> None:
        # ai_monitor/providers.py:702
        snap = ProviderSnapshot(
            name="Cursor",
            ok=False,
            source="api",
            error="Cursor session expired. Log into cursor.com to refresh.",
        )
        self.assertTrue(_is_auth_error(snap))

    def test_vibe_session_expired_routes_to_cta(self) -> None:
        # ai_monitor/providers.py:484 — provider name "Vibe" per AUTH_ACTIONS
        snap = ProviderSnapshot(
            name="Vibe",
            ok=False,
            source="api",
            error="Mistral session expired. Log into console.mistral.ai to refresh.",
        )
        self.assertTrue(_is_auth_error(snap))


class BuildFixActionsTests(unittest.TestCase):
    def test_single_auth_error(self) -> None:
        snaps = [
            ProviderSnapshot(name="Gemini", ok=False, source="api", error="auth failed"),
        ]
        actions = _build_fix_actions(snaps)
        self.assertEqual(actions, {"1": ("Gemini", "cli", "agy")})

    def test_multiple_auth_errors_alphabetical(self) -> None:
        snaps = [
            ProviderSnapshot(name="Gemini", ok=False, source="api", error="auth failed"),
            ProviderSnapshot(name="Claude", ok=False, source="api", error="authenticate required"),
            ProviderSnapshot(
                name="Codex", ok=True, source="api", data={"five_hour_percent_left": 80}
            ),
        ]
        actions = _build_fix_actions(snaps)
        self.assertEqual(actions["1"], ("Claude", "cli", "claude login"))
        self.assertEqual(actions["2"], ("Gemini", "cli", "agy"))
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
            ProviderSnapshot(name="Gemini", ok=False, source="api", error="sign in required"),
        ]
        actions = _build_fix_actions(snaps)
        self.assertEqual(len(actions), 1)
        self.assertEqual(actions["1"], ("Gemini", "cli", "agy"))

    def test_browser_action_type(self) -> None:
        snaps = [
            ProviderSnapshot(
                name="Cursor", ok=False, source="api", error="please login to continue"
            ),
        ]
        actions = _build_fix_actions(snaps)
        self.assertEqual(actions["1"], ("Cursor", "browser", "https://cursor.sh"))


class LaunchFixTests(unittest.TestCase):
    def test_cli_launches_osascript_with_activate(self) -> None:
        with patch("ai_monitor.__main__.subprocess.Popen") as mock_popen:
            _launch_fix("cli", "gh auth login")
        mock_popen.assert_called_once()
        args = mock_popen.call_args[0][0]
        self.assertEqual(args[0], "osascript")
        # First -e activates Terminal, second -e runs the command
        self.assertIn("activate", args[2])
        self.assertIn("gh auth login", args[4])
        # stdout/stderr suppressed
        kwargs = mock_popen.call_args[1]
        self.assertEqual(kwargs.get("stdout"), subprocess.DEVNULL)
        self.assertEqual(kwargs.get("stderr"), subprocess.DEVNULL)

    def test_browser_launches_open(self) -> None:
        with patch("ai_monitor.__main__.subprocess.Popen") as mock_popen:
            _launch_fix("browser", "https://cursor.sh")
        mock_popen.assert_called_once()
        args = mock_popen.call_args[0][0]
        self.assertEqual(args, ["open", "https://cursor.sh"])
        kwargs = mock_popen.call_args[1]
        self.assertEqual(kwargs.get("stdout"), subprocess.DEVNULL)

    def test_unknown_kind_is_noop(self) -> None:
        with patch("ai_monitor.__main__.subprocess.Popen") as mock_popen:
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


if __name__ == "__main__":
    unittest.main()
