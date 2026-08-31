"""Contract checks for local release validation and lightweight hooks."""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).parents[1]
HOOK_CONFIG = ROOT / ".pre-commit-config.yaml"
README = ROOT / "README.md"
TESTING = ROOT / "TESTING.md"


def _hook_block(hook_id: str) -> str:
    """Return the committed config block for one hook id."""
    blocks = HOOK_CONFIG.read_text().split("      - id: ")
    matching = [block for block in blocks[1:] if block.startswith(f"{hook_id}\n")]

    assert len(matching) == 1, f"expected exactly one `{hook_id}` hook"
    return matching[0]


def test_both_local_hook_stages_are_installed() -> None:
    """Fast lint runs at commit; the Python suite runs at push."""
    hook_config = HOOK_CONFIG.read_text()

    assert "default_install_hook_types: [pre-commit, pre-push]" in hook_config


def test_push_runs_the_python_suite_and_nothing_else() -> None:
    """Pre-push is one unconditional pytest leg over the whole Python suite."""
    hook_config = HOOK_CONFIG.read_text()
    pytest_hook = _hook_block("pytest")

    assert hook_config.count("stages: [pre-push]") == 1
    assert "stages: [pre-push]" in pytest_hook
    assert "entry: uv run pytest -q" in pytest_hook
    # Without both of these the hook would be skipped whenever a push touched no
    # Python file, which is the silent-zero execution INV-11 discriminates.
    assert "always_run: true" in pytest_hook
    assert "pass_filenames: false" in pytest_hook


def test_push_hook_is_installed_on_disk() -> None:
    """A gate that is committed but never installed executes nothing."""
    resolved = subprocess.run(
        ["git", "rev-parse", "--git-path", "hooks"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    if resolved.returncode != 0:
        pytest.skip("not a git work tree")

    pre_push = ROOT / resolved.stdout.strip() / "pre-push"

    assert pre_push.exists(), "run `uv run pre-commit install` to install the gate"
    assert "pre-commit" in pre_push.read_text()


def test_push_does_not_invoke_local_xcode_gate() -> None:
    """The committed hook config must not invoke app/test-gate.sh for pushes."""
    hook_config = HOOK_CONFIG.read_text()

    assert "app/test-gate.sh" not in hook_config
    assert "id: test-gate" not in hook_config


def test_docs_name_candidate_bound_local_app_gate() -> None:
    """Docs must describe the candidate-bound local app validation gate."""
    docs = " ".join((README.read_text() + "\n" + TESTING.read_text()).lower().split())

    assert "candidate-bound local gate" in docs
    assert "authoritative local app-validation gate" in docs
    assert "app-specific candidate evidence is collected by the source-bound local" in docs
    assert "xcode cloud validation is optional and non-gating" in docs


def test_ios_scheme_includes_widget_tests_for_local_and_optional_hosted_runs() -> None:
    """The shared iOS scheme executes widget tests in every environment."""
    project = (ROOT / "app/project.yml").read_text()
    schemes = project.split("schemes:\n", maxsplit=1)[1]
    ios_scheme = schemes.split("  GradusiOS:\n", maxsplit=1)[1].split(
        "\n  GradusWidget:\n", maxsplit=1
    )[0]
    shared_scheme = (
        ROOT / "app/Gradus.xcodeproj/xcshareddata/xcschemes/GradusiOS.xcscheme"
    ).read_text()

    assert "- GradusWidgetTests" in ios_scheme
    assert 'BuildableName = "GradusWidgetTests.xctest"' in shared_scheme
    assert 'BlueprintName = "GradusWidgetTests"' in shared_scheme
