"""Provider credential contract tests."""

from __future__ import annotations

import base64
import inspect
import json
import os
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from gradus import providers
from gradus.providers import (
    AntigravityProvider,
    ClaudeHttpProvider,
    CodexHttpProvider,
    CursorProvider,
    OpenCodeGoProvider,
    ProbeFailure,
    VibeCodeProvider,
    _is_jwt_expired,
    _write_debug_dump,
    fetch_provider_snapshot,
)


def _make_jwt(exp_offset_seconds: int) -> str:
    """Build a fake JWT whose `exp` claim is now + offset (no signature)."""
    header = base64.urlsafe_b64encode(b'{"alg":"none"}').rstrip(b"=").decode()
    payload_obj = {"exp": int(time.time()) + exp_offset_seconds}
    payload = base64.urlsafe_b64encode(json.dumps(payload_obj).encode()).rstrip(b"=").decode()
    return f"{header}.{payload}."


class JwtExpiryTests(unittest.TestCase):
    def test_unexpired_token(self) -> None:
        self.assertFalse(_is_jwt_expired(_make_jwt(3600)))

    def test_expired_token(self) -> None:
        self.assertTrue(_is_jwt_expired(_make_jwt(-3600)))

    def test_within_leeway_treated_as_expired(self) -> None:
        # leeway is 60s; expiring in 30s counts as expired
        self.assertTrue(_is_jwt_expired(_make_jwt(30)))

    def test_non_jwt_returns_false(self) -> None:
        self.assertFalse(_is_jwt_expired("not-a-jwt"))

    def test_jwt_without_exp_returns_false(self) -> None:
        header = base64.urlsafe_b64encode(b'{"alg":"none"}').rstrip(b"=").decode()
        payload = base64.urlsafe_b64encode(b"{}").rstrip(b"=").decode()
        self.assertFalse(_is_jwt_expired(f"{header}.{payload}."))


def _raise_http_401(*args: object, **kwargs: object) -> None:
    """urlopen side-effect that always raises HTTP 401.

    Drives every provider's cached-cred → HTTP-401 recovery path (the hardest
    case for INV-2) without touching the real network.
    """
    import urllib.error

    raise urllib.error.HTTPError("https://example.com", 401, "Unauthorized", {}, None)


