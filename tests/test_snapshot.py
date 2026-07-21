"""Unit tests for gradus.snapshot (router-facing capacity snapshot)."""

from __future__ import annotations

import copy
import json
import math
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

from gradus import snapshot as snap
from gradus import ui
from gradus.providers import ProbeFailure, ProviderSnapshot, fetch_provider_snapshot

NOW = datetime(2026, 3, 14, 8, 22, 30)


def _ps(
    name: str, ok: bool, data: dict | None = None, error: str | None = None
) -> ProviderSnapshot:
    """Build a ProviderSnapshot with the common test defaults."""
    return ProviderSnapshot(name=name, ok=ok, source="api", data=data, error=error)


class TestAllowlist(unittest.TestCase):
    def test_payload_data_is_safe_allowlist(self) -> None:
        """INV-1: only allowlisted usage/reset keys survive projection."""
        claude = _ps(
            "Claude",
            True,
            data={
                "session_percent_left": 80,
                "weekly_percent_left": 60,
                "primary_reset": "in 3h",
                "secondary_reset": "in 2d",
                "account_email": "user@example.com",
                "account_organization": "Zero Delta LLC",
                "login_method": "oauth",
                "raw_text": "SECRET DUMP",
            },
        )
        payload = snap.build_snapshot_payload([claude], NOW)
        claude_entry = next(p for p in payload["providers"] if p["name"] == "Claude")
        data = claude_entry["data"]
        for forbidden in (
            "account_email",
            "account_organization",
            "login_method",
            "account_tier",
            "raw_text",
        ):
            self.assertNotIn(forbidden, data)
        self.assertTrue(set(data).issubset(snap.SAFE_DATA_KEYS))
        self.assertEqual(data["session_percent_left"], 80)
        self.assertEqual(data["primary_reset"], "in 3h")

        antigravity = _ps(
            "Antigravity",
            True,
            data={
                "five_hour_percent_left": 90,
                "weekly_percent_left": 70,
                "account_tier": "pro",
                "account_email": "user@example.com",
            },
        )
        payload = snap.build_snapshot_payload([antigravity], NOW)
        agy_entry = next(p for p in payload["providers"] if p["name"] == "Antigravity")
        self.assertNotIn("account_tier", agy_entry["data"])
        self.assertNotIn("account_email", agy_entry["data"])
        self.assertEqual(agy_entry["data"]["five_hour_percent_left"], 90)

    def test_project_data_drops_all_identity_fields(self) -> None:
        """project_data drops every non-usage/identity field."""
        cursor = _ps(
            "Cursor",
            True,
            data={
                "auto_percent_used": 20.0,
                "api_percent_used": 30.0,
                "plan_name": "Pro",
                "session_token": "tok_abc",
                "cookie": "sid=xyz",
            },
        )
        projected = snap.project_data(cursor)
        self.assertEqual(projected, {"auto_percent_used": 20.0, "api_percent_used": 30.0})

    def test_cursor_dollar_meter_field_is_not_allowlisted(self) -> None:
        """The router projection excludes the dollar-spend meter; per-pool fields are kept.

        ``credit_percent_left`` is a $ spend meter, not a usage pool, so it is
        no longer surfaced in the projected/persisted ``data`` block (it
        remains internal provider metadata). ``auto_percent_used`` and
        ``api_percent_used`` are Cursor's two real per-pool percent-used
        fields and ARE allowlisted.
        """
        cursor = _ps(
            "Cursor",
            True,
            data={
                "credit_percent_left": 55.0,
                "auto_percent_used": 20.0,
                "api_percent_used": 30.0,
                "remaining_cents": 500,
                "limit_cents": 1_000,
            },
        )
        self.assertEqual(
            snap.project_data(cursor), {"auto_percent_used": 20.0, "api_percent_used": 30.0}
        )

    def test_payload_error_carries_no_raw_payload(self) -> None:
        sentinel = "SENTINEL-a1b2c3-raw-body"

        class _Boom:
            def fetch(self):
                raise ProbeFailure("Boom", raw_text=f"SECRET-BODY-{sentinel}")

        # Patch the debug-dump writer so the test never writes the real /tmp dump.
        with patch("gradus.providers._write_debug_dump"):
            s = fetch_provider_snapshot("Claude", _Boom(), debug=True)

        # error is plain; the raw tail lives only in debug_detail (never persisted).
        self.assertEqual(s.error, "Boom")
        self.assertIsNotNone(s.debug_detail)
        self.assertIn(sentinel, s.debug_detail)

        payload = snap.build_snapshot_payload([s], NOW)
        entry = next(p for p in payload["providers"] if p["name"] == "Claude")
        self.assertEqual(entry["error"], "Boom")
        self.assertNotIn("raw dump:", entry["error"])
        # Strong, generic check: the raw body must not appear ANYWHERE in the file.
        self.assertNotIn(sentinel, json.dumps(payload))


class TestVibeNormalization(unittest.TestCase):
    def test_vibe_percent_left_is_remaining(self) -> None:
        """INV-3: Vibe usage_percent is inverted to percent-left exactly once."""
        vibe = _ps(
            "Vibe",
            True,
            data={
                "usage_percent": 30.0,
                "start_date": "2026-03-01T00:00:00+00:00",
                "end_date": "2026-04-01T00:00:00+00:00",
            },
        )
        windows = snap.build_windows(vibe, NOW)
        self.assertEqual(len(windows), 1)
        self.assertEqual(windows[0]["percent_left"], 70.0)


