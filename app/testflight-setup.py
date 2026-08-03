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

import sys
import time

from _asc_api import call, make_token

BUNDLE_ID = "com.zerodelta.gradus.ios"
INTERNAL_GROUP_NAME = "Internal Testers"
BUILD_POLL_INTERVAL_SECONDS = 30
BUILD_POLL_TIMEOUT_SECONDS = 30 * 60


def main() -> int:
    token = make_token()

    print(f"==> Looking up app by bundle ID {BUNDLE_ID}")
    apps = call(token, "GET", f"/apps?filter[bundleId]={BUNDLE_ID}")
    if not apps or not apps.get("data"):
        print(f"FAIL: no app found for bundle ID {BUNDLE_ID}", file=sys.stderr)
        return 1
    app_id = apps["data"][0]["id"]
    print(f"    App ID: {app_id}")

    print("==> Finding internal beta group")
    groups = call(token, "GET", f"/apps/{app_id}/betaGroups?limit=50")
    internal_groups = [
        g for g in (groups or {}).get("data", []) if g["attributes"].get("isInternalGroup")
    ]
    if not internal_groups:
        print(f"    None found. Creating internal group '{INTERNAL_GROUP_NAME}'")
        created = call(
            token,
            "POST",
            "/betaGroups",
            {
                "data": {
                    "type": "betaGroups",
                    "attributes": {"name": INTERNAL_GROUP_NAME, "isInternalGroup": True},
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

    target_version = sys.argv[1] if len(sys.argv) > 1 else None
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


if __name__ == "__main__":
    raise SystemExit(main())
