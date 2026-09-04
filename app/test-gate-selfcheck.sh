#!/usr/bin/env bash
# Hermetic tests for the counting-leg assertion in test-gate.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE_SCRIPT="$SCRIPT_DIR/test-gate.sh"
failure_count=0
diagnostic_test_root="$(mktemp -d "${TMPDIR:-/tmp}/gradus-gate-diagnostics.XXXXXX")"
trap 'rm -rf "$diagnostic_test_root"' EXIT INT TERM
export GRADUS_TEST_GATE_DIAGNOSTIC_ROOT="$diagnostic_test_root/evidence/test-gate"

fail() {
  echo "FAIL: $1" >&2
  failure_count=$((failure_count + 1))
}

expect_failure() {
  local description="$1"
  shift
  if "$@"; then
    fail "$description unexpectedly passed"
  fi
}

emit_report() {
  local reporter="$1"
  local count="$2"
  case "$reporter" in
    swift-testing) printf 'Test run with %s tests\n' "$count" ;;
    pytest) printf '%s passed\n' "$count" ;;
    xctest) printf 'Executed %s tests\n** TEST SUCCEEDED **\n' "$count" ;;
    aggregate-xctest-swift)
      printf 'Test run with %s tests\nExecuted 3 tests\n** TEST SUCCEEDED **\n' "$((count - 3))"
      ;;
    *)
      echo "FAIL: unknown reporter '$reporter'" >&2
      return 1
      ;;
  esac
}

emit_absent_report() {
  printf 'command completed successfully\n'
}

# A sourced gate must not change either the caller's directory or shell
# options. Deliberately start with different options from the live gate.
if ! bash -c '
  set +e +u
  set +o pipefail
  expected_cwd="$PWD"
  expected_flags="$-"
  expected_options="$(set -o)"
  source "$1"
  [[ "$PWD" == "$expected_cwd" ]]
  [[ "$-" == "$expected_flags" ]]
  [[ "$(set -o)" == "$expected_options" ]]
' bash "$GATE_SCRIPT"; then
  fail "sourcing test-gate.sh changed the caller's cwd or shell options"
fi

# shellcheck source=./test-gate.sh
source "$GATE_SCRIPT"
validate_counting_leg_declarations || fail "live counting-leg declarations are invalid"
validate_density_image_snapshot_selectors || fail "live density image snapshot selectors are invalid"

emit_failed_diagnostic_fixture() {
  printf 'credential-free failure detail\n'
  return 37
}
if assert_counting_leg "swift-testing" emit_failed_diagnostic_fixture; then
  fail "failed counting leg unexpectedly passed"
fi
diagnostic_path="$(find "$GRADUS_TEST_GATE_DIAGNOSTIC_ROOT" -type f -name 'swift-testing-*.log' -print -quit)"
[[ -n "$diagnostic_path" && "$(cat "$diagnostic_path")" == "credential-free failure detail" ]] ||
  fail "failed counting leg did not preserve its diagnostic output"
[[ -z "$diagnostic_path" || "$(/usr/bin/stat -f '%Lp' "$diagnostic_path")" == "600" ]] ||
  fail "counting-leg diagnostic output was not written 0600"

# Regression: the executable gate cd's into app/ before a failed leg is
# preserved. The default diagnostic root must remain the repository root even
# when the script was sourced through a relative path and the caller is now in
# app/. Keep the fixture in the real repository so this catches a path that
# only looks correct under the temporary override above, then remove its log.
default_diagnostic_root="$PROJECT_ROOT/.release-state/evidence/test-gate"
default_diagnostic_leg="default-root-regression-${BASHPID:-$$}-${RANDOM:-0}"
default_diagnostic_status=0
(
  cd "$PROJECT_ROOT"
  unset GRADUS_TEST_GATE_DIAGNOSTIC_ROOT
  # Deliberately use the relative path that the executable gate receives.
  source app/test-gate.sh
  cd app
  # Declare this synthetic leg only in the isolated fixture shell. It passes
  # assert_counting_leg's normal lookup without changing the live manifest.
  COUNTING_LEG_NAMES+=("$default_diagnostic_leg")
  COUNTING_LEG_REPORTERS+=("pytest")
  COUNTING_LEG_MINIMUMS+=(1)
  COUNTING_LEG_SOURCES+=("selfcheck-fixture")
  emit_default_root_failure() {
    printf 'credential-free default-root failure\n'
    return 37
  }
  assert_counting_leg "$default_diagnostic_leg" emit_default_root_failure
) || default_diagnostic_status=$?
[[ "$default_diagnostic_status" -ne 0 ]] ||
  fail "default diagnostic-root failure fixture unexpectedly passed"
default_diagnostic_path=""
if [[ -d "$default_diagnostic_root" ]]; then
  default_diagnostic_path="$(find "$default_diagnostic_root" -type f -name "${default_diagnostic_leg}-*.log" -print -quit 2>/dev/null || true)"
fi
[[ -n "$default_diagnostic_path" && "$(cat "$default_diagnostic_path")" == "credential-free default-root failure" ]] ||
  fail "default diagnostic root did not preserve its failure output under the repository"
[[ -z "$default_diagnostic_path" || "$(/usr/bin/stat -f '%Lp' "$default_diagnostic_path")" == "600" ]] ||
  fail "default diagnostic output was not written 0600"
[[ -z "$default_diagnostic_path" ]] || rm -f "$default_diagnostic_path"

# The one semantic density-label assertion stays in the iPhone unit suite.
# Every selected canonical image test must contain one image assertion, and the
# gate must derive both destination selectors from this single list.
snapshot_test_names="$(awk '
  /^@Test func / {
    if (name != "" && has_image_assertion) print name
    name = $3
    sub(/\(\).*/, "", name)
    has_image_assertion = 0
    next
  }
  /assertIOSSnapshot\(/ { has_image_assertion = 1 }
  END { if (name != "" && has_image_assertion) print name }
' "$SCRIPT_DIR/GradusiOSTests/DensityLayoutSnapshotTests.swift")"
snapshot_test_count="$(printf '%s\n' "$snapshot_test_names" | sed '/^$/d' | wc -l | tr -d ' ')"
[[ "$snapshot_test_count" -eq "${#DENSITY_IMAGE_SNAPSHOT_TEST_SELECTORS[@]}" ]] ||
  fail "density image selector count does not match image assertion count"
snapshot_selector_names="$(printf '%s\n' "${DENSITY_IMAGE_SNAPSHOT_TEST_SELECTORS[@]}" |
  sed -E 's#^GradusiOSTests/##; s/\(\)$//' | sort)"
if [[ "$(printf '%s\n' "$snapshot_test_names" | sed '/^$/d' | sort)" != "$snapshot_selector_names" ]]; then
  fail "density image selectors do not exactly match source image assertions"
fi
grep -Fq '"${density_snapshot_skip_args[@]}"' "$GATE_SCRIPT" ||
  fail "iPhone does not derive density snapshot exclusions from the shared selector list"
grep -Fq 'assert_counting_leg "GradusiOS-DensityPhone"' "$GATE_SCRIPT" ||
  fail "dedicated phone density snapshot leg is missing"
