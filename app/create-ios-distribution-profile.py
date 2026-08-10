#!/usr/bin/env python3
"""Human-only Gradus iOS App Store profile renewal.

This path is intentionally separate from TestFlight assignment. Invoke only
from an attended terminal after reviewing the target bundle and profile name:
No fixed BWS consumer is installed for this optional operation, so it is
deferred until the release owner supplies an approved attended credential
boundary. It requires an existing Apple Distribution certificate and writes
only the Gradus-named local profile; it never handles testers or internal
groups.
"""

from __future__ import annotations

import argparse
import base64
from pathlib import Path

from _asc_api import ASCClient, make_token_provider

BUNDLE_ID = "com.zerodelta.gradus.ios"
PROFILE_NAME = "Gradus iOS App Store (API-created)"
PROFILE_FILENAME = "gradus-ios-app-store.provisionprofile"
PROFILES_DIR = Path.home() / "Library" / "MobileDevice" / "Provisioning Profiles"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--confirm-human", action="store_true", help="required attended confirmation"
    )
    parser.add_argument("--bundle-id", default=BUNDLE_ID)
    args = parser.parse_args()
    if not args.confirm_human:
        parser.error(
            "profile renewal is human-only; pass --confirm-human from an attended terminal"
        )
    client = ASCClient(make_token_provider())
    apps = client.request("GET", f"/apps?filter[bundleId]={args.bundle_id}") or {}
    data = apps.get("data", [])
    if len(data) != 1:
        raise SystemExit("FAIL: bundle ID did not resolve to exactly one Gradus app")
    app_id = data[0]["id"]
    bundle_ids = client.request("GET", f"/apps/{app_id}/bundleId") or {}
    bundle_id_resource = (bundle_ids.get("data") or {}).get("id")
    if not bundle_id_resource:
        raise SystemExit("FAIL: Gradus bundle resource was not available")
    certificates = (
        client.request("GET", "/certificates?filter[certificateType]=DISTRIBUTION&limit=50") or {}
    )
    certs = certificates.get("data", [])
    if len(certs) != 1:
        raise SystemExit(
            "DEFERRED: profile renewal requires exactly one reviewed Apple Distribution certificate"
        )
    existing = client.request("GET", f"/bundleIds/{bundle_id_resource}/profiles") or {}
    for profile in existing.get("data", []):
        if profile.get("attributes", {}).get("name") == PROFILE_NAME:
            raise SystemExit(
                "DEFERRED: existing Gradus profile renewal requires explicit operator review"
            )
    created = client.request(
        "POST",
        "/profiles",
        {
            "data": {
                "type": "profiles",
                "attributes": {"name": PROFILE_NAME, "profileType": "IOS_APP_STORE"},
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bundle_id_resource}},
                    "certificates": {"data": [{"type": "certificates", "id": certs[0]["id"]}]},
                },
            }
        },
        idempotent=False,
    )
    content = ((created or {}).get("data") or {}).get("attributes", {}).get("profileContent")
    if not isinstance(content, str):
        raise SystemExit("FAIL: profile response did not contain profile content")
    PROFILES_DIR.mkdir(parents=True, exist_ok=True)
    destination = PROFILES_DIR / PROFILE_FILENAME
    destination.write_bytes(base64.b64decode(content))
    print(f"Profile renewed: {destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
