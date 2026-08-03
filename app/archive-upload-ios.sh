#!/usr/bin/env bash
# Bumps the build number, archives, and uploads GradusiOS straight to App
# Store Connect for TestFlight (T6.1 continuation). Requires
# APP_STORE_CONNECT_API_KEY (.p8 contents), APP_STORE_CONNECT_KEY_ID,
# APP_STORE_CONNECT_ISSUER_ID in the environment (inject via bws-run) --
# same key already used by testflight-setup.py / create-ios-distribution-profile.py.
#
# Packages and uploads manually (codesign + ditto + altool) instead of
# `xcodebuild -exportArchive`. That command fails with a generic
# `error: exportArchive Copy failed` on this project even with manual
# signing and a confirmed-good local private key -- reproduced with
# -destination local-only (no App Store Connect interaction at all), so
# it's a packaging-step bug unrelated to signing/upload auth, and Xcode's
# own logs (IDEDistribution.verbose.log) give no further detail. Manually
# resigning the archived .app with the same identity/profile succeeds
# every time and the resulting .ipa validates cleanly against ASC's real
# servers via `altool --validate-app`, so that's the reliable path.
#
# Run via:
#   bws-run -- app/archive-upload-ios.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

: "${APP_STORE_CONNECT_API_KEY:?required}"
: "${APP_STORE_CONNECT_KEY_ID:?required}"
: "${APP_STORE_CONNECT_ISSUER_ID:?required}"

SIGNING_IDENTITY="Apple Distribution"
PROFILE_PATH="${HOME}/Library/MobileDevice/Provisioning Profiles/gradus-ios-app-store.provisionprofile"
ARCHIVE_PATH="build/GradusiOS.xcarchive"
PACKAGE_DIR="build/package-ios"

echo "==> Determining next build number from App Store Connect"
NEXT_BUILD="$(uv run --with pyjwt --with cryptography next-ios-build-number.py)"
echo "    Next CURRENT_PROJECT_VERSION: $NEXT_BUILD"
sed -i '' -E "s/(CURRENT_PROJECT_VERSION: )\"[0-9]+\"/\1\"${NEXT_BUILD}\"/" project.yml

echo "==> Regenerating Xcode project from project.yml"
xcodegen generate

rm -rf "$ARCHIVE_PATH" "$PACKAGE_DIR"

echo "==> Archiving GradusiOS (build $NEXT_BUILD)"
xcodebuild archive \
  -project Gradus.xcodeproj \
  -scheme GradusiOS \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=iOS"

echo "==> Repackaging for App Store distribution (manual codesign)"
mkdir -p "$PACKAGE_DIR/Payload"
cp -R "$ARCHIVE_PATH/Products/Applications/GradusiOS.app" "$PACKAGE_DIR/Payload/GradusiOS.app"
cp "$PROFILE_PATH" "$PACKAGE_DIR/Payload/GradusiOS.app/embedded.mobileprovision"

# Entitlements to sign with come from the app's OWN archived entitlements,
# not the provisioning profile's `Entitlements` dict -- that dict is the
# profile's maximal *permitted* grant (often wildcards like icloud-services
# "*" or ubiquity-kvstore-identifier "TeamID.*"), and ASC's upload validator
# rejects those literal wildcard values if actually present in a shipped
# binary's signature (confirmed: errors 90211/90045/90046 on exactly those
# keys). Only two things need to change for a distribution build: drop
# get-task-allow (debug-only) and grant aps-environment=production (the
# archive's dev-signed entitlements have neither aps-environment nor
# get-task-allow=false, since the wildcard dev profile doesn't declare push).
codesign -d --entitlements :- "$PACKAGE_DIR/Payload/GradusiOS.app" 2>/dev/null \
  | plutil -convert xml1 -o "$PACKAGE_DIR/entitlements.plist" -
/usr/libexec/PlistBuddy -c "Set :get-task-allow false" "$PACKAGE_DIR/entitlements.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :get-task-allow bool false" "$PACKAGE_DIR/entitlements.plist"
/usr/libexec/PlistBuddy -c "Add :aps-environment string production" "$PACKAGE_DIR/entitlements.plist" 2>/dev/null || true
# Without an explicit value here, `--generate-entitlement-der` tries to derive
# this key from the embedded profile's own (multi-valued: Production AND
# Development) icloud-container-environment grant, can't resolve a single
# value, and silently emits an empty string -- which ASC's upload validator
# rejects outright ("this value should be a string value of 'Production'").
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.icloud-container-environment string Production" "$PACKAGE_DIR/entitlements.plist" 2>/dev/null || true

codesign --force --sign "$SIGNING_IDENTITY" \
  --entitlements "$PACKAGE_DIR/entitlements.plist" --generate-entitlement-der --timestamp \
  "$PACKAGE_DIR/Payload/GradusiOS.app"

# Every file in the bundle -- including ones codesign itself just wrote/
# touched -- carries a com.apple.provenance extended attribute (macOS
# re-tags files as a side effect of codesign running, so stripping before
# signing doesn't help; it has to happen after). A strict codesign verify
# rejects it ("resource fork, Finder information, or similar detritus not
# allowed"); stripping post-signature doesn't invalidate the signature
# (confirmed: verify passes clean afterward with no re-sign needed).
xattr -cr "$PACKAGE_DIR/Payload/GradusiOS.app"

echo "==> Verifying signature"
codesign --verify --deep --strict "$PACKAGE_DIR/Payload/GradusiOS.app"

IPA_PATH="$PACKAGE_DIR/GradusiOS.ipa"
echo "==> Building .ipa"
( cd "$PACKAGE_DIR" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent Payload "$(basename "$IPA_PATH")" )

# altool's --api-key auth looks for AuthKey_<key-id>.p8 in a fixed set of
# directories (or $API_PRIVATE_KEYS_DIR); write it to a private temp file
# for this process only and shred it on exit (success or failure) so the
# plaintext key never lingers on disk or appears in any log.
KEY_DIR="$(mktemp -d)"
trap 'rm -rf "$KEY_DIR"' EXIT
umask 077
printf '%s' "$APP_STORE_CONNECT_API_KEY" > "${KEY_DIR}/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
export API_PRIVATE_KEYS_DIR="$KEY_DIR"

echo "==> Uploading to App Store Connect"
xcrun altool --upload-package "$IPA_PATH" \
  -t ios \
  --api-key "$APP_STORE_CONNECT_KEY_ID" \
  --api-issuer "$APP_STORE_CONNECT_ISSUER_ID"

echo "==> Done. Build $NEXT_BUILD uploaded -- Apple will take a few minutes to process it."
echo "    Run: bws-run -- uv run --with pyjwt --with cryptography testflight-setup.py $NEXT_BUILD"
