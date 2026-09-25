#!/usr/bin/env bash
# Focused, offscreen Mac image-snapshot gate with a process-wide pinned timezone.
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_TIME_ZONE="America/New_York"
TIMEOUT_SECONDS="${GRADUS_MAC_SNAPSHOT_TIMEOUT_SECONDS:-300}"
DERIVED_DATA_PATH="${GRADUS_MAC_SNAPSHOT_DERIVED_DATA_PATH:-}"

if ! [[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "FAIL: GRADUS_MAC_SNAPSHOT_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi

original_tz_is_set=0
original_tz=""
if [[ -n "${TZ+x}" ]]; then
  original_tz_is_set=1
  original_tz="$TZ"
fi

stage_root="$(mktemp -d "${TMPDIR:-/private/tmp}/gradus-mac-snapshots.XXXXXX")"
if [[ -z "$DERIVED_DATA_PATH" ]]; then
  DERIVED_DATA_PATH="$stage_root/DerivedData"
fi
output_file="$stage_root/xcodebuild.log"

cleanup() {
  rm -rf "$stage_root"
}
trap cleanup EXIT INT TERM

snapshot_root="$stage_root/__Snapshots__"
mkdir -p "$snapshot_root"
/usr/bin/ditto "$SCRIPT_DIR/GradusMacTests/__Snapshots__/." "$snapshot_root"
if [[ -z "$(find "$snapshot_root" -type f -name '*.png' -print -quit)" ]]; then
  echo "FAIL: staged Mac snapshot baseline directory is empty" >&2
  exit 1
fi

selectors=(
  "GradusMacTests/menuMixedWindowCountsShareTheBarLeadingEdge()"
  "GradusMacTests/menuProviderListRendersBothFitAndOverflowArms()"
  "GradusMacTests/providerListViewRendersFromFixtureData()"
  "GradusMacTests/providerListViewRendersEveryRampLevel()"
  "GradusMacTests/providerListViewRendersEveryRampLevelOnTheDarkPanel()"
  "GradusMacTests/providerListViewRendersEmptyState()"
  "GradusMacTests/providerListViewReportsPinnedTestTimezone()"
  "GradusMacTests/macSettingsResetAlertsOnLight()"
  "GradusMacTests/macSettingsResetAlertsOnDark()"
  "GradusMacTests/macSettingsResetAlertsRequestingLight()"
  "GradusMacTests/macSettingsResetAlertsRequestingDark()"
  "GradusMacTests/macSettingsResetAlertsDeniedLight()"
  "GradusMacTests/macSettingsResetAlertsDeniedDark()"
)
selector_args=()
for selector in "${selectors[@]}"; do
  selector_args+=("-only-testing:$selector")
done

# Reuse the release gate's process-tree deadline implementation. Sourcing the
# gate is side-effect free and leaves the caller's options and directory intact.
# shellcheck source=./test-gate.sh
source "$SCRIPT_DIR/test-gate.sh"

echo "==> Staged ${#selectors[@]} focused Mac snapshot/timezone tests"
echo "==> Child timezone: $SNAPSHOT_TIME_ZONE; deadline: ${TIMEOUT_SECONDS}s"
(
  cd "$SCRIPT_DIR"
  run_with_deadline "$TIMEOUT_SECONDS" "focused Mac snapshots" env \
    TZ="$SNAPSHOT_TIME_ZONE" \
    TEST_RUNNER_TZ="$SNAPSHOT_TIME_ZONE" \
    TEST_RUNNER_GRADUS_SNAPSHOT_ROOT="$snapshot_root" \
    GRADUS_DISABLE_PIPELINE=1 \
    xcodebuild test \
    -project Gradus.xcodeproj \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -scheme GradusMac \
    -destination 'platform=macOS,arch=arm64' \
    "${selector_args[@]}" \
    CODE_SIGNING_ALLOWED=NO
) 2>&1 | tee "$output_file"

reported_count="$(awk '
  match($0, /Test run with [0-9]+ tests?/) {
    value = substr($0, RSTART, RLENGTH)
    gsub(/[^0-9]/, "", value)
    if (value + 0 > maximum) maximum = value + 0
  }
  END { if (maximum) print maximum }
' "$output_file")"
if [[ -z "$reported_count" || "$reported_count" -ne "${#selectors[@]}" ]]; then
  echo "FAIL: focused Mac snapshot selectors reported ${reported_count:-0} tests; expected exactly ${#selectors[@]}" >&2
  exit 1
fi
if ! grep -Fq "GRADUS_EFFECTIVE_TIME_ZONE=$SNAPSHOT_TIME_ZONE" "$output_file"; then
  echo "FAIL: focused Mac test child did not report $SNAPSHOT_TIME_ZONE" >&2
  exit 1
fi
if [[ "$original_tz_is_set" -eq 1 ]]; then
  [[ "${TZ:-}" == "$original_tz" ]] || {
    echo "FAIL: parent TZ changed during focused Mac snapshots" >&2
    exit 1
  }
else
  [[ -z "${TZ+x}" ]] || {
    echo "FAIL: focused Mac snapshots introduced TZ into the parent shell" >&2
    exit 1
  }
fi

echo "focused Mac snapshots passed: $reported_count test(s), child timezone $SNAPSHOT_TIME_ZONE"
