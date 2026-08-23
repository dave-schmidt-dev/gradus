#!/usr/bin/env bash
# Regression tests for the GradusiOS App Store upload wrapper.
# These tests never contact App Store Connect or consume credentials.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPLOAD_SCRIPT="$SCRIPT_DIR/archive-upload-ios.sh"
GATE_SCRIPT="$SCRIPT_DIR/test-gate.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gradus-upload-tests.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
# shellcheck source=./archive-upload-ios.sh
source "$UPLOAD_SCRIPT"
EXPECTED_HOME="$(
  /usr/bin/id -P | /usr/bin/awk -F: 'NF >= 9 {print $9; exit}'
)"

unset GRADUS_INJECT_FAILURE
failure_hook allocation >/dev/null 2>&1 || {
  echo "FAIL: unset failure hook did not allow the normal path" >&2
  exit 1
}

default_evidence_path="$(HOME="$TEST_ROOT" env -u GRADUS_PRODUCER_EVIDENCE_PATH /bin/bash -c 'source "$1"; resolve_producer_evidence_path' bash "$UPLOAD_SCRIPT")"
[[ "$default_evidence_path" == "$TEST_ROOT/Library/Application Support/Gradus/publish-evidence.json" ]] || {
  echo "FAIL: default producer evidence path did not target Application Support" >&2
  exit 1
}
override_evidence_path="$TEST_ROOT/override/publish-evidence.json"
resolved_override_path="$(GRADUS_PRODUCER_EVIDENCE_PATH="$override_evidence_path" /bin/bash -c 'source "$1"; resolve_producer_evidence_path' bash "$UPLOAD_SCRIPT")"
[[ "$resolved_override_path" == "$override_evidence_path" ]] || {
  echo "FAIL: explicit producer evidence path override was not preserved" >&2
  exit 1
}

set +e
injected_hook_output="$(GRADUS_INJECT_FAILURE=allocation failure_hook allocation 2>&1)"
injected_hook_status=$?
nonmatching_hook_output="$(GRADUS_INJECT_FAILURE=allocation failure_hook archive 2>&1)"
nonmatching_hook_status=$?
set -e
[[ "$injected_hook_status" -eq 97 ]] || {
  echo "FAIL: matching failure-hook injection returned $injected_hook_status, expected 97" >&2
  exit 1
}
[[ "$injected_hook_output" == *"FAIL: injected failure after allocation"* ]] || {
  echo "FAIL: matching failure-hook injection message changed" >&2
  exit 1
}
[[ "$nonmatching_hook_status" -eq 0 && -z "$nonmatching_hook_output" ]] || {
  echo "FAIL: nonmatching failure-hook injection did not allow the normal path" >&2
  exit 1
}

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

non_git_source="$TEST_ROOT/non-git-source"
mkdir -p "$non_git_source"
injected_revision="$(GRADUS_SOURCE_REVISION=fixture-revision /bin/bash -c \
  'source "$1"; snapshot_source_revision "$2"' bash "$UPLOAD_SCRIPT" "$non_git_source")"
[[ "$injected_revision" == "fixture-revision" ]] || {
  echo "FAIL: injected source revision was not used for a non-Git checkout" >&2
  exit 1
}

clean_git_source="$TEST_ROOT/clean-git-source"
mkdir -p "$clean_git_source"
git -C "$clean_git_source" init -q
git -C "$clean_git_source" config user.name GradusTest
git -C "$clean_git_source" config user.email gradus-test@example.invalid
printf 'clean\n' >"$clean_git_source/source.txt"
git -C "$clean_git_source" add source.txt
git -C "$clean_git_source" commit -qm initial
clean_revision="$(snapshot_source_revision "$clean_git_source")"
[[ "$clean_revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo "FAIL: clean Git checkout did not resolve a revision" >&2
  exit 1
}
printf 'dirty\n' >>"$clean_git_source/source.txt"
set +e
dirty_revision_output="$(snapshot_source_revision "$clean_git_source" 2>&1)"
dirty_revision_status=$?
set -e
[[ "$dirty_revision_status" -ne 0 && "$dirty_revision_output" == *"source checkout is dirty"* ]] || {
  echo "FAIL: dirty Git checkout did not fail closed" >&2
  exit 1
}
set +e
dirty_injected_output="$(GRADUS_SOURCE_REVISION=fixture-revision snapshot_source_revision "$clean_git_source" 2>&1)"
dirty_injected_status=$?
set -e
[[ "$dirty_injected_status" -ne 0 && "$dirty_injected_output" == *"source checkout is dirty"* ]] || {
  echo "FAIL: injected source revision bypassed dirty Git state" >&2
  exit 1
}
report_git_source="$TEST_ROOT/report-git-source"
mkdir -p "$report_git_source/verifications"
git -C "$report_git_source" init -q
git -C "$report_git_source" config user.name GradusTest
git -C "$report_git_source" config user.email gradus-test@example.invalid
printf 'clean\n' >"$report_git_source/source.txt"
git -C "$report_git_source" add source.txt
git -C "$report_git_source" commit -qm initial
printf 'candidate verification\n' >"$report_git_source/verifications/2026-08-09-internal-testflight-candidate-migration-verification.md"
report_revision="$(snapshot_source_revision "$report_git_source")"
[[ "$report_revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo "FAIL: exact internal-TestFlight verification report was not accepted" >&2
  exit 1
}
resumed_revision="$(validate_resumed_source_revision "$report_git_source" "$report_revision" 2>&1 || true)"
[[ -z "$resumed_revision" ]] || {
  echo "FAIL: matching resumed source revision was rejected" >&2
  exit 1
}
set +e
resumed_drift_output="$(validate_resumed_source_revision "$report_git_source" "0000000000000000000000000000000000000000" 2>&1)"
resumed_drift_status=$?
set -e
[[ "$resumed_drift_status" -ne 0 && "$resumed_drift_output" == *"source revision changed"* ]] || {
  echo "FAIL: resumed source revision drift was accepted" >&2
  exit 1
}
printf 'unexpected\n' >"$report_git_source/unexpected.txt"
set +e
other_untracked_output="$(snapshot_source_revision "$report_git_source" 2>&1)"
other_untracked_status=$?
set -e
[[ "$other_untracked_status" -ne 0 && "$other_untracked_output" == *"source checkout is dirty"* ]] || {
  echo "FAIL: unrelated untracked source file did not fail closed" >&2
  exit 1
}

assert_upload_argument_rejected() {
  local label="$1" expected="$2"
  shift 2
  set +e
  local output
  output="$($UPLOAD_SCRIPT "$@" 2>&1)"
  local status=$?
  set -e
  [[ "$status" -ne 0 && "$output" == *"$expected"* ]] || {
    echo "FAIL: $label did not fail with '$expected'" >&2
    echo "$output" >&2
    exit 1
  }
}
assert_upload_argument_rejected "rollover without reason" "requires --supersession-reason" --rollover-assigned
assert_upload_argument_rejected "reason without rollover" "requires --rollover-assigned" --supersession-reason correction
assert_upload_argument_rejected "whitespace reason" "requires --supersession-reason" \
  --rollover-assigned --supersession-reason "   "
assert_upload_argument_rejected "unknown argument" "unknown argument" --unexpected-flag
assert_upload_argument_rejected "unsafe candidate" "contains unsupported characters" --candidate 'candidate;touch'

assert_upload_option_parsed() {
  local label="$1"
  shift
  set +e
  local output
  output="$(
    APP_STORE_CONNECT_API_KEY=fixture-key \
    APP_STORE_CONNECT_KEY_ID=fixture-key-id \
    APP_STORE_CONNECT_ISSUER_ID=fixture-issuer \
    GRADUS_PRODUCER_EVIDENCE_PATH="$TEST_ROOT/missing-evidence.json" \
      "$UPLOAD_SCRIPT" "$@" 2>&1
  )"
  local status=$?
  set -e
  [[ "$status" -ne 64 && "$output" != *"unknown argument"* ]] || {
    echo "FAIL: $label was rejected during option parsing" >&2
    echo "$output" >&2
    exit 1
  }
}
assert_upload_option_parsed "prepare-only" --prepare-only
assert_upload_option_parsed "prepare-only with assigned rollover" \
  --prepare-only --rollover-assigned --supersession-reason correction
assert_upload_option_parsed "upload-only" --upload-only

rollover_root="$TEST_ROOT/rollover"
rollover_ledger="$rollover_root/candidate.json"
rollover_workspace="$rollover_root/candidates/old"
mkdir -p "$rollover_workspace"
printf '{"candidateId":"old"}\n' >"$rollover_workspace/candidate-evidence.json"
printf '{"candidate_id":"old"}\n' >"$rollover_workspace/receipt.json"
PYTHONPATH="$SCRIPT_DIR" python3 - "$rollover_ledger" "$rollover_workspace" <<'PY'
import sys
from release_candidate.ledger import CandidateLedger, CandidateState

ledger = CandidateLedger(sys.argv[1])
ledger.prepare(
    "old", source_sha256="a" * 64, project_sha256="b" * 64, artifact_sha256="c" * 64,
    build=7, marketing_version="1.2.3", metadata={"candidateWorkspace": sys.argv[2]},
)
for state in (CandidateState.UPLOADING, CandidateState.UPLOADED_UNASSIGNED, CandidateState.ASSIGNED):
    ledger.transition(state)
PY
set +e
no_rollover_output="$(assert_candidate_not_in_flight "$rollover_ledger" 2>&1)"
no_rollover_status=$?
set -e
[[ "$no_rollover_status" -ne 0 && "$no_rollover_output" == *"already in state assigned"* ]] || {
  echo "FAIL: assigned candidate rolled over without explicit request" >&2
  exit 1
}
assert_candidate_not_in_flight "$rollover_ledger" 1
replacement_workspace="$rollover_root/candidates/new"
archive_output="$(prepare_candidate_ledger "$rollover_ledger" new dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
  eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
  ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff 8 1.2.3 revision 9 \
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2026-08-11T00:00:00Z "$replacement_workspace" "$replacement_workspace/GradusiOS.ipa" \
  "release-blocking correction" "$rollover_root/archived" 2>&1)"
