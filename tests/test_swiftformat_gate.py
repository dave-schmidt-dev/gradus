"""Contract checks for the repository's mandatory SwiftFormat pre-commit gate."""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).parents[1]
HOOK_CONFIG = ROOT / ".pre-commit-config.yaml"
SWIFTFORMAT_CONFIG = ROOT / ".swiftformat"


def _swiftformat_hook_block(hook: str) -> str:
    """Return only the SwiftFormat entry, excluding other hook settings."""
    return hook.split("      - id: swiftformat", 1)[1].split("\n      - id:", 1)[0]


def test_swiftformat_gate_contract_is_committed() -> None:
    """Keep changed Swift files in the non-mutating, explicit-format hook."""
    hook = HOOK_CONFIG.read_text()
    config = SWIFTFORMAT_CONFIG.read_text()
    swiftformat_hook = _swiftformat_hook_block(hook)

    assert "entry: swiftformat --lint --cache ignore --config .swiftformat" in swiftformat_hook
    assert "types: [swift]" in swiftformat_hook
    assert "require_serial: true" in swiftformat_hook
    assert "stages: [pre-commit]" in swiftformat_hook
    assert "pass_filenames: false" not in swiftformat_hook
    assert "always_run: true" not in swiftformat_hook
    assert "--all" not in swiftformat_hook
    assert "--output" not in swiftformat_hook
    assert "--swift-version 6.0" in config
