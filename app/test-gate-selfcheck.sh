#!/usr/bin/env bash
# Hermetic tests for the counting-leg assertion in test-gate.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

source "$GATE_SCRIPT"
validate_counting_leg_declarations || fail "live counting-leg declarations are invalid"

leg_count="${#COUNTING_LEG_NAMES[@]}"
[[ "$leg_count" -eq "$EXPECTED_COUNTING_LEG_COUNT" ]] ||
  fail "live expected count does not match live leg names"
[[ "${#COUNTING_LEG_MINIMUMS[@]}" -eq "$EXPECTED_COUNTING_LEG_COUNT" ]] ||
  fail "live expected count does not match live floors"
[[ "${#COUNTING_LEG_REPORTERS[@]}" -eq "$EXPECTED_COUNTING_LEG_COUNT" ]] ||
  fail "live expected count does not match live reporters"

for ((index = 0; index < leg_count; index++)); do
  floor="${COUNTING_LEG_MINIMUMS[index]}"
  [[ "$floor" -gt 1 ]] || fail "${COUNTING_LEG_NAMES[index]} floor is not above a one-test placeholder"
done

# Every declared leg passes at its live floor, exercising all three reporter
# forms and proving the self-check is using the gate's data.
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
COUNTING_LEG_RUN_COUNT=0
for ((index = 0; index < leg_count - 1; index++)); do
  assert_counting_leg \
    "${COUNTING_LEG_NAMES[index]}" \
    emit_report "${COUNTING_LEG_REPORTERS[index]}" "${COUNTING_LEG_MINIMUMS[index]}"
done
expect_failure "deleted counting leg" assert_counting_legs_complete

if [[ "$failure_count" -ne 0 ]]; then
  echo "FAIL: $failure_count test-gate self-check failure(s)" >&2
  exit 1
fi

echo "test-gate.sh counting-leg assertions passed"
