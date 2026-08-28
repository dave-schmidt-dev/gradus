"""UI rendering tests — Rich-based rendering pipeline."""

from __future__ import annotations

import json
import math
import pathlib
import re
import unittest
from datetime import datetime
from io import StringIO

from rich.console import Console
from rich.text import Text

from gradus.providers import ProviderSnapshot
from gradus.snapshot import (
    ANTIGRAVITY_AUTH_RETRY_MESSAGE,
    SAFE_DATA_KEYS,
    percent_is_depleted,
    signal_level,
    window_warns,
)
from gradus.ui import (
    _FILL_GLYPH,
    THEME,
    DynamicMicroDepletedPair,
    DynamicMicroDepletedSingle,
    PaceLabel,
    PercentageBar,
    _build_compact_lines,
    _compact_pace,
    _compact_window_parts,
    _expected_remaining,
    _extract_depleted_reset_str,
    _format_pace_delta,
    _format_percent_value,
    _format_reset_display,
    _percent_str,
    _provider_is_empty,
    _ResponsiveDashboardBody,
    _style_for_signal,
    build_dashboard,
    build_loading_screen,
    build_micro_depleted_panel,
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
        _environ={"TERM": "xterm-256color"},
    )
    console.print(renderable)
    return console.file.getvalue()


def _marker_cells(percent: float, expected_remaining: float | None, *, width: int) -> list[int]:
    """Cell indices carrying the marker style, found by style rather than glyph.

    The marker is drawn with the bar's own fill glyph, so nothing in the plain
    text distinguishes it — only its style does. Any test that looked for a
    distinct marker character would now match every filled cell in the bar.
    """
    console = Console(
        file=StringIO(),
        theme=THEME,
        force_terminal=True,
        width=width,
        _environ={"TERM": "xterm-256color"},
    )
    rendered = next(
        PercentageBar(percent, "bar.green", expected_remaining=expected_remaining).__rich_console__(
            console, console.options
        )
    )
    assert isinstance(rendered, Text)
    return [
        index
        for index in range(len(rendered.plain))
        for span in rendered.spans
        if span.style == "bar.marker" and span.start <= index < span.end
    ]


def _capture_colored(renderable, *, width: int = 80) -> str:
    """Render keeping ANSI colour, which is the only way to see the marker."""
    console = Console(
        file=StringIO(),
        theme=THEME,
        force_terminal=True,
        width=width,
        _environ={"TERM": "xterm-256color"},
    )
    console.print(renderable)
    return console.file.getvalue()


_MARKER_ANSI = f"\x1b[38;5;{THEME.styles['bar.marker'].color.number}m"


def _markers(colored: str) -> int:
    """Count marker cells in a colour-preserving capture.

    Must be a coloured capture. The marker is drawn with the bar's own fill
    glyph, so in plain text it is indistinguishable from any other filled cell
    — its colour is the only thing that identifies it, and no other theme style
    uses that colour. Passing a `no_color` capture here would silently count
    zero, so the tests that need this use `_capture_colored`.
    """
    return colored.count(_MARKER_ANSI)


_FILL_GLYPHS = (_FILL_GLYPH, "█")
_BAR_GLYPHS = (*_FILL_GLYPHS, "░")


def _bar_start(line: str) -> int:
    """Column of a row's first bar cell, whatever glyph happens to be drawn there.

    Not ``line.index("▓")``: on a narrow card the bar is a handful of cells, and
    the expected-pace marker can legitimately be sitting on the first one. The
    property under test is where the bar *starts*, not which glyph won that cell.
    """
    return min(line.index(glyph) for glyph in _BAR_GLYPHS if glyph in line)


class PercentFallbackRampTests(unittest.TestCase):
    """Boundaries of the no-pace fallback, exercised through the real entry point.

    Asserting against ``_style_for_signal(percent, None)`` rather than the
    private ``_percent_fallback_level`` keeps these tests on a path the app
    can actually reach: a window whose provider reports no reset timestamp.
    """

    def test_green_threshold(self) -> None:
        self.assertEqual(_style_for_signal(75, None), "bar.green")
        self.assertEqual(_style_for_signal(70, None), "bar.green")

    def test_yellow_threshold(self) -> None:
        self.assertEqual(_style_for_signal(45, None), "bar.yellow")
        self.assertEqual(_style_for_signal(40, None), "bar.yellow")

    def test_orange_threshold(self) -> None:
        self.assertEqual(_style_for_signal(25, None), "bar.orange")
        self.assertEqual(_style_for_signal(20, None), "bar.orange")

    def test_red_threshold(self) -> None:
        self.assertEqual(_style_for_signal(10, None), "bar.red")
        self.assertEqual(_style_for_signal(0, None), "bar.red")

    def test_none_returns_muted(self) -> None:
        self.assertEqual(_style_for_signal(None, None), "text.muted")

    def test_invalid_percent_is_stricter_than_the_old_ramp(self) -> None:
        """The pre-pace ramp returned green for 150; INV-3 says unknown."""
        self.assertEqual(_style_for_signal(150, None), "text.muted")


class PaceRampRenderingTests(unittest.TestCase):
    """Prove the pace ramp reaches the rendered table, not just the pure function.

    ``_capture`` renders with ``no_color=True``, so every other panel test in
    this file is blind to style. Without these, a call site left on the
    percent-only ramp would pass the whole suite.

    Each case also asserts what the no-pace fallback would return for the same
    percentage, so the test fails if the two ramps are ever collapsed into one.
    """

    now = datetime(2026, 8, 5, 12, 0, 0)

    def _percent_cell_color(self, snap: ProviderSnapshot, needle: str) -> object:
        console = Console(
            file=StringIO(),
            theme=THEME,
            force_terminal=True,
            width=80,
            color_system="256",
            _environ={"TERM": "xterm-256color"},
        )
        for segment in console.render(build_provider_panel(snap, self.now)):
            if needle in segment.text and segment.style is not None:
                return segment.style.color
        self.fail(f"no styled segment containing {needle!r} was rendered")

    def test_healthy_percent_burning_fast_renders_red(self) -> None:
        """60% left but nearly the whole window still to run: the old ramp said green."""
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="api",
            data={
                "five_hour_percent_left": 20.0,
                "five_hour_reset": "Resets in 4h 0m",
            },
        )
        self.assertEqual(self._percent_cell_color(snap, "20%"), THEME.styles["bar.red"].color)
        self.assertEqual(_style_for_signal(20.0, None), "bar.orange")

    def test_low_percent_at_end_of_window_is_not_red(self) -> None:
        """1% left 5 minutes before reset — David's motivating case."""
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="api",
            data={
                "five_hour_percent_left": 1.0,
                "five_hour_reset": "Resets in 5m",
            },
        )
        self.assertEqual(self._percent_cell_color(snap, "1.0%"), THEME.styles["bar.yellow"].color)
        self.assertEqual(_style_for_signal(1.0, None), "bar.red")

    def test_no_reset_falls_back_to_percent_ramp(self) -> None:
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="api",
            data={"five_hour_percent_left": 85.0},
        )
        self.assertEqual(self._percent_cell_color(snap, "85%"), THEME.styles["bar.green"].color)


class SignalLevelTruthTableTests(unittest.TestCase):
    """Assert the TUI ramp against the shared cross-language truth table.

    The Swift half (``SignalLevelTests.swift``) reads the same file, so a ramp
    edit applied to only one surface fails on both. The fixture lives inside
    the SwiftPM test target because SwiftPM resources cannot reference files
    outside the target directory; see its header comment.
    """

    TRUTH_TABLE = (
        pathlib.Path(__file__).resolve().parents[1]
        / "app/GradusKit/Tests/GradusKitTests/Fixtures/signal-levels.json"
    )

    @staticmethod
    def _number(raw: object) -> float | None:
        """Translate the fixture's JSON encoding: null -> None, "nan" -> NaN."""
        if raw is None:
            return None
        if raw == "nan":
            return math.nan
        assert isinstance(raw, (int, float))
        return float(raw)

    def _cases(self) -> list[dict[str, object]]:
        self.assertTrue(
            self.TRUTH_TABLE.is_file(),
            f"shared truth table missing at {self.TRUTH_TABLE}",
        )
        cases = json.loads(self.TRUTH_TABLE.read_text())["cases"]
        self.assertGreaterEqual(
            len(cases), 15, "truth table shrank — boundary coverage was removed"
        )
        return cases

    def test_matches_shared_truth_table(self) -> None:
        for case in self._cases():
            percent = self._number(case["percent_left"])
            pace = self._number(case["pace_delta"])
            with self.subTest(percent=percent, pace=pace, why=case["why"]):
                self.assertEqual(signal_level(percent, pace), case["level"])

    def test_orange_or_worse_equals_window_warns(self) -> None:
        """A colored row and a notification can never contradict each other.

        This used to skip rows with no pace, because there the two genuinely
        differed: the ramp fell back to percentage and ``window_warns``
        returned False, so a window could render red and stay silent. Since
        2026-08-06 ``window_warns`` *is* this property, and the absence of that
        skip is what pins it. Mirrors
        ``SignalLevelTests.orangeOrWorseEqualsWindowWarns``.
        """
        checked_without_pace = 0
        for case in self._cases():
            percent = self._number(case["percent_left"])
            pace = self._number(case["pace_delta"])
            if percent is None or not math.isfinite(percent):
                continue
            if pace is None or not math.isfinite(pace):
                checked_without_pace += 1
            with self.subTest(percent=percent, pace=pace):
                alarming = case["level"] in ("orange", "red")
                self.assertEqual(
                    window_warns({"percent_left": percent, "pace_delta": pace}),
                    alarming,
                )
        self.assertGreater(
            checked_without_pace,
            0,
            "the fixture no longer covers a window without pace, "
            "which is the case this property used to fail on",
        )

    def test_style_mapping_covers_every_level(self) -> None:
        for case in self._cases():
            percent = self._number(case["percent_left"])
            pace = self._number(case["pace_delta"])
            style = _style_for_signal(percent, pace)
            expected = "text.muted" if case["level"] == "unknown" else f"bar.{case['level']}"
            with self.subTest(percent=percent, pace=pace):
                self.assertEqual(style, expected)
                self.assertIn(style, THEME.styles)


