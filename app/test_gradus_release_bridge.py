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


class _RecordingClient:
    """Injectable stand-in that replays fixed responses and records every call.

    Recording the HTTP method is the point: it is what lets a test assert that
    an observation stayed an observation and never mutated anything at Apple.
    """

    def __init__(self, responses: list) -> None:
        self._responses = list(responses)
        self.requests: list[tuple] = []

    def request(self, method: str, path: str, body: dict | None = None, **_kwargs) -> dict | None:
        self.requests.append((method, path, body))
        if not self._responses:
            raise AssertionError("unexpected additional App Store Connect request")
        return self._responses.pop(0)


class BridgeTests(unittest.TestCase):
    def test_prepare_only_freezes_then_stages_without_upload(self) -> None:
        wrapper = (ROOT / "app" / "release-testflight").read_text(encoding="utf-8")
        prepare_branch = wrapper.split("--prepare-only)", 1)[1].split("--upload)", 1)[0]
        self.assertIn("-m release_tools testflight", prepare_branch)
        self.assertIn("-m release_tools stage", prepare_branch)
        self.assertIn('READINESS_MANIFEST="$readiness_manifest"', prepare_branch)
        self.assertIn('--candidate "$candidate"', prepare_branch)
        self.assertNotIn("--upload", prepare_branch)

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
                    "notification", product="gradus-ios", candidate="gradus-ios-19"
                )
                self.assertEqual(status, 3)
                proof = json.loads(
                    (root / "evidence" / "gradus-ios-19" / "notification.json").read_text()
                )
                self.assertEqual(proof["result"], "blocked")

    def test_upload_dispatch_is_candidate_bound_and_shell_free(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record_path = root / ".release-state" / "candidate.json"
            record_path.parent.mkdir(parents=True)
            record_path.write_text(
                json.dumps(
                    {
                        "candidateId": "gradus-ios-19",
                        "marketingVersion": "1.7.0",
                        "build": 19,
                        "artifactSha256": "a" * 64,
                    }
                ),
                encoding="utf-8",
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

    def test_upload_resolves_central_candidate_to_exact_legacy_tuple(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            central = root / ".git" / "release-state" / "gradus-ios" / "candidates" / "1.8.0-20"
            central.mkdir(parents=True)
            artifact = "a" * 64
            (central / "manifest.json").write_text(
                json.dumps(
                    {
                        "candidateId": "1.8.0-20",
                        "release": {"marketingVersion": "1.8.0", "buildNumber": "20"},
                        "artifactAttestation": {"path": "artifact-attestation.json"},
                    }
                ),
                encoding="utf-8",
            )
            (central / "artifact-attestation.json").write_text(
                json.dumps({"candidateId": "1.8.0-20", "artifactSha256": artifact}),
                encoding="utf-8",
            )
            legacy = root / ".release-state" / "candidate.json"
            legacy.parent.mkdir(parents=True)
            legacy.write_text(
                json.dumps(
                    {
                        "candidateId": "gradus-ios-20",
                        "state": "prepared",
                        "marketingVersion": "1.8.0",
                        "build": 20,
                        "artifactSha256": artifact,
                    }
                ),
                encoding="utf-8",
            )
            calls = []

            def runner(argv, **kwargs):
                calls.append(argv)
                return subprocess.CompletedProcess(
                    argv,
                    0,
                    "==> Done. Candidate gradus-ios-20 build 20 uploaded -- Apple will take a few minutes to process it.\n",
                    "",
                )

            with (
                patch.object(BRIDGE, "ROOT", root),
                patch.object(BRIDGE, "ARCHIVE", root / "archive.sh"),
                patch.object(BRIDGE, "EVIDENCE_ROOT", root / "evidence"),
            ):
                self.assertEqual(
                    BRIDGE.dispatch(
                        "upload", product="gradus-ios", candidate="1.8.0-20", runner=runner
                    ),
                    0,
                )
            self.assertEqual(
                calls, [[str(root / "archive.sh"), "--upload-only", "--candidate", "gradus-ios-20"]]
            )
            proof = json.loads((root / "evidence" / "1.8.0-20" / "upload.json").read_text())
            self.assertEqual(proof["result"], "passed")
            self.assertEqual(proof["candidateId"], "1.8.0-20")
            self.assertEqual(proof["signedArtifactSha256"], artifact)
            self.assertEqual(proof["uploadedBuildIdentifier"], "1.8.0 (20)")

    def test_upload_rejects_ambiguous_legacy_binding_without_invoking_uploader(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            central = root / ".git" / "release-state" / "gradus-ios" / "candidates" / "1.8.0-20"
            central.mkdir(parents=True)
            artifact = "b" * 64
            (central / "manifest.json").write_text(
                json.dumps(
                    {
                        "candidateId": "1.8.0-20",
                        "release": {"marketingVersion": "1.8.0", "buildNumber": "20"},
                        "artifactAttestation": {"path": "artifact-attestation.json"},
                    }
                ),
                encoding="utf-8",
            )
            (central / "artifact-attestation.json").write_text(
                json.dumps({"candidateId": "1.8.0-20", "artifactSha256": artifact}),
                encoding="utf-8",
            )
            ledgers = root / ".release-state" / "candidates"
            for legacy_id in ("gradus-ios-20-a", "gradus-ios-20-b"):
                path = ledgers / legacy_id / "candidate.json"
                path.parent.mkdir(parents=True)
                path.write_text(
                    json.dumps(
                        {
                            "candidateId": legacy_id,
                            "state": "prepared",
                            "marketingVersion": "1.8.0",
                            "build": 20,
                            "artifactSha256": artifact,
                        }
                    ),
                    encoding="utf-8",
                )

            def runner(*args, **kwargs):
                raise AssertionError("uploader invoked")

            with (
                patch.object(BRIDGE, "ROOT", root),
                patch.object(BRIDGE, "EVIDENCE_ROOT", root / "evidence"),
            ):
                self.assertEqual(
                    BRIDGE.dispatch(
                        "upload", product="gradus-ios", candidate="1.8.0-20", runner=runner
                    ),
                    3,
                )

    def test_adopted_delivery_stdout_yields_exactly_one_upload_identifier(self):
        """The adopt path's own stdout must parse to exactly one identifier.

        The shell announces an adopted delivery with two lines that name the same
        candidate and build, and only the second one says "uploaded".
        ``_uploaded_build_identifier`` returns None unless it finds exactly one
        match, so rewording the first line into something that also matched would
        silently downgrade an adopted delivery to a blocked operation -- the exact
        stuck state the receipt exists to prevent. The lines are lifted out of the
        script instead of retyped so this checks what actually ships.
        """

        lines = (
            (Path(__file__).resolve().parent / "archive-upload-ios.sh")
            .read_text(encoding="utf-8")
            .splitlines()
        )
        anchors = [
            index
            for index, line in enumerate(lines)
            if "already delivered to App Store Connect; adopting" in line
        ]
        self.assertEqual(len(anchors), 1, "adopt path announcement is no longer unique")
        echoes = lines[anchors[0] : anchors[0] + 2]

        stdout = []
        for line in echoes:
            body = line.strip()
            self.assertTrue(body.startswith('echo "') and body.endswith('"'), body)
            stdout.append(
                body[len('echo "') : -1]
                .replace("$candidate_id", "gradus-ios-20")
                .replace("$NEXT_BUILD", "20")
            )
        self.assertIn("uploaded", stdout[1])

        self.assertEqual(
            BRIDGE._uploaded_build_identifier(
                "\n".join(stdout),
                legacy_candidate="gradus-ios-20",
                marketing_version="1.8.0",
                build=20,
            ),
            "1.8.0 (20)",
        )

    # -- processing and compliance observation --------------------------------

    @staticmethod
    def _legacy_candidate(root: Path, *, uploaded: bool = True) -> None:
        """Write the minimum ledger and upload proof the observers require."""

        record = root / ".release-state" / "candidate.json"
        record.parent.mkdir(parents=True, exist_ok=True)
        record.write_text(
            json.dumps(
                {
                    "candidateId": "gradus-ios-19",
                    "marketingVersion": "1.7.0",
                    "build": 19,
                    "artifactSha256": "a" * 64,
                }
            ),
            encoding="utf-8",
        )
        if uploaded:
            proof = root / "evidence" / "gradus-ios-19" / "upload.json"
            proof.parent.mkdir(parents=True, exist_ok=True)
            proof.write_text(
                json.dumps(
                    {
                        "result": "passed",
                        "candidateId": "gradus-ios-19",
                        "uploadedBuildIdentifier": "1.7.0 (19)",
                    }
                ),
                encoding="utf-8",
            )

    @staticmethod
    def _builds(build: int, processing: str, compliance: str | None = None) -> dict:
        attributes = {"version": str(build), "processingState": processing}
        if compliance is not None:
            attributes["complianceState"] = compliance
        return {"data": [{"id": "build-1", "attributes": attributes}]}

    def _dispatch_observed(self, operation: str, root: Path, responses: list, **kwargs) -> tuple:
        client = _RecordingClient(responses)
        with (
            patch.object(BRIDGE, "ROOT", root),
            patch.object(BRIDGE, "EVIDENCE_ROOT", root / "evidence"),
        ):
            status = BRIDGE.dispatch(
                operation,
                product="gradus-ios",
                candidate="gradus-ios-19",
                client=client,
                sleep=lambda _seconds: None,
                **kwargs,
            )
        return status, client

    def test_processing_attests_only_after_apple_reports_valid(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._legacy_candidate(root)
            status, client = self._dispatch_observed(
                "processing",
                root,
                [
                    {"data": [{"id": "app-1"}]},
                    self._builds(19, "PROCESSING"),
                    self._builds(19, "VALID", "COMPLIANT"),
                ],
            )
            self.assertEqual(status, 0)
            # Three calls means the observer really waited instead of attesting
            # the first state it saw.
            self.assertEqual(len(client.requests), 3)
            proof = json.loads(
                (root / "evidence" / "gradus-ios-19" / "processing.json").read_text()
            )
            self.assertEqual(proof["result"], "passed")
            self.assertEqual(proof["operationClass"], "processing")
            self.assertEqual(proof["uploadedBuildIdentifier"], "1.7.0 (19)")
            self.assertEqual(proof["processingState"], "VALID")
            self.assertRegex(proof["responseSha256"], r"^[0-9a-f]{64}$")

    def test_processing_blocks_immediately_on_terminal_apple_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._legacy_candidate(root)
            status, client = self._dispatch_observed(
                "processing",
                root,
                [{"data": [{"id": "app-1"}]}, self._builds(19, "INVALID")],
            )
            self.assertEqual(status, 3)
            # A rejected build must not burn the full polling timeout.
            self.assertEqual(len(client.requests), 2)
            proof = json.loads(
                (root / "evidence" / "gradus-ios-19" / "processing.json").read_text()
            )
            self.assertEqual(proof["reason"], "build-processing-invalid")

    def test_observation_blocks_without_requesting_a_credential(self) -> None:
        """A locally-decidable block must not reach for the App Store Connect key.

        Blocking because this candidate has no upload proof is a decision made
        entirely from local state.  If the client were constructed first, that
        purely local answer would still demand a credential, which is the same
        mistake the upload adopt path exists to avoid.
        """

        for operation in ("processing", "compliance"):
            with self.subTest(operation=operation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self._legacy_candidate(root, uploaded=False)

                def explode() -> object:
                    raise AssertionError("credential requested for a local block")

                with (
                    patch.object(BRIDGE, "ROOT", root),
                    patch.object(BRIDGE, "EVIDENCE_ROOT", root / "evidence"),
                    patch.object(BRIDGE, "_default_client", explode),
                ):
                    self.assertEqual(
                        BRIDGE.dispatch(operation, product="gradus-ios", candidate="gradus-ios-19"),
                        3,
                    )
                proof = json.loads(
                    (root / "evidence" / "gradus-ios-19" / f"{operation}.json").read_text()
                )
                self.assertEqual(proof["reason"], "uploaded-build-identifier-unavailable")

    def test_compliance_blocks_on_missing_compliance_and_never_declares(self) -> None:
        """Export compliance is a legal declaration, so the bridge only reads it."""

        for field, state in (
            ("processingState", "MISSING_COMPLIANCE"),
            ("complianceState", "MISSING_COMPLIANCE"),
        ):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self._legacy_candidate(root)
                attributes = {"version": "19", "processingState": "VALID"}
                attributes[field] = state
                status, client = self._dispatch_observed(
                    "compliance",
                    root,
                    [
                        {"data": [{"id": "app-1"}]},
                        {"data": [{"id": "build-1", "attributes": attributes}]},
                    ],
                )
                self.assertEqual(status, 3)
                proof = json.loads(
                    (root / "evidence" / "gradus-ios-19" / "compliance.json").read_text()
                )
                self.assertEqual(proof["reason"], "export-compliance-attention-required")
                self.assertEqual(
                    [method for method, _path, _body in client.requests], ["GET", "GET"]
                )

    def test_compliance_attests_when_apple_is_not_withholding_the_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._legacy_candidate(root)
            status, client = self._dispatch_observed(
                "compliance",
                root,
                [{"data": [{"id": "app-1"}]}, self._builds(19, "VALID", "COMPLIANT")],
            )
            self.assertEqual(status, 0)
            self.assertTrue(all(method == "GET" for method, _path, _body in client.requests))
            proof = json.loads(
                (root / "evidence" / "gradus-ios-19" / "compliance.json").read_text()
            )
            self.assertEqual(proof["result"], "passed")
            self.assertEqual(proof["operationClass"], "compliance")
            self.assertEqual(proof["complianceState"], "COMPLIANT")

    def test_observation_refuses_an_ambiguous_build_match(self) -> None:
        """Two builds claiming the same version must not be silently narrowed."""

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._legacy_candidate(root)
            duplicated = {
                "data": [
                    {"id": "build-1", "attributes": {"version": "19", "processingState": "VALID"}},
                    {"id": "build-2", "attributes": {"version": "19", "processingState": "VALID"}},
                ]
            }
            status, _client = self._dispatch_observed(
                "compliance", root, [{"data": [{"id": "app-1"}]}, duplicated]
            )
            self.assertEqual(status, 3)
            proof = json.loads(
                (root / "evidence" / "gradus-ios-19" / "compliance.json").read_text()
            )
            self.assertEqual(proof["reason"], "multiple-builds-matched-candidate")

    def test_processing_blocks_when_apple_never_indexes_the_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._legacy_candidate(root)
            status, _client = self._dispatch_observed(
                "processing",
                root,
                [{"data": [{"id": "app-1"}]}, {"data": []}],
                clock=iter([0.0, 10.0]).__next__,
                timeout=1.0,
            )
            self.assertEqual(status, 3)
            proof = json.loads(
                (root / "evidence" / "gradus-ios-19" / "processing.json").read_text()
            )
            self.assertEqual(proof["reason"], "processing-not-confirmed-before-timeout")


if __name__ == "__main__":
    unittest.main(verbosity=2)
