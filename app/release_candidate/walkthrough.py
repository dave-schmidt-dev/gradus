"""Generate a deterministic, candidate-bound release-owner walkthrough.

The walkthrough is deliberately data driven.  The route manifest is the release
owner's inventory of reachable UI, while this module binds that inventory to
one immutable candidate tuple before it is written.  It never launches an app,
contacts Apple, or treats a generic date-only document as current evidence.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any

from .ledger import CandidateError, CandidateLedger, CandidateRecord


class WalkthroughError(ValueError):
    """Raised when candidate identity or route coverage is incomplete."""


_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_VERSION = re.compile(r"^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$")
_TERMINAL_STATES = frozenset({"failed", "abandoned", "superseded"})
_REQUIRED_MANIFEST_SECTIONS = ("onboarding", "screens", "roles", "states", "systemOwnedSheets")


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _digest_file(path: str | Path) -> str:
    digest = hashlib.sha256()
    try:
        with Path(path).open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as exc:
        raise WalkthroughError(f"artifact is unreadable: {path}") from exc
    return digest.hexdigest()


def _text(mapping: Mapping[str, Any], *names: str, label: str) -> str:
    for name in names:
        value = mapping.get(name)
        if isinstance(value, str) and value.strip():
            return value.strip()
    raise WalkthroughError(f"missing candidate {label}")


def _sha(mapping: Mapping[str, Any], *names: str, label: str) -> str:
    value = _text(mapping, *names, label=label)
    if not _SHA256.fullmatch(value):
        raise WalkthroughError(f"candidate {label} is not a SHA-256 digest")
    return value


def _positive_int(mapping: Mapping[str, Any], *names: str, label: str) -> int:
    value: Any = None
    for name in names:
        if name in mapping:
            value = mapping[name]
            break
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise WalkthroughError(f"missing candidate {label}")
    if isinstance(value, str) and (not value.isdigit() or value.startswith("0")):
        raise WalkthroughError(f"candidate {label} must be a positive integer")
    result = int(value)
    if result < 1:
        raise WalkthroughError(f"candidate {label} must be a positive integer")
    return result


@dataclass(frozen=True)
class CandidateTuple:
    """The non-secret identity which a walkthrough is allowed to describe."""

    candidate_id: str
    source_revision: str
    project_sha256: str
    artifact_sha256: str
    build: int
    marketing_version: str

    @classmethod
    def from_mapping(cls, data: Mapping[str, Any]) -> CandidateTuple:
        if not isinstance(data, Mapping):
            raise WalkthroughError("candidate tuple must be an object")
        candidate_id = _text(data, "candidateId", "candidate_id", label="id")
        source_revision = _text(data, "sourceRevision", "source_revision", label="source revision")
        project = _sha(data, "projectSha256", "project_sha256", label="project digest")
        artifact = _sha(
            data,
            "artifactSha256",
            "artifact_sha256",
            "ipaSha256",
            "ipa_sha256",
            label="artifact digest",
        )
        build = _positive_int(data, "build", "iosBuild", "ios_build", label="build")
        version = _text(data, "marketingVersion", "marketing_version", label="marketing version")
        if not _VERSION.fullmatch(version):
            raise WalkthroughError(
                "candidate marketing version must be numeric MAJOR.MINOR.PATCH text"
            )
        return cls(candidate_id, source_revision, project, artifact, build, version)

    @classmethod
    def from_record(cls, record: CandidateRecord) -> CandidateTuple:
        metadata = record.metadata or {}
        source = metadata.get("sourceRevision", metadata.get("source_revision"))
        if not isinstance(source, str) or not source.strip():
            raise WalkthroughError("candidate ledger is missing source revision evidence")
        if record.build is None or not record.marketing_version:
            raise WalkthroughError("candidate ledger is missing build or marketing version")
        return cls(
            record.candidate_id,
            source.strip(),
            record.project_sha256,
            record.artifact_sha256,
            record.build,
            record.marketing_version,
        )

    def as_dict(self) -> dict[str, Any]:
        return {
            "candidateId": self.candidate_id,
            "sourceRevision": self.source_revision,
            "sourceRevisionSha256": _sha256_bytes(self.source_revision.encode()),
            "projectSha256": self.project_sha256,
            "artifactSha256": self.artifact_sha256,
            "build": self.build,
            "marketingVersion": self.marketing_version,
        }


def default_manifest() -> dict[str, Any]:
    """Return the current Gradus app's explicit reachable-route inventory."""

    def control(identifier, label, *, roles=("all",), state="enabled", recovery=False):
        return {
            "id": identifier,
            "label": label,
            "roles": list(roles),
            "state": state,
            "recovery": recovery,
        }

    return {
        "onboarding": [
            {
                "id": "first-launch",
                "title": "First launch",
                "controls": [
                    control("request-notifications", "Allow notifications", state="permission"),
                    control("enable-sync", "Enable iCloud Sync", state="permission"),
                ],
            }
        ],
        "screens": [
            {
                "id": "dashboard",
                "title": "Now dashboard",
                "controls": [
                    control("provider-row", "Open provider details"),
                    control("settings", "Open Settings"),
                ],
            },
            {
                "id": "provider-detail",
                "title": "Provider detail",
                "controls": [control("back", "Back")],
            },
            {
                "id": "ios-settings",
                "title": "Settings",
                "controls": [
                    control("sort-providers", "Sort providers"),
                    control("show-exhausted", "Show exhausted"),
                    control("warning-threshold", "Warning threshold"),
                    control("notifications", "Notifications", state="permission"),
                    control(
                        "open-ios-settings", "Open iOS Settings", state="disabled", recovery=True
                    ),
                    control("sync", "Enable iCloud Sync", state="permission"),
                ],
            },
            {
                "id": "mac-menu",
                "title": "Gradus menu",
                "controls": [
                    control("mac-sync", "Enable iCloud Sync", state="permission"),
                    control("mac-settings", "Settings"),
                    control("quit", "Quit Gradus"),
                ],
            },
            {
                "id": "mac-settings",
                "title": "Gradus Settings",
                "controls": [
                    control("mac-sort", "Sort providers"),
                    control("mac-show-exhausted", "Show exhausted"),
                ],
            },
        ],
        "roles": [
            {"id": "all", "name": "All users", "permissions": ["view", "change-local-preferences"]},
            {
                "id": "icloud-signed-out",
                "name": "iCloud signed out",
                "permissions": ["view", "open-system-settings"],
            },
            {
                "id": "notifications-denied",
                "name": "Notifications denied",
                "permissions": ["view", "open-system-settings"],
            },
        ],
        "states": [
            {"id": "enabled", "label": "Enabled"},
            {"id": "empty", "label": "No synced data"},
            {"id": "offline", "label": "Offline cached data"},
            {"id": "disabled", "label": "Disabled"},
            {"id": "permission", "label": "Permission required"},
            {"id": "recovery", "label": "Recovery"},
        ],
        "systemOwnedSheets": [
            {
                "id": "notification-permission",
                "owner": "iOS",
                "trigger": "first launch notification request",
            },
            {
                "id": "icloud-settings",
                "owner": "iOS",
                "trigger": "Open Settings from empty/restricted state",
            },
            {"id": "mac-settings-window", "owner": "macOS", "trigger": "Settings from menu"},
        ],
    }


