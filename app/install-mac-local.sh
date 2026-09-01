#!/usr/bin/env bash
# Archives, exports, signs, verifies, installs and relaunches Gradus in /Applications.
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

# Three names, not one. They were the same string until the Release wrapper was
# renamed, and collapsing them again is how this script broke: `xcodebuild`
# wants the SCHEME (`GradusMac`, an engineering identifier that is not going
# anywhere), while the archived product, the exported bundle, the installed app
# and the process to quit are all the PRODUCT name (`Gradus`, set by the
# Release configuration in project.yml). A single APP_NAME made the archive
# look for `Products/Applications/GradusMac.app`, which Release has not
# produced since the rename.
SCHEME_NAME="${SCHEME_NAME:-GradusMac}"
PRODUCT_NAME="${PRODUCT_NAME:-Gradus}"
# The pre-rename installed bundle. Two apps sharing one bundle identifier is
# not a state LaunchServices resolves sensibly, so the operator is told about
# it -- but removing an app from /Applications is their call, not a side effect
# of running an installer.
LEGACY_PRODUCT_NAME="GradusMac"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
PLIST_BUDDY="${PLIST_BUDDY:-/usr/libexec/PlistBuddy}"
BUILD_DIR="${BUILD_DIR:-build}"
ARCHIVE_PATH="$BUILD_DIR/GradusMac.xcarchive"
# The export is staged outside the checkout on purpose. This repository lives
# under ~/Documents, which macOS syncs through the iCloud Drive file provider,
# and that provider re-applies com.apple.FinderInfo to every .app directory it
# manages within about two seconds of it being cleared. codesign refuses to
# sign or verify an item carrying that attribute, so a bundle signed inside the
# synced tree loses the race however carefully it is cleaned -- and `ditto`
# would copy the attribute straight into the zip that goes to Apple. The
# archive stays in build/ (it is only ever read back by exportArchive); the
# export, the signing pass, and the audit run in $TMPDIR. GRADUS_EXPORT_ROOT
# overrides the location, and sign-mac-bundle.sh refuses either way if the
# destination turns out to be managed too.
STAGE_BASE="${TMPDIR:-/tmp}"
STAGE_BASE="${STAGE_BASE%/}"
EXPORT_ROOT="${GRADUS_EXPORT_ROOT:-$STAGE_BASE/gradus-mac-export}"
EXPORT_PATH="$EXPORT_ROOT/export"
APP_PATH="$EXPORT_PATH/$PRODUCT_NAME.app"
ARCHIVE_APP_PATH="$ARCHIVE_PATH/Products/Applications/$PRODUCT_NAME.app"
RUNTIME_APP="$BUILD_DIR/gradus-runtime/dist/GradusRuntime.app"
MANIFEST_PATH="$BUILD_DIR/gradus-mac-bundle-manifest.json"
SIGN_SCRIPT="${INSTALL_SIGN_SCRIPT:-./sign-mac-bundle.sh}"
VERIFY_SCRIPT="${INSTALL_VERIFY_SCRIPT:-./verify-mac-bundle.sh}"
SIGNING_IDENTITY="${INSTALL_SIGNING_IDENTITY:-Developer ID Application}"
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

INSTALLED_APP="$INSTALL_DIR/$PRODUCT_NAME.app"
STAGED_APP="$INSTALL_DIR/.$PRODUCT_NAME.app.incoming"
PREVIOUS_APP="$INSTALL_DIR/.$PRODUCT_NAME.app.previous"

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
      echo "     Previous $PRODUCT_NAME.app restored." >&2
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
    echo "      If this is the installed copy, the copy itself re-applied metadata" >&2
    echo "      codesign rejects -- com.apple.FinderInfo or a resource fork; note" >&2
    echo "      that com.apple.provenance is restricted, unstrippable, and NOT" >&2
    echo "      what fails here. The install has been rolled back; the previously" >&2
    echo "      installed app is untouched." >&2
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
  # The frozen Python runtime is a prerequisite, not a build step: producing it
  # downloads a pinned CPython package. Xcode hard-fails the Release embed
  # phase without it, but minutes into the archive and naming a build setting
  # rather than the command to run.
  if [[ ! -d "$RUNTIME_APP" ]]; then
    echo "FAIL: the frozen Python runtime is missing at $RUNTIME_APP." >&2
    echo "      Build it first (it downloads a pinned CPython, so it is deliberately" >&2
    echo "      not run for you):" >&2
    echo "      ./build-gradus-runtime.sh" >&2
    exit 66
  fi

  echo "==> Regenerating Xcode project from project.yml"
  xcodegen generate

  # Deliberately not `rm -rf "$BUILD_DIR"`: it holds gradus-runtime, the
  # prerequisite checked for immediately above.
  rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH" "$MANIFEST_PATH"
  mkdir -p "$BUILD_DIR"

  echo "==> Archiving $SCHEME_NAME (this takes a few minutes; output stays visible)"
  progress "Starting xcodebuild archive for $SCHEME_NAME"
  xcodebuild archive \
    -project Gradus.xcodeproj \
    -scheme "$SCHEME_NAME" \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    GRADUS_SOURCE_REVISION="$SOURCE_REVISION" \
    GRADUS_PROJECT_SHA256="$PROJECT_SHA256"

  if [[ ! -d "$ARCHIVE_APP_PATH" ]]; then
    echo "FAIL: archive did not contain $PRODUCT_NAME.app." >&2
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

