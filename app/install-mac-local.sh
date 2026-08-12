#!/usr/bin/env bash
# Archives, exports, installs and relaunches GradusMac in /Applications.
#
# This is the local-install counterpart to notarize-mac.sh, which covers the
# *distribution* path. Local installs need no notarization: Gatekeeper only
# enforces it on quarantined files, and a bundle built here never carries
# com.apple.quarantine. What they do need is the same post-signing extended
# attribute strip, and one more of them than the notary path needs.
#
# ## Why this script exists
#
# macOS re-tags files with com.apple.provenance as a side effect of codesign
# running *and* as a side effect of copying an app into /Applications, so a
# bundle that passed `codesign --verify --deep --strict` on export can fail the
# same check once installed. That was found by hand after three sessions of
# doing this sequence manually, and the manual version also hit the classic
# `set -e` footgun on the way: a failure on the left of `&&` does not abort the
# script, it just makes the right-hand side not run and leaves $? = 0 at the
# end of the line. Every check below is therefore an explicit `if !`, never a
# `&&` chain.
#
# ## Staging
#
# The new bundle is copied in beside the old one and verified *there*, then
# swapped by rename. Verifying after replacing the installed app would mean a
# failed verify had already destroyed a working install, which is the wrong way
# round for the one machine that runs this.
#
# Usage:
#   ./install-mac-local.sh                 archive, export, install, relaunch
#   ./install-mac-local.sh --dry-run       build and verify only; touch nothing
#   ./install-mac-local.sh --skip-build    reuse the existing export
#
# Environment:
#   INSTALL_DIR   destination (default /Applications)
#   BUILD_DIR     archive/export scratch directory (default build)
#   PLIST_BUDDY   path to PlistBuddy
set -euo pipefail

unset HISTFILE
set +o history 2>/dev/null || true
umask 077

cd "$(dirname "${BASH_SOURCE[0]}")"

APP_NAME="GradusMac"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
PLIST_BUDDY="${PLIST_BUDDY:-/usr/libexec/PlistBuddy}"
BUILD_DIR="${BUILD_DIR:-build}"
ARCHIVE_PATH="$BUILD_DIR/GradusMac.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/$APP_NAME.app"
ARCHIVE_APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"
ALLOWED_UNTRACKED_SOURCE_REPORT="verifications/2026-08-09-internal-testflight-candidate-migration-verification.md"
assert_source_checkout_clean() {
  local root="$1" status_output status_line dirty=0
  if ! status_output="$(/usr/bin/git -C "$root" status --porcelain=v1 --untracked-files=all 2>/dev/null)"; then
    echo "FAIL: could not inspect source checkout status" >&2
    return 1
  fi
  while IFS= read -r status_line; do
    [[ -z "$status_line" ]] && continue
    if [[ "$status_line" != "?? $ALLOWED_UNTRACKED_SOURCE_REPORT" ]]; then
      dirty=1
      break
    fi
  done <<< "$status_output"
  if (( dirty )); then
    echo "FAIL: source checkout is dirty; install producer provenance from a clean revision" >&2
    return 1
  fi
}
resolve_source_revision() {
  local injected="${GRADUS_SOURCE_REVISION:-}" revision
  if revision="$(/usr/bin/git rev-parse HEAD 2>/dev/null)"; then
    assert_source_checkout_clean "." || return 1
    printf '%s\n' "$revision"
    return 0
  fi
  if [[ -n "${injected//[[:space:]]/}" ]]; then
    printf '%s\n' "$injected"
    return 0
  fi
  echo "FAIL: source revision is unavailable (set GRADUS_SOURCE_REVISION for a non-Git fixture)" >&2
  return 1
}
SOURCE_REVISION="$(resolve_source_revision)"
PROJECT_SHA256="$(/usr/bin/shasum -a 256 project.yml | /usr/bin/awk '{print $1}')"

INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
STAGED_APP="$INSTALL_DIR/.$APP_NAME.app.incoming"
PREVIOUS_APP="$INSTALL_DIR/.$APP_NAME.app.previous"

