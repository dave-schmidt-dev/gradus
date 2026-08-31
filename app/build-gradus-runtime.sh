#!/usr/bin/env bash
# Build the unsigned, universal2 PyInstaller runtime helper in a deterministic tree.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="$SCRIPT_DIR/build/gradus-runtime"
DOWNLOAD_ROOT="$BUILD_ROOT/downloads"
TOOLCHAIN_ROOT="$BUILD_ROOT/toolchain"
GENERATED_ROOT="$BUILD_ROOT/generated"
WORK_ROOT="$BUILD_ROOT/work"
DIST_ROOT="$BUILD_ROOT/dist"
APP_PATH="$DIST_ROOT/GradusRuntime.app"
MANIFEST_PATH="$BUILD_ROOT/GradusRuntime.manifest.json"
SPEC_PATH="$SCRIPT_DIR/packaging/gradus-runtime.spec"
RUNTIME_HOOK="$GENERATED_ROOT/pyi_scrub_external_env.py"
ENTRYPOINT="$GENERATED_ROOT/gradus_runtime_entrypoint.py"
PYTHON_VERSION="3.14.7"
PYTHON_SERIES="3.14"
PYTHON_PACKAGE="$DOWNLOAD_ROOT/python-${PYTHON_VERSION}-macos11.pkg"
PYTHON_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/python-${PYTHON_VERSION}-macos11.pkg"
PYTHON_SHA256="70c5239ad2d62925d2947e46921d0ddd3d35be3d2f0a2d50db33da507dbcb419"
PYTHON_FRAMEWORK_ROOT="$TOOLCHAIN_ROOT/Python.framework"
PYTHON_BIN="$PYTHON_FRAMEWORK_ROOT/Versions/$PYTHON_SERIES/bin/python3.14"
VENV_ROOT="$TOOLCHAIN_ROOT/venv"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1775347200}"
UV_CACHE_DIR="${UV_CACHE_DIR:-$BUILD_ROOT/uv-cache}"
PYINSTALLER_CONFIG_DIR="$BUILD_ROOT/pyinstaller-config"

status() {
  printf '%s\n' "==> $*" >&2
}

fail() {
  printf '%s\n' "FAIL: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "required build prerequisite '$1' is missing from PATH"
}

check_prerequisites() {
  [[ "$(uname -s)" == "Darwin" ]] || fail "GradusRuntime.app can only be built on macOS"
  [[ "$(uname -m)" == "arm64" ]] || fail "the universal2 build must run on an Apple Silicon Mac"
  local command
  for command in bash codesign curl ditto file lipo pkgutil plutil shasum uv; do
    require_command "$command"
  done
  [[ -f "$SPEC_PATH" ]] || fail "PyInstaller spec is missing: $SPEC_PATH"
  [[ -f "$REPO_ROOT/uv.lock" ]] || fail "uv.lock is missing"
  [[ -f "$REPO_ROOT/LICENSE" ]] || fail "project LICENSE is missing"
}

case "${1:-}" in
  "") ;;
  --check-prerequisites)
    check_prerequisites
    status "GradusRuntime build prerequisites present"
    exit 0
    ;;
  --help)
    printf '%s\n' "Usage: bash app/build-gradus-runtime.sh [--check-prerequisites]"
    exit 0
    ;;
  *)
    fail "unknown option '$1'"
    ;;
esac

check_prerequisites

case "$BUILD_ROOT" in
  "$REPO_ROOT/app/build/gradus-runtime") ;;
  *) fail "refusing to clean unexpected build root: $BUILD_ROOT" ;;
esac

mkdir -p "$DOWNLOAD_ROOT"

download_python() {
  local actual_hash partial
  if [[ -f "$PYTHON_PACKAGE" ]]; then
    actual_hash="$(shasum -a 256 "$PYTHON_PACKAGE" | awk '{print $1}')"
    if [[ "$actual_hash" == "$PYTHON_SHA256" ]]; then
      status "Using verified cached CPython $PYTHON_VERSION universal2 package"
      return 0
    fi
    fail "cached CPython package digest mismatch; remove only $PYTHON_PACKAGE and retry"
  fi

  partial="$PYTHON_PACKAGE.partial.$$"
  trap 'rm -f "$partial"' EXIT
  status "Downloading pinned CPython $PYTHON_VERSION universal2 package"
  curl --fail --location --progress-bar --output "$partial" "$PYTHON_URL"
  actual_hash="$(shasum -a 256 "$partial" | awk '{print $1}')"
  [[ "$actual_hash" == "$PYTHON_SHA256" ]] || fail "downloaded CPython package digest mismatch"
  mv "$partial" "$PYTHON_PACKAGE"
  trap - EXIT
}

