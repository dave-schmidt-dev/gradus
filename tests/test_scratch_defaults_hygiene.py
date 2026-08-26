"""Swift test targets must not strand `UserDefaults` suites in `~/Library`.

Two rules, both source-level. A behavioral test cannot enforce either one: the
file a leaking suite leaves behind is written by cfprefsd on its own schedule,
seconds after the test process is gone, so there is no moment during a run at
which the damage is observable. Measured 2026-08-26 -- a run ended at 13:49:21
with every file deleted and cfprefsd recreated all thirteen at 13:49:30.

1. Suites are created through `scratchDefaults`, which clears the domain first.
2. Suite names are fixed, never UUID-derived. A UUID isolates but makes the
   suite unnameable afterwards, so each run strands a file nothing will ever
   reuse or clean up. That is how 800 `com.zerodelta.gradus.mac.tests.*` and 240
   `presence-*` plists accumulated before anyone noticed.
"""

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).parents[1]
TEST_TARGETS = (
    ROOT / "app" / "GradusMacTests",
    ROOT / "app" / "GradusKit" / "Tests" / "GradusKitTests",
    ROOT / "app" / "GradusCredentialBridgeTests",
)
# The two helpers are the only places allowed to touch the raw APIs.
HELPERS = {"SnapshotTestSupport.swift", "ScratchDefaults.swift"}

RAW_CREATION = re.compile(r"UserDefaults\(suiteName:")
RAW_TEARDOWN = re.compile(r"\.removePersistentDomain\(forName:")
UUID_SUITE = re.compile(r'"[^"]*\\\(UUID\(\)\.uuidString\)[^"]*"')


def _swift_sources():
    for target in TEST_TARGETS:
        if not target.is_dir():
            continue
        yield from sorted(target.rglob("*.swift"))


def _offenders(pattern, *, skip_helpers):
    hits = []
    for path in _swift_sources():
        if skip_helpers and path.name in HELPERS:
            continue
        for number, line in enumerate(path.read_text().splitlines(), start=1):
            if pattern.search(line):
                hits.append(f"{path.relative_to(ROOT)}:{number}: {line.strip()}")
    return hits


def test_the_test_targets_exist():
    # Guards the rest of the file: a renamed directory would silently make every
    # assertion below vacuous, since they all iterate over the same empty glob.
    found = [t for t in TEST_TARGETS if t.is_dir()]
    assert found, f"none of the Swift test targets were found under {ROOT}"
    assert list(_swift_sources()), "no Swift sources found in the test targets"


def test_suites_are_created_through_the_scratch_helper():
    offenders = _offenders(RAW_CREATION, skip_helpers=True)
    assert not offenders, (
        "`UserDefaults(suiteName:)` used directly; call `scratchDefaults(_:)` so the "
        "domain is cleared before use:\n  " + "\n  ".join(offenders)
    )


def test_only_the_helpers_remove_a_persistent_domain():
    offenders = _offenders(RAW_TEARDOWN, skip_helpers=True)
    assert not offenders, (
        "`removePersistentDomain(forName:)` clears keys but leaves the file; call "
        "`removeScratchDefaultsSuite(_:using:)`:\n  " + "\n  ".join(offenders)
    )


def test_no_suite_name_is_derived_from_a_uuid():
    offenders = []
    for path in _swift_sources():
        text = path.read_text()
        for match in UUID_SUITE.finditer(text):
            literal = match.group(0)
            # Only string literals that name a suite matter; a UUID inside test
            # data (a record id, a fixture) is unrelated to preference domains.
            context = text[max(0, match.start() - 120) : match.start()]
            if "suiteName" in context or "Suite =" in context or "suite =" in context:
                line = text.count("\n", 0, match.start()) + 1
                offenders.append(f"{path.relative_to(ROOT)}:{line}: {literal}")
    assert not offenders, (
        "UUID-derived suite name strands one preference file per run; use a fixed "
        "name unique to the test:\n  " + "\n  ".join(offenders)
    )


@pytest.mark.parametrize("helper", sorted(HELPERS))
def test_each_target_that_uses_the_helper_defines_one(helper):
    # GradusKit is a separate package, so the helper is duplicated rather than
    # shared. If one copy is deleted its target silently loses the guarantee.
    matches = [p for p in _swift_sources() if p.name == helper]
    assert matches, f"{helper} is missing; its test target has no scratch-suite helper"
    for path in matches:
        text = path.read_text()
        assert "func scratchDefaults(" in text, f"{path.relative_to(ROOT)} lost scratchDefaults"
        assert "func removeScratchDefaultsSuite(" in text, (
            f"{path.relative_to(ROOT)} lost removeScratchDefaultsSuite"
        )
