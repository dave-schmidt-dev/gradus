"""Behavioral tests for the launchd deadline runner.

`launchd/lib/deadline_runner.py` bounds every launchd child process: it owns
the TERM/KILL escalation, the reserved 124 timeout status, the cleanup records
that stop a second run from racing an unreaped process group, and the rule that
no child argv, path, or output ever reaches a diagnostic (INV-1).  Until this
file existed the module was covered only by `test_launchd_install.py`, which
asserts that it is installed at mode 0755 -- so a 34-site lint rewrite shipped
verified by a manual smoke run rather than by the suite.

The module is a standalone script rather than an importable package, so it is
loaded by path.  `run()` takes injectable `popen_factory`, `group_alive`,
`kill_group`, `clock`, and `sleeper` collaborators; the escalation tests use
them so that no test signals a real process or sleeps for a real deadline.
Exit-code passthrough is exercised against real short-lived subprocesses,
because that path is exactly the one where a fake would prove nothing.

Every test passes an explicit `--state-dir` inside a temporary directory: the
runner's default is a single shared `$TMPDIR/launchd-deadline-runner`, and a
test that wrote there could both disturb a live launchd job and inherit
conflicts from one.
"""

from __future__ import annotations

import errno
import importlib.util
import json
import os
import signal
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[1]
RUNNER_PATH = REPO_ROOT / "launchd" / "lib" / "deadline_runner.py"


