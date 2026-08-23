#!/usr/bin/env bash
# Bumps the build number, archives, and uploads GradusiOS straight to App
# Store Connect for TestFlight (T6.1 continuation). Requires
# APP_STORE_CONNECT_API_KEY (.p8 contents), APP_STORE_CONNECT_KEY_ID,
# APP_STORE_CONNECT_ISSUER_ID in the environment. The fixed BWS consumer is
# the only supported credential boundary; the same key serves the attended
# assignment and profile-renewal paths.
#
# Packages and uploads manually (codesign + ditto + a direct App Store
# Connect REST upload) instead of `xcodebuild -exportArchive`. That command
# fails with a generic `error: exportArchive Copy failed` on this project
# even with manual signing and a confirmed-good local private key --
# reproduced with -destination local-only (no App Store Connect interaction
# at all), so it's a packaging-step bug unrelated to signing/upload auth,
# and Xcode's own logs (IDEDistribution.verbose.log) give no further
# detail. Manually resigning the archived .app with the same identity and
# profile succeeds every time, and the resulting .ipa validated cleanly
# against ASC's real servers when this path was established, so that's the
# reliable path.
#
# The upload itself runs through app/asc_build_upload.py, which drives
# Apple's REST buildUploads flow. The API key is read from the environment
# into memory, used only to sign short-lived ES256 JWTs, and is never
# written to disk in any form -- so there is no key file to place, protect,
# or destroy on this path.
#
# Agent-safe upload path:
#   bws-secret-exec app-store-connect-upload --
# Human-attended invocation uses the same fixed consumer:
#   bws-secret-exec app-store-connect-upload -- app/archive-upload-ios.sh
# Upload-only resumes an existing prepared candidate and never creates one:
#   app/archive-upload-ios.sh --upload-only
# Assigned candidates are never replaced implicitly. An attended rollover must
# be explicit and include a non-empty reason:
#   app/archive-upload-ios.sh --rollover-assigned --supersession-reason "<reason>"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUDKIT_ENVIRONMENT_KEY="com.apple.developer.icloud-container-environment"
PRODUCER_EVIDENCE_FILENAME="publish-evidence.json"
ALLOWED_UNTRACKED_SOURCE_REPORT="verifications/2026-08-09-internal-testflight-candidate-migration-verification.md"
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
  local project_path="$1" mac_version ios_version widget_version
  mac_version="$(read_marketing_version "$project_path" GradusMac)"
  ios_version="$(read_marketing_version "$project_path" GradusiOS)"
  widget_version="$(read_marketing_version "$project_path" GradusWidget)"
  [[ -n "$mac_version" && "$mac_version" == "$ios_version" && "$ios_version" == "$widget_version" ]] || {
    echo "FAIL: Mac, iOS, and Widget marketing versions must match" >&2
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
  # The loop variable documents the fixed retry count; its value is unused.
  # shellcheck disable=SC2034
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
    echo "FAIL: source checkout is dirty; publish provenance from a clean revision" >&2
    return 1
  fi
}
snapshot_source_revision() {
  local injected="${GRADUS_SOURCE_REVISION:-}" revision
  if revision="$(/usr/bin/git -C "$1" rev-parse HEAD 2>/dev/null)"; then
    assert_source_checkout_clean "$1" || return 1
    [[ -n "$revision" ]] || {
      echo "FAIL: source revision is empty" >&2
      return 1
    }
    printf '%s\n' "$revision"
    return 0
  fi
  if [[ -n "${injected//[[:space:]]/}" ]]; then
    printf '%s\n' "$injected"
    return 0
  fi
  {
    echo "FAIL: source revision is unavailable (set GRADUS_SOURCE_REVISION for a non-Git checkout)" >&2
    return 1
  }
}
validate_resumed_source_revision() {
  local project_root="$1" expected_revision="$2" actual_revision
  actual_revision="$(snapshot_source_revision "$project_root")" || return 1
  [[ "$actual_revision" == "$expected_revision" ]] || {
    echo "FAIL: checked-out source revision changed since the prepared candidate" >&2
    return 1
  }
}

assert_digest_unchanged() {
  local label="$1" path="$2" expected="$3" actual
  actual="$(sha256_file "$path")"
  [[ "$actual" == "$expected" ]] || {
    echo "FAIL: $label changed during candidate preparation" >&2
    return 1
  }
}

create_candidate_workspace() {
  local project_root="$1" workspace rsync_bin
  workspace="${GRADUS_CANDIDATE_WORKSPACE:-$(mktemp -d "${TMPDIR:-/tmp}/gradus-ios-candidate.XXXXXX")}"
  mkdir -p "$workspace"
  if [[ -x /opt/homebrew/bin/rsync ]]; then
    rsync_bin=/opt/homebrew/bin/rsync
  elif command -v rsync >/dev/null 2>&1; then
    rsync_bin="$(command -v rsync)"
  else
    rsync_bin=/usr/bin/rsync
  fi
  "$rsync_bin" -a \
    --exclude='.git' --exclude='build' --exclude='.state' --exclude='.release-state' \
    --exclude='.venv' --exclude='verifications' --exclude='.ruff_cache' \
    --exclude='.pytest_cache' --exclude='.cache' --exclude='.build' \
    --exclude='DerivedData' --exclude='__pycache__' \
    "$project_root/" "$workspace/project/"
  printf '%s\n' "$workspace/project"
}

persist_identity_allocation() {
  local path="$1" candidate_id="$2" build="$3" marketing_version="$4"
  /usr/bin/python3 - "$SCRIPT_DIR" "$path" "$candidate_id" "$build" "$marketing_version" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from release_candidate.allocation import persist  # noqa: E402

persist(sys.argv[2], candidate_id=sys.argv[3], build=int(sys.argv[4]), marketing_version=sys.argv[5])
PY
}

