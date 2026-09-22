#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

base="${GRADUS_STATIC_BASE:-}"
if [[ -z "$base" ]]; then
  if ! upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
    echo "FAIL: pre-push full gate cannot resolve this branch's upstream; set GRADUS_STATIC_BASE to the comparison commit" >&2
    exit 2
  fi
  if ! base="$(git merge-base HEAD "$upstream")" || [[ -z "$base" ]]; then
    echo "FAIL: pre-push full gate cannot find a merge base between HEAD and $upstream; set GRADUS_STATIC_BASE explicitly" >&2
    exit 2
  fi
  echo "==> Pre-push full Gradus gate: upstream=$upstream base=$base" >&2
else
  echo "==> Pre-push full Gradus gate: using explicit GRADUS_STATIC_BASE=$base" >&2
fi

if ! git cat-file -e "$base^{commit}" 2>/dev/null; then
  echo "FAIL: pre-push full gate comparison base is not a valid Git commit: $base" >&2
  exit 2
fi

export GRADUS_STATIC_BASE="$base"

progress_device="${GRADUS_PROGRESS_DEVICE:-}"
if [[ -z "$progress_device" && ! -t 1 && ! -t 2 ]] && { : > /dev/tty; } 2>/dev/null; then
  progress_device="/dev/tty"
fi

if [[ -n "$progress_device" ]]; then
  caffeinate -disu bash app/test-gate.sh 2>&1 | tee "$progress_device" || {
    statuses=("${PIPESTATUS[@]}")
    if [[ "${statuses[0]}" -ne 0 ]]; then
      exit "${statuses[0]}"
    fi
    exit "${statuses[1]}"
  }
  exit 0
fi

exec caffeinate -disu bash app/test-gate.sh
