#!/usr/bin/env bash
# Phase-gate for the Gradus iOS/macOS work: boots the pinned simulator and
# runs `xcodebuild test` for all pinned destinations. Exits non-zero on any
# failure (preflight mismatch, build failure, or test failure) so it's safe
# to wire into CI/pre-push as a hard gate.

# Resolve the repository before the executable path can change the working
# directory.  Functions may run after the main body has cd'd into app/, so a
# relative BASH_SOURCE path is no longer rooted at the caller's checkout.
GATE_SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_REPO_ROOT="$(cd -P "$GATE_SCRIPT_DIR/.." && pwd)"

# Keep this manifest aligned with every test command wrapped by
# `assert_counting_leg`.  The Python paths are intentionally listed here so
# the self-check can detect a new hermetic suite that is not wired into the
# canonical gate.
EXPECTED_COUNTING_LEG_COUNT=20
COUNTING_LEG_NAMES=(
  "swift-testing"
  "pytest"
  "GradusMac"
  "GradusMacUI"
  "GradusCredentialBridge"
  "GradusRefreshAgent"
  "GradusiOS-iPhone"
  "GradusiOS-DensityPhone"
  "GradusiOS-DensityPad"
  "GradusWidget"
  "GradusiOS-iPad"
  "release-candidate"
  "release-candidate-validation"
  "asc-api"
  "build-upload"
  "release-reconcile"
  "testflight-assignment"
  "candidate-walkthrough"
  "release-bridge"
  "GradusiOSUI"
)
COUNTING_LEG_REPORTERS=(
  "swift-testing"
  "pytest"
  "xctest"
  "xctest"
  "xctest"
  "xctest"
  "aggregate-xctest-swift"
  "swift-testing"
  "swift-testing"
  "swift-testing"
  "aggregate-xctest-swift"
  "pytest"
  "pytest"
  "pytest"
  "pytest"
  "pytest"
  "pytest"
  "pytest"
  "pytest"
  "xctest"
)
# Fixed-size image snapshots run in separate, explicitly destination-bound
# phone and pad legs. The iPad UI leg remains independent so neither class of
# evidence can hide a zero-test result in the other.
#
# GradusiOS-iPhone's floor (index 6) is pinned to its exact integrated-gate
# count (177) rather than a loose lower
# bound, so a test silently dropping out of selection fails the gate instead
# of hiding under slack. Raise it deliberately when adding tests there. The
# leg mixes Swift Testing and XCTest in one target, so its reporter is
# `aggregate-xctest-swift` (sum of both frameworks' max-seen counts, 142 + 20
# here), not `xctest` (max across patterns) -- the latter would let the
# smaller XCTest count silently ride under the larger Swift Testing one
# without ever binding to the reported/floor-checked total.
#
# The `swift-testing` (index 0) and `pytest` (index 1) floors read 2 until
# 2026-08-31, against observed counts of 100 and 1077: those two legs would
# have passed with 98% and 99.8% of their tests silently gone, which is the
# exact failure the floors exist to catch. Both are now sized just under their
# observed counts. They are deliberately NOT pinned exactly like index 6 --
# GradusiOS-iPhone is a fixed scenario set, while these two grow on most
# commits, and an exact floor there would make every added test a gate edit.
# Slack of a few tests still fails a leg that collapses.
#
# `GradusMac` (index 2) is now sized: the 2026-08-31 full gate observed 119,
# and the Task 3.1 background-agent suites took it to 138. Sized like index 0
# rather than pinned -- this bundle grows on most commits -- with enough slack
# that an added suite is not a gate edit and a collapsed one still fails.
#
# `GradusMacUI` (index 3) is pinned exactly, like index 6: it is a fixed
# scenario set (menu, required-iCloud, quit lifecycle), so losing one is a lost
# behavior rather than ordinary churn.
COUNTING_LEG_MINIMUMS=(95 1000 170 3 15 12 177 3 9 10 12 6 5 5 15 5 5 4 31 12)
COUNTING_LEG_SOURCES=(
  "GradusKit"
  "../tests"
  "GradusMac"
  "GradusMacUITests"
  "GradusCredentialBridgeTests"
  "GradusRefreshAgentTests"
  "GradusiOS-iPhone"
  "GradusiOSTests/DensityLayoutSnapshotTests.swift"
  "GradusiOSTests/DensityLayoutSnapshotTests.swift"
  "GradusWidgetTests"
  "GradusiOS-iPad"
  "test_release_candidate.py"
  "test_release_candidate_validation.py"
  "test_asc_api.py"
  "test_asc_build_upload.py"
  "test_release_reconcile.py"
  "testflight-setup-tests.py"
  "test_walkthrough.py"
  "test_gradus_release_bridge.py"
  "GradusiOSUITests"
)

