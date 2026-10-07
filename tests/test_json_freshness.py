"""Freshness gating tests for the ``--json`` reader surface."""

from __future__ import annotations

import argparse
import json
import unittest
from datetime import datetime, timedelta, timezone
from io import StringIO
from unittest.mock import patch

from gradus.__main__ import main
from gradus.json_freshness import mark_unfresh
from gradus.providers import ProviderSnapshot
from gradus.snapshot import STALE_THRESHOLD_SECONDS

NOW = datetime(2026, 10, 7, 12, 0, 0, tzinfo=timezone.utc)


class MarkUnfreshTests(unittest.TestCase):
    def test_fresh_snapshot_unchanged(self) -> None:
        snapshots = [
            ProviderSnapshot(
                name="Codex",
                ok=True,
                source="snapshot",
                data={"end_date": (NOW + timedelta(days=1)).isoformat()},
            )
        ]

        result = mark_unfresh(snapshots, NOW - timedelta(seconds=60), NOW)

        self.assertEqual(result, snapshots)
        self.assertTrue(result[0].ok)
        self.assertEqual(result[0].source, "snapshot")
        self.assertIsNone(result[0].error)

    def test_stale_snapshot_flips_ok_and_keeps_data(self) -> None:
        updated_at = NOW - timedelta(seconds=STALE_THRESHOLD_SECONDS)
        data = {"end_date": "2026-10-01T00:00:00+00:00", "percent_left": 42}
        snapshots = [ProviderSnapshot(name="Vibe Code", ok=True, source="snapshot", data=data)]

        result = mark_unfresh(snapshots, updated_at, NOW)

        self.assertFalse(result[0].ok)
        self.assertEqual(result[0].source, "snapshot (stale)")
        self.assertEqual(
            result[0].error,
            f"snapshot stale: last updated {updated_at.isoformat()}",
        )
        self.assertEqual(result[0].data, data)

    def test_stale_failed_provider_keeps_error(self) -> None:
        snapshots = [
            ProviderSnapshot(
                name="Claude",
                ok=False,
                source="snapshot",
                error="connection timeout",
            )
        ]

        result = mark_unfresh(snapshots, NOW - timedelta(hours=1), NOW)

        self.assertFalse(result[0].ok)
        self.assertEqual(result[0].source, "snapshot (stale)")
        self.assertEqual(result[0].error, "connection timeout")

    def test_ended_cycle_flips_ok_to_false(self) -> None:
        end_date = (NOW - timedelta(hours=1)).isoformat()
        snapshots = [
            ProviderSnapshot(
                name="Vibe Code",
                ok=True,
                source="snapshot",
                data={"end_date": end_date},
            )
        ]

        result = mark_unfresh(snapshots, NOW - timedelta(seconds=60), NOW)

        self.assertFalse(result[0].ok)
        self.assertEqual(result[0].source, "snapshot")
        self.assertEqual(result[0].error, f"usage cycle ended {end_date}; awaiting refresh")
        self.assertEqual(result[0].data, {"end_date": end_date})

    def test_future_end_date_stays_ok(self) -> None:
        end_date = (NOW + timedelta(days=1)).isoformat()
        snapshots = [
            ProviderSnapshot(
                name="Codex",
                ok=True,
                source="snapshot",
                data={"end_date": end_date},
            )
        ]

        result = mark_unfresh(snapshots, NOW - timedelta(seconds=60), NOW)

        self.assertTrue(result[0].ok)
        self.assertIsNone(result[0].error)

    def test_missing_or_garbage_end_date_stays_ok(self) -> None:
        snapshots = [
            ProviderSnapshot(name="Codex", ok=True, source="snapshot"),
            ProviderSnapshot(name="Cursor", ok=True, source="snapshot", data={}),
            ProviderSnapshot(
                name="Gemini",
                ok=True,
                source="snapshot",
                data={"end_date": "not a timestamp"},
            ),
            ProviderSnapshot(
                name="Copilot",
                ok=True,
                source="snapshot",
                # Naive timestamps are not comparable to an aware `now`.
                data={"end_date": "2026-10-07T00:00:00"},
            ),
        ]

        result = mark_unfresh(snapshots, NOW - timedelta(seconds=60), NOW)

        self.assertTrue(all(snapshot.ok for snapshot in result))
        self.assertTrue(all(snapshot.error is None for snapshot in result))

    def test_naive_updated_at_is_stale(self) -> None:
        snapshots = [ProviderSnapshot(name="Codex", ok=True, source="snapshot", data={})]

        result = mark_unfresh(snapshots, NOW.replace(tzinfo=None), NOW)

        self.assertFalse(result[0].ok)
        self.assertEqual(result[0].source, "snapshot (stale)")

    def test_inputs_not_mutated(self) -> None:
        ok_snapshot = ProviderSnapshot(
            name="Vibe Code",
            ok=True,
            source="snapshot",
            data={"end_date": (NOW - timedelta(hours=1)).isoformat()},
        )
        failed_snapshot = ProviderSnapshot(
            name="Claude",
            ok=False,
            source="snapshot",
            error="connection timeout",
        )
        snapshots = [ok_snapshot, failed_snapshot]
        before = [(s.name, s.ok, s.source, s.error, dict(s.data or {})) for s in snapshots]

        mark_unfresh(snapshots, NOW - timedelta(hours=1), NOW)
        mark_unfresh(snapshots, NOW - timedelta(seconds=60), NOW)

        after = [(s.name, s.ok, s.source, s.error, dict(s.data or {})) for s in snapshots]
        self.assertEqual(after, before)


class MainJsonFreshnessTests(unittest.TestCase):
    def test_json_reports_stale_snapshot_as_not_ok(self) -> None:
        updated_at = datetime.now().astimezone() - timedelta(hours=1)
        snapshots = [ProviderSnapshot(name="Vibe Code", ok=True, source="snapshot", data={})]

        buf = StringIO()
        with (
            patch(
                "gradus.__main__.parse_args",
                return_value=argparse.Namespace(json=True, once=False, debug=False, interval=120),
            ),
            patch("gradus.__main__.initialize_providers") as init,
            patch("gradus.__main__.collect_snapshots") as collect,
            patch(
                "gradus.__main__._read_canonical_snapshots",
                return_value=(snapshots, updated_at),
            ),
            patch("gradus.__main__.sys.stdout", buf),
        ):
            rc = main()

        self.assertEqual(rc, 0)
        self.assertIn('"ok": false', buf.getvalue())
        payload = json.loads(buf.getvalue())
        provider = next(p for p in payload["providers"] if p["name"] == "Vibe Code")
        self.assertFalse(provider["ok"])
        self.assertEqual(provider["source"], "snapshot (stale)")
        self.assertEqual(
            provider["error"],
            f"snapshot stale: last updated {updated_at.isoformat()}",
        )
        init.assert_not_called()
        collect.assert_not_called()


if __name__ == "__main__":
    unittest.main()
