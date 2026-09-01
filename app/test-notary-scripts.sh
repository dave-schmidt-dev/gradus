#!/usr/bin/env bash
# Hermetic behavior tests for the Gradus notarization shell workflow.
# Every Apple/Xcode executable is faked; this file never contacts Apple.
set -euo pipefail

umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gradus-notary-tests.XXXXXX")"
FAKE_BIN="$TEST_ROOT/bin"
FAKE_RUNTIME="$TEST_ROOT/runtime"
STATUS_SCRIPT="$SCRIPT_DIR/notary-status.sh"

cleanup() {
  rm -rf "$TEST_ROOT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

mkdir -p "$FAKE_BIN" "$FAKE_RUNTIME"

cat >"$FAKE_BIN/xcrun" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

scenario="${FAKE_NOTARY_SCENARIO:-accepted}"
runtime="${FAKE_NOTARY_RUNTIME:?}"
trap 'exit 143' INT TERM

if [[ "${1:-}" == "stapler" ]]; then
  : >"$runtime/stapled"
  exit 0
fi
[[ "${1:-}" == "notarytool" ]] || exit 90

case "${2:-}" in
  history)
    if [[ "$scenario" == "auth" || "$scenario" == "service" ]]; then
      echo "simulated request failure" >&2
      exit 1
    fi
    if [[ -n "${FAKE_BLOCK_DIR:-}" ]]; then
      : >"$FAKE_BLOCK_DIR/entered"
      while [[ ! -e "$FAKE_BLOCK_DIR/continue" ]]; do sleep 0.01; done
    fi
    if [[ "$scenario" == "monitor-sequence" ]]; then
      count_file="$runtime/history-count"
      count=0
      [[ ! -f "$count_file" ]] || count="$(<"$count_file")"
      ((count += 1))
      printf '%s\n' "$count" >"$count_file"
      case "$count" in
        1)
          printf '{"history":[]}\n'
          exit 0
          ;;
        2)
          printf '{"history":[{"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","name":"Gradus.app.zip","createdDate":"2026-08-04T12:00:00Z","status":"In Progress"}]}\n'
          exit 0
          ;;
        3)
          printf '{"history":[{"id":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","name":"Gradus.app.zip","createdDate":"2026-08-04T12:00:00Z","status":"Invalid"},{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","name":"Gradus.app.zip","createdDate":"2026-08-04T13:00:00Z","status":"Accepted"}]}\n'
          exit 0
          ;;
        4)
          echo "simulated transient history failure" >&2
          exit 1
          ;;
        *)
          printf '{"history":[{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","name":"Gradus.app.zip","createdDate":"2026-08-04T13:00:00Z","status":"Accepted"}]}\n'
          exit 0
          ;;
      esac
    fi
    case "$scenario" in
      empty)
        printf '{"history":[]}\n'
        exit 0
        ;;
      pending) status="In Progress" ;;
      terminal) status="Invalid" ;;
      *) status="Accepted" ;;
    esac
    printf '{"history":[{"id":"11111111-1111-1111-1111-111111111111","name":"Gradus.app.zip","createdDate":"2026-08-04T12:00:00Z","status":"%s"},{"id":"99999999-9999-9999-9999-999999999999","name":"Other.app.zip","createdDate":"2026-08-04T11:00:00Z","status":"Accepted"}]}\n' "$status"
    ;;
  info)
    if [[ "$scenario" == "auth" || "$scenario" == "service" || "$scenario" == "unknown" ]]; then
      echo "simulated request failure" >&2
      exit 1
    fi
    if [[ -n "${FAKE_BLOCK_DIR:-}" ]]; then
      : >"$FAKE_BLOCK_DIR/entered"
      while [[ ! -e "$FAKE_BLOCK_DIR/continue" ]]; do sleep 0.01; done
    fi
    count_file="$runtime/info-count"
    printf '%s\n' "$3" >>"$runtime/info-ids"
    if [[ -n "${FAKE_EXPECT_LEDGER:-}" ]]; then
      grep -q "$3" "$FAKE_EXPECT_LEDGER" || {
        echo "submission was queried before it was recorded" >&2
        exit 92
      }
    fi
    count=0
    [[ ! -f "$count_file" ]] || count="$(<"$count_file")"
    ((count += 1))
    printf '%s\n' "$count" >"$count_file"
    if [[ "$scenario" == "watch" && "$count" -eq 1 ]]; then
      status="In Progress"
    elif [[ "$scenario" == "mixed" && "$count" -eq 1 ]]; then
      status="Accepted"
    elif [[ "$scenario" == "mixed" ]]; then
      status="In Progress"
    elif [[ "$scenario" == "mixed-terminal" && "$count" -eq 1 ]]; then
      status="In Progress"
    elif [[ "$scenario" == "mixed-terminal" ]]; then
      status="Rejected"
    elif [[ "$scenario" == "pending" ]]; then
      status="In Progress"
    elif [[ "$scenario" == "terminal" ]]; then
      status="Rejected"
    else
      status="Accepted"
    fi
    printf '{"id":"%s","name":"Gradus.app.zip","createdDate":"2026-08-04T12:00:00Z","status":"%s"}\n' "$3" "$status"
    ;;
  submit)
    printf '%s\n' "$*" >"$runtime/submit-args"
    if [[ "$scenario" == "submit-fail" ]]; then
      echo "Simulated upload failure" >&2
      exit 55
    fi
    echo "Conducting pre-submission checks for Gradus.app.zip"
    echo "Upload progress: 100.00%"
    if [[ "$scenario" != "submit-no-id" ]]; then
      echo "  id: 22222222-2222-2222-2222-222222222222"
    fi
    echo "Successfully uploaded file"
    ;;
  *)
    exit 91
    ;;
esac
FAKE

cat >"$FAKE_BIN/xcodegen" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE

cat >"$FAKE_BIN/xcodebuild" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${FAKE_NOTARY_RUNTIME:-}" ]]; then
  printf '%s\n' "$*" >>"$FAKE_NOTARY_RUNTIME/xcodebuild-calls"
