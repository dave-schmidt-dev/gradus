#!/usr/bin/env bash
# Capture the fixed Gradus review inventory on one disposable iPhone Simulator.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
PROJECT_PATH="${GRADUS_WALKTHROUGH_PROJECT_PATH:-$APP_DIR/Gradus.xcodeproj}"
ROUTES=(
  "icloud.discovery|fresh-account-discovery|icloud-account-discovery-status|fresh-account-discovery.png"
  "icloud.confirmation|legacy-awaiting-confirmation|Continue|legacy-awaiting-confirmation.png"
  "icloud.retry|temporary-retry|Try Again|temporary-retry.png"
  "icloud.no-account|no-account|Try Again|no-account.png"
  "icloud.restricted|restricted|Try Again|restricted.png"
  "sample.dashboard|sample-dashboard|sample-data-exit|sample-dashboard.png"
  "settings.off|settings-off|warning-alerts-toggle|settings-off.png"
  "settings.requesting|settings-requesting|Requesting warning-alert permission…|settings-requesting.png"
  "settings.denied|settings-denied|Open iOS Settings|settings-denied.png"
  "icloud.confirmation.result|legacy-continue-result|icloud-account-discovery-status|legacy-continue-result.png"
  "icloud.retry.result|temporary-retry-result|Try Again|temporary-retry-result.png"
  "icloud.no-account.result|no-account-retry-result|Try Again|no-account-retry-result.png"
  "icloud.restricted.result|restricted-retry-result|Try Again|restricted-retry-result.png"
  "sample.entry-progress|sample-entry-progress|explore-sample|sample-entry-progress.png"
  "sample.provider|sample-provider-detail|Sample Codex|sample-provider-detail.png"
  "sample.provider-back|sample-provider-back|sample-data-banner|sample-provider-back.png"
  "sample.reset-result|sample-reset-result|sample-data-banner|sample-reset-result.png"
  "sample.exit-result|sample-exit-result|Try Again|sample-exit-result.png"
  "sample.settings|sample-settings|sample-data-reset-settings|sample-settings.png"
  "sample.settings-reset|sample-settings-reset|sample-data-reset-settings|sample-settings-reset.png"
  "sample.settings-exit|sample-settings-exit|Try Again|sample-settings-exit.png"
  "settings.close-result|settings-close-result|settings-button|settings-close-result.png"
  "settings.sort-result|settings-sort-result|Name A-Z|settings-sort-result.png"
  "settings.exhausted-result|settings-show-exhausted-result|show-exhausted-toggle|settings-show-exhausted-result.png"
  "settings.threshold-result|settings-threshold-result|warning-threshold-slider|settings-threshold-result.png"
  "settings.permission-sheet|settings-warning-permission-sheet|notification-permission-sheet|settings-warning-permission-sheet.png"
  "settings.permission-denied|settings-warning-deny-result|Open iOS Settings|settings-warning-deny-result.png"
  "settings.permission-allowed|settings-warning-allow-result|warning-alerts-toggle|settings-warning-allow-result.png"
  "settings.denied-handoff|settings-denied-handoff|ios-settings-app|settings-denied-handoff.png"
  "settings.sort-reset-result|settings-sort-reset-result|Reset soonest|settings-sort-reset-result.png"
  "settings.automatic-result|settings-automatic-result|Automatic|settings-automatic-result.png"
  "settings.card-size-disabled|settings-card-size-disabled|Automatic · 1 column|settings-card-size-disabled.png"
  "settings.card-size-result|settings-card-size-result|Dashboard card size|settings-card-size-result.png"
  "settings.hide-exhausted-result|settings-hide-exhausted-result|show-exhausted-toggle|settings-hide-exhausted-result.png"
  "settings.alert-off-result|settings-alert-off-result|warning-alerts-toggle|settings-alert-off-result.png"
  "widget.current|widget-render-current|widget-current|widget-render-current.png"
  "widget.empty|widget-render-empty|widget-empty|widget-render-empty.png"
  "widget.unavailable|widget-render-unavailable|widget-unavailable|widget-render-unavailable.png"
  "widget.gallery|widget-system-gallery|Search Widgets|widget-system-gallery.png"
  "widget.add-surface|widget-system-add|Add Widget|widget-system-add.png"
  "widget.tap-result|widget-system-tap|explore-sample|widget-system-tap.png"
)

fail() { echo "FAIL: $*" >&2; exit 1; }
status() { echo "==> $*" >&2; }
usage() { echo "usage: capture-walkthrough.sh --output-dir DIRECTORY | --self-test" >&2; }

