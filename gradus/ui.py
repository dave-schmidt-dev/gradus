"""Terminal rendering for the usage dashboard."""

from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass
from datetime import datetime, timezone

from rich.console import Console, ConsoleOptions, Group, RenderableType, RenderResult
from rich.panel import Panel
from rich.segment import Segment
from rich.spinner import Spinner
from rich.table import Table
from rich.text import Text
from rich.theme import Theme

from .providers import ProviderSnapshot
from .snapshot import (
    normalized_warning_windows,
    pace_delta,
    percent_is_depleted,
    percent_is_valid,
    project_data,
    reconcile,
    warning_window_ids,
)
from .snapshot import parse_reset_target as _parse_reset_target

THEME = Theme(
    {
        "bg": "on color(17)",
        "panel": "on color(236)",
        "panel_alt": "on color(234)",
        "text.ink": "color(254)",
        "text.muted": "color(250)",
        "text.blue": "color(111)",
        "text.cyan": "color(117)",
        "text.teal": "color(80)",
        "text.green": "color(114)",
        "text.yellow": "color(221)",
        "text.orange": "color(215)",
        "text.red": "color(203)",
        "text.pink": "color(219)",
        "border": "color(67)",
        "shadow": "color(239)",
        "bar.empty": "color(244)",
        "bar.green": "color(114)",
        "bar.yellow": "color(221)",
        "bar.orange": "color(215)",
        "bar.red": "color(203)",
        # The expected-pace marker. Blue, David's call, and its own key rather
        # than a borrowed `bar.red` so the tier colours are not entangled with
        # it. Blue also happens to be the one hue no fill tier uses, which is
        # what the marker needs: it says "here is where you should be", not
        # "this provider is in trouble", and while it was red it was the same
        # colour as the fill on a red bar -- a 1.00 contrast ratio, i.e. gone,
        # on the one row where pace matters most.
        #
        # This exact blue because the marker crosses two very different
        # backgrounds: the light pastel fills, and the dark empty track. A
        # properly dark navy (#0000af) is crisp on the fill and then vanishes
        # into the terminal background out in the track, where the marker sits
        # whenever a provider is behind. #005fd7 is the darkest blue that stays
        # legible in both places -- 1.95-4.18 against the four fills, 2.42
        # against the terminal background.
        #
        # Used as a foreground on the bar's own fill glyph, never as a
        # background. Painting this as a background was tried twice and
        # rejected on sight both times: `▓` is a stipple, so a cell given a
        # background becomes the only solid one in a textured row.
        "bar.marker": "color(26)",
        "accent.codex": "color(111)",
        "accent.claude": "color(219)",
        "accent.gemini": "color(80)",
        "accent.copilot": "color(117)",
        "accent.cursor": "color(214)",
        "accent.vibe": "color(208)",
        "accent.opencode": "color(150)",
    }
)


@dataclass(frozen=True, slots=True)
class WindowRenderSpec:
    window_id: str
    session_label: str
    reset_label: str
    pace_label: str | None
    percent_key: str
    reset_key: str
    window_hours: float | None
    # When True, the row is hidden entirely if the provider reports no data for
    # it (percent is None) — as opposed to rendering "n/a". Used for the Codex 5h
    # window, which OpenAI removed in 2026-07 but may restore; the row reappears
    # automatically once the API reports the window again.
    omit_when_empty: bool = False


@dataclass(frozen=True, slots=True)
class ProviderRenderSpec:
    title: str
    subtitle: str
    windows: tuple[WindowRenderSpec, ...]


PROVIDER_RENDER_SPECS = {
    "Codex": ProviderRenderSpec(
        title="Codex",
        subtitle="Codex usage",
        windows=(
            WindowRenderSpec(
                "five_hour",
                "5h",
                "5h ↻",
                None,
                "five_hour_percent_left",
                "five_hour_reset",
                5.0,
            ),
            WindowRenderSpec(
                "weekly",
                "1w",
                "1w ↻",
                None,
                "weekly_percent_left",
                "weekly_reset",
                24.0 * 7.0,
            ),
        ),
    ),
    "Claude": ProviderRenderSpec(
        title="Claude",
        subtitle="Claude usage",
        windows=(
            WindowRenderSpec(
                "five_hour",
                "5h",
                "5h ↻",
                None,
                "session_percent_left",
                "primary_reset",
                5.0,
            ),
            WindowRenderSpec(
                "weekly",
                "1w",
                "1w ↻",
                None,
                "weekly_percent_left",
                "secondary_reset",
                24.0 * 7.0,
            ),
        ),
    ),
    "Antigravity": ProviderRenderSpec(
        title="Antigravity",
        subtitle="Antigravity usage",
        windows=(
            WindowRenderSpec(
                "five_hour",
                "5h",
                "5h ↻",
                None,
                "five_hour_percent_left",
                "five_hour_reset",
                5.0,
            ),
            WindowRenderSpec(
                "weekly",
                "1w",
                "1w ↻",
                None,
                "weekly_percent_left",
                "weekly_reset",
                24.0 * 7.0,
            ),
        ),
    ),
    "Copilot": ProviderRenderSpec(
        title="Copilot",
        subtitle="Copilot usage",
        windows=(
            WindowRenderSpec(
                "premium",
                "mo",
                "mo ↻",
                None,
                "premium_percent_left",
                "premium_reset",
                None,
            ),
        ),
    ),
    # Windows are omitted (not "n/a") whenever the console response lacks them:
    # the provider raises when all three are missing, so a rendered card always
    # has at least one row and an absent window means the console changed.
    "OpenCode Go": ProviderRenderSpec(
        title="OpenCode Go",
        subtitle="OpenCode Go usage",
        windows=(
            WindowRenderSpec(
                "five_hour",
                "5h",
                "5h ↻",
                None,
                "five_hour_percent_left",
                "five_hour_reset",
                5.0,
                omit_when_empty=True,
            ),
            WindowRenderSpec(
                "weekly",
                "1w",
                "1w ↻",
                None,
                "weekly_percent_left",
                "weekly_reset",
                24.0 * 7.0,
                omit_when_empty=True,
            ),
            WindowRenderSpec(
                "monthly",
                "mo",
                "mo ↻",
                None,
                "monthly_percent_left",
                "monthly_reset",
                # Subscription-anchored month (28-31 days); 30-day approximation.
                24.0 * 30.0,
                omit_when_empty=True,
            ),
        ),
    ),
}


ANTIGRAVITY_CG_WINDOWS = (
    WindowRenderSpec(
        "cg_five_hour",
        "cg5",
        "cg5 ↻",
        None,
        "third_party_five_hour_percent_left",
        "third_party_five_hour_reset",
        5.0,
        omit_when_empty=True,
    ),
    WindowRenderSpec(
        "cg_weekly",
        "cg1w",
        "cg1w ↻",
        None,
        "third_party_weekly_percent_left",
        "third_party_weekly_reset",
        24.0 * 7.0,
        omit_when_empty=True,
    ),
)


# ---------------------------------------------------------------------------
# Shared helpers (business logic, kept from original)
# ---------------------------------------------------------------------------


def _plain(value: object | None) -> str:
    if value is None or value == "":
        return "n/a"
    return str(value)


def _truncate(text: str, width: int) -> str:
    if len(text) <= width:
        return text
    if width <= 1:
        return text[:width]
    return text[: width - 1] + "…"


