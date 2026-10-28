"""Antigravity provider tests."""

from __future__ import annotations

import json
import os
import stat
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from gradus import providers
from gradus.providers import (
    AntigravityProvider,
    ProbeFailure,
)


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

    def test_publishes_upstream_reset_instants_outside_status_data(self) -> None:
        from datetime import datetime, timezone

        provider = self._make_provider()
        response = json.loads(json.dumps(self.SUMMARY_RESPONSE))
        response["groups"][0]["buckets"][0]["resetTime"] = "2027-01-15T09:00:00Z"
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=self._token()),
            patch("gradus.providers._base._http_json", return_value=response),
        ):
            status = provider.fetch()
        assert status.source_reset_instants is not None
        self.assertEqual(
            status.source_reset_instants["weekly_reset"],
            datetime(2027, 1, 15, 9, 0, tzinfo=timezone.utc),
        )
        self.assertEqual(
            set(status.source_reset_instants),
            {
                "five_hour_reset",
                "weekly_reset",
                "third_party_five_hour_reset",
                "third_party_weekly_reset",
            },
        )
        self.assertNotIn("source_reset_instants", status.to_dict())

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
        # Auth-refresh fixtures must not depend on agy being installed in the test sandbox.
        # Expired token: we nudge `agy` once; if it still can't refresh, surface the
        # run-agy error and never probe the summary endpoint with a dead token.
        provider = self._make_provider()
        expired = self._token(expiry="2000-01-01T00:00:00+00:00")
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=expired),
            patch("gradus.providers.antigravity.shutil.which", return_value="agy"),
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
            patch("gradus.providers.antigravity.shutil.which", return_value="agy"),
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
            patch("gradus.providers.antigravity.shutil.which", return_value="agy"),
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
            patch("gradus.providers.antigravity.shutil.which", return_value="agy"),
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

    def test_missing_gemini_group_keeps_third_party_partial_data(self) -> None:
        provider = self._make_provider()
        only_third_party = {"groups": [self.SUMMARY_RESPONSE["groups"][1]]}
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=self._token()),
            patch("gradus.providers._base._http_json", return_value=only_third_party),
        ):
            status = provider.fetch()
        self.assertIsNone(status.five_hour_percent_left)
        self.assertIsNone(status.weekly_percent_left)
        self.assertIsNone(status.five_hour_reset)
        self.assertIsNone(status.weekly_reset)
        self.assertEqual(status.third_party_five_hour_percent_left, 42.1)
        self.assertEqual(status.third_party_weekly_percent_left, 73.4)
