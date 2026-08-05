#!/usr/bin/env bash
# Phase-gate for the Gradus iOS/macOS work: boots the pinned simulator and
# runs `xcodebuild test` for both destinations. Exits non-zero on any
# failure (preflight mismatch, build failure, or test failure) so it's safe
# to wire into CI/pre-push as a hard gate.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> Hermetic notarization script behavior tests"
./test-notary-scripts.sh

echo "==> Hermetic iOS upload wrapper behavior tests"
./test-archive-upload-ios.sh

# INV-11 declares `area:` over app/GradusKit/**, gradus/**, and tests/** with
# this script as its gate_test -- but the two `xcodebuild test` invocations
# below cover none of those three. GradusKit is consumed as a SwiftPM package
# *dependency*, so `xcodebuild test -scheme ...` builds its library product and
# never its test targets; XcodeGen can't add them to a scheme's `test:` block
# either, since they aren't project targets. Result (found 2026-08-05): 47
# passing GradusKit tests -- the reconciliation core both apps import -- sat
# entirely outside the release gate, and the Python suite only ran via
# pre-push. Both run here now, ordered before the slow simulator work so the
# gate fails fast.
echo "==> swift test — GradusKit package (SwiftPM; not reachable via either app scheme)"
swift test --package-path GradusKit

echo "==> pytest — Python producer suite (INV-1..INV-6, INV-8)"
(cd .. && uv run pytest -q)

PINNED_XCODE_VERSION="$(cat .xcode-version)"
SIM_DEVICE_NAME="iPhone 16"
SIM_OS_VERSION="26.5"
SIM_RUNTIME_ID="com.apple.CoreSimulator.SimRuntime.iOS-26-5"
SIM_DEVICETYPE_ID="com.apple.CoreSimulator.SimDeviceType.iPhone-16"

# iPad Option B renders only at the regular horizontal size class, which the
# iPhone destination never reaches -- so the dense grid's routing and its
# tap-to-detail wiring had no destination that could execute them. Pinned to
# the 11-inch (834x1194 points) because that is exactly the geometry
# `DensityLayoutSnapshotTests` records its baselines at; a different iPad
# would still be "regular width" but would no longer describe the same layout
# the snapshots do. Only `GradusiOSUITests` runs here -- rerunning the whole
# iOS suite on a second simulator would roughly double the gate's slowest
# phase to re-prove device-independent behavior.
IPAD_DEVICE_NAME="iPad Pro 11-inch (M5)"
IPAD_DEVICETYPE_ID="com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB"

echo "==> Preflight: Xcode + simulator OS must match the pins (PM-9)"
active_xcode_version="$(xcodebuild -version | head -1 | awk '{print $2}')"
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
sim_udid="$(xcrun simctl list devices "$SIM_OS_VERSION" | grep "$SIM_DEVICE_NAME (" | grep -oE '[0-9A-F-]{36}' | head -1 || true)"
if [[ -z "$sim_udid" ]]; then
  echo "    Creating $SIM_DEVICE_NAME (iOS $SIM_OS_VERSION) simulator..."
  sim_udid="$(xcrun simctl create "$SIM_DEVICE_NAME" "$SIM_DEVICETYPE_ID" "$SIM_RUNTIME_ID")"
fi
echo "    Simulator UDID: $sim_udid"

echo "==> Ensuring the pinned iPad exists: $IPAD_DEVICE_NAME / iOS $SIM_OS_VERSION"
# -F: the device name contains literal parentheses. The trailing " (" anchors
# the match to the UDID column so a same-prefix variant (e.g. the "(16GB)"
# device type) can't be picked up by accident.
ipad_udid="$(xcrun simctl list devices "$SIM_OS_VERSION" | grep -F "$IPAD_DEVICE_NAME (" | grep -oE '[0-9A-F-]{36}' | head -1 || true)"
if [[ -z "$ipad_udid" ]]; then
  echo "    Creating $IPAD_DEVICE_NAME (iOS $SIM_OS_VERSION) simulator..."
  ipad_udid="$(xcrun simctl create "$IPAD_DEVICE_NAME" "$IPAD_DEVICETYPE_ID" "$SIM_RUNTIME_ID")"
fi
echo "    iPad UDID: $ipad_udid"

# A crashing test (e.g. a segfault inside a snapshot-diffing dependency)
# still produces a valid, useful .ips in ~/Library/Logs/DiagnosticReports --
# only the interactive "GradusiOS quit unexpectedly" dialog is suppressed,
# scoped to this run and restored on exit so it never leaks into the rest
# of the system.
prior_dialog_type="$(defaults read com.apple.CrashReporter DialogType 2>/dev/null || true)"
defaults write com.apple.CrashReporter DialogType none

# Bug fix: the gate previously left the simulator running after tests
# finished (any exit path, including failures). Background simulator
# daemons (e.g. mediaanalysisd re-indexing the simulated Photos library)
# can then spin at 800%+ CPU indefinitely with nothing to notice or stop
# them. Shut the simulator down on every exit path so a gate run never
# leaves runaway processes behind.
trap '
  echo "==> Shutting down simulators to release their background processes"
  xcrun simctl shutdown "$sim_udid" >/dev/null 2>&1 || true
  xcrun simctl shutdown "$ipad_udid" >/dev/null 2>&1 || true
  if [[ -z "$prior_dialog_type" ]]; then
    defaults delete com.apple.CrashReporter DialogType >/dev/null 2>&1 || true
  else
    defaults write com.apple.CrashReporter DialogType "$prior_dialog_type"
  fi
' EXIT

echo "==> Booting simulators"
xcrun simctl bootstatus "$sim_udid" -b || true
xcrun simctl bootstatus "$ipad_udid" -b || true

echo "==> xcodebuild test — GradusMac (platform=macOS)"
xcodebuild test \
  -project Gradus.xcodeproj \
  -scheme GradusMac \
  -destination 'platform=macOS' \
  -allowProvisioningUpdates

echo "==> xcodebuild test — GradusiOS (iPhone 16 / iOS $SIM_OS_VERSION simulator)"
xcodebuild test \
  -project Gradus.xcodeproj \
  -scheme GradusiOS \
  -destination "platform=iOS Simulator,id=$sim_udid" \
  -allowProvisioningUpdates

# `DensityLayoutXCUITests` self-skips on the iPhone destination above, so this
# step is the only place iPad Option B's routing and tap-to-detail wiring are
# executed at all. If this step is ever removed, that file goes silently green
# rather than failing -- which is why it is a named, separate gate line.
echo "==> xcodebuild test — GradusiOS UI tests ($IPAD_DEVICE_NAME / iOS $SIM_OS_VERSION simulator)"
xcodebuild test \
  -project Gradus.xcodeproj \
  -scheme GradusiOS \
  -destination "platform=iOS Simulator,id=$ipad_udid" \
  -only-testing:GradusiOSUITests \
  -allowProvisioningUpdates

echo "==> test-gate.sh: all destinations green"
