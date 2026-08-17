#!/usr/bin/env bash
# notify.sh — shared launchd failure notification + ldstatus-parity helper.
#
# Sourced by agent runner scripts (macOS only; uses /usr/bin/osascript).
# Design + review: ~/.launchd/plans/ldstatus-failure-notify-2026-05-24.md
#
# Two public functions:
#   notify_failure <AGENT> <short_reason>
#       Fire a macOS banner. Body is INTENTIONALLY generic (agent + short reason
#       only) — never raw stderr/paths, for privacy + AppleScript-injection
#       safety (strings are passed as `on run argv`, not interpolated into -e
#       source). Backgrounded with a watchdog so a stuck osascript can never hold
#       a launchd lock. ALWAYS returns 0 (never aborts a `set -e` caller).
#
#   install_failure_trap <AGENT> <ldstatus_logfile>
#       Chain an EXIT trap (preserving any existing one) that, on NONZERO exit,
#       (a) appends a canonical "<agent>: run failed with exit code N" line to the
#       ldstatus-parsed log unless the run already logged its own failure, and
#       (b) notifies. This makes ldstatus and the notifier catch the SAME
#       failures — including nonzero-exit aborts (e.g. DNS timeouts) that carry no
#       "failed" marker. Call AFTER the script installs its own EXIT trap.
#
#   notify_mark_logged_failure
#       Call this right where a script logs its own failure line, so the EXIT
#       trap does not emit a duplicate canonical line / double-count in ldstatus.

# Guard against double-sourcing.
[ -n "${_LAUNCHD_NOTIFY_SH:-}" ] && return 0
_LAUNCHD_NOTIFY_SH=1

NOTIFY_OSASCRIPT="${NOTIFY_OSASCRIPT:-/usr/bin/osascript}"

notify_failure() {
  local agent="${1:-launchd}" reason="${2:-run failed}"
  [ -x "${NOTIFY_OSASCRIPT}" ] || return 0
  (
    "${NOTIFY_OSASCRIPT}" \
      -e 'on run {t, m}' \
      -e 'display notification m with title t' \
      -e 'end run' \
      "launchd: ${agent} FAILED" "${reason}" >/dev/null 2>&1 &
    op=$!
    ( sleep 10; kill "${op}" 2>/dev/null ) &
    wd=$!
    wait "${op}" 2>/dev/null
    kill "${wd}" 2>/dev/null
  ) >/dev/null 2>&1 &
  return 0
}

notify_mark_logged_failure() { _NOTIFY_RUN_FAILED_LOGGED=1; }

_notify_on_exit() {
  local agent="$1" logfile="$2" rc="$3"
  # Run any previously-installed EXIT handler first (e.g. lock cleanup).
  if [ -n "${_NOTIFY_PRIOR_EXIT_TRAP:-}" ]; then
    eval "${_NOTIFY_PRIOR_EXIT_TRAP}"
  fi
  [ "${rc}" -ne 0 ] || return 0
  # If the run already logged + notified its own failure (via the log() hook),
  # the failure is already visible to ldstatus and already alerted — do nothing
  # more, so we neither double-notify nor double-count.
  [ -n "${_NOTIFY_RUN_FAILED_LOGGED:-}" ] && return 0
  # Otherwise this is a marker-less nonzero exit (e.g. a DNS-timeout abort):
  # emit a canonical line so ldstatus shows it, and notify.
  if [ -n "${logfile}" ]; then
    printf '[%s] %s: run failed with exit code %s\n' \
      "$(date '+%Y-%m-%d %H:%M:%S %Z')" "${agent}" "${rc}" >> "${logfile}" 2>/dev/null || true
  fi
  notify_failure "${agent}" "run failed (exit ${rc})"
}

install_failure_trap() {
  local agent="$1" logfile="$2" existing
  existing="$(trap -p EXIT)"
  if [ -n "${existing}" ]; then
    # `trap -p EXIT` prints: trap -- '<cmd>' EXIT  → extract <cmd>.
    _NOTIFY_PRIOR_EXIT_TRAP="$(printf '%s\n' "${existing}" | sed "s/^trap -- '//; s/' EXIT\$//")"
  fi
  _NOTIFY_AGENT="${agent}"
  _NOTIFY_LOGFILE="${logfile}"
  # shellcheck disable=SC2064
  trap '_notify_on_exit "${_NOTIFY_AGENT}" "${_NOTIFY_LOGFILE}" "$?"' EXIT
}
