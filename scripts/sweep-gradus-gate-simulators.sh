#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

SCRIPT_PATH="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"

if [[ "${1:-}" == "--locked" ]]; then
  [[ "$#" -eq 1 ]] || fail "unexpected arguments while holding the Simulator lock"
  inventory="$(xcrun simctl list devices --json)" || fail "could not list Simulator devices"
  candidates="$(printf '%s' "$inventory" | /usr/bin/python3 -c '
import json
import re
import sys
import uuid

try:
    inventory = json.load(sys.stdin)
except (json.JSONDecodeError, OSError) as error:
    raise SystemExit(f"invalid simctl JSON: {error}")
if not isinstance(inventory, dict) or not isinstance(inventory.get("devices"), dict):
    raise SystemExit("simctl inventory has no devices object")

seen = set()
for runtime, devices in inventory["devices"].items():
    if not isinstance(runtime, str) or not isinstance(devices, list):
        raise SystemExit("simctl devices inventory has an invalid runtime entry")
    for device in devices:
        if not isinstance(device, dict):
            raise SystemExit("simctl devices inventory contains a non-object device")
        udid, name, state = (device.get(key) for key in ("udid", "name", "state"))
        if not all(isinstance(value, str) and value for value in (udid, name, state)):
            raise SystemExit("simctl device is missing a non-empty udid, name, or state")
        if any("\t" in value or "\n" in value or "\r" in value for value in (udid, name, state)):
            raise SystemExit("simctl device contains a malformed field")
        try:
            uuid.UUID(udid)
        except ValueError:
            raise SystemExit("simctl device has an invalid UDID")
        if udid in seen:
            raise SystemExit("simctl inventory contains a duplicate UDID")
        seen.add(udid)
        match = re.match(r"^gradus-gate-([1-9][0-9]*)-", name)
        if match:
            print("\t".join((match.group(1), udid, name, state)))
')" || fail "could not parse Simulator inventory; no devices were changed"

  failures=0
  while IFS=$'\t' read -r creator_pid udid name state; do
    [[ -n "$udid" ]] || continue
    if kill -0 "$creator_pid" 2>/dev/null; then
      echo "sweep-gradus-gate-simulators: keeping $name ($udid); creator pid=$creator_pid is live" >&2
      continue
    fi
    if [[ "$state" != "Shutdown" ]]; then
      if xcrun simctl shutdown "$udid"; then
        echo "sweep-gradus-gate-simulators: shut down $name ($udid), prior state=$state" >&2
      else
        echo "FAIL: could not shut down abandoned Gradus simulator $name ($udid)" >&2
        failures=1
        continue
      fi
    fi
    if xcrun simctl delete "$udid"; then
      echo "sweep-gradus-gate-simulators: deleted $name ($udid)" >&2
    else
      echo "FAIL: could not delete abandoned Gradus simulator $name ($udid)" >&2
      failures=1
    fi
  done <<< "$candidates"
  (( failures == 0 )) || exit 1
  exit 0
fi

[[ "$#" -eq 0 ]] || fail "usage: sweep-gradus-gate-simulators.sh"
lock_bin="${APPLE_UI_TEST_LOCK:-$HOME/.agent/bin/apple-ui-test-lock}"
[[ -x "$lock_bin" ]] || fail "host UI lock helper not found or not executable: $lock_bin"
"$lock_bin" --label "Gradus abandoned simulator cleanup" -- "$SCRIPT_PATH" --locked \
  || fail "could not acquire the host Simulator lock or complete the Gradus sweep"