class PaceLabelTruthTableTests(unittest.TestCase):
    """Assert `_format_pace_delta` against the shared cross-language truth table.

    The Swift half (``PaceLabelTests.swift``) reads the same file, so a
    wording edit applied to only one surface fails on both. The fixture
    lives inside the SwiftPM test target because SwiftPM resources cannot
    reference files outside the target directory; see its header comment.
    """

    TRUTH_TABLE = (
        pathlib.Path(__file__).resolve().parents[1]
        / "app/GradusKit/Tests/GradusKitTests/Fixtures/pace-labels.json"
    )

    def _cases(self) -> list[dict[str, object]]:
        self.assertTrue(
            self.TRUTH_TABLE.is_file(),
            f"shared truth table missing at {self.TRUTH_TABLE}",
        )
        cases = json.loads(self.TRUTH_TABLE.read_text())["cases"]
        self.assertGreaterEqual(len(cases), 6, "truth table shrank — boundary coverage was removed")
        return cases

    def test_matches_shared_truth_table(self) -> None:
        for case in self._cases():
            delta = case["pace_delta"]
            with self.subTest(delta=delta, why=case["why"]):
                self.assertEqual(_format_pace_delta(delta), case["label"])


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

    def test_expected_remaining_draws_one_marker_without_changing_bar_width(self) -> None:
        output = _capture(PercentageBar(72.0, "bar.green", expected_remaining=60.0), width=80)
        self.assertEqual(len(output.rstrip("\n")), 80)
        colored = _capture_colored(
            PercentageBar(72.0, "bar.green", expected_remaining=60.0), width=80
        )
        self.assertEqual(_markers(colored), 1)
        self.assertEqual(_marker_cells(72.0, 60.0, width=80), [48])

    def test_marker_lands_on_the_cell_it_names_not_the_next_one(self) -> None:
        """The index is a floor, not a round.

        ``expected_remaining`` names a boundary between two cells, and the cell
        claimed as the marker is the one to its *right*. Rounding up therefore
        put the mark a full cell past the boundary it was naming — at the
        14-cell width the dashboard actually draws, a 7-point error that made a
        provider look further ahead of pace than it was.
        """
        for expected, cell in ((61.0, 8), (75.0, 10), (99.0, 13), (100.0, 13)):
            with self.subTest(expected_remaining=expected):
                self.assertEqual(_marker_cells(80.0, expected, width=14), [cell])

    def test_marker_is_one_whole_cell_of_the_bars_own_fill_glyph(self) -> None:
        """Same glyph and same width as the bar, wherever it lands.

        This is the property the design turns on, and it is what three earlier
        attempts gave up. A thin sub-cell stroke resolves ~3x finer, but needs a
        different glyph per position — 2, 4 and 1 pixels of ink — so the marker
        changed thickness as it moved ("some of these blue bars are thinner than
        others too"), and its cell showed the terminal background through the
        gap ("black bar is STILL there"). Reusing the fill glyph means the
        marker cell inks exactly like its neighbours: nothing shows through, and
        the width never varies.
        """
        for expected in (10.0, 33.3, 50.0, 66.6, 99.9):
            with self.subTest(expected_remaining=expected):
                cells = _marker_cells(80.0, expected, width=14)
                self.assertEqual(len(cells), 1)
                rendered = _capture(
                    PercentageBar(80.0, "bar.green", expected_remaining=expected), width=14
                ).rstrip("\n")
                self.assertEqual(rendered[cells[0]], _FILL_GLYPH)

    def test_marker_resolution_is_one_cell(self) -> None:
        """Steps a whole cell at a time — the accepted cost of the above.

        Pinned so the tradeoff stays visible: if a future change reintroduces
        sub-cell strokes, this fails and whoever did it has to re-read why the
        marker is drawn the way it is.

        Counted on a coloured capture, because the marker is the fill glyph and
        a plain-text capture cannot see it at all — that spelled as `_capture`
        reports 5 distinct renderings for 14 positions, since only the cells
        that displace the `█` cap or a `░` track cell change the text.
        """
        width = 14
        rendered = {
            _capture_colored(
                PercentageBar(80.0, "bar.green", expected_remaining=v / 10), width=width
            )
            for v in range(1001)
        }
        self.assertEqual(len(rendered), width)

    def _marker_style(self, percent: float, expected_remaining: float) -> object:
        console = Console(
            file=StringIO(),
            theme=THEME,
            force_terminal=True,
            width=20,
            _environ={"TERM": "xterm-256color"},
        )
        rendered = next(
            PercentageBar(
                percent, "bar.green", expected_remaining=expected_remaining
            ).__rich_console__(console, console.options)
        )
        assert isinstance(rendered, Text)
        cells = _marker_cells(percent, expected_remaining, width=20)
        self.assertEqual(len(cells), 1)
        return next(span.style for span in rendered.spans if span.start <= cells[0] < span.end)

    def test_marker_never_paints_a_background(self) -> None:
        """Foreground only, on the fill and off it alike.

        Giving the marker cell a background colour was tried twice and rejected
        on sight both times: "this is bad", then "how is this getting worse every
        time!?". The bar's `▓` is a stipple, so a painted cell is the only solid
        one in a textured row. Recolouring the glyph instead keeps the texture.
        """
        for percent, where in ((100.0, "over the fill"), (20.0, "over the track")):
            with self.subTest(where=where):
                self.assertEqual(self._marker_style(percent, 84.0), "bar.marker")

    def test_marker_colour_is_not_any_fill_colour(self) -> None:
        """The marker is blue, which is deliberately off the tier ramp.

        David picked the colour; this test only pins the one property that
        makes it work as a mark -- that it is not any of the four fills. When
        the marker was `bar.red` it was the same colour as the fill on a red
        bar, a 1.00 contrast ratio, i.e. not there at all on the one row where
        knowing your pace matters most.
        """
        marker = THEME.styles["bar.marker"].color
        for tier in ("bar.green", "bar.yellow", "bar.orange", "bar.red"):
            with self.subTest(tier=tier):
                self.assertNotEqual(marker, THEME.styles[tier].color)

    def test_expected_remaining_preserves_fill_and_marker_styles(self) -> None:
        # At width 80 and 72% left the fill ends at cell 58, so 60.0 puts the
        # marker inside the fill and 84.0 puts it out on the empty track. Both
        # draw the fill and a marker styled identically -- the stroke does not
        # change how it is painted depending on what it crosses.
        for expected_remaining in (60.0, 84.0):
            with self.subTest(expected_remaining=expected_remaining):
                console = Console(
                    file=StringIO(),
                    theme=THEME,
                    force_terminal=True,
                    width=80,
                    no_color=True,
                    _environ={"TERM": "xterm-256color"},
                )
                rendered = next(
                    PercentageBar(
                        72.0, "bar.green", expected_remaining=expected_remaining
                    ).__rich_console__(console, console.options)
                )
                self.assertIsInstance(rendered, Text)
                assert isinstance(rendered, Text)
                self.assertTrue(any(span.style == "bar.green" for span in rendered.spans))
                self.assertTrue(any(span.style == "bar.marker" for span in rendered.spans))

    def test_missing_expected_remaining_keeps_existing_bar_output(self) -> None:
        original = _capture(PercentageBar(72.0, "bar.green"), width=80)
        without_marker = _capture(PercentageBar(72.0, "bar.green", None), width=80)
        self.assertEqual(without_marker, original)

    def test_nonfinite_expected_remaining_is_omitted(self) -> None:
        self.assertIsNone(_expected_remaining(72.0, float("nan")))
        self.assertIsNone(_expected_remaining(math.nan, 0.0))
        self.assertIsNone(_expected_remaining(math.inf, 0.0))
        self.assertIsNone(_expected_remaining(-math.inf, 0.0))
        self.assertIsNone(_expected_remaining(72.0, math.inf))
        self.assertIsNone(_expected_remaining(72.0, -math.inf))

    def test_expected_remaining_clamps_to_bar_bounds(self) -> None:
        self.assertEqual(_expected_remaining(80.0, -1.0), 100.0)
        self.assertEqual(_expected_remaining(20.0, 1.0), 0.0)


class UsageRowMarkerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.now = datetime(2026, 3, 14, 8, 22, 30)

    def test_valid_session_pace_renders_one_expected_remaining_marker(self) -> None:
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="api",
            data={
                "five_hour_percent_left": 60.0,
                "five_hour_reset": "Resets in 2h 30m",
            },
        )
        output = _capture_colored(build_provider_panel(snap, self.now), width=80)
        self.assertEqual(_markers(output), 1)

    def test_missing_session_pace_renders_no_marker(self) -> None:
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="api",
            data={"five_hour_percent_left": 60.0},
        )
        output = _capture_colored(build_provider_panel(snap, self.now), width=80)
        self.assertEqual(_markers(output), 0)

    def test_malformed_session_reset_renders_no_marker(self) -> None:
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="api",
            data={
                "five_hour_percent_left": 60.0,
                "five_hour_reset": "Resets in 999999999999999999999999999999999999d",
            },
        )
        output = _capture_colored(build_provider_panel(snap, self.now), width=80)
        self.assertEqual(_markers(output), 0)


class PaceLabelTests(unittest.TestCase):
    def test_wide_console_renders_full_text(self) -> None:
        output = _capture(PaceLabel("5% ahead"), width=120)
        self.assertIn("5% ahead", output)
        self.assertNotIn("↑", output)

    def test_narrow_console_renders_up_arrow_for_ahead(self) -> None:
        output = _capture(PaceLabel("5% ahead"), width=60)
        self.assertIn("↑5%", output)
        self.assertNotIn("ahead", output)

    def test_narrow_console_renders_down_arrow_for_behind(self) -> None:
        output = _capture(PaceLabel("3% behind"), width=60)
        self.assertIn("↓3%", output)
        self.assertNotIn("behind", output)

    def test_narrow_console_collapses_on_pace_to_equals(self) -> None:
        output = _capture(PaceLabel("on pace"), width=60)
        self.assertIn("=", output)

    def test_narrow_console_collapses_na_to_em_dash(self) -> None:
        output = _capture(PaceLabel("n/a"), width=60)
        self.assertIn("—", output)
        self.assertNotIn("n/a", output)

    def test_wide_console_at_boundary_minus_one_still_compacts(self) -> None:
        # _NARROW_CONSOLE_WIDTH = 93 → width 92 must compact, width 93 must not.
        narrow = _capture(PaceLabel("5% ahead"), width=92)
        self.assertIn("↑5%", narrow)
        self.assertNotIn("ahead", narrow)
        wide = _capture(PaceLabel("5% ahead"), width=93)
        self.assertIn("5% ahead", wide)
        self.assertNotIn("↑", wide)

    def test_unknown_pace_text_passes_through_compact(self) -> None:
        # _compact_pace falls back to the original string for unrecognized input.
        self.assertEqual(_compact_pace("totally bogus"), "totally bogus")
        self.assertEqual(_compact_pace(""), "")
        # And PaceLabel renders that unchanged even when narrow.
        output = _capture(PaceLabel("totally bogus"), width=60)
        self.assertIn("totally bogus", output)

    def test_style_colors_ahead_green_and_behind_red(self) -> None:
        # Regression: _pace_style used to match the pre-consolidation "under
        # +"/"over -" wording. _format_pace_delta now emits "N% ahead"/"N%
        # behind", so a substring check on "under"/"over" never matches and
        # every real pace silently fell back to text.muted.
        self.assertEqual(PaceLabel("5% ahead").style, "text.green")
        self.assertEqual(PaceLabel("3% behind").style, "text.red")
        self.assertEqual(PaceLabel("on pace").style, "text.yellow")
        self.assertEqual(PaceLabel("n/a").style, "text.muted")