# These are pixel baselines, not every test in DensityLayoutSnapshotTests.
# The label-fixture semantic test remains in the ordinary iPhone unit suite.
DENSITY_IMAGE_SNAPSHOT_TEST_SELECTORS=(
  "GradusiOSTests/densePadPortraitLight()"
  "GradusiOSTests/densePadPortraitDark()"
  "GradusiOSTests/densePadLandscapeDark()"
  "GradusiOSTests/densityStandardPadPortraitLight()"
  "GradusiOSTests/densityLargePadPortraitLight()"
  "GradusiOSTests/densityLargePadPortraitExtraExtraExtraLarge()"
  "GradusiOSTests/densityCompactPadPortraitExtraExtraExtraLarge()"
  "GradusiOSTests/densityLargePhoneDark()"
  "GradusiOSTests/densityCompactPhoneAccessibility1()"
  "GradusiOSTests/densityCompactPhoneAccessibility5()"
  "GradusiOSTests/densityLargePadPortraitAccessibility1()"
  "GradusiOSTests/densityLargePadPortraitAccessibility5()"
)
DENSITY_PHONE_SNAPSHOT_TEST_SELECTORS=(
  "GradusiOSTests/densityLargePhoneDark()"
  "GradusiOSTests/densityCompactPhoneAccessibility1()"
  "GradusiOSTests/densityCompactPhoneAccessibility5()"
)
DENSITY_PAD_SNAPSHOT_TEST_SELECTORS=(
  "GradusiOSTests/densePadPortraitLight()"
  "GradusiOSTests/densePadPortraitDark()"
  "GradusiOSTests/densePadLandscapeDark()"
  "GradusiOSTests/densityStandardPadPortraitLight()"
  "GradusiOSTests/densityLargePadPortraitLight()"
  "GradusiOSTests/densityLargePadPortraitExtraExtraExtraLarge()"
  "GradusiOSTests/densityCompactPadPortraitExtraExtraExtraLarge()"
  "GradusiOSTests/densityLargePadPortraitAccessibility1()"
  "GradusiOSTests/densityLargePadPortraitAccessibility5()"
)
COUNTING_LEG_RUN_COUNT=0

validate_counting_leg_declarations() {
  local leg_count="${#COUNTING_LEG_NAMES[@]}"
  if [[ "$leg_count" -ne "$EXPECTED_COUNTING_LEG_COUNT" ||
        "${#COUNTING_LEG_REPORTERS[@]}" -ne "$EXPECTED_COUNTING_LEG_COUNT" ||
        "${#COUNTING_LEG_MINIMUMS[@]}" -ne "$EXPECTED_COUNTING_LEG_COUNT" ||
        "${#COUNTING_LEG_SOURCES[@]}" -ne "$EXPECTED_COUNTING_LEG_COUNT" ]]; then
    echo "FAIL: counting-leg declarations disagree (expected $EXPECTED_COUNTING_LEG_COUNT, names $leg_count, reporters ${#COUNTING_LEG_REPORTERS[@]}, floors ${#COUNTING_LEG_MINIMUMS[@]}, sources ${#COUNTING_LEG_SOURCES[@]})" >&2
    return 1
  fi

  local index
  for ((index = 0; index < leg_count; index++)); do
    if ! [[ "${COUNTING_LEG_MINIMUMS[index]}" =~ ^[1-9][0-9]*$ ]]; then
      echo "FAIL: counting leg '${COUNTING_LEG_NAMES[index]}' has invalid minimum '${COUNTING_LEG_MINIMUMS[index]}'" >&2
      return 1
    fi
  done
}

validate_density_image_snapshot_selectors() {
  local selector
  if [[ "${#DENSITY_IMAGE_SNAPSHOT_TEST_SELECTORS[@]}" -ne 12 ]]; then
    echo "FAIL: expected 12 canonical density image snapshots, found ${#DENSITY_IMAGE_SNAPSHOT_TEST_SELECTORS[@]}" >&2
    return 1
  fi
  for selector in "${DENSITY_IMAGE_SNAPSHOT_TEST_SELECTORS[@]}"; do
    if [[ ! "$selector" =~ ^GradusiOSTests/[A-Za-z0-9_]+\(\)$ ]]; then
      echo "FAIL: invalid density image snapshot selector '$selector'" >&2
      return 1
    fi
  done
}

persist_test_gate_diagnostic() {
  # Every command captured by this gate is credential-free. Preserve failed
  # transcripts beside the existing local release evidence so release_tools
  # can discard its child streams without making the failing leg unknowable.
  local leg_name="$1" output_file="$2" diagnostic_root diagnostic_name diagnostic_path
  diagnostic_root="${GRADUS_TEST_GATE_DIAGNOSTIC_ROOT:-$GATE_REPO_ROOT/.release-state/evidence/test-gate}"
  diagnostic_name="${leg_name//[^A-Za-z0-9._-]/_}"
  diagnostic_path="$diagnostic_root/${diagnostic_name}-$(date -u '+%Y%m%dT%H%M%SZ')-${BASHPID:-$$}-${RANDOM:-0}.log"
  if mkdir -p "$diagnostic_root" \
      && chmod 700 "$diagnostic_root" \
      && /bin/cp "$output_file" "$diagnostic_path" \
      && chmod 600 "$diagnostic_path"; then
    echo "    Diagnostic output preserved at $diagnostic_path" >&2
    rm -f "$output_file"
    return 0
  fi
  echo "FAIL: could not preserve diagnostic output for counting leg '$leg_name'" >&2
  return 1
}

