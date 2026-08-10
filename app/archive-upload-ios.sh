#!/usr/bin/env bash
# Bumps the build number, archives, and uploads GradusiOS straight to App
# Store Connect for TestFlight (T6.1 continuation). Requires
# APP_STORE_CONNECT_API_KEY (.p8 contents), APP_STORE_CONNECT_KEY_ID,
# APP_STORE_CONNECT_ISSUER_ID in the environment. The fixed BWS consumer is
# the only supported credential boundary; the same key serves the attended
# assignment and profile-renewal paths.
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
# Human-attended invocation uses the same fixed consumer:
#   bws-secret-exec app-store-connect-upload -- app/archive-upload-ios.sh
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
  if environment="$(/usr/libexec/PlistBuddy -c "Print :$CLOUDKIT_ENVIRONMENT_KEY" "$entitlements_path" 2>/dev/null)"; then
    :
  else
    environment=""
  fi
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

read_marketing_version() {
  local project_path="$1" target="$2"
  awk -v target="$target" '
    $0 ~ "^  " target ":" { active=1; next }
    active && /^  [A-Za-z0-9_]+:/ { exit }
    active && /MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }
  ' "$project_path"
}

validate_common_marketing_version() {
  local project_path="$1" mac_version ios_version
  mac_version="$(read_marketing_version "$project_path" GradusMac)"
  ios_version="$(read_marketing_version "$project_path" GradusiOS)"
  [[ -n "$mac_version" && "$mac_version" == "$ios_version" ]] || {
    echo "FAIL: Mac and iOS marketing versions must match" >&2
    return 1
  }
}

read_evidence_field() {
  local field="$1"
  local evidence_path="$2"
  /usr/bin/plutil -extract "$field" raw -o - "$evidence_path"
}

sha256_file() {
  local path="$1" digest attempt
  for attempt in 1 2 3 4 5; do
    if digest="$(/usr/bin/shasum -a 256 "$path" 2>/dev/null | /usr/bin/awk '{print $1}')" \
      && [[ "$digest" =~ ^[[:xdigit:]]{64}$ ]]; then
      printf '%s\n' "$digest"
      return 0
    fi
    /bin/sleep 0.05
  done
  echo "FAIL: could not hash '$path' after retries" >&2
  return 1
}

