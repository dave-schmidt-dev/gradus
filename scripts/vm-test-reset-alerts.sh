#!/usr/bin/env bash
# Focused, non-UI reset-alert tests for the profile-free macOS VM lane.
#
# Run scripts/vm-test-build.sh GradusMac first. The test host reads staged
# source, snapshot, and fixture resources outside ~/Documents; this command
# selects only reset-alert and commit-barrier tests from GradusMacTests.
#
# Environment:
#   VM_TEST_DERIVED_DATA  derived data path used by vm-test-build.sh

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
readonly PROJECT="${REPO_ROOT}/app/Gradus.xcodeproj"
readonly DERIVED_DATA="${VM_TEST_DERIVED_DATA:-${REPO_ROOT}/build/vm-test}"

readonly -a RESET_ALERT_TEST_SELECTORS=(
  "BankedObservationTests/parsesRealPythonWriterFixture()"
  "BankedObservationTests/derivesOnlyPublicSiblingPathsFromInjectedSnapshot()"
  "BankedObservationTests/rejectsMissingExtraWrongTypedAndUnboundedFields()"
  "BankedObservationTests/rejectsNaiveInvalidAndStaleTimestamps()"
  "BankedObservationWatcherTests/reportsAtomicReplacementAndRemovalButFiltersSiblingWrites()"
  "BackgroundAgentStateTests/newAgentCommitTokenDecodesWithoutAffectingOldStatus()"
  "ResetObservationPipelineTests/sidecarBeforeTerminalStatusJoinsExactlyOnce()"
  "ResetObservationPipelineTests/terminalStatusBeforeSidecarAddsCountWithoutSecondUsageEvaluation()"
  "ResetObservationPipelineTests/failureAndRollbackDiscardPendingEdge()"
  "ResetObservationPipelineTests/mismatchedOrOldStatusNeverCommitsInstalledSnapshot()"
  "ResetObservationPipelineTests/externalTimeoutCommitsOnceAndLateSidecarAugments()"
  "ResetObservationPipelineTests/supersededSnapshotAndLateOlderCountPreserveNewUsage()"
  "ResetObservationPipelineTests/cadenceDeferredSuccessDoesNotConsumeRefillEdge()"
  "ResetObservationPipelineTests/matchingSidecarGrantSurvivesNonfreshCodexUsage()"
  "ResetObservationPipelineTests/replayAfterICloudConfirmationPublishesWithoutReevaluating()"
  "resetPreferencesStartOffAndRemainIndependent()"
  "permissionPromptRunsOnlyAfterExplicitOptInAndHasRequestingState()"
  "optedInAlertNeedsCurrentSystemPermissionAndDoesNotChangeWarnings()"
  "bankedUnavailableRetainsOnlyLabeledLastObservation()"
  "sidecarWaitProgressIsVisibleButNeverRepeatsCallerDetail()"
  "attendedBackgroundAccessRunsOnlyFromAction()"
  "resetNotificationCopyAndSystemStatusMappingStayGeneric()"
  "delayedOlderSaveCannotFinishAfterNewerUsageAndLateBankedEvidence()"
  "staleUsageArrivalDoesNotReplaceSavedNewerSnapshot()"
  "backoffRetryCompletesBeforeNewerSnapshotSave()"
  "snapshotDataValidationAcceptsExactProducerKeys()"
  "snapshotDataValidationRejectsUnknownKeysAndOversizedValues()"
  "snapshotDataValidationRejectsNonFiniteNumbersAndOversizedAggregate()"
  "bankedAugmentationRequiresValidatedCodexEvidence()"
  "bankedAugmentationRejectsMalformedTriples()"
  "repeatedOversizeBankedFallbackHasStableContentHash()"
  "mismatchedBankedSidecarDoesNotAugmentRawStatus()"
)

if [[ ! -d "${DERIVED_DATA}/Build/Products" ]]; then
  echo "FAIL: no GradusMac test products under ${DERIVED_DATA}; run scripts/vm-test-build.sh GradusMac first" >&2
  exit 2
fi

stage_root=""
result_bundle=""
cleanup() {
  local status="$?"
  if [[ -n "${stage_root}" && -d "${stage_root}" ]]; then
    /bin/rm -rf -- "${stage_root}"
  fi
  if [[ -n "${result_bundle}" && -d "${result_bundle}" ]]; then
    if [[ "${status}" -eq 0 ]]; then
      /bin/rm -rf -- "${result_bundle}"
    else
      echo "    Failed result bundle preserved at ${result_bundle}" >&2
    fi
  fi
  return "${status}"
}
trap cleanup EXIT

