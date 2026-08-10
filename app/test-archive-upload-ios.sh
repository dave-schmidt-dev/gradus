#!/usr/bin/env bash
# Regression tests for the GradusiOS App Store upload wrapper.
# These tests never contact App Store Connect or consume credentials.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPLOAD_SCRIPT="$SCRIPT_DIR/archive-upload-ios.sh"
GATE_SCRIPT="$SCRIPT_DIR/test-gate.sh"
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

PYTHONPATH="$SCRIPT_DIR" python3 - "$SCRIPT_DIR/next-ios-build-number.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("next_build", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
pages = [
    {"data": [{"id": "b1", "attributes": {"version": "9"}}], "links": {"next": "/builds?page=2"}},
    {"data": [{"id": "b2", "attributes": {"version": "101"}}]},
]
assert module.next_build_number(pages) == 102
for bad in (
    [{"data": [{"id": "b1", "attributes": {"version": "x"}}]}],
    [{"data": [{"id": "b1", "attributes": {"version": "2"}}]}, {"data": [{"id": "b2", "attributes": {"version": "2"}}]}],
    [{"data": [{"id": "b1", "attributes": {"version": "2"}}]}, {"data": [{"id": "b1", "attributes": {"version": "3"}}]}],
):
    try:
        module.next_build_number(bad)
    except module.BuildHistoryError:
        pass
    else:
        raise AssertionError("malformed/duplicate history was accepted")
calls = []
def fetch(path):
    calls.append(path)
    return pages[0] if len(calls) == 1 else pages[1]
module.fetch_all_build_pages(fetch, "app")
assert calls == ["/builds?filter[app]=app&limit=200", "/builds?page=2"]
PY

grep -Fq 'PRODUCT_BUNDLE_IDENTIFIER: com.zerodelta.gradus.ios' "$SCRIPT_DIR/project.yml" || {
  echo "FAIL: iOS bundle identifier is not pinned" >&2
  exit 1
}
grep -Fq 'validate_common_marketing_version "$SCRIPT_DIR/project.yml"' "$UPLOAD_SCRIPT" || {
  echo "FAIL: common marketing-version validation is missing" >&2
  exit 1
}
grep -Fq 'set_required_entitlement "$PACKAGE_DIR/entitlements.plist" aps-environment string production' "$UPLOAD_SCRIPT" || {
  echo "FAIL: production APS entitlement is not explicit" >&2
  exit 1
}
grep -Fq 'set_required_entitlement "$PACKAGE_DIR/entitlements.plist" get-task-allow bool false' "$UPLOAD_SCRIPT" || {
  echo "FAIL: false get-task-allow entitlement is not explicit" >&2
  exit 1
}
grep -Fq 'codesign --verify --deep --strict' "$UPLOAD_SCRIPT" || {
  echo "FAIL: strict codesign verification is missing" >&2
  exit 1
}

first_xattr_cleanup_line="$(awk '/xattr -cr "\$PACKAGE_DIR\/Payload\/GradusiOS\.app"/ {print NR; exit}' "$UPLOAD_SCRIPT")"
codesign_line="$(awk '/codesign --force --sign/ {print NR; exit}' "$UPLOAD_SCRIPT")"
[[ -n "$first_xattr_cleanup_line" && -n "$codesign_line" && "$first_xattr_cleanup_line" -lt "$codesign_line" ]] || {
  echo "FAIL: upload wrapper must clear bundle metadata before codesign" >&2
  exit 1
}

project_hash_before="$(sha256_file "$SCRIPT_DIR/project.yml")"
source_hash_before="$(snapshot_source_digest "$(cd "$SCRIPT_DIR/.." && pwd)")"
candidate_project="$(create_candidate_workspace "$(cd "$SCRIPT_DIR/.." && pwd)")/app/project.yml"
bump_ios_build_number 99 "$candidate_project"
[[ "$(sha256_file "$SCRIPT_DIR/project.yml")" == "$project_hash_before" ]] || {
  echo "FAIL: isolated candidate preparation changed checked-out project.yml" >&2
  exit 1
}
[[ -n "$source_hash_before" && "$(sha256_file "$SCRIPT_DIR/project.yml")" == "$project_hash_before" ]] || {
  echo "FAIL: source/project baseline was not stable after isolated preparation" >&2
  exit 1
}

grep -Eq 'failure_hook (after-allocation|archive|signing|packaging|receipt-persistence|assignment)' "$UPLOAD_SCRIPT" || {
  echo "FAIL: archive wrapper has no injected boundary-failure hooks" >&2
  exit 1
}
if grep -Eq 'PlistBuddy.*\|\| true' "$UPLOAD_SCRIPT"; then
  echo "FAIL: required PlistBuddy operation still swallows failure" >&2
  exit 1
