#!/usr/bin/env python3
"""Prints the next CFBundleVersion (build number) for GradusiOS: the highest
existing build's version on App Store Connect, plus one (or "1" if none
exist yet). ASC rejects re-uploading a build with a version number already
used for the app, so `archive-upload-ios.sh` must bump CURRENT_PROJECT_VERSION
before each archive rather than reusing the value checked into project.yml.

Run through the fixed consumer that injects App Store Connect credentials; do
not invoke this module with a legacy secret wrapper.
"""

from __future__ import annotations

import sys
from collections.abc import Callable, Iterable, Mapping
from typing import Any

from _asc_api import call, make_token

BUNDLE_ID = "com.zerodelta.gradus.ios"


class BuildHistoryError(ValueError):
    """Raised when ASC returns malformed or duplicate build history."""


def read_build_history(pages: Iterable[Mapping[str, Any]]) -> list[int]:
    """Validate fixture-shaped ASC pages and return numeric build versions."""
    seen_ids: set[str] = set()
    seen_builds: set[int] = set()
    versions: list[int] = []
    for page in pages:
        if not isinstance(page, Mapping) or not isinstance(page.get("data"), list):
            raise BuildHistoryError("malformed ASC build history page")
        for item in page["data"]:
            if not isinstance(item, Mapping) or not isinstance(item.get("id"), str):
                raise BuildHistoryError("malformed ASC build entry")
            attributes = item.get("attributes")
            if not isinstance(attributes, Mapping):
                raise BuildHistoryError("ASC build entry is missing attributes")
            raw = attributes.get("version", attributes.get("buildNumber"))
            if not isinstance(raw, (str, int)) or isinstance(raw, bool) or not str(raw).isdigit():
                raise BuildHistoryError("ASC build version is not numeric")
            value = int(raw)
            if value < 1 or item["id"] in seen_ids or value in seen_builds:
                raise BuildHistoryError("duplicate or invalid ASC build entry")
            seen_ids.add(item["id"])
            seen_builds.add(value)
            versions.append(value)
    return sorted(versions)


def fetch_all_build_pages(
    fetch: Callable[[str], Mapping[str, Any]], app_id: str
) -> list[Mapping[str, Any]]:
    """Follow ASC pagination using the existing redacted API boundary."""
    pages: list[Mapping[str, Any]] = []
    path = f"/builds?filter[app]={app_id}&limit=200"
    while path:
        page = fetch(path)
        if not isinstance(page, Mapping):
            raise BuildHistoryError("malformed ASC response")
        pages.append(page)
        next_link = (
            page.get("links", {}).get("next") if isinstance(page.get("links"), Mapping) else None
        )
        if next_link is None:
            break
        if not isinstance(next_link, str) or not next_link:
            raise BuildHistoryError("malformed ASC pagination link")
        path = next_link
    return pages


def next_build_number(pages: Iterable[Mapping[str, Any]]) -> int:
    """Return the highest validated numeric build plus one."""
    versions = read_build_history(pages)
    return (max(versions) + 1) if versions else 1


def main() -> int:
    token = make_token()

    apps = call(token, "GET", f"/apps?filter[bundleId]={BUNDLE_ID}")
    if not apps or not apps.get("data"):
        print(f"FAIL: no app found for bundle ID {BUNDLE_ID}", file=sys.stderr)
        return 1
    app_id = apps["data"][0]["id"]

    pages = fetch_all_build_pages(
        lambda path: call(token, "GET", path),
        app_id,
    )
    print(next_build_number(pages))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
