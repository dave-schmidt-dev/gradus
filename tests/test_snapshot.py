"""Unit tests for ai_monitor.snapshot (router-facing capacity snapshot)."""

from __future__ import annotations

import json
import math
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

from ai_monitor import snapshot as snap
from ai_monitor import ui
from ai_monitor.providers import ProviderSnapshot

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
                "credit_percent_left": 55.0,
                "plan_name": "Pro",
                "session_token": "tok_abc",
                "cookie": "sid=xyz",
            },
        )
        projected = snap.project_data(cursor)
        self.assertEqual(projected, {"credit_percent_left": 55.0})


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
        """Cursor: naive full-precision start + tz-aware full-precision end."""
        cursor = _ps(
            "Cursor",
            True,
            data={
                "credit_percent_left": 60.0,
                "billing_cycle_start": "2026-03-01T00:00:00",
                "billing_cycle_end_iso": "2026-04-01T00:00:00+00:00",
            },
        )
        windows = snap.build_windows(cursor, NOW)
        self.assertEqual(len(windows), 1)
        win = windows[0]
        self.assertEqual(win["id"], "billing_cycle")
        self.assertEqual(win["percent_left"], 60.0)
        self.assertIsInstance(win["window_hours"], float)
        self.assertGreater(win["window_hours"], 0.0)
        self.assertIsInstance(win["pace_delta"], float)

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

    def test_malformed_boundary_returns_empty(self) -> None:
        """A malformed billing boundary makes build_windows return [] (no crash)."""
        cursor = _ps(
            "Cursor",
            True,
            data={
                "credit_percent_left": 50.0,
                "billing_cycle_start": "2026-03-01T00:00:00",
                "billing_cycle_end_iso": "not-a-date",
            },
        )
        self.assertEqual(snap.build_windows(cursor, NOW), [])

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

    def test_build_windows_empty_when_not_ok(self) -> None:
        """A not-ok or unknown snapshot yields no windows."""
        self.assertEqual(snap.build_windows(_ps("Codex", False), NOW), [])
        self.assertEqual(snap.build_windows(_ps("Unknown", True, data={"x": 1}), NOW), [])


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
        self.assertTrue(codex["ok"])
        self.assertTrue(codex["windows"])

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


class TestPathContract(unittest.TestCase):
    def test_snapshot_path_is_state_dir(self) -> None:
        """SNAPSHOT_PATH lives under .state/, never .cache/."""
        text = str(snap.SNAPSHOT_PATH)
        self.assertTrue(text.endswith("/.state/snapshot.json"))
        self.assertNotIn("/.cache/", text)


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

        # Cursor / Vibe are absent from PROVIDER_RENDER_SPECS: pin the literal
        # keys read in ui._add_cursor_rows / ui._add_vibe_rows.
        (cursor_win,) = snap.WINDOW_SPECS["Cursor"]
        self.assertEqual(cursor_win.percent_key, "credit_percent_left")
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


if __name__ == "__main__":  # pragma: no cover
    unittest.main()
