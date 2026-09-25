#!/usr/bin/env python3
"""Hermetic contract checks for Gradus walkthrough capture."""

from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
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

    def run_stubbed_capture(
        self,
        runtimes: list[dict[str, object]],
        start_at: int,
        xcode_exit: int = 0,
        capture_timeout: int = 180,
        long_running_xcode: bool = False,
        send_term: bool = False,
        xctest_clone_state: str | None = None,
        xctest_clone_preexisting: bool = False,
        xctest_clone_matches_gate: bool = False,
    ) -> tuple[subprocess.CompletedProcess[str], str, str, str, str, str]:
        """Run the real capture driver against hermetic simulator and Xcode stubs."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            output_dir = root / "screenshots"
            output_dir.mkdir()
            simulator_list = root / "simulators.json"
            simulator_list.write_text(
                json.dumps(
                    {
                        "runtimes": runtimes,
                        "devicetypes": [
                            {
                                "identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-15",
                                "name": "iPhone 15",
                                "isAvailable": True,
                            }
                        ],
                        "devices": {},
                    }
                ),
                encoding="utf-8",
            )
            create_log = root / "created-runtime.txt"
            action_log = root / "simulator-actions.txt"
            lock_log = root / "lock-invocations.txt"
            xcode_env_log = root / "xcode-environment.txt"
            xctest_set = root / "xctest-devices"
            xctest_clone_id = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            xctest_clone_marker = root / "xctest-clone-created"
            empty_clone_inventory = root / "xctest-empty.json"
            clone_inventory = root / "xctest-clone.json"
            empty_clone_inventory.write_text('{"devices":{}}', encoding="utf-8")
            if xctest_clone_state is not None:
                clone_data = xctest_set / xctest_clone_id / "data"
                clone_data.mkdir(parents=True)
                clone_inventory.write_text(
                    json.dumps(
                        {
                            "devices": {
                                "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                                    {
                                        "udid": xctest_clone_id,
                                        "name": "Clone 7 of iPhone 15",
                                        "dataPath": str(clone_data),
                                        "state": xctest_clone_state,
                                    }
                                ]
                            }
                        }
                    ),
                    encoding="utf-8",
                )
                if xctest_clone_preexisting:
                    xctest_clone_marker.touch()
            scripts = {
                "xcrun": """#!/bin/bash
set -eu
if [[ "$1" == "simctl" && "$2" == "--set" && "$4" == "list" ]]; then
  if [[ -f "$XCTEST_CLONE_MARKER" ]]; then
    if [[ "${XCTEST_CLONE_MATCHES_GATE:-0}" == 1 ]]; then
      python3 - "$XCTEST_CLONE_INVENTORY" "$GRADUS_XCTEST_SOURCE_SIMULATOR_NAME" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    inventory = json.load(stream)
for devices in inventory.get("devices", {}).values():
    for device in devices:
        device["name"] = f"Clone 7 of {sys.argv[2]}"
print(json.dumps(inventory))
PY
    else
      cat "$XCTEST_CLONE_INVENTORY"
    fi
  else
    cat "$XCTEST_EMPTY_INVENTORY"
  fi
elif [[ "$1" == "simctl" && "$2" == "--set" && "$4" == "shutdown" ]]; then
  printf 'xctest-shutdown\t%s\n' "$5" >> "$SIMULATOR_ACTION_LOG"
elif [[ "$1" == "simctl" && "$2" == "--set" && "$4" == "delete" ]]; then
  printf 'xctest-delete\\t%s\\n' "$5" >> "$SIMULATOR_ACTION_LOG"
  rm -f "$XCTEST_CLONE_MARKER"
elif [[ "$1" == "simctl" && "$2" == "list" ]]; then
  cat "$SIMULATOR_LIST_JSON"
elif [[ "$1" == "simctl" && "$2" == "create" ]]; then
  printf '%s\\n' "$5" >> "$SIMULATOR_CREATE_LOG"
  printf '%s\\n' "$3" >> "$SIMULATOR_CREATE_NAME_LOG"
  : > "$SIMULATOR_PRESENT_FILE"
  printf '11111111-2222-3333-4444-555555555555\\n'
