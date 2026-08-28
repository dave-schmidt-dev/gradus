#!/usr/bin/env -S /Users/dave/.local/bin/uv run --with pyjwt --with cryptography python
"""Allocate one Gradus iOS App Store Connect identity through the fixed broker.

Only the fixed product is accepted.  The script reads the checked-out
Gradus marketing version, performs GET-only ASC requests through the existing
redacting client, and writes one typed proof.  Raw responses and credentials
never leave memory.
"""

from __future__ import annotations

import argparse
import base64
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
WIDGET_BUNDLE_ID = "com.zerodelta.gradus.ios.widget"
WIDGET_PROFILE_NAME = "Gradus Widget App Store (API-created)"
WIDGET_PROFILE_FILENAME = "gradus-widget-app-store.provisionprofile"
IOS_APP_GROUP_PROFILE_NAME = "Gradus iOS App Store App Group (API-created)"
IOS_APP_PROFILE_FILENAME = "gradus-ios-app-store.provisionprofile"
DISTRIBUTION_CERTIFICATE_SHA1 = "FD247ACDEBCD05C725AE29B40218FB0F57807A2C"
EVIDENCE_PATH = Path(".release-state/evidence/allocate-identity.json")
TESTFLIGHT_WORKFLOW_NAME = "Gradus iOS Internal TestFlight"
_SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
_POSITIVE_INTEGER = re.compile(r"^[1-9][0-9]*$")


class IdentityAllocationError(ValueError):
    """Raised when the fixed ASC response cannot produce a safe proof."""


def _asc_error_label(error: ASCError) -> str:
    """Return a response-body-free ASC diagnostic label for attended release failures."""

    code = error.outcome.diagnostic_code
    return error.outcome.error_class if code is None else f"{error.outcome.error_class}-{code}"


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


def ensure_distribution_profile(
    client: ASCClient,
    profiles_dir: Path,
    *,
    bundle_identifier: str,
    profile_name: str,
    profile_filename: str,
) -> dict[str, str | bool]:
    """Create or refresh one exact Gradus App Store provisioning profile."""

    bundle_payload = client.request(
        "GET", f"/bundleIds?filter[identifier]={quote(bundle_identifier, safe='')}&limit=200"
    )
    bundle_data = bundle_payload.get("data") if isinstance(bundle_payload, Mapping) else None
    if not isinstance(bundle_data, list):
        raise IdentityAllocationError("profile-bundle-list-invalid")
    if not bundle_data:
        raise IdentityAllocationError("profile-bundle-list-empty")
    candidate_ids: list[str] = []
    for candidate in bundle_data:
        if (
            not isinstance(candidate, Mapping)
            or candidate.get("type") != "bundleIds"
            or not isinstance(candidate.get("id"), str)
            or not candidate["id"]
        ):
            raise IdentityAllocationError("profile-bundle-list-invalid")
        candidate_ids.append(candidate["id"])
    if len(set(candidate_ids)) != len(candidate_ids):
        raise IdentityAllocationError("profile-bundle-list-ambiguous")
    matching_bundle_ids: list[str] = []
    for candidate_id in candidate_ids:
        bundle = client.request("GET", f"/bundleIds/{candidate_id}")
        detail = bundle.get("data") if isinstance(bundle, Mapping) else None
        if (
            not isinstance(detail, Mapping)
            or detail.get("type") != "bundleIds"
            or detail.get("id") != candidate_id
            or not isinstance(detail.get("attributes"), Mapping)
            or not isinstance(detail["attributes"].get("identifier"), str)
        ):
            raise IdentityAllocationError("profile-bundle-detail-invalid")
        if detail["attributes"]["identifier"] == bundle_identifier:
            matching_bundle_ids.append(candidate_id)
    if not matching_bundle_ids:
        raise IdentityAllocationError("profile-bundle-identity-missing")
    if len(matching_bundle_ids) != 1:
        raise IdentityAllocationError("profile-bundle-identity-ambiguous")
    bundle_id = matching_bundle_ids[0]

    certificates = client.request(
        "GET", "/certificates?filter[certificateType]=DISTRIBUTION&limit=50"
    )
    certificate_data = certificates.get("data") if isinstance(certificates, Mapping) else None
    if not isinstance(certificate_data, list):
        raise IdentityAllocationError("widget-profile-certificate-ambiguous")
    certificate_ids = [
        certificate["id"]
        for certificate in certificate_data
        if isinstance(certificate, Mapping)
        and certificate.get("type") == "certificates"
        and isinstance(certificate.get("id"), str)
        and certificate.get("id")
    ]
    if len(certificate_ids) != len(certificate_data) or not certificate_ids:
        raise IdentityAllocationError("widget-profile-certificate-ambiguous")
    matching_certificate_ids: list[str] = []
    for candidate_id in certificate_ids:
        certificate = client.request("GET", f"/certificates/{candidate_id}")
        content = (
            certificate.get("data", {}).get("attributes", {}).get("certificateContent")
            if isinstance(certificate, Mapping)
            else None
        )
        if not isinstance(content, str):
            raise IdentityAllocationError("widget-profile-certificate-content-invalid")
        try:
            certificate_der = base64.b64decode(content, validate=True)
        except (ValueError, UnicodeError) as exc:
            raise IdentityAllocationError("widget-profile-certificate-content-invalid") from exc
        if hashlib.sha1(certificate_der).hexdigest().upper() == DISTRIBUTION_CERTIFICATE_SHA1:
            matching_certificate_ids.append(candidate_id)
    if len(matching_certificate_ids) != 1:
        raise IdentityAllocationError("widget-profile-signing-certificate-unavailable")
    certificate_id = matching_certificate_ids[0]

    listed = client.request("GET", f"/bundleIds/{bundle_id}/profiles")
    profile_data = listed.get("data") if isinstance(listed, Mapping) else None
    if not isinstance(profile_data, list):
        raise IdentityAllocationError("widget-profile-list-invalid")
    matches = [
        profile
        for profile in profile_data
        if isinstance(profile, Mapping)
        and profile.get("type") == "profiles"
        and isinstance(profile.get("id"), str)
        and isinstance(profile.get("attributes"), Mapping)
        and profile["attributes"].get("name") == profile_name
        and profile["attributes"].get("profileType") == "IOS_APP_STORE"
    ]
    if len(matches) > 1:
        raise IdentityAllocationError("widget-profile-ambiguous")
    created = not matches
    if matches:
        profile = client.request("GET", f"/profiles/{matches[0]['id']}")
    else:
        profile = client.request(
            "POST",
            "/profiles",
            {
                "data": {
                    "type": "profiles",
                    "attributes": {
                        "name": profile_name,
                        "profileType": "IOS_APP_STORE",
                    },
                    "relationships": {
                        "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
                        "certificates": {"data": [{"type": "certificates", "id": certificate_id}]},
                    },
                }
            },
            idempotent=False,
        )
    content = (
        profile.get("data", {}).get("attributes", {}).get("profileContent")
        if isinstance(profile, Mapping)
        else None
    )
    if not isinstance(content, str):
        raise IdentityAllocationError("widget-profile-content-invalid")
    try:
        raw_profile = base64.b64decode(content, validate=True)
    except (ValueError, UnicodeError) as exc:
        raise IdentityAllocationError("widget-profile-content-invalid") from exc
    if not raw_profile:
        raise IdentityAllocationError("widget-profile-content-invalid")
    profiles_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    destination = profiles_dir / profile_filename
    temporary = destination.with_name(f".{destination.name}.tmp")
    try:
        temporary.write_bytes(raw_profile)
        temporary.chmod(0o600)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    return {
        "bundleId": bundle_identifier,
        "created": created,
        "profileFilename": profile_filename,
    }


