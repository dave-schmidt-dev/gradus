#!/usr/bin/env python3
"""Create a Developer ID ("Direct") provisioning profile for GradusMac via
the App Store Connect API and install it locally.

Bypasses xcodebuild's cloud-managed signing (-allowProvisioningUpdates +
-authenticationKeyPath), which returned a persistent "Cloud signing
permission error" even with an Admin-role API key — a known-flaky path per
multiple Apple Developer Forum threads (e.g. developer.apple.com/forums/
thread/688626). Creating the profile directly via POST /v1/profiles is a
stable, well-documented alternative.

Schema confirmed against developer.apple.com's official DocC JSON
(2026-08-03): profileType enum includes MAC_APP_DIRECT for Developer ID
distribution; certificateType DEVELOPER_ID_APPLICATION matches the local
keychain identity.

Run via:
    bws-run -- uv run --with pyjwt --with cryptography app/create-developer-id-profile.py
"""

from __future__ import annotations

import base64
import sys
from pathlib import Path

from _asc_api import call, make_token

BUNDLE_ID = "com.zerodelta.gradus.mac"
PROFILE_NAME = "Gradus Mac Developer ID (API-created)"
PROFILES_DIR = Path.home() / "Library" / "MobileDevice" / "Provisioning Profiles"


def main() -> int:
    token = make_token()

    print(f"==> Looking up bundle ID {BUNDLE_ID}")
    bundle_ids = call(token, "GET", f"/bundleIds?filter[identifier]={BUNDLE_ID}")
    data = (bundle_ids or {}).get("data") or []
    if not data:
        print(f"FAIL: no bundleId resource found for {BUNDLE_ID}", file=sys.stderr)
        return 1
    bundle_id_resource = data[0]["id"]
    print(f"    bundleId resource: {bundle_id_resource}")

    print("==> Looking up Developer ID Application certificate")
    certs = call(token, "GET", "/certificates?filter[certificateType]=DEVELOPER_ID_APPLICATION")
    cert_data = (certs or {}).get("data") or []
    if not cert_data:
        print("FAIL: no DEVELOPER_ID_APPLICATION certificate found on the account", file=sys.stderr)
        return 1
    cert_id = cert_data[0]["id"]
    cert_name = cert_data[0]["attributes"].get("displayName")
    print(f"    Certificate: {cert_name} ({cert_id})")

    print("==> Checking for an existing Developer ID profile for this bundle ID")
    existing_profiles = call(token, "GET", f"/bundleIds/{bundle_id_resource}/profiles")
    for p in (existing_profiles or {}).get("data", []):
        if p["attributes"].get("profileType") == "MAC_APP_DIRECT":
            print(f"    Found existing profile: {p['attributes'].get('name')} ({p['id']})")
            print("    Re-downloading its content instead of creating a new one.")
            full = call(token, "GET", f"/profiles/{p['id']}")
            write_profile(full["data"]["attributes"]["profileContent"])
            return 0

    print("==> Creating new Developer ID (MAC_APP_DIRECT) profile")
    created = call(
        token,
        "POST",
        "/profiles",
        {
            "data": {
                "type": "profiles",
                "attributes": {"name": PROFILE_NAME, "profileType": "MAC_APP_DIRECT"},
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bundle_id_resource}},
                    "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
                },
            }
        },
    )
    profile_content = created["data"]["attributes"]["profileContent"]
    write_profile(profile_content)
    print(f"==> Done. Profile installed: {PROFILES_DIR}")
    return 0


def write_profile(profile_content_b64: str) -> None:
    PROFILES_DIR.mkdir(parents=True, exist_ok=True)
    raw = base64.b64decode(profile_content_b64)
    # Real UUID is embedded in the profile's plist; using a fixed name is fine —
    # Xcode/security indexes profiles in this directory by content, not filename.
    dest = PROFILES_DIR / "gradus-mac-developer-id.provisionprofile"
    dest.write_bytes(raw)
    print(f"    Wrote {dest} ({len(raw)} bytes)")


if __name__ == "__main__":
    raise SystemExit(main())
