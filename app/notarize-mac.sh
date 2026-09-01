#!/usr/bin/env bash
# Archives, exports, signs inside out, audits, and -- when run attended --
# notarizes and staples the Gradus Mac bundle for Developer ID distribution
# (T6.2).
#
# Submission is opt-in: without `--attended` the script stops after the audit
# and uploads nothing. See the ATTENDED block below for why.
#
# Requires:
# 1. The one-time `xcrun notarytool store-credentials gradus-notary ...`
#    setup already done (stores the ASC API key in the login keychain).
# 2. The Developer ID provisioning profile already created and installed via
#    `create-developer-id-profile.py` (ExportOptionsMac.plist references it
#    by name under manual signing). Cloud-managed signing
#    (-allowProvisioningUpdates + API-key auth) was tried first and reliably
#    failed with "Cloud signing permission error" even with an Admin-role
#    key — a known-flaky Apple service for Developer ID exports (see
#    developer.apple.com/forums/thread/688626) — so this deliberately avoids
#    it in favor of a manually-installed profile.
set -euo pipefail

unset HISTFILE
set +o history 2>/dev/null || true
umask 077

cd "$(dirname "${BASH_SOURCE[0]}")"

PROFILE="${NOTARY_PROFILE:-gradus-notary}"
NOTARY_STATUS_SCRIPT="${NOTARY_STATUS_SCRIPT:-./notary-status.sh}"
SIGN_SCRIPT="${NOTARY_SIGN_SCRIPT:-./sign-mac-bundle.sh}"
VERIFY_SCRIPT="${NOTARY_VERIFY_SCRIPT:-./verify-mac-bundle.sh}"
SIGNING_IDENTITY="${NOTARY_SIGNING_IDENTITY:-Developer ID Application}"
PLIST_BUDDY="${PLIST_BUDDY:-/usr/libexec/PlistBuddy}"
PYTHON="${NOTARY_PYTHON:-python3}"
# `GradusMac` survives in the archive name and the scheme: those are internal
# engineering identifiers. The exported product is `Gradus.app`, because the
# Release configuration sets PRODUCT_NAME to `Gradus` (project.yml) and that is
# the only name a user ever sees.
ARCHIVE_PATH="build/GradusMac.xcarchive"
EXPORT_PATH="build/export"
APP_PATH="$EXPORT_PATH/Gradus.app"
RUNTIME_APP="build/gradus-runtime/dist/GradusRuntime.app"
MANIFEST_PATH="build/gradus-mac-bundle-manifest.json"
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
    echo "FAIL: source checkout is dirty; notarize producer provenance from a clean revision" >&2
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
# Submission is an attended step, by default and on purpose. Everything up to
# and including verification is reproducible local work; the upload is an
# irreversible external action against Apple's service, made under David's
# Developer ID, that starts a queue entry someone then has to track. A script
# that uploads simply because it was run is one cron entry or one agent away
# from submitting a build nobody chose to ship. So the network write needs a
# human saying so at the moment it happens.
ATTENDED="${NOTARY_ATTENDED:-0}"
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --attended)
      ATTENDED=1
      shift
      ;;
    --help)
      echo "Usage: notarize-mac.sh [--attended]"
      echo
      echo "  Archives, exports, signs inside out and audits the Mac bundle."
      echo "  Without --attended it stops there and uploads nothing."
      echo "  With --attended it also submits to Apple, polls, staples and packages."
      exit 0
      ;;
    *)
      echo "FAIL: unknown notarize-mac option '$1'" >&2
      exit 2
      ;;
  esac
done

SOURCE_REVISION="$(resolve_source_revision)"
PROJECT_SHA256="$(/usr/bin/shasum -a 256 project.yml | /usr/bin/awk '{print $1}')"
ZIP_PATH="build/Gradus.app.zip"
submit_output=""
acceptance_output=""

cleanup() {
  if [[ -n "$submit_output" ]]; then
    rm -f "$submit_output" 2>/dev/null || true
  fi
  if [[ -n "$acceptance_output" ]]; then
    rm -f "$acceptance_output" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

progress() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$1" >&2
}