def _items(value: Any, section: str) -> list[Mapping[str, Any]]:
    if not isinstance(value, list) or not value:
        raise WalkthroughError(f"walkthrough coverage section is empty: {section}")
    if any(not isinstance(item, Mapping) for item in value):
        raise WalkthroughError(f"walkthrough coverage section is malformed: {section}")
    return list(value)


def validate_manifest(manifest: Mapping[str, Any]) -> dict[str, Any]:
    """Validate route/control, role, state, and system-sheet completeness."""
    if not isinstance(manifest, Mapping):
        raise WalkthroughError("walkthrough manifest must be an object")
    missing = [section for section in _REQUIRED_MANIFEST_SECTIONS if section not in manifest]
    if missing:
        raise WalkthroughError(f"walkthrough coverage is missing: {', '.join(missing)}")
    onboarding = _items(manifest["onboarding"], "onboarding")
    screens = _items(manifest["screens"], "screens")
    roles = _items(manifest["roles"], "roles")
    states = _items(manifest["states"], "states")
    sheets = _items(manifest["systemOwnedSheets"], "systemOwnedSheets")
    seen_routes: set[str] = set()
    for route in [*onboarding, *screens]:
        identifier = _text(route, "id", label="route id")
        if identifier in seen_routes:
            raise WalkthroughError(f"duplicate reachable route: {identifier}")
        seen_routes.add(identifier)
        controls = _items(route.get("controls"), f"controls for {identifier}")
        control_ids: set[str] = set()
        for item in controls:
            control_id = _text(item, "id", label=f"control id in {identifier}")
            if control_id in control_ids:
                raise WalkthroughError(f"duplicate control in {identifier}: {control_id}")
            control_ids.add(control_id)
            _text(item, "label", "title", label=f"control label for {identifier}/{control_id}")
            _text(item, "state", label=f"control state for {identifier}/{control_id}")
            roles_for_control = item.get("roles")
            if not isinstance(roles_for_control, list) or not roles_for_control:
                raise WalkthroughError(f"control has no role coverage: {identifier}/{control_id}")
    state_ids = {_text(item, "id", label="state id") for item in states}
    if not {"disabled", "recovery"}.issubset(state_ids):
        raise WalkthroughError("coverage must include disabled and recovery states")
    role_ids = {_text(item, "id", label="role id") for item in roles}
    if "all" not in role_ids:
        raise WalkthroughError("coverage must include the all-users role")
    for route in [*onboarding, *screens]:
        for control in route["controls"]:
            unknown_roles = set(control["roles"]) - role_ids
            if unknown_roles:
                raise WalkthroughError(
                    f"control references unknown roles: {', '.join(sorted(unknown_roles))}"
                )
            if control["state"] not in state_ids:
                raise WalkthroughError(f"control references unknown state: {control['state']}")
    for sheet in sheets:
        _text(sheet, "id", label="system-sheet id")
        _text(sheet, "owner", label="system-sheet owner")
        _text(sheet, "trigger", label="system-sheet trigger")
    return json.loads(json.dumps(manifest, sort_keys=True, separators=(",", ":")))


