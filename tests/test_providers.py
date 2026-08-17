"""Provider helper tests."""

from __future__ import annotations

import ast
import base64
import json
import os
import stat
import subprocess
import tempfile
import time
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import MagicMock, patch

from gradus import providers
from gradus import snapshot as snapshot_module
from gradus.__main__ import _is_auth_error
from gradus.providers import (
    AntigravityProvider,
    ClaudeHttpProvider,
    CodexHttpProvider,
    CopilotHttpProvider,
    CursorProvider,
    OpenCodeGoProvider,
    ProbeFailure,
    ProviderSnapshot,
    VibeProvider,
    _AuthRejected,
    _classify_codex_windows,
    _codex_percent_left,
    _format_reset_time,
    _http_json,
    _is_jwt_expired,
    _seroval_decode,
    _write_debug_dump,
    fetch_provider_snapshot,
)
from gradus.providers import claude as claude_provider_module
from gradus.providers._codex_helpers import _extract_spark_window
from gradus.snapshot import _is_transient_probe_error


class ProviderHelperTests(unittest.TestCase):
    def test_copilot_monthly_reset_label_uses_local_time(self) -> None:
        label = CopilotHttpProvider._monthly_reset_label()
        self.assertTrue(label.startswith("Resets "))
        self.assertNotIn("UTC", label)
        self.assertIn(" at ", label)


class FetchProviderSnapshotTests(unittest.TestCase):
    def test_generic_provider_exception_uses_fixed_safe_error_and_debug_detail(self) -> None:
        sentinel = "provider-secret-sentinel"

        class FakeProvider:
            def fetch(self) -> None:
                raise RuntimeError(sentinel)

        snapshot = fetch_provider_snapshot("Codex", FakeProvider(), debug=True)

        self.assertFalse(snapshot.ok)
        self.assertEqual(snapshot.error, "provider probe failed")
        self.assertNotIn(sentinel, snapshot.error or "")
        self.assertIn(sentinel, snapshot.debug_detail or "")

        quiet_snapshot = fetch_provider_snapshot("Codex", FakeProvider(), debug=False)
        self.assertIsNone(quiet_snapshot.debug_detail)
        for build_payload in (
            snapshot_module.build_snapshot_payload,
            snapshot_module.build_snapshot_v2_payload,
        ):
            payload_json = json.dumps(build_payload([snapshot], datetime(2026, 1, 1)))
            self.assertNotIn(sentinel, payload_json)

    def test_status_serialization_exception_uses_fixed_safe_error_and_debug_detail(self) -> None:
        sentinel = "status-secret-sentinel"

        class FakeStatus:
            def to_dict(self) -> dict[str, object]:
                raise RuntimeError(sentinel)

        class FakeProvider:
            def fetch(self) -> FakeStatus:
                return FakeStatus()

        snapshot = fetch_provider_snapshot("Codex", FakeProvider(), debug=True)

        self.assertFalse(snapshot.ok)
        self.assertEqual(snapshot.error, "provider probe failed")
        self.assertNotIn(sentinel, snapshot.error or "")
        self.assertIn(sentinel, snapshot.debug_detail or "")

        quiet_snapshot = fetch_provider_snapshot("Codex", FakeProvider(), debug=False)
        self.assertIsNone(quiet_snapshot.debug_detail)
        for build_payload in (
            snapshot_module.build_snapshot_payload,
            snapshot_module.build_snapshot_v2_payload,
        ):
            payload_json = json.dumps(build_payload([snapshot], datetime(2026, 1, 1)))
            self.assertNotIn(sentinel, payload_json)

    def test_read_timeout_classifies_as_transient_not_a_hard_failure(self) -> None:
        """A urllib read timeout must reach the device as a retryable error.

        ``socket.timeout`` is ``TimeoutError`` on 3.10+, and ``TimeoutError``
        is NOT a subclass of ``urllib.error.URLError`` -- it is an ``OSError``.
        So ``_http_json``'s URLError branch never sees a *read* timeout and it
        lands in the generic catch-all, which used to flatten every exception
        to "provider probe failed". That string matches no transient marker, so
        `_merge_with_previous` declined to serve the last-known-good reading
        and a two-second network blip published a failure card to iPhone and
        iPad while the TUI, on its own cycle, looked fine.
        """
        import socket
        import urllib.error

        # The two facts the bug rests on, asserted rather than assumed. If a
        # future Python decouples these, raising `TimeoutError` below would
        # stop resembling what urllib actually raises and this test would
        # quietly stop testing the real path.
        self.assertIs(socket.timeout, TimeoutError)
        self.assertFalse(issubclass(TimeoutError, urllib.error.URLError))

        class FakeProvider:
            def fetch(self) -> None:
                raise TimeoutError("The read operation timed out")

        snapshot = fetch_provider_snapshot("Antigravity", FakeProvider(), debug=False)

        self.assertFalse(snapshot.ok)
        self.assertEqual(snapshot.error, "provider probe timed out")
        # The payoff: the classifier must accept what the catch-all emits.
        # Asserting the string alone would re-create the original gap, where
        # both halves were correct and only the seam between them was wrong.
        self.assertTrue(_is_transient_probe_error(snapshot))

    def test_connection_error_classifies_as_transient(self) -> None:
        class FakeProvider:
            def fetch(self) -> None:
                raise ConnectionResetError("Connection reset by peer")

        snapshot = fetch_provider_snapshot("Antigravity", FakeProvider(), debug=False)

        self.assertEqual(snapshot.error, "provider probe network error")
        self.assertTrue(_is_transient_probe_error(snapshot))

    def test_transient_mapping_still_withholds_the_exception_text(self) -> None:
        """Classifying by type must not become an excuse to publish the message.

        ``AntigravityProvider._load_keychain_token`` embeds `security`
        subprocess output in its exception, so raw text on ``error`` would push
        credential-adjacent strings through CloudKit to both devices. Type is
        safe to branch on; the message stays on the ``--debug`` channel.
        """
        sentinel = "timeout-secret-sentinel"

        class FakeProvider:
            def fetch(self) -> None:
                raise TimeoutError(sentinel)

        snapshot = fetch_provider_snapshot("Antigravity", FakeProvider(), debug=True)

        self.assertEqual(snapshot.error, "provider probe timed out")
        self.assertNotIn(sentinel, snapshot.error or "")
        self.assertIn(sentinel, snapshot.debug_detail or "")

        quiet = fetch_provider_snapshot("Antigravity", FakeProvider(), debug=False)
        self.assertIsNone(quiet.debug_detail)
        for build_payload in (
            snapshot_module.build_snapshot_payload,
            snapshot_module.build_snapshot_v2_payload,
        ):
            payload_json = json.dumps(build_payload([snapshot], datetime(2026, 1, 1)))
            self.assertNotIn(sentinel, payload_json)

    def test_subprocess_timeout_keeps_debug_detail_off_the_snapshot_surface(self) -> None:
        """A CLI timeout is retryable, with command detail debug-only."""
        sentinel = "credential-helper-timeout-detail"

        class FakeProvider:
            def fetch(self) -> None:
                raise subprocess.TimeoutExpired(["provider", sentinel], timeout=7)

        snapshot = fetch_provider_snapshot("Copilot", FakeProvider(), debug=True)

        self.assertFalse(snapshot.ok)
        self.assertEqual(snapshot.error, "provider probe timed out")
        self.assertIn(sentinel, snapshot.debug_detail or "")
        self.assertNotIn(sentinel, snapshot.error or "")

        quiet_snapshot = fetch_provider_snapshot("Copilot", FakeProvider(), debug=False)
        self.assertIsNone(quiet_snapshot.debug_detail)
        payload_json = json.dumps(
            snapshot_module.build_snapshot_payload([snapshot], datetime(2026, 1, 1))
        )
        self.assertNotIn(sentinel, payload_json)

    def test_headless_debug_detail_omits_the_dump_hint_it_cannot_honor(self) -> None:
        """Don't name a dump file that was never written.

        `_write_debug_dump` is a no-op under headless (INV-2: `--json` and
        `--write-snapshot` must have zero side effects), but `debug_detail`
        used to embed `raw dump: <path>` unconditionally -- so the two paths a
        human is most likely to be debugging pointed at a nonexistent file.
        """
        import gradus.providers as providers

        class FakeProvider:
            def fetch(self) -> None:
                raise ProbeFailure("HTTP 500", "raw body text")

        try:
            providers.set_headless(True)
            headless = fetch_provider_snapshot("Codex", FakeProvider(), debug=True)
        finally:
            providers.set_headless(False)

        self.assertNotIn("raw dump:", headless.debug_detail or "")
        # The real content still survives; only the false pointer is dropped.
        self.assertIn("HTTP 500", headless.debug_detail or "")
        self.assertIn("raw body text", headless.debug_detail or "")

        interactive = fetch_provider_snapshot("Codex", FakeProvider(), debug=True)
        self.assertIn("raw dump:", interactive.debug_detail or "")

    def test_unrecognized_exception_type_stays_opaque(self) -> None:
        """Only the two known-retryable families get a specific message.

        Anything else keeps the opaque generic string, so a new failure mode
        cannot accidentally inherit "retry me" semantics it has not earned.
        """

        class FakeProvider:
            def fetch(self) -> None:
                raise ValueError("something structural is wrong")

        snapshot = fetch_provider_snapshot("Antigravity", FakeProvider(), debug=False)

        self.assertEqual(snapshot.error, "provider probe failed")
        self.assertFalse(_is_transient_probe_error(snapshot))


class NetworkFailureClassificationTests(unittest.TestCase):
    """Every provider must classify an unreachable network as *transient*.

    The contract this locks: a provider's failure message is not free prose,
    it is the input to ``snapshot._is_transient_probe_error``, which decides
    whether ``_merge_with_previous`` serves the last-known-good reading or
    publishes a failure card to iPhone and iPad. Classification has to run off
    the string because it also runs against snapshots read back from disk,
    where the original exception is long gone -- so provider wording is a de
    facto API, and this is the test that says so.

    It existed because nothing did. OpenCode Go and Vibe both caught
    ``URLError`` correctly and then described it in accurate English that
    matched no marker ("Could not reach opencode.ai"), so a DNS blip read as a
    hard failure on both devices. Cursor is included even though it has always
    been correct -- an untested correct case is one refactor from being an
    untested broken one.
    """

    def _dns_failure(self):
        import socket
        import urllib.error

        # A real resolver failure, not a synthetic string: gaierror is what
        # macOS actually raises when the network drops mid-probe.
        return urllib.error.URLError(socket.gaierror(8, "nodename nor servname provided"))

    def _assert_transient(self, snapshot: ProviderSnapshot, *, provider: str) -> None:
        self.assertFalse(snapshot.ok, f"{provider}: probe should have failed")
        self.assertTrue(
            _is_transient_probe_error(snapshot),
            f"{provider}: {snapshot.error!r} matches no transient marker, so a "
            f"network blip would publish a failure card instead of serving cache",
        )
        # A network error must not be mistaken for an auth problem: that would
        # offer the user a `login` fix action for a failure logging in cannot fix.
        self.assertFalse(_is_auth_error(snapshot), f"{provider}: misread as an auth error")

    def test_opencode_go_dns_failure_is_transient(self) -> None:
        provider = OpenCodeGoProvider()
        provider._auth_cookie = "cookie-value"  # skips _acquire's disk path
        opener = MagicMock()
        opener.open.side_effect = self._dns_failure()

        with patch("urllib.request.build_opener", return_value=opener):
            snapshot = fetch_provider_snapshot("OpenCode Go", provider, debug=False)

        self._assert_transient(snapshot, provider="OpenCode Go")

    def test_vibe_dns_failure_is_transient(self) -> None:
        provider = VibeProvider(project_root="/nonexistent")
        provider._ory_name = "ory_session"
        provider._ory_value = "value"
        provider._csrf = "csrf"

        with patch("urllib.request.urlopen", side_effect=self._dns_failure()):
            snapshot = fetch_provider_snapshot("Vibe", provider, debug=False)

        self._assert_transient(snapshot, provider="Vibe")

    def test_cursor_dns_failure_is_transient(self) -> None:
        """Cursor is already correct; this pins it.

        `cursor.fetch` catches ``(OSError, URLError)`` together, which works
        because ``URLError`` derives from ``OSError``. Narrowing that handler
        later would silently reopen the same bug.
        """
        provider = CursorProvider()
        provider._access_token = "token"

        with patch("urllib.request.urlopen", side_effect=self._dns_failure()):
            snapshot = fetch_provider_snapshot("Cursor", provider, debug=False)

        self._assert_transient(snapshot, provider="Cursor")

    def test_cursor_network_blip_on_the_post_refresh_retry_is_transient(self) -> None:
        """401 → refresh → blip. The retry sits inside the HTTPError block.

        Its sibling ``except (OSError, URLError)`` cannot catch it, so before
        this the blip escaped to the catch-all and read as a hard failure.
        """
        import urllib.error

        provider = CursorProvider()
        provider._access_token = "token"
        provider._refresh_token = "refresh"

        responses = [
            urllib.error.HTTPError("https://api.cursor.com", 401, "Unauthorized", {}, None),
            self._dns_failure(),
        ]
        with (
            patch.object(CursorProvider, "_do_token_refresh"),
            patch.object(CursorProvider, "_can_refresh", True),
            patch.object(CursorProvider, "_api_post", side_effect=responses),
        ):
            snapshot = fetch_provider_snapshot("Cursor", provider, debug=False)

        self._assert_transient(snapshot, provider="Cursor retry")
        # Two layers now cover this, and they are not equivalent. Without the
        # retry's own handler the exception still escapes to the catch-all,
        # where `_safe_probe_error`'s URLError backstop maps it to the generic
        # "provider probe network error" -- transient, so the merge behavior is
        # already correct. Asserting the provider-specific wording is what
        # distinguishes the two, and it is the reason to keep both: the
        # backstop cannot name the provider or the cause.
        self.assertIn("Cursor API network error", snapshot.error)

    def test_cursor_401_surviving_the_refresh_is_actionable_not_generic(self) -> None:
        """A dead session must say so, not collapse to "provider probe failed".

        This is the same escape as above with the opposite required outcome:
        the user can fix it by signing in, so the message has to reach
        ``_is_auth_error`` and light up the fix action.
        """
        import urllib.error

        provider = CursorProvider()
        provider._access_token = "token"
        provider._refresh_token = "refresh"

        unauthorized = lambda: urllib.error.HTTPError(  # noqa: E731
            "https://api.cursor.com", 401, "Unauthorized", {}, None
        )
        with (
            patch.object(CursorProvider, "_do_token_refresh"),
            patch.object(CursorProvider, "_can_refresh", True),
            patch.object(CursorProvider, "_api_post", side_effect=[unauthorized(), unauthorized()]),
            patch.object(CursorProvider, "_clear_cache"),
        ):
            snapshot = fetch_provider_snapshot("Cursor", provider, debug=False)

        self.assertFalse(snapshot.ok)
        self.assertIn("session expired", snapshot.error.lower())
        self.assertTrue(_is_auth_error(snapshot), "should offer the sign-in fix action")

    def test_catch_all_backstop_maps_urlerror_but_not_httperror(self) -> None:
        """Ordering guard inside ``_safe_probe_error``.

        ``HTTPError`` subclasses ``URLError``. If the URLError branch ran
        first, a 401 reaching the catch-all would classify as transient and
        ``_merge_with_previous`` would serve stale data forever while hiding a
        dead session -- silent staleness, worse than the failure card the
        transient mapping exists to prevent.
        """
        import urllib.error

        class Unreachable:
            def fetch(self_inner):
                raise self._dns_failure()

        class Unauthorized:
            def fetch(self_inner):
                raise urllib.error.HTTPError(
                    "https://example.invalid", 401, "Unauthorized", {}, None
                )

        transient = fetch_provider_snapshot("Codex", Unreachable(), debug=False)
        self.assertEqual(transient.error, "provider probe network error")
        self.assertTrue(_is_transient_probe_error(transient))

        opaque = fetch_provider_snapshot("Codex", Unauthorized(), debug=False)
        self.assertEqual(opaque.error, "provider probe failed")
        self.assertFalse(
            _is_transient_probe_error(opaque),
            "a 401 must not be served from cache -- that hides a dead session",
        )

    def test_shared_http_helper_dns_failure_is_transient(self) -> None:
        """Covers every provider that probes through ``_http_json``.

        Claude, Codex, Antigravity and Copilot share this one branch, so
        classifying it here classifies it for all four.
        """

        class FakeProvider:
            def fetch(self_inner):
                return _http_json("https://example.invalid/usage")

        with patch("urllib.request.urlopen", side_effect=self._dns_failure()):
            snapshot = fetch_provider_snapshot("Claude", FakeProvider(), debug=False)

        self._assert_transient(snapshot, provider="_http_json")


