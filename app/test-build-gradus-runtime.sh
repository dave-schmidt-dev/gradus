#!/usr/bin/env bash
# Hermetic build, relocation, and provider-child boundary checks for GradusRuntime.app.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_SCRIPT="$SCRIPT_DIR/build-gradus-runtime.sh"
BUILD_ROOT="$SCRIPT_DIR/build/gradus-runtime"
APP_PATH="$BUILD_ROOT/dist/GradusRuntime.app"
MANIFEST_PATH="$BUILD_ROOT/GradusRuntime.manifest.json"

fail() {
  printf '%s\n' "FAIL: $*" >&2
  exit 1
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gradus-runtime-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/empty-path"
ln -s /usr/bin/dirname "$TEST_ROOT/empty-path/dirname"
ln -s /usr/bin/uname "$TEST_ROOT/empty-path/uname"
if PATH="$TEST_ROOT/empty-path" /bin/bash "$BUILD_SCRIPT" --check-prerequisites \
    >"$TEST_ROOT/prerequisite.out" 2>&1; then
  fail "build prerequisite check accepted an empty PATH"
fi
grep -q "required build prerequisite" "$TEST_ROOT/prerequisite.out" ||
  fail "missing-prerequisite failure was not precise"

printf '%s\n' "==> Building the pinned universal2 relocation fixture"
UV_CACHE_DIR="${UV_CACHE_DIR:-$BUILD_ROOT/uv-cache}" bash "$BUILD_SCRIPT"

[[ -x "$APP_PATH/Contents/MacOS/GradusRuntime" ]] || fail "built runtime executable is missing"
[[ -f "$MANIFEST_PATH" ]] || fail "build manifest is missing"

printf '%s\n' "==> Verifying isolated Gradus distribution metadata"
(
  cd "$TEST_ROOT"
  env -i \
    DYLD_FRAMEWORK_PATH="$BUILD_ROOT/toolchain" \
    PATH="/usr/bin:/bin" \
    "$BUILD_ROOT/toolchain/venv/bin/python" - "$BUILD_ROOT/toolchain/venv" <<'PY'
from importlib import metadata
from pathlib import Path
import sys

venv_root = Path(sys.argv[1]).resolve()
distribution = metadata.distribution("gradus")
metadata_path = Path(distribution._path).resolve()
if not metadata_path.is_relative_to(venv_root) or metadata_path.suffix != ".dist-info":
    raise SystemExit(
        f"FAIL: Gradus distribution metadata is not installed non-editably: {metadata_path}"
    )
PY
)

relocated_root="$TEST_ROOT/Relocated Product"
relocated_app="$relocated_root/GradusRuntime.app"
mkdir -p "$relocated_root"
/usr/bin/ditto "$APP_PATH" "$relocated_app"
runtime="$relocated_app/Contents/MacOS/GradusRuntime"
[[ -x "$runtime" ]] || fail "relocated runtime executable is missing"

fixture_bin="$TEST_ROOT/fixture-bin"
fixture_home="$TEST_ROOT/home"
fixture_work="$TEST_ROOT/work"
trace_file="$TEST_ROOT/provider-children.log"
forbidden_file="$TEST_ROOT/forbidden-child-environment.log"
security_marker="$TEST_ROOT/security-gemini-first-call"
mkdir -p "$fixture_bin" "$fixture_home" "$fixture_work"
mkdir -p \
  "$fixture_home/Library/Application Support/Gradus/Installed" \
  "$fixture_home/Library/Application Support/Gradus/Private/.cache" \
  "$fixture_home/Library/Logs/Gradus"
chmod 700 \
  "$fixture_home/Library/Application Support/Gradus/Installed" \
  "$fixture_home/Library/Application Support/Gradus/Private/.cache" \
  "$fixture_home/Library/Logs/Gradus"

cat >"$fixture_bin/provider-fixture" <<'SH'
#!/bin/sh
command_name=${0##*/}
bad_names=$(/usr/bin/env | /usr/bin/awk -F= '
  $1 == "_MEIPASS2" ||
  $1 ~ /^_PYI_/ ||
  $1 ~ /^PYINSTALLER_/ ||
  $1 ~ /^PYTHON/ ||
  $1 ~ /^DYLD_/ { print $1 }
')
if [ -n "$bad_names" ]; then
  printf '%s\n' "$bad_names" >>"$GRADUS_TEST_FORBIDDEN_ENV"
  exit 91
fi
printf '%s\n' "$command_name" >>"$GRADUS_TEST_CHILD_TRACE"
case "$command_name" in
  agy)
    exit 0
    ;;
  gh)
    exit 1
    ;;
  security)
    case " $* " in
      *" -s gemini "*)
        if [ ! -e "$GRADUS_TEST_SECURITY_MARKER" ]; then
          : >"$GRADUS_TEST_SECURITY_MARKER"
          printf '%s\n' '{"token":{"access_token":"fixture-value","expiry":"2000-01-01T00:00:00+00:00"}}'
          exit 0
        fi
        ;;
    esac
    exit 1
    ;;
