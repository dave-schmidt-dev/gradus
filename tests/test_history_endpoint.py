"""Compatibility regressions for Antigravity history endpoint provenance."""

from __future__ import annotations

import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from gradus.history import build_history_record, query_history, read_history_evidence
from gradus.providers import ProviderSnapshot
from gradus.snapshot import build_snapshot_v2_payload

UTC = timezone.utc


class HistoricalAntigravityEndpointTests(unittest.TestCase):
    """The endpoint switch must not invalidate pre-existing Antigravity records.

    ``_valid_history_record`` compares provenance exactly, so moving the live
    endpoint from ``daily-cloudcode-pa`` to ``cloudcode-pa`` turned every older
    Antigravity pool record into corruption.  These pin the narrow compatibility
    window: current descriptor OR the identical descriptor with only the prior
    endpoint -- and nothing wider.
    """

    HISTORICAL_ENDPOINT = (
        "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
    )

    def _record(self, name: str, when: datetime, endpoint: str) -> dict[str, object]:
        snapshot = ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="api",
            data={"five_hour_percent_left": 90, "third_party_five_hour_percent_left": 80},
        )
        payload = build_snapshot_v2_payload([snapshot], when)
        payload["providers"] = [entry for entry in payload["providers"] if entry["name"] == name]
        record = build_history_record(payload, [])
        assert record is not None
        record["provenance"][name]["endpoint"] = endpoint
        return record

    def _write(self, history_dir: Path, record: dict[str, object], when: datetime) -> None:
        path = history_dir / f"{when.date().isoformat()}.jsonl"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(record) + "\n", encoding="utf-8")

    def test_old_and_current_endpoint_read_and_query_for_both_pools(self) -> None:
        when = datetime(2026, 1, 8, 12, tzinfo=UTC)
        endpoints = {
            "current": "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
            "historical": self.HISTORICAL_ENDPOINT,
        }
        for name in ("Antigravity", "Antigravity (Claude)"):
            for label, endpoint in endpoints.items():
                with self.subTest(name=name, endpoint=label):
                    with tempfile.TemporaryDirectory() as tmp:
                        history_dir = Path(tmp) / "history"
                        self._write(history_dir, self._record(name, when, endpoint), when)

                        records, status = read_history_evidence(history_dir)
                        self.assertEqual(status, "ok")
                        self.assertEqual(len(records), 1)

                        result = query_history(
                            [when.isoformat()],
                            providers=[name],
                            history_dir=history_dir,
                        )
                        self.assertEqual(result["results"][0]["reason"], "matched")
                        self.assertTrue(result["results"][0]["verified"])
                        origin = result["results"][0]["providers"][name]["capacity_origin"]
                        self.assertEqual(origin["endpoint"], endpoint)

    def test_arbitrary_endpoint_and_altered_descriptor_are_rejected(self) -> None:
        when = datetime(2026, 1, 8, 12, tzinfo=UTC)
        cases: dict[str, dict[str, object]] = {
            "arbitrary_endpoint": {
                "endpoint": "https://example.com/v1internal:retrieveUserQuotaSummary"
            },
            "altered_method": {"method": "GET"},
            "altered_bucket_family": {"bucket_family": "other-*"},
            "altered_projection": {"projection": "sideways"},
        }
        for name in ("Antigravity", "Antigravity (Claude)"):
            for label, mutation in cases.items():
                with self.subTest(name=name, mutation=label):
                    with tempfile.TemporaryDirectory() as tmp:
                        history_dir = Path(tmp) / "history"
                        record = self._record(name, when, self.HISTORICAL_ENDPOINT)
                        record["provenance"][name].update(mutation)
                        self._write(history_dir, record, when)

                        records, status = read_history_evidence(history_dir)
                        self.assertEqual(records, [])
                        self.assertEqual(status, "corrupt")
