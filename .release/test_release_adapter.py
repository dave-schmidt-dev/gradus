#!/usr/bin/env python3
"""Hermetic Gradus adapter and plan contract checks."""

from __future__ import annotations

import copy
import hashlib
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "apple_developer"))

from release_tools import load_workflow_spec
from release_tools.adapter import adapter_rejection_codes, load_adapter
from release_tools.conformance import audit_conformance

ROOT = Path(__file__).resolve().parents[1]
ADAPTER = ROOT / ".release" / "release-adapter.json"
PLAN = ROOT / ".release" / "release-plan.json"
BROKER_REQUEST = ROOT / ".release" / "broker-consumer-request.json"


class GradusAdapterTests(unittest.TestCase):
    def test_adapter_and_plan_are_conformant_without_running_tools(self) -> None:
        document = json.loads(ADAPTER.read_text(encoding="utf-8"))
        self.assertEqual(adapter_rejection_codes(document), ())
        loaded = load_adapter(document, repository_root=ROOT)
        self.assertEqual(loaded.product["productKey"], "gradus-ios")
        report = audit_conformance(adapter_path=ADAPTER, plan_path=PLAN, repository_root=ROOT)
        self.assertEqual(report["status"], "passed", report)
        self.assertEqual(report["adoptionStatus"], "adoption-authorized")
        descriptor_digest = hashlib.sha256(BROKER_REQUEST.read_bytes()).hexdigest()
        self.assertEqual(
            document["registeredConsumers"][0]["evidence"]["descriptorSha256"],
            descriptor_digest,
        )

    def test_typed_proof_paths_bind_identity_before_candidate_and_later_proofs_to_candidate(
        self,
    ) -> None:
        document = json.loads(ADAPTER.read_text(encoding="utf-8"))
        plan = json.loads(PLAN.read_text(encoding="utf-8"))
        self.assertIn("bash", document["operations"][2]["argv"])
        self.assertIn("app/test-gate.sh", document["operations"][2]["argv"])
        evidence_paths = {entry["name"]: entry["path"] for entry in document["evidencePaths"]}
        self.assertEqual(
            evidence_paths["allocate-identity-proof"],
            ".release-state/evidence/allocate-identity.json",
        )
        self.assertNotIn("{candidateId}", evidence_paths["allocate-identity-proof"])
        self.assertTrue(
            all(
                "{candidateId}" in path
                for name, path in evidence_paths.items()
                if name != "allocate-identity-proof"
            )
        )
        plan_paths = {
            entry["operationClass"]: entry["evidencePath"] for entry in plan["obligations"]
        }
        self.assertEqual(
            plan_paths["identityAllocation"], evidence_paths["allocate-identity-proof"]
        )
        self.assertTrue(
            all(
                "{candidateId}" in path
                for operation_class, path in plan_paths.items()
                if operation_class != "identityAllocation"
            )
        )
        self.assertEqual(len(evidence_paths), len(set(evidence_paths)))
        for operation in document["operations"]:
            serialized = json.dumps(operation, sort_keys=True)
            self.assertNotRegex(serialized, r"(?i)(secret|token|password|private.key)")
            self.assertNotIn("command", operation)
            if operation["mode"] == "nonCredential":
                self.assertFalse(operation["environment"]["inherit"])
                self.assertIsInstance(operation["argv"], list)
            elif operation["mode"] == "credential":
                self.assertIsInstance(operation["arguments"], list)

    def test_identity_and_credential_argv_are_fixed_and_candidate_bound_only_after_allocation(
        self,
    ) -> None:
        adapter = json.loads(ADAPTER.read_text(encoding="utf-8"))
        plan = json.loads(PLAN.read_text(encoding="utf-8"))
        operations = {entry["class"]: entry for entry in adapter["operations"]}
        obligations = {entry["operationClass"]: entry for entry in plan["obligations"]}
        expected_identity = ["--operation", "identity-allocation", "--product", "gradus-ios"]
        self.assertEqual(operations["identityAllocation"]["arguments"], expected_identity)
        self.assertEqual(
            obligations["identityAllocation"]["command"],
            ["bws-secret-exec", "gradus-app-store-connect-bridge", "--", *expected_identity],
        )
        operation_ids = {
            "upload": "upload",
            "processing": "processing",
            "compliance": "compliance",
            "testerGroup": "tester-group",
            "assignment": "assignment",
            "deviceHealth": "device-health",
            "notification": "notification",
        }
        for operation_class, operation_id in operation_ids.items():
            expected = [
                "--operation",
                operation_id,
                "--product",
                "gradus-ios",
                "--candidate",
                "{candidateId}",
            ]
            self.assertEqual(operations[operation_class]["arguments"], expected)
            self.assertEqual(
                obligations[operation_class]["command"],
                ["bws-secret-exec", "gradus-app-store-connect-bridge", "--", *expected],
            )

    def test_operation_graph_uses_central_profile_classes_and_predecessors(self) -> None:
        document = json.loads(ADAPTER.read_text(encoding="utf-8"))
        operations = {entry["class"]: entry for entry in document["operations"]}
        expected = [
            ("identityAllocation", []),
            ("sourceSnapshot", ["allocate-identity"]),
            ("readiness", ["source-snapshot"]),
            ("localGate", ["readiness"]),
            ("productionReleaseBuild", ["local-gate"]),
            ("archive", ["production-build"]),
            ("sign", ["archive"]),
            ("artifactVerify", ["sign"]),
            ("upload", ["artifact-verify"]),
            ("processing", ["upload"]),
            ("compliance", ["processing"]),
            ("testerGroup", ["compliance"]),
            ("assignment", ["tester-group"]),
            ("deviceHealth", ["assignment"]),
            ("notification", ["device-health"]),
            ("receipt", ["notification"]),
        ]
        self.assertEqual(
            [
                (operation_class, operations[operation_class]["dependencies"])
                for operation_class, _ in expected
            ],
            expected,
        )

    def test_typed_proof_fixture_has_every_workflow_field_and_binding(self) -> None:
        document = json.loads(ADAPTER.read_text(encoding="utf-8"))
        schemas = load_workflow_spec()["core"]["proofSchemas"]
        candidate = "gradus-ios-18-a4acb3118b78faff"
        source = "a" * 64
        artifact = "b" * 64
        uploaded = "gradus-ios-build-18"
        common = {"proofVersion": "1.0.0", "result": "passed"}
        for operation in document["operations"]:
            operation_class = operation["class"]
            required = schemas[operation["proofSchema"]]["required"]
            proof = dict(common, operationClass=operation_class)
            values = {
                "candidateId": candidate,
                "sourceDigest": source,
                "artifactSha256": artifact,
                "archiveSha256": artifact,
                "signedArtifactSha256": artifact,
                "uploadedBuildIdentifier": uploaded,
                "responseSha256": "c" * 64,
                "metadataSha256": "d" * 64,
                "evidenceSha256": "e" * 64,
                "manifestSha256": "f" * 64,
                "policyVersion": "1.0.0",
                "entryCount": 1,
                "marketingVersion": "1.6.7",
                "buildNumber": 18,
                "configuration": "Production",
                "installMode": "candidate",
                "groupIdentifierHash": "1" * 64,
                "lane": "standard",
                "observedAt": "2026-08-12T00:00:00Z",
                "issuedAt": "2026-08-12T00:00:00Z",
                "expiresAt": "2026-08-13T00:00:00Z",
                "deliveryReceiptSha256": "2" * 64,
                "receiptSha256": "3" * 64,
            }
            proof.update({field: values[field] for field in required if field in values})
            self.assertTrue(set(required) <= set(proof), operation_class)
            if "candidateId" in required:
                self.assertEqual(proof["candidateId"], candidate)
            if "sourceDigest" in required:
                self.assertEqual(proof["sourceDigest"], source)
            if "artifactSha256" in required or "signedArtifactSha256" in required:
                self.assertIn(artifact, proof.values())
            if "uploadedBuildIdentifier" in required:
                self.assertEqual(proof["uploadedBuildIdentifier"], uploaded)

    def test_adapter_rejects_secret_names_shell_strings_executables_and_routes(self) -> None:
        document = json.loads(ADAPTER.read_text(encoding="utf-8"))
        secret = copy.deepcopy(document)
        secret["environmentInputs"].append(
            {"name": "ASC_API_KEY", "required": True, "source": "caller"}
        )
        self.assertIn("adapter-secret-selection-forbidden", adapter_rejection_codes(secret))

        executable = copy.deepcopy(document)
        executable["operations"][0]["executable"] = "/bin/sh"
        self.assertIn(
            "adapter-credential-executable-forbidden", adapter_rejection_codes(executable)
        )

        shell = copy.deepcopy(document)
        shell["operations"][2]["command"] = "bash app/test-gate.sh"
        self.assertIn("adapter-shell-string-forbidden", adapter_rejection_codes(shell))

        route = copy.deepcopy(document)
        route["operations"][2]["providerRoute"] = "external-provider"
        self.assertIn("adapter-unknown-field", adapter_rejection_codes(route))

    def test_wrappers_are_fixed_and_executable(self) -> None:
        for name in ("release-testflight", "release-status"):
            path = ROOT / "app" / name
            self.assertTrue(path.is_file())
            self.assertTrue(path.stat().st_mode & 0o111)
            source = path.read_text(encoding="utf-8")
            self.assertIn('git -C "$ROOT" rev-parse --show-toplevel', source)
            self.assertNotRegex(source, r"(?i)(--executable|secretNames)")
            self.assertNotIn('"$@"', source)
            self.assertIn("../apple_developer", source)
            self.assertIn("python3", source)
            self.assertNotIn("archive-upload-ios.sh", source)
            if name == "release-testflight":
                self.assertIn("-m release_tools testflight", source)
                self.assertIn('--adapter "$ADAPTER" --repository "$ROOT"', source)
            else:
                self.assertIn("-m release_tools status", source)
            if name == "release-status":
                self.assertIn("[[ $# -eq 0 ]]", source)
            else:
                self.assertIn("[[ $# -eq 1 ]]", source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
