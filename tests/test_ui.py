"""UI rendering tests — Rich-based rendering pipeline."""

from __future__ import annotations

import json
import unittest
from datetime import datetime
from io import StringIO

from rich.console import Console

from ai_monitor.providers import ProviderSnapshot
from ai_monitor.ui import (
    THEME,
    PaceLabel,
    PercentageBar,
    _compact_pace,
    _format_reset_display,
    _style_for_percent,
    build_dashboard,
    build_loading_screen,
    build_provider_panel,
    render_json,
)


def _capture(renderable, *, width: int = 80) -> str:
    """Render a Rich renderable to plain text via Console capture."""
    console = Console(
        file=StringIO(),
        theme=THEME,
        force_terminal=True,
        width=width,
        no_color=True,
    )
    console.print(renderable)
    return console.file.getvalue()


class StyleForPercentTests(unittest.TestCase):
    def test_green_threshold(self) -> None:
        self.assertEqual(_style_for_percent(75), "bar.green")
        self.assertEqual(_style_for_percent(70), "bar.green")

    def test_yellow_threshold(self) -> None:
        self.assertEqual(_style_for_percent(45), "bar.yellow")
        self.assertEqual(_style_for_percent(40), "bar.yellow")

    def test_orange_threshold(self) -> None:
        self.assertEqual(_style_for_percent(25), "bar.orange")
        self.assertEqual(_style_for_percent(20), "bar.orange")

    def test_red_threshold(self) -> None:
        self.assertEqual(_style_for_percent(10), "bar.red")
        self.assertEqual(_style_for_percent(0), "bar.red")

    def test_none_returns_muted(self) -> None:
        self.assertEqual(_style_for_percent(None), "text.muted")


class PercentageBarTests(unittest.TestCase):
    def test_filled_bar_contains_block_chars(self) -> None:
        output = _capture(PercentageBar(68.0, "bar.green"), width=40)
        self.assertIn("▓", output)
        self.assertIn("█", output)
        self.assertIn("░", output)

    def test_none_renders_dots(self) -> None:
        output = _capture(PercentageBar(None, "text.muted"), width=30)
        self.assertIn("·", output)
        self.assertNotIn("▓", output)

    def test_zero_renders_all_empty(self) -> None:
        output = _capture(PercentageBar(0.0, "bar.red"), width=20)
        self.assertNotIn("▓", output)
        self.assertIn("░", output)

    def test_hundred_renders_all_filled(self) -> None:
        output = _capture(PercentageBar(100.0, "bar.green"), width=20)
        self.assertNotIn("░", output)
        self.assertIn("█", output)


class PaceLabelTests(unittest.TestCase):
    def test_wide_console_renders_full_text(self) -> None:
        output = _capture(PaceLabel("under +5pt"), width=120)
        self.assertIn("under +5pt", output)
        self.assertNotIn("↑", output)

    def test_narrow_console_renders_up_arrow_for_under(self) -> None:
        output = _capture(PaceLabel("under +5pt"), width=60)
        self.assertIn("↑5pt", output)
        self.assertNotIn("under", output)

    def test_narrow_console_renders_down_arrow_for_over(self) -> None:
        output = _capture(PaceLabel("over -3pt"), width=60)
        self.assertIn("↓3pt", output)
        self.assertNotIn("over", output)

    def test_narrow_console_collapses_on_pace_to_equals(self) -> None:
        output = _capture(PaceLabel("on pace"), width=60)
        self.assertIn("=", output)

    def test_narrow_console_collapses_na_to_em_dash(self) -> None:
        output = _capture(PaceLabel("n/a"), width=60)
        self.assertIn("—", output)
        self.assertNotIn("n/a", output)

    def test_wide_console_at_boundary_minus_one_still_compacts(self) -> None:
        # _NARROW_CONSOLE_WIDTH = 93 → width 92 must compact, width 93 must not.
        narrow = _capture(PaceLabel("under +5pt"), width=92)
        self.assertIn("↑5pt", narrow)
        self.assertNotIn("under", narrow)
        wide = _capture(PaceLabel("under +5pt"), width=93)
        self.assertIn("under +5pt", wide)
        self.assertNotIn("↑", wide)

    def test_unknown_pace_text_passes_through_compact(self) -> None:
        # _compact_pace falls back to the original string for unrecognized input.
        self.assertEqual(_compact_pace("totally bogus"), "totally bogus")
        self.assertEqual(_compact_pace(""), "")
        # And PaceLabel renders that unchanged even when narrow.
        output = _capture(PaceLabel("totally bogus"), width=60)
        self.assertIn("totally bogus", output)