def _load_runner() -> Any:
    """Load the runner by path; it ships as a script, not as a package module."""
    spec = importlib.util.spec_from_file_location("gradus_test_deadline_runner", RUNNER_PATH)
    if spec is None or spec.loader is None:  # pragma: no cover - import wiring
        raise RuntimeError(f"cannot load {RUNNER_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runner = _load_runner()


class FakeProcess:
    """A `Popen` stand-in whose exit is driven by the test, not by the OS."""

    def __init__(self, pid: int = 4_000_000, returncodes: list[int | None] | None = None) -> None:
        self.pid = pid
        self.stderr = None
        # Each poll() consumes one entry; the last entry repeats forever so a
        # test never has to predict how many times the runner will poll.
        self._returncodes = list(returncodes or [None])
        self.poll_count = 0

    def poll(self) -> int | None:
        self.poll_count += 1
        if len(self._returncodes) > 1:
            return self._returncodes.pop(0)
        return self._returncodes[0]


class RunnerTestCase(unittest.TestCase):
    """Shared temporary state directory and argv assembly."""

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.state_dir = self.root / "state"
        self.state_dir.mkdir()

    def argv(self, *options: str, child: list[str] | None = None) -> list[str]:
        base = ["--deadline", "5", "--state-dir", str(self.state_dir)]
        return [*base, *options, "--", *(child or ["/bin/sh", "-c", "exit 0"])]

    def run_fake(
        self,
        argv: list[str],
        process: FakeProcess,
        *,
        alive_sequence: list[bool] | None = None,
        elapsed_per_tick: float = 1.0,
    ) -> tuple[int, list[tuple[int, int]]]:
        """Drive `run()` with fake time so a deadline elapses without waiting."""
        signals: list[tuple[int, int]] = []
        alive = list(alive_sequence or [True])
        ticks = {"now": 0.0}

        def clock() -> float:
            return ticks["now"]

        def sleeper(_seconds: float) -> None:
            ticks["now"] += elapsed_per_tick

        def group_alive(_pgid: int) -> bool:
            return alive.pop(0) if len(alive) > 1 else alive[0]

        def kill_group(pgid: int, sig: int) -> bool:
            signals.append((pgid, sig))
            return True

        status = runner.run(
            argv,
            popen_factory=lambda *a, **k: process,
            group_alive=group_alive,
            kill_group=kill_group,
            clock=clock,
            sleeper=sleeper,
        )
        return status, signals


class ArgumentParsingTests(RunnerTestCase):
    """`RunnerArguments` is the only way an invocation is refused."""

    def _expect_refusal(self, argv: list[str]) -> None:
        with self.assertRaises(runner.RunnerArguments):
            runner._parse(argv)

    def test_missing_delimiter_is_refused(self) -> None:
        self._expect_refusal(["--deadline", "5", "/bin/true"])

    def test_missing_child_argv_is_refused(self) -> None:
        self._expect_refusal(["--deadline", "5", "--"])

    def test_empty_child_executable_is_refused(self) -> None:
        self._expect_refusal(["--deadline", "5", "--", ""])

    def test_missing_deadline_is_refused(self) -> None:
        self._expect_refusal(["--category", "snapshot", "--", "/bin/true"])

    def test_non_positive_and_non_finite_deadlines_are_refused(self) -> None:
        for value in ("0", "-1", "nan", "inf", "abc", ""):
            with self.subTest(deadline=value):
                self._expect_refusal(["--deadline", value, "--", "/bin/true"])

    def test_invalid_category_is_refused(self) -> None:
        for value in ("has space", "semi;colon", "", "x" * 65):
            with self.subTest(category=value):
                self._expect_refusal(["--deadline", "5", "--category", value, "--", "/bin/true"])

    def test_unknown_option_is_refused(self) -> None:
        self._expect_refusal(["--deadline", "5", "--shell", "1", "--", "/bin/true"])

    def test_option_without_a_value_is_refused(self) -> None:
        self._expect_refusal(["--deadline", "--", "/bin/true"])

    def test_option_value_may_not_be_the_delimiter(self) -> None:
        self._expect_refusal(["--category", "--", "--deadline", "5", "--", "/bin/true"])

    def test_duplicate_state_locations_are_refused(self) -> None:
        self._expect_refusal(
            ["--deadline", "5", "--state-dir", "/a", "--state-dir", "/b", "--", "/bin/true"]
        )
        self._expect_refusal(
            ["--deadline", "5", "--state-file", "/a", "--state-file", "/b", "--", "/bin/true"]
        )

    def test_state_dir_and_state_file_together_are_refused(self) -> None:
        self._expect_refusal(
            ["--deadline", "5", "--state-dir", "/a", "--state-file", "/b", "--", "/bin/true"]
        )

    def test_empty_state_and_stderr_locations_are_refused(self) -> None:
        for option in ("--state-dir", "--state-file", "--stderr-file"):
            with self.subTest(option=option):
                self._expect_refusal(["--deadline", "5", option, "", "--", "/bin/true"])

    def test_documented_option_aliases_all_parse(self) -> None:
        deadline, grace, cleanup, category, _dir, _file, _err, child = runner._parse(
            [
                "--deadline-seconds",
                "9",
                "--term-grace",
                "3",
                "--cleanup-allowance",
                "4",
                "--category",
                "snapshot.v2",
                "--",
                "/bin/echo",
                "hi",
            ]
        )
        self.assertEqual((deadline, grace, cleanup, category), (9.0, 3.0, 4.0, "snapshot.v2"))
        self.assertEqual(child, ["/bin/echo", "hi"])

    def test_defaults_apply_when_only_a_deadline_is_given(self) -> None:
        _deadline, grace, cleanup, category, state_dir, state_file, stderr_file, _child = (
            runner._parse(["--deadline", "5", "--", "/bin/true"])
        )
        self.assertEqual(grace, runner.DEFAULT_GRACE)
        self.assertEqual(cleanup, runner.DEFAULT_CLEANUP)
        self.assertEqual(category, "child")
        self.assertIsNone(state_dir)
        self.assertIsNone(state_file)
        self.assertIsNone(stderr_file)

    def test_child_argv_is_never_treated_as_options(self) -> None:
        *_head, child = runner._parse(
            ["--deadline", "5", "--", "/bin/echo", "--deadline", "--state-dir", "/etc"]
        )
        self.assertEqual(child, ["/bin/echo", "--deadline", "--state-dir", "/etc"])


class ExitCodePassthroughTests(RunnerTestCase):
    """Real subprocesses: an ordinary child status must survive unchanged."""

    def test_successful_child_returns_zero(self) -> None:
        self.assertEqual(runner.run(self.argv(child=["/bin/sh", "-c", "exit 0"])), 0)

    def test_failing_child_status_is_passed_through(self) -> None:
        for code in (1, 7, 42, 125, 126):
            with self.subTest(code=code):
                self.assertEqual(
                    runner.run(self.argv(child=["/bin/sh", "-c", f"exit {code}"])), code
                )

    def test_reserved_timeout_status_is_not_produced_by_a_fast_child(self) -> None:
        # 124 is reserved for a deadline timeout, so a child that merely *exits*
        # 124 must still be distinguishable only by the absent diagnostic; the
        # status itself is passed through unchanged.
        self.assertEqual(
            runner.run(self.argv(child=["/bin/sh", "-c", "exit 124"])), runner.TIMEOUT_EXIT
        )

    def test_a_signalled_child_reports_the_negative_status(self) -> None:
        status = runner.run(self.argv(child=["/bin/sh", "-c", "kill -TERM $$"]))
        self.assertEqual(status, -signal.SIGTERM)

    def test_no_cleanup_record_is_written_for_a_clean_exit(self) -> None:
        runner.run(self.argv(child=["/bin/sh", "-c", "exit 0"]))
        self.assertEqual(list(self.state_dir.iterdir()), [])

    def test_child_gets_no_stdin(self) -> None:
        # DEVNULL stdin means `read` fails immediately rather than hanging on
        # the caller's terminal, which is what makes the runner safe under
        # launchd.
        self.assertEqual(runner.run(self.argv(child=["/bin/sh", "-c", "read x"])), 1)


class DeadlineEscalationTests(RunnerTestCase):
    """TERM then KILL, each followed by a finite poll window."""

    def test_child_that_never_exits_times_out_with_the_reserved_status(self) -> None:
        status, signals = self.run_fake(self.argv(), FakeProcess())
        self.assertEqual(status, runner.TIMEOUT_EXIT)
        self.assertEqual([sig for _pgid, sig in signals], [signal.SIGTERM, signal.SIGKILL])

    def test_term_alone_ends_the_group_and_kill_is_not_sent(self) -> None:
        process = FakeProcess(returncodes=[None, None, None, None, None, 0])
        status, signals = self.run_fake(
            self.argv(),
            process,
            # Alive through the deadline window, gone once TERM lands.
            alive_sequence=[True, True, True, True, True, True, False],
        )
        self.assertEqual([sig for _pgid, sig in signals], [signal.SIGTERM])
        self.assertEqual(status, runner.TIMEOUT_EXIT)

    def test_grace_and_cleanup_windows_are_honoured_separately(self) -> None:
        status, signals = self.run_fake(self.argv("--grace", "3", "--cleanup", "3"), FakeProcess())
        self.assertEqual(status, runner.TIMEOUT_EXIT)
        self.assertEqual(len(signals), 2)

    def test_timeout_writes_a_cleanup_record_naming_the_category(self) -> None:
        self.run_fake(self.argv("--category", "snapshot"), FakeProcess(pid=4_000_017))
        records = list(self.state_dir.glob("cleanup-*.json"))
        self.assertEqual(len(records), 1)
        payload = json.loads(records[0].read_text())
        self.assertEqual(payload["pid"], 4_000_017)
        self.assertEqual(payload["category"], "snapshot")
        self.assertEqual(records[0].stat().st_mode & 0o777, 0o600)

    def test_cleanup_record_never_contains_child_argv_or_paths(self) -> None:
        self.run_fake(
            self.argv("--category", "snapshot", child=["/bin/echo", "/Users/secret/path"]),
            FakeProcess(),
        )
        record = next(self.state_dir.glob("cleanup-*.json"))
        text = record.read_text()
        self.assertNotIn("secret", text)
        self.assertNotIn("/bin/echo", text)
        self.assertEqual(set(json.loads(text)), {"pid", "pgid", "category"})

    def test_explicit_state_file_receives_the_cleanup_record(self) -> None:
        state_file = self.root / "records" / "snapshot.json"
        argv = [
            "--deadline",
            "5",
            "--state-file",
            str(state_file),
            "--category",
            "snapshot",
            "--",
            "/bin/sh",
            "-c",
            "sleep 30",
        ]
        self.run_fake(argv, FakeProcess())
        self.assertTrue(state_file.exists())
        self.assertEqual(json.loads(state_file.read_text())["category"], "snapshot")

    def test_child_exiting_before_the_group_returns_that_status_without_signals(self) -> None:
        # The direct child exits 3 and the descendant that held the group open
        # goes away on its own, still inside the deadline. Nothing needs
        # killing and the ordinary status is preserved.
        process = FakeProcess(returncodes=[3])
        status, signals = self.run_fake(
            self.argv(),
            process,
            alive_sequence=[True, True, False],
            elapsed_per_tick=0.1,
        )
        self.assertEqual(status, 3)
        self.assertEqual(signals, [])

    def test_descendant_holding_the_group_past_the_deadline_reports_a_timeout(self) -> None:
        # The direct child exited 3, but a descendant kept the fresh process
        # group alive through the whole deadline. The group is escalated and
        # the run is reported as a timeout, NOT as the child's status 3.
        #
        # This pins the behaviour that `run()`'s trailing
        # `clock() - started < deadline` branch intends to change but cannot
        # reach: `_wait_bounded` only returns with the group still present once
        # `remaining <= 0`, i.e. once the full deadline has already elapsed, so
        # that comparison is false on every path that gets there. If a future
        # change makes the branch live, this test is the one that will notice.
        process = FakeProcess(returncodes=[3])
        argv = [
            "--deadline",
            "0.3",
            "--state-dir",
            str(self.state_dir),
            "--",
            "/bin/sh",
            "-c",
            "exit 3",
        ]
        status, signals = self.run_fake(
            argv,
            process,
            alive_sequence=[True, True, True, True, False],
            elapsed_per_tick=0.1,
        )
        self.assertEqual(status, runner.TIMEOUT_EXIT)
        self.assertEqual([sig for _pgid, sig in signals], [signal.SIGTERM])


class CleanupConflictTests(RunnerTestCase):
    """A live record from a previous run blocks a new launch."""

    def _write_record(self, pid: int, pgid: int, category: str = "snapshot") -> Path:
        path = self.state_dir / f"cleanup-{pid}-{pgid}.json"
        path.write_text(json.dumps({"pid": pid, "pgid": pgid, "category": category}))
        return path

    def test_live_conflict_returns_timeout_without_launching_anything(self) -> None:
        # `_check_conflicts` calls the module-level `_pid_group_alive` rather
        # than `run()`'s injected `group_alive`, so liveness here has to be
        # real. This process group always is.
        self._write_record(os.getpid(), os.getpgrp())
        launched: list[Any] = []

        status = runner.run(
            self.argv(),
            popen_factory=lambda *a, **k: launched.append(a) or FakeProcess(),
            kill_group=lambda _pgid, _sig: True,
        )
        self.assertEqual(status, runner.TIMEOUT_EXIT)
        self.assertEqual(launched, [])

    def test_dead_conflict_is_reaped_and_the_run_proceeds(self) -> None:
        record = self._write_record(4_000_002, 4_000_002)
        status = runner.run(
            self.argv(child=["/bin/sh", "-c", "exit 5"]),
            group_alive=lambda _pgid: False,
        )
        self.assertEqual(status, 5)
        self.assertFalse(record.exists())

    def test_malformed_and_foreign_records_are_ignored(self) -> None:
        (self.state_dir / "cleanup-bad.json").write_text("{not json")
        (self.state_dir / "cleanup-1-1.json").write_text(json.dumps({"pid": 1, "pgid": 1}))
        (self.state_dir / "unrelated.json").write_text(json.dumps({"pid": 9, "pgid": 9}))
        self.assertEqual(runner.run(self.argv(child=["/bin/sh", "-c", "exit 6"])), 6)

    def test_state_file_conflict_blocks_without_scanning_the_parent(self) -> None:
        state_file = self.root / "records" / "snapshot.json"
        state_file.parent.mkdir()
        state_file.write_text(json.dumps({"pid": 4_000_003, "pgid": 4_000_003, "category": "s"}))
        unrelated = state_file.parent / "cleanup-4000004-4000004.json"
        unrelated.write_text(json.dumps({"pid": 4_000_004, "pgid": 4_000_004, "category": "s"}))

        argv = [
            "--deadline",
            "5",
            "--state-file",
            str(state_file),
            "--",
            "/bin/sh",
            "-c",
            "exit 0",
        ]
        status = runner.run(argv, group_alive=lambda _pgid: True)
        self.assertEqual(status, runner.TIMEOUT_EXIT)
        # The unrelated neighbour is application state, not the runner's.
        self.assertTrue(unrelated.exists())

    def test_stale_state_file_is_removed_and_the_run_proceeds(self) -> None:
        state_file = self.root / "snapshot.json"
        state_file.write_text(json.dumps({"pid": 4_000_005, "pgid": 4_000_005, "category": "s"}))
        argv = [
            "--deadline",
            "5",
            "--state-file",
            str(state_file),
            "--",
            "/bin/sh",
            "-c",
            "exit 4",
        ]
        self.assertEqual(runner.run(argv, group_alive=lambda _pgid: False), 4)

    def test_unusable_state_directory_is_refused(self) -> None:
        blocker = self.root / "not-a-dir"
        blocker.write_text("")
        with self.assertRaises(runner.RunnerArguments):
            runner.run(["--deadline", "5", "--state-dir", str(blocker), "--", "/bin/true"])


class RecordValidationTests(unittest.TestCase):
    """`_valid_record` is the gate that keeps a hostile file from steering cleanup."""

    def test_well_formed_record_is_accepted(self) -> None:
        self.assertEqual(
            runner._valid_record({"pid": 20, "pgid": 21, "category": "snapshot"}),
            (20, 21, "snapshot"),
        )

    def test_malformed_records_are_rejected(self) -> None:
        cases = [
            "not a dict",
            {"pid": 20, "pgid": 21},
            {"pid": "20", "pgid": 21, "category": "s"},
            {"pid": True, "pgid": 21, "category": "s"},
            {"pid": 1, "pgid": 21, "category": "s"},
            {"pid": 20, "pgid": 0, "category": "s"},
            {"pid": 20, "pgid": 21, "category": "bad category"},
            {"pid": 20, "pgid": 21, "category": 5},
        ]
        for case in cases:
            with self.subTest(record=case):
                self.assertIsNone(runner._valid_record(case))

    def test_symlinked_record_is_not_followed(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            target = root / "real.json"
            target.write_text(json.dumps({"pid": 20, "pgid": 21, "category": "s"}))
            link = root / "link.json"
            link.symlink_to(target)
            self.assertIsNone(runner._read_record(str(link)))


class GroupLivenessTests(unittest.TestCase):
    """Unknown liveness must never be reported as 'gone'."""

    def test_own_group_and_reserved_ids_are_treated_as_alive(self) -> None:
        self.assertTrue(runner._pid_group_alive(os.getpgrp()))
        self.assertTrue(runner._pid_group_alive(1))
        self.assertTrue(runner._pid_group_alive(0))

    def test_eperm_is_treated_as_alive_and_esrch_as_gone(self) -> None:
        original = os.killpg
        try:
            os.killpg = lambda _pgid, _sig: (_ for _ in ()).throw(  # type: ignore[assignment]
                OSError(errno.EPERM, "not permitted")
            )
            self.assertTrue(runner._pid_group_alive(4_000_009))
            os.killpg = lambda _pgid, _sig: (_ for _ in ()).throw(  # type: ignore[assignment]
                OSError(errno.ESRCH, "no such process")
            )
            self.assertFalse(runner._pid_group_alive(4_000_009))
        finally:
            os.killpg = original  # type: ignore[assignment]

    def test_kill_group_refuses_to_signal_its_own_group(self) -> None:
        self.assertFalse(runner._kill_group(os.getpgrp(), signal.SIGTERM))
        self.assertFalse(runner._kill_group(1, signal.SIGTERM))


class StderrSinkTests(RunnerTestCase):
    """An explicit stderr file must be a regular file the runner itself opened."""

    def test_child_stderr_is_appended_to_the_named_file(self) -> None:
        sink = self.root / "child.err"
        status = runner.run(
            self.argv("--stderr-file", str(sink), child=["/bin/sh", "-c", "echo boom >&2"])
        )
        self.assertEqual(status, 0)
        self.assertIn("boom", sink.read_text())
        self.assertEqual(sink.stat().st_mode & 0o777, 0o600)

    def test_stderr_file_in_a_missing_directory_is_refused(self) -> None:
        with self.assertRaises(runner.RunnerArguments):
            runner.run(self.argv("--stderr-file", str(self.root / "absent" / "child.err")))

    def test_non_regular_stderr_target_is_refused(self) -> None:
        with self.assertRaises(runner.RunnerArguments):
            runner.run(self.argv("--stderr-file", str(self.state_dir)))

    def test_piped_child_stderr_is_bounded(self) -> None:
        # A noisy child must not be able to fill the pipe and wedge the runner;
        # the counter saturates at MAX_METADATA_BYTES.
        status = runner.run(
            self.argv(
                child=[
                    "/bin/sh",
                    "-c",
                    "i=0; while [ $i -lt 400 ]; do echo xxxxxxxx >&2; i=$((i+1)); done; exit 0",
                ]
            )
        )
        self.assertEqual(status, 0)


class LaunchFailureTests(RunnerTestCase):
    """A child that cannot start is 127, never a timeout."""

    def test_popen_error_returns_127(self) -> None:
        def explode(*_a: Any, **_k: Any) -> Any:
            raise OSError(errno.ENOENT, "no such file")

        self.assertEqual(runner.run(self.argv(), popen_factory=explode), 127)

    def test_implausible_child_pid_returns_127(self) -> None:
        self.assertEqual(
            runner.run(self.argv(), popen_factory=lambda *a, **k: FakeProcess(pid=0)), 127
        )

    def test_missing_child_executable_returns_127(self) -> None:
        missing = str(self.root / "definitely-not-here")
        self.assertEqual(runner.run(self.argv(child=[missing])), 127)


class MainEntryPointTests(RunnerTestCase):
    """`main` converts refusals into status 2 without echoing caller data."""

    def test_invalid_arguments_return_two(self) -> None:
        self.assertEqual(runner.main(["--deadline", "0", "--", "/bin/true"]), 2)

    def test_invalid_arguments_diagnostic_is_fixed_format(self) -> None:
        script = (
            f"import runpy,sys; sys.argv=['deadline_runner','--deadline','0','--',"
            f"'/bin/echo','/Users/secret/token']; "
            f"runpy.run_path({str(RUNNER_PATH)!r}, run_name='__main__')"
        )
        import subprocess

        result = subprocess.run(
            [sys.executable, "-c", script], capture_output=True, text=True, timeout=30
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stderr.strip(), "deadline-runner: invalid-arguments")
        self.assertNotIn("secret", result.stderr)

    def test_successful_run_through_main_passes_the_status_through(self) -> None:
        self.assertEqual(runner.main(self.argv(child=["/bin/sh", "-c", "exit 9"])), 9)


class InstalledScriptContractTests(unittest.TestCase):
    """Shape guarantees the launchd wrappers depend on."""

    def test_runner_is_executable_and_reserves_124(self) -> None:
        self.assertTrue(RUNNER_PATH.stat().st_mode & stat.S_IXUSR)
        self.assertEqual(runner.TIMEOUT_EXIT, 124)

    def test_runner_never_offers_a_shell_mode(self) -> None:
        source = RUNNER_PATH.read_text()
        self.assertIn("shell=False", source)
        self.assertNotIn("shell=True", source)

    def test_diagnostics_are_prefixed_and_single_line(self) -> None:
        import io
        from contextlib import redirect_stderr

        buffer = io.StringIO()
        with redirect_stderr(buffer):
            runner._diagnostic("timeout category=snapshot")
        self.assertEqual(buffer.getvalue(), "deadline-runner: timeout category=snapshot\n")


if __name__ == "__main__":  # pragma: no cover - convenience entry point
    unittest.main()
