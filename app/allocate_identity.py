#!/usr/bin/env -S /Users/dave/.local/bin/uv run --with pyjwt --with cryptography python
"""Allocate one Gradus iOS App Store Connect identity through the fixed broker.

Only the fixed product is accepted.  The script reads the checked-out
Gradus marketing version, performs GET-only ASC requests through the existing
redacting client, and writes one typed proof.  Raw responses and credentials
never leave memory.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from collections.abc import Mapping
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote

from _asc_api import API_BASE, ASCClient, ASCError, make_token_provider
from xcode_cloud_artifact import (
    ArtifactDownloadError,
    download_ci_build_action_result_bundle,
    list_result_bundle_metadata,
)

PRODUCT = "gradus-ios"
BUNDLE_ID = "com.zerodelta.gradus.ios"
EVIDENCE_PATH = Path(".release-state/evidence/allocate-identity.json")
_SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
_POSITIVE_INTEGER = re.compile(r"^[1-9][0-9]*$")


class IdentityAllocationError(ValueError):
    """Raised when the fixed ASC response cannot produce a safe proof."""


def _version_shape(value: Any) -> str:
    """Return a value-free diagnostic category for an invalid version."""

    if not isinstance(value, str):
        return "type"
    if not value:
        return "empty"
    parts = value.split(".")
    if len(parts) != 3:
        return f"components-{len(parts)}"
    if any(not part.isdigit() for part in parts):
        return "nonnumeric"
    if any(len(part) > 1 and part.startswith("0") for part in parts):
        return "leading-zero"
    return "unknown"


def _semver(value: Any, *, label: str) -> tuple[int, int, int]:
    if not isinstance(value, str) or not _SEMVER.fullmatch(value):
        raise IdentityAllocationError(f"{label}-invalid-{_version_shape(value)}")
    return tuple(int(part) for part in value.split("."))  # type: ignore[return-value]


def _remote_semver(value: Any) -> tuple[int, int, int]:
    """Normalize an abbreviated historic ASC version without weakening candidates."""

    if not isinstance(value, str):
        raise IdentityAllocationError(f"remote-marketing-version-invalid-{_version_shape(value)}")
    parts = value.split(".")
    if len(parts) not in (1, 2, 3) or any(not part.isdigit() for part in parts):
        raise IdentityAllocationError(f"remote-marketing-version-invalid-{_version_shape(value)}")
    if any(len(part) > 1 and part.startswith("0") for part in parts):
        raise IdentityAllocationError(f"remote-marketing-version-invalid-{_version_shape(value)}")
    return tuple(int(part) for part in (*parts, "0", "0")[:3])  # type: ignore[return-value]


def _positive_integer(value: Any, *, label: str) -> int:
    if isinstance(value, bool) or not _POSITIVE_INTEGER.fullmatch(str(value)):
        raise IdentityAllocationError(f"{label}-invalid")
    return int(value)


def read_marketing_version(project_path: Path) -> str:
    """Read the fixed GradusiOS marketing version from project.yml."""

    try:
        text = project_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise IdentityAllocationError("project-version-unreadable") from exc
    target = re.search(r"(?m)^  GradusiOS:\s*$", text)
    if target is None:
        raise IdentityAllocationError("project-target-missing")
    next_target = re.search(r"(?m)^  [A-Za-z0-9_]+:\s*$", text[target.end() :])
    section = text[target.end() :]
    if next_target is not None:
        section = section[: next_target.start()]
    match = re.search(r'(?m)^\s+MARKETING_VERSION:\s*["\']?([^"\'\s]+)', section)
    if match is None:
        raise IdentityAllocationError("project-version-missing")
    version = match.group(1)
    _semver(version, label="marketing-version")
    return version


def _one_app(client: ASCClient) -> str:
    payload = client.request("GET", f"/apps?filter[bundleId]={quote(BUNDLE_ID, safe='')}")
    if not isinstance(payload, Mapping) or not isinstance(payload.get("data"), list):
        raise IdentityAllocationError("app-response-invalid")
    entries = payload["data"]
    if len(entries) != 1 or not isinstance(entries[0], Mapping):
        raise IdentityAllocationError("app-identity-ambiguous")
    app_id = entries[0].get("id")
    attributes = entries[0].get("attributes")
    if (
        not isinstance(app_id, str)
        or not app_id
        or not isinstance(attributes, Mapping)
        or attributes.get("bundleId") != BUNDLE_ID
    ):
        raise IdentityAllocationError("app-identity-invalid")
    return app_id


def _next_path(value: Any) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value:
        raise IdentityAllocationError("build-pagination-invalid")
    if value.startswith("/v1/"):
        return value
    if value.startswith(f"{API_BASE}/"):
        return value
    raise IdentityAllocationError("build-pagination-invalid")


def _builds(
    client: ASCClient, app_id: str
) -> tuple[list[Mapping[str, Any]], list[Mapping[str, Any]]]:
    """Read all iOS builds and their included pre-release versions."""

    path = f"/builds?filter[app]={quote(app_id, safe='')}&filter[preReleaseVersion.platform]=IOS&include=preReleaseVersion&limit=200"
    builds: list[Mapping[str, Any]] = []
    prereleases: list[Mapping[str, Any]] = []
    while path is not None:
        payload = client.request("GET", path)
        if not isinstance(payload, Mapping) or not isinstance(payload.get("data"), list):
            raise IdentityAllocationError("build-response-invalid")
        for item in payload["data"]:
            if not isinstance(item, Mapping):
                raise IdentityAllocationError("build-response-invalid")
            builds.append(item)
        included = payload.get("included", [])
        if not isinstance(included, list):
            raise IdentityAllocationError("build-response-invalid")
        for item in included:
            if not isinstance(item, Mapping):
                raise IdentityAllocationError("build-response-invalid")
            prereleases.append(item)
        links = payload.get("links")
        path = _next_path(links.get("next") if isinstance(links, Mapping) else None)
    return builds, prereleases


def _identity_observation(client: ASCClient, app_id: str) -> tuple[str | None, int, bytes]:
    builds, prereleases = _builds(client, app_id)
    versions: dict[str, str] = {}
    for item in prereleases:
        if item.get("type") != "preReleaseVersions":
            continue
        identifier = item.get("id")
        attributes = item.get("attributes")
        if not isinstance(identifier, str) or not identifier or not isinstance(attributes, Mapping):
            raise IdentityAllocationError("prerelease-response-invalid")
        version = attributes.get("version")
        platform = attributes.get("platform")
        _remote_semver(version)
        if platform != "IOS":
            raise IdentityAllocationError("prerelease-platform-invalid")
        versions[identifier] = str(version)

    highest_version: str | None = None
    highest_key: tuple[int, int, int] | None = None
    highest_build = 0
    normalized: list[dict[str, Any]] = []
    for item in builds:
        identifier = item.get("id")
        attributes = item.get("attributes")
        relationships = item.get("relationships")
        if (
            not isinstance(identifier, str)
            or not identifier
            or not isinstance(attributes, Mapping)
            or not isinstance(relationships, Mapping)
        ):
            raise IdentityAllocationError("build-response-invalid")
        build = _positive_integer(attributes.get("version"), label="remote-build")
        relation = relationships.get("preReleaseVersion")
        relation_data = relation.get("data") if isinstance(relation, Mapping) else None
        prerelease_id = relation_data.get("id") if isinstance(relation_data, Mapping) else None
        if not isinstance(prerelease_id, str) or prerelease_id not in versions:
            raise IdentityAllocationError("build-prerelease-binding-invalid")
        marketing_version = versions[prerelease_id]
        version_key = _remote_semver(marketing_version)
        if highest_key is None or version_key > highest_key:
            highest_key = version_key
            highest_version = marketing_version
        highest_build = max(highest_build, build)
        normalized.append({"id": identifier, "build": build, "marketingVersion": marketing_version})
    response_material = json.dumps(
        {"appId": app_id, "builds": normalized}, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return highest_version, highest_build, response_material


def make_proof(
    client: ASCClient,
    *,
    product: str,
    marketing_version: str,
    observed_at: str | None = None,
) -> dict[str, Any]:
    """Build one exact central identity-allocation operation proof."""

    if product != PRODUCT:
        raise IdentityAllocationError("product-unsupported")
    _semver(marketing_version, label="marketing-version")
    app_id = _one_app(client)
    remote_version, remote_build, response_material = _identity_observation(client, app_id)
    proof = {
        "proofVersion": "1.0.0",
        "operationClass": "identityAllocation",
        "result": "passed",
        "marketingVersion": marketing_version,
        "buildNumber": remote_build + 1,
        "responseSha256": hashlib.sha256(response_material).hexdigest(),
        "productKey": product,
        "remoteHighestMarketingVersion": remote_version,
        "remoteHighestBuildNumber": remote_build,
        "observedAt": observed_at
        or datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    }
    return proof


def write_proof(path: Path, proof: Mapping[str, Any]) -> None:
    """Create the fixed evidence file exclusively without overwriting it."""

    encoded = json.dumps(dict(proof), sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = -1
    try:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o400)
    except FileExistsError as exc:
        raise IdentityAllocationError("identity-proof-already-exists") from exc
    try:
        with os.fdopen(descriptor, "wb") as handle:
            descriptor = -1
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="allocate_identity")
    parser.add_argument("--product", choices=(PRODUCT,), required=False)
    parser.add_argument(
        "--ci-build-action-id",
        "--ci-build-action",
        "--build-action-id",
        "--build-action",
        "--action-id",
        dest="ci_build_action_id",
        required=False,
        help="Xcode Cloud CI build action UUID",
    )
    parser.add_argument(
        "--output-dir",
        "--output-directory",
        "--output",
        "-o",
        dest="output_dir",
        required=False,
        help="Explicit output directory for downloaded artifact",
    )
    parser.add_argument("--ci-artifact-id", help="Exact RESULT_BUNDLE artifact ID")
    parser.add_argument(
        "--list-result-bundles",
        action="store_true",
        help="Print safe RESULT_BUNDLE metadata without download URLs",
    )
    args = parser.parse_args(argv)

    if args.product and (
        args.ci_build_action_id
        or args.output_dir
        or args.ci_artifact_id
        or args.list_result_bundles
    ):
        print(
            "FAIL: cannot combine --product with artifact download options",
            file=sys.stderr,
        )
        return 1

    if args.product is not None:
        try:
            project_root = Path.cwd()
            proof = make_proof(
                ASCClient(make_token_provider()),
                product=args.product,
                marketing_version=read_marketing_version(project_root / "app" / "project.yml"),
            )
            write_proof(project_root / EVIDENCE_PATH, proof)
        except ASCError as exc:
            # Emit only the typed transport classification.  The broker boundary
            # needs an actionable failure code, never an ASC response body or
            # credential-bearing diagnostic.
            print(f"FAIL: identity allocation failed ({exc.outcome.error_class})", file=sys.stderr)
            return 1
        except IdentityAllocationError as exc:
            print(f"FAIL: identity allocation failed ({exc})", file=sys.stderr)
            return 1
        except (OSError, ValueError):
            print("FAIL: identity allocation failed", file=sys.stderr)
            return 1
        return 0

    if args.ci_build_action_id is not None and args.list_result_bundles:
        if args.output_dir is not None or args.ci_artifact_id is not None:
            print("FAIL: listing result bundles does not accept download options", file=sys.stderr)
            return 1
        try:
            metadata = list_result_bundle_metadata(
                ASCClient(make_token_provider()), args.ci_build_action_id
            )
            print(json.dumps(metadata, sort_keys=True, separators=(",", ":")))
            return 0
        except ASCError as exc:
            print(f"FAIL: artifact listing failed ({exc.outcome.error_class})", file=sys.stderr)
            return 1
        except ArtifactDownloadError as exc:
            print(f"FAIL: artifact listing failed ({exc})", file=sys.stderr)
            return 1

    if args.ci_build_action_id is not None and args.output_dir is not None:
        try:
            client = ASCClient(make_token_provider())
            destination = download_ci_build_action_result_bundle(
                client,
                action_id=args.ci_build_action_id,
                output_dir=Path(args.output_dir),
                artifact_id=args.ci_artifact_id,
            )
            print(str(destination))
            return 0
        except ASCError as exc:
            print(f"FAIL: artifact download failed ({exc.outcome.error_class})", file=sys.stderr)
            return 1
        except ArtifactDownloadError as exc:
            print(f"FAIL: artifact download failed ({exc})", file=sys.stderr)
            return 1
        except (OSError, ValueError):
            print("FAIL: artifact download failed", file=sys.stderr)
            return 1

    print(
        "FAIL: either --product, --list-result-bundles with an action ID, or an action ID with --output-dir is required",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
