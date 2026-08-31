"""PyInstaller recipe for the unsigned universal2 Gradus runtime helper."""

from __future__ import annotations

import os
from pathlib import Path


repository_root = Path(SPECPATH).resolve().parents[1]
runtime_hook = Path(os.environ["GRADUS_PYINSTALLER_RUNTIME_HOOK"]).resolve()
if not runtime_hook.is_file():
    raise SystemExit("generated PyInstaller runtime hook is missing")
entrypoint = Path(os.environ["GRADUS_PYINSTALLER_ENTRYPOINT"]).resolve()
if not entrypoint.is_file():
    raise SystemExit("generated PyInstaller entry point is missing")
python_library_root = Path(os.environ["GRADUS_PYINSTALLER_PYTHON_LIB"]).resolve()
python_libraries = [
    python_library_root / "libcrypto.3.dylib",
    python_library_root / "libssl.3.dylib",
    python_library_root / "libzstd.1.dylib",
]
if not all(path.is_file() for path in python_libraries):
    raise SystemExit("pinned CPython framework libraries are incomplete")

analysis = Analysis(
    [str(entrypoint)],
    pathex=[str(repository_root)],
    binaries=[(str(path), ".") for path in python_libraries],
    datas=[],
    hiddenimports=[],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[str(runtime_hook)],
    excludes=["hypothesis", "pytest", "ruff", "setuptools", "virtualenv"],
    noarchive=False,
    optimize=1,
)

python_archive = PYZ(analysis.pure)

executable = EXE(
    python_archive,
    analysis.scripts,
    [],
    exclude_binaries=True,
    name="GradusRuntime",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch="universal2",
    codesign_identity=None,
    entitlements_file=None,
)

collected = COLLECT(
    executable,
    analysis.binaries,
    analysis.datas,
    strip=False,
    upx=False,
    name="GradusRuntime",
)

application = BUNDLE(
    collected,
    name="GradusRuntime.app",
    icon=None,
    bundle_identifier="com.zerodelta.gradus.runtime",
    version="0.1.0",
    info_plist={
        "CFBundleDisplayName": "GradusRuntime",
        "CFBundleName": "GradusRuntime",
        "LSMinimumSystemVersion": "13.0",
        "LSUIElement": True,
    },
)
