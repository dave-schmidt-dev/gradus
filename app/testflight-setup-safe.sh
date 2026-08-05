#!/usr/bin/env bash
# Agent-safe wrapper for the existing TestFlight processing/assignment script.
# Credentials are supplied only by the fixed BWS consumer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/archive-upload-ios.sh"

# bws-secret-exec starts children with a minimal environment, just like the
# upload wrapper. Restore the account paths that uv and Xcode tooling expect.
export HOME="$(resolve_user_home)"
export USER="$(resolve_user_name)"
export LOGNAME="$USER"
uv_bin="$(resolve_uv)"

: "${APP_STORE_CONNECT_API_KEY:?required}"
: "${APP_STORE_CONNECT_KEY_ID:?required}"
: "${APP_STORE_CONNECT_ISSUER_ID:?required}"

cd "$SCRIPT_DIR"
exec "$uv_bin" run --with pyjwt --with cryptography testflight-setup.py "$@"
