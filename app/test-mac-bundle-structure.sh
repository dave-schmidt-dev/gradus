#!/usr/bin/env bash
# Hermetic behavior tests for the Gradus Mac bundle signing and verification
# scripts. Nothing here touches a real signing identity, a real keychain, or
# the network: `codesign` is a mock driven by environment variables, and the
# bundle under test is a synthetic tree built from tiny clang-compiled binaries.
#
# The fixtures are real files with real Mach-O headers and real permission bits
# on purpose. `lipo`, `file`, `plutil`, `stat` and `xattr` all run for real, so
# the architecture, placement, mode and metadata checks are exercised against
# the same tools the release path uses. Only the parts that genuinely require
# Apple's signing infrastructure are faked.
#
# Each fixture carries exactly one deliberate defect and asserts the one
# message that names it. A suite where several defects share a message cannot
# tell you which check regressed.
set -euo pipefail

umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_SCRIPT="$SCRIPT_DIR/verify-mac-bundle.sh"
SIGN_SCRIPT="$SCRIPT_DIR/sign-mac-bundle.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gradus-bundle-tests.XXXXXX")"
MOCK_BIN="$TEST_ROOT/bin"
FIXTURE_SOURCE="$TEST_ROOT/fixture-source"

cleanup() {
  rm -rf "$TEST_ROOT" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

mkdir -p "$MOCK_BIN" "$FIXTURE_SOURCE"

tests_run=0
TEAM_ID="4CJ49V6QHW"
IDENTITY="Developer ID Application: Zero Delta LLC (US) ($TEAM_ID)"

# --- mock codesign -----------------------------------------------------------
# Modes, in the order they are recognised:
#   --sign        signing pass; appends the full argument list to MOCK_SIGN_LOG
#   --verify      strict verification; fails when MOCK_VERIFY_FAIL=1
#   --entitlements with -d   entitlement dump as an XML plist
#   -dvvv         signature information block
#
# Per-path overrides are "substring" or "substring=value" so a fixture can
# break exactly one file in an otherwise valid bundle.
cat >"$MOCK_BIN/codesign" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail

args=("$@")
target="${args[${#args[@]} - 1]}"
team="${MOCK_TEAM_ID:-4CJ49V6QHW}"
identity="${MOCK_IDENTITY:-Developer ID Application: Zero Delta LLC (US) (4CJ49V6QHW)}"

contains() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

matches() {
  # "" never matches, so an unset override leaves every path alone.
  [[ -n "${1:-}" ]] || return 1
  [[ "$target" == *"$1"* ]]
}

if contains "--sign" "${args[@]}"; then
  if [[ -n "${MOCK_SIGN_LOG:-}" ]]; then
    printf '%s\n' "$*" >>"$MOCK_SIGN_LOG"
  fi
  exit 0
fi

if contains "--verify" "${args[@]}"; then
  if [[ "${MOCK_VERIFY_FAIL:-0}" == "1" ]]; then
    echo "$target: a sealed resource is missing or invalid" >&2
    exit 1
  fi
  exit 0
fi

if contains "--entitlements" "${args[@]}"; then
  extra_path="${MOCK_EXTRA_ENTITLEMENT%%=*}"
  extra_key="${MOCK_EXTRA_ENTITLEMENT##*=}"
  printf '<?xml version="1.0" encoding="UTF-8"?>'
  printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  printf '<plist version="1.0"><dict>'
  if [[ "$target" == *"/Contents/MacOS/Gradus" && "$target" != *Runtime* ]]; then
    printf '<key>com.apple.application-identifier</key><string>%s.com.zerodelta.gradus.mac</string>' "$team"
    printf '<key>com.apple.developer.aps-environment</key><string>production</string>'
    printf '<key>com.apple.developer.icloud-container-environment</key><string>Production</string>'
    printf '<key>com.apple.developer.icloud-container-identifiers</key><array><string>iCloud.com.zerodelta.gradus</string></array>'
    printf '<key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>'
    printf '<key>com.apple.developer.team-identifier</key><string>%s</string>' "$team"
  fi
  if [[ -n "${MOCK_EXTRA_ENTITLEMENT:-}" && "$target" == *"$extra_path"* ]]; then
    printf '<key>%s</key><array><string>group.com.zerodelta.gradus</string></array>' "$extra_key"
  fi
  printf '</dict></plist>'
  exit 0
fi

if matches "${MOCK_UNSIGNED:-}"; then
  echo "$target: code object is not signed at all" >&2
  exit 1
fi

printf 'Executable=%s\n' "$target"
printf 'Identifier=com.zerodelta.gradus.mac\n'
printf 'Format=app bundle with Mach-O universal (x86_64 arm64)\n'
if matches "${MOCK_NO_RUNTIME:-}"; then
  printf 'CodeDirectory v=20500 size=1572 flags=0x0(none) hashes=38+7 location=embedded\n'
else
  printf 'CodeDirectory v=20500 size=1572 flags=0x10000(runtime) hashes=38+7 location=embedded\n'
fi
if matches "${MOCK_ADHOC:-}"; then
  printf 'Signature=adhoc\n'
  exit 0
fi
printf 'Signature size=8987\n'
override_path="${MOCK_TEAM_OVERRIDE%%=*}"
override_team="${MOCK_TEAM_OVERRIDE##*=}"
if [[ -n "${MOCK_TEAM_OVERRIDE:-}" && "$target" == *"$override_path"* ]]; then
  team="$override_team"
fi
if matches "${MOCK_WRONG_IDENTITY:-}"; then
  identity="Apple Development: someone else (ZZZZZZZZZZ)"
fi
printf 'Authority=%s\n' "$identity"
printf 'Authority=Developer ID Certification Authority\n'
printf 'Authority=Apple Root CA\n'
if ! matches "${MOCK_NO_TIMESTAMP:-}"; then
  printf 'Timestamp=Aug 31, 2026 at 6:10:56 PM\n'
fi
printf 'TeamIdentifier=%s\n' "$team"
exit 0
MOCK
chmod +x "$MOCK_BIN/codesign"

# --- fixture construction ----------------------------------------------------

cat >"$FIXTURE_SOURCE/main.c" <<'C'
int main(void) { return 0; }
C
cat >"$FIXTURE_SOURCE/lib.c" <<'C'
int gradus_fixture_symbol(void) { return 0; }
C

# Built once and copied, because two clang invocations per fixture across two
# dozen fixtures is most of the suite's runtime.
clang -arch arm64 -arch x86_64 -o "$FIXTURE_SOURCE/fat" "$FIXTURE_SOURCE/main.c"
clang -arch arm64 -o "$FIXTURE_SOURCE/thin" "$FIXTURE_SOURCE/main.c"
clang -arch arm64 -arch x86_64 -dynamiclib -o "$FIXTURE_SOURCE/fat.dylib" "$FIXTURE_SOURCE/lib.c"
clang -arch arm64 -dynamiclib -o "$FIXTURE_SOURCE/thin.dylib" "$FIXTURE_SOURCE/lib.c"

write_app_plist() {
  local path="$1" name="$2" executable="$3" identifier="$4"
  cat >"$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$executable</string>
    <key>CFBundleIdentifier</key>
    <string>$identifier</string>
    <key>CFBundleName</key>
    <string>$name</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.10.1</string>
    <key>CFBundleVersion</key>
    <string>18</string>
</dict>
</plist>
PLIST
}

# Builds a structurally correct release wrapper. Every fixture starts here and
# then breaks exactly one thing.
make_bundle() {
  local root="$1"
  local app="$root/Gradus.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Library/LaunchAgents"
  write_app_plist "$app/Contents/Info.plist" "Gradus" "Gradus" "com.zerodelta.gradus.mac"
  cp "$FIXTURE_SOURCE/fat" "$app/Contents/MacOS/Gradus"

  cat >"$app/Contents/Library/LaunchAgents/com.zerodelta.gradus.refresh-agent.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.zerodelta.gradus.refresh-agent</string>
    <key>BundleProgram</key>
    <string>Contents/Helpers/GradusRefreshAgent</string>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>120</integer>
</dict>
</plist>
PLIST

  cp "$FIXTURE_SOURCE/fat" "$app/Contents/Helpers/GradusRefreshAgent"

  local bridge="$app/Contents/Helpers/GradusCredentialBridge.app"
  mkdir -p "$bridge/Contents/MacOS"
  write_app_plist "$bridge/Contents/Info.plist" "GradusCredentialBridge" \
    "GradusCredentialBridge" "com.zerodelta.gradus.credential-bridge"
  cp "$FIXTURE_SOURCE/fat" "$bridge/Contents/MacOS/GradusCredentialBridge"

  local runtime="$app/Contents/Helpers/GradusRuntime.app"
  mkdir -p "$runtime/Contents/MacOS" "$runtime/Contents/Frameworks/python3__dot__14/lib-dynload"
  write_app_plist "$runtime/Contents/Info.plist" "GradusRuntime" "GradusRuntime" "GradusRuntime"
  cp "$FIXTURE_SOURCE/fat" "$runtime/Contents/MacOS/GradusRuntime"
  cp "$FIXTURE_SOURCE/fat.dylib" "$runtime/Contents/Frameworks/libfixture.dylib"
  cp "$FIXTURE_SOURCE/fat.dylib" \
    "$runtime/Contents/Frameworks/python3__dot__14/lib-dynload/_fixture.cpython-314-darwin.so"
  printf 'resource\n' >"$runtime/Contents/Frameworks/python3__dot__14/fixture.py"

  chmod -R go-w "$app"
  # Matches what the signing pass does to a real export. It does not remove
  # com.apple.provenance -- nothing can, see verify-mac-bundle.sh -- which is
  # exactly why the verifier does not check for that one.
  xattr -cr "$app"
  printf '%s\n' "$app"
}

# --- assertions --------------------------------------------------------------

run_verify() {
  local app="$1"
  shift
  set +e
  env CODESIGN="$MOCK_BIN/codesign" "$@" "$VERIFY_SCRIPT" "$app" \
    >"$TEST_ROOT/verify.out" 2>"$TEST_ROOT/verify.err"
  VERIFY_STATUS=$?
  set -e
  cat "$TEST_ROOT/verify.out" "$TEST_ROOT/verify.err" >"$TEST_ROOT/verify.all"
}

assert_verify_fails_with() {
  local message="$1" label="$2"
  if ((VERIFY_STATUS == 0)); then
    echo "FAIL: $label -- verification passed a bundle it should have rejected" >&2
    exit 1
  fi
  if ! grep -Fq -- "$message" "$TEST_ROOT/verify.all"; then
    echo "FAIL: $label -- expected message '$message' was not reported" >&2
    sed -n '1,40p' "$TEST_ROOT/verify.all" >&2
    exit 1
  fi
  echo "  ✓ $label"
  ((tests_run += 1))
}

assert_verify_passes() {
  local label="$1"
  if ((VERIFY_STATUS != 0)); then
    echo "FAIL: $label -- verification rejected a clean bundle" >&2
    sed -n '1,60p' "$TEST_ROOT/verify.all" >&2
    exit 1
  fi
  echo "  ✓ $label"
  ((tests_run += 1))
}

# 1. A structurally correct, correctly signed bundle passes every check.
fixture="$TEST_ROOT/clean"
app="$(make_bundle "$fixture")"
run_verify "$app"
assert_verify_passes "a clean release bundle passes every structural and signature check"

# 2. An unsigned nested Mach-O is named, not summarised.
fixture="$TEST_ROOT/unsigned"
app="$(make_bundle "$fixture")"
run_verify "$app" MOCK_UNSIGNED="libfixture.dylib"
assert_verify_fails_with "unsigned nested code: Contents/Helpers/GradusRuntime.app/Contents/Frameworks/libfixture.dylib" \
  "an unsigned nested binary fails and is named"

# 3. PyInstaller's ad-hoc signature is rejected specifically, because that is
#    the state the frozen runtime arrives in before the signing pass runs.
fixture="$TEST_ROOT/adhoc"
app="$(make_bundle "$fixture")"
run_verify "$app" MOCK_ADHOC="GradusRuntime.app/Contents/MacOS"
assert_verify_fails_with "ad-hoc signature on Contents/Helpers/GradusRuntime.app/Contents/MacOS/GradusRuntime" \
  "an ad-hoc signed frozen runtime is rejected"

# 4. Wrong Team ID on one nested item.
fixture="$TEST_ROOT/team"
app="$(make_bundle "$fixture")"
run_verify "$app" MOCK_TEAM_OVERRIDE="GradusCredentialBridge=ZZZZZZZZZZ"
assert_verify_fails_with "wrong Team ID on Contents/Helpers/GradusCredentialBridge.app" \
  "a nested binary signed by another team fails"

# 5. A signing identity that is not Developer ID.
fixture="$TEST_ROOT/identity"
app="$(make_bundle "$fixture")"
run_verify "$app" MOCK_WRONG_IDENTITY="GradusRefreshAgent"
assert_verify_fails_with "signing identity on Contents/Helpers/GradusRefreshAgent must begin with 'Developer ID Application'" \
  "a development-signed helper fails the identity check"

# 6. Hardened runtime missing on one item.
fixture="$TEST_ROOT/hardened"
app="$(make_bundle "$fixture")"
run_verify "$app" MOCK_NO_RUNTIME="_fixture.cpython"
assert_verify_fails_with "hardened runtime is not enabled on Contents/Helpers/GradusRuntime.app/Contents/Frameworks/python3__dot__14/lib-dynload/_fixture.cpython-314-darwin.so" \
  "a binary without the hardened runtime fails"

# 7. No secure timestamp: Apple rejects these, so the gate must too.
fixture="$TEST_ROOT/timestamp"
app="$(make_bundle "$fixture")"
run_verify "$app" MOCK_NO_TIMESTAMP="Contents/MacOS/Gradus"
assert_verify_fails_with "no secure timestamp on" "a signature without a secure timestamp fails"

# 8. A helper that picked up a privilege it should not have.
fixture="$TEST_ROOT/entitlement"
app="$(make_bundle "$fixture")"
run_verify "$app" MOCK_EXTRA_ENTITLEMENT="GradusCredentialBridge=com.apple.security.application-groups"
assert_verify_fails_with "unexpected entitlement on Contents/Helpers/GradusCredentialBridge.app/Contents/MacOS/GradusCredentialBridge: com.apple.security.application-groups" \
  "an unexpected entitlement on a helper fails and names the key"

# 9. The frozen runtime losing its Intel slice.
fixture="$TEST_ROOT/arch"
app="$(make_bundle "$fixture")"
cp "$FIXTURE_SOURCE/thin.dylib" "$app/Contents/Helpers/GradusRuntime.app/Contents/Frameworks/libfixture.dylib"
run_verify "$app"
assert_verify_fails_with "missing architecture on Contents/Helpers/GradusRuntime.app/Contents/Frameworks/libfixture.dylib" \
  "a frozen runtime binary missing its universal2 slice fails"

# 10. Writable drift.
fixture="$TEST_ROOT/writable"
app="$(make_bundle "$fixture")"
chmod g+w "$app/Contents/Helpers/GradusRuntime.app/Contents/Frameworks/python3__dot__14/fixture.py"
run_verify "$app"
assert_verify_fails_with "group- or world-writable file: Contents/Helpers/GradusRuntime.app/Contents/Frameworks/python3__dot__14/fixture.py" \
  "a group-writable file inside the runtime fails"

# 11. Executable drift outside the runtime's code directories.
fixture="$TEST_ROOT/exec-drift"
app="$(make_bundle "$fixture")"
mkdir -p "$app/Contents/Helpers/GradusRuntime.app/Contents/Resources"
cp "$FIXTURE_SOURCE/fat" "$app/Contents/Helpers/GradusRuntime.app/Contents/Resources/stray"
chmod go-w "$app/Contents/Helpers/GradusRuntime.app/Contents/Resources/stray"
run_verify "$app"
assert_verify_fails_with "executable file has nonstandard placement in the frozen runtime: Contents/Resources/stray" \
  "an executable outside the runtime code directories fails"

# 12. An absolute LaunchAgent program path: the defect that makes the job work
#     on the build machine and nowhere else.
fixture="$TEST_ROOT/absolute-agent"
app="$(make_bundle "$fixture")"
/usr/libexec/PlistBuddy -c "Set :BundleProgram /Applications/Gradus.app/Contents/Helpers/GradusRefreshAgent" \
  "$app/Contents/Library/LaunchAgents/com.zerodelta.gradus.refresh-agent.plist" >/dev/null
run_verify "$app"
assert_verify_fails_with "LaunchAgent BundleProgram must be bundle-relative" \
  "an absolute LaunchAgent program path fails"

# 13. The same defect wearing launchd's other key.
fixture="$TEST_ROOT/absolute-program"
app="$(make_bundle "$fixture")"
/usr/libexec/PlistBuddy -c "Add :Program string /usr/local/bin/gradus-refresh" \
  "$app/Contents/Library/LaunchAgents/com.zerodelta.gradus.refresh-agent.plist" >/dev/null
run_verify "$app"
assert_verify_fails_with "LaunchAgent Program must not be set" \
  "an absolute LaunchAgent Program key fails even when BundleProgram is correct"

# 14. A missing helper is a bundle that installs and then fails at first refresh.
fixture="$TEST_ROOT/missing-helper"
app="$(make_bundle "$fixture")"
rm -rf "$app/Contents/Helpers/GradusRuntime.app"
run_verify "$app"
assert_verify_fails_with "required helper is missing: Contents/Helpers/GradusRuntime.app" \
  "a bundle without the frozen runtime fails"

# 15. Release naming: the shipped wrapper is Gradus.app.
fixture="$TEST_ROOT/wrapper-name"
app="$(make_bundle "$fixture")"
mv "$app" "$fixture/GradusMac.app"
run_verify "$fixture/GradusMac.app"
assert_verify_fails_with "shipped wrapper must be named Gradus.app, found GradusMac.app" \
  "a wrapper still named GradusMac.app fails"

# 16. Platform suffixes are engineering identifiers, never customer-facing.
fixture="$TEST_ROOT/customer-name"
app="$(make_bundle "$fixture")"
/usr/libexec/PlistBuddy -c "Set :CFBundleName GradusMac" "$app/Contents/Info.plist" >/dev/null
run_verify "$app"
assert_verify_fails_with "platform suffix in a customer-facing name" \
  "a platform suffix in CFBundleName fails"

# 17. A failing strict verify is surfaced with Apple's own wording.
fixture="$TEST_ROOT/seal"
app="$(make_bundle "$fixture")"
run_verify "$app" MOCK_VERIFY_FAIL=1
assert_verify_fails_with "strict signature verification failed" \
  "a broken seal fails and quotes the verifier"

# 18. Quarantine metadata on a shipped bundle.
fixture="$TEST_ROOT/quarantine"
app="$(make_bundle "$fixture")"
xattr -w com.apple.quarantine "0081;00000000;fixture;" "$app/Contents/MacOS/Gradus"
run_verify "$app"
assert_verify_fails_with "quarantine or resource-fork metadata is present" \
  "quarantine metadata on a shipped bundle fails"

# 19. The verifier is read-only. A check that repairs what it audits reports a
#     state that was never shipped.
fixture="$TEST_ROOT/readonly"
app="$(make_bundle "$fixture")"
xattr -w com.apple.quarantine "0081;00000000;fixture;" "$app/Contents/MacOS/Gradus"
tree_state() {
  find "$1" \( -type f -o -type l \) -print0 | LC_ALL=C sort -z | xargs -0 stat -f '%N %Lp %z'
  xattr -r -l "$1" 2>/dev/null | LC_ALL=C sort
}
before="$(tree_state "$app")"
run_verify "$app"
after="$(tree_state "$app")"
if [[ "$before" != "$after" ]]; then
  echo "FAIL: verification modified the bundle it was auditing" >&2
  diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2 || true
  exit 1
fi
echo "  ✓ verification never writes to the bundle it audits"
((tests_run += 1))

# 20. Manifest schema: identities, architecture, entitlements, versions, source
#     revision and opaque digests -- and nothing that reads as a credential.
fixture="$TEST_ROOT/manifest"
app="$(make_bundle "$fixture")"
manifest="$TEST_ROOT/manifest.json"
set +e
env CODESIGN="$MOCK_BIN/codesign" SOURCE_REVISION="0123456789abcdef0123456789abcdef01234567" \
  "$VERIFY_SCRIPT" "$app" --manifest "$manifest" >"$TEST_ROOT/manifest.out" 2>&1
manifest_status=$?
set -e
if ((manifest_status != 0)); then
  echo "FAIL: manifest generation failed on a clean bundle" >&2
  sed -n '1,40p' "$TEST_ROOT/manifest.out" >&2
  exit 1
fi
/usr/bin/python3 - "$manifest" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)

