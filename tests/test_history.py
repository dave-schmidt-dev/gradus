"""Tests for the credential-free, bounded schema-v2 history store."""

from __future__ import annotations

import json
import os
import stat
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
from pathlib import Path

from gradus.history import (
    HISTORY_LOCK_NAME,
    HISTORY_SCHEMA_VERSION,
    HistoryStore,
    build_history_record,
    query_history,
    read_history_evidence,
    read_history_records,
    recent_auth_failure_count,
)
from gradus.providers import ProviderSnapshot
from gradus.snapshot import build_snapshot_v2_payload

UTC = timezone.utc


def _iso(value: datetime | None) -> str | None:
    return value.isoformat() if value is not None else None


def _entry(
    name: str,
    updated_at: datetime,
    *,
    ok: bool = True,
    observed_at: datetime | None = None,
    error: str | None = None,
    data: dict[str, object] | None = None,
) -> dict[str, object]:
    return {
        "name": name,
        "ok": ok,
        "error": error,
        "windows": (
            [
                {
                    "id": "five_hour",
                    "percent_left": 91.25,
                    "reset_iso": "2026-01-01T17:00:00+00:00",
                    "window_hours": 5.0,
                    "pace_delta": -0.01,
                }
            ]
            if ok
            else []
        ),
        "data": data or {},
        "observed_at": _iso(observed_at if observed_at is not None else updated_at) if ok else None,
    }


def _payload(
    updated_at: datetime,
    entries: list[dict[str, object]] | None = None,
) -> dict[str, object]:
    return {
        "schema_version": 2,
        "updated_at": updated_at.isoformat(),
        "providers": entries or [_entry("Codex", updated_at)],
    }


def _provider_snapshots() -> list[ProviderSnapshot]:
    return [
        ProviderSnapshot(
            name="Antigravity",
            ok=True,
            source="api",
            data={"five_hour_percent_left": 91.25},
        ),
        ProviderSnapshot(
            name="OpenCode Go",
            ok=False,
            source="api",
            error="session expired: sign in at opencode.ai",
        ),
    ]


