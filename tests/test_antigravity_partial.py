"""Partial grouped-quota regressions for the Antigravity provider.

``retrieveUserQuotaSummary`` has been observed returning a valid response
whose only group is the third-party ``3p-*`` (Claude+GPT) pool. These tests
pin the partial-data contract: a recognized group is retained with its real
values even when its sibling group is absent or malformed, an absent Gemini
pool stays unknown (``None``) instead of an invented 0/100, and a response
with no recognized group still fails closed.
"""

from __future__ import annotations

import unittest
from datetime import datetime, timezone
from io import StringIO
from unittest.mock import patch

from rich.console import Console

from gradus.__main__ import _canonical_snapshots
from gradus.parsing import AntigravityStatus
from gradus.providers import (
    AntigravityProvider,
    ProbeFailure,
    ProviderSnapshot,
    fetch_provider_snapshot,
)
from gradus.snapshot import build_snapshot_v2_payload
from gradus.ui import THEME, build_dashboard

NOW = datetime(2026, 10, 15, 12, 0, 0, tzinfo=timezone.utc)

LIVE_THIRD_PARTY_ONLY = {
    "groups": [
        {
            "displayName": "Claude and GPT models",
            "description": "Models within this group: Claude Sonnet, GPT-5",
            "buckets": [
                {
                    "bucketId": "3p-weekly",
                    "window": "weekly",
                    "remainingFraction": 0,
                    "resetTime": "2026-10-17T09:00:07Z",
                },
                {
                    "bucketId": "3p-5h",
                    "window": "5h",
                    "remainingFraction": 1,
                    "resetTime": "2026-10-16T03:37:51Z",
                },
            ],
        }
    ]
}

GEMINI_ONLY = {
    "groups": [
        {
            "displayName": "Gemini Models",
            "description": "Models within this group: Gemini Flash, Gemini Pro",
            "buckets": [
                {
                    "bucketId": "gemini-weekly",
                    "window": "weekly",
                    "remainingFraction": 0.5,
                    "resetTime": "2026-10-17T20:52:22Z",
                },
                {
                    "bucketId": "gemini-5h",
                    "window": "5h",
                    "remainingFraction": 0.25,
                    "resetTime": "2026-10-16T05:31:46Z",
                },
            ],
        }
    ]
}

BOTH_GROUPS = {"groups": [GEMINI_ONLY["groups"][0], LIVE_THIRD_PARTY_ONLY["groups"][0]]}


