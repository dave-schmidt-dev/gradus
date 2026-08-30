#!/usr/bin/env python3
"""Hermetic contract checks for Gradus walkthrough capture."""

from __future__ import annotations

import re
import subprocess
import sys
import unittest
from pathlib import Path

APP = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(APP))
from release_candidate.walkthrough import capture_routes  # noqa: E402

CAPTURE = APP / "scripts" / "capture-walkthrough.sh"
TEST = APP / "GradusiOSUITests" / "WalkthroughCaptureXCUITests.swift"
FIXTURES = APP / "GradusiOS" / "UITestFixtures.swift"
IOS_APP = APP / "GradusiOS" / "GradusiOSApp.swift"
WIDGET_TESTS = APP / "GradusWidgetTests" / "GradusWidgetTests.swift"
PROJECT = APP / "Gradus.xcodeproj" / "project.pbxproj"


class CaptureContractTests(unittest.TestCase):
    """Check route parity, progress, and screenshot gating without a simulator."""

    def setUp(self) -> None:
        self.shell = CAPTURE.read_text(encoding="utf-8")
        self.swift = TEST.read_text(encoding="utf-8")
        self.fixtures = FIXTURES.read_text(encoding="utf-8")
        self.ios_app = IOS_APP.read_text(encoding="utf-8")
        self.widget_tests = WIDGET_TESTS.read_text(encoding="utf-8")
        self.project = PROJECT.read_text(encoding="utf-8")

    def test_self_test_emits_one_visible_status_per_declared_screen(self) -> None:
        result = subprocess.run(
            ["bash", str(CAPTURE), "--self-test"], capture_output=True, text=True, check=False
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        count = int(re.search(r"screenCount=(\d+)", result.stdout).group(1))
        statuses = re.findall(r"capture-\d+-of-\d+", result.stderr)
        self.assertGreater(count, 0)
        self.assertEqual(len(statuses), count)
        self.assertIn(f"statusCount={count}", result.stdout)

    def test_declared_images_are_unique_and_capture_is_fail_closed(self) -> None:
        routes = re.findall(
            r'^\s+"([^|]+)\|([^|]+)\|([^|]+)\|([^"|]+\.png)"', self.shell, re.MULTILINE
        )
        self.assertEqual(len(routes), 41)
        self.assertEqual(len({route[0] for route in routes}), len(routes))
        self.assertEqual(len({route[3] for route in routes}), len(routes))
        self.assertEqual(
            {(route[0], route[1], route[2], route[3]) for route in routes},
            {
                (route["screenId"], route["fixture"], route["marker"], route["image"])
                for route in capture_routes()
            },
        )
        self.assertIn('[[ -s "$screenshot" ]]', self.shell)
        self.assertIn('[[ "$png_count" == "$expected_count" ]]', self.shell)

    def test_capture_waits_for_foreground_and_marker_before_write(self) -> None:
        foreground = "app.wait(for: .runningForeground, timeout: 30)"
        marker = "expected.waitForExistence(timeout: 30)"
        write = "pngRepresentation.write"
        for token in (foreground, marker, write):
            self.assertIn(token, self.swift)
        self.assertLess(self.swift.index(foreground), self.swift.index(marker))
        self.assertLess(self.swift.index(marker), self.swift.index(write))

    def test_capture_harness_skips_outside_an_explicit_walkthrough_run(self) -> None:
        self.assertIn('guard let route = env["GRADUS_WALKTHROUGH_FIXTURE"] else', self.swift)
        self.assertIn(
            'throw XCTSkip("Walkthrough capture environment is not configured")', self.swift
        )

    def test_driver_is_disposable_dark_and_progress_visible(self) -> None:
        self.assertIn("simctl create", self.shell)
        self.assertIn("simctl delete", self.shell)
        self.assertIn('simctl ui "$simulator_udid" appearance dark', self.shell)
        self.assertIn('status "capture-$((index + 1))-of-$total $screen"', self.shell)
        self.assertIn("still running", self.shell)
        self.assertIn("TEST_RUNNER_GRADUS_WALKTHROUGH_FIXTURE", self.shell)
        self.assertIn("TEST_RUNNER_GRADUS_WALKTHROUGH_WIDGET_OUTPUT", self.shell)
        self.assertIn("widget-render-blocked.log", self.shell)
        self.assertIn("$fixture-blocked.log", self.shell)
        self.assertIn("persistent simulator selection is not supported", self.shell)

    def test_progress_and_widget_states_have_deterministic_test_hooks(self) -> None:
        self.assertIn('case sampleEntryInProgress = "sample-entry-in-progress"', self.fixtures)
        self.assertIn("uiTestFixture?.startsSampleEntryInProgress ?? false", self.ios_app)
        for image in (
            "widget-render-current.png",
            "widget-render-empty.png",
            "widget-render-unavailable.png",
        ):
            self.assertIn(image, self.widget_tests)
        self.assertIn("ImageRenderer", self.widget_tests)
        self.assertIn('bundleIdentifier: "com.apple.springboard"', self.swift)
        self.assertIn("openGradusWidgetAddSurface", self.swift)

    def test_capture_test_is_a_target_member_and_zero_tests_are_rejected(self) -> None:
        self.assertEqual(self.project.count("WalkthroughCaptureXCUITests.swift in Sources"), 2)
        self.assertEqual(self.project.count("/* WalkthroughCaptureXCUITests.swift */"), 3)
        self.assertIn('get("totalTestCount")', self.shell)
        guard = 'if [[ "$route_test_count" != "1" ]]'
        png = 'if [[ ! -s "$screenshot" ]]'
        self.assertIn(guard, self.shell)
        self.assertLess(self.shell.index(guard), self.shell.index(png))
        self.assertIn("$fixture-blocked.xcresult", self.shell)


if __name__ == "__main__":
    unittest.main()
