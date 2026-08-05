#!/usr/bin/env bash
# Regression tests for the GradusiOS App Store upload wrapper.
# These tests never contact App Store Connect or consume credentials.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPLOAD_SCRIPT="$SCRIPT_DIR/archive-upload-ios.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gradus-upload-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
EXPECTED_HOME="$(
  /usr/bin/id -P | /usr/bin/awk -F: 'NF >= 9 {print $9; exit}'
)"

explicit_home="$(HOME=/tmp/gradus-test-home /bin/bash -c 'source "$1"; resolve_user_home' bash "$UPLOAD_SCRIPT")"
[[ "$explicit_home" == "/tmp/gradus-test-home" ]] || {
  echo "FAIL: explicit HOME was not preserved" >&2
  exit 1
}

discovered_home="$(env -u HOME /bin/bash -c 'source "$1"; resolve_user_home' bash "$UPLOAD_SCRIPT")"
[[ -n "$EXPECTED_HOME" && "$discovered_home" == "$EXPECTED_HOME" ]] || {
  echo "FAIL: HOME fallback resolved to '$discovered_home', expected '$EXPECTED_HOME'" >&2
  exit 1
}

resolved_uv="$(PATH=/usr/bin:/bin HOME="$EXPECTED_HOME" /bin/bash -c 'source "$1"; resolve_uv' bash "$UPLOAD_SCRIPT")"
[[ "$resolved_uv" == "$EXPECTED_HOME/.local/bin/uv" ]] || {
  echo "FAIL: uv fallback resolved to '$resolved_uv'" >&2
  exit 1
}

resolved_user="$(env -i PATH=/usr/bin:/bin HOME="$EXPECTED_HOME" /bin/bash -c 'source "$1"; resolve_user_name' bash "$UPLOAD_SCRIPT")"
[[ "$resolved_user" == "$(/usr/bin/id -un)" ]] || {
  echo "FAIL: user identity fallback resolved to '$resolved_user'" >&2
  exit 1
}

printf '%s\n' \
  'targets:' \
  '  GradusMac:' \
  '    settings:' \
  '      base:' \
  '        CURRENT_PROJECT_VERSION: "4"' \
  '  GradusiOS:' \
  '    settings:' \
  '      base:' \
  '        CURRENT_PROJECT_VERSION: "4"' \
  >"$TEST_ROOT/project.yml"
(
  cd "$TEST_ROOT"
  source "$UPLOAD_SCRIPT"
  bump_ios_build_number 9
)
[[ "$(sed -n '5p' "$TEST_ROOT/project.yml")" == '        CURRENT_PROJECT_VERSION: "4"' ]] || {
  echo "FAIL: iOS build bump changed the Mac target" >&2
  exit 1
}
[[ "$(sed -n '9p' "$TEST_ROOT/project.yml")" == '        CURRENT_PROJECT_VERSION: "9"' ]] || {
  echo "FAIL: iOS build bump did not update GradusiOS" >&2
  exit 1
}

set +e
missing_credentials_output="$(env -u HOME "$UPLOAD_SCRIPT" 2>&1)"
missing_credentials_status=$?
set -e
[[ "$missing_credentials_status" -ne 0 ]] || {
  echo "FAIL: upload wrapper unexpectedly ran without credentials" >&2
  exit 1
}
[[ "$missing_credentials_output" == *"APP_STORE_CONNECT_API_KEY"* ]] || {
  echo "FAIL: missing-credential guard did not run" >&2
  exit 1
}
[[ "$missing_credentials_output" != *"HOME is unset"* ]] || {
  echo "FAIL: upload wrapper still failed at HOME resolution" >&2
  exit 1
}

first_xattr_cleanup_line="$(awk '/xattr -cr "\$PACKAGE_DIR\/Payload\/GradusiOS\.app"/ {print NR; exit}' "$UPLOAD_SCRIPT")"
codesign_line="$(awk '/codesign --force --sign/ {print NR; exit}' "$UPLOAD_SCRIPT")"
[[ -n "$first_xattr_cleanup_line" && -n "$codesign_line" && "$first_xattr_cleanup_line" -lt "$codesign_line" ]] || {
  echo "FAIL: upload wrapper must clear bundle metadata before codesign" >&2
  exit 1
}

echo "archive-upload-ios.sh HOME fallback and credential guard passed"