def ensure_widget_distribution_profile(
    client: ASCClient, profiles_dir: Path
) -> dict[str, str | bool]:
    """Create or refresh the dedicated GradusWidget App Store profile."""

    return ensure_distribution_profile(
        client,
        profiles_dir,
        bundle_identifier=WIDGET_BUNDLE_ID,
        profile_name=WIDGET_PROFILE_NAME,
        profile_filename=WIDGET_PROFILE_FILENAME,
    )


def ensure_ios_app_group_distribution_profile(
    client: ASCClient, profiles_dir: Path
) -> dict[str, str | bool]:
    """Refresh the main iOS profile after its App Group capability changed."""

    return ensure_distribution_profile(
        client,
        profiles_dir,
        bundle_identifier=BUNDLE_ID,
        profile_name=IOS_APP_GROUP_PROFILE_NAME,
        profile_filename=IOS_APP_PROFILE_FILENAME,
    )


def _one_ci_product(client: ASCClient, app_id: str) -> str:
    """Resolve the Xcode Cloud product that belongs to one fixed app."""

    payload = client.request(
        "GET",
        f"/ciProducts?filter[app]={quote(app_id, safe='')}&fields[ciProducts]=app&limit=200",
    )
    if not isinstance(payload, Mapping) or not isinstance(payload.get("data"), list):
        raise IdentityAllocationError("ci-product-response-invalid")
    products = payload["data"]
    if not products:
        raise IdentityAllocationError("ci-product-missing")
    if len(products) != 1 or not isinstance(products[0], Mapping):
        raise IdentityAllocationError("ci-product-ambiguous")
    product = products[0]
    if product.get("type") != "ciProducts":
        raise IdentityAllocationError("ci-product-response-invalid")
    product_id = product.get("id")
    if not isinstance(product_id, str) or not product_id:
        raise IdentityAllocationError("ci-product-response-invalid")
    return product_id


def list_cloud_product_metadata(client: ASCClient) -> list[dict[str, str]]:
    """List only the metadata needed to choose an existing Cloud product."""

    payload = client.request(
        "GET",
        "/ciProducts?fields[ciProducts]=name,productType&limit=200",
    )
    if not isinstance(payload, Mapping) or not isinstance(payload.get("data"), list):
        raise IdentityAllocationError("ci-products-response-invalid")
    products: list[dict[str, str]] = []
    seen_ids: set[str] = set()
    for product in payload["data"]:
        if not isinstance(product, Mapping):
            raise IdentityAllocationError("ci-products-response-invalid")
        product_id = product.get("id")
        attributes = product.get("attributes")
        if (
            product.get("type") != "ciProducts"
            or not isinstance(product_id, str)
            or not product_id
            or product_id in seen_ids
            or not isinstance(attributes, Mapping)
        ):
            raise IdentityAllocationError("ci-products-response-ambiguous")
        name = attributes.get("name")
        product_type = attributes.get("productType")
        if (
            not isinstance(name, str)
            or not name
            or not isinstance(product_type, str)
            or not product_type
        ):
            raise IdentityAllocationError("ci-products-response-invalid")
        seen_ids.add(product_id)
        products.append({"id": product_id, "name": name, "productType": product_type})
    return products


def _workflow_next_path(value: Any) -> str | None:
    """Validate a workflow-list pagination link before issuing it."""

    if value is None:
        return None
    if not isinstance(value, str) or not value:
        raise IdentityAllocationError("workflow-pagination-invalid")
    if value.startswith("/v1/") or value.startswith(f"{API_BASE}/"):
        return value
    raise IdentityAllocationError("workflow-pagination-invalid")


def _manual_start_present(attributes: Mapping[str, Any]) -> bool:
    """Return whether any supported manual-start condition is configured."""

    present = False
    for name in (
        "manualBranchStartCondition",
        "manualTagStartCondition",
        "manualPullRequestStartCondition",
    ):
        condition = attributes.get(name)
        if condition is None:
            continue
        if not isinstance(condition, Mapping):
            raise IdentityAllocationError("workflow-manual-start-invalid")
        present = True
    return present


def _archive_actions(attributes: Mapping[str, Any]) -> list[dict[str, str]]:
    """Extract only the allowlisted fields from archive workflow actions."""

    actions = attributes.get("actions")
    if not isinstance(actions, list):
        raise IdentityAllocationError("workflow-actions-invalid")
    archive_actions: list[dict[str, str]] = []
    for action in actions:
        if not isinstance(action, Mapping):
            raise IdentityAllocationError("workflow-actions-invalid")
        action_type = action.get("actionType")
        if not isinstance(action_type, str):
            raise IdentityAllocationError("workflow-actions-invalid")
        if action_type != "ARCHIVE":
            continue
        platform = action.get("platform")
        scheme = action.get("scheme")
        audience = action.get("buildDistributionAudience")
        if (
            not isinstance(platform, str)
            or not platform
            or not isinstance(scheme, str)
            or not scheme
            or not isinstance(audience, str)
            or not audience
        ):
            raise IdentityAllocationError("workflow-archive-action-invalid")
        archive_actions.append(
            {
                "platform": platform,
                "scheme": scheme,
                "distributionAudience": audience,
            }
        )
    return archive_actions


