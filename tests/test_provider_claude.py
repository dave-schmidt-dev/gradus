"""Claude HTTP provider tests."""

from __future__ import annotations

import ast
import json
import math
import os
import subprocess
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from types import SimpleNamespace
from typing import Any
from unittest.mock import MagicMock, patch

from gradus import providers
from gradus import snapshot as snapshot_module
from gradus.providers import (
    ClaudeHttpProvider,
    ProbeFailure,
    fetch_provider_snapshot,
)
from gradus.providers import claude as claude_provider_module
from gradus.snapshot import CLAUDE_STALE_CREDENTIAL_MESSAGE, _is_transient_probe_error


class ClaudeHttpProviderTests(unittest.TestCase):
    """Claude usage comes from Claude Code's structured OAuth endpoint."""

    NORMAL_RESPONSE = {
        "five_hour": {"utilization": 30.0, "resets_at": "2026-04-17T00:00:00Z"},
        "seven_day": {"utilization": 45.0, "resets_at": "2026-04-21T00:00:00Z"},
        "seven_day_opus": {"utilization": 10.0, "resets_at": "2026-04-21T00:00:00Z"},
    }

    def test_provider_has_no_terminal_or_pty_probe(self) -> None:
        """Claude usage must come from structured HTTP data, never PTY scraping."""
        source = Path(claude_provider_module.__file__).read_text(encoding="utf-8")
        tree = ast.parse(source)
        imported_roots = {
            name
            for node in ast.walk(tree)
            for name in (
                [alias.name.split(".", 1)[0] for alias in node.names]
                if isinstance(node, ast.Import)
                else (
                    [node.module.split(".", 1)[0]]
                    if isinstance(node, ast.ImportFrom) and node.module
                    else []
                )
            )
        }
        self.assertTrue({"pty", "pexpect"}.isdisjoint(imported_roots))

    def setUp(self) -> None:
        providers.set_headless(False)
        self.addCleanup(providers.set_headless, False)
        account = patch("gradus.providers.claude.getpass.getuser", return_value="fixture-user")
        account.start()
        self.addCleanup(account.stop)

    def _make_provider(self) -> ClaudeHttpProvider:
        provider = ClaudeHttpProvider()
        provider._access_token = "test-oauth-token"
        return provider

    def test_keychain_payload_extracts_only_oauth_access_token(self) -> None:
        keychain = MagicMock(
            returncode=0,
            stdout=json.dumps(
                {
                    "claudeAiOauth": {
                        "accessToken": "test-oauth-token",
                        "refreshToken": "must-not-be-used",
                    },
                    "sessionKey": "must-not-be-used",
                }
            ),
        )
        with patch("gradus.providers.claude.subprocess.run", return_value=keychain) as run:
            credential = ClaudeHttpProvider._load_keychain_credential()

        self.assertEqual(credential.access_token, "test-oauth-token")
        args = run.call_args.args[0]
        self.assertEqual(args[:3], ["security", "find-generic-password", "-w"])
        self.assertIn("Claude Code-credentials", args)
        self.assertNotIn("test-oauth-token", args)

    def _keychain(self, **oauth: object) -> MagicMock:
        payload = {"accessToken": "test-oauth-token", **oauth}
        return MagicMock(returncode=0, stdout=json.dumps({"claudeAiOauth": payload}))

    def test_keychain_read_needs_no_host_account_lookup(self) -> None:
        """Mocked Keychain reads also work in a scrubbed, account-denying sandbox."""
        with (
            patch.dict(os.environ, {"LOGNAME": "", "USER": "", "LNAME": "", "USERNAME": ""}),
            patch("pwd.getpwuid", side_effect=AssertionError("host account lookup forbidden")),
            patch("gradus.providers.claude.subprocess.run", return_value=self._keychain()) as run,
        ):
            credential = ClaudeHttpProvider._load_keychain_credential()

        self.assertEqual(credential.access_token, "test-oauth-token")
        self.assertEqual(run.call_args.args[0][-2:], ["-a", "fixture-user"])

    def test_stale_access_token_is_reported_as_transient_not_a_sign_in(self) -> None:
        """A refreshable grant must not be reported as needing `claude auth login`.

        Observed 2026-09-08: Claude Code refreshes its keychain item lazily, so
        the cached token can sit expired for ~19 minutes while Claude Code is in
        active use. The old probe sent it, took a 401, and told David to sign in
        to a session he had never left.
        """
        now_ms = datetime.now().timestamp() * 1000
        keychain = self._keychain(
            expiresAt=now_ms - 60_000,
            refreshTokenExpiresAt=now_ms + 30 * 86_400_000,
        )
        with patch("gradus.providers.claude.subprocess.run", return_value=keychain):
            with patch("gradus.providers.claude._base._http_json") as http:
                with self.assertRaises(ProbeFailure) as ctx:
                    ClaudeHttpProvider().fetch()

        # The stale token is never spent: no request, so no 401 to misread.
        http.assert_not_called()
        self.assertEqual(str(ctx.exception), CLAUDE_STALE_CREDENTIAL_MESSAGE)
        self.assertTrue(
            _is_transient_probe_error(
                SimpleNamespace(name="Claude", ok=False, error=str(ctx.exception))
            )
        )
        message = str(ctx.exception).lower()
        for classifier_substring in (
            "session expired",
            "re-authenticate",
            "login`",
            "auth required",
            "session unavailable",
            "authorization denied",
        ):
            self.assertNotIn(classifier_substring, message)

    _OK_ENVELOPE = json.dumps({"type": "result", "is_error": False, "result": "OK"})
    _CLAUDE_BIN = "/opt/homebrew/bin/claude"

    def _stale_and_fresh(self) -> tuple[Any, Any]:
        now_ms = datetime.now().timestamp() * 1000
        stale = claude_provider_module._KeychainCredential(
            access_token="stale-token",
            expires_at=now_ms - 60_000,
            refresh_expires_at=now_ms + 30 * 86_400_000,
        )
        fresh = claude_provider_module._KeychainCredential(
            access_token="fresh-token",
            expires_at=now_ms + 3_600_000,
            refresh_expires_at=now_ms + 30 * 86_400_000,
        )
        return stale, fresh

    def _run_recovery(
        self,
        outcome: object,
        *,
        reloads: tuple[object, ...] = (),
        executable: str | None = _CLAUDE_BIN,
    ) -> tuple[list[str], MagicMock, MagicMock, Any]:
        """Run one stale fetch with recovery patched; return statuses, mocks, logs."""
        stale, _ = self._stale_and_fresh()
        statuses: list[str] = []
        with (
            patch.object(
                ClaudeHttpProvider, "_load_keychain_credential", side_effect=[stale, *reloads]
            ),
            patch.object(ClaudeHttpProvider, "_claude_executable", return_value=executable),
            patch("gradus.providers.claude.subprocess.run", side_effect=[outcome]) as run,
            patch("gradus.providers.claude._base._http_json") as http,
            self.assertLogs("gradus.providers.claude", level="WARNING") as logs,
        ):
            with self.assertRaisesRegex(ProbeFailure, f"^{CLAUDE_STALE_CREDENTIAL_MESSAGE}$"):
                ClaudeHttpProvider(on_status=statuses.append).fetch()
        http.assert_not_called()
        self.assertEqual(
            statuses,
            ["provider Claude recovery started", "provider Claude recovery unavailable"],
        )
        return statuses, run, http, logs

    def test_stale_token_recovery_runs_claude_code_directly(self) -> None:
        """Regression for 2026-10-06: recovery went through a retired wrapper flag.

        `claude-headless --verify-auth` was removed on 2026-10-05, so every
        refresh attempt exited 2 and Claude read "usage unavailable" until a
        human session happened to refresh the token. Gradus now runs Claude
        Code itself with a fixed, tool-free, transcript-free one-line prompt.
        """
        stale, fresh = self._stale_and_fresh()
        statuses: list[str] = []
        with (
            patch.object(
                ClaudeHttpProvider, "_load_keychain_credential", side_effect=[stale, fresh]
            ) as load,
            patch.object(ClaudeHttpProvider, "_claude_executable", return_value=self._CLAUDE_BIN),
            patch(
                "gradus.providers.claude.subprocess.run",
                return_value=subprocess.CompletedProcess([], 0, self._OK_ENVELOPE, None),
            ) as run,
            patch(
                "gradus.providers.claude._base._http_json", return_value=self.NORMAL_RESPONSE
            ) as http,
        ):
            status = ClaudeHttpProvider(on_status=statuses.append).fetch()

        self.assertEqual(status.session_percent_left, 70.0)
        self.assertEqual(load.call_count, 2)
        self.assertEqual(http.call_args.kwargs["headers"]["Authorization"], "Bearer fresh-token")
        run.assert_called_once()
        self.assertEqual(
            run.call_args.args[0],
            [
                self._CLAUDE_BIN,
                "-p",
                "--model",
                "haiku",
                "--tools",
                "",
                "--no-session-persistence",
                "--strict-mcp-config",
                "--disable-slash-commands",
                "--settings",
                '{"disableAllHooks":true}',
                "--output-format",
                "json",
                "Reply with exactly OK.",
            ],
        )
        kwargs = run.call_args.kwargs
        self.assertEqual(kwargs["stdout"], subprocess.PIPE)
        self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)
        self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
        self.assertIs(kwargs["text"], True)
        self.assertIs(kwargs["check"], False)
        self.assertEqual(kwargs["timeout"], ClaudeHttpProvider._AUTH_RECOVERY_TIMEOUT_SECONDS)
        self.assertIn("gradus-claude-refresh-", kwargs["cwd"])
        self.assertFalse(Path(kwargs["cwd"]).exists())
        self.assertNotEqual(Path(kwargs["cwd"]).resolve(), Path.cwd().resolve())
        self.assertEqual(
            statuses,
            ["provider Claude recovery started", "provider Claude recovery complete"],
        )

    def test_stale_token_recovery_rejects_inexact_envelopes(self) -> None:
        envelopes = {
            "is_error_true": {"type": "result", "is_error": True, "result": "OK"},
            "is_error_missing": {"type": "result", "result": "OK"},
            "is_error_falsy_non_bool": {"type": "result", "is_error": 0, "result": "OK"},
            "wrong_type": {"type": "assistant", "is_error": False, "result": "OK"},
            "wrong_result": {"type": "result", "is_error": False, "result": "OK then"},
            "non_string_result": {"type": "result", "is_error": False, "result": None},
        }
        stdouts = {name: json.dumps(value) for name, value in envelopes.items()}
        stdouts["invalid_json"] = "OK\n"
        stdouts["json_list"] = "[]"
        for name, stdout in stdouts.items():
            with self.subTest(envelope=name):
                _, run, _, logs = self._run_recovery(
                    subprocess.CompletedProcess([], 0, stdout, None)
                )
                run.assert_called_once()
                self.assertEqual(
                    logs.output,
                    [
                        "WARNING:gradus.providers.claude:provider Claude recovery unavailable: "
                        "bad_envelope"
                    ],
                )

    def test_stale_token_recovery_failure_reasons_are_fixed_and_hide_output(self) -> None:
        cases = {
            "nonzero_exit": subprocess.CompletedProcess([], 1, "secret-adjacent output", None),
            "timeout": subprocess.TimeoutExpired(["claude"], 30, output="secret-adjacent"),
            "spawn_error": OSError("secret-adjacent spawn detail"),
        }
        for reason, outcome in cases.items():
            with self.subTest(reason=reason):
                _, run, _, logs = self._run_recovery(outcome)
                run.assert_called_once()
                self.assertEqual(
                    logs.output,
                    [
                        f"WARNING:gradus.providers.claude:provider Claude recovery unavailable: "
                        f"{reason}"
                    ],
                )
                self.assertNotIn("secret-adjacent", " ".join(logs.output))

    def test_stale_token_recovery_without_claude_executable_never_spawns(self) -> None:
        _, run, _, logs = self._run_recovery(AssertionError("must not run"), executable=None)
        run.assert_not_called()
        self.assertIn("recovery unavailable: not_found", logs.output[0])

    def test_stale_token_recovery_reload_failure_retains_stale_status(self) -> None:
        _, _, _, logs = self._run_recovery(
            subprocess.CompletedProcess([], 0, self._OK_ENVELOPE, None),
            reloads=(RuntimeError("credential secret must not surface"),),
        )
        self.assertIn("recovery unavailable: keychain_reload_failed", logs.output[0])
        self.assertNotIn("credential secret", " ".join(logs.output))

    def test_stale_token_recovery_requires_fresh_access_expiry(self) -> None:
        now_ms = datetime.now().timestamp() * 1000
        unchanged = claude_provider_module._KeychainCredential(
            access_token="still-stale-token",
            expires_at=now_ms - 1,
            refresh_expires_at=now_ms + 30 * 86_400_000,
        )
        _, _, _, logs = self._run_recovery(
            subprocess.CompletedProcess([], 0, self._OK_ENVELOPE, None),
            reloads=(unchanged,),
        )
        self.assertIn("recovery unavailable: still_stale", logs.output[0])

    def test_claude_executable_prefers_path_then_fixed_candidates_without_realpath(self) -> None:
        with patch("gradus.providers.claude.shutil.which", return_value="/custom/bin/claude"):
            self.assertEqual(ClaudeHttpProvider._claude_executable(), "/custom/bin/claude")

        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            target = home / "Caskroom" / "claude"
            target.parent.mkdir()
            target.write_text("#!/bin/sh\n")
            target.chmod(0o755)
            link = home / ".local" / "bin" / "claude"
            link.parent.mkdir(parents=True)
            link.symlink_to(target)
            with (
                patch("gradus.providers.claude.shutil.which", return_value=None),
                patch("gradus.providers.claude.Path.home", return_value=home),
                patch.object(
                    ClaudeHttpProvider,
                    "_CLAUDE_EXECUTABLE_CANDIDATES",
                    (str(home / "missing" / "claude"), ".local/bin/claude"),
                ),
            ):
                self.assertEqual(ClaudeHttpProvider._claude_executable(), str(link))
            with (
                patch("gradus.providers.claude.shutil.which", return_value=None),
                patch.object(
                    ClaudeHttpProvider,
                    "_CLAUDE_EXECUTABLE_CANDIDATES",
                    (str(home / "missing" / "claude"),),
                ),
            ):
                self.assertIsNone(ClaudeHttpProvider._claude_executable())

    def test_stale_token_recovery_is_attempted_once_per_provider(self) -> None:
        stale, _ = self._stale_and_fresh()
        provider = ClaudeHttpProvider()
        with (
            patch.object(ClaudeHttpProvider, "_load_keychain_credential", return_value=stale),
            patch.object(ClaudeHttpProvider, "_claude_executable", return_value=self._CLAUDE_BIN),
            patch(
                "gradus.providers.claude.subprocess.run",
                return_value=subprocess.CompletedProcess([], 5, "", None),
            ) as run,
            patch("gradus.providers.claude._base._http_json") as http,
            self.assertLogs("gradus.providers.claude", level="WARNING"),
        ):
            for _ in range(2):
                with self.assertRaisesRegex(ProbeFailure, f"^{CLAUDE_STALE_CREDENTIAL_MESSAGE}$"):
                    provider.fetch()

        run.assert_called_once()
        http.assert_not_called()

    def test_expired_access_with_unusable_refresh_expiry_is_not_queried(self) -> None:
        now_ms = datetime.now().timestamp() * 1000
        unusable_values = (None, "not-a-timestamp", True, math.inf, -math.inf, math.nan)

        for refresh_expiry in unusable_values:
            with self.subTest(refresh_expiry=refresh_expiry):
                keychain = self._keychain(
                    expiresAt=now_ms - 60_000,
                    refreshTokenExpiresAt=refresh_expiry,
                )
                with patch("gradus.providers.claude.subprocess.run", return_value=keychain) as run:
                    with patch("gradus.providers.claude._base._http_json") as http:
                        with self.assertRaisesRegex(
                            ProbeFailure,
                            f"^{snapshot_module.CLAUDE_REFRESH_METADATA_UNAVAILABLE_MESSAGE}$",
                        ):
                            ClaudeHttpProvider().fetch()

                http.assert_not_called()
                run.assert_called_once()
                self.assertEqual(
                    run.call_args.args[0][:3], ["security", "find-generic-password", "-w"]
                )

    def test_expired_refresh_token_is_still_a_real_sign_in(self) -> None:
        """With nothing left to refresh from, `claude auth login` is the right call."""
        now_ms = datetime.now().timestamp() * 1000
        keychain = self._keychain(
            expiresAt=now_ms - 60_000,
            refreshTokenExpiresAt=now_ms - 30_000,
        )
        with patch("gradus.providers.claude.subprocess.run", return_value=keychain) as run:
            with patch("gradus.providers.claude._base._http_json") as http:
                with self.assertRaises(ProbeFailure) as ctx:
                    ClaudeHttpProvider().fetch()
        self.assertIn("session expired", str(ctx.exception))
        http.assert_not_called()
        run.assert_called_once()

    def test_live_access_token_is_used_without_a_staleness_veto(self) -> None:
        now_ms = datetime.now().timestamp() * 1000
        keychain = self._keychain(
            expiresAt=now_ms + 3_600_000,
            refreshTokenExpiresAt=now_ms + 30 * 86_400_000,
        )
        with patch("gradus.providers.claude.subprocess.run", return_value=keychain):
            with patch(
                "gradus.providers.claude._base._http_json",
                return_value=self.NORMAL_RESPONSE,
            ) as http:
                status = ClaudeHttpProvider().fetch()
        http.assert_called_once()
        self.assertEqual(status.session_percent_left, 70.0)

    def test_missing_expiry_falls_back_to_trying_the_token(self) -> None:
        """An older payload without `expiresAt` keeps the pre-2026-09-08 behavior."""
        with patch("gradus.providers.claude.subprocess.run", return_value=self._keychain()):
            with patch(
                "gradus.providers.claude._base._http_json",
                return_value=self.NORMAL_RESPONSE,
            ) as http:
                ClaudeHttpProvider().fetch()
        http.assert_called_once()

    def test_invalid_keychain_payload_fails_closed(self) -> None:
        keychain = MagicMock(returncode=0, stdout=json.dumps({"sessionKey": "legacy"}))
        with patch("gradus.providers.claude.subprocess.run", return_value=keychain):
            with self.assertRaises(FileNotFoundError) as ctx:
                ClaudeHttpProvider._load_keychain_credential()
        self.assertEqual(str(ctx.exception), "keychain item has no access token")

    def test_keychain_failure_does_not_expose_command_output(self) -> None:
        keychain = MagicMock(returncode=1, stdout="secret-adjacent-output")
        with patch("gradus.providers.claude.subprocess.run", return_value=keychain):
            with self.assertRaises(FileNotFoundError) as ctx:
                ClaudeHttpProvider._load_keychain_credential()
        self.assertNotIn("secret-adjacent-output", str(ctx.exception))

    def test_keychain_item_not_found_is_distinguished_from_denied_access(self) -> None:
        """A real errSecItemNotFound (exit 44) genuinely needs a fresh sign-in."""
        keychain = MagicMock(returncode=44, stdout="")
        with patch("gradus.providers.claude.subprocess.run", return_value=keychain):
            with self.assertRaises(FileNotFoundError) as ctx:
                ClaudeHttpProvider._load_keychain_credential()
        self.assertEqual(str(ctx.exception), "no keychain item")

    def test_keychain_interaction_not_allowed_is_not_a_sign_in_problem(self) -> None:
        """errSecInteractionNotAllowed (exit 36) means the Keychain is locked,
        not that Claude Code's grant is gone -- `claude auth login` won't help."""
        keychain = MagicMock(returncode=36, stdout="")
        with patch("gradus.providers.claude.subprocess.run", return_value=keychain):
            with self.assertRaises(FileNotFoundError) as ctx:
                ClaudeHttpProvider._load_keychain_credential()
        self.assertEqual(str(ctx.exception), "keychain is locked or unavailable to this session")

    def test_other_keychain_exit_codes_report_their_exit_status(self) -> None:
        keychain = MagicMock(returncode=51, stdout="")
        with patch("gradus.providers.claude.subprocess.run", return_value=keychain):
            with self.assertRaises(FileNotFoundError) as ctx:
                ClaudeHttpProvider._load_keychain_credential()
        self.assertEqual(str(ctx.exception), "keychain denied the read, exit 51")

    def test_malformed_keychain_json_names_the_reason(self) -> None:
        keychain = MagicMock(returncode=0, stdout="not json")
        with patch("gradus.providers.claude.subprocess.run", return_value=keychain):
            with self.assertRaises(FileNotFoundError) as ctx:
                ClaudeHttpProvider._load_keychain_credential()
        self.assertEqual(str(ctx.exception), "keychain item is not valid JSON")

    def test_probe_failure_surfaces_the_keychain_reason(self) -> None:
        """The dashboard message must name which of the four causes fired,
        not just repeat one generic "unavailable" string for all of them."""
        keychain = MagicMock(returncode=36, stdout="")
        with patch("gradus.providers.claude.subprocess.run", return_value=keychain):
            with self.assertRaises(ProbeFailure) as ctx:
                ClaudeHttpProvider().fetch()
        message = str(ctx.exception)
        self.assertIn("keychain is locked or unavailable to this session", message)
        self.assertIn("credentials unavailable", message)
        self.assertIn("claude auth login", message)

    def test_headless_acquire_never_reads_keychain(self) -> None:
        providers.set_headless(True)
        self.addCleanup(providers.set_headless, False)
        with patch("gradus.providers.claude.subprocess.run") as run:
            with self.assertRaises(ProbeFailure) as ctx:
                ClaudeHttpProvider().fetch()
        run.assert_not_called()
        self.assertEqual(str(ctx.exception), "auth required: no cached credentials")

    def test_normal_response_field_mapping(self) -> None:
        provider = self._make_provider()
        with patch(
            "gradus.providers._base._http_json", return_value=self.NORMAL_RESPONSE
        ) as http_json:
            status = provider.fetch()
        http_json.assert_called_once_with(
            ClaudeHttpProvider._OAUTH_USAGE_URL,
            headers={
                "Authorization": "Bearer test-oauth-token",
                "Accept": "application/json",
                "User-Agent": ClaudeHttpProvider._USER_AGENT,
            },
        )
        # 100 - 30 = 70
        self.assertEqual(status.session_percent_left, 70)
        # 100 - 45 = 55
        self.assertEqual(status.weekly_percent_left, 55)
        # 100 - 10 = 90
        self.assertEqual(status.opus_percent_left, 90)
        self.assertIsNone(status.account_email)
        self.assertIsNone(status.account_organization)
        self.assertIsNone(status.login_method)

    def test_percent_left_fields_are_float(self) -> None:
        provider = self._make_provider()
        with patch("gradus.providers._base._http_json", return_value=self.NORMAL_RESPONSE):
            status = provider.fetch()
        self.assertIsInstance(status.session_percent_left, float)
        self.assertIsInstance(status.weekly_percent_left, float)
        self.assertIsInstance(status.opus_percent_left, float)

    def test_enabled_extra_usage_exposes_remaining_dollar_credit(self) -> None:
        response = {
            **self.NORMAL_RESPONSE,
            "extra_usage": {
                "is_enabled": True,
                "monthly_limit": 100,
                "used_credits": 12.25,
            },
        }
        provider = self._make_provider()
        with patch("gradus.providers._base._http_json", return_value=response):
            status = provider.fetch()
        self.assertEqual(status.credit_balance, 87.75)

    def test_missing_disabled_or_invalid_extra_usage_omits_credit(self) -> None:
        cases = (
            {},
            {"is_enabled": False, "monthly_limit": 100, "used_credits": 10},
            {"is_enabled": True, "monthly_limit": "bad", "used_credits": 10},
            {"is_enabled": True, "monthly_limit": 100, "used_credits": -1},
        )
        for extra_usage in cases:
            with self.subTest(extra_usage=extra_usage):
                provider = self._make_provider()
                response = {**self.NORMAL_RESPONSE, "extra_usage": extra_usage}
                with patch("gradus.providers._base._http_json", return_value=response):
                    status = provider.fetch()
                self.assertIsNone(status.credit_balance)

    def test_bucketless_success_is_transient_instead_of_erasing_usage(self) -> None:
        provider = self._make_provider()
        with patch("gradus.providers._base._http_json", return_value={}):
            snapshot = fetch_provider_snapshot("Claude", provider, debug=False)
        self.assertFalse(snapshot.ok)
        self.assertEqual(snapshot.error, "Claude usage data not available yet")
        self.assertTrue(_is_transient_probe_error(snapshot))

    def test_401_clears_token_and_routes_to_login(self) -> None:
        provider = self._make_provider()
        with patch("gradus.providers._base._http_json", side_effect=ProbeFailure("HTTP 401", "")):
            with self.assertRaises(ProbeFailure) as ctx:
                provider.fetch()
        self.assertIn("session expired", str(ctx.exception).lower())
        self.assertEqual(provider._access_token, "")

    def test_403_clears_token_and_routes_to_login(self) -> None:
        provider = self._make_provider()
        with patch("gradus.providers._base._http_json", side_effect=ProbeFailure("HTTP 403", "")):
            with self.assertRaises(ProbeFailure) as ctx:
                provider.fetch()
        self.assertIn("session expired", str(ctx.exception).lower())
        self.assertEqual(provider._access_token, "")

    def test_missing_oauth_credentials_fails_closed(self) -> None:
        provider = ClaudeHttpProvider()
        with patch.object(
            ClaudeHttpProvider,
            "_load_keychain_credential",
            side_effect=FileNotFoundError("credential helper unavailable"),
        ):
            snapshot = fetch_provider_snapshot("Claude", provider, debug=False)
        self.assertFalse(snapshot.ok)
        self.assertIn("claude auth login", snapshot.error or "")
