#!/usr/bin/env bash
# Phase-gate for the Gradus iOS/macOS work: boots the pinned simulator and
# runs `xcodebuild test` for all pinned destinations. Exits non-zero on any
# failure (preflight mismatch, build failure, or test failure) so it's safe
# to wire into CI/pre-push as a hard gate.

# Keep this manifest aligned with every test command wrapped by
# `assert_counting_leg`.  The Python paths are intentionally listed here so
# the self-check can detect a new hermetic suite that is not wired into the
# canonical gate.
EXPECTED_COUNTING_LEG_COUNT=13
COUNTING_LEG_NAMES=(
  "swift-testing"
  "pytest"
  "GradusMac"
  "GradusiOS-iPhone"
  "GradusiOS-iPad"
  "release-candidate"
  "release-candidate-validation"
  "asc-api"
  "release-reconcile"
  "testflight-assignment"
  "candidate-walkthrough"
  "GradusMacUI"
  "GradusiOSUI"
)
COUNTING_LEG_REPORTERS=(
  "swift-testing"
  "pytest"
  "xctest"
  "aggregate-xctest-swift"
  "aggregate-xctest-swift"
  "pytest"
  "pytest"
  "pytest"
  "pytest"
  "pytest"
  "pytest"
  "xctest"
  "xctest"
)
# The iPad leg includes the 12 canonical image tests below as well as the
# nine GradusiOSUITests workflows. Its floor must exceed the image-only
# result, or a zero-test UI target could be hidden by the snapshot count.
#
# GradusiOS-iPhone's floor (index 3) is pinned to its exact current reported
# count (162, as of the Codex (Spark) bucket work) rather than a loose lower
# bound, so a test silently dropping out of selection fails the gate instead
# of hiding under slack. Raise it deliberately when adding tests there. The
# leg mixes Swift Testing and XCTest in one target, so its reporter is
# `aggregate-xctest-swift` (sum of both frameworks' max-seen counts, 142 + 20
# here), not `xctest` (max across patterns) -- the latter would let the
# smaller XCTest count silently ride under the larger Swift Testing one
# without ever binding to the reported/floor-checked total.
COUNTING_LEG_MINIMUMS=(2 2 2 162 21 6 5 5 5 5 4 2 9)
COUNTING_LEG_SOURCES=(
  "GradusKit"
  "../tests"
  "GradusMac"
  "GradusiOS-iPhone"
  "GradusiOS-iPad"
  "test_release_candidate.py"
  "test_release_candidate_validation.py"
  "test_asc_api.py"
  "test_release_reconcile.py"
  "testflight-setup-tests.py"
  "test_walkthrough.py"
  "GradusMacUITests"
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
    rm -f "$output_file"
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
  rm -f "$output_file"

  if [[ -z "$reported_count" ]]; then
    echo "FAIL: counting leg '$leg_name' reported no recognized test count" >&2
    return 1
  fi
  if [[ "$reported_count" -lt "${COUNTING_LEG_MINIMUMS[leg_index]}" ]]; then
    echo "FAIL: counting leg '$leg_name' reported $reported_count tests; minimum is ${COUNTING_LEG_MINIMUMS[leg_index]}" >&2
    return 1
  fi

  COUNTING_LEG_RUN_COUNT=$((COUNTING_LEG_RUN_COUNT + 1))
  echo "    $leg_name: $reported_count tests reported (minimum ${COUNTING_LEG_MINIMUMS[leg_index]}). OK."
}