def list_product_workflow_metadata(client: ASCClient, product_id: str) -> list[dict[str, Any]]:
    """List allowlisted workflow metadata for one validated Cloud product."""

    if not isinstance(product_id, str) or not product_id:
        raise IdentityAllocationError("ci-product-id-invalid")
    path = (
        f"/ciProducts/{quote(product_id, safe='')}/workflows?"
        "fields[ciWorkflows]="
        "name,isEnabled,manualBranchStartCondition,manualTagStartCondition,"
        "manualPullRequestStartCondition,actions&limit=200"
    )
    seen_paths: set[str] = set()
    workflow_ids: set[str] = set()
    workflows: list[dict[str, Any]] = []
    while path is not None:
        if path in seen_paths:
            raise IdentityAllocationError("workflow-pagination-ambiguous")
        seen_paths.add(path)
        payload = client.request("GET", path)
        if not isinstance(payload, Mapping) or not isinstance(payload.get("data"), list):
            raise IdentityAllocationError("workflow-response-invalid")
        for workflow in payload["data"]:
            if not isinstance(workflow, Mapping):
                raise IdentityAllocationError("workflow-response-invalid")
            workflow_id = workflow.get("id")
            attributes = workflow.get("attributes")
            if (
                workflow.get("type") != "ciWorkflows"
                or not isinstance(workflow_id, str)
                or not workflow_id
                or workflow_id in workflow_ids
                or not isinstance(attributes, Mapping)
            ):
                raise IdentityAllocationError("workflow-response-ambiguous")
            name = attributes.get("name")
            enabled = attributes.get("isEnabled")
            if not isinstance(name, str) or not name or not isinstance(enabled, bool):
                raise IdentityAllocationError("workflow-response-invalid")
            workflow_ids.add(workflow_id)
            workflows.append(
                {
                    "id": workflow_id,
                    "name": name,
                    "isEnabled": enabled,
                    "hasManualStart": _manual_start_present(attributes),
                    "archiveActions": _archive_actions(attributes),
                }
            )
        links = payload.get("links")
        if links is None:
            path = None
        elif not isinstance(links, Mapping):
            raise IdentityAllocationError("workflow-pagination-invalid")
        else:
            path = _workflow_next_path(links.get("next"))
    return workflows


def list_workflow_metadata(client: ASCClient) -> list[dict[str, Any]]:
    """List allowlisted workflow metadata for the fixed Gradus iOS app only."""

    return list_product_workflow_metadata(client, _one_ci_product(client, _one_app(client)))


def read_workflow_template(client: ASCClient, workflow_id: str) -> dict[str, str | bool]:
    """Read only the immutable configuration needed to create a sibling workflow."""

    if not isinstance(workflow_id, str) or not workflow_id:
        raise IdentityAllocationError("workflow-id-invalid")
    payload = client.request(
        "GET",
        f"/ciWorkflows/{quote(workflow_id, safe='')}?"
        "fields[ciWorkflows]=containerFilePath,clean,repository,xcodeVersion,macOsVersion&"
        "include=repository,xcodeVersion,macOsVersion",
    )
    if not isinstance(payload, Mapping) or not isinstance(payload.get("data"), Mapping):
        raise IdentityAllocationError("workflow-template-response-invalid")
    workflow = payload["data"]
    attributes = workflow.get("attributes")
    relationships = workflow.get("relationships")
    if workflow.get("type") != "ciWorkflows" or not isinstance(attributes, Mapping):
        raise IdentityAllocationError("workflow-template-response-invalid")
    container_path = attributes.get("containerFilePath")
    clean = attributes.get("clean")
    if not isinstance(container_path, str) or not container_path or not isinstance(clean, bool):
        raise IdentityAllocationError("workflow-template-attributes-invalid")
    result: dict[str, str | bool] = {"containerFilePath": container_path, "clean": clean}
    expected = {
        "repository": "scmRepositories",
        "xcodeVersion": "ciXcodeVersions",
        "macOsVersion": "ciMacOsVersions",
    }
    for key, resource_type in expected.items():
        relation = relationships.get(key) if isinstance(relationships, Mapping) else None
        relation_data = relation.get("data") if isinstance(relation, Mapping) else None
        relation_id = relation_data.get("id") if isinstance(relation_data, Mapping) else None
        if (
            relation_data.get("type") != resource_type
            if isinstance(relation_data, Mapping)
            else True
        ):
            raise IdentityAllocationError(f"workflow-template-{key}-invalid")
        if not isinstance(relation_id, str) or not relation_id:
            raise IdentityAllocationError(f"workflow-template-{key}-invalid")
        result[f"{key}Id"] = relation_id
    return result


def _read_toolchain_version(
    client: ASCClient, resource_type: str, version_id: str
) -> dict[str, str]:
    """Read one Cloud toolchain version's allowlisted name and version."""

    if not isinstance(version_id, str) or not version_id:
        raise IdentityAllocationError(f"{resource_type}-id-invalid")
    payload = client.request(
        "GET",
        f"/{resource_type}/{quote(version_id, safe='')}?fields[{resource_type}]=name,version",
    )
    if not isinstance(payload, Mapping) or not isinstance(payload.get("data"), Mapping):
        raise IdentityAllocationError(f"{resource_type}-response-invalid")
    record = payload["data"]
    attributes = record.get("attributes")
    if record.get("type") != resource_type or not isinstance(attributes, Mapping):
        raise IdentityAllocationError(f"{resource_type}-response-invalid")
    name = attributes.get("name")
    if not isinstance(name, str) or not name:
        raise IdentityAllocationError(f"{resource_type}-response-invalid")
    resolved = {"id": version_id, "name": name}
    # `version` is the concrete build Cloud resolves a floating name like
    # "Latest Release" to. It is the field that actually answers the question,
    # and it is absent whenever the name is already concrete -- so it is
    # reported when present rather than required.
    version = attributes.get("version")
    if version is not None:
        if not isinstance(version, str) or not version:
            raise IdentityAllocationError(f"{resource_type}-response-invalid")
        resolved["version"] = version
    return resolved


