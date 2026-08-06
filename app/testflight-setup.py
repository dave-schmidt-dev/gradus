#!/usr/bin/env python3
"""T6.1 automation: discover (or create) GradusiOS's internal TestFlight
group, report whether David is already an eligible/added tester, and assign
the latest processed build to the group.

Creating the internal group itself, and inviting a team member as a beta
tester into it, are both documented, ToS-safe API calls — POST /betaGroups
accepts isInternalGroup=true, and POST /betaTesters accepts a
relationships.betaGroups link (confirmed against Apple's official DocC
schemas for BetaGroupCreateRequest and BetaTesterCreateRequest, 2026-08-03).
Creating a betaTester this way is exactly what the ASC UI's "Invite Testers"
button does under the hood — it triggers Apple's own invitation email, not a
raw account action.

Run via:
    bws-run -- uv run --with pyjwt --with cryptography app/testflight-setup.py [version]

If `version` is given, polls specifically for that build's version number
instead of "whatever /builds returns as newest by uploadedDate". That
distinction matters: a build that altool just successfully uploaded can take
several minutes before it's even indexed as a queryable /builds resource at
all (separate from its processingState reaching VALID) -- polling by
uploadedDate alone can silently grab an older, already-processed build
instead of waiting for the new one, and happily report "already assigned,
nothing to do" without ever having looked at the build you actually meant.
"""

from __future__ import annotations

import argparse
import base64
import subprocess
import sys
import time
from pathlib import Path

from _asc_api import call, make_token

