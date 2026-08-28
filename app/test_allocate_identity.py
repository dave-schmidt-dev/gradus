from __future__ import annotations

import hashlib
import json
from pathlib import Path

import pytest
from _asc_api import ASCOutcome, PermanentASCError
from allocate_identity import (
    IdentityAllocationError,
    _remote_semver,
    assign_build_to_internal_group,
    create_internal_testflight_workflow,
    ensure_ios_app_group_distribution_profile,
    ensure_widget_distribution_profile,
    find_ios_testflight_build,
    inspect_testflight_build_app,
    list_ci_builds,
    list_cloud_product_metadata,
    list_product_workflow_metadata,
    list_workflow_build_runs,
    list_workflow_metadata,
    main,
    make_proof,
    read_build_run_status,
    read_marketing_version,
    read_workflow_template,
    resolve_workflow_toolchain,
    start_internal_testflight_build,
    write_proof,
)


class FixtureClient:
    def __init__(self, responses):
        self.responses = iter(responses)
        self.paths = []

    def request(self, method, path):
        assert method == "GET"
        self.paths.append(path)
        return next(self.responses)


class MutationFixtureClient(FixtureClient):
    def __init__(self, responses):
        super().__init__(responses)
        self.methods = []
        self.bodies = []

    def request(self, method, path, body=None, *, idempotent=None):
        self.methods.append(method)
        self.paths.append(path)
        self.bodies.append(body)
        return next(self.responses)


def _project(tmp_path: Path, version: str = "1.6.7") -> Path:
    path = tmp_path / "project.yml"
    path.write_text(
        f'name: Gradus\ntargets:\n  GradusiOS:\n    settings:\n      MARKETING_VERSION: "{version}"\n',
        encoding="utf-8",
    )
    return path


def _responses():
    return [
        {"data": [{"id": "app-1", "attributes": {"bundleId": "com.zerodelta.gradus.ios"}}]},
        {
            "data": [
                {
                    "id": "build-7",
                    "attributes": {"version": "7", "processingState": "VALID"},
                    "relationships": {"preReleaseVersion": {"data": {"id": "pre-167"}}},
                },
                {
                    "id": "build-6",
                    "attributes": {"version": "6", "processingState": "VALID"},
                    "relationships": {"preReleaseVersion": {"data": {"id": "pre-166"}}},
                },
            ],
            "included": [
                {
                    "type": "preReleaseVersions",
                    "id": "pre-167",
                    "attributes": {"version": "1.6.7", "platform": "IOS"},
                },
                {
                    "type": "preReleaseVersions",
                    "id": "pre-166",
                    "attributes": {"version": "1.6.6", "platform": "IOS"},
                },
            ],
            "links": {"next": None},
        },
    ]


def _workflow_responses():
    return [
        {"data": [{"id": "app-1", "attributes": {"bundleId": "com.zerodelta.gradus.ios"}}]},
        {"data": [{"type": "ciProducts", "id": "product-1"}]},
        {
            "data": [
                {
                    "type": "ciWorkflows",
                    "id": "workflow-1",
                    "attributes": {
                        "name": "Release",
                        "isEnabled": True,
                        "manualBranchStartCondition": {"branch": "main"},
                        "manualTagStartCondition": None,
                        "actions": [
                            {"actionType": "TEST", "platform": "IOS"},
                            {
                                "actionType": "ARCHIVE",
                                "platform": "IOS",
                                "scheme": "GradusiOS",
                                "buildDistributionAudience": "APP_STORE_ELIGIBLE",
                            },
                        ],
                    },
                }
            ],
            "links": {"next": None},
        },
    ]


def _cloud_product_responses():
    return [
        {
            "data": [
                {
                    "type": "ciProducts",
                    "id": "product-1",
                    "attributes": {"name": "GradusMac", "productType": "APP"},
                }
            ]
        }
    ]


