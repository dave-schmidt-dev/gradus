#!/usr/bin/env bash
# Read-only structural and signature audit of an exported Gradus Mac bundle.
#
# This is the check that has to survive leaving the building: it runs against a
# bundle alone, using only bash and tools shipped with macOS. No repository
# checkout, no `uv`, no project virtualenv, no host Python. If it needed any of
# those, "the artifact is intact" would be a claim only this machine could make.
#
# It never writes to the bundle. `xattr -c` is deliberately NOT run here even
# though a stray provenance xattr fails the strict verify below -- clearing it
# would repair the artifact under audit and report a state that was not shipped.
# Stripping belongs to the signing pass; noticing belongs here.
#
# What is checked, and why each one is worth a separate message:
#   * naming        -- the shipped wrapper is `Gradus.app` and its customer name
#                      is `Gradus`; platform suffixes are engineering-only.
#   * layout        -- every helper the refresh agent execs is actually present.
#   * LaunchAgent   -- its program path is bundle-relative, so the job keeps
#                      working from `/Applications` or `~/Applications` alike.
#   * signatures    -- every Mach-O, not just the outer seal: signed, this
#                      team, this identity, hardened runtime, and (for release
#                      artifacts) a secure timestamp.
#   * entitlements  -- an explicit allowlist. A helper that quietly gained the
#                      wrapper's CloudKit grant is a privilege change, and the
#                      only way to see it is to enumerate and compare.
#   * architecture  -- the frozen runtime must stay universal2; the wrapper must
#                      carry at least the required slices.
#   * file modes    -- nothing group- or world-writable, and no executable file
#                      outside the frozen runtime's code directories.
#   * provenance    -- no quarantine or provenance xattr anywhere.
#
# Usage:
#   ./verify-mac-bundle.sh <app-bundle> [--manifest <path>]
#
# Environment (every expectation is injectable so hermetic fixtures can drive
# this script without a real Developer ID identity):
#   EXPECTED_APP_NAME          default Gradus.app
#   EXPECTED_BUNDLE_NAME       default Gradus
#   EXPECTED_BUNDLE_ID         default com.zerodelta.gradus.mac
#   EXPECTED_TEAM_ID           default 4CJ49V6QHW
#   EXPECTED_IDENTITY          default "Developer ID Application"
#   REQUIRED_ARCHS             default "arm64 x86_64"
#   UNIVERSAL_SUBPATH          default Contents/Helpers/GradusRuntime.app
#   REQUIRE_TIMESTAMP          default 1
#   REQUIRE_GATEKEEPER         default 0 (an un-notarized bundle is rejected by
#                              spctl by design; notarize-mac.sh runs that check
#                              after stapling, where it means something)
#   SOURCE_REVISION            recorded in the manifest when set
set -euo pipefail

umask 077

CODESIGN="${CODESIGN:-/usr/bin/codesign}"
FILE_TOOL="${FILE_TOOL:-/usr/bin/file}"
LIPO="${LIPO:-/usr/bin/lipo}"
PLUTIL="${PLUTIL:-/usr/bin/plutil}"
PLIST_BUDDY="${PLIST_BUDDY:-/usr/libexec/PlistBuddy}"
SHASUM="${SHASUM:-/usr/bin/shasum}"
SPCTL="${SPCTL:-/usr/sbin/spctl}"
XATTR_TOOL="${XATTR_TOOL:-/usr/bin/xattr}"

EXPECTED_APP_NAME="${EXPECTED_APP_NAME:-Gradus.app}"
EXPECTED_BUNDLE_NAME="${EXPECTED_BUNDLE_NAME:-Gradus}"
EXPECTED_BUNDLE_ID="${EXPECTED_BUNDLE_ID:-com.zerodelta.gradus.mac}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-4CJ49V6QHW}"
EXPECTED_IDENTITY="${EXPECTED_IDENTITY:-Developer ID Application}"
REQUIRED_ARCHS="${REQUIRED_ARCHS:-arm64 x86_64}"
UNIVERSAL_SUBPATH="${UNIVERSAL_SUBPATH:-Contents/Helpers/GradusRuntime.app}"
REQUIRE_TIMESTAMP="${REQUIRE_TIMESTAMP:-1}"
REQUIRE_GATEKEEPER="${REQUIRE_GATEKEEPER:-0}"
SOURCE_REVISION="${SOURCE_REVISION:-}"

