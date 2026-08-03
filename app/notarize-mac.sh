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

cd "$(dirname "${BASH_SOURCE[0]}")"

PROFILE="gradus-notary"
ARCHIVE_PATH="build/GradusMac.xcarchive"
EXPORT_PATH="build/export"
APP_PATH="$EXPORT_PATH/GradusMac.app"
ZIP_PATH="build/GradusMac.app.zip"

echo "==> Checking notarytool credential profile ($PROFILE)"
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "FAIL: no notarytool keychain profile named '$PROFILE'." >&2
  echo "      Run the one-time store-credentials step first." >&2
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
  -destination "generic/platform=macOS"

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

echo "==> Submitting to Apple notary service (can take a few minutes; notarytool reports status as it polls)"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$PROFILE" --wait

echo "==> Stapling notarization ticket to the app"
xcrun stapler staple "$APP_PATH"

echo "==> Verifying Gatekeeper acceptance"
spctl -a -vv -t install "$APP_PATH"

version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")"
dist_zip="build/GradusMac-${version}.zip"
echo "==> Packaging distributable: $dist_zip"
ditto -c -k --keepParent "$APP_PATH" "$dist_zip"

echo "==> Done. Notarized, stapled app: $APP_PATH"
echo "    Distributable zip for testers: $dist_zip"
