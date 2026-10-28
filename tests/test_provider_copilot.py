"""Copilot HTTP provider tests."""

from __future__ import annotations

import subprocess
import unittest
from datetime import datetime, timedelta
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from gradus import snapshot as snapshot_module
from gradus.providers import (
    CopilotHttpProvider,
    ProbeFailure,
    ProviderSnapshot,
    fetch_provider_snapshot,
)
from gradus.snapshot import _is_transient_probe_error


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
        # Retained values publish the substituted message, not the raw probe
        # error: the reading beside it is good, and "provider probe timed out"
        # carries no remedy CR-6 could be protecting. Still `ok: false` so
        # routers keep failing closed, and still transient so the tick does not
        # get reclassified downstream.
        self.assertEqual(copilot["error"], snapshot_module.COPILOT_PROBE_RETRY_MESSAGE)
        self.assertTrue(
            _is_transient_probe_error(SimpleNamespace(ok=False, error=copilot["error"]))
        )
        self.assertEqual(copilot["windows"][0]["percent_left"], 82)

    def test_token_fallback_timeout_stops_retaining_prior_at_stale_boundary(self) -> None:
        """Retention is strict, and the Copilot timeout window is the long one.

        The boundary is `COPILOT_TIMEOUT_RETENTION_SECONDS`, not the 300s
        default: a loaded machine starves the 10s `gh auth token` cap for a
        median of ~794s (measured 2026-08-27), so the default expired
        mid-episode and blanked a monthly counter that had not moved. The old
        300s case is kept below to prove it now *carries* rather than expires.
        """
        provider = self._make_provider()
        timeout = subprocess.TimeoutExpired(["gh", "auth", "token"], timeout=10)
        with (
            patch.object(provider, "_read_hosts_yml", return_value=None),
            patch("gradus.providers.copilot._is_headless", return_value=False),
            patch("subprocess.run", side_effect=timeout),
        ):
            current = fetch_provider_snapshot("Copilot", provider, debug=False)

        observed_at = datetime(2026, 1, 1, 12, 0, 0)
        boundary = snapshot_module.COPILOT_TIMEOUT_RETENTION_SECONDS
        for age in (299, 300, boundary - 1, boundary):
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
                if age < boundary:
                    self.assertEqual(copilot["error"], snapshot_module.COPILOT_PROBE_RETRY_MESSAGE)
                    self.assertEqual(copilot["windows"][0]["percent_left"], 82)
                else:
                    # Past the window there is nothing to show, so the raw
                    # probe error is the honest thing to publish.
                    self.assertEqual(copilot["error"], "provider probe timed out")
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

    def test_reset_instant_survives_a_december_to_january_rollover(self) -> None:
        from datetime import timezone

        provider = self._make_provider()
        response = dict(self.PAID_RESPONSE, quota_reset_date_utc="2027-01-01T00:00:00Z")
        with (
            patch("gradus.providers._base._http_json", return_value=response),
            patch("subprocess.run") as mock_run,
        ):
            mock_run.return_value = MagicMock(returncode=0, stdout="gho_testtoken\n")
            status = provider.fetch()
        assert status.source_reset_instants is not None
        self.assertEqual(
            status.source_reset_instants["premium_reset"],
            datetime(2027, 1, 1, 0, 0, tzinfo=timezone.utc),
        )
        self.assertNotIn("source_reset_instants", status.to_dict())

    def test_monthly_fallback_reset_carries_its_instant(self) -> None:
        provider = self._make_provider()
        response = {k: v for k, v in self.PAID_RESPONSE.items() if "reset" not in k}
        with (
            patch("gradus.providers._base._http_json", return_value=response),
            patch("subprocess.run") as mock_run,
        ):
            mock_run.return_value = MagicMock(returncode=0, stdout="gho_testtoken\n")
            status = provider.fetch()
        assert status.source_reset_instants is not None
        self.assertEqual(status.source_reset_instants["premium_reset"].day, 1)
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