# The wrapper's own grants, plus the two entitlements Xcode injects from the
# provisioning profile at signing time. Anything else on any code item is a
# privilege the release did not ask for.
WRAPPER_ENTITLEMENTS=(
  "com.apple.application-identifier"
  "com.apple.developer.aps-environment"
  "com.apple.developer.icloud-container-environment"
  "com.apple.developer.icloud-container-identifiers"
  "com.apple.developer.icloud-services"
  "com.apple.developer.team-identifier"
)
# Helpers get no *privileges*. The credential bridge talks to the user's
# browsers, the refresh agent execs two local programs, and the frozen runtime
# makes HTTPS requests -- no CloudKit, no push, no shared container between
# them. The two keys below are not privileges: Xcode injects them from the
# signing identity and profile, and a real Xcode-signed helper carries them
# whether or not it has an entitlements file. Rejecting those would make the
# check fire on every correct build, which is how a check gets switched off.
HELPER_ENTITLEMENTS=(
  "com.apple.application-identifier"
  "com.apple.developer.team-identifier"
)

REQUIRED_HELPERS=(
  "Contents/Helpers/GradusCredentialBridge.app"
  "Contents/Helpers/GradusRefreshAgent"
  "Contents/Helpers/GradusRuntime.app"
)
LAUNCH_AGENT_RELATIVE="Contents/Library/LaunchAgents/com.zerodelta.gradus.refresh-agent.plist"

APP=""
MANIFEST_PATH=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --manifest)
      MANIFEST_PATH="${2:-}"
      shift 2
      ;;
    --help)
      echo "Usage: verify-mac-bundle.sh <app-bundle> [--manifest <path>]"
      exit 0
      ;;
    -*)
      echo "FAIL: unknown verify-mac-bundle option '$1'" >&2
      exit 2
      ;;
    *)
      if [[ -n "$APP" ]]; then
        echo "FAIL: verify-mac-bundle takes exactly one bundle path" >&2
        exit 2
      fi
      APP="$1"
      shift
      ;;
  esac
done

if [[ -z "$APP" ]]; then
  echo "FAIL: no bundle path given" >&2
  exit 2
fi
if [[ ! -d "$APP" ]]; then
  echo "FAIL: no bundle at $APP" >&2
  exit 66
fi