[[ "$archive_output" == *"Archiving assigned candidate old workspace and receipt journal"* \
  && "$archive_output" == *"Assigned candidate archive complete"* ]] || {
  echo "FAIL: assigned-candidate archive did not emit operation progress" >&2
  echo "$archive_output" >&2
  exit 1
}
PYTHONPATH="$SCRIPT_DIR" python3 - "$rollover_ledger" "$rollover_root/archived/old/candidate.json" <<'PY'
import sys
from release_candidate.ledger import CandidateLedger, CandidateState

active = CandidateLedger(sys.argv[1]).load()
archived = CandidateLedger(sys.argv[2]).load()
assert active.candidate_id == "new" and active.state == CandidateState.PREPARED
assert archived.state == CandidateState.SUPERSEDED
assert archived.metadata["supersededReason"] == "release-blocking correction"
PY

set +e
non_git_revision_output="$(env -u GRADUS_SOURCE_REVISION /bin/bash -c \
  'source "$1"; snapshot_source_revision "$2"' bash "$UPLOAD_SCRIPT" "$non_git_source" 2>&1)"
non_git_revision_status=$?
set -e
[[ "$non_git_revision_status" -ne 0 && "$non_git_revision_output" == *"source revision is unavailable"* ]] || {
  echo "FAIL: non-Git checkout without injected source revision did not fail closed" >&2
  exit 1
}