def _load_manifest(path: str | Path | None) -> Mapping[str, Any]:
    if path is None:
        return default_manifest()
    try:
        with Path(path).open(encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise WalkthroughError(f"cannot read walkthrough manifest: {path}") from exc
    return value


def _candidate_from_input(
    ledger: CandidateLedger, candidate: Mapping[str, Any] | None
) -> tuple[CandidateRecord, CandidateTuple]:
    record = ledger.load()
    if record is None:
        raise WalkthroughError("candidate ledger is missing")
    if record.state in _TERMINAL_STATES:
        raise WalkthroughError(f"candidate is not current in state {record.state}")
    if candidate is not None and not any(
        name in candidate for name in ("candidateId", "candidate_id")
    ):
        candidate = {"candidateId": record.candidate_id, **candidate}
    tuple_value = (
        CandidateTuple.from_mapping(candidate)
        if candidate is not None
        else CandidateTuple.from_record(record)
    )
    if tuple_value.candidate_id != record.candidate_id:
        raise WalkthroughError("candidate id mismatch")
    if tuple_value.project_sha256 != record.project_sha256:
        raise WalkthroughError("candidate project digest mismatch")
    if tuple_value.artifact_sha256 != record.artifact_sha256:
        raise WalkthroughError("candidate artifact digest mismatch")
    if (
        record.build != tuple_value.build
        or record.marketing_version != tuple_value.marketing_version
    ):
        raise WalkthroughError("candidate build or marketing version mismatch")
    metadata = record.metadata or {}
    recorded_source = metadata.get("sourceRevision", metadata.get("source_revision"))
    if recorded_source != tuple_value.source_revision:
        raise WalkthroughError("candidate source revision mismatch")
    return record, tuple_value


def render_walkthrough(
    tuple_value: CandidateTuple, manifest: Mapping[str, Any], *, generated_on: date
) -> bytes:
    """Render stable Markdown; only the supplied date changes the dated header."""
    normalized = validate_manifest(manifest)
    lines = [
        "# Gradus internal TestFlight candidate walkthrough",
        "",
        f"- Candidate: `{tuple_value.candidate_id}`",
        f"- Marketing version/build: `{tuple_value.marketing_version}` / `{tuple_value.build}`",
        f"- Source revision: `{tuple_value.source_revision}`",
        f"- Source revision SHA-256: `{_sha256_bytes(tuple_value.source_revision.encode())}`",
        f"- Project SHA-256: `{tuple_value.project_sha256}`",
        f"- Artifact SHA-256: `{tuple_value.artifact_sha256}`",
        f"- Generated on: `{generated_on.isoformat()}`",
        "- Scope: internal TestFlight only; App Store submission and public release are excluded.",
        "",
        "## Release-owner review gate",
        "",
        "Review every route, control, role, disabled/recovery state, and system-owned sheet on the exact candidate artifact before authorizing TestFlight. This document is evidence for review, not proof of Apple processing or installability.",
        "",
    ]
    for section, heading in (
        ("onboarding", "Onboarding"),
        ("screens", "Reachable screens and controls"),
        ("roles", "Role and permission differences"),
        ("states", "Disabled and recovery states"),
        ("systemOwnedSheets", "System-owned sheets"),
    ):
        lines.extend([f"## {heading}", ""])
        for item in normalized[section]:
            identifier = item["id"]
            title = item.get("title", item.get("name", identifier))
            lines.append(f"### `{identifier}`: {title}")
            for key in ("owner", "trigger", "permissions", "label"):
                if key in item:
                    value = item[key]
                    lines.append(
                        f"- {key}: `{json.dumps(value, sort_keys=True) if isinstance(value, (list, dict)) else value}`"
                    )
            for control in item.get("controls", []):
                roles = ", ".join(control["roles"])
                recovery = "; recovery path required" if control.get("recovery") else ""
                lines.append(
                    f"- [ ] Control `{control['id']}` ({control.get('label', control.get('title', control['id']))}); roles: `{roles}`; state: `{control['state']}`{recovery}"
                )
            lines.append("")
    return ("\n".join(lines).rstrip() + "\n").encode()


def generate_walkthrough(
    ledger: CandidateLedger,
    artifact_path: str | Path,
    *,
    source_revision: str | None = None,
    candidate: Mapping[str, Any] | None = None,
    manifest: Mapping[str, Any] | None = None,
    output_path: str | Path,
    generated_on: date | None = None,
) -> dict[str, Any]:
    """Validate, render, hash, and bind one walkthrough to a candidate ledger."""
    record = ledger.load()
    if record is None:
        raise WalkthroughError("candidate ledger is missing")
    if candidate is None and source_revision is not None:
        candidate = {
            **CandidateTuple.from_record(record).as_dict(),
            "sourceRevision": source_revision,
        }
    record, tuple_value = _candidate_from_input(ledger, candidate)
    if source_revision is not None and source_revision != tuple_value.source_revision:
        raise WalkthroughError("source revision mismatch")
    actual_artifact = _digest_file(artifact_path)
    if actual_artifact != tuple_value.artifact_sha256:
        raise WalkthroughError("artifact bytes do not match candidate tuple")
    effective_date = generated_on or datetime.now(timezone.utc).date()
    content = render_walkthrough(
        tuple_value, manifest or default_manifest(), generated_on=effective_date
    )
    digest = _sha256_bytes(content)
    output = Path(output_path)
    metadata = dict(record.metadata or {})
    existing = metadata.get("walkthrough")
    prior_digests = [metadata.get("walkthroughSha256")]
    prior_digests.append(existing.get("sha256") if isinstance(existing, Mapping) else existing)
    if any(prior is not None and prior != digest for prior in prior_digests):
        raise WalkthroughError("candidate already contains a different walkthrough digest")
    output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    output.write_bytes(content)
    metadata["walkthrough"] = {
        "path": str(output),
        "sha256": digest,
        "generatedOn": effective_date.isoformat(),
    }
    metadata["walkthroughPath"] = str(output)
    metadata["walkthroughSha256"] = digest
    ledger.write(
        CandidateRecord(
            record.candidate_id,
            record.state,
            record.source_sha256,
            record.project_sha256,
            record.artifact_sha256,
            record.build,
            record.marketing_version,
            metadata,
        )
    )
    return {
        "candidateId": tuple_value.candidate_id,
        "sourceRevision": tuple_value.source_revision,
        "artifactSha256": actual_artifact,
        "walkthroughPath": str(output),
        "walkthroughSha256": digest,
        "generatedOn": metadata["walkthrough"]["generatedOn"],
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ledger", required=True, type=Path)
    parser.add_argument("--artifact", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--source-revision")
    parser.add_argument(
        "--candidate",
        type=Path,
        help="JSON candidate tuple; required unless ledger metadata is complete",
    )
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--date", type=date.fromisoformat, dest="generated_on")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        candidate = None
        if args.candidate:
            with args.candidate.open(encoding="utf-8") as handle:
                candidate = json.load(handle)
        result = generate_walkthrough(
            CandidateLedger(args.ledger),
            args.artifact,
            source_revision=args.source_revision,
            candidate=candidate,
            manifest=_load_manifest(args.manifest),
            output_path=args.output,
            generated_on=args.generated_on,
        )
    except (CandidateError, OSError, json.JSONDecodeError, WalkthroughError) as exc:
        print(f"walkthrough: {exc}")
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
