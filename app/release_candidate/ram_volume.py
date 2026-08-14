"""Offline validation for the RAM-backed upload-key attestation."""

from __future__ import annotations

import re
from collections.abc import Mapping
from dataclasses import dataclass

from .ledger import CandidateError

_SHA256 = re.compile(r"^[0-9a-f]{64}$")


@dataclass(frozen=True)
class RamVolumeAttestation:
    """Allowlisted mount and teardown facts; never includes key material."""

    candidate_id: str
    mount_evidence_sha256: str
    detach_evidence_sha256: str
    volume_id: str
    filesystem: str
    disk_backed: bool
    detached: bool


def validate(data: Mapping[str, object], *, require_detach: bool = True) -> RamVolumeAttestation:
    """Reject disk-backed, unproven, or still-mounted key volumes."""

    required = (
        "candidateId",
        "mountEvidenceSha256",
        "detachEvidenceSha256",
        "volumeId",
        "filesystem",
        "diskBacked",
        "detached",
    )
    if any(key not in data for key in required):
        raise CandidateError("RAM-volume attestation is incomplete")
    candidate_id = data["candidateId"]
    mount_digest = data["mountEvidenceSha256"]
    detach_digest = data["detachEvidenceSha256"]
    volume_id = data["volumeId"]
    filesystem = data["filesystem"]
    if (
        not isinstance(candidate_id, str)
        or not candidate_id.strip()
        or not isinstance(mount_digest, str)
        or not _SHA256.fullmatch(mount_digest)
        or not isinstance(detach_digest, str)
        or not _SHA256.fullmatch(detach_digest)
        or not isinstance(volume_id, str)
        or not volume_id.strip()
        or not isinstance(filesystem, str)
        or not filesystem.strip()
        or data["diskBacked"] is not False
        or (require_detach and data["detached"] is not True)
    ):
        raise CandidateError("RAM-volume attestation failed closed")
    return RamVolumeAttestation(
        candidate_id,
        mount_digest,
        detach_digest,
        volume_id,
        filesystem,
        False,
        bool(data["detached"]),
    )
