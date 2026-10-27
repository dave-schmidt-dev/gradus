"""Vibe provider tests."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from gradus.__main__ import _is_auth_error
from gradus.providers import (
    ProbeFailure,
    ProviderSnapshot,
    VibeApiProvider,
    VibeCodeProvider,
)


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
        # Isolate _CACHE_PATH so constructing VibeCodeProvider can't overwrite the
        # repo's real .cache/vibe_cookies.json with whatever cookies Safari holds.
        self._tmpdir = tempfile.TemporaryDirectory()
        self._cache_path = Path(self._tmpdir.name) / "vibe_cookies.json"
        self._patcher = patch.object(VibeCodeProvider, "_CACHE_PATH", self._cache_path)
        self._patcher.start()

    def tearDown(self) -> None:
        self._patcher.stop()
        self._tmpdir.cleanup()

    def test_usage_percentage_is_not_scaled_again(self) -> None:
        provider = VibeCodeProvider(".")
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
        provider = VibeCodeProvider(".")
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
        provider = VibeCodeProvider(".")
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
        provider = VibeCodeProvider(".")
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


class VibeApiProviderTests(unittest.TestCase):
    """The "Vibe" entry reads only ``api_budget`` from billing.budget."""

    BUDGET = {
        "result": {
            "data": {
                "json": {
                    "usage_percentage": 100,
                    "initial_budget": 15,
                    "currency": "USD",
                    "reset_at": "2026-10-01T00:00:00Z",
                    "api_budget": {
                        "usage_percentage": 100,
                        "initial_budget": 15,
                        "currency": "USD",
                        "reset_at": "2026-10-01T00:00:00Z",
                    },
                    "vibe_budget": {
                        "usage_percentage": 66.3,
                        "initial_budget": 150,
                        "currency": "USD",
                        "reset_at": "2026-10-01T00:00:00Z",
                    },
                }
            }
        }
    }

    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self._patcher = patch.object(
            VibeApiProvider, "_CACHE_PATH", Path(self._tmpdir.name) / "vibe_cookies.json"
        )
        self._patcher.start()

    def tearDown(self) -> None:
        self._patcher.stop()
        self._tmpdir.cleanup()

    def _fetch(self, payload: dict):
        provider = VibeApiProvider(".")
        provider._ory_name, provider._ory_value, provider._csrf = "ory_session_t", "tok", "csrf"
        resp = MagicMock()
        resp.read.return_value = json.dumps(payload).encode("utf-8")
        resp.__enter__ = lambda s: s
        resp.__exit__ = MagicMock(return_value=False)
        with patch("urllib.request.urlopen", return_value=resp) as urlopen:
            return provider.fetch(), urlopen

    def test_reads_api_budget_not_vibe_budget(self) -> None:
        status, urlopen = self._fetch(self.BUDGET)
        self.assertEqual(status.usage_percent, 100.0)
        request = urlopen.call_args.args[0]
        self.assertIn("admin.mistral.ai/api/local-trpc/billing.budget", request.full_url)

    def test_cycle_is_the_calendar_month_ending_at_reset(self) -> None:
        status, _ = self._fetch(self.BUDGET)
        self.assertEqual(status.start_date, "2026-09-01T00:00:00+00:00")
        self.assertEqual(status.end_date, "2026-10-01T00:00:00+00:00")

    def test_missing_api_budget_is_a_probe_failure(self) -> None:
        payload = {"result": {"data": {"json": {"vibe_budget": {"usage_percentage": 5}}}}}
        with self.assertRaises(ProbeFailure):
            self._fetch(payload)

    def test_registered_under_both_entry_names(self) -> None:
        from gradus.providers._base import _PROVIDER_REGISTRY

        self.assertIs(_PROVIDER_REGISTRY["Vibe"], VibeApiProvider)
        self.assertIs(_PROVIDER_REGISTRY["Vibe Code"], VibeCodeProvider)


class VibeCookieCacheTests(unittest.TestCase):
    """Vibe reads bridge-written cache files only."""

    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self._cache_path = Path(self._tmpdir.name) / "vibe_cookies.json"
        self._patcher = patch.object(VibeCodeProvider, "_CACHE_PATH", self._cache_path)
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
        provider = VibeCodeProvider(project_root=self._tmpdir.name)
        provider._acquire()
        self.assertEqual(provider._ory_name, "ory_session_x")
        self.assertEqual(provider._ory_value, "v")
        self.assertEqual(provider._csrf, "c")

    def test_missing_cache_does_not_create_credentials(self) -> None:
        provider = VibeCodeProvider(project_root=self._tmpdir.name)
        provider._acquire()
        self.assertFalse(self._cache_path.exists())

    def test_missing_cache_reports_no_session_rather_than_an_expired_one(self) -> None:
        # The provider cannot tell a denied bridge from a signed-out Safari;
        # "expired" claimed the latter and sent the user to sign in when the
        # fix was a Full Disk Access grant. The Mac resolver and the TUI both
        # classify "session unavailable" as needing authentication.
        from gradus.history import _probe_metadata
        from gradus.snapshot import _is_transient_probe_error

        provider = VibeCodeProvider(project_root=self._tmpdir.name)
        with patch("gradus.providers._base._is_headless", return_value=False):
            with self.assertRaises(ProbeFailure) as ctx:
                provider.fetch()
        message = str(ctx.exception)
        self.assertIn("session unavailable", message)
        self.assertNotIn("expired", message)
        self.assertIn("console.mistral.ai", message)
        snapshot = ProviderSnapshot(name="Vibe", ok=False, source="api", error=message)
        self.assertTrue(_is_auth_error(snapshot))
        self.assertFalse(_is_transient_probe_error(snapshot))
        self.assertEqual(_probe_metadata(snapshot, {})["reason"], "auth_failure")

    def test_401_clears_cache(self) -> None:
        import urllib.error as ue

        self._cache_path.parent.mkdir(parents=True, exist_ok=True)
        self._cache_path.write_text(
            json.dumps(
                {"ory_session_name": "ory_session_x", "ory_session_value": "v", "csrftoken": "c"}
            ),
            encoding="utf-8",
        )
        provider = VibeCodeProvider(project_root=self._tmpdir.name)
        err = ue.HTTPError("u", 401, "Unauthorized", {}, None)  # type: ignore[arg-type]
        with patch("urllib.request.urlopen", side_effect=err):
            with self.assertRaises(ProbeFailure) as ctx:
                provider.fetch()
        self.assertFalse(self._cache_path.exists())
        self.assertIn("session expired", str(ctx.exception))


class CacheResilienceTests(unittest.TestCase):
    """Malformed bridge output must fail closed without browser fallback."""

    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self._vibe_cache = Path(self._tmpdir.name) / "vibe_cookies.json"
        self._patchers = [
            patch.object(VibeCodeProvider, "_CACHE_PATH", self._vibe_cache),
        ]
        for p in self._patchers:
            p.start()

    def tearDown(self) -> None:
        for p in self._patchers:
            p.stop()
        self._tmpdir.cleanup()

    def test_vibe_corrupted_cache_is_ignored(self) -> None:
        self._vibe_cache.parent.mkdir(parents=True, exist_ok=True)
        self._vibe_cache.write_text("{ NOT VALID JSON !!!", encoding="utf-8")
        provider = VibeCodeProvider(project_root=self._tmpdir.name)
        provider._acquire()
        self.assertFalse(provider._has_cookies)
