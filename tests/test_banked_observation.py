"""Stdlib-only sidecar codec and atomic writer checks for VM preflight."""

import json
import os
import tempfile
import unittest
from pathlib import Path

from gradus.banked_observation import bounded_count, validated_sidecar, write_sidecar


class BankedObservationTests(unittest.TestCase):
    def test_bounded_count_rejects_coercions(self):
        for invalid in (None, True, -1, 1.0, "1", 1_000_001):
            self.assertIsNone(bounded_count(invalid))
        self.assertEqual(bounded_count(0), 0)
        self.assertEqual(bounded_count(1_000_000), 1_000_000)

    def test_writer_produces_exact_credential_free_shape_and_0600(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "banked-observation-v1.json"
            document = write_sidecar(
                path,
                count=2,
                generation="8a596d59-294c-4efc-81a3-0caab767abbb",
                snapshot_updated_at="2026-09-23T10:00:00-04:00",
                observed_at="2026-09-23T10:00:00-04:00",
            )
            self.assertEqual(json.loads(path.read_text()), document)
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)
            self.assertEqual(
                set(document),
                {"schema_version", "count", "generation", "snapshot_updated_at", "observed_at"},
            )
            self.assertEqual(validated_sidecar(document), document)
            self.assertNotIn("user", path.read_text())

    def test_invalid_replacement_preserves_prior_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "banked-observation-v1.json"
            write_sidecar(
                path,
                count=1,
                generation="8a596d59-294c-4efc-81a3-0caab767abbb",
                snapshot_updated_at="2026-09-23T10:00:00Z",
                observed_at="2026-09-23T10:00:00Z",
            )
            prior = path.read_bytes()
            with self.assertRaises(ValueError):
                write_sidecar(
                    path,
                    count=-1,
                    generation="invalid",
                    snapshot_updated_at="bad",
                    observed_at="bad",
                )
            self.assertEqual(path.read_bytes(), prior)
            malformed = dict(json.loads(prior))
            malformed["user_id"] = "private"
            self.assertIsNone(validated_sidecar(malformed))

    def test_checked_in_fixture_matches_real_writer(self):
        fixture = Path(__file__).parent / "fixtures" / "banked-observation-v1.json"
        with tempfile.TemporaryDirectory() as directory:
            generated = Path(directory) / fixture.name
            write_sidecar(
                generated,
                count=3,
                generation="8a596d59-294c-4efc-81a3-0caab767abbb",
                snapshot_updated_at="2026-09-23T10:00:00-04:00",
                observed_at="2026-09-23T10:00:00-04:00",
            )
            self.assertEqual(generated.read_bytes(), fixture.read_bytes())


if __name__ == "__main__":
    unittest.main()
