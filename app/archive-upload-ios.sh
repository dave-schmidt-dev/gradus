#!/usr/bin/env bash
# Bumps the build number, archives, and uploads GradusiOS straight to App
# Store Connect for TestFlight (T6.1 continuation). Requires
# APP_STORE_CONNECT_API_KEY (.p8 contents), APP_STORE_CONNECT_KEY_ID,
# APP_STORE_CONNECT_ISSUER_ID in the environment. The legacy bws-run path
# below is human-terminal-only; agents must use a reviewed fixed BWS consumer.
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
# Agent-safe upload path:
#   bws-secret-exec app-store-connect-upload --
# Human-terminal compatibility path:
#   bws-run -- app/archive-upload-ios.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUDKIT_ENVIRONMENT_KEY="com.apple.developer.icloud-container-environment"
PRODUCER_EVIDENCE_FILENAME="publish-evidence.json"
# The snapshot refresher runs every 120 seconds. Five missed refresh intervals
# are enough to reject a quiet producer without making the upload race a normal
# refresh delay.
PRODUCER_EVIDENCE_MAX_AGE_SECONDS=600

read_cloudkit_environment() {
  local entitlements_path="$1"
  [[ -f "$entitlements_path" ]] || {
    echo "FAIL: entitlements file not found: $entitlements_path" >&2
    return 1
  }
  local environment
  environment="$(/usr/libexec/PlistBuddy -c "Print :$CLOUDKIT_ENVIRONMENT_KEY" "$entitlements_path" 2>/dev/null || true)"
  if [[ -n "$environment" ]]; then
    printf '%s\n' "$environment"
  else
    # The Debug entitlement omits the optional key and therefore uses the
    # Development CloudKit environment.
    printf '%s\n' "Development"
  fi
}

read_mac_build_number() {
  local project_path="$1"
  awk '
    /^  GradusMac:/ { in_mac=1; next }
    in_mac && /^  [A-Za-z0-9_]+:/ { exit }
    in_mac && /CURRENT_PROJECT_VERSION:/ { gsub(/"/, "", $2); print $2; exit }
  ' "$project_path"
}

read_evidence_field() {
  local field="$1"
  local evidence_path="$2"
  /usr/bin/plutil -extract "$field" raw -o - "$evidence_path"
}

validate_producer_evidence() {
  local evidence_path="$1"
  local expected_build="$2"
  local expected_environment="$3"
  local evidence_build evidence_environment published_at normalized_timestamp published_epoch age

  if [[ ! -f "$evidence_path" ]]; then
    echo "FAIL: producer evidence is missing" >&2
    return 1
  fi
  evidence_build="$(read_evidence_field producerBuildNumber "$evidence_path" 2>/dev/null || true)"
  evidence_environment="$(read_evidence_field cloudKitEnvironment "$evidence_path" 2>/dev/null || true)"
  published_at="$(read_evidence_field publishedAt "$evidence_path" 2>/dev/null || true)"
  if [[ -z "$evidence_build" || -z "$evidence_environment" || -z "$published_at" ]]; then
    echo "FAIL: producer evidence is incomplete" >&2
    return 1
  fi
  if [[ "$evidence_environment" != "$expected_environment" ]]; then
    echo "FAIL: producer evidence targets the wrong CloudKit environment" >&2
    return 1
  fi
  if [[ "$evidence_build" != "$expected_build" ]]; then
    echo "FAIL: producer evidence has the wrong GradusMac build" >&2
    return 1
  fi
  if [[ "$published_at" != *Z ]]; then
    echo "FAIL: producer evidence timestamp is not UTC" >&2
    return 1
  fi
  normalized_timestamp="${published_at%Z}"
  normalized_timestamp="${normalized_timestamp%%.*}Z"
  published_epoch="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$normalized_timestamp" +%s 2>/dev/null || true)"
  if [[ -z "$published_epoch" ]]; then
    echo "FAIL: producer evidence timestamp is invalid" >&2
    return 1
  fi
  age=$(( $(date -u +%s) - published_epoch ))
  if (( age < 0 || age > PRODUCER_EVIDENCE_MAX_AGE_SECONDS )); then
    echo "FAIL: producer evidence is older than ${PRODUCER_EVIDENCE_MAX_AGE_SECONDS}s" >&2
    return 1
  fi
}

resolve_user_home() {
  if [[ -n "${HOME:-}" ]]; then
    printf '%s\n' "$HOME"
    return 0
  fi

  local username discovered_home
  username="$(/usr/bin/id -un)"
  discovered_home="$(
    /usr/bin/dscl . -read "/Users/${username}" NFSHomeDirectory 2>/dev/null \
      | /usr/bin/awk '/^NFSHomeDirectory:/ {print $2; exit}' \
      || true
  )"
  if [[ -z "$discovered_home" ]]; then
    discovered_home="$(/usr/bin/id -P | /usr/bin/awk -F: 'NF >= 9 {print $9; exit}')"
  fi
  if [[ -z "$discovered_home" ]]; then
    echo "FAIL: HOME is unset and the macOS home directory could not be determined" >&2
    return 1
  fi
  printf '%s\n' "$discovered_home"
}