class ProviderPanelTests(unittest.TestCase):
    def setUp(self) -> None:
        self.now = datetime(2026, 3, 14, 8, 22, 30)
        self.codex_data = {
            "five_hour_percent_left": 68,
            "five_hour_reset": "Resets 1:16 PM (EDT)",
            "weekly_percent_left": 91,
            "weekly_reset": "Resets Mar 17 at 9 PM",
        }
        self.claude_data = {
            "session_percent_left": 73,
            "primary_reset": "Resets 1:16 PM (EDT)",
            "weekly_percent_left": 64,
            "secondary_reset": "Resets Mar 17 at 8 PM",
        }
        self.gemini_data = {
            "flash_percent_left": 98,
            "flash_reset": "resets in 15h 36m",
            "pro_percent_left": 83,
            "pro_reset": "resets in 22h 23m",
        }

    def test_codex_panel_contains_labels_and_values(self) -> None:
        snap = ProviderSnapshot(name="Codex", ok=True, source="cli", data=self.codex_data)
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertIn("Codex", output)
        self.assertIn("5h", output)
        self.assertIn("1w", output)
        self.assertIn("68%", output)
        self.assertIn("91%", output)

    def test_claude_panel_contains_labels(self) -> None:
        snap = ProviderSnapshot(name="Claude", ok=True, source="cli", data=self.claude_data)
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertIn("Claude", output)
        self.assertIn("5h", output)
        self.assertIn("1w", output)
        self.assertIn("73%", output)

    def test_gemini_panel_shows_flash_and_pro(self) -> None:
        # Canonical provider key stays "Gemini"; the panel now renders as
        # "Antigravity" (agy), which draws from the same Gemini request-quota pool.
        snap = ProviderSnapshot(name="Gemini", ok=True, source="cli", data=self.gemini_data)
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertIn("Antigravity", output)
        self.assertNotIn("Gemini", output)
        self.assertIn("fl", output)
        self.assertIn("pr", output)

    def test_error_panel_shows_error_message(self) -> None:
        snap = ProviderSnapshot(name="Claude", ok=False, source="cli", error="connection timeout")
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertIn("Claude", output)
        self.assertIn("error", output)
        self.assertIn("connection timeout", output)

    def test_cursor_panel_shows_credit_metrics(self) -> None:
        snap = ProviderSnapshot(
            name="Cursor",
            ok=True,
            source="api",
            data={
                "credit_percent_left": 82.5,
                "plan_name": "pro",
                "billing_cycle_end": "Resets Apr 30 at 8:00 PM",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertIn("Cursor", output)
        self.assertIn("ap", output)
        self.assertIn("82%", output)
        self.assertNotIn("pl", output)
        self.assertNotIn("pro", output)

    def test_vibe_panel_shows_monthly_usage(self) -> None:
        snap = ProviderSnapshot(
            name="Vibe",
            ok=True,
            source="api",
            data={
                "usage_percent": 1.17,
                "reset_at": "Resets Apr 30 at 8:00 PM",
                "payg_enabled": False,
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertIn("Vibe", output)
        self.assertIn("mo", output)
        self.assertIn("99%", output)

    def test_empty_view_codex_weekly_zero(self) -> None:
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 72,
                "five_hour_reset": "Resets 1:16 PM",
                "weekly_percent_left": 0,
                "weekly_reset": "Resets Mar 17 at 9 PM",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=70)
        # both rows show "until"; no bars anywhere — 5h is still blocked by 1w
        self.assertIn("until", output)
        self.assertIn("1w", output)
        self.assertIn("5h", output)
        self.assertNotIn("▓", output)
        self.assertNotIn("72%", output)

    def test_empty_view_codex_five_hour_zero(self) -> None:
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0,
                "five_hour_reset": "Resets 1:16 PM",
                "weekly_percent_left": 88,
                "weekly_reset": "Resets Mar 17 at 9 PM",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=70)
        # both rows show "until"; 1w's 88% is irrelevant — blocked by 5h
        self.assertIn("until", output)
        self.assertIn("5h", output)
        self.assertIn("1w", output)
        self.assertNotIn("▓", output)
        self.assertNotIn("88%", output)

    def test_empty_view_gemini_requires_both_zero(self) -> None:
        # fl=0 but pr has usage → normal view
        snap = ProviderSnapshot(
            name="Gemini",
            ok=True,
            source="cli",
            data={
                "flash_percent_left": 0,
                "flash_reset": "Resets at 23:58",
                "pro_percent_left": 83,
                "pro_reset": "Resets Mar 15 at 06:45",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=50)
        self.assertNotIn("until", output)
        self.assertIn("▓", output)

    def test_empty_view_gemini_both_zero(self) -> None:
        snap = ProviderSnapshot(
            name="Gemini",
            ok=True,
            source="cli",
            data={
                "flash_percent_left": 0,
                "flash_reset": "Resets at 23:58",
                "pro_percent_left": 0,
                "pro_reset": "Resets Mar 15 at 06:45",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=50)
        self.assertIn("until", output)
        self.assertIn("fl", output)
        self.assertIn("pr", output)
        self.assertNotIn("▓", output)

    def test_empty_view_claude_weekly_zero(self) -> None:
        snap = ProviderSnapshot(
            name="Claude",
            ok=True,
            source="cli",
            data={
                "session_percent_left": 65,
                "primary_reset": "Resets 3:00 PM",
                "weekly_percent_left": 0,
                "secondary_reset": "Resets Mar 17 at 9 PM",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=70)
        self.assertIn("until", output)
        self.assertIn("1w", output)
        self.assertIn("5h", output)
        self.assertNotIn("▓", output)
        self.assertNotIn("65%", output)

    def test_empty_view_claude_five_hour_zero(self) -> None:
        snap = ProviderSnapshot(
            name="Claude",
            ok=True,
            source="cli",
            data={
                "session_percent_left": 0,
                "primary_reset": "Resets 3:00 PM",
                "weekly_percent_left": 91,
                "secondary_reset": "Resets Mar 17 at 9 PM",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=70)
        self.assertIn("until", output)
        self.assertIn("5h", output)
        self.assertIn("1w", output)
        self.assertNotIn("▓", output)
        self.assertNotIn("91%", output)

    def test_empty_view_cursor(self) -> None:
        snap = ProviderSnapshot(
            name="Cursor",
            ok=True,
            source="api",
            data={
                "credit_percent_left": 0,
                "billing_cycle_end": "Resets Apr 30 at 8:00 PM",
                "plan_name": "pro",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=70)
        self.assertIn("ap", output)
        self.assertIn("until", output)
        self.assertNotIn("▓", output)
        self.assertNotIn("pl", output)
        self.assertNotIn("pro", output)

    def test_empty_view_vibe(self) -> None:
        snap = ProviderSnapshot(
            name="Vibe",
            ok=True,
            source="api",
            data={
                "usage_percent": 100,
                "reset_at": "Resets Apr 30 at 8:00 PM",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=70)
        self.assertIn("until", output)
        self.assertNotIn("▓", output)

    def test_cached_shows_offline_in_title(self) -> None:
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="cli (cached)",
            data=self.codex_data,
            cached_since=datetime(2026, 3, 14, 8, 19, 0),
        )
        output = _capture(build_provider_panel(snap, self.now), width=50)
        self.assertIn("offline", output)
        self.assertIn("3m", output)

    def test_stale_panel_shows_yellow_message(self) -> None:
        snap = ProviderSnapshot(
            name="Claude",
            ok=False,
            source="api",
            error="stale — offline for 7m",
        )
        output = _capture(build_provider_panel(snap, self.now), width=50)
        self.assertIn("stale", output)
        self.assertIn("7m", output)
        # Stale panels should NOT show "error:" prefix
        self.assertNotIn("error:", output)


class DashboardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.now = datetime(2026, 3, 14, 8, 22, 30)
        self.codex_snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 68,
                "five_hour_reset": "Resets 1:16 PM (EDT)",
                "weekly_percent_left": 91,
                "weekly_reset": "Resets Mar 17 at 9 PM",
            },
        )
        self.claude_snap = ProviderSnapshot(
            name="Claude",
            ok=True,
            source="cli",
            data={
                "session_percent_left": 73,
                "primary_reset": "Resets 1:16 PM (EDT)",
                "weekly_percent_left": 64,
                "secondary_reset": "Resets Mar 17 at 8 PM",
            },
        )

    def test_dashboard_shows_header_and_footer(self) -> None:
        dashboard = build_dashboard([self.codex_snap], self.now, 30)
        output = _capture(dashboard, width=80)
        self.assertIn("AI Usage Monitor", output)
        self.assertIn("↻ 30s", output)
        self.assertIn("[q]", output)

    def test_dashboard_updating_badge(self) -> None:
        dashboard = build_dashboard(
            [self.codex_snap], self.now, 0, updating=True, update_elapsed=1.4
        )
        output = _capture(dashboard, width=80)
        self.assertIn("↻ 1.4s", output)

    def test_two_column_grid_at_wide_width(self) -> None:
        dashboard = build_dashboard([self.codex_snap, self.claude_snap], self.now, 30)
        output = _capture(dashboard, width=92)
        # Both provider names should appear on the same line in a 2-column grid
        self.assertIn("Codex", output)
        self.assertIn("Claude", output)
        lines = output.splitlines()
        self.assertTrue(
            any("Codex" in line and "Claude" in line for line in lines),
            "Expected Codex and Claude on the same line in 2-column grid",
        )

    def test_single_panel_at_narrow_width(self) -> None:
        dashboard = build_dashboard([self.codex_snap], self.now, 30)
        output = _capture(dashboard, width=50)
        self.assertIn("Codex", output)


class LoadingScreenTests(unittest.TestCase):
    def test_loading_screen_content(self) -> None:
        now = datetime(2026, 3, 14, 8, 22, 30)
        screen = build_loading_screen("Fetching data...", now, 2.3)
        output = _capture(screen, width=80)
        self.assertIn("Warming Up", output)
        self.assertIn("Starting up 2.3s", output)
        self.assertIn("Fetching data...", output)


class FormatResetDisplayTests(unittest.TestCase):
    def setUp(self) -> None:
        self.now = datetime(2026, 3, 14, 8, 22, 30)

    def test_normalizes_24_hour_same_day_times(self) -> None:
        value = _format_reset_display("Resets 13:16", self.now)
        self.assertEqual(value, "13:16")

    def test_normalizes_relative_times(self) -> None:
        value = _format_reset_display("Resets in 2h 14m", self.now)
        self.assertEqual(value, "10:36")

    def test_normalizes_date_stamped_provider_formats(self) -> None:
        cases = {
            "Resets on Mar 18, 9:00AM": "Mar 18 09:00",
            "resets 03:09 on 17 Mar": "Mar 17 03:09",
            "Resets Mar 17 at 4 pm": "Mar 17 16:00",
            "Resets 10pm (EDT)": "22:00",
        }
        for raw, expected in cases.items():
            with self.subTest(raw=raw):
                self.assertEqual(_format_reset_display(raw, self.now), expected)


class RenderJsonTests(unittest.TestCase):
    def test_includes_canonical_reset_display_fields(self) -> None:
        now = datetime(2026, 3, 14, 8, 22, 30)
        snapshots = [
            ProviderSnapshot(
                name="Codex",
                ok=True,
                source="cli",
                data={
                    "five_hour_percent_left": 68,
                    "five_hour_reset": "Resets 1:16 PM (EDT)",
                    "weekly_percent_left": 91,
                    "weekly_reset": "Resets Mar 17 at 9 PM",
                },
            ),
            ProviderSnapshot(
                name="Claude",
                ok=True,
                source="cli",
                data={
                    "session_percent_left": 73,
                    "primary_reset": "Resets 1:16 PM (EDT)",
                    "weekly_percent_left": 64,
                    "secondary_reset": "Resets Mar 17 at 8 PM",
                },
            ),
        ]

        payload = json.loads(render_json(snapshots, now))

        codex = next(p for p in payload["providers"] if p["name"] == "Codex")
        claude = next(p for p in payload["providers"] if p["name"] == "Claude")

        self.assertEqual(codex["display"]["five_hour_reset_display"], "13:16")
        self.assertEqual(codex["display"]["weekly_reset_display"], "Mar 17 21:00")
        self.assertEqual(claude["display"]["five_hour_reset_display"], "13:16")
        self.assertEqual(claude["display"]["weekly_reset_display"], "Mar 17 20:00")


class SharedLabelAlignmentTests(unittest.TestCase):
    """Verify that all windowed providers use the same label pipeline."""

    def test_codex_and_claude_share_same_labels(self) -> None:
        now = datetime(2026, 3, 14, 8, 22, 30)
        codex_snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 68,
                "five_hour_reset": "Resets 1:16 PM (EDT)",
                "weekly_percent_left": 91,
                "weekly_reset": "Resets Mar 17 at 9 PM",
            },
        )
        claude_snap = ProviderSnapshot(
            name="Claude",
            ok=True,
            source="cli",
            data={
                "session_percent_left": 73,
                "primary_reset": "Resets 1:16 PM (EDT)",
                "weekly_percent_left": 64,
                "secondary_reset": "Resets Mar 17 at 8 PM",
            },
        )

        dashboard = build_dashboard([codex_snap, claude_snap], now, 30)
        output = _capture(dashboard, width=92)

        # Each window label appears once per provider (2 providers → 2 occurrences each)
        for label in ("5h", "1w"):
            self.assertEqual(
                output.count(label),
                2,
                f"Expected label '{label}' to appear exactly 2 times",
            )


class NoANSIRegressionTests(unittest.TestCase):
    """Verify the rendering pipeline never emits raw ANSI escape codes."""

    def _assert_no_ansi(self, output: str) -> None:
        self.assertNotIn("\033[", output, "Raw ANSI escape found in captured output")

    def test_provider_panel_no_ansi_in_captured_output(self) -> None:
        now = datetime(2026, 3, 14, 8, 22, 30)
        for name, data in (
            ("Codex", {"five_hour_percent_left": 50, "weekly_percent_left": 80}),
            ("Claude", {"session_percent_left": 30, "weekly_percent_left": 90}),
            ("Gemini", {"flash_percent_left": 75, "pro_percent_left": 60}),
        ):
            with self.subTest(provider=name):
                snap = ProviderSnapshot(name=name, ok=True, source="cli", data=data)
                output = _capture(build_provider_panel(snap, now), width=44)
                self._assert_no_ansi(output)

    def test_error_panel_no_ansi(self) -> None:
        now = datetime(2026, 3, 14, 8, 22, 30)
        snap = ProviderSnapshot(name="Claude", ok=False, source="cli", error="rate limited")
        output = _capture(build_provider_panel(snap, now), width=44)
        self._assert_no_ansi(output)

    def test_dashboard_no_ansi(self) -> None:
        now = datetime(2026, 3, 14, 8, 22, 30)
        snaps = [
            ProviderSnapshot(
                name="Codex",
                ok=True,
                source="cli",
                data={"five_hour_percent_left": 50, "weekly_percent_left": 80},
            ),
            ProviderSnapshot(name="Claude", ok=False, source="cli", error="timeout"),
        ]
        output = _capture(build_dashboard(snaps, now, 60), width=92)
        self._assert_no_ansi(output)

    def test_loading_screen_no_ansi(self) -> None:
        now = datetime(2026, 3, 14, 8, 22, 30)
        output = _capture(build_loading_screen("loading...", now, 1.5), width=80)
        self._assert_no_ansi(output)


class NarrowTerminalTests(unittest.TestCase):
    """Verify rendering doesn't crash at narrow widths."""

    def test_panel_at_minimum_width(self) -> None:
        now = datetime(2026, 3, 14, 8, 22, 30)
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="cli",
            data={"five_hour_percent_left": 50, "weekly_percent_left": 80},
        )
        output = _capture(build_provider_panel(snap, now), width=30)
        self.assertIn("Codex", output)

    def test_provider_panel_pace_cell_uses_arrow_at_narrow_width(self) -> None:
        # End-to-end: confirm PaceLabel inside build_provider_panel actually
        # collapses to arrow notation when rendered at a narrow console width.
        # 50% remaining on a 5h window with reset 1h away → "under" pace.
        now = datetime(2026, 3, 14, 8, 22, 30)
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 50,
                "five_hour_reset": "Resets 9:22 AM",
                "weekly_percent_left": 80,
                "weekly_reset": "Resets Mar 21 at 8:22 AM",
            },
        )
        narrow = _capture(build_provider_panel(snap, now), width=44)
        # At 44 cols the pace cell must be compacted — no "under"/"over" words.
        self.assertNotIn("under", narrow)
        self.assertNotIn("over", narrow)
        # Either an arrow, equals, or em dash must appear in the pace column.
        self.assertTrue(
            any(token in narrow for token in ("↑", "↓", "=", "—")),
            "Expected compact pace token (arrow/=/—) at narrow width",
        )

    def test_dashboard_single_column_at_narrow_width(self) -> None:
        now = datetime(2026, 3, 14, 8, 22, 30)
        snaps = [
            ProviderSnapshot(
                name="Codex",
                ok=True,
                source="cli",
                data={"five_hour_percent_left": 50},
            ),
            ProviderSnapshot(
                name="Claude",
                ok=True,
                source="cli",
                data={"session_percent_left": 30},
            ),
        ]
        # At narrow width, should still render without error
        output = _capture(build_dashboard(snaps, now, 30), width=40)
        self.assertIn("Codex", output)
        self.assertIn("Claude", output)