class TestPaceDelta(unittest.TestCase):
    def test_pace_delta_unit_and_sign(self) -> None:
        """INV-4: signed fraction, finite, unclamped, None on missing input."""
        # Plenty left early in the window -> positive (ahead/healthy).
        ahead = snap.pace_delta(90.0, NOW + timedelta(hours=1), 5 * 3600.0, NOW)
        self.assertIsNotNone(ahead)
        self.assertGreater(ahead, 0.0)
        self.assertTrue(math.isfinite(ahead))

        # Nearly empty with lots of time left -> negative (behind).
        behind = snap.pace_delta(5.0, NOW + timedelta(hours=4), 5 * 3600.0, NOW)
        self.assertIsNotNone(behind)
        self.assertLess(behind, 0.0)
        self.assertTrue(math.isfinite(behind))

        # A reset rolled far into the future (e.g. past instant rolled +1 day)
        # against a 5h window pushes the delta below -1 and it is NOT clamped.
        rolled = snap.pace_delta(0.0, NOW + timedelta(days=1), 5 * 3600.0, NOW)
        self.assertIsNotNone(rolled)
        self.assertLess(rolled, -1.0)

        # Missing inputs -> None.
        self.assertIsNone(snap.pace_delta(None, NOW, 5 * 3600.0, NOW))
        self.assertIsNone(snap.pace_delta(50.0, None, 5 * 3600.0, NOW))
        self.assertIsNone(snap.pace_delta(50.0, NOW, 0.0, NOW))
        self.assertIsNone(snap.pace_delta(50.0, NOW, None, NOW))
        self.assertIsNone(snap.pace_delta(50.0, NOW, -10.0, NOW))


class TestWarningPredicate(unittest.TestCase):
    """Warnings are derived only from normalized remaining and pace fields."""

    def test_pace_warning_boundary_and_invalid_values(self) -> None:
        self.assertFalse(snap.window_warns({"percent_left": 1.0, "pace_delta": -0.10}))
        self.assertTrue(snap.window_warns({"percent_left": 1.0, "pace_delta": -0.1001}))
        self.assertFalse(snap.window_warns({"percent_left": 1.0, "pace_delta": math.nan}))
        self.assertFalse(snap.window_warns({"percent_left": 1.0, "pace_delta": -math.inf}))
        self.assertFalse(snap.window_warns({"percent_left": True, "pace_delta": -0.2}))
        self.assertFalse(snap.window_warns({"percent_left": "0", "pace_delta": -0.2}))
        for percent_left in (math.nan, math.inf, -math.inf, -1.0, 100.1):
            with self.subTest(percent_left=percent_left):
                self.assertFalse(
                    snap.window_warns({"percent_left": percent_left, "pace_delta": -0.2})
                )

    def test_zero_warns_with_unknown_pace_and_one_percent_near_reset_does_not(self) -> None:
        self.assertTrue(snap.window_warns({"percent_left": 0.0, "pace_delta": None}))
        self.assertFalse(snap.window_warns({"percent_left": 1.0, "pace_delta": None}))

    def test_cursor_warning_windows_are_v2_capable_but_not_v1_persisted(self) -> None:
        cursor = _ps(
            "Cursor",
            True,
            data={"auto_percent_used": 100, "credit_percent_left": 0, "api_percent_used": 100},
        )
        self.assertEqual(snap.warning_window_ids(cursor, NOW), ("ac", "ap"))
        self.assertEqual(
            [window["id"] for window in snap.build_windows(cursor, NOW)], ["billing_cycle"]
        )

    def test_antigravity_cg_warning_windows_are_interactive_only(self) -> None:
        """C+G quota alerts never enter v1/v2 router projections (INV-1, INV-5)."""
        antigravity = _ps(
            "Antigravity",
            True,
            data={
                "five_hour_percent_left": 80,
                "weekly_percent_left": 70,
                "third_party_five_hour_percent_left": 0,
                "third_party_weekly_percent_left": 5,
                "third_party_five_hour_reset": "in 3h",
                "third_party_weekly_reset": "in 6d",
            },
        )

        warning_windows = {
            window["id"]: window for window in snap.normalized_warning_windows(antigravity, NOW)
        }
        self.assertEqual(set(warning_windows), {"five_hour", "weekly", "cg5", "cg1w"})
        self.assertEqual(warning_windows["cg5"]["percent_left"], 0.0)
        self.assertEqual(warning_windows["cg5"]["window_hours"], 5.0)
        self.assertEqual(warning_windows["cg1w"]["percent_left"], 5.0)
        self.assertEqual(warning_windows["cg1w"]["window_hours"], 168.0)
        self.assertLess(warning_windows["cg1w"]["pace_delta"], -0.10)
        self.assertEqual(snap.warning_window_ids(antigravity, NOW), ("cg5", "cg1w"))
        self.assertEqual(
            snap.warning_membership([antigravity], NOW), {"Antigravity": ("cg5", "cg1w")}
        )

        expected_router_ids = ["five_hour", "weekly"]
        self.assertEqual(
            [window["id"] for window in snap.build_windows(antigravity, NOW)], expected_router_ids
        )
        self.assertEqual(
            [window["id"] for window in snap.build_v2_windows(antigravity, NOW)],
            expected_router_ids,
        )
        self.assertFalse(
            {
                "third_party_five_hour_percent_left",
                "third_party_weekly_percent_left",
                "third_party_five_hour_reset",
                "third_party_weekly_reset",
            }
            & set(snap.SAFE_DATA_KEYS)
        )
        self.assertEqual(
            snap.project_data(antigravity),
            {"five_hour_percent_left": 80, "weekly_percent_left": 70},
        )
        for payload in (
            snap.build_snapshot_payload([antigravity], NOW),
            snap.build_snapshot_v2_payload([antigravity], NOW),
        ):
            entry = next(
                provider for provider in payload["providers"] if provider["name"] == "Antigravity"
            )
            self.assertEqual([window["id"] for window in entry["windows"]], expected_router_ids)
            self.assertEqual(
                entry["data"], {"five_hour_percent_left": 80, "weekly_percent_left": 70}
            )