expected_top = {"bundle", "code", "digest", "schema_version", "source_revision"}
if set(manifest) != expected_top:
    raise SystemExit(f"FAIL: manifest top-level keys are {sorted(manifest)}")
if set(manifest["bundle"]) != {"build_version", "identifier", "name", "short_version", "wrapper"}:
    raise SystemExit(f"FAIL: manifest bundle keys are {sorted(manifest['bundle'])}")
if set(manifest["digest"]) != {"algorithm", "file_count", "value"}:
    raise SystemExit(f"FAIL: manifest digest keys are {sorted(manifest['digest'])}")

expected_code = {
    "architectures",
    "entitlements",
    "hardened_runtime",
    "path",
    "sha256",
    "signing_identity",
    "team_identifier",
}
if not manifest["code"]:
    raise SystemExit("FAIL: manifest recorded no code items")
for item in manifest["code"]:
    if set(item) != expected_code:
        raise SystemExit(f"FAIL: manifest code keys are {sorted(item)}")
    if not re.fullmatch(r"[0-9a-f]{64}", item["sha256"]):
        raise SystemExit(f"FAIL: {item['path']} digest is not an opaque sha256")
    if item["team_identifier"] != "4CJ49V6QHW":
        raise SystemExit(f"FAIL: {item['path']} recorded team {item['team_identifier']}")
    if not isinstance(item["hardened_runtime"], bool):
        raise SystemExit(f"FAIL: {item['path']} hardened_runtime is not a boolean")