def _countdown_label(reset_text: str | None, now: datetime) -> str | None:
    target = _parse_reset_target(reset_text, now)
    if target is None:
        return None
    delta = target - now
    total_minutes = int(delta.total_seconds() // 60)
    if total_minutes < 0:
        return None
    hours, minutes = divmod(total_minutes, 60)
    days, hours = divmod(hours, 24)
    if days > 0:
        return f"in {days}d {hours}h"
    if hours > 0:
        return f"in {hours}h {minutes}m"
    return f"in {minutes}m"


def _format_clock(hour: int, minute: int) -> str:
    return f"{hour:02d}:{minute:02d}"


def _cached_badge_text(snapshot: ProviderSnapshot, now: datetime) -> str:
    if not snapshot.cached_since:
        return "live"
    age_seconds = max(0, int((now - snapshot.cached_since).total_seconds()))
    if age_seconds < 60:
        return "cached <1m"
    age_minutes = age_seconds // 60
    if age_minutes < 60:
        return f"cached {age_minutes}m"
    age_hours = age_minutes // 60
    return f"cached {age_hours}h"


def _format_reset_display(reset_text: str | None, now: datetime) -> str:
    if not reset_text or reset_text == "n/a":
        return "n/a"
    target = _parse_reset_target(reset_text, now)
    if target is None:
        value = reset_text.replace("Resets", "").replace("resets", "").strip()
        return re.sub(r"\s+", " ", value)

    if target.date() != now.date():
        return target.strftime("%b %d ") + _format_clock(target.hour, target.minute)

    return _format_clock(target.hour, target.minute)


def _pace_value(
    percent_left: float | None,
    reset_text: str | None,
    now: datetime,
    window_hours: float | None,
) -> float | None:
    """Return a session window's numeric pace delta, or None if incomputable.

    Split out of :func:`_pace_label` so the row's *color* and its *label* are
    driven by the same number instead of recomputing it two ways.
    """
    if percent_left is None or window_hours is None:
        return None
    target = _parse_reset_target(reset_text, now)
    if target is None:
        return None
    return pace_delta(percent_left, target, window_hours * 3600.0, now)


def _pace_label(
    percent_left: float | None,
    reset_text: str | None,
    now: datetime,
    window_hours: float | None,
) -> str:
    delta = _pace_value(percent_left, reset_text, now, window_hours)
    if delta is None:
        return "n/a"
    diff_points = round(abs(delta) * 100)
    if abs(delta) <= 0.05:
        return "on pace"
    if delta > 0:
        return f"under +{diff_points}pt"
    return f"over -{diff_points}pt"


def _expected_remaining(percent_left: float | None, delta: float | None) -> float | None:
    """Return the expected remaining percentage for a valid pace calculation."""
    if not percent_is_valid(percent_left) or delta is None or not math.isfinite(delta):
        return None
    return max(0.0, min(100.0, float(percent_left) - (delta * 100.0)))


def _expected_session_remaining(
    percent_left: float | None,
    reset_text: str | None,
    now: datetime,
    window_hours: float | None,
) -> float | None:
    """Return a session window's expected remaining percentage, if computable."""
    try:
        if window_hours is None or not math.isfinite(window_hours) or window_hours <= 0:
            return None
        target = _parse_reset_target(reset_text, now)
        return _expected_remaining(
            percent_left,
            pace_delta(percent_left, target, window_hours * 3600.0, now),
        )
    except (OverflowError, TypeError, ValueError):
        # Malformed provider reset metadata must not take down dashboard
        # rendering; the row simply omits its expected-pace marker.
        return None


def _expected_billing_remaining(
    percent_left: float | None,
    start_iso: str | None,
    end_iso: str | None,
    now: datetime,
) -> float | None:
    """Return a billing window's expected remaining percentage, if computable."""
    if (
        not isinstance(start_iso, str)
        or not isinstance(end_iso, str)
        or not start_iso
        or not end_iso
    ):
        return None
    try:
        start = datetime.fromisoformat(start_iso)
        end = datetime.fromisoformat(end_iso)
    except ValueError:
        return None
    try:
        start, end = reconcile(start, end)
        total_seconds = max(1.0, (end - start).total_seconds())
        return _expected_remaining(percent_left, pace_delta(percent_left, end, total_seconds, now))
    except (OverflowError, TypeError, ValueError):
        # Mixed or malformed datetime metadata must not take down dashboard
        # rendering; the row simply omits its expected-pace marker.
        return None


def _percent_str(percent: float) -> str:
    if percent < 10:
        return f"{percent:.1f}"
    return f"{round(percent)}"


def _format_percent_value(percent: float | None) -> str:
    if percent is None:
        return "n/a"
    return f"{_percent_str(percent)}%"


def _is_empty_window(percent: float | None) -> bool:
    """Return True only for an exactly depleted remaining percentage."""
    return percent_is_depleted(percent)


def _provider_is_empty(snapshot: ProviderSnapshot, now: datetime) -> bool:
    """Return True when the provider should switch to the depleted/empty view."""
    if not snapshot.ok or not snapshot.data:
        return False
    name = snapshot.name.removesuffix(" [HTTP]")
    if name == "Antigravity":
        # Gemini and C+G quotas are independently usable. Keep the normal
        # panel whenever either group has capacity, even when the other is
        # depleted. This is intentionally based on the raw numeric values so
        # the UI does not depend on router/snapshot window publication.
        percent_keys = tuple(
            window.percent_key
            for window in (*PROVIDER_RENDER_SPECS[name].windows, *ANTIGRAVITY_CG_WINDOWS)
        )
        values = [snapshot.data.get(key) for key in percent_keys]
        available = [value for value in values if percent_is_valid(value)]
        if available and all(percent_is_depleted(value) for value in available):
            return True
        # Each pool (native Gemini, third-party C+G) is itself blocked the
        # moment either of its two windows hits 0% -- same "any window at
        # 0% blocks usage" rule Codex/Claude already use. The provider as a
        # whole is only exhausted once BOTH pools are blocked, including via
        # different windows (e.g. native 5h=0% and third-party 1w=0%, even
        # though native 1w and third-party 5h both still have capacity).
        native_blocked = percent_is_depleted(
            snapshot.data.get("five_hour_percent_left")
        ) or percent_is_depleted(snapshot.data.get("weekly_percent_left"))
        third_party_blocked = percent_is_depleted(
            snapshot.data.get("third_party_five_hour_percent_left")
        ) or percent_is_depleted(snapshot.data.get("third_party_weekly_percent_left"))
        return native_blocked and third_party_blocked

    windows = normalized_warning_windows(snapshot, now)
    depleted = {
        str(window["id"]) for window in windows if percent_is_depleted(window["percent_left"])
    }
    available = {str(window["id"]) for window in windows}
    if name == "Cursor":
        return bool(available) and depleted == available
    return bool(depleted)


def _copilot_monthly_reset_target(now: datetime) -> datetime:
    utc_now = now.astimezone(timezone.utc) if now.tzinfo else now.replace(tzinfo=timezone.utc)
    year = utc_now.year + (1 if utc_now.month == 12 else 0)
    month = 1 if utc_now.month == 12 else utc_now.month + 1
    return datetime(year, month, 1, 0, 0, tzinfo=timezone.utc)


def _billing_cycle_pace_value(
    percent_left: float | None,
    start_iso: str | None,
    end_iso: str | None,
    now: datetime,
) -> float | None:
    """Return a billing cycle's numeric pace delta, or None if incomputable.

    Billing cycles carry explicit start/end dates rather than a rolling window
    length, so they need their own total-seconds derivation; the resulting
    delta feeds the same ramp as a session window's.
    """
    if percent_left is None or not start_iso or not end_iso:
        return None
    try:
        start = datetime.fromisoformat(start_iso)
        end = datetime.fromisoformat(end_iso)
    except ValueError:
        return None
    start, end = reconcile(start, end)
    total_seconds = max(1.0, (end - start).total_seconds())
    return pace_delta(percent_left, end, total_seconds, now)


def _billing_cycle_pace_label(
    percent_left: float | None,
    start_iso: str | None,
    end_iso: str | None,
    now: datetime,
) -> str:
    """Compute pace label for any billing cycle with known start and end dates."""
    delta = _billing_cycle_pace_value(percent_left, start_iso, end_iso, now)
    if delta is None:
        return "n/a"
    delta_points = delta * 100.0
    diff_points = round(abs(delta_points))
    if abs(delta_points) <= 5.0:
        return "on pace"
    if delta_points > 0:
        return f"under +{diff_points}pt"
    return f"over -{diff_points}pt"


def _provider_display_fields(snapshot: ProviderSnapshot, now: datetime) -> dict[str, str]:
    if not snapshot.data:
        return {}
    spec = PROVIDER_RENDER_SPECS.get(snapshot.name)
    if spec is None:
        return {}
    display: dict[str, str] = {}
    for window in spec.windows:
        raw_reset = snapshot.data.get(window.reset_key)
        display[f"{window.window_id}_reset_display"] = _format_reset_display(
            None if raw_reset is None else str(raw_reset),
            now,
        )
    return display


# ---------------------------------------------------------------------------
# Rich style helpers
# ---------------------------------------------------------------------------


#: Pace at or above this is healthy: spending exactly as fast as the clock
#: runs down is what the window is for.
_PACE_GREEN_FLOOR = 0.0

#: Matches ``window_warns``, which alerts at ``pace_delta < -0.10``. Because
#: this bound is inclusive, "orange or worse" and "warns" are the same
#: predicate whenever pace is known, so a colored row and a notification
#: cannot disagree.
_PACE_YELLOW_FLOOR = -0.10

#: Burning down more than 25 points faster than the clock. Unlike
#: ``_PACE_YELLOW_FLOOR`` this is not derived from an existing predicate; it
#: separates "drifting" from "will run out early" and is free to be retuned.
_PACE_ORANGE_FLOOR = -0.25

_SIGNAL_STYLES: dict[str, str] = {
    "green": "bar.green",
    "yellow": "bar.yellow",
    "orange": "bar.orange",
    "red": "bar.red",
    "unknown": "text.muted",
}


def _percent_fallback_level(percent: float) -> str:
    """Classify by absolute percentage alone, for windows with no usable pace.

    This is the pre-pace ramp, kept only as :func:`_signal_level`'s step 3 —
    it is not a public alternative to it. Reaching it means the window has no
    reset timestamp, so there is no evidence about how fast the remaining
    percentage is being spent.

    Mirrors the ``guard let paceDelta`` branch of ``signalLevel`` in
    ``app/GradusKit/Sources/GradusKit/SignalLevel.swift``.
    """
    if percent >= 70:
        return "green"
    if percent >= 40:
        return "yellow"
    if percent >= 20:
        return "orange"
    return "red"


def _signal_level(percent: float | None, pace: float | None) -> str:
    """Classify a window by pace rather than by absolute percentage left.

    Mirrors ``signalLevel`` in ``app/GradusKit/Sources/GradusKit/SignalLevel.swift``.
    The two are held together by the shared truth table at
    ``app/GradusKit/Tests/GradusKitTests/Fixtures/signal-levels.json``, which
    both test suites read.

    The rules, in order:

    1. An invalid percentage (missing, non-finite, or outside 0-100 per
       INV-3) is ``unknown``. This is stricter than the pre-pace ramp, which
       returned green for a value like 150.
    2. A depleted percentage is ``red`` regardless of pace — there is nothing
       left to pace.
    3. A missing or non-finite pace falls back to the percent-only ramp so a
       window without a reset timestamp still gets a color. This is the one
       case where "orange or worse" is not equivalent to ``window_warns``:
       19% with no pace renders red but raises no alert, because there is no
       evidence to alert on.
    4. Otherwise the pace delta selects the step.

    Args:
        percent: Remaining percentage, normalized 0-100.
        pace: ``fraction_left - fraction_of_window_remaining``. Positive is
            ahead of schedule. Not clamped (INV-4).

    Returns:
        One of ``green``, ``yellow``, ``orange``, ``red``, ``unknown``.
    """
    if not percent_is_valid(percent):
        return "unknown"
    if percent_is_depleted(percent):
        return "red"

    pace_is_usable = (
        isinstance(pace, (int, float)) and not isinstance(pace, bool) and math.isfinite(pace)
    )
    if not pace_is_usable:
        return _percent_fallback_level(percent)

    if pace >= _PACE_GREEN_FLOOR:
        return "green"
    if pace >= _PACE_YELLOW_FLOOR:
        return "yellow"
    if pace >= _PACE_ORANGE_FLOOR:
        return "orange"
    return "red"


def _style_for_signal(percent: float | None, pace: float | None) -> str:
    """Return the Rich theme style for a window's pace-aware signal level."""
    return _SIGNAL_STYLES[_signal_level(percent, pace)]


ACCENT_STYLES: dict[str, str] = {
    "Codex": "accent.codex",
    "Claude": "accent.claude",
    "Gemini": "accent.gemini",
    "Copilot": "accent.copilot",
    "Cursor": "accent.cursor",
    "Vibe": "accent.vibe",
    "OpenCode Go": "accent.opencode",
}

# Display-only title overrides, keyed by canonical provider name. Empty now that
# the Antigravity card is a first-class provider (no longer a relabeled Gemini
# probe); kept as the extension point for any future rename that must not disturb
# a provider's config/dispatch/warning key.
DISPLAY_TITLES: dict[str, str] = {}


# ---------------------------------------------------------------------------
# Rich renderables
# ---------------------------------------------------------------------------


# The glyph the bar's fill is drawn with. The marker uses it too, which is the
# whole point of the marker's design -- see `_marker_index`.
_FILL_GLYPH = "▓"


class PercentageBar:
    """Custom Rich renderable: a static percentage bar using block characters."""

    def __init__(
        self, percent: float | None, style: str, expected_remaining: float | None = None
    ) -> None:
        self.percent = percent
        self.style = style
        self.expected_remaining = expected_remaining

    def __rich_console__(self, console: Console, options: ConsoleOptions) -> RenderResult:
        width = options.max_width
        if self.percent is None:
            yield Text("·" * width, style="shadow")
            return
        # `filled` is a *count* of cells, so rounding it is right -- it picks the
        # nearest drawable length. The marker below is an *index*, which is why
        # it does not get the same treatment.
        filled = max(0, min(width, round(width * self.percent / 100)))
        marker_index = self._marker_index(width)
        bar = Text()
        for index in range(width):
            if index == marker_index:
                bar.append(_FILL_GLYPH, style="bar.marker")
            elif index < filled:
                bar.append(_FILL_GLYPH if index < filled - 1 else "█", style=self.style)
            else:
                bar.append("░", style="bar.empty")
        yield bar

    def _marker_index(self, width: int) -> int | None:
        """Which cell the expected-pace marker claims, if there is one.

        The marker is one whole cell of `_FILL_GLYPH` in the marker colour --
        the bar's own fill glyph, recoloured. That is a deliberate choice over
        a thin stroke, and the reasoning is worth keeping because three
        attempts went the other way first.

        A thin stroke can be positioned inside a cell, which triples the
        marker's resolution, but it costs two things that turned out to matter
        more. Sub-cell placement needs a different glyph per position (`▏ ┃ ▕`)
        and those ink 2, 4 and 1 pixels respectively, so the marker visibly
        changes thickness as it slides -- David: "some of these blue bars are
        thinner than others too." And a thin stroke inks at most 36% of its
        cell against the fill's 67%, so the rest of the cell shows the terminal
        background: "black bar is STILL there". Painting that remainder makes
        the cell the only *solid* one in a stippled row, which reads worse
        again. All three complaints are the same geometry, and there is no
        arrangement of glyphs that escapes it -- fine movement, constant width
        and no dark cell cannot coexist in a character grid.

        Drawing the marker with the fill glyph settles all of it: identical ink
        coverage to its neighbours so nothing shows through, identical width
        every time, and the same texture as the bar it sits in. The cost, which
        David chose knowingly, is that the marker steps one whole cell at a
        time -- about 7 points on the 14-cell bars here.
        """
        if self.expected_remaining is None or width <= 0:
            return None
        position = min(1.0, max(0.0, self.expected_remaining / 100)) * width
        # `int`, not `round`. The value names a *boundary* between two cells and
        # the marker then claims the cell to the right of it, so rounding up put
        # the mark a full cell past the boundary it was meant to name.
        return min(width - 1, int(position))


# Below this console width the 2-panel grid can't fit a full 12-char pace cell
# without truncation. ~46 chars per panel + grid padding ≈ 93.
_NARROW_CONSOLE_WIDTH = 93


def _compact_pace(pace: str) -> str:
    """Arrow notation for the pace cell when the column gets truncated."""
    if pace == "n/a":
        return "—"
    if pace == "on pace":
        return "="
    if pace.startswith("under +"):
        return "↑" + pace[len("under +") :]
    if pace.startswith("over -"):
        return "↓" + pace[len("over -") :]
    return pace


class PaceLabel:
    """Pace cell that collapses to arrow notation when the terminal is narrow.

    Up arrow = above the expected trend (more remaining than pace predicts).
    Down arrow = below the expected trend (less remaining than pace predicts).
    """

    def __init__(self, pace: str) -> None:
        self.pace = pace
        self.style = _pace_style(pace)

    def __rich_console__(self, console: Console, options: ConsoleOptions) -> RenderResult:
        text = self.pace
        if console.width < _NARROW_CONSOLE_WIDTH:
            text = _compact_pace(self.pace)
        yield Text(text, style=self.style)


class ResponsiveProviderBody:
    """Provider rows with a shared, percentage-first allocation per card.

    The percentage cell is always four characters wide, which accommodates the
    widest rendered integer value (``100%``). Bars take every remaining column
    after the normal text cells have their preferred widths, then disappear
    entirely before Rich is asked to crop the reset or pace text.
    """

    _LABEL_WIDTH = 4
    _PERCENT_WIDTH = 4
    _RESET_WIDTH = 12
    _PACE_WIDTH = 12
    _GUTTER_WIDTH = 1

    def __init__(self) -> None:
        self.rows: list[
            tuple[RenderableType, RenderableType, RenderableType, RenderableType, RenderableType]
        ] = []

    def add_row(
        self,
        label: RenderableType,
        percent: RenderableType,
        bar: RenderableType,
        reset: RenderableType,
        pace: RenderableType,
    ) -> None:
        """Store a row until Rich supplies the card's available width."""
        self.rows.append((label, percent, bar, reset, pace))

    def __rich_console__(self, console: Console, options: ConsoleOptions) -> RenderResult:
        # Four gutters are needed when a bar is visible. Once it has no room,
        # omit its column and recover one gutter for the text cells.
        preferred_text_width = (
            self._LABEL_WIDTH + self._PERCENT_WIDTH + self._RESET_WIDTH + self._PACE_WIDTH
        )
        bar_width = max(0, options.max_width - preferred_text_width - 4 * self._GUTTER_WIDTH)
        include_bar = bar_width > 0

        table = Table.grid(padding=(0, self._GUTTER_WIDTH), expand=False)
        if include_bar:
            table.add_column(width=self._LABEL_WIDTH, no_wrap=True, overflow="ellipsis")
            table.add_column(width=self._PERCENT_WIDTH, no_wrap=True, overflow="ellipsis")
            table.add_column(width=bar_width, no_wrap=True, overflow="crop")
            table.add_column(width=self._RESET_WIDTH, no_wrap=True, overflow="ellipsis")
            table.add_column(width=self._PACE_WIDTH, no_wrap=True, overflow="ellipsis")
            for row in self.rows:
                table.add_row(*row)
        else:
            # A zero-width Rich column cannot render reliably. Removing it is
            # equivalent visually and lets the remaining cells use its gutter.
            text_width = max(0, options.max_width - 3 * self._GUTTER_WIDTH)
            label_width = min(self._LABEL_WIDTH, max(2, text_width - self._PERCENT_WIDTH))
            remaining = max(0, text_width - label_width - self._PERCENT_WIDTH)
            reset_width = min(self._RESET_WIDTH, (remaining + 1) // 2)
            pace_width = min(self._PACE_WIDTH, remaining - reset_width)
            table.add_column(width=label_width, no_wrap=True, overflow="ellipsis")
            table.add_column(width=self._PERCENT_WIDTH, no_wrap=True, overflow="ellipsis")
            table.add_column(width=reset_width, no_wrap=True, overflow="ellipsis")
            table.add_column(width=pace_width, no_wrap=True, overflow="ellipsis")
            for label, percent, _bar, reset, pace in self.rows:
                table.add_row(label, percent, reset, pace)

        yield table


class DepletedProviderBody:
    """Depleted rows without an unused usage-bar column.

    A depleted card communicates one thing per row: ``0% until <reset>``.
    Unlike normal usage rows, it gives the reset text every column left after
    the label and percentage, so a discarded bar never crowds that message at
    narrow card widths.
    """

    _LABEL_WIDTH = 4
    _PERCENT_WIDTH = 4
    _GUTTER_WIDTH = 1

    def __init__(self) -> None:
        self.rows: list[tuple[RenderableType, RenderableType, RenderableType]] = []

    def add_row(
        self,
        label: RenderableType,
        percent: RenderableType,
        reset: RenderableType,
        *_unused: RenderableType,
    ) -> None:
        """Store a depleted row; compatibility cells are intentionally ignored."""
        self.rows.append((label, percent, reset))

    def __rich_console__(self, console: Console, options: ConsoleOptions) -> RenderResult:
        reset_width = max(
            0,
            options.max_width - self._LABEL_WIDTH - self._PERCENT_WIDTH - 2 * self._GUTTER_WIDTH,
        )
        table = Table.grid(padding=(0, self._GUTTER_WIDTH), expand=False)
        table.add_column(width=self._LABEL_WIDTH, no_wrap=True, overflow="ellipsis")
        table.add_column(width=self._PERCENT_WIDTH, no_wrap=True, overflow="ellipsis")
        table.add_column(width=reset_width, no_wrap=True, overflow="ellipsis")
        for row in self.rows:
            table.add_row(*row)
        yield table


class GenericProviderBody:
    """Compact key/value rows for providers without usage windows."""

    _LABEL_WIDTH = 12
    _GUTTER_WIDTH = 1

    def __init__(self) -> None:
        self.rows: list[tuple[RenderableType, RenderableType]] = []

    def add_row(
        self,
        label: RenderableType,
        value: RenderableType,
        *_unused: RenderableType,
    ) -> None:
        """Store a key/value row; generic cards intentionally have no bar cells."""
        self.rows.append((label, value))

    def __rich_console__(self, console: Console, options: ConsoleOptions) -> RenderResult:
        label_width = min(self._LABEL_WIDTH, max(0, options.max_width - self._GUTTER_WIDTH - 1))
        value_width = max(0, options.max_width - label_width - self._GUTTER_WIDTH)
        table = Table.grid(padding=(0, self._GUTTER_WIDTH), expand=False)
        table.add_column(width=label_width, no_wrap=True, overflow="ellipsis")
        table.add_column(width=value_width, no_wrap=True, overflow="ellipsis")
        for row in self.rows:
            table.add_row(*row)
        yield table


# ---------------------------------------------------------------------------
# Panel builders
# ---------------------------------------------------------------------------


def build_provider_panel(
    snapshot: ProviderSnapshot,
    now: datetime,
    *,
    auth_fix_key: str | None = None,
) -> Panel:
    """Build a Rich Panel for a single provider snapshot."""
    base_name = snapshot.name.removesuffix(" [HTTP]")
    accent = ACCENT_STYLES.get(base_name, "text.cyan")
    warning_ids = warning_window_ids(snapshot, now) if snapshot.ok else ()
    display_name = DISPLAY_TITLES.get(base_name, snapshot.name)
    title_text = f"[bold {accent}]{display_name}[/]"
    if warning_ids:
        title_text += " [bold text.red][!][/]"

    # Surface cached/offline status in the panel title
    if snapshot.ok and snapshot.cached_since:
        age_sec = max(0, int((now - snapshot.cached_since).total_seconds()))
        if age_sec < 60:
            age_str = "<1m"
        elif age_sec < 3600:
            age_str = f"{age_sec // 60}m"
        else:
            age_str = f"{age_sec // 3600}h"
        title_text += f" [text.yellow](offline {age_str})[/]"

    if not snapshot.ok:
        # Stale data — distinct from hard errors (yellow, not red)
        if snapshot.error and snapshot.error.startswith("stale"):
            body = Text.from_markup(f"[text.yellow]{snapshot.error}[/]")
            return Panel(
                body,
                title=title_text,
                border_style="text.yellow",
                padding=(0, 1),
            )
        if auth_fix_key is not None:
            body = Text.from_markup(
                f"[text.red]auth error[/] [text.muted]— press [/]"
                f"[text.cyan]\\[{auth_fix_key}][/]"
                f"[text.muted] to fix[/]"
            )
        else:
            error_msg = _truncate(snapshot.error or "unknown error", 60)
            body = Text.from_markup(f"[text.red]error:[/] [text.muted]{error_msg}[/]")
        return Panel(
            body,
            title=title_text,
            border_style="text.red",
            padding=(0, 1),
        )

    assert snapshot.data is not None
    cached_badge = (
        _cached_badge_text(snapshot, now) if "cached" in snapshot.source.lower() else None
    )

    spec = PROVIDER_RENDER_SPECS.get(base_name)

    if _provider_is_empty(snapshot, now):
        body = DepletedProviderBody()
        _add_empty_view(body, snapshot, now)
    elif base_name == "Copilot":
        body = ResponsiveProviderBody()
        _add_copilot_rows(body, snapshot.data, now)
    elif spec is None and base_name not in {"Cursor", "Vibe"}:
        # Generic status cards have no usage bar. Their two-column layout is
        # intentionally separate from the normal usage-row allocator.
        body = GenericProviderBody()
        _add_generic_rows(body, snapshot.data, snapshot.source)
    else:
        body = ResponsiveProviderBody()
        if base_name == "Cursor":
            _add_cursor_rows(body, snapshot.data, now)
        elif base_name == "Vibe":
            _add_vibe_rows(body, snapshot.data, now)
        elif base_name == "Antigravity":
            _add_antigravity_rows(body, snapshot.data, now, spec.windows)
        elif spec:
            _add_usage_rows(body, snapshot.data, now, spec.windows)

    panel_kwargs: dict[str, object] = {
        "title": title_text,
        "border_style": "text.yellow" if snapshot.cached_since else accent,
        "subtitle_align": "left",
        "padding": (0, 1),
    }
    # Cached status is shown in the title; subtitle badge is redundant
    if cached_badge and not snapshot.cached_since:
        panel_kwargs["subtitle"] = f"[{accent}]{cached_badge}[/]"

    return Panel(body, **panel_kwargs)


def _pace_style(pace: str) -> str:
    if "under" in pace:
        return "text.green"
    if "over" in pace:
        return "text.red"
    if "on pace" in pace:
        return "text.yellow"
    return "text.muted"


def _add_usage_rows(
    table: Table,
    data: dict[str, object],
    now: datetime,
    windows: tuple[WindowRenderSpec, ...],
) -> None:
    """Add one row per window: label | % | bar | reset | pace."""
    for window in windows:
        percent = data.get(window.percent_key)
        if window.omit_when_empty and percent is None:
            continue
        reset = data.get(window.reset_key)
        reset_str = None if reset is None else str(reset)
        pace_value = _pace_value(percent, reset_str, now, window.window_hours)
        style = _style_for_signal(percent, pace_value)
        reset_display = _format_reset_display(reset_str, now)
        pace = _pace_label(percent, reset_str, now, window.window_hours)
        table.add_row(
            Text(window.session_label, style="text.muted"),
            Text(_format_percent_value(percent), style=style),
            PercentageBar(
                percent,
                style,
                _expected_session_remaining(percent, reset_str, now, window.window_hours),
            ),
            Text(reset_display, style="text.cyan"),
            PaceLabel(pace),
        )


def _antigravity_cg_data(data: dict[str, object]) -> dict[str, object]:
    """Return the C+G windows that have a valid, reportable percentage.

    Malformed or missing values are excluded so a downstream row is never
    rendered from invalid data. A valid value renders regardless of level,
    including a fully unused 100% pool — every tracked window stays visible.
    """
    visible: dict[str, object] = {}
    for window in ANTIGRAVITY_CG_WINDOWS:
        percent = data.get(window.percent_key)
        if percent_is_valid(percent):
            visible[window.percent_key] = percent
            reset = data.get(window.reset_key)
            if reset is not None:
                visible[window.reset_key] = reset
    return visible


def _add_antigravity_rows(
    table: Table,
    data: dict[str, object],
    now: datetime,
    gemini_windows: tuple[WindowRenderSpec, ...],
) -> None:
    """Add baseline Gemini rows followed by active C+G quota rows."""
    _add_usage_rows(table, data, now, gemini_windows)
    _add_usage_rows(table, _antigravity_cg_data(data), now, ANTIGRAVITY_CG_WINDOWS)


def _add_empty_view(table: Table, snapshot: ProviderSnapshot, now: datetime) -> None:
    """All rows show depleted format — provider has no usable capacity.

    Depleted windows show their own reset. Non-depleted windows (still blocked
    because another window in the same quota pool is at 0%) show that pool's
    blocking reset. Antigravity has two independent pools (native Gemini,
    third-party C+G) that can each be blocked via a different window, so the
    blocking reset is computed per pool rather than once globally — otherwise
    a capacity-remaining row could be stamped with the other pool's reset, a
    time that doesn't actually free up that row's own pool.
    """
    data = snapshot.data
    assert data is not None
    name = snapshot.name.removesuffix(" [HTTP]")
    _e = Text("")

    def _row(label: str, reset_str: str | None, is_na: bool = False) -> None:
        if is_na:
            table.add_row(
                Text(label, style="text.muted"),
                Text("n/a", style="text.muted"),
                _e,
                _e,
                _e,
            )
        else:
            reset_display = _format_reset_display(reset_str, now)
            table.add_row(
                Text(label, style="text.muted"),
                Text("0%", style="bar.red"),
                Text(f"until {reset_display}", style="text.red"),
                _e,
                _e,
            )

    def _pool_blocking_reset(pool_windows: tuple[WindowRenderSpec, ...]) -> str | None:
        """Reset of the first depleted window in this pool — what blocks it."""
        for window in pool_windows:
            if _is_empty_window(data.get(window.percent_key)):
                raw = data.get(window.reset_key)
                return None if raw is None else str(raw)
        return None

    spec = PROVIDER_RENDER_SPECS.get(name)
    if spec:
        # C+G rows use the same depleted presentation when every usable quota
        # is exhausted, while malformed/absent C+G values remain omitted
        # rather than producing phantom rows.
        pools = (spec.windows, ANTIGRAVITY_CG_WINDOWS) if name == "Antigravity" else (spec.windows,)
        windows = tuple(window for pool in pools for window in pool)
        blocking_reset_by_key: dict[str, str | None] = {}
        for pool in pools:
            pool_blocking = _pool_blocking_reset(pool)
            for window in pool:
                blocking_reset_by_key[window.percent_key] = pool_blocking

        for window in windows:
            percent = data.get(window.percent_key)
            if window.omit_when_empty and percent is None:
                continue
            if name == "Antigravity" and not percent_is_valid(percent):
                continue
            if percent is None:
                _row(window.session_label, None, is_na=True)
            elif _is_empty_window(percent):
                raw = data.get(window.reset_key)
                _row(window.session_label, None if raw is None else str(raw))
            else:
                # Window has remaining capacity but its pool is blocked;
                # show that pool's blocking reset so the user knows when
                # they can work again.
                _row(window.session_label, blocking_reset_by_key[window.percent_key])
    elif name == "Cursor":
        reset_value = data.get("billing_cycle_end")
        reset_str = str(reset_value) if isinstance(reset_value, str) else None
        for window in normalized_warning_windows(snapshot, now):
            _row(str(window["id"]), reset_str)
    elif name == "Vibe":
        reset_value = data.get("reset_at")
        _row("mo", str(reset_value) if isinstance(reset_value, str) else None)


def _add_copilot_rows(table: Table, data: dict[str, object], now: datetime) -> None:
    """Add Copilot-specific monthly metric rows."""
    remaining = data.get("premium_percent_left")
    percent_left = float(remaining) if isinstance(remaining, (int, float)) else None
    reset_value = (
        data.get("premium_reset")
        or f"Resets {_copilot_monthly_reset_target(now).astimezone().strftime('%b %d at %H:%M')}"
    )
    utc_now = now.astimezone(timezone.utc) if now.tzinfo else now.replace(tzinfo=timezone.utc)
    start = utc_now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    end = _copilot_monthly_reset_target(utc_now)
    pace_text = _billing_cycle_pace_label(percent_left, start.isoformat(), end.isoformat(), utc_now)

    style = _style_for_signal(
        percent_left,
        _billing_cycle_pace_value(percent_left, start.isoformat(), end.isoformat(), utc_now),
    )
    value_text = _format_percent_value(percent_left)
    reset_display = _format_reset_display(None if reset_value is None else str(reset_value), now)
    table.add_row(
        Text("mo", style="text.muted"),
        Text(value_text, style=style),
        PercentageBar(
            percent_left,
            style,
            _expected_billing_remaining(percent_left, start.isoformat(), end.isoformat(), utc_now),
        ),
        Text(reset_display, style="text.cyan"),
        PaceLabel(pace_text),
    )


def _add_cursor_rows(table: Table, data: dict[str, object], now: datetime) -> None:
    """Add Cursor Auto + Composer and API remaining-capacity rows."""
    reset_value = data.get("billing_cycle_end")
    reset_display = _format_reset_display(None if reset_value is None else str(reset_value), now)
    start_iso = data.get("billing_cycle_start")
    end_iso = data.get("billing_cycle_end_iso")
    start = str(start_iso) if isinstance(start_iso, str) else None
    end = str(end_iso) if isinstance(end_iso, str) else None

    def _remaining(key: str, *, used: bool = False) -> float | None:
        value = data.get(key)
        if not percent_is_valid(value):
            return None
        percent = float(value)
        return 100.0 - percent if used else percent

    # Both rows are Cursor's two real usage pools, each reported as percent
    # *used* and converted here to percent remaining: ``ac`` from
    # ``auto_percent_used`` (first-party Auto + Composer) and ``ap`` from
    # ``api_percent_used`` (the API/third-party pool). The dollar-denominated
    # spend meter (``credit_percent_left``, from Cursor's remaining/limit
    # cents) is intentionally NOT shown here — it's a $ budget, not a usage
    # pool, and displaying it under "ap" previously conflated the two.
    # ``credit_percent_left`` is still computed by the provider as internal
    # metadata; it is simply no longer surfaced in this row loop. Row IDs
    # stay ``ac``/``ap`` rather than ``fp``/``api`` — see the comment on
    # WARNING_WINDOW_SPECS["Cursor"] in snapshot.py for why (INV-5 schema
    # stability).
    for label, key, is_used in (
        ("ac", "auto_percent_used", True),
        ("ap", "api_percent_used", True),
    ):
        percent_left = _remaining(key, used=is_used)
        style = _style_for_signal(
            percent_left, _billing_cycle_pace_value(percent_left, start, end, now)
        )
        pace_text = _billing_cycle_pace_label(percent_left, start, end, now)
        table.add_row(
            Text(label, style="text.muted"),
            Text(_format_percent_value(percent_left), style=style),
            PercentageBar(
                percent_left, style, _expected_billing_remaining(percent_left, start, end, now)
            ),
            Text(reset_display, style="text.cyan"),
            PaceLabel(pace_text),
        )


def _add_vibe_rows(table: Table, data: dict[str, object], now: datetime) -> None:
    """Add Mistral Vibe monthly usage rows."""
    usage_percent = data.get("usage_percent")
    if isinstance(usage_percent, (int, float)):
        percent_left = max(0.0, 100.0 - float(usage_percent))
    else:
        percent_left = None

    reset_value = data.get("reset_at")

    value_text = _format_percent_value(percent_left)
    reset_display = _format_reset_display(None if reset_value is None else str(reset_value), now)
    start_iso = data.get("start_date")
    end_iso = data.get("end_date")
    cycle_start = str(start_iso) if isinstance(start_iso, str) else None
    cycle_end = str(end_iso) if isinstance(end_iso, str) else None
    style = _style_for_signal(
        percent_left, _billing_cycle_pace_value(percent_left, cycle_start, cycle_end, now)
    )
    pace_text = _billing_cycle_pace_label(percent_left, cycle_start, cycle_end, now)
    table.add_row(
        Text("mo", style="text.muted"),
        Text(value_text, style=style),
        PercentageBar(
            percent_left,
            style,
            _expected_billing_remaining(
                percent_left,
                str(start_iso) if isinstance(start_iso, str) else None,
                str(end_iso) if isinstance(end_iso, str) else None,
                now,
            ),
        ),
        Text(reset_display, style="text.cyan"),
        PaceLabel(pace_text),
    )


def _add_generic_rows(table: Table, data: dict[str, object], source: str) -> None:
    """Add generic key-value rows for unknown providers."""
    _e = Text("")
    table.add_row(Text("status", style="text.muted"), Text("ok", style="text.ink"), _e, _e, _e)
    table.add_row(Text("source", style="text.muted"), Text(source, style="text.ink"), _e, _e, _e)
    count = 0
    for key, value in sorted(data.items()):
        if key == "raw_text":
            continue
        label = key.replace("_", " ")[:12]
        table.add_row(
            Text(label, style="text.muted"),
            Text(_plain(value), style="text.ink"),
            _e,
            _e,
            _e,
        )
        count += 1
        if count >= 4:
            break


# ---------------------------------------------------------------------------
# Dashboard composition
# ---------------------------------------------------------------------------


class PackedProviderCards:
    """Pack fixed-width provider cards into the shorter of two vertical stacks."""

    # Keep two columns until they can no longer show a full text-only row, so a
    # narrowing terminal shrinks each card's usage bar to nothing (see
    # ResponsiveProviderBody) *before* the layout gives up and stacks the cards
    # into one wide column. Dropping to one column early would re-widen every
    # card and balloon the bars back — stretching the dashboard taller instead
    # of more compact. The floor is the width where two bar-less cards still fit:
    # a card needs LABEL(4)+PERCENT(4)+RESET(12)+PACE(12) + 3 gutters + 2 border
    # + 2 padding = 39 cols, so two of them plus the 1-col grid gutter = 79.
    _TWO_COLUMN_MIN_WIDTH = 79
    _GUTTER_WIDTH = 1

    def __init__(self, panels: list[Panel]) -> None:
        self.panels = panels

    def __rich_console__(self, console: Console, options: ConsoleOptions) -> RenderResult:
        """Render cards at a fixed width so stack heights are comparable."""
        if options.max_width < self._TWO_COLUMN_MIN_WIDTH:
            # Yield each card directly: unlike a two-column line, there is no
            # vacant cell to render in the one-column fallback.
            yield from self.panels
            return

        card_width = (options.max_width - self._GUTTER_WIDTH) // 2
        trailing_width = options.max_width - (2 * card_width + self._GUTTER_WIDTH)
        card_options = options.update_width(card_width)
        left_stack: list[list[Segment]] = []
        right_stack: list[list[Segment]] = []
        left_height = 0
        right_height = 0

        for panel in self.panels:
            # Measuring and rendering use the same fixed options. This keeps
            # wrapping-dependent panel heights faithful to the final layout.
            lines = console.render_lines(panel, card_options, pad=True)
            if left_height <= right_height:
                left_stack.extend(lines)
                left_height += len(lines)
            else:
                right_stack.extend(lines)
                right_height += len(lines)

        blank_line: list[Segment] = []
        for line_number in range(max(left_height, right_height)):
            left_line = left_stack[line_number] if line_number < left_height else blank_line
            right_line = right_stack[line_number] if line_number < right_height else blank_line
            yield from Segment.adjust_line_length(left_line, card_width)
            yield Segment(" " * self._GUTTER_WIDTH)
            yield from Segment.adjust_line_length(right_line, card_width)
            if trailing_width:
                yield Segment(" " * trailing_width)
            yield Segment.line()


def _pool_is_present(pool_windows: tuple[WindowRenderSpec, ...], data: dict[str, object]) -> bool:
    """Return whether this pool has at least one tracked (valid) window.

    Antigravity's third-party (C+G) pool is entirely absent -- both percents
    ``None`` -- for accounts the API doesn't track it for, even while the
    probe otherwise succeeds. `_provider_is_empty` reacts to that: with one
    pool fully absent, the "both pools independently blocked" AND can never
    fire (an absent pool's blocked flag is permanently False), so exhaustion
    falls back to its other rule -- every *available* window depleted -- which
    has different unblock semantics than the normal two-pool case.
    """
    return any(percent_is_valid(data.get(window.percent_key)) for window in pool_windows)


def _pool_free_reset(
    pool_windows: tuple[WindowRenderSpec, ...], data: dict[str, object], now: datetime
) -> str | None:
    """Reset string for when this pool stops blocking, or None if unknown.

    A pool stays blocked until every one of its currently-depleted windows has
    reset, so this is the latest (max) reset among them, not just the first
    depleted window found. If any depleted window's reset is missing, the
    pool's true clear time can't be determined — reporting another window's
    reset could understate how long the pool stays blocked, so this reports
    unknown (None) rather than guessing.
    """
    depleted_raw: list[str] = []
    for window in pool_windows:
        if not _is_empty_window(data.get(window.percent_key)):
            continue
        raw = data.get(window.reset_key)
        if raw is None:
            return None
        depleted_raw.append(str(raw))
    if not depleted_raw:
        return None
    far_future = datetime.max.replace(tzinfo=now.tzinfo)
    return max(depleted_raw, key=lambda raw: _parse_reset_target(raw, now) or far_future)


def _extract_depleted_reset_str(snapshot: ProviderSnapshot, now: datetime) -> str | None:
    """Extract reset timestamp for any depleted provider.

    A provider with independent quota pools (Antigravity's native + third-party)
    becomes usable again as soon as any one currently-blocking pool clears, so
    this picks the soonest (min) reset among the blocking pools rather than the
    first depleted window found.
    """
    data = snapshot.data or {}
    name = snapshot.name.removesuffix(" [HTTP]")
    spec = PROVIDER_RENDER_SPECS.get(name)
    if spec:
        far_future = datetime.max.replace(tzinfo=now.tzinfo)
        if name == "Antigravity":
            native, third_party = spec.windows, ANTIGRAVITY_CG_WINDOWS
            if _pool_is_present(native, data) and _pool_is_present(third_party, data):
                pool_resets = [
                    reset
                    for pool in (native, third_party)
                    if (reset := _pool_free_reset(pool, data, now)) is not None
                ]
                if pool_resets:
                    return min(
                        pool_resets, key=lambda raw: _parse_reset_target(raw, now) or far_future
                    )
            else:
                # One whole pool is absent (see `_pool_is_present`), so
                # `_provider_is_empty` isn't held exhausted by the two-pool AND --
                # it falls back to "every available window is depleted", which
                # un-exhausts the instant any single depleted window recovers.
                # That's a flat soonest (min) across all currently-depleted
                # windows, not a per-pool latest-then-soonest.
                depleted_raw = [
                    str(data[window.reset_key])
                    for window in (*native, *third_party)
                    if _is_empty_window(data.get(window.percent_key))
                    and data.get(window.reset_key) is not None
                ]
                if depleted_raw:
                    return min(
                        depleted_raw, key=lambda raw: _parse_reset_target(raw, now) or far_future
                    )
        else:
            reset = _pool_free_reset(spec.windows, data, now)
            if reset is not None:
                return reset
    for key in (
        "premium_reset",
        "reset_at",
        "billing_cycle_end",
        "weekly_reset_at",
        "session_reset_at",
        "five_hour_reset_at",
    ):
        val = data.get(key)
        if val is not None:
            return str(val)
    return None


def build_micro_depleted_panel(
    snapshot: ProviderSnapshot,
    now: datetime,
    width: int = 21,
) -> Panel:
    """Build a quarter-width micro Panel (centered text) for any depleted provider."""
    name = snapshot.name.removesuffix(" [HTTP]")
    reset_str = _extract_depleted_reset_str(snapshot, now)
    reset_disp = _format_reset_display(reset_str, now)
    body = Text(f"0% until {reset_disp}", style="text.red", justify="center")
    title = Text(f"{name} [!]", style="text.red")
    return Panel(
        body,
        title=title,
        border_style="text.red",
        width=width,
        subtitle_align="left",
        padding=(0, 0),
    )


class DynamicMicroDepletedPair:
    """Two depleted micro panels side-by-side dynamically filling column width."""

    def __init__(self, snap1: ProviderSnapshot, snap2: ProviderSnapshot, now: datetime) -> None:
        self.snap1 = snap1
        self.snap2 = snap2
        self.now = now

    def __rich_console__(self, console: Console, options: ConsoleOptions) -> RenderResult:
        w1 = options.max_width // 2
        w2 = options.max_width - 1 - w1
        p1 = build_micro_depleted_panel(self.snap1, self.now, width=w1)
        p2 = build_micro_depleted_panel(self.snap2, self.now, width=w2)
        grid = Table.grid(padding=(0, 1))
        grid.add_row(p1, p2)
        yield from console.render(grid, options)


class DynamicMicroDepletedSingle:
    """One depleted micro panel dynamically filling column width.

    Used for a trailing unpaired exhausted provider so it matches the same
    condensed micro-card treatment as paired exhausted providers, instead of
    falling back to the taller full provider panel.
    """

    def __init__(self, snapshot: ProviderSnapshot, now: datetime) -> None:
        self.snapshot = snapshot
        self.now = now

    def __rich_console__(self, console: Console, options: ConsoleOptions) -> RenderResult:
        panel = build_micro_depleted_panel(self.snapshot, self.now, width=options.max_width)
        yield from console.render(panel, options)


def build_dashboard(
    snapshots: list[ProviderSnapshot],
    updated_at: datetime,
    next_refresh_seconds: int,
    *,
    updating: bool = False,
    update_elapsed: float = 0.0,
    fix_actions: dict[str, tuple[str, str, str]] | None = None,
) -> Group:
    """Build the full dashboard as a Rich Group."""
    now = updated_at

    # Header
    refresh_value = f"{update_elapsed:0.1f}s" if updating else f"{next_refresh_seconds}s"
    header = Text.assemble(
        ("Gradus", "bold text.cyan"),
        ("  |  ", "text.muted"),
        ("Last Updated: ", "text.muted"),
        (updated_at.strftime("%b %d %H:%M:%S"), "text.yellow"),
        ("  |  ", "text.muted"),
        ("↻ ", "text.muted"),
        (refresh_value, "text.cyan"),
    )

    # Build panels — active providers first; pairs of exhausted providers are grouped
    # into side-by-side micro cards (ratio Cursor:Copilot:Vibe = 2:1:1) at the bottom.
    active_snaps = [s for s in snapshots if not _provider_is_empty(s, now)]
    exhausted_snaps = [s for s in snapshots if _provider_is_empty(s, now)]

    _COMPACT = {"Cursor", "Vibe"}
    active_ordered = sorted(
        active_snaps,
        key=lambda s: (
            (s.name.removesuffix(" [HTTP]") if hasattr(s.name, "removesuffix") else s.name)
            in _COMPACT
        ),
    )

    fix_key_by_name: dict[str, str] = {}
    if fix_actions:
        for key, (name, _, _) in fix_actions.items():
            fix_key_by_name[name] = key

    active_panels = [
        build_provider_panel(snap, now, auth_fix_key=fix_key_by_name.get(snap.name))
        for snap in active_ordered
    ]

    all_panels: list[RenderableType] = list(active_panels)
    if len(exhausted_snaps) >= 2:
        for i in range(0, len(exhausted_snaps), 2):
            pair = exhausted_snaps[i : i + 2]
            if len(pair) == 2:
                all_panels.append(DynamicMicroDepletedPair(pair[0], pair[1], now))
            else:
                all_panels.append(DynamicMicroDepletedSingle(pair[0], now))
    elif len(exhausted_snaps) == 1:
        all_panels.append(DynamicMicroDepletedSingle(exhausted_snaps[0], now))

    # Layout: cards pack into the shorter stack at safe two-column widths.
    if len(all_panels) > 1:
        body: RenderableType = _ResponsiveDashboardBody(
            all_panels, _build_compact_lines(snapshots, now)
        )
    elif all_panels:
        body = _ResponsiveDashboardBody(all_panels, _build_compact_lines(snapshots, now))
    else:
        body = Text("No providers configured.", style="text.muted")

    footer_parts: list[str | tuple[str, str]] = [
        ("[q]", "cyan"),
        " quit  ",
        ("[r]", "cyan"),
        " refresh",
    ]
    if fix_actions:
        for key in sorted(fix_actions):
            name = fix_actions[key][0]
            footer_parts.extend(["  ", (f"[{key}]", "cyan"), f" fix {name}"])
    footer = Text.assemble(*footer_parts)

    return Group(header, Text(""), body, Text(""), footer)


# ---------------------------------------------------------------------------
# Responsive dashboard body — picks compact or panel layout at render time
# ---------------------------------------------------------------------------

# Below this width the dashboard switches from 2-column panels to compact single lines.
# Must match PackedProviderCards._TWO_COLUMN_MIN_WIDTH so the 1-column panel fallback
# is never used — below this point, compact mode takes over.
_COMPACT_THRESHOLD = PackedProviderCards._TWO_COLUMN_MIN_WIDTH


class _ResponsiveDashboardBody:
    """At render time picks compact or full panel layout based on available width."""

    def __init__(
        self,
        panels: list[RenderableType],
        compact_lines: list[RenderableType],
    ) -> None:
        self._panels = panels
        self._compact = compact_lines

    def __rich_console__(self, console: Console, options: ConsoleOptions) -> RenderResult:
        if options.max_width < _COMPACT_THRESHOLD:
            if self._compact:
                yield from console.render(Group(*self._compact), options)
            else:
                yield from console.render(
                    Text("No providers configured.", style="text.muted"), options
                )
        elif len(self._panels) > 1:
            yield from console.render(PackedProviderCards(self._panels), options)
        elif self._panels:
            yield from console.render(self._panels[0], options)
        else:
            yield from console.render(Text("No providers configured.", style="text.muted"), options)


def _build_compact_lines(snapshots: list[ProviderSnapshot], now: datetime) -> list[RenderableType]:
    """Build compact single/double-line renderables for active providers.

    Each provider gets one line per pair of windows::

        Antigravity  5h:100%↑    1w:74%↑
                      cg5:100%=   cg1w:42%=
        Claude       5h:44%↑     1w:43%=
        Codex        1w:76%↑

    The provider name column and each window pair column are aligned.
    """
    active_snaps = [s for s in snapshots if not _provider_is_empty(s, now)]
    if not active_snaps:
        return []

    # First pass: collect window parts and compute column widths.
    all_parts: list[tuple[str, str, list[tuple[str, str]]]] = []  # (name, accent, [(text, style)])
    name_width = 0
    col_widths = [0, 0]

    for snap in active_snaps:
        name = snap.name.removesuffix(" [HTTP]")
        accent = ACCENT_STYLES.get(name, "text.cyan")
        parts = _compact_window_parts(snap, now)
        all_parts.append((name, accent, parts))
        name_width = max(name_width, len(name))
        for i, (text, _) in enumerate(parts):
            col_widths[i % 2] = max(col_widths[i % 2], len(text))

    # Build rows: one Text per row (no Rich Table — simpler with Group).
    rows: list[RenderableType] = []
    for name, accent, parts in all_parts:
        name_style = f"bold {accent}"
        for pair_idx in range(0, max(1, len(parts)), 2):
            if pair_idx == 0:
                prefix = f"{name:<{name_width}}  "
                prefix_style = name_style
            else:
                prefix = " " * (name_width + 2)
                prefix_style = ""

            cols: list[tuple[str, str]] = [(prefix, prefix_style)]
            for offset in range(2):
                idx = pair_idx + offset
                if idx < len(parts):
                    text, style = parts[idx]
                    padded = f"{text:<{col_widths[offset]}}  "
                    cols.append((padded, style))
                else:
                    cols.append((" " * col_widths[offset] + "  ", ""))
            rows.append(Text.assemble(*cols) if cols else Text(""))

        # Blank line between providers (but not after the last).
        if parts and all_parts[-1][0] != name:
            rows.append(Text(""))

    # Strip trailing blank line.
    while rows and rows[-1].plain.strip() == "":
        rows.pop()

    return rows


def _compact_window_parts(snapshot: ProviderSnapshot, now: datetime) -> list[tuple[str, str]]:
    """Return [(window_text, style), ...] for each window of a provider.

    Window text is e.g. ``5h:68%↑41pt``.  Style is a theme style name based
    on the pace direction (text.green / text.red / text.yellow / text.muted).
    """
    name = snapshot.name.removesuffix(" [HTTP]")

    if not snapshot.ok or not snapshot.data:
        return []

    def _pace_style(part: str) -> str:
        if "↓" in part:
            return "text.red"
        if "↑" in part:
            return "text.green"
        if "=" in part:
            return "text.yellow"
        return "text.muted"

    spec = PROVIDER_RENDER_SPECS.get(name)

    # --- Cursor (percent-used → percent-remaining, billing-cycle pace) ---
    if spec is None and name == "Cursor":
        data = snapshot.data
        parts: list[tuple[str, str]] = []
        start_iso = data.get("billing_cycle_start")
        end_iso = data.get("billing_cycle_end_iso")
        start = str(start_iso) if isinstance(start_iso, str) else None
        end = str(end_iso) if isinstance(end_iso, str) else None
        for label, key in (("ac", "auto_percent_used"), ("ap", "api_percent_used")):
            value = data.get(key)
            if not percent_is_valid(value):
                continue
            pct_left = 100.0 - float(value)
            pace = _billing_cycle_pace_label(pct_left, start, end, now)
            part = f"{label}:{_percent_str(pct_left)}% {_compact_pace(pace)}"
            parts.append((part, _pace_style(part)))
        return parts

    # --- Vibe (percent-used → percent-remaining, billing-cycle pace) ---
    if spec is None and name == "Vibe":
        data = snapshot.data
        usage = data.get("usage_percent")
        if not isinstance(usage, (int, float)):
            return []
        pct_left = max(0.0, 100.0 - float(usage))
        start_iso = data.get("start_date")
        end_iso = data.get("end_date")
        pace = _billing_cycle_pace_label(
            pct_left,
            str(start_iso) if isinstance(start_iso, str) else None,
            str(end_iso) if isinstance(end_iso, str) else None,
            now,
        )
        part = f"mo:{_percent_str(pct_left)}% {_compact_pace(pace)}"
        return [(part, _pace_style(part))]

    # --- Unknown provider ---
    if spec is None:
        return []

    # --- Standard window-based provider ---
    parts: list[tuple[str, str]] = []
    for window in spec.windows:
        percent = snapshot.data.get(window.percent_key)
        if window.omit_when_empty and percent is None:
            continue
        if percent is None:
            continue
        pct = _percent_str(percent)
        reset = snapshot.data.get(window.reset_key)
        reset_str = None if reset is None else str(reset)
        pace = _pace_label(percent, reset_str, now, window.window_hours)
        part = f"{window.session_label}:{pct}% {_compact_pace(pace)}"
        parts.append((part, _pace_style(part)))

    # Antigravity C+G windows
    if name == "Antigravity":
        for window in ANTIGRAVITY_CG_WINDOWS:
            percent = snapshot.data.get(window.percent_key)
            if not percent_is_valid(percent):
                continue
            pct = _percent_str(percent)
            reset = snapshot.data.get(window.reset_key)
            reset_str = None if reset is None else str(reset)
            pace = _pace_label(percent, reset_str, now, window.window_hours)
            part = f"{window.session_label}:{pct}% {_compact_pace(pace)}"
            parts.append((part, _pace_style(part)))

    return parts


def build_loading_screen(message: str, updated_at: datetime, elapsed_seconds: float = 0.0) -> Group:
    """Build the loading/startup screen as a Rich Group."""
    header = Text.assemble(
        ("Gradus", "bold text.cyan"),
        ("  |  ", "text.muted"),
        ("Last Updated: ", "text.muted"),
        (updated_at.strftime("%b %d %H:%M:%S"), "text.yellow"),
        ("  |  ", "text.muted"),
        ("Starting up ", "text.muted"),
        (f"{elapsed_seconds:0.1f}s", "text.cyan"),
    )

    body = Table.grid(padding=(0, 1))
    body.add_column()
    spinner = Spinner("dots", text=Text(message, style="text.ink"), style="text.cyan")
    body.add_row(spinner)
    body.add_row(Text("First refresh can take a few seconds.", style="text.muted"))
    body.add_row(Text("PTY sessions are reused after startup.", style="text.muted"))

    panel = Panel(
        body,
        title="[bold text.cyan]Warming Up[/]",
        subtitle="[text.muted]getting initial usage[/]",
        border_style="border",
        subtitle_align="left",
        padding=(0, 1),
    )

    footer = Text.assemble(("[q]", "cyan"), " quit  ", ("[r]", "cyan"), " refresh")
    return Group(header, Text(""), panel, Text(""), footer)


# ---------------------------------------------------------------------------
# JSON output (no Rich dependency — plain string)
# ---------------------------------------------------------------------------


def render_json(snapshots: list[ProviderSnapshot], updated_at: datetime) -> str:
    payload = {
        "updated_at": updated_at.isoformat(),
        "providers": [
            {
                "name": snap.name,
                "ok": snap.ok,
                "source": snap.source,
                "data": project_data(snap),
                "display": _provider_display_fields(snap, updated_at),
                "error": snap.error[:200] if snap.error else snap.error,
            }
            for snap in snapshots
        ],
    }
    return json.dumps(payload, indent=2, sort_keys=True)
