#!/usr/bin/env bash
# Records only the six named Mac Settings reset-alert snapshots into the checkout.
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd)"
TEST_DIR="$APP_DIR/GradusMacTests"
SOURCE_ROOT="$TEST_DIR/__Snapshots__"
SETTINGS_SOURCE="$SOURCE_ROOT/MacSettingsSnapshotTests"
TIMEOUT_SECONDS="${GRADUS_MAC_SNAPSHOT_TIMEOUT_SECONDS:-300}"
DERIVED_DATA_PATH="${GRADUS_MAC_SNAPSHOT_DERIVED_DATA_PATH:-}"
EXPECTED_EXISTING_BASELINES=7

if ! [[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "FAIL: GRADUS_MAC_SNAPSHOT_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi

expected_files=(
  "macSettingsResetAlertsOnLight.1.png"
  "macSettingsResetAlertsOnDark.1.png"
  "macSettingsResetAlertsRequestingLight.1.png"
  "macSettingsResetAlertsRequestingDark.1.png"
  "macSettingsResetAlertsDeniedLight.1.png"
  "macSettingsResetAlertsDeniedDark.1.png"
)
selectors=(
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

if [[ ! -d "$SOURCE_ROOT" ]]; then
  echo "FAIL: existing Mac snapshot baselines are missing: $SOURCE_ROOT" >&2
  exit 1
fi

# Refuse an unreviewed baseline set. The existing seven images are retained
# byte-for-byte; this helper adds only the six explicitly named Settings files.
baseline_manifest() {
  local root="$1"
  (
    cd "$root"
    find . -type f -name '*.png' ! -path './MacSettingsSnapshotTests/*' -print \
      | LC_ALL=C sort \
      | while IFS= read -r path; do shasum -a 256 "$path"; done
  )
}

existing_manifest="$(baseline_manifest "$SOURCE_ROOT")"
existing_count="$(printf '%s\n' "$existing_manifest" | awk 'NF { count += 1 } END { print count + 0 }')"
if [[ "$existing_count" -ne "$EXPECTED_EXISTING_BASELINES" ]]; then
  echo "FAIL: found $existing_count existing Mac PNG baselines; expected exactly $EXPECTED_EXISTING_BASELINES" >&2
  exit 1
fi

if [[ -d "$SETTINGS_SOURCE" ]]; then
  for path in "$SETTINGS_SOURCE"/*; do
    [[ -e "$path" ]] || continue
    name="${path##*/}"
    allowed=0
    for expected in "${expected_files[@]}"; do
      [[ "$name" == "$expected" ]] && allowed=1
    done
    if [[ "$allowed" -ne 1 || ! -f "$path" ]]; then
      echo "FAIL: unexpected existing Mac Settings baseline: $path" >&2
      exit 1
    fi
  done
fi

stage_root="$(mktemp -d "${TMPDIR:-/private/tmp}/gradus-mac-settings-record.XXXXXX")"
if [[ -z "$DERIVED_DATA_PATH" ]]; then
  DERIVED_DATA_PATH="$stage_root/DerivedData"
fi
output_file="$stage_root/xcodebuild.log"
result_bundle="$stage_root/record.xcresult"
summary_file="$stage_root/test-summary.json"
trap 'rm -rf "$stage_root"' EXIT INT TERM

snapshot_root="$stage_root/__Snapshots__"
mkdir -p "$snapshot_root/MacSettingsSnapshotTests"
/usr/bin/ditto "$SOURCE_ROOT/." "$snapshot_root"

# shellcheck source=../test-gate.sh
source "$APP_DIR/test-gate.sh"

echo "==> Recording ${#selectors[@]} named Mac Settings reset-alert snapshots"
echo "==> Existing baselines: $existing_count; deadline: ${TIMEOUT_SECONDS}s"
test_status=0
(
  cd "$APP_DIR"
  run_with_deadline "$TIMEOUT_SECONDS" "record Mac Settings snapshots" env \
    TZ="America/New_York" \
    TEST_RUNNER_TZ="America/New_York" \
    TEST_RUNNER_GRADUS_SNAPSHOT_ROOT="$snapshot_root" \
    GRADUS_DISABLE_PIPELINE=1 \
    xcodebuild test \
    -project Gradus.xcodeproj \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -scheme GradusMac \
    -destination 'platform=macOS,arch=arm64' \
    -parallel-testing-enabled NO \
    -resultBundlePath "$result_bundle" \
    "${selector_args[@]}" \
    'OTHER_SWIFT_FLAGS=$(inherited) -D MAC_SETTINGS_SNAPSHOT_RECORD' \
    CODE_SIGNING_ALLOWED=NO
) 2>&1 | tee "$output_file" || test_status=$?

if [[ "$test_status" -ne 0 && "$test_status" -ne 65 ]]; then
  echo "FAIL: Mac Settings recorder exited $test_status (only expected XCTest snapshot-recording failure 65 is accepted)" >&2
  exit "$test_status"
fi
if [[ ! -d "$result_bundle" ]]; then
  echo "FAIL: xcodebuild did not produce the Mac Settings result bundle" >&2
  exit 1
fi
xcrun xcresulttool get test-results summary --path "$result_bundle" --compact > "$summary_file"
python3 - "$summary_file" "$test_status" <<'PY'
import json
import sys

summary_path, raw_status = sys.argv[1:]
status = int(raw_status)
summary = json.load(open(summary_path, encoding="utf-8"))
expected_names = {
    "macSettingsResetAlertsOnLight()",
    "macSettingsResetAlertsOnDark()",
    "macSettingsResetAlertsRequestingLight()",
    "macSettingsResetAlertsRequestingDark()",
    "macSettingsResetAlertsDeniedLight()",
    "macSettingsResetAlertsDeniedDark()",
}
if summary.get("totalTestCount") != len(expected_names):
    raise SystemExit(f"FAIL: result bundle reports {summary.get('totalTestCount')} tests; expected {len(expected_names)}")
if summary.get("result") != "Failed":
    raise SystemExit(f"FAIL: record mode result was {summary.get('result')!r}; expected only the six explicit recording issues")
if summary.get("passedTests") != 0 or summary.get("failedTests") != len(expected_names):
    raise SystemExit(
        "FAIL: record mode must report exactly six snapshot-recording test issues; "
        f"passed={summary.get('passedTests')} failed={summary.get('failedTests')}"
    )
if summary.get("skippedTests") != 0 or summary.get("expectedFailures") != 0:
    raise SystemExit("FAIL: Mac Settings recording skipped or expected-failure tests")
if status not in (0, 65):
    raise SystemExit(f"FAIL: unexpected xcodebuild exit status {status}")

failures = summary.get("testFailures") or []
if len(failures) != len(expected_names):
    raise SystemExit(f"FAIL: result bundle contains {len(failures)} test failure issues; expected {len(expected_names)}")
seen = set()
marker = "Record mode is on. Automatically recorded snapshot:"
for failure in failures:
    name = failure.get("testName", "")
    if failure.get("targetName") != "GradusMacTests":
        raise SystemExit(f"FAIL: snapshot-recording issue came from unexpected target {failure.get('targetName')!r}")
    matches = [expected for expected in expected_names if name.endswith(expected)]
    if len(matches) != 1:
        raise SystemExit(f"FAIL: unexpected recorded failure belongs to {name!r}")
    test_name = matches[0]
    if test_name in seen:
        raise SystemExit(f"FAIL: duplicate failure issue for {test_name}")
    seen.add(test_name)
    message = failure.get("failureText", "")
    if message.count(marker) != 1:
        raise SystemExit(f"FAIL: {test_name} did not report exactly one expected snapshot-recording issue")
    if "Automatically recorded snapshot" not in message:
        raise SystemExit(f"FAIL: {test_name} failure was not caused by snapshot recording")
if seen != expected_names:
    raise SystemExit(f"FAIL: missing recorded test cases: {sorted(expected_names - seen)}")
if summary.get("runtimeWarnings"):
    raise SystemExit(f"FAIL: result bundle contains runtime warnings: {summary['runtimeWarnings']}")

print("Mac Settings record result: all six selected cases ran and each reported only its expected recording issue")
PY

if ! grep -Fq 'GRADUS_EFFECTIVE_TIME_ZONE=America/New_York' "$output_file"; then
  echo "FAIL: Mac Settings snapshot tests did not report the pinned timezone" >&2
  exit 1
fi

staged_settings="$snapshot_root/MacSettingsSnapshotTests"
for expected in "${expected_files[@]}"; do
  image="$staged_settings/$expected"
  if [[ ! -f "$image" ]] || ! /usr/bin/file "$image" | grep -Fq 'PNG image data'; then
    echo "FAIL: expected recorded PNG is missing or invalid: $expected" >&2
    exit 1
  fi
  dimensions="$(/usr/bin/sips -g pixelWidth -g pixelHeight "$image")"
  if ! grep -Fq 'pixelWidth: 460' <<<"$dimensions" || ! grep -Fq 'pixelHeight: 1600' <<<"$dimensions"; then
    echo "FAIL: recorded snapshot has unexpected dimensions: $expected" >&2
    exit 1
  fi
done
actual_settings_count="$(find "$staged_settings" -type f -print | wc -l | tr -d '[:space:]')"
if [[ "$actual_settings_count" -ne "${#expected_files[@]}" ]]; then
  echo "FAIL: staged Mac Settings directory contains $actual_settings_count files; expected exactly ${#expected_files[@]}" >&2
  exit 1
fi
if [[ "$(baseline_manifest "$snapshot_root")" != "$existing_manifest" ]]; then
  echo "FAIL: recording changed one or more of the seven existing Mac snapshot baselines" >&2
  exit 1
fi

# Source mutation occurs only after every focused test, count, timezone, file,
# dimension, and retained-baseline check passes. Copy explicit filenames only.
mkdir -p "$SETTINGS_SOURCE"
for expected in "${expected_files[@]}"; do
  /bin/cp -p "$staged_settings/$expected" "$SETTINGS_SOURCE/$expected"
done

final_count="$(find "$SOURCE_ROOT" -type f -name '*.png' -print | wc -l | tr -d '[:space:]')"
if [[ "$final_count" -ne "$((EXPECTED_EXISTING_BASELINES + ${#expected_files[@]}))" ]]; then
  echo "FAIL: source now contains $final_count Mac PNG baselines; expected $((EXPECTED_EXISTING_BASELINES + ${#expected_files[@]}))" >&2
  exit 1
fi
if [[ "$(baseline_manifest "$SOURCE_ROOT")" != "$existing_manifest" ]]; then
  echo "FAIL: one or more of the seven existing Mac snapshot baselines changed" >&2
  exit 1
fi

echo "recorded Mac Settings reset-alert snapshots: ${#expected_files[@]}; preserved existing baselines: $existing_count"