elif [[ "$1" == "simctl" && ( "$2" == "shutdown" || "$2" == "delete" ) ]]; then
  printf '%s\\t%s\\n' "$2" "$3" >> "$SIMULATOR_ACTION_LOG"
  if [[ "$2" == "delete" ]]; then
    if [[ -f "$XCODEBUILD_PID_FILE" ]]; then
      if kill -0 "$(cat "$XCODEBUILD_PID_FILE")" 2>/dev/null; then
        printf 'alive\\n' > "$XCODEBUILD_STATE_AT_DELETE"
      else
        printf 'gone\\n' > "$XCODEBUILD_STATE_AT_DELETE"
      fi
    else
      printf 'not-started\\n' > "$XCODEBUILD_STATE_AT_DELETE"
    fi
    if [[ -f "$XCTEST_CLONE_MARKER" ]]; then
      printf 'xctest-still-present\\n' >> "$SIMULATOR_ACTION_LOG"
    fi
    rm -f "$SIMULATOR_PRESENT_FILE"
  fi
elif [[ "$1" == "xcresulttool" ]]; then
  printf '{"totalTestCount":1}\\n'
fi
""",
                "xcodebuild": """#!/bin/bash
set -eu
[[ -e "$SIMULATOR_PRESENT_FILE" ]] || { echo 'walkthrough simulator was deleted before Xcode finished' >&2; exit 89; }
if [[ "${XCODEBUILD_MODE:-}" == "long-running" ]]; then
  printf '%s\\n' "$$" > "$XCODEBUILD_PID_FILE"
  [[ "${XCODEBUILD_CREATE_CLONE:-0}" == 1 ]] && : > "$XCTEST_CLONE_MARKER"
  exec /bin/sleep 60
fi
printf '%s\\t%s\\t%s\\t%s\\n' \\
  "${TEST_RUNNER_GRADUS_WALKTHROUGH_FIXTURE:-}" \\
  "${TEST_RUNNER_GRADUS_WALKTHROUGH_MARKER:-}" \\
  "${TEST_RUNNER_GRADUS_WALKTHROUGH_SCREENSHOT:-}" \\
  "${TEST_RUNNER_GRADUS_WALKTHROUGH_WIDGET_OUTPUT:-}" >> "$XCODEBUILD_ENV_LOG"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-resultBundlePath" ]]; then
    mkdir -p "$2"
    shift 2
  else
    shift
  fi
done
if [[ -n "${TEST_RUNNER_GRADUS_WALKTHROUGH_SCREENSHOT:-}" ]]; then
  printf 'png' > "$TEST_RUNNER_GRADUS_WALKTHROUGH_SCREENSHOT"
fi
if [[ -n "${TEST_RUNNER_GRADUS_WALKTHROUGH_WIDGET_OUTPUT:-}" ]]; then
  for image in widget-render-current.png widget-render-empty.png widget-render-unavailable.png; do
    printf 'png' > "$TEST_RUNNER_GRADUS_WALKTHROUGH_WIDGET_OUTPUT/$image"
  done
fi
exit "${XCODEBUILD_EXIT:-0}"
""",
                "apple-ui-test-lock": """#!/bin/bash
set -eu
printf '%s\\n' "$*" >> "$APPLE_UI_TEST_LOCK_LOG"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--" ]]; then
    shift
    exec "$@"
  fi
  shift
done
exit 64
""",
                "sleep": """#!/usr/bin/env python3