DEFAULT_BUNDLE_ID = "com.zerodelta.gradus.ios"
DEFAULT_INTERNAL_GROUP_NAME = "Internal Testers"
BUILD_POLL_INTERVAL_SECONDS = 30
BUILD_POLL_TIMEOUT_SECONDS = 30 * 60


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "version",
        nargs="?",
        help="build version to wait for; omitted means the newest uploaded build",
    )
    parser.add_argument(
        "--bundle-id",
        default=DEFAULT_BUNDLE_ID,
        help=f"App bundle ID (default: {DEFAULT_BUNDLE_ID})",
    )
    parser.add_argument(
        "--group-name",
        default=DEFAULT_INTERNAL_GROUP_NAME,
        help=f"Internal beta group name (default: {DEFAULT_INTERNAL_GROUP_NAME})",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="discover the app and existing internal groups without changing ASC",
    )
    parser.add_argument(
        "--create-group-only",
        action="store_true",
        help="create or find the internal group, then stop before testers/builds",
    )
    parser.add_argument(
        "--skip-tester-invites",
        action="store_true",
        help="do not create or link beta tester records",
    )
    parser.add_argument(
        "--create-profile",
        choices=("development", "distribution"),
        help="create and install a WWPIS iOS provisioning profile via the ASC API",
    )
    parser.add_argument(
        "--profile-name",
        help="override the name of the API-created provisioning profile",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    token = make_token()

    if args.create_profile:
        return create_profile(
            token,
            bundle_id=args.bundle_id,
            profile_kind=args.create_profile,
            profile_name=args.profile_name,
        )

    print(f"==> Looking up app by bundle ID {args.bundle_id}")
    apps = call(token, "GET", f"/apps?filter[bundleId]={args.bundle_id}")
    if not apps or not apps.get("data"):
        print(f"FAIL: no app found for bundle ID {args.bundle_id}", file=sys.stderr)
        return 1
    app_id = apps["data"][0]["id"]
    app_name = apps["data"][0]["attributes"].get("name")
    print(f"    App: {app_name} ({app_id})")

    print("==> Finding internal beta group")
    groups = call(token, "GET", f"/apps/{app_id}/betaGroups?limit=50")
    internal_groups = [
        g for g in (groups or {}).get("data", []) if g["attributes"].get("isInternalGroup")
    ]
    if not internal_groups:
        if args.dry_run:
            print(f"    None found. Would create internal group '{args.group_name}'")
            return 0
        print(f"    None found. Creating internal group '{args.group_name}'")
        created = call(
            token,
            "POST",
            "/betaGroups",
            {
                "data": {
                    "type": "betaGroups",
                    "attributes": {"name": args.group_name, "isInternalGroup": True},
                    "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
                }
            },
        )
        group_id = created["data"]["id"]
        group_name = created["data"]["attributes"].get("name")
        print(f"    Created internal group: {group_name} ({group_id})")
    else:
        group_id = internal_groups[0]["id"]
        group_name = internal_groups[0]["attributes"].get("name")
        print(f"    Internal group: {group_name} ({group_id})")

    if args.dry_run or args.create_group_only:
        print("==> Done. Group discovery/creation complete.")
        return 0

    if args.skip_tester_invites:
        print("==> Skipping tester discovery/invites")
    else:
        print("==> Listing current team members (users)")
        users = call(token, "GET", "/users?limit=50")
        members = [
            (u["id"], u["attributes"].get("username"), u["attributes"].get("roles"))
            for u in (users or {}).get("data", [])
        ]
        for uid, email, roles in members:
            print(f"    - {email} ({', '.join(roles or [])})")

        print("==> Checking existing testers already in the internal group")
        existing = call(token, "GET", f"/betaGroups/{group_id}/betaTesters?limit=50")
        existing_emails = {t["attributes"].get("email") for t in (existing or {}).get("data", [])}
        if existing_emails:
            print(f"    Already in group: {', '.join(sorted(existing_emails))}")
        else:
            print("    No testers in this group yet.")

        unmatched = [email for _, email, _ in members if email not in existing_emails]
        if unmatched:
            print(
                "==> These team members are eligible but not yet in the internal "
                "group. Checking for existing betaTesters records to link:"
            )
            for email in unmatched:
                testers = call(token, "GET", f"/betaTesters?filter[email]={email}")
                data = (testers or {}).get("data") or []
                if data:
                    tester_id = data[0]["id"]
                    print(f"    Linking {email} (betaTester {tester_id}) to group")
                    call(
                        token,
                        "POST",
                        f"/betaGroups/{group_id}/relationships/betaTesters",
                        {"data": [{"type": "betaTesters", "id": tester_id}]},
                    )
                    print(f"    Linked {email}.")
                else:
                    print(f"    No betaTesters record for {email} yet — creating one and inviting")
                    call(
                        token,
                        "POST",
                        "/betaTesters",
                        {
                            "data": {
                                "type": "betaTesters",
                                "attributes": {"email": email},
                                "relationships": {
                                    "betaGroups": {"data": [{"type": "betaGroups", "id": group_id}]}
                                },
                            }
                        },
                    )
                    print(f"    Invited {email} — TestFlight invite email is on its way.")

    target_version = args.version
    if target_version:
        print(f"==> Waiting for build version {target_version} to appear and process")
    else:
        print(
            "==> Finding latest processed build (polling — Apple processing can take several minutes)"
        )
    deadline = time.monotonic() + BUILD_POLL_TIMEOUT_SECONDS
    build_data: list = []
    while True:
        filter_version = f"&filter[version]={target_version}" if target_version else ""
        builds = call(
            token,
            "GET",
            f"/builds?filter[app]={app_id}{filter_version}&sort=-uploadedDate&limit=1",
        )
        build_data = (builds or {}).get("data") or []
        if build_data:
            state = build_data[0]["attributes"].get("processingState")
            version = build_data[0]["attributes"].get("version")
            if state == "VALID":
                break
            if state == "FAILED" or state == "INVALID":
                print(
                    f"FAIL: build (version {version}) processing state is {state}",
                    file=sys.stderr,
                )
                return 1
            print(f"    Build (version {version}) still processing ({state})...")
        else:
            label = f"version {target_version}" if target_version else "any builds"
            print(f"    No indexed build yet for {label}...")
        if time.monotonic() >= deadline:
            print("No VALID (processed) build found within the timeout — nothing to assign.")
            return 0
        time.sleep(BUILD_POLL_INTERVAL_SECONDS)
    build_id = build_data[0]["id"]
    build_version = build_data[0]["attributes"].get("version")
    print(f"    Build: version {build_version} ({build_id})")

    print("==> Checking whether build is already assigned to the group")
    group_builds = call(token, "GET", f"/betaGroups/{group_id}/builds?limit=50")
    assigned_ids = {b["id"] for b in (group_builds or {}).get("data", [])}
    if build_id in assigned_ids:
        print("    Already assigned. Nothing to do.")
    else:
        print("    Assigning build to internal group")
        call(
            token,
            "POST",
            f"/betaGroups/{group_id}/relationships/builds",
            {"data": [{"type": "builds", "id": build_id}]},
        )
        print("    Assigned.")

    print("==> Done.")
    return 0


def create_profile(
    token: str,
    *,
    bundle_id: str,
    profile_kind: str,
    profile_name: str | None,
) -> int:
    """Create and install an iOS profile using the Gradus API-backed path."""
    profile_config = {
        "development": {
            "certificate_type": "DEVELOPMENT",
            "profile_type": "IOS_APP_DEVELOPMENT",
            "name": "WWPIS iOS Development (API-created)",
            "filename": "wwpis-ios-development.provisionprofile",
            "certificate_label": "Apple Development",
        },
        "distribution": {
            "certificate_type": "DISTRIBUTION",
            "profile_type": "IOS_APP_STORE",
            "name": "WWPIS iOS App Store (API-created)",
            "filename": "wwpis-ios-app-store.provisionprofile",
            "certificate_label": "Apple Distribution",
        },
    }[profile_kind]
    name = profile_name or profile_config["name"]

    print(f"==> Looking up bundle ID {bundle_id}")
    bundle_ids = call(token, "GET", f"/bundleIds?filter[identifier]={bundle_id}")
    data = (bundle_ids or {}).get("data") or []
    if not data:
        print(f"FAIL: no bundleId resource found for {bundle_id}", file=sys.stderr)
        return 1
    bundle_id_resource = data[0]["id"]
    print(f"    bundleId resource: {bundle_id_resource}")

    print(f"==> Finding a usable {profile_config['certificate_label']} certificate")
    certs = call(
        token,
        "GET",
        f"/certificates?filter[certificateType]={profile_config['certificate_type']}&limit=50",
    )
    local_serials = local_certificate_serials(profile_config["certificate_label"])
    cert_id = None
    for certificate in (certs or {}).get("data", []):
        serial = (certificate["attributes"].get("serialNumber") or "").upper()
        if serial and serial in local_serials:
            cert_id = certificate["id"]
            print(
                "    Found usable local certificate: "
                f"{certificate['attributes'].get('displayName')} ({cert_id})"
            )
            break
    if not cert_id:
        print(
            f"FAIL: no {profile_config['certificate_label']} certificate has a matching local private key",
            file=sys.stderr,
        )
        return 1

    print(f"==> Replacing any existing profile named '{name}'")
    existing_profiles = call(token, "GET", f"/bundleIds/{bundle_id_resource}/profiles")
    for profile in (existing_profiles or {}).get("data", []):
        if profile["attributes"].get("name") == name:
            call(token, "DELETE", f"/profiles/{profile['id']}")

    print(f"==> Creating {profile_config['profile_type']} profile")
    created = call(
        token,
        "POST",
        "/profiles",
        {
            "data": {
                "type": "profiles",
                "attributes": {"name": name, "profileType": profile_config["profile_type"]},
                "relationships": {
                    "bundleId": {"data": {"type": "bundleIds", "id": bundle_id_resource}},
                    "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
                },
            }
        },
    )
    profile_content = created["data"]["attributes"]["profileContent"]
    profiles_dir = Path.home() / "Library" / "MobileDevice" / "Provisioning Profiles"
    profiles_dir.mkdir(parents=True, exist_ok=True)
    destination = profiles_dir / profile_config["filename"]
    destination.write_bytes(base64.b64decode(profile_content))
    print(f"==> Installed profile: {destination}")
    return 0


def local_certificate_serials(label: str) -> set[str]:
    """Return local certificate serials for certificates backed by this Mac."""
    listing = subprocess.run(
        ["security", "find-certificate", "-a", "-c", label, "-p"],
        capture_output=True,
        text=True,
        check=False,
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
            check=False,
        )
        if result.returncode == 0 and result.stdout.startswith("serial="):
            serials.add(result.stdout.strip().removeprefix("serial=").upper())
    return serials


if __name__ == "__main__":
    raise SystemExit(main())
