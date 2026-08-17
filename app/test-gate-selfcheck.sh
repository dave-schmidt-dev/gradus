#!/usr/bin/env bash
# Hermetic tests for the counting-leg assertion in test-gate.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE_SCRIPT="$SCRIPT_DIR/test-gate.sh"
failure_count=0

fail() {
  echo "FAIL: $1" >&2
  failure_count=$((failure_count + 1))
}

expect_failure() {
  local description="$1"
  shift
  if "$@"; then
    fail "$description unexpectedly passed"
  fi
}

emit_report() {
  local reporter="$1"
  local count="$2"
  case "$reporter" in
    swift-testing) printf 'Test run with %s tests\n' "$count" ;;
    pytest) printf '%s passed\n' "$count" ;;
    xctest) printf 'Executed %s tests\n** TEST SUCCEEDED **\n' "$count" ;;
    aggregate-xctest-swift)
      printf 'Test run with %s tests\nExecuted 3 tests\n** TEST SUCCEEDED **\n' "$((count - 3))"
      ;;
    *)
      echo "FAIL: unknown reporter '$reporter'" >&2
      return 1
      ;;
  esac
}

emit_absent_report() {
  printf 'command completed successfully\n'
}

# A sourced gate must not change either the caller's directory or shell
# options. Deliberately start with different options from the live gate.
if ! bash -c '
  set +e +u
  set +o pipefail
  expected_cwd="$PWD"
  expected_flags="$-"
  expected_options="$(set -o)"
  source "$1"
  [[ "$PWD" == "$expected_cwd" ]]
  [[ "$-" == "$expected_flags" ]]
  [[ "$(set -o)" == "$expected_options" ]]
' bash "$GATE_SCRIPT"; then
  fail "sourcing test-gate.sh changed the caller's cwd or shell options"
fi

# shellcheck source=./test-gate.sh
source "$GATE_SCRIPT"
validate_counting_leg_declarations || fail "live counting-leg declarations are invalid"
validate_density_image_snapshot_selectors || fail "live density image snapshot selectors are invalid"

# The one semantic density-label assertion stays in the iPhone unit suite.
# Every selected canonical image test must contain one image assertion, and the
# gate must derive both destination selectors from this single list.
snapshot_test_names="$(awk '
  /^@Test func / {
    if (name != "" && has_image_assertion) print name
    name = $3
    sub(/\(\).*/, "", name)
    has_image_assertion = 0
    next
  }
  /assertSnapshot\(/ { has_image_assertion = 1 }
  END { if (name != "" && has_image_assertion) print name }
' "$SCRIPT_DIR/GradusiOSTests/DensityLayoutSnapshotTests.swift")"
snapshot_test_count="$(printf '%s\n' "$snapshot_test_names" | sed '/^$/d' | wc -l | tr -d ' ')"
[[ "$snapshot_test_count" -eq "${#DENSITY_IMAGE_SNAPSHOT_TEST_SELECTORS[@]}" ]] ||
  fail "density image selector count does not match image assertion count"
snapshot_selector_names="$(printf '%s\n' "${DENSITY_IMAGE_SNAPSHOT_TEST_SELECTORS[@]}" |
  sed -E 's#^GradusiOSTests/##; s/\(\)$//' | sort)"
if [[ "$(printf '%s\n' "$snapshot_test_names" | sed '/^$/d' | sort)" != "$snapshot_selector_names" ]]; then
  fail "density image selectors do not exactly match source image assertions"
fi
grep -Fq '"${density_snapshot_skip_args[@]}"' "$GATE_SCRIPT" ||
  fail "iPhone does not derive density snapshot exclusions from the shared selector list"
grep -Fq '"${density_snapshot_only_args[@]}"' "$GATE_SCRIPT" ||
  fail "iPad does not derive density snapshot inclusions from the shared selector list"

