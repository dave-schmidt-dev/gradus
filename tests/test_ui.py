"""UI rendering tests — Rich-based rendering pipeline."""

from __future__ import annotations

import json
import unittest
from datetime import datetime
from io import StringIO

from rich.console import Console

from ai_monitor.providers import ProviderSnapshot
from ai_monitor.snapshot import SAFE_DATA_KEYS
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
        self.antigravity_data = {
            "five_hour_percent_left": 86,
            "five_hour_reset": "resets in 3h 19m",
            "weekly_percent_left": 96,
            "weekly_reset": "resets in 5d 18h",
        }

    def test_codex_panel_contains_labels_and_values(self) -> None:
        snap = ProviderSnapshot(name="Codex", ok=True, source="cli", data=self.codex_data)
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertIn("Codex", output)
        self.assertIn("5h", output)
        self.assertIn("1w", output)
        self.assertIn("68%", output)
        self.assertIn("91%", output)

    def test_normal_rows_preserve_full_percentages_across_card_widths(self) -> None:
        # The Antigravity panel stays in normal mode because the non-zero C+G
        # window remains usable. That gives one card all three integer widths:
        # 0%, 87%, and 100%.
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0,
                "five_hour_reset": "Resets 9:22 AM",
                "weekly_percent_left": 100,
                "weekly_reset": "Resets Mar 21 at 8:22 AM",
                "third_party_five_hour_percent_left": 87,
                "third_party_five_hour_reset": "Resets 9:22 AM",
            },
        )
        for width in (44, 40, 30):
            with self.subTest(width=width):
                output = _capture(build_provider_panel(snap, self.now), width=width)
                self.assertIn("0%", output)
                self.assertIn("87%", output)
                self.assertIn("100%", output)

    def test_normal_row_bar_shrinks_to_zero_before_percentage_is_clipped(self) -> None:
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0,
                "five_hour_reset": "Resets 9:22 AM",
                "weekly_percent_left": 100,
                "weekly_reset": "Resets Mar 21 at 8:22 AM",
                "third_party_five_hour_percent_left": 87,
                "third_party_five_hour_reset": "Resets 9:22 AM",
            },
        )
        wide = _capture(build_provider_panel(snap, self.now), width=44)
        zero_bar = _capture(build_provider_panel(snap, self.now), width=40)

        self.assertIn("▓", wide)
        self.assertNotIn("▓", zero_bar)
        self.assertNotIn("░", zero_bar)
        self.assertIn("0%", zero_bar)
        self.assertIn("87%", zero_bar)
        self.assertIn("100%", zero_bar)

    def test_normal_row_bars_share_card_level_start_and_end_columns(self) -> None:
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 50,
                "five_hour_reset": "Resets 9:22 AM",
                "weekly_percent_left": 75,
                "weekly_reset": "Resets Mar 21 at 8:22 AM",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=44)
        usage_lines = [line for line in output.splitlines() if "5h" in line or "1w" in line]
        self.assertEqual(len(usage_lines), 2)

        # Filled blocks begin at the bar's common left edge; reset text starts
        # immediately after its common right edge.
        self.assertEqual(usage_lines[0].index("▓"), usage_lines[1].index("▓"))
        self.assertEqual(usage_lines[0].index("09:22"), usage_lines[1].index("Mar 21"))

    def test_depleted_rows_keep_reset_text_at_normal_bar_boundary(self) -> None:
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0,
                "five_hour_reset": "Resets 9:22 AM",
                "weekly_percent_left": 0,
                "weekly_reset": "Resets Mar 17 at 9 PM",
            },
        )

        # Width 40 is where normal cards have already given their bar no
        # budget. Depleted rows instead reserve that space for "until <reset>".
        output = _capture(build_provider_panel(snap, self.now), width=40)

        self.assertIn("5h   0%   until 09:22", output)
        self.assertIn("1w   0%   until Mar 17 21:00", output)
        self.assertNotIn("▓", output)

    def test_generic_card_preserves_key_value_layout_without_usage_bar(self) -> None:
        snap = ProviderSnapshot(
            name="Custom",
            ok=True,
            source="script",
            data={"account": "team", "remaining": "unknown"},
        )
        output = _capture(build_provider_panel(snap, self.now), width=40)

        self.assertIn("status", output)
        self.assertIn("source", output)
        self.assertIn("script", output)
        self.assertIn("team", output)
        self.assertIn("unknown", output)
        self.assertNotIn("▓", output)

    def test_error_card_remains_a_message_without_usage_bar(self) -> None:
        snap = ProviderSnapshot(name="Claude", ok=False, source="cli", error="connection timeout")
        output = _capture(build_provider_panel(snap, self.now), width=44)

        self.assertIn("error:", output)
        self.assertIn("connection timeout", output)
        self.assertNotIn("▓", output)

    def test_auth_card_remains_a_message_without_usage_bar(self) -> None:
        snap = ProviderSnapshot(name="Claude", ok=False, source="cli", error="login required")
        output = _capture(build_provider_panel(snap, self.now, auth_fix_key="2"), width=44)

        self.assertIn("auth error", output)
        self.assertIn("[2]", output)
        self.assertIn("to fix", output)
        self.assertNotIn("▓", output)

    def test_codex_panel_omits_absent_five_hour_row(self) -> None:
        # After OpenAI removed the 5h window the provider reports it as None; the
        # card must drop the 5h row entirely rather than render "5h  n/a".
        data = {
            "five_hour_percent_left": None,
            "five_hour_reset": None,
            "weekly_percent_left": 91,
            "weekly_reset": "Resets Mar 17 at 9 PM",
        }
        snap = ProviderSnapshot(name="Codex", ok=True, source="cli", data=data)
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertIn("Codex", output)
        self.assertIn("1w", output)
        self.assertIn("91%", output)
        self.assertNotIn("5h", output)
        self.assertNotIn("n/a", output)

    def test_claude_panel_contains_labels(self) -> None:
        snap = ProviderSnapshot(name="Claude", ok=True, source="cli", data=self.claude_data)
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertIn("Claude", output)
        self.assertIn("5h", output)
        self.assertIn("1w", output)
        self.assertIn("73%", output)

    def test_antigravity_panel_shows_five_hour_and_weekly(self) -> None:
        # Antigravity (agy) is now a first-class provider: grouped quota with a
        # 5-hour and a weekly window for the Gemini model group.
        snap = ProviderSnapshot(
            name="Antigravity", ok=True, source="cli", data=self.antigravity_data
        )
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertIn("Antigravity", output)
        self.assertNotIn("Gemini", output)
        self.assertIn("5h", output)
        self.assertIn("1w", output)
        self.assertIn("86%", output)
        self.assertIn("96%", output)

    def test_antigravity_active_cg_windows_render_with_reset_and_pace(self) -> None:
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                **self.antigravity_data,
                "third_party_five_hour_percent_left": 55,
                "third_party_five_hour_reset": "Resets 9:22 AM",
                "third_party_weekly_percent_left": 72,
                "third_party_weekly_reset": "Resets Mar 21 at 8:22 AM",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=80)
        self.assertIn("cg5", output)
        self.assertIn("cg1w", output)
        self.assertIn("55%", output)
        self.assertIn("72%", output)
        self.assertIn("09:22", output)
        self.assertIn("Mar 21 08:22", output)
        self.assertTrue(any(token in output for token in ("↑", "↓", "=")))

    def test_antigravity_hides_idle_cg_windows_at_exactly_hundred(self) -> None:
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                **self.antigravity_data,
                "third_party_five_hour_percent_left": 100.0,
                "third_party_weekly_percent_left": 100,
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertNotIn("cg5", output)
        self.assertNotIn("cg1w", output)

    def test_antigravity_cg_raw_99_point_9_is_not_treated_as_idle(self) -> None:
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                **self.antigravity_data,
                "third_party_five_hour_percent_left": 99.9,
                "third_party_five_hour_reset": "Resets 9:22 AM",
                "third_party_weekly_percent_left": 100.0,
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertIn("cg5", output)
        self.assertIn("100%", output)
        self.assertNotIn("cg1w", output)

    def test_antigravity_omits_missing_or_malformed_cg_windows_independently(self) -> None:
        for invalid_value in (None, "unknown"):
            with self.subTest(invalid_value=invalid_value):
                data = {
                    **self.antigravity_data,
                    "third_party_weekly_percent_left": 64,
                    "third_party_weekly_reset": "Resets Mar 21 at 8:22 AM",
                }
                if invalid_value is not None:
                    data["third_party_five_hour_percent_left"] = invalid_value
                snap = ProviderSnapshot(name="Antigravity", ok=True, source="cli", data=data)
                output = _capture(build_provider_panel(snap, self.now), width=44)
                self.assertNotIn("cg5", output)
                self.assertIn("cg1w", output)
                self.assertIn("64%", output)

    def test_antigravity_depleted_gemini_does_not_hide_usable_cg_rows(self) -> None:
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0,
                "five_hour_reset": "Resets 9:22 AM",
                "weekly_percent_left": 0,
                "weekly_reset": "Resets Mar 21 at 8:22 AM",
                "third_party_five_hour_percent_left": 42,
                "third_party_five_hour_reset": "Resets 9:22 AM",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertIn("cg5", output)
        self.assertIn("42%", output)
        self.assertIn("▓", output)
        self.assertNotIn("until", output)

    def test_antigravity_cg_rows_remain_readable_at_44_columns(self) -> None:
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                **self.antigravity_data,
                "third_party_five_hour_percent_left": 55,
                "third_party_weekly_percent_left": 72,
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertIn("cg5", output)
        self.assertIn("cg1w", output)
        self.assertTrue(all(len(line) <= 44 for line in output.splitlines()))

    def test_antigravity_cg_warning_adds_badge_without_changing_gemini_rows(self) -> None:
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                **self.antigravity_data,
                "third_party_five_hour_percent_left": 0,
                "third_party_five_hour_reset": "Resets 9:22 AM",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertIn("[!]", output)
        self.assertIn("5h", output)
        self.assertIn("1w", output)
        self.assertIn("86%", output)
        self.assertIn("96%", output)

    def test_error_panel_shows_error_message(self) -> None:
        snap = ProviderSnapshot(name="Claude", ok=False, source="cli", error="connection timeout")
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertIn("Claude", output)
        self.assertIn("error", output)
        self.assertIn("connection timeout", output)

    def test_cursor_panel_shows_auto_composer_and_api_remaining_metrics(self) -> None:
        snap = ProviderSnapshot(
            name="Cursor",
            ok=True,
            source="api",
            data={
                "credit_percent_left": 82.5,
                "auto_percent_used": 6.6,
                "api_percent_used": 1.5,
                "plan_name": "pro",
                "billing_cycle_end": "Resets Apr 30 at 8:00 PM",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertIn("Cursor", output)
        self.assertIn("ac", output)
        self.assertIn("ap", output)
        self.assertIn("82%", output)
        self.assertIn("93%", output)
        self.assertNotIn("98%", output)
        self.assertNotIn("pl", output)
        self.assertNotIn("pro", output)

    def test_cursor_badge_marks_independent_warning_pool(self) -> None:
        one_warning = ProviderSnapshot(
            name="Cursor",
            ok=True,
            source="api",
            data={"auto_percent_used": 100, "credit_percent_left": 82},
        )
        no_warning = ProviderSnapshot(
            name="Cursor",
            ok=True,
            source="api",
            data={"auto_percent_used": 99.7, "credit_percent_left": 82},
        )

        warning_output = _capture(build_provider_panel(one_warning, self.now), width=44)
        no_warning_output = _capture(build_provider_panel(no_warning, self.now), width=44)

        self.assertIn("[!]", warning_output)
        self.assertNotIn("[!]", no_warning_output)

    def test_cursor_badge_allows_api_pool_to_warn_independently(self) -> None:
        snap = ProviderSnapshot(
            name="Cursor",
            ok=True,
            source="api",
            data={"credit_percent_left": 0},
        )
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertIn("[!]", output)

    def test_cursor_boolean_pool_values_render_as_absent(self) -> None:
        snap = ProviderSnapshot(
            name="Cursor",
            ok=True,
            source="api",
            data={"auto_percent_used": True, "credit_percent_left": False},
        )
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertNotIn("[!]", output)
        self.assertNotIn("0%", output)
        self.assertEqual(output.count("n/a"), 4)

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

    def test_empty_view_codex_weekly_zero_without_five_hour(self) -> None:
        # Weekly depleted and the 5h window removed: the depleted view shows only
        # the 1w row — no phantom "5h until …" row for a window that's gone.
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": None,
                "five_hour_reset": None,
                "weekly_percent_left": 0,
                "weekly_reset": "Resets Mar 17 at 9 PM",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=70)
        self.assertIn("until", output)
        self.assertIn("1w", output)
        self.assertNotIn("5h", output)

    def test_empty_view_antigravity_requires_both_zero(self) -> None:
        # 5h=0 but weekly has usage → normal view
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0,
                "five_hour_reset": "Resets at 23:58",
                "weekly_percent_left": 83,
                "weekly_reset": "Resets Mar 15 at 06:45",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=50)
        self.assertNotIn("until", output)
        self.assertIn("▓", output)

    def test_empty_view_antigravity_both_zero(self) -> None:
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0,
                "five_hour_reset": "Resets at 23:58",
                "weekly_percent_left": 0,
                "weekly_reset": "Resets Mar 15 at 06:45",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=50)
        self.assertIn("until", output)
        self.assertIn("5h", output)
        self.assertIn("1w", output)
        self.assertNotIn("▓", output)

    def test_empty_view_antigravity_includes_depleted_cg_rows(self) -> None:
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0,
                "five_hour_reset": "Resets at 23:58",
                "weekly_percent_left": 0,
                "weekly_reset": "Resets Mar 15 at 06:45",
                "third_party_five_hour_percent_left": 0,
                "third_party_five_hour_reset": "Resets at 23:58",
                "third_party_weekly_percent_left": 0,
                "third_party_weekly_reset": "Resets Mar 15 at 06:45",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=50)
        self.assertIn("cg5", output)
        self.assertIn("cg1w", output)
        self.assertIn("until", output)
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
                "auto_percent_used": 100,
                "credit_percent_left": 0,
                "billing_cycle_end": "Resets Apr 30 at 8:00 PM",
                "plan_name": "pro",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=70)
        self.assertIn("ac", output)
        self.assertIn("ap", output)
        self.assertIn("until", output)
        self.assertEqual(output.count("until"), 2)
        self.assertNotIn("▓", output)
        self.assertNotIn("pl", output)
        self.assertNotIn("pro", output)

    def test_empty_view_cursor_api_pool_zero(self) -> None:
        snap = ProviderSnapshot(
            name="Cursor",
            ok=True,
            source="api",
            data={
                "auto_percent_used": 10,
                "credit_percent_left": 0,
                "billing_cycle_end": "Resets Apr 30 at 8:00 PM",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=70)
        self.assertIn("ac", output)
        self.assertIn("ap", output)
        self.assertNotIn("until", output)
        self.assertIn("90%", output)

    def test_empty_view_cursor_omits_absent_pool(self) -> None:
        snap = ProviderSnapshot(
            name="Cursor",
            ok=True,
            source="api",
            data={
                "credit_percent_left": 0,
                "billing_cycle_end": "Resets Apr 30 at 8:00 PM",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=70)
        self.assertIn("ap", output)
        self.assertNotIn("ac", output)
        self.assertEqual(output.count("until"), 1)

    def test_cursor_auto_composer_zero_keeps_api_pool_available(self) -> None:
        snap = ProviderSnapshot(
            name="Cursor",
            ok=True,
            source="api",
            data={
                "auto_percent_used": 100,
                "credit_percent_left": 82,
                "billing_cycle_end": "Resets Apr 30 at 8:00 PM",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=70)
        self.assertIn("ac", output)
        self.assertIn("ap", output)
        self.assertNotIn("until", output)
        self.assertIn("82%", output)

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
        first_panel_line = next(line for line in lines if line.startswith("╭"))
        self.assertEqual(len(first_panel_line), 92)

    def test_packed_cards_place_next_provider_below_shorter_stack(self) -> None:
        short_codex = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="cli",
            data={"weekly_percent_left": 91, "weekly_reset": "Resets Mar 17 at 9 PM"},
        )
        antigravity = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 75,
                "five_hour_reset": "Resets 1:16 PM",
                "weekly_percent_left": 60,
                "weekly_reset": "Resets Mar 17 at 9 PM",
            },
        )

        output = _capture(
            build_dashboard([short_codex, self.claude_snap, antigravity], self.now, 30),
            width=92,
        )
        lines = output.splitlines()
        codex_title = next(index for index, line in enumerate(lines) if "Codex" in line)
        antigravity_title = next(index for index, line in enumerate(lines) if "Antigravity" in line)

        # Codex is one row shorter than Claude, so Antigravity starts directly
        # below Codex while Claude is still finishing in the opposite stack.
        self.assertEqual(antigravity_title, codex_title + 3)
        self.assertTrue(lines[antigravity_title - 1].startswith("╰"))
        self.assertTrue(lines[antigravity_title].startswith("╭"))

    def test_five_provider_packing_keeps_every_card_and_no_vertical_gutter(self) -> None:
        antigravity = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 75,
                "five_hour_reset": "Resets 1:16 PM",
                "weekly_percent_left": 60,
                "weekly_reset": "Resets Mar 17 at 9 PM",
                "third_party_five_hour_percent_left": 50,
                "third_party_five_hour_reset": "Resets 1:16 PM",
            },
        )
        cursor = ProviderSnapshot(
            name="Cursor",
            ok=True,
            source="api",
            data={
                "auto_percent_used": 20,
                "credit_percent_left": 60,
                "billing_cycle_end": "Resets Mar 30 at 9 PM",
            },
        )
        vibe = ProviderSnapshot(
            name="Vibe",
            ok=True,
            source="api",
            data={"usage_percent": 10, "reset_at": "Resets Mar 30 at 9 PM"},
        )

        output = _capture(
            build_dashboard(
                [self.codex_snap, self.claude_snap, antigravity, cursor, vibe], self.now, 30
            ),
            width=92,
        )
        lines = output.splitlines()
        for name in ("Codex", "Claude", "Antigravity", "Cursor", "Vibe"):
            self.assertEqual(output.count(name), 1)

        first_panel_line = next(index for index, line in enumerate(lines) if line.startswith("╭"))
        last_panel_line = max(index for index, line in enumerate(lines) if line.startswith("╰"))
        self.assertTrue(all(line.strip() for line in lines[first_panel_line : last_panel_line + 1]))

    def test_dashboard_falls_back_to_one_column_below_safe_threshold(self) -> None:
        output = _capture(
            build_dashboard([self.codex_snap, self.claude_snap], self.now, 30), width=91
        )
        self.assertFalse(any("Codex" in line and "Claude" in line for line in output.splitlines()))
        self.assertEqual(output.count("Codex"), 1)
        self.assertEqual(output.count("Claude"), 1)

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

    def test_render_json_data_is_safe_allowlist(self) -> None:
        # INV-1: render_json must project snap.data through the same
        # SAFE_DATA_KEYS allowlist the persisted snapshot uses — no raw
        # identity/credential/debug fields may leak onto the --json surface.
        now = datetime(2026, 3, 14, 8, 22, 30)
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "account_email": "leak@example.com",
                "raw_text": "SECRET-RAW-BODY",
                "five_hour_percent_left": 42,
            },
            debug_detail="SECRET-DEBUG-DETAIL raw body tail",
        )

        raw_output = render_json([snap], now)
        payload = json.loads(raw_output)

        provider = next(p for p in payload["providers"] if p["name"] == "Antigravity")
        self.assertTrue(set(provider["data"]).issubset(SAFE_DATA_KEYS))
        self.assertNotIn("account_email", provider["data"])
        self.assertNotIn("raw_text", provider["data"])
        self.assertEqual(provider["data"]["five_hour_percent_left"], 42)

        self.assertNotIn("SECRET-RAW-BODY", raw_output)
        self.assertNotIn("SECRET-DEBUG-DETAIL", raw_output)

        for entry in payload["providers"]:
            self.assertNotIn("debug_detail", entry)

    def test_render_json_excludes_cursor_raw_pool_fields(self) -> None:
        now = datetime(2026, 3, 14, 8, 22, 30)
        cursor = ProviderSnapshot(
            name="Cursor",
            ok=True,
            source="api",
            data={
                "credit_percent_left": 82.5,
                "auto_percent_used": 6.6,
                "api_percent_used": 1.5,
                "session_token": "must-not-leak",
            },
        )

        payload = json.loads(render_json([cursor], now))
        data = payload["providers"][0]["data"]

        self.assertEqual(data["credit_percent_left"], 82.5)
        self.assertNotIn("auto_percent_used", data)
        self.assertNotIn("api_percent_used", data)
        self.assertNotIn("session_token", data)


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
            ("Antigravity", {"five_hour_percent_left": 75, "weekly_percent_left": 60}),
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
            name="Antigravity", ok=False, source="api", error="auth failed: run agy"
        )
        panel = build_provider_panel(snap, self.now, auth_fix_key="1")
        output = _capture(panel, width=60)
        self.assertIn("auth error", output)
        self.assertIn("[1]", output)
        self.assertIn("to fix", output)
        # Raw error text should NOT appear
        self.assertNotIn("run agy", output)

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
            ProviderSnapshot(name="Antigravity", ok=False, source="api", error="auth failed"),
            ProviderSnapshot(
                name="Codex", ok=True, source="api", data={"five_hour_percent_left": 80}
            ),
        ]
        fix_actions = {"1": ("Antigravity", "cli", "agy")}
        dashboard = build_dashboard(snaps, self.now, 30, fix_actions=fix_actions)
        output = _capture(dashboard, width=80)
        self.assertIn("[1]", output)
        self.assertIn("fix Antigravity", output)
        # Standard hints still present
        self.assertIn("[q]", output)
        self.assertIn("[r]", output)

    def test_footer_multiple_fix_hints_in_order(self) -> None:
        snaps = [
            ProviderSnapshot(name="Antigravity", ok=False, source="api", error="auth failed"),
            ProviderSnapshot(name="Cursor", ok=False, source="api", error="login required"),
        ]
        fix_actions = {
            "1": ("Cursor", "browser", "https://cursor.sh"),
            "2": ("Antigravity", "cli", "agy"),
        }
        dashboard = build_dashboard(snaps, self.now, 30, fix_actions=fix_actions)
        output = _capture(dashboard, width=100)
        self.assertIn("[1]", output)
        self.assertIn("fix Cursor", output)
        self.assertIn("[2]", output)
        self.assertIn("fix Antigravity", output)

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
            ProviderSnapshot(name="Antigravity", ok=False, source="api", error="auth failed"),
        ]
        fix_actions = {"1": ("Antigravity", "cli", "agy")}
        dashboard = build_dashboard(snaps, self.now, 30, fix_actions=fix_actions)
        output = _capture(dashboard, width=80)
        self.assertIn("auth error", output)
        self.assertIn("[1]", output)
        self.assertIn("to fix", output)
        # Raw error should not appear in the panel body
        self.assertNotIn("auth failed", output)