class PercentStrTests(unittest.TestCase):
    """Direct unit tests for the percent formatting helpers."""

    def test_values_below_ten_show_one_decimal(self) -> None:
        self.assertEqual(_percent_str(0.0), "0.0")
        self.assertEqual(_percent_str(5.5), "5.5")
        self.assertEqual(_percent_str(9.9), "9.9")

    def test_values_ten_and_above_show_integer(self) -> None:
        self.assertEqual(_percent_str(10.0), "10")
        self.assertEqual(_percent_str(10.4), "10")
        self.assertEqual(_percent_str(100.0), "100")

    def test_display_truncates_rather_than_rounding_up(self) -> None:
        """Remaining budget is never overstated.

        This is the rule the surfaces disagreed on until 2026-08-06: `47.8`
        showed 48% here and 47% on the phone. Truncation won because rounding
        up claims headroom that does not exist, and because it is what four of
        the five surfaces already did.
        """
        self.assertEqual(_percent_str(47.8), "47")
        self.assertEqual(_percent_str(99.9), "99")
        # Below ten the same rule applies one decimal down, so a value just
        # under the threshold stays in its band instead of rounding across it.
        self.assertEqual(_percent_str(9.99), "9.9")
        self.assertEqual(_percent_str(9.94), "9.9")

    def test_live_windows_below_one_percent_never_display_as_zero(self) -> None:
        """The defect that settled the sub-ten decimal rule.

        `percent_is_depleted` treats <= 0.5 as exhausted, so 0.6 through 0.9
        are live windows. Whole-number truncation renders every one of them as
        "0", which reads as exhausted -- and until 2026-08-06 spoke that way to
        VoiceOver on iOS, whose label was `Int(window.percentLeft)` as well.
        """
        # Expected strings are spelled out, not rebuilt from the input with the
        # same format spec: an expectation derived from its own input cannot
        # catch a formatting change.
        for percent, text in ((0.6, "0.6"), (0.7, "0.7"), (0.8, "0.8"), (0.9, "0.9")):
            with self.subTest(percent=percent):
                self.assertFalse(percent_is_depleted(percent))
                self.assertEqual(_percent_str(percent), text)
                self.assertNotEqual(_percent_str(percent), "0")

    def test_computed_percentages_do_not_lose_a_digit(self) -> None:
        """`100.0 - used` lands a true 9.1 at 9.099999999999994.

        Without the epsilon in `_truncated` the floor drops it to 9.0. Measured
        over the realistic producer range: 40 affected values below ten, 123
        overall.
        """
        self.assertEqual(_percent_str(100.0 - 90.9), "9.1")
        self.assertEqual(_percent_str(0.29 * 100), "29")

    def test_displayed_percentage_never_exceeds_the_actual_one(self) -> None:
        """The property truncation exists to guarantee, swept rather than spot-checked."""
        for thousandths in range(0, 100_001):
            percent = thousandths / 1000
            shown = float(_percent_str(percent))
            if shown > percent + 1e-9:
                self.fail(f"{percent} displayed as {shown}, claiming headroom that does not exist")

    def test_format_percent_value_none(self) -> None:
        self.assertEqual(_format_percent_value(None), "n/a")

    def test_format_percent_value_non_finite(self) -> None:
        self.assertEqual(_format_percent_value(math.nan), "n/a")
        self.assertEqual(_format_percent_value(math.inf), "n/a")

    def test_format_percent_value_edge_values(self) -> None:
        self.assertEqual(_format_percent_value(0.0), "0.0%")
        self.assertEqual(_format_percent_value(9.99), "9.9%")
        self.assertEqual(_format_percent_value(10.0), "10%")
        self.assertEqual(_format_percent_value(100.0), "100%")