def _test_destinations(attributes: Mapping[str, Any]) -> list[dict[str, Any]]:
    """Extract only the allowlisted fields from TEST workflow actions.

    This is the missing half of "which toolchain does Cloud build with": the
    Xcode and macOS versions describe the host, while `destination` describes
    the simulator that actually renders a snapshot. A value such as
    `ANY_IOS_SIMULATOR` means Cloud chooses the runtime from its own image
    rather than honouring any pin in the repository -- which is precisely the
    condition a local gate cannot reproduce.
    """

    actions = attributes.get("actions")
    if not isinstance(actions, list):
        raise IdentityAllocationError("workflow-actions-invalid")
    tests: list[dict[str, Any]] = []
    for action in actions:
        if not isinstance(action, Mapping):
            raise IdentityAllocationError("workflow-actions-invalid")
        if action.get("actionType") != "TEST":
            continue
        entry: dict[str, Any] = {}
        for key in ("name", "scheme", "platform", "destination"):
            value = action.get(key)
            if isinstance(value, str) and value:
                entry[key] = value
        configuration = action.get("testConfiguration")
        if isinstance(configuration, Mapping):
            kinds = configuration.get("testPlanName")
            if isinstance(kinds, str) and kinds:
                entry["testPlanName"] = kinds
            devices = configuration.get("devices")
            if isinstance(devices, list):
                entry["deviceCount"] = len(devices)
        tests.append(entry)
    return tests


def resolve_workflow_toolchain(client: ASCClient, workflow_id: str) -> dict[str, Any]:
    """Resolve one workflow's opaque Xcode/macOS version IDs into named versions.

    Read-only, and separate from `read_workflow_template` on purpose: that
    function returns the opaque relationship IDs, which is exactly enough to
    clone a workflow and useless for answering "which toolchain does Cloud
    actually build with". That question decides whether a snapshot baseline
    recorded on Cloud can ever match a local render, and it was unanswerable
    until this mode existed.
    """

    template = read_workflow_template(client, workflow_id)
    resolved: dict[str, Any] = {
        "xcodeVersion": _read_toolchain_version(
            client, "ciXcodeVersions", str(template["xcodeVersionId"])
        ),
        "macOsVersion": _read_toolchain_version(
            client, "ciMacOsVersions", str(template["macOsVersionId"])
        ),
    }
    payload = client.request(
        "GET", f"/ciWorkflows/{quote(workflow_id, safe='')}?fields[ciWorkflows]=actions"
    )
    if not isinstance(payload, Mapping) or not isinstance(payload.get("data"), Mapping):
        raise IdentityAllocationError("workflow-actions-response-invalid")
    attributes = payload["data"].get("attributes")
    if not isinstance(attributes, Mapping):
        raise IdentityAllocationError("workflow-actions-response-invalid")
    resolved["testDestinations"] = _test_destinations(attributes)
    return resolved


def create_internal_testflight_workflow(
    client: ASCClient, *, product_id: str, template_workflow_id: str
) -> dict[str, str]:
    """Create one locked, clean, manual iOS internal-TestFlight workflow.

    The operation is intentionally narrow: it accepts only an existing product
    and one of that product's workflows as the environment template, never
    creates a per-commit start condition, and refuses a duplicate by name.
    """

    workflows = list_product_workflow_metadata(client, product_id)
    workflow_ids = {workflow["id"] for workflow in workflows}
    if template_workflow_id not in workflow_ids:
        raise IdentityAllocationError("workflow-template-not-in-product")
    if any(workflow["name"] == TESTFLIGHT_WORKFLOW_NAME for workflow in workflows):
        raise IdentityAllocationError("testflight-workflow-already-exists")
    template = read_workflow_template(client, template_workflow_id)
    required_ids = ("repositoryId", "xcodeVersionId", "macOsVersionId")
    if any(not isinstance(template.get(key), str) or not template[key] for key in required_ids):
        raise IdentityAllocationError("workflow-template-response-invalid")
    body = {
        "data": {
            "type": "ciWorkflows",
            "attributes": {
                "name": TESTFLIGHT_WORKFLOW_NAME,
                "description": "Manual clean archive for Gradus internal TestFlight candidates.",
                "manualBranchStartCondition": {
                    "source": {
                        "isAllMatch": False,
                        "patterns": [{"pattern": "main", "isPrefix": False}],
                    }
                },
                "actions": [
                    {
                        "name": "Archive iOS",
                        "actionType": "ARCHIVE",
                        "scheme": "GradusiOS",
                        "platform": "IOS",
                        "isRequiredToPass": True,
                        "buildDistributionAudience": "INTERNAL_ONLY",
                    }
                ],
                "isEnabled": True,
                "isLockedForEditing": True,
                "clean": True,
                "containerFilePath": template["containerFilePath"],
            },
            "relationships": {
                "product": {"data": {"type": "ciProducts", "id": product_id}},
                "repository": {"data": {"type": "scmRepositories", "id": template["repositoryId"]}},
                "xcodeVersion": {
                    "data": {"type": "ciXcodeVersions", "id": template["xcodeVersionId"]}
                },
                "macOsVersion": {
                    "data": {"type": "ciMacOsVersions", "id": template["macOsVersionId"]}
                },
            },
        }
    }
    payload = client.request("POST", "/ciWorkflows", body, idempotent=False)
    if not isinstance(payload, Mapping) or not isinstance(payload.get("data"), Mapping):
        raise IdentityAllocationError("testflight-workflow-create-response-invalid")
    created = payload["data"]
    workflow_id = created.get("id")
    attributes = created.get("attributes")
    if (
        created.get("type") != "ciWorkflows"
        or not isinstance(workflow_id, str)
        or not workflow_id
        or not isinstance(attributes, Mapping)
        or attributes.get("name") != TESTFLIGHT_WORKFLOW_NAME
    ):
        raise IdentityAllocationError("testflight-workflow-create-response-invalid")
    return {
        "workflowId": workflow_id,
        "name": TESTFLIGHT_WORKFLOW_NAME,
        "branch": "main",
        "platform": "IOS",
        "distributionAudience": "INTERNAL_ONLY",
    }


def start_internal_testflight_build(
    client: ASCClient, *, product_id: str, workflow_id: str
) -> dict[str, str]:
    """Start the fixed manual internal-TestFlight workflow once on its configured branch."""

    workflows = list_product_workflow_metadata(client, product_id)
    selected = next((workflow for workflow in workflows if workflow["id"] == workflow_id), None)
    if selected is None:
        raise IdentityAllocationError("testflight-workflow-not-in-product")
    if (
        selected["name"] != TESTFLIGHT_WORKFLOW_NAME
        or not selected["isEnabled"]
        or not selected["hasManualStart"]
        or selected["archiveActions"]
        != [
            {
                "platform": "IOS",
                "scheme": "GradusiOS",
                "distributionAudience": "INTERNAL_ONLY",
            }
        ]
    ):
        raise IdentityAllocationError("testflight-workflow-contract-mismatch")
    payload = client.request(
        "POST",
        "/ciBuildRuns",
        {
            "data": {
                "type": "ciBuildRuns",
                "attributes": {"clean": True},
                "relationships": {"workflow": {"data": {"type": "ciWorkflows", "id": workflow_id}}},
            }
        },
        idempotent=False,
    )
    if not isinstance(payload, Mapping) or not isinstance(payload.get("data"), Mapping):
        raise IdentityAllocationError("testflight-build-start-response-invalid")
    run = payload["data"]
    run_id = run.get("id")
    attributes = run.get("attributes")
    progress = attributes.get("executionProgress") if isinstance(attributes, Mapping) else None
    if (
        run.get("type") != "ciBuildRuns"
        or not isinstance(run_id, str)
        or not run_id
        or not isinstance(progress, str)
        or not progress
    ):
        raise IdentityAllocationError("testflight-build-start-response-invalid")
    return {"buildRunId": run_id, "executionProgress": progress, "workflowId": workflow_id}