fi
export_path=""
while (($#)); do
  if [[ "$1" == "-exportPath" ]]; then
    export_path="$2"
    shift 2
  else
    shift
  fi
done
if [[ -n "$export_path" ]]; then
  mkdir -p "$export_path/Gradus.app/Contents"
  printf 'fixture\n' >"$export_path/Gradus.app/Contents/Info.plist"
fi
FAKE

for command_name in xattr codesign spctl; do
  cat >"$FAKE_BIN/$command_name" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
done

cat >"$FAKE_BIN/ditto" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
destination="${!#}"
mkdir -p "$(dirname "$destination")"
printf 'fake zip\n' >"$destination"
FAKE

cat >"$FAKE_BIN/PlistBuddy" <<'FAKE'
#!/usr/bin/env bash
echo "1.2.3"
FAKE

# sign-mac-bundle.sh and verify-mac-bundle.sh are exercised for real by
# test-mac-bundle-structure.sh. What matters here is the release workflow's
# ordering contract: both run on the export, and both run before anything is
# zipped or uploaded.
cat >"$FAKE_BIN/sign-stub" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_NOTARY_RUNTIME:?}/sign-calls"
exit "${FAKE_SIGN_EXIT:-0}"
FAKE

cat >"$FAKE_BIN/verify-stub" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_NOTARY_RUNTIME:?}/verify-calls"
exit "${FAKE_VERIFY_EXIT:-0}"
FAKE

