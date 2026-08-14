#!/usr/bin/env bash
#
# Profile-free test build for the switchyard macOS VM lane.
#
# The VM guest holds no Apple Development identity, no team membership, and no
# provisioning profile. Two failure modes follow from that, and this script
# exists to sit between them:
#
#   * Building against DEVELOPMENT_TEAM / a profile fails outright in the guest,
#     because neither is installed there.
#   * Building with CODE_SIGNING_ALLOWED=NO produces an unsigned Mach-O that
#     AMFI SIGKILLs at exec on Apple silicon. xcodebuild reports that as
#     "Test crashed with signal kill before establishing connection", which
#     reads like a test bug and is not one.
#
# An ad-hoc identity ("-") satisfies AMFI without needing a team, so that is
# what the macOS schemes build with here. The iOS scheme needs no overrides at
# all: Xcode already signs simulator products ad-hoc and strips entitlements
# from them, so a bare build is profile-free on its own.
#
# Usage:
#   scripts/vm-test-build.sh <scheme> [extra xcodebuild args...]
#
# Environment:
#   VM_TEST_DERIVED_DATA  derived data path (default: build/vm-test)
#   VM_TEST_SIM_UDID      iOS simulator UDID for GradusiOS (default: newest available)

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly PROJECT="${REPO_ROOT}/app/Gradus.xcodeproj"

scheme="${1:-}"
if [[ -z "${scheme}" ]]; then
  echo "usage: $(basename "$0") <scheme> [extra xcodebuild args...]" >&2
  echo "schemes: GradusMac, GradusCredentialBridge, GradusiOS" >&2
  exit 2
fi
shift

derived_data="${VM_TEST_DERIVED_DATA:-${REPO_ROOT}/build/vm-test}"

# The profile-free override set, applied to the macOS schemes only.
#
# CODE_SIGN_INJECT_BASE_ENTITLEMENTS is deliberately absent. GradusMac's Debug
# config already sets it to NO, along with an empty CODE_SIGN_ENTITLEMENTS, so
# that local Mac tests do not depend on a stale provisioning profile; forcing a
# value here would make the guest build something the host never tests. The
# entitlements and profile clears below are therefore redundant for GradusMac,
# and necessary for GradusCredentialBridge, which has no per-config Debug
# overrides at all. Stating them explicitly keeps the guest correct either way.
readonly -a PROFILE_FREE_OVERRIDES=(
  CODE_SIGN_IDENTITY=-
  CODE_SIGN_STYLE=Manual
  DEVELOPMENT_TEAM=
  PROVISIONING_PROFILE_SPECIFIER=
  CODE_SIGN_ENTITLEMENTS=
)

resolve_simulator() {
  if [[ -n "${VM_TEST_SIM_UDID:-}" ]]; then
    printf '%s' "${VM_TEST_SIM_UDID}"
    return
  fi
  # Resolve to a UDID, never a name: duplicate device names across runtimes make
  # `name=` ambiguous and xcodebuild picks one of them without saying which.
  local udid
  udid="$(xcrun simctl list devices available --json |
    /usr/bin/python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
runtimes = sorted(k for k in devices if "iOS" in k)
for runtime in reversed(runtimes):
    for device in devices[runtime]:
        if device.get("isAvailable"):
            print(device["udid"])
            sys.exit(0)
sys.exit(1)
')"
  if [[ -z "${udid}" ]]; then
    echo "error: no available iOS simulator; set VM_TEST_SIM_UDID" >&2
    exit 1
  fi
  printf '%s' "${udid}"
}

case "${scheme}" in
  GradusMac | GradusCredentialBridge)
    destination="platform=macOS,arch=arm64"
    overrides=("${PROFILE_FREE_OVERRIDES[@]}")
    overrides_label="ad-hoc identity, no team, no profile, no entitlements file"
    products_subdir="Debug"
    ;;
  GradusiOS)
    destination="platform=iOS Simulator,id=$(resolve_simulator)"
    overrides=()
    overrides_label="none (simulator products are ad-hoc signed by default)"
    products_subdir="Debug-iphonesimulator"
    ;;
  *)
    echo "error: unknown scheme '${scheme}'" >&2
    echo "schemes: GradusMac, GradusCredentialBridge, GradusiOS" >&2
    exit 2
    ;;
esac

echo "==> building ${scheme} for testing" >&2
echo "    destination:  ${destination}" >&2
echo "    derived data: ${derived_data}" >&2
echo "    overrides:    ${overrides_label}" >&2

xcodebuild \
  -project "${PROJECT}" \
  -scheme "${scheme}" \
  -destination "${destination}" \
  -derivedDataPath "${derived_data}" \
  ${overrides[@]+"${overrides[@]}"} \
  build-for-testing \
  "$@"

# Verify the claim rather than assume it. A team identifier reappearing here is
# the signal that some target regained a signing setting the guest cannot honor,
# and it is far cheaper to catch that on the host than as a build failure in the
# VM twenty minutes later.
products_dir="${derived_data}/Build/Products/${products_subdir}"
echo "==> verifying products are profile-free" >&2

failures=0
checked=0
while IFS= read -r bundle; do
  checked=$((checked + 1))
  info="$(codesign -dvvv "${bundle}" 2>&1 || true)"
  name="$(basename "${bundle}")"
  if ! grep -q 'Signature=adhoc' <<<"${info}"; then
    echo "    FAIL ${name}: not ad-hoc signed" >&2
    failures=$((failures + 1))
  elif ! grep -q 'TeamIdentifier=not set' <<<"${info}"; then
    echo "    FAIL ${name}: carries a TeamIdentifier" >&2
    failures=$((failures + 1))
  else
    echo "    ok   ${name}" >&2
  fi
done < <(find "${products_dir}" \( -name '*.app' -o -name '*.xctest' \) | sort)

if ((checked == 0)); then
  echo "error: no bundles found under ${products_dir}" >&2
  exit 1
fi
if ((failures > 0)); then
  echo "error: ${failures} of ${checked} bundles are not profile-free" >&2
  exit 1
fi

echo "==> ${checked} bundles verified profile-free" >&2
echo "    run with: xcodebuild -project ${PROJECT} -scheme ${scheme} \\" >&2
echo "                -destination '${destination}' -derivedDataPath ${derived_data} \\" >&2
echo "                test-without-building" >&2