prepare_toolchain() {
  local expanded framework_payload archs
  expanded="$TOOLCHAIN_ROOT/expanded"
  framework_payload="$expanded/Python_Framework.pkg/Payload/Versions/$PYTHON_SERIES"

  rm -rf "$TOOLCHAIN_ROOT" "$GENERATED_ROOT" "$WORK_ROOT" "$DIST_ROOT"
  rm -f "$MANIFEST_PATH"
  mkdir -p "$TOOLCHAIN_ROOT" "$GENERATED_ROOT" "$WORK_ROOT" "$DIST_ROOT"

  status "Expanding pinned CPython framework without installing host files"
  pkgutil --expand-full "$PYTHON_PACKAGE" "$expanded"
  [[ -x "$framework_payload/bin/python3.14" ]] || fail "CPython framework payload is incomplete"
  mkdir -p "$PYTHON_FRAMEWORK_ROOT/Versions"
  ditto "$framework_payload" "$PYTHON_FRAMEWORK_ROOT/Versions/$PYTHON_SERIES"
  ln -s "$PYTHON_SERIES" "$PYTHON_FRAMEWORK_ROOT/Versions/Current"
  ln -s "Versions/Current/Python" "$PYTHON_FRAMEWORK_ROOT/Python"
  ln -s "Versions/Current/Resources" "$PYTHON_FRAMEWORK_ROOT/Resources"
  archs="$(lipo -archs "$PYTHON_FRAMEWORK_ROOT/Versions/$PYTHON_SERIES/Python")"
  [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] ||
    fail "pinned CPython framework is not universal2: $archs"

  status "Creating isolated universal2 build environment"
  env DYLD_FRAMEWORK_PATH="$TOOLCHAIN_ROOT" UV_CACHE_DIR="$UV_CACHE_DIR" \
    uv venv --python "$PYTHON_BIN" "$VENV_ROOT"
  status "Syncing the exact locked build dependencies"
  env VIRTUAL_ENV="$VENV_ROOT" DYLD_FRAMEWORK_PATH="$TOOLCHAIN_ROOT" \
    UV_CACHE_DIR="$UV_CACHE_DIR" \
    uv sync --locked --active --all-groups --no-editable
  # PyInstaller already forwards DYLD_LIBRARY_PATH through macOS's `arch -e`
  # wrapper, but not DYLD_FRAMEWORK_PATH. The private python.org interpreter
  # needs the latter until PyInstaller collects and rewrites its framework.
  # Apply one exact, fail-closed build-tool patch inside the disposable venv.
  env DYLD_FRAMEWORK_PATH="$TOOLCHAIN_ROOT" "$VENV_ROOT/bin/python" \
    - "$VENV_ROOT/lib/python3.14/site-packages/PyInstaller/compat.py" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = """        if 'DYLD_LIBRARY_PATH' in os.environ:
            path = os.environ['DYLD_LIBRARY_PATH']
            py_prefix += ['-e', 'DYLD_LIBRARY_PATH=%s' % path]
"""
replacement = needle + """        if 'DYLD_FRAMEWORK_PATH' in os.environ:
            path = os.environ['DYLD_FRAMEWORK_PATH']
            py_prefix += ['-e', 'DYLD_FRAMEWORK_PATH=%s' % path]
"""
if text.count(needle) != 1:
    raise SystemExit("FAIL: pinned PyInstaller DYLD forwarding hook changed")
path.write_text(text.replace(needle, replacement), encoding="utf-8")
PY
  local pyinstaller_version
  pyinstaller_version="$(env DYLD_FRAMEWORK_PATH="$TOOLCHAIN_ROOT" \
    "$VENV_ROOT/bin/python" -c 'import PyInstaller; print(PyInstaller.__version__)')"
  [[ "$pyinstaller_version" == "6.22.2" ]] ||
    fail "locked PyInstaller version is '$pyinstaller_version', expected 6.22.2"
}

