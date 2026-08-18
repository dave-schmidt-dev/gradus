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

    # -- tester group confirmation --------------------------------------------

    @staticmethod
    def _groups(*entries: tuple[str, str, bool]) -> dict:
        return {
            "data": [
                {
                    "id": group_id,
                    "attributes": {
                        "name": name,
                        "isInternalGroup": internal,
                        "hasAccessToAllBuilds": True,
                    },
                }
                for group_id, name, internal in entries
            ]
        }

    @staticmethod
    def _confirm(root: Path, group_id: str, group_name: str) -> None:
        record = root / ".release" / "tester-group.json"
        record.parent.mkdir(parents=True, exist_ok=True)
        record.write_text(
            json.dumps({"groupId": group_id, "groupName": group_name}), encoding="utf-8"
        )

    def test_tester_group_blocks_until_a_group_is_confirmed(self) -> None:
        """Reading the list of groups is not the same act as choosing one."""

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._legacy_candidate(root)
            status, client = self._dispatch_observed(
                "tester-group",
                root,
                [{"data": [{"id": "app-1"}]}, self._groups(("group-1", "Internal Testers", True))],
            )
            self.assertEqual(status, 3)
            proof = json.loads(
                (root / "evidence" / "gradus-ios-19" / "tester-group.json").read_text()
            )
            self.assertEqual(proof["reason"], "tester-group-confirmation-required")
            self.assertEqual(proof["operationClass"], "testerGroup")
            self.assertTrue(all(method == "GET" for method, _path, _body in client.requests))

    def test_tester_group_records_only_confirmation_facts_never_tester_data(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._legacy_candidate(root)
            groups = self._groups(("group-1", "Internal Testers", True))
            # Apple returns far more than the operator needs; none of it may land.
            groups["data"][0]["attributes"]["betaTesters"] = ["tester@example.com"]
            groups["data"][0]["relationships"] = {"betaTesters": {"data": [{"id": "tester-1"}]}}
            self._dispatch_observed("tester-group", root, [{"data": [{"id": "app-1"}]}, groups])
            choices = json.loads(
                (root / "evidence" / "gradus-ios-19" / "tester-group-choices.json").read_text()
            )
            self.assertEqual(len(choices["internalGroups"]), 1)
            self.assertEqual(
                set(choices["internalGroups"][0]),
                {"groupId", "groupName", "hasAccessToAllBuilds"},
            )
            self.assertNotIn("tester@example.com", json.dumps(choices))

    def test_tester_group_passes_only_on_an_exact_confirmed_match(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._legacy_candidate(root)
            self._confirm(root, "group-1", "Internal Testers")
            status, client = self._dispatch_observed(
                "tester-group",
                root,
                [{"data": [{"id": "app-1"}]}, self._groups(("group-1", "Internal Testers", True))],
            )
            self.assertEqual(status, 0)
            self.assertTrue(all(method == "GET" for method, _path, _body in client.requests))
            proof = json.loads(
                (root / "evidence" / "gradus-ios-19" / "tester-group.json").read_text()
            )
            self.assertEqual(proof["result"], "passed")
            self.assertEqual(proof["operationClass"], "testerGroup")
            self.assertRegex(proof["groupIdentifierHash"], r"^[0-9a-f]{64}$")
            # The proof binds the choice; it does not republish the identifier.
            self.assertNotIn("group-1", json.dumps(proof))

    def test_tester_group_blocks_when_the_confirmed_group_no_longer_matches(self) -> None:
        """A renamed or newly added group invalidates the recorded confirmation."""

        cases = {
            "renamed": (self._groups(("group-1", "Renamed Testers", True)),),
            "second-internal-group": (
                self._groups(("group-1", "Internal Testers", True), ("group-2", "Others", True)),
            ),
            "different-identifier": (self._groups(("group-9", "Internal Testers", True)),),
        }
        for label, (groups,) in cases.items():
            with self.subTest(case=label), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self._legacy_candidate(root)
                self._confirm(root, "group-1", "Internal Testers")
                status, _client = self._dispatch_observed(
                    "tester-group", root, [{"data": [{"id": "app-1"}]}, groups]
                )
                self.assertEqual(status, 3)
                proof = json.loads(
                    (root / "evidence" / "gradus-ios-19" / "tester-group.json").read_text()
                )
                self.assertEqual(proof["reason"], "confirmed-tester-group-is-not-the-only-one")

    def test_tester_group_ignores_external_groups(self) -> None:
        """An external group must never satisfy an internal-group confirmation."""

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._legacy_candidate(root)
            self._confirm(root, "group-2", "Public Beta")
            status, _client = self._dispatch_observed(
                "tester-group",
                root,
                [
                    {"data": [{"id": "app-1"}]},
                    self._groups(
                        ("group-1", "Internal Testers", True), ("group-2", "Public Beta", False)
                    ),
                ],
            )
            self.assertEqual(status, 3)
            choices = json.loads(
                (root / "evidence" / "gradus-ios-19" / "tester-group-choices.json").read_text()
            )
            self.assertEqual([g["groupId"] for g in choices["internalGroups"]], ["group-1"])

    @staticmethod
    def _central_candidate(root: Path, *, state: str, receipt: dict | None = None) -> str:
        """Write a central manifest plus the legacy ledger it must bind to.

        Returns the artifact digest so a caller can build a receipt that either
        matches those exact bytes or deliberately does not.
        """

        artifact = "a" * 64
        central = root / ".git" / "release-state" / "gradus-ios" / "candidates" / "1.8.0-20"
        central.mkdir(parents=True)
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
        workspace = root / ".release-state" / "candidates" / "gradus-ios-20"
        legacy = root / ".release-state" / "candidate.json"
        legacy.parent.mkdir(parents=True, exist_ok=True)
        legacy.write_text(
            json.dumps(
                {
                    "candidateId": "gradus-ios-20",
                    "state": state,
                    "marketingVersion": "1.8.0",
                    "build": 20,
                    "artifactSha256": artifact,
                    "metadata": {"candidateWorkspace": str(workspace)},
                }
            ),
            encoding="utf-8",
        )
        if receipt is not None:
            workspace.mkdir(parents=True, exist_ok=True)
            (workspace / "upload-delivery.json").write_text(json.dumps(receipt), encoding="utf-8")
        return artifact

    def test_binding_survives_every_state_that_follows_delivery(self) -> None:
        """A candidate keeps resolving once its transfer has begun.

        Binding only to ``prepared`` stranded a delivered candidate: the ledger
        advances the moment the transfer starts, so every operation that runs
        after upload lost the very binding it needed to observe the build.
        """

        for state in ("prepared", "uploading", "uploaded_unassigned", "assigned"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                artifact = self._central_candidate(root, state=state)
                with patch.object(BRIDGE, "ROOT", root):
                    binding = BRIDGE._candidate_bindings("1.8.0-20")
                self.assertIsNotNone(binding, f"{state} lost its legacy binding")
                self.assertEqual(
                    (binding[0], binding[2], binding[3], binding[4]),
                    ("gradus-ios-20", "1.8.0", 20, artifact),
                )

    def test_binding_refuses_a_candidate_that_is_no_longer_current(self) -> None:
        """Recovery and replacement states must not resolve.

        These records still carry a matching digest, so digest equality alone
        would happily bind them.  They describe a candidate nobody should
        attest, which is a decision about state and not about bytes.
        """

        for state in ("draft", "validated", "failed", "abandoned", "superseded"):
            with self.subTest(state=state), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self._central_candidate(root, state=state)
                with patch.object(BRIDGE, "ROOT", root):
                    self.assertIsNone(BRIDGE._candidate_bindings("1.8.0-20"))

    def test_upload_adopts_a_delivery_apple_already_accepted(self) -> None:
        """A receipt for these exact bytes passes without re-running transport.

        Apple refuses a duplicate build number, so a second transfer of a
        delivered candidate cannot succeed.  The runner is a trap here: reaching
        it at all would mean the bridge chose a transfer that is certain to fail.
        """

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            artifact = self._central_candidate(
                root,
                state="uploading",
                receipt={
                    "candidateId": "gradus-ios-20",
                    "build": 20,
                    "artifactSha256": "a" * 64,
                    "result": "delivered",
                },
            )

            def runner(argv, **kwargs):
                raise AssertionError("re-sent a build Apple had already accepted")

            with (
                patch.object(BRIDGE, "ROOT", root),
                patch.object(BRIDGE, "ARCHIVE", root / "archive.sh"),
                patch.object(BRIDGE, "EVIDENCE_ROOT", root / "evidence"),
            ):
                status = BRIDGE.dispatch(
                    "upload", product="gradus-ios", candidate="1.8.0-20", runner=runner
                )
            self.assertEqual(status, 0)
            proof = json.loads((root / "evidence" / "1.8.0-20" / "upload.json").read_text())
            self.assertEqual(proof["result"], "passed")
            self.assertEqual(proof["uploadedBuildIdentifier"], "1.8.0 (20)")
            self.assertEqual(proof["signedArtifactSha256"], artifact)

    def test_upload_never_adopts_a_receipt_describing_other_bytes(self) -> None:
        """Adoption requires every field to agree, not merely to look close.

        Each variant below is a receipt that is wrong in exactly one way.  A
        near-match is not a weaker match: adopting one would attest a build that
        was never sent, so the bridge must fall through to the transport.
        """

        variants = {
            "different-digest": {"artifactSha256": "b" * 64},
            "different-build": {"build": 21},
            "different-candidate": {"candidateId": "gradus-ios-19"},
            "not-delivered": {"result": "failed"},
            "build-as-bool": {"build": True},
        }
        for name, override in variants.items():
            with self.subTest(variant=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                receipt = {
                    "candidateId": "gradus-ios-20",
                    "build": 20,
                    "artifactSha256": "a" * 64,
                    "result": "delivered",
                }
                receipt.update(override)
                self._central_candidate(root, state="uploading", receipt=receipt)
                calls = []

                def runner(argv, **kwargs):
                    calls.append(argv)
                    return subprocess.CompletedProcess(argv, 1, "", "refused")

                with (
                    patch.object(BRIDGE, "ROOT", root),
                    patch.object(BRIDGE, "ARCHIVE", root / "archive.sh"),
                    patch.object(BRIDGE, "EVIDENCE_ROOT", root / "evidence"),
                ):
                    status = BRIDGE.dispatch(
                        "upload", product="gradus-ios", candidate="1.8.0-20", runner=runner
                    )
                self.assertEqual(status, 3, f"{name} was adopted")
                self.assertEqual(len(calls), 1, f"{name} skipped the transport")


if __name__ == "__main__":
    unittest.main(verbosity=2)
