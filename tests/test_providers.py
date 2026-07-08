"""Provider helper tests."""

from __future__ import annotations

import base64
import json
import os
import stat
import tempfile
import time
import unittest
from datetime import datetime
from pathlib import Path
from unittest.mock import MagicMock, patch

from ai_monitor import providers
from ai_monitor.providers import (
    AntigravityProvider,
    ClaudeHttpProvider,
    CodexHttpProvider,
    CursorProvider,
    ProbeFailure,
    VibeProvider,
    _format_reset_time,
    _http_json,
    _is_jwt_expired,
    _write_debug_dump,
)


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
    """Regression: aimonitor must keep working when Safari has lost the cookie."""

    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self._cache_path = Path(self._tmpdir.name) / "cursor_token.json"
        # Patch class attribute so provider instances use the tempfile.
        self._patcher = patch.object(CursorProvider, "_CACHE_PATH", self._cache_path)
        self._patcher.start()

    def tearDown(self) -> None:
        self._patcher.stop()
        self._tmpdir.cleanup()

    def test_cache_used_when_safari_empty(self) -> None:
        """If cache has a valid token, Safari is not consulted and no browser opens."""
        valid_jwt = _make_jwt(3600)
        self._cache_path.parent.mkdir(parents=True, exist_ok=True)
        self._cache_path.write_text(
            json.dumps({"access_token": valid_jwt, "refresh_token": "rt"}),
            encoding="utf-8",
        )
        with (
            patch("ai_monitor.providers._read_safari_cookies", return_value={}) as safari,
            patch("ai_monitor.providers.subprocess.Popen") as popen,
        ):
            provider = CursorProvider()
        self.assertEqual(provider._access_token, valid_jwt)
        self.assertEqual(provider._refresh_token, "rt")
        self.assertEqual(provider._token_source, "cache")
        safari.assert_not_called()
        popen.assert_not_called()

    def test_expired_cache_falls_back_to_safari(self) -> None:
        """Expired cached token is ignored; Safari is consulted instead."""
        self._cache_path.parent.mkdir(parents=True, exist_ok=True)
        self._cache_path.write_text(
            json.dumps({"access_token": _make_jwt(-3600)}),
            encoding="utf-8",
        )
        fresh_jwt = _make_jwt(3600)
        cookie_value = f"user_x%3A%3A{fresh_jwt}"
        with patch(
            "ai_monitor.providers._read_safari_cookies",
            return_value={"WorkosCursorSessionToken": cookie_value},
        ):
            provider = CursorProvider()
        self.assertEqual(provider._access_token, fresh_jwt)
        self.assertEqual(provider._token_source, "safari")

    def test_safari_read_writes_cache(self) -> None:
        """First Safari read persists the token for subsequent runs."""
        fresh_jwt = _make_jwt(3600)
        cookie_value = f"user_x%3A%3A{fresh_jwt}"
        with patch(
            "ai_monitor.providers._read_safari_cookies",
            return_value={"WorkosCursorSessionToken": cookie_value},
        ):
            CursorProvider()
        self.assertTrue(self._cache_path.exists())
        cached = json.loads(self._cache_path.read_text(encoding="utf-8"))
        self.assertEqual(cached["access_token"], fresh_jwt)

    def test_401_clears_cache(self) -> None:
        """A rejected token must be evicted so the next startup re-reads from Safari."""
        import urllib.error as ue

        valid_jwt = _make_jwt(3600)
        self._cache_path.parent.mkdir(parents=True, exist_ok=True)
        self._cache_path.write_text(json.dumps({"access_token": valid_jwt}), encoding="utf-8")
        with patch("ai_monitor.providers._read_safari_cookies", return_value={}):
            provider = CursorProvider()
        err = ue.HTTPError("u", 401, "Unauthorized", {}, None)  # type: ignore[arg-type]
        with patch.object(provider, "_api_post", side_effect=err):
            with self.assertRaises(ProbeFailure):
                provider.fetch()
        self.assertFalse(self._cache_path.exists())


