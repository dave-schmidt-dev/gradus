"""Contract checks for the frozen runtime build script."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "app" / "build-gradus-runtime.sh").read_text()


def test_build_runs_venv_tools_through_the_interpreter() -> None:
    """Keep DYLD_* variables from being stripped by a shell launcher."""
    tools = set(re.findall(r'"\$VENV_ROOT/bin/([A-Za-z0-9_.-]+)"', SCRIPT))

    assert tools <= {"python"}, (
        f"Venv tools {tools - {'python'}} must run through the interpreter because "
        "SIP strips DYLD_* variables through /bin/sh."
    )


def test_pyinstaller_is_invoked_as_a_module() -> None:
    """Invoke PyInstaller without its uv-generated console-script launcher."""
    assert '"$VENV_ROOT/bin/python" -m PyInstaller' in SCRIPT
