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

persist_ram_volume_attestation() {
  local path="$1" candidate_id="$2" mount_digest="$3" detach_digest="$4" volume_id="$5" filesystem="$6"
  /usr/bin/python3 - "$SCRIPT_DIR" "$path" "$candidate_id" "$mount_digest" "$detach_digest" "$volume_id" "$filesystem" <<'PY'
import json
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from release_candidate.ram_volume import validate  # noqa: E402

path = Path(sys.argv[2])
payload = {
    "proofVersion": "release.proof.ram-volume.v1",
    "operationClass": "ram-volume",
    "candidateId": sys.argv[3],
    "mountEvidenceSha256": sys.argv[4],
    "detachEvidenceSha256": sys.argv[5],
    "volumeId": sys.argv[6],
    "filesystem": sys.argv[7],
    "diskBacked": False,
    "detached": True,
    "result": "passed",
}
validate(payload)
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

persist_cleanup_leak_evidence() {
  # Raised when the transfer succeeded but the key volume could not be
  # detached. The upload's outcome owns the exit code (see
  # cleanup_ram_key_volume), so this file -- not the status -- is what carries
  # the secret-hygiene condition forward.
  local status="$1" path workspace
  workspace="${GRADUS_RAM_VOLUME_ATTESTATION_PATH:-}"
  workspace="${workspace%/*}"
  [[ -n "$workspace" && -d "$workspace" ]] || return 0
  path="${workspace}/ram-volume-leak.json"
  /usr/bin/python3 - "$path" "${GRADUS_RAM_VOLUME_CANDIDATE_ID:-}" \
    "${RAM_VOLUME_DEVICE:-}" "${RAM_VOLUME_MOUNTPOINT:-}" "$status" \
    "${RAM_VOLUME_KEY_DESTROYED:-0}" <<'PY' || return 0
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

path = Path(sys.argv[1])
payload = {
    "schemaVersion": "1.0.0",
    "operationClass": "cleanup",
    "candidateId": sys.argv[2],
    "device": sys.argv[3],
    "mountpoint": sys.argv[4],
    "cleanupExitCode": int(sys.argv[5]),
    # The field that says whether a stranded volume is an actual credential
    # exposure or merely 2 MB of empty RAM awaiting the next reboot.
    "keyMaterialDestroyed": sys.argv[6] == "1",
    "result": "key-volume-not-detached",
    "reason": "upload-succeeded-cleanup-failed",
    "remediation": "detach the RAM-backed key volume; it clears on reboot",
    "observedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
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
    except OSError:
        pass
    raise
PY
  return 0
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

persist_upload_failure_diagnostics() {
  # altool output is useful release evidence but is produced inside the
  # credential-bearing broker process. Redact exact credential values before
  # retaining the transcript in the candidate workspace.
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

create_ram_key_volume() {
  local mountpoint device mount_record mount_type
  if [[ -n "${GRADUS_RAM_VOLUME_MOUNT_PATH:-}" || -n "${GRADUS_TEST_KEY_LOG:-}" ]]; then
    # Hermetic tests provide a declared RAM-volume fixture. The fixture is
    # explicit and never becomes a production disk-backed fallback.
    if [[ -n "${GRADUS_RAM_VOLUME_MOUNT_PATH:-}" ]]; then
      mountpoint="$GRADUS_RAM_VOLUME_MOUNT_PATH"
    else
      mountpoint="$(mktemp -d "${TMPDIR:-/tmp}/gradus-test-ram-volume.XXXXXX")"
    fi
    mkdir -p "$mountpoint"
    device="${GRADUS_RAM_VOLUME_DEVICE:-fixture-ram-volume}"
    mount_type="${GRADUS_RAM_VOLUME_FILESYSTEM:-hfs}"
    [[ "${GRADUS_RAM_VOLUME_DISK_BACKED:-false}" != "true" ]] || {
      echo "FAIL: disk-backed key volume fixture was rejected" >&2
      return 1
    }
  else
    mountpoint="$(mktemp -d "${TMPDIR:-/tmp}/gradus-ios-key-volume.XXXXXX")"
    device="$(hdiutil attach -nomount ram://4096 | /usr/bin/awk 'NF {value=$NF} END {print value}')"
    [[ "$device" == /dev/disk* ]] || {
      echo "FAIL: hdiutil did not return a RAM-backed device" >&2
      return 1
    }
    newfs_hfs "$device" >/dev/null
    # "nobrowse" keeps the volume out of the Finder/volume list so fseventsd
    # never opens a watch on it, and ".fseventsd/no_log" tells fseventsd not to
    # journal it even if it does. Without both, fseventsd holds the volume open
    # and the later "hdiutil detach" fails "Resource busy", stranding a mounted
    # volume that still holds the App Store Connect private key (observed live
    # on the 1.8.0 build 20 upload).
    mount -t hfs -o noowners -o nobrowse "$device" "$mountpoint"
    mkdir -p "${mountpoint}/.fseventsd"
    : > "${mountpoint}/.fseventsd/no_log"
    # Match on $device (always a canonical /dev/diskN, unlike the mktemp
    # mountpoint, which mount(8) reports through its /private-resolved
    # symlink target and would never string-match otherwise) and read the
    # filesystem token out of field 4 ("(hfs,"), not field 3 (the mountpoint).
    mount_type="$(mount | /usr/bin/awk -v dev="$device" '$1 == dev {print $4; exit}')"
    mount_type="${mount_type#\(}"
    mount_type="${mount_type%,}"
    mount_type="${mount_type%\)}"
    [[ "$mount_type" == "hfs" || "$mount_type" == "apfs" ]] || {
      echo "FAIL: key volume mount type was not verified" >&2
      return 1
    }
    # The RAM device is the proof that this regular-file volume is volatile;
    # a normal mktemp directory is never accepted as the key directory.
    [[ "$device" == /dev/disk* ]] || return 1
  fi
  [[ -d "$mountpoint" ]] || {
    echo "FAIL: RAM-backed key volume mountpoint is unavailable" >&2
    return 1
  }
  mount_record="device=$device;mountpoint=$mountpoint;filesystem=$mount_type;disk_backed=false"
  RAM_VOLUME_MOUNTPOINT="$mountpoint"
  RAM_VOLUME_DEVICE="$device"
  RAM_VOLUME_FILESYSTEM="$mount_type"
  RAM_VOLUME_MOUNT_DIGEST="$(printf '%s' "$mount_record" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  RAM_VOLUME_DETACHED=0
  export RAM_VOLUME_MOUNTPOINT RAM_VOLUME_DEVICE RAM_VOLUME_FILESYSTEM RAM_VOLUME_MOUNT_DIGEST RAM_VOLUME_DETACHED
}

shred_ram_key_material() {
  # The credential's exposure window is the mount, not the process: a detach
  # that fails leaves the App Store Connect key readable for as long as the
  # volume stays up (four hours, on the 1.8.0 build 20 upload). Destroying the
  # key first means the worst case degrades from an exposed secret to 2 MB of
  # stranded empty RAM.
  #
  # Idempotent by construction -- shredding an absent key is a no-op -- so it
  # is safe to call from every teardown path, and calling it too few times is
  # the only real failure. It runs inside an EXIT trap under "set -e", so it
  # must never propagate a non-zero status and abort the rest of cleanup.
  local key size
  if [[ -n "${GRADUS_RAM_VOLUME_MOUNT_PATH:-}" || -n "${GRADUS_TEST_KEY_LOG:-}" ]]; then
    return 0
  fi
  [[ -n "${RAM_VOLUME_MOUNTPOINT:-}" && -d "${RAM_VOLUME_MOUNTPOINT}" ]] || return 0
  for key in "$RAM_VOLUME_MOUNTPOINT"/AuthKey_*.p8; do
    [[ -f "$key" ]] || continue
    # Overwrite the exact length in place before unlinking; a short write
    # would leave the tail of the original key in the same blocks.
    size="$(/usr/bin/stat -f %z "$key" 2>/dev/null || printf '0')"
    if [[ "$size" =~ ^[0-9]+$ ]] && (( size > 0 )); then
      /bin/dd if=/dev/urandom of="$key" bs=1 count="$size" conv=notrunc >/dev/null 2>&1 || true
    fi
    rm -f "$key" || true
  done
  if compgen -G "$RAM_VOLUME_MOUNTPOINT/AuthKey_*.p8" >/dev/null 2>&1; then
    RAM_VOLUME_KEY_DESTROYED=0
  else
    RAM_VOLUME_KEY_DESTROYED=1
  fi
  export RAM_VOLUME_KEY_DESTROYED
  return 0
}

detach_ram_key_volume() {
  # Ahead of the already-detached short circuit: the success path calls this
  # directly before the EXIT trap fires, so a shred behind that return would
  # be skipped on exactly the run that completed.
  shred_ram_key_material
  [[ "${RAM_VOLUME_DETACHED:-0}" -eq 1 ]] && return 0
  local detach_record
  if [[ -n "${GRADUS_RAM_VOLUME_MOUNT_PATH:-}" || -n "${GRADUS_TEST_KEY_LOG:-}" ]]; then
    detach_record="device=$RAM_VOLUME_DEVICE;mountpoint=$RAM_VOLUME_MOUNTPOINT;detached=true"
  else
    # hdiutil detach can transiently fail "Resource busy" against a RAM
    # volume moments after its last reader lets go (observed live on the
    # gradus-ios-19 upload, immediately after a successful altool transfer,
    # with nothing in lsof/ps holding the mount). Retry with backoff before
    # treating it as a real failure.
    local attempt delay=1
    for attempt in 1 2 3 4; do
      hdiutil detach "$RAM_VOLUME_DEVICE" >/dev/null && break
      if (( attempt == 4 )); then
        # Escalate rather than strand the volume. Nothing here prompts: this
        # runs inside the BWS broker subprocess with no TTY, so a privileged
        # "umount -f" could only hang, and is deliberately not attempted.
        hdiutil detach -force "$RAM_VOLUME_DEVICE" >/dev/null 2>&1 && break
        /usr/sbin/diskutil unmount force "$RAM_VOLUME_MOUNTPOINT" >/dev/null 2>&1 || true
        hdiutil detach -force "$RAM_VOLUME_DEVICE" >/dev/null 2>&1 && break
        echo "FAIL: hdiutil detach $RAM_VOLUME_DEVICE did not succeed after $attempt attempts" >&2
        return 1
      fi
      echo "    hdiutil detach $RAM_VOLUME_DEVICE busy, retrying in ${delay}s (attempt $attempt/4)..." >&2
      sleep "$delay"
      delay=$(( delay * 2 ))
    done
    detach_record="device=$RAM_VOLUME_DEVICE;mountpoint=$RAM_VOLUME_MOUNTPOINT;detached=true"
  fi
  RAM_VOLUME_DETACH_DIGEST="$(printf '%s' "$detach_record" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
  RAM_VOLUME_DETACHED=1
  export RAM_VOLUME_DETACH_DIGEST RAM_VOLUME_DETACHED
}

cleanup_ram_key_volume() {
  local exit_status="${GRADUS_UPLOAD_FAILURE_STATUS:-$?}"
  local cleanup_status=0
  shred_ram_key_material
  if [[ -n "${RAM_VOLUME_MOUNTPOINT:-}" && "${RAM_VOLUME_DETACHED:-0}" -eq 0 ]]; then
    if ! detach_ram_key_volume; then
      echo "FAIL: RAM-backed key volume could not be detached" >&2
      cleanup_status=70
    fi
  fi
  if [[ -n "${GRADUS_RAM_VOLUME_ATTESTATION_PATH:-}" && "${RAM_VOLUME_DETACHED:-0}" -eq 1 \
    && ! -e "$GRADUS_RAM_VOLUME_ATTESTATION_PATH" ]]; then
    if ! persist_ram_volume_attestation "$GRADUS_RAM_VOLUME_ATTESTATION_PATH" \
      "$GRADUS_RAM_VOLUME_CANDIDATE_ID" "$RAM_VOLUME_MOUNT_DIGEST" \
      "$RAM_VOLUME_DETACH_DIGEST" "$RAM_VOLUME_DEVICE" "$RAM_VOLUME_FILESYSTEM"; then
      echo "FAIL: RAM-volume attestation could not be persisted" >&2
      cleanup_status=70
    fi
  fi
  if [[ "${GRADUS_UPLOAD_ATTEMPTED:-0}" -eq 1 && "${GRADUS_UPLOAD_SUCCEEDED:-0}" -eq 0 \
    && -n "${GRADUS_UPLOAD_RECONCILIATION_PATH:-}" ]]; then
    if ! persist_upload_reconciliation "$GRADUS_UPLOAD_RECONCILIATION_PATH" \
      "$GRADUS_RAM_VOLUME_CANDIDATE_ID" "$GRADUS_RAM_VOLUME_ARTIFACT_SHA256" "$exit_status"; then
      echo "FAIL: upload reconciliation evidence could not be persisted" >&2
      cleanup_status=70
    fi
  fi
  if [[ -n "${RAM_VOLUME_MOUNTPOINT:-}" && -d "$RAM_VOLUME_MOUNTPOINT" && -z "${GRADUS_RAM_VOLUME_MOUNT_PATH:-}" ]]; then
    rmdir "$RAM_VOLUME_MOUNTPOINT" 2>/dev/null || true
  fi
  if (( cleanup_status != 0 )); then
    if [[ "${GRADUS_UPLOAD_SUCCEEDED:-0}" -eq 1 ]]; then
      # The transfer is complete and not repeatable: Apple holds the build and
      # rejects a duplicate build number, so re-running is not a recovery path.
      # Returning the cleanup status here reported a delivered release as a
      # failed one, which sent every caller back to retry an upload that had
      # already succeeded. The upload owns the exit code; the cleanup failure
      # is carried by durable evidence plus stderr, which a retry cannot erase.
      persist_cleanup_leak_evidence "$cleanup_status"
      echo "==> Upload to App Store Connect SUCCEEDED; local key-volume cleanup did NOT." >&2
      echo "    ACTION REQUIRED: ${RAM_VOLUME_MOUNTPOINT:-the key volume} is still mounted and holds" >&2
      echo "    the App Store Connect private key. Detach it; it is RAM-backed and clears on reboot." >&2
      return 0
    fi
    return "$cleanup_status"
  fi
  # A successful upload followed by an aborted intermediate step (e.g. the
  # first, now-retried detach attempt) leaves $exit_status holding that
  # step's stale failure code even once cleanup above has fully recovered.
  # Once cleanup is clean, the outcome is whatever the upload itself was.
  if [[ "${GRADUS_UPLOAD_SUCCEEDED:-0}" -eq 1 ]]; then
    return 0
  fi
  return "$exit_status"
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
  cd "$SCRIPT_DIR"
  local project_root evidence_path expected_mac_build expected_cloudkit_environment expected_project_digest
  local baseline_source_digest baseline_project_digest current_artifact_digest actual_source_digest candidate_root candidate_script_dir candidate_receipt_path
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

  # The fixed BWS consumer starts children with a minimal environment. Restore
  # HOME from the local account record before uv,
  # xcodebuild, and the provisioning-profile lookup need it.
  # shellcheck disable=SC2155
  export HOME="$(resolve_user_home)"
  # shellcheck disable=SC2155
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
  # Deliberately ahead of create_ram_key_volume: adopting needs no credential,
  # so the App Store Connect key is never written to a volume on this path.
  if delivery_receipt_matches "${candidate_workspace}/upload-delivery.json" \
      "$candidate_id" "$NEXT_BUILD" "$artifact_digest"; then
    echo "==> Candidate $candidate_id build $NEXT_BUILD was already delivered to App Store Connect; adopting the existing receipt"
    echo "==> Done. Candidate $candidate_id build $NEXT_BUILD uploaded -- Apple will take a few minutes to process it."
    return 0
  fi

# altool's --api-key auth looks for AuthKey_<key-id>.p8 in a fixed set of
# directories (or $API_PRIVATE_KEYS_DIR). Keep that regular file only on a
# verified RAM-backed volume; a disk-backed temporary directory is forbidden.
  create_ram_key_volume
  trap 'cleanup_ram_key_volume' EXIT
  # An interrupt would otherwise bypass the EXIT trap entirely and leave the
  # key mounted. Destroy it in the handler, then exit so cleanup still runs.
  trap 'shred_ram_key_material; exit 130' INT
  trap 'shred_ram_key_material; exit 143' TERM
  trap 'shred_ram_key_material; exit 129' HUP
  export GRADUS_RAM_VOLUME_ATTESTATION_PATH="${candidate_workspace}/ram-volume-attestation.json"
  export GRADUS_UPLOAD_RECONCILIATION_PATH="${candidate_workspace}/upload-reconciliation.json"
  export GRADUS_UPLOAD_DELIVERY_RECEIPT_PATH="${candidate_workspace}/upload-delivery.json"
  export GRADUS_RAM_VOLUME_CANDIDATE_ID="$candidate_id"
  export GRADUS_RAM_VOLUME_ARTIFACT_SHA256="$artifact_digest"
  export GRADUS_UPLOAD_ATTEMPTED=0 GRADUS_UPLOAD_SUCCEEDED=0
  umask 077
  printf '%s' "$APP_STORE_CONNECT_API_KEY" > "${RAM_VOLUME_MOUNTPOINT}/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
  chmod 600 "${RAM_VOLUME_MOUNTPOINT}/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
  export API_PRIVATE_KEYS_DIR="$RAM_VOLUME_MOUNTPOINT"

  # Record "uploading" only once local pre-flight work (RAM volume, key
  # material) has succeeded and the next step is the network call itself.
  # A failure before this point is unambiguously local-only and must leave
  # the candidate in a retryable "prepared" state rather than stranding it
  # in "uploading", which only forward-transitions to failed/abandoned.
  transition_candidate_state "$candidate_ledger_path" uploading

  echo "==> Uploading to App Store Connect"
  export GRADUS_UPLOAD_ATTEMPTED=1
  local delivery_log delivery_uuid artifact_bytes upload_status
  # altool reports the delivery outcome, including the UUID Apple assigns, on
  # stderr. Tee the merged stream so the receipt below can quote Apple's own
  # confirmation while the operator still sees transfer progress live -- a
  # plain redirect would buffer a multi-minute upload into silence.
  delivery_log="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/gradus-delivery.XXXXXX")"
  if xcrun altool --upload-package "$IPA_PATH" \
      -t ios \
      --api-key "$APP_STORE_CONNECT_KEY_ID" \
      --api-issuer "$APP_STORE_CONNECT_ISSUER_ID" 2>&1 | tee "$delivery_log"; then
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
    cleanup_ram_key_volume
    trap - EXIT INT TERM HUP
    return "$upload_status"
  fi
  # Persist the receipt before anything else can fail. Every step after this
  # point -- detach, attestation, the exit trap -- has already been observed to
  # fail on a delivered build, and each one of those failures used to erase the
  # only record that the delivery happened.
  delivery_uuid="$(/usr/bin/sed -n \
    's/.*Delivery UUID: *\([0-9a-fA-F][0-9a-fA-F-]*\).*/\1/p' "$delivery_log" | /usr/bin/head -n 1)"
  artifact_bytes="$(/usr/bin/stat -f %z "$IPA_PATH" 2>/dev/null || printf '0')"
  rm -f "$delivery_log"
  persist_delivery_receipt "$GRADUS_UPLOAD_DELIVERY_RECEIPT_PATH" \
    "$candidate_id" "$marketing_version" "$NEXT_BUILD" \
    "$artifact_digest" "$artifact_bytes" "$delivery_uuid"
  detach_ram_key_volume
  persist_ram_volume_attestation "$GRADUS_RAM_VOLUME_ATTESTATION_PATH" \
    "$candidate_id" "$RAM_VOLUME_MOUNT_DIGEST" "$RAM_VOLUME_DETACH_DIGEST" "$RAM_VOLUME_DEVICE" "$RAM_VOLUME_FILESYSTEM"
  failure_hook assignment

  echo "==> Done. Candidate $candidate_id build $NEXT_BUILD uploaded -- Apple will take a few minutes to process it."
  echo "    Assignment is a separate attended step: provide the candidate ID, exact internal-group ID/name,"
  echo "    candidate ledger/evidence paths, and receipt-journal path to the assignment-only wrapper."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
