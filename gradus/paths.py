"""Explicit filesystem policy for source and installed Gradus runtimes."""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

RUNTIME_MODE_ENV = "GRADUS_RUNTIME_MODE"
SOURCE_MODE = "source"
INSTALLED_MODE = "installed"
PROJECT_ROOT = Path(__file__).resolve().parent.parent


@dataclass(frozen=True, slots=True)
class RuntimePaths:
    """All Gradus-owned runtime paths for one explicitly selected mode."""

    mode: str
    public_state_root: Path
    private_cache_root: Path
    log_root: Path
    legacy_snapshot_v2_mirror: Path | None = None

    @property
    def snapshot_path(self) -> Path:
        return self.public_state_root / "snapshot.json"

    @property
    def snapshot_v2_path(self) -> Path:
        return self.public_state_root / "snapshot-v2.json"

    @property
    def history_dir(self) -> Path:
        return self.public_state_root / "history"

    @property
    def log_path(self) -> Path:
        return self.log_root / "gradus.log"

    @property
    def agent_status_path(self) -> Path:
        return self.public_state_root / "agent-status.json"

    @property
    def refresh_lock_path(self) -> Path:
        return self.public_state_root / ".refresh-snapshot.lock"

    @property
    def tui_settings_path(self) -> Path:
        return self.public_state_root / "tui-settings.json"

    def private_cache_path(self, filename: str) -> Path:
        if Path(filename).name != filename or filename in {"", ".", ".."}:
            raise ValueError("private cache filename must be one path component")
        return self.private_cache_root / filename


def _absolute(path: Path) -> Path:
    return Path(os.path.abspath(os.path.expanduser(path)))


def _assert_nonaliasing(paths: RuntimePaths) -> RuntimePaths:
    owned = {
        _absolute(paths.public_state_root),
        _absolute(paths.private_cache_root),
        _absolute(paths.log_root),
    }
    if len(owned) != 3:
        raise ValueError("public state, private cache, and log roots must not alias")
    if paths.legacy_snapshot_v2_mirror is not None:
        mirror = _absolute(paths.legacy_snapshot_v2_mirror)
        if mirror in {
            _absolute(paths.snapshot_path),
            _absolute(paths.snapshot_v2_path),
        }:
            raise ValueError("legacy mirror must not alias a canonical snapshot")
    return paths


def source_runtime_paths(
    *,
    project_root: Path = PROJECT_ROOT,
    application_support_root: Path | None = None,
) -> RuntimePaths:
    """Return checkout-local source paths plus the rollback-only Mac mirror."""
    root = _absolute(project_root)
    app_support = _absolute(
        application_support_root or (Path.home() / "Library" / "Application Support" / "Gradus")
    )
    return _assert_nonaliasing(
        RuntimePaths(
            mode=SOURCE_MODE,
            public_state_root=root / ".state",
            private_cache_root=root / ".cache",
            log_root=root / ".logs",
            legacy_snapshot_v2_mirror=app_support / "snapshot-v2.json",
        )
    )


def installed_runtime_paths(
    *,
    application_support_root: Path | None = None,
    logs_root: Path | None = None,
) -> RuntimePaths:
    """Return checkout-independent paths for the signed installed runtime."""
    app_support = _absolute(
        application_support_root or (Path.home() / "Library" / "Application Support" / "Gradus")
    )
    logs = _absolute(logs_root or (Path.home() / "Library" / "Logs" / "Gradus"))
    return _assert_nonaliasing(
        RuntimePaths(
            mode=INSTALLED_MODE,
            public_state_root=app_support / "Installed",
            private_cache_root=app_support / "Private" / ".cache",
            log_root=logs,
        )
    )


def resolve_runtime_paths(
    environment: Mapping[str, str] | None = None,
    *,
    project_root: Path = PROJECT_ROOT,
    application_support_root: Path | None = None,
    logs_root: Path | None = None,
    require_installed: bool = False,
) -> RuntimePaths:
    """Resolve mode only from ``GRADUS_RUNTIME_MODE``, never from a path."""
    env = os.environ if environment is None else environment
    marker = env.get(RUNTIME_MODE_ENV)
    if marker is None or not marker.strip():
        if require_installed:
            raise ValueError("bundled agent requires GRADUS_RUNTIME_MODE=installed")
        marker = SOURCE_MODE
    marker = marker.strip().lower()
    if marker == SOURCE_MODE:
        if require_installed:
            raise ValueError("bundled agent requires GRADUS_RUNTIME_MODE=installed")
        return source_runtime_paths(
            project_root=project_root,
            application_support_root=application_support_root,
        )
    if marker == INSTALLED_MODE:
        return installed_runtime_paths(
            application_support_root=application_support_root,
            logs_root=logs_root,
        )
    raise ValueError(f"unknown {RUNTIME_MODE_ENV} value")


RUNTIME_PATHS = resolve_runtime_paths()
