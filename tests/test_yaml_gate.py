"""Contract checks for the repository's mandatory YAML syntax pre-commit gate."""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).parents[1]
HOOK_CONFIG = ROOT / ".pre-commit-config.yaml"


def test_yaml_gate_contract_is_committed() -> None:
    """Keep YAML files on the syntax-only check-yaml hook."""
    hook = HOOK_CONFIG.read_text()
    check_yaml_hook = hook.split("      - id: check-yaml", 1)[1].split("\n      - id:", 1)[0]

    assert "repo: https://github.com/pre-commit/pre-commit-hooks" in hook
    assert "rev: v6.0.0" in hook
    assert "types: [yaml]" in check_yaml_hook
    assert "stages: [pre-commit]" in check_yaml_hook
    assert "--allow-multiple-documents" not in check_yaml_hook
    assert "--unsafe" not in check_yaml_hook
    assert "--fix" not in check_yaml_hook
    assert "--format" not in check_yaml_hook