APP="${APP%/}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gradus-verify-bundle.XXXXXX")"
cleanup() {
  rm -rf "$WORK_DIR" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

failures=0
checks=0

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

ok() {
  checks=$((checks + 1))
  echo "    $1 OK."
}

relative_to_app() {
  local path="$1"
  printf '%s\n' "${path#"$APP"/}"
}

# --- naming ------------------------------------------------------------------

echo "==> Checking shipped names"
if [[ "$(basename "$APP")" != "$EXPECTED_APP_NAME" ]]; then
  fail "shipped wrapper must be named $EXPECTED_APP_NAME, found $(basename "$APP")"
else
  ok "wrapper bundle name"
fi

INFO_PLIST="$APP/Contents/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  fail "wrapper has no Contents/Info.plist"
  echo "==> $failures failure(s); the bundle is not structurally an app." >&2
  exit 65
fi
"$PLUTIL" -lint "$INFO_PLIST" >/dev/null || fail "wrapper Info.plist is malformed"

plist_value() {
  "$PLIST_BUDDY" -c "Print :$2" "$1" 2>/dev/null || printf ''
}

BUNDLE_NAME="$(plist_value "$INFO_PLIST" CFBundleName)"
BUNDLE_ID="$(plist_value "$INFO_PLIST" CFBundleIdentifier)"
BUNDLE_EXECUTABLE="$(plist_value "$INFO_PLIST" CFBundleExecutable)"
SHORT_VERSION="$(plist_value "$INFO_PLIST" CFBundleShortVersionString)"
BUILD_VERSION="$(plist_value "$INFO_PLIST" CFBundleVersion)"

if [[ "$BUNDLE_NAME" != "$EXPECTED_BUNDLE_NAME" ]]; then
  fail "customer-facing CFBundleName must be $EXPECTED_BUNDLE_NAME, found '$BUNDLE_NAME'"
else
  ok "customer-facing bundle name"
fi
# `Mac`, `iOS`, `macOS` and friends are internal engineering identifiers: the
# target, scheme, module and source directory keep them, the shipped product
# does not. A user sees one product called Gradus on both platforms.
if [[ "$BUNDLE_NAME" =~ (Mac|macOS|iOS|OSX) || "$BUNDLE_EXECUTABLE" =~ (Mac|macOS|iOS|OSX) ]]; then
  fail "platform suffix in a customer-facing name: CFBundleName='$BUNDLE_NAME' CFBundleExecutable='$BUNDLE_EXECUTABLE'"
else
  ok "no platform suffix in customer-facing names"
fi
if [[ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
  fail "bundle identifier must be $EXPECTED_BUNDLE_ID, found '$BUNDLE_ID'"
else
  ok "bundle identifier"
fi
if [[ -z "$BUNDLE_EXECUTABLE" || ! -f "$APP/Contents/MacOS/$BUNDLE_EXECUTABLE" ]]; then
  fail "main executable Contents/MacOS/$BUNDLE_EXECUTABLE is missing"
else
  ok "main executable present"
fi

# --- layout ------------------------------------------------------------------

echo "==> Checking embedded helpers"
missing_helpers=0
for helper in "${REQUIRED_HELPERS[@]}"; do
  if [[ ! -e "$APP/$helper" ]]; then
    fail "required helper is missing: $helper"
    missing_helpers=$((missing_helpers + 1))
  fi
done
if ((missing_helpers == 0)); then
  ok "embedded helper inventory"
fi

# --- LaunchAgent -------------------------------------------------------------

echo "==> Checking LaunchAgent program path"
LAUNCH_AGENT="$APP/$LAUNCH_AGENT_RELATIVE"
if [[ ! -f "$LAUNCH_AGENT" ]]; then
  fail "LaunchAgent plist is missing: $LAUNCH_AGENT_RELATIVE"
else
  "$PLUTIL" -lint "$LAUNCH_AGENT" >/dev/null || fail "LaunchAgent plist is malformed"
  bundle_program="$(plist_value "$LAUNCH_AGENT" BundleProgram)"
  absolute_program="$(plist_value "$LAUNCH_AGENT" Program)"
  if [[ -n "$absolute_program" ]]; then
    fail "LaunchAgent Program must not be set; BundleProgram keeps the path bundle-relative (found '$absolute_program')"
  fi
  if [[ -z "$bundle_program" ]]; then
    fail "LaunchAgent has no BundleProgram"
  elif [[ "$bundle_program" == /* ]]; then
    fail "LaunchAgent BundleProgram must be bundle-relative: '$bundle_program'"
  elif [[ ! -f "$APP/$bundle_program" ]]; then
    fail "LaunchAgent BundleProgram does not resolve inside the bundle: '$bundle_program'"
  else
    ok "LaunchAgent program path is bundle-relative"
  fi
  # A first argument that is an absolute path is the same defect wearing a
  # different key: launchd would exec that, not the bundled helper.
  first_argument="$(plist_value "$LAUNCH_AGENT" "ProgramArguments:0")"
  if [[ "$first_argument" == /* ]]; then
    fail "LaunchAgent ProgramArguments:0 must be bundle-relative: '$first_argument'"
  fi
fi

# --- Mach-O inventory --------------------------------------------------------

# One batched `file` call: the frozen runtime carries the whole Python standard
# library, and a fork per file turns this into a visible stall.
list_macho_files() {
  local root="$1" candidates
  candidates="$(find "$root" -type f ! -type l \
    \( -perm +111 -o -name '*.so' -o -name '*.dylib' -o -name '*.bundle' \) -print)"
  [[ -n "$candidates" ]] || return 0
  if printf '%s\n' "$candidates" | grep -q ':'; then
    echo "FAIL: a bundle path contains a colon, which the Mach-O inventory cannot parse" >&2
    return 1
  fi
  printf '%s\n' "$candidates" | tr '\n' '\0' | xargs -0 "$FILE_TOOL" -- |
    awk -F': ' '$2 ~ /Mach-O/ { print $1 }' | LC_ALL=C sort
}

MACHO_LIST="$WORK_DIR/machos"
list_macho_files "$APP" >"$MACHO_LIST"
if [[ ! -s "$MACHO_LIST" ]]; then
  fail "bundle contains no Mach-O binaries"
fi

entitlement_keys() {
  local target="$1"
  "$CODESIGN" -d --entitlements - --xml "$target" 2>/dev/null >"$WORK_DIR/entitlements.plist" || return 0
  [[ -s "$WORK_DIR/entitlements.plist" ]] || return 0
  "$PLUTIL" -convert xml1 -o - "$WORK_DIR/entitlements.plist" 2>/dev/null |
    awk -F'[<>]' '/^\t<key>/ { print $3 }'
}

# The wrapper is the only code item allowed to carry entitlements. Everything
# under Contents/Helpers is compared against the empty allowlist, so a helper
# that picks one up -- from a `--deep` sign, say -- is named rather than
# averaged away.
allowed_entitlements_for() {
  local relative="$1"
  if [[ "$relative" == Contents/Helpers/* ]]; then
    printf '%s\n' "${HELPER_ENTITLEMENTS[@]+"${HELPER_ENTITLEMENTS[@]}"}"
  else
    printf '%s\n' "${WRAPPER_ENTITLEMENTS[@]}"
  fi
}

MANIFEST_CODE="$WORK_DIR/code.jsonl"
: >"$MANIFEST_CODE"

echo "==> Checking every Mach-O signature, identity, and architecture"
macho_count=0
while IFS= read -r macho; do
  [[ -n "$macho" ]] || continue
  relative="$(relative_to_app "$macho")"
  macho_count=$((macho_count + 1))

  if ! "$CODESIGN" -dvvv "$macho" >"$WORK_DIR/codesign.out" 2>&1; then
    fail "unsigned nested code: $relative"
    continue
  fi
  signature_line="$(awk -F= '/^Signature=/ { print $2; exit }' "$WORK_DIR/codesign.out")"
  if [[ "$signature_line" == "adhoc" ]]; then
    fail "ad-hoc signature on $relative; a distributable bundle must be Developer ID signed"
    continue
  fi

  team="$(awk -F= '/^TeamIdentifier=/ { print $2; exit }' "$WORK_DIR/codesign.out")"
  if [[ "$team" != "$EXPECTED_TEAM_ID" ]]; then
    fail "wrong Team ID on $relative: expected $EXPECTED_TEAM_ID, found '${team:-none}'"
  fi

  identity="$(awk -F= '/^Authority=/ { print $2; exit }' "$WORK_DIR/codesign.out")"
  if [[ "$identity" != "$EXPECTED_IDENTITY"* ]]; then
    fail "signing identity on $relative must begin with '$EXPECTED_IDENTITY', found '${identity:-none}'"
  fi

  if ! grep -q 'flags=.*runtime' "$WORK_DIR/codesign.out"; then
    fail "hardened runtime is not enabled on $relative"
  fi

  timestamp="$(awk -F= '/^Timestamp=/ { print $2; exit }' "$WORK_DIR/codesign.out")"
  if [[ "$REQUIRE_TIMESTAMP" == "1" && -z "$timestamp" ]]; then
    fail "no secure timestamp on $relative; Apple will reject the submission"
  fi

  architectures="$("$LIPO" -archs "$macho" 2>/dev/null || printf '')"
  required="$REQUIRED_ARCHS"
  if [[ "$relative" == "$UNIVERSAL_SUBPATH"/* || "$relative" == "$UNIVERSAL_SUBPATH" ]]; then
    # The frozen runtime is built universal2 on purpose (see
    # build-gradus-runtime.sh); losing a slice there silently drops Intel
    # support for the only component that cannot be rebuilt on the user's Mac.
    required="arm64 x86_64"
  fi
  for arch in $required; do
    if [[ " $architectures " != *" $arch "* ]]; then
      fail "missing architecture on $relative: expected '$required', found '${architectures:-none}'"
      break
    fi
  done

  entitlements="$(entitlement_keys "$macho" | LC_ALL=C sort)"
  allowed="$(allowed_entitlements_for "$relative" | LC_ALL=C sort)"
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    if ! printf '%s\n' "$allowed" | grep -Fxq -- "$key"; then
      fail "unexpected entitlement on $relative: $key"
    fi
  done <<< "$entitlements"

  digest="$("$SHASUM" -a 256 "$macho" | awk '{print $1}')"
  hardened=false
  grep -q 'flags=.*runtime' "$WORK_DIR/codesign.out" && hardened=true
  # One row per code item, tab separated, entitlement keys space separated in
  # the last field. Keeping them in the same row as the item they belong to is
  # the whole point: a side table keyed by loop index drifts the moment a check
  # short-circuits and skips a row.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$relative" "$architectures" "$team" "$identity" "$hardened" "$digest" \
    "$(printf '%s\n' "$entitlements" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')" \
    >>"$MANIFEST_CODE"
done <"$MACHO_LIST"
ok "$macho_count Mach-O code items inspected"

# --- file modes --------------------------------------------------------------

echo "==> Checking file modes and runtime drift"
writable="$(find "$APP" -type f ! -type l -perm +022 -print | head -5)"
if [[ -n "$writable" ]]; then
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    fail "group- or world-writable file: $(relative_to_app "$path")"
  done <<< "$writable"
else
  ok "no group- or world-writable files"
fi

# Mirrors the placement rule build-gradus-runtime.sh enforces at build time. It
# is re-checked here because the bundle passes through an Xcode copy phase, an
# export, and a signing pass between then and now.
runtime_root="$APP/$UNIVERSAL_SUBPATH"
if [[ -d "$runtime_root" ]]; then
  drift=0
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    inner="${path#"$runtime_root"/}"
    if [[ "$inner" != "Contents/MacOS/"* && "$inner" != "Contents/Frameworks/"* ]]; then
      fail "executable file has nonstandard placement in the frozen runtime: $inner"
      drift=1
    fi
  done < <(find "$runtime_root" -type f ! -type l -perm +111 -print)
  if ((drift == 0)); then
    ok "frozen runtime executables stay in its code directories"
  fi
fi

# --- extended attributes -----------------------------------------------------

# Deliberately NOT checking com.apple.provenance. It is a restricted xattr that
# `xattr -c` cannot remove -- macOS stamps it on every locally built file and
# re-stamps it after a strip -- and, measured on this OS, it does not break a
# strict verify: an ad-hoc signed bundle carrying provenance on every node
# returns "valid on disk / satisfies its Designated Requirement". Checking it
# would fail every honest build for something nobody can fix. The attributes
# below are the ones that actually reject: a real export failed strict verify
# here with "Disallowed xattr com.apple.FinderInfo", not provenance.
echo "==> Checking quarantine and resource-fork metadata"
tagged="$("$XATTR_TOOL" -r -l "$APP" 2>/dev/null |
  grep -E 'com\.apple\.(quarantine|FinderInfo|ResourceFork)' | head -3 || true)"
if [[ -n "$tagged" ]]; then
  fail "quarantine or resource-fork metadata is present; strip it before verifying or shipping"
else
  ok "no quarantine or resource-fork metadata"
fi

# --- strict verification -----------------------------------------------------

echo "==> Verifying the seal"
# `--deep` here is verification-only defense in depth: it walks nested code that
# the explicit inventory above could in principle miss. It is never the signing
# algorithm -- see sign-mac-bundle.sh for why.
if ! "$CODESIGN" --verify --deep --strict --verbose=2 "$APP" >"$WORK_DIR/verify.out" 2>&1; then
  fail "strict signature verification failed: $(tail -3 "$WORK_DIR/verify.out" | tr '\n' ' ')"
else
  ok "strict deep signature verification"
fi

if [[ "$REQUIRE_GATEKEEPER" == "1" ]]; then
  if ! "$SPCTL" -a -vv -t install "$APP" >"$WORK_DIR/spctl.out" 2>&1; then
    fail "Gatekeeper rejected the bundle: $(tail -2 "$WORK_DIR/spctl.out" | tr '\n' ' ')"
  else
    ok "Gatekeeper acceptance"
  fi
fi

# --- manifest ----------------------------------------------------------------

json_string() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

json_array() {
  local first=1 item
  printf '['
  for item in "$@"; do
    ((first)) || printf ', '
    first=0
    json_string "$item"
  done
  printf ']'
}

# Reproduces build-gradus-runtime.sh's `sha256-tree-v1`: kind, relative path,
# permission bits and content digest per entry, in byte order, so the two
# manifests describe an artifact the same way and can be compared directly.
tree_digest() {
  local root="$1" entries="$WORK_DIR/tree-entries" list="$WORK_DIR/tree-list"
  : >"$entries"
  find "$root" \( -type f -o -type l \) -print | LC_ALL=C sort >"$list"
  local path relative mode content
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    relative="${path#"$root"/}"
    if [[ -L "$path" ]]; then
      content="$(readlink "$path" | tr -d '\n' | "$SHASUM" -a 256 | awk '{print $1}')"
      printf 'symlink\0%s\0%o\0%s\n' "$relative" 0 "$content" >>"$entries"
    else
      mode="$(stat -f '%Lp' "$path")"
      content="$("$SHASUM" -a 256 "$path" | awk '{print $1}')"
      printf 'file\0%s\0%o\0%s\n' "$relative" "0$mode" "$content" >>"$entries"
    fi
  done <"$list"
  printf '%s %s\n' "$("$SHASUM" -a 256 "$entries" | awk '{print $1}')" "$(wc -l <"$list" | tr -d ' ')"
}

if [[ -n "$MANIFEST_PATH" ]]; then
  echo "==> Writing bundle manifest"
  read -r digest_value file_count <<< "$(tree_digest "$APP")"
  {
    printf '{\n'
    printf '  "bundle": {\n'
    printf '    "build_version": %s,\n' "$(json_string "$BUILD_VERSION")"
    printf '    "identifier": %s,\n' "$(json_string "$BUNDLE_ID")"
    printf '    "name": %s,\n' "$(json_string "$BUNDLE_NAME")"
    printf '    "short_version": %s,\n' "$(json_string "$SHORT_VERSION")"
    printf '    "wrapper": %s\n' "$(json_string "$(basename "$APP")")"
    printf '  },\n'
    printf '  "code": [\n'
    first=1
    while IFS=$'\t' read -r relative architectures team identity hardened digest entitlements; do
      [[ -n "$relative" ]] || continue
      ((first)) || printf ',\n'
      first=0
      printf '    {\n'
      # Both fields are deliberately unquoted: they are space-separated lists
      # that json_array turns into JSON arrays, and quoting would emit one
      # element containing spaces.
      # shellcheck disable=SC2086
      printf '      "architectures": %s,\n' "$(json_array $architectures)"
      # shellcheck disable=SC2086
      printf '      "entitlements": %s,\n' "$(json_array $entitlements)"
      printf '      "hardened_runtime": %s,\n' "$hardened"
      printf '      "path": %s,\n' "$(json_string "$relative")"
      printf '      "sha256": %s,\n' "$(json_string "$digest")"
      printf '      "signing_identity": %s,\n' "$(json_string "$identity")"
      printf '      "team_identifier": %s\n' "$(json_string "$team")"
      printf '    }'
    done <"$MANIFEST_CODE"
    printf '\n  ],\n'
    printf '  "digest": {\n'
    printf '    "algorithm": "sha256-tree-v1",\n'
    printf '    "file_count": %s,\n' "$file_count"
    printf '    "value": %s\n' "$(json_string "$digest_value")"
    printf '  },\n'
    printf '  "schema_version": 1,\n'
    printf '  "source_revision": %s\n' "$(json_string "$SOURCE_REVISION")"
    printf '}\n'
  } >"$MANIFEST_PATH"
  chmod 600 "$MANIFEST_PATH"
  # `plutil -lint` only understands property lists ("Unexpected character {").
  # `-convert` is the JSON-capable parse, and /dev/null keeps this read-only.
  "$PLUTIL" -convert xml1 -o /dev/null "$MANIFEST_PATH" ||
    fail "generated manifest is not valid JSON"
  ok "manifest written to $MANIFEST_PATH"
fi

if ((failures > 0)); then
  echo "==> $failures check(s) failed." >&2
  exit 65
fi
echo "==> Bundle verified: $checks checks passed across $macho_count code items."
