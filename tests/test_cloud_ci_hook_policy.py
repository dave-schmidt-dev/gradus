"""Contract checks for cloud-only app validation after push."""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).parents[1]
HOOK_CONFIG = ROOT / ".pre-commit-config.yaml"
README = ROOT / "README.md"
TESTING = ROOT / "TESTING.md"


def test_only_fast_pre_commit_hook_type_is_installed() -> None:
    """Fast local checks should be the only pre-commit hook type installed."""
    hook_config = HOOK_CONFIG.read_text()

    assert "default_install_hook_types: [pre-commit]" in hook_config
    assert "default_install_hook_types: [pre-commit, pre-push]" not in hook_config


def test_push_does_not_invoke_local_xcode_gate() -> None:
    """The committed hook config must not invoke app/test-gate.sh for pushes."""
    hook_config = HOOK_CONFIG.read_text()

    assert "app/test-gate.sh" not in hook_config
    assert "id: test-gate" not in hook_config
    assert "stages: [pre-push]" not in hook_config


def test_docs_name_xcode_cloud_as_post_push_app_gate() -> None:
    """Docs must describe Xcode Cloud as the post-push app validation gate."""
    docs = " ".join((README.read_text() + "\n" + TESTING.read_text()).lower().split())

    assert "required xcode cloud checks" in docs
    assert "pushes trigger required xcode cloud checks" in docs
    assert "local hooks stay lightweight and do not run xcode app automation" in docs
    assert "app-specific evidence is collected by the required xcode cloud checks" in docs


def test_required_ios_cloud_scheme_includes_widget_tests() -> None:
    """The required iOS cloud action must execute the widget test target."""
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
