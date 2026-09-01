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


IOS_PLIST = ROOT / "app" / "GradusiOS" / "Info.plist"


def _project() -> dict:
    import yaml

    with (ROOT / "app" / "project.yml").open(encoding="utf-8") as handle:
        return yaml.safe_load(handle)


def test_shipped_mac_wrapper_is_named_gradus() -> None:
    """Release ships `Gradus.app`; the internal target name is not customer-facing."""
    mac = _project()["targets"]["GradusMac"]["settings"]

    assert mac["configs"]["Release"]["PRODUCT_NAME"] == "Gradus"
    assert _plist(RELEASE_PLIST)["CFBundleName"] == "$(PRODUCT_NAME)"
    assert _plist(RELEASE_PLIST)["CFBundleDisplayName"] == "Gradus"


def test_debug_wrapper_keeps_the_internal_name_the_ui_harness_launches() -> None:
    """The exact-PID harness launches `Debug/GradusMac.app/Contents/MacOS/GradusMac`."""
    mac = _project()["targets"]["GradusMac"]["settings"]
    harness = (ROOT / "app" / "GradusMacUITests" / "GradusMacUITests.swift").read_text()

    assert mac["configs"]["Debug"]["PRODUCT_NAME"] == "GradusMac"
    assert 'appendingPathComponent("GradusMac.app", isDirectory: true)' in harness


def test_renaming_the_product_does_not_rename_the_swift_module() -> None:
    """PRODUCT_NAME silently drives PRODUCT_MODULE_NAME unless it is pinned."""
    mac = _project()["targets"]["GradusMac"]["settings"]

    assert mac["base"]["PRODUCT_MODULE_NAME"] == "GradusMac"


def test_ios_bundle_presents_gradus_without_renaming_the_product() -> None:
    """iOS needs the display name only; the archive tooling keeps `GradusiOS`."""
    ios = _project()["targets"]["GradusiOS"]

    assert ios["info"]["properties"]["CFBundleName"] == "Gradus"
    assert ios["info"]["properties"]["CFBundleDisplayName"] == "Gradus"
    assert "PRODUCT_NAME" not in ios["settings"]["base"]
    assert _plist(IOS_PLIST)["CFBundleName"] == "Gradus"
    assert _plist(IOS_PLIST)["CFBundleDisplayName"] == "Gradus"


def test_no_shipped_bundle_presents_an_internal_target_name_to_users() -> None:
    """`GradusMac`/`GradusiOS` stay internal identifiers, never user-visible text."""
    for plist_path in (RELEASE_PLIST, IOS_PLIST):
        plist = _plist(plist_path)
        for key in ("CFBundleName", "CFBundleDisplayName"):
            value = plist.get(key)
            if value is None or value.startswith("$("):
                continue
            assert value == "Gradus", f"{plist_path.name}:{key} is customer-facing"


def test_the_rename_does_not_touch_either_bundle_identifier() -> None:
    """TCC grants and defaults domains are keyed on these; they must not move."""
    targets = _project()["targets"]

    assert (
        targets["GradusMac"]["settings"]["base"]["PRODUCT_BUNDLE_IDENTIFIER"]
        == "com.zerodelta.gradus.mac"
    )
    assert (
        targets["GradusiOS"]["settings"]["base"]["PRODUCT_BUNDLE_IDENTIFIER"]
        == "com.zerodelta.gradus.ios"
    )
    assert _plist(RELEASE_PLIST)["CFBundleIdentifier"] == "$(PRODUCT_BUNDLE_IDENTIFIER)"