if __name__ == "__main__":
    unittest.main()


# ---------------------------------------------------------------------------
# Characterization tests — pin exact string output BEFORE refactor
# ---------------------------------------------------------------------------
from ai_monitor.ui import _billing_cycle_pace_label, _pace_label  # noqa: E402


class PaceLabelCharacterizationTests(unittest.TestCase):
    """Pin the exact return values of _pace_label and _billing_cycle_pace_label.

    These tests must stay green across any refactor that preserves existing
    behavior.  Do NOT change the expected literals — if they fail after a
    refactor, the refactor changed visible output.
    """

    def setUp(self) -> None:
        self.now = datetime(2026, 3, 14, 8, 22, 30)

    # ------------------------------------------------------------------
    # _pace_label — 5-hour window, reset "Resets in 2h 30m"
    # remaining_fraction = 2.5h / 5.0h = 0.50
    # ------------------------------------------------------------------

    def test_pace_label_na_when_percent_left_is_none(self) -> None:
        result = _pace_label(None, "Resets in 2h 30m", self.now, 5.0)
        self.assertEqual(result, "n/a")

    def test_pace_label_na_when_reset_text_is_none(self) -> None:
        result = _pace_label(50, None, self.now, 5.0)
        self.assertEqual(result, "n/a")

    def test_pace_label_on_pace_when_pct_matches_remaining_fraction(self) -> None:
        # 50% left, 50% of window remaining → delta=0.0 → on pace
        result = _pace_label(50, "Resets in 2h 30m", self.now, 5.0)
        self.assertEqual(result, "on pace")

    def test_pace_label_under_when_more_budget_than_time(self) -> None:
        # 60% left, 50% of window remaining → delta=+0.10 → under +10pt
        result = _pace_label(60, "Resets in 2h 30m", self.now, 5.0)
        self.assertEqual(result, "under +10pt")

    def test_pace_label_over_when_less_budget_than_time(self) -> None:
        # 40% left, 50% of window remaining → delta=-0.10 → over -10pt
        result = _pace_label(40, "Resets in 2h 30m", self.now, 5.0)
        self.assertEqual(result, "over -10pt")

    # ------------------------------------------------------------------
    # _billing_cycle_pace_label — tz-aware UTC billing cycle
    # 2026-03-01..2026-04-01, now=2026-03-14T08:22:30 → ~57% remaining
    # ------------------------------------------------------------------

    def test_billing_cycle_pace_label_on_pace_tzaware(self) -> None:
        result = _billing_cycle_pace_label(
            60,
            "2026-03-01T00:00:00+00:00",
            "2026-04-01T00:00:00+00:00",
            self.now,
        )
        self.assertEqual(result, "on pace")

    def test_billing_cycle_pace_label_under_tzaware(self) -> None:
        result = _billing_cycle_pace_label(
            70,
            "2026-03-01T00:00:00+00:00",
            "2026-04-01T00:00:00+00:00",
            self.now,
        )
        self.assertEqual(result, "under +13pt")

    def test_billing_cycle_pace_label_over_tzaware(self) -> None:
        result = _billing_cycle_pace_label(
            50,
            "2026-03-01T00:00:00+00:00",
            "2026-04-01T00:00:00+00:00",
            self.now,
        )
        self.assertEqual(result, "over -7pt")

    # ------------------------------------------------------------------
    # _billing_cycle_pace_label — naive date-only billing cycle
    # 2026-03-01..2026-03-20, now=2026-03-14T08:22:30 → ~29.7% remaining
    # ------------------------------------------------------------------

    def test_billing_cycle_pace_label_on_pace_naive(self) -> None:
        result = _billing_cycle_pace_label(30, "2026-03-01", "2026-03-20", self.now)
        self.assertEqual(result, "on pace")

    def test_billing_cycle_pace_label_under_naive(self) -> None:
        result = _billing_cycle_pace_label(35, "2026-03-01", "2026-03-20", self.now)
        self.assertEqual(result, "under +5pt")

    def test_billing_cycle_pace_label_over_naive(self) -> None:
        result = _billing_cycle_pace_label(20, "2026-03-01", "2026-03-20", self.now)
        self.assertEqual(result, "over -10pt")