write_runtime_hook() {
  status "Generating provider subprocess environment scrubber"
  cat >"$RUNTIME_HOOK" <<'PY'
"""Remove frozen-runtime loader state from every external child process."""

from __future__ import annotations

import os
import subprocess


_ORIGINAL_POPEN = subprocess.Popen


def _scrubbed_environment(environment):
    child_environment = os.environ.copy() if environment is None else dict(environment)
    for name in tuple(child_environment):
        upper_name = name.upper()
        if (
            name == "_MEIPASS2"
            or name.startswith("_PYI_")
            or upper_name.startswith("PYINSTALLER_")
            or upper_name.startswith("PYTHON")
            or upper_name.startswith("DYLD_")
        ):
            child_environment.pop(name, None)
    return child_environment


class _GradusExternalPopen(_ORIGINAL_POPEN):
    def __init__(self, *args, **kwargs):
        kwargs["env"] = _scrubbed_environment(kwargs.get("env"))
        super().__init__(*args, **kwargs)


subprocess.Popen = _GradusExternalPopen
PY
  cat >"$ENTRYPOINT" <<'PY'
"""Frozen executable entry point; Gradus remains an imported package."""

from gradus.__main__ import main


raise SystemExit(main())
PY
}

build_application() {
  status "Building unsigned GradusRuntime.app (universal2)"
  env \
    DYLD_LIBRARY_PATH="$PYTHON_FRAMEWORK_ROOT/Versions/$PYTHON_SERIES/lib" \
    DYLD_FRAMEWORK_PATH="$TOOLCHAIN_ROOT" \
    GRADUS_PYINSTALLER_ENTRYPOINT="$ENTRYPOINT" \
    GRADUS_PYINSTALLER_PYTHON_LIB="$PYTHON_FRAMEWORK_ROOT/Versions/$PYTHON_SERIES/lib" \
    GRADUS_PYINSTALLER_RUNTIME_HOOK="$RUNTIME_HOOK" \
    PYINSTALLER_CONFIG_DIR="$PYINSTALLER_CONFIG_DIR" \
    PYTHONHASHSEED=0 \
    SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    "$VENV_ROOT/bin/pyinstaller" \
      --noconfirm \
      --clean \
      --distpath "$DIST_ROOT" \
      --workpath "$WORK_ROOT" \
      "$SPEC_PATH"
  [[ -x "$APP_PATH/Contents/MacOS/GradusRuntime" ]] || fail "GradusRuntime executable is missing"
}