if not re.fullmatch(r"[0-9a-f]{64}", manifest["digest"]["value"]):
    raise SystemExit("FAIL: artifact digest is not an opaque sha256")
if manifest["digest"]["algorithm"] != "sha256-tree-v1":
    raise SystemExit("FAIL: artifact digest algorithm changed without a schema bump")
if manifest["source_revision"] != "0123456789abcdef0123456789abcdef01234567":
    raise SystemExit("FAIL: manifest did not record the source revision it was given")

# Same rule build-gradus-runtime.sh applies to its own manifest: no key may
# read as a credential, so a future field cannot smuggle one past review.
forbidden = re.compile(r"(?:auth|credential|password|secret|token)", re.IGNORECASE)


def walk(value, trail=()):
    if isinstance(value, dict):
        for key, child in value.items():
            if forbidden.search(str(key)):
                raise SystemExit("FAIL: credential-shaped manifest key: " + ".".join((*trail, str(key))))
            walk(child, (*trail, str(key)))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            walk(child, (*trail, str(index)))


walk(manifest)
PY
if [[ "$(stat -f '%Lp' "$manifest")" != "600" ]]; then
  echo "FAIL: manifest is not written mode 600" >&2
  exit 1
fi
echo "  ✓ the manifest carries only identities, architecture, entitlements, versions, revision and digests"
((tests_run += 1))