# The two iOS destinations are separate evidence, not interchangeable labels.
# Keep the destination contract structural so a copied iPhone command cannot
# silently make the iPad leg green (or vice versa).
validate_ios_destination_contract() {
  local gate_path="$1"
  local iphone_block ipad_block iphone_ui_block
  iphone_block="$(sed -n '/assert_counting_leg "GradusiOS-iPhone"/,/CODE_SIGNING_ALLOWED=NO/p' "$gate_path")"
  ipad_block="$(sed -n '/assert_counting_leg "GradusiOS-iPad"/,/CODE_SIGNING_ALLOWED=NO/p' "$gate_path")"
  iphone_ui_block="$(sed -n '/assert_counting_leg "GradusiOSUI"/,/CODE_SIGNING_ALLOWED=NO/p' "$gate_path")"

  [[ "$iphone_block" == *'-destination "platform=iOS Simulator,id=$sim_udid"'* ]] ||
    return 1
  [[ "$ipad_block" == *'-destination "platform=iOS Simulator,id=$ipad_udid"'* ]] ||
    return 1
  [[ "$iphone_ui_block" == *'-destination "platform=iOS Simulator,id=$sim_udid"'* ]] ||
    return 1
  [[ "$iphone_ui_block" == *'-only-testing:GradusiOSUITests'* ]] ||
    return 1
  [[ "$ipad_block" == *'-only-testing:GradusiOSUITests'* ]] ||
    return 1
  [[ "$iphone_block" == *'"${density_snapshot_skip_args[@]}"'* ]] ||
    return 1
  [[ "$ipad_block" == *'"${density_snapshot_only_args[@]}"'* ]] ||
    return 1
}

validate_ios_destination_contract "$GATE_SCRIPT" ||
  fail "iPhone/iPad destination or UI-selector contract is incomplete"

# Every Xcode test leg must use one fresh, run-scoped DerivedData directory.
# Without it, snapshot resources or a stale Mac XCTest runner can survive a
# source/signing change and make the release gate exercise the wrong bundle.
validate_derived_data_contract() {
  local gate_path="$1" leg block
  grep -Fq 'derived_data_dir="$(mktemp -d "${TMPDIR:-/tmp}/gradus-test-gate-derived-data.XXXXXX")"' "$gate_path" ||
    return 1
  grep -Fq 'rm -rf "$derived_data_dir"' "$gate_path" || return 1
  for leg in GradusMac GradusiOS-iPhone GradusiOS-iPad GradusMacUI GradusiOSUI; do
    block="$(sed -n "/assert_counting_leg \"$leg\"/,/CODE_SIGNING_ALLOWED=NO/p" "$gate_path")"
    [[ "$leg" == "GradusMacUI" ]] &&
      block="$(sed -n "/assert_counting_leg \"$leg\"/,/PROVISIONING_PROFILE_SPECIFIER=/p" "$gate_path")"
    [[ "$block" == *'-derivedDataPath "$derived_data_dir"'* ]] || return 1
  done
}

validate_derived_data_contract "$GATE_SCRIPT" ||
  fail "Xcode test legs are not isolated in fresh run-scoped DerivedData"

grep -Fq 'APPLE_UI_TEST_LOCK="${APPLE_UI_TEST_LOCK:-$HOME/.agent/bin/apple-ui-test-lock}"' "$GATE_SCRIPT" ||
  fail "canonical Apple UI-test lock path is missing"
for leg in GradusiOS-iPad GradusMacUI GradusiOSUI; do
  ui_block="$(sed -n "/assert_counting_leg \"$leg\"/,/CODE_SIGNING_ALLOWED=NO/p" "$GATE_SCRIPT")"
  [[ "$leg" == "GradusMacUI" ]] &&
    ui_block="$(sed -n "/assert_counting_leg \"$leg\"/,/PROVISIONING_PROFILE_SPECIFIER=/p" "$GATE_SCRIPT")"
  [[ "$ui_block" == *'"$APPLE_UI_TEST_LOCK" --label'* ]] ||
    fail "$leg is not serialized by apple-ui-test-lock"
done
for leg in GradusMac GradusiOS-iPhone; do
  unit_block="$(sed -n "/assert_counting_leg \"$leg\"/,/CODE_SIGNING_ALLOWED=NO/p" "$GATE_SCRIPT")"
  [[ "$unit_block" != *'"$APPLE_UI_TEST_LOCK"'* ]] ||
    fail "$leg unit leg must not use apple-ui-test-lock"
done

ipad_ui_line="$(grep -nF 'assert_counting_leg "GradusiOS-iPad"' "$GATE_SCRIPT" | cut -d: -f1)"
iphone_ui_line="$(grep -nF 'assert_counting_leg "GradusiOSUI"' "$GATE_SCRIPT" | cut -d: -f1)"
mac_ui_line="$(grep -nF 'assert_counting_leg "GradusMacUI"' "$GATE_SCRIPT" | cut -d: -f1)"
if ! (( ipad_ui_line < iphone_ui_line && iphone_ui_line < mac_ui_line )); then
  fail "simulator UI legs must stay adjacent and precede the macOS UI leg"
