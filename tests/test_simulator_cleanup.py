"""Hermetic checks for Gradus-owned Simulator cleanup paths."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHARED_GATE_LIB = Path(
    "/Users/dave/Documents/Projects/apple_developer/release_tools/templates/simctl_gate_lib.sh"
)
SWEEP = ROOT / "scripts" / "sweep-gradus-gate-simulators.sh"
SIMULATOR_ID = "11111111-2222-3333-4444-555555555555"


def executable(path: Path, source: str) -> None:
    """Write a small executable helper into a temporary test directory."""
    path.write_text(textwrap.dedent(source), encoding="utf-8")
    path.chmod(0o755)


class FakeSimulatorEnvironment:
    """Build fake xcrun and UI-lock commands for isolated shell tests."""

    def __init__(self, root: Path) -> None:
        self.root = root
        self.bin_dir = root / "bin"
        self.bin_dir.mkdir()
        self.inventory = root / "simulators.json"
        self.actions = root / "actions.txt"
        self.names = root / "created-names.txt"
        self.lock_calls = root / "lock-calls.txt"
        self.lock_exit = root / "lock-exit.txt"
        self.lock_exit.write_text("0", encoding="utf-8")
        self.inventory.write_text(json.dumps({"devices": {}}), encoding="utf-8")
        executable(
            self.bin_dir / "xcrun",
            """#!/bin/bash
set -eu
if [[ "$1" == "simctl" && "$2" == "list" ]]; then
  [[ "${SIMCTL_LIST_EXIT:-0}" == 0 ]] || exit "$SIMCTL_LIST_EXIT"
  cat "$SIMULATOR_LIST_JSON"
elif [[ "$1" == "simctl" && "$2" == "create" ]]; then
  printf '%s\\n' "$3" >> "$SIMULATOR_CREATE_NAME_LOG"
  printf '%s\\n' "$SIMULATOR_CREATE_UDID"
elif [[ "$1" == "simctl" && ( "$2" == "shutdown" || "$2" == "delete" ) ]]; then
  printf '%s\\t%s\\n' "$2" "$3" >> "$SIMULATOR_ACTION_LOG"
else
  echo "unexpected xcrun call: $*" >&2
  exit 90
fi
""",
        )
        executable(
            self.bin_dir / "apple-ui-test-lock",
            """#!/bin/bash
set -eu
printf '%s\\n' "$*" >> "$APPLE_UI_TEST_LOCK_LOG"
[[ "${LOCK_EXIT_CODE:-0}" == 0 ]] || exit "$LOCK_EXIT_CODE"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--" ]]; then
    shift
    exec "$@"
  fi
  shift
done
exit "${LOCK_EXIT_CODE:-0}"
""",
        )

    def environment(self) -> dict[str, str]:
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.bin_dir}:{env['PATH']}",
                "HOME": str(self.root / "home"),
                "TMPDIR": str(self.root),
                "SIMULATOR_LIST_JSON": str(self.inventory),
                "SIMULATOR_ACTION_LOG": str(self.actions),
                "SIMULATOR_CREATE_NAME_LOG": str(self.names),
                "SIMULATOR_CREATE_UDID": SIMULATOR_ID,
                "APPLE_UI_TEST_LOCK": str(self.bin_dir / "apple-ui-test-lock"),
                "APPLE_UI_TEST_LOCK_LOG": str(self.lock_calls),
                "GATE_XCTEST_DEVICE_SET": str(self.root / "no-xctest-devices"),
                "LOCK_EXIT_CODE": self.lock_exit.read_text(encoding="utf-8"),
            }
        )
        return env

    def action_lines(self) -> list[str]:
        if not self.actions.exists():
            return []
        return self.actions.read_text(encoding="utf-8").splitlines()


class GateLibraryCleanupTests(unittest.TestCase):
    """Prove the shared gate library removes its registered device on EXIT."""

    def run_gate(self, exit_code: int) -> tuple[subprocess.CompletedProcess[str], list[str]]:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        fake = FakeSimulatorEnvironment(root)
        runner = root / "gate.sh"
        executable(
            runner,
            f"""#!/bin/bash
set -euo pipefail
source {SHARED_GATE_LIB}
udid="$(gate_sim_create gradus unit com.apple.CoreSimulator.SimDeviceType.iPhone-15 \\
  com.apple.CoreSimulator.SimRuntime.iOS-26-5)"