class ClaudeCookieCacheTests(unittest.TestCase):
    """Same disk-sync-lag fix as Cursor: cache Safari cookies to local file."""

    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self._cache_path = Path(self._tmpdir.name) / "claude_cookies.json"
        self._patcher = patch.object(ClaudeHttpProvider, "_CACHE_PATH", self._cache_path)
        self._patcher.start()

    def tearDown(self) -> None:
        self._patcher.stop()
        self._tmpdir.cleanup()

    def test_cache_used_when_safari_empty(self) -> None:
        self._cache_path.parent.mkdir(parents=True, exist_ok=True)
        self._cache_path.write_text(
            json.dumps({"sessionKey": "sk", "cf_clearance": "cf", "lastActiveOrg": "org"}),
            encoding="utf-8",
        )
        with (
            patch("ai_monitor.providers._read_safari_cookies", return_value={}) as safari,
            patch("ai_monitor.providers.subprocess.Popen") as popen,
        ):
            provider = ClaudeHttpProvider()
        self.assertEqual(provider._session_key, "sk")
        self.assertEqual(provider._cf_clearance, "cf")
        self.assertEqual(provider._org_id, "org")
        safari.assert_not_called()
        popen.assert_not_called()

    def test_safari_read_writes_cache(self) -> None:
        with patch(
            "ai_monitor.providers._read_safari_cookies",
            return_value={"sessionKey": "sk", "cf_clearance": "cf", "lastActiveOrg": "org"},
        ):
            ClaudeHttpProvider()
        self.assertTrue(self._cache_path.exists())
        cached = json.loads(self._cache_path.read_text(encoding="utf-8"))
        self.assertEqual(cached["sessionKey"], "sk")
        self.assertEqual(cached["lastActiveOrg"], "org")

    def test_403_clears_cache(self) -> None:
        """cf_clearance can expire fast; a 403 must evict the cache to recover."""
        self._cache_path.parent.mkdir(parents=True, exist_ok=True)
        self._cache_path.write_text(
            json.dumps({"sessionKey": "sk", "cf_clearance": "cf", "lastActiveOrg": "org"}),
            encoding="utf-8",
        )
        with patch("ai_monitor.providers._read_safari_cookies", return_value={}):
            provider = ClaudeHttpProvider()
        with patch(
            "ai_monitor.providers._http_json",
            side_effect=ProbeFailure("Claude API returned HTTP 403", ""),
        ):
            with self.assertRaises(ProbeFailure):
                provider.fetch()
        self.assertFalse(self._cache_path.exists())

    def test_400_clears_cache(self) -> None:
        # Regression for the 2026-05-30 cache-poison bug: a cached lastActiveOrg
        # that is not a valid UUID makes Claude return HTTP 400 (invalid_request_error)
        # rather than 401/403, so without 400 in the eviction set the poison is sticky.
        self._cache_path.parent.mkdir(parents=True, exist_ok=True)
        self._cache_path.write_text(
            json.dumps(
                {"sessionKey": "sk-ant-test", "cf_clearance": "cf_test", "lastActiveOrg": "org-123"}
            ),
            encoding="utf-8",
        )
        with patch("ai_monitor.providers._read_safari_cookies", return_value={}):
            provider = ClaudeHttpProvider()
        with patch(
            "ai_monitor.providers._http_json",
            side_effect=ProbeFailure("HTTP 400", ""),
        ):
            with self.assertRaises(ProbeFailure) as ctx:
                provider.fetch()
        self.assertFalse(self._cache_path.exists())
        self.assertIn("session expired", str(ctx.exception).lower())


