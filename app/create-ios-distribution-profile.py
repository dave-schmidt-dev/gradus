#!/usr/bin/env python3
"""Create an Apple Distribution certificate + iOS App Store provisioning
profile for GradusiOS via the App Store Connect API, and install both
locally.

archive-upload-ios.sh's first attempt used cloud-managed automatic signing
(-allowProvisioningUpdates + API key), same as the Mac Developer ID path.
Xcode's export step resolved an "Apple Distribution" certificate + "iOS Team
Store Provisioning Profile" that way, but re-signing with it failed ("Copy
failed") -- its private key was never present in the local keychain (that
certificate's issueDate predates this session, and `/certificates` no longer
lists it, so Apple's cloud signing service apparently minted and then
discarded/revoked it when the local sign failed). Rather than depend on that
flaky cloud path again, this generates our own CSR + private key locally
(the private key never leaves this machine), submits it to create the
certificate directly, and creates a profile referencing it -- the same
"sidestep cloud-managed signing with a manually-created profile" fix already
proven for GradusMac's Developer ID export.

Schema confirmed against developer.apple.com's official DocC JSON
(2026-08-03): CertificateCreateRequest.Data.Attributes takes `certificateType`
(here "DISTRIBUTION", Apple's unified cross-platform distribution cert type)
and `csrContent` (base64 of the raw PEM CSR bytes -- confirmed against a
DTS-engineer-answered Apple Developer Forums thread, not guessed). The
Certificate response's cert bytes are under `certificateContent` (base64
DER) -- also confirmed against the official schema, not `certContent`.

Run via:
    bws-run -- uv run --with pyjwt --with cryptography app/create-ios-distribution-profile.py
"""

from __future__ import annotations

import base64
import subprocess
import sys
import tempfile
from pathlib import Path

from _asc_api import call, make_token

BUNDLE_ID = "com.zerodelta.gradus.ios"
PROFILE_NAME = "Gradus iOS App Store (API-created)"
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

    print("==> Checking for an existing Apple Distribution certificate")
    certs = call(token, "GET", "/certificates?filter[certificateType]=DISTRIBUTION&limit=50")
    local_serials = local_apple_distribution_serials()
    cert_id = None
    for c in (certs or {}).get("data", []):
        # Only usable if this machine actually holds the matching private
        # key -- a cert whose key isn't local can't sign anything, which is
        # exactly the bug this script exists to route around.
        serial = (c["attributes"].get("serialNumber") or "").upper()
        if serial and serial in local_serials:
            cert_id = c["id"]
            print(
                f"    Found usable local certificate: {c['attributes'].get('displayName')} ({cert_id})"
            )
            break
    if not cert_id:
        cert_id = create_certificate(token)

    print("==> Checking for an existing iOS App Store profile for this bundle ID")
    existing_profiles = call(token, "GET", f"/bundleIds/{bundle_id_resource}/profiles")
    for p in (existing_profiles or {}).get("data", []):
        if p["attributes"].get("profileType") == "IOS_APP_STORE":
            print(
                f"    Found existing profile: {p['attributes'].get('name')} ({p['id']}) -- deleting to recreate with the new certificate"
            )
            call(token, "DELETE", f"/profiles/{p['id']}")

    print("==> Creating new iOS App Store (IOS_APP_STORE) profile")
    created = call(
        token,
        "POST",
        "/profiles",
        {
            "data": {
                "type": "profiles",
                "attributes": {"name": PROFILE_NAME, "profileType": "IOS_APP_STORE"},
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


def local_apple_distribution_serials() -> set[str]:
    """Serial numbers (uppercase hex) of every "Apple Distribution" cert
    sitting in the local keychain, regardless of whether a private key
    backs it -- cross-referenced against ASC's cert list by the caller,
    which already filters to certs this machine can actually sign with."""
    listing = subprocess.run(
        ["security", "find-certificate", "-a", "-c", "Apple Distribution", "-p"],
        capture_output=True,
        text=True,
    ).stdout
    serials: set[str] = set()
    for pem in listing.split("-----BEGIN CERTIFICATE-----"):
        if "-----END CERTIFICATE-----" not in pem:
            continue
        pem_block = "-----BEGIN CERTIFICATE-----" + pem
        result = subprocess.run(
            ["openssl", "x509", "-noout", "-serial"],
            input=pem_block,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0 and result.stdout.startswith("serial="):
            serials.add(result.stdout.strip().removeprefix("serial=").upper())
    return serials


def create_certificate(token: str) -> str:
    print("==> No usable local Apple Distribution certificate -- generating a CSR")
    with tempfile.TemporaryDirectory() as tmp:
        key_path = Path(tmp) / "distribution.key"
        csr_path = Path(tmp) / "distribution.csr"
        subprocess.run(
            [
                "openssl",
                "req",
                "-new",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-keyout",
                str(key_path),
                "-out",
                str(csr_path),
                "-subj",
                "/CN=Zero Delta LLC/O=Zero Delta LLC/C=US",
            ],
            check=True,
            capture_output=True,
        )

        print("==> Submitting CSR to create the Apple Distribution certificate")
        # NOT base64-encoded: the CSR's PEM text is already base64-armored
        # data with headers, and sending it through a second base64 pass
        # produces this exact 409 ENTITY_ERROR.ATTRIBUTE.INVALID/"Invalid
        # Certificate" -- confirmed by reproducing it, then fixed per a real
        # bug report of the identical error (developer.apple.com/forums/
        # thread/132084), not guessed.
        created = call(
            token,
            "POST",
            "/certificates",
            {
                "data": {
                    "type": "certificates",
                    "attributes": {
                        "certificateType": "DISTRIBUTION",
                        "csrContent": csr_path.read_text(),
                    },
                }
            },
        )
        cert_id = created["data"]["id"]
        cert_der = base64.b64decode(created["data"]["attributes"]["certificateContent"])
        cert_path = Path(tmp) / "distribution.cer"
        cert_path.write_bytes(cert_der)

        print("==> Importing private key + certificate into the login keychain")
        subprocess.run(
            ["security", "import", str(key_path), "-A", "-T", "/usr/bin/codesign"],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["security", "import", str(cert_path), "-A", "-T", "/usr/bin/codesign"],
            check=True,
            capture_output=True,
        )
    print(f"    Certificate created and installed: {cert_id}")
    return cert_id


def write_profile(profile_content_b64: str) -> None:
    PROFILES_DIR.mkdir(parents=True, exist_ok=True)
    raw = base64.b64decode(profile_content_b64)
    dest = PROFILES_DIR / "gradus-ios-app-store.provisionprofile"
    dest.write_bytes(raw)
    print(f"    Wrote {dest} ({len(raw)} bytes)")


if __name__ == "__main__":
    raise SystemExit(main())