def test_make_proof_reads_fixed_app_and_build_bindings_without_persisting_response(tmp_path):
    client = FixtureClient(_responses())
    proof = make_proof(
        client,
        product="gradus-ios",
        marketing_version=read_marketing_version(_project(tmp_path)),
        observed_at="2026-08-13T12:00:00Z",
    )

    assert set(proof) == {
        "proofVersion",
        "operationClass",
        "result",
        "marketingVersion",
        "buildNumber",
        "responseSha256",
        "productKey",
        "remoteHighestMarketingVersion",
        "remoteHighestBuildNumber",
        "observedAt",
    }
    assert proof["operationClass"] == "identityAllocation"
    assert proof["result"] == "passed"
    assert proof["marketingVersion"] == "1.6.7"
    assert proof["buildNumber"] == 8
    assert proof["remoteHighestMarketingVersion"] == "1.6.7"
    assert proof["remoteHighestBuildNumber"] == 7
    assert len(proof["responseSha256"]) == 64
    assert "Bearer" not in json.dumps(proof)
    assert len(client.paths) == 2


def test_unsupported_product_and_unbound_response_fail_closed(tmp_path):
    with pytest.raises(IdentityAllocationError, match="product-unsupported"):
        make_proof(FixtureClient([]), product="other", marketing_version="1.6.7")

    responses = _responses()
    responses[1]["data"][0]["relationships"] = {}
    with pytest.raises(IdentityAllocationError, match="build-prerelease-binding-invalid"):
        make_proof(FixtureClient(responses), product="gradus-ios", marketing_version="1.6.7")


def test_remote_abbreviated_version_is_normalized_but_extra_components_fail_closed():
    assert _remote_semver("1.6") == (1, 6, 0)
    assert _remote_semver("1") == (1, 0, 0)
    with pytest.raises(IdentityAllocationError, match="components-4"):
        _remote_semver("1.6.7.1")


def test_write_proof_is_fixed_and_does_not_overwrite(tmp_path):
    destination = tmp_path / ".release-state/evidence/allocate-identity.json"
    proof = {"proofVersion": "1.0.0", "operationClass": "identityAllocation"}
    write_proof(destination, proof)
    assert json.loads(destination.read_text(encoding="utf-8")) == proof
    assert destination.stat().st_mode & 0o777 == 0o400
    with pytest.raises(IdentityAllocationError, match="identity-proof-already-exists"):
        write_proof(destination, proof)

    assert json.loads(destination.read_text(encoding="utf-8")) == proof
    assert destination.stat().st_mode & 0o777 == 0o400