class VibeCookieCacheTests(unittest.TestCase):
    """Same disk-sync-lag fix as Cursor: cache Mistral cookies to local file."""

    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self._cache_path = Path(self._tmpdir.name) / "vibe_cookies.json"
        self._patcher = patch.object(VibeProvider, "_CACHE_PATH", self._cache_path)
        self._patcher.start()

    def tearDown(self) -> None:
        self._patcher.stop()
        self._tmpdir.cleanup()

    def test_cache_used_when_safari_and_chrome_empty(self) -> None:
        self._cache_path.parent.mkdir(parents=True, exist_ok=True)
        self._cache_path.write_text(
            json.dumps(
                {"ory_session_name": "ory_session_x", "ory_session_value": "v", "csrftoken": "c"}
            ),
            encoding="utf-8",
        )
        with (
            patch.object(VibeProvider, "_extract_safari_cookies", return_value=None) as safari,
            patch.object(VibeProvider, "_extract_chrome_cookies", return_value=None) as chrome,
            patch("ai_monitor.providers.subprocess.Popen") as popen,
        ):
            provider = VibeProvider(project_root=self._tmpdir.name)
        self.assertEqual(provider._ory_name, "ory_session_x")
        self.assertEqual(provider._ory_value, "v")
        self.assertEqual(provider._csrf, "c")
        safari.assert_not_called()
        chrome.assert_not_called()
        popen.assert_not_called()

    def test_safari_read_writes_cache(self) -> None:
        with patch.object(
            VibeProvider,
            "_extract_safari_cookies",
            return_value={
                "ory_session_name": "ory_session_x",
                "ory_session_value": "v",
                "csrftoken": "c",
            },
        ):
            VibeProvider(project_root=self._tmpdir.name)
        self.assertTrue(self._cache_path.exists())
        cached = json.loads(self._cache_path.read_text(encoding="utf-8"))
        self.assertEqual(cached["ory_session_name"], "ory_session_x")
        self.assertEqual(cached["csrftoken"], "c")

    def test_401_clears_cache(self) -> None:
        import urllib.error as ue

        self._cache_path.parent.mkdir(parents=True, exist_ok=True)
        self._cache_path.write_text(
            json.dumps(
                {"ory_session_name": "ory_session_x", "ory_session_value": "v", "csrftoken": "c"}
            ),
            encoding="utf-8",
        )
        with (
            patch.object(VibeProvider, "_extract_safari_cookies", return_value=None),
            patch.object(VibeProvider, "_extract_chrome_cookies", return_value=None),
        ):
            provider = VibeProvider(project_root=self._tmpdir.name)
        err = ue.HTTPError("u", 401, "Unauthorized", {}, None)  # type: ignore[arg-type]
        with patch("urllib.request.urlopen", side_effect=err):
            with self.assertRaises(ProbeFailure):
                provider.fetch()
        self.assertFalse(self._cache_path.exists())


