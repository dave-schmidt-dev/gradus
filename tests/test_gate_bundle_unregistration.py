"""`app/test-gate.sh` must unregister its bundles before deleting DerivedData.

`rm -rf` on a DerivedData tree does not undo what LaunchServices recorded when
xcodebuild registered the app it built there. Every gate run used a fresh temp
path, so every run leaked one more registration; by 2026-08-26 there were 404
dead Gradus bundles, and Finder resolved "gradus" to one of them instead of
`/Applications/GradusMac.app`. These tests pin the cleanup that closes the leak.

The function is extracted and run against a fake `lsregister` recorder rather
than the real one -- a test must never mutate the machine's LaunchServices
database. That works because the function dereferences `$LSREGISTER` at call
time, so the injected value wins in a shell that never sourced the gate.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).parents[1]
GATE = ROOT / "app" / "test-gate.sh"

FUNCTION = "gate_unregister_bundles"


def _function_source() -> str:
    """Return the committed body of the cleanup function, verbatim."""
    match = re.search(
        rf"^{FUNCTION}\(\) \{{\n.*?^\}}$",
        GATE.read_text(),
        re.DOTALL | re.MULTILINE,
    )

    assert match, f"`{FUNCTION}` is no longer defined in {GATE.name}"
    return match.group(0)


def _run_against(derived_data_dir: Path, recorder: Path) -> str:
    """Run the extracted function with a fake lsregister; return what it logged."""
    log = recorder.parent / "calls.log"
    recorder.write_text(f'#!/bin/bash\nprintf "%s\\n" "$*" >> {log}\n')
    recorder.chmod(0o755)

    script = "\n".join(
        [
            "set -u",
            f'derived_data_dir="{derived_data_dir}"',
            f'LSREGISTER="{recorder}"',
            _function_source(),
            FUNCTION,
        ]
    )
    subprocess.run(["bash", "-c", script], check=True)

    return log.read_text() if log.exists() else ""


def test_the_exit_trap_unregisters_before_it_deletes() -> None:
    """Reversed, the function would scan a directory that no longer exists."""
    trap = GATE.read_text().split("trap '")[-1].split("' EXIT")[0]

    assert FUNCTION in trap, "the EXIT trap must call the cleanup"
    assert trap.index(FUNCTION) < trap.index('rm -rf "$derived_data_dir"')


def test_every_bundle_under_derived_data_is_unregistered(tmp_path: Path) -> None:
    """Both the top-level app and one nested in a test runner are found."""
    products = tmp_path / "dd" / "Build" / "Products" / "Debug"
    bundles = [
        products / "GradusMac.app",
        products / "GradusMacUITests-Runner.app" / "Contents" / "PlugIns" / "x.app",
    ]
    for bundle in bundles:
        bundle.mkdir(parents=True)

    logged = _run_against(tmp_path / "dd", tmp_path / "lsregister")

    for bundle in bundles:
        assert f"-u {bundle}" in logged


def test_the_index_store_is_skipped(tmp_path: Path) -> None:
    """It is the one subtree large enough to matter and holds no products."""
    index = tmp_path / "dd" / "Index.noindex" / "stale.app"
    index.mkdir(parents=True)

    assert _run_against(tmp_path / "dd", tmp_path / "lsregister") == ""


def test_nothing_outside_derived_data_is_touched(tmp_path: Path) -> None:
    """A stray sibling bundle must not be swept up by the find."""
    (tmp_path / "dd").mkdir()
    (tmp_path / "dd" / "GradusMac.app").mkdir()
    sibling = tmp_path / "Applications" / "GradusMac.app"
    sibling.mkdir(parents=True)

    logged = _run_against(tmp_path / "dd", tmp_path / "lsregister")

    assert str(sibling) not in logged


@pytest.mark.parametrize("directory", ["", "absent"])
def test_an_unset_or_missing_directory_is_a_silent_no_op(tmp_path: Path, directory: str) -> None:
    """The trap fires even when the run died before the build; it must not fail."""
    target = tmp_path / directory if directory else Path()

    assert _run_against(target, tmp_path / "lsregister") == ""