class FormatResetTimeTests(unittest.TestCase):
    def test_iso_string_with_z(self) -> None:
        result = _format_reset_time("2026-05-01T12:00:00Z")
        self.assertIsNotNone(result)
        assert result is not None
        self.assertTrue(result.startswith("Resets "))
        self.assertIn(" at ", result)

    def test_iso_string_without_z(self) -> None:
        result = _format_reset_time("2026-05-01T12:00:00+00:00")
        self.assertIsNotNone(result)
        assert result is not None
        self.assertTrue(result.startswith("Resets "))

    def test_epoch_seconds(self) -> None:
        # 2026-01-01 00:00:00 UTC = 1767225600
        result = _format_reset_time(1767225600)
        self.assertIsNotNone(result)
        assert result is not None
        self.assertTrue(result.startswith("Resets "))

    def test_epoch_milliseconds(self) -> None:
        result = _format_reset_time(1767225600000)  # > 1e12 → treated as ms
        self.assertIsNotNone(result)
        assert result is not None
        self.assertTrue(result.startswith("Resets "))

    def test_none_input(self) -> None:
        self.assertIsNone(_format_reset_time(None))

    def test_invalid_string(self) -> None:
        self.assertIsNone(_format_reset_time("not-a-date"))


class HttpJsonHelperTests(unittest.TestCase):
    def test_success(self) -> None:
        mock_resp = MagicMock()
        mock_resp.read.return_value = b'{"ok": true}'
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        with patch("urllib.request.urlopen", return_value=mock_resp):
            result = _http_json("https://example.com/api")
        self.assertEqual(result, {"ok": True})

    def test_http_error_raises_probe_failure(self) -> None:
        import urllib.error

        with patch(
            "urllib.request.urlopen",
            side_effect=urllib.error.HTTPError(
                "https://example.com", 429, "Too Many Requests", {}, None
            ),
        ):
            with self.assertRaises(ProbeFailure) as ctx:
                _http_json("https://example.com/api")
        self.assertIn("429", str(ctx.exception))

    def test_network_error_raises_probe_failure(self) -> None:
        import urllib.error

        with patch(
            "urllib.request.urlopen",
            side_effect=urllib.error.URLError("connection refused"),
        ):
            with self.assertRaises(ProbeFailure):
                _http_json("https://example.com/api")

    def test_invalid_json_raises_probe_failure(self) -> None:
        mock_resp = MagicMock()
        mock_resp.read.return_value = b"not json"
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        with patch("urllib.request.urlopen", return_value=mock_resp):
            with self.assertRaises(ProbeFailure):
                _http_json("https://example.com/api")


class CopilotHttpProviderTests(unittest.TestCase):
    # Real API uses percent_remaining + remaining directly; quota_reset_date_utc top-level
    PAID_RESPONSE = {
        "quota_snapshots": {
            "premium_interactions": {
                "percent_remaining": 95.0,
                "remaining": 285,
                "unlimited": False,
            }
        },
        "quota_reset_date_utc": "2026-05-01T00:00:00.000Z",
    }
    FREE_RESPONSE = {
        "quota_snapshots": {
            "premium_interactions": {
                "percent_remaining": 10.0,
                "remaining": 5,
                "unlimited": False,
            }
        },
        "quota_reset_date_utc": "2026-05-01T00:00:00.000Z",
    }

    def _make_provider(self) -> CopilotHttpProvider:
        with patch("shutil.which", return_value="/usr/bin/gh"):
            return CopilotHttpProvider()

    def test_token_fallback_timeout_is_transient_and_retains_recent_prior(self) -> None:
        """A ``gh auth token`` timeout must retain the last healthy Copilot window.

        This exercises the complete seam: the token fallback raises
        ``subprocess.TimeoutExpired``, the provider wrapper maps it to a safe
        transient error, and snapshot retention carries the recent prior
        values while preserving the current failure state.
        """
        provider = self._make_provider()
        timeout = subprocess.TimeoutExpired(["gh", "auth", "token"], timeout=10)
        with (
            patch.object(provider, "_read_hosts_yml", return_value=None),
            patch("gradus.providers.copilot._is_headless", return_value=False),
            patch("subprocess.run", side_effect=timeout),
        ):
            current = fetch_provider_snapshot("Copilot", provider, debug=False)

        self.assertFalse(current.ok)
        self.assertEqual(current.error, "provider probe timed out")
        self.assertTrue(_is_transient_probe_error(current))

        observed_at = datetime(2026, 1, 1, 12, 0, 0)
        prior = snapshot_module.build_snapshot_payload(
            [
                ProviderSnapshot(
                    name="Copilot",
                    ok=True,
                    source="api",
                    data={"premium_percent_left": 82, "premium_reset": "in 5d"},
                )
            ],
            observed_at,
        )
        payload = snapshot_module.build_snapshot_payload(
            [current], observed_at + timedelta(seconds=100), prior=prior
        )
        copilot = next(entry for entry in payload["providers"] if entry["name"] == "Copilot")
        self.assertFalse(copilot["ok"])
        self.assertEqual(copilot["error"], "provider probe timed out")
        self.assertEqual(copilot["windows"][0]["percent_left"], 82)

    def test_token_fallback_timeout_stops_retaining_prior_at_stale_boundary(self) -> None:
        """Retention is strict: age 299s carries, age 300s expires."""
        provider = self._make_provider()
        timeout = subprocess.TimeoutExpired(["gh", "auth", "token"], timeout=10)
        with (
            patch.object(provider, "_read_hosts_yml", return_value=None),
            patch("gradus.providers.copilot._is_headless", return_value=False),
            patch("subprocess.run", side_effect=timeout),
        ):
            current = fetch_provider_snapshot("Copilot", provider, debug=False)

        observed_at = datetime(2026, 1, 1, 12, 0, 0)
        for age in (299, 300):
            with self.subTest(age=age):
                prior = snapshot_module.build_snapshot_payload(
                    [
                        ProviderSnapshot(
                            name="Copilot",
                            ok=True,
                            source="api",
                            data={"premium_percent_left": 82, "premium_reset": "in 5d"},
                        )
                    ],
                    observed_at,
                )
                payload = snapshot_module.build_snapshot_payload(
                    [current], observed_at + timedelta(seconds=age), prior=prior
                )
                copilot = next(
                    entry for entry in payload["providers"] if entry["name"] == "Copilot"
                )
                self.assertFalse(copilot["ok"])
                self.assertEqual(copilot["error"], "provider probe timed out")
                if age < snapshot_module.STALE_THRESHOLD_SECONDS:
                    self.assertEqual(copilot["windows"][0]["percent_left"], 82)
                else:
                    self.assertEqual(copilot["windows"], [])
                    self.assertIsNone(copilot["observed_at"])

    def test_paid_tier_field_mapping(self) -> None:
        provider = self._make_provider()
        with (
            patch("gradus.providers._base._http_json", return_value=self.PAID_RESPONSE),
            patch("subprocess.run") as mock_run,
        ):
            mock_run.return_value = MagicMock(returncode=0, stdout="gho_testtoken\n")
            status = provider.fetch()
        self.assertIsNotNone(status.premium_percent_left)
        assert status.premium_percent_left is not None
        self.assertAlmostEqual(status.premium_percent_left, 95.0, places=1)
        self.assertEqual(status.premium_requests, 285)
        self.assertIsNotNone(status.premium_reset)

    def test_free_tier_field_mapping(self) -> None:
        provider = self._make_provider()
        with (
            patch("gradus.providers._base._http_json", return_value=self.FREE_RESPONSE),
            patch("subprocess.run") as mock_run,
        ):
            mock_run.return_value = MagicMock(returncode=0, stdout="gho_testtoken\n")
            status = provider.fetch()
        self.assertIsNotNone(status.premium_percent_left)
        assert status.premium_percent_left is not None
        self.assertAlmostEqual(status.premium_percent_left, 10.0, places=1)
        self.assertEqual(status.premium_requests, 5)

    def test_401_raises_probe_failure(self) -> None:
        provider = self._make_provider()
        with (
            patch("gradus.providers._base._http_json", side_effect=ProbeFailure("HTTP 401", "")),
            patch("subprocess.run") as mock_run,
        ):
            mock_run.return_value = MagicMock(returncode=0, stdout="gho_testtoken\n")
            with self.assertRaises(ProbeFailure) as ctx:
                provider.fetch()
        self.assertIn("gh auth login", str(ctx.exception))

    def test_read_hosts_yml_extracts_token(self) -> None:
        provider = CopilotHttpProvider()
        content = "github.com:\n    oauth_token: gho_testtoken\n    user: dave\n"
        with patch("pathlib.Path.read_text", return_value=content):
            with patch("pathlib.Path.exists", return_value=True):
                self.assertEqual(provider._read_hosts_yml(), "gho_testtoken")

    def test_read_hosts_yml_user_before_oauth_token(self) -> None:
        provider = CopilotHttpProvider()
        content = "github.com:\n    user: dave\n    oauth_token: gho_reorderedtoken\n"
        with patch("pathlib.Path.read_text", return_value=content):
            with patch("pathlib.Path.exists", return_value=True):
                self.assertEqual(provider._read_hosts_yml(), "gho_reorderedtoken")

    def test_read_hosts_yml_no_oauth_token(self) -> None:
        provider = CopilotHttpProvider()
        content = "github.com:\n    user: dave\n"
        with patch("pathlib.Path.read_text", return_value=content):
            with patch("pathlib.Path.exists", return_value=True):
                self.assertIsNone(provider._read_hosts_yml())

    def test_read_hosts_yml_file_missing(self) -> None:
        provider = CopilotHttpProvider()
        with patch("pathlib.Path.exists", return_value=False):
            self.assertIsNone(provider._read_hosts_yml())

    def test_read_hosts_yml_multiple_hosts(self) -> None:
        provider = CopilotHttpProvider()
        content = (
            "github.com:\n    oauth_token: gho_first\n    user: dave\n"
            "enterprise.github.com:\n    oauth_token: gho_enterprise\n"
        )
        with patch("pathlib.Path.read_text", return_value=content):
            with patch("pathlib.Path.exists", return_value=True):
                self.assertEqual(provider._read_hosts_yml(), "gho_first")


