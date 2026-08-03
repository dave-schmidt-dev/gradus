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
    bws-run -- uv run --with pyjwt --with cryptography app/testflight-setup.py
"""

from __future__ import annotations

import sys

from _asc_api import call, make_token

BUNDLE_ID = "com.zerodelta.gradus.ios"
INTERNAL_GROUP_NAME = "Internal Testers"


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

    print("==> Finding latest processed build")
    builds = call(
        token,
        "GET",
        f"/builds?filter[app]={app_id}&filter[processingState]=VALID&sort=-uploadedDate&limit=1",
    )
    build_data = (builds or {}).get("data") or []
    if not build_data:
        print("No VALID (processed) build found yet — nothing to assign.")
        return 0
    build_id = build_data[0]["id"]
    build_version = build_data[0]["attributes"].get("version")
    print(f"    Latest build: version {build_version} ({build_id})")

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
