"""Fixture-only App Store Connect version/build history policy."""

from __future__ import annotations

import re
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from typing import Any


class VersionPolicyError(ValueError):
    """Raised for malformed history or an unsafe release-version choice."""


_NUMERIC = re.compile(r"^(0|[1-9][0-9]*)$")
_SEMVER = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")


def version_key(version: str) -> tuple[int, ...]:
    if not isinstance(version, str) or not _SEMVER.fullmatch(version):
        raise VersionPolicyError(f"malformed marketing version: {version!r}")
    return tuple(int(part) for part in version.split("."))


def build_key(build: int | str) -> int:
    if (
        isinstance(build, bool)
        or (isinstance(build, str) and not _NUMERIC.fullmatch(build))
        or not isinstance(build, (int, str))
    ):
        raise VersionPolicyError(f"malformed build number: {build!r}")
    value = int(build)
    if value < 1:
        raise VersionPolicyError(f"malformed build number: {build!r}")
    return value


@dataclass(frozen=True)
class ASCBuild:
    version: str
    build: int
    identifier: str


class FixtureASCVersionHistory:
    """Read ASC-shaped pages supplied by tests; no transport is permitted."""

    def __init__(self, pages: Iterable[Mapping[str, Any]], *, transport: Any = None):
        if transport is not None:
            raise VersionPolicyError("live transport is forbidden in fixture mode")
        self._pages = tuple(pages)

    def builds(self) -> list[ASCBuild]:
        found: list[ASCBuild] = []
        identities: set[str] = set()
        version_builds: set[tuple[str, int]] = set()
        for page in self._pages:
            if not isinstance(page, Mapping) or not isinstance(page.get("data"), list):
                raise VersionPolicyError("malformed ASC history page")
            for item in page["data"]:
                if not isinstance(item, Mapping):
                    raise VersionPolicyError("malformed ASC build")
                attributes = item.get("attributes", item)
                if not isinstance(attributes, Mapping):
                    raise VersionPolicyError("malformed ASC build attributes")
                version = attributes.get("version") or attributes.get("marketingVersion")
                build = attributes.get("buildNumber", attributes.get("build"))
                identifier = item.get("id")
                if not isinstance(identifier, str) or not identifier:
                    raise VersionPolicyError("ASC build is missing an identifier")
                parsed = ASCBuild(version_key(version) and version, build_key(build), identifier)
                if identifier in identities or (parsed.version, parsed.build) in version_builds:
                    raise VersionPolicyError("duplicate ASC build history entry")
                identities.add(identifier)
                version_builds.add((parsed.version, parsed.build))
                found.append(parsed)
        return sorted(
            found, key=lambda item: (version_key(item.version), item.build, item.identifier)
        )

    def newest_version(self) -> str | None:
        builds = self.builds()
        return max((item.version for item in builds), key=version_key) if builds else None


def require_new_marketing_version(
    history: FixtureASCVersionHistory,
    release_version: str,
    *,
    supersedes_reason: str | None = None,
    release_blocking_reason: str | None = None,
) -> tuple[int, ...]:
    """Require a caller-selected version to exceed fixture history unless justified."""
    requested = version_key(release_version)
    supplied_reasons = [
        reason for reason in (supersedes_reason, release_blocking_reason) if reason is not None
    ]
    override_reason = next(
        (reason for reason in supplied_reasons if isinstance(reason, str) and reason.strip()),
        None,
    )
    if supplied_reasons and override_reason is None:
        raise VersionPolicyError("supersedes/release-blocking reason must be non-empty text")
    current = history.newest_version()
    if current is not None and requested <= version_key(current) and override_reason is None:
        raise VersionPolicyError("release version is not strictly newer than ASC history")
    return requested