class CacheResilienceTests(unittest.TestCase):
    """Edge-cases: corrupted cache files and write failures must not break providers."""

    def setUp(self) -> None:
        self._tmpdir = tempfile.TemporaryDirectory()
        self._cursor_cache = Path(self._tmpdir.name) / "cursor_token.json"
        self._claude_cache = Path(self._tmpdir.name) / "claude_cookies.json"
        self._vibe_cache = Path(self._tmpdir.name) / "vibe_cookies.json"
        self._patchers = [
            patch.object(CursorProvider, "_CACHE_PATH", self._cursor_cache),
            patch.object(ClaudeHttpProvider, "_CACHE_PATH", self._claude_cache),
            patch.object(VibeProvider, "_CACHE_PATH", self._vibe_cache),
        ]
        for p in self._patchers:
            p.start()

    def tearDown(self) -> None:
        for p in self._patchers:
            p.stop()
        self._tmpdir.cleanup()

    def test_cursor_corrupted_cache_falls_back_to_safari(self) -> None:
        """Garbage JSON in cursor cache is silently ignored; Safari is consulted."""
        self._cursor_cache.parent.mkdir(parents=True, exist_ok=True)
        self._cursor_cache.write_text("{ NOT VALID JSON !!!", encoding="utf-8")
        fresh_jwt = _make_jwt(3600)
        cookie_value = f"user_x%3A%3A{fresh_jwt}"
        with patch(
            "ai_monitor.providers._read_safari_cookies",
            return_value={"WorkosCursorSessionToken": cookie_value},
        ):
            provider = CursorProvider()
        self.assertEqual(provider._access_token, fresh_jwt)
        self.assertEqual(provider._token_source, "safari")

    def test_claude_corrupted_cache_falls_back_to_safari(self) -> None:
        """Garbage JSON in Claude cache is silently ignored; Safari is consulted."""
        self._claude_cache.parent.mkdir(parents=True, exist_ok=True)
        self._claude_cache.write_text("{ NOT VALID JSON !!!", encoding="utf-8")
        with patch(
            "ai_monitor.providers._read_safari_cookies",
            return_value={"sessionKey": "sk", "cf_clearance": "cf", "lastActiveOrg": "org"},
        ):
            provider = ClaudeHttpProvider()
        self.assertEqual(provider._session_key, "sk")
        self.assertEqual(provider._org_id, "org")

    def test_vibe_corrupted_cache_falls_back_to_safari(self) -> None:
        """Garbage JSON in Vibe cache is silently ignored; Safari is consulted."""
        self._vibe_cache.parent.mkdir(parents=True, exist_ok=True)
        self._vibe_cache.write_text("{ NOT VALID JSON !!!", encoding="utf-8")
        with patch.object(
            VibeProvider,
            "_extract_safari_cookies",
            return_value={
                "ory_session_name": "ory_session_x",
                "ory_session_value": "v",
                "csrftoken": "c",
            },
        ):
            provider = VibeProvider(project_root=self._tmpdir.name)
        self.assertEqual(provider._ory_name, "ory_session_x")

    def test_cursor_save_cache_oserror_does_not_break_provider(self) -> None:
        """If writing the cache raises OSError, the provider still has a valid token."""
        fresh_jwt = _make_jwt(3600)
        cookie_value = f"user_x%3A%3A{fresh_jwt}"
        with (
            patch(
                "ai_monitor.providers._read_safari_cookies",
                return_value={"WorkosCursorSessionToken": cookie_value},
            ),
            patch("pathlib.Path.mkdir", side_effect=OSError("no space")),
        ):
            provider = CursorProvider()
        self.assertEqual(provider._access_token, fresh_jwt)

    def test_cursor_refresh_writes_new_refresh_token_to_cache(self) -> None:
        """After a token refresh, the updated refresh_token must be persisted."""
        import urllib.error as ue

        valid_jwt = _make_jwt(3600)
        self._cursor_cache.parent.mkdir(parents=True, exist_ok=True)
        self._cursor_cache.write_text(
            json.dumps({"access_token": valid_jwt, "refresh_token": "old_rt"}),
            encoding="utf-8",
        )
        with patch("ai_monitor.providers._read_safari_cookies", return_value={}):
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

        # Cache must now contain the new refresh token
        cached = json.loads(self._cursor_cache.read_text(encoding="utf-8"))
        self.assertEqual(cached["access_token"], new_jwt)
        self.assertEqual(cached["refresh_token"], "new_rt")


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
        auth_data = {
            "tokens": {
                "access_token": "test_access_token",
                "account_id": "test_account_id",
            }
        }
        with patch.object(CodexHttpProvider, "_AUTH_PATH") as mock_path:
            mock_path.exists.return_value = True
            mock_path.read_text.return_value = json.dumps(auth_data)
            return CodexHttpProvider()

    def test_normal_response_field_mapping(self) -> None:
        provider = self._make_provider()
        with patch("ai_monitor.providers._http_json", return_value=self.NORMAL_RESPONSE):
            status = provider.fetch()
        # 100 - 20 = 80
        self.assertEqual(status.five_hour_percent_left, 80)
        self.assertEqual(status.weekly_percent_left, 80)
        self.assertAlmostEqual(status.credits, 12.5)
        self.assertIsNotNone(status.five_hour_reset)
        self.assertIsNotNone(status.weekly_reset)

    def test_401_raises_probe_failure(self) -> None:
        provider = self._make_provider()
        with patch("ai_monitor.providers._http_json", side_effect=ProbeFailure("HTTP 401", "")):
            with self.assertRaises(ProbeFailure):
                provider.fetch()

    def test_401_reloads_auth_json_and_retries(self) -> None:
        # Regression: previously the provider cached _access_token at __init__ and never
        # reloaded it, so running `codex login` after a 401 left aimonitor stuck on the
        # stale token forever. The 401 path must re-read ~/.codex/auth.json from disk.
        provider = self._make_provider()
        self.assertEqual(provider._access_token, "test_access_token")

        refreshed_auth = json.dumps(
            {"tokens": {"access_token": "fresh_token", "account_id": "test_account_id"}}
        )
        with patch.object(CodexHttpProvider, "_AUTH_PATH") as mock_path:
            mock_path.exists.return_value = True
            mock_path.read_text.return_value = refreshed_auth
            with patch(
                "ai_monitor.providers._http_json",
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
                    "ai_monitor.providers._http_json",
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
                "ai_monitor.providers._http_json",
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
            with patch("ai_monitor.providers._http_json") as mock_http:
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
                "ai_monitor.providers._http_json",
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
            with patch("ai_monitor.providers._http_json", side_effect=side_effect_fn):
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
            with patch("ai_monitor.providers._http_json", side_effect=side_effect_fn):
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
            with patch("ai_monitor.providers._http_json", side_effect=side_effect_fn):
                with self.assertRaises(ProbeFailure) as ctx:
                    provider.fetch()

        self.assertEqual(call_count, 3)
        self.assertIn("re-authenticate", str(ctx.exception).lower())


class ClaudeHttpProviderTests(unittest.TestCase):
    # Real API: {five_hour: {utilization, resets_at}, seven_day: {...}, seven_day_opus: {...}}
    NORMAL_RESPONSE = {
        "five_hour": {"utilization": 30.0, "resets_at": "2026-04-17T00:00:00Z"},
        "seven_day": {"utilization": 45.0, "resets_at": "2026-04-21T00:00:00Z"},
        "seven_day_opus": {"utilization": 10.0, "resets_at": "2026-04-21T00:00:00Z"},
    }

    def setUp(self) -> None:
        # Isolate _CACHE_PATH: _make_provider mocks _read_safari_cookies with fixture
        # values, and without this isolation the constructor would write those fixtures
        # straight to the repo's real .cache/claude_cookies.json — which is exactly how
        # the 2026-05-30 weekend cache work landed sk-ant-test/org-123 in production
        # and produced HTTP 400 from Claude's UUID validator.
        self._tmpdir = tempfile.TemporaryDirectory()
        self._cache_path = Path(self._tmpdir.name) / "claude_cookies.json"
        self._patcher = patch.object(ClaudeHttpProvider, "_CACHE_PATH", self._cache_path)
        self._patcher.start()

    def tearDown(self) -> None:
        self._patcher.stop()
        self._tmpdir.cleanup()

    def _make_provider(self) -> ClaudeHttpProvider:
        cookies = {
            "sessionKey": "sk-ant-test",
            "cf_clearance": "cf_test",
            "lastActiveOrg": "org-123",
        }
        with patch("ai_monitor.providers._read_safari_cookies", return_value=cookies):
            return ClaudeHttpProvider()

    def test_normal_response_field_mapping(self) -> None:
        provider = self._make_provider()
        with patch("ai_monitor.providers._http_json", return_value=self.NORMAL_RESPONSE):
            status = provider.fetch()
        # 100 - 30 = 70
        self.assertEqual(status.session_percent_left, 70)
        # 100 - 45 = 55
        self.assertEqual(status.weekly_percent_left, 55)
        # 100 - 10 = 90
        self.assertEqual(status.opus_percent_left, 90)
        self.assertIsNone(status.account_email)
        self.assertIsNone(status.account_organization)
        self.assertIsNone(status.login_method)

    def test_401_raises_probe_failure(self) -> None:
        provider = self._make_provider()
        with patch("ai_monitor.providers._http_json", side_effect=ProbeFailure("HTTP 401", "")):
            with self.assertRaises(ProbeFailure) as ctx:
                provider.fetch()
        self.assertIn("session expired", str(ctx.exception).lower())

    def test_missing_cookies_raises_probe_failure(self) -> None:
        # Patches must stay active through fetch() so _load_cookies() still finds nothing
        with (
            patch("ai_monitor.providers._read_safari_cookies", return_value={}),
            patch("subprocess.Popen"),
        ):
            provider = ClaudeHttpProvider()
            with self.assertRaises(ProbeFailure) as ctx:
                provider.fetch()
        self.assertIn("claude.ai", str(ctx.exception).lower())


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
                    {"bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 1},
                    {"bucketId": "3p-5h", "window": "5h", "remainingFraction": 1},
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
                "ai_monitor.providers._http_json", return_value=self.SUMMARY_RESPONSE
            ) as mock_http,
        ):
            status = provider.fetch()
        self.assertEqual(status.five_hour_percent_left, 86)
        self.assertEqual(status.weekly_percent_left, 96)
        self.assertIsNotNone(status.five_hour_reset)
        self.assertIsNotNone(status.weekly_reset)
        # The endpoint rejects a non-empty body (400) and the default urllib UA (403).
        _, kwargs = mock_http.call_args
        self.assertEqual(kwargs["body"], b"{}")
        self.assertIn("antigravity", kwargs["headers"]["User-Agent"].lower())
        self.assertTrue(kwargs["headers"]["Authorization"].startswith("Bearer "))

    def test_selects_gemini_group_not_third_party(self) -> None:
        # Gemini weekly is 96%, the Claude+GPT group is 100%; we must read Gemini's.
        provider = self._make_provider()
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=self._token()),
            patch("ai_monitor.providers._http_json", return_value=self.SUMMARY_RESPONSE),
        ):
            status = provider.fetch()
        self.assertEqual(status.weekly_percent_left, 96)

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
                "ai_monitor.providers.subprocess.run",
                return_value=MagicMock(returncode=0),
            ) as mock_run,
            patch("ai_monitor.providers._http_json") as mock_http,
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
                "ai_monitor.providers.subprocess.run",
                return_value=MagicMock(returncode=0),
            ) as mock_run,
            patch("ai_monitor.providers._http_json", return_value=self.SUMMARY_RESPONSE),
        ):
            status = provider.fetch()
        self.assertEqual(status.five_hour_percent_left, 86)
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
                "ai_monitor.providers.subprocess.run",
                return_value=MagicMock(returncode=1),
            ),
        ):
            self.assertFalse(provider._trigger_agy_self_refresh())

    def test_nudge_returns_false_when_refreshed_token_has_no_access_token(self) -> None:
        # A malformed re-read (no access_token, no expiry) must not count as success.
        provider = self._make_provider()
        provider._token = self._token(expiry="2000-01-01T00:00:00+00:00")
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value={}),
            patch(
                "ai_monitor.providers.subprocess.run",
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
            with patch("ai_monitor.providers.subprocess.run") as mock_run:
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
                "ai_monitor.providers.subprocess.run",
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
            patch("ai_monitor.providers.subprocess.run", side_effect=FileNotFoundError),
            patch("ai_monitor.providers._http_json") as mock_http,
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
                "ai_monitor.providers.subprocess.run",
                return_value=MagicMock(returncode=0),
            ),
            patch("ai_monitor.providers._http_json") as mock_http,
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
            patch("ai_monitor.providers.subprocess.run", side_effect=FileNotFoundError),
            patch("ai_monitor.providers._http_json", side_effect=ProbeFailure("HTTP 401", "{}")),
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
                "ai_monitor.providers.subprocess.run",
                return_value=MagicMock(returncode=0),
            ),
            patch("ai_monitor.providers._http_json", side_effect=_http),
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
            patch("ai_monitor.providers.subprocess.run") as mock_run,
            patch(
                "ai_monitor.providers._http_json",
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
                "ai_monitor.providers.subprocess.run",
                return_value=MagicMock(returncode=0),
            ) as mock_run,
            patch("ai_monitor.providers._http_json", side_effect=_http),
        ):
            status = provider.fetch()
        self.assertEqual(status.weekly_percent_left, 96)
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
        with patch("ai_monitor.providers.subprocess.run", return_value=fake):
            token = AntigravityProvider._load_keychain_token()
        self.assertEqual(token["access_token"], "ya29.decoded")

    def test_keychain_decode_plain_json(self) -> None:
        # go-keyring stores small UTF-8 secrets without the base64 wrapper.
        inner = {"token": {"access_token": "ya29.plain", "token_type": "Bearer"}}
        fake = MagicMock(returncode=0, stdout=json.dumps(inner), stderr="")
        with patch("ai_monitor.providers.subprocess.run", return_value=fake):
            token = AntigravityProvider._load_keychain_token()
        self.assertEqual(token["access_token"], "ya29.plain")

    def test_missing_keychain_item_raises(self) -> None:
        fake = MagicMock(returncode=44, stdout="", stderr="could not be found")
        with patch("ai_monitor.providers.subprocess.run", return_value=fake):
            with self.assertRaises(FileNotFoundError):
                AntigravityProvider._load_keychain_token()

    def test_init_raises_when_no_access_token(self) -> None:
        with patch.object(AntigravityProvider, "_load_keychain_token", return_value={}):
            with self.assertRaises(FileNotFoundError):
                AntigravityProvider()

    def test_missing_gemini_group_raises(self) -> None:
        provider = self._make_provider()
        only_third_party = {"groups": [self.SUMMARY_RESPONSE["groups"][1]]}
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=self._token()),
            patch("ai_monitor.providers._http_json", return_value=only_third_party),
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
        self._claude_cache = self._root / "claude_cookies.json"
        self._codex_auth = self._root / "auth.json"
        self._patchers = [
            patch.object(VibeProvider, "_CACHE_PATH", self._vibe_cache),
            patch.object(CursorProvider, "_CACHE_PATH", self._cursor_cache),
            patch.object(ClaudeHttpProvider, "_CACHE_PATH", self._claude_cache),
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
            patch("ai_monitor.providers.subprocess.Popen") as popen,
            patch("ai_monitor.providers.subprocess.run") as run,
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
            patch("ai_monitor.providers.os.replace") as os_replace,
            patch("ai_monitor.providers.subprocess.Popen"),
            patch("ai_monitor.providers.subprocess.run"),
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
        self.assertFalse(self._claude_cache.exists())

    def test_headless_off_opens_browser(self) -> None:
        # The _open_url gate — not the readers — is what suppresses the browser
        # open: with the readers stubbed identically, only the flag differs.
        with (
            patch("ai_monitor.providers._read_safari_cookies", return_value={}),
            patch.object(VibeProvider, "_extract_chrome_cookies", return_value=None),
            patch("ai_monitor.providers.subprocess.Popen") as popen,
        ):
            providers.set_headless(False)
            VibeProvider(str(self._root))
            self.assertTrue(popen.called)
            self.assertEqual(popen.call_args.args[0], ["open", "https://console.mistral.ai"])

            popen.reset_mock()
            providers.set_headless(True)
            VibeProvider(str(self._root))
            popen.assert_not_called()

    def test_headless_read_safari_cookies_returns_empty(self) -> None:
        providers.set_headless(True)
        self.assertEqual(providers._read_safari_cookies("claude"), {})
        self.assertIsNone(VibeProvider._extract_chrome_cookies())


class TestCredentialCachePermissions(unittest.TestCase):
    """INV-6: every credential/secret write must land at mode 0600 inside a
    0700 directory, via the shared ``_write_private`` helper. Guards against a
    regression back to a bare ``Path.write_text``, which inherits the process
    umask (0644 = world-readable). These assertions would FAIL against the
    pre-fix code.
    """

    def setUp(self) -> None:
        self._prior_headless = providers._is_headless()
        providers.set_headless(False)

    def tearDown(self) -> None:
        providers.set_headless(self._prior_headless)

    def _assert_private(self, path: Path) -> None:
        self.assertTrue(path.exists(), f"{path} was not written")
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(path.parent).st_mode), 0o700)

    def test_credential_artifacts_are_written_private(self) -> None:
        # Vibe cookie cache — bare instance (no __init__) so construction never
        # touches Safari/Chrome/the browser; only the write path under test runs.
        with tempfile.TemporaryDirectory() as tmp:
            cache_path = Path(tmp) / "vibe" / "vibe_cookies.json"
            with patch.object(VibeProvider, "_CACHE_PATH", cache_path):
                provider = VibeProvider.__new__(VibeProvider)
                provider._ory_name = "ory_session_x"
                provider._ory_value = "v"
                provider._csrf = "c"
                provider._save_to_cache()
            self._assert_private(cache_path)

        # Cursor token cache
        with tempfile.TemporaryDirectory() as tmp:
            cache_path = Path(tmp) / "cursor" / "cursor_token.json"
            with patch.object(CursorProvider, "_CACHE_PATH", cache_path):
                provider = CursorProvider.__new__(CursorProvider)
                provider._access_token = "at"
                provider._refresh_token = "rt"
                provider._save_to_cache()
            self._assert_private(cache_path)

        # Claude cookie cache
        with tempfile.TemporaryDirectory() as tmp:
            cache_path = Path(tmp) / "claude" / "claude_cookies.json"
            with patch.object(ClaudeHttpProvider, "_CACHE_PATH", cache_path):
                provider = ClaudeHttpProvider.__new__(ClaudeHttpProvider)
                provider._session_key = "sk"
                provider._cf_clearance = "cf"
                provider._org_id = "org"
                provider._save_to_cache()
            self._assert_private(cache_path)

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
            dump_path = shared / "ai_monitor_test_capture.txt"
            with patch("ai_monitor.providers._debug_dump_path", return_value=dump_path):
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


