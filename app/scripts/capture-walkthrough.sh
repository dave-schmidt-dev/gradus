#!/usr/bin/env bash
# Capture the fixed Gradus review inventory on one disposable iPhone Simulator.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
APP_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
PROJECT_PATH="${GRADUS_WALKTHROUGH_PROJECT_PATH:-$APP_DIR/Gradus.xcodeproj}"
APPLE_UI_TEST_LOCK="${APPLE_UI_TEST_LOCK:-$HOME/.agent/bin/apple-ui-test-lock}"
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
  "settings.reset-alerts-off|reset-alerts-off|reset-alerts-banked-toggle|reset-alerts-off.png"
  "settings.reset-alerts-on|reset-alerts-on|reset-alerts-refill-toggle|reset-alerts-on.png"
  "settings.reset-alerts-requesting|reset-alerts-requesting|reset-alerts-permission-requesting|reset-alerts-requesting.png"
  "settings.reset-alerts-denied|reset-alerts-denied|reset-alerts-permission-denied|reset-alerts-denied.png"
)

fail() { echo "FAIL: $*" >&2; exit 1; }
status() { echo "==> $*" >&2; }
usage() { echo "usage: capture-walkthrough.sh --output-dir DIRECTORY | --self-test" >&2; }

sweep_stale_walkthrough_directories() {
  local tmp_root="${TMPDIR:-/tmp}" uid candidate owner recent foreign open_output open_status
  [[ -d "$tmp_root" && ! -L "$tmp_root" ]] || return 0
  tmp_root="$(cd -P "$tmp_root" && pwd -P)" || return 0
  command -v lsof >/dev/null 2>&1 || return 0
  uid="$(id -u)" || return 0
  while IFS= read -r -d '' candidate; do
    [[ ! -L "$candidate" ]] || continue
    owner="$(stat -f '%u' "$candidate" 2>/dev/null)" || continue
    [[ "$owner" == "$uid" ]] || continue
    if recent="$(find "$candidate" -mmin -1440 -print -quit 2>/dev/null)"; then
      [[ -z "$recent" ]] || continue
    else
      continue
    fi
    if foreign="$(find "$candidate" ! -uid "$uid" -print -quit 2>/dev/null)"; then
      [[ -z "$foreign" ]] || continue
    else
      continue
    fi
    status "Checking stale walkthrough directory for open files: $candidate"
    if open_output="$(lsof -t +D "$candidate" 2>&1)"; then
      continue
    else
      open_status=$?
    fi
    [[ "$open_status" -eq 1 && -z "$open_output" ]] || continue
    if rm -rf "$candidate" 2>/dev/null; then
      status "Removed stale walkthrough directory: $candidate"
    fi
  done < <(find "$tmp_root" -mindepth 1 -maxdepth 1 -type d -name 'gradus-walkthrough.*' -print0 2>/dev/null)
}

active_capture_pid=""
active_clone_snapshot=""
active_clone_source_name=""

terminate_capture_group() {
  local pid="$1" attempt=0
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  while (( attempt < 10 )) && kill -0 -- "-$pid" 2>/dev/null; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  if kill -0 -- "-$pid" 2>/dev/null; then
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  fi
  wait "$pid" 2>/dev/null || true
  active_capture_pid=""
}

terminate_capture_on_signal() {
  local exit_status="$1"
  trap '' INT TERM
  if [[ -n "$active_capture_pid" ]]; then
    terminate_capture_group "$active_capture_pid"
  fi
  if [[ -n "$active_clone_snapshot" ]]; then
    reap_interrupted_capture_clones "$active_clone_snapshot" "$active_clone_source_name" || \
      status "interrupted XCTest clone cleanup failed; inspect the XCTestDevices set"
    rm -f "$active_clone_snapshot"
    active_clone_snapshot=""
    active_clone_source_name=""
  fi
  exit "$exit_status"
}