# --- signing pass ------------------------------------------------------------

# Unlike run_verify, whose extra arguments are environment overrides, these are
# the signing script's own options and must land after the script name.
run_sign() {
  local app="$1"
  shift
  : >"$TEST_ROOT/sign.log"
  set +e
  env CODESIGN="$MOCK_BIN/codesign" MOCK_SIGN_LOG="$TEST_ROOT/sign.log" \
    "$SIGN_SCRIPT" "$app" "$@" >"$TEST_ROOT/sign.out" 2>&1
  SIGN_STATUS=$?
  set -e
}

sign_line() {
  grep -n -- "$1" "$TEST_ROOT/sign.log" | head -n 1 | cut -d: -f1
}

# 21. Leaves to parent: every nested item is signed before the wrapper seals it.
fixture="$TEST_ROOT/sign-order"
app="$(make_bundle "$fixture")"
run_sign "$app" --identity "$IDENTITY" --entitlements "$SCRIPT_DIR/GradusMac/GradusMacProduction.entitlements"
if ((SIGN_STATUS != 0)); then
  echo "FAIL: signing a clean bundle failed" >&2
  sed -n '1,40p' "$TEST_ROOT/sign.out" >&2
  exit 1
fi
dylib_line="$(sign_line 'libfixture.dylib')"
runtime_line="$(sign_line 'GradusRuntime.app$')"
bridge_line="$(sign_line 'GradusCredentialBridge.app$')"
wrapper_line="$(sign_line 'Gradus.app$')"
for pair in "dylib:$dylib_line" "runtime:$runtime_line" "bridge:$bridge_line" "wrapper:$wrapper_line"; do
  if [[ -z "${pair#*:}" ]]; then
    echo "FAIL: signing pass never signed the ${pair%%:*}" >&2
    cat "$TEST_ROOT/sign.log" >&2
    exit 1
  fi