stage_root="$(mktemp -d "${TMPDIR:-/private/tmp}/gradus-reset-alerts.XXXXXX")"
readonly INV7_SOURCE_ROOT="${stage_root}/inv7-source/GradusMac"
readonly SNAPSHOT_ROOT="${stage_root}/snapshots/__Snapshots__"
readonly BANKED_FIXTURE_PATH="${stage_root}/banked-observation-v1.json"

echo "==> staging GradusMac INV-7 source and snapshot resources" >&2
mkdir -p "${INV7_SOURCE_ROOT}" "${SNAPSHOT_ROOT}"
/usr/bin/ditto "${REPO_ROOT}/app/GradusMac/." "${INV7_SOURCE_ROOT}"
/usr/bin/ditto "${REPO_ROOT}/app/GradusMacTests/__Snapshots__/." "${SNAPSHOT_ROOT}"
/bin/cp "${REPO_ROOT}/tests/fixtures/banked-observation-v1.json" "${BANKED_FIXTURE_PATH}"
if [[ -z "$(find "${INV7_SOURCE_ROOT}" -type f -print -quit)" ||
      -z "$(find "${SNAPSHOT_ROOT}" -type f -print -quit)" ||
      ! -s "${BANKED_FIXTURE_PATH}" ]]; then
  echo "FAIL: could not stage non-empty Mac source, snapshots, and banked fixture" >&2
  exit 1
fi

only_testing_args=()
for selector in "${RESET_ALERT_TEST_SELECTORS[@]}"; do
  only_testing_args+=("-only-testing:GradusMacTests/${selector}")
done
result_bundle="${DERIVED_DATA}/GradusMacResetAlerts-${BASHPID:-$$}-${RANDOM}.xcresult"
if [[ -e "${result_bundle}" ]]; then
  echo "FAIL: result bundle path already exists: ${result_bundle}" >&2
  exit 1
fi

echo "==> running ${#RESET_ALERT_TEST_SELECTORS[@]} focused GradusMac test selectors" >&2
echo "    derived data: ${DERIVED_DATA}" >&2
echo "    UI automation: excluded" >&2
GRADUS_DISABLE_PIPELINE=1 \
  TZ="America/New_York" \
  TEST_RUNNER_TZ="America/New_York" \
  TEST_RUNNER_GRADUS_INV7_SOURCE_ROOT="${INV7_SOURCE_ROOT}" \
  TEST_RUNNER_GRADUS_SNAPSHOT_ROOT="${SNAPSHOT_ROOT}" \
  TEST_RUNNER_GRADUS_BANKED_FIXTURE_PATH="${BANKED_FIXTURE_PATH}" \
  xcodebuild test-without-building \
    -project "${PROJECT}" \
    -scheme GradusMac \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "${DERIVED_DATA}" \
    -resultBundlePath "${result_bundle}" \
    "${only_testing_args[@]}"

if [[ ! -d "${result_bundle}" ]]; then
  echo "FAIL: xcodebuild returned without creating a result bundle" >&2
  exit 1
fi

summary_json="${stage_root}/result-summary.json"
echo "==> confirming XCTest executed every selected test" >&2
xcrun xcresulttool get test-results summary --path "${result_bundle}" --compact >"${summary_json}"
/usr/bin/python3 - "${summary_json}" "${#RESET_ALERT_TEST_SELECTORS[@]}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as summary_file:
    summary = json.load(summary_file)
minimum = int(sys.argv[2])

def count(field):
    value = summary.get(field)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise SystemExit(f"FAIL: xcresult summary has invalid {field}: {value!r}")
    return value

total = count("totalTestCount")
passed = count("passedTests")
failed = count("failedTests")
skipped = count("skippedTests")
expected_failures = count("expectedFailures")
print(
    f"GradusMac reset-alert results: total={total} passed={passed} "
    f"failed={failed} skipped={skipped} expected_failures={expected_failures}"
)
if total < minimum or passed == 0:
    raise SystemExit(
        f"FAIL: expected at least {minimum} selected tests and one pass; "
        f"xcresult reports total={total}, passed={passed}"
    )
if failed != 0:
    raise SystemExit(f"FAIL: xcresult reports {failed} failed tests")
PY

echo "==> focused GradusMac reset-alert tests passed" >&2