def read_build_run_status(client: ASCClient, build_run_id: str) -> dict[str, str | None]:
    """Read the allowlisted execution state of one Xcode Cloud build run."""

    if not isinstance(build_run_id, str) or not build_run_id:
        raise IdentityAllocationError("build-run-id-invalid")
    payload = client.request(
        "GET",
        f"/ciBuildRuns/{quote(build_run_id, safe='')}?"
        "fields[ciBuildRuns]=executionProgress,completionStatus,startedDate,finishedDate",
    )
    if not isinstance(payload, Mapping) or not isinstance(payload.get("data"), Mapping):
        raise IdentityAllocationError("build-run-status-response-invalid")
    run = payload["data"]
    attributes = run.get("attributes")
    if run.get("type") != "ciBuildRuns" or not isinstance(attributes, Mapping):
        raise IdentityAllocationError("build-run-status-response-invalid")
    progress = attributes.get("executionProgress")
    completion = attributes.get("completionStatus")
    if (
        not isinstance(progress, str)
        or not progress
        or (completion is not None and not isinstance(completion, str))
    ):
        raise IdentityAllocationError("build-run-status-response-invalid")
    return {
        "buildRunId": build_run_id,
        "executionProgress": progress,
        "completionStatus": completion,
    }


def list_workflow_build_runs(client: ASCClient, workflow_id: str) -> list[dict[str, str | None]]:
    """List allowlisted state for build runs of one workflow."""

    if not isinstance(workflow_id, str) or not workflow_id:
        raise IdentityAllocationError("workflow-id-invalid")
    payload = client.request(
        "GET",
        f"/ciWorkflows/{quote(workflow_id, safe='')}/buildRuns?"
        "fields[ciBuildRuns]=executionProgress,completionStatus,number&limit=10",
    )
    if not isinstance(payload, Mapping) or not isinstance(payload.get("data"), list):
        raise IdentityAllocationError("workflow-build-runs-response-invalid")
    rows: list[dict[str, str | None]] = []
    for run in payload["data"]:
        attributes = run.get("attributes") if isinstance(run, Mapping) else None
        run_id = run.get("id") if isinstance(run, Mapping) else None
        progress = attributes.get("executionProgress") if isinstance(attributes, Mapping) else None
        completion = attributes.get("completionStatus") if isinstance(attributes, Mapping) else None
        if (
            not isinstance(run_id, str)
            or not run_id
            or not isinstance(progress, str)
            or not progress
            or (completion is not None and not isinstance(completion, str))
        ):
            raise IdentityAllocationError("workflow-build-runs-response-invalid")
        rows.append(
            {"buildRunId": run_id, "executionProgress": progress, "completionStatus": completion}
        )
    return rows


def list_ci_builds(client: ASCClient, build_run_id: str) -> list[dict[str, str]]:
    """List allowlisted TestFlight build state produced by one Cloud run."""

    if not isinstance(build_run_id, str) or not build_run_id:
        raise IdentityAllocationError("build-run-id-invalid")
    payload = client.request(
        "GET",
        f"/ciBuildRuns/{quote(build_run_id, safe='')}/builds?"
        "fields[builds]=version,processingState,buildAudienceType&limit=50",
    )
    if not isinstance(payload, Mapping) or not isinstance(payload.get("data"), list):
        raise IdentityAllocationError("ci-builds-response-invalid")
    builds: list[dict[str, str]] = []
    for build in payload["data"]:
        attributes = build.get("attributes") if isinstance(build, Mapping) else None
        build_id = build.get("id") if isinstance(build, Mapping) else None
        version = attributes.get("version") if isinstance(attributes, Mapping) else None
        state = attributes.get("processingState") if isinstance(attributes, Mapping) else None
        audience = attributes.get("buildAudienceType") if isinstance(attributes, Mapping) else None
        if not all(
            isinstance(value, str) and value for value in (build_id, version, state, audience)
        ):
            raise IdentityAllocationError("ci-builds-response-invalid")
        builds.append(
            {
                "buildId": build_id,
                "buildNumber": version,
                "processingState": state,
                "distributionAudience": audience,
            }
        )
    return builds


def find_ios_testflight_build(client: ASCClient, build_number: str) -> list[dict[str, str]]:
    """Resolve a Cloud build number through the fixed Gradus iOS app relation."""

    if not isinstance(build_number, str) or not _POSITIVE_INTEGER.fullmatch(build_number):
        raise IdentityAllocationError("build-number-invalid")
    app_id = _one_app(client)
    payload = client.request(
        "GET",
        f"/builds?filter[app]={quote(app_id, safe='')}&filter[version]={quote(build_number, safe='')}&"
        "fields[builds]=version,processingState,buildAudienceType&limit=50",
    )
    if not isinstance(payload, Mapping) or not isinstance(payload.get("data"), list):
        raise IdentityAllocationError("build-response-invalid")
    results: list[dict[str, str]] = []
    for item in payload["data"]:
        attributes = item.get("attributes") if isinstance(item, Mapping) else None
        build_id = item.get("id") if isinstance(item, Mapping) else None
        version = attributes.get("version") if isinstance(attributes, Mapping) else None
        state = attributes.get("processingState") if isinstance(attributes, Mapping) else None
        audience = attributes.get("buildAudienceType") if isinstance(attributes, Mapping) else None
        if not all(
            isinstance(value, str) and value for value in (build_id, version, state, audience)
        ):
            raise IdentityAllocationError("build-response-invalid")
        results.append(
            {
                "buildId": build_id,
                "buildNumber": version,
                "processingState": state,
                "distributionAudience": audience,
            }
        )
    return results


