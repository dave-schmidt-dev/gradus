"""Fake-Security lineage and bounded helper checks; no live item operations."""

import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from gradus import banked_keychain as banked

_REAL_HELPER_COMMAND = banked._helper_command


class FakeSecurity:
    def __init__(self, denied=False, failed=False):
        self.denied = denied
        self.failed = failed
        self.calls = []

    def get_or_create(self, service, *, attended):
        self.calls.append((service, attended))
        if self.denied:
            raise banked.BankedAccessDenied("synthetic denial secret")
        if self.failed:
            raise RuntimeError("synthetic transient secret")
        return b"k" * 32


class BankedKeychainTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "banked-identity-v1.json"
        patcher = patch.object(banked, "_cache_path", return_value=self.path)
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_helper(self, user="user-one", account=None, adapter=None):
        stdin = io.TextIOWrapper(
            io.BytesIO(json.dumps({"user_id": user, "account_id": account}).encode())
        )
        stdout = io.StringIO()
        with patch.object(banked.sys, "stdin", stdin), patch.object(banked.sys, "stdout", stdout):
            code = banked.helper_main(adapter=adapter or FakeSecurity())
        return code, json.loads(stdout.getvalue())

    def test_identity_rotation_and_optional_account(self):
        fake = FakeSecurity()
        _, first = self.run_helper(adapter=fake)
        _, repeat = self.run_helper(adapter=fake)
        _, account = self.run_helper(account="account-a", adapter=fake)
        _, changed_user = self.run_helper(user="user-two", adapter=fake)
        self.assertEqual(first["generation"], repeat["generation"])
        self.assertNotEqual(first["generation"], account["generation"])
        self.assertNotEqual(account["generation"], changed_user["generation"])
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)
        private = self.path.read_text()
        self.assertNotIn("user-one", private)
        self.assertNotIn("account-a", private)
        self.assertNotIn("kkkk", private)
        self.assertEqual(len(fake.calls), 4)
        self.assertTrue(all(not attended for _, attended in fake.calls))

    def test_denial_is_type_only(self):
        code, result = self.run_helper(adapter=FakeSecurity(denied=True))
        self.assertEqual(code, 1)
        self.assertEqual(result, {"status": "denied"})

    def test_transient_helper_failure_is_typed_separately(self):
        code, result = self.run_helper(adapter=FakeSecurity(failed=True))
        self.assertEqual(code, 2)
        self.assertEqual(result, {"status": "failed"})

    def test_explicit_denial_osstatus_only(self):
        with self.assertRaises(banked.BankedAccessDenied):
            banked._raise_keychain_failure(-25308)
        with self.assertRaises(RuntimeError) as failure:
            banked._raise_keychain_failure(-25291)
        self.assertNotIsInstance(failure.exception, banked.BankedAccessDenied)

    def test_typed_helper_failures_keep_distinct_backoff(self):
        for status, exit_code, delay in (("denied", 1, 3600), ("failed", 2, 600)):
            with self.subTest(status=status):
                self.path.unlink(missing_ok=True)
                with (
                    patch.object(banked, "_helper_command", return_value=["/synthetic/stub"]),
                    patch.object(banked.time, "time", return_value=1000),
                    patch.object(
                        banked.subprocess,
                        "run",
                        return_value=subprocess.CompletedProcess(
                            ["/synthetic/stub"],
                            exit_code,
                            json.dumps({"status": status}).encode(),
                            b"",
                        ),
                    ),
                ):
                    self.assertIsNone(banked.get_generation("u", None, seconds_remaining=50))
                cache = json.loads(self.path.read_text())
                self.assertEqual(cache["retry_reason"], status)
                self.assertEqual(cache["retry_after"], 1000 + delay)

    def test_timeout_sets_backoff_and_skips_next_child(self):
        with (
            patch.object(banked, "_helper_command", return_value=["/synthetic/stub"]),
            patch.object(
                banked.subprocess, "run", side_effect=subprocess.TimeoutExpired("stub", 2)
            ) as run,
        ):
            self.assertIsNone(banked.get_generation("u", None, seconds_remaining=50))
            self.assertIsNone(banked.get_generation("u", None, seconds_remaining=50))
            self.assertEqual(run.call_count, 1)
        self.assertEqual(json.loads(self.path.read_text())["retry_reason"], "timeout")

    def test_low_budget_skips_child_without_writing(self):
        self.assertIsNone(banked.get_generation("u", None, seconds_remaining=4.9))
        self.assertFalse(self.path.exists())

    def test_source_and_frozen_helper_commands(self):
        with (
            patch.object(banked.sys, "executable", "/synthetic/python"),
            patch.object(banked.sys, "frozen", False, create=True),
        ):
            self.assertEqual(
                _REAL_HELPER_COMMAND(),
                ["/synthetic/python", "-m", "gradus", "--banked-keychain-helper"],
            )
        with (
            patch.object(banked.sys, "executable", "/synthetic/GradusRuntime"),
            patch.object(banked.sys, "frozen", True, create=True),
        ):
            self.assertEqual(
                _REAL_HELPER_COMMAND(), ["/synthetic/GradusRuntime", "--banked-keychain-helper"]
            )

    def test_source_child_runs_stub_module_without_keychain(self):
        package = Path(self.temporary.name) / "gradus"
        package.mkdir()
        (package / "__init__.py").write_text("")
        (package / "__main__.py").write_text(
            "import json, sys\n"
            "assert sys.argv[1:] == ['--banked-keychain-helper']\n"
            "request = json.load(sys.stdin)\n"
            "assert request == {'user_id': 'synthetic-user', 'account_id': None}\n"
            "print(json.dumps({'status': 'ok', 'generation': "
            "'8a596d59-294c-4efc-81a3-0caab767abbb'}))\n"
        )
        with patch.object(banked.sys, "frozen", False, create=True):
            command = _REAL_HELPER_COMMAND()
        result = subprocess.run(
            command,
            input=b'{"user_id":"synthetic-user","account_id":null}',
            capture_output=True,
            cwd=self.temporary.name,
            env={**os.environ, "PYTHONPATH": self.temporary.name},
            timeout=2,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(json.loads(result.stdout)["status"], "ok")
        self.assertFalse(self.path.exists())

    def test_stub_success_passes_identity_only_on_stdin(self):
        generation = "8a596d59-294c-4efc-81a3-0caab767abbb"
        with (
            patch.object(banked, "_helper_command", return_value=["/synthetic/stub"]),
            patch.object(
                banked.subprocess,
                "run",
                return_value=subprocess.CompletedProcess(
                    ["/synthetic/stub"],
                    0,
                    json.dumps({"status": "ok", "generation": generation}).encode(),
                    b"",
                ),
            ) as run,
        ):
            self.assertEqual(
                banked.get_generation("private-u", None, seconds_remaining=50), generation
            )
            arguments, options = run.call_args
            self.assertNotIn("private-u", " ".join(arguments[0]))
            self.assertIn(b"private-u", options["input"])
            self.assertEqual(options["timeout"], 2)
            self.assertEqual(options["stderr"], subprocess.DEVNULL)
