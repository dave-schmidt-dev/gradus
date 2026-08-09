"""Provider package — re-exports all symbols from the monolithic providers module."""

# Transition re-exports: test patches target gradus.providers.<module>.<name>.
# These keep `patch("gradus.providers.subprocess.Popen")` etc. working
# until Task 1.4 migrates them to the actual submodule paths.
import os  # noqa: F401
import subprocess  # noqa: F401
import urllib  # noqa: F401

from ._base import (
    _PROVIDER_REGISTRY,
    ProbeFailure,
    ProviderSnapshot,
    _auth_required_message,
    _AuthRejected,
    _canonical_providers,
    _debug_dump_path,
    _format_reset_time,
    _harden_existing,
    _http_json,
    _is_headless,
    _is_jwt_expired,
    _remove_private,
    _write_debug_dump,
    _write_private,
    fetch_provider_snapshot,
    log,
    register,
    set_headless,
)
from ._codex_helpers import _classify_codex_windows, _codex_percent_left
from ._seroval import (
    _is_solidstart_js,
    _seroval_chunks,
    _seroval_decode,
    _solidstart_js_to_json,
)
from .antigravity import AntigravityProvider
from .claude import ClaudeHttpProvider
from .codex import CodexHttpProvider
from .copilot import CopilotHttpProvider
from .cursor import CursorProvider
from .opencode_go import OpenCodeGoProvider
from .vibe import VibeProvider

__all__ = [
    "AntigravityProvider",
    "ClaudeHttpProvider",
    "CodexHttpProvider",
    "CopilotHttpProvider",
    "CursorProvider",
    "OpenCodeGoProvider",
    "VibeProvider",
    "ProbeFailure",
    "ProviderSnapshot",
    "_AuthRejected",
    "_PROVIDER_REGISTRY",
    "_auth_required_message",
    "_canonical_providers",
    "_classify_codex_windows",
    "_codex_percent_left",
    "_debug_dump_path",
    "_format_reset_time",
    "_harden_existing",
    "_http_json",
    "_is_headless",
    "_is_jwt_expired",
    "_is_solidstart_js",
    "_remove_private",
    "_seroval_chunks",
    "_seroval_decode",
    "_solidstart_js_to_json",
    "_write_debug_dump",
    "_write_private",
    "fetch_provider_snapshot",
    "log",
    "register",
    "set_headless",
]
