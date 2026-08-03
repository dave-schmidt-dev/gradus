#!/usr/bin/env python3
"""Prints the next CFBundleVersion (build number) for GradusiOS: the highest
existing build's version on App Store Connect, plus one (or "1" if none
exist yet). ASC rejects re-uploading a build with a version number already
used for the app, so `archive-upload-ios.sh` must bump CURRENT_PROJECT_VERSION
before each archive rather than reusing the value checked into project.yml.

Run via:
    bws-run -- uv run --with pyjwt --with cryptography app/next-ios-build-number.py
"""

from __future__ import annotations

import sys

from _asc_api import call, make_token

BUNDLE_ID = "com.zerodelta.gradus.ios"


def main() -> int:
    token = make_token()

    apps = call(token, "GET", f"/apps?filter[bundleId]={BUNDLE_ID}")
    if not apps or not apps.get("data"):
        print(f"FAIL: no app found for bundle ID {BUNDLE_ID}", file=sys.stderr)
        return 1
    app_id = apps["data"][0]["id"]

    builds = call(token, "GET", f"/builds?filter[app]={app_id}&limit=200")
    versions = [int(b["attributes"]["version"]) for b in (builds or {}).get("data", [])]
    next_version = (max(versions) + 1) if versions else 1
    print(next_version)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