class HeadlessReadOnlyTests(unittest.TestCase):
    """INV-2: with headless mode ON, constructing and fetching any provider must
    invoke neither subprocess.Popen nor subprocess.run, read no browser/Keychain
    path, and write no auth/cache file — even on a cached-cred → HTTP-401 path.
    """

    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self._root = Path(self._tmpdir.name)
        self._vibe_cache = self._root / "vibe_cookies.json"
        self._codex_auth = self._root / "auth.json"
        self._patchers = [
            patch.object(VibeCodeProvider, "_CACHE_PATH", self._vibe_cache),
            patch.object(CodexHttpProvider, "_AUTH_PATH", self._codex_auth),
        ]
        for p in self._patchers:
            p.start()

    def tearDown(self) -> None:
        # SR-3: a leaked headless=True silently disables browser-opens for every
        # later test, so restore the default before anything else can run.
        providers.set_headless(False)
        for p in self._patchers:
            p.stop()
        self._tmpdir.cleanup()

    def _seed_codex_and_cursor(self) -> None:
        """Give Codex and Cursor a valid cached credential so fetch() reaches the
        cached-cred → 401 recovery path instead of failing at construction."""
        self._codex_auth.write_text(
            json.dumps(
                {
                    "tokens": {
                        "access_token": "cached_access",
                        "refresh_token": "cached_refresh",
                        "account_id": "acct",
                    }
                }
            ),
            encoding="utf-8",
        )

    def _construct_and_fetch_all(self) -> None:
        """Construct + fetch all five providers, tolerating expected auth failures.

        Under headless mode fetch() is EXPECTED to fail with a truthful auth
        error (ProbeFailure) or, for Antigravity, a FileNotFoundError at
        construction — that is the correct outcome, so both are swallowed.
        """
        factories = [
            lambda: VibeCodeProvider(str(self._root)),
            OpenCodeGoProvider,
            CodexHttpProvider,
            ClaudeHttpProvider,
            AntigravityProvider,
        ]
        for factory in factories:
            try:
                provider = factory()
                provider.fetch()
            except (ProbeFailure, FileNotFoundError):
                pass

    def test_headless_no_subprocess_any_provider(self) -> None:
        # INV-2 proof: neither Popen nor run may fire across construct+fetch for
        # all providers. If either count is non-zero, a choke-point is ungated.
        self._seed_codex_and_cursor()
        providers.set_headless(True)
        with (
            patch("gradus.providers.subprocess.Popen") as popen,
            patch("gradus.providers.subprocess.run") as run,
            patch("urllib.request.urlopen", side_effect=_raise_http_401),
        ):
            self._construct_and_fetch_all()
        self.assertEqual(popen.call_count, 0)
        self.assertEqual(run.call_count, 0)

    def test_headless_no_cred_or_cache_writes(self) -> None:
        # INV-2: no auth.json rewrite and no cache write/eviction, even on 401.
        self._seed_codex_and_cursor()
        original_auth = self._codex_auth.read_text(encoding="utf-8")
        providers.set_headless(True)
        with (
            patch("gradus.providers.os.replace") as os_replace,
            patch("gradus.providers.subprocess.Popen"),
            patch("gradus.providers.subprocess.run"),
            patch("urllib.request.urlopen", side_effect=_raise_http_401),
        ):
            self._construct_and_fetch_all()
        # Codex must never mint/persist tokens → no atomic auth.json rewrite.
        os_replace.assert_not_called()
        self.assertEqual(self._codex_auth.read_text(encoding="utf-8"), original_auth)
        # No provider may create a fresh cache file from a read.
        self.assertFalse(self._vibe_cache.exists())

    def test_acquire_never_launches_browser(self) -> None:
        # A credential-less probe is a pure cache read in either mode.
        try:
            for headless in (False, True):
                with patch("gradus.providers.subprocess.Popen") as popen:
                    providers.set_headless(headless)
                    provider = VibeCodeProvider(str(self._root))
                    provider._acquire()
                    popen.assert_not_called()
        finally:
            providers.set_headless(False)

    def test_provider_modules_contain_no_browser_readers(self) -> None:
        provider_directory = Path(providers.__file__).resolve().parent
        prohibited = ("Cookies.binarycookies", "Chrome Safe Storage", "state.vscdb")
        for module in provider_directory.glob("*.py"):
            source = module.read_text(encoding="utf-8")
            for value in prohibited:
                self.assertNotIn(value, source, module.name)


class LazyAcquireContractTests(unittest.TestCase):
    """Pins the refactored contract: __init__ only stores config (no credential
    I/O, no browser), and credential acquisition happens lazily in _acquire(),
    reached via fetch(). Missing credentials must still surface as a truthful
    auth-routed snapshot, not a crash or a silent success.
    """

    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self._root = Path(self._tmpdir.name)
        self._vibe_cache = self._root / "vibe_cookies.json"
        self._codex_auth = self._root / "auth.json"
        self._patchers = [
            patch.object(VibeCodeProvider, "_CACHE_PATH", self._vibe_cache),
            patch.object(CodexHttpProvider, "_AUTH_PATH", self._codex_auth),
        ]
        for p in self._patchers:
            p.start()

    def tearDown(self) -> None:
        for p in self._patchers:
            p.stop()
        self._tmpdir.cleanup()

    def test_provider_construction_does_no_credential_io(self) -> None:
        """__init__ must be pure config storage: no subprocess, no cookie read,
        no cache write, and no raised exception — for all five providers.

        This would fail against the pre-refactor contract, where CodexHttpProvider
        and AntigravityProvider raised in __init__ when credentials were absent,
        and where every provider's __init__ triggered a Safari/Chrome/Keychain read.
        """
        with (
            patch("gradus.providers.subprocess.run") as mock_run,
            patch("gradus.providers.subprocess.Popen") as mock_popen,
            patch("gradus.providers._base._write_private") as mock_write,
        ):
            try:
                CodexHttpProvider()
                ClaudeHttpProvider()
                AntigravityProvider()
                CursorProvider()
                OpenCodeGoProvider()
                VibeCodeProvider(str(self._root))
            except Exception as exc:  # noqa: BLE001
                self.fail(f"construction must never raise, got: {exc!r}")

        mock_run.assert_not_called()
        mock_popen.assert_not_called()
        mock_write.assert_not_called()

    def test_missing_creds_surface_as_failed_snapshot_via_fetch(self) -> None:
        """Missing credentials must fail closed without claiming usage."""
        provider = ClaudeHttpProvider()
        with patch.object(
            ClaudeHttpProvider,
            "_load_keychain_credential",
            side_effect=FileNotFoundError("credential helper unavailable"),
        ):
            snapshot = fetch_provider_snapshot("Claude", provider, debug=False)

        self.assertFalse(snapshot.ok)
        self.assertIn("claude auth login", snapshot.error or "")


