#!/usr/bin/env bash
# Archives, exports, notarizes, and staples GradusMac for Developer ID
# distribution (T6.2). Requires:
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
PLIST_BUDDY="${PLIST_BUDDY:-/usr/libexec/PlistBuddy}"
PYTHON="${NOTARY_PYTHON:-python3}"
ARCHIVE_PATH="build/GradusMac.xcarchive"
EXPORT_PATH="build/export"
APP_PATH="$EXPORT_PATH/GradusMac.app"
resolve_source_revision() {
  local injected="${GRADUS_SOURCE_REVISION:-}" revision
  if revision="$(/usr/bin/git rev-parse HEAD 2>/dev/null)"; then
    if [[ -n "$(/usr/bin/git status --porcelain --untracked-files=all 2>/dev/null)" ]]; then
      echo "FAIL: source checkout is dirty; notarize producer provenance from a clean revision" >&2
      return 1
    fi
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
ZIP_PATH="build/GradusMac.app.zip"
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

echo "==> Regenerating Xcode project from project.yml"
xcodegen generate

rm -rf build
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

# Every file in the exported bundle -- including ones codesign itself just
# wrote -- can carry a com.apple.provenance extended attribute (macOS
# re-tags files as a side effect of codesign running, so this must happen
# after export/signing, not before -- same root cause hit on the iOS side,
# see archive-upload-ios.sh and apple_developer/LESSONS.md). A strict
# codesign verify rejects it; strip before verifying/zipping.
xattr -cr "$APP_PATH"

echo "==> Verifying signature"
codesign --verify --deep --strict "$APP_PATH"

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

"$NOTARY_STATUS_SCRIPT" --record "$submission_id" --name "GradusMac.app.zip" --artifact "$ZIP_PATH"
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
dist_zip="build/GradusMac-${version}.zip"
echo "==> Packaging distributable: $dist_zip"
ditto -c -k --keepParent "$APP_PATH" "$dist_zip"

echo "==> Done. Notarized, stapled app: $APP_PATH"
echo "    Distributable zip for testers: $dist_zip"
