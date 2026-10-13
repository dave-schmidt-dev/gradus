"""Mutation coverage for the diagnostics-aware producer evidence contract."""

from __future__ import annotations

import unittest
from pathlib import Path

from app import publish_evidence_source_contract as contract

ROOT = Path(__file__).resolve().parents[1]


SOURCE_PATH = ROOT / "app/GradusMac/PublishCoordinator.swift"
SOURCE = SOURCE_PATH.read_text(encoding="utf-8")
WRAPPER_CALL = "try await writeProducerEvidenceWithDiagnostics()"


class PublishEvidenceSourceContractTests(unittest.TestCase):
    def assert_rejected(self, source: str) -> None:
        with self.assertRaises(contract.SourceContractError):
            contract.validate_source_contract(source)

    def test_real_coordinator_satisfies_contract(self) -> None:
        contract.validate_source_contract(SOURCE)

    def test_removing_quiet_refresh_is_rejected(self) -> None:
        mutated = SOURCE.replace(WRAPPER_CALL, "", 1)
        self.assertNotEqual(mutated, SOURCE)
        self.assert_rejected(mutated)

    def test_moving_changed_refresh_before_failure_handling_is_rejected(self) -> None:
        success_call = WRAPPER_CALL + '\n        GradusLog.publish.notice("published'
        self.assertEqual(SOURCE.count(success_call), 1)
        mutated = SOURCE.replace(
            success_call,
            '        GradusLog.publish.notice("published',
            1,
        )
        failure_gate = "        if failedRecordCount > 0 {"
        self.assertEqual(mutated.count(failure_gate), 1)
        mutated = mutated.replace(
            failure_gate,
            "        " + WRAPPER_CALL + "\n" + failure_gate,
            1,
        )
        self.assert_rejected(mutated)

    def test_removing_diagnostics_wrapper_delegation_is_rejected(self) -> None:
        delegated = "            try writeProducerEvidenceIfConfigured()\n"
        self.assertEqual(SOURCE.count(delegated), 1)
        self.assert_rejected(SOURCE.replace(delegated, "", 1))

    def test_swallowing_diagnostics_wrapper_error_is_rejected(self) -> None:
        rethrow = (
            "            throw error\n"
            "        }\n"
            "    }\n\n"
            "    private func writeProducerEvidenceIfConfigured"
        )
        self.assertEqual(SOURCE.count(rethrow), 1)
        swallowed = rethrow.replace("            throw error\n", "            return\n", 1)
        self.assert_rejected(SOURCE.replace(rethrow, swallowed, 1))

    def test_replacing_current_timestamp_is_rejected(self) -> None:
        timestamp = "publishedAt: Date()"
        self.assertEqual(SOURCE.count(timestamp), 1)
        self.assert_rejected(SOURCE.replace(timestamp, "publishedAt: Date.distantPast", 1))


if __name__ == "__main__":
    unittest.main()
