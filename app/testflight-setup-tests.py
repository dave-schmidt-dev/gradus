from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path

import pytest
from _asc_api import ASCOutcome, PermanentASCError
from release_candidate.ledger import CandidateLedger

_spec = importlib.util.spec_from_file_location(
    "testflight_assign", Path(__file__).with_name("testflight-assign.py")
)
assert _spec and _spec.loader
_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_module)
AssignmentError = _module.AssignmentError
assign_candidate = _module.assign_candidate
confirm_exact_build = _module.confirm_exact_build
add_build_to_group = _module.add_build_to_group
find_exact_internal_group = _module.find_exact_internal_group
load_evidence = _module._load_evidence
resolve_receipt_journal_path = _module._resolve_receipt_journal_path


class FakeClient:
    def __init__(self, responses):
        self.responses = responses
        self.requests = []

    def request(self, method, path, body=None, **kwargs):
        self.requests.append((method, path, body))
        value = self.responses.get((method, path), self.responses.get(path))
        if callable(value):
            return value()
        return value


def app():
    return {"data": [{"id": "app-1", "attributes": {"name": "Gradus"}}]}


def groups(items):
    return {"data": items}


def group(gid="group-1", name="Internal Testers", all_builds=False):
    return {
        "id": gid,
        "attributes": {
            "name": name,
            "isInternalGroup": True,
            "hasAccessToAllBuilds": all_builds,
        },
    }


def build(state="VALID"):
    return {"data": [{"id": "build-1", "attributes": {"version": "42", "processingState": state}}]}


def valid_client(group_items=None, build_response=None):
    selected = build_response or build()
    selected_data = selected["data"][0] if selected.get("data") else None
    exact_response = (
        {"data": {**selected_data, "attributes": {**selected_data["attributes"], "expired": False}}}
        if selected_data is not None
        else {"data": []}
    )
    return FakeClient(
        {
            "/apps?filter[bundleId]=com.zerodelta.gradus.ios": app(),
            "/apps/app-1/betaGroups?limit=200": groups(
                [group()] if group_items is None else group_items
            ),
            "/builds?filter[app]=app-1&filter[version]=42&limit=50": selected,
            "/builds/build-1": exact_response,
            "/betaGroups/group-1/builds?limit=200": {"data": []},
        }
    )


def test_exact_group_assignment_succeeds():
    client = valid_client()
    result = assign_candidate(
        client,
        candidate_id="candidate-1",
        build="42",
        group_id="group-1",
        group_name="Internal Testers",
        clock=lambda: 0,
        timeout=1,
    )
    assert result["assigned"] is True
    assert any(item[0] == "POST" for item in client.requests)


def test_all_builds_internal_group_needs_no_relationship_mutation():
    client = valid_client([group(all_builds=True)])
    result = assign_candidate(
        client,
        candidate_id="candidate-1",
        build="42",
        group_id="group-1",
        group_name="Internal Testers",
        clock=lambda: 0,
        timeout=1,
    )
    assert result["assigned"] is True
    assert result["already_assigned"] is True
    assert not any(item[0] == "POST" for item in client.requests)


def test_group_assignment_uses_build_relationship_route_after_group_404():
    class FallbackClient(FakeClient):
        def request(self, method, path, body=None, **kwargs):
            if method == "POST" and path == "/betaGroups/group-1/relationships/builds":
                outcome = ASCOutcome(None, "http_404", False, 404)
                raise PermanentASCError(outcome)
            return super().request(method, path, body, **kwargs)

    client = FallbackClient({})
    add_build_to_group(client, "group-1", "build-1")
    assert client.requests[-1] == (
        "POST",
        "/builds/build-1/relationships/betaGroups",
        {"data": [{"type": "betaGroups", "id": "group-1"}]},
    )


def test_zero_multiple_renamed_or_mismatched_groups_fail_before_assignment():
    cases = [
        [],
        [group(), group("group-2", "Internal Testers")],
        [group("group-1", "Renamed")],
        [group("other", "Internal Testers")],
    ]
    for entries in cases:
        client = valid_client(entries)
        try:
            assign_candidate(
                client,
                candidate_id="c",
                build="42",
                group_id="group-1",
                group_name="Internal Testers",
                clock=lambda: 0,
                timeout=1,
            )
        except AssignmentError:
            pass
        else:
            raise AssertionError("ambiguous group accepted")
        assert not any(item[0] == "POST" for item in client.requests)