uv_test_home="$TEST_ROOT/uv-test-home"
mkdir -p "$uv_test_home/.local/bin"
touch "$uv_test_home/.local/bin/uv"
chmod 755 "$uv_test_home/.local/bin/uv"
resolved_uv="$(PATH=/usr/bin:/bin HOME="$uv_test_home" /bin/bash -c 'source "$1"; resolve_uv' bash "$UPLOAD_SCRIPT")"
[[ "$resolved_uv" == "$uv_test_home/.local/bin/uv" ]] || {
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
  '  GradusWidget:' \
  '    settings:' \
  '      base:' \
  '        CURRENT_PROJECT_VERSION: "4"' \
  >"$TEST_ROOT/project.yml"
(
  cd "$TEST_ROOT"
  # shellcheck source=./archive-upload-ios.sh
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
[[ "$(sed -n '13p' "$TEST_ROOT/project.yml")" == '        CURRENT_PROJECT_VERSION: "9"' ]] || {
  echo "FAIL: iOS build bump did not update GradusWidget" >&2
  exit 1
}
(
  cd "$TEST_ROOT"
  # shellcheck source=./archive-upload-ios.sh
  source "$UPLOAD_SCRIPT"
  bump_target_build_number GradusMac 19 "$TEST_ROOT/project.yml"
)
[[ "$(sed -n '5p' "$TEST_ROOT/project.yml")" == '        CURRENT_PROJECT_VERSION: "19"' ]] || {
  echo "FAIL: target build bump did not update GradusMac" >&2
  exit 1
}

EXPECTED_MAC_BUILD="$(read_mac_build_number "$SCRIPT_DIR/project.yml")"
EXPECTED_CLOUDKIT_ENVIRONMENT="$(read_cloudkit_environment "$SCRIPT_DIR/GradusMac/GradusMacProduction.entitlements")"
EXPECTED_SOURCE_REVISION="fixture-revision"
EXPECTED_PROJECT_SHA256="$(sha256_file "$SCRIPT_DIR/project.yml")"
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
grep -Fq 'PROVISIONING_PROFILE_SPECIFIER: "Gradus iOS App Store (API-created)"' "$SCRIPT_DIR/project.yml" || {
  echo "FAIL: GradusiOS Release archive does not pin its App Store profile" >&2
  exit 1
}
grep -Fq 'PROVISIONING_PROFILE_SPECIFIER: "Gradus Widget App Store (API-created)"' "$SCRIPT_DIR/project.yml" || {
  echo "FAIL: GradusWidget Release archive does not pin its App Store profile" >&2
  exit 1
}

write_evidence_fixture() {
  local path="$1"
  local build="$2"
  local environment="$3"
  local timestamp="$4"
  local source_revision="${5:-}"
  local project_sha256="${6:-}"
  mkdir -p "$(dirname "$path")"
  printf '{"cloudKitEnvironment":"%s","producerBuildNumber":"%s","publishedAt":"%s","sourceRevision":"%s","projectSha256":"%s"}\n' \
    "$environment" "$build" "$timestamp" "$source_revision" "$project_sha256" >"$path"
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

assert_boundary_refused() {
  local name="$1"
  local path="$2"
  if validate_producer_evidence_boundary "$path" "$EXPECTED_MAC_BUILD" "$EXPECTED_CLOUDKIT_ENVIRONMENT" \
    "$EXPECTED_SOURCE_REVISION" "$EXPECTED_PROJECT_SHA256"; then
    echo "FAIL: producer evidence boundary accepted $name evidence" >&2
    exit 1
  fi
}

assert_evidence_refused missing "$TEST_ROOT/missing/publish-evidence.json"

write_evidence_fixture "$TEST_ROOT/mismatched.json" "$EXPECTED_MAC_BUILD" Development "$now_timestamp" \
  "$EXPECTED_SOURCE_REVISION" "$EXPECTED_PROJECT_SHA256"
assert_evidence_refused mismatched "$TEST_ROOT/mismatched.json"

write_evidence_fixture "$TEST_ROOT/wrong-build.json" 0 "$EXPECTED_CLOUDKIT_ENVIRONMENT" "$now_timestamp" \
  "$EXPECTED_SOURCE_REVISION" "$EXPECTED_PROJECT_SHA256"
assert_evidence_refused wrong-build "$TEST_ROOT/wrong-build.json"

write_evidence_fixture "$TEST_ROOT/stale.json" "$EXPECTED_MAC_BUILD" "$EXPECTED_CLOUDKIT_ENVIRONMENT" "$stale_timestamp" \
  "$EXPECTED_SOURCE_REVISION" "$EXPECTED_PROJECT_SHA256"
assert_evidence_refused stale "$TEST_ROOT/stale.json"

write_evidence_fixture "$TEST_ROOT/matching.json" "$EXPECTED_MAC_BUILD" "$EXPECTED_CLOUDKIT_ENVIRONMENT" "$now_timestamp" \
  "$EXPECTED_SOURCE_REVISION" "$EXPECTED_PROJECT_SHA256"
validate_producer_evidence "$TEST_ROOT/matching.json" "$EXPECTED_MAC_BUILD" "$EXPECTED_CLOUDKIT_ENVIRONMENT" || {
  echo "FAIL: matching producer evidence was refused" >&2
  exit 1
}
validate_producer_evidence_boundary "$TEST_ROOT/matching.json" "$EXPECTED_MAC_BUILD" "$EXPECTED_CLOUDKIT_ENVIRONMENT" \
  "$EXPECTED_SOURCE_REVISION" "$EXPECTED_PROJECT_SHA256" || {
  echo "FAIL: matching producer evidence boundary was refused" >&2
  exit 1
}

# The legacy wrapper consumes the central allocator's typed proof without any
# ASC credentials and persists the exact public identity for later retries.
allocation_root="$TEST_ROOT/identity-proof"
allocation_proof="$allocation_root/.release-state/evidence/allocate-identity.json"
allocation_record="$allocation_root/.release-state/allocated-ios.json"
mkdir -p "$(dirname "$allocation_proof")"
cat >"$allocation_proof" <<'JSON'
{"buildNumber":43,"marketingVersion":"1.6.7","observedAt":"2026-08-13T12:00:00Z","operationClass":"identityAllocation","productKey":"gradus-ios","proofVersion":"1.0.0","remoteHighestBuildNumber":42,"remoteHighestMarketingVersion":"1.6.7","responseSha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","result":"passed"}
JSON
unset APP_STORE_CONNECT_API_KEY APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID
allocation_metadata="$(consume_identity_allocation_proof "$allocation_proof" "$allocation_record" 1.6.7 '')"
[[ "$allocation_metadata" == *$'build\t43'* && "$allocation_metadata" == *$'candidateId\tgradus-ios-43'* ]] || {
  echo "FAIL: typed identity proof was not consumed into the durable allocation" >&2
  exit 1
}
allocation_digest_before="$(sha256_file "$allocation_record")"
allocation_metadata_retry="$(consume_identity_allocation_proof "$allocation_proof" "$allocation_record" 1.6.7 '')"
[[ "$allocation_metadata_retry" == "$allocation_metadata" && "$(sha256_file "$allocation_record")" == "$allocation_digest_before" ]] || {
  echo "FAIL: consuming the same identity proof allocated a second identity" >&2
  exit 1
}
printf '%s\n' '{"operationClass":"identityAllocation"}' >"$allocation_root/malformed.json"
set +e
malformed_allocation_output="$(consume_identity_allocation_proof "$allocation_root/malformed.json" "$allocation_root/malformed-record.json" 1.6.7 '' 2>&1)"
malformed_allocation_status=$?
set -e
[[ "$malformed_allocation_status" -ne 0 && "$malformed_allocation_output" == *"missing or malformed"* ]] || {
  echo "FAIL: malformed identity proof was accepted" >&2
  exit 1
}

# Exercise main's prepared-candidate resume path without invoking archive
# tooling or App Store Connect. The checkout is intentionally dirty while
# this hermetic test runs, so the fixture's source revision is checked by a
# narrow test seam instead of weakening the production validation function.
behavior_root="$TEST_ROOT/prepare-only-behavior"
behavior_workspace="$behavior_root/candidate"
behavior_ledger="$behavior_root/candidate.json"
behavior_ipa="$behavior_workspace/GradusiOS.ipa"
behavior_candidate_evidence="$behavior_workspace/candidate-evidence.json"
behavior_walkthrough="$behavior_workspace/walkthrough.md"
behavior_producer_evidence="$behavior_root/publish-evidence.json"
behavior_receipt="$behavior_workspace/ios-artifact.json"
behavior_candidate_id="fixture-prepared-candidate"
behavior_source_revision="fixture-resume-revision"
behavior_build=42
behavior_marketing_version="$(read_marketing_version "$SCRIPT_DIR/project.yml" GradusiOS)"
mkdir -p "$behavior_workspace"
printf 'hermetic prepared candidate ipa\n' >"$behavior_ipa"
printf '# Fixture candidate walkthrough\n' >"$behavior_walkthrough"
behavior_artifact_digest="$(sha256_file "$behavior_ipa")"
behavior_walkthrough_digest="$(sha256_file "$behavior_walkthrough")"
behavior_published_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
write_evidence_fixture "$behavior_producer_evidence" "$EXPECTED_MAC_BUILD" "$EXPECTED_CLOUDKIT_ENVIRONMENT" \
  "$behavior_published_at" "$behavior_source_revision" "$EXPECTED_PROJECT_SHA256"
behavior_producer_digest="$(sha256_file "$behavior_producer_evidence")"
behavior_source_digest="$(printf '%s' fixture-source | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
prepare_candidate_ledger "$behavior_ledger" "$behavior_candidate_id" "$behavior_source_digest" "$EXPECTED_PROJECT_SHA256" \
  "$behavior_artifact_digest" "$behavior_build" "$behavior_marketing_version" "$behavior_source_revision" \
  "$EXPECTED_MAC_BUILD" "$behavior_producer_digest" "$behavior_published_at" "$behavior_workspace" "$behavior_ipa"
persist_candidate_evidence "$behavior_ledger" "$behavior_candidate_evidence" "$behavior_candidate_id" \
  "$behavior_source_digest" "$EXPECTED_PROJECT_SHA256" "$behavior_artifact_digest" "$behavior_build" \
  "$behavior_marketing_version" "$behavior_source_revision" "$EXPECTED_MAC_BUILD" "$behavior_producer_digest" \
  "$behavior_walkthrough" "$behavior_walkthrough_digest" "$behavior_published_at" "$behavior_workspace" "$behavior_ipa"

behavior_bin="$behavior_root/bin"
behavior_transition_log="$behavior_root/transitions.log"
behavior_key_log="$behavior_root/mktemp.log"
behavior_xcrun_log="$behavior_root/xcrun.log"
behavior_transport_log="$behavior_root/transport.log"
mkdir -p "$behavior_bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\\n" "$*" >> "$GRADUS_TEST_KEY_LOG"' \
  'exec /usr/bin/mktemp "$@"' >"$behavior_bin/mktemp"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\\n" "$*" >> "$GRADUS_TEST_XCRUN_LOG"' \
  'exit 0' >"$behavior_bin/xcrun"
# The upload transport is a Python module run through uv, so uv is now the
# stub point that xcrun used to be. resolve_uv prefers `command -v uv`, which
# is why placing it on PATH is enough. The stub serves both calls the upload
# path makes: the credential preflight (`python -c ...`) and the transport
# itself, which reports the delivery id on stdout for the receipt writer.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\\n" "$*" >> "$GRADUS_TEST_TRANSPORT_LOG"' \
  'case "$*" in' \
  '  *asc_build_upload.py*)' \
  '    printf "Delivery UUID: %s\\n" "fixture-delivery-id"' \
  '    exit 0 ;;' \
  'esac' \
  'exit 0' >"$behavior_bin/uv"
chmod 700 "$behavior_bin/mktemp" "$behavior_bin/xcrun" "$behavior_bin/uv"

# The seam records production's transition requests while preventing even a
# mocked transition from mutating the fixture before the assertions run.
validate_resumed_source_revision() {
  [[ "$1" == "$(cd "$SCRIPT_DIR/.." && pwd)" && "$2" == "$behavior_source_revision" ]] || {
    echo "FAIL: prepared-candidate source fixture was not selected" >&2
    return 1
  }
}
transition_candidate_state() {
  printf '%s\n' "$2" >>"$behavior_transition_log"
}

export GRADUS_PRODUCER_EVIDENCE_PATH="$behavior_producer_evidence"
export GRADUS_CANDIDATE_LEDGER_PATH="$behavior_ledger"
export GRADUS_CANDIDATE_RECEIPT_PATH="$behavior_receipt"
export GRADUS_TEST_KEY_LOG="$behavior_key_log"
export GRADUS_TEST_XCRUN_LOG="$behavior_xcrun_log"
export GRADUS_TEST_TRANSPORT_LOG="$behavior_transport_log"
behavior_path="$PATH"
export PATH="$behavior_bin:$behavior_path"

set +e
prepare_only_output="$(main --prepare-only 2>&1)"
prepare_only_status=$?
set -e
[[ "$prepare_only_status" -eq 0 && "$prepare_only_output" == *"upload deferred"* ]] || {
  echo "FAIL: --prepare-only did not return successfully from a prepared candidate" >&2
  echo "$prepare_only_output" >&2
  exit 1
}
[[ ! -s "$behavior_transition_log" && ! -s "$behavior_key_log" \
  && ! -s "$behavior_xcrun_log" && ! -s "$behavior_transport_log" ]] || {
  echo "FAIL: --prepare-only reached the upload transition, mktemp, xcrun, or the transport" >&2
  exit 1
}
PYTHONPATH="$SCRIPT_DIR" /usr/bin/python3 - "$behavior_ledger" <<'PY'
import sys
from release_candidate.ledger import CandidateLedger, CandidateState

record = CandidateLedger(sys.argv[1]).load()
assert record is not None and record.state == CandidateState.PREPARED
PY

# A failed transport must leave an explicit reconciliation-required record
# before returning the transport status: the transfer may have reached Apple
# before failing, so the ambiguity has to survive as evidence rather than
# invite a retry. Build a second prepared fixture so the successful resume
# below stays independent of this failure path.
failure_root="$TEST_ROOT/upload-failure-behavior"
failure_workspace="$failure_root/candidate"
failure_ledger="$failure_root/candidate.json"
failure_ipa="$failure_workspace/GradusiOS.ipa"
failure_candidate_evidence="$failure_workspace/candidate-evidence.json"
failure_walkthrough="$failure_workspace/walkthrough.md"
failure_receipt="$failure_workspace/ios-artifact.json"
failure_candidate_id="fixture-upload-failure"
mkdir -p "$failure_workspace"
printf 'hermetic failed-upload candidate ipa\n' >"$failure_ipa"
failure_artifact_digest="$(sha256_file "$failure_ipa")"
printf '# Fixture failed-upload walkthrough\n' >"$failure_walkthrough"
failure_walkthrough_digest="$(sha256_file "$failure_walkthrough")"
prepare_candidate_ledger "$failure_ledger" "$failure_candidate_id" "$behavior_source_digest" "$EXPECTED_PROJECT_SHA256" \
  "$failure_artifact_digest" "$behavior_build" "$behavior_marketing_version" "$behavior_source_revision" \
  "$EXPECTED_MAC_BUILD" "$behavior_producer_digest" "$behavior_published_at" "$failure_workspace" "$failure_ipa"
persist_candidate_evidence "$failure_ledger" "$failure_candidate_evidence" "$failure_candidate_id" \
  "$behavior_source_digest" "$EXPECTED_PROJECT_SHA256" "$failure_artifact_digest" "$behavior_build" \
  "$behavior_marketing_version" "$behavior_source_revision" "$EXPECTED_MAC_BUILD" "$behavior_producer_digest" \
  "$failure_walkthrough" "$failure_walkthrough_digest" "$behavior_published_at" "$failure_workspace" "$failure_ipa"
failure_bin="$failure_root/bin"
failure_key_log="$failure_root/mktemp.log"
failure_xcrun_log="$failure_root/xcrun.log"
failure_transport_log="$failure_root/transport.log"
mkdir -p "$failure_bin"
cp "$behavior_bin/mktemp" "$failure_bin/mktemp"
cp "$behavior_bin/xcrun" "$failure_bin/xcrun"
# Only the transport fails. The credential preflight ahead of it must still
# succeed, or this would exercise the preflight's refusal path instead of the
# ambiguous-transport path it is here to cover. The stub echoes the injected
# credentials so the redaction assertions below have something to detect.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\\n" "$*" >> "$GRADUS_TEST_TRANSPORT_LOG"' \
  'case "$*" in' \
  '  *asc_build_upload.py*)' \
  '    printf "transport failed: %s %s %s\\n" "$APP_STORE_CONNECT_API_KEY" "$APP_STORE_CONNECT_KEY_ID" "$APP_STORE_CONNECT_ISSUER_ID" >&2' \
  '    exit 42 ;;' \
  'esac' \
  'exit 0' >"$failure_bin/uv"
chmod 700 "$failure_bin/mktemp" "$failure_bin/xcrun" "$failure_bin/uv"
export GRADUS_CANDIDATE_LEDGER_PATH="$failure_ledger"
export GRADUS_CANDIDATE_RECEIPT_PATH="$failure_receipt"
export GRADUS_TEST_KEY_LOG="$failure_key_log"
export GRADUS_TEST_XCRUN_LOG="$failure_xcrun_log"
export GRADUS_TEST_TRANSPORT_LOG="$failure_transport_log"
export PATH="$failure_bin:$behavior_path"
export APP_STORE_CONNECT_API_KEY=fixture-api-key
export APP_STORE_CONNECT_KEY_ID=fixture-key-id
export APP_STORE_CONNECT_ISSUER_ID=fixture-issuer
unset GRADUS_UPLOAD_FAILURE_STATUS
set +e
failed_upload_output="$(main --upload-only 2>&1)"
failed_upload_status=$?
set -e
[[ "$failed_upload_status" -eq 42 && "$failed_upload_output" == *"Uploading to App Store Connect"* ]] || {
  echo "FAIL: failed upload did not return the transport status" >&2
  echo "$failed_upload_output" >&2
  exit 1
}
[[ -f "$failure_workspace/upload-reconciliation.json" ]] || {
  echo "FAIL: failed upload did not persist reconciliation evidence" >&2
  exit 1
}
failure_diagnostic="$failure_workspace/upload-failure.log"
[[ -f "$failure_diagnostic" && "$(/usr/bin/stat -f '%Lp' "$failure_diagnostic")" == "600" ]] || {
  echo "FAIL: failed upload did not preserve a private diagnostic transcript" >&2
  exit 1
}
grep -Fq 'transport failed:' "$failure_diagnostic" || {
  echo "FAIL: upload diagnostic transcript lost the transport output" >&2
  exit 1
}
grep -Fq '<redacted:APP_STORE_CONNECT_API_KEY>' "$failure_diagnostic" || {
  echo "FAIL: upload diagnostic transcript did not mark credential redaction" >&2
  exit 1
}
if grep -Fq fixture-api-key "$failure_diagnostic" \
    || grep -Fq fixture-key-id "$failure_diagnostic" \
    || grep -Fq fixture-issuer "$failure_diagnostic"; then
  echo "FAIL: upload diagnostic transcript retained credential material" >&2
  exit 1
fi
/usr/bin/python3 - "$failure_workspace/upload-reconciliation.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["result"] == "reconciliation-required"
assert payload["reason"] == "upload-result-ambiguous"
assert payload["transportExitCode"] == 42
PY

export GRADUS_CANDIDATE_LEDGER_PATH="$behavior_ledger"
export GRADUS_CANDIDATE_RECEIPT_PATH="$behavior_receipt"
export GRADUS_TEST_KEY_LOG="$behavior_key_log"
export GRADUS_TEST_XCRUN_LOG="$behavior_xcrun_log"
export GRADUS_TEST_TRANSPORT_LOG="$behavior_transport_log"
export PATH="$behavior_bin:$behavior_path"
unset GRADUS_UPLOAD_FAILURE_STATUS

set +e
resume_output="$(main 2>&1)"
resume_status=$?
set -e
[[ "$resume_status" -eq 0 && "$resume_output" == *"Uploading to App Store Connect"* ]] || {
  echo "FAIL: normal prepared-candidate resume did not reach mocked upload" >&2
  echo "$resume_output" >&2
  exit 1
}
grep -Fxq uploading "$behavior_transition_log" || {
  echo "FAIL: normal resume did not request the uploading transition" >&2
  exit 1
}
grep -Fq -- 'asc_build_upload.py' "$behavior_transport_log" || {
  echo "FAIL: normal resume did not reach the mocked upload transport" >&2
  exit 1
}
# No positive assertion on the mktemp stub here: the delivery transcript is
# created through the absolute /usr/bin/mktemp, so the stub is unreachable on
# this path. The receipt assertion below is the real proof that the transcript
# was written, teed, and parsed. The stub stays on PATH because the
# prepare-only check above still requires nothing to reach it.
# Nothing on the upload path may write the private key to disk any more.
# Assert the absence directly rather than trusting that the code which used
# to do it is gone: this is the property, not the implementation detail.
if /usr/bin/find "$behavior_root" -name 'AuthKey_*.p8' -print -quit | grep -q .; then
  echo "FAIL: upload path wrote App Store Connect key material to disk" >&2
  exit 1
fi
# End-to-end proof that the receipt writer's pattern still matches what the
# transport actually prints. The old pattern accepted only hex-and-dash, so a
# non-hex delivery id would have been dropped from the evidence in silence.
/usr/bin/python3 - "$behavior_workspace/upload-delivery.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["deliveryUuid"] == "fixture-delivery-id", payload
PY
export PATH="$behavior_path"
unset APP_STORE_CONNECT_API_KEY APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID
unset GRADUS_PRODUCER_EVIDENCE_PATH GRADUS_CANDIDATE_LEDGER_PATH
unset GRADUS_CANDIDATE_RECEIPT_PATH GRADUS_TEST_KEY_LOG GRADUS_TEST_XCRUN_LOG
unset GRADUS_TEST_TRANSPORT_LOG

write_evidence_fixture "$TEST_ROOT/missing-fields.json" "$EXPECTED_MAC_BUILD" "$EXPECTED_CLOUDKIT_ENVIRONMENT" "$now_timestamp"
assert_boundary_refused missing-fields "$TEST_ROOT/missing-fields.json"
write_evidence_fixture "$TEST_ROOT/mismatched-source.json" "$EXPECTED_MAC_BUILD" "$EXPECTED_CLOUDKIT_ENVIRONMENT" "$now_timestamp" \
  "different-source" "$EXPECTED_PROJECT_SHA256"
assert_boundary_refused mismatched-source "$TEST_ROOT/mismatched-source.json"
write_evidence_fixture "$TEST_ROOT/mismatched-project.json" "$EXPECTED_MAC_BUILD" "$EXPECTED_CLOUDKIT_ENVIRONMENT" "$now_timestamp" \
  "$EXPECTED_SOURCE_REVISION" "$(printf 'b%.0s' {1..64})"
assert_boundary_refused mismatched-project "$TEST_ROOT/mismatched-project.json"

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
grep -Eq 'set_required_entitlement "\$(PACKAGE_DIR|package_dir)/entitlements\.plist" aps-environment string production' "$UPLOAD_SCRIPT" || {
  echo "FAIL: production APS entitlement is not explicit" >&2
  exit 1
}
grep -Eq 'set_required_entitlement "\$(PACKAGE_DIR|package_dir)/entitlements\.plist" get-task-allow bool false' "$UPLOAD_SCRIPT" || {
  echo "FAIL: false get-task-allow entitlement is not explicit" >&2
  exit 1
}
grep -Fq 'codesign --verify --deep --strict' "$UPLOAD_SCRIPT" || {
  echo "FAIL: strict codesign verification is missing" >&2
  exit 1
}
grep -Fq 'CODE_SIGN_STYLE=Manual' "$UPLOAD_SCRIPT" || {
  echo "FAIL: iOS archive signing is not pinned to manual mode" >&2
  exit 1
}
grep -Fq 'CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"' "$UPLOAD_SCRIPT" || {
  echo "FAIL: iOS archive signing identity is not pinned" >&2
  exit 1
}
! grep -Fq 'PROVISIONING_PROFILE_SPECIFIER="$SIGNING_PROFILE_NAME"' "$UPLOAD_SCRIPT" || {
  echo "FAIL: global command-line PROVISIONING_PROFILE_SPECIFIER override was not removed from archive invocation" >&2
  exit 1
}
grep -Fq 'repackage_and_sign_ios_candidate' "$UPLOAD_SCRIPT" || {
  echo "FAIL: nested repackage and sign helper is missing" >&2
  exit 1
}

first_xattr_cleanup_line="$(awk '/xattr -cr/ {print NR; exit}' "$UPLOAD_SCRIPT")"
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
grep -Fq -- '--upload-only requires an existing prepared candidate' "$UPLOAD_SCRIPT" || {
  echo "FAIL: upload-only path does not fail closed without a prepared candidate" >&2
  exit 1
}
grep -Fq 'Revalidating fresh producer evidence before resumed upload' "$UPLOAD_SCRIPT" || {
  echo "FAIL: resumed upload does not require fresh producer evidence" >&2
  exit 1
}
prepare_line="$(grep -n 'Persisting machine-written candidate ledger before walkthrough generation' "$UPLOAD_SCRIPT" | tail -1 | cut -d: -f1)"
walkthrough_line="$(grep -n -- '-m release_candidate.walkthrough' "$UPLOAD_SCRIPT" | tail -1 | cut -d: -f1)"
uploading_line="$(grep -n 'transition_candidate_state "\$candidate_ledger_path" uploading' "$UPLOAD_SCRIPT" | tail -1 | cut -d: -f1)"
prepare_only_line="$(grep -n 'if (( prepare_only )); then' "$UPLOAD_SCRIPT" | tail -1 | cut -d: -f1)"
preflight_line="$(grep -n '_asc_api.make_token()' "$UPLOAD_SCRIPT" | tail -1 | cut -d: -f1)"
transport_line="$(grep -n 'asc_build_upload.py' "$UPLOAD_SCRIPT" | tail -1 | cut -d: -f1)"
[[ -n "$prepare_line" && -n "$walkthrough_line" && -n "$uploading_line" \
  && -n "$prepare_only_line" && -n "$preflight_line" && -n "$transport_line" \
  && "$prepare_line" -lt "$walkthrough_line" && "$walkthrough_line" -lt "$uploading_line" ]] || {
  echo "FAIL: candidate ledger, walkthrough, and uploading transitions are out of order" >&2
  exit 1
}
[[ "$walkthrough_line" -lt "$prepare_only_line" && "$prepare_only_line" -lt "$uploading_line" \
  && "$prepare_only_line" -lt "$preflight_line" && "$prepare_only_line" -lt "$transport_line" ]] || {
  echo "FAIL: prepare-only exit is not before the upload transition, preflight, or transport" >&2
  exit 1
}
# The credential preflight has to sit before the uploading transition. That
# state only forward-transitions to failed/abandoned, so a key that cannot
# sign must be caught while the candidate is still retryable as "prepared".
[[ "$preflight_line" -lt "$uploading_line" && "$uploading_line" -lt "$transport_line" ]] || {
  echo "FAIL: credential preflight does not precede the uploading transition" >&2
  exit 1
}

grep -Fq 'persist_identity_allocation' "$UPLOAD_SCRIPT" || {
  echo "FAIL: identity allocation is not persisted before candidate freeze" >&2
  exit 1
}
grep -Fq 'allocated-but-unfrozen' "$SCRIPT_DIR/release_candidate/allocation.py" || {
  echo "FAIL: allocated-but-unfrozen recovery state is missing" >&2
  exit 1
}
grep -Fq 'persist_upload_outcome' "$UPLOAD_SCRIPT" || {
  echo "FAIL: ambiguous-upload reconciliation evidence is not persisted" >&2
  exit 1
}

# An interrupted transfer is the ambiguous case: Apple may already hold the
# package. SIGINT/SIGTERM/SIGHUP bypass the EXIT trap, so the script handles
# them explicitly. Assert the real script installs every handler -- a deleted
# trap line would otherwise leave this suite green.
for signal_name in INT TERM HUP; do
  grep -Eq "trap 'persist_upload_outcome; exit [0-9]+' $signal_name\b" "$UPLOAD_SCRIPT" || {
    echo "FAIL: archive-upload-ios.sh does not reconcile an interrupted upload on $signal_name" >&2
    exit 1
  }
done
grep -Fq "trap 'persist_upload_outcome' EXIT" "$UPLOAD_SCRIPT" || {
  echo "FAIL: archive-upload-ios.sh does not reconcile an ambiguous upload on EXIT" >&2
  exit 1
}

# The probe mirrors the script's handler shape but calls the real function, so
# an interrupted upload is proven to leave durable reconciliation evidence.
interrupt_root="$TEST_ROOT/interrupt-reconciliation"
mkdir -p "$interrupt_root"
cat >"$interrupt_root/probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
source "$2"
export GRADUS_UPLOAD_RECONCILIATION_PATH="$1"
export GRADUS_UPLOAD_CANDIDATE_ID=fixture-interrupted
export GRADUS_UPLOAD_ARTIFACT_SHA256=fixture-digest
export GRADUS_UPLOAD_ATTEMPTED=1 GRADUS_UPLOAD_SUCCEEDED=0
trap 'persist_upload_outcome; exit 143' TERM
kill -TERM $$
sleep 10
PROBE
set +e
bash "$interrupt_root/probe.sh" "$interrupt_root/upload-reconciliation.json" "$UPLOAD_SCRIPT" >/dev/null 2>&1
interrupt_exit=$?
set -e
[[ "$interrupt_exit" -eq 143 ]] || {
  echo "FAIL: interrupted upload did not exit through its handler (got $interrupt_exit)" >&2
  exit 1
}
/usr/bin/python3 - "$interrupt_root/upload-reconciliation.json" <<'PY'
import json
import sys
from pathlib import Path

payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert payload["result"] == "reconciliation-required", payload
assert payload["reason"] == "upload-result-ambiguous", payload
assert payload["candidateId"] == "fixture-interrupted", payload
PY

# A delivered upload must leave no reconciliation record. A stale one would
# send a build Apple already accepted back to manual reconciliation forever.
success_root="$TEST_ROOT/succeeded-no-reconciliation"
mkdir -p "$success_root"
(
  # shellcheck source=./archive-upload-ios.sh
  source "$UPLOAD_SCRIPT"
  export GRADUS_UPLOAD_RECONCILIATION_PATH="$success_root/upload-reconciliation.json"
  export GRADUS_UPLOAD_CANDIDATE_ID=fixture-delivered
  export GRADUS_UPLOAD_ARTIFACT_SHA256=fixture-digest
  export GRADUS_UPLOAD_ATTEMPTED=1 GRADUS_UPLOAD_SUCCEEDED=1
  persist_upload_outcome
)
[[ ! -e "$success_root/upload-reconciliation.json" ]] || {
  echo "FAIL: a delivered upload was recorded as needing reconciliation" >&2
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

# A delivered upload must survive every failure that follows it. Build 20 of
# 1.8.0 reached Apple and then lost that fact to a detach failure, so each
# retry re-sent a build Apple already held. These cover the receipt that makes
# the transfer adoptable instead of repeatable.
delivery_root="$TEST_ROOT/delivery"
mkdir -p "$delivery_root"
delivery_receipt="$delivery_root/upload-delivery.json"
persist_delivery_receipt "$delivery_receipt" \
  gradus-ios-20 1.8.0 20 \
  4e5feb927071139485ae567871a5c2a32bf56f8af5b9046d1a5e701ecc598c08 347635 \
  7cedd283-fae4-432b-bfcc-b83b4f8ac719

[[ -f "$delivery_receipt" ]] || {
  echo "FAIL: delivery receipt was not written" >&2
  exit 1
}
delivery_mode="$(/usr/bin/stat -f %Lp "$delivery_receipt")"
[[ "$delivery_mode" == "600" ]] || {
  echo "FAIL: delivery receipt mode is $delivery_mode, expected 600" >&2
  exit 1
}
/usr/bin/python3 - "$delivery_receipt" <<'PY' || exit 1
import json
import sys

receipt = json.load(open(sys.argv[1], encoding="utf-8"))
expected = {
    "schemaVersion": "1.0.0",
    "operationClass": "upload",
    "candidateId": "gradus-ios-20",
    "marketingVersion": "1.8.0",
    "build": 20,
    "artifactSha256": "4e5feb927071139485ae567871a5c2a32bf56f8af5b9046d1a5e701ecc598c08",
    "artifactBytes": 347635,
    "result": "delivered",
    "deliveryUuid": "7cedd283-fae4-432b-bfcc-b83b4f8ac719",
}
for name, value in expected.items():
    if receipt.get(name) != value:
        print(f"FAIL: delivery receipt {name} is {receipt.get(name)!r}", file=sys.stderr)
        raise SystemExit(1)
if not str(receipt.get("deliveredAt", "")).endswith("Z"):
    print("FAIL: delivery receipt deliveredAt is not a UTC instant", file=sys.stderr)
    raise SystemExit(1)
PY

delivery_receipt_matches "$delivery_receipt" gradus-ios-20 20 \
  4e5feb927071139485ae567871a5c2a32bf56f8af5b9046d1a5e701ecc598c08 || {
  echo "FAIL: delivery receipt did not match its own candidate tuple" >&2
  exit 1
}

# Each rejection is the case where adopting would attest something that was
# never delivered, so none of them may be treated as a near-enough match.
while read -r reject_label reject_candidate reject_build reject_digest; do
  set +e
  delivery_receipt_matches "$delivery_receipt" "$reject_candidate" "$reject_build" "$reject_digest"
  reject_status=$?
  set -e
  [[ "$reject_status" -ne 0 ]] || {
    echo "FAIL: delivery receipt adopted a $reject_label mismatch" >&2
    exit 1
  }
done <<'REJECTS'
digest gradus-ios-20 20 0000000000000000000000000000000000000000000000000000000000000000
build gradus-ios-20 21 4e5feb927071139485ae567871a5c2a32bf56f8af5b9046d1a5e701ecc598c08
candidate gradus-ios-19 20 4e5feb927071139485ae567871a5c2a32bf56f8af5b9046d1a5e701ecc598c08
REJECTS

set +e
delivery_receipt_matches "$delivery_root/absent.json" gradus-ios-20 20 \
  4e5feb927071139485ae567871a5c2a32bf56f8af5b9046d1a5e701ecc598c08
absent_status=$?
set -e
[[ "$absent_status" -ne 0 ]] || {
  echo "FAIL: a missing delivery receipt was treated as a delivery" >&2
  exit 1
}

# An ambiguous transport result is exactly the state that must NOT auto-adopt.
undelivered_receipt="$delivery_root/undelivered.json"
/usr/bin/python3 - "$delivery_receipt" "$undelivered_receipt" <<'PY'
import json
import sys

receipt = json.load(open(sys.argv[1], encoding="utf-8"))
receipt["result"] = "reconciliation-required"
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(receipt, stream, sort_keys=True)
PY
set +e
delivery_receipt_matches "$undelivered_receipt" gradus-ios-20 20 \
  4e5feb927071139485ae567871a5c2a32bf56f8af5b9046d1a5e701ecc598c08
undelivered_status=$?
set -e
[[ "$undelivered_status" -ne 0 ]] || {
  echo "FAIL: a receipt that never confirmed delivery was adopted" >&2
  exit 1
}

# Ordering is the availability property: adoption runs before the credential
# preflight, so a run that transfers nothing can still adopt a delivery Apple
# already accepted even when no usable key is present.
adopt_line="$(awk '/delivery_receipt_matches "\$\{candidate_workspace\}\/upload-delivery.json"/ {print NR; exit}' "$UPLOAD_SCRIPT")"
credential_line="$(awk '/_asc_api.make_token\(\)/ {print NR; exit}' "$UPLOAD_SCRIPT")"
[[ -n "$adopt_line" && -n "$credential_line" && "$adopt_line" -lt "$credential_line" ]] || {
  echo "FAIL: delivery adoption does not precede the credential preflight" >&2
  exit 1
}

# Ordering is also the durability property: the receipt must be on disk before
# the traps that would otherwise record a delivered build as ambiguous are
# released, so the delivery is never left with neither record.
persist_line="$(awk '/^  persist_delivery_receipt "\$GRADUS_UPLOAD_DELIVERY_RECEIPT_PATH"/ {print NR; exit}' "$UPLOAD_SCRIPT")"
# The failure branch releases the same traps earlier, so match the last
# occurrence: the one on the delivered path this ordering is about.
release_line="$(awk '/^  trap - EXIT INT TERM HUP$/ {found = NR} END {if (found) print found}' "$UPLOAD_SCRIPT")"
[[ -n "$persist_line" && -n "$release_line" && "$persist_line" -lt "$release_line" ]] || {
  echo "FAIL: delivery receipt is not persisted before the reconciliation traps are released" >&2
  exit 1
}

# Keep the upload regression runner coupled to the canonical gate manifest:
# this script is the first hermetic leg, so it must fail loudly if candidate
# suites are added without counted invocations in test-gate.sh.
for candidate_suite in \
  test_release_candidate.py \
  test_release_candidate_validation.py \
  test_asc_api.py \
  test_asc_build_upload.py \
  test_release_reconcile.py \
  testflight-setup-tests.py \
  test_walkthrough.py; do
  grep -Fq "\"$candidate_suite\"" "$GATE_SCRIPT" || {
    echo "FAIL: canonical gate does not declare $candidate_suite" >&2
    exit 1
  }
done

# Hermetic profile validation fixtures
nested_test_root="$TEST_ROOT/nested-signing-tests"
mkdir -p "$nested_test_root"

create_test_profile() {
  local path="$1" bundle_id="${2:-com.zerodelta.gradus.ios}" team_id="${3:-4CJ49V6QHW}" cert_sha1="${4:-FD247ACDEBCD05C725AE29B40218FB0F57807A2C}"
  local app_group="${5:-group.com.zerodelta.gradus}" get_task_allow="${6:-false}" provisioned_devices="${7:-false}"
  local provisions_all_devices="${8:-false}" expired="${9:-false}"
  /usr/bin/python3 - "$path" "$bundle_id" "$team_id" "$cert_sha1" "$app_group" "$get_task_allow" "$provisioned_devices" "$provisions_all_devices" "$expired" <<'PY'
import datetime
import hashlib
import plistlib
import sys
from pathlib import Path

path, bundle_id, team_id, cert_sha1, app_group, get_task_allow_str, provisioned_devices_str, provisions_all_devices_str, expired_str = sys.argv[1:]

now = datetime.datetime.now(datetime.timezone.utc)
if expired_str == "true":
    exp = now - datetime.timedelta(days=1)
else:
    exp = now + datetime.timedelta(days=30)

cert_der = f"MOCK_CERT_DER_{cert_sha1}".encode("utf-8")
actual_sha1 = hashlib.sha1(cert_der).hexdigest().upper()

profile_data = {
    "AppIDName": "Gradus",
    "ApplicationIdentifierPrefix": [team_id],
    "CreationDate": now,
    "ExpirationDate": exp,
    "Name": f"Gradus {bundle_id} Profile",
    "TeamIdentifier": [team_id],
    "DeveloperCertificates": [cert_der],
    "Entitlements": {
        "application-identifier": f"{team_id}.{bundle_id}",
        "com.apple.developer.team-identifier": team_id,
        "com.apple.security.application-groups": [app_group] if app_group else [],
        "get-task-allow": True if get_task_allow_str == "true" else False,
    },
}
if provisioned_devices_str == "true":
    profile_data["ProvisionedDevices"] = ["00008030-001234567890"]
if provisions_all_devices_str == "true":
    profile_data["ProvisionsAllDevices"] = True

target_path = Path(path)
target_path.parent.mkdir(parents=True, exist_ok=True)
target_path.write_bytes(plistlib.dumps(profile_data))
print(actual_sha1)
PY
}

app_profile_fixture="$nested_test_root/profiles/app.mobileprovision"
widget_profile_fixture="$nested_test_root/profiles/widget.mobileprovision"

app_cert_sha1="$(create_test_profile "$app_profile_fixture" "com.zerodelta.gradus.ios" "4CJ49V6QHW" "app_cert")"
widget_cert_sha1="$(create_test_profile "$widget_profile_fixture" "com.zerodelta.gradus.ios.widget" "4CJ49V6QHW" "widget_cert")"

# 1. Valid profile validation
validate_profile "$app_profile_fixture" "com.zerodelta.gradus.ios" "4CJ49V6QHW" "$app_cert_sha1" "group.com.zerodelta.gradus" || {
  echo "FAIL: valid app profile was refused" >&2
  exit 1
}
validate_profile "$widget_profile_fixture" "com.zerodelta.gradus.ios.widget" "4CJ49V6QHW" "$widget_cert_sha1" "group.com.zerodelta.gradus" || {
  echo "FAIL: valid widget profile was refused" >&2
  exit 1
}

# 2. Swapped profiles
set +e
swapped_app_output="$(validate_profile "$app_profile_fixture" "com.zerodelta.gradus.ios.widget" "4CJ49V6QHW" "$app_cert_sha1" "group.com.zerodelta.gradus" 2>&1)"
swapped_app_status=$?
swapped_widget_output="$(validate_profile "$widget_profile_fixture" "com.zerodelta.gradus.ios" "4CJ49V6QHW" "$widget_cert_sha1" "group.com.zerodelta.gradus" 2>&1)"
swapped_widget_status=$?
set -e
[[ "$swapped_app_status" -ne 0 && "$swapped_app_output" == *"bundle ID mismatch"* ]] || {
  echo "FAIL: swapped app profile for widget was accepted" >&2
  exit 1
}
[[ "$swapped_widget_status" -ne 0 && "$swapped_widget_output" == *"bundle ID mismatch"* ]] || {
  echo "FAIL: swapped widget profile for app was accepted" >&2
  exit 1
}

# 3. Team mismatch
wrong_team_profile="$nested_test_root/profiles/wrong_team.mobileprovision"
wrong_team_sha1="$(create_test_profile "$wrong_team_profile" "com.zerodelta.gradus.ios" "OTHERTEAM" "cert")"
set +e
wrong_team_output="$(validate_profile "$wrong_team_profile" "com.zerodelta.gradus.ios" "4CJ49V6QHW" "$wrong_team_sha1" "group.com.zerodelta.gradus" 2>&1)"
wrong_team_status=$?
set -e
[[ "$wrong_team_status" -ne 0 && "$wrong_team_output" == *"team mismatch"* ]] || {
  echo "FAIL: profile with wrong team was accepted" >&2
  exit 1
}

# 4. Certificate mismatch
set +e
wrong_cert_output="$(validate_profile "$app_profile_fixture" "com.zerodelta.gradus.ios" "4CJ49V6QHW" "0000000000000000000000000000000000000000" "group.com.zerodelta.gradus" 2>&1)"
wrong_cert_status=$?
set -e
[[ "$wrong_cert_status" -ne 0 && "$wrong_cert_output" == *"does not contain expected certificate"* ]] || {
  echo "FAIL: profile with wrong certificate fingerprint was accepted" >&2
  exit 1
}

# 5. App Group mismatch
no_group_profile="$nested_test_root/profiles/no_group.mobileprovision"
no_group_sha1="$(create_test_profile "$no_group_profile" "com.zerodelta.gradus.ios" "4CJ49V6QHW" "cert" "group.wrong")"
set +e
no_group_output="$(validate_profile "$no_group_profile" "com.zerodelta.gradus.ios" "4CJ49V6QHW" "$no_group_sha1" "group.com.zerodelta.gradus" 2>&1)"
no_group_status=$?
set -e
[[ "$no_group_status" -ne 0 && "$no_group_output" == *"missing expected App Group"* ]] || {
  echo "FAIL: profile missing required App Group was accepted" >&2
  exit 1
}

# 6. Distribution type (get-task-allow, ProvisionedDevices, ProvisionsAllDevices)
dev_profile="$nested_test_root/profiles/dev.mobileprovision"
dev_sha1="$(create_test_profile "$dev_profile" "com.zerodelta.gradus.ios" "4CJ49V6QHW" "cert" "group.com.zerodelta.gradus" "true")"
set +e
dev_output="$(validate_profile "$dev_profile" "com.zerodelta.gradus.ios" "4CJ49V6QHW" "$dev_sha1" "group.com.zerodelta.gradus" 2>&1)"
dev_status=$?
set -e
[[ "$dev_status" -ne 0 && "$dev_output" == *"not distribution"* ]] || {
  echo "FAIL: development profile with get-task-allow=true was accepted" >&2
  exit 1
}

adhoc_profile="$nested_test_root/profiles/adhoc.mobileprovision"
adhoc_sha1="$(create_test_profile "$adhoc_profile" "com.zerodelta.gradus.ios" "4CJ49V6QHW" "cert" "group.com.zerodelta.gradus" "false" "true")"
set +e
adhoc_output="$(validate_profile "$adhoc_profile" "com.zerodelta.gradus.ios" "4CJ49V6QHW" "$adhoc_sha1" "group.com.zerodelta.gradus" 2>&1)"
adhoc_status=$?
set -e
[[ "$adhoc_status" -ne 0 && "$adhoc_output" == *"contains ProvisionedDevices"* ]] || {
  echo "FAIL: ad-hoc profile with ProvisionedDevices was accepted" >&2
  exit 1
}

ent_profile="$nested_test_root/profiles/enterprise.mobileprovision"
ent_sha1="$(create_test_profile "$ent_profile" "com.zerodelta.gradus.ios" "4CJ49V6QHW" "cert" "group.com.zerodelta.gradus" "false" "false" "true")"
set +e
ent_output="$(validate_profile "$ent_profile" "com.zerodelta.gradus.ios" "4CJ49V6QHW" "$ent_sha1" "group.com.zerodelta.gradus" 2>&1)"
ent_status=$?
set -e
[[ "$ent_status" -ne 0 && "$ent_output" == *"Enterprise distribution"* ]] || {
  echo "FAIL: enterprise profile was accepted" >&2
  exit 1
}

# 7. Expired profile
exp_profile="$nested_test_root/profiles/expired.mobileprovision"
exp_sha1="$(create_test_profile "$exp_profile" "com.zerodelta.gradus.ios" "4CJ49V6QHW" "cert" "group.com.zerodelta.gradus" "false" "false" "false" "true")"
set +e
exp_output="$(validate_profile "$exp_profile" "com.zerodelta.gradus.ios" "4CJ49V6QHW" "$exp_sha1" "group.com.zerodelta.gradus" 2>&1)"
exp_status=$?
set -e
[[ "$exp_status" -ne 0 && "$exp_output" == *"expired"* ]] || {
  echo "FAIL: expired profile was accepted" >&2
  exit 1
}

# Profile resolution tests
profiles_dir="$nested_test_root/managed_profiles"
mkdir -p "$profiles_dir"
app_named_profile="$profiles_dir/gradus-ios-app-store.provisionprofile"
widget_named_profile="$profiles_dir/gradus-widget-app-store.provisionprofile"
app_named_sha1="$(create_test_profile "$app_named_profile" "com.zerodelta.gradus.ios" "4CJ49V6QHW" "app_named")"
create_test_profile "$widget_named_profile" "com.zerodelta.gradus.ios.widget" "4CJ49V6QHW" "widget_named" >/dev/null

resolved_app="$(GRADUS_PROVISIONING_PROFILES_DIR="$profiles_dir" resolve_provisioning_profile "com.zerodelta.gradus.ios")"
[[ "$resolved_app" == "$app_named_profile" ]] || {
  echo "FAIL: resolve_provisioning_profile failed to locate app profile" >&2
  exit 1
}
resolved_widget="$(GRADUS_PROVISIONING_PROFILES_DIR="$profiles_dir" resolve_provisioning_profile "com.zerodelta.gradus.ios.widget")"
[[ "$resolved_widget" == "$widget_named_profile" ]] || {
  echo "FAIL: resolve_provisioning_profile failed to locate widget profile" >&2
  exit 1
}

# locate_and_validate_distribution_profiles output must stay machine-only on
# stdout: exercise the exact command-substitution + cut parsing sequence main
# uses (validated_profiles="$(...)"; app=cut -f1; widget=cut -f2) so any
# progress text leaking onto stdout corrupts the parsed paths and fails here.
locate_profiles_dir="$nested_test_root/locate_profiles"
mkdir -p "$locate_profiles_dir"
locate_app_profile="$locate_profiles_dir/gradus-ios-app-store.provisionprofile"
locate_widget_profile="$locate_profiles_dir/gradus-widget-app-store.provisionprofile"
locate_shared_sha1="$(create_test_profile "$locate_app_profile" "com.zerodelta.gradus.ios" "4CJ49V6QHW" "locate_shared_cert")"
create_test_profile "$locate_widget_profile" "com.zerodelta.gradus.ios.widget" "4CJ49V6QHW" "locate_shared_cert" >/dev/null

locate_validated="$(GRADUS_PROVISIONING_PROFILES_DIR="$locate_profiles_dir" SIGNING_IDENTITY="$locate_shared_sha1" locate_and_validate_distribution_profiles)"
locate_app_path="$(printf '%s\n' "$locate_validated" | cut -f1)"
locate_widget_path="$(printf '%s\n' "$locate_validated" | cut -f2)"
[[ "$locate_app_path" == "$locate_app_profile" ]] || {
  echo "FAIL: locate_and_validate_distribution_profiles app path was corrupted by captured progress output (got '$locate_app_path')" >&2
  exit 1
}
[[ "$locate_widget_path" == "$locate_widget_profile" ]] || {
  echo "FAIL: locate_and_validate_distribution_profiles widget path was corrupted by captured progress output (got '$locate_widget_path')" >&2
  exit 1
}

# Mock archive creation helper
create_mock_archive() {
  local root="$1" app_version="${2:-1.9.0}" app_build="${3:-12}" ext_version="${4:-1.9.0}" ext_build="${5:-12}"
  local ext_name="${6:-GradusWidget.appex}" extra_ext="${7:-}"

  local app_dir="$root/Products/Applications/GradusiOS.app"
  local plugins_dir="$app_dir/PlugIns"
  mkdir -p "$plugins_dir"

  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $app_version" "$app_dir/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$app_dir/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $app_build" "$app_dir/Info.plist" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $app_build" "$app_dir/Info.plist"

  if [[ -n "$ext_name" && "$ext_name" != "NONE" ]]; then
    local ext_dir="$plugins_dir/$ext_name"
    mkdir -p "$ext_dir"
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $ext_version" "$ext_dir/Info.plist" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ext_version" "$ext_dir/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $ext_build" "$ext_dir/Info.plist" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $ext_build" "$ext_dir/Info.plist"
  fi

  if [[ -n "$extra_ext" ]]; then
    local extra_dir="$plugins_dir/$extra_ext"
    mkdir -p "$extra_dir"
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $ext_version" "$extra_dir/Info.plist" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $ext_version" "$extra_dir/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $ext_build" "$extra_dir/Info.plist" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $ext_build" "$extra_dir/Info.plist"
  fi
}

# Mock codesign setup
mock_bin_dir="$nested_test_root/bin"
mkdir -p "$mock_bin_dir"
mock_codesign_log="$nested_test_root/codesign.log"

cat >"$mock_bin_dir/codesign" <<'MOCK_CS'
#!/usr/bin/env bash
set -eu
target="${@: -1}"
if [[ -n "${MOCK_CODESIGN_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "$MOCK_CODESIGN_LOG"
fi
if [[ "$*" == *"-d --entitlements"* ]]; then
  if [[ "$target" == *"GradusWidget.appex"* ]]; then
    if [[ "${MOCK_EXTENSION_ENTITLEMENT_EXTRACT_FAIL:-0}" == "1" ]]; then
      exit 1
    elif [[ "${MOCK_EXTENSION_LEAK_CLOUDKIT:-0}" == "1" ]]; then
      cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.application-groups</key>
  <array><string>group.com.zerodelta.gradus</string></array>
  <key>com.apple.developer.icloud-services</key>
  <array><string>CloudKit</string></array>
</dict>
</plist>
EOF
      exit 0
    elif [[ "${MOCK_EXTENSION_LEAK_APS:-0}" == "1" ]]; then
      cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.application-groups</key>
  <array><string>group.com.zerodelta.gradus</string></array>
  <key>aps-environment</key>
  <string>production</string>
</dict>
</plist>
EOF
      exit 0
    elif [[ "${MOCK_EXTENSION_WRONG_APP_GROUP:-0}" == "1" ]]; then
      cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.application-groups</key>
  <array><string>group.wrong</string></array>
</dict>
</plist>
EOF
      exit 0
    else
      cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.application-groups</key>
  <array><string>group.com.zerodelta.gradus</string></array>
</dict>
</plist>
EOF
      exit 0
    fi
  else
    cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.application-groups</key>
  <array><string>group.com.zerodelta.gradus</string></array>
</dict>
</plist>
EOF
    exit 0
  fi
fi
exit 0
MOCK_CS
chmod +x "$mock_bin_dir/codesign"

orig_path="$PATH"
export PATH="$mock_bin_dir:$orig_path"
export MOCK_CODESIGN_LOG="$mock_codesign_log"

# 8. Missing extension fixture
missing_ext_archive="$nested_test_root/archive_no_ext"
create_mock_archive "$missing_ext_archive" 1.9.0 12 1.9.0 12 "NONE"
set +e
missing_ext_output="$(repackage_and_sign_ios_candidate "$missing_ext_archive" "$nested_test_root/pkg_no_ext" \
  "$app_named_profile" "$widget_named_profile" "$app_named_sha1" "Production" "1.9.0" "12" 2>&1)"
missing_ext_status=$?
set -e
[[ "$missing_ext_status" -ne 0 && "$missing_ext_output" == *"GradusWidget.appex is missing from PlugIns"* ]] || {
  echo "FAIL: archive missing GradusWidget.appex was accepted" >&2
  exit 1
}

# 9. Wrong extension fixture
wrong_ext_archive="$nested_test_root/archive_wrong_ext"
create_mock_archive "$wrong_ext_archive" 1.9.0 12 1.9.0 12 "WrongExtension.appex"
set +e
wrong_ext_output="$(repackage_and_sign_ios_candidate "$wrong_ext_archive" "$nested_test_root/pkg_wrong_ext" \
  "$app_named_profile" "$widget_named_profile" "$app_named_sha1" "Production" "1.9.0" "12" 2>&1)"
wrong_ext_status=$?
set -e
[[ "$wrong_ext_status" -ne 0 && "$wrong_ext_output" == *"GradusWidget.appex is missing from PlugIns"* ]] || {
  echo "FAIL: archive with wrong extension name was accepted" >&2
  exit 1
}

# 10. Multiple extensions fixture
multi_ext_archive="$nested_test_root/archive_multi_ext"
create_mock_archive "$multi_ext_archive" 1.9.0 12 1.9.0 12 "GradusWidget.appex" "ExtraWidget.appex"
set +e
multi_ext_output="$(repackage_and_sign_ios_candidate "$multi_ext_archive" "$nested_test_root/pkg_multi_ext" \
  "$app_named_profile" "$widget_named_profile" "$app_named_sha1" "Production" "1.9.0" "12" 2>&1)"
multi_ext_status=$?
set -e
[[ "$multi_ext_status" -ne 0 && "$multi_ext_output" == *"expected exactly 1 .appex"* ]] || {
  echo "FAIL: archive with multiple extensions was accepted" >&2
  exit 1
}

# 11. Extension CloudKit/APS leakage fixtures
valid_archive="$nested_test_root/archive_valid"
create_mock_archive "$valid_archive" 1.9.0 12 1.9.0 12 "GradusWidget.appex"

set +e
leak_ck_output="$(MOCK_EXTENSION_LEAK_CLOUDKIT=1 repackage_and_sign_ios_candidate "$valid_archive" "$nested_test_root/pkg_leak_ck" \
  "$app_named_profile" "$widget_named_profile" "$app_named_sha1" "Production" "1.9.0" "12" 2>&1)"
leak_ck_status=$?
set -e
[[ "$leak_ck_status" -ne 0 && "$leak_ck_output" == *"extension leaked disallowed entitlement"* ]] || {
  echo "FAIL: extension CloudKit leakage was accepted" >&2
  exit 1
}

set +e
leak_aps_output="$(MOCK_EXTENSION_LEAK_APS=1 repackage_and_sign_ios_candidate "$valid_archive" "$nested_test_root/pkg_leak_aps" \
  "$app_named_profile" "$widget_named_profile" "$app_named_sha1" "Production" "1.9.0" "12" 2>&1)"
leak_aps_status=$?
set -e
[[ "$leak_aps_status" -ne 0 && "$leak_aps_output" == *"extension leaked disallowed entitlement"* ]] || {
  echo "FAIL: extension APS leakage was accepted" >&2
  exit 1
}

# 11b. Extension entitlement extraction failure must fail closed, not synthesize
: > "$mock_codesign_log"
set +e
extract_fail_output="$(MOCK_EXTENSION_ENTITLEMENT_EXTRACT_FAIL=1 repackage_and_sign_ios_candidate "$valid_archive" "$nested_test_root/pkg_extract_fail" \
  "$app_named_profile" "$widget_named_profile" "$app_named_sha1" "Production" "1.9.0" "12" 2>&1)"
extract_fail_status=$?
set -e
[[ "$extract_fail_status" -ne 0 && "$extract_fail_output" == *"could not extract entitlements from GradusWidget.appex"* ]] || {
  echo "FAIL: failed GradusWidget entitlement extraction was not rejected" >&2
  exit 1
}
grep -Fq -- '--sign' "$mock_codesign_log" && {
  echo "FAIL: signing proceeded despite failed GradusWidget entitlement extraction" >&2
  exit 1
}

# 12. Version / build drift fixtures
drift_ver_archive="$nested_test_root/archive_drift_ver"
create_mock_archive "$drift_ver_archive" 1.9.0 12 1.8.0 12 "GradusWidget.appex"
set +e
drift_ver_output="$(repackage_and_sign_ios_candidate "$drift_ver_archive" "$nested_test_root/pkg_drift_ver" \
  "$app_named_profile" "$widget_named_profile" "$app_named_sha1" "Production" "1.9.0" "12" 2>&1)"
drift_ver_status=$?
set -e
[[ "$drift_ver_status" -ne 0 && "$drift_ver_output" == *"CFBundleShortVersionString"* ]] || {
  echo "FAIL: extension marketing version drift was accepted" >&2
  exit 1
}

drift_bld_archive="$nested_test_root/archive_drift_bld"
create_mock_archive "$drift_bld_archive" 1.9.0 12 1.9.0 11 "GradusWidget.appex"
set +e
drift_bld_output="$(repackage_and_sign_ios_candidate "$drift_bld_archive" "$nested_test_root/pkg_drift_bld" \
  "$app_named_profile" "$widget_named_profile" "$app_named_sha1" "Production" "1.9.0" "12" 2>&1)"
drift_bld_status=$?
set -e
[[ "$drift_bld_status" -ne 0 && "$drift_bld_output" == *"CFBundleVersion"* ]] || {
  echo "FAIL: extension build number drift was accepted" >&2
  exit 1
}

# Project.yml marketing version parity check
project_drift_yaml="$nested_test_root/project_drift.yml"
cat >"$project_drift_yaml" <<'YAML'
targets:
  GradusMac:
    settings:
      base:
        MARKETING_VERSION: "1.9.0"
  GradusiOS:
    settings:
      base:
        MARKETING_VERSION: "1.9.0"
  GradusWidget:
    settings:
      base:
        MARKETING_VERSION: "1.8.0"
YAML
set +e
project_drift_output="$(validate_common_marketing_version "$project_drift_yaml" 2>&1)"
project_drift_status=$?
set -e
[[ "$project_drift_status" -ne 0 && "$project_drift_output" == *"Mac, iOS, and Widget marketing versions must match"* ]] || {
  echo "FAIL: project.yml with drifted widget marketing version was accepted" >&2
  exit 1
}

# 13. Signing order & valid nested output
: > "$mock_codesign_log"
valid_pkg_dir="$nested_test_root/pkg_valid"
repackage_and_sign_ios_candidate "$valid_archive" "$valid_pkg_dir" \
  "$app_named_profile" "$widget_named_profile" "$app_named_sha1" "Production" "1.9.0" "12"

# Verify embedded profile placement
[[ -f "$valid_pkg_dir/Payload/GradusiOS.app/embedded.mobileprovision" ]] || {
  echo "FAIL: app profile was not embedded" >&2
  exit 1
}
[[ -f "$valid_pkg_dir/Payload/GradusiOS.app/PlugIns/GradusWidget.appex/embedded.mobileprovision" ]] || {
  echo "FAIL: widget profile was not embedded" >&2
  exit 1
}
cmp -s "$valid_pkg_dir/Payload/GradusiOS.app/embedded.mobileprovision" "$app_named_profile" || {
  echo "FAIL: embedded app profile does not match source profile" >&2
  exit 1
}
cmp -s "$valid_pkg_dir/Payload/GradusiOS.app/PlugIns/GradusWidget.appex/embedded.mobileprovision" "$widget_named_profile" || {
  echo "FAIL: embedded widget profile does not match source profile" >&2
  exit 1
}

# Verify derived entitlements
assert_required_entitlement "$valid_pkg_dir/widget-entitlements.plist" get-task-allow false
assert_required_app_group "$valid_pkg_dir/widget-entitlements.plist" "group.com.zerodelta.gradus"
assert_no_disallowed_extension_entitlements "$valid_pkg_dir/widget-entitlements.plist"

assert_required_entitlement "$valid_pkg_dir/entitlements.plist" get-task-allow false
assert_required_entitlement "$valid_pkg_dir/entitlements.plist" aps-environment production
assert_required_entitlement "$valid_pkg_dir/entitlements.plist" "com.apple.developer.icloud-container-environment" Production
assert_required_app_group "$valid_pkg_dir/entitlements.plist" "group.com.zerodelta.gradus"

# Verify signing order: extension FIRST, main app LAST
widget_sign_line="$(grep -n -- '--sign.*GradusWidget.appex' "$mock_codesign_log" | cut -d: -f1 | head -n 1)"
app_sign_line="$(grep -n -- '--sign.*GradusiOS.app' "$mock_codesign_log" | grep -v 'GradusWidget' | cut -d: -f1 | head -n 1)"
[[ -n "$widget_sign_line" && -n "$app_sign_line" && "$widget_sign_line" -lt "$app_sign_line" ]] || {
  echo "FAIL: codesign signing order must sign extension first and app last" >&2
  exit 1
}

export PATH="$orig_path"
unset MOCK_CODESIGN_LOG

echo "archive-upload-ios.sh HOME fallback and credential guard passed"