class PercentFormatTruthTableTests(unittest.TestCase):
    """The Python half of the shared percent-format contract.

    `GradusKitTests/PercentFormatTests.swift` asserts the same rows against
    `GradusKit.percentText`, so a one-sided formatting edit fails on both
    sides. Same placement constraint as the signal-level table: it lives in the
    SwiftPM test target because SwiftPM resources cannot reference files
    outside the target directory.
    """

    FORMAT_TABLE = (
        pathlib.Path(__file__).resolve().parents[1]
        / "app/GradusKit/Tests/GradusKitTests/Fixtures/percent-format.json"
    )

    def _cases(self) -> list[dict[str, object]]:
        self.assertTrue(
            self.FORMAT_TABLE.is_file(),
            f"shared percent-format table missing at {self.FORMAT_TABLE}",
        )
        cases = json.loads(self.FORMAT_TABLE.read_text())["cases"]
        self.assertGreaterEqual(
            len(cases), 16, "format table shrank — boundary coverage was removed"
        )
        return cases

    def test_matches_shared_truth_table(self) -> None:
        for case in self._cases():
            percent = case["percent_left"]
            with self.subTest(percent=percent, why=case["why"]):
                actual = "n/a" if percent is None else _percent_str(float(percent))
                self.assertEqual(actual, case["text"])

    def test_table_pins_the_depleted_boundary(self) -> None:
        """Without the 0.5/0.6 pair the table cannot catch a return to `Int()`."""
        covered = {
            case["percent_left"] for case in self._cases() if case["percent_left"] is not None
        }
        self.assertIn(0.5, covered, "the depleted ceiling itself is untested")
        self.assertIn(0.6, covered, "the first live value above the ceiling is untested")


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
        self.copilot_data = {
            "premium_percent_left": 97.6,
            "premium_reset": "Resets Apr 01 12:00 AM",
        }

    def test_codex_panel_contains_labels_and_values(self) -> None:
        snap = ProviderSnapshot(name="Codex", ok=True, source="cli", data=self.codex_data)
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertIn("Codex", output)
        self.assertIn("5h", output)
        self.assertIn("1w", output)
        self.assertIn("68%", output)
        self.assertIn("91%", output)

    def test_copilot_panel_shows_monthly_metrics(self) -> None:
        snap = ProviderSnapshot(name="Copilot", ok=True, source="cli", data=self.copilot_data)
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertIn("Copilot", output)
        self.assertIn("mo", output)
        # Truncated, not rounded -- the raw value is 97.x.
        self.assertIn("97%", output)

    def test_opencode_panel_shows_three_decimal_zen_credit_only_when_present(self) -> None:
        data = {
            "five_hour_percent_left": 75,
            "weekly_percent_left": 90,
            "monthly_percent_left": 80,
            "zen_credit": 12.345,
        }
        snap = ProviderSnapshot(name="OpenCode Go", ok=True, source="api", data=data)
        output = _capture(build_provider_panel(snap, self.now), width=50)
        self.assertIn("Zen credit", output)
        self.assertIn("$12.345", output)

        without_credit = ProviderSnapshot(
            name="OpenCode Go",
            ok=True,
            source="api",
            data={key: value for key, value in data.items() if key != "zen_credit"},
        )
        self.assertNotIn(
            "Zen credit", _capture(build_provider_panel(without_credit, self.now), width=50)
        )

    def test_opencode_compact_line_shows_three_decimal_zen_credit(self) -> None:
        snap = ProviderSnapshot(
            name="OpenCode Go",
            ok=True,
            source="api",
            data={"weekly_percent_left": 90, "zen_credit": 12.345},
        )
        parts = [text for text, _style in _compact_window_parts(snap, self.now)]
        self.assertIn("Zen credit:$12.345", parts)

    def test_panel_shows_decimal_for_fractional_percent_below_ten(self) -> None:
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 5.5,
                "five_hour_reset": "Resets 1:16 PM (EDT)",
                "weekly_percent_left": 91,
                "weekly_reset": "Resets Mar 17 at 9 PM",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertIn("5.5%", output)
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
        self.assertEqual(_bar_start(usage_lines[0]), _bar_start(usage_lines[1]))
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

    def test_codex_panel_hides_absent_five_hour_row(self) -> None:
        # When the provider reports no 5h data (percent is None), the row is
        # omitted entirely rather than rendered as "n/a".
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
        self.assertFalse(
            any(re.search(r"\b5h\b", line) for line in output.splitlines()),
            "Expected no '5h' row when five_hour_percent_left is None",
        )
        self.assertNotIn("n/a", output)

    def test_codex_panel_shows_five_hour_row_when_present(self) -> None:
        # Restoration path: when the provider DOES report 5h data, the row
        # renders normally.
        data = {
            "five_hour_percent_left": 80.0,
            "five_hour_reset": "Resets 9 PM",
            "weekly_percent_left": 91,
            "weekly_reset": "Resets Mar 17 at 9 PM",
        }
        snap = ProviderSnapshot(name="Codex", ok=True, source="cli", data=data)
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertIn("Codex", output)
        self.assertTrue(
            any(re.search(r"\b5h\b", line) for line in output.splitlines()),
            "Expected a '5h' row when five_hour_percent_left is present",
        )
        self.assertIn("80%", output)

    def test_codex_panel_shows_spark_weekly_row_when_present(self) -> None:
        data = {
            "five_hour_percent_left": 80.0,
            "five_hour_reset": "Resets 9 PM",
            "weekly_percent_left": 91,
            "weekly_reset": "Resets Mar 17 at 9 PM",
            "spark_weekly_percent_left": 42.0,
            "spark_weekly_reset": "Resets Mar 17 at 9 PM",
        }
        snap = ProviderSnapshot(name="Codex", ok=True, source="cli", data=data)
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertTrue(
            any("sp1w" in line for line in output.splitlines()),
            "Expected an 'sp1w' row when spark_weekly_percent_left is present",
        )
        self.assertIn("42%", output)

    def test_codex_panel_hides_spark_weekly_row_when_absent(self) -> None:
        data = {
            "five_hour_percent_left": 80.0,
            "five_hour_reset": "Resets 9 PM",
            "weekly_percent_left": 91,
            "weekly_reset": "Resets Mar 17 at 9 PM",
            "spark_weekly_percent_left": None,
            "spark_weekly_reset": None,
        }
        snap = ProviderSnapshot(name="Codex", ok=True, source="cli", data=data)
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertFalse(
            any("sp1w" in line for line in output.splitlines()),
            "Expected no 'sp1w' row when spark_weekly_percent_left is None",
        )

    def test_codex_provider_is_empty_native_blocked_spark_has_capacity_stays_normal(
        self,
    ) -> None:
        # Cross-pool case: native weekly=0% blocks the native pool, but the
        # Spark pool (sp1w) still has capacity, so Codex is NOT fully empty --
        # the normal panel must render with an sp1w row, not the depleted
        # view. Regression for the bug this task fixes: before the Codex
        # branch existed, the generic fallthrough treated ANY single depleted
        # window (including sp1w, unioned into warning windows by task 3.1)
        # as "provider empty".
        data = {
            "five_hour_percent_left": 80.0,
            "five_hour_reset": "Resets 9 PM",
            "weekly_percent_left": 0,
            "weekly_reset": "Resets Mar 17 at 9 PM",
            "spark_weekly_percent_left": 60.0,
            "spark_weekly_reset": "Resets Mar 17 at 9 PM",
        }
        snap = ProviderSnapshot(name="Codex", ok=True, source="cli", data=data)
        self.assertFalse(_provider_is_empty(snap, self.now))
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertTrue(
            any("sp1w" in line for line in output.splitlines()),
            "Expected an 'sp1w' row in the normal panel",
        )
        self.assertIn("60%", output)
        self.assertNotIn("until", output)

    def test_codex_provider_is_empty_spark_alone_blocked_stays_normal(self) -> None:
        # Symmetric case: Spark is exhausted but native (5h/1w) both still
        # have capacity -- native is independently usable, so the provider
        # must not flip to the depleted view over Spark alone.
        data = {
            "five_hour_percent_left": 80.0,
            "five_hour_reset": "Resets 9 PM",
            "weekly_percent_left": 91,
            "weekly_reset": "Resets Mar 17 at 9 PM",
            "spark_weekly_percent_left": 0.0,
            "spark_weekly_reset": "Resets Mar 17 at 9 PM",
        }
        snap = ProviderSnapshot(name="Codex", ok=True, source="cli", data=data)
        self.assertFalse(_provider_is_empty(snap, self.now))

    def test_codex_provider_is_empty_cross_pool_blocked_via_different_windows(self) -> None:
        # Native pool is blocked via five_hour=0% (weekly still has capacity),
        # and Spark is independently blocked via spark_weekly=0% -- both
        # pools blocked, via different windows, means Codex has no usable
        # capacity right now.
        data = {
            "five_hour_percent_left": 0.0,
            "five_hour_reset": "Resets 9 PM",
            "weekly_percent_left": 50,
            "weekly_reset": "Resets Mar 17 at 9 PM",
            "spark_weekly_percent_left": 0.0,
            "spark_weekly_reset": "Resets Mar 17 at 9 PM",
        }
        snap = ProviderSnapshot(name="Codex", ok=True, source="cli", data=data)
        self.assertTrue(_provider_is_empty(snap, self.now))

    def test_codex_provider_is_empty_spark_absent_native_fully_depleted(self) -> None:
        # Regression for the presence hazard: spark_weekly_percent_left is
        # None for accounts without Spark access. A naive
        # `native_blocked and spark_blocked` rule would make spark_blocked
        # permanently False for these accounts, permanently suppressing the
        # depleted view even when native quota is fully exhausted. The
        # presence-safe rule (all *present* windows depleted) must still fire.
        data = {
            "five_hour_percent_left": 0.0,
            "five_hour_reset": "Resets 9 PM",
            "weekly_percent_left": 0.0,
            "weekly_reset": "Resets Mar 17 at 9 PM",
            "spark_weekly_percent_left": None,
            "spark_weekly_reset": None,
        }
        snap = ProviderSnapshot(name="Codex", ok=True, source="cli", data=data)
        self.assertTrue(_provider_is_empty(snap, self.now))

    def test_codex_provider_is_empty_spark_absent_single_native_window_depleted(self) -> None:
        # Locks in pre-Spark, currently-live Codex semantics: five_hour and
        # weekly are tranches of ONE quota (not independent pools like
        # Antigravity's native/third-party), so either hitting 0% empties the
        # provider regardless of the other window's remaining capacity --
        # established behavior `test_empty_view_codex_five_hour_zero` and
        # `test_empty_view_codex_weekly_zero` already exercise via the
        # rendered panel. A literal copy of Antigravity's two-rule structure
        # (presence-safe "all present depleted" + bare
        # `native_blocked and spark_blocked`) breaks this: for the near-100%
        # of accounts with spark_weekly_percent_left still None, neither rule
        # fires when only ONE native window is at 0% and the other still has
        # capacity. `_provider_is_empty` must treat an absent Spark value as
        # "blocked" (not an escape hatch) so the AND collapses to plain
        # `native_blocked` for these accounts. This test asserts the
        # predicate directly with `spark_weekly_percent_left: None` written
        # out, so a future simplification of that presence handling fails
        # here even if nobody re-runs the panel-level tests by hand.
        data = {
            "five_hour_percent_left": 0.0,
            "five_hour_reset": "Resets 1:16 PM",
            "weekly_percent_left": 88,
            "weekly_reset": "Resets Mar 17 at 9 PM",
            "spark_weekly_percent_left": None,
        }
        snap = ProviderSnapshot(name="Codex", ok=True, source="cli", data=data)
        self.assertTrue(_provider_is_empty(snap, self.now))

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

    def test_antigravity_shows_cg_windows_at_exactly_hundred(self) -> None:
        # A fully unused C+G pool (100% remaining) is still real, trackable
        # quota -- it must render like any other window, not be hidden as
        # "idle".
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                **self.antigravity_data,
                "third_party_five_hour_percent_left": 100.0,
                "third_party_five_hour_reset": "Resets 9:22 AM",
                "third_party_weekly_percent_left": 100,
                "third_party_weekly_reset": "Resets Mar 21 at 8:22 AM",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertIn("cg5", output)
        self.assertIn("cg1w", output)
        self.assertEqual(output.count("100%"), 2)

    def test_antigravity_cg_fractional_value_truncates_rather_than_reaching_hundred(self) -> None:
        # A near-full pool (99.9% raw) is a genuinely different value from an
        # exactly-100% one, and since 2026-08-06 it displays as one: truncation
        # keeps it at "99%" rather than rounding up to a "100%" that would
        # claim the pool is untouched. Only an exact 100.0 reads as full.
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                **self.antigravity_data,
                "third_party_five_hour_percent_left": 99.9,
                "third_party_five_hour_reset": "Resets 9:22 AM",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=44)
        cg5_lines = [line for line in output.splitlines() if "cg5" in line and "cg1w" not in line]
        self.assertTrue(cg5_lines, "expected a cg5 row in the output")
        self.assertIn("99%", cg5_lines[0])

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
        cg_line = next(line for line in output.splitlines() if "cg5" in line)
        self.assertTrue(any(glyph in cg_line for glyph in _FILL_GLYPHS))
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
        self.assertIn("93%", output)
        # api_percent_used 1.5% used -> 98.5% remaining (banker's rounding -> 98%).
        self.assertIn("98%", output)
        # The dollar-spend meter (credit_percent_left=82.5) must no longer render.
        self.assertNotIn("82%", output)
        self.assertNotIn("pl", output)
        self.assertNotIn("pro", output)

    def test_cursor_badge_marks_independent_warning_pool(self) -> None:
        one_warning = ProviderSnapshot(
            name="Cursor",
            ok=True,
            source="api",
            data={"auto_percent_used": 100, "api_percent_used": 18},
        )
        # 50% used, not 80%. These fixtures omit the billing cycle, so neither
        # pool has a pace and both fall back to the percent ramp -- under which
        # 20% left is orange and does warn. 50% left is yellow and does not.
        no_warning = ProviderSnapshot(
            name="Cursor",
            ok=True,
            source="api",
            data={"auto_percent_used": 50, "api_percent_used": 18},
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
            data={"api_percent_used": 100},
        )
        output = _capture(build_provider_panel(snap, self.now), width=44)
        self.assertIn("[!]", output)

    def test_cursor_boolean_pool_values_render_as_absent(self) -> None:
        snap = ProviderSnapshot(
            name="Cursor",
            ok=True,
            source="api",
            data={"auto_percent_used": True, "api_percent_used": False},
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
        # 1.17% used leaves 98.83, which truncates to 98 rather than rounding to 99.
        self.assertIn("98%", output)

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
        # Weekly depleted and the 5h window absent: the depleted view shows
        # the 1w row only — the 5h row is omitted entirely, not "n/a".
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
        self.assertFalse(
            any(re.search(r"\b5h\b", line) for line in output.splitlines()),
            "Expected no '5h' row in depleted view when five_hour_percent_left is None",
        )
        self.assertNotIn("n/a", output)

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

    def test_empty_view_antigravity_five_hour_pair_both_zero(self) -> None:
        # Regression: native 5h and third-party cg5 both at 0% block all
        # usage right now even though the 1w windows still have capacity.
        # Previously this required *every* window to be zero before the
        # provider switched to the depleted view.
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0,
                "five_hour_reset": "Resets at 23:58",
                "weekly_percent_left": 45,
                "weekly_reset": "Resets Mar 15 at 06:45",
                "third_party_five_hour_percent_left": 0,
                "third_party_five_hour_reset": "Resets at 23:58",
                "third_party_weekly_percent_left": 60,
                "third_party_weekly_reset": "Resets Mar 15 at 06:45",
            },
        )
        self.assertTrue(_provider_is_empty(snap, self.now))
        output = _capture(build_provider_panel(snap, self.now), width=50)
        self.assertIn("until", output)
        self.assertNotIn("▓", output)

    def test_empty_view_antigravity_weekly_pair_both_zero(self) -> None:
        # Same rule, applied to the 1w pair: native weekly and cg1w both at
        # 0% block usage even though the 5h windows still have capacity.
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 35,
                "five_hour_reset": "Resets at 23:58",
                "weekly_percent_left": 0,
                "weekly_reset": "Resets Mar 15 at 06:45",
                "third_party_five_hour_percent_left": 50,
                "third_party_five_hour_reset": "Resets at 23:58",
                "third_party_weekly_percent_left": 0,
                "third_party_weekly_reset": "Resets Mar 15 at 06:45",
            },
        )
        self.assertTrue(_provider_is_empty(snap, self.now))
        output = _capture(build_provider_panel(snap, self.now), width=50)
        self.assertIn("until", output)
        self.assertNotIn("▓", output)

    def test_empty_view_antigravity_cross_window_both_pools_blocked(self) -> None:
        # Regression: each pool (native, third-party) is blocked the moment
        # EITHER of its own windows hits 0% -- so native 5h=0% blocks the
        # native pool even with weekly capacity left, and third-party
        # weekly=0% blocks the third-party pool even with 5h capacity left.
        # Both pools blocked, via different windows, still means you can't
        # use agy at all right now.
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0,
                "five_hour_reset": "Resets at 23:58",
                "weekly_percent_left": 50,
                "weekly_reset": "Resets Mar 15 at 06:45",
                "third_party_five_hour_percent_left": 50,
                "third_party_five_hour_reset": "Resets at 23:58",
                "third_party_weekly_percent_left": 0,
                "third_party_weekly_reset": "Resets Mar 15 at 06:45",
            },
        )
        self.assertTrue(_provider_is_empty(snap, self.now))
        output = _capture(build_provider_panel(snap, self.now), width=50)
        self.assertIn("until", output)
        self.assertNotIn("▓", output)

    def test_empty_view_antigravity_cross_window_both_pools_blocked_reverse(self) -> None:
        # Symmetric case: third-party 5h=0% blocks the third-party pool,
        # native weekly=0% blocks the native pool.
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 50,
                "five_hour_reset": "Resets at 23:58",
                "weekly_percent_left": 0,
                "weekly_reset": "Resets Mar 15 at 06:45",
                "third_party_five_hour_percent_left": 0,
                "third_party_five_hour_reset": "Resets at 23:58",
                "third_party_weekly_percent_left": 50,
                "third_party_weekly_reset": "Resets Mar 15 at 06:45",
            },
        )
        self.assertTrue(_provider_is_empty(snap, self.now))
        output = _capture(build_provider_panel(snap, self.now), width=50)
        self.assertIn("until", output)
        self.assertNotIn("▓", output)

    def test_empty_view_antigravity_only_one_pool_blocked_stays_normal(self) -> None:
        # Negative case: native pool blocked (5h=0%) but the third-party pool
        # has capacity in both windows -- third-party is independently
        # usable, so the provider must not flip to the depleted view.
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0,
                "five_hour_reset": "Resets at 23:58",
                "weekly_percent_left": 50,
                "weekly_reset": "Resets Mar 15 at 06:45",
                "third_party_five_hour_percent_left": 40,
                "third_party_five_hour_reset": "Resets at 23:58",
                "third_party_weekly_percent_left": 60,
                "third_party_weekly_reset": "Resets Mar 15 at 06:45",
            },
        )
        self.assertFalse(_provider_is_empty(snap, self.now))
        output = _capture(build_provider_panel(snap, self.now), width=50)
        self.assertNotIn("until", output)
        self.assertIn("▓", output)

    def test_empty_view_antigravity_only_third_party_pool_blocked_stays_normal(self) -> None:
        # Symmetric case: third-party pool blocked (cg5=0%) but the native
        # pool has capacity in both windows -- native is independently
        # usable, so the provider must not flip to the depleted view.
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 40,
                "five_hour_reset": "Resets at 23:58",
                "weekly_percent_left": 60,
                "weekly_reset": "Resets Mar 15 at 06:45",
                "third_party_five_hour_percent_left": 0,
                "third_party_five_hour_reset": "Resets at 23:58",
                "third_party_weekly_percent_left": 50,
                "third_party_weekly_reset": "Resets Mar 15 at 06:45",
            },
        )
        self.assertFalse(_provider_is_empty(snap, self.now))
        output = _capture(build_provider_panel(snap, self.now), width=50)
        self.assertNotIn("until", output)
        self.assertIn("▓", output)

    def test_empty_view_antigravity_blocking_reset_is_scoped_per_pool(self) -> None:
        # Regression: the depleted view used to compute one global "blocking
        # reset" (the first depleted window across all four) and stamp it on
        # every non-depleted row. With native 5h=0% and third-party cg1w=0%
        # blocking the provider via different windows, that leaked the native
        # pool's reset onto the third-party pool's capacity-remaining row
        # (cg5) -- a resume time that has nothing to do with when cg5 is
        # actually usable again. Each pool's non-depleted row must show its
        # OWN pool's blocking reset, never the other pool's.
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0,
                "five_hour_reset": "Resets at 10:00",
                "weekly_percent_left": 50,
                "weekly_reset": "Resets Mar 18 at 06:45",
                "third_party_five_hour_percent_left": 60,
                "third_party_five_hour_reset": "Resets at 23:58",
                "third_party_weekly_percent_left": 0,
                "third_party_weekly_reset": "Resets at 12:00",
            },
        )
        self.assertTrue(_provider_is_empty(snap, self.now))
        output = _capture(build_provider_panel(snap, self.now), width=50)
        row_labels = ("5h", "1w", "cg5", "cg1w")
        lines = {
            tokens[1]: line
            for line in output.splitlines()
            if len(tokens := line.split()) >= 2 and tokens[1] in row_labels
        }
        # native 1w (non-depleted, 50%) is blocked by native 5h -> until 10:00
        self.assertIn("10:00", lines["1w"])
        self.assertNotIn("12:00", lines["1w"])
        # cg5 (non-depleted, 60%) is blocked by cg1w -> until 12:00, never
        # the native pool's 10:00
        self.assertIn("12:00", lines["cg5"])
        self.assertNotIn("10:00", lines["cg5"])

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

    def test_empty_view_copilot(self) -> None:
        snap = ProviderSnapshot(
            name="Copilot",
            ok=True,
            source="cli",
            data={
                "premium_percent_left": 0,
                "premium_reset": "Resets Apr 01 at 12:00 AM",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=70)
        self.assertIn("[!]", output)
        self.assertIn("mo", output)
        self.assertIn("until", output)
        self.assertNotIn("░", output)
        self.assertNotIn("▓", output)

    def test_empty_view_copilot_fractional_rounds_to_zero(self) -> None:
        snap = ProviderSnapshot(
            name="Copilot [HTTP]",
            ok=True,
            source="http",
            data={
                "premium_percent_left": 0.4,
                "premium_reset": "Resets Apr 01 at 12:00 AM",
            },
        )
        output = _capture(build_provider_panel(snap, self.now), width=70)
        self.assertIn("[!]", output)
        self.assertIn("mo", output)
        self.assertIn("until", output)
        self.assertNotIn("░", output)
        self.assertNotIn("▓", output)

    def test_empty_view_cursor(self) -> None:
        snap = ProviderSnapshot(
            name="Cursor",
            ok=True,
            source="api",
            data={
                "auto_percent_used": 100,
                "api_percent_used": 100,
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
                "api_percent_used": 100,
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
                "api_percent_used": 100,
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
                "api_percent_used": 18,
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

    def test_rate_limited_claude_shows_cached_values_not_credentials_error(self) -> None:
        snap = ProviderSnapshot(
            name="Claude",
            ok=True,
            source="snapshot (cached)",
            data={"session_percent_left": 98.0, "primary_reset": "Resets in 1h"},
            error="HTTP 429",
            cached_since=datetime(2026, 3, 14, 8, 8, 0),
        )
        output = _capture(build_provider_panel(snap, self.now), width=70)
        self.assertIn("rate limited; cached 14m", output)
        self.assertIn("98%", output)
        self.assertNotIn("auth error", output)

    def test_graced_antigravity_shows_its_values_and_says_retrying(self) -> None:
        """The promoted grace entry must keep both its numbers and its reason.

        `carried_failure` now promotes a graced entry to ok/cached so the
        reader stops discarding the values the writer retained.  That promotion
        routes it past the `not snapshot.ok` retry panel below, so without a
        title branch the card would silently relabel itself the generic
        "offline" -- swapping the panel's missing numbers for a missing reason.
        """
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="snapshot (cached)",
            data={"five_hour_percent_left": 62.0, "five_hour_reset": "Resets 9:22 AM"},
            error=ANTIGRAVITY_AUTH_RETRY_MESSAGE,
            cached_since=datetime(2026, 3, 14, 8, 8, 0),
        )
        output = _capture(build_provider_panel(snap, self.now, auth_fix_key="1"), width=70)
        self.assertIn("retrying; cached 14m", output)
        self.assertIn("62%", output)
        self.assertNotIn("offline", output)
        # Still no call to action: the grace window is the retry, not the user's job.
        self.assertNotIn("auth error", output)

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
        self.assertIn("Gradus", output)
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
                "api_percent_used": 40,
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

    def test_dashboard_switches_to_compact_below_two_column_threshold(self) -> None:
        # Below 79, two cards switch to compact lines instead of 1-column panels.
        output = _capture(
            build_dashboard([self.codex_snap, self.claude_snap], self.now, 30), width=78
        )
        lines = output.splitlines()
        self.assertFalse(any("Codex" in line and "Claude" in line for line in lines))
        self.assertEqual(output.count("Codex"), 1)
        self.assertEqual(output.count("Claude"), 1)
        # Compact mode uses plain text with pace arrows (no panel borders).
        self.assertNotIn("╭", output)
        self.assertNotIn("╰", output)
        # Pace arrows confirm compact notation is in use.
        self.assertTrue(any("↑" in line or "↓" in line or "=" in line for line in lines))

    def test_dashboard_stays_two_column_with_bars_collapsed_when_narrow(self) -> None:
        # The whole point of the low two-column floor: a narrowing terminal
        # shrinks the usage bars to nothing while keeping two columns, rather
        # than stacking early and re-widening every card. Across the no-bar band
        # — the exact threshold (79) through the last bar-less width (82) — the
        # cards sit side by side yet carry no bar glyphs, just reset + pace text.
        for width in (79, 80, 82):
            with self.subTest(width=width):
                output = _capture(
                    build_dashboard([self.codex_snap, self.claude_snap], self.now, 30),
                    width=width,
                )
                lines = output.splitlines()
                self.assertTrue(
                    any("Codex" in line and "Claude" in line for line in lines),
                    f"Expected two columns at width {width}",
                )
                self.assertNotIn("▓", output)
                self.assertNotIn("░", output)
                # Nothing is cropped to make room: no ellipsis anywhere, and both
                # cards keep their full reset time and pace figure.
                self.assertNotIn("…", output)
                self.assertIn("Mar 17 21:00", output)  # Codex weekly reset
                self.assertIn("↑41%", output)  # Codex weekly pace
                self.assertIn("Mar 17 20:00", output)  # Claude weekly reset
                self.assertIn("↓25%", output)  # Claude 5h pace

    def test_dashboard_two_column_keeps_bars_above_collapse_band(self) -> None:
        # Bracket the other side of the transition: at a comfortably wide
        # two-column width the usage bars are still present, so the collapse is
        # width-driven rather than always-off.
        output = _capture(
            build_dashboard([self.codex_snap, self.claude_snap], self.now, 30), width=92
        )
        self.assertTrue(
            any("Codex" in line and "Claude" in line for line in output.splitlines()),
            "Expected two columns at width 92",
        )
        self.assertIn("▓", output)

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

    def test_render_json_excludes_cursor_dollar_meter_field(self) -> None:
        """--json keeps Cursor's two real usage pools; drops the dollar meter."""
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

        self.assertNotIn("credit_percent_left", data)
        self.assertEqual(data["auto_percent_used"], 6.6)
        self.assertEqual(data["api_percent_used"], 1.5)
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
            ("Copilot", {"premium_percent_left": 95.0}),
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

    def test_antigravity_retry_marker_is_neutral_and_has_no_cta(self) -> None:
        snap = ProviderSnapshot(
            name="Antigravity", ok=False, source="api", error=ANTIGRAVITY_AUTH_RETRY_MESSAGE
        )
        panel = build_provider_panel(snap, self.now, auth_fix_key="1")
        output = _capture(panel, width=70)
        self.assertIn("retrying", output)
        self.assertIn("values may be stale", output)
        self.assertNotIn("auth error", output)
        self.assertEqual(panel.border_style, "text.yellow")

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


class CompactModeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.now = datetime(2026, 3, 14, 8, 22, 30)

    # -- _compact_window_parts -------------------------------------------------

    def test_compact_window_parts_error_snapshot_returns_empty(self) -> None:
        snap = ProviderSnapshot(name="Codex", ok=False, source="cli", error="timeout")
        self.assertEqual(_compact_window_parts(snap, self.now), [])

    def test_compact_window_parts_cursor_converts_used_to_remaining(self) -> None:
        snap = ProviderSnapshot(
            name="Cursor",
            ok=True,
            source="api",
            data={
                "auto_percent_used": 6.6,
                "api_percent_used": 1.5,
                "billing_cycle_start": "2026-03-01T00:00:00",
                "billing_cycle_end_iso": "2026-04-01T00:00:00+00:00",
            },
        )
        result = _compact_window_parts(snap, self.now)
        self.assertEqual(len(result), 2)
        labels = {part.split(":")[0] for part, _ in result}
        self.assertEqual(labels, {"ac", "ap"})
        for text, style in result:
            self.assertIn(style, ("text.green", "text.red", "text.yellow", "text.muted"))

    def test_compact_window_parts_cursor_missing_percent_skipped(self) -> None:
        snap = ProviderSnapshot(
            name="Cursor",
            ok=True,
            source="api",
            data={
                "api_percent_used": 1.5,
                "billing_cycle_start": "2026-03-01T00:00:00",
                "billing_cycle_end_iso": "2026-04-01T00:00:00+00:00",
            },
        )
        result = _compact_window_parts(snap, self.now)
        self.assertEqual(len(result), 1)
        self.assertIn("ap:", result[0][0])
        self.assertNotIn("ac:", result[0][0])

    def test_compact_window_parts_vibe_usage_to_remaining(self) -> None:
        snap = ProviderSnapshot(
            name="Vibe",
            ok=True,
            source="api",
            data={
                "usage_percent": 1.17,
                "start_date": "2026-03-01T00:00:00+00:00",
                "end_date": "2026-04-01T00:00:00+00:00",
            },
        )
        result = _compact_window_parts(snap, self.now)
        self.assertEqual(len(result), 1)
        text = result[0][0]
        self.assertIn("mo:", text)
        # 1.17% used leaves 98.83, which truncates to 98 rather than rounding to 99.
        self.assertIn("98%", text)
        self.assertTrue(any(c in text for c in "↑↓=—"))

    def test_compact_window_parts_vibe_non_numeric_usage_returns_empty(self) -> None:
        snap = ProviderSnapshot(
            name="Vibe",
            ok=True,
            source="api",
            data={"usage_percent": "unknown"},
        )
        self.assertEqual(_compact_window_parts(snap, self.now), [])

    def test_compact_window_parts_unknown_provider_returns_empty(self) -> None:
        snap = ProviderSnapshot(
            name="Foobar",
            ok=True,
            source="cli",
            data={"some_key": 42},
        )
        self.assertEqual(_compact_window_parts(snap, self.now), [])

    def test_compact_window_parts_codex_fractional_below_ten(self) -> None:
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 5.5,
                "five_hour_reset": "Resets 1:16 PM (EDT)",
                "weekly_percent_left": 91,
                "weekly_reset": "Resets Mar 17 at 9 PM",
            },
        )
        result = _compact_window_parts(snap, self.now)
        self.assertEqual(len(result), 2)
        texts = [text for text, _ in result]
        self.assertIn("5h:5.5%", texts[0])
        self.assertIn("1w:91%", texts[1])

    def test_compact_window_parts_cursor_fractional_below_ten(self) -> None:
        snap = ProviderSnapshot(
            name="Cursor",
            ok=True,
            source="api",
            data={
                "auto_percent_used": 94.5,
                "api_percent_used": 1.5,
                "billing_cycle_start": "2026-03-01T00:00:00",
                "billing_cycle_end_iso": "2026-04-01T00:00:00+00:00",
            },
        )
        result = _compact_window_parts(snap, self.now)
        texts = [text for text, _ in result]
        self.assertEqual(len(result), 2)
        self.assertTrue(any("ac:5.5%" in text for text in texts))
        self.assertTrue(any("ap:98%" in text for text in texts))

    def test_compact_window_parts_vibe_fractional_below_ten(self) -> None:
        snap = ProviderSnapshot(
            name="Vibe",
            ok=True,
            source="api",
            data={
                "usage_percent": 94.5,
                "start_date": "2026-03-01T00:00:00+00:00",
                "end_date": "2026-04-01T00:00:00+00:00",
            },
        )
        result = _compact_window_parts(snap, self.now)
        self.assertEqual(len(result), 1)
        self.assertIn("mo:5.5%", result[0][0])

    def test_compact_window_parts_codex_standard_format(self) -> None:
        snap = ProviderSnapshot(
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
        result = _compact_window_parts(snap, self.now)
        self.assertEqual(len(result), 2)
        texts = [text for text, _ in result]
        self.assertIn("5h:", texts[0])
        self.assertIn("68%", texts[0])
        self.assertIn("1w:", texts[1])
        self.assertIn("91%", texts[1])
        for text in texts:
            self.assertTrue(any(c in text for c in "↑↓=—"))
        for _text, style in result:
            self.assertIn(style, ("text.green", "text.red", "text.yellow", "text.muted"))

    def test_compact_window_parts_antigravity_cg_windows(self) -> None:
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 86,
                "five_hour_reset": "resets in 3h 19m",
                "weekly_percent_left": 96,
                "weekly_reset": "resets in 5d 18h",
                "third_party_five_hour_percent_left": 55,
                "third_party_five_hour_reset": "Resets 9:22 AM",
                "third_party_weekly_percent_left": 72,
                "third_party_weekly_reset": "Resets Mar 21 at 8:22 AM",
            },
        )
        result = _compact_window_parts(snap, self.now)
        self.assertEqual(len(result), 4)
        labels = [part.split(":")[0] for part, _ in result]
        self.assertEqual(labels, ["5h", "1w", "cg5", "cg1w"])

    # -- _build_compact_lines --------------------------------------------------

    def test_build_compact_lines_no_active_returns_empty(self) -> None:
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0,
                "five_hour_reset": "Resets 1:16 PM (EDT)",
                "weekly_percent_left": 0,
                "weekly_reset": "Resets Mar 17 at 9 PM",
            },
        )
        self.assertEqual(_build_compact_lines([snap], self.now), [])

    def test_build_compact_lines_multiple_providers_layout(self) -> None:
        codex = ProviderSnapshot(
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
        claude = ProviderSnapshot(
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
        lines = [
            _capture(r, width=120).rstrip() for r in _build_compact_lines([codex, claude], self.now)
        ]
        self.assertTrue(any("Codex" in line for line in lines))
        self.assertTrue(any("Claude" in line for line in lines))
        # Blank line between providers
        self.assertIn("", [ln.strip() for ln in lines])
        # Names aligned at the same column
        codex_line = next(ln for ln in lines if "Codex" in ln)
        claude_line = next(ln for ln in lines if "Claude" in ln)
        self.assertEqual(codex_line.index("Codex"), claude_line.index("Claude"))

    def test_build_compact_lines_antigravity_max_two_windows_per_line(self) -> None:
        antigravity = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 86,
                "five_hour_reset": "resets in 3h 19m",
                "weekly_percent_left": 96,
                "weekly_reset": "resets in 5d 18h",
                "third_party_five_hour_percent_left": 55,
                "third_party_five_hour_reset": "Resets 9:22 AM",
                "third_party_weekly_percent_left": 72,
                "third_party_weekly_reset": "Resets Mar 21 at 8:22 AM",
            },
        )
        lines = [
            _capture(r, width=120).rstrip() for r in _build_compact_lines([antigravity], self.now)
        ]
        self.assertEqual(len(lines), 2)
        self.assertIn("5h:", lines[0])
        self.assertIn("1w:", lines[0])
        self.assertIn("cg5:", lines[1])
        self.assertIn("cg1w:", lines[1])

    # -- _ResponsiveDashboardBody ----------------------------------------------

    def test_responsive_body_below_threshold_renders_compact(self) -> None:
        codex = ProviderSnapshot(
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
        panels = [build_provider_panel(codex, self.now)]
        compact = _build_compact_lines([codex], self.now)
        body = _ResponsiveDashboardBody(panels, compact)
        output = _capture(body, width=70)
        self.assertIn("Codex", output)
        self.assertNotIn("╭", output)
        self.assertNotIn("╰", output)

    def test_dashboard_compact_shows_decimal_for_fractional_percent(self) -> None:
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 5.5,
                "five_hour_reset": "Resets 1:16 PM (EDT)",
                "weekly_percent_left": 91,
                "weekly_reset": "Resets Mar 17 at 9 PM",
            },
        )
        output = _capture(build_dashboard([snap], self.now, 30), width=78)
        self.assertIn("5.5%", output)
        self.assertIn("91%", output)

    def test_responsive_body_above_threshold_renders_panels(self) -> None:
        codex = ProviderSnapshot(
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
        panels = [build_provider_panel(codex, self.now)]
        compact = _build_compact_lines([codex], self.now)
        body = _ResponsiveDashboardBody(panels, compact)
        output = _capture(body, width=92)
        self.assertIn("Codex", output)
        self.assertIn("╭", output)


if __name__ == "__main__":
    unittest.main()


# ---------------------------------------------------------------------------
# Characterization tests — pin exact string output BEFORE refactor
# ---------------------------------------------------------------------------
from gradus.ui import _billing_cycle_pace_label, _pace_label  # noqa: E402


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
        # 60% left, 50% of window remaining → delta=+0.10 → 10% ahead
        result = _pace_label(60, "Resets in 2h 30m", self.now, 5.0)
        self.assertEqual(result, "10% ahead")

    def test_pace_label_over_when_less_budget_than_time(self) -> None:
        # 40% left, 50% of window remaining → delta=-0.10 → 10% behind
        result = _pace_label(40, "Resets in 2h 30m", self.now, 5.0)
        self.assertEqual(result, "10% behind")

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
        self.assertEqual(result, "13% ahead")

    def test_billing_cycle_pace_label_over_tzaware(self) -> None:
        result = _billing_cycle_pace_label(
            50,
            "2026-03-01T00:00:00+00:00",
            "2026-04-01T00:00:00+00:00",
            self.now,
        )
        self.assertEqual(result, "7% behind")

    def test_dashboard_sorts_exhausted_providers_to_bottom(self) -> None:
        """Exhausted providers are sorted after active providers in the dashboard list."""
        copilot_depleted = ProviderSnapshot(
            name="Copilot",
            ok=True,
            source="http",
            data={"premium_percent_left": 0.0, "premium_reset": "Resets Apr 01"},
        )
        codex_active = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="api",
            data={"five_hour_percent_left": 80, "weekly_percent_left": 90},
        )
        group = build_dashboard([copilot_depleted, codex_active], self.now, 120)
        output = _capture(group, width=90)
        codex_idx = output.find("Codex")
        copilot_idx = output.find("Copilot")
        self.assertNotEqual(codex_idx, -1)
        self.assertNotEqual(copilot_idx, -1)
        self.assertLess(codex_idx, copilot_idx)

    def test_dashboard_odd_exhausted_count_all_use_micro_card_style(self) -> None:
        # Regression: with three exhausted providers, the first two paired up
        # as condensed micro-cards but the trailing unpaired one fell back to
        # the taller full depleted panel — an inconsistent look. All three
        # must now render with the same single-line "0% until <reset>" micro
        # format.
        antigravity_depleted = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0,
                "five_hour_reset": "Resets 19:16",
                "weekly_percent_left": 0,
                "weekly_reset": "Resets 19:16",
            },
        )
        copilot_depleted = ProviderSnapshot(
            name="Copilot",
            ok=True,
            source="http",
            data={"premium_percent_left": 0.0, "premium_reset": "Resets Jul 31 20:00"},
        )
        vibe_depleted = ProviderSnapshot(
            name="Vibe",
            ok=True,
            source="cli",
            data={"usage_percent": 100.0, "reset_at": "Resets Jul 31 20:00"},
        )
        group = build_dashboard(
            [antigravity_depleted, copilot_depleted, vibe_depleted], self.now, 79
        )
        output = _capture(group, width=90)
        self.assertIn("Antigravity [!]", output)
        self.assertIn("Copilot [!]", output)
        self.assertIn("Vibe [!]", output)
        self.assertEqual(output.count("0% until"), 3)

    def test_dashboard_single_exhausted_provider_uses_micro_card_style(self) -> None:
        # Regression: a lone exhausted provider (alongside an active one) used
        # to fall back to the taller full depleted panel, which shows "0%"
        # and "until <reset>" in separate table cells rather than the
        # condensed micro-card's single contiguous "0% until <reset>" string.
        codex_active = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 68,
                "five_hour_reset": "Resets 1:16 PM",
                "weekly_percent_left": 91,
                "weekly_reset": "Resets Mar 17 at 9 PM",
            },
        )
        copilot_depleted = ProviderSnapshot(
            name="Copilot",
            ok=True,
            source="http",
            data={"premium_percent_left": 0.0, "premium_reset": "Resets Apr 01"},
        )
        group = build_dashboard([codex_active, copilot_depleted], self.now, 30)
        output = _capture(group, width=90)
        self.assertIn("Copilot [!]", output)
        self.assertIn("0% until Apr 01", output)

    def test_dashboard_even_exhausted_count_all_pair_up(self) -> None:
        # Characterization: this branch predates the odd-leftover fix, but is
        # adjacent code exercised by the same pairing loop — lock in that an
        # even count of exhausted providers pairs up completely, with no
        # trailing DynamicMicroDepletedSingle card.
        antigravity_depleted = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0,
                "five_hour_reset": "Resets 19:16",
                "weekly_percent_left": 0,
                "weekly_reset": "Resets 19:16",
            },
        )
        claude_depleted = ProviderSnapshot(
            name="Claude",
            ok=True,
            source="cli",
            data={
                "session_percent_left": 0,
                "primary_reset": "Resets 19:16",
                "weekly_percent_left": 0,
                "secondary_reset": "Resets 19:16",
            },
        )
        copilot_depleted = ProviderSnapshot(
            name="Copilot",
            ok=True,
            source="http",
            data={"premium_percent_left": 0.0, "premium_reset": "Resets Jul 31 20:00"},
        )
        vibe_depleted = ProviderSnapshot(
            name="Vibe",
            ok=True,
            source="cli",
            data={"usage_percent": 100.0, "reset_at": "Resets Jul 31 20:00"},
        )
        group = build_dashboard(
            [antigravity_depleted, claude_depleted, copilot_depleted, vibe_depleted],
            self.now,
            30,
        )
        output = _capture(group, width=90)
        lines = output.splitlines()
        self.assertTrue(
            any("Antigravity" in line and "Claude" in line for line in lines),
            "expected the first exhausted pair on the same micro-card row",
        )
        self.assertTrue(
            any("Copilot" in line and "Vibe" in line for line in lines),
            "expected the second exhausted pair on the same micro-card row",
        )
        self.assertEqual(output.count("0% until"), 4)

    # ------------------------------------------------------------------
    # _billing_cycle_pace_label — naive date-only billing cycle
    # 2026-03-01..2026-03-20, now=2026-03-14T08:22:30 → ~29.7% remaining
    # ------------------------------------------------------------------

    def test_billing_cycle_pace_label_on_pace_naive(self) -> None:
        result = _billing_cycle_pace_label(30, "2026-03-01", "2026-03-20", self.now)
        self.assertEqual(result, "on pace")

    def test_billing_cycle_pace_label_under_naive(self) -> None:
        result = _billing_cycle_pace_label(35, "2026-03-01", "2026-03-20", self.now)
        self.assertEqual(result, "5% ahead")

    def test_billing_cycle_pace_label_over_naive(self) -> None:
        result = _billing_cycle_pace_label(20, "2026-03-01", "2026-03-20", self.now)
        self.assertEqual(result, "10% behind")