resolve_uv() {
  local candidate
  candidate="$(command -v uv 2>/dev/null || true)"
  if [[ -z "$candidate" ]]; then
    for candidate in "$HOME/.local/bin/uv" "/opt/homebrew/bin/uv"; do
      if [[ -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  else
    printf '%s\n' "$candidate"
    return 0
  fi
  echo "FAIL: uv is not installed in PATH, HOME/.local/bin, or /opt/homebrew/bin" >&2
  return 1
}

resolve_user_name() {
  /usr/bin/id -un
}

bump_ios_build_number() {
  local next_build="$1"
  local ios_build_pattern
  ios_build_pattern="/^  GradusiOS:/,/^  [A-Za-z0-9_]+:/ s/(CURRENT_PROJECT_VERSION: )\"[0-9]+\"/\\1\"$next_build\"/"
  sed -i '' -E "$ios_build_pattern" project.yml
}

main() {
  cd "$SCRIPT_DIR"
  local project_root evidence_path expected_mac_build expected_cloudkit_environment
  project_root="$(cd .. && pwd)"
  evidence_path="${GRADUS_PRODUCER_EVIDENCE_PATH:-$project_root/.state/$PRODUCER_EVIDENCE_FILENAME}"
  expected_mac_build="$(read_mac_build_number project.yml)"
  expected_cloudkit_environment="$(read_cloudkit_environment "$SCRIPT_DIR/GradusMac/GradusMacProduction.entitlements")"
  validate_producer_evidence "$evidence_path" "$expected_mac_build" "$expected_cloudkit_environment"

  # bws-run and bws-secret-exec intentionally start children with a minimal
  # environment. Restore HOME from the local account record before uv,
  # xcodebuild, and the provisioning-profile lookup need it.
  export HOME="$(resolve_user_home)"
  export USER="$(resolve_user_name)"
  export LOGNAME="$USER"
  local uv_bin
  uv_bin="$(resolve_uv)"

  : "${APP_STORE_CONNECT_API_KEY:?required}"
  : "${APP_STORE_CONNECT_KEY_ID:?required}"
  : "${APP_STORE_CONNECT_ISSUER_ID:?required}"

  SIGNING_IDENTITY="Apple Distribution"
  PROFILE_PATH="${HOME}/Library/MobileDevice/Provisioning Profiles/gradus-ios-app-store.provisionprofile"
  ARCHIVE_PATH="build/GradusiOS.xcarchive"
  PACKAGE_DIR="build/package-ios"

  echo "==> Determining next build number from App Store Connect"
  NEXT_BUILD="$("$uv_bin" run --with pyjwt --with cryptography next-ios-build-number.py)"
  echo "    Next CURRENT_PROJECT_VERSION: $NEXT_BUILD"
  bump_ios_build_number "$NEXT_BUILD"

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

# Xcode/archive tooling can attach Finder/provenance metadata to the copied
# bundle.  codesign rejects that metadata before it can replace the archive's
# development signature, so clear it before extracting entitlements and
# signing.  codesign can add provenance metadata again; the second cleanup
# below remains necessary before packaging the IPA.
  xattr -cr "$PACKAGE_DIR/Payload/GradusiOS.app"

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
  /usr/libexec/PlistBuddy -c "Add :$CLOUDKIT_ENVIRONMENT_KEY string $expected_cloudkit_environment" "$PACKAGE_DIR/entitlements.plist" 2>/dev/null || true

  codesign --force --sign "$SIGNING_IDENTITY" \
    --entitlements "$PACKAGE_DIR/entitlements.plist" --generate-entitlement-der --timestamp \
    "$PACKAGE_DIR/Payload/GradusiOS.app"

# Every file in the bundle -- including ones codesign itself just wrote/
# touched -- can carry a com.apple.provenance extended attribute (macOS
# re-tags files as a side effect of codesign running). A strict codesign
# verify rejects it ("resource fork, Finder information, or similar detritus
# not allowed"); stripping post-signature doesn't invalidate the signature
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
  echo "    To wait for processing and assign it to Internal Testers:"
  echo "    bws-secret-exec app-store-connect-testflight-setup -- $NEXT_BUILD"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