grep -Fq 'assert_counting_leg "GradusiOS-DensityPad"' "$GATE_SCRIPT" ||
  fail "dedicated pad density snapshot leg is missing"

# The two iOS destinations are separate evidence, not interchangeable labels.
# Keep the destination contract structural so a copied iPhone command cannot
# silently make the iPad leg green (or vice versa).
validate_ios_destination_contract() {
  local gate_path="$1"
  local iphone_block density_phone_block density_pad_block widget_block ipad_block iphone_ui_block
  iphone_block="$(sed -n '/assert_counting_leg "GradusiOS-iPhone"/,/CODE_SIGNING_ALLOWED=NO/p' "$gate_path")"
  density_phone_block="$(sed -n '/assert_counting_leg "GradusiOS-DensityPhone"/,/CODE_SIGNING_ALLOWED=NO/p' "$gate_path")"
  density_pad_block="$(sed -n '/assert_counting_leg "GradusiOS-DensityPad"/,/CODE_SIGNING_ALLOWED=NO/p' "$gate_path")"
  widget_block="$(sed -n '/assert_counting_leg "GradusWidget"/,/CODE_SIGNING_ALLOWED=NO/p' "$gate_path")"
  ipad_block="$(sed -n '/assert_counting_leg "GradusiOS-iPad"/,/CODE_SIGNING_ALLOWED=NO/p' "$gate_path")"
  iphone_ui_block="$(sed -n '/assert_counting_leg "GradusiOSUI"/,/CODE_SIGNING_ALLOWED=NO/p' "$gate_path")"

  [[ "$iphone_block" == *'-destination "platform=iOS Simulator,id=$sim_udid"'* ]] ||
    return 1
  [[ "$widget_block" == *'-destination "platform=iOS Simulator,id=$sim_udid"'* ]] ||
    return 1
  [[ "$density_phone_block" == *'-destination "platform=iOS Simulator,id=$sim_udid"'* ]] ||
    return 1
  [[ "$density_phone_block" == *'"${density_phone_only_args[@]}"'* ]] ||
    return 1
  [[ "$density_pad_block" == *'-destination "platform=iOS Simulator,id=$ipad_udid"'* ]] ||
    return 1
  [[ "$density_pad_block" == *'"${density_pad_only_args[@]}"'* ]] ||
    return 1
  [[ "$widget_block" == *'-scheme GradusWidget'* ]] || return 1
  [[ "$widget_block" == *'-only-testing:GradusWidgetTests'* ]] || return 1
  [[ "$ipad_block" == *'-destination "platform=iOS Simulator,id=$ipad_udid"'* ]] ||
    return 1
  [[ "$iphone_ui_block" == *'-destination "platform=iOS Simulator,id=$sim_udid"'* ]] ||
    return 1
  [[ "$iphone_ui_block" == *'-only-testing:GradusiOSUITests'* ]] ||
    return 1
  [[ "$ipad_block" == *'-only-testing:GradusiOSUITests'* ]] ||
    return 1
  [[ "$iphone_block" == *'"${density_snapshot_skip_args[@]}"'* ]] ||
    return 1
}

validate_ios_destination_contract "$GATE_SCRIPT" ||
  fail "iPhone/iPad destination or UI-selector contract is incomplete"

# Every Xcode test leg must use one fresh, run-scoped DerivedData directory.
# Without it, snapshot resources or a stale Mac XCTest runner can survive a
# source/signing change and make the release gate exercise the wrong bundle.
validate_derived_data_contract() {
  local gate_path="$1" leg block
  grep -Fq 'derived_data_dir="$(gate_derived_data)"' "$gate_path" ||
    return 1
  grep -Fq 'rm -rf "$derived_data_dir"' "$gate_path" || return 1
  for leg in GradusMac GradusRefreshAgent GradusiOS-iPhone GradusiOS-DensityPhone GradusiOS-DensityPad GradusWidget GradusiOS-iPad GradusiOSUI; do
    block="$(sed -n "/assert_counting_leg \"$leg\"/,/CODE_SIGNING_ALLOWED=NO/p" "$gate_path")"
    [[ "$block" == *'-derivedDataPath "$derived_data_dir"'* ]] || return 1
  done
}

validate_derived_data_contract "$GATE_SCRIPT" ||
  fail "Xcode test legs are not isolated in fresh run-scoped DerivedData"

validate_widget_contract() {
  local gate_path="$1" project_path="$2" source_root="$3"
  local widget_block ios_block widget_target tests_target widget_scheme embed_count
  widget_block="$(sed -n '/assert_counting_leg "GradusWidget"/,/CODE_SIGNING_ALLOWED=NO/p' "$gate_path")"
  ios_block="$(sed -n '/^  GradusiOS:$/,/^  GradusWidget:$/p' "$project_path")"
  widget_target="$(awk '/^  GradusWidget:/ { in_t=1; next } in_t && /^  [A-Za-z0-9_]+:/ { exit } in_t { print }' "$project_path")"
  tests_target="$(awk '/^  GradusWidgetTests:/ { in_t=1; next } in_t && /^schemes:$/ { exit } in_t { print }' "$project_path")"
  widget_scheme="$(awk '/^schemes:$/ { in_s=1; next } in_s && /^  GradusWidget:$/ { in_w=1; next } in_w && /^  [A-Za-z0-9_]+:/ { exit } in_w { print }' "$project_path")"
  embed_count="$(grep -Fxc -- '      - target: GradusWidget' "$project_path" || true)"

  local widget_source_dir widget_source_file tests_source_dir
  widget_source_dir="$(awk '/^  GradusWidget:/ { in_t=1; next } in_t && /^  [A-Za-z0-9_]+:/ { exit } in_t && /path:/ { for (i=1; i<=NF; i++) if ($i == "path:") { print $(i+1); exit } }' "$project_path")"
  widget_source_file="$(awk '/^  GradusWidget:/ { in_t=1; next } in_t && /^  [A-Za-z0-9_]+:/ { exit } in_t && /includes:/ { for (i=1; i<=NF; i++) if ($i == "includes:") { val=$(i+1); gsub(/[\[\],]/, "", val); print val; exit } }' "$project_path")"
  tests_source_dir="$(awk '/^  GradusWidgetTests:/ { in_t=1; next } in_t && /^  [A-Za-z0-9_]+:/ { exit } in_t && /sources:/ { for (i=1; i<=NF; i++) if ($i == "sources:") { val=$(i+1); gsub(/[\[\],]/, "", val); print val; exit } }' "$project_path")"

  local mac_marketing ios_marketing widget_marketing ios_build widget_build
  mac_marketing="$(awk '/^  GradusMac:/ { in_t=1; next } in_t && /^  [A-Za-z0-9_]+:/ { exit } in_t && /MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' "$project_path")"
  ios_marketing="$(awk '/^  GradusiOS:/ { in_t=1; next } in_t && /^  GradusWidget:/ { exit } in_t && /MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' "$project_path")"
  widget_marketing="$(awk '/^  GradusWidget:/ { in_t=1; next } in_t && /^  [A-Za-z0-9_]+:/ { exit } in_t && /MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' "$project_path")"
  ios_build="$(awk '/^  GradusiOS:/ { in_t=1; next } in_t && /^  GradusWidget:/ { exit } in_t && /CURRENT_PROJECT_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' "$project_path")"
  widget_build="$(awk '/^  GradusWidget:/ { in_t=1; next } in_t && /^  [A-Za-z0-9_]+:/ { exit } in_t && /CURRENT_PROJECT_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' "$project_path")"

  [[ "$widget_block" == *'-scheme GradusWidget'* ]] || return 1
  [[ "$widget_block" == *'-only-testing:GradusWidgetTests'* ]] || return 1
  [[ "$widget_block" == *'-destination "platform=iOS Simulator,id=$sim_udid"'* ]] || return 1
  [[ "$widget_block" == *'-derivedDataPath "$derived_data_dir"'* ]] || return 1
  [[ "$embed_count" -eq 1 ]] || return 1
  [[ "$ios_block" == *'- target: GradusWidget'* && "$ios_block" == *'embed: true'* ]] || return 1
  [[ "$widget_target" == *'type: app-extension'* ]] || return 1
  [[ "$widget_target" == *'APPLICATION_EXTENSION_API_ONLY: YES'* ]] || return 1
  [[ "$tests_target" == *'- target: GradusWidgetSupport'* ]] || return 1
  [[ "$widget_scheme" == *'- GradusWidgetTests'* ]] || return 1
  [[ -n "$widget_source_dir" && -n "$widget_source_file" ]] || return 1
  [[ -f "$source_root/$widget_source_dir/$widget_source_file" ]] || return 1
  [[ -n "$tests_source_dir" && -f "$source_root/$tests_source_dir/GradusWidgetTests.swift" ]] || return 1
  [[ -n "$mac_marketing" && "$mac_marketing" == "$ios_marketing" && "$ios_marketing" == "$widget_marketing" ]] || return 1
  [[ -n "$ios_build" && "$ios_build" == "$widget_build" ]] || return 1
  [[ "$(find "$source_root/GradusWidgetTests/__Snapshots__" -type f -name '*.png' | wc -l | tr -d ' ')" -eq 4 ]] || return 1
  ! grep -Eqr 'URLSession|CKContainer|CloudKit|import Security|Keychain|widgetURL|AppIntent|ActivityKit|aps-environment|UIBackgroundModes' \
    "$source_root/GradusWidget"
}

