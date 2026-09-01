#!/usr/bin/env bash
# Signs an exported Gradus Mac bundle from the leaves inward.
#
# ## Why this exists at all
#
# `xcodebuild -exportArchive` signs the targets Xcode knows about. It does not
# sign `Contents/Helpers/GradusRuntime.app`: that bundle is copied in by a run
# script (see the "Embed GradusRuntime.app" phase in project.yml), so Xcode
# seals it as a *resource* of the wrapper and never signs its Mach-O files.
# PyInstaller ships it ad-hoc signed -- confirmed on a real artifact:
#
#     CodeDirectory v=20400 ... flags=0x2(adhoc)
#     Signature=adhoc
#
# An ad-hoc nested binary fails `codesign --verify --strict` and is rejected by
# the notary service, so the frozen runtime must be re-signed with the same
# Developer ID identity as everything else, and each of its ~40 Mach-O files
# individually: notarization requires a signature and the hardened runtime on
# every executable page in the bundle, not just on the outermost seal.
#
# ## Why not `--deep`
#
# `codesign --deep` is documented by Apple as a fallback for emergencies, not a
# signing algorithm. It applies the outer bundle's entitlements and identifier
# rules to nested code, which is exactly wrong for a wrapper that carries
# CloudKit entitlements the helpers must not inherit. It also silently skips
# code it does not recognize as nested. This script signs each item explicitly,
# innermost first, so a signature that did not happen is an error rather than
# an omission nobody notices until Apple rejects the upload.
# `--deep` remains legitimate on the *verify* side as defense in depth.
#
# ## Ordering contract
#
# A bundle's seal covers its nested code, so the nested code must be final
# before the seal is computed. The order is therefore: deepest nested bundles
# first, then loose Mach-O files, then the wrapper last. Signing the other way
# round produces a wrapper whose CodeResources no longer match its contents,
# which verifies as "a sealed resource is missing or invalid" -- a message that
# names the resource, not the ordering mistake that caused it.
#
# Usage:
#   ./sign-mac-bundle.sh <app-bundle> --identity <identity> \
#       [--entitlements <plist>]
#
# Environment:
#   CODESIGN         codesign executable (default /usr/bin/codesign)
#   FILE_TOOL        file(1) executable (default /usr/bin/file)
#   XATTR_TOOL       xattr executable (default /usr/bin/xattr)
#   SIGN_TIMESTAMP   1 (default) to request a secure timestamp; 0 for offline
set -euo pipefail

umask 077

CODESIGN="${CODESIGN:-/usr/bin/codesign}"
FILE_TOOL="${FILE_TOOL:-/usr/bin/file}"
XATTR_TOOL="${XATTR_TOOL:-/usr/bin/xattr}"
SIGN_TIMESTAMP="${SIGN_TIMESTAMP:-1}"

APP=""
IDENTITY=""
ENTITLEMENTS=""

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --identity)
      IDENTITY="${2:-}"
      shift 2
      ;;
    --entitlements)
      ENTITLEMENTS="${2:-}"
      shift 2
      ;;
    --help)
      echo "Usage: sign-mac-bundle.sh <app-bundle> --identity <identity> [--entitlements <plist>]"
      exit 0
      ;;
    -*)
      echo "FAIL: unknown sign-mac-bundle option '$1'" >&2
      exit 2
      ;;
    *)
      if [[ -n "$APP" ]]; then
        echo "FAIL: sign-mac-bundle takes exactly one bundle path" >&2
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
if [[ -z "$IDENTITY" ]]; then
  echo "FAIL: --identity is required; refusing to ad-hoc sign a distributable bundle" >&2
  exit 2
fi
if [[ -n "$ENTITLEMENTS" && ! -f "$ENTITLEMENTS" ]]; then
  echo "FAIL: no entitlements file at $ENTITLEMENTS" >&2
  exit 66
fi

progress() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$1" >&2
}

# Every codesign invocation in this script goes through here, so the flags that
# make a bundle notarizable cannot drift apart between call sites.
#
# Each call with `--timestamp` is a round trip to Apple's timestamp authority,
# and the frozen runtime alone is forty-odd of them. Without a line per item
# this is several silent network-bound minutes, which is indistinguishable from
# a hang -- so the counter is part of the contract, not decoration.
SIGNED_COUNT=0
sign_one() {
  local target="$1"
  shift
  SIGNED_COUNT=$((SIGNED_COUNT + 1))
  progress "Signing ${SIGNED_COUNT}/${SIGN_TOTAL}: ${target#"$APP"/}"
  local args=(--force --options runtime --sign "$IDENTITY")
  if [[ "$SIGN_TIMESTAMP" == "1" ]]; then
    args+=(--timestamp)
  fi
  args+=("$@" "$target")
  if ! "$CODESIGN" "${args[@]}"; then
    echo "FAIL: could not sign $target" >&2
    return 1
  fi
}