chmod 700 "$FAKE_BIN"/*

tests_run=0
last_output=""
last_stdout=""
last_stderr=""
last_status=0

run_status() {
  local state_file="$1"
  local scenario="$2"
  shift 2
  : >"$TEST_ROOT/run.stdout"
  : >"$TEST_ROOT/run.stderr"
  set +e
  PATH="$FAKE_BIN:/usr/bin:/bin" \
  FAKE_NOTARY_SCENARIO="$scenario" \
  FAKE_NOTARY_RUNTIME="$FAKE_RUNTIME" \
  GRADUS_NOTARY_STATE_FILE="$state_file" \
  TMPDIR="$TEST_ROOT/tmp" \
  "$STATUS_SCRIPT" "$@" >"$TEST_ROOT/run.stdout" 2>"$TEST_ROOT/run.stderr"
  last_status=$?
  set -e
  last_stdout="$(<"$TEST_ROOT/run.stdout")"
  last_stderr="$(<"$TEST_ROOT/run.stderr")"
  last_output="$last_stdout"
  if [[ -n "$last_stderr" ]]; then
    last_output="${last_output}${last_output:+$'\n'}${last_stderr}"
  fi
}

assert_status() {
  local expected="$1"
  local label="$2"
  ((tests_run += 1))
  if [[ "$last_status" -ne "$expected" ]]; then
    echo "FAIL: $label: expected exit $expected, got $last_status" >&2
    echo "$last_output" >&2
    exit 1
  fi
  echo "  ✓ $label"
}

assert_contains() {
  local needle="$1"
  local label="$2"
  ((tests_run += 1))
  if [[ "$last_output" != *"$needle"* ]]; then
    echo "FAIL: $label: output did not contain: $needle" >&2
    echo "$last_output" >&2
    exit 1
  fi
  echo "  ✓ $label"
}

mkdir -p "$TEST_ROOT/tmp"

run_status "$TEST_ROOT/accepted.tsv" accepted </dev/null
assert_status 0 "accepted one-shot exits 0 with closed stdin"
assert_contains "Submission ID: 11111111-1111-1111-1111-111111111111" "accepted output shows the submission ID"
assert_contains "Status:        Accepted" "accepted output shows status"
if ! grep -Eq '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] Requesting live Apple notarization history$' <<<"$last_stderr"; then
  echo "FAIL: history request did not emit timestamped progress to stderr" >&2
  exit 1
fi
[[ "$last_stdout" != *"Requesting live Apple"* ]] || {
  echo "FAIL: request progress contaminated stdout" >&2
  exit 1
}
echo "  ✓ history request emits timestamped progress on stderr only"
((tests_run += 1))
if [[ "$last_output" == *"Other.app.zip"* ]]; then
  echo "FAIL: history included a non-Gradus artifact" >&2
  exit 1
fi
echo "  ✓ one-shot history filters non-Gradus artifacts"
((tests_run += 1))

run_status "$TEST_ROOT/pending.tsv" pending
assert_status 2 "pending one-shot exits 2"
assert_contains "Status:        In Progress" "pending output is visible"

run_status "$TEST_ROOT/terminal.tsv" terminal
assert_status 3 "terminal failure exits 3"
assert_contains "Status:        Invalid" "terminal status is visible"

run_status "$TEST_ROOT/empty.tsv" empty
assert_status 4 "empty Apple history exits 4 rather than looking accepted"
assert_contains "No Gradus.app.zip submissions were returned" "empty history is explicit"

rm -f "$FAKE_RUNTIME/info-count"
run_status "$TEST_ROOT/watch.tsv" watch --watch --interval 1 --id 22222222-2222-2222-2222-222222222222
assert_status 0 "watch polls pending to accepted and exits 0"
assert_contains "Still pending. Checking again" "watch reports live polling progress"
[[ "$(grep -c 'Requesting live Apple notarization info for submission 22222222-2222-2222-2222-222222222222' <<<"$last_stderr")" -eq 2 ]] || {
  echo "FAIL: each watched info request did not emit progress" >&2
  exit 1
}
echo "  ✓ every watched info request emits ID-specific progress"
((tests_run += 1))
[[ "$(<"$FAKE_RUNTIME/info-count")" -eq 2 ]] || {
  echo "FAIL: watch did not perform exactly two status checks" >&2
  exit 1
}
echo "  ✓ watch queried twice"
((tests_run += 1))

# --monitor is deliberately persistent: it discovers IDs from fresh history,
# survives empty and transient history responses, and only stops on TERM.
rm -f "$FAKE_RUNTIME/history-count" "$FAKE_RUNTIME/info-count" "$FAKE_RUNTIME/info-ids"
: >"$TEST_ROOT/monitor.stdout"
: >"$TEST_ROOT/monitor.stderr"
set +e
PATH="$FAKE_BIN:/usr/bin:/bin" \
FAKE_NOTARY_SCENARIO=monitor-sequence \
FAKE_NOTARY_RUNTIME="$FAKE_RUNTIME" \
GRADUS_NOTARY_STATE_FILE="$TEST_ROOT/monitor.tsv" \
NOTARY_POLL_INTERVAL=1 \
TMPDIR="$TEST_ROOT/tmp" \
"$STATUS_SCRIPT" --monitor >"$TEST_ROOT/monitor.stdout" 2>"$TEST_ROOT/monitor.stderr" &
monitor_pid=$!
set -e
attempt=1
while [[ ! -f "$FAKE_RUNTIME/history-count" || "$(<"$FAKE_RUNTIME/history-count")" -lt 5 ]]; do
  sleep 0.05
  ((attempt += 1))
  if ((attempt > 200)); then
    echo "FAIL: monitor did not complete four refresh cycles" >&2
    kill -TERM "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    exit 1
  fi
done
attempt=1
while ! grep -q "Apple notarytool history request failed" "$TEST_ROOT/monitor.stderr"; do
  sleep 0.05
  ((attempt += 1))
  if ((attempt > 100)); then
    echo "FAIL: monitor did not surface the transient history failure" >&2
    kill -TERM "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
    exit 1
  fi
done
kill -TERM "$monitor_pid"
set +e
wait "$monitor_pid"
monitor_status=$?
set -e
[[ "$monitor_status" -eq 130 ]] || {
  echo "FAIL: monitor exits 130 on TERM, got $monitor_status" >&2
  exit 1
}
if find "$TEST_ROOT/tmp" -maxdepth 1 -name 'gradus-notary-status.*' -print -quit | grep -q .; then
  echo "FAIL: monitor leaked its temporary directory after TERM" >&2
  exit 1
fi
monitor_stdout="$(<"$TEST_ROOT/monitor.stdout")"
monitor_stderr="$(<"$TEST_ROOT/monitor.stderr")"
[[ "$monitor_stdout" == *"No Gradus.app.zip submissions were returned"* ]] || {
  echo "FAIL: monitor did not report the empty first history cycle" >&2
  exit 1
}
[[ "$monitor_stdout" == *"Submission ID: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"* &&
   "$monitor_stdout" == *"Submission ID: bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"* ]] || {
  echo "FAIL: monitor did not discover IDs across history cycles" >&2
  exit 1
}
[[ "$monitor_stdout" == *"Status:        Invalid"* ]] || {
  echo "FAIL: monitor did not persist a terminal status snapshot" >&2
  exit 1
}
[[ "$monitor_stdout" == *"Next refresh: in 1s"* ]] || {
  echo "FAIL: monitor did not print the next-refresh countdown" >&2
  exit 1
}
[[ "$monitor_stderr" == *"Apple notarytool history request failed"* ]] || {
  echo "FAIL: monitor did not survive/report the transient history failure" >&2
  exit 1
}
[[ ! -e "$FAKE_RUNTIME/info-ids" ]] || {
  echo "FAIL: monitor queried a history-discovered ID after it disappeared" >&2
  exit 1
}
if grep -q $'\033' "$TEST_ROOT/monitor.stdout"; then
  echo "FAIL: non-TTY monitor output contains ANSI redraw escapes" >&2
  exit 1
fi
echo "  ✓ monitor discovers across cycles, persists through empty/transient states, and stops on TERM"
((tests_run += 1))

# TERM must cancel an in-flight Apple request rather than waiting for the
# request to return. The fake request remains blocked until explicitly released;
# this test intentionally never releases it.
blocked_monitor_dir="$TEST_ROOT/blocked-monitor"
mkdir -p "$blocked_monitor_dir"
: >"$TEST_ROOT/blocked-monitor.stdout"
: >"$TEST_ROOT/blocked-monitor.stderr"
set +e
PATH="$FAKE_BIN:/usr/bin:/bin" \
FAKE_NOTARY_SCENARIO=accepted \
FAKE_NOTARY_RUNTIME="$FAKE_RUNTIME" \
FAKE_BLOCK_DIR="$blocked_monitor_dir" \
GRADUS_NOTARY_STATE_FILE="$TEST_ROOT/blocked-monitor.tsv" \
NOTARY_POLL_INTERVAL=1 \
TMPDIR="$TEST_ROOT/tmp" \
"$STATUS_SCRIPT" --monitor >"$TEST_ROOT/blocked-monitor.stdout" 2>"$TEST_ROOT/blocked-monitor.stderr" &
blocked_monitor_pid=$!
set -e
attempt=1
while [[ ! -e "$blocked_monitor_dir/entered" ]]; do
  sleep 0.05
  ((attempt += 1))
  if ((attempt > 100)); then
    echo "FAIL: blocked monitor request did not start" >&2
    kill -KILL "$blocked_monitor_pid" 2>/dev/null || true
    wait "$blocked_monitor_pid" 2>/dev/null || true
    exit 1
  fi
done
kill -TERM "$blocked_monitor_pid"
attempt=1
while kill -0 "$blocked_monitor_pid" 2>/dev/null; do
  sleep 0.05
  ((attempt += 1))
  if ((attempt > 100)); then
    echo "FAIL: TERM did not promptly cancel the blocked monitor request" >&2
    kill -KILL "$blocked_monitor_pid" 2>/dev/null || true
    wait "$blocked_monitor_pid" 2>/dev/null || true
    exit 1
  fi
done
set +e
wait "$blocked_monitor_pid"
blocked_monitor_status=$?
set -e
[[ "$blocked_monitor_status" -eq 130 && ! -e "$blocked_monitor_dir/continue" ]] || {
  echo "FAIL: blocked monitor did not exit 130 without releasing the fake request" >&2
  exit 1
}
if find "$TEST_ROOT/tmp" -maxdepth 1 -name 'gradus-notary-status.*' -print -quit | grep -q .; then
  echo "FAIL: blocked monitor leaked its temporary directory" >&2
  exit 1
fi
echo "  ✓ TERM promptly cancels an in-flight monitor request and cleans up"
((tests_run += 1))

# A history row is already a fresh Apple status; monitor mode must not issue a
# redundant info request for every row on every cycle.
rm -f "$FAKE_RUNTIME/history-count" "$FAKE_RUNTIME/info-count" "$FAKE_RUNTIME/info-ids"
: >"$TEST_ROOT/monitor-known.stdout"
: >"$TEST_ROOT/monitor-known.stderr"
set +e
PATH="$FAKE_BIN:/usr/bin:/bin" \
FAKE_NOTARY_SCENARIO=accepted \
FAKE_NOTARY_RUNTIME="$FAKE_RUNTIME" \
GRADUS_NOTARY_STATE_FILE="$TEST_ROOT/monitor-known.tsv" \
NOTARY_POLL_INTERVAL=1 \
TMPDIR="$TEST_ROOT/tmp" \
"$STATUS_SCRIPT" --monitor >"$TEST_ROOT/monitor-known.stdout" 2>"$TEST_ROOT/monitor-known.stderr" &
known_pid=$!
set -e
attempt=1
while ! grep -q "Submission ID: 11111111-1111-1111-1111-111111111111" "$TEST_ROOT/monitor-known.stdout"; do
  sleep 0.05
  ((attempt += 1))
  if ((attempt > 100)); then
    echo "FAIL: known-history monitor did not complete a display cycle" >&2
    kill -TERM "$known_pid" 2>/dev/null || true
    wait "$known_pid" 2>/dev/null || true
    exit 1
  fi
done
kill -TERM "$known_pid"
set +e
wait "$known_pid"
known_status=$?
set -e
[[ "$known_status" -eq 130 && ! -e "$FAKE_RUNTIME/info-count" ]] || {
  echo "FAIL: monitor redundantly queried known history IDs via info" >&2
  exit 1
}
echo "  ✓ monitor uses fresh history rows without redundant info requests"
((tests_run += 1))

# A tracked submission omitted from the current history still gets an info
# lookup, so a temporarily incomplete history response does not hide it.
fallback_ledger="$TEST_ROOT/monitor-fallback.tsv"
printf '2026-08-04T12:00:00Z\tcccccccc-cccc-cccc-cccc-cccccccccccc\tGradus.app.zip\tfixture.zip\tdeadbeef\n' >"$fallback_ledger"
rm -f "$FAKE_RUNTIME/history-count" "$FAKE_RUNTIME/info-count" "$FAKE_RUNTIME/info-ids"
: >"$TEST_ROOT/monitor-fallback.stdout"
: >"$TEST_ROOT/monitor-fallback.stderr"
set +e
PATH="$FAKE_BIN:/usr/bin:/bin" \
FAKE_NOTARY_SCENARIO=empty \
FAKE_NOTARY_RUNTIME="$FAKE_RUNTIME" \
GRADUS_NOTARY_STATE_FILE="$fallback_ledger" \
NOTARY_POLL_INTERVAL=1 \
TMPDIR="$TEST_ROOT/tmp" \
"$STATUS_SCRIPT" --monitor >"$TEST_ROOT/monitor-fallback.stdout" 2>"$TEST_ROOT/monitor-fallback.stderr" &
fallback_pid=$!
set -e
attempt=1
while ! grep -q "Submission ID: cccccccc-cccc-cccc-cccc-cccccccccccc" "$TEST_ROOT/monitor-fallback.stdout"; do
  sleep 0.05
  ((attempt += 1))
  if ((attempt > 100)); then
    echo "FAIL: monitor did not display a tracked ID omitted from history" >&2
    kill -TERM "$fallback_pid" 2>/dev/null || true
    wait "$fallback_pid" 2>/dev/null || true
    exit 1
  fi
done
kill -TERM "$fallback_pid"
set +e
wait "$fallback_pid"
fallback_status=$?
set -e
[[ "$fallback_status" -eq 130 && "$(<"$FAKE_RUNTIME/info-count")" -ge 1 ]] || {
  echo "FAIL: monitor fallback info query did not complete cleanly" >&2
  exit 1
}
[[ "$(<"$TEST_ROOT/monitor-fallback.stdout")" == *"Submission ID: cccccccc-cccc-cccc-cccc-cccccccccccc"* ]] || {
  echo "FAIL: monitor did not display the fallback info status" >&2
  exit 1
}
echo "  ✓ monitor falls back to live info for tracked IDs missing from history"
((tests_run += 1))

# Explicit IDs are also retained independently of history and must fall back to
# notarytool info when Apple history omits them.
explicit_id="dddddddd-dddd-dddd-dddd-dddddddddddd"
rm -f "$FAKE_RUNTIME/history-count" "$FAKE_RUNTIME/info-count" "$FAKE_RUNTIME/info-ids"
: >"$TEST_ROOT/monitor-explicit.stdout"
: >"$TEST_ROOT/monitor-explicit.stderr"
set +e
PATH="$FAKE_BIN:/usr/bin:/bin" \
FAKE_NOTARY_SCENARIO=empty \
FAKE_NOTARY_RUNTIME="$FAKE_RUNTIME" \
GRADUS_NOTARY_STATE_FILE="$TEST_ROOT/monitor-explicit.tsv" \
NOTARY_POLL_INTERVAL=1 \
TMPDIR="$TEST_ROOT/tmp" \
"$STATUS_SCRIPT" --monitor --id "$explicit_id" >"$TEST_ROOT/monitor-explicit.stdout" 2>"$TEST_ROOT/monitor-explicit.stderr" &
explicit_pid=$!
set -e
attempt=1
while ! grep -q "Submission ID: $explicit_id" "$TEST_ROOT/monitor-explicit.stdout"; do
  sleep 0.05
  ((attempt += 1))
  if ((attempt > 100)); then
    echo "FAIL: monitor did not display an explicit ID omitted from history" >&2
    kill -TERM "$explicit_pid" 2>/dev/null || true
    wait "$explicit_pid" 2>/dev/null || true
    exit 1
  fi
done
kill -TERM "$explicit_pid"
set +e
wait "$explicit_pid"
explicit_status=$?
set -e
[[ "$explicit_status" -eq 130 && "$(<"$FAKE_RUNTIME/info-count")" -ge 1 ]] || {
  echo "FAIL: explicit monitor ID was not queried via info or did not exit 130" >&2
  exit 1
}
grep -qx "$explicit_id" "$FAKE_RUNTIME/info-ids" || {
  echo "FAIL: explicit monitor ID was not the info query target" >&2
  exit 1
}
if find "$TEST_ROOT/tmp" -maxdepth 1 -name 'gradus-notary-status.*' -print -quit | grep -q .; then
  echo "FAIL: explicit monitor ID leaked its temporary directory" >&2
  exit 1
fi
echo "  ✓ monitor falls back to live info for an explicit ID missing from history"
((tests_run += 1))

rm -f "$FAKE_RUNTIME/info-count"
run_status "$TEST_ROOT/mixed.tsv" mixed \
  --id 66666666-6666-6666-6666-666666666666 \
  --id 77777777-7777-7777-7777-777777777777
assert_status 2 "mixed accepted and pending IDs aggregate to pending"
assert_contains "Submission ID: 66666666-6666-6666-6666-666666666666" "mixed output includes the first ID"
assert_contains "Submission ID: 77777777-7777-7777-7777-777777777777" "mixed output includes the second ID"

rm -f "$FAKE_RUNTIME/info-count"
run_status "$TEST_ROOT/mixed-terminal.tsv" mixed-terminal \
  --id 88888888-8888-8888-8888-888888888888 \
  --id aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
assert_status 3 "terminal status takes precedence over pending across IDs"
assert_contains "Status:        In Progress" "mixed terminal output preserves pending detail"
assert_contains "Status:        Rejected" "mixed terminal output preserves rejection detail"

run_status "$TEST_ROOT/auth.tsv" auth
assert_status 70 "profile/auth failure exits 70"
assert_contains "A sandboxed agent may not be able to see the login Keychain" "profile failure explains sandbox visibility"
assert_contains "service, network, request, or Keychain-profile issue" "profile guidance remains neutral about the cause"

run_status "$TEST_ROOT/service.tsv" service
assert_status 70 "service failure exits 70"
assert_contains "Apple notarytool history request failed" "service failure identifies the failed request neutrally"

run_status "$TEST_ROOT/unknown.tsv" unknown --id 55555555-5555-5555-5555-555555555555
assert_status 70 "unknown submission request exits 70"
assert_contains "info for submission 55555555-5555-5555-5555-555555555555 request failed" "unknown ID failure identifies the request without guessing the cause"

block_dir="$TEST_ROOT/block"
mkdir -p "$block_dir"
: >"$TEST_ROOT/blocked.stdout"
: >"$TEST_ROOT/blocked.stderr"
set +e
PATH="$FAKE_BIN:/usr/bin:/bin" \
FAKE_NOTARY_SCENARIO=accepted \
FAKE_NOTARY_RUNTIME="$FAKE_RUNTIME" \
FAKE_BLOCK_DIR="$block_dir" \
GRADUS_NOTARY_STATE_FILE="$TEST_ROOT/blocked.tsv" \
TMPDIR="$TEST_ROOT/tmp" \
"$STATUS_SCRIPT" >"$TEST_ROOT/blocked.stdout" 2>"$TEST_ROOT/blocked.stderr" &
blocked_pid=$!
set -e
attempt=1
while [[ ! -e "$block_dir/entered" && "$attempt" -le 100 ]]; do
  sleep 0.01
  ((attempt += 1))
done
[[ -e "$block_dir/entered" ]] || {
  echo "FAIL: blocked fake request did not start" >&2
  exit 1
}
grep -Eq '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] Requesting live Apple notarization history$' "$TEST_ROOT/blocked.stderr" || {
  echo "FAIL: progress was not visible while the Apple request was blocked" >&2
  exit 1
}
[[ ! -s "$TEST_ROOT/blocked.stdout" ]] || {
  echo "FAIL: queue result appeared before the blocked Apple request returned" >&2
  exit 1
}
: >"$block_dir/continue"
set +e
wait "$blocked_pid"
blocked_status=$?
set -e
[[ "$blocked_status" -eq 0 ]] || {
  echo "FAIL: released fake request did not complete successfully" >&2
  exit 1
}
echo "  ✓ timestamped stderr progress is visible before a slow request returns"
((tests_run += 1))

run_status "$TEST_ROOT/usage.tsv" accepted --interval 0
assert_status 64 "invalid interval exits 64"
assert_contains "--interval must be a positive integer" "invalid interval is actionable"

run_status "$TEST_ROOT/usage.tsv" accepted --id not-a-uuid
assert_status 64 "invalid submission ID exits 64"

run_status "$TEST_ROOT/usage.tsv" accepted --id
assert_status 64 "missing --id value exits 64"

set +e
last_output="$(
  PATH="$FAKE_BIN:/usr/bin:/bin" \
  NOTARY_XCRUN=missing-xcrun-for-test \
  NOTARY_PYTHON=python3 \
  GRADUS_NOTARY_STATE_FILE="$TEST_ROOT/missing.tsv" \
  TMPDIR="$TEST_ROOT/tmp" \
  "$STATUS_SCRIPT" 2>&1
)"
last_status=$?
set -e
assert_status 69 "missing xcrun dependency exits 69"
assert_contains "required tool is missing: missing-xcrun-for-test" "missing dependency names the tool"

artifact="$TEST_ROOT/Gradus.app.zip"
printf 'artifact fixture\n' >"$artifact"
ledger="$TEST_ROOT/concurrent/notary-submissions.tsv"
record_one="$TEST_ROOT/record-one.out"
record_two="$TEST_ROOT/record-two.out"
set +e
GRADUS_NOTARY_STATE_FILE="$ledger" "$STATUS_SCRIPT" --record 33333333-3333-3333-3333-333333333333 --name Gradus.app.zip --artifact "$artifact" >"$record_one" 2>&1 &
pid_one=$!
GRADUS_NOTARY_STATE_FILE="$ledger" "$STATUS_SCRIPT" --record 33333333-3333-3333-3333-333333333333 --name Gradus.app.zip --artifact "$artifact" >"$record_two" 2>&1 &
pid_two=$!
wait "$pid_one"
status_one=$?
wait "$pid_two"
status_two=$?
set -e
[[ "$status_one" -eq 0 && "$status_two" -eq 0 ]] || {
  echo "FAIL: concurrent ledger writers did not both exit 0" >&2
  exit 1
}
[[ "$(awk -F $'\t' '$2 == "33333333-3333-3333-3333-333333333333" { count++ } END { print count + 0 }' "$ledger")" -eq 1 ]] || {
  echo "FAIL: duplicate submission was written more than once" >&2
  exit 1
}
[[ "$(stat -f '%Lp' "$ledger")" == "600" ]] || {
  echo "FAIL: ledger permissions are not 600" >&2
  exit 1
}
[[ ! -e "${ledger}.lock" ]] || {
  echo "FAIL: ledger lock leaked after concurrent recording" >&2
  exit 1
}
if find "$(dirname "$ledger")" -maxdepth 1 -name 'notary-submissions.tsv.tmp.*' -print -quit | grep -q .; then
  echo "FAIL: atomic ledger update leaked a temporary file" >&2
  exit 1
fi
echo "  ✓ concurrent duplicate records produce one mode-600 ledger row"
((tests_run += 1))

rm -f "$FAKE_RUNTIME/info-count"
run_status "$ledger" accepted
assert_status 0 "default command refreshes IDs from a nonempty ledger"
assert_contains "Submission ID: 33333333-3333-3333-3333-333333333333" "ledger-driven output shows the recorded ID"
assert_contains "Status source: local ledger" "output identifies the ledger-driven live query"

run_status "$TEST_ROOT/missing-artifact.tsv" accepted --record 44444444-4444-4444-4444-444444444444 --name Gradus.app.zip --artifact "$TEST_ROOT/does-not-exist.zip"
assert_status 64 "missing record artifact exits 64 without a partial ledger"
[[ ! -e "$TEST_ROOT/missing-artifact.tsv" ]] || {
  echo "FAIL: invalid record left a partial ledger" >&2
  exit 1
}
echo "  ✓ invalid record leaves no partial state"
((tests_run += 1))

if find "$TEST_ROOT/tmp" -maxdepth 1 -name 'gradus-notary-status.*' -print -quit | grep -q .; then
  echo "FAIL: status command leaked a temporary directory" >&2
  exit 1
fi
echo "  ✓ status command cleans temporary files"
((tests_run += 1))

release_root="$TEST_ROOT/release"
release_app="$release_root/app"
mkdir -p "$release_app" "$release_root/.state" "$TEST_ROOT/release-tmp"
cp "$SCRIPT_DIR/notarize-mac.sh" "$SCRIPT_DIR/notary-status.sh" "$release_app/"
cp "$SCRIPT_DIR/project.yml" "$release_app/"
chmod 700 "$release_app/notarize-mac.sh" "$release_app/notary-status.sh"
# The frozen runtime is a prerequisite of archiving, not something the release
# path builds: producing it downloads a pinned CPython.
mkdir -p "$release_app/build/gradus-runtime/dist/GradusRuntime.app/Contents/MacOS"
rm -f "$FAKE_RUNTIME/info-count" "$FAKE_RUNTIME/sign-calls" "$FAKE_RUNTIME/verify-calls"
set +e
(
  cd "$release_app"
  PATH="$FAKE_BIN:/usr/bin:/bin" \
  GRADUS_SOURCE_REVISION=fixture-revision \
  FAKE_NOTARY_SCENARIO=watch \
  FAKE_NOTARY_RUNTIME="$FAKE_RUNTIME" \
  FAKE_EXPECT_LEDGER="$release_root/.state/notary-submissions.tsv" \
  PLIST_BUDDY="$FAKE_BIN/PlistBuddy" \
  NOTARY_SIGN_SCRIPT="$FAKE_BIN/sign-stub" \
  NOTARY_VERIFY_SCRIPT="$FAKE_BIN/verify-stub" \
  NOTARY_POLL_INTERVAL=1 \
  TMPDIR="$TEST_ROOT/release-tmp" \
  ./notarize-mac.sh --attended
) >"$TEST_ROOT/release.stdout" 2>"$TEST_ROOT/release.stderr"
last_status=$?
set -e
last_stdout="$(<"$TEST_ROOT/release.stdout")"
last_stderr="$(<"$TEST_ROOT/release.stderr")"
last_output="${last_stdout}${last_stderr:+$'\n'}${last_stderr}"
assert_status 0 "release workflow hands off to visible polling and completes"
assert_contains "Upload progress: 100.00%" "release upload progress remains visible"
assert_contains "./notary-status.sh --watch --id 22222222-2222-2222-2222-222222222222" "release prints the interruption recovery command"
assert_contains "Direct Apple status: Accepted. OK." "release independently confirms exact acceptance"
assert_contains "Requesting Apple notarization history for release preflight" "release preflight emits timestamped request progress"
assert_contains "Requesting live Apple notarization info for submission 22222222-2222-2222-2222-222222222222" "independent acceptance query emits ID-specific progress"
grep -q -- '--no-wait' "$FAKE_RUNTIME/submit-args" || {
  echo "FAIL: release submission did not explicitly use --no-wait" >&2
  exit 1
}
echo "  ✓ release submission explicitly returns after upload for status handoff"
((tests_run += 1))
[[ "$(awk -F $'\t' '$2 == "22222222-2222-2222-2222-222222222222" { count++ } END { print count + 0 }' "$release_root/.state/notary-submissions.tsv")" -eq 1 ]] || {
  echo "FAIL: release workflow did not record the submission ID exactly once" >&2
  exit 1
}
[[ -f "$release_app/build/Gradus-1.2.3.zip" ]] || {
  echo "FAIL: release workflow did not reach final packaging after acceptance" >&2
  exit 1
}
[[ -f "$FAKE_RUNTIME/stapled" ]] || {
  echo "FAIL: accepted release did not reach stapling" >&2
  exit 1
}
if find "$TEST_ROOT/release-tmp" -maxdepth 1 \
  \( -name 'gradus-notary-submit.*' -o -name 'gradus-notary-acceptance.*' \) -print -quit | grep -q .; then
  echo "FAIL: release workflow leaked a secure temporary file" >&2
  exit 1
fi
echo "  ✓ release records before polling, packages only after acceptance, and cleans its capture file"
((tests_run += 1))

# `exportArchive` leaves Contents/Helpers/GradusRuntime.app ad-hoc signed, so
# the release path has to sign the tree itself -- and audit it -- before a
# single byte goes to Apple.
grep -q -- '--identity' "$FAKE_RUNTIME/sign-calls" || {
  echo "FAIL: release did not sign the export with an explicit identity" >&2
  exit 1
}
# Preserved, not reconstructed. Xcode injects com.apple.application-identifier
# and com.apple.developer.team-identifier from the provisioning profile, so
# re-signing from GradusMacProduction.entitlements alone would silently drop
# both and ship an app that notarizes and cannot reach CloudKit.
grep -q -- '--preserve-entitlements' "$FAKE_RUNTIME/sign-calls" || {
  echo "FAIL: release re-signed the wrapper without preserving its entitlements" >&2
  exit 1
}
if grep -q -- '--entitlements ' "$FAKE_RUNTIME/sign-calls"; then
  echo "FAIL: release rebuilt the entitlement blob from the source file" >&2
  exit 1
fi
grep -q 'export/Gradus.app' "$FAKE_RUNTIME/sign-calls" || {
  echo "FAIL: release signed something other than the exported Gradus.app" >&2
  exit 1
}
grep -q -- '--manifest' "$FAKE_RUNTIME/verify-calls" || {
  echo "FAIL: release did not emit a bundle manifest during verification" >&2
  exit 1
}
grep -q 'export/Gradus.app' "$FAKE_RUNTIME/verify-calls" || {
  echo "FAIL: release audited something other than the exported Gradus.app" >&2
  exit 1
}
echo "  ✓ release signs the export inside out and audits it before packaging"
((tests_run += 1))

# The clean step used to be `rm -rf build`, which deleted the frozen runtime
# the archive then hard-failed without.
[[ -d "$release_app/build/gradus-runtime/dist/GradusRuntime.app" ]] || {
  echo "FAIL: the release clean step deleted the frozen runtime it depends on" >&2
  exit 1
}
echo "  ✓ the release clean step preserves the frozen runtime"
((tests_run += 1))

# Naming: the shipped wrapper, the notary artifact and the distributable all
# carry the customer-facing product name; only the archive keeps `GradusMac`,
# which is a scheme and an engineering identifier.
[[ -f "$release_app/build/Gradus.app.zip" ]] || {
  echo "FAIL: the notary submission artifact is not named Gradus.app.zip" >&2
  exit 1
}
grep -q $'\tGradus.app.zip\t' "$release_root/.state/notary-submissions.tsv" || {
  echo "FAIL: the ledger recorded a submission name other than Gradus.app.zip" >&2
  exit 1
}
grep -Fq 'ARCHIVE_PATH="build/GradusMac.xcarchive"' "$release_app/notarize-mac.sh" || {
  echo "FAIL: the archive stopped using the internal GradusMac identifier" >&2
  exit 1
}
echo "  ✓ shipped, submitted and packaged names are Gradus; only the archive stays GradusMac"
((tests_run += 1))

cat >"$FAKE_BIN/false-status-helper" <<'FAKE'
#!/usr/bin/env bash
# Adversarial helper: falsely reports success for record and watch operations.
exit 0
FAKE
chmod 700 "$FAKE_BIN/false-status-helper"

for adversarial_scenario in pending terminal; do
  adversarial_root="$TEST_ROOT/adversarial-$adversarial_scenario"
  adversarial_app="$adversarial_root/app"
  mkdir -p "$adversarial_app" "$TEST_ROOT/adversarial-tmp-$adversarial_scenario"
  cp "$SCRIPT_DIR/notarize-mac.sh" "$adversarial_app/"
  cp "$SCRIPT_DIR/project.yml" "$adversarial_app/"
  chmod 700 "$adversarial_app/notarize-mac.sh"
  mkdir -p "$adversarial_app/build/gradus-runtime/dist/GradusRuntime.app/Contents/MacOS"
  rm -f "$FAKE_RUNTIME/stapled" "$FAKE_RUNTIME/info-count"
  set +e
  last_output="$(
    cd "$adversarial_app" && \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    GRADUS_SOURCE_REVISION=fixture-revision \
    FAKE_NOTARY_SCENARIO="$adversarial_scenario" \
    FAKE_NOTARY_RUNTIME="$FAKE_RUNTIME" \
    NOTARY_STATUS_SCRIPT="$FAKE_BIN/false-status-helper" \
    PLIST_BUDDY="$FAKE_BIN/PlistBuddy" \
    NOTARY_SIGN_SCRIPT="$FAKE_BIN/sign-stub" \
    NOTARY_VERIFY_SCRIPT="$FAKE_BIN/verify-stub" \
    TMPDIR="$TEST_ROOT/adversarial-tmp-$adversarial_scenario" \
    ./notarize-mac.sh --attended 2>&1
  )"
  last_status=$?
  set -e

  if [[ "$adversarial_scenario" == "pending" ]]; then
    assert_status 2 "dishonest helper cannot bypass a direct pending Apple status"
    assert_contains "direct Apple status is still In Progress" "pending defense fails closed visibly"
  else
    assert_status 3 "dishonest helper cannot bypass a direct rejected Apple status"
    assert_contains "direct Apple status is terminal and not Accepted" "rejected defense fails closed visibly"
  fi
  [[ ! -e "$FAKE_RUNTIME/stapled" ]] || {
    echo "FAIL: $adversarial_scenario defense reached stapling" >&2
    exit 1
  }
  if find "$adversarial_app/build" -maxdepth 1 -name 'Gradus-*.zip' -print -quit | grep -q .; then
    echo "FAIL: $adversarial_scenario defense reached distributable packaging" >&2
    exit 1
  fi
  if find "$TEST_ROOT/adversarial-tmp-$adversarial_scenario" -maxdepth 1 \
    \( -name 'gradus-notary-submit.*' -o -name 'gradus-notary-acceptance.*' \) -print -quit | grep -q .; then
    echo "FAIL: $adversarial_scenario defense leaked a secure temporary file" >&2
    exit 1
  fi
  echo "  ✓ $adversarial_scenario direct check blocks stapling/packaging and cleans secure temp files"
  ((tests_run += 1))
done

# `label` defaults to the scenario, but two cases can share an Apple scenario
# while differing in local state (a missing runtime, a failing audit). Giving
# those distinct directories keeps one case's ledger out of the next one's
# assertions.
run_release_audit_case() {
  local scenario="$1"
  local label="${2:-$scenario}"
  local case_root="$TEST_ROOT/audit-$label"
  local case_app="$case_root/app"
  local case_tmp="$TEST_ROOT/audit-tmp-$label"
  mkdir -p "$case_app" "$case_tmp"
  cp "$SCRIPT_DIR/notarize-mac.sh" "$SCRIPT_DIR/notary-status.sh" "$case_app/"
  cp "$SCRIPT_DIR/project.yml" "$case_app/"
  chmod 700 "$case_app/notarize-mac.sh" "$case_app/notary-status.sh"
  if [[ "${CASE_OMIT_RUNTIME:-0}" != "1" ]]; then
    mkdir -p "$case_app/build/gradus-runtime/dist/GradusRuntime.app/Contents/MacOS"
  fi
  # submit-args included: these files are shared across cases, and a leftover
  # from an earlier submission would read as "this case uploaded".
  rm -f "$FAKE_RUNTIME/stapled" "$FAKE_RUNTIME/info-count" "$FAKE_RUNTIME/submit-args" \
    "$FAKE_RUNTIME/sign-calls" "$FAKE_RUNTIME/verify-calls" "$FAKE_RUNTIME/xcodebuild-calls"
  set +e
  last_output="$(
    cd "$case_app" && \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    GRADUS_SOURCE_REVISION=fixture-revision \
    FAKE_NOTARY_SCENARIO="$scenario" \
    FAKE_NOTARY_RUNTIME="$FAKE_RUNTIME" \
    PLIST_BUDDY="$FAKE_BIN/PlistBuddy" \
    NOTARY_SIGN_SCRIPT="$FAKE_BIN/sign-stub" \
    NOTARY_VERIFY_SCRIPT="$FAKE_BIN/verify-stub" \
    NOTARY_POLL_INTERVAL=1 \
    TMPDIR="$case_tmp" \
    ./notarize-mac.sh ${CASE_NOTARY_ARGS-"--attended"} 2>&1
  )"
  last_status=$?
  set -e
  audit_root="$case_root"
  audit_app="$case_app"
  audit_tmp="$case_tmp"
}

assert_no_release_downstream() {
  local label="$1"
  [[ ! -e "$FAKE_RUNTIME/stapled" ]] || {
    echo "FAIL: $label reached stapling" >&2
    exit 1
  }
  if [[ -d "$audit_app/build" ]] &&
    find "$audit_app/build" -maxdepth 1 -name 'Gradus-*.zip' -print -quit | grep -q .; then
    echo "FAIL: $label reached distributable packaging" >&2
    exit 1
  fi
  if find "$audit_tmp" -maxdepth 1 \
    \( -name 'gradus-notary-submit.*' -o -name 'gradus-notary-acceptance.*' \) -print -quit | grep -q .; then
    echo "FAIL: $label leaked a secure temporary file" >&2
    exit 1
  fi
}

run_release_audit_case submit-fail
assert_status 55 "nonzero submit failure preserves the uploader exit status"
assert_contains "no submission was recorded" "submit failure reports that no ledger record exists"
[[ ! -e "$audit_root/.state/notary-submissions.tsv" ]] || {
  echo "FAIL: submit failure created a ledger" >&2
  exit 1
}
[[ ! -e "$FAKE_RUNTIME/info-count" ]] || {
  echo "FAIL: submit failure reached status polling" >&2
  exit 1
}
assert_no_release_downstream "submit failure"
echo "  ✓ submit failure leaves no ledger, poll, staple, package, or temp artifact"
((tests_run += 1))

run_release_audit_case submit-no-id
assert_status 70 "successful upload response without an ID exits 70"
assert_contains "Recover the ID from Apple history; do not resubmit" "missing ID points to safe history recovery"
[[ ! -e "$audit_root/.state/notary-submissions.tsv" ]] || {
  echo "FAIL: missing-ID response created a ledger without an ID" >&2
  exit 1
}
[[ ! -e "$FAKE_RUNTIME/info-count" ]] || {
  echo "FAIL: missing-ID response reached status polling" >&2
  exit 1
}
assert_no_release_downstream "missing-ID response"
echo "  ✓ missing ID leaves no ledger, poll, staple, package, or temp artifact"
((tests_run += 1))

run_release_audit_case terminal
assert_status 3 "honest rejected status exits 3 after recording"
[[ "$(awk -F $'\t' '$2 == "22222222-2222-2222-2222-222222222222" { count++ } END { print count + 0 }' "$audit_root/.state/notary-submissions.tsv")" -eq 1 ]] || {
  echo "FAIL: rejected submission was not retained in the durable ledger" >&2
  exit 1
}
assert_no_release_downstream "rejected recorded submission"
echo "  ✓ rejected submission stays recorded and cannot staple or package"
((tests_run += 1))


# A missing frozen runtime is caught before Xcode starts, because otherwise the
# failure arrives minutes into an archive and names a build setting rather than
# the command that fixes it.
CASE_OMIT_RUNTIME=1 run_release_audit_case accepted missing-runtime
unset CASE_OMIT_RUNTIME
assert_status 66 "a missing frozen runtime stops the release before archiving"
assert_contains "./build-gradus-runtime.sh" "the refusal names the command that produces the runtime"
[[ ! -e "$FAKE_RUNTIME/xcodebuild-calls" ]] || {
  echo "FAIL: xcodebuild ran before the frozen-runtime prerequisite was checked" >&2
  exit 1
}
assert_no_release_downstream "missing frozen runtime"
echo "  ✓ a missing frozen runtime stops the release before Xcode is invoked"
((tests_run += 1))

# The audit is upstream of the upload on purpose: a bundle Apple would reject
# must never leave the machine, and a submission that was never made needs no
# recovery.
export FAKE_VERIFY_EXIT=1
run_release_audit_case accepted failed-audit
unset FAKE_VERIFY_EXIT
if ((last_status == 0)); then
  echo "FAIL: a failed structural audit still completed the release" >&2
  exit 1
fi
[[ ! -f "$audit_app/build/Gradus.app.zip" ]] || {
  echo "FAIL: a bundle that failed the audit was zipped for submission" >&2
  exit 1
}
[[ ! -e "$audit_root/.state/notary-submissions.tsv" ]] || {
  echo "FAIL: a bundle that failed the audit was recorded as submitted" >&2
  exit 1
}
assert_no_release_downstream "failed structural audit"
echo "  ✓ a failed structural audit blocks zipping, submission and packaging"
((tests_run += 1))


# Submission is the one irreversible external step in this script, so it is
# opt-in. A run that was not asked to submit must do the whole local job and
# then stop, having sent nothing.
CASE_NOTARY_ARGS="" run_release_audit_case accepted unattended
assert_status 0 "an unattended run completes the local work without failing"
assert_contains "Stopping before submission" "an unattended run says it stopped short of Apple"
assert_contains "./notarize-mac.sh --attended" "an unattended run names the flag that submits"
[[ ! -f "$audit_app/build/Gradus.app.zip" ]] || {
  echo "FAIL: an unattended run packaged a submission artifact" >&2
  exit 1
}
[[ ! -e "$audit_root/.state/notary-submissions.tsv" ]] || {
  echo "FAIL: an unattended run recorded a submission" >&2
  exit 1
}
[[ ! -e "$FAKE_RUNTIME/submit-args" ]] || {
  echo "FAIL: an unattended run uploaded to Apple" >&2
  exit 1
}
# It still did the local work it is useful for.
grep -q 'export/Gradus.app' "$FAKE_RUNTIME/sign-calls" || {
  echo "FAIL: an unattended run skipped the signing pass" >&2
  exit 1
}
grep -q -- '--manifest' "$FAKE_RUNTIME/verify-calls" || {
  echo "FAIL: an unattended run skipped the structural audit" >&2
  exit 1
}
assert_no_release_downstream "unattended run"
echo "  ✓ an unattended run signs and audits but never submits"
((tests_run += 1))

echo "==> test-notary-scripts.sh: $tests_run behavior assertions passed"
