#!/usr/bin/env bash
# Phase-gate for the Gradus iOS/macOS work: boots the pinned simulator and
# runs `xcodebuild test` for both destinations. Exits non-zero on any
# failure (preflight mismatch, build failure, or test failure) so it's safe
# to wire into CI/pre-push as a hard gate.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

PINNED_XCODE_VERSION="$(cat .xcode-version)"
SIM_DEVICE_NAME="iPhone 16"
SIM_OS_VERSION="26.5"
SIM_RUNTIME_ID="com.apple.CoreSimulator.SimRuntime.iOS-26-5"
SIM_DEVICETYPE_ID="com.apple.CoreSimulator.SimDeviceType.iPhone-16"

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

echo "==> Booting simulator"
xcrun simctl bootstatus "$sim_udid" -b || true

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

echo "==> test-gate.sh: all destinations green"
