#!/usr/bin/env bash
# Focused iOS reset-alert behavior tests for the profile-free VM lane.
# Build first with scripts/vm-test-build.sh GradusiOS using the same derived data
# and VM_TEST_SIM_UDID. No snapshot/pixel tests or live accounts are selected.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
readonly PROJECT="${REPO_ROOT}/app/Gradus.xcodeproj"
readonly DERIVED_DATA="${VM_TEST_DERIVED_DATA:-${REPO_ROOT}/build/vm-test}"

readonly -a RESET_ALERT_TEST_SELECTORS=(
  "GradusiOSTests/fullAndDeltaSyncDetectRefillsAndLateSameTimestampBankedGrant()"
  "GradusiOSTests/missingAndStaleBankedKeysStayUnavailableUntilLaterIncrease()"
  "GradusiOSTests/replayAndRestartKeepRefillCursorAndAllowSecondRealLowEdge()"
  "GradusiOSTests/nilDeadlineRefillUsesSourceTimeAndAlertsOnlyOnce()"
  "GradusiOSTests/delayedDeliveryDoesNotUseDeviceClockForElapsedDeadline()"
  "GradusiOSTests/resetConsentAndSystemAuthorizationGateDeliveryIndependently()"
  "GradusiOSTests/authorizedResetDeliveryRespectsEachIndependentOptIn()"
  "GradusiOSTests/secondResetOptInKeepsSharedPermissionRequestLive()"
  "GradusiOSTests/resetAlertsCopyNamesCoverageAndMobileDelivery()"
  "GradusiOSUITests/DashboardXCUITests/testResetAlertsOffExplainsIndependentControlsAndMobileDelivery"
  "GradusiOSUITests/DashboardXCUITests/testResetAlertsOnShowsBothEnabled"
  "GradusiOSUITests/DashboardXCUITests/testResetAlertsRequestingShowsProgressWithoutSystemPrompt"
  "GradusiOSUITests/DashboardXCUITests/testResetAlertsDeniedShowsRecovery"
)

resolve_simulator() {
  local requested="${VM_TEST_SIM_UDID:-}"
  xcrun simctl list devices available --json |
    /usr/bin/python3 -c '
import json
import sys

requested = sys.argv[1]
devices = json.load(sys.stdin)["devices"]
runtimes = sorted(key for key in devices if "iOS" in key)
for runtime in reversed(runtimes):
    for device in devices[runtime]:
        if not device.get("isAvailable"):
            continue
        if not requested or device.get("udid") == requested:
            print(device["udid"])
            sys.exit(0)
raise SystemExit("FAIL: no available iOS simulator matches VM_TEST_SIM_UDID")
' "${requested}"
}

if [[ ! -d "${DERIVED_DATA}/Build/Products/Debug-iphonesimulator" ]]; then
  echo "FAIL: no GradusiOS test products under ${DERIVED_DATA}; run scripts/vm-test-build.sh GradusiOS first" >&2
  exit 2
fi

sim_udid="$(resolve_simulator)"
[[ "${sim_udid}" =~ ^[0-9A-Fa-f-]{36}$ ]] || {
  echo "FAIL: simulator resolver returned an invalid UDID" >&2
  exit 1
}

stage_root="$(mktemp -d "${TMPDIR:-/private/tmp}/gradus-ios-reset-alerts.XXXXXX")"
result_bundle="${stage_root}/reset-alerts.xcresult"
cleanup() {
  local status="$?"
  if (( status == 0 )); then
    /bin/rm -rf -- "${stage_root}"
  else
    echo "    Failed result bundle and summary preserved at ${stage_root}" >&2
  fi
  return "${status}"
}
trap cleanup EXIT

only_testing_args=()
for selector in "${RESET_ALERT_TEST_SELECTORS[@]}"; do
  only_testing_args+=("-only-testing:${selector}")
done

echo "==> running ${#RESET_ALERT_TEST_SELECTORS[@]} focused iOS reset-alert tests" >&2
echo "    simulator: ${sim_udid}" >&2
echo "    derived data: ${DERIVED_DATA}" >&2
echo "    pixel snapshots: excluded" >&2
xcodebuild test-without-building \
  -project "${PROJECT}" \
  -scheme GradusiOS \
  -destination "platform=iOS Simulator,id=${sim_udid}" \
  -parallel-testing-enabled NO \
  -derivedDataPath "${DERIVED_DATA}" \
  -resultBundlePath "${result_bundle}" \
  "${only_testing_args[@]}"

[[ -d "${result_bundle}" ]] || {
  echo "FAIL: xcodebuild returned without creating a result bundle" >&2
  exit 1
}

summary_json="${stage_root}/result-summary.json"
echo "==> confirming XCTest executed every selected test" >&2
xcrun xcresulttool get test-results summary --path "${result_bundle}" --compact >"${summary_json}"
/usr/bin/python3 - "${summary_json}" "${#RESET_ALERT_TEST_SELECTORS[@]}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as summary_file:
    summary = json.load(summary_file)
expected = int(sys.argv[2])

def count(field):
    value = summary.get(field)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise SystemExit(f"FAIL: xcresult summary has invalid {field}: {value!r}")
    return value

total = count("totalTestCount")
passed = count("passedTests")
failed = count("failedTests")
skipped = count("skippedTests")
print(f"GradusiOS reset-alert results: total={total} passed={passed} failed={failed} skipped={skipped}")
if total < expected or passed < expected or failed or skipped:
    raise SystemExit(
        f"FAIL: expected {expected} selected tests to run and pass; "
        f"xcresult reports total={total}, passed={passed}, failed={failed}, skipped={skipped}"
    )
PY

echo "==> focused iOS reset-alert behavior tests passed" >&2