run_bounded_capture() {
  local label="$1" log="$2"
  shift 2
  "$@" >"$log" 2>&1 &
  local pid=$! elapsed=0 maximum="${GRADUS_WALKTHROUGH_CAPTURE_TIMEOUT_SECONDS:-180}"
  while kill -0 "$pid" 2>/dev/null; do
    if (( elapsed >= maximum )); then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      tail -n 80 "$log" >&2 || true
      status "$label timed out; the disposable Simulator will be removed"
      return 124
    fi
    sleep 5
    elapsed=$((elapsed + 5))
    status "$label still running (${elapsed}s)"
  done
  local result=0
  wait "$pid" || result=$?
  if (( result != 0 )); then
    tail -n 80 "$log" >&2 || true
  fi
  return "$result"
}

executed_test_count() {
  local result_bundle="$1"
  xcrun xcresulttool get test-results summary --path "$result_bundle" --compact | \
    /usr/bin/python3 -c '
import json, sys
try:
    count = json.load(sys.stdin).get("totalTestCount")
except (json.JSONDecodeError, OSError):
    raise SystemExit(1)
if isinstance(count, bool) or not isinstance(count, int) or count < 0:
    raise SystemExit(1)
print(count)
'
}

output_dir=""
self_test=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir) [[ $# -ge 2 ]] || { usage; exit 2; }; output_dir="$2"; shift 2 ;;
    --self-test) self_test=1; shift ;;
    *) usage; exit 2 ;;
  esac
done

if (( self_test )); then
  [[ -z "$output_dir" ]] || fail "--self-test cannot be combined with capture"
  total="${#ROUTES[@]}"
  for index in "${!ROUTES[@]}"; do
    IFS='|' read -r screen _fixture _marker _image <<< "${ROUTES[$index]}"
    status "capture-$((index + 1))-of-$total $screen"
  done
  echo "walkthrough-capture=self-test-only screenCount=$total statusCount=$total"
  exit 0
fi

[[ -n "$output_dir" ]] || { usage; exit 2; }
[[ -z "${GRADUS_SIMULATOR_UDID:-}" ]] || fail "persistent simulator selection is not supported"
[[ "${GRADUS_WALKTHROUGH_CAPTURE_TIMEOUT_SECONDS:-180}" =~ ^[1-9][0-9]*$ ]] || fail "capture timeout must be a positive integer"
start_at="${GRADUS_WALKTHROUGH_START_AT:-1}"
[[ "$start_at" =~ ^[1-9][0-9]*$ ]] || fail "diagnostic start index must be a positive integer"
mkdir -p "$output_dir"
output_dir="$(cd -- "$output_dir" && pwd -P)"
capture_root="$(mktemp -d "${TMPDIR:-/tmp}/gradus-walkthrough.XXXXXX")"
simulator_udid=""
cleanup() {
  if [[ -n "$simulator_udid" ]]; then
    xcrun simctl shutdown "$simulator_udid" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator_udid" >/dev/null 2>&1 || true
  fi
  rm -rf "$capture_root"
}
trap cleanup EXIT INT TERM

create_spec="$(xcrun simctl list --json | /usr/bin/python3 -c '
import json, re, sys
data=json.load(sys.stdin)
r=[x for x in data.get("runtimes",[]) if x.get("isAvailable") is True and x.get("platform")=="iOS"]
d=[x for x in data.get("devicetypes",[]) if x.get("isAvailable") is not False and str(x.get("name","")).startswith("iPhone")]
if not r or not d: raise SystemExit(1)
key=lambda x: tuple(int(v) for v in re.findall(r"\d+",x.get("version","")))
print(sorted(d,key=lambda x:(x.get("name","") != "iPhone 15",x.get("name","")))[0]["identifier"]+"\t"+max(r,key=key)["identifier"])
')" || fail "could not discover an available iPhone Simulator"
IFS=$'\t' read -r device_type runtime <<< "$create_spec"
simulator_udid="$(xcrun simctl create "Gradus walkthrough disposable $$" "$device_type" "$runtime")"
[[ "$simulator_udid" =~ ^[0-9A-Fa-f-]{36}$ ]] || fail "Simulator create returned an invalid identifier"
xcrun simctl boot "$simulator_udid"
xcrun simctl bootstatus "$simulator_udid" -b
xcrun simctl ui "$simulator_udid" appearance dark