class VibeProviderTests(unittest.TestCase):
    RESPONSE = {
        "usage_percentage": 1.0841208999999998,
        "payg_enabled": False,
        "reset_at": "2026-05-01T00:00:00Z",
        "start_date": "2026-04-01T00:00:00Z",
        "end_date": "2026-04-30T23:59:59.999Z",
        "vibe": {"models": {}},
    }

    def setUp(self) -> None:
        # Isolate _CACHE_PATH so constructing VibeProvider can't overwrite the
        # repo's real .cache/vibe_cookies.json with whatever cookies Safari holds.
        self._tmpdir = tempfile.TemporaryDirectory()
        self._cache_path = Path(self._tmpdir.name) / "vibe_cookies.json"
        self._patcher = patch.object(VibeProvider, "_CACHE_PATH", self._cache_path)
        self._patcher.start()

    def tearDown(self) -> None:
        self._patcher.stop()
        self._tmpdir.cleanup()

    def test_usage_percentage_is_not_scaled_again(self) -> None:
        provider = VibeProvider(".")
        provider._ory_name = "ory_session_test"
        provider._ory_value = "token"
        provider._csrf = "csrf"
        body = json.dumps(self.RESPONSE).encode("utf-8")
        mock_resp = MagicMock()
        mock_resp.read.return_value = body
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        with patch("urllib.request.urlopen", return_value=mock_resp):
            status = provider.fetch()
        self.assertAlmostEqual(status.usage_percent, 1.0841, places=4)
        self.assertEqual(status.start_date, "2026-04-01T00:00:00Z")
        self.assertEqual(status.end_date, "2026-04-30T23:59:59.999Z")

    def test_post_rebrand_response_derives_cycle_boundaries(self) -> None:
        # 2026-05-28 Le Chat → Vibe rebrand dropped start_date/end_date.
        rebrand_response = {
            "usage_percentage": 9.089239716666667,
            "quota_changed_this_month": False,
            "payg_enabled": False,
            "reset_at": "2026-06-01T00:00:00Z",
        }
        provider = VibeProvider(".")
        provider._ory_name = "ory_session_test"
        provider._ory_value = "token"
        provider._csrf = "csrf"
        body = json.dumps(rebrand_response).encode("utf-8")
        mock_resp = MagicMock()
        mock_resp.read.return_value = body
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        with patch("urllib.request.urlopen", return_value=mock_resp):
            status = provider.fetch()
        self.assertAlmostEqual(status.usage_percent, 9.0892, places=4)
        self.assertEqual(status.start_date, "2026-05-01T00:00:00+00:00")
        self.assertEqual(status.end_date, "2026-06-01T00:00:00+00:00")

    def test_year_rollover_derives_previous_december_start(self) -> None:
        # reset_at in January should yield start_date = Dec 1 of previous year.
        rollover_response = {
            "usage_percentage": 12.5,
            "payg_enabled": False,
            "reset_at": "2027-01-01T00:00:00Z",
        }
        provider = VibeProvider(".")
        provider._ory_name = "ory_session_test"
        provider._ory_value = "token"
        provider._csrf = "csrf"
        body = json.dumps(rollover_response).encode("utf-8")
        mock_resp = MagicMock()
        mock_resp.read.return_value = body
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        with patch("urllib.request.urlopen", return_value=mock_resp):
            status = provider.fetch()
        self.assertEqual(status.start_date, "2026-12-01T00:00:00+00:00")
        self.assertEqual(status.end_date, "2027-01-01T00:00:00+00:00")

    def test_missing_reset_at_leaves_boundaries_none(self) -> None:
        # Without reset_at there is no anchor to derive from — both fields stay None.
        no_reset_response = {
            "usage_percentage": 4.2,
            "payg_enabled": False,
        }
        provider = VibeProvider(".")
        provider._ory_name = "ory_session_test"
        provider._ory_value = "token"
        provider._csrf = "csrf"
        body = json.dumps(no_reset_response).encode("utf-8")
        mock_resp = MagicMock()
        mock_resp.read.return_value = body
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        with patch("urllib.request.urlopen", return_value=mock_resp):
            status = provider.fetch()
        self.assertAlmostEqual(status.usage_percent, 4.2, places=4)
        self.assertIsNone(status.start_date)
        self.assertIsNone(status.end_date)
        self.assertIsNone(status.reset_at)


class CursorProviderTests(unittest.TestCase):
    USAGE_RESPONSE = {
        "billingCycleStart": 1775994366000,
        "billingCycleEnd": 1778586366000,
        "planUsage": {
            "apiPercentUsed": 1.5555555555555556,
            "autoPercentUsed": 6.644444444444445,
            "includedSpend": 369,
            "limit": 2000,
            "remaining": 1631,
            "totalPercentUsed": 4.1000000000000005,
            "totalSpend": 369,
        },
    }
    PLAN_RESPONSE = {
        "planInfo": {
            "name": "pro",
        }
    }

    def setUp(self) -> None:
        # Isolate _CACHE_PATH so constructing CursorProvider can't overwrite the
        # repo's real .cache/cursor_token.json with whatever JWT Safari holds.
        self._tmpdir = tempfile.TemporaryDirectory()
        self._cache_path = Path(self._tmpdir.name) / "cursor_token.json"
        self._patcher = patch.object(CursorProvider, "_CACHE_PATH", self._cache_path)
        self._patcher.start()

    def tearDown(self) -> None:
        self._patcher.stop()
        self._tmpdir.cleanup()

    def test_cursor_nested_plan_usage_mapping(self) -> None:
        provider = CursorProvider()
        provider._access_token = "cursor-access-token"
        provider._refresh_token = "cursor-refresh-token"
        with patch.object(
            provider,
            "_api_post",
            side_effect=[self.USAGE_RESPONSE, self.PLAN_RESPONSE],
        ):
            status = provider.fetch()
        self.assertAlmostEqual(status.credit_percent_left, 81.55, places=2)
        self.assertAlmostEqual(status.auto_percent_used, 6.644444444444445)
        self.assertAlmostEqual(status.api_percent_used, 1.5555555555555556)
        self.assertEqual(status.remaining_cents, 1631)
        self.assertEqual(status.limit_cents, 2000)
        self.assertEqual(status.plan_name, "pro")
        self.assertEqual(status.billing_cycle_start, "2026-04-12T07:46:06-04:00")
        self.assertEqual(status.billing_cycle_end_iso, "2026-05-12T07:46:06-04:00")
        # Round-trip: both values must be tz-aware and subtraction must yield a timedelta
        start_parsed = datetime.fromisoformat(status.billing_cycle_start)
        end_parsed = datetime.fromisoformat(status.billing_cycle_end_iso)
        delta = end_parsed - start_parsed
        self.assertIsInstance(delta.total_seconds(), float)

    def test_cursor_falls_back_to_total_percent_used_when_cents_missing(self) -> None:
        provider = CursorProvider()
        provider._access_token = "cursor-access-token"
        provider._refresh_token = "cursor-refresh-token"
        usage_response = {
            "billingCycleStart": 1775994366000,
            "billingCycleEnd": 1778586366000,
            "planUsage": {
                "totalPercentUsed": 4.1,
            },
        }
        with patch.object(
            provider,
            "_api_post",
            side_effect=[usage_response, self.PLAN_RESPONSE],
        ):
            status = provider.fetch()
        self.assertAlmostEqual(status.credit_percent_left, 95.9, places=1)


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


class CursorTokenCacheTests(unittest.TestCase):
    """Cursor reads its credential cache; the bridge is the only browser reader."""

    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self._cache_path = Path(self._tmpdir.name) / "cursor_token.json"
        # Patch class attribute so provider instances use the tempfile.
        self._patcher = patch.object(CursorProvider, "_CACHE_PATH", self._cache_path)
        self._patcher.start()

    def tearDown(self) -> None:
        self._patcher.stop()
        self._tmpdir.cleanup()

    def test_cache_is_the_only_credential_source(self) -> None:
        valid_jwt = _make_jwt(3600)
        self._cache_path.parent.mkdir(parents=True, exist_ok=True)
        self._cache_path.write_text(
            json.dumps({"access_token": valid_jwt, "refresh_token": "rt"}),
            encoding="utf-8",
        )
        provider = CursorProvider()
        provider._acquire()
        self.assertEqual(provider._access_token, valid_jwt)
        self.assertEqual(provider._refresh_token, "rt")
        self.assertEqual(provider._token_source, "cache")

    def test_expired_cache_is_not_used(self) -> None:
        self._cache_path.parent.mkdir(parents=True, exist_ok=True)
        self._cache_path.write_text(
            json.dumps({"access_token": _make_jwt(-3600)}),
            encoding="utf-8",
        )
        provider = CursorProvider()
        provider._acquire()
        self.assertIsNone(provider._access_token)

    def test_missing_cache_does_not_create_credentials(self) -> None:
        provider = CursorProvider()
        provider._acquire()
        self.assertFalse(self._cache_path.exists())

    def test_401_clears_cache(self) -> None:
        """A rejected token must be evicted so the next startup re-reads from Safari."""
        import urllib.error as ue

        valid_jwt = _make_jwt(3600)
        self._cache_path.parent.mkdir(parents=True, exist_ok=True)
        self._cache_path.write_text(json.dumps({"access_token": valid_jwt}), encoding="utf-8")
        provider = CursorProvider()
        err = ue.HTTPError("u", 401, "Unauthorized", {}, None)  # type: ignore[arg-type]
        with patch.object(provider, "_api_post", side_effect=err):
            with self.assertRaises(ProbeFailure):
                provider.fetch()
        self.assertFalse(self._cache_path.exists())


class VibeCookieCacheTests(unittest.TestCase):
    """Vibe reads bridge-written cache files only."""

    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self._cache_path = Path(self._tmpdir.name) / "vibe_cookies.json"
        self._patcher = patch.object(VibeProvider, "_CACHE_PATH", self._cache_path)
        self._patcher.start()

    def tearDown(self) -> None:
        self._patcher.stop()
        self._tmpdir.cleanup()

    def test_cache_is_the_only_credential_source(self) -> None:
        self._cache_path.parent.mkdir(parents=True, exist_ok=True)
        self._cache_path.write_text(
            json.dumps(
                {"ory_session_name": "ory_session_x", "ory_session_value": "v", "csrftoken": "c"}
            ),
            encoding="utf-8",
        )
        provider = VibeProvider(project_root=self._tmpdir.name)
        provider._acquire()
        self.assertEqual(provider._ory_name, "ory_session_x")
        self.assertEqual(provider._ory_value, "v")
        self.assertEqual(provider._csrf, "c")

    def test_missing_cache_does_not_create_credentials(self) -> None:
        provider = VibeProvider(project_root=self._tmpdir.name)
        provider._acquire()
        self.assertFalse(self._cache_path.exists())

    def test_401_clears_cache(self) -> None:
        import urllib.error as ue

        self._cache_path.parent.mkdir(parents=True, exist_ok=True)
        self._cache_path.write_text(
            json.dumps(
                {"ory_session_name": "ory_session_x", "ory_session_value": "v", "csrftoken": "c"}
            ),
            encoding="utf-8",
        )
        provider = VibeProvider(project_root=self._tmpdir.name)
        err = ue.HTTPError("u", 401, "Unauthorized", {}, None)  # type: ignore[arg-type]
        with patch("urllib.request.urlopen", side_effect=err):
            with self.assertRaises(ProbeFailure):
                provider.fetch()
        self.assertFalse(self._cache_path.exists())


class CacheResilienceTests(unittest.TestCase):
    """Malformed bridge output must fail closed without browser fallback."""

    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self._cursor_cache = Path(self._tmpdir.name) / "cursor_token.json"
        self._vibe_cache = Path(self._tmpdir.name) / "vibe_cookies.json"
        self._patchers = [
            patch.object(CursorProvider, "_CACHE_PATH", self._cursor_cache),
            patch.object(VibeProvider, "_CACHE_PATH", self._vibe_cache),
        ]
        for p in self._patchers:
            p.start()

    def tearDown(self) -> None:
        for p in self._patchers:
            p.stop()
        self._tmpdir.cleanup()

    def test_cursor_corrupted_cache_is_ignored(self) -> None:
        self._cursor_cache.parent.mkdir(parents=True, exist_ok=True)
        self._cursor_cache.write_text("{ NOT VALID JSON !!!", encoding="utf-8")
        provider = CursorProvider()
        provider._acquire()
        self.assertIsNone(provider._access_token)

    def test_vibe_corrupted_cache_is_ignored(self) -> None:
        self._vibe_cache.parent.mkdir(parents=True, exist_ok=True)
        self._vibe_cache.write_text("{ NOT VALID JSON !!!", encoding="utf-8")
        provider = VibeProvider(project_root=self._tmpdir.name)
        provider._acquire()
        self.assertFalse(provider._has_cookies)

    def test_cursor_refresh_keeps_new_token_in_memory_without_rewriting_bridge_cache(self) -> None:
        """Provider refreshes must not gain write access to bridge-managed credentials."""
        import urllib.error as ue

        valid_jwt = _make_jwt(3600)
        self._cursor_cache.parent.mkdir(parents=True, exist_ok=True)
        self._cursor_cache.write_text(
            json.dumps({"access_token": valid_jwt, "refresh_token": "old_rt"}),
            encoding="utf-8",
        )
        provider = CursorProvider()

        # Simulate: first API call → 401, refresh succeeds with new tokens, retry succeeds
        first_err = ue.HTTPError("u", 401, "Unauthorized", {}, None)  # type: ignore[arg-type]

        new_jwt = _make_jwt(7200)
        refresh_body = json.dumps({"access_token": new_jwt, "refresh_token": "new_rt"}).encode()
        mock_refresh_resp = MagicMock()
        mock_refresh_resp.read.return_value = refresh_body
        mock_refresh_resp.__enter__ = lambda s: s
        mock_refresh_resp.__exit__ = MagicMock(return_value=False)

        usage_resp = {
            "billingCycleStart": 1775994366000,
            "billingCycleEnd": 1778586366000,
            "planUsage": {"totalPercentUsed": 4.1},
        }
        plan_resp = {"planInfo": {"name": "pro"}}

        call_count = 0

        def api_post_side_effect(*args, **kwargs):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                raise first_err
            elif call_count == 2:
                return usage_resp
            else:
                return plan_resp

        with (
            patch.object(provider, "_api_post", side_effect=api_post_side_effect),
            patch("urllib.request.urlopen", return_value=mock_refresh_resp),
        ):
            provider.fetch()

        # The bridge-owned cache remains untouched; the fresh token is only in memory.
        cached = json.loads(self._cursor_cache.read_text(encoding="utf-8"))
        self.assertEqual(cached["access_token"], valid_jwt)
        self.assertEqual(cached["refresh_token"], "old_rt")
        self.assertEqual(provider._access_token, new_jwt)
        self.assertEqual(provider._refresh_token, "new_rt")