class CountdownDisplayTests(unittest.TestCase):
    """Verify countdown values render correctly in the dashboard header."""

    def test_countdown_shows_padded_seconds(self) -> None:
        now = datetime(2026, 3, 14, 8, 22, 30)
        snap = ProviderSnapshot(
            name="Codex", ok=True, source="cli", data={"five_hour_percent_left": 50}
        )
        for seconds in (120, 60, 5, 1):
            with self.subTest(seconds=seconds):
                dashboard = build_dashboard([snap], now, seconds)
                output = _capture(dashboard, width=80)
                self.assertIn(f"↻ {seconds}s", output)

    def test_updating_shows_elapsed(self) -> None:
        now = datetime(2026, 3, 14, 8, 22, 30)
        snap = ProviderSnapshot(
            name="Codex", ok=True, source="cli", data={"five_hour_percent_left": 50}
        )
        dashboard = build_dashboard([snap], now, 0, updating=True, update_elapsed=3.7)
        output = _capture(dashboard, width=80)
        self.assertIn("↻ 3.7s", output)


class AuthFixPanelTests(unittest.TestCase):
    def setUp(self) -> None:
        self.now = datetime(2026, 3, 14, 8, 22, 30)

    def test_auth_error_shows_cta_with_key(self) -> None:
        snap = ProviderSnapshot(
            name="Gemini", ok=False, source="api", error="auth failed: run gemini"
        )
        panel = build_provider_panel(snap, self.now, auth_fix_key="1")
        output = _capture(panel, width=60)
        self.assertIn("auth error", output)
        self.assertIn("[1]", output)
        self.assertIn("to fix", output)
        # Raw error text should NOT appear
        self.assertNotIn("run gemini", output)

    def test_non_auth_error_shows_raw_error(self) -> None:
        snap = ProviderSnapshot(name="Claude", ok=False, source="api", error="connection timeout")
        panel = build_provider_panel(snap, self.now, auth_fix_key=None)
        output = _capture(panel, width=60)
        self.assertIn("error:", output)
        self.assertIn("connection timeout", output)
        self.assertNotIn("to fix", output)

    def test_auth_error_keeps_red_border(self) -> None:
        snap = ProviderSnapshot(name="Claude", ok=False, source="api", error="authenticate failed")
        panel = build_provider_panel(snap, self.now, auth_fix_key="2")
        # Panel border_style is set to "text.red" — verify by checking the Panel object
        self.assertEqual(panel.border_style, "text.red")

    def test_auth_fix_key_none_on_error_shows_normal_error(self) -> None:
        """When auth_fix_key is not passed, error panel is unchanged from current behavior."""
        snap = ProviderSnapshot(name="Codex", ok=False, source="api", error="HTTP 500 server error")
        panel = build_provider_panel(snap, self.now)
        output = _capture(panel, width=60)
        self.assertIn("error:", output)
        self.assertIn("HTTP 500 server error", output)


class AuthFixFooterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.now = datetime(2026, 3, 14, 8, 22, 30)

    def test_footer_shows_fix_hints(self) -> None:
        snaps = [
            ProviderSnapshot(name="Gemini", ok=False, source="api", error="auth failed"),
            ProviderSnapshot(
                name="Codex", ok=True, source="api", data={"five_hour_percent_left": 80}
            ),
        ]
        fix_actions = {"1": ("Gemini", "cli", "agy")}
        dashboard = build_dashboard(snaps, self.now, 30, fix_actions=fix_actions)
        output = _capture(dashboard, width=80)
        self.assertIn("[1]", output)
        self.assertIn("fix Gemini", output)
        # Standard hints still present
        self.assertIn("[q]", output)
        self.assertIn("[r]", output)

    def test_footer_multiple_fix_hints_in_order(self) -> None:
        snaps = [
            ProviderSnapshot(name="Gemini", ok=False, source="api", error="auth failed"),
            ProviderSnapshot(name="Cursor", ok=False, source="api", error="login required"),
        ]
        fix_actions = {
            "1": ("Cursor", "browser", "https://cursor.sh"),
            "2": ("Gemini", "cli", "agy"),
        }
        dashboard = build_dashboard(snaps, self.now, 30, fix_actions=fix_actions)
        output = _capture(dashboard, width=100)
        self.assertIn("[1]", output)
        self.assertIn("fix Cursor", output)
        self.assertIn("[2]", output)
        self.assertIn("fix Gemini", output)

    def test_footer_no_fix_hints_when_empty(self) -> None:
        snaps = [
            ProviderSnapshot(
                name="Codex", ok=True, source="api", data={"five_hour_percent_left": 80}
            ),
        ]
        dashboard = build_dashboard(snaps, self.now, 30, fix_actions={})
        output = _capture(dashboard, width=80)
        self.assertNotIn("fix", output)

    def test_footer_no_fix_hints_when_none(self) -> None:
        snaps = [
            ProviderSnapshot(
                name="Codex", ok=True, source="api", data={"five_hour_percent_left": 80}
            ),
        ]
        dashboard = build_dashboard(snaps, self.now, 30)
        output = _capture(dashboard, width=80)
        self.assertNotIn("fix", output)

    def test_auth_error_panel_gets_cta_in_dashboard(self) -> None:
        """Verify the panel inside the dashboard shows the CTA, not raw error."""
        snaps = [
            ProviderSnapshot(name="Gemini", ok=False, source="api", error="auth failed"),
        ]
        fix_actions = {"1": ("Gemini", "cli", "agy")}
        dashboard = build_dashboard(snaps, self.now, 30, fix_actions=fix_actions)
        output = _capture(dashboard, width=80)
        self.assertIn("auth error", output)
        self.assertIn("[1]", output)
        self.assertIn("to fix", output)
        # Raw error should not appear in the panel body
        self.assertNotIn("auth failed", output)


if __name__ == "__main__":
    unittest.main()