fi

validate_iphone_ui_handoff_contract() {
  local gate_path="$1" handoff_block handoff_call_line restore_block
  handoff_block="$(sed -n '/^reset_simulator_ui_session_for_iphone()/,/^}/p' "$gate_path")"
  [[ "$handoff_block" == *'xcrun simctl shutdown "$ipad_udid"'* ]] || return 1
  [[ "$handoff_block" == *'xcrun simctl shutdown "$sim_udid"'* ]] || return 1
  [[ "$handoff_block" == *'xcrun simctl boot "$sim_udid"'* ]] || return 1
  [[ "$handoff_block" == *'xcrun simctl bootstatus "$sim_udid" -b'* ]] || return 1
  restore_block="$(sed -n '/^restore_preexisting_ipad_after_handoff()/,/^}/p' "$gate_path")"
  [[ "$restore_block" == *'xcrun simctl boot "$ipad_udid"'* ]] || return 1
  [[ "$restore_block" == *'xcrun simctl bootstatus "$ipad_udid" -b'* ]] || return 1
  handoff_call_line="$(grep -nF 'reset_simulator_ui_session_for_iphone' "$gate_path" | tail -n 1 | cut -d: -f1)"
  [[ -n "$handoff_call_line" ]] || return 1
  (( ipad_ui_line < handoff_call_line && handoff_call_line < iphone_ui_line ))
}

validate_iphone_ui_handoff_contract "$GATE_SCRIPT" ||
  fail "iPhone UI leg lacks a deterministic post-iPad simulator handoff"

# Prove the contract rejects a destination copy/paste regression, not just
# that the current source happens to contain the expected strings.
mutated_gate="$(mktemp "${TMPDIR:-/tmp}/gradus-gate-contract.XXXXXX")"
sed 's/platform=iOS Simulator,id=\$ipad_udid/platform=iOS Simulator,id=\$sim_udid/g' \
  "$GATE_SCRIPT" > "$mutated_gate"
if validate_ios_destination_contract "$mutated_gate"; then
  fail "destination contract accepted an iPad leg pointed at the iPhone simulator"
fi
rm -f "$mutated_gate"

# Prove the DerivedData check rejects a partial wiring regression rather than
# only recognizing the current source.
mutated_gate="$(mktemp "${TMPDIR:-/tmp}/gradus-derived-data-contract.XXXXXX")"
sed '/-derivedDataPath "\$derived_data_dir"/d' "$GATE_SCRIPT" > "$mutated_gate"
if validate_derived_data_contract "$mutated_gate"; then
  fail "DerivedData contract accepted an Xcode test leg without isolation"
fi
rm -f "$mutated_gate"

leg_count="${#COUNTING_LEG_NAMES[@]}"
[[ "$leg_count" -eq "$EXPECTED_COUNTING_LEG_COUNT" ]] ||
  fail "live expected count does not match live leg names"
[[ "${#COUNTING_LEG_MINIMUMS[@]}" -eq "$EXPECTED_COUNTING_LEG_COUNT" ]] ||
  fail "live expected count does not match live floors"
[[ "${#COUNTING_LEG_REPORTERS[@]}" -eq "$EXPECTED_COUNTING_LEG_COUNT" ]] ||
  fail "live expected count does not match live reporters"
[[ "${#COUNTING_LEG_SOURCES[@]}" -eq "$EXPECTED_COUNTING_LEG_COUNT" ]] ||
  fail "live expected count does not match live sources"

# The iPad leg also carries the 12 canonical image snapshots. Its aggregate
# floor must therefore include every image plus every shipped iOS UI test;
# otherwise the image count can hide a zero-test UI target.
snapshot_count="${#DENSITY_IMAGE_SNAPSHOT_TEST_SELECTORS[@]}"
ios_ui_test_count="$(rg --no-heading '^\s*func test' "$SCRIPT_DIR/GradusiOSUITests" -g '*.swift' | wc -l | tr -d ' ')"
[[ "$ios_ui_test_count" -eq 9 ]] ||
  fail "expected 9 GradusiOSUITests workflows, found $ios_ui_test_count"
