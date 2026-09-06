"""Publisher-watchdog trigger-matrix tests.

The watchdog is the only Gradus code path that can spawn a GUI application, so
every test here either passes ``launch=False`` or patches ``subprocess.run``.
None of them may start a real publisher.
"""

from __future__ import annotations

import json
import subprocess
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest.mock import patch

from gradus import publisher_watchdog as wd

NOW = 1_800_000_000.0


def _iso(seconds_ago: float) -> str:
    return datetime.fromtimestamp(NOW - seconds_ago, tz=timezone.utc).isoformat()


class PublisherWatchdogTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.root = Path(self._tmp.name)
        self.snapshot = self.root / "snapshot-v2.json"
        self.evidence = self.root / "publish-evidence.json"
        self.state = self.root / ".publisher-watchdog.json"
        self.app = self.root / "Gradus.app"
        self.app.mkdir()
        self.executable = self.app / "Contents" / "MacOS" / "Gradus"

    def _write(self, snapshot_age: float | None, publish_age: float | None) -> None:
        if snapshot_age is not None:
            self.snapshot.write_text(json.dumps({"updated_at": _iso(snapshot_age)}))
        if publish_age is not None:
            self.evidence.write_text(json.dumps({"publishedAt": _iso(publish_age)}))

    def _evaluate(self, *, running: bool, launch: bool = False) -> wd.WatchdogDecision:
        with patch.object(wd, "_publisher_is_running", return_value=running):
            return wd.evaluate(
                now=NOW,
                snapshot_path=self.snapshot,
                evidence_path=self.evidence,
                app_path=self.app,
                executable_path=self.executable,
                state_path=self.state,
                launch=launch,
            )

    # --- the quiet cases: nothing is wrong, nothing is said -------------------

    def test_fresh_snapshot_and_recent_publish_is_quiet(self) -> None:
        self._write(snapshot_age=30, publish_age=30)
        decision = self._evaluate(running=True)
        self.assertEqual(decision.action, "healthy")
        self.assertTrue(decision.is_quiet)

    def test_stale_snapshot_is_the_producers_problem_not_the_watchdogs(self) -> None:
        """A behind producer means the publisher correctly has nothing to publish."""
        self._write(snapshot_age=4000, publish_age=4000)
        decision = self._evaluate(running=False)
        self.assertEqual(decision.action, "snapshot_stale")
        self.assertTrue(decision.is_quiet)

    def test_publish_lag_inside_tolerance_absorbs_a_scheduling_wobble(self) -> None:
        self._write(snapshot_age=10, publish_age=wd.PUBLISH_LAG_SECONDS - 1)
        self.assertEqual(self._evaluate(running=True).action, "healthy")

    # --- the acting case ------------------------------------------------------

    def test_absent_publisher_behind_a_fresh_snapshot_is_relaunched(self) -> None:
        self._write(snapshot_age=10, publish_age=3600)
        with (
            patch.object(wd, "_publisher_is_running", return_value=False),
            patch.object(wd, "subprocess") as sub,
        ):
            sub.run.return_value = SimpleNamespace(returncode=0, stdout="", stderr="")
            decision = wd.evaluate(
                now=NOW,
                snapshot_path=self.snapshot,
                evidence_path=self.evidence,
                app_path=self.app,
                executable_path=self.executable,
                state_path=self.state,
                launch=True,
            )
        self.assertEqual(decision.action, "relaunched")
        self.assertIn("relaunched", decision.message)
        argv = sub.run.call_args.args[0]
        self.assertEqual(argv[:2], ["/usr/bin/open", "-g"])
        self.assertEqual(argv[2], str(self.app))

    def test_relaunch_targets_an_absolute_path_never_a_bundle_identifier(self) -> None:
        """Two installed bundles share com.zerodelta.gradus.mac; only one can publish."""
        self.assertTrue(wd.PUBLISHER_APP.is_absolute())
        self.assertTrue(str(wd.PUBLISHER_EXECUTABLE).startswith(str(wd.PUBLISHER_APP)))
        # The shipped product is Gradus.app. Pointing here at the pre-rename
        # GradusMac.app kept a stale 1.10.0 publisher alive beside the installed
        # one (2026-09-06), so the target is locked to the current product.
        self.assertEqual(wd.PUBLISHER_APP, Path("/Applications/Gradus.app"))
        self.assertEqual(wd.PUBLISHER_EXECUTABLE.name, "Gradus")
        with patch.object(wd.subprocess, "run") as run:
            run.return_value = SimpleNamespace(returncode=0, stdout="", stderr="")
            wd._launch(self.app)
        argv = run.call_args.args[0]
        self.assertNotIn("-b", argv)
        self.assertNotIn("-a", argv)
        self.assertIn(str(self.app), argv)
        self.assertTrue(Path(argv[-1]).is_absolute())

    def test_missing_evidence_against_a_fresh_snapshot_counts_as_never_published(self) -> None:
        self._write(snapshot_age=10, publish_age=None)
        decision = self._evaluate(running=False)
        self.assertEqual(decision.action, "would_relaunch")
        self.assertIn("never", decision.message)

    def test_unparseable_evidence_counts_as_lagging(self) -> None:
        self._write(snapshot_age=10, publish_age=None)
        self.evidence.write_text("{ not json")
        self.assertEqual(self._evaluate(running=False).action, "would_relaunch")

    # --- the cases a relaunch cannot fix --------------------------------------

    def test_running_but_stale_publisher_is_reported_and_left_alone(self) -> None:
        """A live process that is not publishing is wedged or CloudKit is down."""
        self._write(snapshot_age=10, publish_age=3600)
        decision = self._evaluate(running=True, launch=True)
        self.assertEqual(decision.action, "running_but_stale")
        self.assertIn("Not relaunching", decision.message)
        self.assertFalse(self.state.exists())

    def test_crash_loop_is_throttled_and_stays_visible(self) -> None:
        self._write(snapshot_age=10, publish_age=3600)
        self.state.write_text(json.dumps({"relaunched_at": [NOW - 60, NOW - 600, NOW - 1200]}))
        decision = self._evaluate(running=False, launch=True)
        self.assertEqual(decision.action, "throttled")
        self.assertIn("crash loop", decision.message)

    def test_relaunches_older_than_an_hour_do_not_count_toward_the_throttle(self) -> None:
        self._write(snapshot_age=10, publish_age=3600)
        self.state.write_text(json.dumps({"relaunched_at": [NOW - 4000, NOW - 5000, NOW - 6000]}))
        self.assertEqual(self._evaluate(running=False).action, "would_relaunch")

    def test_missing_app_bundle_is_reported_rather_than_launched(self) -> None:
        self._write(snapshot_age=10, publish_age=3600)
        decision = wd.evaluate(
            now=NOW,
            snapshot_path=self.snapshot,
            evidence_path=self.evidence,
            app_path=self.root / "Absent.app",
            executable_path=self.executable,
            state_path=self.state,
            launch=True,
        )
        self.assertEqual(decision.action, "app_missing")

    def test_failed_launch_is_reported_and_not_recorded_as_a_relaunch(self) -> None:
        self._write(snapshot_age=10, publish_age=3600)
        with (
            patch.object(wd, "_publisher_is_running", return_value=False),
            patch.object(wd, "subprocess") as sub,
        ):
            sub.run.return_value = SimpleNamespace(returncode=1, stdout="", stderr="")
            decision = wd.evaluate(
                now=NOW,
                snapshot_path=self.snapshot,
                evidence_path=self.evidence,
                app_path=self.app,
                executable_path=self.executable,
                state_path=self.state,
                launch=True,
            )
        self.assertEqual(decision.action, "launch_failed")
        self.assertFalse(self.state.exists())

    def test_unreadable_snapshot_is_reported_without_launching(self) -> None:
        decision = self._evaluate(running=False, launch=True)
        self.assertEqual(decision.action, "snapshot_unreadable")
        self.assertFalse(decision.is_quiet)

    # --- liveness detection ---------------------------------------------------

    def test_liveness_matches_the_exact_executable_path(self) -> None:
        """A DerivedData or stub build of the same app must not read as healthy."""
        with patch.object(wd.subprocess, "run") as run:
            run.return_value = SimpleNamespace(returncode=0, stdout="123\n", stderr="")
            self.assertTrue(wd._publisher_is_running(Path("/Applications/X.app/C/M/X")))
        pattern = run.call_args.args[0][-1]
        self.assertTrue(pattern.startswith("^") and pattern.endswith("$"))
        self.assertIn("/Applications/X.app/C/M/X", pattern)

    def test_unknown_liveness_does_not_authorize_a_launch(self) -> None:
        for failure in (OSError("boom"), subprocess.TimeoutExpired(["pgrep"], timeout=10)):
            with (
                self.subTest(failure=type(failure).__name__),
                patch.object(wd.subprocess, "run", side_effect=failure),
            ):
                self.assertTrue(wd._publisher_is_running(Path("/Applications/X")))

    # --- the producer's contract with this module -----------------------------

    def test_watchdog_is_opt_in_and_disableable(self) -> None:
        with (
            patch.dict("os.environ", {"GRADUS_DISABLE_PUBLISHER_WATCHDOG": "1"}),
            patch.object(wd, "evaluate") as evaluate,
        ):
            self.assertEqual(wd.main(), 0)
        evaluate.assert_not_called()

    def test_main_is_quiet_and_zero_when_healthy(self) -> None:
        with (
            patch.object(wd, "evaluate", return_value=wd.WatchdogDecision("healthy", "")),
            patch("builtins.print") as printed,
        ):
            self.assertEqual(wd.main(), 0)
        printed.assert_not_called()

    def test_main_reports_nonzero_only_when_it_could_not_act(self) -> None:
        for action, expected in (
            ("relaunched", 0),
            ("running_but_stale", 0),
            ("throttled", 0),
            ("launch_failed", 1),
            ("app_missing", 1),
        ):
            with (
                self.subTest(action=action),
                patch.object(
                    wd, "evaluate", return_value=wd.WatchdogDecision(action, "said something")
                ),
                patch("builtins.print") as printed,
            ):
                self.assertEqual(wd.main(), expected)
            printed.assert_called_once()

    def test_real_defaults_point_at_the_paths_the_publisher_actually_uses(self) -> None:
        self.assertEqual(wd.PUBLISHER_SNAPSHOT.name, "snapshot-v2.json")
        self.assertEqual(wd.PUBLISHER_EVIDENCE.name, "publish-evidence.json")
        self.assertEqual(wd.PUBLISHER_EVIDENCE.parent, wd.PUBLISHER_SNAPSHOT.parent)
        self.assertIn("Application Support/Gradus/Installed", str(wd.PUBLISHER_SNAPSHOT))
        # The bare `Gradus/snapshot-v2.json` is the legacy rollback mirror.
        self.assertNotEqual(wd.PUBLISHER_SNAPSHOT.parent.name, "Gradus")

    def test_evaluate_defaults_to_wall_clock(self) -> None:
        """Omitting `now` must read the real clock, not leave the comparison unanchored."""
        real_now = datetime.now(timezone.utc)
        self.snapshot.write_text(json.dumps({"updated_at": real_now.isoformat()}))
        self.evidence.write_text(
            json.dumps({"publishedAt": (real_now - timedelta(seconds=5)).isoformat()})
        )
        with patch.object(wd, "_publisher_is_running", return_value=True):
            fresh = wd.evaluate(
                snapshot_path=self.snapshot,
                evidence_path=self.evidence,
                app_path=self.app,
                executable_path=self.executable,
                state_path=self.state,
                launch=False,
            )
        self.assertEqual(fresh.action, "healthy")

        old = real_now - timedelta(seconds=wd.SNAPSHOT_FRESH_SECONDS + 60)
        self.snapshot.write_text(json.dumps({"updated_at": old.isoformat()}))
        with patch.object(wd, "_publisher_is_running", return_value=False):
            stale = wd.evaluate(
                snapshot_path=self.snapshot,
                evidence_path=self.evidence,
                app_path=self.app,
                executable_path=self.executable,
                state_path=self.state,
                launch=False,
            )
        self.assertEqual(stale.action, "snapshot_stale")


if __name__ == "__main__":
    unittest.main()