class TestReconcile(unittest.TestCase):
    def test_reconcile_reset_vs_now(self) -> None:
        """reconcile aligns the second arg's tz-awareness to the first."""
        aware = datetime(2026, 3, 14, 8, 0, tzinfo=timezone.utc)
        naive = datetime(2026, 3, 14, 8, 0)

        # a naive, b aware -> b becomes naive.
        a, b = snap.reconcile(naive, aware)
        self.assertIsNone(a.tzinfo)
        self.assertIsNone(b.tzinfo)

        # a aware, b naive -> b becomes aware with a's tzinfo.
        a, b = snap.reconcile(aware, naive)
        self.assertIsNotNone(a.tzinfo)
        self.assertEqual(b.tzinfo, aware.tzinfo)

        # both aware -> unchanged.
        a, b = snap.reconcile(aware, aware)
        self.assertEqual((a.tzinfo, b.tzinfo), (aware.tzinfo, aware.tzinfo))

    def test_reconcile_billing_start_vs_end(self) -> None:
        """reconcile also aligns a billing start<->end pair (single site)."""
        start_naive = datetime(2026, 3, 1, 0, 0)
        end_aware = datetime(2026, 4, 1, 0, 0, tzinfo=timezone.utc)
        start, end = snap.reconcile(start_naive, end_aware)
        self.assertIsNone(start.tzinfo)
        self.assertIsNone(end.tzinfo)
        # Now subtraction is safe.
        self.assertGreater((end - start).total_seconds(), 0.0)