audit_and_manifest() {
  status "Auditing layout, architectures, embedded paths, and secret-shaped data"
  env \
    DYLD_FRAMEWORK_PATH="$TOOLCHAIN_ROOT" \
    GRADUS_BUILD_APP="$APP_PATH" \
    GRADUS_BUILD_MANIFEST="$MANIFEST_PATH" \
    GRADUS_BUILD_REPO_ROOT="$REPO_ROOT" \
    GRADUS_BUILD_PROJECT_LICENSE="$REPO_ROOT/LICENSE" \
    GRADUS_BUILD_PYTHON_SHA256="$PYTHON_SHA256" \
    GRADUS_BUILD_PYTHON_URL="$PYTHON_URL" \
    GRADUS_BUILD_SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    "$VENV_ROOT/bin/python" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import subprocess
from importlib import metadata
from pathlib import Path


app = Path(os.environ["GRADUS_BUILD_APP"]).resolve()
manifest_path = Path(os.environ["GRADUS_BUILD_MANIFEST"]).resolve()
repository_root = Path(os.environ["GRADUS_BUILD_REPO_ROOT"]).resolve()
project_license = Path(os.environ["GRADUS_BUILD_PROJECT_LICENSE"]).resolve()


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: {message}")


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def artifact_digest(root: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    count = 0
    for path in sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix()):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            kind = "symlink"
            content_digest = hashlib.sha256(os.readlink(path).encode()).hexdigest()
            mode = 0
        elif path.is_file():
            kind = "file"
            content_digest = digest_file(path)
            mode = stat.S_IMODE(path.stat().st_mode)
        else:
            continue
        count += 1
        digest.update(f"{kind}\0{relative}\0{mode:o}\0{content_digest}\n".encode())
    return digest.hexdigest(), count


def is_macho(path: Path) -> bool:
    output = subprocess.run(
        ["/usr/bin/file", "-b", str(path)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return "Mach-O" in output


main_executable = app / "Contents" / "MacOS" / "GradusRuntime"
if not main_executable.is_file() or not os.access(main_executable, os.X_OK):
    fail("main executable is absent or not executable")

binaries = []
for path in sorted(app.rglob("*"), key=lambda item: item.relative_to(app).as_posix()):
    if path.is_symlink() or not path.is_file():
        continue
    relative = path.relative_to(app).as_posix()
    macho = is_macho(path)
    executable = bool(path.stat().st_mode & 0o111)
    in_code_directory = relative == "Contents/MacOS/GradusRuntime" or relative.startswith(
        "Contents/Frameworks/"
    )
    if macho:
        if not in_code_directory:
            fail(f"Mach-O has nonstandard bundle placement: {relative}")
        architectures = set(
            subprocess.run(
                ["/usr/bin/lipo", "-archs", str(path)],
                check=True,
                capture_output=True,
                text=True,
            ).stdout.split()
        )
        if not {"arm64", "x86_64"}.issubset(architectures):
            fail(f"Mach-O is missing a universal2 slice: {relative}")
        binaries.append(
            {
                "architectures": sorted(architectures),
                "path": relative,
                "sha256": digest_file(path),
            }
        )
    elif executable and not in_code_directory:
        fail(f"executable file has nonstandard bundle placement: {relative}")

if not binaries:
    fail("bundle contains no Mach-O binaries")

forbidden_literals = {
    str(repository_root).encode(): "absolute checkout path",
    b"/.venv/": "checkout virtual-environment path",
    b"/opt/homebrew/Cellar/python": "Homebrew Python Cellar path",
    b"/opt/homebrew/bin/python": "Homebrew Python executable path",
    b"/usr/local/Cellar/python": "Intel Homebrew Python Cellar path",
}
secret_patterns = {
    "private key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "AWS access key": re.compile(rb"AKIA[0-9A-Z]{16}"),
    "Google API key": re.compile(rb"AIza[0-9A-Za-z_-]{35}"),
    "GitHub token": re.compile(rb"gh[pousr]_[0-9A-Za-z]{30,}"),
    "OpenAI-style token": re.compile(rb"sk-[0-9A-Za-z_-]{20,}"),
    "bearer credential": re.compile(rb"Bearer[ \t]+[0-9A-Za-z._~-]{20,}"),
}
for path in sorted(app.rglob("*"), key=lambda item: item.relative_to(app).as_posix()):
    if path.is_symlink() or not path.is_file():
        continue
    data = path.read_bytes()
    relative = path.relative_to(app).as_posix()
    for literal, label in forbidden_literals.items():
        if literal in data:
            fail(f"{label} embedded in {relative}")
    for label, pattern in secret_patterns.items():
        if pattern.search(data):
            fail(f"secret-shaped {label} embedded in {relative}")

package_licenses = {
    "gradus": "MIT",
    "markdown-it-py": "MIT",
    "mdurl": "MIT",
    "Pygments": "BSD-2-Clause",
    "rich": "MIT",
}
packages = []
for package_name, license_id in package_licenses.items():
    distribution = metadata.distribution(package_name)
    packages.append(
        {
            "license": license_id,
            "name": distribution.metadata["Name"],
            "version": distribution.version,
        }
    )
packages.append({"license": "PSF-2.0", "name": "CPython", "version": "3.14.7"})
packages.sort(key=lambda item: item["name"].lower())

tree_digest, file_count = artifact_digest(app)
manifest = {
    "artifact": {
        "digest_algorithm": "sha256-tree-v1",
        "digest": tree_digest,
        "file_count": file_count,
        "path": "dist/GradusRuntime.app",
    },
    "binaries": binaries,
    "build": {
        "codesign_identity": None,
        "pyinstaller": metadata.version("PyInstaller"),
        "python_package_sha256": os.environ["GRADUS_BUILD_PYTHON_SHA256"],
        "python_package_url": os.environ["GRADUS_BUILD_PYTHON_URL"],
        "source_date_epoch": int(os.environ["GRADUS_BUILD_SOURCE_DATE_EPOCH"]),
        "target_architectures": ["arm64", "x86_64"],
    },
    "licenses": sorted(set(package_licenses.values()) | {"PSF-2.0"}),
    "packages": packages,
    "project_license_sha256": digest_file(project_license),
    "schema_version": 1,
}

credential_key = re.compile(r"(?:auth|credential|password|secret|token)", re.IGNORECASE)


def reject_credential_keys(value: object, trail: tuple[str, ...] = ()) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if credential_key.search(str(key)):
                fail("credential-shaped manifest field: " + ".".join((*trail, str(key))))
            reject_credential_keys(child, (*trail, str(key)))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_credential_keys(child, (*trail, str(index)))


reject_credential_keys(manifest)
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
  plutil -lint "$APP_PATH/Contents/Info.plist" >/dev/null
  status "Manifest written: $MANIFEST_PATH"
}

download_python
prepare_toolchain
write_runtime_hook
build_application
audit_and_manifest
status "GradusRuntime.app ready: $APP_PATH"
