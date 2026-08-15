"""Repository hygiene checks for snapshot fixtures and their baselines."""

from __future__ import annotations

import hashlib
import re
from collections import defaultdict
from itertools import combinations
from pathlib import Path

from gradus.snapshot import V2_WINDOW_SPECS

ROOT = Path(__file__).resolve().parents[1]
_IOS_TESTS = ROOT / "app/GradusiOSTests"
# A suite's windows are counted across every file that declares them, because
# `006356d` moved most of them into companion `*SnapshotFixtures.swift` files
# without changing a single one. Pinning the count to the `*Tests.swift` file
# alone made a pure relocation look like a 6-window loss. The totals below are
# unchanged from before that split -- what moved is where they live.
FIXTURE_COUNTS = {
    "dashboard": (
        (
            _IOS_TESTS / "DashboardSnapshotTests.swift",
            _IOS_TESTS / "DashboardSnapshotFixtures.swift",
        ),
        8,
    ),
    "density-layout": (
        (
            _IOS_TESTS / "DensityLayoutSnapshotTests.swift",
            _IOS_TESTS / "DensityLayoutSnapshotFixtures.swift",
        ),
        15,
    ),
    "settings": ((_IOS_TESTS / "SettingsViewSnapshotTests.swift",), 1),
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


def suite_source(paths: tuple[Path, ...]) -> str:
    """Concatenate a suite's fixture-declaring files into one source blob."""
    missing = [str(path.relative_to(ROOT)) for path in paths if not path.is_file()]
    assert not missing, f"fixture source has moved or been deleted: {missing}"
    return "\n".join(path.read_text() for path in paths)


def test_snapshot_fixture_window_ids_are_registered_and_extracted() -> None:
    # Every suite is checked before failing. Reporting only the first hid that
    # the same refactor had broken two of the three suites, not one.
    failures: list[str] = []
    for suite, (paths, expected_count) in FIXTURE_COUNTS.items():
        try:
            validate_fixture_source(suite_source(paths), expected_count)
        except AssertionError as exc:
            failures.append(f"{suite}: {exc}")
    assert not failures, "snapshot fixture drift:\n  " + "\n  ".join(failures)


def test_snapshot_fixture_extractor_rejects_under_matching() -> None:
    paths, expected_count = FIXTURE_COUNTS["density-layout"]
    source = suite_source(paths).replace('w("ap",', 'not_a_window("ap",', 1)
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
