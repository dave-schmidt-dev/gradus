"""Contract checks for the mandatory ShellCheck pre-commit gate."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).parents[1]
HOOK_CONFIG = ROOT / ".pre-commit-config.yaml"
SHELL_SUFFIXES = {".sh", ".bash", ".zsh", ".command"}
SHELLCHECK_EXCLUDES = {Path("monitor")}


def _shell_scripts() -> list[Path]:
    tracked = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return [
        ROOT / relative
        for relative in map(Path, tracked.stdout.splitlines())
        if relative.suffix in SHELL_SUFFIXES and relative not in SHELLCHECK_EXCLUDES
    ]


def test_shellcheck_gate_contract_is_committed() -> None:
    """Keep the strict, shell-only, non-fixing hook from disappearing."""
    hook = HOOK_CONFIG.read_text()

    assert "id: shellcheck" in hook
    assert "entry: shellcheck --severity=warning" in hook
    assert "types: [shell]" in hook
    assert "exclude: ^monitor$" in hook
    assert "stages: [pre-commit]" in hook
    assert "--fix" not in hook
    assert "--format=diff" not in hook


def test_repository_shell_scripts_pass_shellcheck() -> None:
    """The checked-in shell surface must remain clean at the hook's severity."""
    shellcheck = shutil.which("shellcheck")
    assert shellcheck, "ShellCheck must be installed for the pre-commit gate"

    result = subprocess.run(
        [shellcheck, "--severity=warning", *_shell_scripts()],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_shellcheck_rejects_a_warning(tmp_path: Path) -> None:
    """The configured severity must fail on an ordinary ShellCheck finding."""
    shellcheck = shutil.which("shellcheck")
    assert shellcheck, "ShellCheck must be installed for the pre-commit gate"
    script = tmp_path / "finding.sh"
    script.write_text("#!/usr/bin/env bash\nunused=value\n")

    result = subprocess.run(
        [shellcheck, "--severity=warning", script],
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert "SC2034" in result.stdout
