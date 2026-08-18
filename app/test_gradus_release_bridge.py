#!/usr/bin/env python3
"""Hermetic tests for the Gradus broker bridge."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "gradus_release_bridge", ROOT / "app" / "gradus_release_bridge.py"
)
assert SPEC and SPEC.loader
BRIDGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BRIDGE)


class BridgeTests(unittest.TestCase):
    def test_parser_is_closed_and_rejects_shell_candidate(self) -> None:
        with self.assertRaises(ValueError):
            BRIDGE.dispatch("upload", product="gradus-ios", candidate="x;touch /tmp/no")

    def test_identity_reuses_valid_proof_without_second_call(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            proof = {
                "proofVersion": "1.0.0",
                "operationClass": "identityAllocation",
                "result": "passed",
                "productKey": "gradus-ios",
                "marketingVersion": "1.6.7",
                "buildNumber": 19,
                "responseSha256": "a" * 64,
                "remoteHighestMarketingVersion": "1.6.7",
                "remoteHighestBuildNumber": 18,
                "observedAt": "2026-08-13T00:00:00Z",
            }
            with (
                patch.object(BRIDGE, "IDENTITY_PROOF", Path(temporary) / "allocate.json"),
                patch.object(BRIDGE, "ROOT", Path(temporary)),
                patch.object(BRIDGE, "_current_marketing_version", return_value="1.6.7"),
            ):
                BRIDGE.IDENTITY_PROOF.write_text(json.dumps(proof), encoding="utf-8")

                def runner(*args, **kwargs):
                    raise AssertionError("reran allocator")

                self.assertEqual(
                    BRIDGE.dispatch(
                        "identity-allocation", product="gradus-ios", candidate=None, runner=runner
                    ),
                    0,
                )

    def test_identity_archives_prior_train_before_allocating_current_train(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            proof_path = root / "evidence" / "allocate.json"
            prior = {
                "proofVersion": "1.0.0",
                "operationClass": "identityAllocation",
                "result": "passed",
                "productKey": "gradus-ios",
                "marketingVersion": "1.7.0",
                "buildNumber": 19,
                "responseSha256": "a" * 64,
                "remoteHighestMarketingVersion": "1.7.0",
                "remoteHighestBuildNumber": 18,
                "observedAt": "2026-08-13T00:00:00Z",
            }
            current = dict(prior, marketingVersion="1.8.0", buildNumber=20)
            current["remoteHighestBuildNumber"] = 19
            proof_path.parent.mkdir(parents=True)
            proof_path.write_text(json.dumps(prior), encoding="utf-8")

            def runner(*args, **kwargs):
                proof_path.write_text(json.dumps(current), encoding="utf-8")
                return subprocess.CompletedProcess(args[0], 0, "", "")

            with (
                patch.object(BRIDGE, "IDENTITY_PROOF", proof_path),
                patch.object(BRIDGE, "EVIDENCE_ROOT", root / "evidence"),
                patch.object(BRIDGE, "ROOT", root),
                patch.object(BRIDGE, "_current_marketing_version", return_value="1.8.0"),
            ):
                self.assertEqual(
                    BRIDGE.dispatch(
                        "identity-allocation", product="gradus-ios", candidate=None, runner=runner
                    ),
                    0,
                )

            archived = list((root / "evidence" / "archive").glob("*.json"))
            self.assertEqual(len(archived), 1)
            self.assertEqual(json.loads(archived[0].read_text()), prior)
            self.assertEqual(json.loads(proof_path.read_text()), current)

    def test_unsupported_operation_writes_blocked_proof(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with (
                patch.object(BRIDGE, "ROOT", root),
                patch.object(BRIDGE, "EVIDENCE_ROOT", root / "evidence"),
            ):
                status = BRIDGE.dispatch(
                    "processing", product="gradus-ios", candidate="gradus-ios-19"
                )
                self.assertEqual(status, 3)
                proof = json.loads(
                    (root / "evidence" / "gradus-ios-19" / "processing.json").read_text()
                )
                self.assertEqual(proof["result"], "blocked")

    def test_upload_dispatch_is_candidate_bound_and_shell_free(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record_path = root / ".release-state" / "candidate.json"
            record_path.parent.mkdir(parents=True)
            record_path.write_text(
                json.dumps({"candidateId": "gradus-ios-19", "build": 19}), encoding="utf-8"
            )
            calls = []

            def runner(argv, **kwargs):
                calls.append((argv, kwargs))
                return subprocess.CompletedProcess(argv, 0, "", "")

            with (
                patch.object(BRIDGE, "ROOT", root),
                patch.object(BRIDGE, "ARCHIVE", root / "archive.sh"),
                patch.object(BRIDGE, "EVIDENCE_ROOT", root / "evidence"),
            ):
                self.assertEqual(
                    BRIDGE.dispatch(
                        "upload", product="gradus-ios", candidate="gradus-ios-19", runner=runner
                    ),
                    3,
                )
            self.assertEqual(calls[0][0][1:], ["--upload-only", "--candidate", "gradus-ios-19"])
            self.assertFalse(calls[0][1]["shell"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
