#!/usr/bin/env bash
# Hermetic behavior tests for install-mac-local.sh. Every Xcode and system
# executable it calls is faked; this file never builds, signs, or writes
# outside its own temp directory, and never touches /Applications.
#
# The case that matters is the staged-verify failure. The whole reason the
# script stages and swaps instead of copying straight over /Applications is
# that a bundle can pass strict verification on export and fail it once
# installed, because copying re-applies com.apple.provenance. If that ever
# gets "simplified" back into a direct copy, this is the test that notices.
#
# Note the shape of every negative assertion below: `if run_install ...; then
# fail ...; fi`, never `run_install ... && fail ...`. Under `set -e` the second
# form aborts the whole file the moment the command fails — which is the case
# these tests exist to exercise. That is the same footgun the install script
# was written to avoid, and it bit this file first.
set -euo pipefail

umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/install-mac-local.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gradus-install-tests.XXXXXX")"
FAKE_BIN="$TEST_ROOT/bin"

cleanup() {
  rm -rf "$TEST_ROOT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

mkdir -p "$FAKE_BIN"

# ---------------------------------------------------------------- fake tools

cat >"$FAKE_BIN/codesign" <<'FAKE'
#!/usr/bin/env bash
set -eu
target="${!#}"
printf '%s\n' "$target" >>"${FAKE_RUNTIME:?}/codesign-calls"
if [[ -n "${FAKE_CODESIGN_FAIL_SUBSTR:-}" && "$target" == *"$FAKE_CODESIGN_FAIL_SUBSTR"* ]]; then
  echo "fake codesign: rejected $target" >&2
  exit 1
fi
exit 0
FAKE

cat >"$FAKE_BIN/xattr" <<'FAKE'
#!/usr/bin/env bash
set -eu
target="${!#}"
printf '%s\n' "$target" >>"${FAKE_RUNTIME:?}/xattr-calls"
if [[ -n "${FAKE_XATTR_FAIL_SUBSTR:-}" && "$target" == *"$FAKE_XATTR_FAIL_SUBSTR"* ]]; then
  exit 1
fi
exit 0
FAKE

# `ditto src dst` copies the source *as* the destination, which is the
# behavior the staging step relies on.
cat >"$FAKE_BIN/ditto" <<'FAKE'
#!/usr/bin/env bash
set -eu
cp -R "$1" "$2"
FAKE

cat >"$FAKE_BIN/pkill" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_RUNTIME:?}/pkill-calls"
exit "${FAKE_PKILL_EXIT:-1}"
FAKE

# Reports "still running" while the flag file exists, so a test that wants the
# app to look permanently stuck simply never removes it.
cat >"$FAKE_BIN/pgrep" <<'FAKE'
#!/usr/bin/env bash
if [[ -n "${FAKE_APP_RUNNING_FLAG:-}" && -e "$FAKE_APP_RUNNING_FLAG" ]]; then
  echo 4242
  exit 0
fi
exit 1
FAKE

cat >"$FAKE_BIN/open" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_RUNTIME:?}/open-calls"
exit "${FAKE_OPEN_EXIT:-0}"
FAKE

cat >"$FAKE_BIN/xcodegen" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_RUNTIME:?}/xcodegen-calls"
exit 0
FAKE

# Records the subcommand and, on export, materializes the bundle the real
# exportArchive would have produced.
cat >"$FAKE_BIN/xcodebuild" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"${FAKE_RUNTIME:?}/xcodebuild-calls"
if [[ "$*" == *"-exportArchive"* ]]; then
  export_path=""
  while (($# > 0)); do
    if [[ "$1" == "-exportPath" ]]; then
      export_path="$2"
    fi
    shift
  done
  mkdir -p "$export_path/GradusMac.app/Contents/MacOS"
  : >"$export_path/GradusMac.app/Contents/Info.plist"
fi
exit 0
FAKE

cat >"$FAKE_BIN/plistbuddy" <<'FAKE'
#!/usr/bin/env bash
set -eu
plist="${!#}"
key="$2"
if [[ "$plist" == *"/export/"* ]]; then
  short="${FAKE_INCOMING_SHORT:-9.9.9}"
  build="${FAKE_INCOMING_BUILD:-99}"
else
  short="${FAKE_INSTALLED_SHORT:-1.0.0}"
  build="${FAKE_INSTALLED_BUILD:-1}"
fi
case "$key" in
  *CFBundleShortVersionString*) printf '%s\n' "$short" ;;
  *CFBundleVersion*) printf '%s\n' "$build" ;;
  *) exit 1 ;;
esac
FAKE