class TestBuildWindows(unittest.TestCase):
    def test_cursor_full_precision_mixed_tz(self) -> None:
        """Cursor v1 has one billing cycle from remaining credit percentage."""
        cursor = _ps(
            "Cursor",
            True,
            data={
                "credit_percent_left": 60.0,
                "auto_percent_used": 10.0,
                "api_percent_used": 25.0,
                "billing_cycle_start": "2026-03-01T00:00:00",
                "billing_cycle_end_iso": "2026-04-01T00:00:00+00:00",
            },
        )
        windows = snap.build_windows(cursor, NOW)
        self.assertEqual(len(windows), 1)
        (window,) = windows
        self.assertEqual(window["id"], "billing_cycle")
        self.assertEqual(window["percent_left"], 60.0)
        self.assertIsInstance(window["window_hours"], float)
        self.assertGreater(window["window_hours"], 0.0)
        self.assertIsInstance(window["pace_delta"], float)

    def test_cursor_omits_missing_or_invalid_credit_percentage(self) -> None:
        """Cursor v1 never emits a billing window with null percent_left."""
        for value in (None, "60", True, False, math.nan, math.inf, -1.0, 100.1, object()):
            with self.subTest(value=repr(value)):
                cursor = _ps("Cursor", True, data={"credit_percent_left": value})
                self.assertEqual(snap.build_windows(cursor, NOW), [])

    def test_session_windows_omit_boolean_percentages(self) -> None:
        codex = _ps("Codex", True, data={"five_hour_percent_left": True})
        self.assertEqual(snap.build_windows(codex, NOW), [])

    def test_vibe_tz_aware_window(self) -> None:
        """Vibe: tz-aware UTC start/end yield numeric window_hours + pace."""
        vibe = _ps(
            "Vibe",
            True,
            data={
                "usage_percent": 40.0,
                "start_date": "2026-03-01T00:00:00+00:00",
                "end_date": "2026-04-01T00:00:00+00:00",
            },
        )
        windows = snap.build_windows(vibe, NOW)
        self.assertEqual(len(windows), 1)
        win = windows[0]
        self.assertEqual(win["percent_left"], 60.0)
        self.assertIsInstance(win["window_hours"], float)
        self.assertIsInstance(win["pace_delta"], float)

    def test_malformed_boundary_keeps_capacity_without_pace_metadata(self) -> None:
        """Malformed billing dates omit only pacing metadata, not capacity."""
        cursor = _ps(
            "Cursor",
            True,
            data={
                "credit_percent_left": 50.0,
                "billing_cycle_start": "2026-03-01T00:00:00",
                "billing_cycle_end_iso": "not-a-date",
            },
        )
        self.assertEqual(
            snap.build_windows(cursor, NOW),
            [
                {
                    "id": "billing_cycle",
                    "percent_left": 50.0,
                    "reset_iso": None,
                    "window_hours": None,
                    "pace_delta": None,
                }
            ],
        )

    def test_malformed_cursor_dates_do_not_suppress_depleted_sibling_warning_pools(self) -> None:
        cursor = _ps(
            "Cursor",
            True,
            data={
                "auto_percent_used": 100,
                "api_percent_used": 100,
                "billing_cycle_start": "not-a-date",
                "billing_cycle_end_iso": "also-not-a-date",
            },
        )
        windows = snap.normalized_warning_windows(cursor, NOW)
        self.assertEqual([window["id"] for window in windows], ["ac", "ap"])
        self.assertTrue(all(window["pace_delta"] is None for window in windows))
        self.assertEqual(snap.warning_window_ids(cursor, NOW), ("ac", "ap"))

    def test_build_windows_reset_iso_parse_and_null(self) -> None:
        """Session reset parses to ISO; unparseable human reset -> None."""
        parseable = _ps(
            "Codex",
            True,
            data={
                "five_hour_percent_left": 75,
                "weekly_percent_left": 50,
                "five_hour_reset": "in 3h",
                "weekly_reset": "definitely not a timestamp",
            },
        )
        windows = {w["id"]: w for w in snap.build_windows(parseable, NOW)}
        self.assertIsNotNone(windows["five_hour"]["reset_iso"])
        # Parses back to an offset-aware datetime.
        parsed = datetime.fromisoformat(windows["five_hour"]["reset_iso"])
        self.assertIsNotNone(parsed.tzinfo)
        self.assertIsNone(windows["weekly"]["reset_iso"])

    def test_stale_explicit_reset_does_not_roll_into_the_next_year(self) -> None:
        reset = "Resets Mar 14 at 8:00 AM"
        target = snap.parse_reset_target(reset, NOW)
        self.assertEqual(target, datetime(2026, 3, 14, 8, 0))
        delta = snap.pace_delta(5.0, target, 5 * 3600.0, NOW)
        self.assertIsNotNone(delta)
        self.assertFalse(snap.window_warns({"percent_left": 5.0, "pace_delta": delta}))

    def test_build_windows_empty_when_not_ok(self) -> None:
        """A not-ok or unknown snapshot yields no windows."""
        self.assertEqual(snap.build_windows(_ps("Codex", False), NOW), [])
        self.assertEqual(snap.build_windows(_ps("Unknown", True, data={"x": 1}), NOW), [])

    def test_build_windows_omits_absent_session_window(self) -> None:
        """A session window with no percent (Codex 5h after 2026-07) is omitted.

        Emitting a null-percent window would violate the router contract that
        every window's percent_left is numeric; the weekly window still emits.
        """
        codex = _ps(
            "Codex",
            True,
            data={
                "five_hour_percent_left": None,
                "weekly_percent_left": 95,
                "five_hour_reset": None,
                "weekly_reset": "in 5d",
            },
        )
        windows = snap.build_windows(codex, NOW)
        ids = [w["id"] for w in windows]
        self.assertEqual(ids, ["weekly"])
        self.assertEqual(windows[0]["percent_left"], 95.0)