class CodexWindowClassificationTests(unittest.TestCase):
    """Codex windows are slotted by declared span, not position (2026-07 change)."""

    FIVE_HOUR = {"used_percent": 10, "reset_at": 1, "limit_window_seconds": 18000}
    WEEKLY = {"used_percent": 20, "reset_at": 2, "limit_window_seconds": 604800}

    def test_weekly_only_leaves_five_hour_empty(self) -> None:
        # The current live shape: OpenAI removed the 5h window, so primary_window
        # carries the weekly limit and secondary_window is null.
        five_hour, weekly = _classify_codex_windows([self.WEEKLY, None])
        self.assertIsNone(five_hour)
        self.assertIs(weekly, self.WEEKLY)

    def test_both_windows_slot_by_span_regardless_of_order(self) -> None:
        # Normal order.
        fh, wk = _classify_codex_windows([self.FIVE_HOUR, self.WEEKLY])
        self.assertIs(fh, self.FIVE_HOUR)
        self.assertIs(wk, self.WEEKLY)
        # Reversed order still slots correctly — position is not trusted.
        fh, wk = _classify_codex_windows([self.WEEKLY, self.FIVE_HOUR])
        self.assertIs(fh, self.FIVE_HOUR)
        self.assertIs(wk, self.WEEKLY)

    def test_positional_fallback_when_span_missing(self) -> None:
        # Pre-2026-07 payloads had no limit_window_seconds: first -> 5h, second -> weekly.
        primary = {"used_percent": 10, "reset_at": 1}
        secondary = {"used_percent": 20, "reset_at": 2}
        fh, wk = _classify_codex_windows([primary, secondary])
        self.assertIs(fh, primary)
        self.assertIs(wk, secondary)

    def test_percent_left_is_remaining_and_handles_missing(self) -> None:
        self.assertEqual(_codex_percent_left({"used_percent": 5}), 95)
        self.assertIsNone(_codex_percent_left(None))
        self.assertIsNone(_codex_percent_left({}))
        self.assertIsNone(_codex_percent_left({"used_percent": None}))

    def test_percent_left_returns_float(self) -> None:
        result = _codex_percent_left({"used_percent": 5})
        self.assertIsInstance(result, float)
        self.assertEqual(result, 95.0)


class CodexSparkWindowExtractionTests(unittest.TestCase):
    """GPT-5.3-Codex-Spark ships as a top-level additional_rate_limits entry."""

    SPARK_WINDOW = {
        "allowed": True,
        "limit_reached": False,
        "primary_window": {"used_percent": 10, "reset_at": 1787274482},
        "secondary_window": None,
    }

    def _payload(self, *, metered_feature="codex_bengalfox", limit_name="GPT-5.3-Codex-Spark"):
        return {
            "rate_limit": {},
            "additional_rate_limits": [
                {
                    "limit_name": limit_name,
                    "metered_feature": metered_feature,
                    "rate_limit": self.SPARK_WINDOW,
                }
            ],
        }

    def test_extracts_primary_window_from_matching_entry(self) -> None:
        result = _extract_spark_window(self._payload())
        self.assertIs(result, self.SPARK_WINDOW["primary_window"])

    def test_absent_array_returns_none(self) -> None:
        self.assertIsNone(_extract_spark_window({"rate_limit": {}}))

    def test_non_list_array_returns_none(self) -> None:
        self.assertIsNone(_extract_spark_window({"additional_rate_limits": {"not": "a list"}}))

    def test_non_dict_element_is_skipped_not_fatal(self) -> None:
        payload = {
            "additional_rate_limits": [
                "not a dict",
                None,
                42,
                {
                    "limit_name": "GPT-5.3-Codex-Spark",
                    "metered_feature": "codex_bengalfox",
                    "rate_limit": self.SPARK_WINDOW,
                },
            ]
        }
        result = _extract_spark_window(payload)
        self.assertIs(result, self.SPARK_WINDOW["primary_window"])

    def test_all_non_dict_elements_returns_none(self) -> None:
        self.assertIsNone(_extract_spark_window({"additional_rate_limits": ["x", None, 1]}))

    def test_missing_inner_rate_limit_returns_none(self) -> None:
        payload = {
            "additional_rate_limits": [
                {"limit_name": "GPT-5.3-Codex-Spark", "metered_feature": "codex_bengalfox"}
            ]
        }
        self.assertIsNone(_extract_spark_window(payload))

    def test_non_dict_inner_rate_limit_returns_none(self) -> None:
        payload = {
            "additional_rate_limits": [
                {
                    "limit_name": "GPT-5.3-Codex-Spark",
                    "metered_feature": "codex_bengalfox",
                    "rate_limit": "not a dict",
                }
            ]
        }
        self.assertIsNone(_extract_spark_window(payload))

    def test_missing_primary_window_returns_none(self) -> None:
        payload = {
            "additional_rate_limits": [
                {
                    "limit_name": "GPT-5.3-Codex-Spark",
                    "metered_feature": "codex_bengalfox",
                    "rate_limit": {"allowed": True},
                }
            ]
        }
        self.assertIsNone(_extract_spark_window(payload))

    def test_non_dict_primary_window_returns_none(self) -> None:
        payload = {
            "additional_rate_limits": [
                {
                    "limit_name": "GPT-5.3-Codex-Spark",
                    "metered_feature": "codex_bengalfox",
                    "rate_limit": {"primary_window": "not a dict"},
                }
            ]
        }
        self.assertIsNone(_extract_spark_window(payload))

    def test_missing_or_non_numeric_used_percent_yields_no_percent_but_no_raise(self) -> None:
        # _extract_spark_window itself only locates the window; a malformed
        # used_percent inside it is _codex_percent_left's job to reject.
        for bad_used_percent in (None, "not a number", [1, 2]):
            window = dict(self.SPARK_WINDOW)
            window["primary_window"] = {"used_percent": bad_used_percent, "reset_at": 1}
            payload = {
                "additional_rate_limits": [
                    {
                        "limit_name": "GPT-5.3-Codex-Spark",
                        "metered_feature": "codex_bengalfox",
                        "rate_limit": window,
                    }
                ]
            }
            result = _extract_spark_window(payload)
            self.assertIsNotNone(result)
            self.assertIsNone(_codex_percent_left(result))

    def test_metered_feature_match_wins_over_limit_name_when_they_disagree(self) -> None:
        # One entry matches by metered_feature but has an unrelated limit_name;
        # another matches by limit_name but has an unrelated metered_feature.
        # The metered_feature match must win.
        by_feature_window = {"used_percent": 11, "reset_at": 111}
        by_name_window = {"used_percent": 22, "reset_at": 222}
        payload = {
            "additional_rate_limits": [
                {
                    "limit_name": "Some Other Bucket",
                    "metered_feature": "codex_bengalfox",
                    "rate_limit": {"primary_window": by_feature_window},
                },
                {
                    "limit_name": "GPT-5.3-Codex-Spark",
                    "metered_feature": "some_other_feature",
                    "rate_limit": {"primary_window": by_name_window},
                },
            ]
        }
        result = _extract_spark_window(payload)
        self.assertIs(result, by_feature_window)

    def test_limit_name_fallback_when_no_metered_feature_match(self) -> None:
        payload = self._payload(metered_feature="some_other_feature")
        result = _extract_spark_window(payload)
        self.assertIs(result, self.SPARK_WINDOW["primary_window"])

    def test_no_match_by_either_key_returns_none(self) -> None:
        payload = self._payload(metered_feature="unrelated", limit_name="Unrelated Bucket")
        self.assertIsNone(_extract_spark_window(payload))