consume_identity_allocation_proof() {
  local proof_path="$1" allocation_path="$2" marketing_version="$3" candidate_id="$4"
  /usr/bin/python3 - "$SCRIPT_DIR" "$proof_path" "$allocation_path" "$marketing_version" "$candidate_id" <<'PY'
import json
import re
import sys
from datetime import datetime

from pathlib import Path

script_dir, proof_path, allocation_path, expected_version, candidate_id = sys.argv[1:]
required = {
    "proofVersion", "operationClass", "result", "marketingVersion", "buildNumber",
    "responseSha256", "productKey", "remoteHighestMarketingVersion",
    "remoteHighestBuildNumber", "observedAt",
}
hex64 = re.compile(r"^[0-9a-f]{64}$")
semver = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")

def fail(message):
    print(f"FAIL: identity allocation proof {message}", file=sys.stderr)
    raise SystemExit(1)

try:
    with Path(proof_path).open(encoding="utf-8") as stream:
        proof = json.load(stream)
except (OSError, json.JSONDecodeError):
    fail("is missing or malformed")
if not isinstance(proof, dict) or set(proof) != required:
    fail("is missing or malformed")
if (
    proof["proofVersion"] != "1.0.0"
    or proof["operationClass"] != "identityAllocation"
    or proof["result"] != "passed"
    or proof["productKey"] != "gradus-ios"
    or not isinstance(proof["marketingVersion"], str)
    or not semver.fullmatch(proof["marketingVersion"])
    or proof["marketingVersion"] != expected_version
    or isinstance(proof["buildNumber"], bool)
    or not isinstance(proof["buildNumber"], int)
    or proof["buildNumber"] < 1
    or not isinstance(proof["responseSha256"], str)
    or not hex64.fullmatch(proof["responseSha256"])
    or proof["remoteHighestMarketingVersion"] is not None
    and (
        not isinstance(proof["remoteHighestMarketingVersion"], str)
        or not semver.fullmatch(proof["remoteHighestMarketingVersion"])
    )
    or isinstance(proof["remoteHighestBuildNumber"], bool)
    or not isinstance(proof["remoteHighestBuildNumber"], int)
    or proof["remoteHighestBuildNumber"] < 0
    or proof["buildNumber"] != proof["remoteHighestBuildNumber"] + 1
    or not isinstance(proof["observedAt"], str)
    or not proof["observedAt"].endswith("Z")
):
    fail("is mismatched or malformed")
try:
    observed_at = datetime.fromisoformat(proof["observedAt"][:-1] + "+00:00")
except ValueError:
    fail("is malformed")
if observed_at.tzinfo is None:
    fail("is malformed")

sys.path.insert(0, script_dir)
from release_candidate.allocation import CandidateError, load, persist  # noqa: E402

try:
    existing = load(allocation_path)
except CandidateError as exc:
    fail(str(exc))

if not candidate_id:
    candidate_id = existing.candidate_id if existing is not None else f"gradus-ios-{proof['buildNumber']}"
if not re.fullmatch(r"[A-Za-z0-9._-]+", candidate_id):
    fail("is mismatched or malformed")

try:
    if existing is None:
        record = persist(
            allocation_path,
            candidate_id=candidate_id,
            build=proof["buildNumber"],
            marketing_version=proof["marketingVersion"],
            allocated_at=proof["observedAt"],
        )
    else:
        if candidate_id and existing.candidate_id != candidate_id:
            fail("does not match durable allocation")
        if (
            existing.build != proof["buildNumber"]
            or existing.marketing_version != proof["marketingVersion"]
        ):
            fail("does not match durable allocation")
        record = existing
except CandidateError as exc:
    fail(str(exc))
print(f"candidateId\t{record.candidate_id}")
print(f"build\t{record.build}")
print(f"marketingVersion\t{record.marketing_version}")
PY
}

read_identity_allocation() {
  local path="$1"
  /usr/bin/python3 - "$SCRIPT_DIR" "$path" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from release_candidate.allocation import load  # noqa: E402

record = load(sys.argv[2])
if record is not None:
    print(f"candidateId\t{record.candidate_id}")
    print(f"build\t{record.build}")
    print(f"marketingVersion\t{record.marketing_version}")
PY
}

persist_upload_reconciliation() {
  local path="$1" candidate_id="$2" artifact_digest="$3" transport_status="$4"
  /usr/bin/python3 - "$path" "$candidate_id" "$artifact_digest" "$transport_status" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
payload = {
    "schemaVersion": "1.0.0",
    "operationClass": "upload",
    "candidateId": sys.argv[2],
    "artifactSha256": sys.argv[3],
    "result": "reconciliation-required",
    "reason": "upload-result-ambiguous",
    "transportExitCode": int(sys.argv[4]),
}

path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
try:
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(payload, stream, sort_keys=True, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
except Exception:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PY
}

persist_upload_outcome() {
  # An upload that was attempted but did not demonstrably succeed is
  # ambiguous: the transport can hand the package to Apple and still fail
  # afterwards, so a retry risks re-sending a build Apple already holds and
  # will reject on the duplicate build number. Leave a durable
  # reconciliation record instead of letting the ambiguity disappear.
  #
  # Installed on EXIT and on INT/TERM/HUP because an interrupt part-way
  # through a multi-minute transfer is exactly the ambiguous case, and a
  # signal would otherwise bypass the EXIT trap. The `! -e` guard makes the
  # signal handlers idempotent against the EXIT trap that follows them.
  local exit_status="${GRADUS_UPLOAD_FAILURE_STATUS:-$?}"
  if [[ "${GRADUS_UPLOAD_ATTEMPTED:-0}" -eq 1 && "${GRADUS_UPLOAD_SUCCEEDED:-0}" -eq 0 \
    && -n "${GRADUS_UPLOAD_RECONCILIATION_PATH:-}" \
    && ! -e "$GRADUS_UPLOAD_RECONCILIATION_PATH" ]]; then
    persist_upload_reconciliation "$GRADUS_UPLOAD_RECONCILIATION_PATH" \
      "${GRADUS_UPLOAD_CANDIDATE_ID:-}" "${GRADUS_UPLOAD_ARTIFACT_SHA256:-}" "$exit_status" \
      || echo "FAIL: upload reconciliation evidence could not be persisted" >&2
  fi
}

persist_upload_failure_diagnostics() {
  # Transport output is useful release evidence but is produced inside the
  # credential-bearing broker process, and a traceback out of the upload
  # subprocess can quote the environment it was handed. Redact exact
  # credential values before retaining the transcript in the candidate
  # workspace.
  local source_path="$1" destination_path="$2" transport_status="$3"
  /usr/bin/python3 - "$source_path" "$destination_path" "$transport_status" <<'PY'
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
text = source.read_text(encoding="utf-8", errors="replace")
for name in (
    "APP_STORE_CONNECT_API_KEY",
    "APP_STORE_CONNECT_KEY_ID",
    "APP_STORE_CONNECT_ISSUER_ID",
):
    value = os.environ.get(name, "")
    if value:
        text = text.replace(value, f"<redacted:{name}>")
body = (
    "operation: upload\n"
    f"transportExitCode: {int(sys.argv[3])}\n"
    f"observedAt: {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}\n"
    "stdout/stderr:\n"
    f"{text}"
)
if body and not body.endswith("\n"):
    body += "\n"
destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
descriptor, temporary = tempfile.mkstemp(prefix=f".{destination.name}.", dir=destination.parent)
try:
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(body)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, destination)
except Exception:
    try:
        os.unlink(temporary)
    except OSError:
        pass
    raise
PY
}