run_bounded_capture() {
  local label="$1" log="$2"
  shift 2
  local set_root="${GATE_XCTEST_DEVICE_SET:-$HOME/Library/Developer/XCTestDevices}"
  local clone_snapshot
  clone_snapshot="$(mktemp "${TMPDIR:-/tmp}/gradus-xctest-snapshot.XXXXXX")"
  if ! _gate_lib_snapshot_clones "$set_root" >"$clone_snapshot"; then
    rm -f "$clone_snapshot"
    echo "FAIL: could not snapshot XCTest clones before $label" >&2
    return 1
  fi
  active_clone_snapshot="$clone_snapshot"
  active_clone_source_name="$simulator_name"
  local monitor_was_enabled=0
  [[ "$-" == *m* ]] && monitor_was_enabled=1
  set -m
  "$@" >"$log" 2>&1 &
  local pid=$! elapsed=0 maximum="${GRADUS_WALKTHROUGH_CAPTURE_TIMEOUT_SECONDS:-180}"
  active_capture_pid="$pid"
  (( monitor_was_enabled )) || set +m
  while kill -0 "$pid" 2>/dev/null; do
    if (( elapsed >= maximum )); then
      terminate_capture_group "$pid"
      local clone_cleanup_result=0
      reap_interrupted_capture_clones "$clone_snapshot" "$simulator_name" || clone_cleanup_result=$?
      rm -f "$clone_snapshot"
      active_clone_snapshot=""
      active_clone_source_name=""
      tail -n 80 "$log" >&2 || true
      status "$label timed out; the disposable Simulator will be removed"
      if (( clone_cleanup_result != 0 )); then
        status "interrupted XCTest clone cleanup failed; inspect the XCTestDevices set"
        return 125
      fi
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
    (( elapsed % 5 == 0 )) && status "$label still running (${elapsed}s)"
  done
  local result=0
  wait "$pid" || result=$?
  active_capture_pid=""
  rm -f "$clone_snapshot"
  active_clone_snapshot=""
  active_clone_source_name=""
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
sweep_stale_walkthrough_directories
capture_root="$(mktemp -d "${TMPDIR:-/tmp}/gradus-walkthrough.XXXXXX")"
simulator_udid=""
cleanup() {
  rm -rf "$capture_root"
}
trap cleanup EXIT
trap 'terminate_capture_on_signal 130' INT
trap 'terminate_capture_on_signal 143' TERM
# Source after the EXIT trap so the shared library composes simulator cleanup
# with removal of this script's temporary capture directory.
# shellcheck source=/dev/null
source "/Users/dave/Documents/Projects/apple_developer/release_tools/templates/simctl_gate_lib.sh"

reap_interrupted_capture_clones() {
  local before="$1"
  local source_name="$2"
  local set_root="${GATE_XCTEST_DEVICE_SET:-$HOME/Library/Developer/XCTestDevices}"
  [[ -d "$set_root" ]] || return 0
  local end_ts locked_command
  end_ts="$(date +%s)" || return 1
  locked_command=""
  IFS= read -r -d '' locked_command <<'EOF' || true
set -euo pipefail
source "$1"
_gate_lib_reap_new_clones "$2" "$3" "$4"
source_name="$5"
[[ "$source_name" =~ ^gradus-gate-[1-9][0-9]*-walkthrough(-permission-[1-9][0-9]*)?$ ]] || exit 1
while IFS=$'\t' read -r udid name data_path state; do
  [[ -n "$udid" ]] || continue
  grep -qxF -- "$udid" "$3" && continue
  case "$data_path" in "$2"/*) ;; *) continue ;; esac
  case "$name" in Clone\ *\ of\ *) ;; *) continue ;; esac
  [[ "$state" == "Shutdown" ]] && continue
  if [[ "$state" == "Booted" && "$name" =~ ^Clone\ [0-9]+\ of\ ${source_name}$ ]]; then
    if xcrun simctl --set "$2" shutdown "$udid" >/dev/null 2>&1 && \
      xcrun simctl --set "$2" delete "$udid" >/dev/null 2>&1; then
      echo "capture-walkthrough: deleted owned booted XCTest clone $name ($udid)" >&2
      continue
    fi
    echo "capture-walkthrough: failed to remove owned booted XCTest clone $name ($udid)" >&2
    exit 1
  fi
  echo "capture-walkthrough: left new XCTest clone $name ($udid) state=$state; ownership is not safe to infer" >&2
done < <(_gate_lib_list_devices --set "$2")
EOF

  GRADUS_XCTEST_SOURCE_SIMULATOR_NAME="$source_name" \
    "$APPLE_UI_TEST_LOCK" --label "Gradus interrupted XCTest clone cleanup" -- bash -c \
      "$locked_command" _ "$_GATE_LIB_SELF" "$set_root" "$before" "$end_ts" "$source_name"
}

run_widget_render() {
  TEST_RUNNER_GRADUS_WALKTHROUGH_WIDGET_OUTPUT="$output_dir" \
    gate_ui_test_lock --simulator-udid "$simulator_udid" \
      --label "Gradus walkthrough widget rendering" \
      xcodebuild test -project "$PROJECT_PATH" -scheme GradusiOS \
        -destination "platform=iOS Simulator,id=$simulator_udid" -parallel-testing-enabled NO \
        -maximum-parallel-testing-workers 1 \
        -derivedDataPath "$capture_root/DerivedData" \
        "-only-testing:GradusWidgetTests/exportWalkthroughWidgetStates()" \
        -resultBundlePath "$capture_root/widget-render.xcresult" CODE_SIGNING_ALLOWED=NO
}

run_route_capture() {
  TEST_RUNNER_GRADUS_WALKTHROUGH_FIXTURE="$fixture" \
    TEST_RUNNER_GRADUS_WALKTHROUGH_MARKER="$marker" \
    TEST_RUNNER_GRADUS_WALKTHROUGH_SCREENSHOT="$screenshot" \
    gate_ui_test_lock --simulator-udid "$simulator_udid" \
      --label "Gradus walkthrough capture $screen" \
      xcodebuild test -project "$PROJECT_PATH" -scheme GradusiOS \
        -destination "platform=iOS Simulator,id=$simulator_udid" -parallel-testing-enabled NO \
        -maximum-parallel-testing-workers 1 \
        -derivedDataPath "$capture_root/DerivedData" \
        -only-testing:GradusiOSUITests/WalkthroughCaptureXCUITests/testWalkthroughCapture \
        -resultBundlePath "$capture_root/$fixture.xcresult" CODE_SIGNING_ALLOWED=NO
}

simulator_inventory="$(xcrun simctl list --json)" || fail "could not list available Simulator runtimes"
create_spec="$(printf '%s' "$simulator_inventory" | /usr/bin/python3 -c '
import json, re, sys
data = json.load(sys.stdin)
runtimes = [
    runtime
    for runtime in data.get("runtimes", [])
    if runtime.get("platform") == "iOS"
    and runtime.get("isAvailable") is True
    and re.fullmatch(r"26(?:\.\d+)*", str(runtime.get("version", "")))
]
devices = [
    device
    for device in data.get("devicetypes", [])
    if device.get("isAvailable") is not False
    and str(device.get("name", "")).startswith("iPhone")
]
if not runtimes:
    print("no-available-ios-26-runtime")
    raise SystemExit(0)
if not devices:
    print("no-available-iphone-device")
    raise SystemExit(0)

def version_key(runtime):
    return tuple(int(part) for part in str(runtime.get("version", "")).split("."))

def device_key(device):
    name = device.get("name", "")
    return (name != "iPhone 15", name)

device = sorted(devices, key=device_key)[0]
runtime = max(runtimes, key=version_key)
print(device["identifier"] + "\t" + runtime["identifier"])
')" || fail "could not parse the available Simulator inventory"
case "$create_spec" in
  no-available-ios-26-runtime)
    fail "no available iOS 26.x Simulator runtime; install or enable an iOS 26.x runtime"
    ;;
  no-available-iphone-device)
    fail "could not discover an available iPhone Simulator device type"
    ;;
esac
IFS=$'\t' read -r device_type runtime <<< "$create_spec"
simulator_name="gradus-gate-$$-walkthrough"
simulator_udid="$(gate_sim_create gradus walkthrough "$device_type" "$runtime")"
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
      if ! run_bounded_capture "rendering deterministic widget states" "$log" \
        run_widget_render; then
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
    simulator_name="gradus-gate-$$-walkthrough-permission-$index"
    simulator_udid="$(gate_sim_create gradus "walkthrough-permission-$index" "$device_type" "$runtime")"
    [[ "$simulator_udid" =~ ^[0-9A-Fa-f-]{36}$ ]] || fail "Simulator create returned an invalid identifier"
    xcrun simctl boot "$simulator_udid"
    xcrun simctl bootstatus "$simulator_udid" -b
    xcrun simctl ui "$simulator_udid" appearance dark
  fi
  log="$capture_root/$fixture.log"
  if ! run_bounded_capture "capture-$((index + 1))-of-$total $screen" "$log" \
    run_route_capture; then
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