class TestPayloadSchema(unittest.TestCase):
    def test_payload_matches_contract_schema(self) -> None:
        """INV-5: schema_version, aware updated_at, 5 canonical providers, shape."""
        snapshots = [
            _ps(
                "Codex",
                True,
                data={
                    "five_hour_percent_left": 80,
                    "weekly_percent_left": 60,
                    "five_hour_reset": "in 2h",
                    "weekly_reset": "in 5d",
                },
            ),
            _ps(
                "Cursor",
                True,
                data={
                    "credit_percent_left": 45.0,
                    "auto_percent_used": 20.0,
                    "api_percent_used": 30.0,
                    "billing_cycle_start": "2026-03-01T00:00:00",
                    "billing_cycle_end_iso": "2026-04-01T00:00:00+00:00",
                },
            ),
        ]
        payload = snap.build_snapshot_payload(snapshots, NOW)
        self.assertEqual(payload["schema_version"], 1)

        parsed_updated = datetime.fromisoformat(payload["updated_at"])
        self.assertIsNotNone(parsed_updated.tzinfo)

        names = [p["name"] for p in payload["providers"]]
        self.assertEqual(tuple(names), snap.CANONICAL_PROVIDERS)
        self.assertEqual(len(payload["providers"]), 5)

        cursor = next(entry for entry in payload["providers"] if entry["name"] == "Cursor")
        self.assertIn("auto_percent_used", cursor["data"])
        self.assertIn("api_percent_used", cursor["data"])
        self.assertNotIn("credit_percent_left", cursor["data"])
        self.assertEqual(
            {window["id"]: window["percent_left"] for window in cursor["windows"]},
            {"billing_cycle": 45.0},
        )

        for entry in payload["providers"]:
            for key in ("name", "ok", "error", "windows", "data"):
                self.assertIn(key, entry)
            if entry["ok"]:
                for win in entry["windows"]:
                    self.assertIsInstance(win["percent_left"], (int, float))
                    if win["reset_iso"] is not None:
                        # Must be parseable.
                        datetime.fromisoformat(win["reset_iso"])
                    self.assertTrue(
                        win["window_hours"] is None or isinstance(win["window_hours"], (int, float))
                    )
                    self.assertTrue(
                        win["pace_delta"] is None or isinstance(win["pace_delta"], float)
                    )

    def test_absent_provider_is_disabled(self) -> None:
        """A provider missing from snapshots is emitted as disabled."""
        payload = snap.build_snapshot_payload([_ps("Codex", True, data={})], NOW)
        vibe = next(p for p in payload["providers"] if p["name"] == "Vibe")
        self.assertFalse(vibe["ok"])
        self.assertEqual(vibe["error"], "provider not enabled")
        self.assertEqual(vibe["windows"], [])
        self.assertEqual(vibe["data"], {})

    def test_updated_at_monotonicity(self) -> None:
        """Strictly increasing updated_at -> strictly increasing aware ISO."""
        p1 = snap.build_snapshot_payload([], NOW)
        p2 = snap.build_snapshot_payload([], NOW + timedelta(seconds=30))
        t1 = datetime.fromisoformat(p1["updated_at"])
        t2 = datetime.fromisoformat(p2["updated_at"])
        self.assertIsNotNone(t1.tzinfo)
        self.assertIsNotNone(t2.tzinfo)
        self.assertLess(t1, t2)

    def test_v2_cursor_windows_are_independent_and_numeric(self) -> None:
        """V2 publishes only available Cursor pools; v1 remains unchanged."""
        cursor = _ps(
            "Cursor",
            True,
            data={
                "auto_percent_used": 20,
                "api_percent_used": None,
                "billing_cycle_start": "2026-03-01T00:00:00",
                "billing_cycle_end_iso": "2026-04-01T00:00:00+00:00",
            },
        )
        v1 = snap.build_snapshot_payload([cursor], NOW)
        v2 = snap.build_snapshot_v2_payload([cursor], NOW)
        self.assertEqual(v1["schema_version"], 1)
        self.assertEqual(v2["schema_version"], 2)
        v1_cursor = next(entry for entry in v1["providers"] if entry["name"] == "Cursor")
        v2_cursor = next(entry for entry in v2["providers"] if entry["name"] == "Cursor")
        self.assertEqual(v1_cursor["windows"], [])
        self.assertEqual(
            [(window["id"], window["percent_left"]) for window in v2_cursor["windows"]],
            [("ac", 80.0)],
        )

    def test_v2_non_cursor_windows_match_v1(self) -> None:
        """The parallel schema changes only Cursor's window projection."""
        codex = _ps("Codex", True, data={"five_hour_percent_left": 75})
        v1 = snap.build_snapshot_payload([codex], NOW)
        v2 = snap.build_snapshot_v2_payload([codex], NOW)
        self.assertEqual(v1["providers"][0], v2["providers"][0])