persist_delivery_receipt() {
  # Durable proof that Apple accepted these exact bytes, written the moment the
  # transfer returns and before any cleanup can fail. The 1.8.0 build 20 upload
  # succeeded at Apple and then lost its own outcome to a detach failure, which
  # left the candidate stuck and sent every retry back at a build Apple already
  # had. A receipt on disk is what makes the upload resumable instead: the next
  # run reads it and adopts the delivery rather than re-transferring.
  #
  # It records the artifact digest, not just the build number, so adoption is a
  # statement about bytes. "Some build 20 exists" is a different and much weaker
  # claim than "the artifact I hold was the one delivered".
  local path="$1" candidate_id="$2" marketing_version="$3" build="$4"
  local artifact_digest="$5" artifact_bytes="$6" delivery_uuid="$7"
  /usr/bin/python3 - "$path" "$candidate_id" "$marketing_version" "$build" \
    "$artifact_digest" "$artifact_bytes" "$delivery_uuid" <<'PY'
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

path = Path(sys.argv[1])
payload = {
    "schemaVersion": "1.0.0",
    "operationClass": "upload",
    "candidateId": sys.argv[2],
    "marketingVersion": sys.argv[3],
    "build": int(sys.argv[4]),
    "artifactSha256": sys.argv[5],
    "artifactBytes": int(sys.argv[6]),
    "result": "delivered",
    "deliveredAt": datetime.now(timezone.utc)
    .replace(microsecond=0)
    .isoformat()
    .replace("+00:00", "Z"),
}
# Apple does not always print a delivery UUID; its absence must not discard an
# otherwise-complete receipt, so it is recorded only when actually observed.
delivery_uuid = sys.argv[7].strip()
if delivery_uuid:
    payload["deliveryUuid"] = delivery_uuid
path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
try:
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(payload, stream, sort_keys=True, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
except Exception:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PY
}

delivery_receipt_matches() {
  # Succeeds only when the receipt describes this exact candidate, build, and
  # artifact. A receipt for a different digest is not a weaker match, it is a
  # different build, and adopting it would attest bytes that were never sent.
  local path="$1" candidate_id="$2" build="$3" artifact_digest="$4"
  [[ -f "$path" ]] || return 1
  /usr/bin/python3 - "$path" "$candidate_id" "$build" "$artifact_digest" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        receipt = json.load(stream)
except (OSError, ValueError):
    raise SystemExit(1)
if not isinstance(receipt, dict):
    raise SystemExit(1)
try:
    build_matches = int(receipt.get("build")) == int(sys.argv[3])
except (TypeError, ValueError):
    build_matches = False
raise SystemExit(
    0
    if (
        build_matches
        and receipt.get("candidateId") == sys.argv[2]
        and receipt.get("artifactSha256") == sys.argv[4]
        and receipt.get("result") == "delivered"
    )
    else 1
)
PY
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
  local ledger_path="$1" allow_assigned="${2:-0}"
  /usr/bin/python3 - "$SCRIPT_DIR" "$ledger_path" "$allow_assigned" <<'PY'
import sys

script_dir, ledger_path, allow_assigned = sys.argv[1:]
sys.path.insert(0, script_dir)
from release_candidate.ledger import CandidateLedger, CandidateError  # noqa: E402

try:
    record = CandidateLedger(ledger_path).load()
    blocked = {"uploading", "uploaded_unassigned"}
    if allow_assigned != "1":
        blocked.add("assigned")
    if record is not None and record.state in blocked:
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
  local supersedes_reason="${14:-}" archive_root="${15:-}"
  /usr/bin/python3 - "$SCRIPT_DIR" "$ledger_path" "$candidate_id" "$source_digest" "$project_digest" \
    "$artifact_digest" "$build" "$marketing_version" "$source_revision" "$producer_build" \
    "$producer_evidence_digest" "$producer_published_at" "$candidate_workspace" "$ipa_path" \
    "$supersedes_reason" "$archive_root" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from release_candidate.ledger import CandidateError, CandidateLedger  # noqa: E402

_, _, ledger_path, candidate_id, source_digest, project_digest, artifact_digest, build, marketing_version, source_revision, producer_build, producer_evidence_digest, producer_published_at, candidate_workspace, ipa_path, supersedes_reason, archive_root = sys.argv
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
        supersedes_reason=supersedes_reason or None,
        archive_root=archive_root or None,
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

validate_profile() {
  local profile_path="$1" expected_bundle_id="$2" expected_team="$3" expected_cert_sha1="$4" expected_app_group="$5"
  /usr/bin/python3 - "$profile_path" "$expected_bundle_id" "$expected_team" "$expected_cert_sha1" "$expected_app_group" <<'PY'
import datetime
import hashlib
import plistlib
import sys
from pathlib import Path

profile_path, expected_bundle_id, expected_team, expected_cert_sha1, expected_app_group = sys.argv[1:]

path = Path(profile_path)
if not path.is_file():
    print(f"FAIL: provisioning profile not found: {path}", file=sys.stderr)
    sys.exit(1)

content = path.read_bytes()
xml_start = content.find(b"<?xml")
xml_end = content.find(b"</plist>")
data = None
if xml_start != -1 and xml_end != -1:
    try:
        data = plistlib.loads(content[xml_start : xml_end + len(b"</plist>")])
    except Exception:
        pass

if data is None:
    try:
        data = plistlib.loads(content)
    except Exception:
        print(f"FAIL: provisioning profile '{path}' is malformed or cannot be parsed", file=sys.stderr)
        sys.exit(1)

# 1. Exact Bundle ID
entitlements = data.get("Entitlements", {})
app_id = entitlements.get("application-identifier", "")
expected_app_id = f"{expected_team}.{expected_bundle_id}"
if app_id != expected_app_id:
    if not app_id.startswith(f"{expected_team}."):
        print(f"FAIL: profile '{path.name}' team mismatch in application-identifier: expected prefix '{expected_team}.', got '{app_id}'", file=sys.stderr)
        sys.exit(1)
    print(f"FAIL: profile '{path.name}' bundle ID mismatch: expected '{expected_app_id}', got '{app_id}'", file=sys.stderr)
    sys.exit(1)

# 2. Team
team_id = entitlements.get("com.apple.developer.team-identifier")
team_list = data.get("TeamIdentifier", [])
if team_id != expected_team or expected_team not in team_list:
    print(f"FAIL: profile '{path.name}' team mismatch: expected '{expected_team}', got '{team_id}'", file=sys.stderr)
    sys.exit(1)

# 3. Certificate
cert_fingerprints = []
for cert_der in data.get("DeveloperCertificates", []):
    if isinstance(cert_der, (bytes, bytearray)):
        cert_fingerprints.append(hashlib.sha1(cert_der).hexdigest().upper())
if expected_cert_sha1.upper() not in cert_fingerprints:
    print(f"FAIL: profile '{path.name}' does not contain expected certificate '{expected_cert_sha1}'", file=sys.stderr)
    sys.exit(1)

# 4. App Group
app_groups = entitlements.get("com.apple.security.application-groups", [])
if not isinstance(app_groups, list) or expected_app_group not in app_groups:
    print(f"FAIL: profile '{path.name}' missing expected App Group '{expected_app_group}'", file=sys.stderr)
    sys.exit(1)

# 5. Distribution Type (App Store: get-task-allow is False, no ProvisionedDevices, not ProvisionsAllDevices)
get_task_allow = entitlements.get("get-task-allow")
if get_task_allow is not False:
    print(f"FAIL: profile '{path.name}' is not distribution (get-task-allow={get_task_allow})", file=sys.stderr)
    sys.exit(1)
if "ProvisionedDevices" in data:
    print(f"FAIL: profile '{path.name}' is not App Store distribution (contains ProvisionedDevices)", file=sys.stderr)
    sys.exit(1)
if data.get("ProvisionsAllDevices") is True:
    print(f"FAIL: profile '{path.name}' is Enterprise distribution (ProvisionsAllDevices=True)", file=sys.stderr)
    sys.exit(1)

# 6. Expiry
exp = data.get("ExpirationDate")
if not isinstance(exp, datetime.datetime):
    print(f"FAIL: profile '{path.name}' has no valid ExpirationDate", file=sys.stderr)
    sys.exit(1)
now = datetime.datetime.now(datetime.timezone.utc)
if exp.tzinfo is None:
    exp = exp.replace(tzinfo=datetime.timezone.utc)
if exp <= now:
    print(f"FAIL: profile '{path.name}' expired on {exp.isoformat()}", file=sys.stderr)
    sys.exit(1)
PY
}

resolve_provisioning_profile() {
  local bundle_id="$1" explicit_path="${2:-}"
  if [[ -n "$explicit_path" && -f "$explicit_path" ]]; then
    printf '%s\n' "$explicit_path"
    return 0
  fi
  local user_home profiles_dir
  user_home="$(resolve_user_home)" || return 1
  profiles_dir="${GRADUS_PROVISIONING_PROFILES_DIR:-$user_home/Library/MobileDevice/Provisioning Profiles}"

  if [[ "$bundle_id" == "com.zerodelta.gradus.ios" ]]; then
    for candidate in \
      "${GRADUS_IOS_APP_PROFILE_PATH:-}" \
      "$profiles_dir/gradus-ios-app-store.provisionprofile" \
      "$profiles_dir/gradus-ios-app-store.mobileprovision"; do
      if [[ -n "$candidate" && -f "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  elif [[ "$bundle_id" == "com.zerodelta.gradus.ios.widget" ]]; then
    for candidate in \
      "${GRADUS_IOS_WIDGET_PROFILE_PATH:-}" \
      "${GRADUS_WIDGET_PROFILE_PATH:-}" \
      "$profiles_dir/gradus-widget-app-store.provisionprofile" \
      "$profiles_dir/gradus-widget-app-store.mobileprovision" \
      "$profiles_dir/gradus-ios-widget-app-store.provisionprofile" \
      "$profiles_dir/gradus-ios-widget-app-store.mobileprovision"; do
      if [[ -n "$candidate" && -f "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  fi

  if [[ -d "$profiles_dir" ]]; then
    local matched_profile=""
    while IFS= read -r profile_candidate; do
      [[ -f "$profile_candidate" ]] || continue
      if /usr/bin/python3 - "$profile_candidate" "$bundle_id" <<'PY' >/dev/null 2>&1
import plistlib, sys
from pathlib import Path
c = Path(sys.argv[1]).read_bytes()
s, e = c.find(b"<?xml"), c.find(b"</plist>")
d = None
if s != -1 and e != -1:
    try:
        d = plistlib.loads(c[s : e + 8])
    except Exception:
        pass
if d is None:
    try:
        d = plistlib.loads(c)
    except Exception:
        sys.exit(1)
app_id = d.get("Entitlements", {}).get("application-identifier", "")
if app_id.endswith("." + sys.argv[2]) or app_id == sys.argv[2]:
    sys.exit(0)
sys.exit(1)
PY
      then
        matched_profile="$profile_candidate"
        break
      fi
    done < <(find "$profiles_dir" -maxdepth 1 \( -name "*.provisionprofile" -o -name "*.mobileprovision" \) 2>/dev/null | sort)
    if [[ -n "$matched_profile" ]]; then
      printf '%s\n' "$matched_profile"
      return 0
    fi
  fi

  echo "FAIL: could not locate App Store provisioning profile for $bundle_id" >&2
  return 1
}

locate_and_validate_distribution_profiles() {
  local app_profile_override="${1:-${GRADUS_IOS_APP_PROFILE_PATH:-}}"
  local widget_profile_override="${2:-${GRADUS_IOS_WIDGET_PROFILE_PATH:-}}"
  local expected_team="4CJ49V6QHW"
  local expected_cert_sha1="${SIGNING_IDENTITY:-FD247ACDEBCD05C725AE29B40218FB0F57807A2C}"
  local expected_app_group="group.com.zerodelta.gradus"

  local app_profile_path widget_profile_path
  app_profile_path="$(resolve_provisioning_profile "com.zerodelta.gradus.ios" "$app_profile_override")" || return 1
  widget_profile_path="$(resolve_provisioning_profile "com.zerodelta.gradus.ios.widget" "$widget_profile_override")" || return 1

  echo "==> Validating iOS app distribution profile ($app_profile_path)"
  validate_profile "$app_profile_path" "com.zerodelta.gradus.ios" "$expected_team" "$expected_cert_sha1" "$expected_app_group" || return 1

  echo "==> Validating iOS widget distribution profile ($widget_profile_path)"
  validate_profile "$widget_profile_path" "com.zerodelta.gradus.ios.widget" "$expected_team" "$expected_cert_sha1" "$expected_app_group" || return 1

  printf '%s\t%s\n' "$app_profile_path" "$widget_profile_path"
}

ensure_required_app_group() {
  local plist="$1" group="$2"
  /usr/bin/python3 - "$plist" "$group" <<'PY'
import plistlib, sys
from pathlib import Path
plist_path, group = sys.argv[1], sys.argv[2]
path = Path(plist_path)
try:
    data = plistlib.loads(path.read_bytes())
except Exception:
    data = {}
groups = data.setdefault("com.apple.security.application-groups", [])
if not isinstance(groups, list):
    groups = [groups]
    data["com.apple.security.application-groups"] = groups
if group not in groups:
    groups.append(group)
path.write_bytes(plistlib.dumps(data))
PY
}

assert_required_app_group() {
  local plist="$1" expected_group="$2"
  /usr/bin/python3 - "$plist" "$expected_group" <<'PY'
import plistlib, sys
from pathlib import Path
plist_path, expected_group = sys.argv[1], sys.argv[2]
try:
    data = plistlib.loads(Path(plist_path).read_bytes())
except Exception as e:
    print(f"FAIL: could not parse entitlements plist {plist_path}: {e}", file=sys.stderr)
    sys.exit(1)
groups = data.get("com.apple.security.application-groups", [])
if not isinstance(groups, list) or expected_group not in groups:
    print(f"FAIL: entitlements {plist_path} missing required App Group '{expected_group}'", file=sys.stderr)
    sys.exit(1)
PY
}

assert_no_disallowed_extension_entitlements() {
  local plist="$1"
  /usr/bin/python3 - "$plist" <<'PY'
import plistlib, sys
from pathlib import Path
plist_path = sys.argv[1]
try:
    data = plistlib.loads(Path(plist_path).read_bytes())
except Exception as e:
    print(f"FAIL: could not parse entitlements plist {plist_path}: {e}", file=sys.stderr)
    sys.exit(1)
disallowed_keys = [
    "com.apple.developer.icloud-container-identifiers",
    "com.apple.developer.icloud-services",
    "com.apple.developer.icloud-container-environment",
    "com.apple.developer.aps-environment",
    "aps-environment",
]
for key in disallowed_keys:
    if key in data:
        print(f"FAIL: extension leaked disallowed entitlement: '{key}'", file=sys.stderr)
        sys.exit(1)
PY
}

validate_bundle_version_parity() {
  local app_bundle="$1" extension_bundle="$2" expected_marketing="$3" expected_build="$4"
  local app_marketing app_build ext_marketing ext_build

  app_marketing="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app_bundle/Info.plist" 2>/dev/null)" || app_marketing=""
  app_build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app_bundle/Info.plist" 2>/dev/null)" || app_build=""
  ext_marketing="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$extension_bundle/Info.plist" 2>/dev/null)" || ext_marketing=""
  ext_build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$extension_bundle/Info.plist" 2>/dev/null)" || ext_build=""

  [[ -n "$app_marketing" && "$app_marketing" == "$expected_marketing" ]] || {
    echo "FAIL: app CFBundleShortVersionString is '$app_marketing', expected '$expected_marketing'" >&2
    return 1
  }
  [[ -n "$app_build" && "$app_build" == "$expected_build" ]] || {
    echo "FAIL: app CFBundleVersion is '$app_build', expected '$expected_build'" >&2
    return 1
  }
  [[ -n "$ext_marketing" && "$ext_marketing" == "$expected_marketing" ]] || {
    echo "FAIL: extension CFBundleShortVersionString is '$ext_marketing', expected '$expected_marketing'" >&2
    return 1
  }
  [[ -n "$ext_build" && "$ext_build" == "$expected_build" ]] || {
    echo "FAIL: extension CFBundleVersion is '$ext_build', expected '$expected_build'" >&2
    return 1
  }
  [[ "$app_marketing" == "$ext_marketing" && "$app_build" == "$ext_build" ]] || {
    echo "FAIL: marketing version or build number drift between app and extension" >&2
    return 1
  }
}

repackage_and_sign_ios_candidate() {
  local archive_path="$1" package_dir="$2" app_profile_path="$3" widget_profile_path="$4"
  local signing_identity="$5" expected_cloudkit_environment="$6" marketing_version="$7" next_build="$8"

  mkdir -p "$package_dir/Payload"
  cp -R "$archive_path/Products/Applications/GradusiOS.app" "$package_dir/Payload/GradusiOS.app"

  local app_bundle="$package_dir/Payload/GradusiOS.app"
  local plugins_dir="$app_bundle/PlugIns"
  local widget_bundle="$plugins_dir/GradusWidget.appex"

  # 1. Require exactly one GradusWidget.appex
  [[ -d "$plugins_dir" ]] || {
    echo "FAIL: PlugIns directory is missing from GradusiOS.app" >&2
    return 1
  }
  [[ -d "$widget_bundle" ]] || {
    echo "FAIL: GradusWidget.appex is missing from PlugIns" >&2
    return 1
  }
  local appex_count
  appex_count="$(find "$plugins_dir" -mindepth 1 -maxdepth 1 -name "*.appex" | wc -l | tr -d ' ')"
  [[ "$appex_count" -eq 1 ]] || {
    echo "FAIL: expected exactly 1 .appex in PlugIns, found $appex_count" >&2
    return 1
  }

  # 2. Embed each profile into its own bundle
  cp "$app_profile_path" "$app_bundle/embedded.mobileprovision"
  cp "$widget_profile_path" "$widget_bundle/embedded.mobileprovision"

  # 3. Derive and assert exact entitlements for extension
  xattr -cr "$widget_bundle"
  codesign -d --entitlements :- "$widget_bundle" 2>/dev/null \
    | plutil -convert xml1 -o "$package_dir/widget-entitlements.plist" - 2>/dev/null || {
      echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict/></plist>" > "$package_dir/widget-entitlements.plist"
    }
  set_required_entitlement "$package_dir/widget-entitlements.plist" get-task-allow bool false || return 1
  assert_required_entitlement "$package_dir/widget-entitlements.plist" get-task-allow false || return 1
  ensure_required_app_group "$package_dir/widget-entitlements.plist" "group.com.zerodelta.gradus" || return 1
  assert_required_app_group "$package_dir/widget-entitlements.plist" "group.com.zerodelta.gradus" || return 1
  assert_no_disallowed_extension_entitlements "$package_dir/widget-entitlements.plist" || return 1

  # 4. Sign extension FIRST
  echo "==> Signing GradusWidget.appex"
  codesign --force --sign "$signing_identity" \
    --entitlements "$package_dir/widget-entitlements.plist" --generate-entitlement-der --timestamp \
    "$widget_bundle" || return 1
  xattr -cr "$widget_bundle"

  # 5. Derive and assert exact entitlements for main app
  xattr -cr "$app_bundle"
  codesign -d --entitlements :- "$app_bundle" 2>/dev/null \
    | plutil -convert xml1 -o "$package_dir/entitlements.plist" - || return 1
  set_required_entitlement "$package_dir/entitlements.plist" get-task-allow bool false || return 1
  set_required_entitlement "$package_dir/entitlements.plist" aps-environment string production || return 1
  set_required_entitlement "$package_dir/entitlements.plist" "$CLOUDKIT_ENVIRONMENT_KEY" string "$expected_cloudkit_environment" || return 1
  assert_required_entitlement "$package_dir/entitlements.plist" aps-environment production || return 1
  assert_required_entitlement "$package_dir/entitlements.plist" "$CLOUDKIT_ENVIRONMENT_KEY" "$expected_cloudkit_environment" || return 1
  ensure_required_app_group "$package_dir/entitlements.plist" "group.com.zerodelta.gradus" || return 1
  assert_required_app_group "$package_dir/entitlements.plist" "group.com.zerodelta.gradus" || return 1

  # 6. Sign main app LAST
  echo "==> Signing GradusiOS.app"
  codesign --force --sign "$signing_identity" \
    --entitlements "$package_dir/entitlements.plist" --generate-entitlement-der --timestamp \
    "$app_bundle" || return 1
  xattr -cr "$app_bundle"
  failure_hook signing

  # 7. Verify signatures
  echo "==> Verifying signatures"
  codesign --verify --deep --strict "$widget_bundle" || return 1
  codesign --verify --deep --strict "$app_bundle" || return 1

  # 8. Verify marketing and build version parity
  echo "==> Verifying app and extension version parity"
  validate_bundle_version_parity "$app_bundle" "$widget_bundle" "$marketing_version" "$next_build" || return 1
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
  [[ -n "$expected_source" && -n "$expected_project" ]] || {
    echo "FAIL: producer evidence boundary is missing source/project expectations" >&2
    return 1
  }
  validate_producer_evidence "$evidence_path" "$expected_build" "$expected_environment"
  actual_source="$(read_evidence_field sourceRevision "$evidence_path" 2>/dev/null || true)"
  [[ -n "$actual_source" && "$actual_source" == "$expected_source" ]] || {
    echo "FAIL: producer evidence source revision is missing or mismatched" >&2
    return 1
  }
  actual_project="$(read_evidence_field projectSha256 "$evidence_path" 2>/dev/null || true)"
  [[ -n "$actual_project" && "$actual_project" == "$expected_project" ]] || {
    echo "FAIL: producer evidence project digest is missing or mismatched" >&2
    return 1
  }
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

restore_account_environment() {
  # The fixed BWS consumer starts children with a minimal environment. uv,
  # xcodebuild, and the provisioning-profile lookup all need a real HOME, so
  # restore it from the local account record rather than whatever the broker
  # passed down. Idempotent, and called from both the build path and the
  # --upload-only resume path -- only one of those runs a build, but both now
  # run uv.
  local account_home account_user
  account_home="$(resolve_user_home)" || return 1
  account_user="$(resolve_user_name)" || return 1
  export HOME="$account_home"
  export USER="$account_user"
  export LOGNAME="$account_user"
}

resolve_user_name() {
  /usr/bin/id -un
}

bump_target_build_number() {
  local target="$1" next_build="$2"
  local project_path="${3:-project.yml}"
  local target_pattern
  target_pattern="/^  ${target}:/,/^  [A-Za-z0-9_]+:/ s/(CURRENT_PROJECT_VERSION: )\"[0-9]+\"/\\1\"$next_build\"/"
  sed -i '' -E "$target_pattern" "$project_path"
}

bump_build_number() {
  bump_target_build_number "$@"
}

bump_ios_build_number() {
  local next_build="$1"
  local project_path="${2:-project.yml}"
  bump_target_build_number GradusiOS "$next_build" "$project_path"
  bump_target_build_number GradusWidget "$next_build" "$project_path"
}

main() {
  local prepare_only=0 upload_only=0 rollover_assigned=0 supersession_reason="" requested_candidate_id=""
  while (($# > 0)); do
    case "$1" in
      --prepare-only) prepare_only=1 ;;
      --upload-only) upload_only=1 ;;
      --candidate)
        (($# >= 2)) || {
          echo "FAIL: --candidate requires a non-empty candidate ID" >&2
          return 64
        }
        requested_candidate_id="$2"
        [[ "$requested_candidate_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || {
          echo "FAIL: --candidate contains unsupported characters" >&2
          return 64
        }
        shift
        ;;
      --rollover-assigned) rollover_assigned=1 ;;
      --supersession-reason)
        (($# >= 2)) || {
          echo "FAIL: --supersession-reason requires a non-empty reason" >&2
          return 64
        }
        supersession_reason="$2"
        shift
        ;;
      -h | --help)
        sed -n '2,28p' "${BASH_SOURCE[0]}"
        echo "Options:"
        echo "  --prepare-only                              prepare and persist a resumable candidate without uploading"
        echo "  --upload-only                                upload only the existing prepared candidate"
        echo "  --candidate <id>                             require this exact prepared candidate"
        echo "  --rollover-assigned                         archive the assigned candidate before replacement"
        echo "  --supersession-reason <reason>              record why the assigned candidate is superseded"
        return 0
        ;;
      *)
        echo "FAIL: unknown argument: $1" >&2
        return 64
        ;;
    esac
    shift
  done
  if (( rollover_assigned )) && [[ -z "${supersession_reason//[[:space:]]/}" ]]; then
    echo "FAIL: --rollover-assigned requires --supersession-reason" >&2
    return 64
  fi
  if (( ! rollover_assigned )) && [[ -n "$supersession_reason" ]]; then
    echo "FAIL: --supersession-reason requires --rollover-assigned" >&2
    return 64
  fi
  # The central adapter still invokes this fixed legacy entrypoint for each
  # pre-upload operation. The first invocation enters the candidate-aware
  # bridge, which prepares once and emits all four immutable proofs. Its child
  # sets the marker below so the actual archive implementation runs exactly
  # once instead of recursing back through the bridge.
  if (( prepare_only )) \
      && [[ "${GRADUS_RELEASE_BRIDGE_ACTIVE:-0}" != "1" ]] \
      && [[ -z "${HOME:-}" && -z "${USER:-}" && -z "${LOGNAME:-}" ]]; then
    exec /usr/bin/python3 "$SCRIPT_DIR/release_prepare_bridge.py" --operation all
  fi
  cd "$SCRIPT_DIR"
  local project_root evidence_path expected_mac_build expected_cloudkit_environment expected_project_digest
  local baseline_source_digest baseline_project_digest current_artifact_digest actual_source_digest candidate_root candidate_script_dir candidate_receipt_path uv_bin
  local candidate_workspace candidate_ledger_path candidate_evidence_path walkthrough_path candidate_id source_revision producer_published_at
  local producer_evidence_digest artifact_digest marketing_version walkthrough_digest candidate_ipa_path durable_ipa_path prepared_metadata resume_candidate=0
  local allocation_record_path identity_proof_path allocation_metadata candidate_id_hint
  project_root="$(cd .. && pwd)"
  evidence_path="$(resolve_producer_evidence_path)" || return 1
  candidate_ledger_path="${GRADUS_CANDIDATE_LEDGER_PATH:-$project_root/.release-state/candidate.json}"
  candidate_evidence_path="${GRADUS_CANDIDATE_EVIDENCE_PATH:-}"
  walkthrough_path="${GRADUS_WALKTHROUGH_PATH:-}"
  candidate_receipt_path="${GRADUS_CANDIDATE_RECEIPT_PATH:-}"
  allocation_record_path="${GRADUS_IDENTITY_ALLOCATION_PATH:-$project_root/.release-state/allocated-ios.json}"
  identity_proof_path="${GRADUS_IDENTITY_ALLOCATION_PROOF_PATH:-$project_root/.release-state/evidence/allocate-identity.json}"
  expected_mac_build="$(read_mac_build_number project.yml)"
  expected_cloudkit_environment="$(read_cloudkit_environment "$SCRIPT_DIR/GradusMac/GradusMacProduction.entitlements")"
  echo "==> Reading producer evidence from $evidence_path"
  if (( ! prepare_only )); then
    : "${APP_STORE_CONNECT_API_KEY:?required}"
    : "${APP_STORE_CONNECT_KEY_ID:?required}"
    : "${APP_STORE_CONNECT_ISSUER_ID:?required}"
  fi
  # The live tree's marketing version is what a new candidate would be built
  # from, so it is validated on the prepare path only. On --upload-only the
  # version being shipped is already frozen in the candidate ledger and is not
  # read from the tree, which is why this was previously exempted for one
  # hardcoded candidate ID rather than for the resume path it actually blocks.
  if (( ! upload_only )); then
    validate_common_marketing_version "$SCRIPT_DIR/project.yml"
  fi
  assert_candidate_not_in_flight "$candidate_ledger_path" "$rollover_assigned"
  prepared_metadata="$(read_prepared_candidate "$candidate_ledger_path")"
  if (( upload_only )) && [[ -z "$prepared_metadata" ]]; then
    echo "FAIL: --upload-only requires an existing prepared candidate" >&2
    return 3
  fi
  if [[ -n "$prepared_metadata" ]]; then
    resume_candidate=1
    while IFS=$'\t' read -r metadata_key metadata_value; do
      case "$metadata_key" in
        candidateId) candidate_id="$metadata_value"; candidate_id_hint="$metadata_value" ;;
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
    if [[ -n "$requested_candidate_id" && "$requested_candidate_id" != "$candidate_id" ]]; then
      echo "FAIL: requested candidate does not match the prepared candidate" >&2
      return 1
    fi
    [[ -n "${candidate_ipa_path:-}" && -n "${candidate_id:-}" && -n "${artifact_digest:-}" ]] || {
      echo "FAIL: prepared candidate metadata is incomplete" >&2
      return 1
    }
    if (( ! upload_only )); then
      validate_resumed_source_revision "$project_root" "$source_revision" || return 1
    fi
    IPA_PATH="$candidate_ipa_path"
    echo "==> Resuming prepared candidate $candidate_id build $NEXT_BUILD"
  fi
  if [[ "$resume_candidate" -eq 0 ]]; then
  # Resolve and validate the producer tuple before allocation. The source
  # freeze itself occurs below, after the ASC identity is durable.
  source_revision="$(snapshot_source_revision "$project_root")" || {
    echo "FAIL: could not resolve the checked-out source revision" >&2
    return 1
  }
  expected_project_digest="$(snapshot_project_digest "$SCRIPT_DIR/project.yml")"
  echo "==> Validating producer evidence before candidate allocation"
  validate_producer_evidence_boundary "$evidence_path" "$expected_mac_build" "$expected_cloudkit_environment" "$source_revision" "$expected_project_digest"
  candidate_root="$(create_candidate_workspace "$project_root")"
  candidate_workspace="$(dirname "$candidate_root")"
  candidate_script_dir="$candidate_root/app"
  failure_hook allocation

  restore_account_environment
  uv_bin="$(resolve_uv)"

  # Pin the certificate fingerprint that is actually embedded in the checked-
  # in API-created distribution profile.  A bare "Apple Distribution" lets
  # Xcode choose a different installed distribution certificate when more than
  # one exists, which the profile rejects.
  SIGNING_IDENTITY="FD247ACDEBCD05C725AE29B40218FB0F57807A2C"
  echo "==> Locating and validating App Store distribution profiles"
  local validated_profiles app_profile_path widget_profile_path
  validated_profiles="$(locate_and_validate_distribution_profiles)" || return 1
  app_profile_path="$(printf '%s\n' "$validated_profiles" | cut -f1)"
  widget_profile_path="$(printf '%s\n' "$validated_profiles" | cut -f2)"

  ARCHIVE_PATH="$candidate_script_dir/build/GradusiOS.xcarchive"
  PACKAGE_DIR="$candidate_script_dir/build/package-ios"

  marketing_version="$(read_marketing_version "$candidate_script_dir/project.yml" GradusiOS)"
  if (( prepare_only )); then
    echo "==> Consuming typed identity allocation proof from $identity_proof_path"
    allocation_metadata="$(consume_identity_allocation_proof "$identity_proof_path" "$allocation_record_path" \
      "$marketing_version" "${GRADUS_CANDIDATE_ID:-}")" || return 1
  else
    allocation_metadata="$(read_identity_allocation "$allocation_record_path")"
    if [[ -z "$allocation_metadata" ]]; then
      echo "==> Determining next build number from App Store Connect"
      NEXT_BUILD="$(cd "$candidate_script_dir" && "$uv_bin" run --with pyjwt --with cryptography next-ios-build-number.py)"
      candidate_id_hint="${GRADUS_CANDIDATE_ID:-gradus-ios-${NEXT_BUILD}}"
      persist_identity_allocation "$allocation_record_path" "$candidate_id_hint" "$NEXT_BUILD" "$marketing_version"
      allocation_metadata="$(read_identity_allocation "$allocation_record_path")"
    else
      echo "==> Resuming allocated iOS identity without a second allocation"
    fi
  fi
  while IFS=$'\t' read -r metadata_key metadata_value; do
    case "$metadata_key" in
      candidateId) candidate_id_hint="$metadata_value" ;;
      build) NEXT_BUILD="$metadata_value" ;;
      marketingVersion) marketing_version="$metadata_value" ;;
    esac
  done <<< "$allocation_metadata"
  [[ -n "${NEXT_BUILD:-}" && -n "${candidate_id_hint:-}" ]] || {
    echo "FAIL: identity allocation record is incomplete" >&2
    return 1
  }
  echo "    Next CURRENT_PROJECT_VERSION: $NEXT_BUILD"
  # Only the isolated candidate copy is edited; the checked-out project is
  # never rewritten after the identity is allocated.
  bump_ios_build_number "$NEXT_BUILD" "$candidate_script_dir/project.yml"
  failure_hook after-allocation

  echo "==> Regenerating Xcode project from project.yml"
  (cd "$candidate_script_dir" && xcodegen generate)

  echo "==> Freezing source and candidate project after identity allocation"
  baseline_source_digest="$(snapshot_source_digest "$project_root")"
  baseline_project_digest="$expected_project_digest"
  export GRADUS_SOURCE_FROZEN=1

  rm -rf "$ARCHIVE_PATH" "$PACKAGE_DIR"

  echo "==> Archiving GradusiOS (build $NEXT_BUILD)"
  (cd "$candidate_script_dir" && xcodebuild archive \
    -project Gradus.xcodeproj \
    -scheme GradusiOS \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=iOS" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY")
  failure_hook archive

  echo "==> Repackaging for App Store distribution (nested manual codesign)"
  repackage_and_sign_ios_candidate "$ARCHIVE_PATH" "$PACKAGE_DIR" "$app_profile_path" "$widget_profile_path" \
    "$SIGNING_IDENTITY" "$expected_cloudkit_environment" "$marketing_version" "$NEXT_BUILD"

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
  validate_producer_evidence_boundary "$evidence_path" "$expected_mac_build" "$expected_cloudkit_environment" "$source_revision" "$baseline_project_digest"

  artifact_digest="$(sha256_file "$IPA_PATH")"
  candidate_id="${candidate_id_hint:-${GRADUS_CANDIDATE_ID:-gradus-ios-${NEXT_BUILD}-${artifact_digest:0:16}}}"
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
  producer_published_at="$(read_evidence_field publishedAt "$evidence_path")"
  producer_evidence_digest="$(sha256_file "$evidence_path")"
  marketing_version="$(read_marketing_version "$candidate_script_dir/project.yml" GradusiOS)"
  echo "==> Persisting machine-written candidate ledger before walkthrough generation"
  prepare_candidate_ledger "$candidate_ledger_path" "$candidate_id" "$baseline_source_digest" "$baseline_project_digest" \
    "$artifact_digest" "$NEXT_BUILD" "$marketing_version" "$source_revision" "$expected_mac_build" "$producer_evidence_digest" \
    "$producer_published_at" "$candidate_workspace" "$IPA_PATH" "$supersession_reason" \
    "$project_root/.release-state/archived"
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
    # A prepared candidate is a frozen, signed artifact. What must be proven
    # before transferring it is that the IPA on disk is still bit-for-bit the
    # one that was attested -- not that the working tree has stood still.
    # Pinning the checked-out project.yml here meant any later edit invalidated
    # an already-built candidate the edit could not have changed, including
    # edits to this release tooling itself. The frozen baseline still governs
    # the producer-evidence boundary check immediately below.
    current_artifact_digest="$(sha256_file "$IPA_PATH")"
    [[ "$current_artifact_digest" == "$artifact_digest" ]] || {
      echo "FAIL: prepared artifact no longer matches its attested digest" >&2
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
  if (( prepare_only )); then
    echo "==> Prepared candidate $candidate_id build $NEXT_BUILD; upload deferred"
    return 0
  fi

  # Adopt a delivery Apple already accepted instead of re-sending it. Apple
  # rejects a duplicate build number, so a second transfer of a delivered
  # candidate cannot succeed -- it can only fail and strand the candidate
  # again. The receipt is matched on the artifact digest, so this adopts the
  # exact delivered bytes and never a merely same-numbered build.
  #
  # Deliberately ahead of the credential preflight below: adopting an existing
  # receipt needs no App Store Connect credential at all, so a candidate Apple
  # already accepted stays adoptable even when no usable key is present.
  if delivery_receipt_matches "${candidate_workspace}/upload-delivery.json" \
      "$candidate_id" "$NEXT_BUILD" "$artifact_digest"; then
    echo "==> Candidate $candidate_id build $NEXT_BUILD was already delivered to App Store Connect; adopting the existing receipt"
    echo "==> Done. Candidate $candidate_id build $NEXT_BUILD uploaded -- Apple will take a few minutes to process it."
    return 0
  fi

  export GRADUS_UPLOAD_RECONCILIATION_PATH="${candidate_workspace}/upload-reconciliation.json"
  export GRADUS_UPLOAD_DELIVERY_RECEIPT_PATH="${candidate_workspace}/upload-delivery.json"
  export GRADUS_UPLOAD_ATTEMPTED=0 GRADUS_UPLOAD_SUCCEEDED=0
  export GRADUS_UPLOAD_CANDIDATE_ID="$candidate_id"
  export GRADUS_UPLOAD_ARTIFACT_SHA256="$artifact_digest"
  trap 'persist_upload_outcome' EXIT
  trap 'persist_upload_outcome; exit 130' INT
  trap 'persist_upload_outcome; exit 143' TERM
  trap 'persist_upload_outcome; exit 129' HUP
  # Keep the delivery log and the receipt written below owner-only.
  umask 077

  # A credential that cannot sign must fail while the candidate is still
  # retryable. The transport mints its own tokens in-process, but only after
  # the "uploading" transition below, and that state forward-transitions to
  # failed/abandoned only -- so a malformed key first discovered inside the
  # transport would strand the candidate rather than leave it prepared. Mint
  # one here, where the failure is unambiguously local. Output is discarded
  # rather than logged: a signing error can quote the key material it failed
  # to parse, and this runs before the redacting diagnostics writer exists.
  # --upload-only resumes a prepared candidate without entering the build
  # branch, which is where the account environment is restored and uv is
  # resolved. Both are needed here now that the transport runs through uv, and
  # both are idempotent, so do them on every path that reaches the upload.
  restore_account_environment
  if [[ -z "$uv_bin" ]]; then
    uv_bin="$(resolve_uv)"
  fi

  if ! (cd "$SCRIPT_DIR" && "$uv_bin" run --with pyjwt --with cryptography \
      python -c 'import _asc_api; _asc_api.make_token()') >/dev/null 2>&1; then
    echo "FAIL: App Store Connect credentials did not produce a signed token" >&2
    return 1
  fi

  # Record "uploading" only once local pre-flight work (packaging, token
  # signing) has succeeded and the next step is the network call itself.
  # A failure before this point is unambiguously local-only and must leave
  # the candidate in a retryable "prepared" state rather than stranding it
  # in "uploading", which only forward-transitions to failed/abandoned.
  # The transport's first network call is a non-mutating app lookup, so the
  # first request that can change anything at Apple is the build-upload
  # reservation, strictly after this point.
  transition_candidate_state "$candidate_ledger_path" uploading

  echo "==> Uploading to App Store Connect"
  export GRADUS_UPLOAD_ATTEMPTED=1
  local delivery_log delivery_uuid artifact_bytes upload_status
  # The transport reports per-chunk progress as it runs and the delivery id
  # Apple assigns on its final line. Tee the merged stream so the receipt
  # below can quote Apple's own confirmation while the operator still sees
  # transfer progress live -- a plain redirect would buffer a multi-minute
  # upload into silence. `set -o pipefail` (line 29) is what makes the
  # transport's exit status rather than tee's decide the branch below.
  # Invoked by absolute path, with no `cd`, so every path argument stays
  # resolved against the caller's directory; Python still puts the script's
  # own directory on sys.path, which is how it reaches _asc_api.
  #
  # Deliberately $SCRIPT_DIR and not the candidate checkout: the transport is
  # release tooling, not a build input. Gradus declares its source scope as
  # app/GradusiOS, app/Shared, app/GradusKit and app/project.yml, so this file
  # is outside it by design -- and the candidate checkout is not resolved at
  # all on the --upload-only path.
  delivery_log="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/gradus-delivery.XXXXXX")"
  if "$uv_bin" run --with pyjwt --with cryptography \
      "$SCRIPT_DIR/asc_build_upload.py" \
      --ipa-path "$IPA_PATH" \
      --marketing-version "$marketing_version" \
      --build "$NEXT_BUILD" 2>&1 | tee "$delivery_log"; then
    export GRADUS_UPLOAD_SUCCEEDED=1
  else
    # The transport may have accepted the package before returning a failure.
    # Preserve the candidate and require reconciliation instead of re-uploading.
    upload_status=$?
    export GRADUS_UPLOAD_FAILURE_STATUS="$upload_status"
    if persist_upload_failure_diagnostics "$delivery_log" \
        "${candidate_workspace}/upload-failure.log" "$upload_status"; then
      echo "    Diagnostic output preserved at ${candidate_workspace}/upload-failure.log" >&2
    else
      echo "FAIL: upload diagnostic output could not be persisted" >&2
    fi
    rm -f "$delivery_log"
    persist_upload_outcome
    trap - EXIT INT TERM HUP
    return "$upload_status"
  fi
  # Persist the receipt before anything else can fail. Every step after this
  # point -- detach, attestation, the exit trap -- has already been observed to
  # fail on a delivered build, and each one of those failures used to erase the
  # only record that the delivery happened.
  # Apple's buildUploads ids are opaque and not necessarily hex, so match any
  # non-space token rather than the hex-and-dash class this line inherited
  # from the previous transport's output format. It is optional metadata
  # -- adoption matches candidateId + build + artifactSha256 + result, never
  # this -- but letting the pattern silently miss would discard Apple's only
  # confirmation identifier from the evidence record.
  delivery_uuid="$(/usr/bin/sed -n \
    's/.*Delivery UUID: *\([^[:space:]][^[:space:]]*\).*/\1/p' "$delivery_log" | /usr/bin/head -n 1)"
  artifact_bytes="$(/usr/bin/stat -f %z "$IPA_PATH" 2>/dev/null || printf '0')"
  rm -f "$delivery_log"
  persist_delivery_receipt "$GRADUS_UPLOAD_DELIVERY_RECEIPT_PATH" \
    "$candidate_id" "$marketing_version" "$NEXT_BUILD" \
    "$artifact_digest" "$artifact_bytes" "$delivery_uuid"
  # The delivery is recorded, so nothing downstream is ambiguous any more.
  # GRADUS_UPLOAD_SUCCEEDED already makes the handler a no-op; dropping the
  # traps here keeps that from depending on one exported variable.
  trap - EXIT INT TERM HUP
  failure_hook assignment

  echo "==> Done. Candidate $candidate_id build $NEXT_BUILD uploaded -- Apple will take a few minutes to process it."
  echo "    Assignment is a separate attended step: provide the candidate ID, exact internal-group ID/name,"
  echo "    candidate ledger/evidence paths, and receipt-journal path to the assignment-only wrapper."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
