#!/usr/bin/env bash
# Build, Developer-ID sign, and atomically install the narrow Safari credential bridge.
# The installed app is the sole process that should receive Full Disk Access.
set -euo pipefail

unset HISTFILE
set +o history 2>/dev/null || true
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="GradusCredentialBridge"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Zero Delta LLC (US) (4CJ49V6QHW)}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/build/credential-bridge}"
DERIVED_DATA="$BUILD_DIR/DerivedData"
SOURCE_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
STAGED_APP="$INSTALL_DIR/.$APP_NAME.app.incoming"
PREVIOUS_APP="$INSTALL_DIR/.$APP_NAME.app.previous"

dry_run=0
skip_build=0
installed=0

usage() {
  printf '%s\n' "Usage: $0 [--dry-run] [--skip-build]" >&2
}

progress() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$1" >&2
}

restore_previous() {
  rm -rf "$STAGED_APP" 2>/dev/null || true
  if ((installed == 0)) && [[ -d "$PREVIOUS_APP" ]]; then
    rm -rf "$INSTALLED_APP" 2>/dev/null || true
    mv "$PREVIOUS_APP" "$INSTALLED_APP" 2>/dev/null || true
  fi
}
trap restore_previous EXIT
trap 'exit 130' INT TERM

while (($# > 0)); do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --skip-build) skip_build=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 64 ;;
  esac
  shift
done

if [[ "$INSTALL_DIR" == "/" || "$INSTALL_DIR" == "$HOME" ]]; then
  printf '%s\n' "FAIL: refusing unsafe install directory: $INSTALL_DIR" >&2
  exit 64
fi

sign_and_verify() {
  local target="$1"
  local label="$2"
  if ! xattr -cr "$target"; then
    printf '%s\n' "FAIL: could not strip extended attributes from $label." >&2
    return 1
  fi
  progress "Developer-ID signing $label"
  if ! codesign --force --deep --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$target"; then
    printf '%s\n' "FAIL: Developer-ID signing failed for $label." >&2
    return 1
  fi
  if ! xattr -cr "$target"; then
    printf '%s\n' "FAIL: could not strip post-signing attributes from $label." >&2
    return 1
  fi
  if ! codesign --verify --deep --strict "$target"; then
    printf '%s\n' "FAIL: strict signature verification failed for $label." >&2
    return 1
  fi
}

if ((skip_build == 0)); then
  progress "Regenerating Xcode project"
  xcodegen generate
  progress "Building $APP_NAME (Release)"
  xcodebuild build \
    -project Gradus.xcodeproj \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO
fi

if [[ ! -d "$SOURCE_APP" ]]; then
  printf '%s\n' "FAIL: no Release bridge app at $SOURCE_APP" >&2
  exit 66
fi

sign_and_verify "$SOURCE_APP" "built bridge"

if ((dry_run == 1)); then
  printf '%s\n' "==> Dry run complete; no app was installed."
  exit 0
fi

if [[ ! -d "$INSTALL_DIR" ]]; then
  mkdir -p "$INSTALL_DIR"
fi
if [[ ! -w "$INSTALL_DIR" ]]; then
  printf '%s\n' "FAIL: install directory is not writable: $INSTALL_DIR" >&2
  exit 77
fi

rm -rf "$STAGED_APP" "$PREVIOUS_APP"
progress "Staging bridge at $STAGED_APP"
if ! ditto "$SOURCE_APP" "$STAGED_APP"; then
  printf '%s\n' "FAIL: could not stage the bridge app." >&2
  exit 73
fi

# Copying can add provenance attributes; verify the exact app that will hold the TCC row.
if ! xattr -cr "$STAGED_APP" || ! codesign --verify --deep --strict "$STAGED_APP"; then
  printf '%s\n' "FAIL: staged bridge did not pass strict signature verification." >&2
  exit 65
fi

if [[ -d "$INSTALLED_APP" ]]; then
  if ! mv "$INSTALLED_APP" "$PREVIOUS_APP"; then
    printf '%s\n' "FAIL: could not move the prior bridge aside." >&2
    exit 73
  fi
fi
if ! mv "$STAGED_APP" "$INSTALLED_APP"; then
  printf '%s\n' "FAIL: could not activate the staged bridge." >&2
  exit 73
fi
if ! codesign --verify --deep --strict "$INSTALLED_APP"; then
  printf '%s\n' "FAIL: installed bridge did not pass strict signature verification." >&2
  exit 65
fi

rm -rf "$PREVIOUS_APP"
installed=1
printf '%s\n' "==> Installed: $INSTALLED_APP"
printf '%s\n' "    In System Settings > Privacy & Security > Full Disk Access, enable only this app."