import os
import sys
import time
time.sleep(float(sys.argv[1]) if os.environ.get("XCODEBUILD_MODE") == "long-running" else 0.01)
""",
            }
            for name, source in scripts.items():
                script = bin_dir / name
                script.write_text(textwrap.dedent(source), encoding="utf-8")
                script.chmod(0o755)
            stat_stub = bin_dir / "stat"
            stat_stub.write_text(
                '#!/usr/bin/env bash\nprintf "%s\\n" "$FAKE_SIMULATOR_BIRTH_TIME"\n',
                encoding="utf-8",
            )
            stat_stub.chmod(0o755)

            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": f"{bin_dir}:{environment['PATH']}",
                    "SIMULATOR_LIST_JSON": str(simulator_list),
                    "SIMULATOR_CREATE_LOG": str(create_log),
                    "SIMULATOR_CREATE_NAME_LOG": str(root / "created-names.txt"),
                    "SIMULATOR_ACTION_LOG": str(action_log),
                    "SIMULATOR_PRESENT_FILE": str(root / "simulator-present"),
                    "APPLE_UI_TEST_LOCK": str(bin_dir / "apple-ui-test-lock"),
                    "APPLE_UI_TEST_LOCK_LOG": str(lock_log),
                    "XCODEBUILD_ENV_LOG": str(xcode_env_log),
                    "GRADUS_WALKTHROUGH_START_AT": str(start_at),
                    "GRADUS_WALKTHROUGH_CAPTURE_TIMEOUT_SECONDS": str(capture_timeout),
                    "GATE_XCTEST_DEVICE_SET": str(
                        xctest_set if xctest_clone_state is not None else root / "no-xctest-devices"
                    ),
                    "XCTEST_CLONE_MARKER": str(xctest_clone_marker),
                    "XCTEST_CLONE_MATCHES_GATE": "1" if xctest_clone_matches_gate else "0",
                    "XCTEST_CLONE_INVENTORY": str(clone_inventory),
                    "XCTEST_EMPTY_INVENTORY": str(empty_clone_inventory),
                    "XCODEBUILD_CREATE_CLONE": "1" if xctest_clone_state is not None else "0",
                    "FAKE_SIMULATOR_BIRTH_TIME": str(int(time.time()) - 1),
                    "XCODEBUILD_EXIT": str(xcode_exit),
                    "XCODEBUILD_MODE": "long-running" if long_running_xcode else "normal",
                    "XCODEBUILD_PID_FILE": str(root / "xcodebuild.pid"),
                    "XCODEBUILD_STATE_AT_DELETE": str(root / "xcodebuild-state-at-delete.txt"),
                }
            )
            command = ["bash", str(CAPTURE), "--output-dir", str(output_dir)]
            process = subprocess.Popen(
                command,
                cwd=APP,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
            )
            try:
                if send_term:
                    deadline = time.monotonic() + 8
                    while not (root / "xcodebuild.pid").exists() and process.poll() is None:
                        if time.monotonic() >= deadline:
                            raise AssertionError(
                                "fake Xcode did not start before TERM test deadline"
                            )
                        time.sleep(0.02)
                    process.send_signal(signal.SIGTERM)
                stdout, stderr = process.communicate(timeout=12)
            except BaseException:
                pid_file = root / "xcodebuild.pid"
                if pid_file.exists():
                    try:
                        xcode_pid = int(pid_file.read_text(encoding="utf-8"))
                        os.killpg(os.getpgid(xcode_pid), signal.SIGKILL)
                    except (ProcessLookupError, PermissionError, ValueError):
                        pass
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.communicate()
                raise
            result = subprocess.CompletedProcess(
                command, process.returncode, stdout=stdout, stderr=stderr
            )
            return (
                result,
                create_log.read_text(encoding="utf-8") if create_log.exists() else "",
                lock_log.read_text(encoding="utf-8") if lock_log.exists() else "",
                xcode_env_log.read_text(encoding="utf-8") if xcode_env_log.exists() else "",
                action_log.read_text(encoding="utf-8") if action_log.exists() else "",
                (root / "xcodebuild-state-at-delete.txt").read_text(encoding="utf-8").strip()
                if (root / "xcodebuild-state-at-delete.txt").exists()
                else "",
            )

    @staticmethod
    def runtime(identifier: str, version: str, available: bool = True) -> dict[str, object]:
        return {
            "identifier": identifier,
            "version": version,
            "isAvailable": available,
            "platform": "iOS",
        }

    def test_selects_highest_available_ios_26_runtime_only(self) -> None:
        result, created_runtime, _locks, xcode_environment, actions, _child_state = (
            self.run_stubbed_capture(
                [
                    self.runtime("com.apple.CoreSimulator.SimRuntime.iOS-26-3", "26.3"),
                    self.runtime("com.apple.CoreSimulator.SimRuntime.iOS-26-5", "26.5"),
                    self.runtime("com.apple.CoreSimulator.SimRuntime.iOS-27-0", "27.0"),
                ],
                start_at=45,
            )
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(created_runtime.strip(), "com.apple.CoreSimulator.SimRuntime.iOS-26-5")
        self.assertIn("reset-alerts-denied", xcode_environment)
        self.assertIn("shutdown\t11111111-2222-3333-4444-555555555555", actions)
        self.assertIn("delete\t11111111-2222-3333-4444-555555555555", actions)

    def test_unavailable_ios_26_runtime_fails_closed(self) -> None:
        result, created_runtime, locks, _xcode_environment, actions, _child_state = (
            self.run_stubbed_capture(
                [
                    self.runtime("com.apple.CoreSimulator.SimRuntime.iOS-26-5", "26.5", False),
                    self.runtime("com.apple.CoreSimulator.SimRuntime.iOS-27-0", "27.0"),
                ],
                start_at=45,
            )
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no available iOS 26.x Simulator runtime", result.stderr)
        self.assertEqual(created_runtime, "")
        self.assertEqual(locks, "")
        self.assertEqual(actions, "")

    def test_missing_ios_26_runtime_fails_closed(self) -> None:
        result, created_runtime, locks, _xcode_environment, actions, _child_state = (
            self.run_stubbed_capture(
                [self.runtime("com.apple.CoreSimulator.SimRuntime.iOS-27-0", "27.0")],
                start_at=45,
            )
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no available iOS 26.x Simulator runtime", result.stderr)
        self.assertEqual(created_runtime, "")
        self.assertEqual(locks, "")
        self.assertEqual(actions, "")

    def test_both_xcode_capture_lanes_use_the_disposable_simulator_lock(self) -> None:
        result, created_runtime, locks, xcode_environment, actions, child_state = (
            self.run_stubbed_capture(
                [self.runtime("com.apple.CoreSimulator.SimRuntime.iOS-26-5", "26.5")],
                start_at=35,
            )
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(created_runtime.splitlines()), 1)
        self.assertEqual(
            actions.splitlines(),
            [
                "shutdown\t11111111-2222-3333-4444-555555555555",
                "delete\t11111111-2222-3333-4444-555555555555",
            ],
        )
        self.assertEqual(child_state, "not-started")
        invocations = locks.splitlines()
        xcode_invocations = [line for line in invocations if "xcodebuild test" in line]
        self.assertTrue(xcode_invocations)
        self.assertTrue(
            all(
                "--simulator-udid 11111111-2222-3333-4444-555555555555" in invocation
                for invocation in xcode_invocations
            )
        )
        self.assertTrue(
            any("GradusWidgetTests/exportWalkthroughWidgetStates()" in line for line in invocations)
        )
        self.assertIn("shutdown\t11111111-2222-3333-4444-555555555555", actions)
        self.assertIn("delete\t11111111-2222-3333-4444-555555555555", actions)
        self.assertTrue(
            any(
                "GradusiOSUITests/WalkthroughCaptureXCUITests/testWalkthroughCapture" in line
                for line in invocations
            )
        )
        environment_rows = [row.split("\t") for row in xcode_environment.splitlines()]
        self.assertTrue(
            any(row[0] == "" and row[3].endswith("/screenshots") for row in environment_rows)
        )
        self.assertTrue(
            any(
                row[0] == "reset-alerts-denied"
                and row[1] == "reset-alerts-permission-denied"
                and row[2].endswith("/reset-alerts-denied.png")
                and row[3] == ""
                for row in environment_rows
            )
        )

    def test_capture_driver_uses_canonical_lane_lock_for_both_xcode_calls(self) -> None:
        self.assertIn(
            'APPLE_UI_TEST_LOCK="${APPLE_UI_TEST_LOCK:-$HOME/.agent/bin/apple-ui-test-lock}"',
            self.shell,
        )
        self.assertEqual(
            self.shell.count('gate_ui_test_lock --simulator-udid "$simulator_udid"'), 2
        )

    def test_xcode_failure_still_cleans_the_walkthrough_simulator(self) -> None:
        result, created_runtime, _locks, _xcode_environment, actions, _child_state = (
            self.run_stubbed_capture(
                [self.runtime("com.apple.CoreSimulator.SimRuntime.iOS-26-5", "26.5")],
                start_at=45,
                xcode_exit=42,
            )
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("capture failed for settings.reset-alerts-denied", result.stderr)
        self.assertEqual(len(created_runtime.splitlines()), 1)
        self.assertIn("shutdown\t11111111-2222-3333-4444-555555555555", actions)
        self.assertIn("delete\t11111111-2222-3333-4444-555555555555", actions)

    def test_capture_timeout_terminates_xcode_before_simulator_cleanup(self) -> None:
        result, _created, _locks, _environment, actions, child_state = self.run_stubbed_capture(
            [self.runtime("com.apple.CoreSimulator.SimRuntime.iOS-26-5", "26.5")],
            start_at=45,
            capture_timeout=1,
            long_running_xcode=True,
            xctest_clone_state="Shutdown",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("timed out", result.stderr)
        self.assertEqual(child_state, "gone")
        self.assertIn("xctest-delete\taaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", actions)
        self.assertLess(
            actions.index("xctest-delete\taaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            actions.index("delete\t11111111-2222-3333-4444-555555555555"),
        )
        self.assertEqual(
            actions.splitlines(),
            [
                "xctest-delete\taaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                "shutdown\t11111111-2222-3333-4444-555555555555",
                "delete\t11111111-2222-3333-4444-555555555555",
            ],
        )

    def test_term_terminates_xcode_before_simulator_cleanup(self) -> None:
        result, _created, _locks, _environment, actions, child_state = self.run_stubbed_capture(
            [self.runtime("com.apple.CoreSimulator.SimRuntime.iOS-26-5", "26.5")],
            start_at=45,
            capture_timeout=30,
            long_running_xcode=True,
            send_term=True,
            xctest_clone_state="Shutdown",
        )
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assertEqual(child_state, "gone")
        self.assertIn("xctest-delete\taaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", actions)
        self.assertLess(
            actions.index("xctest-delete\taaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            actions.index("delete\t11111111-2222-3333-4444-555555555555"),
        )
        self.assertEqual(
            actions.splitlines(),
            [
                "xctest-delete\taaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                "shutdown\t11111111-2222-3333-4444-555555555555",
                "delete\t11111111-2222-3333-4444-555555555555",
            ],
        )

    def test_timeout_preserves_booted_clone_with_ambiguous_owner(self) -> None:
        result, _created, _locks, _environment, actions, _child_state = self.run_stubbed_capture(
            [self.runtime("com.apple.CoreSimulator.SimRuntime.iOS-26-5", "26.5")],
            start_at=45,
            capture_timeout=1,
            long_running_xcode=True,
            xctest_clone_state="Booted",
        )
        self.assertIn("timed out", result.stderr)
        self.assertIn("left new XCTest clone Clone 7 of iPhone 15", result.stderr)
        self.assertNotIn("xctest-delete", actions)
        self.assertIn("xctest-still-present", actions)

    def test_timeout_deletes_booted_clone_of_this_gate_simulator(self) -> None:
        result, _created, _locks, _environment, actions, _child_state = self.run_stubbed_capture(
            [self.runtime("com.apple.CoreSimulator.SimRuntime.iOS-26-5", "26.5")],
            start_at=45,
            capture_timeout=1,
            long_running_xcode=True,
            xctest_clone_state="Booted",
            xctest_clone_matches_gate=True,
        )
        self.assertIn("timed out", result.stderr)
        self.assertIn("deleted owned booted XCTest clone", result.stderr)
        self.assertLess(
            actions.index("xctest-shutdown\taaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            actions.index("xctest-delete\taaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
        )
        self.assertLess(
            actions.index("xctest-delete\taaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            actions.index("delete\t11111111-2222-3333-4444-555555555555"),
        )
        self.assertNotIn("xctest-still-present", actions)

    def test_timeout_preserves_clone_that_existed_before_the_leg(self) -> None:
        result, _created, _locks, _environment, actions, _child_state = self.run_stubbed_capture(
            [self.runtime("com.apple.CoreSimulator.SimRuntime.iOS-26-5", "26.5")],
            start_at=45,
            capture_timeout=1,
            long_running_xcode=True,
            xctest_clone_state="Shutdown",
            xctest_clone_preexisting=True,
        )
        self.assertIn("timed out", result.stderr)
        self.assertNotIn("xctest-delete", actions)
        self.assertIn("xctest-still-present", actions)

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
        self.assertEqual(len(routes), 45)
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
        self.assertIn("gate_sim_create gradus walkthrough", self.shell)
        self.assertIn('gate_sim_create gradus "walkthrough-permission-$index"', self.shell)
        self.assertIn("simctl delete", self.shell)
        self.assertIn('simctl ui "$simulator_udid" appearance dark', self.shell)
        self.assertIn('status "capture-$((index + 1))-of-$total $screen"', self.shell)
        self.assertIn("still running", self.shell)
        self.assertIn("TEST_RUNNER_GRADUS_WALKTHROUGH_FIXTURE", self.shell)
        self.assertIn("TEST_RUNNER_GRADUS_WALKTHROUGH_WIDGET_OUTPUT", self.shell)
        self.assertIn("widget-render-blocked.log", self.shell)
        self.assertIn("$fixture-blocked.log", self.shell)
        self.assertIn("persistent simulator selection is not supported", self.shell)

    def test_reset_alert_routes_match_declared_fixtures_markers_and_images(self) -> None:
        reset_routes = {
            (
                "settings.reset-alerts-off",
                "reset-alerts-off",
                "reset-alerts-banked-toggle",
                "reset-alerts-off.png",
            ),
            (
                "settings.reset-alerts-on",
                "reset-alerts-on",
                "reset-alerts-refill-toggle",
                "reset-alerts-on.png",
            ),
            (
                "settings.reset-alerts-requesting",
                "reset-alerts-requesting",
                "reset-alerts-permission-requesting",
                "reset-alerts-requesting.png",
            ),
            (
                "settings.reset-alerts-denied",
                "reset-alerts-denied",
                "reset-alerts-permission-denied",
                "reset-alerts-denied.png",
            ),
        }
        routes = re.findall(
            r'^\s+"([^|]+)\|([^|]+)\|([^|]+)\|([^"|]+\.png)"', self.shell, re.MULTILINE
        )
        declared = {(route[0], route[1], route[2], route[3]) for route in routes}
        self.assertTrue(reset_routes <= declared)
        self.assertTrue(
            reset_routes
            <= {
                (route["screenId"], route["fixture"], route["marker"], route["image"])
                for route in capture_routes()
            }
        )
        for case, fixture in (
            ("resetAlertsOff", "reset-alerts-off"),
            ("resetAlertsOn", "reset-alerts-on"),
            ("resetAlertsRequesting", "reset-alerts-requesting"),
            ("resetAlertsDenied", "reset-alerts-denied"),
        ):
            self.assertIn(f'case {case} = "{fixture}"', self.fixtures)
        self.assertIn('case "reset-alerts-off": return "reset-alerts-off"', self.swift)
        self.assertIn('case "reset-alerts-on": return "reset-alerts-on"', self.swift)
        self.assertIn(
            'case "reset-alerts-requesting": return "reset-alerts-requesting"', self.swift
        )
        self.assertIn('case "reset-alerts-denied": return "reset-alerts-denied"', self.swift)
        self.assertIn(
            'case "reset-alerts-off", "reset-alerts-on", "reset-alerts-requesting", "reset-alerts-denied":',
            self.swift,
        )

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