# `exportArchive` does not sign Contents/Helpers/GradusRuntime.app: a run
# script copies it in, and PyInstaller leaves it ad-hoc signed. Sign the whole
# tree explicitly, leaves first, before anything verifies or installs it.
#
# `--preserve-entitlements` re-applies each item's existing blob rather than
# the source .entitlements file: Xcode injects com.apple.application-identifier
# and com.apple.developer.team-identifier from the provisioning profile, and
# re-signing from the source file alone would drop both and break CloudKit at
# runtime while every signature check still passed.
echo "==> Signing embedded code from the leaves inward"
if ! "$SIGN_SCRIPT" "$APP_PATH" \
  --identity "$SIGNING_IDENTITY" \
  --preserve-entitlements; then
  echo "FAIL: inside-out signing of the exported bundle failed." >&2
  exit 65
fi

echo "==> Verifying the exported bundle"
if ! strip_and_verify "$APP_PATH" "exported"; then
  exit 65
fi
verify_provenance "$APP_PATH" "exported" || exit 65
# The same structural audit the notarized release path runs, so a locally
# installed build and a distributed one are held to one contract.
if ! SOURCE_REVISION="$SOURCE_REVISION" "$VERIFY_SCRIPT" "$APP_PATH" --manifest "$MANIFEST_PATH"; then
  echo "FAIL: the exported bundle did not pass the structural audit." >&2
  exit 65
fi

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

echo "==> Quitting any running $PRODUCT_NAME"
# pkill exits 1 when nothing matched, which is the normal case and not an
# error. Under `set -e` an unguarded call would end the script here.
pkill -x "$PRODUCT_NAME" 2>/dev/null || true
quit_timeout="${QUIT_TIMEOUT_SECONDS:-15}"
quit_deadline=$((SECONDS + quit_timeout))
while pgrep -x "$PRODUCT_NAME" >/dev/null 2>&1; do
  if ((SECONDS >= quit_deadline)); then
    echo "FAIL: $PRODUCT_NAME still running after ${quit_timeout}s; refusing to swap a live bundle." >&2
    exit 75
  fi
  progress "Waiting for $PRODUCT_NAME to exit"
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

legacy_installed="$INSTALL_DIR/$LEGACY_PRODUCT_NAME.app"
if [[ -d "$legacy_installed" ]]; then
  echo "WARN: $legacy_installed is still present and carries the same bundle" >&2
  echo "      identifier as the app just installed. LaunchServices picks between" >&2
  echo "      two such copies unpredictably. Remove the old one when you are" >&2
  echo "      satisfied with this install:" >&2
  echo "      rm -rf \"$legacy_installed\"" >&2
fi

echo "==> Done. $PRODUCT_NAME $incoming_version installed at $INSTALLED_APP"
echo "    Gradus reads its credential-free snapshot from Application Support."
echo "    It does not require Documents access for ordinary monitoring."

# The installer deliberately does not stop, disable, or delete the legacy
# launchd job. Cutover is a decision with a rollback, and it belongs to the app
# -- which can put the job back -- not to a script that has already exited.
LEGACY_HOME="${GRADUS_LEGACY_HOME:-$HOME}"
if [[ -f "$LEGACY_HOME/Library/LaunchAgents/local.gradus-snapshot.plist" ]] ||
   [[ -x "$LEGACY_HOME/.launchd/scripts/gradus_snapshot.sh" ]]; then
  echo "    The legacy local.gradus-snapshot job is still installed and untouched."
  echo "    Move refresh into Gradus from Settings > Legacy Background Job when"
  echo "    the other tools have switched to the installed snapshot path."
fi