sha256_tree() {
  local root="$1" path
  local digest=""
  while IFS= read -r path; do
    [[ -f "$path" ]] || continue
    digest+="$(sha256_file "$path")  ${path#"$root"/}\n"
  done < <(/usr/bin/git -C "$root" ls-files --cached --others --exclude-standard -z \
    | /usr/bin/tr '\0' '\n' \
    | /usr/bin/awk -v root="$root" '
        $0 !~ /^(\.git|build|\.state|\.release-state|\.venv|verifications|\.build|DerivedData|\.cache|\.ruff_cache|\.pytest_cache|__pycache__)(\/|$)/ { print root "/" $0 }
      ' \
    | /usr/bin/sort)
  printf '%b' "$digest" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
}

snapshot_source_digest() { sha256_tree "$1"; }
snapshot_project_digest() { sha256_file "$1"; }

assert_digest_unchanged() {
  local label="$1" path="$2" expected="$3" actual
  actual="$(sha256_file "$path")"
  [[ "$actual" == "$expected" ]] || {
    echo "FAIL: $label changed during candidate preparation" >&2
    return 1
  }
}

create_candidate_workspace() {
  local project_root="$1" workspace
  workspace="${GRADUS_CANDIDATE_WORKSPACE:-$(mktemp -d "${TMPDIR:-/tmp}/gradus-ios-candidate.XXXXXX")}"
  mkdir -p "$workspace"
  /opt/homebrew/bin/rsync -a \
    --exclude='.git' --exclude='build' --exclude='.state' --exclude='.release-state' \
    --exclude='.venv' --exclude='verifications' --exclude='.ruff_cache' \
    --exclude='.pytest_cache' --exclude='.cache' --exclude='.build' \
    --exclude='DerivedData' --exclude='__pycache__' \
    "$project_root/" "$workspace/project/"
  printf '%s\n' "$workspace/project"
}

failure_hook() {
  local point="$1"
  if [[ "${GRADUS_INJECT_FAILURE:-}" == "$point" ]]; then
    echo "FAIL: injected failure after $point" >&2
    return 97
  fi
  return 0
}

assert_candidate_not_in_flight() {
  local ledger_path="$1"
  /usr/bin/python3 - "$SCRIPT_DIR" "$ledger_path" <<'PY'
import sys

script_dir, ledger_path = sys.argv[1:]
sys.path.insert(0, script_dir)
from release_candidate.ledger import CandidateLedger, CandidateError  # noqa: E402

try:
    record = CandidateLedger(ledger_path).load()
    if record is not None and record.state in {"uploading", "uploaded_unassigned", "assigned"}:
        raise CandidateError(f"candidate is already in state {record.state}; reconcile it before retrying")
except CandidateError as exc:
    print(f"FAIL: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
}

read_prepared_candidate() {
  local ledger_path="$1"
  /usr/bin/python3 - "$SCRIPT_DIR" "$ledger_path" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

script_dir, ledger_path = sys.argv[1:]
sys.path.insert(0, script_dir)
from release_candidate.ledger import CandidateLedger, CandidateError  # noqa: E402

def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()

try:
    record = CandidateLedger(ledger_path).load()
    if record is None or record.state != "prepared":
        raise SystemExit(0)
    metadata = record.metadata or {}
    required = {
        "sourceRevision": metadata.get("sourceRevision"),
        "producerBuild": metadata.get("producerBuild"),
        "producerEvidenceSha256": metadata.get("producerEvidenceSha256"),
        "producerPublishedAt": metadata.get("producerPublishedAt"),
        "iosBuild": metadata.get("iosBuild"),
        "candidateWorkspace": metadata.get("candidateWorkspace"),
        "ipaPath": metadata.get("ipaPath"),
    }
    for key, value in required.items():
        if not isinstance(value, (str, int)) or (isinstance(value, str) and not value.strip()):
            raise CandidateError(f"prepared candidate is missing resumable metadata: {key}")
        if isinstance(value, str) and any(character in value for character in "\r\n\t"):
            raise CandidateError(f"prepared candidate metadata contains a control character: {key}")
    ipa_path = Path(required["ipaPath"])
    workspace_path = Path(required["candidateWorkspace"])
    if not workspace_path.is_dir():
        raise CandidateError(f"prepared candidate workspace is missing: {workspace_path}")
    if not ipa_path.is_file():
        raise CandidateError(f"prepared candidate IPA is missing: {ipa_path}")
    if digest(ipa_path) != record.artifact_sha256:
        raise CandidateError("prepared candidate IPA digest does not match the ledger")
    print(f"candidateId\t{record.candidate_id}")
    print(f"sourceSha256\t{record.source_sha256}")
    print(f"projectSha256\t{record.project_sha256}")
    print(f"artifactSha256\t{record.artifact_sha256}")
    print(f"build\t{record.build}")
    print(f"marketingVersion\t{record.marketing_version}")
    for key, value in required.items():
        print(f"{key}\t{value}")
    for key in ("walkthroughPath", "walkthroughSha256", "candidateEvidencePath"):
        value = metadata.get(key)
        if value is not None:
            if not isinstance(value, str) or any(character in value for character in "\r\n\t"):
                raise CandidateError(f"prepared candidate metadata contains an invalid path: {key}")
            print(f"{key}\t{value}")
except (CandidateError, OSError, json.JSONDecodeError) as exc:
    print(f"FAIL: cannot resume prepared candidate: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
}

persist_candidate_ipa() {
  local source_path="$1" destination_path="$2"
  /usr/bin/python3 - "$source_path" "$destination_path" <<'PY'
import os
import shutil
import sys
import tempfile
from pathlib import Path

source_path, destination_path = map(Path, sys.argv[1:])
if not source_path.is_file():
    raise SystemExit(f"FAIL: candidate IPA is missing: {source_path}")
destination_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
descriptor, temporary = tempfile.mkstemp(prefix=f".{destination_path.name}.", dir=destination_path.parent)
try:
    with os.fdopen(descriptor, "wb") as handle, source_path.open("rb") as source:
        shutil.copyfileobj(source, handle)
        handle.flush()
        os.fchmod(handle.fileno(), 0o600)
        os.fsync(handle.fileno())
    os.replace(temporary, destination_path)
    directory_fd = os.open(destination_path.parent, os.O_RDONLY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
except Exception:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PY
}

persist_candidate_evidence() {
  local ledger_path="$1" evidence_record_path="$2" candidate_id="$3" source_digest="$4" project_digest="$5"
  local artifact_digest="$6" build="$7" marketing_version="$8" source_revision="$9" producer_build="${10}"
  local producer_evidence_digest="${11}" walkthrough_path="${12}" walkthrough_digest="${13}" producer_published_at="${14}"
  local candidate_workspace="${15}" ipa_path="${16}"
  local refresh_existing="${17:-0}"
  /usr/bin/python3 - "$SCRIPT_DIR" "$ledger_path" "$evidence_record_path" "$candidate_id" \
    "$source_digest" "$project_digest" "$artifact_digest" "$build" "$marketing_version" \
    "$source_revision" "$producer_build" "$producer_evidence_digest" "$walkthrough_path" \
    "$walkthrough_digest" "$producer_published_at" "$candidate_workspace" "$ipa_path" "$refresh_existing" <<'PY'
import json
import os
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

script_dir, ledger_path, evidence_path, candidate_id, source_digest, project_digest, artifact_digest, build, marketing_version, source_revision, producer_build, producer_evidence_digest, walkthrough_path, walkthrough_digest, producer_published_at, candidate_workspace, ipa_path, refresh_existing = sys.argv[1:]
sys.path.insert(0, script_dir)
from release_candidate.ledger import CandidateError, CandidateLedger  # noqa: E402
from release_candidate.validation import ValidationError, validate_candidate_evidence  # noqa: E402

payload = {
    "candidateId": candidate_id,
    "sourceRevision": source_revision,
    "projectSha256": project_digest,
    "marketingVersion": marketing_version,
    "macMarketingVersion": marketing_version,
    "iosMarketingVersion": marketing_version,
    "producerBuild": int(producer_build),
    "producerEvidenceSha256": producer_evidence_digest,
    "iosBuild": int(build),
    "ipaSha256": artifact_digest,
    "walkthroughPath": walkthrough_path,
    "walkthroughSha256": walkthrough_digest,
    "createdAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "producerPublishedAt": producer_published_at,
}
try:
    evidence_file = Path(evidence_path)
    existing = None
    if evidence_file.exists():
        with evidence_file.open(encoding="utf-8") as stream:
            existing_data = json.load(stream)
        # A retry must reuse the same candidate even if Apple-side work paused
        # past the producer receipt freshness window.  The candidate tuple and
        # exact file digests remain bound; only the initial preparation path
        # requires a fresh producer receipt.
        existing = validate_candidate_evidence(existing_data, max_producer_age=timedelta.max)
        # Preserve the original preparation timestamp on a deterministic retry;
        # it is evidence metadata, not a new candidate tuple value.
        payload["createdAt"] = existing.created_at.isoformat().replace("+00:00", "Z")
        candidate_evidence = validate_candidate_evidence(payload, max_producer_age=timedelta.max)
        if existing != candidate_evidence and refresh_existing != "1":
            raise CandidateError("existing candidate evidence tuple mismatch")
    else:
        candidate_evidence = validate_candidate_evidence(
            payload, max_producer_age=timedelta.max if refresh_existing == "1" else timedelta(seconds=600)
        )
    if not evidence_file.exists() or (refresh_existing == "1" and existing != candidate_evidence):
        evidence_file.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(prefix=f".{evidence_file.name}.", dir=evidence_file.parent)
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                json.dump(payload, stream, sort_keys=True, indent=2)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, evidence_file)
        except Exception:
            try:
                os.unlink(temporary)
            except FileNotFoundError:
                pass
            raise
    ledger = CandidateLedger(ledger_path)
    if refresh_existing == "1":
        ledger.refresh_producer_evidence(producer_evidence_digest, producer_published_at)
    ledger.prepare(
        candidate_id,
        source_sha256=source_digest,
        project_sha256=project_digest,
        artifact_sha256=artifact_digest,
        build=int(build),
        marketing_version=marketing_version,
        metadata={
            "sourceRevision": source_revision,
            "producerBuild": int(producer_build),
            "producerEvidenceSha256": producer_evidence_digest,
            "producerPublishedAt": producer_published_at,
            "iosBuild": int(build),
            "candidateWorkspace": candidate_workspace,
            "ipaPath": ipa_path,
            "walkthroughPath": walkthrough_path,
            "walkthroughSha256": walkthrough_digest,
            "candidateEvidencePath": str(evidence_file),
        },
    )
except (CandidateError, ValidationError, OSError, ValueError, json.JSONDecodeError) as exc:
    print(f"FAIL: candidate preparation: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
}

prepare_candidate_ledger() {
  local ledger_path="$1" candidate_id="$2" source_digest="$3" project_digest="$4"
  local artifact_digest="$5" build="$6" marketing_version="$7" source_revision="$8" producer_build="$9"
  local producer_evidence_digest="${10}" producer_published_at="${11}" candidate_workspace="${12}" ipa_path="${13}"
  /usr/bin/python3 - "$SCRIPT_DIR" "$ledger_path" "$candidate_id" "$source_digest" "$project_digest" \
    "$artifact_digest" "$build" "$marketing_version" "$source_revision" "$producer_build" \
    "$producer_evidence_digest" "$producer_published_at" "$candidate_workspace" "$ipa_path" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from release_candidate.ledger import CandidateError, CandidateLedger  # noqa: E402

_, _, ledger_path, candidate_id, source_digest, project_digest, artifact_digest, build, marketing_version, source_revision, producer_build, producer_evidence_digest, producer_published_at, candidate_workspace, ipa_path = sys.argv
try:
    CandidateLedger(ledger_path).prepare(
        candidate_id,
        source_sha256=source_digest,
        project_sha256=project_digest,
        artifact_sha256=artifact_digest,
        build=int(build),
        marketing_version=marketing_version,
        metadata={
            "sourceRevision": source_revision,
            "producerBuild": int(producer_build),
            "producerEvidenceSha256": producer_evidence_digest,
            "producerPublishedAt": producer_published_at,
            "iosBuild": int(build),
            "candidateWorkspace": candidate_workspace,
            "ipaPath": ipa_path,
        },
    )
except (CandidateError, ValueError) as exc:
    print(f"FAIL: candidate ledger preparation: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
}

transition_candidate_state() {
  local ledger_path="$1" target="$2"
  /usr/bin/python3 - "$SCRIPT_DIR" "$ledger_path" "$target" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from release_candidate.ledger import CandidateError, CandidateLedger  # noqa: E402
try:
    CandidateLedger(sys.argv[2]).transition(sys.argv[3])
except CandidateError as exc:
    print(f"FAIL: candidate transition: {exc}", file=sys.stderr)
    raise SystemExit(1)
PY
}

set_required_entitlement() {
  local plist="$1" key="$2" type="$3" value="$4"
  if /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist" 2>/dev/null; then
    return 0
  fi
  /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$plist" 2>/dev/null || {
    echo "FAIL: required entitlement '$key' could not be written" >&2
    return 1
  }
}

assert_required_entitlement() {
  local plist="$1" key="$2" expected="$3" actual
  actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null)" || {
    echo "FAIL: required entitlement '$key' is missing" >&2
    return 1
  }
  [[ "$actual" == "$expected" ]] || {
    echo "FAIL: entitlement '$key' is '$actual', expected '$expected'" >&2
    return 1
  }
}

validate_producer_evidence() {
  local evidence_path="$1"
  local expected_build="$2"
  local expected_environment="$3"
  local evidence_build evidence_environment published_at normalized_timestamp published_epoch age

  if [[ ! -f "$evidence_path" ]]; then
    echo "FAIL: producer evidence is missing at '$evidence_path'" >&2
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

validate_producer_evidence_boundary() {
  local evidence_path="$1" expected_build="$2" expected_environment="$3"
  local expected_source="${4:-}" expected_project="${5:-}" actual_source actual_project
  validate_producer_evidence "$evidence_path" "$expected_build" "$expected_environment"
  if [[ -n "$expected_source" ]]; then
    actual_source="$(read_evidence_field sourceRevision "$evidence_path" 2>/dev/null || true)"
    [[ -z "$actual_source" || "$actual_source" == "$expected_source" ]] || {
      echo "FAIL: producer evidence source revision mismatch" >&2
      return 1
    }
  fi
  if [[ -n "$expected_project" ]]; then
    actual_project="$(read_evidence_field projectSha256 "$evidence_path" 2>/dev/null || true)"
    [[ -z "$actual_project" || "$actual_project" == "$expected_project" ]] || {
      echo "FAIL: producer evidence project digest mismatch" >&2
      return 1
    }
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

resolve_producer_evidence_path() {
  if [[ -n "${GRADUS_PRODUCER_EVIDENCE_PATH:-}" ]]; then
    printf '%s\n' "$GRADUS_PRODUCER_EVIDENCE_PATH"
    return 0
  fi

  local user_home
  user_home="$(resolve_user_home)" || return 1
  printf '%s\n' "$user_home/Library/Application Support/Gradus/$PRODUCER_EVIDENCE_FILENAME"
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
  local project_path="${2:-project.yml}"
  local ios_build_pattern
  ios_build_pattern="/^  GradusiOS:/,/^  [A-Za-z0-9_]+:/ s/(CURRENT_PROJECT_VERSION: )\"[0-9]+\"/\\1\"$next_build\"/"
  sed -i '' -E "$ios_build_pattern" "$project_path"
}

main() {
  cd "$SCRIPT_DIR"
  local project_root evidence_path expected_mac_build expected_cloudkit_environment
  local baseline_source_digest baseline_project_digest current_project_digest actual_source_digest candidate_root candidate_script_dir candidate_receipt_path
  local candidate_workspace candidate_ledger_path candidate_evidence_path walkthrough_path candidate_id source_revision producer_published_at
  local producer_evidence_digest artifact_digest marketing_version walkthrough_digest candidate_ipa_path durable_ipa_path prepared_metadata resume_candidate=0
  project_root="$(cd .. && pwd)"
  evidence_path="$(resolve_producer_evidence_path)" || return 1
  candidate_ledger_path="${GRADUS_CANDIDATE_LEDGER_PATH:-$project_root/.release-state/candidate.json}"
  candidate_evidence_path="${GRADUS_CANDIDATE_EVIDENCE_PATH:-}"
  walkthrough_path="${GRADUS_WALKTHROUGH_PATH:-}"
  candidate_receipt_path="${GRADUS_CANDIDATE_RECEIPT_PATH:-}"
  expected_mac_build="$(read_mac_build_number project.yml)"
  expected_cloudkit_environment="$(read_cloudkit_environment "$SCRIPT_DIR/GradusMac/GradusMacProduction.entitlements")"
  echo "==> Reading producer evidence from $evidence_path"
  : "${APP_STORE_CONNECT_API_KEY:?required}"
  : "${APP_STORE_CONNECT_KEY_ID:?required}"
  : "${APP_STORE_CONNECT_ISSUER_ID:?required}"
  validate_common_marketing_version "$SCRIPT_DIR/project.yml"
  assert_candidate_not_in_flight "$candidate_ledger_path"
  prepared_metadata="$(read_prepared_candidate "$candidate_ledger_path")"
  if [[ -n "$prepared_metadata" ]]; then
    resume_candidate=1
    while IFS=$'\t' read -r metadata_key metadata_value; do
      case "$metadata_key" in
        candidateId) candidate_id="$metadata_value" ;;
        sourceSha256) baseline_source_digest="$metadata_value" ;;
        projectSha256) baseline_project_digest="$metadata_value" ;;
        artifactSha256) artifact_digest="$metadata_value" ;;
        build) NEXT_BUILD="$metadata_value" ;;
        marketingVersion) marketing_version="$metadata_value" ;;
        sourceRevision) source_revision="$metadata_value" ;;
        producerBuild) expected_mac_build="$metadata_value" ;;
        producerEvidenceSha256) producer_evidence_digest="$metadata_value" ;;
        producerPublishedAt) producer_published_at="$metadata_value" ;;
        candidateWorkspace) candidate_workspace="$metadata_value" ;;
        ipaPath) candidate_ipa_path="$metadata_value" ;;
        walkthroughPath) walkthrough_path="$metadata_value" ;;
        walkthroughSha256) walkthrough_digest="$metadata_value" ;;
        candidateEvidencePath) candidate_evidence_path="$metadata_value" ;;
      esac
    done <<< "$prepared_metadata"
    [[ -n "${candidate_ipa_path:-}" && -n "${candidate_id:-}" && -n "${artifact_digest:-}" ]] || {
      echo "FAIL: prepared candidate metadata is incomplete" >&2
      return 1
    }
    IPA_PATH="$candidate_ipa_path"
    echo "==> Resuming prepared candidate $candidate_id build $NEXT_BUILD"
  fi
  if [[ "$resume_candidate" -eq 0 ]]; then
  baseline_source_digest="$(snapshot_source_digest "$project_root")"
  baseline_project_digest="$(snapshot_project_digest "$SCRIPT_DIR/project.yml")"
  echo "==> Validating producer evidence before candidate allocation"
  validate_producer_evidence_boundary "$evidence_path" "$expected_mac_build" "$expected_cloudkit_environment" "" "$baseline_project_digest"
  candidate_root="$(create_candidate_workspace "$project_root")"
  candidate_workspace="$(dirname "$candidate_root")"
  candidate_script_dir="$candidate_root/app"
  failure_hook allocation

  # The fixed BWS consumer starts children with a minimal environment. Restore
  # HOME from the local account record before uv,
  # xcodebuild, and the provisioning-profile lookup need it.
  export HOME="$(resolve_user_home)"
  export USER="$(resolve_user_name)"
  export LOGNAME="$USER"
  local uv_bin
  uv_bin="$(resolve_uv)"

  # Pin the certificate fingerprint that is actually embedded in the checked-
  # in API-created distribution profile.  A bare "Apple Distribution" lets
  # Xcode choose a different installed distribution certificate when more than
  # one exists, which the profile rejects.
  SIGNING_IDENTITY="FD247ACDEBCD05C725AE29B40218FB0F57807A2C"
  SIGNING_PROFILE_NAME="Gradus iOS App Store (API-created)"
  PROFILE_PATH="${HOME}/Library/MobileDevice/Provisioning Profiles/gradus-ios-app-store.provisionprofile"
  ARCHIVE_PATH="$candidate_script_dir/build/GradusiOS.xcarchive"
  PACKAGE_DIR="$candidate_script_dir/build/package-ios"

  echo "==> Determining next build number from App Store Connect"
  NEXT_BUILD="$(cd "$candidate_script_dir" && "$uv_bin" run --with pyjwt --with cryptography next-ios-build-number.py)"
  echo "    Next CURRENT_PROJECT_VERSION: $NEXT_BUILD"
  bump_ios_build_number "$NEXT_BUILD" "$candidate_script_dir/project.yml"
  failure_hook after-allocation

  echo "==> Regenerating Xcode project from project.yml"
  (cd "$candidate_script_dir" && xcodegen generate)

  rm -rf "$ARCHIVE_PATH" "$PACKAGE_DIR"

  echo "==> Archiving GradusiOS (build $NEXT_BUILD)"
  (cd "$candidate_script_dir" && xcodebuild archive \
    -project Gradus.xcodeproj \
    -scheme GradusiOS \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=iOS" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    PROVISIONING_PROFILE_SPECIFIER="$SIGNING_PROFILE_NAME")
  failure_hook archive

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
  set_required_entitlement "$PACKAGE_DIR/entitlements.plist" get-task-allow bool false
  set_required_entitlement "$PACKAGE_DIR/entitlements.plist" aps-environment string production
# Without an explicit value here, `--generate-entitlement-der` tries to derive
# this key from the embedded profile's own (multi-valued: Production AND
# Development) icloud-container-environment grant, can't resolve a single
# value, and silently emits an empty string -- which ASC's upload validator
# rejects outright ("this value should be a string value of 'Production'").
  set_required_entitlement "$PACKAGE_DIR/entitlements.plist" "$CLOUDKIT_ENVIRONMENT_KEY" string "$expected_cloudkit_environment"
  assert_required_entitlement "$PACKAGE_DIR/entitlements.plist" aps-environment production
  assert_required_entitlement "$PACKAGE_DIR/entitlements.plist" "$CLOUDKIT_ENVIRONMENT_KEY" "$expected_cloudkit_environment"

  codesign --force --sign "$SIGNING_IDENTITY" \
    --entitlements "$PACKAGE_DIR/entitlements.plist" --generate-entitlement-der --timestamp \
    "$PACKAGE_DIR/Payload/GradusiOS.app"
  failure_hook signing

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
  failure_hook packaging

  assert_digest_unchanged project "$SCRIPT_DIR/project.yml" "$baseline_project_digest"
  actual_source_digest="$(snapshot_source_digest "$project_root")"
  [[ "$actual_source_digest" == "$baseline_source_digest" ]] || {
    echo "FAIL: source changed during candidate preparation" >&2
    return 1
  }
  echo "==> Revalidating producer evidence immediately before upload"
  validate_producer_evidence_boundary "$evidence_path" "$expected_mac_build" "$expected_cloudkit_environment" "" "$baseline_project_digest"

  artifact_digest="$(sha256_file "$IPA_PATH")"
  candidate_id="${GRADUS_CANDIDATE_ID:-gradus-ios-${NEXT_BUILD}-${artifact_digest:0:16}}"
  [[ "$candidate_id" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "FAIL: candidate ID contains unsupported path characters" >&2
    return 1
  }
  candidate_workspace="$project_root/.release-state/candidates/$candidate_id"
  durable_ipa_path="$candidate_workspace/GradusiOS.ipa"
  echo "==> Persisting durable candidate IPA"
  persist_candidate_ipa "$IPA_PATH" "$durable_ipa_path"
  IPA_PATH="$durable_ipa_path"
  candidate_evidence_path="${candidate_evidence_path:-$candidate_workspace/candidate-evidence.json}"
  walkthrough_path="${walkthrough_path:-$candidate_workspace/walkthrough.md}"
  source_revision="$(read_evidence_field sourceRevision "$evidence_path" 2>/dev/null || true)"
  [[ -n "$source_revision" ]] || source_revision="$baseline_source_digest"
  producer_published_at="$(read_evidence_field publishedAt "$evidence_path")"
  producer_evidence_digest="$(sha256_file "$evidence_path")"
  marketing_version="$(read_marketing_version "$candidate_script_dir/project.yml" GradusiOS)"
  echo "==> Persisting machine-written candidate ledger before walkthrough generation"
  prepare_candidate_ledger "$candidate_ledger_path" "$candidate_id" "$baseline_source_digest" "$baseline_project_digest" \
    "$artifact_digest" "$NEXT_BUILD" "$marketing_version" "$source_revision" "$expected_mac_build" "$producer_evidence_digest" \
    "$producer_published_at" "$candidate_workspace" "$IPA_PATH"
  echo "==> Generating candidate-current walkthrough"
  PYTHONPATH="$SCRIPT_DIR" /usr/bin/python3 -m release_candidate.walkthrough \
    --ledger "$candidate_ledger_path" --artifact "$IPA_PATH" \
    --source-revision "$source_revision" --output "$walkthrough_path"
  walkthrough_digest="$(sha256_file "$walkthrough_path")"
  echo "==> Persisting machine-written candidate evidence and prepared ledger"
  persist_candidate_evidence \
    "$candidate_ledger_path" "$candidate_evidence_path" "$candidate_id" "$baseline_source_digest" \
    "$baseline_project_digest" "$artifact_digest" "$NEXT_BUILD" "$marketing_version" "$source_revision" \
    "$expected_mac_build" "$producer_evidence_digest" "$walkthrough_path" "$walkthrough_digest" "$producer_published_at" \
    "$candidate_workspace" "$IPA_PATH"
  else
    walkthrough_path="${walkthrough_path:-$candidate_workspace/walkthrough.md}"
    candidate_evidence_path="${candidate_evidence_path:-$candidate_workspace/candidate-evidence.json}"
    current_project_digest="$(snapshot_project_digest "$SCRIPT_DIR/project.yml")"
    [[ "$current_project_digest" == "$baseline_project_digest" ]] || {
      echo "FAIL: checked-out project changed since the prepared candidate" >&2
      return 1
    }
    echo "==> Revalidating fresh producer evidence before resumed upload"
    validate_producer_evidence_boundary "$evidence_path" "$expected_mac_build" "$expected_cloudkit_environment" "$source_revision" "$baseline_project_digest"
    producer_published_at="$(read_evidence_field publishedAt "$evidence_path")"
    producer_evidence_digest="$(sha256_file "$evidence_path")"
    if [[ ! -f "$walkthrough_path" || -z "${walkthrough_digest:-}" || "$(sha256_file "$walkthrough_path")" != "$walkthrough_digest" ]]; then
      echo "==> Completing candidate-current walkthrough for resumed candidate"
      PYTHONPATH="$SCRIPT_DIR" /usr/bin/python3 -m release_candidate.walkthrough \
        --ledger "$candidate_ledger_path" --artifact "$IPA_PATH" \
        --source-revision "$source_revision" --output "$walkthrough_path"
      walkthrough_digest="$(sha256_file "$walkthrough_path")"
    fi
    echo "==> Reusing prepared candidate evidence and IPA"
    persist_candidate_evidence \
      "$candidate_ledger_path" "$candidate_evidence_path" "$candidate_id" "$baseline_source_digest" \
      "$baseline_project_digest" "$artifact_digest" "$NEXT_BUILD" "$marketing_version" "$source_revision" \
      "$expected_mac_build" "$producer_evidence_digest" "$walkthrough_path" "$walkthrough_digest" "$producer_published_at" \
      "$candidate_workspace" "$IPA_PATH" 1
  fi
  candidate_receipt_path="${candidate_receipt_path:-$candidate_workspace/ios-artifact.json}"
  /usr/bin/python3 - "$candidate_receipt_path" "$artifact_digest" "$baseline_source_digest" "$baseline_project_digest" <<'PY'
import json
import os
import sys

path, artifact, source, project = sys.argv[1:]
payload = {"artifactSha256": artifact, "sourceSha256": source, "projectSha256": project}
os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as stream:
    json.dump(payload, stream, sort_keys=True)
    stream.write("\n")
os.chmod(temporary, 0o600)
os.replace(temporary, path)
PY
  failure_hook receipt-persistence
  transition_candidate_state "$candidate_ledger_path" uploading

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
  if xcrun altool --upload-package "$IPA_PATH" \
      -t ios \
      --api-key "$APP_STORE_CONNECT_KEY_ID" \
      --api-issuer "$APP_STORE_CONNECT_ISSUER_ID"; then
    transition_candidate_state "$candidate_ledger_path" uploaded_unassigned
  else
    # The transport may have accepted the package before returning a failure.
    # Preserve the candidate and require reconciliation instead of re-uploading.
    transition_candidate_state "$candidate_ledger_path" uploaded_unassigned || true
    return 1
  fi
  failure_hook assignment

  echo "==> Done. Candidate $candidate_id build $NEXT_BUILD uploaded -- Apple will take a few minutes to process it."
  echo "    Assignment is a separate attended step: provide the candidate ID, exact internal-group ID/name,"
  echo "    candidate ledger/evidence paths, and receipt-journal path to the assignment-only wrapper."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
