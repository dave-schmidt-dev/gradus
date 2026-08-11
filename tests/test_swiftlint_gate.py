"""Contract checks for the repository's mandatory SwiftLint pre-commit gate."""

from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).parents[1]
HOOK_CONFIG = ROOT / ".pre-commit-config.yaml"
SWIFTLINT_CONFIG = ROOT / ".swiftlint.yml"
BASELINE = ROOT / ".swiftlint-baseline.json"


def test_swiftlint_gate_contract_is_committed() -> None:
    """Keep the strict, baseline-backed Swift-only hook from disappearing."""
    hook = HOOK_CONFIG.read_text()
    config = SWIFTLINT_CONFIG.read_text()

    assert "id: swiftlint" in hook
    assert "entry: swiftlint lint" in hook
    assert "--strict" in hook
    assert "--no-cache" in hook
    assert "--baseline .swiftlint-baseline.json" in hook
    assert "--fix" not in hook
    assert "--autocorrect" not in hook
    assert "types: [swift]" in hook
    assert "stages: [pre-commit]" in hook
    assert "- app" in config
    for excluded in (
        "app/build",
        "app/GradusKit/.build",
        "app/DerivedData",
        "app/Generated",
    ):
        assert excluded in config

    baseline = json.loads(BASELINE.read_text())
    assert isinstance(baseline, list)
    assert baseline
    assert all("violation" in entry for entry in baseline)