dry_run=0
skip_build=0

while (($# > 0)); do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --skip-build) skip_build=1 ;;
    -h | --help)
      sed -n '2,40p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "FAIL: unknown argument: $1" >&2
      exit 64
      ;;
  esac
  shift
done

progress() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$1" >&2
}

# Leaves the destination as it was found. The staged copy is disposable; the
# previous bundle is not, so it is only ever removed once its replacement is
# verified and in place.
restore_previous() {
  rm -rf "$STAGED_APP" 2>/dev/null || true
  if [[ -d "$PREVIOUS_APP" ]]; then
    if [[ ! -d "$INSTALLED_APP" ]]; then
      mv "$PREVIOUS_APP" "$INSTALLED_APP" 2>/dev/null || true
      echo "     Previous $APP_NAME.app restored." >&2
    else
      rm -rf "$PREVIOUS_APP" 2>/dev/null || true
    fi
  fi
}
trap restore_previous EXIT
trap 'exit 130' INT TERM

bundle_version() {
  local plist="$1/Contents/Info.plist"
  local short build
  short="$("$PLIST_BUDDY" -c "Print :CFBundleShortVersionString" "$plist" 2>/dev/null || echo "?")"
  build="$("$PLIST_BUDDY" -c "Print :CFBundleVersion" "$plist" 2>/dev/null || echo "?")"
  printf '%s (%s)' "$short" "$build"
}

# `xattr -cr` then a strict verify, as one unit, because neither half means
# anything alone: the strip is only known to have worked if the verify passes,
# and the verify is only meaningful on a stripped bundle.
strip_and_verify() {
  local target="$1"
  local label="$2"

  if ! xattr -cr "$target"; then
    echo "FAIL: could not strip extended attributes from the $label bundle." >&2
    return 1
  fi
  if ! codesign --verify --deep --strict "$target"; then
    echo "FAIL: strict signature verification failed on the $label bundle." >&2
    echo "      If this is the installed copy, com.apple.provenance was re-applied" >&2
    echo "      by the copy itself and could not be stripped. The install has been" >&2
    echo "      rolled back; the previously installed app is untouched." >&2
    return 1
  fi
  return 0
}

verify_provenance() {
  local target="$1"
  local label="$2"
  local plist="$target/Contents/Info.plist"
  local source_revision project_sha256

  if [[ ! -f "$plist" ]]; then
    echo "FAIL: $label bundle has no Info.plist for provenance verification." >&2
    return 1
  fi
  if ! source_revision="$($PLIST_BUDDY -c 'Print :GRADUS_SOURCE_REVISION' "$plist" 2>/dev/null)"; then
    echo "FAIL: $label bundle is missing GRADUS_SOURCE_REVISION." >&2
    return 1
  fi
  if ! project_sha256="$($PLIST_BUDDY -c 'Print :GRADUS_PROJECT_SHA256' "$plist" 2>/dev/null)"; then
    echo "FAIL: $label bundle is missing GRADUS_PROJECT_SHA256." >&2
    return 1
  fi
  if [[ "$source_revision" != "$SOURCE_REVISION" ]]; then
    echo "FAIL: $label bundle source revision does not match the clean checkout." >&2
    return 1
  fi
  if [[ "$project_sha256" != "$PROJECT_SHA256" ]]; then
    echo "FAIL: $label bundle project digest does not match project.yml." >&2
    return 1
  fi
}

