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
mkdir -p "$behavior_bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\\n" "$*" >> "$GRADUS_TEST_KEY_LOG"' \
  'exec /usr/bin/mktemp "$@"' >"$behavior_bin/mktemp"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\\n" "$*" >> "$GRADUS_TEST_XCRUN_LOG"' \
  'exit 0' >"$behavior_bin/xcrun"
chmod 700 "$behavior_bin/mktemp" "$behavior_bin/xcrun"

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
behavior_path="$PATH"
export PATH="$behavior_bin:$behavior_path"
unset API_PRIVATE_KEYS_DIR

set +e
prepare_only_output="$(main --prepare-only 2>&1)"
prepare_only_status=$?
set -e
[[ "$prepare_only_status" -eq 0 && "$prepare_only_output" == *"upload deferred"* ]] || {
  echo "FAIL: --prepare-only did not return successfully from a prepared candidate" >&2
  echo "$prepare_only_output" >&2
  exit 1
}
[[ ! -s "$behavior_transition_log" && ! -s "$behavior_key_log" && ! -s "$behavior_xcrun_log" ]] || {
  echo "FAIL: --prepare-only reached upload transition, key creation, or xcrun" >&2
  exit 1
}
PYTHONPATH="$SCRIPT_DIR" /usr/bin/python3 - "$behavior_ledger" <<'PY'
import sys
from release_candidate.ledger import CandidateLedger, CandidateState

record = CandidateLedger(sys.argv[1]).load()
assert record is not None and record.state == CandidateState.PREPARED
PY

# A failed transport must detach the key volume and leave both the RAM proof
# and an explicit reconciliation-required record before returning the transport
# status. Build a second prepared fixture so the successful resume below stays
# independent of this failure path.
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
mkdir -p "$failure_bin"
cp "$behavior_bin/mktemp" "$failure_bin/mktemp"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\\n" "$*" >> "$GRADUS_TEST_XCRUN_LOG"' \
  'exit 42' >"$failure_bin/xcrun"
chmod 700 "$failure_bin/mktemp" "$failure_bin/xcrun"
export GRADUS_CANDIDATE_LEDGER_PATH="$failure_ledger"
export GRADUS_CANDIDATE_RECEIPT_PATH="$failure_receipt"
export GRADUS_TEST_KEY_LOG="$failure_key_log"
export GRADUS_TEST_XCRUN_LOG="$failure_xcrun_log"
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
[[ -f "$failure_workspace/ram-volume-attestation.json" && -f "$failure_workspace/upload-reconciliation.json" ]] || {
  echo "FAIL: failed upload did not persist RAM and reconciliation evidence" >&2
  exit 1
}
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
grep -Fq -- '--upload-package' "$behavior_xcrun_log" || {
  echo "FAIL: normal resume did not reach the mocked xcrun altool attempt" >&2
  exit 1
}
grep -Fq -- '-d' "$behavior_key_log" || {
  echo "FAIL: normal resume did not create the hermetic RAM-volume fixture" >&2
  exit 1
}
export PATH="$behavior_path"
unset APP_STORE_CONNECT_API_KEY APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID
unset API_PRIVATE_KEYS_DIR GRADUS_PRODUCER_EVIDENCE_PATH GRADUS_CANDIDATE_LEDGER_PATH
unset GRADUS_CANDIDATE_RECEIPT_PATH GRADUS_TEST_KEY_LOG GRADUS_TEST_XCRUN_LOG

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
grep -Fq 'CODE_SIGN_STYLE=Manual' "$UPLOAD_SCRIPT" || {
  echo "FAIL: iOS archive signing is not pinned to manual mode" >&2
  exit 1
}
grep -Fq 'CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"' "$UPLOAD_SCRIPT" || {
  echo "FAIL: iOS archive signing identity is not pinned" >&2
  exit 1
}
grep -Fq 'PROVISIONING_PROFILE_SPECIFIER="$SIGNING_PROFILE_NAME"' "$UPLOAD_SCRIPT" || {
  echo "FAIL: iOS archive provisioning profile is not pinned" >&2
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
key_dir_line="$(grep -n '^  create_ram_key_volume$' "$UPLOAD_SCRIPT" | tail -1 | cut -d: -f1)"
altool_line="$(grep -n 'xcrun altool --upload-package' "$UPLOAD_SCRIPT" | tail -1 | cut -d: -f1)"
[[ -n "$prepare_line" && -n "$walkthrough_line" && -n "$uploading_line" \
  && -n "$prepare_only_line" && -n "$key_dir_line" && -n "$altool_line" \
  && "$prepare_line" -lt "$walkthrough_line" && "$walkthrough_line" -lt "$uploading_line" ]] || {
  echo "FAIL: candidate ledger, walkthrough, and uploading transitions are out of order" >&2
  exit 1
}
[[ "$walkthrough_line" -lt "$prepare_only_line" && "$prepare_only_line" -lt "$uploading_line" \
  && "$prepare_only_line" -lt "$key_dir_line" && "$prepare_only_line" -lt "$altool_line" ]] || {
  echo "FAIL: prepare-only exit is not before upload transition or key/altool setup" >&2
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
grep -Fq 'persist_ram_volume_attestation' "$UPLOAD_SCRIPT" || {
  echo "FAIL: RAM-volume detach proof is not persisted" >&2
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
