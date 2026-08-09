"""Repository hygiene checks for snapshot fixtures and their baselines."""

from __future__ import annotations

import hashlib
import re
from collections import defaultdict
from itertools import combinations
from pathlib import Path

from gradus.snapshot import V2_WINDOW_SPECS

ROOT = Path(__file__).resolve().parents[1]
FIXTURE_COUNTS = {
    ROOT / "app/GradusiOSTests/DashboardSnapshotTests.swift": 6,
    ROOT / "app/GradusiOSTests/DensityLayoutSnapshotTests.swift": 14,
    ROOT / "app/GradusiOSTests/SettingsViewSnapshotTests.swift": 1,
}
BASELINE_DIRS = (
    ROOT / "app/GradusiOSTests/__Snapshots__",
    ROOT / "app/GradusMacTests/__Snapshots__",
)

# Keep this empty unless a deliberate duplicate is documented with both fields.
DUPLICATE_ALLOWLIST: dict[tuple[str, str], dict[str, str]] = {}

_NAMED_WINDOW = re.compile(
    r"ProviderWindow\s*\((?:(?!\)).)*?\bid\s*:\s*\"([^\"]+)\"",
    re.DOTALL,
)
_POSITIONAL_WINDOW = re.compile(r"\bw\s*\(\s*\"([^\"]+)\"\s*,")


def extract_window_ids(source: str) -> list[str]:
    """Extract named ProviderWindow and positional w fixture constructors."""
    return _NAMED_WINDOW.findall(source) + _POSITIONAL_WINDOW.findall(source)


def registered_window_ids() -> set[str]:
    """Return every schema-v2 window id emitted by the snapshot producer."""
    return {window.window_id for specs in V2_WINDOW_SPECS.values() for window in specs}


def validate_fixture_source(source: str, expected_count: int) -> list[str]:
    """Validate extraction count and ids for one Swift fixture source."""
    ids = extract_window_ids(source)
    assert len(ids) == expected_count, (
        f"expected {expected_count} extracted windows, got {len(ids)}"
    )
    unknown = sorted(set(ids) - registered_window_ids())
    assert not unknown, f"fixture uses unregistered window ids: {unknown}"
    return ids


def test_snapshot_fixture_window_ids_are_registered_and_extracted() -> None:
    for path, expected_count in FIXTURE_COUNTS.items():
        validate_fixture_source(path.read_text(), expected_count)


def test_snapshot_fixture_extractor_rejects_under_matching() -> None:
    path, expected_count = next(
        path_and_count
        for path_and_count in FIXTURE_COUNTS.items()
        if "DensityLayout" in path_and_count[0].name
    )
    source = path.read_text().replace('w("ap",', 'not_a_window("ap",', 1)
    try:
        validate_fixture_source(source, expected_count)
    except AssertionError:
        return
    raise AssertionError("extractor accepted an under-matched fixture")


def test_snapshot_fixture_extractor_rejects_over_matching() -> None:
    source = 'let provider = w("cursor", 0, -0.1, nil)'
    try:
        validate_fixture_source(source, 1)
    except AssertionError:
        return
    raise AssertionError("extractor accepted a provider name as a window id")


def test_snapshot_baselines_have_unique_sha256_digests() -> None:
    by_digest: dict[str, list[str]] = defaultdict(list)
    for directory in BASELINE_DIRS:
        for path in sorted(directory.rglob("*.png")):
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            by_digest[digest].append(str(path.relative_to(ROOT)))

    for digest, paths in by_digest.items():
        for pair in combinations(paths, 2):
            metadata = DUPLICATE_ALLOWLIST.get(pair)
            if metadata is None:
                raise AssertionError(f"duplicate baseline sha256 {digest}: {pair}")
            assert metadata.get("reason"), f"allowlisted duplicate lacks reason: {pair}"
            assert metadata.get("task_id"), f"allowlisted duplicate lacks task id: {pair}"
