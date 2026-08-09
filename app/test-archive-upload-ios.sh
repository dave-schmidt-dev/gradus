#!/usr/bin/env bash
# Regression tests for the GradusiOS App Store upload wrapper.
# These tests never contact App Store Connect or consume credentials.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPLOAD_SCRIPT="$SCRIPT_DIR/archive-upload-ios.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gradus-upload-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
source "$UPLOAD_SCRIPT"
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

EXPECTED_MAC_BUILD="$(read_mac_build_number "$SCRIPT_DIR/project.yml")"
EXPECTED_CLOUDKIT_ENVIRONMENT="$(read_cloudkit_environment "$SCRIPT_DIR/GradusMac/GradusMacProduction.entitlements")"
[[ "$EXPECTED_CLOUDKIT_ENVIRONMENT" == "Production" ]] || {
  echo "FAIL: release entitlements do not declare the production CloudKit environment" >&2
  exit 1
}
debug_cloudkit_environment="$(read_cloudkit_environment "$SCRIPT_DIR/GradusMac/GradusMac.entitlements" 2>/dev/null || true)"
if [[ -z "$debug_cloudkit_environment" ]]; then
  grep -Fq 'return "Development"' "$SCRIPT_DIR/GradusMac/GradusMacApp.swift" || {
    echo "FAIL: missing Debug environment is not resolved as Development" >&2
    exit 1
  }
elif [[ "$debug_cloudkit_environment" == "$EXPECTED_CLOUDKIT_ENVIRONMENT" ]]; then
  echo "FAIL: Debug and Release entitlements unexpectedly share the production environment" >&2
  exit 1
fi
grep -Fq 'CODE_SIGN_ENTITLEMENTS: GradusMac/GradusMac.entitlements' "$SCRIPT_DIR/project.yml" || {
  echo "FAIL: Debug signing configuration does not use GradusMac.entitlements" >&2
  exit 1
}
grep -Fq 'CODE_SIGN_ENTITLEMENTS: GradusMac/GradusMacProduction.entitlements' "$SCRIPT_DIR/project.yml" || {
  echo "FAIL: Release signing configuration does not use GradusMacProduction.entitlements" >&2
  exit 1
}
grep -Fq 'CODE_SIGN_STYLE: Manual' "$SCRIPT_DIR/project.yml" || {
  echo "FAIL: GradusMac Release archive signing is not manual" >&2
  exit 1
}
grep -Fq 'CODE_SIGN_IDENTITY: "Developer ID Application"' "$SCRIPT_DIR/project.yml" || {
  echo "FAIL: GradusMac Release archive does not pin Developer ID Application" >&2
  exit 1
}
grep -Fq 'PROVISIONING_PROFILE_SPECIFIER: "Gradus Mac Developer ID (API-created)"' "$SCRIPT_DIR/project.yml" || {
  echo "FAIL: GradusMac Release archive does not pin its Developer ID profile" >&2
  exit 1
}

write_evidence_fixture() {
  local path="$1"
  local build="$2"
  local environment="$3"
  local timestamp="$4"
  mkdir -p "$(dirname "$path")"
  printf '{"cloudKitEnvironment":"%s","producerBuildNumber":"%s","publishedAt":"%s"}\n' \
    "$environment" "$build" "$timestamp" >"$path"
}

now_timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
stale_timestamp="$(date -u -v "-$((PRODUCER_EVIDENCE_MAX_AGE_SECONDS + 1))S" '+%Y-%m-%dT%H:%M:%SZ')"

assert_evidence_refused() {
  local name="$1"
  local path="$2"
  if validate_producer_evidence "$path" "$EXPECTED_MAC_BUILD" "$EXPECTED_CLOUDKIT_ENVIRONMENT"; then
    echo "FAIL: producer evidence guard accepted $name evidence" >&2
    exit 1
  fi
}

assert_evidence_refused missing "$TEST_ROOT/missing/publish-evidence.json"

write_evidence_fixture "$TEST_ROOT/mismatched.json" "$EXPECTED_MAC_BUILD" Development "$now_timestamp"
assert_evidence_refused mismatched "$TEST_ROOT/mismatched.json"