validate_widget_contract "$GATE_SCRIPT" "$SCRIPT_DIR/project.yml" "$SCRIPT_DIR" ||
  fail "widget target, selector, embed, source, snapshot, version parity, or isolation contract is incomplete"

validate_inv7_staging_contract() {
  local gate_path="$1" test_path="$SCRIPT_DIR/GradusMacTests/INV7Tests.swift" stage_block mac_leg_block snapshot_files snapshot_assertion_count
  stage_block="$(sed -n '/^# INV-7 runs inside/,/assert_counting_leg "GradusMac"/p' "$gate_path")"
  mac_leg_block="$(sed -n '/assert_counting_leg "GradusMac"/,/assert_counting_leg "GradusiOS-iPhone"/p' "$gate_path")"
  grep -Fq 'gradus_mac_inv7_source_root="$derived_data_dir/inv7-source/GradusMac"' "$gate_path" || return 1
  grep -Fq 'gradus_mac_snapshot_root="$derived_data_dir/snapshots/__Snapshots__"' "$gate_path" || return 1
  [[ "$stage_block" == *'/usr/bin/ditto "$GATE_REPO_ROOT/app/GradusMac/." "$gradus_mac_inv7_source_root"'* ]] || return 1
  [[ "$stage_block" == *'/usr/bin/ditto "$GATE_REPO_ROOT/app/GradusMacTests/__Snapshots__/." "$gradus_mac_snapshot_root"'* ]] || return 1
  [[ "$mac_leg_block" == *'env \
  GRADUS_DISABLE_PIPELINE=1 \
  TEST_RUNNER_GRADUS_INV7_SOURCE_ROOT="$gradus_mac_inv7_source_root" \
  TEST_RUNNER_GRADUS_SNAPSHOT_ROOT="$gradus_mac_snapshot_root" \
  xcodebuild test'* ]] || return 1
  grep -Fq 'environment[inv7SourceRootEnvironmentKey]' "$test_path" || return 1
  grep -Fq '!rawSourceRoot.isEmpty' "$test_path" || return 1
  grep -Fq 'fileExists(atPath: gradusMacDir.path, isDirectory: &isDirectory)' "$test_path" || return 1
  grep -Fq 'CI_WORKSPACE_PATH' "$test_path" || return 1
  grep -Fq 'app/GradusMac' "$test_path" || return 1
  grep -Fq 'xcodeCloudSnapshotRoot' "$SCRIPT_DIR/GradusMacTests/SnapshotTestSupport.swift" || return 1
  grep -Fq 'app/GradusMacTests/__Snapshots__' "$SCRIPT_DIR/GradusMacTests/SnapshotTestSupport.swift" || return 1

  snapshot_files=(
    "$SCRIPT_DIR/GradusMacTests/MenuContentSnapshotTests.swift"
    "$SCRIPT_DIR/GradusMacTests/ProviderListViewSnapshotTests.swift"
  )
  snapshot_assertion_count="$(rg -o 'assertStagedSnapshot\(' "${snapshot_files[@]}" | wc -l | tr -d ' ')"
  [[ "$snapshot_assertion_count" -eq 6 ]] || return 1
  ! rg -q 'assertSnapshot\(' "${snapshot_files[@]}" || return 1
  grep -Fq 'environment[stagedSnapshotRootEnvironmentKey]' "$SCRIPT_DIR/GradusMacTests/SnapshotTestSupport.swift" || return 1
  grep -Fq '!rawRoot.isEmpty' "$SCRIPT_DIR/GradusMacTests/SnapshotTestSupport.swift" || return 1
  rg -Uq 'FileManager\.default\.fileExists\(\s*atPath: root\.path,\s*isDirectory: &isDirectory\s*\)' \
    "$SCRIPT_DIR/GradusMacTests/SnapshotTestSupport.swift" || return 1
  grep -Fq 'snapshotDirectory: snapshotDirectory.path' "$SCRIPT_DIR/GradusMacTests/SnapshotTestSupport.swift" || return 1
}

validate_inv7_staging_contract "$GATE_SCRIPT" ||
  fail "INV-7 hosted test does not use the staged, explicit source root"

