from __future__ import annotations

import hashlib
import json
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from release_stage_readiness import build_proof


def test_build_proof_binds_candidate_source_and_manifest_bytes() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        manifest = Path(temporary) / "manifest.json"
        raw = json.dumps(
            {
                "candidateId": "1.8.0-20",
                "sourceSnapshot": {"sha256": "a" * 64},
            },
            sort_keys=True,
        ).encode()
        manifest.write_bytes(raw)

        proof = build_proof(manifest, now=datetime(2026, 8, 18, 3, 0, tzinfo=timezone.utc))

        assert proof == {
            "proofVersion": "1.0.0",
            "operationClass": "readiness",
            "candidateId": "1.8.0-20",
            "sourceDigest": "a" * 64,
            "result": "passed",
            "issuedAt": "2026-08-18T03:00:00Z",
            "expiresAt": "2026-08-18T09:00:00Z",
            "evidenceSha256": hashlib.sha256(raw).hexdigest(),
        }


def test_build_proof_rejects_missing_source_binding() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        manifest = Path(temporary) / "manifest.json"
        manifest.write_text('{"candidateId":"1.8.0-20"}', encoding="utf-8")

        try:
            build_proof(manifest)
        except ValueError as exc:
            assert str(exc) == "readiness-source-invalid"
        else:
            raise AssertionError("missing source binding was accepted")
