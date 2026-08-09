#!/usr/bin/env bash
# Hermetic behavior tests for install-credential-bridge.sh. Never touches ~/Applications.
set -euo pipefail

umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/install-credential-bridge.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gradus-bridge-install-tests.XXXXXX")"
FAKE_BIN="$TEST_ROOT/bin"

cleanup() { rm -rf "$TEST_ROOT" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
mkdir -p "$FAKE_BIN"

cat >"$FAKE_BIN/codesign" <<'FAKE'
#!/usr/bin/env bash
set -eu
target="${!#}"
printf '%s\n' "$*" >>"${FAKE_RUNTIME:?}/codesign-calls"
printf 'codesign %s\n' "$target" >>"${FAKE_RUNTIME:?}/events"
call_count_file="$FAKE_RUNTIME/codesign-count"
call_count=0
if [[ -f "$call_count_file" ]]; then call_count="$(<"$call_count_file")"; fi
call_count=$((call_count + 1))
printf '%s\n' "$call_count" >"$call_count_file"
if [[ -n "${FAKE_CODESIGN_FAIL_SUBSTR:-}" && "$target" == *"$FAKE_CODESIGN_FAIL_SUBSTR"* ]]; then
  exit 1
fi
if [[ "${FAKE_CODESIGN_FAIL_ON_CALL:-0}" == "$call_count" ]]; then exit 1; fi
FAKE

cat >"$FAKE_BIN/xattr" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"${FAKE_RUNTIME:?}/xattr-calls"
printf 'xattr %s\n' "${!#}" >>"${FAKE_RUNTIME:?}/events"
FAKE

cat >"$FAKE_BIN/ditto" <<'FAKE'
#!/usr/bin/env bash
set -eu
cp -R "$1" "$2"
FAKE

cat >"$FAKE_BIN/xcodegen" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"${FAKE_RUNTIME:?}/xcodegen-calls"
FAKE

cat >"$FAKE_BIN/xcodebuild" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"${FAKE_RUNTIME:?}/xcodebuild-calls"
derived_data=""
while (($# > 0)); do
  if [[ "$1" == "-derivedDataPath" ]]; then derived_data="$2"; fi
  shift
done
mkdir -p "$derived_data/Build/Products/Release/GradusCredentialBridge.app/Contents/MacOS"
: >"$derived_data/Build/Products/Release/GradusCredentialBridge.app/Contents/MacOS/GradusCredentialBridge"
FAKE

chmod +x "$FAKE_BIN"/*

failures=0
fail() { printf 'FAIL: %s\n' "$1" >&2; failures=$((failures + 1)); }

setup_case() {
  CASE_ROOT="$TEST_ROOT/$1"
  INSTALL_DIR="$CASE_ROOT/Applications"
  BUILD_DIR="$CASE_ROOT/build"
  FAKE_RUNTIME="$CASE_ROOT/runtime"
  mkdir -p "$INSTALL_DIR" "$BUILD_DIR" "$FAKE_RUNTIME"
  export INSTALL_DIR BUILD_DIR FAKE_RUNTIME
  unset FAKE_CODESIGN_FAIL_SUBSTR FAKE_CODESIGN_FAIL_ON_CALL
}

make_bundle() {
  mkdir -p "$1/Contents/MacOS"
  : >"$1/Contents/MacOS/GradusCredentialBridge"
  if [[ -n "${2:-}" ]]; then printf '%s\n' "$2" >"$1/Contents/marker"; fi
}

run_install() {
  set +e
  PATH="$FAKE_BIN:$PATH" "$INSTALL_SCRIPT" "$@" >"$FAKE_RUNTIME/stdout" 2>"$FAKE_RUNTIME/stderr"
  local result=$?
  set -e
  return "$result"
}

marker() { cat "$1/Contents/marker" 2>/dev/null || true; }

echo "==> install-credential-bridge.sh"

setup_case dry-run
make_bundle "$BUILD_DIR/DerivedData/Build/Products/Release/GradusCredentialBridge.app"
make_bundle "$INSTALL_DIR/GradusCredentialBridge.app" old
run_install --skip-build --dry-run || fail "dry run failed"
[[ "$(marker "$INSTALL_DIR/GradusCredentialBridge.app")" == old ]] || fail "dry run changed installed app"
[[ ! -e "$INSTALL_DIR/.GradusCredentialBridge.app.incoming" ]] || fail "dry run staged an app"

setup_case happy
make_bundle "$BUILD_DIR/DerivedData/Build/Products/Release/GradusCredentialBridge.app"
make_bundle "$INSTALL_DIR/GradusCredentialBridge.app" old
run_install --skip-build || fail "install failed"
[[ -d "$INSTALL_DIR/GradusCredentialBridge.app" ]] || fail "installed app missing"
[[ -z "$(marker "$INSTALL_DIR/GradusCredentialBridge.app")" ]] || fail "old app was retained"
grep -q -- '--sign Developer ID Application: Zero Delta LLC' "$FAKE_RUNTIME/codesign-calls" || fail "Developer ID signing was not requested"
first_event="$(head -1 "$FAKE_RUNTIME/events")"
[[ "$first_event" == xattr* ]] || fail "source metadata was not stripped before signing"
[[ ! -e "$INSTALL_DIR/.GradusCredentialBridge.app.incoming" && ! -e "$INSTALL_DIR/.GradusCredentialBridge.app.previous" ]] || fail "staging artifacts remain"

setup_case staged-verify-fails
make_bundle "$BUILD_DIR/DerivedData/Build/Products/Release/GradusCredentialBridge.app"
make_bundle "$INSTALL_DIR/GradusCredentialBridge.app" keep
export FAKE_CODESIGN_FAIL_SUBSTR=".incoming"
if run_install --skip-build; then fail "staged verification failure succeeded"; fi
[[ "$(marker "$INSTALL_DIR/GradusCredentialBridge.app")" == keep ]] || fail "staged failure replaced installed app"

setup_case installed-verify-fails
make_bundle "$BUILD_DIR/DerivedData/Build/Products/Release/GradusCredentialBridge.app"
make_bundle "$INSTALL_DIR/GradusCredentialBridge.app" keep
export FAKE_CODESIGN_FAIL_ON_CALL=4
if run_install --skip-build; then fail "installed verification failure succeeded"; fi
[[ "$(marker "$INSTALL_DIR/GradusCredentialBridge.app")" == keep ]] || fail "installed verification failure did not restore prior app"

setup_case missing-source
if run_install --skip-build; then fail "missing source succeeded"; fi
grep -q 'no Release bridge app' "$FAKE_RUNTIME/stderr" || fail "missing source did not explain failure"

setup_case builds
run_install --dry-run || fail "build-backed dry run failed"
[[ -s "$FAKE_RUNTIME/xcodegen-calls" && -s "$FAKE_RUNTIME/xcodebuild-calls" ]] || fail "build path was not exercised"
grep -q 'CODE_SIGNING_ALLOWED=NO' "$FAKE_RUNTIME/xcodebuild-calls" || fail "build path did not disable Xcode signing"

if ((failures > 0)); then
  printf '%s bridge installer behavior test(s) failed\n' "$failures" >&2
  exit 1
fi
printf '%s\n' "bridge installer behavior tests passed"