if ((skip_build == 0)); then
  echo "==> Regenerating Xcode project from project.yml"
  xcodegen generate

  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR"

  echo "==> Archiving $APP_NAME (this takes a few minutes; output stays visible)"
  progress "Starting xcodebuild archive for $APP_NAME"
  xcodebuild archive \
    -project Gradus.xcodeproj \
    -scheme "$APP_NAME" \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    GRADUS_SOURCE_REVISION="$SOURCE_REVISION" \
    GRADUS_PROJECT_SHA256="$PROJECT_SHA256"

  if [[ ! -d "$ARCHIVE_APP_PATH" ]]; then
    echo "FAIL: archive did not contain $APP_NAME.app." >&2
    exit 66
  fi
  verify_provenance "$ARCHIVE_APP_PATH" "archived" || exit 65

  echo "==> Exporting for Developer ID distribution"
  # Export the same Developer ID-signed artifact that is installed locally.
  # GradusMac consumes only its Application Support snapshot mirror; it never
  # needs a Documents-folder grant for ordinary monitoring.
  progress "Starting xcodebuild -exportArchive"
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist ExportOptionsMac.plist
else
  echo "==> Skipping build; reusing $APP_PATH"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "FAIL: no exported app at $APP_PATH." >&2
  echo "      Run without --skip-build, or check the export step's output." >&2
  exit 66
fi

echo "==> Verifying the exported bundle"
if ! strip_and_verify "$APP_PATH" "exported"; then
  exit 65
fi
verify_provenance "$APP_PATH" "exported" || exit 65

incoming_version="$(bundle_version "$APP_PATH")"
if [[ -d "$INSTALLED_APP" ]]; then
  echo "    Installed: $(bundle_version "$INSTALLED_APP")  ->  incoming: $incoming_version"
else
  echo "    Nothing installed yet; incoming: $incoming_version"
fi

if ((dry_run == 1)); then
  echo "==> Dry run: verified $APP_PATH and stopped before touching $INSTALL_DIR"
  exit 0
fi

if [[ ! -d "$INSTALL_DIR" ]]; then
  echo "FAIL: install directory does not exist: $INSTALL_DIR" >&2
  exit 66
fi
if [[ ! -w "$INSTALL_DIR" ]]; then
  echo "FAIL: install directory is not writable: $INSTALL_DIR" >&2
  exit 77
fi

echo "==> Quitting any running $APP_NAME"
# pkill exits 1 when nothing matched, which is the normal case and not an
# error. Under `set -e` an unguarded call would end the script here.
pkill -x "$APP_NAME" 2>/dev/null || true
quit_timeout="${QUIT_TIMEOUT_SECONDS:-15}"
quit_deadline=$((SECONDS + quit_timeout))
while pgrep -x "$APP_NAME" >/dev/null 2>&1; do
  if ((SECONDS >= quit_deadline)); then
    echo "FAIL: $APP_NAME still running after ${quit_timeout}s; refusing to swap a live bundle." >&2
    exit 75
  fi
  progress "Waiting for $APP_NAME to exit"
  sleep 0.5
done

echo "==> Staging the new bundle beside the installed one"
rm -rf "$STAGED_APP"
if ! ditto "$APP_PATH" "$STAGED_APP"; then
  echo "FAIL: could not copy the app into $INSTALL_DIR." >&2
  exit 73
fi

# The strip that the notary path does not need. `ditto` into /Applications
# re-tags the copy with com.apple.provenance even though the source was clean,
# so the bundle that just passed verification above can fail here.
echo "==> Verifying the staged copy in place"
if ! strip_and_verify "$STAGED_APP" "staged"; then
  exit 65
fi
verify_provenance "$STAGED_APP" "staged" || exit 65

echo "==> Swapping $INSTALLED_APP"
rm -rf "$PREVIOUS_APP"
if [[ -d "$INSTALLED_APP" ]]; then
  if ! mv "$INSTALLED_APP" "$PREVIOUS_APP"; then
    echo "FAIL: could not move the existing app aside." >&2
    exit 73
  fi
fi
if ! mv "$STAGED_APP" "$INSTALLED_APP"; then
  echo "FAIL: could not move the staged app into place." >&2
  exit 73
fi
rm -rf "$PREVIOUS_APP"

echo "==> Relaunching"
if ! open -a "$INSTALLED_APP"; then
  echo "WARN: installed cleanly but could not relaunch; start it from Finder." >&2
fi

echo "==> Done. $APP_NAME $incoming_version installed at $INSTALLED_APP"
echo "    GradusMac reads its credential-free snapshot from Application Support."
echo "    It does not require Documents access for ordinary monitoring."