class ExtractDepletedResetStrTests(unittest.TestCase):
    def setUp(self) -> None:
        self.now = datetime(2026, 3, 14, 8, 22, 30)

    def test_extract_reset_str_known_provider_window_depleted(self) -> None:
        snap = ProviderSnapshot(
            name="Copilot",
            ok=True,
            source="http",
            data={"premium_percent_left": 0.0, "premium_reset": "2026-03-20T12:00:00Z"},
        )
        self.assertEqual(_extract_depleted_reset_str(snap, self.now), "2026-03-20T12:00:00Z")

    def test_extract_reset_str_antigravity_cg_window_depleted(self) -> None:
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "third_party_five_hour_percent_left": 0.0,
                "third_party_five_hour_reset": "2026-03-21T15:00:00Z",
            },
        )
        self.assertEqual(_extract_depleted_reset_str(snap, self.now), "2026-03-21T15:00:00Z")

    def test_extract_reset_str_fallback_keys(self) -> None:
        snap = ProviderSnapshot(
            name="CustomProvider",
            ok=True,
            source="api",
            data={"billing_cycle_end": "2026-04-01"},
        )
        self.assertEqual(_extract_depleted_reset_str(snap, self.now), "2026-04-01")

    def test_extract_reset_str_returns_none_when_no_reset_found(self) -> None:
        snap = ProviderSnapshot(
            name="CustomProvider",
            ok=True,
            source="api",
            data={},
        )
        self.assertIsNone(_extract_depleted_reset_str(snap, self.now))

    def test_extract_reset_str_antigravity_cross_window_picks_soonest_blocking_pool(self) -> None:
        # Native pool is blocked solely by 5h (resets 8pm); third-party pool
        # is blocked solely by cg5 (resets 9am, earlier). The provider is
        # usable again the moment either pool clears, so the soonest (9am)
        # is correct — not native 5h just because it iterates first. Reset
        # strings use the real "Resets <date> at <time>" format providers.py
        # emits (raw ISO strings never reach this function in production).
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0.0,
                "five_hour_reset": "Resets Mar 14 at 08:00 PM",
                "weekly_percent_left": 50.0,
                "third_party_five_hour_percent_left": 0.0,
                "third_party_five_hour_reset": "Resets Mar 14 at 09:00 AM",
                "third_party_weekly_percent_left": 50.0,
            },
        )
        self.assertTrue(_provider_is_empty(snap, self.now))
        self.assertEqual(_extract_depleted_reset_str(snap, self.now), "Resets Mar 14 at 09:00 AM")

    def test_extract_reset_str_antigravity_within_pool_picks_latest_depleted_window(self) -> None:
        # Native pool has BOTH windows depleted (5h resets 9am, weekly resets
        # 11am same day) -- the pool doesn't clear until the LATER of the two
        # (11am), not whichever window iterates first (5h). Third-party pool
        # is blocked only by cg5, resetting the next day (much later), so
        # native's 11am correctly wins the overall soonest-pool selection --
        # a wrong within-pool pick (9am) would surface directly in the result.
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0.0,
                "five_hour_reset": "Resets Mar 14 at 09:00 AM",
                "weekly_percent_left": 0.0,
                "weekly_reset": "Resets Mar 14 at 11:00 AM",
                "third_party_five_hour_percent_left": 0.0,
                "third_party_five_hour_reset": "Resets Mar 15 at 09:00 AM",
                "third_party_weekly_percent_left": 50.0,
            },
        )
        self.assertTrue(_provider_is_empty(snap, self.now))
        self.assertEqual(_extract_depleted_reset_str(snap, self.now), "Resets Mar 14 at 11:00 AM")

    def test_extract_reset_str_antigravity_third_party_absent_picks_soonest_native_window(
        self,
    ) -> None:
        # Accounts with no C+G tracking report third-party fields as None
        # entirely (not 0%), so `_provider_is_empty`'s two-pool AND can never
        # fire -- an absent pool's blocked flag is permanently False. It
        # falls back to "every available window depleted", which un-exhausts
        # the instant ANY currently-depleted window recovers -- the soonest
        # (min) of native's two resets, not the latest (max) a present pool
        # would use. Reporting the later one would overstate the wait far
        # beyond how long the card actually stays up.
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0.0,
                "five_hour_reset": "Resets Mar 14 at 11:00 AM",
                "weekly_percent_left": 0.0,
                "weekly_reset": "Resets Mar 19 at 09:00 AM",
                "third_party_five_hour_percent_left": None,
                "third_party_weekly_percent_left": None,
            },
        )
        self.assertTrue(_provider_is_empty(snap, self.now))
        self.assertEqual(_extract_depleted_reset_str(snap, self.now), "Resets Mar 14 at 11:00 AM")

    def test_extract_reset_str_codex_cross_pool_picks_soonest_blocking_pool(self) -> None:
        # Native pool has BOTH windows depleted (5h resets 8pm, weekly resets
        # 6am same day) -- the native pool doesn't clear until the LATER of
        # the two (8pm). Spark is its own single-window pool, resetting the
        # next morning (9am Mar 15, later still). Codex is usable again the
        # moment either pool clears, so the soonest across pools (8pm Mar 14)
        # is correct -- not a flat max/min over all three raw windows, which
        # would pick 6am (flat min) or 9am Mar 15 (flat max) instead.
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0.0,
                "five_hour_reset": "Resets Mar 14 at 08:00 PM",
                "weekly_percent_left": 0.0,
                "weekly_reset": "Resets Mar 14 at 06:00 AM",
                "spark_weekly_percent_left": 0.0,
                "spark_weekly_reset": "Resets Mar 15 at 09:00 AM",
            },
        )
        self.assertTrue(_provider_is_empty(snap, self.now))
        self.assertEqual(_extract_depleted_reset_str(snap, self.now), "Resets Mar 14 at 08:00 PM")

    def test_extract_reset_str_codex_spark_absent_falls_back_to_flat_latest_native_window(
        self,
    ) -> None:
        # Spark absent (None) entirely -- the realistic case for accounts
        # without Spark access -- so `_provider_is_empty`'s two-pool AND
        # can't fire; it falls back to Codex's legacy rule where native 5h/1w
        # are tranches of one quota and *either* window at 0% blocks the
        # provider (OR). That OR only clears once BOTH currently-depleted
        # windows have reset, so this is the latest (max) of native's two
        # resets (Mar 19), not the soonest (min).
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0.0,
                "five_hour_reset": "Resets Mar 14 at 11:00 AM",
                "weekly_percent_left": 0.0,
                "weekly_reset": "Resets Mar 19 at 09:00 AM",
                "spark_weekly_percent_left": None,
                "spark_weekly_reset": None,
            },
        )
        self.assertTrue(_provider_is_empty(snap, self.now))
        self.assertEqual(_extract_depleted_reset_str(snap, self.now), "Resets Mar 19 at 09:00 AM")

    def test_codex_spark_five_hour_capacity_keeps_provider_available_without_weekly(self) -> None:
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 80.0,
                "weekly_percent_left": 80.0,
                "spark_five_hour_percent_left": 60.0,
                "spark_weekly_percent_left": None,
            },
        )
        self.assertFalse(_provider_is_empty(snap, self.now))

    def test_codex_spark_weekly_depletion_does_not_block_when_five_hour_has_capacity(self) -> None:
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 80.0,
                "weekly_percent_left": 80.0,
                "spark_five_hour_percent_left": 60.0,
                "spark_weekly_percent_left": 0.0,
                "spark_weekly_reset": "Resets Mar 15 at 09:00 AM",
            },
        )
        self.assertFalse(_provider_is_empty(snap, self.now))

    def test_codex_spark_reset_selection_considers_both_windows(self) -> None:
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 80.0,
                "weekly_percent_left": 80.0,
                "spark_five_hour_percent_left": 0.0,
                "spark_five_hour_reset": "Resets Mar 14 at 10:00 AM",
                "spark_weekly_percent_left": 0.0,
                "spark_weekly_reset": "Resets Mar 15 at 09:00 AM",
            },
        )
        self.assertEqual(_extract_depleted_reset_str(snap, self.now), "Resets Mar 15 at 09:00 AM")


