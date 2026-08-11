#!/usr/bin/env bash
# Fixed BWS consumer for read-only internal TestFlight group discovery.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

resolve_user_home() {
  if [[ -n "${HOME:-}" ]]; then
    printf '%s\n' "$HOME"
    return 0
  fi
  /usr/bin/id -P | /usr/bin/awk -F: 'NF >= 9 {print $9; exit}'
}

resolve_uv() {
  local candidate
  candidate="$(command -v uv 2>/dev/null || true)"
  if [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  printf '%s\n' "$(resolve_user_home)/.local/bin/uv"
}

# shellcheck disable=SC2155
export HOME="$(resolve_user_home)"
export USER="${USER:-$(/usr/bin/id -un)}"
export LOGNAME="${LOGNAME:-$USER}"
: "${APP_STORE_CONNECT_API_KEY:?required}"
: "${APP_STORE_CONNECT_KEY_ID:?required}"
: "${APP_STORE_CONNECT_ISSUER_ID:?required}"
uv_bin="$(resolve_uv)"
cd "$SCRIPT_DIR"
exec "$uv_bin" run --with pyjwt --with cryptography list-testflight-internal-groups.py "$@"