class TestTransientMerge(unittest.TestCase):
    def _healthy_prior(self, at: datetime) -> dict:
        """A prior payload where Codex is healthy at instant ``at``."""
        codex = _ps(
            "Codex",
            True,
            data={
                "five_hour_percent_left": 88,
                "weekly_percent_left": 66,
                "five_hour_reset": "in 4h",
                "weekly_reset": "in 6d",
            },
        )
        return snap.build_snapshot_payload([codex], at)

    def test_transient_retains_recent_prior(self) -> None:
        """A transient failure within 300s reuses the healthy prior entry."""
        prior = self._healthy_prior(NOW - timedelta(seconds=100))
        failing = _ps("Codex", False, error="rate limited")
        payload = snap.build_snapshot_payload([failing], NOW, prior=prior)
        codex = next(p for p in payload["providers"] if p["name"] == "Codex")
        prior_codex = next(p for p in prior["providers"] if p["name"] == "Codex")
        self.assertTrue(codex["ok"])
        self.assertTrue(codex["windows"])
        self.assertEqual(codex, prior_codex)
        self.assertIsNot(codex, prior_codex)
        codex["data"]["five_hour_percent_left"] = 1
        self.assertEqual(prior_codex["data"]["five_hour_percent_left"], 88)

    def test_transient_rejects_prior_with_extra_or_error_metadata(self) -> None:
        """A retained prior cannot carry unrecognized metadata or an error."""
        invalid_fields = (
            ("debug_detail", "diagnostic detail"),
            ("access_token", "redacted"),
            ("error", "prior failure"),
        )
        failing = _ps("Codex", False, error="rate limited")
        for field, value in invalid_fields:
            with self.subTest(field=field):
                prior = self._healthy_prior(NOW - timedelta(seconds=100))
                codex = next(entry for entry in prior["providers"] if entry["name"] == "Codex")
                codex[field] = value

                payload = snap.build_snapshot_payload([failing], NOW, prior=prior)
                current = next(entry for entry in payload["providers"] if entry["name"] == "Codex")
                self.assertFalse(current["ok"])
                self.assertEqual(current["error"], "rate limited")
                self.assertEqual(current["windows"], [])

    def test_transient_rejects_nonmapping_or_invalid_prior_timestamp(self) -> None:
        """Malformed prior metadata neither raises nor seeds cached data."""
        failing = _ps("Codex", False, error="rate limited")
        invalid_priors: list[object] = (["not a payload"], "not a payload")
        for prior in invalid_priors:
            with self.subTest(prior=repr(prior)):
                payload = snap.build_snapshot_payload([failing], NOW, prior=prior)
                current = next(entry for entry in payload["providers"] if entry["name"] == "Codex")
                self.assertFalse(current["ok"])
                self.assertEqual(current["windows"], [])

        for timestamp in ((NOW - timedelta(seconds=100)).isoformat(), "not an ISO timestamp"):
            with self.subTest(timestamp=timestamp):
                prior = self._healthy_prior(NOW - timedelta(seconds=100))
                prior["updated_at"] = timestamp
                payload = snap.build_snapshot_payload([failing], NOW, prior=prior)
                current = next(entry for entry in payload["providers"] if entry["name"] == "Codex")
                self.assertFalse(current["ok"])
                self.assertEqual(current["windows"], [])

    def test_transient_cursor_rejects_legacy_malformed_prior(self) -> None:
        """Cursor must not retain pre-v1-shape windows or raw pool metadata."""
        prior = {
            "schema_version": 1,
            "updated_at": snap.local_iso(NOW - timedelta(seconds=100)),
            "providers": [
                {
                    "name": "Cursor",
                    "ok": True,
                    "error": None,
                    "windows": [
                        {
                            "id": "ac",
                            "percent_left": None,
                            "reset_iso": None,
                            "window_hours": None,
                            "pace_delta": None,
                        },
                        {
                            "id": "ap",
                            "percent_left": "45",
                            "reset_iso": None,
                            "window_hours": None,
                            "pace_delta": None,
                        },
                    ],
                    "data": {
                        "credit_percent_left": 45.0,
                        "auto_percent_used": 20.0,
                        "api_percent_used": 30.0,
                    },
                }
            ],
        }
        failing = _ps("Cursor", False, error="network error")
        payload = snap.build_snapshot_payload([failing], NOW, prior=prior)
        cursor = next(p for p in payload["providers"] if p["name"] == "Cursor")
        self.assertFalse(cursor["ok"])
        self.assertEqual(cursor["windows"], [])
        self.assertEqual(cursor["data"], {})

    def test_transient_v2_cursor_rejects_pre_fix_dollar_meter_prior(self) -> None:
        """A v2 prior written before the 2026-07-16 ap-source fix must not crash.

        Before the fix, ``ap``'s persisted ``data`` was keyed by
        ``credit_percent_left`` (the dollar meter, now removed from
        SAFE_DATA_KEYS). On-disk history from before the fix can therefore
        contain that stale key under the still-current ``ap`` window ID.
        Retention must reject it via the SAFE_DATA_KEYS check (not crash),
        and the provider must cleanly fall back to an empty entry.
        """
        prior = {
            "schema_version": 2,
            "updated_at": snap.local_iso(NOW - timedelta(seconds=100)),
            "providers": [
                {
                    "name": "Cursor",
                    "ok": True,
                    "error": None,
                    "windows": [
                        {
                            "id": "ap",
                            "percent_left": 82.0,
                            "reset_iso": None,
                            "window_hours": None,
                            "pace_delta": None,
                        },
                    ],
                    "data": {"credit_percent_left": 82.0},
                }
            ],
        }
        failing = _ps("Cursor", False, error="network error")
        payload = snap.build_snapshot_v2_payload([failing], NOW, prior=prior)
        cursor = next(p for p in payload["providers"] if p["name"] == "Cursor")
        self.assertFalse(cursor["ok"])
        self.assertEqual(cursor["windows"], [])
        self.assertEqual(cursor["data"], {})

    def test_transient_antigravity_rejects_cg_prior_windows(self) -> None:
        """Router snapshots never retain C+G windows from a transient prior."""
        antigravity = _ps(
            "Antigravity",
            True,
            data={
                "five_hour_percent_left": 88,
                "weekly_percent_left": 66,
                "five_hour_reset": "in 4h",
                "weekly_reset": "in 6d",
            },
        )
        failing = _ps("Antigravity", False, error="network error")
        builders = (
            (snap.build_snapshot_payload, "cg5"),
            (snap.build_snapshot_v2_payload, "cg1w"),
        )
        for build, forbidden_window_id in builders:
            with self.subTest(schema=build.__name__, window_id=forbidden_window_id):
                prior = build([antigravity], NOW - timedelta(seconds=100))
                retained = build([failing], NOW, prior=prior)
                retained_antigravity = next(
                    entry for entry in retained["providers"] if entry["name"] == "Antigravity"
                )
                self.assertTrue(retained_antigravity["ok"])
                self.assertEqual(
                    [window["id"] for window in retained_antigravity["windows"]],
                    ["five_hour", "weekly"],
                )

                malicious_prior = copy.deepcopy(prior)
                malicious_entry = next(
                    entry
                    for entry in malicious_prior["providers"]
                    if entry["name"] == "Antigravity"
                )
                malicious_entry["windows"].append(
                    {
                        "id": forbidden_window_id,
                        "percent_left": 50.0,
                        "reset_iso": None,
                        "window_hours": 5.0,
                        "pace_delta": None,
                    }
                )
                payload = build([failing], NOW, prior=malicious_prior)
                current_antigravity = next(
                    entry for entry in payload["providers"] if entry["name"] == "Antigravity"
                )
                self.assertFalse(current_antigravity["ok"])
                self.assertEqual(current_antigravity["windows"], [])

    def test_transient_drops_stale_prior(self) -> None:
        """A transient failure past 300s does NOT retain the prior entry."""
        prior = self._healthy_prior(NOW - timedelta(seconds=400))
        failing = _ps("Codex", False, error="rate limited")
        payload = snap.build_snapshot_payload([failing], NOW, prior=prior)
        codex = next(p for p in payload["providers"] if p["name"] == "Codex")
        self.assertFalse(codex["ok"])
        self.assertEqual(codex["error"], "rate limited")

    def test_nontransient_failure_not_retained(self) -> None:
        """A non-transient failure is never retained even with fresh prior."""
        prior = self._healthy_prior(NOW - timedelta(seconds=50))
        failing = _ps("Codex", False, error="not logged in")
        payload = snap.build_snapshot_payload([failing], NOW, prior=prior)
        codex = next(p for p in payload["providers"] if p["name"] == "Codex")
        self.assertFalse(codex["ok"])

    def test_transient_priors_are_schema_specific(self) -> None:
        """A v1 prior cannot seed v2 (and vice versa)."""
        prior_v1 = self._healthy_prior(NOW - timedelta(seconds=100))
        failing = _ps("Codex", False, error="rate limited")
        v2 = snap.build_snapshot_v2_payload([failing], NOW, prior=prior_v1)
        codex = next(entry for entry in v2["providers"] if entry["name"] == "Codex")
        self.assertFalse(codex["ok"])

    def test_transient_rejects_nonfinite_prior_data_and_persists(self) -> None:
        """A corrupt recent prior cannot make strict JSON persistence fail."""
        prior = self._healthy_prior(NOW - timedelta(seconds=100))
        codex = next(entry for entry in prior["providers"] if entry["name"] == "Codex")
        codex["data"]["five_hour_percent_left"] = float("nan")
        payload = snap.build_snapshot_payload(
            [_ps("Codex", False, error="rate limited")], NOW, prior=prior
        )
        current = next(entry for entry in payload["providers"] if entry["name"] == "Codex")
        self.assertFalse(current["ok"])
        with tempfile.TemporaryDirectory() as tmpdir:
            self.assertTrue(snap.write_snapshot(payload, Path(tmpdir) / "snapshot.json"))

    def test_transient_rejects_prior_with_unhashable_window_id(self) -> None:
        """An unhashable prior ID is rejected instead of raising during membership."""
        prior = self._healthy_prior(NOW - timedelta(seconds=100))
        codex = next(entry for entry in prior["providers"] if entry["name"] == "Codex")
        codex["windows"][0]["id"] = ["five_hour"]

        payload = snap.build_snapshot_payload(
            [_ps("Codex", False, error="rate limited")], NOW, prior=prior
        )
        current = next(entry for entry in payload["providers"] if entry["name"] == "Codex")
        self.assertFalse(current["ok"])
        self.assertEqual(current["windows"], [])

    def test_transient_rejects_corrupt_window_metadata(self) -> None:
        """Corrupt retained metadata never survives a transient provider failure."""
        corrupt_values = (
            ("reset_iso", []),
            ("reset_iso", {"not": "a string"}),
            ("window_hours", math.nan),
            ("window_hours", math.inf),
            ("window_hours", True),
            ("window_hours", 0.0),
            ("pace_delta", math.nan),
            ("pace_delta", -math.inf),
            ("pace_delta", False),
            ("pace_delta", [0.1]),
        )
        for field, value in corrupt_values:
            with self.subTest(field=field, value=repr(value)):
                prior = self._healthy_prior(NOW - timedelta(seconds=100))
                codex = next(entry for entry in prior["providers"] if entry["name"] == "Codex")
                codex["windows"][0][field] = value

                payload = snap.build_snapshot_payload(
                    [_ps("Codex", False, error="rate limited")], NOW, prior=prior
                )
                current = next(entry for entry in payload["providers"] if entry["name"] == "Codex")
                self.assertFalse(current["ok"])
                self.assertEqual(current["windows"], [])


