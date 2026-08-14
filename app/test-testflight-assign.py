#!/usr/bin/env python3
"""Offline tests for Gradus allocation and RAM-volume release boundaries."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from release_candidate.allocation import ALLOCATION_STATE, persist, reconcile
from release_candidate.ledger import CandidateError
from release_candidate.ram_volume import validate


class ReleaseBoundaryTests(unittest.TestCase):
    def test_allocation_is_idempotent_and_exactly_reconcilable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "allocated.json"
            first = persist(
                path,
                candidate_id="gradus-ios-18",
                build=18,
                marketing_version="1.6.7",
                allocated_at="2026-08-12T00:00:00Z",
            )
            self.assertEqual(first.state, ALLOCATION_STATE)
            self.assertEqual(
                persist(
                    path,
                    candidate_id="gradus-ios-18",
                    build=18,
                    marketing_version="1.6.7",
                    allocated_at="2026-08-12T00:00:00Z",
                ),
                first,
            )
            self.assertEqual(reconcile(path, candidate_id="gradus-ios-18", build=18), first)
            with self.assertRaises(CandidateError):
                persist(
                    path,
                    candidate_id="different",
                    build=19,
                    marketing_version="1.6.7",
                    allocated_at="2026-08-12T00:00:00Z",
                )

    def test_ram_attestation_rejects_disk_backed_or_mounted_volume(self) -> None:
        base = {
            "candidateId": "gradus-ios-18",
            "mountEvidenceSha256": "a" * 64,
            "detachEvidenceSha256": "b" * 64,
            "volumeId": "fixture-ram-volume",
            "filesystem": "hfs",
            "diskBacked": False,
            "detached": True,
        }
        self.assertFalse(validate(base).disk_backed)
        for key, value in (("diskBacked", True), ("detached", False)):
            invalid = dict(base)
            invalid[key] = value
            with self.assertRaises(CandidateError):
                validate(invalid)


if __name__ == "__main__":
    unittest.main(verbosity=2)