chmod +x "$FAKE_BIN"/*

# ------------------------------------------------------------------- harness

fail_count=0
case_count=0

fail() {
  printf '      %s\n' "$1" >&2
  fail_count=$((fail_count + 1))
}

expect_eq() {
  if [[ "$1" != "$2" ]]; then
    fail "$3 (expected '$2', got '$1')"
  fi
}

# Each case gets its own install dir, build dir and call log, so nothing
# observed in one can have been produced by another.
setup_case() {
  CASE_ROOT="$TEST_ROOT/case-$1"
  CASE_INSTALL_SCRIPT="$CASE_ROOT/install-mac-local.sh"
  INSTALL_DIR="$CASE_ROOT/Applications"
  BUILD_DIR="$CASE_ROOT/build"
  FAKE_RUNTIME="$CASE_ROOT/runtime"
  mkdir -p "$INSTALL_DIR" "$BUILD_DIR" "$FAKE_RUNTIME"
  cp "$INSTALL_SCRIPT" "$CASE_INSTALL_SCRIPT"
  cp "$SCRIPT_DIR/project.yml" "$CASE_ROOT/project.yml"
  chmod 700 "$CASE_INSTALL_SCRIPT"
  export INSTALL_DIR BUILD_DIR FAKE_RUNTIME
  export GRADUS_SOURCE_REVISION=fixture-revision
  export PLIST_BUDDY="$FAKE_BIN/plistbuddy"
  export QUIT_TIMEOUT_SECONDS=1
  unset FAKE_CODESIGN_FAIL_SUBSTR FAKE_XATTR_FAIL_SUBSTR FAKE_APP_RUNNING_FLAG
  unset FAKE_OPEN_EXIT FAKE_PKILL_EXIT
}

make_bundle() {
  local path="$1"
  local marker="${2:-}"
  mkdir -p "$path/Contents/MacOS"
  : >"$path/Contents/Info.plist"
  printf 'binary\n' >"$path/Contents/MacOS/GradusMac"
  if [[ -n "$marker" ]]; then
    printf '%s\n' "$marker" >"$path/Contents/marker"
  fi
}

run_install() {
  set +e
  PATH="$FAKE_BIN:$PATH" "$CASE_INSTALL_SCRIPT" "$@" >"$FAKE_RUNTIME/stdout" 2>"$FAKE_RUNTIME/stderr"
  local status=$?
  set -e
  return "$status"
}

marker_is() {
  local expected="$2"
  local actual
  actual="$(cat "$1/Contents/marker" 2>/dev/null || true)"
  [[ "$actual" == "$expected" ]]
}

no_staging_artifacts() {
  local count
  count="$(find "$INSTALL_DIR" -maxdepth 1 -name '.GradusMac.app.*' | wc -l | tr -d ' ')"
  expect_eq "$count" "0" "staging artifacts were left in the destination"
}

begin() {
  case_count=$((case_count + 1))
  CASE_LABEL="$1"
  CASE_FAILS_BEFORE=$fail_count
  printf '  %s\n' "$CASE_LABEL"
}

end() {
  if (($fail_count > $CASE_FAILS_BEFORE)); then
    printf '    NOT OK\n' >&2
  fi
}

# --------------------------------------------------------------------- cases

echo "==> install-mac-local.sh"

begin "--dry-run verifies without touching the destination"
setup_case dry-run
make_bundle "$BUILD_DIR/export/GradusMac.app"
make_bundle "$INSTALL_DIR/GradusMac.app" "untouched"
run_install --skip-build --dry-run || fail "dry run exited non-zero"
marker_is "$INSTALL_DIR/GradusMac.app" "untouched" || fail "dry run modified the installed app"
grep -q "export/GradusMac.app" "$FAKE_RUNTIME/codesign-calls" 2>/dev/null ||
  fail "dry run did not verify the exported bundle"
[[ ! -e "$FAKE_RUNTIME/open-calls" ]] || fail "dry run relaunched the app"
[[ ! -e "$FAKE_RUNTIME/pkill-calls" ]] || fail "dry run quit the running app"
no_staging_artifacts
end

begin "installs, strips both copies, relaunches, leaves no artifacts"
setup_case happy
make_bundle "$BUILD_DIR/export/GradusMac.app"
make_bundle "$INSTALL_DIR/GradusMac.app" "old"
run_install --skip-build || fail "install exited non-zero"
[[ -d "$INSTALL_DIR/GradusMac.app" ]] || fail "app is not installed"
marker_is "$INSTALL_DIR/GradusMac.app" "" || fail "old bundle was not replaced"
# The strip must happen twice: once on the export, once on the copy sitting in
# the destination. The second is the one the manual sequence kept forgetting.
grep -q "export/GradusMac.app" "$FAKE_RUNTIME/xattr-calls" || fail "exported bundle was not stripped"
grep -q "incoming" "$FAKE_RUNTIME/xattr-calls" || fail "staged copy was not stripped"
grep -q "incoming" "$FAKE_RUNTIME/codesign-calls" || fail "staged copy was not verified in place"
[[ -s "$FAKE_RUNTIME/open-calls" ]] || fail "app was not relaunched"
[[ -s "$FAKE_RUNTIME/pkill-calls" ]] || fail "running app was not asked to quit"
grep -q "9.9.9 (99)" "$FAKE_RUNTIME/stdout" || fail "did not report the version it installed"
no_staging_artifacts
end

begin "a staged-verify failure leaves the installed app untouched"
setup_case staged-verify-fails
make_bundle "$BUILD_DIR/export/GradusMac.app"
make_bundle "$INSTALL_DIR/GradusMac.app" "keep-me"
export FAKE_CODESIGN_FAIL_SUBSTR="incoming"
if run_install --skip-build; then
  fail "install succeeded despite the staged copy failing verification"
fi
[[ -d "$INSTALL_DIR/GradusMac.app" ]] || fail "the previously installed app was destroyed"
marker_is "$INSTALL_DIR/GradusMac.app" "keep-me" ||
  fail "the installed app was replaced by the unverified copy"
[[ ! -e "$FAKE_RUNTIME/open-calls" ]] || fail "relaunched an app that failed verification"
no_staging_artifacts
end

begin "an unverifiable export never reaches the destination"
setup_case export-verify-fails
make_bundle "$BUILD_DIR/export/GradusMac.app"
make_bundle "$INSTALL_DIR/GradusMac.app" "keep-me"
export FAKE_CODESIGN_FAIL_SUBSTR="export"
if run_install --skip-build; then
  fail "install succeeded despite the export failing verification"
fi
marker_is "$INSTALL_DIR/GradusMac.app" "keep-me" ||
  fail "the installed app was touched despite an unverifiable export"
[[ ! -e "$FAKE_RUNTIME/pkill-calls" ]] || fail "quit the running app before knowing the build was good"
no_staging_artifacts
end

begin "refuses to swap a bundle that is still running"
setup_case will-not-quit
make_bundle "$BUILD_DIR/export/GradusMac.app"
make_bundle "$INSTALL_DIR/GradusMac.app" "keep-me"
touch "$CASE_ROOT/still-running"
export FAKE_APP_RUNNING_FLAG="$CASE_ROOT/still-running"
if run_install --skip-build; then
  fail "install proceeded while the app was still running"
fi
marker_is "$INSTALL_DIR/GradusMac.app" "keep-me" || fail "swapped the bundle of a running app"
no_staging_artifacts
end

begin "rejects an unknown argument instead of doing the default thing"
setup_case unknown-arg
make_bundle "$INSTALL_DIR/GradusMac.app" "keep-me"
status=0
run_install --no-such-flag || status=$?
expect_eq "$status" "64" "unknown argument should exit 64"
marker_is "$INSTALL_DIR/GradusMac.app" "keep-me" || fail "acted on an unparsed command line"
end

begin "--skip-build with no exported app fails instead of installing nothing"
setup_case missing-export
status=0
run_install --skip-build || status=$?
expect_eq "$status" "66" "a missing export should exit 66"
[[ ! -e "$INSTALL_DIR/GradusMac.app" ]] || fail "installed something with no export present"
end

begin "a non-Git fixture without provenance fails closed"
setup_case missing-provenance
unset GRADUS_SOURCE_REVISION
status=0
run_install --skip-build || status=$?
expect_eq "$status" "1" "missing provenance should exit 1"
grep -q "source revision is unavailable" "$FAKE_RUNTIME/stderr" ||
  fail "missing provenance did not name the source revision requirement"
end

begin "the build path archives and exports before installing"
setup_case build-path
run_install || fail "full build path exited non-zero"
[[ -s "$FAKE_RUNTIME/xcodegen-calls" ]] || fail "project was not regenerated"
grep -q "archive" "$FAKE_RUNTIME/xcodebuild-calls" || fail "no archive step"
grep -q "exportArchive" "$FAKE_RUNTIME/xcodebuild-calls" || fail "no export step"
[[ -d "$INSTALL_DIR/GradusMac.app" ]] || fail "build path did not install"
no_staging_artifacts
end

# ------------------------------------------------------------------- summary

echo
if ((fail_count > 0)); then
  printf 'install-mac-local: %d check(s) failed across %d case(s)\n' "$fail_count" "$case_count" >&2
  exit 1
fi
printf 'install-mac-local: %d case(s) passed\n' "$case_count"