def test_processing_failures_and_missing_compliance_are_nonzero():
    for state in ("INVALID", "FAILED", "MISSING_COMPLIANCE"):
        client = valid_client(build_response=build(state))
        try:
            assign_candidate(
                client,
                candidate_id="c",
                build="42",
                group_id="group-1",
                group_name="Internal Testers",
                clock=lambda: 0,
                timeout=1,
            )
        except AssignmentError:
            pass
        else:
            raise AssertionError("unsafe processing state accepted")
        assert not any(item[0] == "POST" for item in client.requests)


def test_timeout_is_nonzero_and_no_assignment():
    client = valid_client(build_response={"data": []})
    try:
        assign_candidate(
            client,
            candidate_id="c",
            build="42",
            group_id="group-1",
            group_name="Internal Testers",
            clock=lambda: 2,
            timeout=0,
            interval=0,
        )
    except AssignmentError:
        pass
    else:
        raise AssertionError("timeout accepted")
    assert not any(item[0] == "POST" for item in client.requests)


def test_forbidden_mutation_routes_are_absent():
    source = Path(__file__).with_name("testflight-assign.py").read_text(encoding="utf-8")
    for forbidden in ("betaTesters", "/users", "/profiles", "DELETE", '"POST", " /betaGroups'):
        assert forbidden not in source


def test_assignment_cli_has_an_executable_entrypoint():
    source = Path(__file__).with_name("testflight-assign.py").read_text(encoding="utf-8")
    assert 'if __name__ == "__main__":' in source
    assert "raise SystemExit(main())" in source


def test_assignment_accepts_immutable_evidence_after_processing_delay(tmp_path):
    walkthrough = tmp_path / "walkthrough.md"
    walkthrough.write_text("candidate walkthrough\n", encoding="utf-8")
    evidence = tmp_path / "candidate-evidence.json"
    payload = {
        "sourceRevision": "revision",
        "projectSha256": "a" * 64,
        "marketingVersion": "1.6.7",
        "producerBuild": 17,
        "producerEvidenceSha256": "b" * 64,
        "iosBuild": 13,
        "ipaSha256": "c" * 64,
        "walkthroughPath": str(walkthrough),
        "walkthroughSha256": hashlib.sha256(walkthrough.read_bytes()).hexdigest(),
        "createdAt": "2026-08-10T12:18:21Z",
        "producerPublishedAt": "2026-08-09T12:00:00Z",
    }
    evidence.write_text(json.dumps(payload), encoding="utf-8")
    assert load_evidence(str(evidence)).producer_build == 17


def test_exact_build_is_rechecked_before_mutation():
    client = valid_client()
    client.responses["/builds/build-1"] = {
        "data": {
            "id": "build-1",
            "attributes": {"version": "42", "processingState": "VALID", "expired": False},
        }
    }
    result = confirm_exact_build(client, "build-1", "42")
    assert result["id"] == "build-1"


def test_receipt_journal_must_be_workspace_local_and_is_recorded(tmp_path):
    workspace = tmp_path / "candidate-workspace"
    workspace.mkdir()
    ledger = CandidateLedger(tmp_path / "candidate.json")
    ledger.create(
        "candidate-1",
        source=b"source",
        project=b"project",
        artifact=b"artifact",
        metadata={"candidateWorkspace": str(workspace)},
    )
    receipt = resolve_receipt_journal_path(ledger, str(workspace / "receipt.json"))
    ledger.extend_metadata({"receiptJournalPath": str(receipt)})
    assert ledger.load().metadata["receiptJournalPath"] == str(receipt)
    with pytest.raises(AssignmentError, match="inside the candidate workspace"):
        resolve_receipt_journal_path(ledger, str(tmp_path / "external-receipt.json"))
    (workspace / "receipt-dir").mkdir()
    with pytest.raises(AssignmentError, match="regular file"):
        resolve_receipt_journal_path(ledger, str(workspace / "receipt-dir"))
    missing_parent = workspace / "missing" / "receipt.json"
    with pytest.raises(AssignmentError, match="parent directory"):
        resolve_receipt_journal_path(ledger, str(missing_parent))
    fifo = workspace / "receipt.fifo"
    os.mkfifo(fifo)
    with pytest.raises(AssignmentError, match="regular file"):
        resolve_receipt_journal_path(ledger, str(fifo))