write_evidence_fixture "$TEST_ROOT/wrong-build.json" 0 "$EXPECTED_CLOUDKIT_ENVIRONMENT" "$now_timestamp"
assert_evidence_refused wrong-build "$TEST_ROOT/wrong-build.json"

write_evidence_fixture "$TEST_ROOT/stale.json" "$EXPECTED_MAC_BUILD" "$EXPECTED_CLOUDKIT_ENVIRONMENT" "$stale_timestamp"
assert_evidence_refused stale "$TEST_ROOT/stale.json"

write_evidence_fixture "$TEST_ROOT/matching.json" "$EXPECTED_MAC_BUILD" "$EXPECTED_CLOUDKIT_ENVIRONMENT" "$now_timestamp"
validate_producer_evidence "$TEST_ROOT/matching.json" "$EXPECTED_MAC_BUILD" "$EXPECTED_CLOUDKIT_ENVIRONMENT" || {
  echo "FAIL: matching producer evidence was refused" >&2
  exit 1
}

guard_line="$(awk '/validate_producer_evidence "\$evidence_path"/ {print NR; exit}' "$UPLOAD_SCRIPT")"
next_build_line="$(awk '/NEXT_BUILD=.*next-ios-build-number.py/ {print NR; exit}' "$UPLOAD_SCRIPT")"
project_edit_line="$(awk '/bump_ios_build_number "\$NEXT_BUILD"/ {print NR; exit}' "$UPLOAD_SCRIPT")"
[[ -n "$guard_line" && "$guard_line" -lt "$next_build_line" && "$guard_line" -lt "$project_edit_line" ]] || {
  echo "FAIL: producer evidence guard is not before iOS build allocation and project edit" >&2
  exit 1
}

coordinator_source="$SCRIPT_DIR/GradusMac/PublishCoordinator.swift"
throw_line="$(awk '/throw PublishCoordinatorError\.recordFailures/ {print NR; exit}' "$coordinator_source")"
evidence_write_line="$(awk '/try Self\.writeProducerEvidence/ {print NR; exit}' "$coordinator_source")"
quiet_write_line="$(awk '
  /guard !toSave\.isEmpty/ {in_quiet=1; next}
  in_quiet && /try writeProducerEvidenceIfConfigured/ {print NR; exit}
  in_quiet && /return/ {exit}
' "$coordinator_source")"
success_write_line="$(awk '/try writeProducerEvidenceIfConfigured/ {line=NR} END {print line}' "$coordinator_source")"
success_notice_line="$(awk '/GradusLog\.publish\.notice\("published/ {print NR; exit}' "$coordinator_source")"
[[ -n "$throw_line" && -n "$evidence_write_line" && -n "$success_write_line" && -n "$success_notice_line" \
  && -n "$quiet_write_line" && "$quiet_write_line" -lt "$throw_line" \
  && "$throw_line" -lt "$success_write_line" && "$success_write_line" -lt "$success_notice_line" \
  && "$evidence_write_line" -gt "$success_notice_line" ]] || {
  echo "FAIL: producer evidence write is not after failure handling and before success" >&2
  exit 1
}

[[ "$(grep -c 'try writeProducerEvidenceIfConfigured' "$coordinator_source")" -eq 2 ]] || {
  echo "FAIL: producer evidence must refresh on both changed and quiet publish cycles" >&2
  exit 1
}

[[ "$(grep -c 'try Self.writeProducerEvidence' "$coordinator_source")" -eq 1 ]] || {
  echo "FAIL: producer success path must contain exactly one evidence write" >&2
  exit 1
}

[[ "$(grep -c 'publishedAt: Date()' "$coordinator_source")" -eq 1 ]] || {
  echo "FAIL: producer evidence must use a current write timestamp" >&2
  exit 1
}

set +e
missing_credentials_output="$(env -u HOME GRADUS_PRODUCER_EVIDENCE_PATH="$TEST_ROOT/matching.json" "$UPLOAD_SCRIPT" 2>&1)"
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