ipad_leg_index=-1
iphone_ui_leg_index=-1
for ((index = 0; index < leg_count; index++)); do
  if [[ "${COUNTING_LEG_NAMES[index]}" == "GradusiOS-iPad" ]]; then
    ipad_leg_index="$index"
  fi
  if [[ "${COUNTING_LEG_NAMES[index]}" == "GradusiOSUI" ]]; then
    iphone_ui_leg_index="$index"
  fi
done
if [[ "$ipad_leg_index" -lt 0 ||
      "${COUNTING_LEG_MINIMUMS[ipad_leg_index]}" -lt $((snapshot_count + ios_ui_test_count)) ]]; then
  fail "iPad aggregate floor does not protect its UI target from snapshot masking"
fi
if [[ "$iphone_ui_leg_index" -lt 0 ||
      "${COUNTING_LEG_MINIMUMS[iphone_ui_leg_index]}" -lt "$ios_ui_test_count" ]]; then
  fail "dedicated iPhone UI floor does not protect its UI target"
fi

for ((index = 0; index < leg_count; index++)); do
  floor="${COUNTING_LEG_MINIMUMS[index]}"
  [[ "$floor" -gt 1 ]] || fail "${COUNTING_LEG_NAMES[index]} floor is not above a one-test placeholder"
done

# The new hermetic suites are part of the runner manifest, not merely present
# in the checkout. Check both the declared source and its counted invocation.
for ((index = 0; index < leg_count; index++)); do
  source_name="${COUNTING_LEG_SOURCES[index]}"
  if [[ "$source_name" == *.py ]]; then
    [[ -f "$SCRIPT_DIR/$source_name" ]] ||
      fail "declared hermetic source is missing: $source_name"
    grep -Fq "assert_counting_leg \"${COUNTING_LEG_NAMES[index]}\"" "$GATE_SCRIPT" ||
      fail "declared hermetic source has no counted invocation: $source_name"
  fi
done

# Target-level UI legs must remain explicit rather than hidden inside a broad
# scheme invocation.
grep -Fq -- "-only-testing:GradusMacUITests" "$GATE_SCRIPT" ||
  fail "Mac UI target-level selector is missing from the canonical gate"
grep -Fq -- "-only-testing:GradusiOSUITests" "$GATE_SCRIPT" ||
  fail "iOS UI target-level selector is missing from the canonical gate"

mac_ui_block="$(sed -n '/assert_counting_leg "GradusMacUI"/,/PROVISIONING_PROFILE_SPECIFIER=/p' "$GATE_SCRIPT")"
[[ "$mac_ui_block" == *'CODE_SIGN_IDENTITY="Apple Development"'* ]] ||
  fail "Mac UI runner must use an explicit development signing identity"
[[ "$mac_ui_block" == *'DEVELOPMENT_TEAM=4CJ49V6QHW'* ]] ||
  fail "Mac UI runner must pin the development team"
[[ "$mac_ui_block" == *'CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO'* ]] ||
  fail "Mac UI runner must disable base entitlement injection"
[[ "$mac_ui_block" != *'CODE_SIGNING_ALLOWED=NO'* ]] ||
  fail "Mac UI runner must not use the unsigned test path"

iphone_unit_block="$(sed -n '/assert_counting_leg "GradusiOS-iPhone"/,/CODE_SIGNING_ALLOWED=NO/p' "$GATE_SCRIPT")"
[[ "$iphone_unit_block" == *"-skip-testing:GradusiOSUITests"* ]] ||
  fail "iPhone unit leg must leave UI tests to their dedicated gate"
iphone_leg_index=-1
for ((index = 0; index < leg_count; index++)); do
  if [[ "${COUNTING_LEG_NAMES[index]}" == "GradusiOS-iPhone" ]]; then
    iphone_leg_index="$index"
  fi
done
[[ "$iphone_leg_index" -ge 0 && "${COUNTING_LEG_MINIMUMS[iphone_leg_index]}" -eq 171 ]] ||
  fail "iPhone integrated-gate floor must remain exactly 171"
iphone_ui_block="$(sed -n '/assert_counting_leg "GradusiOSUI"/,/CODE_SIGNING_ALLOWED=NO/p' "$GATE_SCRIPT")"
[[ "$iphone_ui_block" == *"-only-testing:GradusiOSUITests"* ]] ||
  fail "dedicated iPhone UI leg is missing its explicit selector"
