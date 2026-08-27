"""Pin the carry-marker strings Python publishes against their Swift readers.

A carry marker is a probe-authored error that means "this failure is expected;
the retained values below are still the last good reading."  Python writes it
into the snapshot, and each Swift surface recognises it by *exact equality* to
decide whether the provider row goes quiet or red.

Nothing connected the two sides.  On 2026-08-27 the Copilot timeout message was
renamed from the shared ``"provider probe timed out"`` to a dedicated
``COPILOT_PROBE_RETRY_MESSAGE`` so the Python retention window could find it --
and both Swift consumers, still matching the old string, began painting a red
"needs attention" row whose own text read "showing cached values".  Every Python
and Swift test stayed green, because each side was self-consistent.

These tests are the missing edge.  They read the Swift sources as text rather
than building them, so they run in the Python pre-push gate and fail in seconds
instead of waiting on Xcode Cloud.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

from gradus.snapshot import (
    ANTIGRAVITY_AUTH_RETRY_MESSAGE,
    COPILOT_PROBE_RETRY_MESSAGE,
)

ROOT = Path(__file__).resolve().parents[1]

#: Swift constant name -> the Python constant it must mirror verbatim.
CARRY_MARKERS = {
    "retryingLabel": ANTIGRAVITY_AUTH_RETRY_MESSAGE,
    "copilotRetryLabel": COPILOT_PROBE_RETRY_MESSAGE,
}

#: Every Swift surface that classifies a provider failure. A new one belongs
#: here the day it is written, not the day it drifts.
SWIFT_SOURCES = {
    "Mac": ROOT / "app" / "GradusMac" / "ProviderEntry+Ranking.swift",
    "iOS": ROOT / "app" / "GradusiOS" / "ProviderStatus+Ranking.swift",
}

_DECLARATION = re.compile(r'static let (\w+)\s*=\s*"([^"]*)"')
_CARRY_SET = re.compile(r"static let carryLabels: Set<String> = \[([^\]]*)\]")


class SwiftCarryMarkerParityTests(unittest.TestCase):
    """The Python constants and their Swift mirrors are one unit (INV-9)."""

    def _declarations(self, path: Path) -> dict[str, str]:
        return dict(_DECLARATION.findall(path.read_text(encoding="utf-8")))

    def test_every_marker_is_mirrored_verbatim(self) -> None:
        """A reword on either side alone fails here, on both surfaces."""
        for surface, path in SWIFT_SOURCES.items():
            declared = self._declarations(path)
            for name, expected in CARRY_MARKERS.items():
                with self.subTest(surface=surface, constant=name):
                    self.assertIn(
                        name,
                        declared,
                        f"{path.name} declares no `{name}`; Python publishes "
                        f"{expected!r} and this surface cannot recognise it.",
                    )
                    self.assertEqual(
                        declared[name],
                        expected,
                        f"{surface} `{name}` has drifted from gradus.snapshot.",
                    )

    def test_each_surface_acts_on_every_marker(self) -> None:
        """Declaring the string is inert unless `carryLabels` also lists it.

        The bug this file exists for would have survived a declaration-only
        check: the constant could sit unread while `label(for:)` kept matching
        the old value.
        """
        for surface, path in SWIFT_SOURCES.items():
            with self.subTest(surface=surface):
                match = _CARRY_SET.search(path.read_text(encoding="utf-8"))
                self.assertIsNotNone(match, f"{path.name} declares no `carryLabels` set.")
                assert match is not None  # narrowing for type checkers
                members = {m.strip() for m in match.group(1).split(",") if m.strip()}
                self.assertEqual(members, set(CARRY_MARKERS))

    def test_no_surface_invents_a_marker_python_never_publishes(self) -> None:
        """The reverse direction: Swift may not grant grace on its own.

        A Swift-only carry label would quiet a row that Python still reports as
        a hard failure -- the same class of divergence, pointed the other way.
        """
        published = set(CARRY_MARKERS.values())
        for surface, path in SWIFT_SOURCES.items():
            declared = self._declarations(path)
            match = _CARRY_SET.search(path.read_text(encoding="utf-8"))
            assert match is not None
            for member in (m.strip() for m in match.group(1).split(",")):
                if not member:
                    continue
                with self.subTest(surface=surface, constant=member):
                    self.assertIn(
                        declared.get(member),
                        published,
                        f"{surface} treats `{member}` as a carry marker, but "
                        "gradus.snapshot never publishes that string.",
                    )


if __name__ == "__main__":
    unittest.main()
