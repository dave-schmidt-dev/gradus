"""Codex provider tests."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from gradus.__main__ import _is_auth_error
from gradus.providers import (
    CodexHttpProvider,
    ProbeFailure,
    ProviderSnapshot,
    _classify_codex_windows,
    _codex_percent_left,
)
from gradus.snapshot import _is_transient_probe_error


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

    def test_banked_count_is_private_optional_and_distinct_from_paid_balance(self) -> None:
        provider = self._make_provider()
        payload = dict(self.NORMAL_RESPONSE)
        payload.update(user_id="usage-user", rate_limit_reset_credits={"available_count": 3})
        with patch("gradus.providers._base._http_json", return_value=payload):
            status = provider.fetch()
        self.assertEqual(status.banked_candidate.count, 3)
        self.assertEqual(status.banked_candidate.user_id, "usage-user")
        self.assertEqual(status.banked_candidate.account_id, "test_account_id")
        encoded = json.dumps(status.to_dict())
        self.assertNotIn("usage-user", encoded)
        self.assertNotIn("test_account_id", encoded)
        self.assertNotIn("available_count", encoded)
        self.assertNotIn("banked_candidate", encoded)
        self.assertEqual(status.credits, 12.5)

        for count in (None, -1, 1.5, True, "3", 1_000_001):
            payload["rate_limit_reset_credits"] = {"available_count": count}
            with patch("gradus.providers._base._http_json", return_value=payload):
                self.assertIsNone(provider.fetch().banked_candidate)
        payload["rate_limit_reset_credits"] = {"available_count": 3}
        payload.pop("user_id")
        with patch("gradus.providers._base._http_json", return_value=payload):
            self.assertIsNone(provider.fetch().banked_candidate)

    def test_banked_candidate_allows_missing_or_malformed_auth_account_id(self) -> None:
        payload = dict(self.NORMAL_RESPONSE)
        payload.update(user_id="usage-user", rate_limit_reset_credits={"available_count": 3})
        for present, account_id in (
            (False, None),
            (True, None),
            (True, 42),
            (True, ["wrong-type"]),
            (True, "  "),
        ):
            with self.subTest(present=present, account_id=account_id):
                auth_data = {"tokens": {"access_token": "test_access_token"}}
                if present:
                    auth_data["tokens"]["account_id"] = account_id
                with (
                    patch.object(CodexHttpProvider, "_AUTH_PATH") as auth_path,
                    patch("gradus.providers._base._http_json", return_value=payload) as request,
                ):
                    auth_path.exists.return_value = True
                    auth_path.read_text.return_value = json.dumps(auth_data)
                    status = CodexHttpProvider().fetch()
                self.assertEqual(status.banked_candidate.count, 3)
                self.assertEqual(status.banked_candidate.user_id, "usage-user")
                self.assertIsNone(status.banked_candidate.account_id)
                self.assertNotIn("Account-Id", request.call_args.kwargs["headers"])

    def test_banked_candidate_uses_final_response_after_401_retry(self) -> None:
        provider = self._make_provider()
        first = ProbeFailure("HTTP 401", "transient private body")
        final = dict(self.NORMAL_RESPONSE)
        final.update(user_id="final-user", rate_limit_reset_credits={"available_count": 4})
        with (
            patch.object(provider, "_request_usage", side_effect=[first, final]),
            patch.object(provider, "_refresh_tokens", return_value=True),
        ):
            status = provider.fetch()
        self.assertEqual(status.banked_candidate.count, 4)
        self.assertEqual(status.banked_candidate.user_id, "final-user")
        self.assertNotIn("transient private body", json.dumps(status.to_dict()))

    def test_percent_left_fields_are_float(self) -> None:
        provider = self._make_provider()
        with patch("gradus.providers._base._http_json", return_value=self.NORMAL_RESPONSE):
            status = provider.fetch()
        self.assertIsInstance(status.five_hour_percent_left, float)
        self.assertIsInstance(status.weekly_percent_left, float)

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