grep -Fq -- "-destination 'platform=macOS,arch=arm64'" "$GATE_SCRIPT" ||
  fail "Mac UI leg must pin the Apple-silicon destination"
grep -Fq 'simulator_created=0' "$GATE_SCRIPT" ||
  fail "gate must track whether the iPhone simulator pre-existed"
grep -Fq 'ipad_simulator_created=0' "$GATE_SCRIPT" ||
  fail "gate must track whether the iPad simulator pre-existed"
grep -Fq 'Leaving pre-existing simulators running' "$GATE_SCRIPT" ||
  fail "gate must preserve pre-existing simulators"

# Every declared leg passes at its live floor, exercising all three reporter
# forms and proving the self-check is using the gate's data.
# shellcheck disable=SC2034
COUNTING_LEG_RUN_COUNT=0
for ((index = 0; index < leg_count; index++)); do
  assert_counting_leg \
    "${COUNTING_LEG_NAMES[index]}" \
    emit_report "${COUNTING_LEG_REPORTERS[index]}" "${COUNTING_LEG_MINIMUMS[index]}"
done
assert_counting_legs_complete || fail "all live counting legs did not complete"

# Zero and absent reporter counts must fail, including XCTest's successful
# zero-test transcript.
for ((index = 0; index < leg_count; index++)); do
  expect_failure \
    "${COUNTING_LEG_NAMES[index]} zero count" \
    assert_counting_leg "${COUNTING_LEG_NAMES[index]}" \
      emit_report "${COUNTING_LEG_REPORTERS[index]}" 0
  expect_failure \
    "${COUNTING_LEG_NAMES[index]} absent count" \
    assert_counting_leg "${COUNTING_LEG_NAMES[index]}" emit_absent_report
  below_floor=$((COUNTING_LEG_MINIMUMS[index] - 1))
  expect_failure \
    "${COUNTING_LEG_NAMES[index]} below-floor count" \
    assert_counting_leg "${COUNTING_LEG_NAMES[index]}" \
      emit_report "${COUNTING_LEG_REPORTERS[index]}" "$below_floor"
done

# A missing invocation is distinct from a zero-count invocation and must fail
# the expected-leg check.
# shellcheck disable=SC2034
COUNTING_LEG_RUN_COUNT=0
for ((index = 0; index < leg_count - 1; index++)); do
  assert_counting_leg \
    "${COUNTING_LEG_NAMES[index]}" \
    emit_report "${COUNTING_LEG_REPORTERS[index]}" "${COUNTING_LEG_MINIMUMS[index]}"
done
expect_failure "deleted counting leg" assert_counting_legs_complete

# Regression lock: `record()`'s per-pattern comparison must be numeric, not
# lexicographic (fixed 2026-08-13 -- see HISTORY.md). A smaller-magnitude
# match recorded first must not block a later larger-magnitude match from
# winning. The real GradusiOS-iPhone incident this locks in had "Executed 20
# tests" precede "Test run with 142 tests" in the same leg's captured output;
# a lexicographic `>` keeps "20" because '1' < '2'. No declared leg's mock
# emits out-of-order magnitudes today, so this exercises the awk logic
# directly against a synthetic transcript shaped like that incident.
emit_out_of_order_magnitudes() {
  printf 'Executed 20 tests\n** TEST SUCCEEDED **\nTest run with 142 tests in 3 suites.\n'
}
[[ "${COUNTING_LEG_NAMES[2]}" == "GradusMac" ]] ||
  fail "numeric-max regression lock assumes GradusMac is index 2; array order changed"
saved_gradusmac_floor="${COUNTING_LEG_MINIMUMS[2]}"
COUNTING_LEG_MINIMUMS[2]=100
assert_counting_leg "GradusMac" emit_out_of_order_magnitudes ||
  fail "record() picked the string-comparison-losing count (20) instead of the numeric max (142)"
COUNTING_LEG_MINIMUMS[2]="$saved_gradusmac_floor"

if [[ "$failure_count" -ne 0 ]]; then
  echo "FAIL: $failure_count test-gate self-check failure(s)" >&2
  exit 1
fi

echo "test-gate.sh counting-leg assertions passed"
