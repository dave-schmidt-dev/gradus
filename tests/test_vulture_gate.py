"""Contract checks for the mandatory dead-code pre-commit gate.

Dead-code detection ranks alongside lint and tests in the project's quality
standard, but the repository ran ruff, swiftlint, swiftformat, and shellcheck
with nothing detecting dead code until 2026-08-31. These tests keep the hook,
its configuration, and the clean result from drifting apart.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import tomllib

ROOT = Path(__file__).parents[1]
HOOK_CONFIG = ROOT / ".pre-commit-config.yaml"
PROJECT_CONFIG = ROOT / "pyproject.toml"


def _vulture_config() -> dict:
    return tomllib.loads(PROJECT_CONFIG.read_text())["tool"]["vulture"]


def test_vulture_hook_contract_is_committed() -> None:
    """Keep the whole-tree, non-fixing dead-code hook from disappearing."""
    hook = HOOK_CONFIG.read_text()

    assert "id: vulture" in hook
    assert "entry: uv run vulture" in hook
    # Vulture cannot see cross-file usage, so a changed-files-only invocation
    # would report every module's public surface as dead. It must run whole-tree.
    assert "pass_filenames: false" in hook
    assert "always_run: true" in hook
    assert "stages: [pre-commit]" in hook


def test_vulture_is_a_declared_dev_dependency() -> None:
    assert "vulture" in PROJECT_CONFIG.read_text()


def test_vulture_configuration_lives_in_pyproject() -> None:
    """The hook entry takes no flags, so the config is the only source of truth."""
    config = _vulture_config()

    assert config["min_confidence"] == 80
    assert "gradus" in config["paths"]
    assert "tests" in config["paths"]
    assert "launchd" in config["paths"]
    # `app/build/` vendors a CPython framework for the single-bundle runtime;
    # scanning it takes 40s and reports only CPython's own test corpus.
    assert "*/build/*" in config["exclude"]


def test_repository_python_surface_has_no_dead_code() -> None:
    """The checked-in Python surface must stay clean at the hook's threshold."""
    if shutil.which("uv") is None:  # pragma: no cover - tool always present locally
        return

    result = subprocess.run(
        ["uv", "run", "vulture"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=300,
    )
    assert result.returncode == 0, result.stdout + result.stderr