class TestPathContract(unittest.TestCase):
    def test_snapshot_path_is_state_dir(self) -> None:
        """SNAPSHOT_PATH lives under .state/, never .cache/."""
        text = str(snap.SNAPSHOT_PATH)
        self.assertTrue(text.endswith("/.state/snapshot.json"))
        self.assertNotIn("/.cache/", text)

    def test_v2_snapshot_path_is_a_sibling_state_file(self) -> None:
        self.assertTrue(str(snap.SNAPSHOT_V2_PATH).endswith("/.state/snapshot-v2.json"))


class TestConsistencyGuard(unittest.TestCase):
    def test_window_specs_match_render_specs(self) -> None:
        """CR-5: WINDOW_SPECS agree with ui render/row definitions."""
        for name in ("Codex", "Claude", "Antigravity"):
            render_windows = ui.PROVIDER_RENDER_SPECS[name].windows
            spec_windows = snap.WINDOW_SPECS[name]
            self.assertEqual(len(render_windows), len(spec_windows))
            for render_win, spec_win in zip(render_windows, spec_windows):
                self.assertEqual(spec_win.window_id, render_win.window_id)
                self.assertEqual(spec_win.percent_key, render_win.percent_key)
                self.assertEqual(spec_win.reset_key, render_win.reset_key)
                self.assertEqual(spec_win.window_hours, render_win.window_hours)

        # Cursor / Vibe are absent from PROVIDER_RENDER_SPECS. Cursor's
        # router contract remains independent from the TUI's two-pool rows.
        cursor_windows = snap.WINDOW_SPECS["Cursor"]
        self.assertEqual(
            [(window.window_id, window.percent_key, window.normalize) for window in cursor_windows],
            [
                ("billing_cycle", "credit_percent_left", "remaining"),
            ],
        )
        for cursor_win in cursor_windows:
            self.assertEqual(cursor_win.start_key, "billing_cycle_start")
            self.assertEqual(cursor_win.end_key, "billing_cycle_end_iso")

        (vibe_win,) = snap.WINDOW_SPECS["Vibe"]
        self.assertEqual(vibe_win.percent_key, "usage_percent")
        self.assertEqual(vibe_win.start_key, "start_date")
        self.assertEqual(vibe_win.end_key, "end_date")