done
if ((dylib_line >= runtime_line)); then
  echo "FAIL: a framework was signed after the bundle that seals it" >&2
  exit 1
fi
if ((runtime_line >= wrapper_line || bridge_line >= wrapper_line)); then
  echo "FAIL: the wrapper was sealed before its nested code was signed" >&2
  cat "$TEST_ROOT/sign.log" >&2
  exit 1
fi
echo "  ✓ signing runs from the leaves inward and seals the wrapper last"
((tests_run += 1))

# 22. `--deep` is never the signing algorithm.
if grep -q -- '--deep' "$TEST_ROOT/sign.log"; then
  echo "FAIL: the signing pass used --deep" >&2
  exit 1
fi
if grep -nE 'codesign[^|]*--deep' "$SIGN_SCRIPT" | grep -qv '^[0-9]*:#'; then
  echo "FAIL: sign-mac-bundle.sh has a --deep code path" >&2
  exit 1
fi
echo "  ✓ the signing pass never uses --deep"
((tests_run += 1))

# 23. Hardened runtime and a secure timestamp on every single item.
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  if [[ "$line" != *"--options runtime"* ]]; then
    echo "FAIL: a code item was signed without the hardened runtime: $line" >&2
    exit 1
  fi
  if [[ "$line" != *"--timestamp"* ]]; then
    echo "FAIL: a code item was signed without a secure timestamp: $line" >&2
    exit 1
  fi