fi
grep -Fq 'validate_producer_evidence_boundary' "$UPLOAD_SCRIPT" || {
  echo "FAIL: producer evidence is not checked at both irreversible boundaries" >&2
  exit 1
}
grep -Fq 'prepare_candidate_ledger' "$UPLOAD_SCRIPT" || {
  echo "FAIL: archive wrapper does not machine-create the candidate ledger" >&2
  exit 1
}
grep -Fq 'release_candidate.walkthrough' "$UPLOAD_SCRIPT" || {
  echo "FAIL: archive wrapper does not generate the candidate walkthrough" >&2
  exit 1
}
grep -Fq 'read_prepared_candidate' "$UPLOAD_SCRIPT" || {
  echo "FAIL: archive wrapper has no prepared-candidate retry path" >&2
  exit 1
}
grep -Fq 'Revalidating fresh producer evidence before resumed upload' "$UPLOAD_SCRIPT" || {
  echo "FAIL: resumed upload does not require fresh producer evidence" >&2
  exit 1
}
prepare_line="$(grep -n 'Persisting machine-written candidate ledger before walkthrough generation' "$UPLOAD_SCRIPT" | tail -1 | cut -d: -f1)"
walkthrough_line="$(grep -n -- '-m release_candidate.walkthrough' "$UPLOAD_SCRIPT" | tail -1 | cut -d: -f1)"
uploading_line="$(grep -n 'transition_candidate_state "\$candidate_ledger_path" uploading' "$UPLOAD_SCRIPT" | tail -1 | cut -d: -f1)"
[[ -n "$prepare_line" && -n "$walkthrough_line" && -n "$uploading_line" \
  && "$prepare_line" -lt "$walkthrough_line" && "$walkthrough_line" -lt "$uploading_line" ]] || {
  echo "FAIL: candidate ledger, walkthrough, and uploading transitions are out of order" >&2
  exit 1
}

# A post-prepare interruption must leave one resumable tuple; a retry may not
# allocate a new build or rebind the IPA digest.
retry_root="$TEST_ROOT/retry-candidate"
retry_ipa="$retry_root/GradusiOS.ipa"
retry_ledger="$retry_root/candidate.json"
mkdir -p "$retry_root"
printf 'candidate-ipa' >"$retry_ipa"
PYTHONPATH="$SCRIPT_DIR" python3 - "$retry_ledger" "$retry_ipa" <<'PY'
import hashlib
import sys
from pathlib import Path
from release_candidate.ledger import CandidateLedger

ledger_path, ipa_path = sys.argv[1:]
ipa_digest = hashlib.sha256(Path(ipa_path).read_bytes()).hexdigest()
ledger = CandidateLedger(ledger_path)
ledger.prepare(
    "candidate-retry",
    source_sha256="a" * 64,
    project_sha256="b" * 64,
    artifact_sha256=ipa_digest,
    build=42,
    marketing_version="1.2.3",
    metadata={
        "sourceRevision": "revision-retry",
        "producerBuild": 7,
        "producerEvidenceSha256": "c" * 64,
        "producerPublishedAt": "2026-08-09T23:00:00Z",
        "iosBuild": 42,
        "candidateWorkspace": str(Path(ipa_path).parent),
        "ipaPath": ipa_path,
    },
)
PY
retry_metadata_before="$(read_prepared_candidate "$retry_ledger")"
[[ "$retry_metadata_before" == *$'candidateId\tcandidate-retry'* ]] || {
  echo "FAIL: prepared candidate retry identity was not recovered" >&2
  exit 1
}
set +e
GRADUS_INJECT_FAILURE=receipt-persistence failure_hook receipt-persistence >/dev/null 2>&1
retry_failure_status=$?
set -e
[[ "$retry_failure_status" -ne 0 ]] || {
  echo "FAIL: receipt-persistence injection did not fail closed" >&2
  exit 1
}
[[ "$(read_prepared_candidate "$retry_ledger")" == "$retry_metadata_before" ]] || {
  echo "FAIL: retry path changed the prepared candidate tuple" >&2
  exit 1
}

# Keep the upload regression runner coupled to the canonical gate manifest:
# this script is the first hermetic leg, so it must fail loudly if candidate
# suites are added without counted invocations in test-gate.sh.
for candidate_suite in \
  test_release_candidate.py \
  test_release_candidate_validation.py \
  test_asc_api.py \
  test_release_reconcile.py \
  testflight-setup-tests.py \
  test_walkthrough.py; do
  grep -Fq "\"$candidate_suite\"" "$GATE_SCRIPT" || {
    echo "FAIL: canonical gate does not declare $candidate_suite" >&2
    exit 1
  }
done

echo "archive-upload-ios.sh HOME fallback and credential guard passed"