esac
exit 1
SH
chmod 755 "$fixture_bin/provider-fixture"
ln -s provider-fixture "$fixture_bin/agy"
ln -s provider-fixture "$fixture_bin/gh"
ln -s provider-fixture "$fixture_bin/security"

cat >"$fixture_work/.gradus.json" <<'JSON'
{"providers":["Antigravity","Claude","Copilot"]}
JSON

if PATH="$fixture_bin" command -v python >/dev/null 2>&1 ||
   PATH="$fixture_bin" command -v python3 >/dev/null 2>&1; then
  fail "host Python leaked onto the relocation fixture PATH"
fi

run_frozen() {
  local output_file="$1"
  shift
  (
    cd "$fixture_work"
    env -i \
      HOME="$fixture_home" \
      PATH="$fixture_bin" \
      GRADUS_RUNTIME_MODE=installed \
      GRADUS_TEST_CHILD_TRACE="$trace_file" \
      GRADUS_TEST_FORBIDDEN_ENV="$forbidden_file" \
      GRADUS_TEST_SECURITY_MARKER="$security_marker" \
      _MEIPASS2=/forbidden \
      _PYI_TEST_SENTINEL=/forbidden \
      PYINSTALLER_TEST_SENTINEL=/forbidden \
      PYTHONHOME=/forbidden \
      PYTHONPATH=/forbidden \
      DYLD_FRAMEWORK_PATH=/forbidden \
      DYLD_LIBRARY_PATH=/forbidden \
      "$runtime" "$@" >"$output_file"
  )
}

printf '%s\n' "==> Running fixture-backed --refresh-snapshot from the relocated app"
run_frozen "$TEST_ROOT/refresh.out" --refresh-snapshot
[[ ! -s "$forbidden_file" ]] ||
  fail "provider child inherited forbidden loader variables"
for expected_child in agy gh security; do
  grep -qx "$expected_child" "$trace_file" ||
    fail "provider subprocess fixture '$expected_child' did not run"
done

printf '%s\n' "==> Verifying the relocated runtime carries its own TLS trust store"
run_frozen "$TEST_ROOT/tls.out" --tls-trust-report
/usr/bin/python3 - "$TEST_ROOT/tls.out" "$relocated_app" <<'PY'
import json
import sys
from pathlib import Path

report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
relocated_app = Path(sys.argv[2]).resolve()
if report.get("frozen") is not True:
    raise SystemExit("FAIL: --tls-trust-report did not run from the frozen runtime")
if report.get("verify_mode") != "CERT_REQUIRED" or report.get("check_hostname") is not True:
    raise SystemExit("FAIL: frozen runtime TLS context is not a verifying client context")
bundled = Path(report.get("bundled_ca_file", "")).resolve()
if not bundled.is_file() or not bundled.is_relative_to(relocated_app):
    raise SystemExit(f"FAIL: bundled CA file is not inside the relocated app: {bundled}")
# The python.org OpenSSL has no usable OPENSSLDIR here; the regression this
# guards is a provider store that is empty without the bundle.
if report.get("ca_certificates", 0) < 100:
    raise SystemExit(
        "FAIL: frozen runtime trust store is empty or truncated: "
        f"{report.get('ca_certificates')} CA certificates"
    )
PY

printf '%s\n' "==> Running --json and --once with no host Python on PATH"
run_frozen "$TEST_ROOT/json.out" --json
run_frozen "$TEST_ROOT/once.out" --once
[[ -s "$TEST_ROOT/once.out" ]] || fail "--once produced no output"

/usr/bin/python3 - "$TEST_ROOT/json.out" "$MANIFEST_PATH" "$APP_PATH" <<'PY'
from __future__ import annotations

import hashlib
import json
import os
import stat
import sys
from pathlib import Path


json_output, manifest_path, app_path = map(Path, sys.argv[1:])
payload = json.loads(json_output.read_text(encoding="utf-8"))
if not isinstance(payload.get("providers"), list):
    raise SystemExit("FAIL: --json output does not contain providers")

manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
if manifest.get("schema_version") != 1:
    raise SystemExit("FAIL: unexpected build manifest schema")
if manifest.get("build", {}).get("pyinstaller") != "6.22.2":
    raise SystemExit("FAIL: build manifest does not pin PyInstaller 6.22.2")


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


digest = hashlib.sha256()
count = 0
for path in sorted(app_path.rglob("*"), key=lambda item: item.relative_to(app_path).as_posix()):
    relative = path.relative_to(app_path).as_posix()
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

artifact = manifest.get("artifact", {})
if artifact.get("digest") != digest.hexdigest() or artifact.get("file_count") != count:
    raise SystemExit("FAIL: build manifest artifact digest does not match the bundle")
if not manifest.get("binaries") or not manifest.get("packages") or not manifest.get("licenses"):
    raise SystemExit("FAIL: build manifest inventory is incomplete")
PY

printf '%s\n' "12 GradusRuntime build and relocation checks passed"