done <"$TEST_ROOT/sign.log"
echo "  ✓ every signed item gets the hardened runtime and a secure timestamp"
((tests_run += 1))

# Every `--timestamp` is a round trip to Apple's timestamp authority, and the
# frozen runtime alone is forty-odd of them. Without a line per item that is
# several silent network-bound minutes, which reads as a hang.
signed_items="$(wc -l <"$TEST_ROOT/sign.log" | tr -d ' ')"
progress_lines="$(grep -c '^\[.*\] Signing [0-9]*/[0-9]*: ' "$TEST_ROOT/sign.out" || true)"
if [[ "$progress_lines" != "$signed_items" ]]; then
  echo "FAIL: $signed_items items were signed but $progress_lines progress lines were emitted" >&2
  sed -n '1,20p' "$TEST_ROOT/sign.out" >&2
  exit 1
fi
if ! grep -q "Signing ${signed_items}/${signed_items}: Gradus.app\$" "$TEST_ROOT/sign.out" &&
  ! grep -q "Signing ${signed_items}/${signed_items}: " "$TEST_ROOT/sign.out"; then
  echo "FAIL: the progress counter never reached its own total" >&2
  exit 1
fi
echo "  ✓ signing reports progress for every item against a known total"
((tests_run += 1))

# 24. Only the wrapper carries entitlements; helpers must not inherit CloudKit.
entitlement_signs="$(grep -c -- '--entitlements' "$TEST_ROOT/sign.log" || true)"
if [[ "$entitlement_signs" != "1" ]]; then
  echo "FAIL: expected exactly one entitlement-bearing signature, found $entitlement_signs" >&2
  cat "$TEST_ROOT/sign.log" >&2
  exit 1