class CodexHttpProviderTests(unittest.TestCase):
    # Real API uses rate_limit.{primary,secondary}_window.used_percent (epoch reset_at)
    NORMAL_RESPONSE = {
        "rate_limit": {
            "primary_window": {
                "used_percent": 20,
                "reset_at": 1776368464,
            },
            "secondary_window": {
                "used_percent": 20,
                "reset_at": 1776971477,
            },
        },
        "credits": {"balance": 12.5, "has_credits": True},
    }

    def _make_provider(self) -> CodexHttpProvider:
        # _AUTH_PATH must stay patched beyond this helper: _acquire() now runs
        # lazily inside fetch() (not __init__), so the mock has to still be in
        # effect when the caller later invokes provider.fetch(). Stop it via
        # addCleanup rather than a `with` block that would exit on return.
        auth_data = {
            "tokens": {
                "access_token": "test_access_token",
                "account_id": "test_account_id",
            }
        }
        patcher = patch.object(CodexHttpProvider, "_AUTH_PATH")
        mock_path = patcher.start()
        self.addCleanup(patcher.stop)
        mock_path.exists.return_value = True
        mock_path.read_text.return_value = json.dumps(auth_data)
        return CodexHttpProvider()

    def test_normal_response_field_mapping(self) -> None:
        provider = self._make_provider()
        with patch("gradus.providers._base._http_json", return_value=self.NORMAL_RESPONSE):
            status = provider.fetch()
        # 100 - 20 = 80
        self.assertEqual(status.five_hour_percent_left, 80)
        self.assertEqual(status.weekly_percent_left, 80)
        self.assertAlmostEqual(status.credits, 12.5)
        self.assertIsNotNone(status.five_hour_reset)
        self.assertIsNotNone(status.weekly_reset)

    def test_percent_left_fields_are_float(self) -> None:
        provider = self._make_provider()
        with patch("gradus.providers._base._http_json", return_value=self.NORMAL_RESPONSE):
            status = provider.fetch()
        self.assertIsInstance(status.five_hour_percent_left, float)
        self.assertIsInstance(status.weekly_percent_left, float)

    def test_spark_window_populates_status_fields(self) -> None:
        provider = self._make_provider()
        response = dict(self.NORMAL_RESPONSE)
        response["additional_rate_limits"] = [
            {
                "limit_name": "GPT-5.3-Codex-Spark",
                "metered_feature": "codex_bengalfox",
                "rate_limit": {
                    "allowed": True,
                    "limit_reached": False,
                    "primary_window": {
                        "limit_window_seconds": 604800,
                        "reset_after_seconds": 604800,
                        "reset_at": 1787274482,
                        "used_percent": 15,
                    },
                    "secondary_window": None,
                },
            }
        ]
        with patch("gradus.providers._base._http_json", return_value=response):
            status = provider.fetch()
        self.assertEqual(status.spark_weekly_percent_left, 85.0)
        self.assertIsNotNone(status.spark_weekly_reset)

    def test_spark_window_absent_leaves_fields_none(self) -> None:
        provider = self._make_provider()
        with patch("gradus.providers._base._http_json", return_value=self.NORMAL_RESPONSE):
            status = provider.fetch()
        self.assertIsNone(status.spark_weekly_percent_left)
        self.assertIsNone(status.spark_weekly_reset)

    def test_spark_reset_at_as_dict_does_not_raise_and_yields_none_reset(self) -> None:
        # A malformed reset_at (dict instead of str/int/float) must not reach
        # _format_reset_time, which only catches ValueError/OSError/OverflowError
        # and would crash the whole Codex probe on an unguarded TypeError.
        provider = self._make_provider()
        response = dict(self.NORMAL_RESPONSE)
        response["additional_rate_limits"] = [
            {
                "limit_name": "GPT-5.3-Codex-Spark",
                "metered_feature": "codex_bengalfox",
                "rate_limit": {
                    "primary_window": {
                        "used_percent": 15,
                        "reset_at": {"nested": "malformed"},
                    },
                },
            }
        ]
        with patch("gradus.providers._base._http_json", return_value=response):
            status = provider.fetch()  # must not raise TypeError
        self.assertIsNone(status.spark_weekly_reset)
        self.assertEqual(status.spark_weekly_percent_left, 85.0)

    def test_spark_percent_set_with_absent_reset_at(self) -> None:
        provider = self._make_provider()
        response = dict(self.NORMAL_RESPONSE)
        response["additional_rate_limits"] = [
            {
                "limit_name": "GPT-5.3-Codex-Spark",
                "metered_feature": "codex_bengalfox",
                "rate_limit": {"primary_window": {"used_percent": 30}},
            }
        ]
        with patch("gradus.providers._base._http_json", return_value=response):
            status = provider.fetch()
        self.assertEqual(status.spark_weekly_percent_left, 70.0)
        self.assertIsNone(status.spark_weekly_reset)

    def test_five_hour_removal_maps_weekly_only(self) -> None:
        # Live shape after OpenAI dropped the 5h window: primary_window is the
        # weekly limit (limit_window_seconds=604800) and secondary_window is null.
        provider = self._make_provider()
        response = {
            "rate_limit": {
                "primary_window": {
                    "used_percent": 5,
                    "reset_at": 1784488271,
                    "limit_window_seconds": 604800,
                },
                "secondary_window": None,
            },
            "credits": {"balance": None},
        }
        with patch("gradus.providers._base._http_json", return_value=response):
            status = provider.fetch()
        # Weekly is populated correctly; the 5h slot stays empty (not mislabeled).
        self.assertEqual(status.weekly_percent_left, 95)
        self.assertIsNotNone(status.weekly_reset)
        self.assertIsNone(status.five_hour_percent_left)
        self.assertIsNone(status.five_hour_reset)

    def test_five_hour_restored_slots_both_windows(self) -> None:
        # If OpenAI restores the 5h window, both windows populate — no code change.
        provider = self._make_provider()
        response = {
            "rate_limit": {
                "primary_window": {
                    "used_percent": 30,
                    "reset_at": 1784488271,
                    "limit_window_seconds": 18000,
                },
                "secondary_window": {
                    "used_percent": 40,
                    "reset_at": 1784900000,
                    "limit_window_seconds": 604800,
                },
            },
        }
        with patch("gradus.providers._base._http_json", return_value=response):
            status = provider.fetch()
        self.assertEqual(status.five_hour_percent_left, 70)
        self.assertEqual(status.weekly_percent_left, 60)
        self.assertIsNotNone(status.five_hour_reset)
        self.assertIsNotNone(status.weekly_reset)

    def test_401_raises_probe_failure(self) -> None:
        provider = self._make_provider()
        with patch("gradus.providers._base._http_json", side_effect=ProbeFailure("HTTP 401", "")):
            with self.assertRaises(ProbeFailure):
                provider.fetch()

    def test_401_reloads_auth_json_and_retries(self) -> None:
        # Regression: previously the provider cached _access_token at __init__ and never
        # reloaded it, so running `codex login` after a 401 left gradus stuck on the
        # stale token forever. The 401 path must re-read ~/.codex/auth.json from disk.
        provider = self._make_provider()
        provider._acquire()
        self.assertEqual(provider._access_token, "test_access_token")

        refreshed_auth = json.dumps(
            {"tokens": {"access_token": "fresh_token", "account_id": "test_account_id"}}
        )
        with patch.object(CodexHttpProvider, "_AUTH_PATH") as mock_path:
            mock_path.exists.return_value = True
            mock_path.read_text.return_value = refreshed_auth
            with patch(
                "gradus.providers._base._http_json",
                side_effect=[ProbeFailure("HTTP 401", ""), self.NORMAL_RESPONSE],
            ):
                status = provider.fetch()

        self.assertEqual(provider._access_token, "fresh_token")
        self.assertEqual(status.five_hour_percent_left, 80)

    def test_401_with_valid_refresh_token_refreshes_silently(self) -> None:
        # When the access_token is server-side revoked but the refresh_token still
        # works, the OAuth refresh grant should mint a new pair, persist it to
        # auth.json, and the retry should succeed — all without surfacing a
        # re-auth prompt to the user. This is the common case after OpenAI rotates
        # a session (e.g. sign-in elsewhere) while the refresh credential is intact.
        tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(tmpdir.cleanup)
        auth_path = Path(tmpdir.name) / "auth.json"
        auth_path.write_text(
            json.dumps(
                {
                    "auth_mode": "chatgpt",
                    "OPENAI_API_KEY": "sk-preserve-me",
                    "tokens": {
                        "access_token": "stale_access",
                        "refresh_token": "good_refresh",
                        "account_id": "acct_1",
                        "id_token": "old_id",
                    },
                    "last_refresh": "2026-06-13T17:49:29.038739Z",
                }
            )
        )
        with patch.object(CodexHttpProvider, "_AUTH_PATH", auth_path):
            provider = CodexHttpProvider()

            refresh_response = {
                "access_token": "fresh_access",
                "id_token": "fresh_id",
                "refresh_token": "fresh_refresh",
                "expires_in": 864000,
            }

            with patch.object(CodexHttpProvider, "_AUTH_PATH", auth_path):
                with patch(
                    "gradus.providers._base._http_json",
                    side_effect=[
                        ProbeFailure(
                            "HTTP 401",
                            '{"error":{"code":"token_invalidated"}}',
                        ),
                        refresh_response,
                        self.NORMAL_RESPONSE,
                    ],
                ) as mock_http:
                    status = provider.fetch()

        # Three HTTP calls: usage(401) → refresh(200) → usage(200)
        self.assertEqual(mock_http.call_count, 3)
        self.assertEqual(status.five_hour_percent_left, 80)
        # New access_token must be loaded into the provider for subsequent cycles.
        self.assertEqual(provider._access_token, "fresh_access")
        # auth.json must be merged, not clobbered — preserve unrelated fields.
        on_disk = json.loads(auth_path.read_text(encoding="utf-8"))
        self.assertEqual(on_disk["auth_mode"], "chatgpt")
        self.assertEqual(on_disk["OPENAI_API_KEY"], "sk-preserve-me")
        self.assertEqual(on_disk["tokens"]["access_token"], "fresh_access")
        self.assertEqual(on_disk["tokens"]["refresh_token"], "fresh_refresh")
        self.assertEqual(on_disk["tokens"]["id_token"], "fresh_id")
        self.assertEqual(on_disk["tokens"]["account_id"], "acct_1")
        # File mode must stay 0600 — auth.json holds long-lived OAuth credentials.
        self.assertEqual(auth_path.stat().st_mode & 0o777, 0o600)

    def test_401_with_invalidated_refresh_token_surfaces_reauth(self) -> None:
        # If the refresh_token itself is revoked (refresh_token_invalidated from
        # auth.openai.com), no amount of retrying will help — the user has to run
        # `codex login` interactively. Surface the [1]-actionable message and stop.
        tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(tmpdir.cleanup)
        auth_path = Path(tmpdir.name) / "auth.json"
        auth_path.write_text(
            json.dumps(
                {
                    "tokens": {
                        "access_token": "stale_access",
                        "refresh_token": "dead_refresh",
                        "account_id": "acct_1",
                    }
                }
            )
        )
        with patch.object(CodexHttpProvider, "_AUTH_PATH", auth_path):
            provider = CodexHttpProvider()
            with patch(
                "gradus.providers._base._http_json",
                side_effect=[
                    ProbeFailure("HTTP 401", '{"error":{"code":"token_invalidated"}}'),
                    ProbeFailure(
                        "HTTP 401",
                        '{"error":{"code":"refresh_token_invalidated",'
                        '"message":"Your session has ended. Please log in again."}}',
                    ),
                ],
            ) as mock_http:
                with self.assertRaises(ProbeFailure) as ctx:
                    provider.fetch()

        self.assertEqual(mock_http.call_count, 2)
        self.assertIn("re-authenticate", str(ctx.exception).lower())
        # Auth.json must NOT be modified — the refresh failed before the write step.
        on_disk = json.loads(auth_path.read_text(encoding="utf-8"))
        self.assertEqual(on_disk["tokens"]["access_token"], "stale_access")
        self.assertEqual(on_disk["tokens"]["refresh_token"], "dead_refresh")

    def test_401_with_unchanged_auth_json_surfaces_reauth_error(self) -> None:
        # If the file on disk still has the same (stale) token, don't waste a retry HTTP
        # call — surface the "re-authenticate" message immediately. The _AUTH_PATH patch
        # must stay active through fetch() so the 401-triggered reload sees the same JSON
        # the constructor saw, not whatever ~/.codex/auth.json holds on the test host.
        same_auth = json.dumps(
            {"tokens": {"access_token": "test_access_token", "account_id": "test_account_id"}}
        )
        with patch.object(CodexHttpProvider, "_AUTH_PATH") as mock_path:
            mock_path.exists.return_value = True
            mock_path.read_text.return_value = same_auth
            provider = CodexHttpProvider()
            with patch("gradus.providers._base._http_json") as mock_http:
                mock_http.side_effect = ProbeFailure("HTTP 401", "")
                with self.assertRaises(ProbeFailure) as ctx:
                    provider.fetch()
        self.assertIn("re-authenticate", str(ctx.exception).lower())
        # Exactly one HTTP call — no retry against the same token
        self.assertEqual(mock_http.call_count, 1)

    def test_refresh_tokens_returns_false_when_response_missing_access_token(self) -> None:
        # _refresh_tokens returns False when the OAuth endpoint responds 200 but omits
        # access_token (e.g. a shape change or error JSON without an HTTP error status).
        # fetch() treats this like no refresh_token: falls back to the disk-reload path.
        tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(tmpdir.cleanup)
        auth_path = Path(tmpdir.name) / "auth.json"
        auth_path.write_text(
            json.dumps(
                {
                    "tokens": {
                        "access_token": "stale_access",
                        "refresh_token": "some_refresh",
                        "account_id": "acct_1",
                    }
                }
            )
        )
        with patch.object(CodexHttpProvider, "_AUTH_PATH", auth_path):
            provider = CodexHttpProvider()
            with patch(
                "gradus.providers._base._http_json",
                side_effect=[
                    ProbeFailure("HTTP 401", ""),
                    {"token_type": "Bearer"},  # refresh response with no access_token
                ],
            ) as mock_http:
                with self.assertRaises(ProbeFailure) as ctx:
                    provider.fetch()

        # usage(401) → refresh(200/no access_token) → _refresh_tokens returns False
        # → raise original 401 → reload path sees same token → surfaces re-auth
        self.assertEqual(mock_http.call_count, 2)
        self.assertIn("re-authenticate", str(ctx.exception).lower())
        # auth.json must be untouched — no partial write on a no-access_token response
        on_disk = json.loads(auth_path.read_text(encoding="utf-8"))
        self.assertEqual(on_disk["tokens"]["access_token"], "stale_access")

    def test_transient_refresh_failure_falls_back_to_reload_then_succeeds(self) -> None:
        # When the refresh endpoint returns a transient error (e.g. 500, not
        # refresh_token_invalidated), fetch() should fall back to the disk-reload path.
        # If auth.json was meanwhile updated (e.g. by `codex login`), the retry succeeds.
        tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(tmpdir.cleanup)
        auth_path = Path(tmpdir.name) / "auth.json"
        auth_path.write_text(
            json.dumps(
                {
                    "tokens": {
                        "access_token": "stale_access",
                        "refresh_token": "some_refresh",
                        "account_id": "acct_1",
                    }
                }
            )
        )
        with patch.object(CodexHttpProvider, "_AUTH_PATH", auth_path):
            provider = CodexHttpProvider()

        normal_response = self.NORMAL_RESPONSE
        call_count = 0

        # usage_url and refresh_url calls are distinguishable by URL argument.
        def side_effect_fn(url, **kwargs):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                # initial usage call → 401
                raise ProbeFailure("HTTP 401", "")
            elif call_count == 2:
                # refresh call → transient 500; also update disk to simulate `codex login`
                auth_path.write_text(
                    json.dumps(
                        {
                            "tokens": {
                                "access_token": "refreshed_by_login",
                                "account_id": "acct_1",
                            }
                        }
                    )
                )
                raise ProbeFailure("HTTP 500", "internal server error")
            else:
                # retry usage call → success
                return normal_response

        with patch.object(CodexHttpProvider, "_AUTH_PATH", auth_path):
            with patch("gradus.providers._base._http_json", side_effect=side_effect_fn):
                status = provider.fetch()

        # usage(401) → refresh(500) → reload → usage(200)
        self.assertEqual(call_count, 3)
        self.assertEqual(status.five_hour_percent_left, 80)
        self.assertEqual(provider._access_token, "refreshed_by_login")

    def test_transient_refresh_failure_and_missing_auth_json_surfaces_reauth(self) -> None:
        # If auth.json disappears while recovering (e.g. the user deleted it),
        # _load_creds raises FileNotFoundError — fetch() must surface the re-auth message.
        tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(tmpdir.cleanup)
        auth_path = Path(tmpdir.name) / "auth.json"
        auth_path.write_text(
            json.dumps(
                {
                    "tokens": {
                        "access_token": "stale_access",
                        "refresh_token": "some_refresh",
                        "account_id": "acct_1",
                    }
                }
            )
        )
        with patch.object(CodexHttpProvider, "_AUTH_PATH", auth_path):
            provider = CodexHttpProvider()

        call_count = 0

        def side_effect_fn(url, **kwargs):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                raise ProbeFailure("HTTP 401", "")
            else:
                # refresh call → 500 and delete auth.json mid-flight
                auth_path.unlink()
                raise ProbeFailure("HTTP 500", "internal server error")

        with patch.object(CodexHttpProvider, "_AUTH_PATH", auth_path):
            with patch("gradus.providers._base._http_json", side_effect=side_effect_fn):
                with self.assertRaises(ProbeFailure) as ctx:
                    provider.fetch()

        self.assertEqual(call_count, 2)
        self.assertIn("re-authenticate", str(ctx.exception).lower())

    def test_reload_succeeds_but_retry_still_401_surfaces_reauth(self) -> None:
        # If auth.json was updated (new token present) but that new token is also rejected
        # with 401, fetch() must raise the re-auth ProbeFailure, not loop forever.
        tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(tmpdir.cleanup)
        auth_path = Path(tmpdir.name) / "auth.json"
        auth_path.write_text(
            json.dumps(
                {
                    "tokens": {
                        "access_token": "stale_access",
                        "refresh_token": "some_refresh",
                        "account_id": "acct_1",
                    }
                }
            )
        )
        with patch.object(CodexHttpProvider, "_AUTH_PATH", auth_path):
            provider = CodexHttpProvider()

        call_count = 0

        def side_effect_fn(url, **kwargs):
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                raise ProbeFailure("HTTP 401", "")
            elif call_count == 2:
                # refresh call → 500; write a new (also-rejected) token to disk
                auth_path.write_text(
                    json.dumps(
                        {
                            "tokens": {
                                "access_token": "also_stale",
                                "account_id": "acct_1",
                            }
                        }
                    )
                )
                raise ProbeFailure("HTTP 500", "server error")
            else:
                # retry usage call → 401 again (server still rejects)
                raise ProbeFailure("HTTP 401", "")

        with patch.object(CodexHttpProvider, "_AUTH_PATH", auth_path):
            with patch("gradus.providers._base._http_json", side_effect=side_effect_fn):
                with self.assertRaises(ProbeFailure) as ctx:
                    provider.fetch()

        self.assertEqual(call_count, 3)
        self.assertIn("re-authenticate", str(ctx.exception).lower())

    def test_codex_post_refresh_5xx_is_transient_not_auth(self) -> None:
        # Regression: a successful on-disk refresh followed by a transient 5xx on the
        # immediate retry must NOT be misclassified as an auth failure. Previously the
        # retry shared a try/except with _refresh_tokens(), so the 5xx was caught by
        # `except ProbeFailure as refresh_exc`, the reload fallback found the token
        # unchanged (refresh already wrote+loaded it), and the code raised the
        # "session expired" re-auth message instead of propagating the transient error.
        auth_data = json.dumps(
            {
                "tokens": {
                    "access_token": "test_access_token",
                    "account_id": "test_account_id",
                }
            }
        )
        with patch.object(CodexHttpProvider, "_AUTH_PATH") as mock_path:
            mock_path.exists.return_value = True
            mock_path.read_text.return_value = auth_data
            provider = CodexHttpProvider()
            with (
                patch.object(CodexHttpProvider, "_refresh_tokens", return_value=True),
                patch.object(
                    CodexHttpProvider,
                    "_request_usage",
                    side_effect=[
                        ProbeFailure("HTTP 401", '{"error":"unauthorized"}'),
                        ProbeFailure("HTTP 503", "service unavailable"),
                    ],
                ),
            ):
                with self.assertRaises(ProbeFailure) as ctx:
                    provider.fetch()

        message = str(ctx.exception)
        self.assertIn("HTTP 503", message)
        self.assertNotIn("session expired", message)

        # INV-1: the error string must never contain raw response bodies.
        self.assertNotIn("service unavailable", message)

        snapshot = ProviderSnapshot(name="Codex", ok=False, source="api", error=message)
        self.assertTrue(_is_transient_probe_error(snapshot))
        self.assertFalse(_is_auth_error(snapshot))

    def test_codex_post_refresh_401_still_reauths(self) -> None:
        # Non-regression: if the refresh succeeds but the fresh token is ALSO rejected
        # with a 401 on the immediate retry, that is a genuine auth rejection and must
        # still surface the "session expired" re-auth message.
        auth_data = json.dumps(
            {
                "tokens": {
                    "access_token": "test_access_token",
                    "account_id": "test_account_id",
                }
            }
        )
        with patch.object(CodexHttpProvider, "_AUTH_PATH") as mock_path:
            mock_path.exists.return_value = True
            mock_path.read_text.return_value = auth_data
            provider = CodexHttpProvider()
            with (
                patch.object(CodexHttpProvider, "_refresh_tokens", return_value=True),
                patch.object(
                    CodexHttpProvider,
                    "_request_usage",
                    side_effect=[
                        ProbeFailure("HTTP 401", '{"error":"unauthorized"}'),
                        ProbeFailure("HTTP 401", '{"error":"unauthorized"}'),
                    ],
                ),
            ):
                with self.assertRaises(ProbeFailure) as ctx:
                    provider.fetch()

        message = str(ctx.exception)
        self.assertIn("session expired", message)

        snapshot = ProviderSnapshot(name="Codex", ok=False, source="api", error=message)
        self.assertTrue(_is_auth_error(snapshot))
        self.assertFalse(_is_transient_probe_error(snapshot))


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
            token = ClaudeHttpProvider._load_keychain_access_token()

        self.assertEqual(token, "test-oauth-token")
        args = run.call_args.args[0]
        self.assertEqual(args[:3], ["security", "find-generic-password", "-w"])
        self.assertIn("Claude Code-credentials", args)
        self.assertNotIn("test-oauth-token", args)

    def test_invalid_keychain_payload_fails_closed(self) -> None:
        keychain = MagicMock(returncode=0, stdout=json.dumps({"sessionKey": "legacy"}))
        with patch("gradus.providers.claude.subprocess.run", return_value=keychain):
            with self.assertRaises(FileNotFoundError):
                ClaudeHttpProvider._load_keychain_access_token()

    def test_keychain_failure_does_not_expose_command_output(self) -> None:
        keychain = MagicMock(returncode=1, stdout="secret-adjacent-output")
        with patch("gradus.providers.claude.subprocess.run", return_value=keychain):
            with self.assertRaises(FileNotFoundError) as ctx:
                ClaudeHttpProvider._load_keychain_access_token()
        self.assertNotIn("secret-adjacent-output", str(ctx.exception))

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
            "_load_keychain_access_token",
            side_effect=FileNotFoundError("credential helper unavailable"),
        ):
            snapshot = fetch_provider_snapshot("Claude", provider, debug=False)
        self.assertFalse(snapshot.ok)
        self.assertIn("claude auth login", snapshot.error or "")


