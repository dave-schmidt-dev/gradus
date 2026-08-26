"""The Debug and Release Mac bundles must be tellable apart in Finder.

Debug sets `LSUIElement` NO so XCUITest can drive a real window; Release sets
it YES so the shipped app is a menu-bar agent. That difference makes the Debug
build a regular app, which Spotlight ranks *above* the installed agent app. On
2026-08-26 both bundles were named `GradusMac`, a Finder search for "gradus"
opened the Debug one, and because Debug carries its own bundle id
(`com.zerodelta.gradus.mac.dev`) it had its own empty defaults -- so it looked
like a working Gradus reporting no data. These tests lock the two apart.
"""

import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAC = ROOT / "app" / "GradusMac"
DEBUG_PLIST = MAC / "Info-Debug.plist"
RELEASE_PLIST = MAC / "Info-Release.plist"


def _plist(path: Path) -> dict:
    with path.open("rb") as handle:
        return plistlib.load(handle)


def test_debug_and_release_agent_policy_still_differ() -> None:
    """The premise of the collision: Debug is a regular app, Release is not."""
    assert _plist(DEBUG_PLIST)["LSUIElement"] is False
    assert _plist(RELEASE_PLIST)["LSUIElement"] is True


def test_debug_bundle_declares_a_distinct_display_name() -> None:
    """Without this, Finder shows two identically named `GradusMac` apps."""
    debug_name = _plist(DEBUG_PLIST).get("CFBundleDisplayName")

    assert debug_name, "Info-Debug.plist must set CFBundleDisplayName"
    assert debug_name != "GradusMac"
    # A build-setting reference would resolve to the same PRODUCT_NAME both
    # configurations share, which is the collision this guards.
    assert "$(" not in debug_name


def test_release_display_name_does_not_collide_with_debug() -> None:
    """Release may omit the key; if it sets one it must not match Debug."""
    release = _plist(RELEASE_PLIST)
    debug_name = _plist(DEBUG_PLIST)["CFBundleDisplayName"]

    if "CFBundleDisplayName" in release:
        assert release["CFBundleDisplayName"] != debug_name


def test_debug_bundle_id_stays_separate_from_the_installed_app() -> None:
    """The separate id is why the dev build has its own empty defaults."""
    project = (ROOT / "app" / "project.yml").read_text()

    assert "PRODUCT_BUNDLE_IDENTIFIER: com.zerodelta.gradus.mac.dev" in project
    assert "PRODUCT_BUNDLE_IDENTIFIER: com.zerodelta.gradus.mac\n" in project