class TestCredentialCachePermissions(unittest.TestCase):
    """Python readers harden bridge-written cache files before use."""

    def setUp(self) -> None:
        self._prior_headless = providers._is_headless()
        providers.set_headless(False)

    def tearDown(self) -> None:
        providers.set_headless(self._prior_headless)

    def _assert_private(self, path: Path) -> None:
        self.assertTrue(path.exists(), f"{path} was not written")
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(path.parent).st_mode), 0o700)

    def test_debug_dump_compatibility_function_writes_nothing(self) -> None:
        """Legacy import remains available but cannot create raw-body files."""
        with tempfile.TemporaryDirectory() as tmp:
            shared = Path(tmp) / "shared"  # stand-in for /tmp
            shared.mkdir()
            os.chmod(shared, 0o777)  # permissive, like /tmp
            dump_path = shared / "gradus_test_capture.txt"
            with patch("gradus.providers._base._debug_dump_path", return_value=dump_path):
                _write_debug_dump("Test", "raw capture output")
            self.assertFalse(dump_path.exists())
            self.assertEqual(stat.S_IMODE(os.stat(shared).st_mode), 0o777)


class SafariFreeProviderTests(unittest.TestCase):
    def setUp(self) -> None:
        guard = patch.object(OpenCodeGoProvider, "_DB_PATH", Path(os.devnull) / "opencode-test.db")
        guard.start()
        self.addCleanup(guard.stop)

    def test_cursor_keychain_lookup_uses_cli_item_without_persisting(self) -> None:
        with patch("gradus.providers.cursor.subprocess.run") as run:
            run.return_value = SimpleNamespace(returncode=0, stdout="cursor-token\n")
            self.assertEqual(CursorProvider._load_keychain_token(), "cursor-token")
            args = run.call_args.args[0]
            self.assertEqual(args[:3], ["security", "find-generic-password", "-w"])
            self.assertEqual(args[3:], ["-s", "cursor-access-token", "-a", "cursor-user"])

    def test_cursor_never_writes_the_keychain_or_refreshes_the_cli_session(self) -> None:
        source = Path(inspect.getsourcefile(CursorProvider)).read_text(encoding="utf-8")
        for forbidden in (
            "add-generic-password",
            "delete-generic-password",
            "oauth/token",
            "refresh_token",
            "_clear_cache",
            "cursor_token.json",
        ):
            self.assertNotIn(forbidden, source)

    def test_cursor_keychain_failures_are_typed_without_diagnostics(self) -> None:
        for stderr, expected in (
            ("security: SecKeychain item not found", "item unavailable"),
            ("errSecAuthFailed: authorization denied", "Keychain access denied"),
            ("keychain is locked", "Keychain is locked"),
            ("User interaction is not allowed", "lookup requires interaction"),
        ):
            with (
                self.subTest(stderr=stderr),
                patch("gradus.providers.cursor.subprocess.run") as run,
            ):
                run.return_value = SimpleNamespace(returncode=1, stdout="", stderr=stderr)
                with self.assertRaisesRegex(FileNotFoundError, expected):
                    CursorProvider._load_keychain_token()
            self.assertNotIn(stderr, expected)

    def test_cursor_missing_keychain_item_becomes_auth_required(self) -> None:
        with (
            patch("gradus.providers.cursor._is_headless", return_value=False),
            patch.object(
                CursorProvider,
                "_load_keychain_token",
                side_effect=FileNotFoundError("item unavailable"),
            ),
        ):
            with self.assertRaisesRegex(ProbeFailure, "Keychain item unavailable"):
                CursorProvider().fetch()

    def test_cursor_expired_cli_token_asks_for_relogin_before_any_request(self) -> None:
        expired = _make_jwt(-3600)
        with (
            patch("gradus.providers.cursor._is_headless", return_value=False),
            patch.object(CursorProvider, "_load_keychain_token", return_value=expired),
            patch("urllib.request.urlopen") as open_url,
        ):
            with self.assertRaisesRegex(ProbeFailure, "run `cursor-agent login`"):
                CursorProvider().fetch()
        open_url.assert_not_called()

    def test_cursor_keychain_subprocess_failures_become_safe_typed_errors(self) -> None:
        secret = "cursor-secret-must-not-escape"
        failures = (
            subprocess.TimeoutExpired(["security", secret], timeout=10),
            OSError(secret),
            subprocess.SubprocessError(secret),
        )
        for failure in failures:
            with (
                self.subTest(failure=type(failure).__name__),
                patch("gradus.providers.cursor._is_headless", return_value=False),
                patch("gradus.providers.cursor.subprocess.run", side_effect=failure),
            ):
                with self.assertRaises(ProbeFailure) as raised:
                    CursorProvider().fetch()
            message = str(raised.exception)
            self.assertIn("Cursor Keychain", message)
            self.assertNotIn(secret, message)

    def test_cursor_usage_mapping_and_token_is_not_in_raw_text(self) -> None:
        usage = {
            "billingCycleStart": "1786535166000",
            "billingCycleEnd": "1789213566000",
            "planUsage": {
                "limit": 2000,
                "autoPercentUsed": 93.78,
                "apiPercentUsed": 6.89,
                "totalPercentUsed": 50.33,
            },
        }
        plan = {"planInfo": {"planName": "Pro"}}
        provider = CursorProvider()
        provider._access_token = "fixture-token"
        with patch.object(CursorProvider, "_api_post", side_effect=[usage, plan]):
            status = provider.fetch()
        self.assertEqual(status.credit_percent_left, 49.67)
        self.assertEqual(status.limit_cents, 2000)
        self.assertIsNone(status.remaining_cents)
        self.assertIsNone(status.on_demand_limit_cents)
        self.assertIsNone(status.on_demand_used_cents)
        self.assertEqual(status.plan_name, "Pro")
        self.assertTrue(status.billing_cycle_end.startswith("Resets "))
        self.assertIsNotNone(status.billing_cycle_end_iso)
        self.assertNotIn("fixture-token", status.raw_text)

    def test_cursor_prefers_remaining_over_percent_when_present(self) -> None:
        usage = {"planUsage": {"remaining": 500, "limit": 2000, "totalPercentUsed": 50.33}}
        provider = CursorProvider()
        provider._access_token = "fixture-token"
        with patch.object(CursorProvider, "_api_post", side_effect=[usage, {}]):
            status = provider.fetch()
        self.assertEqual(status.credit_percent_left, 25.0)

    def test_cursor_live_shape_without_on_demand_limit_has_no_on_demand_fields(self) -> None:
        usage = {
            "planUsage": {"remaining": 1041, "limit": 2000, "totalPercentUsed": 10.66},
            "spendLimitUsage": {"limitType": "user"},
        }
        provider = CursorProvider()
        provider._access_token = "fixture-token"
        with patch.object(CursorProvider, "_api_post", side_effect=[usage, {}]):
            status = provider.fetch()
        self.assertIsNone(status.on_demand_limit_cents)
        self.assertIsNone(status.on_demand_used_cents)
        self.assertEqual(status.remaining_cents, 1041)

    def test_cursor_on_demand_limit_parses_used_and_omitted_zero(self) -> None:
        cases = (
            (
                {
                    "individualLimit": 5000,
                    "individualUsed": 1250,
                    "individualRemaining": 3750,
                    "limitType": "user",
                },
                5000,
                1250,
            ),
            ({"individualLimit": 5000, "limitType": "user"}, 5000, 0),
            ({"individualLimit": 5000, "individualRemaining": 4000}, 5000, 1000),
        )
        for spend, expected_limit, expected_used in cases:
            with self.subTest(spend=spend):
                usage = {"planUsage": {"totalPercentUsed": 10}, "spendLimitUsage": spend}
                provider = CursorProvider()
                provider._access_token = "fixture-token"
                with patch.object(CursorProvider, "_api_post", side_effect=[usage, {}]):
                    status = provider.fetch()
                self.assertEqual(status.on_demand_limit_cents, expected_limit)
                self.assertEqual(status.on_demand_used_cents, expected_used)

    def test_cursor_request_is_connect_post_with_bearer(self) -> None:
        provider = CursorProvider()
        provider._access_token = "fixture-token"
        resp = MagicMock()
        resp.read.return_value = json.dumps({"planUsage": {"totalPercentUsed": 10}}).encode()
        resp.__enter__.return_value = resp
        resp.__exit__.return_value = False
        with patch("urllib.request.urlopen", return_value=resp) as open_url:
            provider.fetch()
        request = open_url.call_args_list[0].args[0]
        self.assertEqual(request.method, "POST")
        self.assertEqual(request.full_url, CursorProvider._USAGE_URL)
        self.assertEqual(request.get_header("Authorization"), "Bearer fixture-token")
        self.assertEqual(request.get_header("Connect-protocol-version"), "1")

    def test_cursor_plan_endpoint_failure_is_non_fatal(self) -> None:
        import urllib.error

        usage = {"planUsage": {"totalPercentUsed": 25.0}}
        provider = CursorProvider()
        provider._access_token = "fixture-token"
        plan_error = urllib.error.HTTPError("https://api2.cursor.sh", 500, "boom", {}, None)
        with patch.object(CursorProvider, "_api_post", side_effect=[usage, plan_error]):
            status = provider.fetch()
        self.assertEqual(status.credit_percent_left, 75.0)
        self.assertIsNone(status.plan_name)

    def test_cursor_rejected_session_asks_for_relogin_and_drops_the_token(self) -> None:
        import urllib.error

        for code in (401, 403):
            provider = CursorProvider()
            provider._access_token = "fixture-token"
            error = urllib.error.HTTPError("https://api2.cursor.sh", code, "rejected", {}, None)
            with patch("urllib.request.urlopen", side_effect=error):
                with self.assertRaisesRegex(ProbeFailure, "run `cursor-agent login`"):
                    provider.fetch()
            self.assertEqual(provider._access_token, "")

    def test_cursor_http_and_network_failures_are_typed(self) -> None:
        import urllib.error

        provider = CursorProvider()
        provider._access_token = "fixture-token"
        error = urllib.error.HTTPError("https://api2.cursor.sh", 503, "down", {}, None)
        with (
            patch("urllib.request.urlopen", side_effect=error),
            self.assertRaisesRegex(ProbeFailure, "API error: HTTP 503"),
        ):
            provider.fetch()
        for blip in (urllib.error.URLError("dns failure"), TimeoutError("timed out")):
            provider = CursorProvider()
            provider._access_token = "fixture-token"
            with (
                self.subTest(blip=type(blip).__name__),
                patch("urllib.request.urlopen", side_effect=blip),
                self.assertRaisesRegex(ProbeFailure, "network error"),
            ):
                provider.fetch()

    def test_cursor_malformed_or_unrecognizable_usage_fails_closed(self) -> None:
        provider = CursorProvider()
        provider._access_token = "fixture-token"
        resp = MagicMock()
        resp.read.return_value = b"not-json"
        resp.__enter__.return_value = resp
        resp.__exit__.return_value = False
        with (
            patch("urllib.request.urlopen", return_value=resp),
            self.assertRaisesRegex(ProbeFailure, "malformed"),
        ):
            provider.fetch()
        for usage in ({}, {"planUsage": {"totalPercentUsed": "bad"}}):
            provider = CursorProvider()
            provider._access_token = "fixture-token"
            with (
                self.subTest(usage=usage),
                patch.object(CursorProvider, "_api_post", side_effect=[usage, {}]),
                self.assertRaisesRegex(ProbeFailure, "schema changed"),
            ):
                provider.fetch()

    def test_opencode_keychain_lookup_uses_fixed_item_without_persisting(self) -> None:
        with patch("gradus.providers.opencode_go.subprocess.run") as run:
            run.return_value = SimpleNamespace(returncode=0, stdout="go-key\n")
            self.assertEqual(OpenCodeGoProvider._load_keychain_api_key(), "go-key")
            args = run.call_args.args[0]
            self.assertEqual(args[:3], ["security", "find-generic-password", "-w"])
            self.assertEqual(args[3:], ["-s", "OpenCode Go", "-a", "default"])

    def test_opencode_keychain_failures_are_typed_without_diagnostics(self) -> None:
        for stderr, expected in (
            ("security: SecKeychain item not found", "item unavailable"),
            ("errSecAuthFailed: authorization denied", "Keychain access denied"),
            ("keychain is locked", "Keychain is locked"),
            ("User interaction is not allowed", "lookup requires interaction"),
        ):
            with (
                self.subTest(stderr=stderr),
                patch("gradus.providers.opencode_go.subprocess.run") as run,
            ):
                run.return_value = SimpleNamespace(returncode=1, stdout="", stderr=stderr)
                with self.assertRaisesRegex(FileNotFoundError, expected):
                    OpenCodeGoProvider._load_keychain_api_key()
            self.assertNotIn(stderr, expected)

    def test_opencode_missing_keychain_item_becomes_auth_required(self) -> None:
        with patch.object(
            OpenCodeGoProvider,
            "_load_keychain_api_key",
            side_effect=FileNotFoundError("item unavailable"),
        ):
            with self.assertRaisesRegex(ProbeFailure, "Keychain item unavailable"):
                OpenCodeGoProvider().fetch()

    def test_opencode_keychain_subprocess_failures_become_safe_typed_errors(self) -> None:
        secret = "keychain-secret-must-not-escape"
        failures = (
            subprocess.TimeoutExpired(["security", secret], timeout=10),
            OSError(secret),
            subprocess.SubprocessError(secret),
        )
        for failure in failures:
            with (
                self.subTest(failure=type(failure).__name__),
                patch("gradus.providers.opencode_go.subprocess.run", side_effect=failure),
            ):
                with self.assertRaises(ProbeFailure) as raised:
                    OpenCodeGoProvider().fetch()
            message = str(raised.exception)
            self.assertIn("OpenCode Go Keychain", message)
            self.assertNotIn(secret, message)

    def test_opencode_usage_mapping_and_no_credit_balance(self) -> None:
        response = {
            "usage": {
                "rolling": {"status": "ok", "percent": 12, "resetsAt": "2030-01-02T03:04:05Z"},
                "weekly": {"status": "ok", "percent": 34, "resetsAt": "2030-01-03T03:04:05Z"},
                "monthly": {"status": "ok", "percent": 56, "resetsAt": "2030-01-04T03:04:05Z"},
            },
            "balance": {"usd": 4.10},
        }
        provider = OpenCodeGoProvider()
        provider._api_key = "fixture-key"
        resp = MagicMock()
        resp.read.return_value = json.dumps(response).encode()
        resp.__enter__.return_value = resp
        resp.__exit__.return_value = False
        with patch("urllib.request.OpenerDirector.open", return_value=resp):
            status = provider.fetch()
        self.assertEqual(status.five_hour_percent_left, 88.0)
        self.assertEqual(status.weekly_percent_left, 66.0)
        self.assertEqual(status.monthly_percent_left, 44.0)
        self.assertIsNone(status.zen_credit)

    def test_opencode_request_is_get_bearer_and_key_is_not_logged(self) -> None:
        provider = OpenCodeGoProvider()
        provider._api_key = "fixture-key"
        response = {"usage": {"rolling": {"percent": 1, "resetsAt": None}}}
        resp = MagicMock()
        resp.read.return_value = json.dumps(response).encode()
        resp.__enter__.return_value = resp
        resp.__exit__.return_value = False
        with patch("urllib.request.OpenerDirector.open", return_value=resp) as open_url:
            status = provider.fetch()
        request = open_url.call_args.args[0]
        self.assertEqual(request.method, "GET")
        self.assertEqual(request.get_header("Authorization"), "Bearer fixture-key")
        self.assertNotIn("fixture-key", json.dumps(status.raw_text))

    def test_opencode_http_and_network_failures_are_typed(self) -> None:
        import urllib.error

        provider = OpenCodeGoProvider()
        provider._api_key = "fixture-key"
        error_401 = urllib.error.HTTPError("https://opencode.ai", 401, "rejected", {}, None)
        with (
            patch("urllib.request.OpenerDirector.open", side_effect=error_401),
            self.assertRaisesRegex(ProbeFailure, "API key rejected"),
        ):
            provider.fetch()

        provider = OpenCodeGoProvider()
        provider._api_key = "fixture-key"
        error_403 = urllib.error.HTTPError("https://opencode.ai", 403, "rejected", {}, None)
        with (
            patch("urllib.request.OpenerDirector.open", side_effect=error_403),
            self.assertRaisesRegex(ProbeFailure, "HTTP 403"),
        ):
            provider.fetch()
        provider = OpenCodeGoProvider()
        provider._api_key = "fixture-key"
        with (
            patch("urllib.request.OpenerDirector.open", side_effect=TimeoutError("timed out")),
            self.assertRaisesRegex(ProbeFailure, "network error"),
        ):
            provider.fetch()

    def test_opencode_missing_or_malformed_windows_fail_closed(self) -> None:
        for usage in ({}, {"rolling": {"percent": "bad"}}):
            provider = OpenCodeGoProvider()
            provider._api_key = "fixture-key"
            response = MagicMock()
            response.read.return_value = json.dumps({"usage": usage}).encode()
            response.__enter__.return_value = response
            response.__exit__.return_value = False
            with (
                patch("urllib.request.OpenerDirector.open", return_value=response),
                self.assertRaisesRegex(ProbeFailure, "recognizable windows"),
            ):
                provider.fetch()

    def test_opencode_malformed_json_fails_closed(self) -> None:
        provider = OpenCodeGoProvider()
        provider._api_key = "fixture-key"
        response = MagicMock()
        response.read.return_value = b"not-json"
        response.__enter__.return_value = response
        response.__exit__.return_value = False
        with (
            patch("urllib.request.OpenerDirector.open", return_value=response),
            self.assertRaisesRegex(ProbeFailure, "malformed"),
        ):
            provider.fetch()

    def test_opencode_schema_without_usage_fails_closed(self) -> None:
        provider = OpenCodeGoProvider()
        provider._api_key = "fixture-key"
        resp = MagicMock()
        resp.read.return_value = b"{}"
        resp.__enter__.return_value = resp
        resp.__exit__.return_value = False
        with (
            patch("urllib.request.OpenerDirector.open", return_value=resp),
            self.assertRaisesRegex(ProbeFailure, "schema changed"),
        ):
            provider.fetch()