class AntigravityPartialQuotaTests(unittest.TestCase):
    def _token(self) -> dict[str, str]:
        return {
            "access_token": "ya29.agy-token",
            "refresh_token": "1//agy-refresh",
            "token_type": "Bearer",
            "expiry": "2999-01-01T00:00:00+00:00",
        }

    def _fetch(self, response: dict[str, object]) -> AntigravityStatus:
        provider = AntigravityProvider()
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=self._token()),
            patch.object(AntigravityProvider, "_read_account_email", return_value=None),
            patch("gradus.providers._base._http_json", return_value=response),
        ):
            return provider.fetch()

    def _snapshot(self, response: dict[str, object]) -> ProviderSnapshot:
        provider = AntigravityProvider()
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=self._token()),
            patch.object(AntigravityProvider, "_read_account_email", return_value=None),
            patch("gradus.providers._base._http_json", return_value=response),
        ):
            return fetch_provider_snapshot("Antigravity", provider, debug=False)

    def test_live_third_party_only_response_parses_without_gemini(self) -> None:
        status = self._fetch(LIVE_THIRD_PARTY_ONLY)
        self.assertIsNone(status.five_hour_percent_left)
        self.assertIsNone(status.weekly_percent_left)
        self.assertIsNone(status.five_hour_reset)
        self.assertIsNone(status.weekly_reset)
        self.assertEqual(status.third_party_five_hour_percent_left, 100.0)
        self.assertEqual(status.third_party_weekly_percent_left, 0.0)
        self.assertIsNotNone(status.third_party_five_hour_reset)
        self.assertIsNotNone(status.third_party_weekly_reset)

    def test_gemini_only_response_leaves_third_party_unknown(self) -> None:
        status = self._fetch(GEMINI_ONLY)
        self.assertEqual(status.five_hour_percent_left, 25.0)
        self.assertEqual(status.weekly_percent_left, 50.0)
        self.assertIsNotNone(status.five_hour_reset)
        self.assertIsNotNone(status.weekly_reset)
        self.assertIsNone(status.third_party_five_hour_percent_left)
        self.assertIsNone(status.third_party_weekly_percent_left)
        self.assertIsNone(status.third_party_five_hour_reset)
        self.assertIsNone(status.third_party_weekly_reset)

    def test_both_groups_parse_independently(self) -> None:
        status = self._fetch(BOTH_GROUPS)
        self.assertEqual(status.five_hour_percent_left, 25.0)
        self.assertEqual(status.weekly_percent_left, 50.0)
        self.assertEqual(status.third_party_five_hour_percent_left, 100.0)
        self.assertEqual(status.third_party_weekly_percent_left, 0.0)

    def test_fetch_uses_production_endpoint_over_partial_daily_response(self) -> None:
        """The production host returns both pools; the daily host returns 3p only.

        Dispatching the mocked response by the requested URL pins the endpoint:
        on the old ``daily-`` host this test receives the third-party-only
        fixture, leaving Gemini unknown and failing the percent assertions.
        """

        def by_url(url: str, **_: object) -> dict[str, object]:
            if url == "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary":
                return BOTH_GROUPS
            return LIVE_THIRD_PARTY_ONLY

        provider = AntigravityProvider()
        with (
            patch.object(AntigravityProvider, "_load_keychain_token", return_value=self._token()),
            patch.object(AntigravityProvider, "_read_account_email", return_value=None),
            patch("gradus.providers._base._http_json", side_effect=by_url),
        ):
            status = provider.fetch()
        self.assertEqual(status.five_hour_percent_left, 25.0)
        self.assertEqual(status.weekly_percent_left, 50.0)
        self.assertEqual(status.third_party_five_hour_percent_left, 100.0)
        self.assertEqual(status.third_party_weekly_percent_left, 0.0)

    def test_zero_and_full_fractions_survive_as_exact_bounds(self) -> None:
        response = {
            "groups": [
                {
                    "buckets": [
                        {"bucketId": "3p-5h", "window": "5h", "remainingFraction": 0},
                        {"bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 1},
                    ]
                }
            ]
        }
        status = self._fetch(response)
        self.assertEqual(status.third_party_five_hour_percent_left, 0.0)
        self.assertEqual(status.third_party_weekly_percent_left, 100.0)

    def test_unknown_only_response_fails_closed(self) -> None:
        response = {
            "groups": [
                {
                    "displayName": "Unrecognized models",
                    "buckets": [
                        {"bucketId": "other-weekly", "window": "weekly", "remainingFraction": 1},
                        {"bucketId": "other-5h", "window": "5h", "remainingFraction": 0},
                    ],
                }
            ]
        }
        with self.assertRaises(ProbeFailure) as ctx:
            self._fetch(response)
        self.assertIn("no recognized group", str(ctx.exception))

    def test_zero_groups_fail_closed(self) -> None:
        for response in ({}, {"groups": []}, {"groups": None}):
            with self.subTest(response=response):
                with self.assertRaises(ProbeFailure):
                    self._fetch(response)

    def test_recognized_pool_without_reading_stays_unknown(self) -> None:
        status = self._fetch({"groups": [{"buckets": [{"bucketId": "3p-5h", "window": "5h"}]}]})
        self.assertIsNone(status.five_hour_percent_left)
        self.assertIsNone(status.weekly_percent_left)
        self.assertIsNone(status.third_party_five_hour_percent_left)
        self.assertIsNone(status.third_party_weekly_percent_left)

    def test_malformed_sibling_group_does_not_discard_valid_pool(self) -> None:
        malformed_siblings = (
            {"displayName": "Gemini Models", "buckets": "not a list"},
            {"displayName": "Gemini Models"},
            "not a group",
            {"buckets": [{"bucketId": "gemini-5h", "window": "5h"}]},
        )
        for sibling in malformed_siblings:
            with self.subTest(sibling=sibling):
                response = {"groups": [sibling, LIVE_THIRD_PARTY_ONLY["groups"][0]]}
                status = self._fetch(response)
                self.assertIsNone(status.five_hour_percent_left)
                self.assertIsNone(status.weekly_percent_left)
                self.assertEqual(status.third_party_five_hour_percent_left, 100.0)
                self.assertEqual(status.third_party_weekly_percent_left, 0.0)

    def test_v2_projection_retains_third_party_windows_and_gemini_unknown(self) -> None:
        snapshot = self._snapshot(LIVE_THIRD_PARTY_ONLY)
        self.assertTrue(snapshot.ok)
        payload = build_snapshot_v2_payload([snapshot], NOW)
        entries = {entry["name"]: entry for entry in payload["providers"]}

        gemini_entry = entries["Antigravity"]
        self.assertEqual(gemini_entry["windows"], [])
        self.assertIsNone(gemini_entry["data"]["five_hour_percent_left"])
        self.assertIsNone(gemini_entry["data"]["weekly_percent_left"])

        third_party_entry = entries["Antigravity (Claude)"]
        self.assertEqual(
            [window["id"] for window in third_party_entry["windows"]],
            ["five_hour", "weekly"],
        )
        percents = {window["id"]: window["percent_left"] for window in third_party_entry["windows"]}
        self.assertEqual(percents["five_hour"], 100.0)
        self.assertEqual(percents["weekly"], 0.0)
        self.assertEqual(third_party_entry["data"]["five_hour_percent_left"], 100.0)
        self.assertEqual(third_party_entry["data"]["weekly_percent_left"], 0.0)

    def test_reader_hydration_and_dashboard_show_third_party_values(self) -> None:
        payload = build_snapshot_v2_payload([self._snapshot(LIVE_THIRD_PARTY_ONLY)], NOW)
        hydrated = _canonical_snapshots(payload)
        assert hydrated is not None
        snapshots, updated_at = hydrated
        antigravity = next(snapshot for snapshot in snapshots if snapshot.name == "Antigravity")
        self.assertEqual(antigravity.data["third_party_five_hour_percent_left"], 100.0)
        self.assertEqual(antigravity.data["third_party_weekly_percent_left"], 0.0)
        self.assertIsNone(antigravity.data["five_hour_percent_left"])
        self.assertIsNone(antigravity.data["weekly_percent_left"])
        self.assertNotIn("Antigravity (Claude)", {snapshot.name for snapshot in snapshots})

        console = Console(file=StringIO(), width=100, no_color=True, theme=THEME)
        console.print(build_dashboard([antigravity], updated_at, 30))
        output = console.file.getvalue()
        self.assertRegex(output, r"\bcg5\s+100%")
        self.assertRegex(output, r"\bcg1w\s+0(?:\.0)?%")
        self.assertRegex(output, r"\b5h\s+n/a")
        self.assertRegex(output, r"\b1w\s+n/a")


if __name__ == "__main__":
    unittest.main()