total="${#ROUTES[@]}"
(( start_at <= total )) || fail "diagnostic start index exceeds the $total-route inventory"
for index in "${!ROUTES[@]}"; do
  (( index + 1 >= start_at )) || continue
  IFS='|' read -r screen fixture marker image <<< "${ROUTES[$index]}"
  screenshot="$output_dir/$image"
  status "capture-$((index + 1))-of-$total $screen"
  if [[ "$fixture" == widget-render-* ]]; then
    if [[ ! -s "$output_dir/widget-render-current.png" ]]; then
      log="$capture_root/widget-render.log"
      if ! run_bounded_capture "rendering deterministic widget states" "$log" env \
        TEST_RUNNER_GRADUS_WALKTHROUGH_WIDGET_OUTPUT="$output_dir" \
        xcodebuild test -project "$PROJECT_PATH" -scheme GradusiOS \
          -destination "platform=iOS Simulator,id=$simulator_udid" -parallel-testing-enabled NO \
          -maximum-parallel-testing-workers 1 \
          "-only-testing:GradusWidgetTests/exportWalkthroughWidgetStates()" \
          -resultBundlePath "$capture_root/widget-render.xcresult" CODE_SIGNING_ALLOWED=NO; then
        cp "$log" "$output_dir/widget-render-blocked.log" 2>/dev/null || true
        cp -R "$capture_root/widget-render.xcresult" "$output_dir/widget-render-blocked.xcresult" 2>/dev/null || true
        fail "widget rendering failed; evidence preserved at $output_dir/widget-render-blocked.log"
      fi
      widget_test_count="$(executed_test_count "$capture_root/widget-render.xcresult")" || widget_test_count=""
      if [[ -z "$widget_test_count" || "$widget_test_count" -lt 1 ]]; then
        cp "$log" "$output_dir/widget-render-blocked.log" 2>/dev/null || true
        cp -R "$capture_root/widget-render.xcresult" "$output_dir/widget-render-blocked.xcresult" 2>/dev/null || true
        fail "widget render executed zero tests; diagnostic evidence was preserved"
      fi
    fi
    [[ -s "$screenshot" ]] || fail "widget render produced no PNG for $screen"
    continue
  fi
  [[ ! -e "$screenshot" ]] || fail "refusing to overwrite $screenshot"
  if [[ "$fixture" == settings-warning-* ]]; then
    status "recreating disposable Simulator for isolated notification permission state"
    xcrun simctl shutdown "$simulator_udid" >/dev/null 2>&1 || true
    xcrun simctl delete "$simulator_udid" >/dev/null 2>&1 || true
    simulator_udid="$(xcrun simctl create "Gradus walkthrough permission $$ $index" "$device_type" "$runtime")"
    [[ "$simulator_udid" =~ ^[0-9A-Fa-f-]{36}$ ]] || fail "Simulator create returned an invalid identifier"
    xcrun simctl boot "$simulator_udid"
    xcrun simctl bootstatus "$simulator_udid" -b
    xcrun simctl ui "$simulator_udid" appearance dark
  fi
  log="$capture_root/$fixture.log"
  if ! run_bounded_capture "capture-$((index + 1))-of-$total $screen" "$log" env \
    TEST_RUNNER_GRADUS_WALKTHROUGH_FIXTURE="$fixture" \
    TEST_RUNNER_GRADUS_WALKTHROUGH_MARKER="$marker" \
    TEST_RUNNER_GRADUS_WALKTHROUGH_SCREENSHOT="$screenshot" \
    xcodebuild test -project "$PROJECT_PATH" -scheme GradusiOS \
      -destination "platform=iOS Simulator,id=$simulator_udid" -parallel-testing-enabled NO \
      -maximum-parallel-testing-workers 1 \
      -only-testing:GradusiOSUITests/WalkthroughCaptureXCUITests/testWalkthroughCapture \
      -resultBundlePath "$capture_root/$fixture.xcresult" CODE_SIGNING_ALLOWED=NO; then
    cp "$log" "$output_dir/$fixture-blocked.log" 2>/dev/null || true
    cp -R "$capture_root/$fixture.xcresult" "$output_dir/$fixture-blocked.xcresult" 2>/dev/null || true
    fail "capture failed for $screen; evidence preserved at $output_dir/$fixture-blocked.log"
  fi
  route_test_count="$(executed_test_count "$capture_root/$fixture.xcresult")" || route_test_count=""
  if [[ "$route_test_count" != "1" ]]; then
    cp "$log" "$output_dir/$fixture-blocked.log" 2>/dev/null || true
    cp -R "$capture_root/$fixture.xcresult" "$output_dir/$fixture-blocked.xcresult" 2>/dev/null || true
    fail "capture expected exactly one executed test, found ${route_test_count:-unreadable}; diagnostic evidence was preserved"
  fi
  if [[ ! -s "$screenshot" ]]; then
    cp "$log" "$output_dir/$fixture-blocked.log" 2>/dev/null || true
    cp -R "$capture_root/$fixture.xcresult" "$output_dir/$fixture-blocked.xcresult" 2>/dev/null || true
    fail "capture produced no PNG for $screen; evidence preserved at $output_dir/$fixture-blocked.log"
  fi
done

png_count="$(find "$output_dir" -type f -name '*.png' -size +0c | wc -l | tr -d ' ')"
expected_count=$((total - start_at + 1))
[[ "$png_count" == "$expected_count" ]] || fail "expected $expected_count nonempty PNGs, found $png_count"
echo "walkthrough-capture=passed screenCount=$expected_count pngCount=$png_count startAt=$start_at"