validate_bridge_staging_contract() {
  local gate_path="$1"
  # The structural assertions live in the sibling suite; `BridgeTests.swift`
  # holds only behaviour tests, which are free to use `#filePath`.
  local test_path="$SCRIPT_DIR/GradusCredentialBridgeTests/BridgeStructureTests.swift"
  local stage_block bridge_leg_block staged_root_call_count
  stage_block="$(sed -n '/^# These structural tests must not open/,/assert_counting_leg "GradusCredentialBridge"/p' "$gate_path")"
  bridge_leg_block="$(sed -n '/assert_counting_leg "GradusCredentialBridge"/,/CODE_SIGNING_ALLOWED=NO/p' "$gate_path")"

  grep -Fq 'gradus_bridge_stage_root="$derived_data_dir/bridge-source"' "$gate_path" || return 1
  grep -Fq 'gradus_bridge_source_root="$gradus_bridge_stage_root/app"' "$gate_path" || return 1
  [[ "$stage_block" == *'/bin/cp "$GATE_REPO_ROOT/app/project.yml" "$gradus_bridge_source_root/project.yml"'* ]] || return 1
  [[ "$stage_block" == *'/bin/cp "$GATE_REPO_ROOT/app/GradusCredentialBridgeCore/Bridge.swift"'* ]] || return 1
  [[ "$stage_block" == *'for source_directory in GradusMac GradusRefreshAgent packaging; do'* ]] || return 1
  [[ "$stage_block" == *'"$GATE_REPO_ROOT/app/$source_directory/."'* ]] || return 1
  [[ "$stage_block" == *'"$gradus_bridge_source_root/$source_directory"'* ]] || return 1
  [[ "$stage_block" == *'/usr/bin/ditto "$GATE_REPO_ROOT/gradus/." "$gradus_bridge_stage_root/gradus"'* ]] || return 1
  [[ "$stage_block" == *'could not stage non-empty GradusCredentialBridge structural-test inputs'* ]] || return 1
  [[ "$bridge_leg_block" == *'env \
  TEST_RUNNER_GRADUS_BRIDGE_SOURCE_ROOT="$gradus_bridge_source_root" \
  xcodebuild test'* ]] || return 1

  grep -Fq 'bridgeSourceRootEnvironmentKey = "GRADUS_BRIDGE_SOURCE_ROOT"' "$test_path" || return 1
  grep -Fq 'environment[Self.bridgeSourceRootEnvironmentKey]' "$test_path" || return 1
  grep -Fq '!rawRoot.isEmpty' "$test_path" || return 1
  grep -Fq 'checkout fallback is disabled' "$test_path" || return 1
  grep -Fq 'fileExists(atPath: root.path, isDirectory: &isDirectory)' "$test_path" || return 1
  staged_root_call_count="$(grep -Fc 'let appRoot = try stagedAppRoot()' "$test_path")"
  [[ "$staged_root_call_count" -eq 3 ]] || return 1
  ! grep -Fq '#filePath' "$test_path"
}

validate_bridge_staging_contract "$GATE_SCRIPT" ||
  fail "GradusCredentialBridge structural tests do not use the staged, explicit source root"

validate_local_macos_ui_contract() {
  local project_path="$1" local_block
  local_block="$(sed -n '/^  GradusMac:$/,/^  GradusMacCloud:$/p' "$project_path")"
  [[ "$local_block" == *'- GradusMacTests'* ]] || return 1
  [[ "$local_block" == *'- GradusMacUITests'* ]] || return 1
  [[ "$local_block" == *'GRADUS_DISABLE_PIPELINE: "1"'* ]] || return 1
  [[ "$(printf '%s\n' "$local_block" | grep -Fc -- '- GradusMacUITests' || true)" -eq 1 ]] || return 1
  [[ "$local_block" != *'TEST_RUNNER_GRADUS_INV7_SOURCE_ROOT'* ]] || return 1
  [[ "$local_block" != *'TEST_RUNNER_GRADUS_SNAPSHOT_ROOT'* ]] || return 1
}

local_scheme_keeps_macos_ui() {
  local scheme_path="$1"
  [[ -f "$scheme_path" ]] || return 1
  [[ "$(grep -Fc 'GradusMacUITests' "$scheme_path" || true)" -eq 2 ]] || return 1
  [[ "$(grep -Fc 'BuildableName = "GradusMacUITests.xctest"' "$scheme_path" || true)" -eq 1 ]] || return 1
  [[ "$(grep -Fc 'BlueprintName = "GradusMacUITests"' "$scheme_path" || true)" -eq 1 ]] || return 1
}

release_checklist_local_authority() {
  local checklist_path="$1"
  [[ -f "$checklist_path" ]] || return 1
  grep -Fq "candidate-bound local gate" "$checklist_path" || return 1
  grep -Fq "exact-source candidate evidence" "$checklist_path" || return 1
}

validate_local_macos_ui_contract "$SCRIPT_DIR/project.yml" ||
  fail "local GradusMac scheme must preserve Mac unit and UI coverage"
local_scheme_keeps_macos_ui \
  "$SCRIPT_DIR/Gradus.xcodeproj/xcshareddata/xcschemes/GradusMac.xcscheme" ||
  fail "local GradusMac scheme must include GradusMacUITests exactly twice"
release_checklist_local_authority "$SCRIPT_DIR/../RELEASE_CHECKLIST.md" ||
  fail "release checklist must name the candidate-bound local gate as authority"

grep -Fq -- '-only-testing:GradusMacUITests' "$GATE_SCRIPT" ||
  fail "local gate must select GradusMacUITests"
grep -Fq 'assert_counting_leg "GradusMacUI"' "$GATE_SCRIPT" ||
  fail "local gate must declare a GradusMacUI counting leg"

mutated_project="$(mktemp "${TMPDIR:-/tmp}/gradus-local-mac-ui-contract.XXXXXX")"
sed '/- GradusMacUITests/d' "$SCRIPT_DIR/project.yml" > "$mutated_project"
if validate_local_macos_ui_contract "$mutated_project"; then
  fail "local GradusMac contract accepted a missing GradusMacUITests target"
fi
rm -f "$mutated_project"
mutated_project="$(mktemp "${TMPDIR:-/tmp}/gradus-local-mac-pipeline-contract.XXXXXX")"
sed '/GRADUS_DISABLE_PIPELINE: "1"/d' "$SCRIPT_DIR/project.yml" > "$mutated_project"
if validate_local_macos_ui_contract "$mutated_project"; then
  fail "local GradusMac contract accepted a missing pipeline-disable setting"
fi
rm -f "$mutated_project"

validate_gradus_mac_deadline_contract() {
  local gate_path="$1" helper_block mac_leg_block
  helper_block="$(sed -n '/^run_with_deadline()/,/^}/p' "$gate_path")"
  mac_leg_block="$(sed -n '/assert_counting_leg "GradusMac"/,/assert_counting_leg "GradusiOS-iPhone"/p' "$gate_path")"
  [[ "$helper_block" == *'run_with_deadline()'* ]] || return 1
  [[ "$helper_block" == *'exceeded ${deadline_seconds}s; terminating'* ]] || return 1
  [[ "$helper_block" == *'kill -TERM "$child_pid"'* ]] || return 1
  [[ "$helper_block" == *'kill -KILL "$child_pid"'* ]] || return 1
  [[ "$helper_block" == *'command_status=124'* ]] || return 1
  [[ "$helper_block" == *') >/dev/null 2>&1 &'* ]] || return 1
  [[ "$helper_block" == *'rm -f "$marker"'* ]] || return 1
  [[ "$mac_leg_block" == *'run_with_deadline "$GRADUS_MAC_TEST_TIMEOUT_SECONDS" "GradusMac unit tests"'* ]] || return 1
  [[ "$mac_leg_block" != *'assert_counting_leg "GradusiOS-iPhone" run_with_deadline'* ]] || return 1
  grep -Fq 'GRADUS_MAC_TEST_TIMEOUT_SECONDS="${GRADUS_MAC_TEST_TIMEOUT_SECONDS:-600}"' "$gate_path" || return 1
}