class HistoryRecordTests(unittest.TestCase):
    def test_record_has_safe_provenance_and_separate_probe_and_capacity(self) -> None:
        updated_at = datetime(2026, 1, 8, 12, tzinfo=UTC)
        payload = _payload(
            updated_at,
            [
                _entry(
                    "Antigravity",
                    updated_at,
                    data={"five_hour_percent_left": 91.25},
                ),
                _entry(
                    "Antigravity (Claude)",
                    updated_at,
                    data={"five_hour_percent_left": 76.5},
                ),
                _entry("OpenCode Go", updated_at, ok=False, error="session expired"),
                _entry("Codex", updated_at, ok=False, error="provider not enabled"),
            ],
        )

        record = build_history_record(payload, _provider_snapshots())

        assert record is not None
        self.assertEqual(record["history_schema_version"], HISTORY_SCHEMA_VERSION)
        self.assertEqual(record["snapshot"], payload)
        agy = record["provenance"]["Antigravity"]
        self.assertEqual(agy["method"], "POST")
        self.assertEqual(
            agy["endpoint"],
            "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
        )
        self.assertEqual(agy["bucket_family"], "gemini-*")
        claude = record["provenance"]["Antigravity (Claude)"]
        self.assertEqual(claude["bucket_family"], "3p-*")
        self.assertEqual(claude["upstream_pool"], "Claude and GPT models")
        self.assertEqual(claude["downstream_policy"], "Sonnet target only")
        opencode = record["provenance"]["OpenCode Go"]
        self.assertEqual(opencode["workspace_identifiers"], "redacted")
        self.assertNotIn(
            "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f", json.dumps(record)
        )

        agy_observation = record["observations"]["Antigravity"]
        self.assertEqual(agy_observation["probe"], {"attempted": True, "reason": "success"})
        self.assertEqual(agy_observation["capacity"]["state"], "observed")
        self.assertFalse(agy_observation["capacity"]["synthetic"])
        self.assertTrue(record["observations"]["Antigravity (Claude)"]["capacity"]["synthetic"])
        self.assertEqual(
            record["observations"]["OpenCode Go"]["probe"],
            {"attempted": False, "reason": "auth_failure"},
        )
        self.assertEqual(record["observations"]["Codex"]["capacity"]["state"], "not_enabled")

    def test_capacity_state_precedence_and_timestamp_boundaries(self) -> None:
        updated_at = datetime(2026, 1, 8, 12, tzinfo=UTC)
        payload = _payload(
            updated_at,
            [
                _entry(
                    "failed",
                    updated_at,
                    ok=False,
                    observed_at=updated_at - timedelta(days=1),
                    error="connection timeout",
                ),
                _entry("disabled", updated_at, ok=False, error="provider not enabled"),
                _entry("observed", updated_at, observed_at=updated_at),
                _entry(
                    "carried",
                    updated_at,
                    observed_at=updated_at - timedelta(seconds=1),
                ),
                _entry(
                    "future",
                    updated_at,
                    observed_at=updated_at + timedelta(seconds=1),
                ),
            ],
        )
        record = build_history_record(payload, [])

        assert record is not None
        observations = record["observations"]
        self.assertEqual(observations["failed"]["capacity"]["state"], "failed")
        self.assertIsNone(observations["failed"]["capacity"]["observed_at"])
        self.assertEqual(observations["disabled"]["capacity"]["state"], "not_enabled")
        self.assertEqual(observations["observed"]["capacity"]["state"], "observed")
        self.assertEqual(observations["carried"]["capacity"]["state"], "carried")
        self.assertEqual(observations["future"]["capacity"]["state"], "invalid")

        naive = _payload(
            updated_at,
            [_entry("Codex", updated_at, observed_at=datetime(2026, 1, 8, 12))],
        )
        self.assertIsNone(build_history_record(naive, []))

    def test_rejects_raw_debug_and_credential_like_payloads(self) -> None:
        updated_at = datetime(2026, 1, 8, 12, tzinfo=UTC)
        raw_payload = _payload(
            updated_at,
            [_entry("Codex", updated_at, data={"raw_text": "cookie=secret"})],
        )
        self.assertIsNone(build_history_record(raw_payload, []))

        debug_payload = _payload(updated_at)
        debug_payload["providers"][0]["debug_detail"] = "provider debug output"
        self.assertIsNone(build_history_record(debug_payload, []))

        credential_payload = _payload(updated_at)
        credential_payload["providers"][0]["error"] = "authorization: Bearer secret"
        self.assertIsNone(build_history_record(credential_payload, []))

    def test_codex_spark_entry_synthesized_from_generated_v2_payload(self) -> None:
        """A generated 9-entry v2 payload's "Codex (Spark)" observation is
        synthetic and sourced from the "Codex" probe, which does not exist
        as a probe under its own name (Task 3.2).
        """
        updated_at = datetime(2026, 1, 8, 12, tzinfo=UTC)
        codex_snapshot = ProviderSnapshot(
            name="Codex",
            ok=True,
            source="api",
            data={
                "five_hour_percent_left": 55.0,
                "weekly_percent_left": 10.0,
                "spark_weekly_percent_left": 90.0,
                "spark_weekly_reset": "in 2d",
            },
        )
        payload = build_snapshot_v2_payload([codex_snapshot], updated_at)
        self.assertEqual(len(payload["providers"]), 9)
        self.assertIn("Codex (Spark)", [entry["name"] for entry in payload["providers"]])

        record = build_history_record(payload, [codex_snapshot])
        assert record is not None

        self.assertEqual(record["provenance"]["Codex (Spark)"], {"provenance_available": False})
        spark_observation = record["observations"]["Codex (Spark)"]
        self.assertTrue(spark_observation["capacity"]["synthetic"])
        self.assertEqual(spark_observation["probe"], {"attempted": True, "reason": "success"})
        # The primary Codex entry's own observation is unaffected: it is not
        # synthetic, and its probe metadata is unchanged by the new pairing.
        self.assertFalse(record["observations"]["Codex"]["capacity"]["synthetic"])
        self.assertEqual(
            record["observations"]["Codex"]["probe"], {"attempted": True, "reason": "success"}
        )


class HistoryStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmpdir = tempfile.TemporaryDirectory()
        self.history_dir = Path(self.tmpdir.name) / "history"
        self.store = HistoryStore(self.history_dir)
        self.snapshots: list[ProviderSnapshot] = []

    def tearDown(self) -> None:
        self.tmpdir.cleanup()

    def _append(self, when: datetime) -> bool:
        return self.store.append(_payload(when), self.snapshots, now=when)

    def test_round_trip_requires_committed_candidate_and_hardens_files(self) -> None:
        updated_at = datetime(2026, 1, 8, 12, tzinfo=UTC)
        candidate = _payload(updated_at)
        mismatched = _payload(updated_at + timedelta(seconds=1))
        self.assertFalse(
            self.store.append(
                candidate, self.snapshots, committed_payload=mismatched, now=updated_at
            )
        )
        self.assertFalse(self.history_dir.exists())

        self.assertTrue(
            self.store.append(
                candidate, self.snapshots, committed_payload=candidate, now=updated_at
            )
        )
        records = read_history_records(self.history_dir)
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["snapshot"], candidate)
        partition = next(self.history_dir.glob("*.jsonl"))
        self.assertEqual(stat.S_IMODE(partition.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.history_dir.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((self.history_dir / HISTORY_LOCK_NAME).stat().st_mode), 0o600)
        line = partition.read_text(encoding="utf-8")
        self.assertNotIn(" : ", line)
        self.assertTrue(line.endswith("\n"))

    def test_duplicate_and_non_monotonic_timestamps_are_rejected(self) -> None:
        first = datetime(2026, 1, 8, 12, tzinfo=UTC)
        self.assertTrue(self._append(first))
        self.assertFalse(self._append(first))
        self.assertFalse(self._append(first - timedelta(seconds=1)))
        self.assertTrue(self._append(first + timedelta(seconds=1)))
        self.assertEqual(len(self.store.records()), 2)

    def test_concurrent_appends_leave_a_valid_monotonic_partition(self) -> None:
        first = datetime(2026, 1, 8, 12, tzinfo=UTC)
        second = first + timedelta(seconds=1)
        with ThreadPoolExecutor(max_workers=2) as executor:
            outcomes = list(executor.map(self._append, (first, second)))

        self.assertGreaterEqual(sum(outcomes), 1)
        records = self.store.records()
        timestamps = [
            datetime.fromisoformat(record["snapshot"]["updated_at"]) for record in records
        ]
        self.assertEqual(timestamps, sorted(set(timestamps)))
        self.assertTrue(
            all(record["history_schema_version"] == HISTORY_SCHEMA_VERSION for record in records)
        )

    def test_incomplete_final_line_is_tolerated_and_repaired(self) -> None:
        first = datetime(2026, 1, 8, 12, tzinfo=UTC)
        self.assertTrue(self._append(first))
        partition = next(self.history_dir.glob("*.jsonl"))
        with partition.open("ab") as handle:
            handle.write(b'{"history_schema_version":')
        self.assertEqual(len(self.store.records()), 1)
        self.assertTrue(self._append(first + timedelta(seconds=1)))
        self.assertEqual(len(self.store.records()), 2)
        self.assertFalse(partition.read_bytes().endswith(b'{"history_schema_version":'))

    def test_retention_keeps_exact_cutoff_and_deletes_expired_partition(self) -> None:
        base = datetime(2026, 1, 8, 12, tzinfo=UTC)
        expired = base - timedelta(days=8)
        cutoff = base - timedelta(days=7)
        self.assertTrue(self._append(expired))
        self.assertTrue(self._append(cutoff))
        self.assertTrue(self._append(base))

        timestamps = [
            datetime.fromisoformat(record["snapshot"]["updated_at"])
            for record in self.store.records()
        ]
        self.assertEqual(timestamps, [cutoff, base])
        self.assertFalse((self.history_dir / f"{expired.date().isoformat()}.jsonl").exists())
        self.assertTrue((self.history_dir / f"{cutoff.date().isoformat()}.jsonl").exists())

    def test_existing_permissions_are_hardened_on_read(self) -> None:
        first = datetime(2026, 1, 8, 12, tzinfo=UTC)
        self.assertTrue(self._append(first))
        partition = next(self.history_dir.glob("*.jsonl"))
        os.chmod(self.history_dir, 0o755)
        os.chmod(partition, 0o644)
        os.chmod(self.history_dir / HISTORY_LOCK_NAME, 0o644)

        self.assertEqual(len(self.store.records()), 1)
        self.assertEqual(stat.S_IMODE(self.history_dir.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(partition.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE((self.history_dir / HISTORY_LOCK_NAME).stat().st_mode), 0o600)

    def test_naive_retention_clock_does_not_write_a_record(self) -> None:
        candidate_time = datetime(2026, 1, 8, 12, tzinfo=UTC)
        self.assertFalse(
            self.store.append(
                _payload(candidate_time),
                self.snapshots,
                now=datetime(2026, 1, 8, 12),
            )
        )
        self.assertFalse(self.history_dir.exists())


class HistoryQueryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmpdir = tempfile.TemporaryDirectory()
        self.history_dir = Path(self.tmpdir.name) / "history"
        self.store = HistoryStore(self.history_dir)

    def tearDown(self) -> None:
        self.tmpdir.cleanup()

    def _append(self, when: datetime, *, name: str = "Codex") -> None:
        payload = _payload(
            when,
            [_entry(name, when, data={"five_hour_percent_left": 91.25})],
        )
        self.assertTrue(
            self.store.append(
                payload,
                [ProviderSnapshot(name=name, ok=True, source="api", data={})],
                now=when,
            )
        )

    def test_nearest_prior_round_trips_fractional_windows_and_timezone(self) -> None:
        first = datetime(2026, 1, 8, 12, tzinfo=UTC)
        second = first + timedelta(minutes=1)
        self._append(first)
        self._append(second)

        result = query_history(
            ["2026-01-08T08:00:00-04:00", "2026-01-08T12:01:00+00:00"],
            providers=["Codex"],
            history_dir=self.history_dir,
        )

        self.assertFalse(result["executor_auth_verified"])
        self.assertEqual(result["history_status"], "ok")
        self.assertEqual(len(result["results"]), 2)
        self.assertTrue(result["results"][0]["verified"])
        self.assertEqual(result["results"][0]["distance_seconds"], 0.0)
        self.assertEqual(
            result["results"][0]["providers"]["Codex"]["windows"][0]["percent_left"],
            91.25,
        )
        self.assertEqual(result["results"][1]["distance_seconds"], 0.0)
        self.assertEqual(result["results"][1]["updated_at"], second.isoformat())

    def test_max_gap_and_missing_records_are_explicitly_unverified(self) -> None:
        first = datetime(2026, 1, 8, 12, tzinfo=UTC)
        self._append(first)
        result = query_history(
            ["2026-01-08T11:59:00+00:00", "2026-01-09T12:00:00+00:00"],
            max_gap=10,
            history_dir=self.history_dir,
        )

        self.assertEqual(result["results"][0]["reason"], "no_prior_record")
        self.assertFalse(result["results"][0]["verified"])
        self.assertEqual(result["results"][1]["reason"], "max_gap_exceeded")
        self.assertFalse(result["results"][1]["verified"])
        self.assertGreater(result["results"][1]["distance_seconds"], 10)

    def test_shared_antigravity_claude_provenance_survives_query(self) -> None:
        updated_at = datetime(2026, 1, 8, 12, tzinfo=UTC)
        payload = _payload(
            updated_at,
            [
                _entry("Antigravity", updated_at, data={"five_hour_percent_left": 90}),
                _entry(
                    "Antigravity (Claude)",
                    updated_at,
                    data={"five_hour_percent_left": 42.5},
                ),
            ],
        )
        self.assertTrue(
            self.store.append(
                payload,
                [
                    ProviderSnapshot(
                        name="Antigravity",
                        ok=True,
                        source="api",
                        data={"five_hour_percent_left": 90},
                    )
                ],
                now=updated_at,
            )
        )

        result = query_history(
            [updated_at.isoformat()],
            providers=["Antigravity (Claude)"],
            history_dir=self.history_dir,
        )
        provider = result["results"][0]["providers"]["Antigravity (Claude)"]
        self.assertEqual(provider["capacity_origin"]["bucket_family"], "3p-*")
        self.assertEqual(provider["capacity_origin"]["upstream_pool"], "Claude and GPT models")
        self.assertEqual(provider["capacity_origin"]["downstream_policy"], "Sonnet target only")
        self.assertTrue(provider["synthetic"])

    def test_corrupt_history_is_not_presented_as_verified_and_partial_tail_is_tolerated(
        self,
    ) -> None:
        first = datetime(2026, 1, 8, 12, tzinfo=UTC)
        self._append(first)
        partition = next(self.history_dir.glob("*.jsonl"))
        with partition.open("ab") as handle:
            handle.write(b'{"history_schema_version":1}\n')
            handle.write(b'{"history_schema_version":')

        records, status = read_history_evidence(self.history_dir)
        self.assertEqual(len(records), 1)
        self.assertEqual(status, "corrupt")
        result = query_history([first.isoformat()], history_dir=self.history_dir)
        self.assertEqual(result["results"][0]["reason"], "corrupt_history")
        self.assertFalse(result["results"][0]["verified"])

    def test_tampered_provenance_envelope_is_rejected(self) -> None:
        first = datetime(2026, 1, 8, 12, tzinfo=UTC)
        self._append(first)
        partition = next(self.history_dir.glob("*.jsonl"))
        record = json.loads(partition.read_text(encoding="utf-8"))
        record["provenance"]["Codex"] = {
            "provenance_available": True,
            "credential": "should never be surfaced",
        }
        partition.write_text(json.dumps(record) + "\n", encoding="utf-8")

        records, status = read_history_evidence(self.history_dir)
        self.assertEqual(records, [])
        self.assertEqual(status, "corrupt")
        result = query_history([first.isoformat()], history_dir=self.history_dir)
        self.assertEqual(result["results"][0]["reason"], "corrupt_history")
        self.assertNotIn("should never be surfaced", json.dumps(result))

    def test_query_does_not_create_or_harden_history_files(self) -> None:
        missing = Path(self.tmpdir.name) / "missing-history"
        result = query_history(["2026-01-08T12:00:00+00:00"], history_dir=missing)
        self.assertEqual(result["history_status"], "missing")
        self.assertFalse(missing.exists())

        first = datetime(2026, 1, 8, 12, tzinfo=UTC)
        self._append(first)
        partition = next(self.history_dir.glob("*.jsonl"))
        os.chmod(self.history_dir, 0o755)
        os.chmod(partition, 0o644)
        before_dir = stat.S_IMODE(self.history_dir.stat().st_mode)
        before_file = stat.S_IMODE(partition.stat().st_mode)
        query_history([first.isoformat()], history_dir=self.history_dir)
        self.assertEqual(stat.S_IMODE(self.history_dir.stat().st_mode), before_dir)
        self.assertEqual(stat.S_IMODE(partition.stat().st_mode), before_file)


class AuthFailureJournalTests(unittest.TestCase):
    def test_counter_reads_prior_auth_failures_only_in_rolling_window(self) -> None:
        tmpdir = tempfile.TemporaryDirectory()
        history_dir = Path(tmpdir.name) / "history"
        try:
            now = datetime(2026, 1, 8, 12, tzinfo=UTC)
            for when in (now - timedelta(seconds=600), now - timedelta(seconds=300)):
                payload = _payload(
                    when,
                    [
                        _entry(
                            "Antigravity",
                            when,
                            ok=False,
                            error="Antigravity refresh retrying; values may be stale",
                        )
                    ],
                )
                probe = ProviderSnapshot(
                    name="Antigravity",
                    ok=False,
                    source="api",
                    error="Antigravity refresh retrying; values may be stale",
                    debug_detail="auth_failure",
                )
                self.assertTrue(HistoryStore(history_dir).append(payload, [probe], now=when))
            self.assertEqual(
                recent_auth_failure_count("Antigravity", as_of=now, history_dir=history_dir),
                1,
            )
        finally:
            tmpdir.cleanup()


if __name__ == "__main__":
    unittest.main()