def test_identity_cli_remains_backward_compatible(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project_dir = tmp_path / "app"
    project_dir.mkdir(parents=True, exist_ok=True)
    _project(project_dir)

    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr("allocate_identity.make_token_provider", lambda: None)
    monkeypatch.setattr("allocate_identity.ASCClient", lambda provider: FixtureClient(_responses()))

    status = main(["--product", "gradus-ios"])
    assert status == 0

    evidence_file = tmp_path / ".release-state" / "evidence" / "allocate-identity.json"
    assert evidence_file.is_file()
    proof = json.loads(evidence_file.read_text(encoding="utf-8"))
    assert proof["result"] == "passed"
    assert proof["productKey"] == "gradus-ios"
    assert proof["marketingVersion"] == "1.6.7"
    assert proof["buildNumber"] == 8


def test_widget_profile_creation_uses_the_fixed_extension_identity(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    content = "cHJvZmlsZQ=="
    client = MutationFixtureClient(
        [
            {
                "data": [
                    {
                        "type": "bundleIds",
                        "id": "widget-bundle",
                        "attributes": {"identifier": "com.zerodelta.gradus.ios.widget"},
                    }
                ]
            },
            {
                "data": {
                    "type": "bundleIds",
                    "id": "widget-bundle",
                    "attributes": {"identifier": "com.zerodelta.gradus.ios.widget"},
                }
            },
            {
                "data": [
                    {"type": "certificates", "id": "certificate-other"},
                    {"type": "certificates", "id": "certificate-1"},
                ]
            },
            {"data": {"attributes": {"certificateContent": "b3RoZXI="}}},
            {
                "data": {
                    "attributes": {"certificateContent": "Y2VydGlmaWNhdGUtZm9yLWdyYWR1cy1maXh0dXJl"}
                }
            },
            {"data": []},
            {"data": {"attributes": {"profileContent": content}}},
        ]
    )
    monkeypatch.setattr(
        "allocate_identity.DISTRIBUTION_CERTIFICATE_SHA1",
        hashlib.sha1(b"certificate-for-gradus-fixture").hexdigest().upper(),
    )

    receipt = ensure_widget_distribution_profile(client, tmp_path)

    assert receipt == {
        "bundleId": "com.zerodelta.gradus.ios.widget",
        "created": True,
        "profileFilename": "gradus-widget-app-store.provisionprofile",
    }
    assert (tmp_path / receipt["profileFilename"]).read_bytes() == b"profile"
    assert client.methods == ["GET", "GET", "GET", "GET", "GET", "GET", "POST"]
    assert client.paths[-1] == "/profiles"
    assert client.bodies[-1]["data"]["relationships"]["bundleId"]["data"] == {
        "type": "bundleIds",
        "id": "widget-bundle",
    }


def test_ios_app_group_profile_replaces_only_the_named_main_profile(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    client = MutationFixtureClient(
        [
            {
                "data": [
                    {
                        "type": "bundleIds",
                        "id": "ios-bundle",
                    }
                ]
            },
            {
                "data": {
                    "type": "bundleIds",
                    "id": "ios-bundle",
                    "attributes": {"identifier": "com.zerodelta.gradus.ios"},
                }
            },
            {"data": [{"type": "certificates", "id": "certificate-1"}]},
            {
                "data": {
                    "attributes": {"certificateContent": "Y2VydGlmaWNhdGUtZm9yLWdyYWR1cy1maXh0dXJl"}
                }
            },
            {"data": []},
            {"data": {"attributes": {"profileContent": "cHJvZmlsZQ=="}}},
        ]
    )
    monkeypatch.setattr(
        "allocate_identity.DISTRIBUTION_CERTIFICATE_SHA1",
        hashlib.sha1(b"certificate-for-gradus-fixture").hexdigest().upper(),
    )

    receipt = ensure_ios_app_group_distribution_profile(client, tmp_path)

    assert receipt == {
        "bundleId": "com.zerodelta.gradus.ios",
        "created": True,
        "profileFilename": "gradus-ios-app-store.provisionprofile",
    }
    assert (tmp_path / receipt["profileFilename"]).read_bytes() == b"profile"
    assert client.bodies[-1]["data"]["attributes"]["name"] == (
        "Gradus iOS App Store App Group (API-created)"
    )


def test_list_workflows_resolves_fixed_app_and_emits_allowlisted_metadata(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    client = FixtureClient(_workflow_responses())
    assert list_workflow_metadata(client) == [
        {
            "id": "workflow-1",
            "name": "Release",
            "isEnabled": True,
            "hasManualStart": True,
            "archiveActions": [
                {
                    "platform": "IOS",
                    "scheme": "GradusiOS",
                    "distributionAudience": "APP_STORE_ELIGIBLE",
                }
            ],
        }
    ]
    assert client.paths == [
        "/apps?filter[bundleId]=com.zerodelta.gradus.ios",
        "/ciProducts?filter[app]=app-1&fields[ciProducts]=app&limit=200",
        "/ciProducts/product-1/workflows?fields[ciWorkflows]=name,isEnabled,manualBranchStartCondition,manualTagStartCondition,manualPullRequestStartCondition,actions&limit=200",
    ]

    monkeypatch.setattr("allocate_identity.make_token_provider", lambda: None)
    monkeypatch.setattr(
        "allocate_identity.ASCClient", lambda provider: FixtureClient(_workflow_responses())
    )
    assert main(["--list-workflows"]) == 0
    assert json.loads(capsys.readouterr().out) == [
        {
            "archiveActions": [
                {
                    "distributionAudience": "APP_STORE_ELIGIBLE",
                    "platform": "IOS",
                    "scheme": "GradusiOS",
                }
            ],
            "hasManualStart": True,
            "id": "workflow-1",
            "isEnabled": True,
            "name": "Release",
        }
    ]


def test_list_cloud_products_emits_allowlisted_metadata(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    client = FixtureClient(_cloud_product_responses())
    assert list_cloud_product_metadata(client) == [
        {"id": "product-1", "name": "GradusMac", "productType": "APP"}
    ]
    assert client.paths == ["/ciProducts?fields[ciProducts]=name,productType&limit=200"]

    monkeypatch.setattr("allocate_identity.make_token_provider", lambda: None)
    monkeypatch.setattr(
        "allocate_identity.ASCClient", lambda provider: FixtureClient(_cloud_product_responses())
    )
    assert main(["--list-cloud-products"]) == 0
    assert json.loads(capsys.readouterr().out) == [
        {"id": "product-1", "name": "GradusMac", "productType": "APP"}
    ]


def test_list_product_workflows_uses_explicit_inventory_product(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    responses = _workflow_responses()[2:]
    client = FixtureClient(responses)
    assert list_product_workflow_metadata(client, "product-1")[0]["id"] == "workflow-1"
    assert client.paths == [
        "/ciProducts/product-1/workflows?fields[ciWorkflows]=name,isEnabled,manualBranchStartCondition,manualTagStartCondition,manualPullRequestStartCondition,actions&limit=200"
    ]

    monkeypatch.setattr("allocate_identity.make_token_provider", lambda: None)
    monkeypatch.setattr(
        "allocate_identity.ASCClient", lambda provider: FixtureClient(_workflow_responses()[2:])
    )
    assert main(["--list-product-workflows", "product-1"]) == 0
    assert json.loads(capsys.readouterr().out)[0]["id"] == "workflow-1"


def test_read_workflow_template_emits_only_sibling_configuration(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    response = {
        "data": {
            "type": "ciWorkflows",
            "attributes": {"containerFilePath": "app/Gradus.xcodeproj", "clean": False},
            "relationships": {
                "repository": {"data": {"type": "scmRepositories", "id": "repo-1"}},
                "xcodeVersion": {"data": {"type": "ciXcodeVersions", "id": "xcode-1"}},
                "macOsVersion": {"data": {"type": "ciMacOsVersions", "id": "macos-1"}},
            },
        }
    }
    expected = {
        "containerFilePath": "app/Gradus.xcodeproj",
        "clean": False,
        "repositoryId": "repo-1",
        "xcodeVersionId": "xcode-1",
        "macOsVersionId": "macos-1",
    }
    client = FixtureClient([response])
    assert read_workflow_template(client, "workflow-1") == expected
    assert client.paths == [
        "/ciWorkflows/workflow-1?fields[ciWorkflows]=containerFilePath,clean,repository,xcodeVersion,macOsVersion&include=repository,xcodeVersion,macOsVersion"
    ]
    monkeypatch.setattr("allocate_identity.make_token_provider", lambda: None)
    monkeypatch.setattr("allocate_identity.ASCClient", lambda provider: FixtureClient([response]))
    assert main(["--read-workflow-template", "workflow-1"]) == 0
    assert json.loads(capsys.readouterr().out) == expected


def test_create_internal_testflight_workflow_is_manual_clean_locked_and_idempotent() -> None:
    product_id = "product-1"
    template_id = "workflow-1"
    client = MutationFixtureClient(
        [
            {
                "data": [
                    {
                        "type": "ciWorkflows",
                        "id": template_id,
                        "attributes": {
                            "name": "Gradus iOS Snapshot Trial",
                            "isEnabled": True,
                            "manualBranchStartCondition": None,
                            "manualTagStartCondition": None,
                            "manualPullRequestStartCondition": None,
                            "actions": [],
                        },
                    }
                ]
            },
            {
                "data": {
                    "type": "ciWorkflows",
                    "attributes": {"containerFilePath": "app/Gradus.xcodeproj", "clean": True},
                    "relationships": {
                        "repository": {"data": {"type": "scmRepositories", "id": "repo-1"}},
                        "xcodeVersion": {"data": {"type": "ciXcodeVersions", "id": "xcode-1"}},
                        "macOsVersion": {"data": {"type": "ciMacOsVersions", "id": "macos-1"}},
                    },
                }
            },
            {
                "data": {
                    "type": "ciWorkflows",
                    "id": "workflow-new",
                    "attributes": {"name": "Gradus iOS Internal TestFlight"},
                }
            },
        ]
    )
    assert create_internal_testflight_workflow(
        client, product_id=product_id, template_workflow_id=template_id
    ) == {
        "workflowId": "workflow-new",
        "name": "Gradus iOS Internal TestFlight",
        "branch": "main",
        "platform": "IOS",
        "distributionAudience": "INTERNAL_ONLY",
    }
    assert client.paths[-1] == "/ciWorkflows"
    assert client.methods[-1] == "POST"
    attributes = client.bodies[-1]["data"]["attributes"]
    assert (
        attributes["branchStartCondition"] is None if "branchStartCondition" in attributes else True
    )
    assert attributes["manualBranchStartCondition"]["source"]["patterns"] == [
        {"pattern": "main", "isPrefix": False}
    ]
    assert attributes["actions"] == [
        {
            "name": "Archive iOS",
            "actionType": "ARCHIVE",
            "scheme": "GradusiOS",
            "platform": "IOS",
            "isRequiredToPass": True,
            "buildDistributionAudience": "INTERNAL_ONLY",
        }
    ]


def test_start_internal_testflight_build_checks_contract_before_posting() -> None:
    workflow_id = "workflow-1"
    client = MutationFixtureClient(
        [
            {
                "data": [
                    {
                        "type": "ciWorkflows",
                        "id": workflow_id,
                        "attributes": {
                            "name": "Gradus iOS Internal TestFlight",
                            "isEnabled": True,
                            "manualBranchStartCondition": {"source": {"patterns": []}},
                            "manualTagStartCondition": None,
                            "manualPullRequestStartCondition": None,
                            "actions": [
                                {
                                    "actionType": "ARCHIVE",
                                    "platform": "IOS",
                                    "scheme": "GradusiOS",
                                    "buildDistributionAudience": "INTERNAL_ONLY",
                                }
                            ],
                        },
                    }
                ]
            },
            {
                "data": {
                    "type": "ciBuildRuns",
                    "id": "run-1",
                    "attributes": {"executionProgress": "PENDING"},
                }
            },
        ]
    )
    assert start_internal_testflight_build(
        client, product_id="product-1", workflow_id=workflow_id
    ) == {"buildRunId": "run-1", "executionProgress": "PENDING", "workflowId": workflow_id}
    assert client.methods == ["GET", "POST"]
    assert client.paths[-1] == "/ciBuildRuns"
    assert client.bodies[-1] == {
        "data": {
            "type": "ciBuildRuns",
            "attributes": {"clean": True},
            "relationships": {"workflow": {"data": {"type": "ciWorkflows", "id": workflow_id}}},
        }
    }


def test_read_build_run_status_outputs_only_delivery_state() -> None:
    client = FixtureClient(
        [
            {
                "data": {
                    "type": "ciBuildRuns",
                    "attributes": {"executionProgress": "RUNNING", "completionStatus": None},
                }
            }
        ]
    )
    assert read_build_run_status(client, "run-1") == {
        "buildRunId": "run-1",
        "executionProgress": "RUNNING",
        "completionStatus": None,
    }


def test_list_workflow_build_runs_outputs_only_state() -> None:
    client = FixtureClient(
        [
            {
                "data": [
                    {
                        "id": "run-1",
                        "attributes": {"executionProgress": "PENDING", "completionStatus": None},
                    }
                ]
            }
        ]
    )
    assert list_workflow_build_runs(client, "workflow-1") == [
        {"buildRunId": "run-1", "executionProgress": "PENDING", "completionStatus": None}
    ]


def test_list_ci_builds_outputs_only_testflight_state() -> None:
    client = FixtureClient(
        [
            {
                "data": [
                    {
                        "id": "build-1",
                        "attributes": {
                            "version": "25",
                            "processingState": "PROCESSING",
                            "buildAudienceType": "INTERNAL_ONLY",
                        },
                    }
                ]
            }
        ]
    )
    assert list_ci_builds(client, "run-1") == [
        {
            "buildId": "build-1",
            "buildNumber": "25",
            "processingState": "PROCESSING",
            "distributionAudience": "INTERNAL_ONLY",
        }
    ]


def test_find_ios_testflight_build_binds_the_number_to_the_fixed_app() -> None:
    client = FixtureClient(
        [
            {"data": [{"id": "app-1", "attributes": {"bundleId": "com.zerodelta.gradus.ios"}}]},
            {
                "data": [
                    {
                        "id": "build-39",
                        "attributes": {
                            "version": "39",
                            "processingState": "VALID",
                            "buildAudienceType": "INTERNAL_ONLY",
                        },
                    }
                ]
            },
        ]
    )
    assert find_ios_testflight_build(client, "39") == [
        {
            "buildId": "build-39",
            "buildNumber": "39",
            "processingState": "VALID",
            "distributionAudience": "INTERNAL_ONLY",
        }
    ]


def test_find_ios_testflight_build_names_the_marketing_version_behind_the_number() -> None:
    client = FixtureClient(
        [
            {"data": [{"id": "app-1", "attributes": {"bundleId": "com.zerodelta.gradus.ios"}}]},
            {
                "data": [
                    {
                        "id": "build-12",
                        "attributes": {
                            "version": "12",
                            "processingState": "VALID",
                            "buildAudienceType": "INTERNAL_ONLY",
                        },
                        "relationships": {"preReleaseVersion": {"data": {"id": "train-190"}}},
                    }
                ],
                "included": [
                    {
                        "type": "preReleaseVersions",
                        "id": "train-190",
                        "attributes": {"version": "1.9.0"},
                    }
                ],
            },
        ]
    )
    assert find_ios_testflight_build(client, "12") == [
        {
            "buildId": "build-12",
            "buildNumber": "12",
            "processingState": "VALID",
            "distributionAudience": "INTERNAL_ONLY",
            "marketingVersion": "1.9.0",
        }
    ]


def test_find_ios_testflight_build_rejects_a_dangling_version_linkage() -> None:
    client = FixtureClient(
        [
            {"data": [{"id": "app-1", "attributes": {"bundleId": "com.zerodelta.gradus.ios"}}]},
            {
                "data": [
                    {
                        "id": "build-12",
                        "attributes": {
                            "version": "12",
                            "processingState": "VALID",
                            "buildAudienceType": "INTERNAL_ONLY",
                        },
                        "relationships": {"preReleaseVersion": {"data": {"id": "train-190"}}},
                    }
                ],
                "included": [],
            },
        ]
    )
    with pytest.raises(IdentityAllocationError, match="build-response-invalid"):
        find_ios_testflight_build(client, "12")


def test_inspect_testflight_build_app_returns_only_fixed_app_membership() -> None:
    client = FixtureClient(
        [
            {"data": [{"id": "app-1", "attributes": {"bundleId": "com.zerodelta.gradus.ios"}}]},
            {"data": {"id": "app-2", "attributes": {"bundleId": "com.zerodelta.gradus"}}},
        ]
    )
    assert inspect_testflight_build_app(client, "build-39") == {
        "buildAppPresent": True,
        "belongsToGradusiOS": False,
        "bundleId": "com.zerodelta.gradus",
    }


def test_assign_build_to_internal_group_reads_before_adding() -> None:
    client = MutationFixtureClient(
        [
            {"data": [{"id": "app-1", "attributes": {"bundleId": "com.zerodelta.gradus.ios"}}]},
            {
                "data": [
                    {
                        "type": "betaGroups",
                        "id": "group-1",
                        "attributes": {"isInternalGroup": True, "hasAccessToAllBuilds": False},
                    }
                ]
            },
            {"data": []},
            None,
        ]
    )
    assert assign_build_to_internal_group(client, build_id="build-1", group_id="group-1") == {
        "buildId": "build-1",
        "assignment": "assigned",
    }
    assert client.methods == ["GET", "GET", "GET", "POST"]
    assert client.paths[-1] == "/betaGroups/group-1/relationships/builds"
    assert client.bodies[-1] == {"data": [{"type": "builds", "id": "build-1"}]}


def test_assign_build_to_internal_group_skips_relationship_mutation_for_all_builds_group() -> None:
    client = MutationFixtureClient(
        [
            {"data": [{"id": "app-1", "attributes": {"bundleId": "com.zerodelta.gradus.ios"}}]},
            {
                "data": [
                    {
                        "type": "betaGroups",
                        "id": "group-1",
                        "attributes": {"isInternalGroup": True, "hasAccessToAllBuilds": True},
                    }
                ]
            },
        ]
    )
    assert assign_build_to_internal_group(client, build_id="build-1", group_id="group-1") == {
        "buildId": "build-1",
        "assignment": "allBuildsAccess",
    }
    assert client.methods == ["GET", "GET"]


def test_assign_build_to_internal_group_reports_the_denied_phase_without_response_content() -> None:
    class DeniedClient:
        def request(self, *_args, **_kwargs):
            raise PermanentASCError(ASCOutcome(None, "http_403", False, 403))

    with pytest.raises(IdentityAllocationError, match="testflight-assignment-app-lookup-http_403"):
        assign_build_to_internal_group(DeniedClient(), build_id="build-1", group_id="group-1")


def test_list_workflows_fails_closed_on_ambiguous_or_malformed_responses() -> None:
    duplicate = _workflow_responses()
    duplicate[2]["data"].append(duplicate[2]["data"][0])
    with pytest.raises(IdentityAllocationError, match="workflow-response-ambiguous"):
        list_workflow_metadata(FixtureClient(duplicate))

    malformed = _workflow_responses()
    malformed[2]["data"][0]["attributes"]["actions"][1]["scheme"] = ""
    with pytest.raises(IdentityAllocationError, match="workflow-archive-action-invalid"):
        list_workflow_metadata(FixtureClient(malformed))

    malformed_pagination = _workflow_responses()
    malformed_pagination[2]["links"] = []
    with pytest.raises(IdentityAllocationError, match="workflow-pagination-invalid"):
        list_workflow_metadata(FixtureClient(malformed_pagination))


def test_cli_artifact_download_mode(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    action_id = "11111111-2222-3333-4444-555555555555"
    out_dir = tmp_path / "downloads"
    artifact_data = b"ZIP_BUNDLE_DATA"

    monkeypatch.setattr("allocate_identity.make_token_provider", lambda: None)
    monkeypatch.setattr(
        "allocate_identity.ASCClient",
        lambda provider: FixtureClient(
            [
                {
                    "data": [
                        {
                            "type": "ciArtifacts",
                            "id": "res-1",
                            "attributes": {
                                "fileType": "RESULT_BUNDLE",
                                "fileName": "Test.xcresult.zip",
                                "fileSize": len(artifact_data),
                                "downloadUrl": "https://example.com/test.zip",
                            },
                        }
                    ]
                }
            ]
        ),
    )

    class MockStream:
        def __init__(self, data):
            self.data = data
            self.offset = 0
            self.status = 200

        def read(self, amt=-1):
            if self.offset >= len(self.data):
                return b""
            chunk = self.data[self.offset :]
            self.offset += len(chunk)
            return chunk

        def close(self):
            pass

    monkeypatch.setattr(
        "xcode_cloud_artifact._default_download_transport",
        lambda req, timeout: MockStream(artifact_data),
    )

    status = main(["--ci-build-action-id", action_id, "--output-dir", str(out_dir)])
    assert status == 0
    downloaded_file = out_dir / "Test.xcresult.zip"
    assert downloaded_file.is_file()
    assert downloaded_file.read_bytes() == artifact_data


def test_cli_rejects_conflicting_and_missing_arguments() -> None:
    # Conflicting arguments
    assert (
        main(
            [
                "--product",
                "gradus-ios",
                "--ci-build-action-id",
                "11111111-2222-3333-4444-555555555555",
            ]
        )
        == 1
    )
    # Missing arguments
    assert main([]) == 1
    # Only action ID without output dir
    assert main(["--ci-build-action-id", "11111111-2222-3333-4444-555555555555"]) == 1


def _toolchain_responses(*, xcode_version="26.7", macos_version=None):
    """Workflow template, then the two version records it points at."""
    template = {
        "data": {
            "type": "ciWorkflows",
            "attributes": {"containerFilePath": "app/Gradus.xcodeproj", "clean": True},
            "relationships": {
                "repository": {"data": {"type": "scmRepositories", "id": "repo-1"}},
                "xcodeVersion": {"data": {"type": "ciXcodeVersions", "id": "xcode-1"}},
                "macOsVersion": {"data": {"type": "ciMacOsVersions", "id": "macos-1"}},
            },
        }
    }
    xcode_attributes = {"name": "Latest Release"}
    if xcode_version is not None:
        xcode_attributes["version"] = xcode_version
    macos_attributes = {"name": "Latest Release"}
    if macos_version is not None:
        macos_attributes["version"] = macos_version
    actions = {
        "data": {
            "type": "ciWorkflows",
            "attributes": {
                "actions": [
                    {"actionType": "ARCHIVE", "scheme": "GradusiOS", "testDestinations": []},
                    {
                        "actionType": "TEST",
                        "name": "Test - iOS",
                        "scheme": "GradusiOS",
                        "platform": "IOS",
                        "destination": "ANY_IOS_SIMULATOR",
                        "testConfiguration": {"devices": ["d1", "d2"]},
                    },
                ]
            },
        }
    }
    return [
        template,
        {"data": {"type": "ciXcodeVersions", "id": "xcode-1", "attributes": xcode_attributes}},
        {"data": {"type": "ciMacOsVersions", "id": "macos-1", "attributes": macos_attributes}},
        actions,
    ]


def test_resolve_workflow_toolchain_names_the_versions_behind_opaque_ids(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    """The point of the mode: turn an opaque ID into the concrete build Cloud uses."""
    client = FixtureClient(_toolchain_responses())
    assert resolve_workflow_toolchain(client, "workflow-1") == {
        "xcodeVersion": {"id": "xcode-1", "name": "Latest Release", "version": "26.7"},
        "macOsVersion": {"id": "macos-1", "name": "Latest Release"},
        "testDestinations": [
            {
                "name": "Test - iOS",
                "scheme": "GradusiOS",
                "platform": "IOS",
                "destination": "ANY_IOS_SIMULATOR",
                "deviceCount": 2,
            }
        ],
    }
    assert client.paths[1:] == [
        "/ciXcodeVersions/xcode-1?fields[ciXcodeVersions]=name,version",
        "/ciMacOsVersions/macos-1?fields[ciMacOsVersions]=name,version",
        "/ciWorkflows/workflow-1?fields[ciWorkflows]=actions",
    ]

    monkeypatch.setattr("allocate_identity.make_token_provider", lambda: None)
    monkeypatch.setattr(
        "allocate_identity.ASCClient",
        lambda provider: FixtureClient(_toolchain_responses()),
    )
    assert main(["--resolve-workflow-toolchain", "workflow-1"]) == 0
    assert json.loads(capsys.readouterr().out)["xcodeVersion"]["version"] == "26.7"


def test_resolve_workflow_toolchain_rejects_a_mistyped_version_record() -> None:
    """A wrong resource type means the ID was resolved against the wrong collection."""
    responses = _toolchain_responses()
    responses[1] = {"data": {"type": "ciMacOsVersions", "attributes": {"name": "Latest Release"}}}
    with pytest.raises(IdentityAllocationError, match="ciXcodeVersions-response-invalid"):
        resolve_workflow_toolchain(FixtureClient(responses), "workflow-1")


def test_list_ci_builds_alone_dispatches_instead_of_falling_through(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """The flag validated its arguments and then reached no dispatch at all."""
    monkeypatch.setattr("allocate_identity.make_token_provider", lambda: None)
    monkeypatch.setattr(
        "allocate_identity.ASCClient",
        lambda provider: FixtureClient(
            [
                {
                    "data": [
                        {
                            "id": "build-24",
                            "attributes": {
                                "version": "24",
                                "processingState": "PROCESSING",
                                "buildAudienceType": "INTERNAL_ONLY",
                            },
                        }
                    ]
                }
            ]
        ),
    )
    assert main(["--list-ci-builds", "run-1"]) == 0
    assert json.loads(capsys.readouterr().out) == [
        {
            "buildId": "build-24",
            "buildNumber": "24",
            "processingState": "PROCESSING",
            "distributionAudience": "INTERNAL_ONLY",
        }
    ]


def test_resolve_workflow_toolchain_alone_is_a_recognised_action(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Regression guard for the --list-ci-builds class of bug: the flag must dispatch."""
    monkeypatch.setattr("allocate_identity.make_token_provider", lambda: None)
    monkeypatch.setattr(
        "allocate_identity.ASCClient",
        lambda provider: FixtureClient(_toolchain_responses()),
    )
    assert main(["--resolve-workflow-toolchain", "workflow-1"]) == 0