validate_gradus_mac_deadline_contract "$GATE_SCRIPT" ||
  fail "GradusMac unit-test deadline contract is incomplete"

validate_refresh_agent_contract() {
  local gate_path="$1" project_path="$2"
  local agent_block core_target tool_target tests_target scheme_block mac_target plist_path
  agent_block="$(sed -n '/assert_counting_leg "GradusRefreshAgent"/,/CODE_SIGNING_ALLOWED=NO/p' "$gate_path")"
  core_target="$(awk '/^  GradusRefreshAgentCore:/ { in_t=1; next } in_t && /^  [A-Za-z0-9_]+:/ { exit } in_t { print }' "$project_path")"
  tool_target="$(awk '/^  GradusRefreshAgent:/ { in_t=1; next } in_t && /^  [A-Za-z0-9_]+:/ { exit } in_t { print }' "$project_path")"
  tests_target="$(awk '/^  GradusRefreshAgentTests:/ { in_t=1; next } in_t && /^  [A-Za-z0-9_]+:/ { exit } in_t { print }' "$project_path")"
  scheme_block="$(awk '/^schemes:/ { in_s=1; next } in_s && /^  GradusRefreshAgent:/ { in_t=1; next } in_t && /^  [A-Za-z0-9_]+:/ { exit } in_t { print }' "$project_path")"
  mac_target="$(awk '/^  GradusMac:/ { in_t=1; next } in_t && /^  [A-Za-z0-9_]+:/ { exit } in_t { print }' "$project_path")"
  plist_path="$SCRIPT_DIR/GradusMac/Resources/com.zerodelta.gradus.refresh-agent.plist"

  [[ "$agent_block" == *'-scheme GradusRefreshAgent'* ]] || return 1
  [[ "$agent_block" == *'-only-testing:GradusRefreshAgentTests'* ]] || return 1
  [[ "$agent_block" == *'-destination '\''platform=macOS,arch=arm64'\'''* ]] || return 1
  [[ "$agent_block" == *'-derivedDataPath "$derived_data_dir"'* ]] || return 1
  # An explicit include list, not a directory glob: the core target must never
  # absorb a file by being dropped into the directory.
  [[ "$core_target" == *'includes: [RefreshAgent.swift, RefreshAgentCollaborators.swift]'* ]] || return 1
  [[ "$tool_target" == *'includes: [GradusRefreshAgentApp.swift]'* ]] || return 1
  [[ "$tool_target" == *'- target: GradusRefreshAgentCore'* ]] || return 1
  [[ "$tests_target" == *'- target: GradusRefreshAgentCore'* ]] || return 1
  [[ "$scheme_block" == *'- GradusRefreshAgentTests'* ]] || return 1
  [[ "$mac_target" == *'subpath: Contents/Library/LaunchAgents'* ]] || return 1
  [[ "$mac_target" == *'subpath: Contents/Helpers'* ]] || return 1
  [[ -f "$plist_path" ]] || return 1
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$plist_path" 2>/dev/null)" == "Contents/Helpers/GradusRefreshAgent" ]] || return 1
  ! /usr/libexec/PlistBuddy -c 'Print :Program' "$plist_path" >/dev/null 2>&1 || return 1
  ! /usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$plist_path" >/dev/null 2>&1 || return 1
  ! rg -qi 'import Security|Keychain|Cookies\.binarycookies|CloudKit|CKContainer|dropFirst\(\)' \
    "$SCRIPT_DIR/GradusRefreshAgent"
}

validate_refresh_agent_contract "$GATE_SCRIPT" "$SCRIPT_DIR/project.yml" ||
  fail "GradusRefreshAgent target, counted gate, BundleProgram plist, or isolation contract is incomplete"

mutated_agent_gate="$(mktemp "${TMPDIR:-/tmp}/gradus-refresh-agent-contract.XXXXXX")"
sed '/-only-testing:GradusRefreshAgentTests/d' "$GATE_SCRIPT" > "$mutated_agent_gate"
if validate_refresh_agent_contract "$mutated_agent_gate" "$SCRIPT_DIR/project.yml"; then
  fail "GradusRefreshAgent contract accepted a missing target-level selector"
fi
rm -f "$mutated_agent_gate"

# Run the real helper with hermetic commands. A normal failure keeps its exact
# status, a hung command is terminated with status 124, progress is visible,
# and the watchdog marker is removed in both paths.
deadline_test_root="$(mktemp -d "${TMPDIR:-/tmp}/gradus-deadline-selfcheck.XXXXXX")"
run_deadline_fixture() {
  local name="$1" expected_status="$2"
  shift 2
  local output="$deadline_test_root/$name.out" actual_status
  if TMPDIR="$deadline_test_root" run_with_deadline 1 "$name" "$@" >"$output" 2>&1; then
    actual_status=0
  else
    actual_status=$?
  fi
  [[ "$actual_status" -eq "$expected_status" ]] ||
    fail "deadline fixture '$name' returned $actual_status, expected $expected_status"
  grep -Fq "==> $name (deadline 1s)" "$output" ||
    fail "deadline fixture '$name' did not report its deadline"
}

run_deadline_fixture exact-status 37 bash -c 'printf "%s\\n" complete; exit 37'
run_deadline_fixture bounded-timeout 124 bash -c 'while :; do :; done'
grep -Fq 'FAIL: bounded-timeout exceeded 1s; terminating' \
  "$deadline_test_root/bounded-timeout.out" ||
  fail "deadline timeout did not emit visible termination evidence"
[[ -z "$(find "$deadline_test_root" -maxdepth 1 -type f -name 'gradus-test-deadline.*' -print -quit)" ]] ||
  fail "deadline watchdog marker was not cleaned up"
rm -rf "$deadline_test_root"

# A mutation that removes the deadline wrapper from the GradusMac leg must be
# rejected, so the bounded boundary cannot silently disappear.
mutated_gate="$(mktemp "${TMPDIR:-/tmp}/gradus-mac-deadline-contract.XXXXXX")"
sed 's/run_with_deadline "\$GRADUS_MAC_TEST_TIMEOUT_SECONDS" "GradusMac unit tests" //' \
  "$GATE_SCRIPT" > "$mutated_gate"
if validate_gradus_mac_deadline_contract "$mutated_gate"; then
  fail "GradusMac deadline contract accepted a removed wrapper"
fi
rm -f "$mutated_gate"

grep -Fq 'APPLE_UI_TEST_LOCK="${APPLE_UI_TEST_LOCK:-$HOME/.agent/bin/apple-ui-test-lock}"' "$GATE_SCRIPT" ||
  fail "canonical Apple UI-test lock path is missing"
