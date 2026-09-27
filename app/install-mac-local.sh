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
#   INSTALL_DIR          destination (default /Applications)
#   BUILD_DIR            archive scratch directory (default build)
#   GRADUS_EXPORT_ROOT   where the export is staged, signed, and audited
#                        (default $TMPDIR/gradus-mac-export -- see Staging)
#   PLIST_BUDDY          path to PlistBuddy
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
LSREGISTER="${LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
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
DERIVED_DATA_PATH=""

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

sweep_stale_mac_derived_data() {
  local tmp_root="$1" uid candidate owner recent foreign open_output open_status
  [[ -d "$tmp_root" && ! -L "$tmp_root" ]] || return 0
  tmp_root="$(cd -P "$tmp_root" && pwd -P)" || return 0
  command -v lsof >/dev/null 2>&1 || return 0
  uid="$(id -u)" || return 0
  while IFS= read -r -d '' candidate; do
    [[ ! -L "$candidate" ]] || continue
    owner="$(stat -f '%u' "$candidate" 2>/dev/null)" || continue
    [[ "$owner" == "$uid" ]] || continue
    if recent="$(find "$candidate" -mmin -1440 -print -quit 2>/dev/null)"; then
      [[ -z "$recent" ]] || continue
    else
      continue
    fi
    if foreign="$(find "$candidate" ! -uid "$uid" -print -quit 2>/dev/null)"; then
      [[ -z "$foreign" ]] || continue
    else
      continue
    fi
    printf '==> Checking stale DerivedData for open files: %s\n' "$candidate" >&2
    if open_output="$(lsof -t +D "$candidate" 2>&1)"; then
      continue
    else
      open_status=$?
    fi
    [[ "$open_status" -eq 1 && -z "$open_output" ]] || continue
    if rm -rf "$candidate" 2>/dev/null; then
      printf '    Removed stale DerivedData: %s\n' "$candidate" >&2
    fi
  done < <(find "$tmp_root" -mindepth 1 -maxdepth 1 -type d -name 'gradus-mac-derived-data.*' -print0 2>/dev/null)
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
  if [[ -n "$DERIVED_DATA_PATH" ]]; then
    rm -rf "$DERIVED_DATA_PATH" 2>/dev/null || true
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

sweep_stale_mac_derived_data "$STAGE_BASE"

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
  DERIVED_DATA_PATH="$(mktemp -d "$STAGE_BASE/gradus-mac-derived-data.XXXXXX")"
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
    -derivedDataPath "$DERIVED_DATA_PATH" \
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

echo "==> Quitting any running $PRODUCT_NAME or $LEGACY_PRODUCT_NAME"
# pkill exits 1 when nothing matched, which is the normal case and not an
# error. Under `set -e` an unguarded call would end the script here.
#
# The pre-rename process is quit as well. `pkill -x Gradus` does not match
# `GradusMac`, so until 2026-09-06 a still-running 1.10.0 GradusMac.app
# survived every install and went on publishing stale CloudKit records beside
# the new app. Quitting it is not removing it: the bundle stays on disk, and
# the WARN at the end still hands that decision to the operator.
quit_timeout="${QUIT_TIMEOUT_SECONDS:-15}"
for process_name in "$PRODUCT_NAME" "$LEGACY_PRODUCT_NAME"; do
  pkill -x "$process_name" 2>/dev/null || true
  quit_deadline=$((SECONDS + quit_timeout))
  while pgrep -x "$process_name" >/dev/null 2>&1; do
    if ((SECONDS >= quit_deadline)); then
      echo "FAIL: $process_name still running after ${quit_timeout}s; refusing to swap a live bundle." >&2
      exit 75
    fi
    progress "Waiting for $process_name to exit"
    sleep 0.5
  done
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

# Everything below is about one fact: macOS resolves a Dock click, Spotlight,
# and `open -b` through LaunchServices, which keys on CFBundleIdentifier across
# every registered bundle on this machine -- not on /Applications, and not on
# whichever path was written most recently. Two bundles claiming one identifier
# makes which binary launches unpredictable, and a registration outlives the
# bundle: a gate that builds into a temp root, runs, and deletes the root
# leaves its record behind. Install time is the one moment exactly one path is
# known to be correct, so the reconciliation belongs here rather than in each
# build script.

bundle_identifier_of() {
  "$PLIST_BUDDY" -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

# Prints every bundle path LaunchServices has registered for an identifier.
# The dump is one record per bundle separated by a dashed rule, and a record
# can repeat `identifier:` and `path:` for its document types, so only the
# first of each belongs to the bundle itself. Path lines carry a trailing
# `(0x...)` that is not part of the path.
registered_bundle_paths() {
  local identifier="$1"
  [[ -x "$LSREGISTER" ]] || return 0
  "$LSREGISTER" -dump 2>/dev/null | /usr/bin/awk '
    /^-{20,}$/ { if (id != "" && path != "") print id "\t" path; id=""; path=""; next }
    /^identifier:[[:space:]]+/ { if (id == "") { sub(/^identifier:[[:space:]]+/, ""); id = $0 } next }
    /^path:[[:space:]]+/ {
      if (path == "") { sub(/^path:[[:space:]]+/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path = $0 }
      next
    }
    END { if (id != "" && path != "") print id "\t" path }
  ' | /usr/bin/awk -F'\t' -v want="$identifier" '$1 == want { print $2 }' | sort -u
  return 0
}

# A registration is only dropped when it is provably disposable: the bundle is
# gone, or it lives under a build or temp root. Anything else is named and left
# alone -- unregistering an app someone installed deliberately is their call,
# and a bundle inside the install directory is refused outright rather than
# quietly taken out of the running.
is_disposable_registration() {
  local path="$1" root
  [[ -e "$path" ]] || return 0
  # The script cd's to `app/` above, so $PWD is the app directory: `$PWD/build`
  # is the real build root and an `app/app/build` entry would never match.
  for root in "$PWD/build" "$PWD/.build" "${GRADUS_EXPORT_ROOT:-}" \
    "${TMPDIR:-}" /private/tmp /tmp "$HOME/Library/Developer/Xcode/DerivedData"; do
    [[ -n "$root" ]] || continue
    [[ "$path" == "${root%/}/"* ]] && return 0
  done
  return 1
}

sweep_launch_services_registrations() {
  local identifier="$1" keep="$2" path dropped=0 kept=0
  if [[ ! -x "$LSREGISTER" ]]; then
    echo "WARN: lsregister is not available; skipping the registration sweep." >&2
    return 0
  fi
  while IFS= read -r path; do
    [[ -n "$path" && "$path" != "$keep" ]] || continue
    if [[ "$path" == "${INSTALL_DIR%/}/"* ]]; then
      # The pre-rename bundle gets the more specific notice below, which names
      # the exact command to remove it. Saying it twice trains the operator to
      # skip both.
      if [[ "$path" == "$INSTALL_DIR/$LEGACY_PRODUCT_NAME.app" ]]; then
        kept=$((kept + 1))
        continue
      fi
      echo "WARN: $path also claims $identifier." >&2
      echo "      LaunchServices picks between two such copies unpredictably." >&2
      echo "      Removing an app from $INSTALL_DIR is your call, not this" >&2
      echo "      installer's, so its registration was left alone." >&2
      kept=$((kept + 1))
      continue
    fi
    if is_disposable_registration "$path"; then
      "$LSREGISTER" -u "$path" >/dev/null 2>&1 || true
      dropped=$((dropped + 1))
    else
      echo "WARN: $path claims $identifier and is outside every build root;" >&2
      echo "      it was left registered." >&2
      kept=$((kept + 1))
    fi
  done < <(registered_bundle_paths "$identifier")
  "$LSREGISTER" -f "$keep" >/dev/null 2>&1 || true
  echo "    Dropped $dropped stale registration(s); left $kept in place."
}

echo "==> Reconciling LaunchServices registrations"
BUNDLE_IDENTIFIER="$(bundle_identifier_of "$INSTALLED_APP")"
if [[ -z "$BUNDLE_IDENTIFIER" ]]; then
  echo "FAIL: the installed bundle declares no CFBundleIdentifier, so nothing" >&2
  echo "      can say which binary a click will resolve to." >&2
  exit 65
fi
sweep_launch_services_registrations "$BUNDLE_IDENTIFIER" "$INSTALLED_APP"

# Relaunch the way the user launches it. `open -a <path>` proves the file
# exists and proves nothing about what a Dock click does; `open -b` goes
# through the same resolution a click does. The app was quit above, so this is
# a cold resolve rather than an activation of something already running --
# which is the only version of this check that discriminates.
echo "==> Relaunching by identifier $BUNDLE_IDENTIFIER"
if ! open -b "$BUNDLE_IDENTIFIER"; then
  echo "WARN: $BUNDLE_IDENTIFIER did not resolve; falling back to the path." >&2
  if ! open -a "$INSTALLED_APP"; then
    echo "WARN: installed cleanly but could not relaunch; start it from Finder." >&2
  fi
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