assert_counting_leg() {
  local leg_name="$1"
  shift
  local leg_index=-1
  local index
  for ((index = 0; index < ${#COUNTING_LEG_NAMES[@]}; index++)); do
    if [[ "${COUNTING_LEG_NAMES[index]}" == "$leg_name" ]]; then
      leg_index="$index"
      break
    fi
  done
  if [[ "$leg_index" -lt 0 ]]; then
    echo "FAIL: undeclared counting leg '$leg_name'" >&2
    return 1
  fi

  local output_file
  output_file="$(mktemp "${TMPDIR:-/tmp}/gradus-test-gate.XXXXXX")"
  local command_status=0
  if "$@" 2>&1 | tee "$output_file"; then
    :
  else
    command_status="$?"
  fi
  if [[ "$command_status" -ne 0 ]]; then
    echo "FAIL: counting leg '$leg_name' exited with status $command_status" >&2
    persist_test_gate_diagnostic "$leg_name" "$output_file" || true
    return "$command_status"
  fi

  local reported_count reporter
  reporter="${COUNTING_LEG_REPORTERS[leg_index]}"
  if [[ "$reporter" == "aggregate-xctest-swift" ]]; then
    reported_count="$(awk '
      function number(value) {
        gsub(/[^0-9]/, "", value)
        return value + 0
      }
      {
        if (match($0, /Test run with [0-9]+ tests?/)) {
          value = number(substr($0, RSTART, RLENGTH))
          if (value > swift_testing) swift_testing = value
        }
        if (match($0, /Executed [0-9]+ tests?/)) {
          value = substr($0, RSTART, RLENGTH)
          sub(/^Executed /, "", value)
          value = number(value)
          if (value > xctest) xctest = value
        }
      }
      END { if (swift_testing || xctest) print swift_testing + xctest }
    ' "$output_file")"
  else
    reported_count="$(awk '
    function record(value) {
      gsub(/[^0-9]/, "", value)
      if (value != "") {
        value = value + 0
        if (value > maximum) maximum = value
      }
      found = 1
    }
    {
      if (match($0, /Test run with [0-9]+ tests?/)) {
        value = substr($0, RSTART, RLENGTH)
        sub(/^Test run with /, "", value)
        record(value)
      }
      if (match($0, /[0-9]+ passed/)) {
        record(substr($0, RSTART, RLENGTH))
      }
      if (match($0, /Executed [0-9]+ tests?/)) {
        value = substr($0, RSTART, RLENGTH)
        sub(/^Executed /, "", value)
        record(value)
      }
    }
    END { if (found) print maximum }
    ' "$output_file")"
  fi
  if [[ -z "$reported_count" ]]; then
    echo "FAIL: counting leg '$leg_name' reported no recognized test count" >&2
    persist_test_gate_diagnostic "$leg_name" "$output_file" || true
    return 1
  fi
  if [[ "$reported_count" -lt "${COUNTING_LEG_MINIMUMS[leg_index]}" ]]; then
    echo "FAIL: counting leg '$leg_name' reported $reported_count tests; minimum is ${COUNTING_LEG_MINIMUMS[leg_index]}" >&2
    persist_test_gate_diagnostic "$leg_name" "$output_file" || true
    return 1
  fi
  rm -f "$output_file"

  COUNTING_LEG_RUN_COUNT=$((COUNTING_LEG_RUN_COUNT + 1))
  echo "    $leg_name: $reported_count tests reported (minimum ${COUNTING_LEG_MINIMUMS[leg_index]}). OK."
}

assert_counting_legs_complete() {
  if [[ "$COUNTING_LEG_RUN_COUNT" -ne "$EXPECTED_COUNTING_LEG_COUNT" ]]; then
    echo "FAIL: ran $COUNTING_LEG_RUN_COUNT of $EXPECTED_COUNTING_LEG_COUNT declared counting legs" >&2
    return 1
  fi
}

# xcodebuild can leave an orphaned test runner behind while its parent remains
# alive indefinitely. Keep the deadline local to the one leg that has shown
# this failure mode; ordinary command exits retain their exact status, while a
# deadline produces the conventional 124 timeout status and visible evidence.
run_with_deadline() {
  local deadline_seconds="$1" label="$2"
  shift 2
  if ! [[ "$deadline_seconds" =~ ^[1-9][0-9]*$ ]]; then
    echo "FAIL: invalid deadline for $label: '$deadline_seconds'" >&2
    return 2
  fi
  if [[ "$#" -eq 0 ]]; then
    echo "FAIL: no command supplied for $label" >&2
    return 2
  fi

  local marker child_pid watchdog_pid command_status
  marker="$(mktemp "${TMPDIR:-/tmp}/gradus-test-deadline.XXXXXX")" || return 1
  rm -f "$marker"
  echo "==> $label (deadline ${deadline_seconds}s)"
  "$@" &
  child_pid=$!
  (
    sleep "$deadline_seconds"
    if kill -0 "$child_pid" >/dev/null 2>&1; then
      printf '%s\n' timed_out > "$marker"
      kill -TERM "$child_pid" >/dev/null 2>&1 || true
      for _ in {1..20}; do
        kill -0 "$child_pid" >/dev/null 2>&1 || exit 0
        sleep 0.25
      done
      if kill -0 "$child_pid" >/dev/null 2>&1; then
        echo "FAIL: $label did not exit after TERM; killing" >&2
        kill -KILL "$child_pid" >/dev/null 2>&1 || true
      fi
    fi
  ) >/dev/null 2>&1 &
  watchdog_pid=$!

  if wait "$child_pid"; then
    command_status=0
  else
    command_status="$?"
  fi
  kill "$watchdog_pid" >/dev/null 2>&1 || true
  wait "$watchdog_pid" >/dev/null 2>&1 || true
  if [[ -s "$marker" ]]; then
    command_status=124
    echo "FAIL: $label exceeded ${deadline_seconds}s; terminating" >&2
  fi
  rm -f "$marker"
  return "$command_status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
set -euo pipefail

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --help)
      echo "Usage: bash test-gate.sh"
      exit 0
      ;;
    *)
      echo "FAIL: unknown test-gate option '$1'" >&2
      exit 2
      ;;
  esac
  shift
done

cd "$(dirname "${BASH_SOURCE[0]}")"

validate_counting_leg_declarations
validate_density_image_snapshot_selectors

echo "==> Hermetic notarization script behavior tests"
./test-notary-scripts.sh

# Not a counting leg: the counting legs are the four test-*framework* reporters
# (swift-testing, pytest, xctest, aggregate-xctest-swift), and this is a shell
# suite like the ones around it. It fails loudly on its own, which is what the
# floors exist to guarantee for the framework runners.
echo "==> Hermetic Mac bundle signing and structure tests"
./test-mac-bundle-structure.sh

echo "==> Hermetic test-count gate behavior tests"
./test-gate-selfcheck.sh

echo "==> Hermetic iOS upload wrapper behavior tests"
./test-archive-upload-ios.sh

echo "==> Hermetic local Mac install behavior tests"
./test-install-mac-local.sh

echo "==> Hermetic credential bridge install behavior tests"
./test-install-credential-bridge.sh

echo "==> Hermetic universal2 Gradus runtime build and relocation tests"
bash ./test-build-gradus-runtime.sh

echo "==> Hermetic release-candidate ledger tests"
assert_counting_leg "release-candidate" uv run pytest -q test_release_candidate.py

echo "==> Hermetic release-candidate validation tests"
assert_counting_leg "release-candidate-validation" uv run pytest -q test_release_candidate_validation.py

echo "==> Hermetic App Store Connect client tests"
assert_counting_leg "asc-api" uv run pytest -q test_asc_api.py

# Transport for the App Store Connect REST build-uploads flow that replaced
# altool. Hermetic: every test drives a fake transport, so no credential or
# network access is required to run this leg.
assert_counting_leg "build-upload" uv run pytest -q test_asc_build_upload.py

echo "==> Hermetic release reconciliation tests"
assert_counting_leg "release-reconcile" uv run pytest -q test_release_reconcile.py

echo "==> Hermetic TestFlight assignment tests"
assert_counting_leg "testflight-assignment" uv run pytest -q testflight-setup-tests.py

echo "==> Hermetic candidate walkthrough tests"
assert_counting_leg "candidate-walkthrough" uv run pytest -q test_walkthrough.py

echo "==> Hermetic release bridge dispatch tests"
assert_counting_leg "release-bridge" uv run pytest -q test_gradus_release_bridge.py

# INV-11 declares `area:` over app/GradusKit/**, gradus/**, and tests/** with
# this script as its gate_test -- but the three `xcodebuild test` invocations
# below cover none of those three. GradusKit is consumed as a SwiftPM package
# *dependency*, so `xcodebuild test -scheme ...` builds its library product and
# never its test targets; XcodeGen can't add them to a scheme's `test:` block
# either, since they aren't project targets. Result (found 2026-08-05): 47
# passing GradusKit tests -- the reconciliation core both apps import -- sat
# entirely outside the release gate, and the Python suite only ran via
# pre-push. Both run here now, ordered before the slow simulator work so the
# gate fails fast.
echo "==> swift test — GradusKit package (SwiftPM; not reachable via either app scheme)"
assert_counting_leg "swift-testing" swift test --package-path GradusKit

echo "==> pytest — Python producer suite (INV-1..INV-6, INV-8)"
assert_counting_leg "pytest" bash -c 'cd .. && uv run pytest -q'

PINNED_XCODE_VERSION="$(cat .xcode-version)"
# Three legs take this machine-wide lock -- GradusMacUI and both simulator UI
# legs. `flock` is per open-file-description, so a *nested* acquisition is not
# re-entrant: running this gate underneath an outer `apple-ui-test-lock` hold
# makes each of those legs wait forever on a lock its own ancestor owns. Run
# the gate bare -- `caffeinate -disu bash app/test-gate.sh` -- and let the legs
# take the lock themselves.
APPLE_UI_TEST_LOCK="${APPLE_UI_TEST_LOCK:-$HOME/.agent/bin/apple-ui-test-lock}"
GRADUS_MAC_TEST_TIMEOUT_SECONDS="${GRADUS_MAC_TEST_TIMEOUT_SECONDS:-600}"
if ! [[ "$GRADUS_MAC_TEST_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "FAIL: GRADUS_MAC_TEST_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi
SIM_OS_VERSION="26.5"
SIM_RUNTIME_ID="com.apple.CoreSimulator.SimRuntime.iOS-26-5"
SIM_DEVICETYPE_ID="com.apple.CoreSimulator.SimDeviceType.iPhone-16"

# The iPad destination exists because it is the only one where the adaptive
# grid resolves to more than one column -- the iPhone runs the same dense
# cards in a single column (INV-12), so both destinations execute
# `DensityLayoutXCUITests` for real and neither is proven by the other.
# Image baselines are iPad-canonical because they require fixed 834x1194 host
# geometry; iPhone coverage remains UI tests and non-snapshot units.
# Pinned to the 11-inch (834x1194 points) because that is exactly the geometry
# `DensityLayoutSnapshotTests` records its baselines at; a different iPad
# would still be "regular width" but would no longer describe the same layout
# the snapshots do. The iPad leg selects the UI tests and the 12 canonical
# image snapshot functions; rerunning the whole iOS suite on a second simulator
# would roughly double the gate's slowest phase.
IPAD_DEVICETYPE_ID="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB"

echo "==> Preflight: Xcode + simulator OS must match the pins (PM-9)"
# One `awk` that reads to EOF, rather than `| head -1 | awk ...`. `head` exits
# as soon as it has its line, and if `xcodebuild` is still writing it takes
# SIGPIPE; under `set -euo pipefail` that surfaces as the gate aborting with
# 141 right here, before a single test runs, and the log just stops after the
# banner above with no error text -- which reads like a clean run to anything
# tailing it. Observed once in three runs on 2026-08-06.
#
# Note `awk 'NR==1{print $2; exit}'` would NOT fix it: that `exit` closes the
# pipe exactly as early as `head` does. Consuming the whole stream is the
# point, not matching only the first line.
active_xcode_version="$(xcodebuild -version | awk 'NR==1{print $2}')"
if [[ "$active_xcode_version" != "$PINNED_XCODE_VERSION" ]]; then
  echo "FAIL: active Xcode is $active_xcode_version, pinned to $PINNED_XCODE_VERSION (.xcode-version)" >&2
  echo "      floating minor versions silently break OS-specific snapshot baselines — regenerate deliberately on upgrade." >&2
  exit 1
fi

if ! xcrun simctl list runtimes | grep -q "iOS $SIM_OS_VERSION "; then
  echo "FAIL: iOS $SIM_OS_VERSION runtime is not installed (pinned simulator OS)" >&2
  exit 1
fi
echo "    Xcode $active_xcode_version, iOS $SIM_OS_VERSION runtime present. OK."

echo "==> Regenerating Xcode project from project.yml"
xcodegen generate

is_simulator_booted() {
  local udid="$1"
  xcrun simctl list devices "$SIM_OS_VERSION" |
    grep -F "$udid) (Booted)" >/dev/null
}

# A crashing test (e.g. a segfault inside a snapshot-diffing dependency)
# still produces a valid, useful .ips in ~/Library/Logs/DiagnosticReports --
# only the interactive "GradusiOS quit unexpectedly" dialog is suppressed,
# scoped to this run and restored on exit so it never leaks into the rest
# of the system.
prior_dialog_type="$(defaults read com.apple.CrashReporter DialogType 2>/dev/null || true)"
defaults write com.apple.CrashReporter DialogType none

# All Xcode test legs use one fresh, run-scoped DerivedData directory. This
# prevents a stale Mac XCTest runner (especially one produced by an older
# unsigned invocation) from being rediscovered by testmanagerd on the next
# run. The iOS legs also need isolation so snapshot resources cannot survive a
# source change. Sharing the directory within this gate keeps package/build
# reuse while making the entire test run disposable. Declared empty here (set
# for real via the shared gate lib's gate_derived_data below, once sourced) so
# the EXIT trap below always has a bound variable to rm -rf even if the run
# fails before that point -- `rm -rf ""` is a safe no-op, never `rm -rf` of cwd.
derived_data_dir=""

readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# `rm -rf` on DerivedData does not unregister what LaunchServices already
# recorded: every gate run built `GradusMac.app` under a fresh temp path,
# xcodebuild registered it, and the entry outlived the directory. By
# 2026-08-26 that had accumulated 404 dead Gradus bundles, all named
# `GradusMac`, all `com.zerodelta.gradus.mac.dev`. Unregister before deleting.
gate_unregister_bundles() {
  local bundle
  [[ -n "$derived_data_dir" && -d "$derived_data_dir" ]] || return 0
  [[ -x "$LSREGISTER" ]] || return 0
  # Prune the index store, which is the only large subtree here and holds no
  # bundles, then take every `.app` at any depth -- including helpers nested
  # inside a test runner, which LaunchServices records as their own entries.
  # A depth cap would be shorter and would silently miss whatever sat deeper.
  while IFS= read -r bundle; do
    "$LSREGISTER" -u "$bundle" >/dev/null 2>&1 || true
  done < <(find "$derived_data_dir" -type d -name Index.noindex -prune -o \
    -type d -name "*.app" -print 2>/dev/null)
}

# This gate's own EXIT trap only handles state it owns directly (the
# CrashReporter dialog override and DerivedData). It is set BEFORE sourcing
# the shared simctl gate lib below, on purpose: the lib's
# own EXIT-trap installation composes onto whatever trap already exists at
# source time (see simctl_gate_lib.sh's header) rather than clobbering it, so
# simulator create/delete lifecycle is entirely the shared lib's
# responsibility from here on -- this gate no longer tracks whether a device
# pre-existed, because gate_sim_create always makes a fresh disposable one.
trap '
  if [[ -z "$prior_dialog_type" ]]; then
    defaults delete com.apple.CrashReporter DialogType >/dev/null 2>&1 || true
  else
    defaults write com.apple.CrashReporter DialogType "$prior_dialog_type"
  fi
  gate_unregister_bundles
  rm -rf "$derived_data_dir"
' EXIT

# shellcheck source=/dev/null
source "/Users/dave/Documents/Projects/apple_developer/release_tools/templates/simctl_gate_lib.sh"

echo "==> Sweeping stale Gradus gate simulators (>24h)"
swept_count="$(gate_sweep gradus)"
echo "    Swept $swept_count stale gate device(s)."

derived_data_dir="$(gate_derived_data)"
gradus_mac_inv7_source_root="$derived_data_dir/inv7-source/GradusMac"
gradus_mac_snapshot_root="$derived_data_dir/snapshots/__Snapshots__"
gradus_bridge_stage_root="$derived_data_dir/bridge-source"
gradus_bridge_source_root="$gradus_bridge_stage_root/app"

echo "==> Creating disposable Gradus gate iPhone simulator (iOS $SIM_OS_VERSION)"
sim_udid="$(gate_sim_create gradus iphone "$SIM_DEVICETYPE_ID" "$SIM_RUNTIME_ID")"
echo "    Simulator UDID: $sim_udid"

echo "==> Creating disposable Gradus gate iPad simulator (iOS $SIM_OS_VERSION)"
ipad_udid="$(gate_sim_create gradus ipad "$IPAD_DEVICETYPE_ID" "$SIM_RUNTIME_ID")"
echo "    iPad UDID: $ipad_udid"

echo "==> Booting simulators"
xcrun simctl bootstatus "$sim_udid" -b || true
xcrun simctl bootstatus "$ipad_udid" -b || true

echo "==> xcodebuild test — GradusMac (platform=macOS)"
# Tests execute local Debug products and do not produce a distributable artifact.
# Keeping signing disabled here avoids provisioning/account state becoming a false test gate;
# archive, export, and notarization scripts retain their normal signing paths.
# INV-7 runs inside the hosted GradusMac test process. Stage exactly the source
# tree it scans outside the checkout before launching that host, then pass the
# staged root explicitly so the test never reads ~/Documents through #filePath.
mkdir -p "$(dirname "$gradus_mac_inv7_source_root")"
/usr/bin/ditto "$GATE_REPO_ROOT/app/GradusMac/." "$gradus_mac_inv7_source_root"
staged_gradus_mac_file="$(find "$gradus_mac_inv7_source_root" -type f -print -quit)"
if [[ ! -d "$gradus_mac_inv7_source_root" ]] ||
   [[ -z "$staged_gradus_mac_file" ]]; then
  echo "FAIL: could not stage non-empty GradusMac source for INV-7" >&2
  exit 1
fi
mkdir -p "$(dirname "$gradus_mac_snapshot_root")"
/usr/bin/ditto "$GATE_REPO_ROOT/app/GradusMacTests/__Snapshots__/." "$gradus_mac_snapshot_root"
staged_gradus_mac_snapshot="$(find "$gradus_mac_snapshot_root" -type f -print -quit)"
if [[ ! -d "$gradus_mac_snapshot_root" ]] ||
   [[ -z "$staged_gradus_mac_snapshot" ]]; then
  echo "FAIL: could not stage non-empty GradusMac snapshot baselines" >&2
  exit 1
fi
assert_counting_leg "GradusMac" run_with_deadline "$GRADUS_MAC_TEST_TIMEOUT_SECONDS" "GradusMac unit tests" env \
  GRADUS_DISABLE_PIPELINE=1 \
  TEST_RUNNER_GRADUS_INV7_SOURCE_ROOT="$gradus_mac_inv7_source_root" \
  TEST_RUNNER_GRADUS_SNAPSHOT_ROOT="$gradus_mac_snapshot_root" \
  xcodebuild test \
  -project Gradus.xcodeproj \
  -derivedDataPath "$derived_data_dir" \
  -scheme GradusMac \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:GradusMacTests \
  CODE_SIGNING_ALLOWED=NO

echo "==> xcodebuild test — GradusMacUITests (platform=macOS; exact GradusMac product)"
# This leg drives real HID automation against the host's focused window, so it
# takes the same machine-wide lock the simulator UI legs take; without it a
# concurrent Apple UI test in another project and this one fight over focus and
# both fail. The lock is deliberately the OUTER wrapper: waiting for it is
# unbounded, exactly as on the iOS UI legs, and must not be charged against the
# deadline. Measured 2026-09-01 -- with the deadline outside instead, a
# contending run in another repository held the lock past 600s and this leg
# reported a spurious `exceeded 600s` failure without ever starting xcodebuild.
# The lock execvp's in place, so `run_with_deadline` still runs as its own
# process, still governs only xcodebuild, and its TERM still reaches it;
# `export -f` is what carries the function across that exec.
export -f run_with_deadline
assert_counting_leg "GradusMacUI" \
  "$APPLE_UI_TEST_LOCK" --label "GradusMac UI tests" -- \
  bash -c 'run_with_deadline "$@"' gradus-mac-ui-leg \
  "$GRADUS_MAC_TEST_TIMEOUT_SECONDS" "GradusMac UI tests" env \
  GRADUS_DISABLE_PIPELINE=1 \
  xcodebuild test \
  -project Gradus.xcodeproj \
  -derivedDataPath "$derived_data_dir" \
  -scheme GradusMac \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:GradusMacUITests

echo "==> xcodebuild test — GradusCredentialBridge (platform=macOS)"
# These structural tests must not open the checkout below ~/Documents from the
# hosted XCTest process. Stage exactly the files and trees they inspect under
# gate-owned DerivedData, preserving the app/repository layout they validate.
mkdir -p "$gradus_bridge_source_root/GradusCredentialBridgeCore"
/bin/cp "$GATE_REPO_ROOT/app/project.yml" "$gradus_bridge_source_root/project.yml"
/bin/cp "$GATE_REPO_ROOT/app/GradusCredentialBridgeCore/Bridge.swift" \
  "$gradus_bridge_source_root/GradusCredentialBridgeCore/Bridge.swift"
for source_directory in GradusMac GradusRefreshAgent packaging; do
  /usr/bin/ditto "$GATE_REPO_ROOT/app/$source_directory/." \
    "$gradus_bridge_source_root/$source_directory"
done
/usr/bin/ditto "$GATE_REPO_ROOT/gradus/." "$gradus_bridge_stage_root/gradus"

staged_bridge_file="$(find "$gradus_bridge_stage_root" -type f -print -quit)"
if [[ -z "$staged_bridge_file" ]] ||
   [[ ! -s "$gradus_bridge_source_root/project.yml" ]] ||
   [[ ! -s "$gradus_bridge_source_root/GradusCredentialBridgeCore/Bridge.swift" ]]; then
  echo "FAIL: could not stage non-empty GradusCredentialBridge structural-test inputs" >&2
  exit 1
fi
for staged_directory in \
  "$gradus_bridge_source_root/GradusMac" \
  "$gradus_bridge_source_root/GradusRefreshAgent" \
  "$gradus_bridge_source_root/packaging" \
  "$gradus_bridge_stage_root/gradus"; do
  if [[ ! -d "$staged_directory" ]] ||
     [[ -z "$(find "$staged_directory" -type f -print -quit)" ]]; then
    echo "FAIL: staged GradusCredentialBridge input is empty: $staged_directory" >&2
    exit 1
  fi
done

assert_counting_leg "GradusCredentialBridge" env \
  TEST_RUNNER_GRADUS_BRIDGE_SOURCE_ROOT="$gradus_bridge_source_root" \
  xcodebuild test \
  -project Gradus.xcodeproj \
  -derivedDataPath "$derived_data_dir" \
  -scheme GradusCredentialBridge \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:GradusCredentialBridgeTests \
  CODE_SIGNING_ALLOWED=NO

echo "==> xcodebuild test — GradusRefreshAgent (platform=macOS)"
assert_counting_leg "GradusRefreshAgent" xcodebuild test \
  -project Gradus.xcodeproj \
  -derivedDataPath "$derived_data_dir" \
  -scheme GradusRefreshAgent \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:GradusRefreshAgentTests \
  CODE_SIGNING_ALLOWED=NO

density_snapshot_skip_args=()
density_phone_only_args=()
density_pad_only_args=()
for selector in "${DENSITY_IMAGE_SNAPSHOT_TEST_SELECTORS[@]}"; do
  density_snapshot_skip_args+=("-skip-testing:$selector")
done
for selector in "${DENSITY_PHONE_SNAPSHOT_TEST_SELECTORS[@]}"; do
  density_phone_only_args+=("-only-testing:$selector")
done
for selector in "${DENSITY_PAD_SNAPSHOT_TEST_SELECTORS[@]}"; do
  density_pad_only_args+=("-only-testing:$selector")
done

echo "==> xcodebuild test — GradusiOS (iPhone 16 / iOS $SIM_OS_VERSION simulator)"
assert_counting_leg "GradusiOS-iPhone" xcodebuild test \
  -project Gradus.xcodeproj \
  -derivedDataPath "$derived_data_dir" \
  -scheme GradusiOS \
  -destination "platform=iOS Simulator,id=$sim_udid" \
  -skip-testing:GradusiOSUITests \
  "${density_snapshot_skip_args[@]}" \
  CODE_SIGNING_ALLOWED=NO

echo "==> xcodebuild test — GradusiOS phone density snapshots (iPhone 16 / iOS $SIM_OS_VERSION simulator)"
assert_counting_leg "GradusiOS-DensityPhone" xcodebuild test \
  -project Gradus.xcodeproj \
  -derivedDataPath "$derived_data_dir" \
  -scheme GradusiOS \
  -destination "platform=iOS Simulator,id=$sim_udid" \
  "${density_phone_only_args[@]}" \
  CODE_SIGNING_ALLOWED=NO

echo "==> xcodebuild test — GradusiOS pad density snapshots ($ipad_udid / iOS $SIM_OS_VERSION simulator)"
assert_counting_leg "GradusiOS-DensityPad" xcodebuild test \
  -project Gradus.xcodeproj \
  -derivedDataPath "$derived_data_dir" \
  -scheme GradusiOS \
  -destination "platform=iOS Simulator,id=$ipad_udid" \
  "${density_pad_only_args[@]}" \
  CODE_SIGNING_ALLOWED=NO

echo "==> xcodebuild test — GradusWidget (iPhone 16 / iOS $SIM_OS_VERSION simulator)"
assert_counting_leg "GradusWidget" xcodebuild test \
  -project Gradus.xcodeproj \
  -derivedDataPath "$derived_data_dir" \
  -scheme GradusWidget \
  -destination "platform=iOS Simulator,id=$sim_udid" \
  -only-testing:GradusWidgetTests \
  CODE_SIGNING_ALLOWED=NO

# GradusiOSUITests has its own named iPhone leg below. Keeping it out of this
# broad unit-test pass prevents Xcode from bootstrapping the same UI runner
# twice, while the dedicated leg still makes loss of UI coverage visible.

# `DensityLayoutXCUITests` runs on the iPhone destination below too, but only
# here does the adaptive grid resolve to multiple columns. The test carries no
# idiom skip, so removing this step would not make it go silently green -- it
# would just stop covering the multi-column geometry. Kept as a named,
# separate gate line so that loss is visible if anyone deletes it.
echo "==> xcodebuild test — GradusiOS UI tests ($ipad_udid / iOS $SIM_OS_VERSION simulator)"
assert_counting_leg "GradusiOS-iPad" "$APPLE_UI_TEST_LOCK" --label "GradusiOS UI tests ($ipad_udid)" -- xcodebuild test \
  -project Gradus.xcodeproj \
  -derivedDataPath "$derived_data_dir" \
  -scheme GradusiOS \
  -destination "platform=iOS Simulator,id=$ipad_udid" \
  -only-testing:GradusiOSUITests \
  CODE_SIGNING_ALLOWED=NO

# A completed iPad XCTest runner can leave testmanagerd's Accessibility session
# attached to the wrong CoreSimulator device. Restart the iPhone target after
# retiring the iPad runner so the next AX-loaded notification is fresh.
reset_simulator_ui_session_for_iphone() {
  echo "==> Resetting simulator UI session before iPhone UI tests"
  if is_simulator_booted "$ipad_udid"; then
    xcrun simctl shutdown "$ipad_udid"
  fi
  if is_simulator_booted "$sim_udid"; then
    xcrun simctl shutdown "$sim_udid"
  fi
  xcrun simctl boot "$sim_udid"
  xcrun simctl bootstatus "$sim_udid" -b
}

reset_simulator_ui_session_for_iphone

# Keep both simulator UI legs adjacent.
echo "==> xcodebuild test — GradusiOSUITests target (iPhone 16 / iOS $SIM_OS_VERSION simulator)"
assert_counting_leg "GradusiOSUI" "$APPLE_UI_TEST_LOCK" --label "GradusiOSUITests" -- xcodebuild test \
  -project Gradus.xcodeproj \
  -derivedDataPath "$derived_data_dir" \
  -scheme GradusiOS \
  -destination "platform=iOS Simulator,id=$sim_udid" \
  -only-testing:GradusiOSUITests \
  CODE_SIGNING_ALLOWED=NO

assert_counting_legs_complete

# The release runner supplies READINESS_MANIFEST only for a candidate-bound
# gate. Ordinary developer and pre-push runs retain their prior behavior.
if [[ -n "${READINESS_MANIFEST:-}" ]]; then
  /usr/bin/python3 release_stage_readiness.py --local-gate
fi

echo "==> test-gate.sh: all destinations green"
fi