# The two simulator UI legs take the lock through `gate_ui_test_lock` rather
# than calling apple-ui-test-lock directly. Both forms serialize identically;
# only the wrapper deletes the XCTestDevices clones xcodebuild leaves behind,
# so a regression to the direct form serializes correctly while leaking a
# simulator clone per run -- silent, and worth ~4 GB each. Pinned in both
# directions for exactly that reason.
for leg in GradusiOS-iPad GradusiOSUI; do
  ui_block="$(sed -n "/assert_counting_leg \"$leg\"/,/CODE_SIGNING_ALLOWED=NO/p" "$GATE_SCRIPT")"
  [[ "$ui_block" == *'gate_ui_test_lock --label'* ]] ||
    fail "$leg is not serialized by gate_ui_test_lock"
  [[ "$ui_block" != *'"$APPLE_UI_TEST_LOCK" --label'* ]] ||
    fail "$leg must take the lock via gate_ui_test_lock so its clones are reaped"
done
for leg in GradusMac GradusRefreshAgent GradusiOS-iPhone GradusWidget; do
  unit_block="$(sed -n "/assert_counting_leg \"$leg\"/,/CODE_SIGNING_ALLOWED=NO/p" "$GATE_SCRIPT")"
  [[ "$unit_block" != *'"$APPLE_UI_TEST_LOCK"'* && "$unit_block" != *'gate_ui_test_lock'* ]] ||
    fail "$leg unit leg must not take the Apple UI-test lock"
done