class KeychainDocumentationContractTests(unittest.TestCase):
    """Docs must state the Keychain contract the automated suite cannot prove."""

    @staticmethod
    def _docs(*names: str) -> str:
        root = Path(__file__).parents[1]
        joined = "\n".join((root / name).read_text(encoding="utf-8") for name in names)
        return " ".join(joined.lower().split())

    def test_docs_describe_the_read_only_keychain_boundary(self) -> None:
        docs = self._docs("README.md", "INVARIANTS.md")

        self.assertIn("read fixed macos keychain generic-password items read-only", docs)
        self.assertIn("no refresh, no write-back, and no browser cookie", docs)

    def test_docs_describe_the_cursor_limitation(self) -> None:
        docs = self._docs("README.md")

        self.assertIn("cursor's dashboard api is private and undocumented", docs)
        self.assertIn("fails closed with an actionable `cursor-agent login` message", docs)
        self.assertIn("rather than a fabricated zero", docs)

    def test_docs_describe_the_one_way_rollback_shape(self) -> None:
        docs = self._docs("README.md", "INVARIANTS.md")

        self.assertIn("cursor_token.json", docs)
        self.assertIn("opencode_go_cookies.json", docs)
        self.assertIn("a new bridge release plus a fresh full disk access grant", docs)
        self.assertIn("dormant browser path", docs)

    def test_docs_name_the_separate_live_signed_keychain_validation_gate(self) -> None:
        docs = self._docs("README.md", "INVARIANTS.md", "RELEASE_CHECKLIST.md")

        self.assertIn("live signed-keychain validation", docs)
        self.assertIn("separate human-executed gate", docs)
        self.assertIn("outside `app/test-gate.sh`", docs)
        self.assertIn("live signed-keychain validation gate (human-executed)", docs)
