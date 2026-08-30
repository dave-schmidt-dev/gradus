"""Assemble and seal a candidate-current Gradus screenshot walkthrough."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from collections.abc import Callable, Mapping, Sequence
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .ledger import CandidateError, CandidateLedger, CandidateRecord


class WalkthroughError(ValueError):
    """Raised when walkthrough evidence is incomplete or stale."""


_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
_OWNER = "David"
_SOURCE_MARKERS = {
    "GradusiOS/EmptyStateView.swift": (
        "struct EmptyStateView",
        'accessibilityIdentifier("explore-sample")',
        'accessibilityIdentifier("icloud-account-discovery-status")',
        '"Try Again"',
        '"Continue"',
    ),
    "GradusiOS/SampleDataViews.swift": (
        "struct SampleDataDashboard",
        'accessibilityIdentifier("sample-data-banner")',
        'accessibilityIdentifier("sample-data-reset")',
        'accessibilityIdentifier("sample-data-exit")',
    ),
    "GradusiOS/ProviderDetailView.swift": ("struct ProviderDetailView",),
    "GradusiOS/SettingsView.swift": (
        "struct SettingsView",
        'accessibilityIdentifier: "warning-alerts-toggle"',
        'Button("Open iOS Settings")',
        "Requesting warning-alert permission…",
    ),
    "GradusiOS/SettingsView+SampleMode.swift": (
        'accessibilityIdentifier("sample-data-reset-settings")',
        'accessibilityIdentifier("sample-data-exit-settings")',
    ),
    "GradusiOS/SettingsView+LocalDisplay.swift": (
        'accessibilityIdentifier: "show-exhausted-toggle"',
        'Text("Sort providers")',
        'Toggle("Automatic"',
        "accessibilityLabel = SettingsView.dashboardCardSizeTitle",
    ),
    "GradusiOS/SettingsView+WarningThreshold.swift": (
        'accessibilityIdentifier("warning-threshold-slider")',
    ),
    "GradusiOS/DashboardView.swift": ('accessibilityIdentifier("settings-button")',),
    "GradusWidget/GradusSmallWidgetView.swift": (
        "struct GradusSmallWidgetView",
        "case .empty:",
        "case .unavailable:",
        "case let .current(snapshot):",
    ),
    "GradusWidget/GradusWidget.swift": ("StaticConfiguration", ".supportedFamilies"),
}


def _central_api():
    root = Path(__file__).resolve().parents[3] / "apple_developer"
    if str(root) not in sys.path:
        sys.path.insert(0, str(root))
    try:
        from release_tools.walkthrough import (  # type: ignore[import-not-found]
            WalkthroughError as CentralError,
        )
        from release_tools.walkthrough import (
            assemble_walkthrough,
            write_walkthrough,
        )
    except ImportError as exc:
        raise WalkthroughError("central release_tools.walkthrough is unavailable") from exc
    return assemble_walkthrough, write_walkthrough, CentralError


def _digest(path: str | Path) -> str:
    value = hashlib.sha256()
    try:
        with Path(path).open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                value.update(chunk)
    except OSError as exc:
        raise WalkthroughError(f"file is unreadable: {path}") from exc
    return value.hexdigest()


def _required_text(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise WalkthroughError(f"missing {label}")
    return value.strip()


def _control(
    identifier: str,
    label: str,
    behavior: str,
    *,
    kind: str = "button",
    target: str | None = None,
    states: Sequence[str] = ("enabled",),
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "id": identifier,
        "label": label,
        "kind": kind,
        "behavior": behavior,
        "states": list(states),
    }
    if target:
        result["navigatesTo"] = target
    return result


def _screen(
    identifier: str,
    title: str,
    purpose: str,
    fixture: str,
    marker: str,
    logic: str,
    controls: Sequence[Mapping[str, Any]],
) -> dict[str, Any]:
    return {
        "id": identifier,
        "title": title,
        "purpose": purpose,
        "logic": [logic],
        "controls": list(controls),
        "variants": [
            {
                "id": "iphone-dark",
                "device": "Disposable iPhone Simulator",
                "appearance": "dark",
                "image": f"{fixture}.png",
            }
        ],
        "capture": {"fixture": fixture, "marker": marker},
    }


def default_manifest() -> dict[str, Any]:
    """Return the fixed iOS screenshot and review-surface inventory."""
    return {
        "formatVersion": 1,
        "app": "gradus",
        "platform": "iOS",
        "screens": [
            _screen(
                "icloud.discovery",
                "Checking iCloud",
                "Fresh-account discovery progress.",
                "fresh-account-discovery",
                "icloud-account-discovery-status",
                "The fixture performs no CloudKit access.",
                [
                    _control(
                        "explore-sample",
                        "Explore Sample",
                        "Opens local sample data.",
                        target="sample.dashboard",
                    )
                ],
            ),
            _screen(
                "icloud.confirmation",
                "iCloud confirmation",
                "Migration recovery before account discovery.",
                "legacy-awaiting-confirmation",
                "Continue",
                "Continue begins a fresh account check.",
                [_control("continue", "Continue", "Starts discovery.", target="icloud.discovery")],
            ),
            _screen(
                "icloud.retry",
                "Temporary iCloud failure",
                "Retryable discovery failure.",
                "temporary-retry",
                "Try Again",
                "Retry remains inside Gradus.",
                [_control("retry", "Try Again", "Retries discovery.", states=["recovery"])],
            ),
            _screen(
                "icloud.no-account",
                "No iCloud account",
                "Signed-out recovery state.",
                "no-account",
                "Try Again",
                "No system Settings handoff is offered.",
                [
                    _control("retry", "Try Again", "Retries discovery.", states=["recovery"]),
                    _control(
                        "explore-sample",
                        "Explore Sample",
                        "Opens local sample data.",
                        target="sample.dashboard",
                    ),
                ],
            ),
            _screen(
                "icloud.restricted",
                "Restricted iCloud",
                "Restricted-account recovery state.",
                "restricted",
                "Try Again",
                "No system Settings handoff is offered.",
                [_control("retry", "Try Again", "Retries discovery.", states=["recovery"])],
            ),
            _screen(
                "sample.dashboard",
                "Explore Sample dashboard",
                "Local-only dashboard and reset/exit outcomes.",
                "sample-dashboard",
                "sample-data-exit",
                "Sample data never writes CloudKit.",
                [
                    _control("reset", "Reset", "Restores bundled sample data."),
                    _control(
                        "exit", "Exit", "Returns to iCloud recovery.", target="icloud.no-account"
                    ),
                    _control("settings", "Settings", "Opens Settings.", target="settings.off"),
                ],
            ),
            _screen(
                "settings.off",
                "Settings, alerts off",
                "Settings with optional alerts disabled.",
                "settings-off",
                "warning-alerts-toggle",
                "iCloud syncing is unaffected.",
                [
                    _control(
                        "warning-alerts",
                        "Warning alerts",
                        "Requests permission when enabled.",
                        kind="switch",
                        states=["off"],
                    )
                ],
            ),
            _screen(
                "settings.requesting",
                "Settings, requesting alerts",
                "Disabled progress while permission is pending.",
                "settings-requesting",
                "Requesting warning-alert permission…",
                "The fixture prevents a real system prompt.",
                [
                    _control(
                        "warning-alerts",
                        "Warning alerts",
                        "Waits for permission.",
                        kind="switch",
                        states=["disabled", "requesting"],
                    )
                ],
            ),
            _screen(
                "settings.denied",
                "Settings, alerts denied",
                "Boundary before handing off to iOS Settings.",
                "settings-denied",
                "Open iOS Settings",
                "Capture stops before the system-owned app opens.",
                [
                    _control(
                        "open-ios-settings",
                        "Open iOS Settings",
                        "Hands control to iOS Settings.",
                        states=["recovery", "system-handoff"],
                    )
                ],
            ),
            _screen(
                "icloud.confirmation.result",
                "Continue result",
                "Account discovery after Continue.",
                "legacy-continue-result",
                "icloud-account-discovery-status",
                "The action enters deterministic discovery.",
                [],
            ),
            _screen(
                "icloud.retry.result",
                "Temporary retry result",
                "Recovery state after Try Again.",
                "temporary-retry-result",
                "Try Again",
                "The offline fixture remains retryable.",
                [],
            ),
            _screen(
                "icloud.no-account.result",
                "No-account retry result",
                "Signed-out state after Try Again.",
                "no-account-retry-result",
                "Try Again",
                "The action stays in-app and remains recoverable.",
                [],
            ),
            _screen(
                "icloud.restricted.result",
                "Restricted retry result",
                "Restricted state after Try Again.",
                "restricted-retry-result",
                "Try Again",
                "The action stays in-app and remains recoverable.",
                [],
            ),
            _screen(
                "sample.entry-progress",
                "Entering Sample",
                "Disabled Explore Sample progress state.",
                "sample-entry-progress",
                "explore-sample",
                "The action is disabled while the lifecycle gate suspends.",
                [],
            ),
            _screen(
                "sample.provider",
                "Sample provider detail",
                "Provider-card navigation outcome.",
                "sample-provider-detail",
                "Sample Codex",
                "Bundled sample data is fixed.",
                [
                    _control(
                        "back",
                        "Back",
                        "Returns to the sample dashboard.",
                        target="sample.provider-back",
                    )
                ],
            ),
            _screen(
                "sample.provider-back",
                "Provider Back result",
                "Dashboard after returning from provider detail.",
                "sample-provider-back",
                "sample-data-banner",
                "Back preserves sample mode.",
                [],
            ),
            _screen(
                "sample.reset-result",
                "Sample Reset result",
                "Dashboard after immediate sample reset.",
                "sample-reset-result",
                "sample-data-banner",
                "Reset is immediate; the shipped UI has no confirmation sheet.",
                [],
            ),
            _screen(
                "sample.exit-result",
                "Sample Exit result",
                "Required-iCloud recovery after immediate sample exit.",
                "sample-exit-result",
                "Try Again",
                "Exit is immediate; the shipped UI has no confirmation sheet.",
                [],
            ),
            _screen(
                "sample.settings",
                "Settings in Explore Sample",
                "Sample-only Settings controls.",
                "sample-settings",
                "sample-data-reset-settings",
                "Live alert controls are absent in sample mode.",
                [
                    _control(
                        "reset-sample", "Reset Sample Data", "Resets and remains in Settings."
                    ),
                    _control(
                        "exit-sample",
                        "Exit Explore Sample",
                        "Returns to required-iCloud recovery.",
                        target="sample.settings-exit",
                    ),
                ],
            ),
            _screen(
                "sample.settings-reset",
                "Settings sample Reset result",
                "Settings after resetting sample data.",
                "sample-settings-reset",
                "sample-data-reset-settings",
                "Reset remains in sample Settings.",
                [],
            ),
            _screen(
                "sample.settings-exit",
                "Settings sample Exit result",
                "Required-iCloud recovery after Settings exit.",
                "sample-settings-exit",
                "Try Again",
                "Exit leaves both Settings and sample mode.",
                [],
            ),
            _screen(
                "settings.close-result",
                "Settings Close result",
                "Dashboard after closing Settings.",
                "settings-close-result",
                "settings-button",
                "Close returns without changing state.",
                [],
            ),
            _screen(
                "settings.sort-result",
                "Sort control result",
                "Settings after selecting Name A-Z.",
                "settings-sort-result",
                "Name A-Z",
                "Sort is a local display preference.",
                [],
            ),
            _screen(
                "settings.exhausted-result",
                "Show exhausted result",
                "Settings after toggling exhausted providers.",
                "settings-show-exhausted-result",
                "show-exhausted-toggle",
                "The toggle is local-only.",
                [],
            ),
            _screen(
                "settings.threshold-result",
                "Warning threshold result",
                "Settings after moving the local threshold.",
                "settings-threshold-result",
                "warning-threshold-slider",
                "The threshold does not change pushed-alert selection.",
                [],
            ),
            _screen(
                "settings.permission-sheet",
                "Notification permission sheet",
                "System-owned notification authorization prompt.",
                "settings-warning-permission-sheet",
                "notification-permission-sheet",
                "The disposable Simulator provides a fresh permission state.",
                [
                    _control(
                        "deny",
                        "Don’t Allow",
                        "Returns denied authorization.",
                        target="settings.permission-denied",
                    ),
                    _control(
                        "allow",
                        "Allow",
                        "Returns allowed authorization.",
                        target="settings.permission-allowed",
                    ),
                ],
            ),
            _screen(
                "settings.permission-denied",
                "Permission denied result",
                "Settings after denying the system prompt.",
                "settings-warning-deny-result",
                "Open iOS Settings",
                "The recovery handoff becomes visible.",
                [],
            ),
            _screen(
                "settings.permission-allowed",
                "Permission allowed result",
                "Settings after allowing the system prompt.",
                "settings-warning-allow-result",
                "warning-alerts-toggle",
                "Warning alerts remain enabled.",
                [],
            ),
            _screen(
                "settings.denied-handoff",
                "iOS Settings handoff",
                "System-owned Gradus Settings page after Open iOS Settings.",
                "settings-denied-handoff",
                "ios-settings-app",
                "The screenshot proves the reachable system boundary.",
                [],
            ),
            _screen(
                "settings.sort-reset-result",
                "Reset-soonest sort result",
                "Settings after selecting Reset soonest.",
                "settings-sort-reset-result",
                "Reset soonest",
                "All sort outcomes are local display preferences.",
                [],
            ),
            _screen(
                "settings.automatic-result",
                "Manual card-size state",
                "Settings after turning Automatic off.",
                "settings-automatic-result",
                "Automatic",
                "The card-size slider becomes enabled where multiple columns fit.",
                [],
            ),
            _screen(
                "settings.card-size-disabled",
                "Automatic card-size state",
                "The fixed one-column iPhone state where manual card size is unavailable.",
                "settings-card-size-disabled",
                "Automatic · 1 column",
                "Dashboard card size is intentionally automatic when only one column fits.",
                [],
            ),
            _screen(
                "settings.card-size-result",
                "Dashboard card-size slider result",
                "Settings after selecting the largest card size.",
                "settings-card-size-result",
                "Dashboard card size",
                "Every position retains all provider windows.",
                [],
            ),
            _screen(
                "settings.hide-exhausted-result",
                "Hide exhausted result",
                "Settings after returning Show exhausted to off.",
                "settings-hide-exhausted-result",
                "show-exhausted-toggle",
                "Both toggle outcomes are captured.",
                [],
            ),
            _screen(
                "settings.alert-off-result",
                "Warning alerts off result",
                "Settings after turning an authorized alert toggle off.",
                "settings-alert-off-result",
                "warning-alerts-toggle",
                "Turning alerts off does not affect iCloud syncing.",
                [],
            ),
            _screen(
                "widget.current",
                "Small widget, current",
                "Current most-urgent usage window.",
                "widget-render-current",
                "widget-current",
                "The candidate view is rendered from fixed widget snapshot data.",
                [
                    _control(
                        "open-gradus",
                        "Open Gradus",
                        "Tapping the widget opens the containing app.",
                        target="icloud.discovery",
                    )
                ],
            ),
            _screen(
                "widget.empty",
                "Small widget, empty",
                "No published widget snapshot is available.",
                "widget-render-empty",
                "widget-empty",
                "The widget directs the user to open Gradus to sync.",
                [],
            ),
            _screen(
                "widget.unavailable",
                "Small widget, unavailable",
                "The selected provider window cannot be displayed.",
                "widget-render-unavailable",
                "widget-unavailable",
                "The widget directs the user to open Gradus to refresh.",
                [],
            ),
            _screen(
                "widget.gallery",
                "Widget gallery",
                "System-owned widget picker reached from Home Screen editing.",
                "widget-system-gallery",
                "Search Widgets",
                "The bounded XCUITest preserves a blocked log if SpringBoard accessibility changes.",
                [
                    _control(
                        "select-gradus",
                        "Gradus",
                        "Opens the Gradus widget add surface.",
                        target="widget.add-surface",
                    )
                ],
            ),
            _screen(
                "widget.add-surface",
                "Gradus widget add surface",
                "System-owned preview for the static small widget.",
                "widget-system-add",
                "Add Widget",
                "StaticConfiguration has no additional configurable fields.",
                [
                    _control(
                        "add-widget",
                        "Add Widget",
                        "Adds the small widget to the Home Screen.",
                        target="widget.tap-result",
                    )
                ],
            ),
            _screen(
                "widget.tap-result",
                "Widget tap result",
                "Gradus foregrounded by tapping its Home Screen widget.",
                "widget-system-tap",
                "explore-sample",
                "The containing app opens at its current required-iCloud recovery route.",
                [],
            ),
        ],
    }


def capture_routes(manifest: Mapping[str, Any] | None = None) -> list[dict[str, str]]:
    """Return validated fixture, marker, and image mappings for capture."""
    raw = (manifest or default_manifest()).get("screens")
    if not isinstance(raw, list) or not raw:
        raise WalkthroughError("walkthrough must declare at least one screen")
    routes = []
    for screen in raw:
        if not isinstance(screen, Mapping) or not isinstance(screen.get("capture"), Mapping):
            raise WalkthroughError("walkthrough capture mapping is incomplete")
        variants = screen.get("variants")
        if (
            not isinstance(variants, list)
            or len(variants) != 1
            or not isinstance(variants[0], Mapping)
        ):
            raise WalkthroughError("walkthrough capture variant is incomplete")
        capture = screen["capture"]
        routes.append(
            {
                "screenId": _required_text(screen.get("id"), "screen id"),
                "fixture": _required_text(capture.get("fixture"), "fixture"),
                "marker": _required_text(capture.get("marker"), "marker"),
                "image": _required_text(variants[0].get("image"), "image"),
            }
        )
    return routes


def central_manifest(manifest: Mapping[str, Any] | None = None) -> dict[str, Any]:
    """Return the manifest accepted by the central walkthrough API."""
    value = json.loads(json.dumps(manifest or default_manifest()))
    capture_routes(value)
    if manifest is None:
        validate_source_coverage()
    for screen in value["screens"]:
        screen.pop("capture", None)
    return value


def validate_source_coverage(source_root: str | Path | None = None) -> None:
    """Reject when a declared iOS route or control drifts out of shipped source."""
    root = Path(source_root or Path(__file__).resolve().parents[1])
    problems = []
    for relative, markers in _SOURCE_MARKERS.items():
        try:
            source = (root / relative).read_text(encoding="utf-8")
        except OSError:
            problems.append(f"cannot read source: {relative}")
            continue
        problems.extend(
            f"source marker is missing: {relative}: {marker}"
            for marker in markers
            if marker not in source
        )
    if problems:
        raise WalkthroughError(
            f"{len(problems)} source coverage problem(s):\n  " + "\n  ".join(problems)
        )


def _candidate(ledger: CandidateLedger) -> tuple[CandidateRecord, dict[str, Any]]:
    record = ledger.load()
    if record is None or record.state in {"failed", "abandoned", "superseded"}:
        raise WalkthroughError("candidate ledger is missing or not current")
    metadata = record.metadata or {}
    identity = {
        "candidateId": record.candidate_id,
        "sourceRevision": _required_text(metadata.get("sourceRevision"), "source revision"),
        "projectSha256": record.project_sha256,
        "artifactSha256": record.artifact_sha256,
        "build": record.build,
        "marketingVersion": record.marketing_version,
    }
    if not _SHA256.fullmatch(record.project_sha256) or not _SHA256.fullmatch(
        record.artifact_sha256
    ):
        raise WalkthroughError("candidate digest is invalid")
    if (
        not isinstance(record.build, int)
        or record.build < 1
        or not isinstance(record.marketing_version, str)
        or not _VERSION.fullmatch(record.marketing_version)
    ):
        raise WalkthroughError("candidate build identity is invalid")
    return record, identity


def generate_walkthrough(
    ledger: CandidateLedger,
    artifact_path: str | Path,
    *,
    screenshots_path: str | Path,
    output_path: str | Path,
    inventory_path: str | Path | None = None,
    source_revision: str | None = None,
    manifest: Mapping[str, Any] | None = None,
    on_status: Callable[[str], None] | None = None,
) -> dict[str, Any]:
    """Assemble, hash, and bind one screenshot walkthrough to its candidate."""
    record, identity = _candidate(ledger)
    if source_revision and source_revision != identity["sourceRevision"]:
        raise WalkthroughError("candidate source revision mismatch")
    if _digest(artifact_path) != identity["artifactSha256"]:
        raise WalkthroughError("artifact bytes do not match candidate tuple")
    assemble, write, central_error = _central_api()
    label = f"{identity['marketingVersion']} ({identity['build']}) | source {identity['sourceRevision']} | project {identity['projectSha256']} | artifact {identity['artifactSha256']}"
    try:
        result = assemble(
            central_manifest(manifest),
            screenshots_path,
            candidate_id=identity["candidateId"],
            label=label,
            on_status=on_status,
        )
        if result.screen_count < 1:
            raise WalkthroughError("walkthrough contains zero screens")
        output = Path(output_path)
        inventory = Path(inventory_path or output.with_name("walkthrough-inventory.json"))
        hashes = write(result, html_path=output, inventory_path=inventory)
    except central_error as exc:
        raise WalkthroughError(str(exc)) from exc
    binding = {
        "path": str(output),
        "sha256": hashes["htmlSha256"],
        "inventoryPath": str(inventory),
        "inventorySha256": result.inventory_sha256,
        "inventoryFileSha256": hashes["inventoryFileSha256"],
        "screenCount": result.screen_count,
        **{
            key: identity[key]
            for key in ("candidateId", "sourceRevision", "projectSha256", "artifactSha256")
        },
    }
    metadata = dict(record.metadata or {})
    existing = metadata.get("walkthrough")
    if isinstance(existing, Mapping) and existing != binding:
        raise WalkthroughError("candidate already contains different walkthrough evidence")
    metadata.update(
        {
            "walkthrough": binding,
            "walkthroughPath": str(output),
            "walkthroughSha256": binding["sha256"],
        }
    )
    ledger.write(
        CandidateRecord(
            record.candidate_id,
            record.state,
            record.source_sha256,
            record.project_sha256,
            record.artifact_sha256,
            record.build,
            record.marketing_version,
            metadata,
        )
    )
    return binding


def _validated_binding(ledger: CandidateLedger) -> Mapping[str, Any]:
    """Return current, nonempty walkthrough evidence after checking its files."""
    record, identity = _candidate(ledger)
    binding = (record.metadata or {}).get("walkthrough")
    if (
        not isinstance(binding, Mapping)
        or not isinstance(binding.get("screenCount"), int)
        or binding["screenCount"] < 1
    ):
        raise WalkthroughError("walkthrough evidence is missing or empty")
    for key in ("candidateId", "sourceRevision", "projectSha256", "artifactSha256"):
        if binding.get(key) != identity[key]:
            raise WalkthroughError("walkthrough candidate binding is stale")
    if _digest(_required_text(binding.get("path"), "walkthrough path")) != binding.get("sha256"):
        raise WalkthroughError("walkthrough HTML digest mismatch")
    inventory_path = _required_text(binding.get("inventoryPath"), "walkthrough inventory path")
    if _digest(inventory_path) != binding.get("inventoryFileSha256"):
        raise WalkthroughError("walkthrough inventory digest mismatch")
    try:
        inventory = json.loads(Path(inventory_path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise WalkthroughError("walkthrough inventory is unreadable") from exc
    if not isinstance(inventory, Mapping):
        raise WalkthroughError("walkthrough inventory binding mismatch")
    screens = inventory.get("screens")
    if (
        inventory.get("candidateId") != identity["candidateId"]
        or inventory.get("inventorySha256") != binding.get("inventorySha256")
        or not isinstance(screens, list)
        or len(screens) != binding["screenCount"]
    ):
        raise WalkthroughError("walkthrough inventory binding mismatch")
    return binding


def record_owner_review(
    ledger: CandidateLedger, output_path: str | Path, *, reviewed_by: str
) -> dict[str, Any]:
    """Record David's explicit acknowledgement of the exact sealed page."""
    if reviewed_by != _OWNER:
        raise WalkthroughError("walkthrough review must be explicitly acknowledged by David")
    binding = _validated_binding(ledger)
    proof = {
        "formatVersion": 1,
        "approved": True,
        "reviewedBy": _OWNER,
        "reviewedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        **{
            key: binding[key]
            for key in (
                "candidateId",
                "sourceRevision",
                "projectSha256",
                "artifactSha256",
                "sha256",
                "inventorySha256",
                "screenCount",
            )
        },
    }
    output = Path(output_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(proof, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    return proof


def validate_owner_review(ledger: CandidateLedger, review_path: str | Path) -> dict[str, Any]:
    """Reject unless a David acknowledgement matches the current candidate."""
    binding = _validated_binding(ledger)
    try:
        proof = json.loads(Path(review_path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise WalkthroughError("walkthrough owner acknowledgement is missing") from exc
    if not isinstance(proof, Mapping):
        raise WalkthroughError("walkthrough owner acknowledgement is invalid")
    expected = {
        "approved": True,
        "reviewedBy": _OWNER,
        **{
            key: binding.get(key)
            for key in (
                "candidateId",
                "sourceRevision",
                "projectSha256",
                "artifactSha256",
                "sha256",
                "inventorySha256",
                "screenCount",
            )
        },
    }
    if proof.get("screenCount", 0) < 1 or any(
        proof.get(key) != value for key, value in expected.items()
    ):
        raise WalkthroughError(
            "walkthrough owner acknowledgement does not match candidate evidence"
        )
    return dict(proof)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ledger", required=True, type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--record-owner-review", type=Path)
    mode.add_argument("--validate-owner-review", type=Path)
    parser.add_argument("--reviewed-by")
    parser.add_argument("--artifact", type=Path)
    parser.add_argument("--screenshots", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--inventory-output", type=Path)
    parser.add_argument("--source-revision")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        ledger = CandidateLedger(args.ledger)
        if args.record_owner_review:
            result = record_owner_review(
                ledger, args.record_owner_review, reviewed_by=args.reviewed_by or ""
            )
        elif args.validate_owner_review:
            result = validate_owner_review(ledger, args.validate_owner_review)
        elif args.artifact and args.screenshots and args.output:
            result = generate_walkthrough(
                ledger,
                args.artifact,
                screenshots_path=args.screenshots,
                output_path=args.output,
                inventory_path=args.inventory_output,
                source_revision=args.source_revision,
                on_status=lambda value: print(f"walkthrough: {value}", file=sys.stderr),
            )
        else:
            raise WalkthroughError("artifact, screenshots, and output are required")
    except (CandidateError, OSError, WalkthroughError) as exc:
        print(f"walkthrough: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