# GradusMacUI drives real HID automation against the host's focused window, so
# it takes the machine-wide lock too -- with the lock OUTSIDE the deadline, so
# an unbounded wait for a contending Apple UI test is not charged against the
# 600s budget (measured: it is, and the leg fails spuriously, when the order is
# reversed). apple-ui-test-lock execvp's in place and cannot exec a shell
# function, so `run_with_deadline` is re-entered through `bash -c` and reaches
# that shell via `export -f`. The leg's range terminator is the `-only-testing`
# flag because, unlike the unit legs, it does not end at CODE_SIGNING_ALLOWED=NO.
# Line continuations are folded so one fixed string pins presence, order, and
# composition together.
validate_gradus_mac_ui_lock_contract() {
  local gate_path="$1" ui_leg_block
  ui_leg_block="$(sed -n '/assert_counting_leg "GradusMacUI"/,/-only-testing:GradusMacUITests/p' "$gate_path" |
    sed 's/[[:space:]]*\\$//' | tr '\n' ' ' | tr -s ' ')"
  [[ "$ui_leg_block" == *'assert_counting_leg "GradusMacUI" "$APPLE_UI_TEST_LOCK" --label "GradusMac UI tests" -- bash -c '\''run_with_deadline "$@"'\'' gradus-mac-ui-leg "$GRADUS_MAC_TEST_TIMEOUT_SECONDS" "GradusMac UI tests" env GRADUS_DISABLE_PIPELINE=1 xcodebuild test'* ]] || return 1
  grep -Fq 'export -f run_with_deadline' "$gate_path" || return 1
}

validate_gradus_mac_ui_lock_contract "$GATE_SCRIPT" ||
  fail "GradusMacUI leg is not serialized by apple-ui-test-lock outside its deadline"

mutated_gate="$(mktemp "${TMPDIR:-/tmp}/gradus-mac-ui-lock-contract.XXXXXX")"
sed 's/"\$APPLE_UI_TEST_LOCK" --label "GradusMac UI tests" -- //' "$GATE_SCRIPT" > "$mutated_gate"
if validate_gradus_mac_ui_lock_contract "$mutated_gate"; then
  fail "GradusMacUI lock contract accepted an unserialized leg"
fi
sed '/^export -f run_with_deadline$/d' "$GATE_SCRIPT" > "$mutated_gate"
if validate_gradus_mac_ui_lock_contract "$mutated_gate"; then
  fail "GradusMacUI lock contract accepted a leg whose deadline cannot cross the exec"
fi
rm -f "$mutated_gate"

ipad_ui_line="$(grep -nF 'assert_counting_leg "GradusiOS-iPad"' "$GATE_SCRIPT" | cut -d: -f1)"
iphone_ui_line="$(grep -nF 'assert_counting_leg "GradusiOSUI"' "$GATE_SCRIPT" | cut -d: -f1)"
if ! (( ipad_ui_line < iphone_ui_line )); then
  fail "simulator UI legs must stay adjacent"
fi

validate_iphone_ui_handoff_contract() {
  local gate_path="$1" handoff_block handoff_call_line
  handoff_block="$(sed -n '/^reset_simulator_ui_session_for_iphone()/,/^}/p' "$gate_path")"
  [[ "$handoff_block" == *'xcrun simctl shutdown "$ipad_udid"'* ]] || return 1
  [[ "$handoff_block" == *'xcrun simctl shutdown "$sim_udid"'* ]] || return 1
  [[ "$handoff_block" == *'xcrun simctl boot "$sim_udid"'* ]] || return 1
  [[ "$handoff_block" == *'xcrun simctl bootstatus "$sim_udid" -b'* ]] || return 1
  # Devices are disposable now (gate_sim_create/gate_sweep own their
  # lifecycle end-to-end), so there is no "restore the pre-existing iPad"
  # step to prove anymore -- that function was removed with the persistent
  # named-device model.
  handoff_call_line="$(grep -nF 'reset_simulator_ui_session_for_iphone' "$gate_path" | tail -n 1 | cut -d: -f1)"
  [[ -n "$handoff_call_line" ]] || return 1
  (( ipad_ui_line < handoff_call_line && handoff_call_line < iphone_ui_line ))
}

validate_iphone_ui_handoff_contract "$GATE_SCRIPT" ||
  fail "iPhone UI leg lacks a deterministic post-iPad simulator handoff"

# Prove the contract rejects a destination copy/paste regression, not just
# that the current source happens to contain the expected strings.
mutated_gate="$(mktemp "${TMPDIR:-/tmp}/gradus-gate-contract.XXXXXX")"
sed 's/platform=iOS Simulator,id=\$ipad_udid/platform=iOS Simulator,id=\$sim_udid/g' \
  "$GATE_SCRIPT" > "$mutated_gate"
if validate_ios_destination_contract "$mutated_gate"; then
  fail "destination contract accepted an iPad leg pointed at the iPhone simulator"
fi
rm -f "$mutated_gate"

# Prove the widget boundary rejects regressions: a copied selector, a
# duplicate containing-app embed, an absent target source declaration,
# a corrupted widget scheme testable list, mismatched marketing versions,
# or mismatched iOS/widget build numbers.
mutated_gate="$(mktemp "${TMPDIR:-/tmp}/gradus-widget-selector-contract.XXXXXX")"
sed 's/-only-testing:GradusWidgetTests/-only-testing:GradusiOSTests/' \
  "$GATE_SCRIPT" > "$mutated_gate"
if validate_widget_contract "$mutated_gate" "$SCRIPT_DIR/project.yml" "$SCRIPT_DIR"; then
  fail "widget contract accepted the wrong test selector"
fi
rm -f "$mutated_gate"
mutated_project="$(mktemp "${TMPDIR:-/tmp}/gradus-widget-embed-contract.XXXXXX")"
awk '{ print; if (!duplicated && $0 == "      - target: GradusWidget") { print; duplicated = 1 } }' \
  "$SCRIPT_DIR/project.yml" > "$mutated_project"
if validate_widget_contract "$GATE_SCRIPT" "$mutated_project" "$SCRIPT_DIR"; then
  fail "widget contract accepted a duplicate containing-app embed"
fi
rm -f "$mutated_project"
mutated_project="$(mktemp "${TMPDIR:-/tmp}/gradus-widget-source-contract.XXXXXX")"
sed 's/includes: \[GradusWidget.swift\]/includes: [MissingWidget.swift]/' \
  "$SCRIPT_DIR/project.yml" > "$mutated_project"
if validate_widget_contract "$GATE_SCRIPT" "$mutated_project" "$SCRIPT_DIR"; then
  fail "widget contract accepted an absent extension source"
fi
rm -f "$mutated_project"
mutated_project="$(mktemp "${TMPDIR:-/tmp}/gradus-widget-scheme-contract.XXXXXX")"
awk '
  /^schemes:$/ { in_s=1 }
  in_s && /- GradusWidgetTests/ { sub(/- GradusWidgetTests/, "- OtherTests") }
  { print }
' "$SCRIPT_DIR/project.yml" > "$mutated_project"
if validate_widget_contract "$GATE_SCRIPT" "$mutated_project" "$SCRIPT_DIR"; then
  fail "widget contract accepted wrong testable in widget scheme"
fi
rm -f "$mutated_project"
mutated_project="$(mktemp "${TMPDIR:-/tmp}/gradus-widget-marketing-contract.XXXXXX")"
awk '
  /^  GradusWidget:/ { in_t=1; print; next }
  in_t && /^  [A-Za-z0-9_]+:/ { in_t=0 }
  in_t && /MARKETING_VERSION:/ { sub(/MARKETING_VERSION:.*/, "MARKETING_VERSION: \"999.999.999\"") }
  { print }
' "$SCRIPT_DIR/project.yml" > "$mutated_project"
if validate_widget_contract "$GATE_SCRIPT" "$mutated_project" "$SCRIPT_DIR"; then
  fail "widget contract accepted mismatched widget marketing version"
fi
rm -f "$mutated_project"
mutated_project="$(mktemp "${TMPDIR:-/tmp}/gradus-mac-marketing-contract.XXXXXX")"
awk '
  /^  GradusMac:/ { in_t=1; print; next }
  in_t && /^  [A-Za-z0-9_]+:/ { in_t=0 }
  in_t && /MARKETING_VERSION:/ { sub(/MARKETING_VERSION:.*/, "MARKETING_VERSION: \"999.999.999\"") }
  { print }
' "$SCRIPT_DIR/project.yml" > "$mutated_project"
if validate_widget_contract "$GATE_SCRIPT" "$mutated_project" "$SCRIPT_DIR"; then
  fail "widget contract accepted mismatched Mac marketing version"
fi
rm -f "$mutated_project"
mutated_project="$(mktemp "${TMPDIR:-/tmp}/gradus-widget-build-contract.XXXXXX")"
awk '
  /^  GradusWidget:/ { in_t=1; print; next }
  in_t && /^  [A-Za-z0-9_]+:/ { in_t=0 }
  in_t && /CURRENT_PROJECT_VERSION:/ { sub(/CURRENT_PROJECT_VERSION:.*/, "CURRENT_PROJECT_VERSION: \"999999\"") }
  { print }
' "$SCRIPT_DIR/project.yml" > "$mutated_project"
if validate_widget_contract "$GATE_SCRIPT" "$mutated_project" "$SCRIPT_DIR"; then
  fail "widget contract accepted mismatched iOS/widget build numbers"
fi
rm -f "$mutated_project"

# Prove the DerivedData check rejects a partial wiring regression rather than
# only recognizing the current source.
mutated_gate="$(mktemp "${TMPDIR:-/tmp}/gradus-derived-data-contract.XXXXXX")"
sed '/-derivedDataPath "\$derived_data_dir"/d' "$GATE_SCRIPT" > "$mutated_gate"
if validate_derived_data_contract "$mutated_gate"; then
  fail "DerivedData contract accepted an Xcode test leg without isolation"
fi
rm -f "$mutated_gate"

leg_count="${#COUNTING_LEG_NAMES[@]}"
[[ "$leg_count" -eq "$EXPECTED_COUNTING_LEG_COUNT" ]] ||
  fail "live expected count does not match live leg names"
[[ "${#COUNTING_LEG_MINIMUMS[@]}" -eq "$EXPECTED_COUNTING_LEG_COUNT" ]] ||
  fail "live expected count does not match live floors"
[[ "${#COUNTING_LEG_REPORTERS[@]}" -eq "$EXPECTED_COUNTING_LEG_COUNT" ]] ||
  fail "live expected count does not match live reporters"
[[ "${#COUNTING_LEG_SOURCES[@]}" -eq "$EXPECTED_COUNTING_LEG_COUNT" ]] ||
  fail "live expected count does not match live sources"

# The fixed-size density snapshots and adaptive iPad workflows are separate
# legs so neither count can hide a zero-test result in the other.
snapshot_count="${#DENSITY_IMAGE_SNAPSHOT_TEST_SELECTORS[@]}"
ios_ui_test_count="$(rg --no-heading '^\s*func test' "$SCRIPT_DIR/GradusiOSUITests" -g '*.swift' | wc -l | tr -d ' ')"
[[ "$ios_ui_test_count" -eq 12 ]] ||
  fail "expected 12 GradusiOSUITests workflows, found $ios_ui_test_count"
ipad_leg_index=-1
density_phone_leg_index=-1
density_pad_leg_index=-1
iphone_ui_leg_index=-1
for ((index = 0; index < leg_count; index++)); do
  if [[ "${COUNTING_LEG_NAMES[index]}" == "GradusiOS-iPad" ]]; then
    ipad_leg_index="$index"
  fi
  if [[ "${COUNTING_LEG_NAMES[index]}" == "GradusiOSUI" ]]; then
    iphone_ui_leg_index="$index"
  fi
  if [[ "${COUNTING_LEG_NAMES[index]}" == "GradusiOS-DensityPhone" ]]; then
    density_phone_leg_index="$index"
  fi
  if [[ "${COUNTING_LEG_NAMES[index]}" == "GradusiOS-DensityPad" ]]; then
    density_pad_leg_index="$index"
  fi
done
if [[ "$ipad_leg_index" -lt 0 ||
      "${COUNTING_LEG_MINIMUMS[ipad_leg_index]}" -lt "$ios_ui_test_count" ]]; then
  fail "iPad floor does not protect its UI target"
fi
if [[ "$density_phone_leg_index" -lt 0 ||
      "${COUNTING_LEG_MINIMUMS[density_phone_leg_index]}" -lt "${#DENSITY_PHONE_SNAPSHOT_TEST_SELECTORS[@]}" ]]; then
  fail "phone density snapshot floor is incomplete"
fi
if [[ "$density_pad_leg_index" -lt 0 ||
      "${COUNTING_LEG_MINIMUMS[density_pad_leg_index]}" -lt "${#DENSITY_PAD_SNAPSHOT_TEST_SELECTORS[@]}" ||
      $(( ${#DENSITY_PHONE_SNAPSHOT_TEST_SELECTORS[@]} + ${#DENSITY_PAD_SNAPSHOT_TEST_SELECTORS[@]} )) -ne "$snapshot_count" ]]; then
  fail "pad density snapshot floor or selector partition is incomplete"
fi
if [[ "$iphone_ui_leg_index" -lt 0 ||
      "${COUNTING_LEG_MINIMUMS[iphone_ui_leg_index]}" -lt "$ios_ui_test_count" ]]; then
  fail "dedicated iPhone UI floor does not protect its UI target"
fi

for ((index = 0; index < leg_count; index++)); do
  floor="${COUNTING_LEG_MINIMUMS[index]}"
  [[ "$floor" -gt 1 ]] || fail "${COUNTING_LEG_NAMES[index]} floor is not above a one-test placeholder"
done

# The new hermetic suites are part of the runner manifest, not merely present
# in the checkout. Check both the declared source and its counted invocation.
for ((index = 0; index < leg_count; index++)); do
  source_name="${COUNTING_LEG_SOURCES[index]}"
  if [[ "$source_name" == *.py ]]; then
    [[ -f "$SCRIPT_DIR/$source_name" ]] ||
      fail "declared hermetic source is missing: $source_name"
    grep -Fq "assert_counting_leg \"${COUNTING_LEG_NAMES[index]}\"" "$GATE_SCRIPT" ||
      fail "declared hermetic source has no counted invocation: $source_name"
  fi
done

# UI target-level legs remain explicit rather than hidden in broad schemes.
grep -Fq -- "-only-testing:GradusiOSUITests" "$GATE_SCRIPT" ||
  fail "iOS UI target-level selector is missing from the canonical gate"

iphone_unit_block="$(sed -n '/assert_counting_leg "GradusiOS-iPhone"/,/CODE_SIGNING_ALLOWED=NO/p' "$GATE_SCRIPT")"
[[ "$iphone_unit_block" == *"-skip-testing:GradusiOSUITests"* ]] ||
  fail "iPhone unit leg must leave UI tests to their dedicated gate"
iphone_leg_index=-1
for ((index = 0; index < leg_count; index++)); do
  if [[ "${COUNTING_LEG_NAMES[index]}" == "GradusiOS-iPhone" ]]; then
    iphone_leg_index="$index"
  fi
done
[[ "$iphone_leg_index" -ge 0 && "${COUNTING_LEG_MINIMUMS[iphone_leg_index]}" -eq 177 ]] ||
  fail "iPhone integrated-gate floor must remain exactly 177"
iphone_ui_block="$(sed -n '/assert_counting_leg "GradusiOSUI"/,/CODE_SIGNING_ALLOWED=NO/p' "$GATE_SCRIPT")"
[[ "$iphone_ui_block" == *"-only-testing:GradusiOSUITests"* ]] ||
  fail "dedicated iPhone UI leg is missing its explicit selector"
grep -Fq 'gate_sim_create gradus iphone' "$GATE_SCRIPT" ||
  fail "gate must create a disposable iPhone simulator via the shared gate lib"
grep -Fq 'gate_sim_create gradus ipad' "$GATE_SCRIPT" ||
  fail "gate must create a disposable iPad simulator via the shared gate lib"
grep -Fq 'gate_sweep gradus' "$GATE_SCRIPT" ||
  fail "gate must sweep stale gate devices via the shared gate lib"

# Every declared leg passes at its live floor, exercising all three reporter
# forms and proving the self-check is using the gate's data.
# shellcheck disable=SC2034
COUNTING_LEG_RUN_COUNT=0
for ((index = 0; index < leg_count; index++)); do
  assert_counting_leg \
    "${COUNTING_LEG_NAMES[index]}" \
    emit_report "${COUNTING_LEG_REPORTERS[index]}" "${COUNTING_LEG_MINIMUMS[index]}"
done
assert_counting_legs_complete || fail "all live counting legs did not complete"

# Zero and absent reporter counts must fail, including XCTest's successful
# zero-test transcript.
for ((index = 0; index < leg_count; index++)); do
  expect_failure \
    "${COUNTING_LEG_NAMES[index]} zero count" \
    assert_counting_leg "${COUNTING_LEG_NAMES[index]}" \
      emit_report "${COUNTING_LEG_REPORTERS[index]}" 0
  expect_failure \
    "${COUNTING_LEG_NAMES[index]} absent count" \
    assert_counting_leg "${COUNTING_LEG_NAMES[index]}" emit_absent_report
  below_floor=$((COUNTING_LEG_MINIMUMS[index] - 1))
  expect_failure \
    "${COUNTING_LEG_NAMES[index]} below-floor count" \
    assert_counting_leg "${COUNTING_LEG_NAMES[index]}" \
      emit_report "${COUNTING_LEG_REPORTERS[index]}" "$below_floor"
done

# A missing invocation is distinct from a zero-count invocation and must fail
# the expected-leg check.
# shellcheck disable=SC2034
COUNTING_LEG_RUN_COUNT=0
for ((index = 0; index < leg_count - 1; index++)); do
  assert_counting_leg \
    "${COUNTING_LEG_NAMES[index]}" \
    emit_report "${COUNTING_LEG_REPORTERS[index]}" "${COUNTING_LEG_MINIMUMS[index]}"
done
expect_failure "deleted counting leg" assert_counting_legs_complete

# Regression lock: `record()`'s per-pattern comparison must be numeric, not
# lexicographic (fixed 2026-08-13 -- see HISTORY.md). A smaller-magnitude
# match recorded first must not block a later larger-magnitude match from
# winning. The real GradusiOS-iPhone incident this locks in had "Executed 20
# tests" precede "Test run with 142 tests" in the same leg's captured output;
# a lexicographic `>` keeps "20" because '1' < '2'. No declared leg's mock
# emits out-of-order magnitudes today, so this exercises the awk logic
# directly against a synthetic transcript shaped like that incident.
emit_out_of_order_magnitudes() {
  printf 'Executed 20 tests\n** TEST SUCCEEDED **\nTest run with 142 tests in 3 suites.\n'
}
[[ "${COUNTING_LEG_NAMES[2]}" == "GradusMac" ]] ||
  fail "numeric-max regression lock assumes GradusMac is index 2; array order changed"
saved_gradusmac_floor="${COUNTING_LEG_MINIMUMS[2]}"
COUNTING_LEG_MINIMUMS[2]=100
assert_counting_leg "GradusMac" emit_out_of_order_magnitudes ||
  fail "record() picked the string-comparison-losing count (20) instead of the numeric max (142)"
COUNTING_LEG_MINIMUMS[2]="$saved_gradusmac_floor"

if [[ "$failure_count" -ne 0 ]]; then
  echo "FAIL: $failure_count test-gate self-check failure(s)" >&2
  exit 1
fi

echo "test-gate.sh counting-leg assertions passed"