fi
if ! grep -- '--entitlements' "$TEST_ROOT/sign.log" | grep -q 'Gradus.app$'; then
  echo "FAIL: entitlements were applied to something other than the wrapper" >&2
  exit 1
fi
echo "  ✓ only the wrapper is signed with entitlements"
((tests_run += 1))

# 25. Refusing to ad-hoc sign is a safety property, not a usage nicety: an
#     ad-hoc signed release is exactly what this whole pass exists to prevent.
fixture="$TEST_ROOT/sign-no-identity"
app="$(make_bundle "$fixture")"
set +e
env CODESIGN="$MOCK_BIN/codesign" "$SIGN_SCRIPT" "$app" >"$TEST_ROOT/sign.out" 2>&1
no_identity_status=$?
set -e
if ((no_identity_status == 0)); then
  echo "FAIL: signing without an identity succeeded" >&2
  exit 1
fi
if ! grep -Fq "refusing to ad-hoc sign" "$TEST_ROOT/sign.out"; then
  echo "FAIL: signing without an identity did not explain why it refused" >&2
  exit 1
fi
echo "  ✓ signing refuses to run without an explicit identity"
((tests_run += 1))

# 26. Sign then verify: the pass produces something the audit accepts, so the
#     two scripts cannot drift into disagreeing about the same bundle.
fixture="$TEST_ROOT/round-trip"
app="$(make_bundle "$fixture")"
run_sign "$app" --identity "$IDENTITY" --entitlements "$SCRIPT_DIR/GradusMac/GradusMacProduction.entitlements"
if ((SIGN_STATUS != 0)); then
  echo "FAIL: round-trip signing failed" >&2
  exit 1
fi
run_verify "$app"
assert_verify_passes "a bundle from the signing pass passes verification unchanged"

echo "==> test-mac-bundle-structure.sh: $tests_run behavior assertions passed"