class TestAtomicWrite(unittest.TestCase):
    def test_write_and_read_round_trip(self) -> None:
        """write_snapshot persists atomically and read_prior_snapshot round-trips."""
        payload = snap.build_snapshot_payload(
            [_ps("Codex", True, data={"five_hour_percent_left": 50})], NOW
        )
        tmpdir = tempfile.mkdtemp()
        path = Path(tmpdir) / "sub" / "snapshot.json"
        self.assertTrue(snap.write_snapshot(payload, path))
        self.assertTrue(path.exists())
        self.assertEqual(snap.read_prior_snapshot(path), payload)
        # On-disk JSON matches the payload too.
        with open(path, encoding="utf-8") as f:
            self.assertEqual(json.load(f), payload)

    def test_read_missing_returns_none(self) -> None:
        """read_prior_snapshot returns None for a missing file."""
        tmpdir = tempfile.mkdtemp()
        self.assertIsNone(snap.read_prior_snapshot(Path(tmpdir) / "nope.json"))

    def test_strict_json_rejects_nonfinite_values(self) -> None:
        """The persistence boundary never writes JSON NaN tokens."""
        tmpdir = tempfile.mkdtemp()
        path = Path(tmpdir) / "snapshot.json"
        self.assertFalse(snap.write_snapshot({"bad": float("nan")}, path))
        self.assertFalse(path.exists())

    def test_project_data_drops_nonfinite_allowlisted_values(self) -> None:
        """Bad source metadata cannot poison an otherwise valid payload."""
        provider = _ps(
            "Cursor",
            True,
            data={"auto_percent_used": float("nan"), "billing_cycle_end": "2026-04-01"},
        )
        self.assertEqual(snap.project_data(provider), {"billing_cycle_end": "2026-04-01"})


class TestCopilotParity(unittest.TestCase):
    def test_copilot_window_building_with_reset_key(self) -> None:
        """Copilot billing window populates reset_iso, window_hours, and pace_delta from premium_reset."""
        snap_copilot = _ps(
            "Copilot [HTTP]",
            True,
            data={
                "premium_percent_left": 10.0,
                "premium_reset": "Resets Aug 01 at 00:00",
            },
        )
        windows = snap.build_windows(snap_copilot, NOW)
        self.assertEqual(len(windows), 1)
        win = windows[0]
        self.assertEqual(win["id"], "premium")
        self.assertEqual(win["percent_left"], 10.0)
        self.assertIsNotNone(win["reset_iso"])
        self.assertIsNotNone(win["window_hours"])
        self.assertIsNotNone(win["pace_delta"])
        self.assertLess(win["pace_delta"], -0.10)

    def test_percent_is_depleted_rounds_fractional_zero(self) -> None:
        """Fractional remaining percentage < 0.5% (which renders as 0%) is treated as depleted."""
        self.assertTrue(snap.percent_is_depleted(0.0))
        self.assertTrue(snap.percent_is_depleted(0.4))
        self.assertTrue(snap.percent_is_depleted(0.001))

    def test_snapshot_payload_normalizes_http_suffix(self) -> None:
        """build_snapshot_payload matches snapshots carrying the [HTTP] suffix."""
        http_snap = _ps(
            "Claude [HTTP]", True, data={"session_percent_left": 80, "weekly_percent_left": 60}
        )
        payload = snap.build_snapshot_payload([http_snap], NOW)
        claude_entry = next(p for p in payload["providers"] if p["name"] == "Claude")
        self.assertTrue(claude_entry["ok"])
        self.assertNotEqual(claude_entry.get("error"), "provider not enabled")
        self.assertEqual(claude_entry["data"]["session_percent_left"], 80)


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
