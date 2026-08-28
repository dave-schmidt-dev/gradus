#!/usr/bin/env python3
"""Hermetic tests for the Gradus broker bridge."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "gradus_release_bridge", ROOT / "app" / "gradus_release_bridge.py"
)
assert SPEC and SPEC.loader
BRIDGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BRIDGE)

PREPARE_SPEC = importlib.util.spec_from_file_location(
    "release_prepare_bridge", ROOT / "app" / "release_prepare_bridge.py"
)
assert PREPARE_SPEC and PREPARE_SPEC.loader
PREPARE = importlib.util.module_from_spec(PREPARE_SPEC)
sys.modules[PREPARE_SPEC.name] = PREPARE
PREPARE_SPEC.loader.exec_module(PREPARE)


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
    def _release_wrapper_fixture(self, temporary: str) -> tuple[Path, Path, Path]:
        """Create an isolated checkout with a separately located Git common dir."""
        base = Path(temporary).resolve()
        checkout = base / "gradus"
        common_dir = base / "git-common"
        bin_dir = base / "bin"
        wrapper = checkout / "app" / "release-testflight"
        wrapper.parent.mkdir(parents=True)
        shutil.copy2(ROOT / "app" / "release-testflight", wrapper)
        wrapper.chmod(0o755)
        common_dir.mkdir()
        (checkout / ".release").mkdir(parents=True)
        (checkout / ".release" / "release-adapter.json").write_text("{}", encoding="utf-8")

        release_tools = base / "apple_developer" / "release_tools"
        release_tools.mkdir(parents=True)
        (release_tools / "__init__.py").write_text("", encoding="utf-8")
        (release_tools / "product_state.py").write_text(
            "import hashlib, json, os\n"
            "from pathlib import Path\n"
            "def canonical(value):\n"
            "    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()\n"
            "class ProductState:\n"
            "    def __init__(self, home): self.home = Path(home)\n"
            "    @classmethod\n"
            "    def for_repository(cls, repository, product, non_git_home=None):\n"
            "        return cls(Path(os.environ['WRAPPER_COMMON_DIR']) / 'release-state' / product)\n"
            "    @property\n"
            "    def candidates_directory(self): return self.home / 'candidates'\n"
            "    def _active(self):\n"
            "        path = self.home / 'active-candidate.json'\n"
            "        if not path.exists(): return None\n"
            "        if not path.is_file(): raise ValueError('active-candidate-corrupt')\n"
            "        value = json.loads(path.read_text())\n"
            "        body = dict(value) if isinstance(value, dict) else {}\n"
            "        declared = body.pop('pointerSha256', None)\n"
            "        if value.get('formatVersion') != 2 or hashlib.sha256(canonical(body)).hexdigest() != declared:\n"
            "            raise ValueError('active-candidate-corrupt')\n"
            "        return value\n",
            encoding="utf-8",
        )
        (release_tools / "iterative_release.py").write_text(
            "import hashlib, json\n"
            "from pathlib import Path\n"
            "def canonical(value):\n"
            "    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()\n"
            "def read_candidate_ledger_v2(candidate_directory):\n"
            "    directory = Path(candidate_directory)\n"
            "    ledger = directory / 'transitions.jsonl'\n"
            "    if not ledger.exists(): return []\n"
            "    if not ledger.is_file(): raise ValueError('candidate-ledger-unreadable')\n"
            "    records, previous, failure_attempt = [], '0' * 64, 0\n"
            "    for sequence, line in enumerate(ledger.read_text().splitlines(), 1):\n"
            "        record = json.loads(line)\n"
            "        if not line or not isinstance(record, dict) or record.get('formatVersion') != 2 or record.get('sequence') != sequence:\n"
            "            raise ValueError('candidate-ledger-sequence-invalid')\n"
            "        if record.get('candidateId') != directory.name or record.get('previousHash') != previous:\n"
            "            raise ValueError('candidate-ledger-chain-invalid')\n"
            "        declared = record.get('recordHash')\n"
            "        body = dict(record); body.pop('recordHash', None)\n"
            "        if not isinstance(declared, str) or hashlib.sha256(canonical(body)).hexdigest() != declared:\n"
            "            raise ValueError('candidate-ledger-hash-invalid')\n"
            "        if record.get('transition') == 'failed':\n"
            "            failure_attempt += 1\n"
            "            if record.get('attempt') != failure_attempt: raise ValueError('candidate-failure-attempt-invalid')\n"
            "        records.append(record); previous = declared\n"
            "    return records\n",
            encoding="utf-8",
        )
        (release_tools / "__main__.py").write_text(
            "import json\n"
            "import os\n"
            "import sys\n"
            "from pathlib import Path\n"
            "invocations = Path(__file__).with_name('invocations.jsonl')\n"
            "with open(invocations, 'a', encoding='utf-8') as f:\n"
            "    f.write(json.dumps(sys.argv) + '\\n')\n"
            "Path(__file__).with_name('invoked.json').write_text(\n"
            "    json.dumps(sys.argv), encoding='utf-8'\n"
            ")\n"
            "Path(__file__).with_name('readiness-manifest.txt').write_text(\n"
            "    os.environ.get('READINESS_MANIFEST', ''), encoding='utf-8'\n"
            ")\n"
            "if 'testflight' in sys.argv and '--upload' not in sys.argv:\n"
            "    candidate_id = '1.8.1-21' if '--successor-correction' in sys.argv else '1.8.2-22'\n"
            "    print(json.dumps({'candidateId': candidate_id}))\n",
            encoding="utf-8",
        )

        bin_dir.mkdir()
        git = bin_dir / "git"
        git.write_text(
            "#!/bin/sh\n"
            'case "$*" in\n'
            "  *--show-toplevel*) printf '%s\n' \"$WRAPPER_ROOT\" ;;\n"
            "  *--git-common-dir*) printf '%s\n' \"$WRAPPER_COMMON_DIR\" ;;\n"
            "  *) exit 1 ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        git.chmod(0o755)
        return checkout, common_dir, bin_dir

    @staticmethod
    def _canonical_bytes(value: dict) -> bytes:
        return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()

    @classmethod
    def _write_active_pointer(cls, common_dir: Path, candidate: str) -> Path:
        pointer = common_dir / "release-state" / "gradus-ios" / "active-candidate.json"
        pointer.parent.mkdir(parents=True, exist_ok=True)
        value = {
            "candidateId": candidate,
            "formatVersion": 2,
            "releaseTrain": candidate.rsplit("-", 1)[0],
        }
        value["pointerSha256"] = hashlib.sha256(cls._canonical_bytes(value)).hexdigest()
        pointer.write_bytes(cls._canonical_bytes(value) + b"\n")
        return pointer

    @classmethod
    def _write_v2_ledger(cls, candidate_dir: Path, transitions: list[dict]) -> Path:
        candidate_dir.mkdir(parents=True, exist_ok=True)
        ledger = candidate_dir / "transitions.jsonl"
        previous = "0" * 64
        failed_attempt = 0
        records: list[bytes] = []
        for sequence, transition in enumerate(transitions, 1):
            value = {
                "candidateId": candidate_dir.name,
                "details": {},
                "formatVersion": 2,
                "previousHash": previous,
                "recordedAt": "2026-08-23T00:00:00Z",
                "sequence": sequence,
                **transition,
            }
            if value["transition"] == "failed":
                failed_attempt += 1
                value["attempt"] = failed_attempt
            value["recordHash"] = hashlib.sha256(cls._canonical_bytes(value)).hexdigest()
            records.append(cls._canonical_bytes(value))
            previous = value["recordHash"]
        ledger.write_bytes(b"\n".join(records) + (b"\n" if records else b""))
        return ledger

    @staticmethod
    def _run_release_upload(
        checkout: Path, common_dir: Path, bin_dir: Path
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(checkout / "app" / "release-testflight"), "--upload"],
            cwd=checkout,
            env={
                "PATH": f"{bin_dir}:/bin:/usr/bin",
                "WRAPPER_ROOT": str(checkout),
                "WRAPPER_COMMON_DIR": str(common_dir),
            },
            capture_output=True,
            text=True,
            check=False,
        )

    @staticmethod
    def _run_release_prepare(
        checkout: Path, common_dir: Path, bin_dir: Path
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [str(checkout / "app" / "release-testflight"), "--prepare-only"],
            cwd=checkout,
            env={
                "PATH": f"{bin_dir}:/bin:/usr/bin",
                "WRAPPER_ROOT": str(checkout),
                "WRAPPER_COMMON_DIR": str(common_dir),
            },
            capture_output=True,
            text=True,
            check=False,
        )

    def test_prepare_only_freezes_then_stages_without_upload(self) -> None:
        wrapper = (ROOT / "app" / "release-testflight").read_text(encoding="utf-8")
        prepare_branch = wrapper.split("--prepare-only)", 1)[1].split("--upload)", 1)[0]
        self.assertIn("-m release_tools testflight", prepare_branch)
        self.assertIn("-m release_tools stage", prepare_branch)
        self.assertIn('READINESS_MANIFEST="$readiness_manifest"', prepare_branch)
        self.assertIn('--candidate "$candidate"', prepare_branch)
        self.assertNotIn("--upload", prepare_branch)

    def test_prepare_only_uses_the_closed_failed_preupload_correction(self) -> None:
        wrapper = (ROOT / "app" / "release-testflight").read_text(encoding="utf-8")
        prepare_branch = wrapper.split("--prepare-only)", 1)[1].split("--upload)", 1)[0]
        self.assertIn("--successor-correction", prepare_branch)
        self.assertNotIn("bws-run", prepare_branch)
        self.assertNotIn("bws-get", prepare_branch)

    def test_wrappers_do_not_run_release_tools_on_system_python(self) -> None:
        """`/usr/bin/python3` is 3.9; `release_tools` declares >= 3.11."""
        for name in ("release-status", "release-testflight"):
            with self.subTest(wrapper=name):
                wrapper = (ROOT / "app" / name).read_text(encoding="utf-8")
                self.assertNotIn('/usr/bin/python3" -m release_tools', wrapper)
                self.assertNotIn("/usr/bin/python3 -m release_tools", wrapper)
                self.assertIn("release_python()", wrapper)
                self.assertIn('PYTHON_BIN="$(release_python)"', wrapper)

    def test_release_python_resolves_an_interpreter_release_tools_can_run(self) -> None:
        """The resolver must return a real >= 3.11 interpreter, not just claim to."""
        wrapper = (ROOT / "app" / "release-status").read_text(encoding="utf-8")
        body = wrapper.split("release_python() {", 1)[1].split("\n}\n", 1)[0]
        resolved = subprocess.run(
            ["bash", "-c", f"set -euo pipefail\nrelease_python() {{{body}\n}}\nrelease_python"],
            capture_output=True,
            text=True,
            check=True,
        )
        reported = subprocess.run(
            [
                resolved.stdout.strip(),
                "-c",
                "import sys; print('%d.%d' % sys.version_info[:2])",
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        major, minor = (int(part) for part in reported.stdout.strip().split("."))

        self.assertGreaterEqual((major, minor), (3, 11))

    def test_both_wrappers_share_one_interpreter_resolver(self) -> None:
        """A resolver that drifts between the two entry points is worse than none."""
        bodies = [
            (ROOT / "app" / name)
            .read_text(encoding="utf-8")
            .split("release_python() {", 1)[1]
            .split("\n}\n", 1)[0]
            for name in ("release-status", "release-testflight")
        ]

        self.assertEqual(bodies[0], bodies[1])

    def test_prepare_only_uses_git_common_readiness_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            checkout, common_dir, bin_dir = self._release_wrapper_fixture(temporary)
            stale_manifest = (
                checkout
                / ".git"
                / "release-state"
                / "gradus-ios"
                / "candidates"
                / "1.8.1-21"
                / "manifest.json"
            )
            stale_manifest.parent.mkdir(parents=True)
            stale_manifest.write_text("{}", encoding="utf-8")
            canonical_manifest = (
                common_dir
                / "release-state"
                / "gradus-ios"
                / "candidates"
                / "1.8.1-21"
                / "manifest.json"
            )
            canonical_manifest.parent.mkdir(parents=True)
            canonical_manifest.write_text("{}", encoding="utf-8")

            result = self._run_release_prepare(checkout, common_dir, bin_dir)

            self.assertEqual(result.returncode, 0, result.stderr)
            supplied_manifest = (
                checkout.parent / "apple_developer" / "release_tools" / "readiness-manifest.txt"
            ).read_text()
            self.assertEqual(supplied_manifest, str(canonical_manifest))

    def test_upload_uses_git_common_candidate_pointer_not_project_local_pointer(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            checkout, common_dir, bin_dir = self._release_wrapper_fixture(temporary)
            stale_pointer = checkout / ".release-state" / "gradus-ios" / "active-candidate.json"
            stale_pointer.parent.mkdir(parents=True)
            stale_pointer.write_text('{"candidateId": "1.8.0-20"}', encoding="utf-8")
            canonical_pointer = (
                common_dir / "release-state" / "gradus-ios" / "active-candidate.json"
            )
            canonical_pointer.parent.mkdir(parents=True)
            canonical_pointer.write_text('{"candidateId": "1.8.1-21"}', encoding="utf-8")
            canonical_manifest = (
                common_dir
                / "release-state"
                / "gradus-ios"
                / "candidates"
                / "1.8.1-21"
                / "manifest.json"
            )
            canonical_manifest.parent.mkdir(parents=True)
            canonical_manifest.write_text("{}", encoding="utf-8")

            result = self._run_release_upload(checkout, common_dir, bin_dir)

            self.assertEqual(result.returncode, 0, result.stderr)
            invoked = json.loads(
                (checkout.parent / "apple_developer" / "release_tools" / "invoked.json").read_text()
            )
            self.assertEqual(invoked[invoked.index("--candidate") + 1], "1.8.1-21")
            supplied_manifest = (
                checkout.parent / "apple_developer" / "release_tools" / "readiness-manifest.txt"
            ).read_text()
            self.assertEqual(supplied_manifest, str(canonical_manifest))

    def test_upload_missing_git_common_manifest_stops_before_release_tools(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            checkout, common_dir, bin_dir = self._release_wrapper_fixture(temporary)
            canonical_pointer = (
                common_dir / "release-state" / "gradus-ios" / "active-candidate.json"
            )
            canonical_pointer.parent.mkdir(parents=True)
            canonical_pointer.write_text('{"candidateId": "1.8.1-21"}', encoding="utf-8")

            result = self._run_release_upload(checkout, common_dir, bin_dir)

            self.assertEqual(result.returncode, 3)
            self.assertIn("prepared candidate manifest is unavailable", result.stderr)
            self.assertFalse(
                (checkout.parent / "apple_developer" / "release_tools" / "invoked.json").exists()
            )

    def test_upload_missing_git_common_pointer_stops_before_release_tools(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            checkout, common_dir, bin_dir = self._release_wrapper_fixture(temporary)
            stale_pointer = checkout / ".release-state" / "gradus-ios" / "active-candidate.json"
            stale_pointer.parent.mkdir(parents=True)
            stale_pointer.write_text('{"candidateId": "1.8.0-20"}', encoding="utf-8")

            result = self._run_release_upload(checkout, common_dir, bin_dir)

            self.assertEqual(result.returncode, 3)
            self.assertIn("no prepared central candidate", result.stderr)
            self.assertFalse(
                (checkout.parent / "apple_developer" / "release_tools" / "invoked.json").exists()
            )

    def test_prepare_uploaded_active_candidate_allocates_fresh_candidate_without_successor_correction(
        self,
    ) -> None:
        for transition_name in ("uploadAttemptStarted", "uploaded", "internalTestFlightReceipted"):
            with (
                self.subTest(transition=transition_name),
                tempfile.TemporaryDirectory() as temporary,
            ):
                checkout, common_dir, bin_dir = self._release_wrapper_fixture(temporary)
                self._write_active_pointer(common_dir, "1.8.1-21")
                candidate_dir = (
                    common_dir / "release-state" / "gradus-ios" / "candidates" / "1.8.1-21"
                )
                self._write_v2_ledger(
                    candidate_dir,
                    [{"transition": "sourceFrozen"}, {"transition": transition_name}],
                )

                fresh_manifest = (
                    common_dir
                    / "release-state"
                    / "gradus-ios"
                    / "candidates"
                    / "1.8.2-22"
                    / "manifest.json"
                )
                fresh_manifest.parent.mkdir(parents=True)
                fresh_manifest.write_text("{}", encoding="utf-8")

                result = self._run_release_prepare(checkout, common_dir, bin_dir)

                self.assertEqual(result.returncode, 0, result.stderr)

                invocations_file = (
                    checkout.parent / "apple_developer" / "release_tools" / "invocations.jsonl"
                )
                invocations = [
                    json.loads(line)
                    for line in invocations_file.read_text(encoding="utf-8").splitlines()
                    if line.strip()
                ]
                self.assertEqual(len(invocations), 2)

                prep_call = invocations[0]
                self.assertIn("testflight", prep_call)
                self.assertNotIn("--successor-correction", prep_call)

                stage_call = invocations[1]
                self.assertIn("stage", stage_call)
                self.assertEqual(stage_call[stage_call.index("--candidate") + 1], "1.8.2-22")

                supplied_manifest = (
                    checkout.parent / "apple_developer" / "release_tools" / "readiness-manifest.txt"
                ).read_text()
                self.assertEqual(supplied_manifest, str(fresh_manifest))

    def test_prepare_preupload_active_candidate_retains_successor_correction(self) -> None:
        for transitions in (
            [],
            [{"transition": "draft"}],
            [{"transition": "sourceFrozen"}, {"transition": "staged"}],
            [{"transition": "sourceFrozen"}, {"transition": "validationFailed"}],
            [{"transition": "sourceFrozen"}, {"transition": "failed"}],
            [{"transition": "failed", "detail": "uploaded"}],
        ):
            with self.subTest(transitions=transitions), tempfile.TemporaryDirectory() as temporary:
                checkout, common_dir, bin_dir = self._release_wrapper_fixture(temporary)
                self._write_active_pointer(common_dir, "1.8.1-21")

                if transitions:
                    candidate_dir = (
                        common_dir / "release-state" / "gradus-ios" / "candidates" / "1.8.1-21"
                    )
                    self._write_v2_ledger(candidate_dir, transitions)

                canonical_manifest = (
                    common_dir
                    / "release-state"
                    / "gradus-ios"
                    / "candidates"
                    / "1.8.1-21"
                    / "manifest.json"
                )
                canonical_manifest.parent.mkdir(parents=True, exist_ok=True)
                canonical_manifest.write_text("{}", encoding="utf-8")

                result = self._run_release_prepare(checkout, common_dir, bin_dir)

                self.assertEqual(result.returncode, 0, result.stderr)

                invocations_file = (
                    checkout.parent / "apple_developer" / "release_tools" / "invocations.jsonl"
                )
                invocations = [
                    json.loads(line)
                    for line in invocations_file.read_text(encoding="utf-8").splitlines()
                    if line.strip()
                ]
                self.assertEqual(len(invocations), 2)

                prep_call = invocations[0]
                self.assertIn("testflight", prep_call)
                self.assertIn("--successor-correction", prep_call)

                stage_call = invocations[1]
                self.assertIn("stage", stage_call)
                self.assertEqual(stage_call[stage_call.index("--candidate") + 1], "1.8.1-21")

                supplied_manifest = (
                    checkout.parent / "apple_developer" / "release_tools" / "readiness-manifest.txt"
                ).read_text()
                self.assertEqual(supplied_manifest, str(canonical_manifest))

    def test_prepare_malformed_canonical_pointer_stops_before_release_tools(self) -> None:
        malformed_pointers = [
            ("bad_json", "{not valid json"),
            ("not_dict", '["1.8.1-21"]'),
            ("missing_candidate_id", '{"otherField": "val"}'),
            ("empty_candidate_id", '{"candidateId": ""}'),
            ("numeric_candidate_id", '{"candidateId": 123}'),
            ("invalid_candidate_id", '{"candidateId": "../escape/danger"}'),
            (
                "invalid_pointer_hash",
                json.dumps(
                    {
                        "candidateId": "1.8.1-21",
                        "formatVersion": 2,
                        "pointerSha256": "0" * 64,
                        "releaseTrain": "1.8.1",
                    }
                ),
            ),
        ]
        for label, content in malformed_pointers:
            with self.subTest(case=label), tempfile.TemporaryDirectory() as temporary:
                checkout, common_dir, bin_dir = self._release_wrapper_fixture(temporary)
                canonical_pointer = (
                    common_dir / "release-state" / "gradus-ios" / "active-candidate.json"
                )
                canonical_pointer.parent.mkdir(parents=True)
                canonical_pointer.write_text(content, encoding="utf-8")

                result = self._run_release_prepare(checkout, common_dir, bin_dir)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn(
                    "release-testflight: canonical release state is invalid", result.stderr
                )
                self.assertFalse(
                    (
                        checkout.parent / "apple_developer" / "release_tools" / "invoked.json"
                    ).exists()
                )

        with self.subTest(case="symlink_pointer"), tempfile.TemporaryDirectory() as temporary:
            checkout, common_dir, bin_dir = self._release_wrapper_fixture(temporary)
            target = common_dir / "target.json"
            target.write_text('{"candidateId": "1.8.1-21"}', encoding="utf-8")
            canonical_pointer = (
                common_dir / "release-state" / "gradus-ios" / "active-candidate.json"
            )
            canonical_pointer.parent.mkdir(parents=True)
            canonical_pointer.symlink_to(target)

            result = self._run_release_prepare(checkout, common_dir, bin_dir)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("canonical release state is invalid", result.stderr)
            self.assertFalse(
                (checkout.parent / "apple_developer" / "release_tools" / "invoked.json").exists()
            )

    def test_prepare_malformed_canonical_transitions_stops_before_release_tools(self) -> None:
        malformed_ledgers = [
            ("bad_json_line", '{"transition": "staged"}\n{invalid json line\n'),
            ("invalid_entry_type", '{"transition": "staged"}\n12345\n'),
            ("null_entry", '{"transition": "staged"}\nnull\n'),
            ("missing_transition", '{"transition": "staged"}\n{"detail": "uploaded"}\n'),
        ]
        for label, content in malformed_ledgers:
            with self.subTest(case=label), tempfile.TemporaryDirectory() as temporary:
                checkout, common_dir, bin_dir = self._release_wrapper_fixture(temporary)
                self._write_active_pointer(common_dir, "1.8.1-21")

                transitions_path = (
                    common_dir
                    / "release-state"
                    / "gradus-ios"
                    / "candidates"
                    / "1.8.1-21"
                    / "transitions.jsonl"
                )
                transitions_path.parent.mkdir(parents=True)
                transitions_path.write_text(content, encoding="utf-8")

                result = self._run_release_prepare(checkout, common_dir, bin_dir)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("transitions ledger", result.stderr)
                self.assertFalse(
                    (
                        checkout.parent / "apple_developer" / "release_tools" / "invoked.json"
                    ).exists()
                )

        with self.subTest(case="symlink_transitions"), tempfile.TemporaryDirectory() as temporary:
            checkout, common_dir, bin_dir = self._release_wrapper_fixture(temporary)
            self._write_active_pointer(common_dir, "1.8.1-21")

            target_transitions = common_dir / "target_transitions.jsonl"
            target_transitions.write_text('{"transition": "uploaded"}\n', encoding="utf-8")

            transitions_path = (
                common_dir
                / "release-state"
                / "gradus-ios"
                / "candidates"
                / "1.8.1-21"
                / "transitions.jsonl"
            )
            transitions_path.parent.mkdir(parents=True)
            transitions_path.symlink_to(target_transitions)

            result = self._run_release_prepare(checkout, common_dir, bin_dir)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("canonical transitions ledger is invalid", result.stderr)
            self.assertFalse(
                (checkout.parent / "apple_developer" / "release_tools" / "invoked.json").exists()
            )

    def test_prepare_tampered_v2_ledger_stops_before_release_tools(self) -> None:
        for tamper in (
            "blank-line",
            "candidate-mismatch",
            "sequence-mismatch",
            "hash-mismatch",
            "previous-hash-mismatch",
        ):
            with self.subTest(tamper=tamper), tempfile.TemporaryDirectory() as temporary:
                checkout, common_dir, bin_dir = self._release_wrapper_fixture(temporary)
                self._write_active_pointer(common_dir, "1.8.1-21")
                candidate_dir = (
                    common_dir / "release-state" / "gradus-ios" / "candidates" / "1.8.1-21"
                )
                ledger = self._write_v2_ledger(
                    candidate_dir,
                    [{"transition": "sourceFrozen"}, {"transition": "uploaded"}],
                )
                records = [json.loads(line) for line in ledger.read_text().splitlines()]

                if tamper == "blank-line":
                    ledger.write_text(ledger.read_text() + "\n", encoding="utf-8")
                else:
                    index = 1 if tamper == "previous-hash-mismatch" else 0
                    if tamper == "candidate-mismatch":
                        records[index]["candidateId"] = "1.8.1-999"
                    elif tamper == "sequence-mismatch":
                        records[index]["sequence"] = 2
                    elif tamper == "hash-mismatch":
                        records[index]["recordHash"] = "0" * 64
                    else:
                        records[index]["previousHash"] = "1" * 64
                    if tamper != "hash-mismatch":
                        body = dict(records[index])
                        body.pop("recordHash")
                        records[index]["recordHash"] = hashlib.sha256(
                            self._canonical_bytes(body)
                        ).hexdigest()
                    ledger.write_text(
                        "\n".join(json.dumps(record) for record in records) + "\n",
                        encoding="utf-8",
                    )

                result = self._run_release_prepare(checkout, common_dir, bin_dir)

                self.assertNotEqual(result.returncode, 0)
                self.assertIn("canonical transitions ledger is invalid", result.stderr)
                self.assertFalse(
                    (
                        checkout.parent / "apple_developer" / "release_tools" / "invoked.json"
                    ).exists()
                )

    def test_prepare_ignores_project_local_pointer_and_inspects_only_git_common(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            checkout, common_dir, bin_dir = self._release_wrapper_fixture(temporary)
            local_pointer = checkout / ".release-state" / "gradus-ios" / "active-candidate.json"
            local_pointer.parent.mkdir(parents=True)
            local_pointer.write_text('{"candidateId": "1.8.0-20"}', encoding="utf-8")
            local_transitions = (
                checkout
                / ".release-state"
                / "gradus-ios"
                / "candidates"
                / "1.8.0-20"
                / "transitions.jsonl"
            )
            local_transitions.parent.mkdir(parents=True)
            local_transitions.write_text('{"transition": "uploaded"}\n', encoding="utf-8")

            self._write_active_pointer(common_dir, "1.8.1-21")
            canonical_candidate_dir = (
                common_dir / "release-state" / "gradus-ios" / "candidates" / "1.8.1-21"
            )
            self._write_v2_ledger(canonical_candidate_dir, [{"transition": "staged"}])
            canonical_manifest = (
                common_dir
                / "release-state"
                / "gradus-ios"
                / "candidates"
                / "1.8.1-21"
                / "manifest.json"
            )
            canonical_manifest.parent.mkdir(parents=True, exist_ok=True)
            canonical_manifest.write_text("{}", encoding="utf-8")

            result = self._run_release_prepare(checkout, common_dir, bin_dir)

            self.assertEqual(result.returncode, 0, result.stderr)
            invocations_file = (
                checkout.parent / "apple_developer" / "release_tools" / "invocations.jsonl"
            )
            invocations = [
                json.loads(line)
                for line in invocations_file.read_text(encoding="utf-8").splitlines()
                if line.strip()
            ]
            self.assertEqual(len(invocations), 2)
            prep_call = invocations[0]
            self.assertIn("--successor-correction", prep_call)
            stage_call = invocations[1]
            self.assertEqual(stage_call[stage_call.index("--candidate") + 1], "1.8.1-21")

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

    def test_observation_blocks_rather_than_crashing_on_a_missing_dependency(self) -> None:
        """A dependency that is absent must still produce a proof.

        PyJWT is imported only when a token is first signed, so the failure lands
        mid-request rather than at construction.  An escaping traceback would
        leave no evidence at all for the operation and would put interpreter
        detail somewhere nobody reviews, so it is classified locally instead.
        """

        class _MissingDependencyClient:
            def request(self, *_args, **_kwargs):
                raise ImportError("No module named 'jwt'")

        for operation in ("processing", "compliance", "tester-group"):
            with self.subTest(operation=operation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self._legacy_candidate(root)
                with (
                    patch.object(BRIDGE, "ROOT", root),
                    patch.object(BRIDGE, "EVIDENCE_ROOT", root / "evidence"),
                ):
                    status = BRIDGE.dispatch(
                        operation,
                        product="gradus-ios",
                        candidate="gradus-ios-19",
                        client=_MissingDependencyClient(),
                        sleep=lambda _seconds: None,
                    )
                self.assertEqual(status, 3)
                proof = json.loads(
                    (root / "evidence" / "gradus-ios-19" / f"{operation}.json").read_text()
                )
                self.assertEqual(proof["result"], "blocked")
                self.assertEqual(proof["reason"], "asc-client-unavailable")

    def test_compliance_records_whether_apple_reported_anything_at_all(self) -> None:
        """Silence and an affirmative answer must not look identical in evidence.

        Apple names a compliance state only while it is withholding a build, so
        an app that declares export compliance in its Info.plist gets no field
        back.  Passing on that absence is right; recording it as an observed
        value would misrepresent silence as an answer.
        """

        for compliance, reported in (("", False), (None, False), ("COMPLIANT", True)):
            with self.subTest(compliance=compliance), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self._legacy_candidate(root)
                status, _client = self._dispatch_observed(
                    "compliance",
                    root,
                    [
                        {"data": [{"id": "app-1"}]},
                        self._builds(19, "VALID", compliance),
                    ],
                )
                self.assertEqual(status, 0)
                proof = json.loads(
                    (root / "evidence" / "gradus-ios-19" / "compliance.json").read_text()
                )
                self.assertEqual(proof["complianceStateReported"], reported)

    @staticmethod
    def _tester_group_proof(root: Path, group_id: str, *, result: str = "passed") -> None:
        """Write the tester-group proof assignment refuses to proceed without."""

        proof = root / "evidence" / "gradus-ios-19" / "tester-group.json"
        proof.parent.mkdir(parents=True, exist_ok=True)
        proof.write_text(
            json.dumps(
                {
                    "result": result,
                    "candidateId": "gradus-ios-19",
                    "groupIdentifierHash": hashlib.sha256(group_id.encode()).hexdigest(),
                }
            ),
            encoding="utf-8",
        )

    def _dispatch_assignment(self, root: Path, runner):
        with (
            patch.object(BRIDGE, "ROOT", root),
            patch.object(BRIDGE, "ASSIGN", root / "assign.py"),
            patch.object(BRIDGE, "LEGACY_LEDGER", root / ".release-state" / "candidate.json"),
            patch.object(BRIDGE, "EVIDENCE_ROOT", root / "evidence"),
        ):
            return BRIDGE.dispatch(
                "assignment", product="gradus-ios", candidate="gradus-ios-19", runner=runner
            )

    def test_assignment_never_distributes_without_a_matching_confirmation(self) -> None:
        """The recorded choice and its proof must still agree at assignment time.

        Assignment is the first operation that changes anything at Apple, so a
        confirmation edited after the lookup, or a proof that never passed, must
        stop it.  The runner is a trap: reaching it means a build was about to
        be distributed on an authority nobody granted.
        """

        group = "00000000-0000-4000-8000-000000000001"
        cases = {
            "no-confirmation": (None, group, "passed"),
            "no-proof": ((group, "Internal Testers"), None, "passed"),
            "proof-blocked": ((group, "Internal Testers"), group, "blocked"),
            "confirmation-changed-after-lookup": (
                ("another-group-id", "Internal Testers"),
                group,
                "passed",
            ),
        }
        for name, (confirmation, proof_group, result) in cases.items():
            with self.subTest(case=name), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self._legacy_candidate(root)
                if confirmation is not None:
                    self._confirm(root, confirmation[0], confirmation[1])
                if proof_group is not None:
                    self._tester_group_proof(root, proof_group, result=result)

                def runner(argv, **kwargs):
                    raise AssertionError("distributed a build without a confirmed group")

                self.assertEqual(self._dispatch_assignment(root, runner), 3)
                proof = json.loads(
                    (root / "evidence" / "gradus-ios-19" / "assignment.json").read_text()
                )
                self.assertEqual(proof["reason"], "tester-group-confirmation-required")

    def test_assignment_delegates_to_the_attended_wrapper(self) -> None:
        """The mutation belongs to testflight-assign.py, not to the bridge.

        That wrapper already owns reconciliation, the ledger transition, and the
        receipt journal.  Re-implementing any of it here would give one act two
        records that could disagree, so the bridge only invokes it and attests
        the outcome.
        """

        group = "00000000-0000-4000-8000-000000000001"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._legacy_candidate(root)
            self._confirm(root, group, "Internal Testers")
            self._tester_group_proof(root, group)
            calls = []

            receipt = json.dumps(
                {
                    "candidate_id": "gradus-ios-19",
                    "build": 19,
                    "group_id": group,
                    "group_name": "Internal Testers",
                    "assigned": True,
                    "state": "assigned",
                }
            )

            def runner(argv, **kwargs):
                calls.append(argv)
                return subprocess.CompletedProcess(argv, 0, receipt, "")

            self.assertEqual(self._dispatch_assignment(root, runner), 0)
            self.assertEqual(len(calls), 1)
            argv = calls[0]
            self.assertEqual(argv[1:4], [str(root / "assign.py"), "gradus-ios-19", "19"])
            self.assertIn("--group-id", argv)
            self.assertEqual(argv[argv.index("--group-id") + 1], group)
            self.assertEqual(argv[argv.index("--group-name") + 1], "Internal Testers")
            proof = json.loads(
                (root / "evidence" / "gradus-ios-19" / "assignment.json").read_text()
            )
            self.assertEqual(proof["result"], "passed")
            self.assertEqual(proof["lane"], "standard")
            self.assertEqual(
                proof["groupIdentifierHash"], hashlib.sha256(group.encode()).hexdigest()
            )
            self.assertNotIn(group, json.dumps(proof), "the proof republished the group identifier")

    def test_assignment_refuses_a_receipt_that_never_reached_apple(self) -> None:
        """A zero exit is not a distribution.

        Reconciliation succeeds for a candidate that stayed unassigned -- Apple
        simply never took the build -- so the wrapper exits zero while its own
        receipt reports ``assigned: false``.  Attesting on the exit code would
        record a release nobody received, and every later operation would run
        against a build that reached no tester.
        """

        group = "00000000-0000-4000-8000-000000000001"
        unconfirmed = (
            {"candidate_id": "gradus-ios-19", "build": 19, "group_id": group, "assigned": False},
            {"candidate_id": "gradus-ios-19", "build": 19, "group_id": group},
            {"candidate_id": "gradus-ios-18", "build": 19, "group_id": group, "assigned": True},
            {"candidate_id": "gradus-ios-19", "build": 18, "group_id": group, "assigned": True},
            {"candidate_id": "gradus-ios-19", "build": 19, "group_id": "other", "assigned": True},
        )
        for receipt in unconfirmed:
            with self.subTest(receipt=receipt):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    self._legacy_candidate(root)
                    self._confirm(root, group, "Internal Testers")
                    self._tester_group_proof(root, group)

                    def runner(argv, **kwargs):
                        return subprocess.CompletedProcess(argv, 0, json.dumps(receipt), "")

                    self.assertEqual(self._dispatch_assignment(root, runner), 3)
                    proof = json.loads(
                        (root / "evidence" / "gradus-ios-19" / "assignment.json").read_text()
                    )
                    self.assertEqual(proof["result"], "blocked")
                    self.assertEqual(proof["reason"], "assignment-not-confirmed")

    def test_assignment_blocks_when_the_wrapper_refuses(self) -> None:
        """A refused assignment must leave a blocked proof, never a passing one."""

        group = "00000000-0000-4000-8000-000000000001"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self._legacy_candidate(root)
            self._confirm(root, group, "Internal Testers")
            self._tester_group_proof(root, group)

            def runner(argv, **kwargs):
                return subprocess.CompletedProcess(argv, 1, "", "FAIL: assignment_invalid")

            self.assertEqual(self._dispatch_assignment(root, runner), 3)
            proof = json.loads(
                (root / "evidence" / "gradus-ios-19" / "assignment.json").read_text()
            )
            self.assertEqual(proof["result"], "blocked")
            self.assertEqual(proof["reason"], "assignment-not-confirmed")


class ReleasePrepareBridgeTests(unittest.TestCase):
    """Regression coverage for the central-to-legacy preparation boundary."""

    @staticmethod
    def _fixture(temporary: str) -> tuple[Path, PREPARE.CandidateContext]:
        root = Path(temporary)
        common = root / "git-common"
        candidate = "1.8.2-21"
        manifest = (
            common / "release-state" / "gradus-ios" / "candidates" / candidate / "manifest.json"
        )
        manifest.parent.mkdir(parents=True)
        manifest.write_text(
            json.dumps(
                {
                    "formatVersion": 2,
                    "immutable": True,
                    "candidateId": candidate,
                    "productIdentifier": "gradus-ios",
                    "sourceSnapshot": {"sha256": "a" * 64},
                    "release": {
                        "marketingVersion": "1.8.2",
                        "buildNumber": "21",
                        "frozen": True,
                    },
                }
            ),
            encoding="utf-8",
        )
        evidence = root / ".release-state" / "evidence"
        evidence.mkdir(parents=True)
        (evidence / "allocate-identity.json").write_text(
            json.dumps(
                {
                    "proofVersion": "1.0.0",
                    "operationClass": "identityAllocation",
                    "result": "passed",
                    "productKey": "gradus-ios",
                    "marketingVersion": "1.8.2",
                    "buildNumber": 21,
                    "remoteHighestMarketingVersion": "1.8.0",
                    "remoteHighestBuildNumber": 20,
                    "observedAt": "2026-08-21T13:23:59Z",
                    "responseSha256": "b" * 64,
                }
            ),
            encoding="utf-8",
        )
        old_workspace = root / ".release-state" / "candidates" / "gradus-ios-20"
        old_workspace.mkdir(parents=True)
        (old_workspace / "GradusiOS.ipa").write_bytes(b"old-assigned-artifact")
        ledger = {
            "candidateId": "gradus-ios-20",
            "state": "assigned",
            "marketingVersion": "1.8.0",
            "build": 20,
            "sourceSha256": "c" * 64,
            "projectSha256": "d" * 64,
            "artifactSha256": hashlib.sha256(b"old-assigned-artifact").hexdigest(),
            "metadata": {
                "candidateWorkspace": str(old_workspace),
                "ipaPath": str(old_workspace / "GradusiOS.ipa"),
            },
        }
        (root / ".release-state" / "candidate.json").write_text(
            json.dumps(ledger), encoding="utf-8"
        )
        (root / ".release-state" / "allocated-ios.json").write_text(
            json.dumps(
                {
                    "candidateId": "gradus-ios-20",
                    "state": "allocated-but-unfrozen",
                    "marketingVersion": "1.8.0",
                    "build": 20,
                    "allocatedAt": "2026-08-18T01:58:33Z",
                }
            ),
            encoding="utf-8",
        )
        return root, PREPARE.load_context(manifest, git_common_dir=common)

    def test_assigned_legacy_state_is_archived_only_for_exact_central_allocation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root, context = self._fixture(temporary)
            calls = []
            correction_proof = (
                root
                / ".release-state"
                / "evidence"
                / context.candidate_id
                / "allocate-identity.json"
            )
            correction_proof.parent.mkdir(parents=True)
            correction_proof.write_bytes(
                (root / ".release-state" / "evidence" / "allocate-identity.json").read_bytes()
            )

            def runner(argv, **kwargs):
                calls.append((argv, kwargs))
                self.assertNotIn("APP_STORE_CONNECT_API_KEY", kwargs["env"])
                self.assertEqual(kwargs["env"]["GRADUS_CANDIDATE_ID"], context.candidate_id)
                correction_proof = (
                    root
                    / ".release-state"
                    / "evidence"
                    / context.candidate_id
                    / "allocate-identity.json"
                )
                self.assertEqual(
                    kwargs["env"]["GRADUS_IDENTITY_ALLOCATION_PROOF_PATH"],
                    str(correction_proof),
                )
                archived = root / ".release-state" / "archived" / "gradus-ios-20"
                archived.mkdir(parents=True)
                (archived / "candidate.json").write_text(
                    json.dumps({"candidateId": "gradus-ios-20", "state": "superseded"}),
                    encoding="utf-8",
                )
                artifact_root = root / ".release-state" / "candidates" / context.candidate_id
                artifact_root.mkdir(parents=True)
                ipa = artifact_root / "GradusiOS.ipa"
                ipa.write_bytes(b"central-candidate-artifact")
                digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
                (root / ".release-state" / "candidate.json").write_text(
                    json.dumps(
                        {
                            "candidateId": context.candidate_id,
                            "state": "prepared",
                            "marketingVersion": context.marketing_version,
                            "build": context.build_number,
                            "sourceSha256": "e" * 64,
                            "projectSha256": "f" * 64,
                            "artifactSha256": digest,
                            "metadata": {
                                "candidateWorkspace": str(artifact_root),
                                "ipaPath": str(ipa),
                            },
                        }
                    ),
                    encoding="utf-8",
                )
                (root / ".release-state" / "allocated-ios.json").write_text(
                    json.dumps(
                        {
                            "candidateId": context.candidate_id,
                            "state": "allocated-but-unfrozen",
                            "marketingVersion": context.marketing_version,
                            "build": context.build_number,
                            "allocatedAt": "2026-08-21T13:23:59Z",
                        }
                    ),
                    encoding="utf-8",
                )
                return subprocess.CompletedProcess(argv, 0)

            with patch.dict(os.environ, {"APP_STORE_CONNECT_API_KEY": "fixture-secret"}):
                PREPARE.execute(
                    "all",
                    context,
                    root=root,
                    runner=runner,
                    inspector=lambda *_args: PREPARE.ArtifactInspection(
                        "1" * 64, "2" * 64, "3" * 64
                    ),
                )

            self.assertEqual(len(calls), 1)
            argv = calls[0][0]
            self.assertEqual(argv[1:4], ["--prepare-only", "--candidate", "1.8.2-21"])
            self.assertIn("--rollover-assigned", argv)
            archived_allocation = (
                root / ".release-state" / "archived" / "gradus-ios-20" / "allocated-ios.json"
            )
            self.assertEqual(
                json.loads(archived_allocation.read_text())["candidateId"], "gradus-ios-20"
            )
            self.assertFalse((root / ".release-state" / ".rollover").exists())
            proof = json.loads(
                (
                    root
                    / ".release-state"
                    / "evidence"
                    / context.candidate_id
                    / "production-build.json"
                ).read_text()
            )
            self.assertEqual(proof["candidateId"], context.candidate_id)
            self.assertEqual(proof["sourceDigest"], context.source_digest)
            self.assertEqual(proof["operationClass"], "productionReleaseBuild")
            self.assertEqual(proof["signingMode"], "appStore")
            self.assertTrue(proof["reuseAuthorized"])
            for name in ("archive.json", "signing.json", "artifact.json"):
                self.assertTrue(
                    (root / ".release-state" / "evidence" / context.candidate_id / name).is_file()
                )

    def test_rollover_refuses_nonmatching_remote_predecessor_without_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root, context = self._fixture(temporary)
            proof_path = root / ".release-state" / "evidence" / "allocate-identity.json"
            proof = json.loads(proof_path.read_text())
            proof["remoteHighestBuildNumber"] = 19
            proof["buildNumber"] = 20
            proof_path.write_text(json.dumps(proof), encoding="utf-8")
            ledger_before = (root / ".release-state" / "candidate.json").read_bytes()
            allocation_before = (root / ".release-state" / "allocated-ios.json").read_bytes()

            with self.assertRaises(PREPARE.BridgeError):
                PREPARE.execute(
                    "production-build",
                    context,
                    root=root,
                    runner=lambda *_args, **_kwargs: self.fail("legacy preparation ran"),
                )

            self.assertEqual(
                (root / ".release-state" / "candidate.json").read_bytes(), ledger_before
            )
            self.assertEqual(
                (root / ".release-state" / "allocated-ios.json").read_bytes(),
                allocation_before,
            )

    def test_staged_exact_allocation_remains_retryable_before_ledger_archive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root, context = self._fixture(temporary)

            self.assertEqual(PREPARE.reconcile_assigned_candidate(root, context), "gradus-ios-20")
            self.assertFalse((root / ".release-state" / "allocated-ios.json").exists())
            self.assertEqual(PREPARE.reconcile_assigned_candidate(root, context), "gradus-ios-20")
            staged = root / ".release-state" / ".rollover" / "gradus-ios-20" / "allocated-ios.json"
            self.assertEqual(json.loads(staged.read_text())["candidateId"], "gradus-ios-20")

    def test_failed_preupload_successor_derives_its_legacy_allocation_proof(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root, context = self._fixture(temporary)
            manifest = json.loads(context.manifest_path.read_text())
            manifest["candidateId"] = "1.8.2-22"
            manifest["release"]["buildNumber"] = "22"
            replacement = context.manifest_path.parent.parent / "1.8.2-22" / "manifest.json"
            replacement.parent.mkdir()
            replacement.write_text(json.dumps(manifest), encoding="utf-8")
            (replacement.parent / "identity-allocation.json").write_text(
                json.dumps(
                    {
                        "allocation": {
                            "productKey": "gradus-ios",
                            "requestedMarketingVersion": "1.8.2",
                            "allocatedBuildNumber": 22,
                            "remoteHighestMarketingVersion": "1.8.1",
                            "remoteHighestBuildNumber": 20,
                            "observedAt": "2026-08-21T15:02:30Z",
                            "result": "allocated",
                        },
                        "reuseAuthorization": {
                            "kind": "failed-preupload-correction",
                            "priorCandidateId": "1.8.2-21",
                        },
                    }
                ),
                encoding="utf-8",
            )
            replacement_manifest = json.loads(replacement.read_text(encoding="utf-8"))
            replacement_manifest["identityAllocation"] = {
                "proofSha256": hashlib.sha256(
                    (replacement.parent / "identity-allocation.json").read_bytes()
                ).hexdigest()
            }
            replacement.write_text(json.dumps(replacement_manifest), encoding="utf-8")
            successor = PREPARE.load_context(
                replacement,
                git_common_dir=replacement.parents[4],
            )
            stale_allocation = {
                "candidateId": "1.8.2-21",
                "state": "allocated-but-unfrozen",
                "marketingVersion": "1.8.2",
                "build": 21,
                "allocatedAt": "2026-08-21T14:00:00Z",
            }
            (root / ".release-state" / "allocated-ios.json").write_text(
                json.dumps(stale_allocation), encoding="utf-8"
            )
            self.assertEqual(PREPARE.reconcile_assigned_candidate(root, successor), "gradus-ios-20")
            archived = (
                root / ".release-state" / "failed-preupload" / "1.8.2-21" / "allocated-ios.json"
            )
            self.assertEqual(json.loads(archived.read_text()), stale_allocation)
            self.assertFalse((root / ".release-state" / "allocated-ios.json").exists())
            proof = json.loads(
                (
                    root / ".release-state" / "evidence" / "1.8.2-22" / "allocate-identity.json"
                ).read_text()
            )
            self.assertEqual((proof["marketingVersion"], proof["buildNumber"]), ("1.8.2", 22))
            self.assertEqual(proof["remoteHighestBuildNumber"], 20)
            self.assertEqual(proof["remoteHighestMarketingVersion"], "1.8.1")

    def test_staged_preupload_successor_requires_matching_prior_stage_package(self) -> None:
        for package_case in ("valid", "missing", "tampered"):
            with (
                self.subTest(package_case=package_case),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root, context = self._fixture(temporary)
                manifest = json.loads(context.manifest_path.read_text())
                manifest["candidateId"] = "1.8.2-22"
                manifest["release"]["buildNumber"] = "22"
                replacement = context.manifest_path.parent.parent / "1.8.2-22" / "manifest.json"
                replacement.parent.mkdir()
                prior_dir = context.manifest_path.parent
                package = {
                    "formatVersion": 1,
                    "proofSchema": "release.approval-package.v1",
                    "result": "staged",
                    "candidateId": "1.8.2-21",
                }
                package_bytes = (
                    json.dumps(package, sort_keys=True, separators=(",", ":")).encode() + b"\n"
                )
                prior_package = prior_dir / "approval-package.json"
                prior_package.write_bytes(package_bytes)
                allocation = {
                    "productKey": "gradus-ios",
                    "requestedMarketingVersion": "1.8.2",
                    "allocatedBuildNumber": 22,
                    "remoteHighestMarketingVersion": "1.8.0",
                    "remoteHighestBuildNumber": 20,
                    "observedAt": "2026-08-21T15:02:30Z",
                    "result": "allocated",
                }
                authorization = {
                    "kind": "staged-preupload-correction",
                    "priorCandidateId": "1.8.2-21",
                    "priorStagePackageSha256": hashlib.sha256(package_bytes).hexdigest(),
                }
                if package_case == "missing":
                    prior_package.unlink()
                elif package_case == "tampered":
                    prior_package.write_bytes(b"tampered\n")
                allocation_path = replacement.parent / "identity-allocation.json"
                allocation_path.write_text(
                    json.dumps({"allocation": allocation, "reuseAuthorization": authorization}),
                    encoding="utf-8",
                )
                manifest["identityAllocation"] = {
                    "proofSha256": hashlib.sha256(allocation_path.read_bytes()).hexdigest()
                }
                replacement.write_text(json.dumps(manifest), encoding="utf-8")
                successor = PREPARE.load_context(replacement, git_common_dir=replacement.parents[4])
                if package_case == "valid":
                    proof = PREPARE._identity_proof(root, successor)
                    self.assertEqual(proof["buildNumber"], 22)
                else:
                    with self.assertRaises(PREPARE.BridgeError):
                        PREPARE._identity_proof(root, successor)

    def test_failed_preupload_successor_rejects_identity_allocation_digest_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root, context = self._fixture(temporary)
            manifest = json.loads(context.manifest_path.read_text())
            manifest["candidateId"] = "1.8.2-22"
            manifest["release"]["buildNumber"] = "22"
            replacement = context.manifest_path.parent.parent / "1.8.2-22" / "manifest.json"
            replacement.parent.mkdir()
            allocation_path = replacement.parent / "identity-allocation.json"
            allocation_path.write_text(
                json.dumps(
                    {
                        "allocation": {
                            "productKey": "gradus-ios",
                            "requestedMarketingVersion": "1.8.2",
                            "allocatedBuildNumber": 22,
                            "remoteHighestMarketingVersion": "1.8.2",
                            "remoteHighestBuildNumber": 21,
                            "observedAt": "2026-08-21T15:02:30Z",
                            "result": "allocated",
                        },
                        "reuseAuthorization": {
                            "kind": "failed-preupload-correction",
                            "priorCandidateId": "1.8.2-21",
                        },
                    }
                ),
                encoding="utf-8",
            )
            manifest["identityAllocation"] = {"proofSha256": "0" * 64}
            replacement.write_text(json.dumps(manifest), encoding="utf-8")
            successor = PREPARE.load_context(
                replacement,
                git_common_dir=replacement.parents[4],
            )

            with self.assertRaises(PREPARE.BridgeError):
                PREPARE.reconcile_assigned_candidate(root, successor)

            self.assertFalse(
                (
                    root / ".release-state" / "evidence" / "1.8.2-22" / "allocate-identity.json"
                ).exists()
            )

    def test_failed_preupload_successor_rejects_non_mapping_allocation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root, context = self._fixture(temporary)
            manifest = json.loads(context.manifest_path.read_text())
            manifest["candidateId"] = "1.8.2-22"
            manifest["release"]["buildNumber"] = "22"
            replacement = context.manifest_path.parent.parent / "1.8.2-22" / "manifest.json"
            replacement.parent.mkdir()
            allocation_path = replacement.parent / "identity-allocation.json"
            allocation_path.write_text(
                json.dumps(
                    {
                        "allocation": [],
                        "reuseAuthorization": {
                            "kind": "failed-preupload-correction",
                            "priorCandidateId": "1.8.2-21",
                        },
                    }
                ),
                encoding="utf-8",
            )
            manifest["identityAllocation"] = {
                "proofSha256": hashlib.sha256(allocation_path.read_bytes()).hexdigest()
            }
            replacement.write_text(json.dumps(manifest), encoding="utf-8")
            successor = PREPARE.load_context(
                replacement,
                git_common_dir=replacement.parents[4],
            )

            with self.assertRaises(PREPARE.BridgeError):
                PREPARE.reconcile_assigned_candidate(root, successor)

    def test_each_preupload_operation_emits_the_central_expected_proof(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root, context = self._fixture(temporary)
            artifact_root = root / ".release-state" / "candidates" / context.candidate_id
            artifact_root.mkdir(parents=True)
            ipa = artifact_root / "GradusiOS.ipa"
            ipa.write_bytes(b"frozen-signed-ipa")
            digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
            (root / ".release-state" / "candidate.json").write_text(
                json.dumps(
                    {
                        "candidateId": context.candidate_id,
                        "state": "prepared",
                        "marketingVersion": context.marketing_version,
                        "build": context.build_number,
                        "sourceSha256": "e" * 64,
                        "projectSha256": "f" * 64,
                        "artifactSha256": digest,
                        "metadata": {"ipaPath": str(ipa)},
                    }
                ),
                encoding="utf-8",
            )
            (root / ".release-state" / "allocated-ios.json").write_text(
                json.dumps(
                    {
                        "candidateId": context.candidate_id,
                        "state": "allocated-but-unfrozen",
                        "marketingVersion": context.marketing_version,
                        "build": context.build_number,
                        "allocatedAt": "2026-08-21T13:23:59Z",
                    }
                ),
                encoding="utf-8",
            )
            inspection = PREPARE.ArtifactInspection("1" * 64, "2" * 64, "3" * 64)

            for operation, filename, operation_class in (
                ("archive", "archive.json", "archive"),
                ("sign", "signing.json", "sign"),
                ("artifact-verify", "artifact.json", "artifactVerify"),
            ):
                with self.subTest(operation=operation):
                    path = PREPARE.execute(
                        operation,
                        context,
                        root=root,
                        inspector=lambda *_args: inspection,
                    )
                    self.assertEqual(path.name, filename)
                    proof = json.loads(path.read_text())
                    self.assertEqual(proof["operationClass"], operation_class)
                    self.assertEqual(proof["candidateId"], context.candidate_id)
                    self.assertEqual(proof["sourceDigest"], context.source_digest)
                    self.assertEqual(proof["result"], "passed")
                    self.assertEqual(proof.get("signedArtifactSha256", digest), digest)

    def test_adapter_keeps_frozen_command_contract_while_entrypoint_routes_to_bridge(self) -> None:
        adapter = json.loads((ROOT / ".release" / "release-adapter.json").read_text())
        operations = {entry["id"]: entry for entry in adapter["operations"]}
        for operation in ("production-build", "archive", "sign", "artifact-verify"):
            with self.subTest(operation=operation):
                entry = operations[operation]
                self.assertEqual(
                    entry["argv"], ["bash", "app/archive-upload-ios.sh", "--prepare-only"]
                )
                self.assertEqual(entry["environment"]["inputs"], [])
        entrypoint = (ROOT / "app" / "archive-upload-ios.sh").read_text(encoding="utf-8")
        self.assertIn('"$SCRIPT_DIR/release_prepare_bridge.py" --operation all', entrypoint)
        self.assertIn('"${GRADUS_RELEASE_BRIDGE_ACTIVE:-0}" != "1"', entrypoint)
        self.assertEqual(operations["upload"]["mode"], "credential")
        self.assertNotIn("release_prepare_bridge.py", " ".join(operations["upload"]["arguments"]))


class ReleasePrepareBridgeArtifactInspectionTests(unittest.TestCase):
    """Hermetic tests for artifact inspection, nested widget facts, and schema proofs."""

    @staticmethod
    def _create_mock_ipa(
        ipa_path: Path,
        *,
        app_bundle_id: str = "com.zerodelta.gradus.ios",
        app_version: str = "1.8.2",
        app_build: str = "21",
        include_plugins: bool = True,
        appex_names: Sequence[str] = ("GradusWidget.appex",),
        widget_bundle_id: str = "com.zerodelta.gradus.ios.widget",
        widget_version: str = "1.8.2",
        widget_build: str = "21",
        include_main_profile: bool = True,
        include_widget_profile: bool = True,
        main_profile_content: bytes = b"main-mobileprovision-der-bytes-1",
        widget_profile_content: bytes = b"widget-mobileprovision-der-bytes-2",
        corrupt_main_info: bool = False,
        corrupt_widget_info: bool = False,
    ) -> None:
        ipa_path.parent.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(ipa_path, "w") as archive:
            if corrupt_main_info:
                archive.writestr("Payload/GradusiOS.app/Info.plist", b"invalid-plist-bytes")
            else:
                main_info = {
                    "CFBundleIdentifier": app_bundle_id,
                    "CFBundleShortVersionString": app_version,
                    "CFBundleVersion": app_build,
                }
                archive.writestr("Payload/GradusiOS.app/Info.plist", plistlib.dumps(main_info))

            if include_main_profile:
                archive.writestr(
                    "Payload/GradusiOS.app/embedded.mobileprovision", main_profile_content
                )

            if include_plugins:
                for appex in appex_names:
                    if corrupt_widget_info:
                        archive.writestr(
                            f"Payload/GradusiOS.app/PlugIns/{appex}/Info.plist",
                            b"invalid-plist-bytes",
                        )
                    else:
                        w_info = {
                            "CFBundleIdentifier": widget_bundle_id,
                            "CFBundleShortVersionString": widget_version,
                            "CFBundleVersion": widget_build,
                        }
                        archive.writestr(
                            f"Payload/GradusiOS.app/PlugIns/{appex}/Info.plist",
                            plistlib.dumps(w_info),
                        )

                    if include_widget_profile:
                        archive.writestr(
                            f"Payload/GradusiOS.app/PlugIns/{appex}/embedded.mobileprovision",
                            widget_profile_content,
                        )

    @staticmethod
    def _make_mock_runner(
        *,
        main_profile_plist: Mapping[str, Any] | None = None,
        widget_profile_plist: Mapping[str, Any] | None = None,
        main_signed_entitlements: Mapping[str, Any] | None = None,
        widget_signed_entitlements: Mapping[str, Any] | None = None,
        codesign_verify_fail_widget: bool = False,
        codesign_verify_fail_main: bool = False,
        missing_main_cert: bool = False,
        missing_widget_cert: bool = False,
        main_cert_bytes: bytes = b"cert-main-leaf-0",
        widget_cert_bytes: bytes = b"cert-widget-leaf-0",
    ):
        default_main_profile = {
            "Entitlements": {
                "application-identifier": "4CJ49V6QHW.com.zerodelta.gradus.ios",
                "com.apple.developer.team-identifier": "4CJ49V6QHW",
                "com.apple.developer.icloud-container-environment": "Production",
                "com.apple.security.application-groups": ["group.com.zerodelta.gradus"],
                "get-task-allow": False,
            }
        }
        default_widget_profile = {
            "Entitlements": {
                "application-identifier": "4CJ49V6QHW.com.zerodelta.gradus.ios.widget",
                "com.apple.developer.team-identifier": "4CJ49V6QHW",
                "com.apple.security.application-groups": ["group.com.zerodelta.gradus"],
                "get-task-allow": False,
            }
        }
        default_main_entitlements = {
            "application-identifier": "4CJ49V6QHW.com.zerodelta.gradus.ios",
            "com.apple.developer.team-identifier": "4CJ49V6QHW",
            "com.apple.developer.icloud-container-environment": "Production",
            "com.apple.security.application-groups": ["group.com.zerodelta.gradus"],
            "get-task-allow": False,
        }
        default_widget_entitlements = {
            "application-identifier": "4CJ49V6QHW.com.zerodelta.gradus.ios.widget",
            "com.apple.developer.team-identifier": "4CJ49V6QHW",
            "com.apple.security.application-groups": ["group.com.zerodelta.gradus"],
            "get-task-allow": False,
        }

        m_prof = default_main_profile if main_profile_plist is None else main_profile_plist
        w_prof = default_widget_profile if widget_profile_plist is None else widget_profile_plist
        m_ent = (
            default_main_entitlements
            if main_signed_entitlements is None
            else main_signed_entitlements
        )
        w_ent = (
            default_widget_entitlements
            if widget_signed_entitlements is None
            else widget_signed_entitlements
        )

        def runner(
            argv: Sequence[str], *, capture_output: bool = False
        ) -> subprocess.CompletedProcess[bytes]:
            cmd = list(argv)
            if cmd[0] == "/usr/bin/ditto":
                ipa_zip = Path(cmd[3])
                dest_dir = Path(cmd[4])
                with zipfile.ZipFile(ipa_zip, "r") as z:
                    z.extractall(dest_dir)
                return subprocess.CompletedProcess(cmd, 0)

            if cmd[0] == "/usr/bin/openssl" and "smime" in cmd:
                in_path = cmd[cmd.index("-in") + 1]
                if "GradusWidget.appex" in in_path:
                    raw = plistlib.dumps(w_prof) if isinstance(w_prof, Mapping) else w_prof
                else:
                    raw = plistlib.dumps(m_prof) if isinstance(m_prof, Mapping) else m_prof
                return subprocess.CompletedProcess(cmd, 0, stdout=raw)

            if cmd[0] == "/usr/bin/codesign" and "--verify" in cmd:
                target = cmd[-1]
                if "GradusWidget.appex" in target and codesign_verify_fail_widget:
                    raise PREPARE.BridgeError("artifact-inspection-failed")
                if "GradusWidget.appex" not in target and codesign_verify_fail_main:
                    raise PREPARE.BridgeError("artifact-inspection-failed")
                return subprocess.CompletedProcess(cmd, 0)

            if cmd[0] == "/usr/bin/codesign" and "--entitlements" in cmd:
                target = cmd[-1]
                if "GradusWidget.appex" in target:
                    raw = plistlib.dumps(w_ent) if isinstance(w_ent, Mapping) else w_ent
                else:
                    raw = plistlib.dumps(m_ent) if isinstance(m_ent, Mapping) else m_ent
                return subprocess.CompletedProcess(cmd, 0, stdout=raw)

            if cmd[0] == "/usr/bin/codesign" and any(
                arg.startswith("--extract-certificates=") for arg in cmd
            ):
                prefix_arg = [arg for arg in cmd if arg.startswith("--extract-certificates=")][0]
                prefix = prefix_arg.split("=", 1)[1]
                target = cmd[-1]
                if "GradusWidget.appex" in target:
                    if not missing_widget_cert:
                        Path(f"{prefix}0").write_bytes(widget_cert_bytes)
                else:
                    if not missing_main_cert:
                        Path(f"{prefix}0").write_bytes(main_cert_bytes)
                return subprocess.CompletedProcess(cmd, 0)

            return subprocess.CompletedProcess(cmd, 0)

        return runner

    def _fixture(self, temporary: str) -> tuple[PREPARE.CandidateContext, PREPARE.PreparedArtifact]:
        root = Path(temporary)
        common = root / "git-common"
        candidate = "1.8.2-21"
        manifest = (
            common / "release-state" / "gradus-ios" / "candidates" / candidate / "manifest.json"
        )
        manifest.parent.mkdir(parents=True, exist_ok=True)
        manifest.write_text(
            json.dumps(
                {
                    "formatVersion": 2,
                    "immutable": True,
                    "candidateId": candidate,
                    "productIdentifier": "gradus-ios",
                    "sourceSnapshot": {"sha256": "a" * 64},
                    "release": {
                        "marketingVersion": "1.8.2",
                        "buildNumber": "21",
                        "frozen": True,
                    },
                }
            ),
            encoding="utf-8",
        )
        context = PREPARE.load_context(manifest, git_common_dir=common)
        ipa_path = root / "GradusiOS.ipa"
        self._create_mock_ipa(ipa_path)
        digest = hashlib.sha256(ipa_path.read_bytes()).hexdigest()
        artifact = PREPARE.PreparedArtifact(ipa_path, digest)
        return context, artifact

    def test_valid_nested_artifact_inspection_and_proof_binding(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            runner = self._make_mock_runner()
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                inspection = PREPARE.inspect_artifact(artifact, context)

            self.assertEqual(len(inspection.metadata_sha256), 64)
            self.assertEqual(
                inspection.embedded_profile_sha256,
                hashlib.sha256(b"main-mobileprovision-der-bytes-1").hexdigest(),
            )
            self.assertEqual(
                inspection.signing_certificate_sha256,
                hashlib.sha256(b"cert-main-leaf-0").hexdigest(),
            )
            self.assertEqual(
                inspection.widget_embedded_profile_sha256,
                hashlib.sha256(b"widget-mobileprovision-der-bytes-2").hexdigest(),
            )
            self.assertEqual(
                inspection.widget_signing_certificate_sha256,
                hashlib.sha256(b"cert-widget-leaf-0").hexdigest(),
            )

            proof = PREPARE.build_proof("artifact-verify", context, artifact, inspection=inspection)
            self.assertEqual(proof["operationClass"], "artifactVerify")
            self.assertEqual(proof["metadataSha256"], inspection.metadata_sha256)
            self.assertEqual(proof["cloudKitEnvironment"], "Production")
            self.assertEqual(proof["configuration"], "Production")
            self.assertTrue(proof["signed"])
            self.assertEqual(proof["strictSignatureResult"], "passed")
            self.assertEqual(proof["uploadValidationResult"], "passed")

    def test_missing_plugins_directory_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            self._create_mock_ipa(artifact.ipa_path, include_plugins=False)
            runner = self._make_mock_runner()
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_empty_plugins_directory_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            self._create_mock_ipa(artifact.ipa_path, include_plugins=True, appex_names=())
            runner = self._make_mock_runner()
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_extra_extension_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            self._create_mock_ipa(
                artifact.ipa_path,
                include_plugins=True,
                appex_names=("GradusWidget.appex", "ExtraWidget.appex"),
            )
            runner = self._make_mock_runner()
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_wrong_extension_bundle_name_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            self._create_mock_ipa(
                artifact.ipa_path,
                include_plugins=True,
                appex_names=("OtherWidget.appex",),
            )
            runner = self._make_mock_runner()
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_wrong_widget_bundle_identifier_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            self._create_mock_ipa(artifact.ipa_path, widget_bundle_id="com.other.widget")
            runner = self._make_mock_runner()
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_widget_version_drift_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            self._create_mock_ipa(artifact.ipa_path, widget_version="1.8.1")
            runner = self._make_mock_runner()
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_widget_build_drift_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            self._create_mock_ipa(artifact.ipa_path, widget_build="20")
            runner = self._make_mock_runner()
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_missing_widget_embedded_profile_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            self._create_mock_ipa(artifact.ipa_path, include_widget_profile=False)
            runner = self._make_mock_runner()
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_profile_swap_identical_mobileprovision_bytes_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            self._create_mock_ipa(
                artifact.ipa_path,
                main_profile_content=b"shared-profile-bytes",
                widget_profile_content=b"shared-profile-bytes",
            )
            runner = self._make_mock_runner()
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_profile_swap_mismatched_application_identifiers_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            swapped_main = {
                "Entitlements": {
                    "application-identifier": "4CJ49V6QHW.com.zerodelta.gradus.ios.widget",
                    "com.apple.developer.team-identifier": "4CJ49V6QHW",
                    "com.apple.developer.icloud-container-environment": "Production",
                    "com.apple.security.application-groups": ["group.com.zerodelta.gradus"],
                    "get-task-allow": False,
                }
            }
            swapped_widget = {
                "Entitlements": {
                    "application-identifier": "4CJ49V6QHW.com.zerodelta.gradus.ios",
                    "com.apple.developer.team-identifier": "4CJ49V6QHW",
                    "com.apple.security.application-groups": ["group.com.zerodelta.gradus"],
                    "get-task-allow": False,
                }
            }
            runner = self._make_mock_runner(
                main_profile_plist=swapped_main,
                widget_profile_plist=swapped_widget,
            )
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_absent_app_group_in_main_signed_entitlements_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            bad_main_entitlements = {
                "application-identifier": "4CJ49V6QHW.com.zerodelta.gradus.ios",
                "com.apple.developer.team-identifier": "4CJ49V6QHW",
                "com.apple.developer.icloud-container-environment": "Production",
                "com.apple.security.application-groups": [],
                "get-task-allow": False,
            }
            runner = self._make_mock_runner(main_signed_entitlements=bad_main_entitlements)
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_absent_app_group_in_widget_signed_entitlements_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            bad_widget_entitlements = {
                "application-identifier": "4CJ49V6QHW.com.zerodelta.gradus.ios.widget",
                "com.apple.developer.team-identifier": "4CJ49V6QHW",
                "com.apple.security.application-groups": [],
                "get-task-allow": False,
            }
            runner = self._make_mock_runner(widget_signed_entitlements=bad_widget_entitlements)
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_absent_app_group_in_main_profile_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            bad_main_profile = {
                "Entitlements": {
                    "application-identifier": "4CJ49V6QHW.com.zerodelta.gradus.ios",
                    "com.apple.developer.team-identifier": "4CJ49V6QHW",
                    "com.apple.developer.icloud-container-environment": "Production",
                    "com.apple.security.application-groups": [],
                    "get-task-allow": False,
                }
            }
            runner = self._make_mock_runner(main_profile_plist=bad_main_profile)
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_absent_app_group_in_widget_profile_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            bad_widget_profile = {
                "Entitlements": {
                    "application-identifier": "4CJ49V6QHW.com.zerodelta.gradus.ios.widget",
                    "com.apple.developer.team-identifier": "4CJ49V6QHW",
                    "com.apple.security.application-groups": [],
                    "get-task-allow": False,
                }
            }
            runner = self._make_mock_runner(widget_profile_plist=bad_widget_profile)
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_mismatched_app_group_in_widget_entitlements_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            bad_widget_entitlements = {
                "application-identifier": "4CJ49V6QHW.com.zerodelta.gradus.ios.widget",
                "com.apple.developer.team-identifier": "4CJ49V6QHW",
                "com.apple.security.application-groups": ["group.com.other.group"],
                "get-task-allow": False,
            }
            runner = self._make_mock_runner(widget_signed_entitlements=bad_widget_entitlements)
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_extension_cloudkit_leakage_in_signed_entitlements_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            leaked_widget_entitlements = {
                "application-identifier": "4CJ49V6QHW.com.zerodelta.gradus.ios.widget",
                "com.apple.developer.team-identifier": "4CJ49V6QHW",
                "com.apple.security.application-groups": ["group.com.zerodelta.gradus"],
                "com.apple.developer.icloud-container-environment": "Production",
                "get-task-allow": False,
            }
            runner = self._make_mock_runner(widget_signed_entitlements=leaked_widget_entitlements)
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_extension_cloudkit_leakage_in_profile_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            leaked_widget_profile = {
                "Entitlements": {
                    "application-identifier": "4CJ49V6QHW.com.zerodelta.gradus.ios.widget",
                    "com.apple.developer.team-identifier": "4CJ49V6QHW",
                    "com.apple.security.application-groups": ["group.com.zerodelta.gradus"],
                    "com.apple.developer.icloud-services": ["CloudKit"],
                    "get-task-allow": False,
                }
            }
            runner = self._make_mock_runner(widget_profile_plist=leaked_widget_profile)
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_extension_aps_leakage_in_signed_entitlements_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            leaked_widget_entitlements = {
                "application-identifier": "4CJ49V6QHW.com.zerodelta.gradus.ios.widget",
                "com.apple.developer.team-identifier": "4CJ49V6QHW",
                "com.apple.security.application-groups": ["group.com.zerodelta.gradus"],
                "aps-environment": "production",
                "get-task-allow": False,
            }
            runner = self._make_mock_runner(widget_signed_entitlements=leaked_widget_entitlements)
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_extension_aps_leakage_in_profile_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            leaked_widget_profile = {
                "Entitlements": {
                    "application-identifier": "4CJ49V6QHW.com.zerodelta.gradus.ios.widget",
                    "com.apple.developer.team-identifier": "4CJ49V6QHW",
                    "com.apple.security.application-groups": ["group.com.zerodelta.gradus"],
                    "com.apple.developer.aps-environment": "production",
                    "get-task-allow": False,
                }
            }
            runner = self._make_mock_runner(widget_profile_plist=leaked_widget_profile)
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_invalid_widget_codesign_signature_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            runner = self._make_mock_runner(codesign_verify_fail_widget=True)
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_missing_widget_signing_certificate_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            runner = self._make_mock_runner(missing_widget_cert=True)
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_widget_get_task_allow_true_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            bad_widget_entitlements = {
                "application-identifier": "4CJ49V6QHW.com.zerodelta.gradus.ios.widget",
                "com.apple.developer.team-identifier": "4CJ49V6QHW",
                "com.apple.security.application-groups": ["group.com.zerodelta.gradus"],
                "get-task-allow": True,
            }
            runner = self._make_mock_runner(widget_signed_entitlements=bad_widget_entitlements)
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_main_app_cloudkit_production_preservation_fails_on_development(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            bad_main_entitlements = {
                "application-identifier": "4CJ49V6QHW.com.zerodelta.gradus.ios",
                "com.apple.developer.team-identifier": "4CJ49V6QHW",
                "com.apple.developer.icloud-container-environment": "Development",
                "com.apple.security.application-groups": ["group.com.zerodelta.gradus"],
                "get-task-allow": False,
            }
            runner = self._make_mock_runner(main_signed_entitlements=bad_main_entitlements)
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_main_app_signed_entitlements_get_task_allow_true_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            bad_main_entitlements = {
                "application-identifier": "4CJ49V6QHW.com.zerodelta.gradus.ios",
                "com.apple.developer.team-identifier": "4CJ49V6QHW",
                "com.apple.developer.icloud-container-environment": "Production",
                "com.apple.security.application-groups": ["group.com.zerodelta.gradus"],
                "get-task-allow": True,
            }
            runner = self._make_mock_runner(main_signed_entitlements=bad_main_entitlements)
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)

    def test_corrupt_widget_info_plist_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            context, artifact = self._fixture(temporary)
            self._create_mock_ipa(artifact.ipa_path, corrupt_widget_info=True)
            runner = self._make_mock_runner()
            with patch.object(PREPARE, "_run_checked", side_effect=runner):
                with self.assertRaises(PREPARE.BridgeError):
                    PREPARE.inspect_artifact(artifact, context)


if __name__ == "__main__":
    unittest.main(verbosity=2)
