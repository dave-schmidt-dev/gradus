#!/usr/bin/env bash
# Shows GradusMac notarization submissions without exposing credentials.
# Credentials remain in the named macOS Keychain profile used by notarytool.
set -euo pipefail

unset HISTFILE
set +o history 2>/dev/null || true
umask 077

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$APP_DIR/.." && pwd)"
PROFILE="${NOTARY_PROFILE:-gradus-notary}"
STATE_FILE="${GRADUS_NOTARY_STATE_FILE:-$REPO_DIR/.state/notary-submissions.tsv}"
XCRUN="${NOTARY_XCRUN:-xcrun}"
PYTHON="${NOTARY_PYTHON:-python3}"

EXIT_ACCEPTED=0
EXIT_PENDING=2
EXIT_TERMINAL=3
EXIT_EMPTY=4
EXIT_USAGE=64
EXIT_DEPENDENCY=69
EXIT_TOOL=70

watch=false
interval="${NOTARY_POLL_INTERVAL:-30}"
record=false
record_id=""
record_name=""
record_artifact=""
declare -a requested_ids=()

tmp_dir=""
lock_dir=""
lock_owned=false
ledger_tmp=""

cleanup() {
  if $lock_owned && [[ -n "$lock_dir" ]]; then
    rmdir "$lock_dir" 2>/dev/null || true
  fi
  if [[ -n "$ledger_tmp" ]]; then
    rm -f "$ledger_tmp" 2>/dev/null || true
  fi
  if [[ -n "$tmp_dir" ]]; then
    rm -f "$tmp_dir/response.json" "$tmp_dir/records.tsv" "$tmp_dir/all-records.tsv" 2>/dev/null || true
    rmdir "$tmp_dir" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

usage() {
  cat <<'EOF'
Usage:
  ./notary-status.sh [--watch] [--interval SECONDS] [--id SUBMISSION_ID ...]
  ./notary-status.sh --record SUBMISSION_ID --name NAME --artifact ZIP_PATH

Exit status:
  0   every displayed submission is Accepted (or a ledger record was stored)
  2   at least one displayed submission is still In Progress (one-shot only)
  3   at least one displayed submission has a terminal non-Accepted status
  4   no tracked or matching Gradus submission was returned
  64  invalid arguments
  69  a required local tool is missing
  70  notarytool or its Keychain profile could not be used

With no --id, the command checks every ID in the local submission ledger. If
the ledger is empty, it falls back to GradusMac.app.zip entries from Apple's
notary history. --watch polls while submissions remain pending, then exits when
all are accepted or as soon as any terminal failure appears.
EOF
}

fail_usage() {
  echo "FAIL: $1" >&2
  usage >&2
  exit "$EXIT_USAGE"
}

valid_id() {
  [[ "$1" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]
}

clean_field() {
  [[ "$1" != *$'\t'* && "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}

while (($#)); do
  case "$1" in
    --watch)
      watch=true
      shift
      ;;
    --interval)
      (($# >= 2)) || fail_usage "--interval requires a value"
      interval="$2"
      shift 2
      ;;
    --id)
      (($# >= 2)) || fail_usage "--id requires a submission ID"
      valid_id "$2" || fail_usage "invalid submission ID: $2"
      requested_ids+=("$2")
      shift 2
      ;;
    --record)
      (($# >= 2)) || fail_usage "--record requires a submission ID"
      record=true
      record_id="$2"
      shift 2
      ;;
    --name)
      (($# >= 2)) || fail_usage "--name requires a value"
      record_name="$2"
      shift 2
      ;;
    --artifact)
      (($# >= 2)) || fail_usage "--artifact requires a path"
      record_artifact="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail_usage "unknown argument: $1"
      ;;
  esac
done

[[ "$interval" =~ ^[1-9][0-9]*$ ]] || fail_usage "--interval must be a positive integer"

if $record; then
  $watch && fail_usage "--record cannot be combined with --watch"
  ((${#requested_ids[@]} == 0)) || fail_usage "--record cannot be combined with --id"
  valid_id "$record_id" || fail_usage "invalid submission ID: $record_id"
  [[ -n "$record_name" ]] || fail_usage "--record requires --name"
  [[ -n "$record_artifact" ]] || fail_usage "--record requires --artifact"
  clean_field "$record_name" || fail_usage "--name cannot contain tabs or newlines"
  clean_field "$record_artifact" || fail_usage "--artifact cannot contain tabs or newlines"
  [[ -f "$record_artifact" ]] || fail_usage "artifact does not exist: $record_artifact"

  for dependency in shasum awk mkdir chmod date dirname sleep mktemp cp mv rm rmdir; do
    command -v "$dependency" >/dev/null 2>&1 || {
      echo "FAIL: required tool is missing: $dependency" >&2
      exit "$EXIT_DEPENDENCY"
    }
  done

  state_dir="$(dirname "$STATE_FILE")"
  [[ -n "$state_dir" && "$state_dir" != "/" ]] || fail_usage "unsafe ledger directory"
  mkdir -p "$state_dir"
  chmod 700 "$state_dir"

  lock_dir="${STATE_FILE}.lock"
  acquired=false
  attempt=1
  while ((attempt <= 100)); do
    if mkdir "$lock_dir" 2>/dev/null; then
      acquired=true
      lock_owned=true
      break
    fi
    sleep 0.05
    ((attempt += 1))
  done
  if ! $acquired; then
    echo "FAIL: timed out waiting for the notarization ledger lock: $lock_dir" >&2
    echo "      If no recorder is running, remove that stale lock directory and retry." >&2
    exit "$EXIT_TOOL"
  fi

  if [[ -f "$STATE_FILE" ]] && awk -F $'\t' -v id="$record_id" '$2 == id { found = 1 } END { exit !found }' "$STATE_FILE"; then
    echo "Submission already recorded: $record_id"
    exit 0
  fi

  submitted_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  artifact_hash="$(shasum -a 256 "$record_artifact" | awk '{print $1}')"
  ledger_tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")"
  if [[ -f "$STATE_FILE" ]]; then
    cp "$STATE_FILE" "$ledger_tmp"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$submitted_at" "$record_id" "$record_name" "$record_artifact" "$artifact_hash" >>"$ledger_tmp"
  chmod 600 "$ledger_tmp"
  mv "$ledger_tmp" "$STATE_FILE"
  ledger_tmp=""
  echo "Recorded submission: $record_id"
  echo "Ledger: $STATE_FILE"
  exit 0
fi

for dependency in "$XCRUN" "$PYTHON" mktemp date sleep cat mv rm rmdir; do
  command -v "$dependency" >/dev/null 2>&1 || {
    echo "FAIL: required tool is missing: $dependency" >&2
    exit "$EXIT_DEPENDENCY"
  }
done

if ((${#requested_ids[@]})); then
  status_source="requested submission IDs, refreshed from Apple"
else
  status_source="Apple notarization history"
fi
if ((${#requested_ids[@]} == 0)) && [[ -s "$STATE_FILE" ]]; then
  while IFS=$'\t' read -r _submitted id _name _artifact _hash; do
    [[ -n "$id" ]] || continue
    if ! valid_id "$id"; then
      echo "FAIL: local notarization ledger contains an invalid submission ID." >&2
      echo "      Ledger: $STATE_FILE" >&2
      exit "$EXIT_TOOL"
    fi
    requested_ids+=("$id")
  done <"$STATE_FILE"
  status_source="local ledger ($STATE_FILE), refreshed from Apple"
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/gradus-notary-status.XXXXXX")"
response_file="$tmp_dir/response.json"
records_file="$tmp_dir/records.tsv"

progress() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$1" >&2
}

explain_request_failure() {
  echo "FAIL: Apple notarytool $1 request failed using profile '$PROFILE'." >&2
  echo "      This can be a service, network, request, or Keychain-profile issue." >&2
  echo "      A sandboxed agent may not be able to see the login Keychain even when" >&2
  echo "      the profile exists. Retry in Terminal or approve an outside-sandbox" >&2
  echo "      check. To test history and profile access without submitting:" >&2
  echo "      xcrun notarytool history --keychain-profile $PROFILE" >&2
}

parse_response() {
  local mode="$1"
  "$PYTHON" - "$response_file" "$mode" >"$records_file" <<'PY'
import json
import sys

path, mode = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    payload = json.load(handle)

if mode == "history":
    records = payload.get("history", [])
else:
    records = [payload]

for record in records:
    name = str(record.get("name", "(unknown)"))
    if mode == "history" and name != "GradusMac.app.zip":
        continue
    values = (
        name,
        str(record.get("id", "(unknown)")),
        str(record.get("createdDate", "(unknown)")),
        str(record.get("status", "(unknown)")),
    )
    print("\t".join(value.replace("\t", " ").replace("\r", " ").replace("\n", " ") for value in values))
PY
}

fetch_records() {
  : >"$records_file"
  if ((${#requested_ids[@]})); then
    local id
    for id in "${requested_ids[@]}"; do
      progress "Requesting live Apple notarization info for submission $id"
      if ! "$XCRUN" notarytool info "$id" --keychain-profile "$PROFILE" --output-format json >"$response_file" 2>/dev/null; then
        explain_request_failure "info for submission $id"
        return "$EXIT_TOOL"
      fi
      if ! parse_response info 2>/dev/null; then
        echo "FAIL: notarytool returned unreadable status data for $id." >&2
        return "$EXIT_TOOL"
      fi
      cat "$records_file"
    done >"$tmp_dir/all-records.tsv"
    mv "$tmp_dir/all-records.tsv" "$records_file"
  else
    progress "Requesting live Apple notarization history"
    if ! "$XCRUN" notarytool history --keychain-profile "$PROFILE" --output-format json >"$response_file" 2>/dev/null; then
      explain_request_failure "history"
      return "$EXIT_TOOL"
    fi
    if ! parse_response history 2>/dev/null; then
      echo "FAIL: notarytool returned unreadable history data." >&2
      return "$EXIT_TOOL"
    fi
  fi
}

check_once() {
  local checked_at pending_count=0 terminal_count=0
  if ! fetch_records; then
    return "$EXIT_TOOL"
  fi

  checked_at="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "Notary queue checked: $checked_at"
  echo "Status source: $status_source"
  if [[ ! -s "$records_file" ]]; then
    echo "No GradusMac.app.zip submissions were returned."
    [[ ! -f "$STATE_FILE" ]] || echo "Local submission ledger: $STATE_FILE"
    return "$EXIT_EMPTY"
  fi

  while IFS=$'\t' read -r name id created status; do
    echo "Name:          $name"
    echo "Submission ID: $id"
    echo "Created:       $created"
    echo "Status:        $status"
    echo ""
    case "$status" in
      Accepted) ;;
      "In Progress") ((pending_count += 1)) ;;
      *) ((terminal_count += 1)) ;;
    esac
  done <"$records_file"

  [[ ! -f "$STATE_FILE" ]] || echo "Local submission ledger: $STATE_FILE"

  if ((terminal_count > 0)); then
    return "$EXIT_TERMINAL"
  fi
  if ((pending_count > 0)); then
    return "$EXIT_PENDING"
  fi
  return "$EXIT_ACCEPTED"
}

while true; do
  set +e
  check_once
  result=$?
  set -e

  if ! $watch || ((result != EXIT_PENDING)); then
    exit "$result"
  fi
  echo "Still pending. Checking again in ${interval}s (Ctrl-C to stop; rerun the same command to resume)."
  sleep "$interval"
done