class AntigravityProviderTests(unittest.TestCase):
    # Real shape of retrieveUserQuotaSummary: grouped quota, two windows per group.
    SUMMARY_RESPONSE = {
        "groups": [
            {
                "displayName": "Gemini Models",
                "description": "Models within this group: Gemini Flash, Gemini Pro",
                "buckets": [
                    {
                        "bucketId": "gemini-weekly",
                        "window": "weekly",
                        "resetTime": "2026-07-11T20:52:22Z",
                        "remainingFraction": 0.95879453,
                    },
                    {
                        "bucketId": "gemini-5h",
                        "window": "5h",
                        "resetTime": "2026-07-06T05:31:46Z",
                        "remainingFraction": 0.8624946,
                    },
                ],
            },
            {
                "displayName": "Claude and GPT models",
                "buckets": [
                    {
                        "bucketId": "3p-weekly",
                        "window": "weekly",
                        "resetTime": "2026-07-12T20:52:22Z",
                        "remainingFraction": 0.734,
                    },
                    {
                        "bucketId": "3p-5h",
                        "window": "5h",
                        "resetTime": "2026-07-06T09:31:46Z",
                        "remainingFraction": 0.421,
                    },
                ],
            },
        ],
    }

    def _token(self, expiry: str = "2999-01-01T00:00:00+00:00") -> dict:
        return {
            "access_token": "ya29.agy-token",
            "refresh_token": "1//agy-refresh",
            "token_type": "Bearer",
            "expiry": expiry,
        }

    def _make_provider(self, token: dict | None = None) -> AntigravityProvider:
        with patch.object(
            AntigravityProvider, "_load_keychain_token", return_value=token or self._token()
        ):
            return AntigravityProvider()

    def test_parses_gemini_group_5h_and_weekly(self) -> None:
        provider = self._make_provider()
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=self._token()),
            patch(
                "gradus.providers._base._http_json", return_value=self.SUMMARY_RESPONSE
            ) as mock_http,
        ):
            status = provider.fetch()
        self.assertAlmostEqual(status.five_hour_percent_left, 86.24946, places=5)
        self.assertAlmostEqual(status.weekly_percent_left, 95.879453, places=6)
        self.assertIsNotNone(status.five_hour_reset)
        self.assertIsNotNone(status.weekly_reset)
        # The endpoint rejects a non-empty body (400) and the default urllib UA (403).
        _, kwargs = mock_http.call_args
        self.assertEqual(kwargs["body"], b"{}")
        self.assertIn("antigravity", kwargs["headers"]["User-Agent"].lower())
        self.assertTrue(kwargs["headers"]["Authorization"].startswith("Bearer "))

    def test_percent_left_fields_are_float(self) -> None:
        provider = self._make_provider()
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=self._token()),
            patch("gradus.providers._base._http_json", return_value=self.SUMMARY_RESPONSE),
        ):
            status = provider.fetch()
        self.assertIsInstance(status.five_hour_percent_left, float)
        self.assertIsInstance(status.weekly_percent_left, float)
        self.assertIsInstance(status.third_party_five_hour_percent_left, float)
        self.assertIsInstance(status.third_party_weekly_percent_left, float)

    def test_selects_gemini_group_not_third_party(self) -> None:
        # Gemini weekly is 96%, the Claude+GPT group is 100%; we must read Gemini's.
        provider = self._make_provider()
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=self._token()),
            patch("gradus.providers._base._http_json", return_value=self.SUMMARY_RESPONSE),
        ):
            status = provider.fetch()
        self.assertAlmostEqual(status.weekly_percent_left, 95.879453, places=6)

    def test_parses_third_party_group_5h_and_weekly(self) -> None:
        provider = self._make_provider()
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=self._token()),
            patch("gradus.providers._base._http_json", return_value=self.SUMMARY_RESPONSE),
        ):
            status = provider.fetch()
        self.assertEqual(status.third_party_five_hour_percent_left, 42.1)
        self.assertEqual(status.third_party_weekly_percent_left, 73.4)
        self.assertIsNotNone(status.third_party_five_hour_reset)
        self.assertIsNotNone(status.third_party_weekly_reset)

    def test_invalid_third_party_buckets_do_not_hide_gemini_values(self) -> None:
        responses = {
            "missing": {"groups": [self.SUMMARY_RESPONSE["groups"][0]]},
            "invalid": {
                "groups": [
                    self.SUMMARY_RESPONSE["groups"][0],
                    {"displayName": "renamed group must not matter", "buckets": "not a list"},
                ]
            },
            "malformed": {
                "groups": [
                    self.SUMMARY_RESPONSE["groups"][0],
                    {
                        "displayName": "renamed group must not matter",
                        "buckets": [
                            {
                                "bucketId": "3p-5h",
                                "window": "5h",
                                "remainingFraction": "nan",
                            },
                            {
                                "bucketId": "3p-weekly",
                                "window": "weekly",
                                "remainingFraction": {},
                            },
                            "not a bucket",
                        ],
                    },
                ]
            },
        }
        for response in responses.values():
            with self.subTest(response=response):
                provider = self._make_provider()
                with (
                    patch.object(
                        AntigravityProvider, "_load_keychain_token", return_value=self._token()
                    ),
                    patch("gradus.providers._base._http_json", return_value=response),
                ):
                    status = provider.fetch()
                self.assertAlmostEqual(status.five_hour_percent_left, 86.24946, places=5)
                self.assertAlmostEqual(status.weekly_percent_left, 95.879453, places=6)
                self.assertIsNone(status.third_party_five_hour_percent_left)
                self.assertIsNone(status.third_party_weekly_percent_left)
                self.assertIsNone(status.third_party_five_hour_reset)
                self.assertIsNone(status.third_party_weekly_reset)

    def test_malformed_third_party_reset_does_not_hide_gemini_values(self) -> None:
        response = {
            "groups": [
                self.SUMMARY_RESPONSE["groups"][0],
                {
                    "buckets": [
                        {
                            "bucketId": "3p-5h",
                            "window": "5h",
                            "resetTime": {"unexpected": "object"},
                            "remainingFraction": 0.421,
                        },
                        self.SUMMARY_RESPONSE["groups"][1]["buckets"][0],
                    ]
                },
            ]
        }
        provider = self._make_provider()
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=self._token()),
            patch("gradus.providers._base._http_json", return_value=response),
        ):
            status = provider.fetch()
        self.assertAlmostEqual(status.five_hour_percent_left, 86.24946, places=5)
        self.assertAlmostEqual(status.weekly_percent_left, 95.879453, places=6)
        self.assertEqual(status.third_party_five_hour_percent_left, 42.1)
        self.assertIsNone(status.third_party_five_hour_reset)
        self.assertEqual(status.third_party_weekly_percent_left, 73.4)
        self.assertIsNotNone(status.third_party_weekly_reset)

    def test_bucket_prefix_filters_each_selected_window(self) -> None:
        response = {
            "groups": [
                {
                    "buckets": [
                        self.SUMMARY_RESPONSE["groups"][0]["buckets"][1],
                        self.SUMMARY_RESPONSE["groups"][1]["buckets"][0],
                    ]
                },
                {
                    "buckets": [
                        self.SUMMARY_RESPONSE["groups"][1]["buckets"][0],
                        self.SUMMARY_RESPONSE["groups"][0]["buckets"][1],
                    ]
                },
            ]
        }
        provider = self._make_provider()
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=self._token()),
            patch("gradus.providers._base._http_json", return_value=response),
        ):
            status = provider.fetch()
        self.assertAlmostEqual(status.five_hour_percent_left, 86.24946, places=5)
        self.assertIsNone(status.weekly_percent_left)
        self.assertIsNone(status.third_party_five_hour_percent_left)
        self.assertEqual(status.third_party_weekly_percent_left, 73.4)

    def test_third_party_fraction_preserves_precision(self) -> None:
        response = {
            "groups": [
                self.SUMMARY_RESPONSE["groups"][0],
                {
                    "buckets": [
                        {
                            "bucketId": "3p-5h",
                            "window": "5h",
                            "remainingFraction": 0.999,
                        },
                        {
                            "bucketId": "3p-weekly",
                            "window": "weekly",
                            "remainingFraction": 1,
                        },
                    ]
                },
            ]
        }
        provider = self._make_provider()
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=self._token()),
            patch("gradus.providers._base._http_json", return_value=response),
        ):
            status = provider.fetch()
        self.assertAlmostEqual(status.five_hour_percent_left, 86.24946, places=5)
        self.assertAlmostEqual(status.weekly_percent_left, 95.879453, places=6)
        self.assertEqual(status.third_party_five_hour_percent_left, 99.9)
        self.assertEqual(status.third_party_weekly_percent_left, 100.0)

    def test_third_party_fraction_preserves_exact_boundaries(self) -> None:
        response = {
            "groups": [
                self.SUMMARY_RESPONSE["groups"][0],
                {
                    "buckets": [
                        {
                            "bucketId": "3p-5h",
                            "window": "5h",
                            "remainingFraction": 0,
                        },
                        {
                            "bucketId": "3p-weekly",
                            "window": "weekly",
                            "remainingFraction": 1,
                        },
                    ]
                },
            ]
        }
        provider = self._make_provider()
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=self._token()),
            patch("gradus.providers._base._http_json", return_value=response),
        ):
            status = provider.fetch()
        self.assertEqual(status.third_party_five_hour_percent_left, 0.0)
        self.assertEqual(status.third_party_weekly_percent_left, 100.0)

    def test_out_of_range_third_party_fractions_do_not_hide_gemini_values(self) -> None:
        response = {
            "groups": [
                self.SUMMARY_RESPONSE["groups"][0],
                {
                    "buckets": [
                        {
                            "bucketId": "3p-5h",
                            "window": "5h",
                            "remainingFraction": -0.01,
                        },
                        {
                            "bucketId": "3p-weekly",
                            "window": "weekly",
                            "remainingFraction": 1.01,
                        },
                    ]
                },
            ]
        }
        provider = self._make_provider()
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=self._token()),
            patch("gradus.providers._base._http_json", return_value=response),
        ):
            status = provider.fetch()
        self.assertAlmostEqual(status.five_hour_percent_left, 86.24946, places=5)
        self.assertAlmostEqual(status.weekly_percent_left, 95.879453, places=6)
        self.assertIsNone(status.third_party_five_hour_percent_left)
        self.assertIsNone(status.third_party_weekly_percent_left)

    def test_third_party_fraction_rejects_booleans_and_non_finite_values(self) -> None:
        for fraction in (True, False, float("nan"), float("inf"), float("-inf")):
            with self.subTest(fraction=fraction):
                self.assertIsNone(
                    AntigravityProvider._third_party_percent_from_fraction(
                        {"remainingFraction": fraction}
                    )
                )

    def test_gemini_fraction_parsing_keeps_prior_non_finite_behavior(self) -> None:
        bucket = {"remainingFraction": "nan"}
        self.assertIsNone(AntigravityProvider._percent_from_fraction(bucket))

    # ---- self-heal: nudge `agy` to refresh its OWN token via `agy models` ----

    def test_expired_token_nudge_fails_then_raises_run_agy_and_skips_network(self) -> None:
        # Expired token: we nudge `agy` once; if it still can't refresh, surface the
        # run-agy error and never probe the summary endpoint with a dead token.
        provider = self._make_provider()
        expired = self._token(expiry="2000-01-01T00:00:00+00:00")
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=expired),
            # nudge runs (exit 0) but the re-read token is still expired.
            patch(
                "gradus.providers.subprocess.run",
                return_value=MagicMock(returncode=0),
            ) as mock_run,
            patch("gradus.providers._base._http_json") as mock_http,
        ):
            with self.assertRaises(ProbeFailure) as ctx:
                provider.fetch()
        self.assertIn("agy", str(ctx.exception))
        mock_run.assert_called_once()  # we DID try to nudge agy
        mock_http.assert_not_called()  # but never probed the network with a dead token

    def test_expired_token_nudges_agy_and_self_heals(self) -> None:
        # Expired -> `agy models` refreshes agy's own token -> re-read is valid ->
        # the summary probe succeeds without any user action.
        expired = self._token(expiry="2000-01-01T00:00:00+00:00")
        fresh = self._token()  # far-future expiry, as if agy just refreshed
        provider = self._make_provider()
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", side_effect=[expired, fresh]),
            patch(
                "gradus.providers.subprocess.run",
                return_value=MagicMock(returncode=0),
            ) as mock_run,
            patch("gradus.providers._base._http_json", return_value=self.SUMMARY_RESPONSE),
        ):
            status = provider.fetch()
        self.assertAlmostEqual(status.five_hour_percent_left, 86.24946, places=5)
        # Pin the exact command: non-interactive + quota-free. Never `agy --print`.
        self.assertEqual(list(mock_run.call_args[0][0]), ["agy", "models"])

    def test_nudge_returns_false_when_agy_models_exits_nonzero(self) -> None:
        # Honest success signal: if `agy models` exits non-zero it did NOT refresh,
        # so don't trust a still-readable (stale/rejected) token.
        stale = self._token()  # future expiry, but agy failed to refresh it
        provider = self._make_provider()
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=stale),
            patch(
                "gradus.providers.subprocess.run",
                return_value=MagicMock(returncode=1),
            ),
        ):
            self.assertFalse(provider._trigger_agy_self_refresh())

    def test_nudge_uses_owned_absolute_fallback_when_launchd_path_omits_agy(self) -> None:
        provider = self._make_provider()
        provider._token = self._token(expiry="2000-01-01T00:00:00+00:00")
        fallback = AntigravityProvider._REFRESH_FALLBACK_PATH
        with (
            patch("gradus.providers.antigravity.shutil.which", return_value=None),
            patch.object(
                Path, "stat", return_value=MagicMock(st_mode=stat.S_IFREG, st_uid=os.getuid())
            ),
            patch("gradus.providers.antigravity.os.access", return_value=True),
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=self._token()),
            patch(
                "gradus.providers.subprocess.run",
                return_value=MagicMock(returncode=0),
            ) as mock_run,
        ):
            self.assertTrue(provider._trigger_agy_self_refresh())
        self.assertEqual(list(mock_run.call_args.args[0]), [str(fallback), "models"])

    def test_nudge_returns_false_when_refreshed_token_has_no_access_token(self) -> None:
        # A malformed re-read (no access_token, no expiry) must not count as success.
        provider = self._make_provider()
        provider._token = self._token(expiry="2000-01-01T00:00:00+00:00")
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value={}),
            patch(
                "gradus.providers.subprocess.run",
                return_value=MagicMock(returncode=0),
            ),
        ):
            self.assertFalse(provider._trigger_agy_self_refresh())

    def test_nudge_is_gated_off_in_headless(self) -> None:
        # INV-2: the refresh nudge must never spawn a subprocess on the headless path.
        provider = self._make_provider()
        provider._token = self._token(expiry="2000-01-01T00:00:00+00:00")
        try:
            providers.set_headless(True)
            with patch("gradus.providers.subprocess.run") as mock_run:
                self.assertFalse(provider._trigger_agy_self_refresh())
                mock_run.assert_not_called()
        finally:
            providers.set_headless(False)

    def test_nudge_cooldown_prevents_respawn(self) -> None:
        # A dead refresh token must not make us spawn `agy` on every refresh cycle.
        expired = self._token(expiry="2000-01-01T00:00:00+00:00")
        provider = self._make_provider()
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=expired),
            patch(
                "gradus.providers.subprocess.run",
                return_value=MagicMock(returncode=0),
            ) as mock_run,
        ):
            self.assertFalse(provider._trigger_agy_self_refresh())  # spawns
            self.assertFalse(provider._trigger_agy_self_refresh())  # within cooldown
        mock_run.assert_called_once()

    def test_agy_not_installed_falls_back_to_run_agy(self) -> None:
        expired = self._token(expiry="2000-01-01T00:00:00+00:00")
        provider = self._make_provider()
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=expired),
            patch("gradus.providers.subprocess.run", side_effect=FileNotFoundError),
            patch("gradus.providers._base._http_json") as mock_http,
        ):
            with self.assertRaises(ProbeFailure) as ctx:
                provider.fetch()
        self.assertIn("agy", str(ctx.exception))
        mock_http.assert_not_called()

    def test_nudge_survives_keychain_unreadable_after_agy(self) -> None:
        # If `agy models` runs but the Keychain re-read then fails, the nudge must
        # degrade to the run-agy error, not let FileNotFoundError escape.
        expired = self._token(expiry="2000-01-01T00:00:00+00:00")
        provider = self._make_provider()
        with (
            patch.object(
                AntigravityProvider,
                "_load_keychain_token",
                side_effect=[expired, FileNotFoundError("gone")],
            ),
            patch(
                "gradus.providers.subprocess.run",
                return_value=MagicMock(returncode=0),
            ),
            patch("gradus.providers._base._http_json") as mock_http,
        ):
            with self.assertRaises(ProbeFailure) as ctx:
                provider.fetch()
        self.assertIn("agy", str(ctx.exception))
        mock_http.assert_not_called()

    def test_401_nudge_fails_surfaces_run_agy_not_raw_401(self) -> None:
        # 401 + unrecoverable nudge -> actionable "run agy" error (drives the CTA),
        # never a bare "HTTP 401".
        valid = self._token()
        provider = self._make_provider()
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=valid),
            patch("gradus.providers.subprocess.run", side_effect=FileNotFoundError),
            patch("gradus.providers._base._http_json", side_effect=ProbeFailure("HTTP 401", "{}")),
        ):
            with self.assertRaises(ProbeFailure) as ctx:
                provider.fetch()
        msg = str(ctx.exception)
        self.assertIn("agy", msg)
        self.assertNotIn("HTTP 401", msg)

    def test_401_retry_still_401_surfaces_run_agy(self) -> None:
        # 401 -> nudge succeeds -> retry still 401 -> actionable "run agy" error.
        valid = self._token()

        def _http(url, **kwargs):
            raise ProbeFailure("HTTP 401", "{}")

        provider = self._make_provider()
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", side_effect=[valid, valid]),
            # nudge "succeeds" (exit 0, re-read valid) so we reach the retry.
            patch(
                "gradus.providers.subprocess.run",
                return_value=MagicMock(returncode=0),
            ),
            patch("gradus.providers._base._http_json", side_effect=_http),
        ):
            with self.assertRaises(ProbeFailure) as ctx:
                provider.fetch()
        msg = str(ctx.exception)
        self.assertIn("agy", msg)
        self.assertNotIn("HTTP 401", msg)

    def test_non_401_probe_failure_propagates_unchanged(self) -> None:
        # A network/5xx failure must NOT be rewritten to a run-agy error, and must
        # not trigger a nudge (so upstream transient-retry logic still applies).
        valid = self._token()
        provider = self._make_provider()
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=valid),
            patch("gradus.providers.subprocess.run") as mock_run,
            patch(
                "gradus.providers._base._http_json",
                side_effect=ProbeFailure("Network error: timed out", "x"),
            ),
        ):
            with self.assertRaises(ProbeFailure) as ctx:
                provider.fetch()
        self.assertIn("Network error", str(ctx.exception))
        mock_run.assert_not_called()

    def test_401_nudges_agy_and_retries(self) -> None:
        # Token looks valid but the server 401s the opaque token; nudge agy to
        # refresh its own token once, then retry the summary probe.
        valid = self._token()
        state = {"summary_calls": 0}

        def _http(url, **kwargs):
            state["summary_calls"] += 1
            if state["summary_calls"] == 1:
                raise ProbeFailure("HTTP 401", '{"error":"unauthenticated"}')
            return self.SUMMARY_RESPONSE

        provider = self._make_provider()
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", side_effect=[valid, valid]),
            patch(
                "gradus.providers.subprocess.run",
                return_value=MagicMock(returncode=0),
            ) as mock_run,
            patch("gradus.providers._base._http_json", side_effect=_http),
        ):
            status = provider.fetch()
        self.assertAlmostEqual(status.weekly_percent_left, 95.879453, places=6)
        self.assertEqual(state["summary_calls"], 2)  # original + one retry
        mock_run.assert_called_once()

    def test_keychain_decode_go_keyring_base64(self) -> None:
        import base64

        inner = {
            "auth_method": "consumer",
            "token": {
                "access_token": "ya29.decoded",
                "refresh_token": "1//r",
                "token_type": "Bearer",
                "expiry": "2999-01-01T00:00:00+00:00",
            },
        }
        wrapped = "go-keyring-base64:" + base64.b64encode(json.dumps(inner).encode()).decode()
        fake = MagicMock(returncode=0, stdout=wrapped, stderr="")
        with patch("gradus.providers.subprocess.run", return_value=fake):
            token = AntigravityProvider._load_keychain_token()
        self.assertEqual(token["access_token"], "ya29.decoded")

    def test_keychain_decode_plain_json(self) -> None:
        # go-keyring stores small UTF-8 secrets without the base64 wrapper.
        inner = {"token": {"access_token": "ya29.plain", "token_type": "Bearer"}}
        fake = MagicMock(returncode=0, stdout=json.dumps(inner), stderr="")
        with patch("gradus.providers.subprocess.run", return_value=fake):
            token = AntigravityProvider._load_keychain_token()
        self.assertEqual(token["access_token"], "ya29.plain")

    def test_missing_keychain_item_raises(self) -> None:
        fake = MagicMock(returncode=44, stdout="", stderr="could not be found")
        with patch("gradus.providers.subprocess.run", return_value=fake):
            with self.assertRaises(FileNotFoundError):
                AntigravityProvider._load_keychain_token()

    def test_acquire_raises_when_no_access_token(self) -> None:
        # Construction no longer raises (it does no credential I/O); the same
        # FileNotFoundError now surfaces from _acquire(), called lazily from fetch().
        provider = AntigravityProvider()
        with patch.object(AntigravityProvider, "_load_keychain_token", return_value={}):
            with self.assertRaises(FileNotFoundError):
                provider._acquire()

    def test_missing_gemini_group_raises(self) -> None:
        provider = self._make_provider()
        only_third_party = {"groups": [self.SUMMARY_RESPONSE["groups"][1]]}
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=self._token()),
            patch("gradus.providers._base._http_json", return_value=only_third_party),
        ):
            with self.assertRaises(ProbeFailure):
                provider.fetch()


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
        self._cursor_cache = self._root / "cursor_token.json"
        self._codex_auth = self._root / "auth.json"
        self._patchers = [
            patch.object(VibeProvider, "_CACHE_PATH", self._vibe_cache),
            patch.object(CursorProvider, "_CACHE_PATH", self._cursor_cache),
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
        self._cursor_cache.write_text(
            json.dumps({"access_token": _make_jwt(3600), "refresh_token": "rt"}),
            encoding="utf-8",
        )

    def _construct_and_fetch_all(self) -> None:
        """Construct + fetch all five providers, tolerating expected auth failures.

        Under headless mode fetch() is EXPECTED to fail with a truthful auth
        error (ProbeFailure) or, for Antigravity, a FileNotFoundError at
        construction — that is the correct outcome, so both are swallowed.
        """
        factories = [
            lambda: VibeProvider(str(self._root)),
            CursorProvider,
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
        # all five providers, including the cached-cred → 401 recovery on
        # Codex/Cursor. If either count is non-zero, a choke-point is ungated.
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
        original_cursor = self._cursor_cache.read_text(encoding="utf-8")
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
        # Cursor's 401 path must NOT evict the cache in headless mode.
        self.assertEqual(self._cursor_cache.read_text(encoding="utf-8"), original_cursor)
        # No provider may create a fresh cache file from a read.
        self.assertFalse(self._vibe_cache.exists())

    def test_acquire_never_launches_browser(self) -> None:
        # A credential-less probe is a pure cache read in either mode.
        try:
            for headless in (False, True):
                with patch("gradus.providers.subprocess.Popen") as popen:
                    providers.set_headless(headless)
                    provider = VibeProvider(str(self._root))
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
        self._cursor_cache = self._root / "cursor_token.json"
        self._codex_auth = self._root / "auth.json"
        self._patchers = [
            patch.object(VibeProvider, "_CACHE_PATH", self._vibe_cache),
            patch.object(CursorProvider, "_CACHE_PATH", self._cursor_cache),
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
                VibeProvider(str(self._root))
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
            "_load_keychain_access_token",
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

    def test_debug_dump_is_private_without_hardening_shared_parent(self) -> None:
        """The /tmp debug dump is written 0600 for privacy, but its parent (a
        shared, root-owned 1777 dir in production) must NOT be chmod'd: as a
        normal user that raises PermissionError and crashes --debug; as root it
        would strip /tmp's sticky bit machine-wide. Regression for that bug —
        against the pre-fix code (which chmod'd the parent to 0700) the final
        assertion fails.
        """
        with tempfile.TemporaryDirectory() as tmp:
            shared = Path(tmp) / "shared"  # stand-in for /tmp
            shared.mkdir()
            os.chmod(shared, 0o777)  # permissive, like /tmp
            dump_path = shared / "gradus_test_capture.txt"
            with patch("gradus.providers._base._debug_dump_path", return_value=dump_path):
                _write_debug_dump("Test", "raw capture output")
            # The dump file itself is private...
            self.assertEqual(stat.S_IMODE(os.stat(dump_path).st_mode), 0o600)
            # ...but the shared parent dir is left exactly as it was (never chmod'd).
            self.assertEqual(stat.S_IMODE(os.stat(shared).st_mode), 0o777)

    def test_load_from_cache_self_heals_permissions(self) -> None:
        """A pre-existing 0644 cache file is tightened to 0600 on a successful
        (non-headless) read — the opportunistic self-heal (1.3)."""
        with tempfile.TemporaryDirectory() as tmp:
            cache_path = Path(tmp) / "cursor_token.json"
            cache_path.write_text(
                json.dumps({"access_token": _make_jwt(3600), "refresh_token": "rt"}),
                encoding="utf-8",
            )
            os.chmod(cache_path, 0o644)
            with patch.object(CursorProvider, "_CACHE_PATH", cache_path):
                provider = CursorProvider.__new__(CursorProvider)
                result = provider._load_from_cache()
            self.assertTrue(result)
            self.assertEqual(stat.S_IMODE(os.stat(cache_path).st_mode), 0o600)


def _seroval_stream(node_json: str) -> bytes:
    """Frame one seroval JSON node as a solid-start stream chunk."""
    payload = node_json.encode("utf-8")
    return b";0x" + f"{len(payload):08x}".encode("ascii") + b";" + payload


# Decoded shape: [{"id": "wrk_a", "name": "Personal", "slug": "personal"}]
_SEROVAL_WORKSPACES = (
    '{"t":9,"i":0,"a":[{"t":10,"i":1,"p":{"k":["id","name","slug"],"v":['
    '{"t":1,"s":"wrk_a"},{"t":1,"s":"Personal"},{"t":1,"s":"personal"}]},"o":0}],"o":0}'
)

# Decoded shape: three usage windows; the repeated "ok" status string is
# deduped by seroval into one node (i:9) plus IndexedValue back-references.
_SEROVAL_SUBSCRIPTION = (
    '{"t":10,"i":0,"p":{"k":["mine","useBalance","rollingUsage","weeklyUsage","monthlyUsage"],'
    '"v":[{"t":2,"s":2},{"t":2,"s":3},'
    '{"t":10,"i":1,"p":{"k":["status","resetInSec","usagePercent"],"v":['
    '{"t":1,"i":9,"s":"ok"},{"t":0,"s":18000},{"t":0,"s":25}]},"o":0},'
    '{"t":10,"i":2,"p":{"k":["status","resetInSec","usagePercent"],"v":['
    '{"t":4,"i":9},{"t":0,"s":400000},{"t":0,"s":10}]},"o":0},'
    '{"t":10,"i":3,"p":{"k":["status","resetInSec","usagePercent"],"v":['
    '{"t":4,"i":9},{"t":0,"s":1200000},{"t":0,"s":100}]},"o":0}]},"o":0}'
)


class SerovalDecodeTests(unittest.TestCase):
    """The console's SolidStart server functions answer in seroval cross-JSON."""

    def test_framed_object_array_decodes(self) -> None:
        result = _seroval_decode(_seroval_stream(_SEROVAL_WORKSPACES))
        self.assertEqual(result, [{"id": "wrk_a", "name": "Personal", "slug": "personal"}])

    def test_indexed_value_backreferences_resolve(self) -> None:
        result = _seroval_decode(_seroval_stream(_SEROVAL_SUBSCRIPTION))
        self.assertEqual(result["rollingUsage"]["status"], "ok")
        self.assertEqual(result["weeklyUsage"]["status"], "ok")
        self.assertEqual(result["monthlyUsage"]["status"], "ok")
        self.assertEqual(result["rollingUsage"]["resetInSec"], 18000)
        self.assertEqual(result["monthlyUsage"]["usagePercent"], 100)
        self.assertIs(result["mine"], True)
        self.assertIs(result["useBalance"], False)

    def test_null_constant_decodes_to_none(self) -> None:
        self.assertIsNone(_seroval_decode(_seroval_stream('{"t":2,"s":0}')))

    def test_unframed_json_body_passes_through(self) -> None:
        self.assertEqual(_seroval_decode(b'{"status":500}'), {"status": 500})

    def test_empty_body_decodes_to_none(self) -> None:
        self.assertIsNone(_seroval_decode(b""))

    def test_invalid_payload_raises_probe_failure(self) -> None:
        with self.assertRaises(ProbeFailure):
            _seroval_decode(b"\x00\xff not json")

    def test_solidstart_js_response_decodes(self) -> None:
        js_body = (
            b';0x00000090;((self.$R=self.$R||{})["server-fn:0"]=[],'
            b'($R=>$R[0]=[$R[1]={id:"wrk_123",name:"test",slug:null}])($R["server-fn:0"]))'
        )
        result = _seroval_decode(js_body)
        self.assertEqual(result, [{"id": "wrk_123", "name": "test", "slug": None}])


class OpenCodeGoProviderTests(unittest.TestCase):
    WORKSPACES = [
        {"id": "wrk_a", "name": "Personal", "slug": "personal"},
        {"id": "wrk_b", "name": "Team", "slug": "team"},
    ]
    SUBSCRIPTION = {
        "mine": True,
        "useBalance": False,
        "rollingUsage": {"status": "ok", "resetInSec": 18000, "usagePercent": 25},
        "weeklyUsage": {"status": "ok", "resetInSec": 400000, "usagePercent": 10},
        "monthlyUsage": {"status": "rate-limited", "resetInSec": 1200000, "usagePercent": 100},
    }

    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self._cache_path = Path(self._tmpdir.name) / "opencode_go_cookies.json"
        self._patcher = patch.object(OpenCodeGoProvider, "_CACHE_PATH", self._cache_path)
        self._patcher.start()

    def tearDown(self) -> None:
        self._patcher.stop()
        self._tmpdir.cleanup()

    def _provider(self) -> OpenCodeGoProvider:
        self._cache_path.write_text(json.dumps({"auth": "cookie-value"}), encoding="utf-8")
        provider = OpenCodeGoProvider()
        provider._acquire()
        return provider

    def test_field_mapping_percent_remaining_and_resets(self) -> None:
        provider = self._provider()
        with (
            patch.object(provider, "_call_server_fn", return_value=self.WORKSPACES),
            patch.object(provider, "_fetch_subscription", return_value=self.SUBSCRIPTION),
        ):
            status = provider.fetch()
        # usagePercent is percent USED of the dollar limit; fields are remaining.
        self.assertEqual(status.five_hour_percent_left, 75)
        self.assertEqual(status.weekly_percent_left, 90)
        # rate-limited window reports usagePercent 100 -> 0% remaining.
        self.assertEqual(status.monthly_percent_left, 0)
        for reset in (status.five_hour_reset, status.weekly_reset, status.monthly_reset):
            self.assertIsNotNone(reset)
            assert reset is not None
            self.assertTrue(reset.startswith("Resets "))

    def test_percent_left_fields_are_float(self) -> None:
        provider = self._provider()
        with (
            patch.object(provider, "_call_server_fn", return_value=self.WORKSPACES),
            patch.object(provider, "_fetch_subscription", return_value=self.SUBSCRIPTION),
        ):
            status = provider.fetch()
        self.assertIsInstance(status.five_hour_percent_left, float)
        self.assertIsInstance(status.weekly_percent_left, float)
        self.assertIsInstance(status.monthly_percent_left, float)

    def test_subscribed_workspace_is_remembered(self) -> None:
        provider = self._provider()
        with (
            patch.object(provider, "_call_server_fn", return_value=self.WORKSPACES),
            patch.object(provider, "_fetch_subscription", side_effect=[None, self.SUBSCRIPTION]),
        ):
            provider.fetch()
        self.assertEqual(provider._workspace_id, "wrk_b")
        # Next refresh probes the remembered workspace first (two calls total).
        with (
            patch.object(provider, "_call_server_fn", return_value=self.WORKSPACES),
            patch.object(
                provider, "_fetch_subscription", return_value=self.SUBSCRIPTION
            ) as call_sub,
        ):
            provider.fetch()
        self.assertEqual(call_sub.call_count, 1)
        self.assertEqual(call_sub.call_args_list[0].args[0], "wrk_b")

    def test_no_subscription_anywhere_raises(self) -> None:
        provider = self._provider()
        with (
            patch.object(provider, "_call_server_fn", return_value=self.WORKSPACES),
            patch.object(provider, "_fetch_subscription", return_value=None),
        ):
            with self.assertRaises(ProbeFailure) as ctx:
                provider.fetch()
        self.assertIn("No OpenCode Go subscription", str(ctx.exception))

    def test_all_windows_missing_raises(self) -> None:
        provider = self._provider()
        with (
            patch.object(provider, "_call_server_fn", return_value=self.WORKSPACES),
            patch.object(
                provider,
                "_fetch_subscription",
                return_value={"rollingUsage": {}, "weeklyUsage": None},
            ),
        ):
            with self.assertRaises(ProbeFailure) as ctx:
                provider.fetch()
        self.assertIn("no recognizable windows", str(ctx.exception))

    def test_null_workspaces_is_auth_error_and_evicts_cache(self) -> None:
        provider = self._provider()
        self.assertTrue(self._cache_path.exists())
        with patch.object(provider, "_call_server_fn", return_value=None):
            with self.assertRaises(ProbeFailure) as ctx:
                provider.fetch()
        self.assertIn("session expired", str(ctx.exception).lower())
        self.assertFalse(self._cache_path.exists())
        self.assertEqual(provider._auth_cookie, "")

    def test_rejected_cookie_evicts_cache(self) -> None:
        provider = self._provider()
        with patch.object(provider, "_call_server_fn", side_effect=_AuthRejected("redirect")):
            with self.assertRaises(ProbeFailure) as ctx:
                provider.fetch()
        self.assertIn("session expired", str(ctx.exception).lower())
        self.assertFalse(self._cache_path.exists())

    def test_missing_cookie_raises_auth_message(self) -> None:
        provider = OpenCodeGoProvider()
        with self.assertRaises(ProbeFailure) as ctx:
            provider.fetch()
        self.assertIn("sign in at opencode.ai", str(ctx.exception))

    def test_auth_error_routes_to_fix_action(self) -> None:
        snap = ProviderSnapshot(
            name="OpenCode Go",
            ok=False,
            source="api",
            error="OpenCode Go session expired. Sign in at opencode.ai to refresh.",
        )
        self.assertTrue(_is_auth_error(snap))

    def test_cache_is_the_only_credential_source(self) -> None:
        self._cache_path.parent.mkdir(parents=True, exist_ok=True)
        self._cache_path.write_text(json.dumps({"auth": "cached-cookie"}), encoding="utf-8")
        provider = OpenCodeGoProvider()
        provider._acquire()
        self.assertEqual(provider._auth_cookie, "cached-cookie")

    def test_missing_cache_does_not_create_credentials(self) -> None:
        provider = OpenCodeGoProvider()
        provider._acquire()
        self.assertFalse(self._cache_path.exists())

    def test_missing_cache_fails_then_restored_cache_recovers(self) -> None:
        provider = OpenCodeGoProvider()
        with self.assertRaises(ProbeFailure) as missing:
            provider.fetch()
        self.assertIn("sign in at opencode.ai", str(missing.exception))
        self.assertFalse(self._cache_path.exists())

        self._cache_path.write_text(json.dumps({"auth": "restored-cookie"}), encoding="utf-8")
        with (
            patch.object(provider, "_call_server_fn", return_value=self.WORKSPACES),
            patch.object(provider, "_fetch_subscription", return_value=self.SUBSCRIPTION),
        ):
            recovered = provider.fetch()
        self.assertEqual(recovered.five_hour_percent_left, 75)
        self.assertEqual(recovered.weekly_percent_left, 90)


class OpenCodeGoSerovalIntegrationTests(unittest.TestCase):
    """End-to-end: framed seroval wire bodies -> parsed status fields."""

    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        patcher = patch.object(
            OpenCodeGoProvider,
            "_CACHE_PATH",
            Path(self._tmpdir.name) / "opencode_go_cookies.json",
        )
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self._tmpdir.cleanup)

    def test_fetch_decodes_wire_payloads(self) -> None:
        cache_path = OpenCodeGoProvider._CACHE_PATH
        cache_path.write_text(json.dumps({"auth": "cookie-value"}), encoding="utf-8")
        provider = OpenCodeGoProvider()
        bodies = [
            _seroval_stream(_SEROVAL_WORKSPACES),
        ]

        class _Resp:
            def __init__(self, body: bytes) -> None:
                self.headers: dict[str, str] = {}
                self._body = body

            def read(self) -> bytes:
                return self._body

            def __enter__(self) -> _Resp:
                return self

            def __exit__(self, *args: object) -> bool:
                return False

        class _RespSub(_Resp):
            def __init__(self, body: bytes) -> None:
                super().__init__(body)
                self.url = "https://opencode.ai/workspace/1/go"

        responses = [_Resp(body) for body in bodies]
        html_body = b'rollingUsage:$R[1]={status:"ok",resetInSec:100,usagePercent:25}weeklyUsage:$R[2]={status:"ok",resetInSec:100,usagePercent:10}monthlyUsage:$R[3]={status:"rate-limited",resetInSec:1200000,usagePercent:100}'

        with (
            patch("gradus.providers.urllib.request.build_opener") as build,
            patch("gradus.providers.urllib.request.urlopen") as urlopen_mock,
        ):
            opener = MagicMock()
            opener.open.side_effect = responses
            build.return_value = opener
            urlopen_mock.return_value = _RespSub(html_body)
            status = provider.fetch()

        self.assertEqual(status.five_hour_percent_left, 75)
        self.assertEqual(status.weekly_percent_left, 90)
        self.assertEqual(status.monthly_percent_left, 0)


if __name__ == "__main__":
    unittest.main()
