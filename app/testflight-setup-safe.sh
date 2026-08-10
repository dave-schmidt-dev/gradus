#!/usr/bin/env bash
# Fixed BWS consumer wrapper for the attended assignment-only boundary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/archive-upload-ios.sh"
export HOME="$(resolve_user_home)"
export USER="$(resolve_user_name)"
export LOGNAME="$USER"
uv_bin="$(resolve_uv)"
: "${APP_STORE_CONNECT_API_KEY:?required}"
: "${APP_STORE_CONNECT_KEY_ID:?required}"
: "${APP_STORE_CONNECT_ISSUER_ID:?required}"
cd "$SCRIPT_DIR"
exec "$uv_bin" run --with pyjwt --with cryptography testflight-assign.py "$@"
