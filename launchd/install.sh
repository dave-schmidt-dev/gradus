#!/usr/bin/env bash
# Install or remove Gradus's credential-aware snapshot refresher.
#
# The default paths are deliberately local to this checkout and this user's
# launchd domain. The GRADUS_* overrides make the script hermetic in tests;
# they are not a second installation mechanism.
set -euo pipefail

readonly LABEL="local.gradus-snapshot"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="${GRADUS_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
readonly INSTALL_HOME="${GRADUS_HOME:-$HOME}"
readonly PYTHON_PATH="${GRADUS_PYTHON_PATH:-$REPO_ROOT/.venv/bin/python3}"
readonly LAUNCHCTL="${GRADUS_LAUNCHCTL:-launchctl}"
readonly DOMAIN="gui/$(id -u)"
readonly JOB="$DOMAIN/$LABEL"
readonly WRAPPER="$INSTALL_HOME/.launchd/scripts/gradus_snapshot.sh"
readonly PLIST="$INSTALL_HOME/Library/LaunchAgents/$LABEL.plist"
readonly LOG_DIR="$INSTALL_HOME/Library/Logs/homelab/gradus-snapshot"
readonly SNAPSHOT_V2_PATH="${GRADUS_SNAPSHOT_V2_PATH:-$REPO_ROOT/.state/snapshot-v2.json}"
readonly VERIFY_DURATION="${GRADUS_VERIFY_DURATION:-360}"
readonly VERIFY_INTERVAL="${GRADUS_HEALTH_INTERVAL:-120}"
readonly PROGRESS_INTERVAL="${GRADUS_PROGRESS_INTERVAL:-30}"
readonly RUN_AT_LOAD_TIMEOUT="${GRADUS_RUN_AT_LOAD_TIMEOUT:-$VERIFY_INTERVAL}"
# Start verifier polls one visible-progress quantum after a confirmed refresh.
# This preserves the verifier's fixed duration and cadence while keeping its
# 120-second reads out of phase with launchd's 120-second StartInterval edge.
readonly VERIFY_PHASE_OFFSET="${GRADUS_VERIFY_PHASE_OFFSET:-$PROGRESS_INTERVAL}"

usage() {
  cat <<'EOF'
Usage: launchd/install.sh [install|uninstall]

Install renders and bootstraps the refresh agent, then proves three fresh
provider samples. Uninstall bootouts the agent and removes only its wrapper and
plist.
EOF
}

progress() {
  printf '[%s] gradus launchd: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

sed_escape() {
  printf '%s' "$1" | sed -e 's/[\\/&|]/\\&/g'
}

render_if_changed() {
  local template="$1"
  local target="$2"
  local mode="$3"
  local temporary
  temporary="$(mktemp "${TMPDIR:-/tmp}/gradus-launchd.XXXXXX")"

  sed \
    -e "s|__GRADUS_REPO_ROOT__|$(sed_escape "$REPO_ROOT")|g" \
    -e "s|__GRADUS_PYTHON_PATH__|$(sed_escape "$PYTHON_PATH")|g" \
    -e "s|__GRADUS_WRAPPER_PATH__|$(sed_escape "$WRAPPER")|g" \
    -e "s|__GRADUS_STDOUT_PATH__|$(sed_escape "$LOG_DIR/stdout.log")|g" \
    -e "s|__GRADUS_STDERR_PATH__|$(sed_escape "$LOG_DIR/stderr.log")|g" \
    "$template" > "$temporary"

  if ! cmp -s "$temporary" "$target" 2>/dev/null; then
    install -m "$mode" "$temporary" "$target"
    progress "rendered $target"
  fi
  rm -f "$temporary"
}

require_tools() {
  [[ -x "$PYTHON_PATH" ]] || {
    printf 'FAIL: Gradus Python is not executable: %s\n' "$PYTHON_PATH" >&2
    return 66
  }
  command -v "$LAUNCHCTL" >/dev/null || {
    printf 'FAIL: launchctl command is unavailable: %s\n' "$LAUNCHCTL" >&2
    return 69
  }
}

job_state() {
  local output status
  if output="$("$LAUNCHCTL" print "$JOB" 2>&1)"; then
    printf 'loaded\n'
    return 0
  fi
  status=$?
  case "$output" in
    *"Could not find service"*|*"No such process"*)
      printf 'absent\n'
      ;;
    *)
      printf 'FAIL: could not query launchctl state for %s (exit %s).\n' "$LABEL" "$status" >&2
      printf 'unknown\n'
      ;;
  esac
}

run_with_progress() {
  local activity="$1"
  shift
  progress "$activity"
  (
    while sleep "$PROGRESS_INTERVAL"; do
      progress "${activity} is still running"
    done
  ) &
  local heartbeat_pid=$!
  local result
  if "$@"; then
    result=0
  else
    result=$?
  fi
  kill "$heartbeat_pid" 2>/dev/null || true
  wait "$heartbeat_pid" 2>/dev/null || true
  return "$result"
}

