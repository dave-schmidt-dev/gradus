"""Hermetic contract tests for the Gradus launchd installer."""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
INSTALLER = REPO_ROOT / "launchd" / "install.sh"


class LaunchdInstallTests(unittest.TestCase):
    """Exercise file and launchctl state without touching the real user agent."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        self.state = self.root / "launchctl-state"
        self.launchctl_log = self.root / "launchctl.log"
        self.event_log = self.root / "events.log"
        self.python_log = self.root / "python.log"
        self.bridge_log = self.root / "bridge.log"
        self.run_at_load_counter = self.root / "run-at-load-counter"
        self.snapshot_path = self.root / "state" / "snapshot-v2.json"
        self._write_executable(
            "launchctl",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' \"$*\" >> \"$GRADUS_TEST_LAUNCHCTL_LOG\"
case \"$1\" in
  print)
    if [[ \"${GRADUS_TEST_PRINT_MODE:-normal}\" == error ||
          (\"${GRADUS_TEST_PRINT_MODE:-normal}\" == error_after_bootout &&
           -f \"${GRADUS_TEST_BOOTOUT_MARKER}\") ]]; then
      echo \"launchctl test transport failure\" >&2
      exit 71
    fi
    test -f \"$GRADUS_TEST_LAUNCHCTL_STATE\" || {
      echo \"Could not find service\" >&2
      exit 113
    }
    ;;
  bootstrap)
    printf '%s\\n' bootstrap >> \"$GRADUS_TEST_EVENT_LOG\"
    touch \"$GRADUS_TEST_LAUNCHCTL_STATE\"
    if [[ \"${GRADUS_TEST_RUN_AT_LOAD_WRITES:-yes}\" == yes ]]; then
      count=0
      if [[ -f \"$GRADUS_TEST_RUN_AT_LOAD_COUNTER\" ]]; then
        count=\"$(<\"$GRADUS_TEST_RUN_AT_LOAD_COUNTER\")\"
      fi
      count=$((count + 1))
      printf '%s\\n' \"$count\" > \"$GRADUS_TEST_RUN_AT_LOAD_COUNTER\"
      mkdir -p \"$(dirname \"$GRADUS_TEST_SNAPSHOT_PATH\")\"
      printf '{\"updated_at\":\"2026-08-08T14:28:%02d+00:00\"}\\n' \"$count\" > \"$GRADUS_TEST_SNAPSHOT_PATH\"
      printf '%s\\n' run-at-load-snapshot >> \"$GRADUS_TEST_EVENT_LOG\"
    fi
    ;;
  bootout) printf '%s\\n' bootout >> \"$GRADUS_TEST_EVENT_LOG\"; rm -f \"$GRADUS_TEST_LAUNCHCTL_STATE\"; touch \"$GRADUS_TEST_BOOTOUT_MARKER\" ;;
  *) exit 64 ;;
esac
""",
        )
        self._write_executable(
            "python3",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' \"$*\" >> \"$GRADUS_TEST_PYTHON_LOG\"
if [[ \"${1:-}\" == \"-\" ]]; then
  test -f \"${2:?snapshot path is required}\" || exit 1
  tr -cd '0-9' < \"$2\"
  exit 0
fi
if [[ \" $* \" == *\" --verify-refresh-health \"* ]]; then
  printf '%s\\n' verify >> \"$GRADUS_TEST_EVENT_LOG\"
else
  printf '%s\\n' initial-refresh >> \"$GRADUS_TEST_EVENT_LOG\"
fi
sleep \"${GRADUS_TEST_PYTHON_SLEEP:-0}\"
if [[ \" $* \" == *\" --verify-refresh-health \"* ]]; then
  exit \"${GRADUS_TEST_VERIFY_EXIT:-0}\"
fi
""",
        )
        self._write_executable(
            "credential-bridge",
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$GRADUS_TEST_BRIDGE_LOG"
if [[ -n "${GRADUS_TEST_BRIDGE_STDOUT:-}" ]]; then
  printf '%s\\n' "$GRADUS_TEST_BRIDGE_STDOUT"
fi
if [[ -n "${GRADUS_TEST_BRIDGE_STDERR:-}" ]]; then
  printf '%s\\n' "$GRADUS_TEST_BRIDGE_STDERR" >&2
fi
exit "${GRADUS_TEST_BRIDGE_EXIT:-0}"
""",
        )
        self._write_executable(
            "deadline-runner",
            """#!/usr/bin/env bash
set -euo pipefail
while (($#)); do
  if [[ "$1" == "--" ]]; then
    shift
    exec "$@"
  fi
  shift
done
exit 64
""",
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_executable(self, name: str, content: str) -> None:
        path = self.bin_dir / name
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)

    def _environment(
        self,
        *,
        verify_exit: int = 0,
        python_sleep: str = "0",
        print_mode: str = "normal",
    ) -> dict[str, str]:
        environment = os.environ.copy()
        environment.update(
            {
                "HOME": str(self.home),
                "GRADUS_HOME": str(self.home),
                "GRADUS_REPO_ROOT": str(REPO_ROOT),
                "GRADUS_PYTHON_PATH": str(self.bin_dir / "python3"),
                "GRADUS_LAUNCHCTL": str(self.bin_dir / "launchctl"),
                "GRADUS_TEST_LAUNCHCTL_STATE": str(self.state),
                "GRADUS_TEST_LAUNCHCTL_LOG": str(self.launchctl_log),
                "GRADUS_TEST_EVENT_LOG": str(self.event_log),
                "GRADUS_TEST_BOOTOUT_MARKER": str(self.root / "bootout-marker"),
                "GRADUS_TEST_PYTHON_LOG": str(self.python_log),
                "GRADUS_TEST_BRIDGE_LOG": str(self.bridge_log),
                "GRADUS_DEADLINE_RUNNER": str(self.bin_dir / "deadline-runner"),
                "GRADUS_TEST_RUN_AT_LOAD_COUNTER": str(self.run_at_load_counter),
                "GRADUS_TEST_RUN_AT_LOAD_WRITES": "yes",
                "GRADUS_TEST_SNAPSHOT_PATH": str(self.snapshot_path),
                "GRADUS_SNAPSHOT_V2_PATH": str(self.snapshot_path),
                "GRADUS_TEST_VERIFY_EXIT": str(verify_exit),
                "GRADUS_TEST_PYTHON_SLEEP": python_sleep,
                "GRADUS_TEST_PRINT_MODE": print_mode,
                # The shell timeout loop uses Bash's integer SECONDS counter.
                # Keep the hermetic clock integral while still making each
                # installer run short enough for the unit suite.
                "GRADUS_VERIFY_DURATION": "1",
                "GRADUS_HEALTH_INTERVAL": "1",
                "GRADUS_PROGRESS_INTERVAL": "1",
            }
        )
        return environment

    def _run(
        self,
        command: str = "install",
        *,
        verify_exit: int = 0,
        python_sleep: str = "0",
        print_mode: str = "normal",
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(INSTALLER), command],
            cwd=REPO_ROOT,
            env=self._environment(
                verify_exit=verify_exit,
                python_sleep=python_sleep,
                print_mode=print_mode,
            ),
            text=True,
            capture_output=True,
            check=False,
        )

    def test_install_is_idempotent_in_files_and_launchctl_state(self) -> None:
        first = self._run()
        self.assertEqual(first.returncode, 0, first.stderr)
        wrapper = self.home / ".launchd/scripts/gradus_snapshot.sh"
        helper_dir = self.home / ".launchd/scripts/lib"
        plist = self.home / "Library/LaunchAgents/local.gradus-snapshot.plist"
        first_wrapper = wrapper.read_bytes()
        first_plist = plist.read_bytes()
        self.assertTrue(self.state.exists())
        self.assertTrue(wrapper.stat().st_mode & stat.S_IXUSR)
        self.assertEqual((helper_dir / "deadline_runner.py").stat().st_mode & 0o777, 0o755)
        self.assertEqual((helper_dir / "notify.sh").stat().st_mode & 0o777, 0o644)
        self.assertNotIn(b"__GRADUS_", first_wrapper + first_plist)

        second = self._run()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(wrapper.read_bytes(), first_wrapper)
        self.assertEqual(plist.read_bytes(), first_plist)
        self.assertTrue(self.state.exists())
        calls = self.launchctl_log.read_text(encoding="utf-8").splitlines()
        domain = f"gui/{os.getuid()}"
        self.assertEqual(calls.count(f"bootstrap {domain} {plist}"), 2)
        self.assertEqual(calls.count(f"bootout {domain}/local.gradus-snapshot"), 1)
        self.assertEqual(
            self.python_log.read_text(encoding="utf-8").count("--verify-refresh-health"), 2
        )

    def test_install_reports_progress_while_the_health_check_runs(self) -> None:
        result = self._run(python_sleep="1.1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("observed RunAtLoad snapshot metadata advance", result.stderr)
        self.assertIn("waiting 1s after RunAtLoad before health verification", result.stderr)
        self.assertIn("verifying refresh health for 1s is still running", result.stderr)

    def test_wrapper_uses_only_the_installed_credential_bridge(self) -> None:
        self.assertEqual(self._run().returncode, 0)
        wrapper = self.home / ".launchd/scripts/gradus_snapshot.sh"
        rendered = wrapper.read_text(encoding="utf-8")
        self.assertIn("GRADUS_CREDENTIAL_BRIDGE", rendered)
        self.assertIn("credential bridge status=failed", rendered)
        self.assertNotIn("Cookies.binarycookies", rendered)
        environment = self._environment()
        isolated_repo = self.root / "repo"
        isolated_repo.mkdir()
        environment["GRADUS_REPO_ROOT"] = str(isolated_repo)
        environment["GRADUS_CREDENTIAL_BRIDGE"] = str(self.bin_dir / "credential-bridge")
        result = subprocess.run(
            ["bash", str(wrapper)],
            cwd=REPO_ROOT,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.home / "Library/Logs/homelab/gradus-snapshot/gradus-snapshot.log"
        self.assertIn("credential bridge status=degraded", log.read_text(encoding="utf-8"))
        self.assertEqual(
            self.bridge_log.read_text(encoding="utf-8").strip(),
            f"--cache-directory {isolated_repo / '.cache'}",
        )
        self.assertIn("--refresh-snapshot", self.python_log.read_text(encoding="utf-8"))

    def test_wrapper_continues_with_static_status_when_bridge_fails(self) -> None:
        self.assertEqual(self._run().returncode, 0)
        wrapper = self.home / ".launchd/scripts/gradus_snapshot.sh"
        environment = self._environment()
        environment["GRADUS_CREDENTIAL_BRIDGE"] = str(self.bin_dir / "credential-bridge")
        environment["GRADUS_TEST_BRIDGE_EXIT"] = "1"
        result = subprocess.run(
            ["bash", str(wrapper)],
            cwd=REPO_ROOT,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.home / "Library/Logs/homelab/gradus-snapshot/gradus-snapshot.log"
        self.assertIn("credential bridge status=failed", log.read_text(encoding="utf-8"))
        self.assertIn("--refresh-snapshot", self.python_log.read_text(encoding="utf-8"))

    def test_wrapper_reports_missing_browser_caches_without_reading_safari(self) -> None:
        environment = self._environment()
        isolated_repo = self.root / "repo"
        isolated_repo.mkdir()
        environment["GRADUS_REPO_ROOT"] = str(isolated_repo)
        environment["GRADUS_SNAPSHOT_V2_PATH"] = str(self.snapshot_path)
        installed = subprocess.run(
            ["bash", str(INSTALLER), "install"],
            cwd=REPO_ROOT,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(installed.returncode, 0, installed.stderr)
        wrapper = self.home / ".launchd/scripts/gradus_snapshot.sh"
        environment["GRADUS_CREDENTIAL_BRIDGE"] = str(self.bin_dir / "credential-bridge")
        result = subprocess.run(
            ["bash", str(wrapper)],
            cwd=REPO_ROOT,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.home / "Library/Logs/homelab/gradus-snapshot/gradus-snapshot.log"
        self.assertIn(
            "credential bridge status=degraded; missing cache providers=Claude OpenCode Go.",
            log.read_text(encoding="utf-8"),
        )
        self.assertNotIn("Cookies.binarycookies", wrapper.read_text(encoding="utf-8"))

    def test_wrapper_discards_bridge_payload_and_reports_present_caches_healthy(self) -> None:
        environment = self._environment()
        isolated_repo = self.root / "repo"
        cache = isolated_repo / ".cache"
        cache.mkdir(parents=True)
        (cache / "claude_cookies.json").touch()
        (cache / "opencode_go_cookies.json").touch()
        environment["GRADUS_REPO_ROOT"] = str(isolated_repo)
        environment["GRADUS_CREDENTIAL_BRIDGE"] = str(self.bin_dir / "credential-bridge")
        environment["GRADUS_TEST_BRIDGE_STDOUT"] = "credential-payload-must-not-escape"
        environment["GRADUS_TEST_BRIDGE_STDERR"] = "bridge-diagnostic-must-not-escape"

        installed = subprocess.run(
            ["bash", str(INSTALLER), "install"],
            cwd=REPO_ROOT,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(installed.returncode, 0, installed.stderr)
        wrapper = self.home / ".launchd/scripts/gradus_snapshot.sh"
        result = subprocess.run(
            ["bash", str(wrapper)],
            cwd=REPO_ROOT,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        output = result.stdout + result.stderr
        log = (self.home / "Library/Logs/homelab/gradus-snapshot/gradus-snapshot.log").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("credential-payload-must-not-escape", output + log)
        self.assertNotIn("bridge-diagnostic-must-not-escape", output + log)
        self.assertIn("credential bridge status=ok", log)

    def test_fresh_install_waits_for_run_at_load_before_verifying(self) -> None:
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        events = self.event_log.read_text(encoding="utf-8").splitlines()
        self.assertLess(events.index("bootstrap"), events.index("run-at-load-snapshot"))
        self.assertLess(events.index("run-at-load-snapshot"), events.index("verify"))

    def test_install_fails_closed_when_run_at_load_does_not_advance_snapshot(self) -> None:
        environment = self._environment()
        environment["GRADUS_TEST_RUN_AT_LOAD_WRITES"] = "no"
        environment["GRADUS_RUN_AT_LOAD_TIMEOUT"] = "1"
        result = subprocess.run(
            ["bash", str(INSTALLER), "install"],
            cwd=REPO_ROOT,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("RunAtLoad did not advance snapshot metadata", result.stderr)
        self.assertNotIn("verify", self.event_log.read_text(encoding="utf-8"))

    def test_uninstall_fails_closed_when_launchctl_state_cannot_be_read(self) -> None:
        self.assertEqual(self._run().returncode, 0)
        result = self._run("uninstall", print_mode="error")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not query launchctl state", result.stderr)
        self.assertTrue(self.state.exists())
        self.assertTrue((self.home / ".launchd/scripts/gradus_snapshot.sh").exists())

    def test_uninstall_fails_closed_when_post_bootout_state_cannot_be_read(self) -> None:
        self.assertEqual(self._run().returncode, 0)
        result = self._run("uninstall", print_mode="error_after_bootout")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not query launchctl state", result.stderr)
        self.assertTrue((self.home / ".launchd/scripts/gradus_snapshot.sh").exists())
        self.assertTrue((self.home / "Library/LaunchAgents/local.gradus-snapshot.plist").exists())

    def test_install_fails_when_refresh_health_rejects_the_sample(self) -> None:
        result = self._run(verify_exit=1)
        self.assertEqual(result.returncode, 1)
        self.assertIn("refresh-health verification failed", result.stderr)
        self.assertTrue(self.state.exists())

    def test_uninstall_removes_files_and_boots_out_the_job(self) -> None:
        self.assertEqual(self._run().returncode, 0)
        result = self._run("uninstall")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.state.exists())
        self.assertFalse((self.home / ".launchd/scripts/gradus_snapshot.sh").exists())
        self.assertFalse((self.home / "Library/LaunchAgents/local.gradus-snapshot.plist").exists())
        self.assertTrue((self.home / ".launchd/scripts/lib/deadline_runner.py").exists())
        self.assertTrue((self.home / ".launchd/scripts/lib/notify.sh").exists())


if __name__ == "__main__":
    unittest.main()