if ! command -v "$PYTHON" >/dev/null 2>&1; then
  echo "FAIL: required tool is missing: $PYTHON" >&2
  exit 69
fi

echo "==> Checking notarytool credential profile ($PROFILE)"
progress "Requesting Apple notarization history for release preflight"
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "FAIL: Apple notarytool history request failed using profile '$PROFILE'." >&2
  echo "      This can be a service, network, request, or Keychain-profile issue." >&2
  echo "      A sandboxed agent may not see the login Keychain. Do not recreate the" >&2
  echo "      profile based on this check alone; verify in Terminal or approve an" >&2
  echo "      outside-sandbox check first:" >&2
  echo "      xcrun notarytool history --keychain-profile $PROFILE" >&2
  exit 1
fi
echo "    Profile found. OK."

# The frozen Python runtime is a prerequisite, not a build step: producing it
# downloads a pinned CPython package, and nothing in the release path may
# acquire code from the network without the operator having asked for it. Xcode
# hard-fails the Release embed phase when it is absent, but that failure
# arrives minutes into an archive and names a build setting rather than the
# command to run. Check it here instead.
if [[ ! -d "$RUNTIME_APP" ]]; then
  echo "FAIL: the frozen Python runtime is missing at $RUNTIME_APP." >&2
  echo "      Build it first (it downloads a pinned CPython, so it is deliberately" >&2
  echo "      not run for you):" >&2
  echo "      ./build-gradus-runtime.sh" >&2
  exit 66
fi

echo "==> Regenerating Xcode project from project.yml"
xcodegen generate

# Deliberately NOT `rm -rf build`: build/gradus-runtime holds the frozen
# runtime checked for above, and wiping it here would delete the prerequisite
# this script just insisted on and then fail inside Xcode's embed phase.
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH" "$ZIP_PATH" "$MANIFEST_PATH"
mkdir -p build

echo "==> Archiving GradusMac"
xcodebuild archive \
  -project Gradus.xcodeproj \
  -scheme GradusMac \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  GRADUS_SOURCE_REVISION="$SOURCE_REVISION" \
  GRADUS_PROJECT_SHA256="$PROJECT_SHA256"

echo "==> Exporting for Developer ID distribution"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist ExportOptionsMac.plist

if [[ ! -d "$APP_PATH" ]]; then
  echo "FAIL: the export produced no $APP_PATH." >&2
  echo "      Release builds a wrapper named Gradus.app; check ExportOptionsMac.plist" >&2
  echo "      and the Release PRODUCT_NAME in project.yml if this name has moved." >&2
  exit 66
fi

# `exportArchive` signs the targets Xcode knows about. It does not sign
# Contents/Helpers/GradusRuntime.app, which a run script copies in and which
# PyInstaller leaves ad-hoc signed -- an ad-hoc nested binary is rejected by
# the notary service. Sign the whole tree explicitly, leaves first. Extended
# attributes are stripped inside that pass, before any signature is computed.
#
# `--preserve-entitlements` re-applies each item's existing blob rather than
# the source .entitlements file: Xcode injects com.apple.application-identifier
# and com.apple.developer.team-identifier from the provisioning profile, and
# re-signing from the source file alone would drop both and break CloudKit at
# runtime while every signature check still passed.
echo "==> Signing embedded code from the leaves inward"
"$SIGN_SCRIPT" "$APP_PATH" \
  --identity "$SIGNING_IDENTITY" \
  --preserve-entitlements

# The audit runs before the zip, so a bundle that fails it is never uploaded.
# It repeats `codesign --verify --deep --strict` itself, and adds the checks a
# strict verify does not make: Team ID, hardened runtime, entitlement
# allowlist, architecture, file modes, and bundle-relative helper paths.
echo "==> Verifying the exported bundle"
SOURCE_REVISION="$SOURCE_REVISION" "$VERIFY_SCRIPT" "$APP_PATH" --manifest "$MANIFEST_PATH"