assert_counting_legs_complete() {
  if [[ "$COUNTING_LEG_RUN_COUNT" -ne "$EXPECTED_COUNTING_LEG_COUNT" ]]; then
    echo "FAIL: ran $COUNTING_LEG_RUN_COUNT of $EXPECTED_COUNTING_LEG_COUNT declared counting legs" >&2
    return 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

validate_counting_leg_declarations
validate_density_image_snapshot_selectors

echo "==> Hermetic notarization script behavior tests"
./test-notary-scripts.sh

echo "==> Hermetic test-count gate behavior tests"
./test-gate-selfcheck.sh

echo "==> Hermetic iOS upload wrapper behavior tests"
./test-archive-upload-ios.sh

echo "==> Hermetic local Mac install behavior tests"
./test-install-mac-local.sh

echo "==> Hermetic credential bridge install behavior tests"
./test-install-credential-bridge.sh

echo "==> Hermetic release-candidate ledger tests"
assert_counting_leg "release-candidate" uv run pytest -q test_release_candidate.py

echo "==> Hermetic release-candidate validation tests"
assert_counting_leg "release-candidate-validation" uv run pytest -q test_release_candidate_validation.py

echo "==> Hermetic App Store Connect client tests"
assert_counting_leg "asc-api" uv run pytest -q test_asc_api.py

echo "==> Hermetic release reconciliation tests"
assert_counting_leg "release-reconcile" uv run pytest -q test_release_reconcile.py

echo "==> Hermetic TestFlight assignment tests"
assert_counting_leg "testflight-assignment" uv run pytest -q testflight-setup-tests.py

echo "==> Hermetic candidate walkthrough tests"
assert_counting_leg "candidate-walkthrough" uv run pytest -q test_walkthrough.py

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
SIM_DEVICE_NAME="iPhone 16"
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
IPAD_DEVICE_NAME="iPad Pro 11-inch (M5)"
IPAD_DEVICETYPE_ID="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB"

# The deterministic local Mac UI fixture uses Debug app behavior, but its
# XCTest runner is explicitly development-signed so macOS can launch the
# bundle. Archive/export scripts retain their independent signing and
# entitlement checks for release artifacts.

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

echo "==> Ensuring the pinned simulator exists: $SIM_DEVICE_NAME / iOS $SIM_OS_VERSION"
simulator_created=0
sim_udid="$(xcrun simctl list devices "$SIM_OS_VERSION" | grep "$SIM_DEVICE_NAME (" | grep -oE '[0-9A-F-]{36}' | head -1 || true)"
if [[ -z "$sim_udid" ]]; then
  echo "    Creating $SIM_DEVICE_NAME (iOS $SIM_OS_VERSION) simulator..."
  sim_udid="$(xcrun simctl create "$SIM_DEVICE_NAME" "$SIM_DEVICETYPE_ID" "$SIM_RUNTIME_ID")"
  simulator_created=1
fi
echo "    Simulator UDID: $sim_udid"

echo "==> Ensuring the pinned iPad exists: $IPAD_DEVICE_NAME / iOS $SIM_OS_VERSION"
# -F: the device name contains literal parentheses. The trailing " (" anchors
# the match to the UDID column so a same-prefix variant (e.g. the "(16GB)"
# device type) can't be picked up by accident.
ipad_simulator_created=0
ipad_udid="$(xcrun simctl list devices "$SIM_OS_VERSION" | grep -F "$IPAD_DEVICE_NAME (" | grep -oE '[0-9A-F-]{36}' | head -1 || true)"
if [[ -z "$ipad_udid" ]]; then
  echo "    Creating $IPAD_DEVICE_NAME (iOS $SIM_OS_VERSION) simulator..."
  ipad_udid="$(xcrun simctl create "$IPAD_DEVICE_NAME" "$IPAD_DEVICETYPE_ID" "$SIM_RUNTIME_ID")"
  ipad_simulator_created=1
fi
echo "    iPad UDID: $ipad_udid"

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
# reuse while making the entire test run disposable.
derived_data_dir="$(mktemp -d "${TMPDIR:-/tmp}/gradus-test-gate-derived-data.XXXXXX")"

# Preserve a developer's already-running simulator and its account/share state.
# A gate-created disposable simulator can still be stopped after the run to
# avoid leaving a new background workload behind.
trap '
  if [[ "${GRADUS_KEEP_SIMULATORS:-0}" == "1" ]]; then
    echo "==> Leaving simulators running (GRADUS_KEEP_SIMULATORS=1)"
  else
    if [[ "$simulator_created" == "1" ]]; then
      xcrun simctl shutdown "$sim_udid" >/dev/null 2>&1 || true
    fi
    if [[ "$ipad_simulator_created" == "1" ]]; then
      xcrun simctl shutdown "$ipad_udid" >/dev/null 2>&1 || true
    fi
    if [[ "$simulator_created" != "1" && "$ipad_simulator_created" != "1" ]]; then
      echo "==> Leaving pre-existing simulators running"
    fi
  fi
  if [[ -z "$prior_dialog_type" ]]; then
    defaults delete com.apple.CrashReporter DialogType >/dev/null 2>&1 || true
  else
    defaults write com.apple.CrashReporter DialogType "$prior_dialog_type"
  fi
  rm -rf "$derived_data_dir"
' EXIT

echo "==> Booting simulators"
xcrun simctl bootstatus "$sim_udid" -b || true
xcrun simctl bootstatus "$ipad_udid" -b || true

echo "==> xcodebuild test — GradusMac (platform=macOS)"
# Tests execute local Debug products and do not produce a distributable artifact.
# Keeping signing disabled here avoids provisioning/account state becoming a false test gate;
# archive, export, and notarization scripts retain their normal signing paths.
assert_counting_leg "GradusMac" env GRADUS_DISABLE_PIPELINE=1 xcodebuild test \
  -project Gradus.xcodeproj \
  -derivedDataPath "$derived_data_dir" \
  -scheme GradusMac \
  -destination 'platform=macOS,arch=arm64' \
  -skip-testing:GradusMacUITests \
  CODE_SIGNING_ALLOWED=NO

density_snapshot_skip_args=()
density_snapshot_only_args=()
for selector in "${DENSITY_IMAGE_SNAPSHOT_TEST_SELECTORS[@]}"; do
  density_snapshot_skip_args+=("-skip-testing:$selector")
  density_snapshot_only_args+=("-only-testing:$selector")
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

# GradusiOSUITests has its own named iPhone leg below. Keeping it out of this
# broad unit-test pass prevents Xcode from bootstrapping the same UI runner
# twice, while the dedicated leg still makes loss of UI coverage visible.

# `DensityLayoutXCUITests` runs on the iPhone destination above too, but only
# here does the adaptive grid resolve to multiple columns. The test carries no
# idiom skip, so removing this step would not make it go silently green -- it
# would just stop covering the multi-column geometry. Kept as a named,
# separate gate line so that loss is visible if anyone deletes it.
echo "==> xcodebuild test — GradusiOS UI tests ($IPAD_DEVICE_NAME / iOS $SIM_OS_VERSION simulator)"
assert_counting_leg "GradusiOS-iPad" xcodebuild test \
  -project Gradus.xcodeproj \
  -derivedDataPath "$derived_data_dir" \
  -scheme GradusiOS \
  -destination "platform=iOS Simulator,id=$ipad_udid" \
  -only-testing:GradusiOSUITests \
  "${density_snapshot_only_args[@]}" \
  CODE_SIGNING_ALLOWED=NO

echo "==> xcodebuild test — GradusMacUITests target (platform=macOS)"
assert_counting_leg "GradusMacUI" env GRADUS_DISABLE_PIPELINE=1 xcodebuild test \
  -project Gradus.xcodeproj \
  -derivedDataPath "$derived_data_dir" \
  -scheme GradusMac \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:GradusMacUITests \
  CODE_SIGN_IDENTITY="Apple Development" \
  DEVELOPMENT_TEAM=4CJ49V6QHW \
  CODE_SIGN_ENTITLEMENTS="" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  PROVISIONING_PROFILE_SPECIFIER=""

echo "==> xcodebuild test — GradusiOSUITests target (iPhone 16 / iOS $SIM_OS_VERSION simulator)"
assert_counting_leg "GradusiOSUI" xcodebuild test \
  -project Gradus.xcodeproj \
  -derivedDataPath "$derived_data_dir" \
  -scheme GradusiOS \
  -destination "platform=iOS Simulator,id=$sim_udid" \
  -only-testing:GradusiOSUITests \
  CODE_SIGNING_ALLOWED=NO

assert_counting_legs_complete

echo "==> test-gate.sh: all destinations green"
fi