# `file` is asked in one batch rather than once per path: the frozen runtime
# carries the whole Python standard library, so a fork per file turns a
# sub-second inventory into a visible stall.
list_macho_files() {
  local root="$1"
  local candidates
  candidates="$(find "$root" -type f \
    \( -perm +111 -o -name '*.so' -o -name '*.dylib' -o -name '*.bundle' \) \
    ! -type l -print)"
  [[ -n "$candidates" ]] || return 0
  # `file` reports `path: description`, so a colon in a path would split the
  # wrong field. No Apple bundle layout uses one; say so loudly if that changes.
  if printf '%s\n' "$candidates" | grep -q ':'; then
    echo "FAIL: a bundle path contains a colon, which the Mach-O inventory cannot parse" >&2
    return 1
  fi
  printf '%s\n' "$candidates" | tr '\n' '\0' | xargs -0 "$FILE_TOOL" -- |
    awk -F': ' '$2 ~ /Mach-O/ { print $1 }'
}

# Deepest first, so a framework inside a helper app is final before that app is
# sealed. `awk` counts separators rather than `sort -r` on the path itself:
# lexical order would put `Helpers/A.app/Contents/Frameworks/x.framework` after
# `Helpers/B.app` and seal B before its own contents were done.
list_nested_bundles() {
  local root="$1"
  find "$root" -mindepth 1 -type d \( -name '*.app' -o -name '*.framework' \) -print |
    awk '{ n = gsub("/", "/"); print n "\t" $0 }' |
    sort -rn -k1,1 |
    cut -f2-
}

# True when `path` lives inside some nested bundle other than `self`, which
# signs its own contents. Two mistakes this prevents: the wrapper pass
# re-signing helper binaries after their enclosing bundle was already sealed,
# and a helper app re-signing a framework nested inside it that was sealed
# first. Both invalidate a seal that was correct a moment earlier.
inside_other_bundle() {
  local path="$1" self="$2" bundle
  while IFS= read -r bundle; do
    [[ -n "$bundle" ]] || continue
    [[ "$bundle" == "$self" ]] && continue
    if [[ "$path" == "$bundle/"* ]]; then
      return 0
    fi
  done <<< "$NESTED_BUNDLES"
  return 1
}

# codesign re-tags files with com.apple.provenance as it runs, and a strict
# verify rejects the result ("resource fork, Finder information, or similar
# detritus not allowed"). Clear before signing; the verifier clears again
# before it checks, because this pass creates fresh ones.
"$XATTR_TOOL" -cr "$APP"

NESTED_BUNDLES="$(list_nested_bundles "$APP")"

# The whole work list is built before anything is signed. Two reasons: the
# progress counter needs a denominator, and the ordering -- the property that
# makes or breaks the result -- becomes one readable list instead of a shape
# emerging from three interleaved loops.
WORK_LIST=()
while IFS= read -r bundle; do
  [[ -n "$bundle" ]] || continue
  while IFS= read -r macho; do
    [[ -n "$macho" ]] || continue
    # The bundle's own main executable is covered when the bundle is signed.
    [[ "$(dirname "$macho")" == "$bundle/Contents/MacOS" ]] && continue
    inside_other_bundle "$macho" "$bundle" && continue
    WORK_LIST+=("$macho")
  done < <(list_macho_files "$bundle")
  # No entitlements on helpers: they must not inherit the wrapper's CloudKit
  # and push grants, and none of them talk to either service.
  WORK_LIST+=("$bundle")
done <<< "$NESTED_BUNDLES"

while IFS= read -r macho; do
  [[ -n "$macho" ]] || continue
  inside_other_bundle "$macho" "$APP" && continue
  [[ "$(dirname "$macho")" == "$APP/Contents/MacOS" ]] && continue
  WORK_LIST+=("$macho")
done < <(list_macho_files "$APP")

# The wrapper seals everything above it, so it is always last.
SIGN_TOTAL=$((${#WORK_LIST[@]} + 1))
echo "==> Signing $SIGN_TOTAL code items from the leaves inward"

for item in "${WORK_LIST[@]+"${WORK_LIST[@]}"}"; do
  sign_one "$item"
done

if [[ -n "$ENTITLEMENTS" ]]; then
  sign_one "$APP" --entitlements "$ENTITLEMENTS"
else
  sign_one "$APP"
fi

echo "==> Signed $SIGNED_COUNT code items inside out; wrapper sealed last."