if [[ "$ATTENDED" != "1" ]]; then
  echo "==> Stopping before submission: this run is unattended."
  echo "    Verified bundle:  $APP_PATH"
  echo "    Bundle manifest:  $MANIFEST_PATH"
  echo
  echo "    Uploading to Apple is an attended step: it is an irreversible external"
  echo "    action under your Developer ID and it opens a queue entry someone has"
  echo "    to follow. Nothing has been sent. Re-run when you are at the machine"
  echo "    and ready to submit this exact bundle:"
  echo "      ./notarize-mac.sh --attended"
  exit 0
fi

echo "==> Zipping app bundle for notary submission"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Submitting to Apple notary service (upload progress remains visible)"
submit_output="$(mktemp "${TMPDIR:-/tmp}/gradus-notary-submit.XXXXXX")"
set +e
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$PROFILE" --no-wait 2>&1 | tee "$submit_output"
submit_status=${PIPESTATUS[0]}
set -e
if ((submit_status != 0)); then
  echo "FAIL: notarytool did not accept the upload; no submission was recorded." >&2
  exit "$submit_status"
fi

submission_id="$(awk '/^[[:space:]]*id:[[:space:]]*[[:xdigit:]-]{36}[[:space:]]*$/ { print $2; exit }' "$submit_output")"
if [[ -z "$submission_id" ]]; then
  echo "FAIL: upload completed, but its submission ID could not be read." >&2
  echo "      Recover the ID from Apple history; do not resubmit:" >&2
  echo "      $NOTARY_STATUS_SCRIPT" >&2
  exit 70
fi

"$NOTARY_STATUS_SCRIPT" --record "$submission_id" --name "Gradus.app.zip" --artifact "$ZIP_PATH"
echo "==> Submission recorded before polling: $submission_id"
echo "    If this process is interrupted, resume the queue check without resubmitting:"
echo "    $NOTARY_STATUS_SCRIPT --watch --id $submission_id"
"$NOTARY_STATUS_SCRIPT" --watch --id "$submission_id"

echo "==> Independently confirming exact Accepted status directly with Apple"
acceptance_output="$(mktemp "${TMPDIR:-/tmp}/gradus-notary-acceptance.XXXXXX")"
progress "Requesting live Apple notarization info for submission $submission_id"
if ! xcrun notarytool info "$submission_id" --keychain-profile "$PROFILE" --output-format json >"$acceptance_output" 2>/dev/null; then
  echo "FAIL: direct Apple info request failed; this may be a service, network," >&2
  echo "      request, or Keychain-profile issue. Refusing to staple or package." >&2
  exit 70
fi

set +e
"$PYTHON" - "$acceptance_output" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        status = json.load(handle).get("status")
except (OSError, ValueError, AttributeError):
    raise SystemExit(70)

if status == "Accepted":
    raise SystemExit(0)
if status == "In Progress":
    raise SystemExit(2)
raise SystemExit(3)
PY
acceptance_status=$?
set -e

case "$acceptance_status" in
  0)
    echo "    Direct Apple status: Accepted. OK."
    ;;
  2)
    echo "FAIL: direct Apple status is still In Progress; refusing to staple or package." >&2
    exit 2
    ;;
  3)
    echo "FAIL: direct Apple status is terminal and not Accepted; refusing to staple or package." >&2
    exit 3
    ;;
  *)
    echo "FAIL: direct Apple status response was unreadable; refusing to staple or package." >&2
    exit 70
    ;;
esac

echo "==> Stapling notarization ticket to the app"
xcrun stapler staple "$APP_PATH"

echo "==> Verifying Gatekeeper acceptance"
spctl -a -vv -t install "$APP_PATH"

version="$("$PLIST_BUDDY" -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
dist_zip="build/Gradus-${version}.zip"
echo "==> Packaging distributable: $dist_zip"
ditto -c -k --keepParent "$APP_PATH" "$dist_zip"

echo "==> Done. Notarized, stapled app: $APP_PATH"
echo "    Distributable zip for testers: $dist_zip"
