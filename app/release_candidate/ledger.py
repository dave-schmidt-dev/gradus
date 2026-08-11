"""Small atomic ledger for a non-secret release candidate.

The ledger is deliberately local state.  It records hashes and identifiers,
never credentials or raw remote responses, and does not allocate Apple build
numbers or contact external services.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone

try:
    from enum import StrEnum
except ImportError:  # pragma: no cover - macOS system Python 3.9 fallback
    from enum import Enum

    class StrEnum(str, Enum):
        """Compatibility fallback for Python versions before enum.StrEnum."""


from collections.abc import Mapping
from pathlib import Path
from typing import Any


class CandidateError(ValueError):
    """Raised when candidate state or persistence data is invalid."""


class CandidateState(StrEnum):
    DRAFT = "draft"
    VALIDATED = "validated"
    PREPARED = "prepared"
    UPLOADING = "uploading"
    UPLOADED_UNASSIGNED = "uploaded_unassigned"
    ASSIGNED = "assigned"
    FAILED = "failed"
    ABANDONED = "abandoned"
    SUPERSEDED = "superseded"


ALLOWED_STATES = frozenset(state.value for state in CandidateState)
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_CREDENTIAL_KEY = re.compile(
    r"(?:token|secret|password|passwd|private.?key|api.?key|bearer|cookie|jwt|credential)", re.I
)
_CREDENTIAL_VALUE = re.compile(
    r"(?:bearer\s+|-----BEGIN .*PRIVATE KEY-----|sk-[A-Za-z0-9]|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)",
    re.I,
)
_IMMUTABLE_FIELDS = frozenset(
    {"candidateId", "sourceSha256", "projectSha256", "artifactSha256", "build", "marketingVersion"}
)

# A candidate may only move forward through the release boundary.  Recovery
# states are explicit and never implicitly allocate a replacement candidate.
_TRANSITIONS: dict[str, frozenset[str]] = {
    "draft": frozenset({"validated", "failed", "abandoned"}),
    "validated": frozenset({"prepared", "failed", "abandoned"}),
    "prepared": frozenset({"uploading", "failed", "abandoned"}),
    "uploading": frozenset({"uploaded_unassigned", "failed", "abandoned"}),
    "uploaded_unassigned": frozenset({"assigned", "failed", "abandoned"}),
    "assigned": frozenset({"superseded"}),
    "failed": frozenset({"abandoned", "superseded"}),
    "abandoned": frozenset(),
    "superseded": frozenset(),
}


def _digest(value: str | bytes, label: str) -> str:
    if isinstance(value, str):
        value = value.encode()
    if not isinstance(value, bytes):
        raise CandidateError(f"{label} must be bytes or text")
    return hashlib.sha256(value).hexdigest()


def _check_sha(value: str, label: str) -> str:
    if not isinstance(value, str) or not _SHA256.fullmatch(value):
        raise CandidateError(f"{label} must be a lowercase SHA-256 digest")
    return value


def _check_safe(value: Any, path: str = "record") -> None:
    if isinstance(value, Mapping):
        for key, child in value.items():
            if not isinstance(key, str) or _CREDENTIAL_KEY.search(key):
                raise CandidateError(f"credential-shaped field: {path}.{key}")
            _check_safe(child, f"{path}.{key}")
    elif isinstance(value, (list, tuple)):
        for index, child in enumerate(value):
            _check_safe(child, f"{path}[{index}]")
    elif isinstance(value, str) and _CREDENTIAL_VALUE.search(value):
        raise CandidateError(f"credential-shaped value: {path}")


def _extend_metadata(
    existing: Mapping[str, Any] | None, addition: Mapping[str, Any]
) -> dict[str, Any]:
    """Merge metadata without allowing an existing attestation to be replaced."""

    if not isinstance(addition, Mapping):
        raise CandidateError("metadata update must be an object")

    def merge(current: Mapping[str, Any], incoming: Mapping[str, Any], path: str) -> dict[str, Any]:
        result = dict(current)
        for key, value in incoming.items():
            if not isinstance(key, str):
                raise CandidateError(f"metadata key must be text: {path}")
            if key not in result:
                result[key] = value
                continue
            old = result[key]
            if isinstance(old, Mapping) and isinstance(value, Mapping):
                result[key] = merge(old, value, f"{path}.{key}")
            elif old != value:
                raise CandidateError(f"metadata field is immutable: {path}.{key}")
        return result

    result = merge(existing or {}, addition, "metadata")
    _check_safe(result, "metadata")
    return result


@dataclass(frozen=True)
class CandidateRecord:
    """Immutable candidate tuple persisted by :class:`CandidateLedger`."""

    candidate_id: str
    state: str
    source_sha256: str
    project_sha256: str
    artifact_sha256: str
    build: int | None = None
    marketing_version: str | None = None
    metadata: dict[str, Any] | None = None

    def __post_init__(self) -> None:
        if not self.candidate_id or not isinstance(self.candidate_id, str):
            raise CandidateError("candidate_id is required")
        if self.state not in ALLOWED_STATES:
            raise CandidateError(f"unknown candidate state: {self.state}")
        for label, value in (
            ("source_sha256", self.source_sha256),
            ("project_sha256", self.project_sha256),
            ("artifact_sha256", self.artifact_sha256),
        ):
            _check_sha(value, label)
        if self.build is not None and (
            isinstance(self.build, bool) or not isinstance(self.build, int) or self.build < 1
        ):
            raise CandidateError("build must be a positive integer")
        if self.metadata is not None:
            _check_safe(self.metadata, "metadata")
        _check_safe(
            {"candidateId": self.candidate_id, "marketingVersion": self.marketing_version}, "record"
        )

    def to_dict(self) -> dict[str, Any]:
        data: dict[str, Any] = {
            "candidateId": self.candidate_id,
            "state": self.state,
            "sourceSha256": self.source_sha256,
            "projectSha256": self.project_sha256,
            "artifactSha256": self.artifact_sha256,
        }
        if self.build is not None:
            data["build"] = self.build
        if self.marketing_version is not None:
            data["marketingVersion"] = self.marketing_version
        if self.metadata:
            data["metadata"] = self.metadata
        _check_safe(data)
        return data

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> CandidateRecord:
        if not isinstance(data, Mapping):
            raise CandidateError("candidate record must be an object")
        _check_safe(data)
        expected = {
            "candidateId",
            "state",
            "sourceSha256",
            "projectSha256",
            "artifactSha256",
            "build",
            "marketingVersion",
            "metadata",
        }
        unknown = set(data) - expected
        if unknown:
            raise CandidateError(f"unknown candidate fields: {', '.join(sorted(unknown))}")
        try:
            return cls(
                candidate_id=data["candidateId"],
                state=data["state"],
                source_sha256=data["sourceSha256"],
                project_sha256=data["projectSha256"],
                artifact_sha256=data["artifactSha256"],
                build=data.get("build"),
                marketing_version=data.get("marketingVersion"),
                metadata=data.get("metadata"),
            )
        except KeyError as exc:
            raise CandidateError(f"missing candidate field: {exc.args[0]}") from exc


class CandidateLedger:
    """Atomic single-record ledger rooted in the ignored ``.release-state``."""

    def __init__(self, path: str | Path):
        self.path = Path(path)

    @classmethod
    def in_project(cls, project_root: str | Path) -> CandidateLedger:
        return cls(Path(project_root) / ".release-state" / "candidate.json")

    def load(self) -> CandidateRecord | None:
        if not self.path.exists():
            return None
        try:
            with self.path.open(encoding="utf-8") as handle:
                return CandidateRecord.from_dict(json.load(handle))
        except (OSError, json.JSONDecodeError) as exc:
            raise CandidateError(f"cannot read candidate ledger: {self.path}") from exc

    def write(self, record: CandidateRecord) -> None:
        payload = json.dumps(record.to_dict(), sort_keys=True, indent=2) + "\n"
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix=f".{self.path.name}.", dir=self.path.parent)
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, self.path)
            directory_fd = os.open(self.path.parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        except Exception:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
            raise

    def create(
        self,
        candidate_id: str,
        *,
        source: str | bytes | None = None,
        project: str | bytes | None = None,
        artifact: str | bytes | None = None,
        source_sha256: str | None = None,
        project_sha256: str | None = None,
        artifact_sha256: str | None = None,
        build: int | None = None,
        marketing_version: str | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> CandidateRecord:
        if self.load() is not None:
            raise CandidateError(
                "candidate already exists; replacement requires explicit supersession"
            )

        def choose(raw: str | bytes | None, supplied: str | None, label: str) -> str:
            if supplied is not None:
                return _check_sha(supplied, f"{label}_sha256")
            if raw is None:
                raise CandidateError(f"{label} evidence is required")
            return _digest(raw, label)

        record = CandidateRecord(
            candidate_id,
            CandidateState.DRAFT.value,
            choose(source, source_sha256, "source"),
            choose(project, project_sha256, "project"),
            choose(artifact, artifact_sha256, "artifact"),
            build,
            marketing_version,
            metadata,
        )
        self.write(record)
        return record

    def transition(self, target: str | CandidateState, **updates: Any) -> CandidateRecord:
        current = self.load()
        if current is None:
            raise CandidateError("candidate ledger is missing")
        target = target.value if isinstance(target, CandidateState) else target
        if target not in _TRANSITIONS.get(current.state, ()):
            raise CandidateError(f"invalid transition: {current.state} -> {target}")
        aliases = {
            "candidate_id": "candidateId",
            "source_sha256": "sourceSha256",
            "project_sha256": "projectSha256",
            "artifact_sha256": "artifactSha256",
            "marketing_version": "marketingVersion",
        }
        normalized: dict[str, Any] = {}
        for key, value in updates.items():
            field = aliases.get(key, key)
            if field in normalized and normalized[field] != value:
                raise CandidateError(f"conflicting candidate update: {field}")
            normalized[field] = value
        current_values = {
            "candidateId": current.candidate_id,
            "sourceSha256": current.source_sha256,
            "projectSha256": current.project_sha256,
            "artifactSha256": current.artifact_sha256,
            "build": current.build,
            "marketingVersion": current.marketing_version,
        }
        for field in _IMMUTABLE_FIELDS & normalized.keys():
            if normalized[field] != current_values[field]:
                raise CandidateError(f"candidate tuple field is immutable: {field}")
        if "metadata" in normalized:
            normalized["metadata"] = _extend_metadata(current.metadata, normalized["metadata"])
        values = {**current.to_dict(), **normalized, "state": target}
        record = CandidateRecord.from_dict(values)
        self.write(record)
        return record

    def extend_metadata(self, metadata: Mapping[str, Any]) -> CandidateRecord:
        """Atomically append metadata while preserving the candidate tuple."""

        current = self.load()
        if current is None:
            raise CandidateError("candidate ledger is missing")
        merged = _extend_metadata(current.metadata, metadata)
        record = CandidateRecord(
            current.candidate_id,
            current.state,
            current.source_sha256,
            current.project_sha256,
            current.artifact_sha256,
            current.build,
            current.marketing_version,
            merged,
        )
        self.write(record)
        return record

    def refresh_producer_evidence(self, digest: str, published_at: str) -> CandidateRecord:
        """Bind a fresh producer attestation without changing candidate identity."""

        current = self.load()
        if current is None:
            raise CandidateError("candidate ledger is missing")
        if current.state != CandidateState.PREPARED:
            raise CandidateError("producer evidence can only refresh a prepared candidate")
        _check_sha(digest, "producer_evidence_sha256")
        if not isinstance(published_at, str) or not published_at.strip():
            raise CandidateError("producer published timestamp is required")
        metadata = dict(current.metadata or {})
        previous = metadata.get("producerEvidenceSha256")
        if previous is not None and "initialProducerEvidenceSha256" not in metadata:
            metadata["initialProducerEvidenceSha256"] = previous
        metadata["producerEvidenceSha256"] = digest
        metadata["producerPublishedAt"] = published_at
        _check_safe(metadata, "metadata")
        record = CandidateRecord(
            current.candidate_id,
            current.state,
            current.source_sha256,
            current.project_sha256,
            current.artifact_sha256,
            current.build,
            current.marketing_version,
            metadata,
        )
        self.write(record)
        return record

    def prepare(
        self,
        candidate_id: str,
        *,
        source_sha256: str,
        project_sha256: str,
        artifact_sha256: str,
        build: int,
        marketing_version: str,
        metadata: Mapping[str, Any],
        supersedes_reason: str | None = None,
        archive_root: str | Path | None = None,
    ) -> CandidateRecord:
        """Create or resume a local candidate through the prepared state.

        ``supersedes_reason`` and ``archive_root`` are both required when the
        active record is ``assigned``. In that case the old candidate is
        archived with the reason before this method creates the replacement.
        """

        current = self.load()
        if current is not None and current.state == CandidateState.ASSIGNED:
            if not supersedes_reason or archive_root is None:
                raise CandidateError(
                    "assigned candidate requires an explicit supersession reason and archive root"
                )
            if candidate_id == current.candidate_id:
                raise CandidateError("replacement candidate must have a new candidate ID")
            self.archive_assigned(archive_root, supersedes_reason)
            current = None
        if current is None:
            self.create(
                candidate_id,
                source_sha256=source_sha256,
                project_sha256=project_sha256,
                artifact_sha256=artifact_sha256,
                build=build,
                marketing_version=marketing_version,
                metadata=dict(metadata),
            )
            self.transition(CandidateState.VALIDATED)
            return self.transition(CandidateState.PREPARED)
        expected = {
            "candidate_id": candidate_id,
            "source_sha256": source_sha256,
            "project_sha256": project_sha256,
            "artifact_sha256": artifact_sha256,
            "build": build,
            "marketing_version": marketing_version,
        }
        actual = {
            "candidate_id": current.candidate_id,
            "source_sha256": current.source_sha256,
            "project_sha256": current.project_sha256,
            "artifact_sha256": current.artifact_sha256,
            "build": current.build,
            "marketing_version": current.marketing_version,
        }
        if actual != expected:
            raise CandidateError("existing candidate tuple mismatch")
        if current.state == CandidateState.UPLOADED_UNASSIGNED:
            raise CandidateError("uploaded_unassigned candidate exists; re-upload is forbidden")
        if current.state in {
            CandidateState.UPLOADING,
            CandidateState.ASSIGNED,
            CandidateState.FAILED,
            CandidateState.ABANDONED,
            CandidateState.SUPERSEDED,
        }:
            raise CandidateError(f"candidate cannot be prepared from state {current.state}")
        if current.state == CandidateState.DRAFT:
            current = self.transition(CandidateState.VALIDATED)
        if current.state == CandidateState.VALIDATED:
            current = self.transition(CandidateState.PREPARED)
        return self.extend_metadata(metadata)

    def archive_assigned(
        self,
        archive_root: str | Path,
        reason: str,
        *,
        superseded_at: str | None = None,
    ) -> CandidateRecord:
        """Archive an assigned candidate before allocating its replacement.

        The candidate workspace (including evidence and receipt files) is copied
        into a candidate-specific archive, and the archived ledger is marked
        ``superseded`` with the operator-supplied reason.  The active ledger is
        removed only after the archive is complete so a failed copy cannot
        silently discard the assigned candidate.
        """

        current = self.load()
        if current is None or current.state != CandidateState.ASSIGNED:
            raise CandidateError("only an assigned candidate can be rolled over")
        if not isinstance(reason, str) or not reason.strip():
            raise CandidateError("supersession reason is required")
        if any(character in reason for character in "\r\n\t"):
            raise CandidateError("supersession reason contains a control character")
        if len(reason) > 500:
            raise CandidateError("supersession reason is too long")

        metadata = dict(current.metadata or {})
        workspace_value = metadata.get("candidateWorkspace")
        if not isinstance(workspace_value, str) or not workspace_value.strip():
            raise CandidateError("assigned candidate is missing its workspace")
        workspace = Path(workspace_value)
        if not workspace.is_dir():
            raise CandidateError(f"assigned candidate workspace is missing: {workspace}")
        root = Path(archive_root)
        destination = root / current.candidate_id
        if destination.exists():
            raise CandidateError(f"candidate archive already exists: {destination}")

        receipt_value = metadata.get("receiptJournalPath")
        archived_receipt_path: str | None = None
        if receipt_value is not None:
            if not isinstance(receipt_value, str) or not receipt_value.strip():
                raise CandidateError("assigned candidate receipt journal path is invalid")
            receipt_path = Path(receipt_value).expanduser().resolve()
            try:
                receipt_relative = receipt_path.relative_to(workspace.resolve())
            except ValueError as exc:
                raise CandidateError(
                    "receipt journal must be inside the candidate workspace"
                ) from exc
            archived_receipt_path = str(destination / "candidate-workspace" / receipt_relative)

        archived_at = superseded_at or datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        additions = {
            "supersededAt": archived_at,
            "supersededReason": reason,
            "archivePath": str(destination),
        }
        if archived_receipt_path is not None:
            additions["archivedReceiptJournalPath"] = archived_receipt_path
        archived_metadata = _extend_metadata(
            metadata,
            additions,
        )
        archived = CandidateRecord(
            current.candidate_id,
            CandidateState.SUPERSEDED.value,
            current.source_sha256,
            current.project_sha256,
            current.artifact_sha256,
            current.build,
            current.marketing_version,
            archived_metadata,
        )

        destination.mkdir(mode=0o700, parents=True)
        try:
            print(
                f"==> Archiving assigned candidate {current.candidate_id} workspace and receipt journal",
                file=sys.stderr,
                flush=True,
            )
            shutil.copytree(workspace, destination / "candidate-workspace")
            CandidateLedger(destination / "candidate.json").write(archived)
            print("    Assigned candidate archive complete", file=sys.stderr, flush=True)
        except Exception:
            shutil.rmtree(destination, ignore_errors=True)
            raise
        # This is the final operation. If unlink reports an error after the
        # filesystem has removed the active ledger, preserve the archive so the
        # assigned candidate remains recoverable and auditable.
        self.path.unlink()
        return archived

    def allocate_replacement(self, *args: Any, **kwargs: Any) -> CandidateRecord:
        current = self.load()
        if current is not None and current.state == CandidateState.UPLOADED_UNASSIGNED:
            raise CandidateError(
                "replacement allocation rejected while uploaded candidate is unassigned"
            )
        return self.create(*args, **kwargs)