class MicroDepletedPanelTests(unittest.TestCase):
    def setUp(self) -> None:
        self.now = datetime(2026, 3, 14, 8, 22, 30)

    def test_micro_depleted_panel_antigravity_cross_window_shows_soonest_pool_reset(self) -> None:
        # Regression test through the actual live-rendered path: exhausted
        # Antigravity always reaches the micro-card (never build_provider_panel),
        # so this must exercise build_micro_depleted_panel directly.
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0.0,
                "five_hour_reset": "Resets Mar 14 at 08:00 PM",
                "weekly_percent_left": 50.0,
                "third_party_five_hour_percent_left": 0.0,
                "third_party_five_hour_reset": "Resets Mar 14 at 09:00 AM",
                "third_party_weekly_percent_left": 50.0,
            },
        )
        panel = build_micro_depleted_panel(snap, self.now, width=25)
        output = _capture(panel, width=25)
        self.assertIn("0% until 09:00", output)
        self.assertNotIn("20:00", output)

    def test_micro_depleted_panel_antigravity_within_pool_shows_latest_depleted_window(
        self,
    ) -> None:
        # Native pool has both windows depleted (5h resets 9am, weekly resets
        # 11am same day); native wins the soonest-pool selection over
        # third-party's next-day reset. Must show 11am (the later, correct
        # within-pool clear time), not 9am (the first-iterated window).
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0.0,
                "five_hour_reset": "Resets Mar 14 at 09:00 AM",
                "weekly_percent_left": 0.0,
                "weekly_reset": "Resets Mar 14 at 11:00 AM",
                "third_party_five_hour_percent_left": 0.0,
                "third_party_five_hour_reset": "Resets Mar 15 at 09:00 AM",
                "third_party_weekly_percent_left": 50.0,
            },
        )
        panel = build_micro_depleted_panel(snap, self.now, width=25)
        output = _capture(panel, width=25)
        self.assertIn("0% until 11:00", output)
        self.assertNotIn("09:00", output)
        self.assertNotIn("Mar 15", output)

    def test_micro_depleted_panel_antigravity_third_party_absent_shows_soonest_native_window(
        self,
    ) -> None:
        # Live-render counterpart: an account with no C+G tracking (third-party
        # fields entirely None) must show native's soonest depleted window
        # (11am), not the later one (Mar 19) a two-pool-present account would
        # use.
        snap = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0.0,
                "five_hour_reset": "Resets Mar 14 at 11:00 AM",
                "weekly_percent_left": 0.0,
                "weekly_reset": "Resets Mar 19 at 09:00 AM",
                "third_party_five_hour_percent_left": None,
                "third_party_weekly_percent_left": None,
            },
        )
        panel = build_micro_depleted_panel(snap, self.now, width=25)
        output = _capture(panel, width=25)
        self.assertIn("0% until 11:00", output)
        self.assertNotIn("Mar 19", output)
        self.assertNotIn("09:00", output)

    def test_build_micro_depleted_panel_strips_http_suffix(self) -> None:
        snap = ProviderSnapshot(
            name="Copilot [HTTP]",
            ok=True,
            source="http",
            data={"premium_percent_left": 0.0, "premium_reset": "Resets Apr 01"},
        )
        panel = build_micro_depleted_panel(snap, self.now, width=25)
        self.assertEqual(panel.width, 25)
        output = _capture(panel, width=25)
        self.assertIn("Copilot", output)
        self.assertNotIn("Copilot [HTTP]", output)
        self.assertIn("[!]", output)
        self.assertIn("0% until Apr 01", output)

    def test_build_micro_depleted_panel_handles_missing_reset(self) -> None:
        snap = ProviderSnapshot(name="Claude", ok=True, source="http", data={})
        panel = build_micro_depleted_panel(snap, self.now)
        output = _capture(panel)
        self.assertIn("0% until n/a", output)

    def test_codex_micro_depleted_panel_cross_pool_shows_soonest_blocking_reset(self) -> None:
        # Regression test through the actual live-rendered path: exhausted
        # Codex always reaches the micro-card (never build_provider_panel),
        # so this must exercise build_micro_depleted_panel directly. Both
        # native windows are depleted (pool clears at the LATER of the two,
        # 8pm) and Spark is independently depleted (its own reset, 9am the
        # next day, later still) -- the card must show the soonest blocking
        # pool's reset (8pm), not one reset merged/first-found across all
        # three windows indiscriminately (a flat max would show 9am the next
        # day; a flat min would show weekly's 6am).
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0.0,
                "five_hour_reset": "Resets Mar 14 at 08:00 PM",
                "weekly_percent_left": 0.0,
                "weekly_reset": "Resets Mar 14 at 06:00 AM",
                "spark_weekly_percent_left": 0.0,
                "spark_weekly_reset": "Resets Mar 15 at 09:00 AM",
            },
        )
        panel = build_micro_depleted_panel(snap, self.now, width=25)
        output = _capture(panel, width=25)
        self.assertIn("0% until 20:00", output)
        self.assertNotIn("06:00", output)
        self.assertNotIn("Mar 15", output)

    def test_codex_micro_depleted_panel_spark_absent_still_renders_depleted_view(self) -> None:
        # Regression for the presence hazard described in `_pool_is_present`:
        # spark_weekly_percent_left is None for accounts without Spark access
        # (the realistic case today). A naive `native_blocked and
        # spark_blocked` rule in `_provider_is_empty` would make
        # spark_blocked permanently False for these accounts, so a Codex
        # account with native quota fully exhausted would NEVER show the
        # depleted view again. This exercises the live render path
        # (build_dashboard's DynamicMicroDepletedSingle/Pair both call
        # build_micro_depleted_panel) and asserts the card still renders the
        # depleted view, showing native's own latest reset (the provider
        # stays blocked until BOTH depleted native windows clear).
        snap = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="cli",
            data={
                "five_hour_percent_left": 0.0,
                "five_hour_reset": "Resets Mar 14 at 11:00 AM",
                "weekly_percent_left": 0.0,
                "weekly_reset": "Resets Mar 19 at 09:00 AM",
                "spark_weekly_percent_left": None,
                "spark_weekly_reset": None,
            },
        )
        self.assertTrue(_provider_is_empty(snap, self.now))
        panel = build_micro_depleted_panel(snap, self.now, width=25)
        output = _capture(panel, width=25)
        self.assertIn("Mar 19", output)
        self.assertIn("09:00", output)
        self.assertNotIn("11:00", output)