[[ "$udid" == "$SIMULATOR_CREATE_UDID" ]]
exit {exit_code}
""",
        )
        result = subprocess.run(
            ["bash", str(runner)],
            cwd=ROOT,
            env=fake.environment(),
            capture_output=True,
            text=True,
            check=False,
        )
        return result, fake.action_lines()

    def test_registered_simulator_is_removed_when_gate_passes(self) -> None:
        result, actions = self.run_gate(0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(actions, [f"shutdown\t{SIMULATOR_ID}", f"delete\t{SIMULATOR_ID}"])

    def test_registered_simulator_is_removed_when_gate_fails(self) -> None:
        result, actions = self.run_gate(23)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertEqual(actions, [f"shutdown\t{SIMULATOR_ID}", f"delete\t{SIMULATOR_ID}"])


class AbandonedGradusSweepTests(unittest.TestCase):
    """Protect live owners and other projects during the pre-push sweep."""

    @staticmethod
    def device(udid: str, name: str, state: str) -> dict[str, str]:
        return {"udid": udid, "name": name, "state": state}

    def run_sweep(
        self, inventory: str | dict[str, object], *, lock_exit: int = 0, list_exit: int = 0
    ) -> tuple[subprocess.CompletedProcess[str], FakeSimulatorEnvironment]:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        fake = FakeSimulatorEnvironment(Path(temporary.name))
        payload = inventory if isinstance(inventory, str) else json.dumps(inventory)
        fake.inventory.write_text(payload, encoding="utf-8")
        fake.lock_exit.write_text(str(lock_exit), encoding="utf-8")
        env = fake.environment()
        env["SIMCTL_LIST_EXIT"] = str(list_exit)
        result = subprocess.run(
            [str(SWEEP)],
            cwd=ROOT,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        return result, fake

    def test_sweeps_only_dead_gradus_devices_and_shutdowns_booted_leftovers(self) -> None:
        dead_pid = "2147483647"
        live_pid = str(os.getpid())
        inventory = {
            "devices": {
                "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                    self.device(
                        "11111111-2222-3333-4444-555555555551",
                        f"gradus-gate-{dead_pid}-walkthrough",
                        "Booted",
                    ),
                    self.device(
                        "11111111-2222-3333-4444-555555555552",
                        f"gradus-gate-{dead_pid}-test",
                        "Shutdown",
                    ),
                    self.device(
                        "11111111-2222-3333-4444-555555555553",
                        f"gradus-gate-{live_pid}-active",
                        "Booted",
                    ),
                    self.device(
                        "11111111-2222-3333-4444-555555555554",
                        f"paperpal-gate-{dead_pid}-ui",
                        "Booted",
                    ),
                    self.device("11111111-2222-3333-4444-555555555555", "iPhone 16", "Booted"),
                    self.device(
                        "11111111-2222-3333-4444-555555555556",
                        f"gradus-gate-{dead_pid}x-bad-prefix",
                        "Booted",
                    ),
                ]
            }
        }
        result, fake = self.run_sweep(inventory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            fake.action_lines(),
            [
                "shutdown\t11111111-2222-3333-4444-555555555551",
                "delete\t11111111-2222-3333-4444-555555555551",
                "delete\t11111111-2222-3333-4444-555555555552",
            ],
        )
        lock_call = fake.lock_calls.read_text(encoding="utf-8")
        self.assertIn("Gradus abandoned simulator cleanup", lock_call)
        self.assertNotIn("--simulator-udid", lock_call)
        self.assertIn("keeping gradus-gate-", result.stderr)

    def test_malformed_inventory_fails_before_any_device_change(self) -> None:
        result, fake = self.run_sweep("not-json")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not parse Simulator inventory", result.stderr)
        self.assertEqual(fake.action_lines(), [])

    def test_simctl_failure_fails_before_any_device_change(self) -> None:
        result, fake = self.run_sweep({"devices": {}}, list_exit=9)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not list Simulator devices", result.stderr)
        self.assertEqual(fake.action_lines(), [])

    def test_lock_failure_does_not_enumerate_or_change_devices(self) -> None:
        result, fake = self.run_sweep({"devices": {}}, lock_exit=75)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not acquire the host Simulator lock", result.stderr)
        self.assertEqual(fake.action_lines(), [])


if __name__ == "__main__":
    unittest.main()
