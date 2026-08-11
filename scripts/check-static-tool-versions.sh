#!/usr/bin/env bash

set -euo pipefail

# Keep the static gate reproducible across developer machines. This check only
# observes tool version output; installation and PATH changes are deliberate
# operator actions outside the hook.
readonly REQUIRED_SWIFTLINT="0.65.0"
readonly REQUIRED_SWIFTFORMAT="0.62.1"
readonly REQUIRED_SHELLCHECK="0.11.0"

check_version() {
  local tool="$1" expected="$2" version_args="$3" output actual

  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'static gate: %s %s is required, but %s was not found on PATH.\n' \
      "$tool" "$expected" "$tool" >&2
    return 1
  fi

  if ! output="$($tool $version_args 2>/dev/null)"; then
    printf 'static gate: could not read %s version; %s %s is required.\n' \
      "$tool" "$tool" "$expected" >&2
    return 1
  fi

  actual="$(printf '%s\n' "$output" | /usr/bin/grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | /usr/bin/head -n 1 || true)"
  if [[ "$actual" != "$expected" ]]; then
    if [[ -n "$actual" ]]; then
      printf 'static gate: %s %s is required; found %s.\n' "$tool" "$expected" "$actual" >&2
    else
      printf 'static gate: %s %s is required; version output was not recognized.\n' \
        "$tool" "$expected" >&2
    fi
    return 1
  fi
}

failures=0
check_version swiftlint "$REQUIRED_SWIFTLINT" version || failures=$((failures + 1))
check_version swiftformat "$REQUIRED_SWIFTFORMAT" --version || failures=$((failures + 1))
check_version shellcheck "$REQUIRED_SHELLCHECK" --version || failures=$((failures + 1))

if (( failures > 0 )); then
  printf 'static gate: install or activate the required versions, then retry the commit.\n' >&2
  exit 1
fi