def inspect_testflight_build_app(client: ASCClient, build_id: str) -> dict[str, bool | str]:
    """Check whether one TestFlight build belongs to the fixed Gradus iOS app."""

    if not isinstance(build_id, str) or not build_id:
        raise IdentityAllocationError("build-id-invalid")
    expected_app_id = _one_app(client)
    payload = client.request("GET", f"/builds/{quote(build_id, safe='')}/app?fields[apps]=bundleId")
    data = payload.get("data") if isinstance(payload, Mapping) else None
    app_id = data.get("id") if isinstance(data, Mapping) else None
    attributes = data.get("attributes") if isinstance(data, Mapping) else None
    bundle_id = attributes.get("bundleId") if isinstance(attributes, Mapping) else None
    if not isinstance(app_id, str) or not app_id or not isinstance(bundle_id, str) or not bundle_id:
        raise IdentityAllocationError("build-app-relationship-invalid")
    return {
        "buildAppPresent": True,
        "belongsToGradusiOS": app_id == expected_app_id,
        "bundleId": bundle_id,
    }


def internal_group_assignment_state(client: ASCClient, *, build_id: str, group_id: str) -> str:
    """Return whether one build is available through the confirmed internal group."""

    if (
        not isinstance(build_id, str)
        or not build_id
        or not isinstance(group_id, str)
        or not group_id
    ):
        raise IdentityAllocationError("testflight-assignment-id-invalid")
    try:
        app_id = _one_app(client)
    except ASCError as exc:
        raise IdentityAllocationError(
            f"testflight-assignment-app-lookup-{_asc_error_label(exc)}"
        ) from exc
    try:
        group_payload = client.request(
            "GET",
            f"/apps/{quote(app_id, safe='')}/betaGroups?"
            "fields[betaGroups]=isInternalGroup,hasAccessToAllBuilds&limit=200",
        )
    except ASCError as exc:
        raise IdentityAllocationError(
            f"testflight-assignment-group-lookup-{_asc_error_label(exc)}"
        ) from exc
    if not isinstance(group_payload, Mapping) or not isinstance(group_payload.get("data"), list):
        raise IdentityAllocationError("testflight-group-response-invalid")
    groups = [
        item
        for item in group_payload["data"]
        if isinstance(item, Mapping) and item.get("id") == group_id
    ]
    if len(groups) != 1:
        raise IdentityAllocationError("testflight-group-not-in-app")
    group = groups[0]
    attributes = group.get("attributes")
    if (
        group.get("type") != "betaGroups"
        or group.get("id") != group_id
        or not isinstance(attributes, Mapping)
        or attributes.get("isInternalGroup") is not True
        or not isinstance(attributes.get("hasAccessToAllBuilds"), bool)
    ):
        raise IdentityAllocationError("testflight-group-response-invalid")
    if attributes["hasAccessToAllBuilds"]:
        return "allBuildsAccess"
    try:
        payload = client.request(
            "GET",
            f"/betaGroups/{quote(group_id, safe='')}/builds?limit=200",
        )
    except ASCError as exc:
        raise IdentityAllocationError(
            f"testflight-assignment-group-build-lookup-{_asc_error_label(exc)}"
        ) from exc
    if not isinstance(payload, Mapping) or not isinstance(payload.get("data"), list):
        raise IdentityAllocationError("testflight-assignment-response-invalid")
    build_ids: set[str] = set()
    for build in payload["data"]:
        candidate_id = build.get("id") if isinstance(build, Mapping) else None
        if not isinstance(candidate_id, str) or not candidate_id or candidate_id in build_ids:
            raise IdentityAllocationError("testflight-assignment-response-invalid")
        build_ids.add(candidate_id)
    if build_id in build_ids:
        return "alreadyAssigned"
    return "unassigned"


def inspect_internal_group_assignment(
    client: ASCClient, *, build_id: str, group_id: str
) -> dict[str, str]:
    """Read one exact TestFlight build/group relation without mutating Apple state."""

    return {
        "buildId": build_id,
        "assignment": internal_group_assignment_state(client, build_id=build_id, group_id=group_id),
    }


