#!/usr/bin/env python3
"""List Gradus's existing internal TestFlight groups without mutating ASC.

This is a read-only attended discovery boundary. It emits only the bundle ID
and each internal group's immutable ID/display name; it never prints raw ASC
responses, credentials, tester records, or response bodies.
"""

from __future__ import annotations

import json
import sys
from typing import Any

from _asc_api import ASCClient, ASCError, make_token_provider

BUNDLE_ID = "com.zerodelta.gradus.ios"


class GroupDiscoveryError(RuntimeError):
    """Raised when ASC does not provide one safe, parseable group response."""


def _attrs(item: dict[str, Any]) -> dict[str, Any]:
    attrs = item.get("attributes", item)
    if not isinstance(attrs, dict):
        raise GroupDiscoveryError("malformed ASC group response")
    return attrs


def internal_groups(payload: dict[str, Any]) -> list[dict[str, Any]]:
    """Return allowlisted internal-group identity fields from one ASC payload."""

    entries = payload.get("data")
    if not isinstance(entries, list):
        raise GroupDiscoveryError("malformed ASC group response")
    result: list[dict[str, Any]] = []
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("id"), str):
            raise GroupDiscoveryError("malformed ASC group response")
        attrs = _attrs(entry)
        if attrs.get("isInternalGroup") is True:
            name = attrs.get("name")
            if not isinstance(name, str) or not name:
                raise GroupDiscoveryError("internal group name is missing")
            result.append({"id": entry["id"], "name": name})
    return result


def discover(client: ASCClient) -> dict[str, Any]:
    """Resolve the Gradus app and return only existing internal groups."""

    apps = client.request("GET", f"/apps?filter[bundleId]={BUNDLE_ID}") or {}
    app_data = apps.get("data")
    if not isinstance(app_data, list) or len(app_data) != 1 or not isinstance(app_data[0], dict):
        raise GroupDiscoveryError("bundle ID did not resolve to exactly one app")
    app_id = app_data[0].get("id")
    if not isinstance(app_id, str) or not app_id:
        raise GroupDiscoveryError("ASC app identity is missing")
    groups = client.request("GET", f"/apps/{app_id}/betaGroups?limit=200") or {}
    return {"bundle_id": BUNDLE_ID, "internal_groups": internal_groups(groups)}


def main() -> int:
    try:
        print(json.dumps(discover(ASCClient(make_token_provider())), sort_keys=True))
    except (ASCError, GroupDiscoveryError) as error:
        del error
        print("FAIL: internal-group discovery failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