class DynamicMicroDepletedPairTests(unittest.TestCase):
    def setUp(self) -> None:
        self.now = datetime(2026, 3, 14, 8, 22, 30)

    def test_dynamic_micro_depleted_pair_renders_side_by_side(self) -> None:
        snap1 = ProviderSnapshot(
            name="Copilot",
            ok=True,
            source="http",
            data={"premium_percent_left": 0.0, "premium_reset": "Resets Apr 01"},
        )
        snap2 = ProviderSnapshot(
            name="Cursor",
            ok=True,
            source="http",
            data={"five_hour_percent_left": 0.0, "five_hour_reset_at": "in 3h37m30s"},
        )
        pair = DynamicMicroDepletedPair(snap1, snap2, self.now)
        output = _capture(pair, width=50)
        self.assertIn("Copilot", output)
        self.assertIn("Cursor", output)
        self.assertIn("0% until Apr 01", output)
        self.assertIn("0% until 11:59", output)


class DynamicMicroDepletedSingleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.now = datetime(2026, 3, 14, 8, 22, 30)

    def test_dynamic_micro_depleted_single_renders_micro_content(self) -> None:
        snap = ProviderSnapshot(
            name="Copilot",
            ok=True,
            source="http",
            data={"premium_percent_left": 0.0, "premium_reset": "Resets Apr 01"},
        )
        single = DynamicMicroDepletedSingle(snap, self.now)
        output = _capture(single, width=50)
        self.assertIn("Copilot", output)
        self.assertIn("[!]", output)
        self.assertIn("0% until Apr 01", output)

    def test_dynamic_micro_depleted_single_renders_one_box_unlike_pair(self) -> None:
        # A Single card fills the entire available column width as *one*
        # panel, unlike Pair which splits that same width between *two*
        # side-by-side panels. This is the one behavior Single adds over
        # calling build_micro_depleted_panel directly, and it's the reason
        # Single exists (an odd-leftover/lone provider shouldn't get a
        # half-width, mismatched micro card).
        snap = ProviderSnapshot(
            name="Copilot",
            ok=True,
            source="http",
            data={"premium_percent_left": 0.0, "premium_reset": "Resets Apr 01"},
        )
        single_output = _capture(DynamicMicroDepletedSingle(snap, self.now), width=50)
        self.assertEqual(single_output.count("╭"), 1)
        single_border = next(line for line in single_output.splitlines() if line.startswith("╭"))
        self.assertEqual(len(single_border), 50)

        pair_output = _capture(DynamicMicroDepletedPair(snap, snap, self.now), width=50)
        self.assertEqual(pair_output.count("╭"), 2)