class TestChromeCookieDecrypt(unittest.TestCase):
    """Pins the in-process AES-128-CBC Chrome v10 cookie decrypt (F3). The key
    never reaches argv. Known-answer vector generated with the same scheme
    (key + IV=16x0x20 + PKCS7 padding, v10 prefix)."""

    # 16-byte AES-128 key; v10 blob encrypts "session-token-value-42".
    KEY = bytes.fromhex("0123456789abcdef0123456789abcdef")
    V10_BLOB = bytes.fromhex(
        "7631303f968bc907d80a15a7607391fe1d3b246b64f1b60663a8dcd1cba54defc8e7a7"
    )

    def test_decrypt_chrome_cookie_known_vector(self) -> None:
        self.assertEqual(
            VibeProvider._decrypt_chrome_cookie(self.KEY, self.V10_BLOB),
            "session-token-value-42",
        )

    def test_decrypt_chrome_cookie_bad_padding_returns_none(self) -> None:
        # Wrong key -> PKCS#7 validation fails -> None (openssl's None-on-bad-padding).
        self.assertIsNone(VibeProvider._decrypt_chrome_cookie(b"\x00" * 16, self.V10_BLOB))
        # Garbage ciphertext -> None.
        self.assertIsNone(VibeProvider._decrypt_chrome_cookie(self.KEY, b"v10" + b"\x00" * 16))


if __name__ == "__main__":
    unittest.main()