snapshot_updated_at_epoch() {
  "$PYTHON_PATH" - "$SNAPSHOT_V2_PATH" <<'PY'
import calendar
import json
import sys
from datetime import datetime, timezone

try:
    with open(sys.argv[1], encoding="utf-8") as snapshot_file:
        payload = json.load(snapshot_file)
    value = payload.get("updated_at")
    if not isinstance(value, str):
        raise ValueError("missing updated_at")
    if value.endswith("Z"):
        value = f"{value[:-1]}+00:00"
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        raise ValueError("naive updated_at")
    utc = parsed.astimezone(timezone.utc)
except (OSError, ValueError, TypeError, json.JSONDecodeError):
    raise SystemExit(1)

print(calendar.timegm(utc.utctimetuple()) * 1_000_000 + utc.microsecond)
PY
}

wait_for_run_at_load_refresh() {
  local before="$1"
  local observed
  local started=$SECONDS

  progress "waiting for RunAtLoad snapshot metadata"
  while true; do
    observed="$(snapshot_updated_at_epoch || true)"
    if [[ "$observed" =~ ^[0-9]+$ ]] && {
      [[ -z "$before" ]] || (( observed > before ))
    }; then
      progress "observed RunAtLoad snapshot metadata advance"
      return 0
    fi

    if (( SECONDS - started >= RUN_AT_LOAD_TIMEOUT )); then
      printf 'FAIL: RunAtLoad did not advance snapshot metadata within %ss.\n' \
        "$RUN_AT_LOAD_TIMEOUT" >&2
      return 1
    fi
    progress "waiting for RunAtLoad snapshot metadata"
    sleep "$PROGRESS_INTERVAL"
  done
}

offset_verifier_from_refresh() {
  run_with_progress \
    "waiting ${VERIFY_PHASE_OFFSET}s after RunAtLoad before health verification" \
    sleep "$VERIFY_PHASE_OFFSET"
}

verify_health_with_progress() {
  if ! run_with_progress "verifying refresh health for ${VERIFY_DURATION}s" \
    "$PYTHON_PATH" -m gradus --verify-refresh-health \
    --duration "$VERIFY_DURATION" --health-interval "$VERIFY_INTERVAL"; then
    progress "refresh-health verification failed"
    return 1
  fi
  progress "refresh-health verification passed"
}

install_agent() {
  local state before_bootstrap
  require_tools
  mkdir -p "$(dirname "$WRAPPER")" "$(dirname "$PLIST")" "$LOG_DIR"
  render_if_changed "$SCRIPT_DIR/gradus_snapshot.sh.in" "$WRAPPER" 755
  render_if_changed "$SCRIPT_DIR/local.gradus-snapshot.plist.in" "$PLIST" 644
  plutil -lint "$PLIST" >/dev/null

  state="$(job_state)"
  case "$state" in
    loaded)
      progress "reloading $LABEL"
      "$LAUNCHCTL" bootout "$JOB"
      ;;
    absent) ;;
    unknown|*) return 70 ;;
  esac

  # RunAtLoad is asynchronous. Capture only the safe timestamp metadata before
  # bootstrap, then wait for its own write rather than racing a manual refresh
  # against the verifier's first poll.
  before_bootstrap="$(snapshot_updated_at_epoch || true)"
  "$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST"
  state="$(job_state)"
  case "$state" in
    loaded) ;;
    absent)
      printf 'FAIL: launchctl did not retain %s after bootstrap.\n' "$LABEL" >&2
      return 70
      ;;
    unknown|*) return 70 ;;
  esac
  wait_for_run_at_load_refresh "$before_bootstrap"
  offset_verifier_from_refresh
  verify_health_with_progress
}

uninstall_agent() {
  local state
  require_tools
  state="$(job_state)"
  case "$state" in
    loaded)
      progress "removing $LABEL"
      "$LAUNCHCTL" bootout "$JOB"
      ;;
    absent) ;;
    unknown|*) return 70 ;;
  esac

  state="$(job_state)"
  case "$state" in
    absent) ;;
    loaded)
      printf 'FAIL: launchctl still lists %s after bootout.\n' "$LABEL" >&2
      return 70
      ;;
    unknown|*) return 70 ;;
  esac
  rm -f "$WRAPPER" "$PLIST"
  progress "removed wrapper and plist"
}

case "${1:-install}" in
  install) install_agent ;;
  uninstall) uninstall_agent ;;
  -h|--help) usage ;;
  *) printf 'FAIL: unknown command: %s\n' "$1" >&2; usage >&2; exit 64 ;;
esac