def assign_build_to_internal_group(
    client: ASCClient, *, build_id: str, group_id: str
) -> dict[str, str]:
    """Add one internal-only build to the previously confirmed internal group."""

    state = internal_group_assignment_state(client, build_id=build_id, group_id=group_id)
    if state != "unassigned":
        return {"buildId": build_id, "assignment": state}
    try:
        client.request(
            "POST",
            f"/betaGroups/{quote(group_id, safe='')}/relationships/builds",
            {"data": [{"type": "builds", "id": build_id}]},
            idempotent=False,
        )
    except ASCError as exc:
        raise IdentityAllocationError(
            f"testflight-assignment-write-{_asc_error_label(exc)}"
        ) from exc
    return {"buildId": build_id, "assignment": "assigned"}


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
    parser.add_argument(
        "--list-workflows",
        action="store_true",
        help="Print allowlisted Xcode Cloud workflow metadata for the fixed Gradus iOS app",
    )
    parser.add_argument(
        "--list-cloud-products",
        action="store_true",
        help="Print allowlisted Xcode Cloud product metadata",
    )
    parser.add_argument(
        "--list-product-workflows",
        metavar="CI_PRODUCT_ID",
        help="Print allowlisted workflow metadata for one Cloud product returned by --list-cloud-products",
    )
    parser.add_argument(
        "--read-workflow-template",
        metavar="WORKFLOW_ID",
        help="Print safe template metadata for creating a sibling Cloud workflow",
    )
    parser.add_argument(
        "--resolve-workflow-toolchain",
        metavar="WORKFLOW_ID",
        help="Print the named Xcode and macOS versions one Cloud workflow builds with",
    )
    parser.add_argument(
        "--create-internal-testflight-workflow",
        action="store_true",
        help="Create the one locked, manual iOS internal-TestFlight workflow",
    )
    parser.add_argument(
        "--ci-product-id", help="Cloud product ID returned by --list-cloud-products"
    )
    parser.add_argument(
        "--template-workflow-id",
        help="Existing workflow ID returned by --list-product-workflows",
    )
    parser.add_argument(
        "--start-internal-testflight-build",
        action="store_true",
        help="Start the fixed manual internal-TestFlight workflow",
    )
    parser.add_argument(
        "--workflow-id", help="Workflow ID returned by TestFlight workflow creation"
    )
    parser.add_argument(
        "--build-run-status", metavar="BUILD_RUN_ID", help="Print safe Xcode Cloud build-run status"
    )
    parser.add_argument(
        "--list-workflow-build-runs",
        metavar="WORKFLOW_ID",
        help="Print safe recent build-run states for one workflow",
    )
    parser.add_argument(
        "--list-ci-builds",
        metavar="BUILD_RUN_ID",
        help="Print safe TestFlight build state for one run",
    )
    parser.add_argument(
        "--find-ios-testflight-build",
        metavar="BUILD_NUMBER",
        help="Resolve an iOS TestFlight build number through the fixed Gradus app",
    )
    parser.add_argument(
        "--inspect-testflight-build-app",
        metavar="BUILD_ID",
        help="Print whether one TestFlight build belongs to the fixed Gradus iOS app",
    )
    parser.add_argument("--assign-internal-testflight-build", action="store_true")
    parser.add_argument("--inspect-internal-testflight-build", action="store_true")
    parser.add_argument("--ensure-widget-profile", action="store_true")
    parser.add_argument("--ensure-ios-app-group-profile", action="store_true")
    parser.add_argument("--build-id", help="Processed TestFlight build ID")
    parser.add_argument("--group-id", help="Confirmed internal tester group ID")
    args = parser.parse_args(argv)

    if args.product and (
        args.ci_build_action_id
        or args.output_dir
        or args.ci_artifact_id
        or args.list_result_bundles
        or args.list_workflows
        or args.list_cloud_products
        or args.list_product_workflows
        or args.read_workflow_template
        or args.resolve_workflow_toolchain
        or args.create_internal_testflight_workflow
        or args.start_internal_testflight_build
        or args.build_run_status
        or args.list_workflow_build_runs
        or args.list_ci_builds
        or args.find_ios_testflight_build
        or args.inspect_testflight_build_app
        or args.assign_internal_testflight_build
        or args.inspect_internal_testflight_build
        or args.ensure_widget_profile
        or args.ensure_ios_app_group_profile
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

    if args.ensure_widget_profile:
        try:
            receipt = ensure_widget_distribution_profile(
                ASCClient(make_token_provider()),
                Path.home() / "Library" / "MobileDevice" / "Provisioning Profiles",
            )
            print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
            return 0
        except ASCError as exc:
            print(f"FAIL: widget profile failed ({_asc_error_label(exc)})", file=sys.stderr)
            return 1

    if args.ensure_ios_app_group_profile:
        try:
            receipt = ensure_ios_app_group_distribution_profile(
                ASCClient(make_token_provider()),
                Path.home() / "Library" / "MobileDevice" / "Provisioning Profiles",
            )
            print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
            return 0
        except ASCError as exc:
            print(f"FAIL: iOS App Group profile failed ({_asc_error_label(exc)})", file=sys.stderr)
            return 1
        except IdentityAllocationError as exc:
            print(f"FAIL: iOS App Group profile failed ({exc})", file=sys.stderr)
            return 1
        except OSError:
            print("FAIL: iOS App Group profile failed", file=sys.stderr)
            return 1
        except IdentityAllocationError as exc:
            print(f"FAIL: widget profile failed ({exc})", file=sys.stderr)
            return 1
        except OSError:
            print("FAIL: widget profile failed", file=sys.stderr)
            return 1

    if args.list_workflows:
        if (
            args.ci_build_action_id
            or args.output_dir
            or args.ci_artifact_id
            or args.list_result_bundles
        ):
            print("FAIL: workflow listing does not accept artifact options", file=sys.stderr)
            return 1
        try:
            metadata = list_workflow_metadata(ASCClient(make_token_provider()))
            print(json.dumps(metadata, sort_keys=True, separators=(",", ":")))
            return 0
        except ASCError as exc:
            print(f"FAIL: workflow listing failed ({exc.outcome.error_class})", file=sys.stderr)
            return 1
        except IdentityAllocationError as exc:
            print(f"FAIL: workflow listing failed ({exc})", file=sys.stderr)
            return 1

    if args.list_product_workflows:
        if (
            args.ci_build_action_id
            or args.output_dir
            or args.ci_artifact_id
            or args.list_result_bundles
        ):
            print("FAIL: workflow listing does not accept artifact options", file=sys.stderr)
            return 1
        try:
            metadata = list_product_workflow_metadata(
                ASCClient(make_token_provider()), args.list_product_workflows
            )
            print(json.dumps(metadata, sort_keys=True, separators=(",", ":")))
            return 0
        except ASCError as exc:
            print(f"FAIL: workflow listing failed ({exc.outcome.error_class})", file=sys.stderr)
            return 1
        except IdentityAllocationError as exc:
            print(f"FAIL: workflow listing failed ({exc})", file=sys.stderr)
            return 1

    if args.read_workflow_template:
        if (
            args.ci_build_action_id
            or args.output_dir
            or args.ci_artifact_id
            or args.list_result_bundles
        ):
            print("FAIL: workflow template does not accept artifact options", file=sys.stderr)
            return 1
        try:
            metadata = read_workflow_template(
                ASCClient(make_token_provider()), args.read_workflow_template
            )
            print(json.dumps(metadata, sort_keys=True, separators=(",", ":")))
            return 0
        except ASCError as exc:
            print(f"FAIL: workflow template failed ({exc.outcome.error_class})", file=sys.stderr)
            return 1
        except IdentityAllocationError as exc:
            print(f"FAIL: workflow template failed ({exc})", file=sys.stderr)
            return 1

    if args.resolve_workflow_toolchain:
        if (
            args.ci_build_action_id
            or args.output_dir
            or args.ci_artifact_id
            or args.list_result_bundles
        ):
            print("FAIL: toolchain resolution does not accept artifact options", file=sys.stderr)
            return 1
        try:
            toolchain = resolve_workflow_toolchain(
                ASCClient(make_token_provider()), args.resolve_workflow_toolchain
            )
            print(json.dumps(toolchain, sort_keys=True, separators=(",", ":")))
            return 0
        except ASCError as exc:
            print(f"FAIL: toolchain resolution failed ({exc.outcome.error_class})", file=sys.stderr)
            return 1
        except IdentityAllocationError as exc:
            print(f"FAIL: toolchain resolution failed ({exc})", file=sys.stderr)
            return 1

    if args.create_internal_testflight_workflow:
        if not args.ci_product_id or not args.template_workflow_id:
            print(
                "FAIL: TestFlight workflow creation requires product and template workflow IDs",
                file=sys.stderr,
            )
            return 1
        if (
            args.ci_build_action_id
            or args.output_dir
            or args.ci_artifact_id
            or args.list_result_bundles
        ):
            print(
                "FAIL: TestFlight workflow creation does not accept artifact options",
                file=sys.stderr,
            )
            return 1
        try:
            receipt = create_internal_testflight_workflow(
                ASCClient(make_token_provider()),
                product_id=args.ci_product_id,
                template_workflow_id=args.template_workflow_id,
            )
            print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
            return 0
        except ASCError as exc:
            print(
                f"FAIL: TestFlight workflow creation failed ({exc.outcome.error_class})",
                file=sys.stderr,
            )
            return 1
        except IdentityAllocationError as exc:
            print(f"FAIL: TestFlight workflow creation failed ({exc})", file=sys.stderr)
            return 1

    if args.start_internal_testflight_build:
        if not args.ci_product_id or not args.workflow_id:
            print("FAIL: TestFlight build start requires product and workflow IDs", file=sys.stderr)
            return 1
        if (
            args.ci_build_action_id
            or args.output_dir
            or args.ci_artifact_id
            or args.list_result_bundles
        ):
            print("FAIL: TestFlight build start does not accept artifact options", file=sys.stderr)
            return 1
        try:
            receipt = start_internal_testflight_build(
                ASCClient(make_token_provider()),
                product_id=args.ci_product_id,
                workflow_id=args.workflow_id,
            )
            print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
            return 0
        except ASCError as exc:
            print(
                f"FAIL: TestFlight build start failed ({exc.outcome.error_class})", file=sys.stderr
            )
            return 1
        except IdentityAllocationError as exc:
            print(f"FAIL: TestFlight build start failed ({exc})", file=sys.stderr)
            return 1

    if args.build_run_status:
        if (
            args.ci_build_action_id
            or args.output_dir
            or args.ci_artifact_id
            or args.list_result_bundles
        ):
            print("FAIL: build-run status does not accept artifact options", file=sys.stderr)
            return 1
        try:
            status = read_build_run_status(ASCClient(make_token_provider()), args.build_run_status)
            print(json.dumps(status, sort_keys=True, separators=(",", ":")))
            return 0
        except ASCError as exc:
            print(f"FAIL: build-run status failed ({exc.outcome.error_class})", file=sys.stderr)
            return 1
        except IdentityAllocationError as exc:
            print(f"FAIL: build-run status failed ({exc})", file=sys.stderr)
            return 1

    if args.list_workflow_build_runs:
        if (
            args.ci_build_action_id
            or args.output_dir
            or args.ci_artifact_id
            or args.list_result_bundles
        ):
            print(
                "FAIL: workflow build-run listing does not accept artifact options", file=sys.stderr
            )
            return 1
        try:
            rows = list_workflow_build_runs(
                ASCClient(make_token_provider()), args.list_workflow_build_runs
            )
            print(json.dumps(rows, sort_keys=True, separators=(",", ":")))
            return 0
        except ASCError as exc:
            print(
                f"FAIL: workflow build-run listing failed ({exc.outcome.error_class})",
                file=sys.stderr,
            )
            return 1
        except IdentityAllocationError as exc:
            print(f"FAIL: workflow build-run listing failed ({exc})", file=sys.stderr)
            return 1

    if args.list_ci_builds:
        if (
            args.ci_build_action_id
            or args.output_dir
            or args.ci_artifact_id
            or args.list_result_bundles
        ):
            print("FAIL: CI build listing does not accept artifact options", file=sys.stderr)
            return 1

    if args.find_ios_testflight_build:
        try:
            builds = find_ios_testflight_build(
                ASCClient(make_token_provider()), args.find_ios_testflight_build
            )
            print(json.dumps(builds, sort_keys=True, separators=(",", ":")))
            return 0
        except ASCError as exc:
            print(f"FAIL: build lookup failed ({exc.outcome.error_class})", file=sys.stderr)
            return 1

    if args.inspect_testflight_build_app:
        try:
            binding = inspect_testflight_build_app(
                ASCClient(make_token_provider()), args.inspect_testflight_build_app
            )
            print(json.dumps(binding, sort_keys=True, separators=(",", ":")))
            return 0
        except ASCError as exc:
            print(f"FAIL: build binding failed ({exc.outcome.error_class})", file=sys.stderr)
            return 1
        except IdentityAllocationError as exc:
            print(f"FAIL: build binding failed ({exc})", file=sys.stderr)
            return 1
        except IdentityAllocationError as exc:
            print(f"FAIL: build lookup failed ({exc})", file=sys.stderr)
            return 1
        try:
            builds = list_ci_builds(ASCClient(make_token_provider()), args.list_ci_builds)
            print(json.dumps(builds, sort_keys=True, separators=(",", ":")))
            return 0
        except ASCError as exc:
            print(f"FAIL: CI build listing failed ({exc.outcome.error_class})", file=sys.stderr)
            return 1
        except IdentityAllocationError as exc:
            print(f"FAIL: CI build listing failed ({exc})", file=sys.stderr)
            return 1

    if args.assign_internal_testflight_build or args.inspect_internal_testflight_build:
        if not args.build_id or not args.group_id:
            print("FAIL: TestFlight assignment requires build and group IDs", file=sys.stderr)
            return 1
        if (
            args.ci_build_action_id
            or args.output_dir
            or args.ci_artifact_id
            or args.list_result_bundles
        ):
            print("FAIL: TestFlight assignment does not accept artifact options", file=sys.stderr)
            return 1
        try:
            action = (
                assign_build_to_internal_group
                if args.assign_internal_testflight_build
                else inspect_internal_group_assignment
            )
            receipt = action(
                ASCClient(make_token_provider()), build_id=args.build_id, group_id=args.group_id
            )
            print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
            return 0
        except ASCError as exc:
            print(
                f"FAIL: TestFlight assignment failed ({exc.outcome.error_class})", file=sys.stderr
            )
            return 1
        except IdentityAllocationError as exc:
            print(f"FAIL: TestFlight assignment failed ({exc})", file=sys.stderr)
            return 1

    if args.list_cloud_products:
        if (
            args.ci_build_action_id
            or args.output_dir
            or args.ci_artifact_id
            or args.list_result_bundles
        ):
            print("FAIL: cloud product listing does not accept artifact options", file=sys.stderr)
            return 1
        try:
            metadata = list_cloud_product_metadata(ASCClient(make_token_provider()))
            print(json.dumps(metadata, sort_keys=True, separators=(",", ":")))
            return 0
        except ASCError as exc:
            print(
                f"FAIL: cloud product listing failed ({exc.outcome.error_class})", file=sys.stderr
            )
            return 1
        except IdentityAllocationError as exc:
            print(f"FAIL: cloud product listing failed ({exc})", file=sys.stderr)
            return 1

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
        "FAIL: --product, --list-workflows, --list-product-workflows, --list-cloud-products, --read-workflow-template, --resolve-workflow-toolchain, --list-result-bundles with an action ID, or an action ID with --output-dir is required",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
