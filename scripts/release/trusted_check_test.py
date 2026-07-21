#!/usr/bin/env python3
# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import base64
import copy
from collections import defaultdict, deque
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from typing import Any, Callable, Mapping
from unittest import mock
import zipfile


MODULE_PATH = Path(__file__).with_name("trusted_check.py")
SPEC = importlib.util.spec_from_file_location("studio_trusted_check", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
trusted_check = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = trusted_check
SPEC.loader.exec_module(trusted_check)


HEAD = "1" * 40
BASE = "2" * 40
TREE = "3" * 40
MERGE = "4" * 40
UPSTREAM = "5" * 40
SHA = "a" * 64
REPOSITORY_ID = 4242
PULL_NUMBER = 7
RUN_ID = 700
ARTIFACT_ID = 701
CHECK_APP_ID = 987654
TOKEN = "ghs_" + "x" * 36


def json_response(value: Any, status: int = 200, **headers: str) -> Any:
    return trusted_check.HttpResponse(
        status=status,
        headers={"Content-Type": "application/json", **headers},
        body=json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8"),
    )


class MockHttpTransport:
    def __init__(self) -> None:
        self.routes: dict[
            tuple[str, str],
            deque[Any],
        ] = defaultdict(deque)
        self.requests: list[dict[str, Any]] = []

    def add(self, method: str, url: str, *responses: Any) -> None:
        self.routes[(method, url)].extend(responses)

    def request(
        self,
        method: str,
        url: str,
        headers: Mapping[str, str],
        body: bytes | None,
        maximum_response_bytes: int,
    ) -> Any:
        request = {
            "body": body,
            "headers": dict(headers),
            "maximum": maximum_response_bytes,
            "method": method,
            "url": url,
        }
        self.requests.append(request)
        route = self.routes.get((method, url))
        if not route:
            raise AssertionError(f"unexpected HTTP request: {method} {url}")
        response = route.popleft()
        if callable(response):
            response = response(request)
        if not isinstance(response, trusted_check.HttpResponse):
            raise AssertionError("mock response is not HttpResponse")
        if len(response.body) > maximum_response_bytes:
            raise trusted_check.TrustedCheckError("github_response_too_large")
        return response

    def posted(self) -> list[dict[str, Any]]:
        return [request for request in self.requests if request["method"] == "POST"]

    def assert_drained(self) -> None:
        remaining = {
            key: len(values) for key, values in self.routes.items() if values
        }
        if remaining:
            raise AssertionError(f"unused mock routes: {remaining}")


def canonical_record(record: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "record": dict(record),
        "sha256": trusted_check.sha256_bytes(
            trusted_check.canonical_json_bytes(record)
        ),
    }


def zip_receipt(receipt: Mapping[str, Any], *, mode: int = stat.S_IFREG | 0o644) -> bytes:
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as zipped:
        entry = zipfile.ZipInfo(trusted_check.RELEASE_GATE_RECEIPT)
        entry.create_system = 3
        entry.external_attr = mode << 16
        zipped.writestr(entry, trusted_check.canonical_json_bytes(receipt))
    return output.getvalue()


class Scenario:
    def __init__(
        self,
        *,
        candidate_mutator: Callable[[dict[str, Any]], None] | None = None,
        release_gate_bytes: bytes | None = None,
        check_conclusion: str = "success",
        job_conclusion: str = "success",
        receipt_status: str = "pass",
        artifact_digest: str | None = None,
        final_pull_mutator: Callable[[dict[str, Any]], None] | None = None,
        installation_repository_count: int = 1,
        artifact_location: str = "https://objects.githubusercontent.com/release-gate.zip?sig=safe",
        installation_permissions: Mapping[str, str] | None = None,
        existing_trusted_check: bool = False,
        later_trusted_check_status: str | None = None,
        same_name_wrong_workflow: bool = False,
        required_workflow_path_override: str | None = None,
        newer_required_workflow_conclusion: str | None = None,
    ) -> None:
        root = Path(__file__).resolve().parents[2]
        approved_release_gate = (
            root / trusted_check.RELEASE_GATE_WORKFLOW_PATH
        ).read_bytes()
        self.release_gate_bytes = (
            approved_release_gate
            if release_gate_bytes is None
            else release_gate_bytes
        )

        artifact_bundle = "b" * 64
        source_sha = "c" * 64
        basis_sha = "d" * 64
        readiness = {
            "capabilities": {
                "auth": {"referenceProfile": {"status": "pass"}},
                "linear": {
                    name: {"status": "pass"}
                    for name in trusted_check.REQUIRED_LINEAR_CAPABILITIES
                },
            },
            "checkout": {
                "source": {
                    "schemaManifestBasisSha256": basis_sha,
                    "sha256": source_sha,
                }
            },
            "codex": {
                "artifactBundleSha256": artifact_bundle,
                "version": "0.144.3",
            },
            "conformance": [
                {"id": evidence_id, "outcome": "pass", "required": True}
                for evidence_id in sorted(trusted_check.REQUIRED_CONFORMANCE_IDS)
            ],
            "manifestVersion": 1,
            "platform": {"osStatus": "pass", "packageStatus": "pass"},
            "runtime": {
                "blockers": [],
                "capabilities": "pass",
                "overall": "pass",
            },
        }
        readiness_raw = json.dumps(
            readiness, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
        schema = {
            "artifacts": {"artifactBundleSha256": artifact_bundle},
            "codex": {
                "version": "0.144.3",
                "versionOutput": "codex-cli 0.144.3",
            },
            "compatibility": {
                "fixtures": "pass",
                "overall": "pass",
                "runtimeCapabilities": "pass",
                "runtimeEvidence": {
                    "readinessManifestSha256": trusted_check.sha256_bytes(
                        readiness_raw
                    ),
                    "schemaManifestBasisSha256": basis_sha,
                    "sourceSha256": source_sha,
                },
                "schemaContract": "pass",
                "transportConformance": "pass",
            },
            "manifestVersion": 1,
        }
        schema_raw = json.dumps(
            schema, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")

        self.files = {
            ".github/workflows/make-all.yml": b"name: make-all\n",
            ".github/workflows/pr-description-lint.yml": b"name: pr-description-lint\n",
            trusted_check.RELEASE_GATE_WORKFLOW_PATH: self.release_gate_bytes,
            ".github/workflows/publish-release.yml": b"name: publish-release\n",
            "scripts/release/release.py": b"# release contract\n",
            trusted_check.READINESS_PATH: readiness_raw,
            trusted_check.SCHEMA_MANIFEST_PATH: schema_raw,
        }

        reviews = []
        for role, digest_character in (("evidence", "e"), ("release-security", "f")):
            reviews.append(
                canonical_record(
                    {
                        "blockingFindings": [],
                        "completedAt": "2026-07-21T10:00:00Z",
                        "evidenceSha256": digest_character * 64,
                        "exactHead": HEAD,
                        "exactTree": TREE,
                        "kind": "independent-review",
                        "role": role,
                        "verdict": "GO",
                    }
                )
            )
        test_evidence = canonical_record(
            {
                "blockingFindings": [],
                "command": ["make", "release-gate"],
                "completedAt": "2026-07-21T10:00:00Z",
                "exactHead": HEAD,
                "exactTree": TREE,
                "id": "r0-07-complete-gate",
                "kind": "test-evidence",
                "status": "pass",
                "summarySha256": "9" * 64,
            }
        )
        self.candidate = {
            "approvedWaiverIds": [],
            "baseSha": BASE,
            "candidateTreeSha": TREE,
            "codex": {
                "artifactBundleSha256": artifact_bundle,
                "version": "0.144.3",
            },
            "generatedAt": "2026-07-21T10:00:00Z",
            "kind": "release-candidate-manifest",
            "manifestVersion": 1,
            "migrationPlan": {
                "classification": "none",
                "databaseSchemaVersion": None,
                "migrations": [],
            },
            "previousStableTag": None,
            "readiness": {
                "path": trusted_check.READINESS_PATH,
                "sha256": trusted_check.sha256_bytes(readiness_raw),
            },
            "releaseBranch": trusted_check.RELEASE_BRANCH,
            "releaseHeadSha": HEAD,
            "repository": trusted_check.REPOSITORY,
            "requiredChecks": list(trusted_check.REQUIRED_CHECKS),
            "reviewEvidence": reviews,
            "schemaManifest": {
                "path": trusted_check.SCHEMA_MANIFEST_PATH,
                "sha256": trusted_check.sha256_bytes(schema_raw),
            },
            "sourceDateEpoch": 1784628000,
            "specificationStage": trusted_check.STAGE,
            "supportedPlatforms": [
                {
                    "architecture": "x86_64",
                    "distribution": "Debian GNU/Linux 12",
                    "kernel": "Linux",
                    "packageKind": "prebuilt-escript-source-archive",
                }
            ],
            "testEvidence": [test_evidence],
            "testedMergeTreeSha": TREE,
            "upstreamBaseSha": UPSTREAM,
            "version": trusted_check.VERSION,
            "workflowProvenance": {
                path: trusted_check.sha256_bytes(self.files[path])
                for path in trusted_check.REQUIRED_WORKFLOW_PATHS
            },
        }
        approved_review_hashes = {
            item["record"]["role"]: item["sha256"] for item in reviews
        }
        approved_complete_gate_hash = test_evidence["sha256"]
        if candidate_mutator is not None:
            candidate_mutator(self.candidate)
        self.approvals = trusted_check.ApprovalInputs(
            file_sha256={
                path: (
                    trusted_check.TRUSTED_RELEASE_GATE_SHA256
                    if path == trusted_check.RELEASE_GATE_WORKFLOW_PATH
                    else trusted_check.sha256_bytes(self.files[path])
                )
                for path in trusted_check.REQUIRED_WORKFLOW_PATHS
            },
            review_record_sha256=approved_review_hashes,
            complete_gate_record_sha256=approved_complete_gate_hash,
            trusted_app_id=CHECK_APP_ID,
        )
        candidate_raw = trusted_check.canonical_json_bytes(self.candidate)
        candidate_sha = trusted_check.sha256_bytes(candidate_raw)
        body = (
            f"Candidate manifest SHA-256: `{candidate_sha}`\n\n"
            "<details>\n"
            "<summary>Canonical immutable candidate manifest for this exact head"
            "</summary>\n\n```json\n"
            + candidate_raw.decode("utf-8").rstrip("\n")
            + "\n```\n\n</details>\n"
        )
        self.pull = {
            "base": {
                "ref": trusted_check.BASE_BRANCH,
                "repo": {
                    "full_name": trusted_check.REPOSITORY,
                    "id": REPOSITORY_ID,
                },
                "sha": BASE,
            },
            "body": body,
            "draft": False,
            "head": {
                "ref": trusted_check.RELEASE_BRANCH,
                "repo": {
                    "full_name": trusted_check.REPOSITORY,
                    "id": REPOSITORY_ID,
                },
                "sha": HEAD,
            },
            "merge_commit_sha": MERGE,
            "mergeable": True,
            "merged": False,
            "number": PULL_NUMBER,
            "state": "open",
            "title": "Release v0.1.0 — verified Symphony foundation",
        }
        final_pull = copy.deepcopy(self.pull)
        if final_pull_mutator is not None:
            final_pull_mutator(final_pull)

        self.checks = {
            "check_runs": [
                {
                    "app": {"id": trusted_check.GITHUB_ACTIONS_APP_ID},
                    "check_suite": {"id": 500 + index},
                    "conclusion": check_conclusion,
                    "head_sha": HEAD,
                    "id": 100 + index,
                    "name": name,
                    "pull_requests": [],
                    "status": "completed",
                }
                for index, name in enumerate(trusted_check.REQUIRED_CHECKS[:-1])
            ],
            "total_count": 2,
        }
        if existing_trusted_check:
            trusted_payload = trusted_check._check_payload(
                PULL_NUMBER, HEAD, candidate_raw, candidate_sha
            )
            self.checks["check_runs"].append(
                {
                    **trusted_payload,
                    "app": {"id": CHECK_APP_ID},
                    "id": 899,
                    "output": {
                        **trusted_payload["output"],
                        "annotations_count": 0,
                        "annotations_url": (
                            f"{trusted_check.API_BASE}/repos/"
                            f"{trusted_check.REPOSITORY}/check-runs/899/annotations"
                        ),
                    },
                    "pull_requests": [],
                }
            )
            self.checks["total_count"] = 3
            if later_trusted_check_status is not None:
                later = copy.deepcopy(self.checks["check_runs"][-1])
                later["id"] = 901
                later["status"] = later_trusted_check_status
                later["conclusion"] = None
                self.checks["check_runs"].append(later)
                self.checks["total_count"] = 4
        if same_name_wrong_workflow:
            self.checks["check_runs"].append(
                {
                    "app": {"id": trusted_check.GITHUB_ACTIONS_APP_ID},
                    "check_suite": {"id": 999},
                    "conclusion": "success",
                    "head_sha": HEAD,
                    "id": 999,
                    "name": "make-all",
                    "pull_requests": [],
                    "status": "completed",
                }
            )
            self.checks["total_count"] += 1
        self.required_workflow_runs: dict[str, dict[str, Any]] = {}
        for index, name in enumerate(trusted_check.REQUIRED_CHECKS[:-1]):
            workflow_path = f".github/workflows/{name}.yml"
            if name == "make-all" and required_workflow_path_override is not None:
                workflow_path = required_workflow_path_override
            self.required_workflow_runs[name] = {
                "total_count": 1,
                "workflow_runs": [
                    {
                        "check_suite_id": 500 + index,
                        "conclusion": check_conclusion,
                        "event": "pull_request",
                        "head_branch": trusted_check.RELEASE_BRANCH,
                        "head_repository": {
                            "full_name": trusted_check.REPOSITORY
                        },
                        "head_sha": HEAD,
                        "id": 600 + index,
                        "name": name,
                        "path": workflow_path,
                        "pull_requests": [],
                        "repository": {"full_name": trusted_check.REPOSITORY},
                        "run_attempt": 1,
                        "status": "completed",
                    }
                ],
            }
            if name == "make-all" and newer_required_workflow_conclusion is not None:
                self.required_workflow_runs[name]["workflow_runs"].append(
                    {
                        **self.required_workflow_runs[name]["workflow_runs"][0],
                        "check_suite_id": 998,
                        "conclusion": newer_required_workflow_conclusion,
                        "id": 998,
                    }
                )
                self.required_workflow_runs[name]["total_count"] = 2
        self.workflow_runs = {
            "total_count": 1,
            "workflow_runs": [
                {
                    "check_suite_id": 699,
                    "conclusion": "success",
                    "event": "pull_request",
                    "head_branch": trusted_check.RELEASE_BRANCH,
                    "head_repository": {
                        "full_name": trusted_check.REPOSITORY
                    },
                    "head_sha": HEAD,
                    "id": RUN_ID,
                    "name": "release-gate",
                    "path": trusted_check.RELEASE_GATE_WORKFLOW_PATH,
                    "pull_requests": [],
                    "repository": {"full_name": trusted_check.REPOSITORY},
                    "run_attempt": 1,
                    "status": "completed",
                }
            ],
        }
        self.jobs = {
            "jobs": [
                {
                    "conclusion": job_conclusion,
                    "head_sha": HEAD,
                    "name": trusted_check.RELEASE_GATE_JOB_NAME,
                    "status": "completed",
                    "steps": [
                        {
                            "conclusion": "success",
                            "name": name,
                            "status": "completed",
                        }
                        for name in trusted_check.REQUIRED_RELEASE_GATE_STEPS
                    ],
                }
            ],
            "total_count": 1,
        }
        receipt = {
            "blockingFindings": [],
            "exactHead": HEAD,
            "exactTree": TREE,
            "id": "r0-07-release-specific-gate",
            "kind": "test-evidence",
            "status": receipt_status,
        }
        self.archive = zip_receipt(receipt)
        digest = (
            trusted_check.sha256_bytes(self.archive)
            if artifact_digest is None
            else artifact_digest
        )
        self.artifacts = {
            "artifacts": [
                {
                    "digest": f"sha256:{digest}",
                    "expired": False,
                    "id": ARTIFACT_ID,
                    "name": trusted_check.RELEASE_GATE_ARTIFACT_PREFIX + HEAD,
                    "size_in_bytes": len(self.archive),
                    "workflow_run": {"head_sha": HEAD, "id": RUN_ID},
                }
            ],
            "total_count": 1,
        }

        self.transport = MockHttpTransport()
        api = trusted_check.API_BASE
        expected_permissions = {
            "actions": "read",
            "checks": "write",
            "contents": "read",
            "metadata": "read",
            "pull_requests": "read",
        }
        self.transport.add(
            "GET",
            api + "/installation",
            json_response(
                {
                    "app_id": CHECK_APP_ID,
                    "id": 77,
                    "permissions": dict(
                        expected_permissions
                        if installation_permissions is None
                        else installation_permissions
                    ),
                    "repository_selection": "selected",
                    "suspended_at": None,
                }
            ),
        )
        repositories = [
            {"full_name": trusted_check.REPOSITORY, "id": REPOSITORY_ID}
        ]
        for index in range(1, installation_repository_count):
            repositories.append(
                {"full_name": f"example/extra-{index}", "id": REPOSITORY_ID + index}
            )
        self.transport.add(
            "GET",
            api + "/installation/repositories?per_page=100",
            json_response(
                {"repositories": repositories, "total_count": len(repositories)}
            ),
        )
        self.transport.add(
            "GET",
            api + trusted_check._pull_path(PULL_NUMBER),
            json_response(self.pull),
            json_response(final_pull),
        )
        ref_response = json_response(
            {"object": {"sha": BASE, "type": "commit"}}
        )
        self.transport.add(
            "GET",
            api + trusted_check._main_ref_path(),
            ref_response,
            ref_response,
        )
        self.transport.add(
            "GET",
            api + f"/repos/{trusted_check.REPOSITORY}/git/commits/{HEAD}",
            json_response({"sha": HEAD, "tree": {"sha": TREE}}),
        )
        self.transport.add(
            "GET",
            api + f"/repos/{trusted_check.REPOSITORY}/git/commits/{MERGE}",
            json_response(
                {
                    "parents": [{"sha": BASE}, {"sha": HEAD}],
                    "sha": MERGE,
                    "tree": {"sha": TREE},
                }
            ),
        )
        for path, raw in self.files.items():
            self.transport.add(
                "GET",
                api + trusted_check._content_path(path, HEAD),
                json_response(
                    {
                        "content": base64.b64encode(raw).decode("ascii"),
                        "encoding": "base64",
                        "path": path,
                        "sha": trusted_check.git_blob_sha1(raw),
                        "size": len(raw),
                        "type": "file",
                    }
                ),
            )
        self.transport.add(
            "GET",
            api + trusted_check._check_runs_path(HEAD),
            json_response(self.checks),
            json_response(self.checks),
        )
        for index, name in enumerate(trusted_check.REQUIRED_CHECKS[:-1]):
            suite_id = 500 + index
            self.transport.add(
                "GET",
                api
                + f"/repos/{trusted_check.REPOSITORY}/check-suites/{suite_id}",
                json_response(
                    {
                        "app": {"id": trusted_check.GITHUB_ACTIONS_APP_ID},
                        "conclusion": check_conclusion,
                        "head_branch": trusted_check.RELEASE_BRANCH,
                        "head_sha": HEAD,
                        "id": suite_id,
                        "repository": {
                            "full_name": trusted_check.REPOSITORY
                        },
                        "status": "completed",
                    }
                ),
            )
            workflow_file = f"{name}.yml"
            self.transport.add(
                "GET",
                api + trusted_check._workflow_runs_path(workflow_file, HEAD),
                json_response(self.required_workflow_runs[name]),
                json_response(self.required_workflow_runs[name]),
            )
        if same_name_wrong_workflow:
            self.transport.add(
                "GET",
                api + f"/repos/{trusted_check.REPOSITORY}/check-suites/999",
                json_response(
                    {
                        "app": {"id": trusted_check.GITHUB_ACTIONS_APP_ID},
                        "conclusion": "success",
                        "head_branch": trusted_check.RELEASE_BRANCH,
                        "head_sha": HEAD,
                        "id": 999,
                        "repository": {"full_name": trusted_check.REPOSITORY},
                        "status": "completed",
                    }
                ),
            )
        self.transport.add(
            "GET",
            api + trusted_check._release_gate_runs_path(HEAD),
            json_response(self.workflow_runs),
            json_response(self.workflow_runs),
        )
        self.transport.add(
            "GET",
            api
            + f"/repos/{trusted_check.REPOSITORY}/actions/runs/{RUN_ID}/jobs"
            "?filter=latest&per_page=100",
            json_response(self.jobs),
        )
        self.transport.add(
            "GET",
            api
            + f"/repos/{trusted_check.REPOSITORY}/actions/runs/{RUN_ID}/artifacts"
            "?per_page=100",
            json_response(self.artifacts),
        )
        self.transport.add(
            "GET",
            api
            + f"/repos/{trusted_check.REPOSITORY}/actions/artifacts/{ARTIFACT_ID}/zip",
            trusted_check.HttpResponse(
                status=302, headers={"Location": artifact_location}, body=b""
            ),
        )
        self.transport.add(
            "GET",
            artifact_location,
            trusted_check.HttpResponse(status=200, headers={}, body=self.archive),
        )

        def created_check(request: Mapping[str, Any]) -> Any:
            payload = json.loads(request["body"])
            return json_response(
                {
                    **payload,
                    "app": {"id": CHECK_APP_ID},
                    "id": 900,
                    "output": {
                        **payload["output"],
                        "annotations_count": 0,
                        "annotations_url": (
                            f"{trusted_check.API_BASE}/repos/"
                            f"{trusted_check.REPOSITORY}/check-runs/900/annotations"
                        ),
                    },
                    "pull_requests": [],
                },
                status=201,
            )

        if existing_trusted_check:
            existing = max(
                (
                    run
                    for run in self.checks["check_runs"]
                    if run.get("name") == trusted_check.CHECK_NAME
                ),
                key=lambda run: run["id"],
            )
            self.transport.add(
                "GET",
                api
                + f"/repos/{trusted_check.REPOSITORY}/check-runs/"
                + str(existing["id"]),
                json_response(existing),
            )
        else:
            self.transport.add(
                "POST",
                api + f"/repos/{trusted_check.REPOSITORY}/check-runs",
                created_check,
            )


class TrustedCheckTest(unittest.TestCase):
    def test_happy_path_posts_exact_check_after_all_live_validations(self) -> None:
        scenario = Scenario()
        receipt = trusted_check.attest(
            PULL_NUMBER,
            HEAD,
            TOKEN,
            scenario.approvals,
            transport=scenario.transport,
        )
        self.assertEqual(receipt["status"], "pass")
        self.assertEqual(receipt["checkRunId"], 900)
        requests = scenario.transport.requests
        self.assertEqual(requests[-1]["method"], "POST")
        self.assertEqual(len(scenario.transport.posted()), 1)
        payload = json.loads(requests[-1]["body"])
        candidate_raw = trusted_check.canonical_json_bytes(scenario.candidate)
        digest = trusted_check.sha256_bytes(candidate_raw)
        self.assertEqual(payload["name"], trusted_check.CHECK_NAME)
        self.assertEqual(payload["head_sha"], HEAD)
        self.assertEqual(payload["external_id"], digest)
        self.assertEqual(payload["status"], "completed")
        self.assertEqual(payload["conclusion"], "success")
        self.assertEqual(
            payload["output"],
            {
                "summary": f"candidate-manifest-sha256:{digest}",
                "text": "candidate-manifest-base64:"
                + base64.b64encode(candidate_raw).decode("ascii"),
                "title": trusted_check.CHECK_TITLE,
            },
        )
        artifact_requests = [
            request
            for request in requests
            if request["url"].startswith("https://objects.githubusercontent.com/")
        ]
        self.assertEqual(len(artifact_requests), 1)
        self.assertNotIn("Authorization", artifact_requests[0]["headers"])
        api_requests = [
            request
            for request in requests
            if request["url"].startswith(trusted_check.API_BASE)
        ]
        self.assertTrue(api_requests)
        self.assertTrue(
            all(
                request["headers"].get("Authorization") == f"Bearer {TOKEN}"
                for request in api_requests
            )
        )
        self.assertNotIn(TOKEN.encode(), requests[-1]["body"])
        scenario.transport.assert_drained()

    def test_token_is_environment_only_and_consumed(self) -> None:
        environment = {trusted_check.TOKEN_ENVIRONMENT_VARIABLE: TOKEN}
        self.assertEqual(trusted_check.consume_token(environment), TOKEN)
        self.assertNotIn(trusted_check.TOKEN_ENVIRONMENT_VARIABLE, environment)
        for invalid in (None, "", "short", "x\nheader", "x" * 5000):
            with self.subTest(invalid=repr(invalid)):
                candidate: dict[str, str] = {}
                if invalid is not None:
                    candidate[trusted_check.TOKEN_ENVIRONMENT_VARIABLE] = invalid
                with self.assertRaisesRegex(
                    trusted_check.TrustedCheckError,
                    "trusted_check_token_missing_or_invalid",
                ):
                    trusted_check.consume_token(candidate)
                self.assertNotIn(
                    trusted_check.TOKEN_ENVIRONMENT_VARIABLE, candidate
                )

    def test_blocking_or_self_asserted_review_never_posts(self) -> None:
        def mutate(candidate: dict[str, Any]) -> None:
            candidate["reviewEvidence"][0]["record"]["verdict"] = "NO-GO"

        scenario = Scenario(candidate_mutator=mutate)
        with self.assertRaisesRegex(
            trusted_check.TrustedCheckError, "candidate_review_evidence_invalid"
        ):
            trusted_check.attest(
                PULL_NUMBER,
                HEAD,
                TOKEN,
                scenario.approvals,
                transport=scenario.transport,
            )
        self.assertEqual(scenario.transport.posted(), [])

    def test_workflow_drift_never_posts_even_when_manifest_matches_drift(self) -> None:
        scenario = Scenario(release_gate_bytes=b"name: attacker-controlled\n")
        with self.assertRaisesRegex(
            trusted_check.TrustedCheckError,
            "candidate_workflow_unapproved",
        ):
            trusted_check.attest(
                PULL_NUMBER,
                HEAD,
                TOKEN,
                scenario.approvals,
                transport=scenario.transport,
            )
        self.assertEqual(scenario.transport.posted(), [])

    def test_latest_required_check_failure_never_posts(self) -> None:
        scenario = Scenario(check_conclusion="failure")
        with self.assertRaisesRegex(
            trusted_check.TrustedCheckError, "required_check_not_successful"
        ):
            trusted_check.attest(
                PULL_NUMBER,
                HEAD,
                TOKEN,
                scenario.approvals,
                transport=scenario.transport,
            )
        self.assertEqual(scenario.transport.posted(), [])

    def test_failed_live_job_never_posts(self) -> None:
        scenario = Scenario(job_conclusion="failure")
        with self.assertRaisesRegex(
            trusted_check.TrustedCheckError, "release_gate_job_not_successful"
        ):
            trusted_check.attest(
                PULL_NUMBER,
                HEAD,
                TOKEN,
                scenario.approvals,
                transport=scenario.transport,
            )
        self.assertEqual(scenario.transport.posted(), [])

    def test_artifact_digest_or_receipt_failure_never_posts(self) -> None:
        for scenario, message in (
            (
                Scenario(artifact_digest="0" * 64),
                "release_gate_artifact_digest_mismatch",
            ),
            (Scenario(receipt_status="fail"), "release_gate_receipt_invalid"),
        ):
            with self.subTest(message=message):
                with self.assertRaisesRegex(
                    trusted_check.TrustedCheckError, message
                ):
                    trusted_check.attest(
                        PULL_NUMBER,
                        HEAD,
                        TOKEN,
                        scenario.approvals,
                        transport=scenario.transport,
                    )
                self.assertEqual(scenario.transport.posted(), [])

    def test_changed_pr_during_final_revalidation_never_posts(self) -> None:
        def change_body(pull: dict[str, Any]) -> None:
            pull["body"] += "\nchanged after validation\n"

        scenario = Scenario(final_pull_mutator=change_body)
        with self.assertRaisesRegex(
            trusted_check.TrustedCheckError, "release_pull_request_changed"
        ):
            trusted_check.attest(
                PULL_NUMBER,
                HEAD,
                TOKEN,
                scenario.approvals,
                transport=scenario.transport,
            )
        self.assertEqual(scenario.transport.posted(), [])

    def test_token_must_be_scoped_to_only_the_release_repository(self) -> None:
        scenario = Scenario(installation_repository_count=2)
        with self.assertRaisesRegex(
            trusted_check.TrustedCheckError,
            "github_app_installation_scope_invalid",
        ):
            trusted_check.attest(
                PULL_NUMBER,
                HEAD,
                TOKEN,
                scenario.approvals,
                transport=scenario.transport,
            )
        self.assertEqual(scenario.transport.posted(), [])

    def test_unapproved_artifact_redirect_never_receives_token_or_posts(self) -> None:
        location = "https://attacker.example/release-gate.zip"
        scenario = Scenario(artifact_location=location)
        with self.assertRaisesRegex(
            trusted_check.TrustedCheckError, "artifact_redirect_invalid"
        ):
            trusted_check.attest(
                PULL_NUMBER,
                HEAD,
                TOKEN,
                scenario.approvals,
                transport=scenario.transport,
            )
        self.assertEqual(scenario.transport.posted(), [])
        self.assertFalse(
            any(request["url"] == location for request in scenario.transport.requests)
        )

    def test_installation_permission_overreach_never_posts(self) -> None:
        scenario = Scenario(
            installation_permissions={
                "actions": "read",
                "checks": "write",
                "contents": "read",
                "issues": "write",
                "metadata": "read",
                "pull_requests": "read",
            }
        )
        with self.assertRaisesRegex(
            trusted_check.TrustedCheckError, "github_app_installation_invalid"
        ):
            trusted_check.attest(
                PULL_NUMBER,
                HEAD,
                TOKEN,
                scenario.approvals,
                transport=scenario.transport,
            )
        self.assertEqual(scenario.transport.posted(), [])

    def test_same_name_check_from_different_workflow_never_posts(self) -> None:
        scenario = Scenario(same_name_wrong_workflow=True)
        with self.assertRaisesRegex(
            trusted_check.TrustedCheckError,
            "required_workflow_check_suite_mismatch",
        ):
            trusted_check.attest(
                PULL_NUMBER,
                HEAD,
                TOKEN,
                scenario.approvals,
                transport=scenario.transport,
            )
        self.assertEqual(scenario.transport.posted(), [])

    def test_required_workflow_run_path_is_plain_and_exact(self) -> None:
        scenario = Scenario(
            required_workflow_path_override=".github/workflows/attacker.yml"
        )
        with self.assertRaisesRegex(
            trusted_check.TrustedCheckError, "required_workflow_run_missing"
        ):
            trusted_check.attest(
                PULL_NUMBER,
                HEAD,
                TOKEN,
                scenario.approvals,
                transport=scenario.transport,
            )
        self.assertEqual(scenario.transport.posted(), [])

    def test_newest_exact_workflow_failure_blocks_older_success(self) -> None:
        scenario = Scenario(newer_required_workflow_conclusion="failure")
        with self.assertRaisesRegex(
            trusted_check.TrustedCheckError,
            "required_workflow_run_not_successful",
        ):
            trusted_check.attest(
                PULL_NUMBER,
                HEAD,
                TOKEN,
                scenario.approvals,
                transport=scenario.transport,
            )
        self.assertEqual(scenario.transport.posted(), [])

    def test_existing_exact_latest_check_is_idempotently_reused(self) -> None:
        scenario = Scenario(existing_trusted_check=True)
        receipt = trusted_check.attest(
            PULL_NUMBER,
            HEAD,
            TOKEN,
            scenario.approvals,
            transport=scenario.transport,
        )
        self.assertEqual(receipt["checkRunId"], 899)
        self.assertEqual(scenario.transport.posted(), [])
        scenario.transport.assert_drained()

    def test_later_incomplete_trusted_check_blocks_older_success(self) -> None:
        scenario = Scenario(
            existing_trusted_check=True,
            later_trusted_check_status="in_progress",
        )
        with self.assertRaisesRegex(
            trusted_check.TrustedCheckError, "trusted_check_latest_mismatch"
        ):
            trusted_check.attest(
                PULL_NUMBER,
                HEAD,
                TOKEN,
                scenario.approvals,
                transport=scenario.transport,
            )
        self.assertEqual(scenario.transport.posted(), [])

    def test_candidate_shaped_review_requires_owner_approved_digest(self) -> None:
        def mutate(candidate: dict[str, Any]) -> None:
            item = candidate["reviewEvidence"][0]
            item["record"]["evidenceSha256"] = "0" * 64
            item["sha256"] = trusted_check.sha256_bytes(
                trusted_check.canonical_json_bytes(item["record"])
            )

        scenario = Scenario(candidate_mutator=mutate)
        with self.assertRaisesRegex(
            trusted_check.TrustedCheckError,
            "candidate_review_evidence_unapproved",
        ):
            trusted_check.attest(
                PULL_NUMBER,
                HEAD,
                TOKEN,
                scenario.approvals,
                transport=scenario.transport,
            )
        self.assertEqual(scenario.transport.posted(), [])

    def test_candidate_shaped_complete_gate_requires_owner_approved_digest(
        self,
    ) -> None:
        def mutate(candidate: dict[str, Any]) -> None:
            item = candidate["testEvidence"][0]
            item["record"]["summarySha256"] = "0" * 64
            item["sha256"] = trusted_check.sha256_bytes(
                trusted_check.canonical_json_bytes(item["record"])
            )

        scenario = Scenario(candidate_mutator=mutate)
        with self.assertRaisesRegex(
            trusted_check.TrustedCheckError,
            "candidate_complete_gate_evidence_unapproved",
        ):
            trusted_check.attest(
                PULL_NUMBER,
                HEAD,
                TOKEN,
                scenario.approvals,
                transport=scenario.transport,
            )
        self.assertEqual(scenario.transport.posted(), [])

    def test_candidate_file_requires_owner_approved_digest(self) -> None:
        scenario = Scenario()
        file_sha256 = dict(scenario.approvals.file_sha256)
        file_sha256[".github/workflows/make-all.yml"] = "0" * 64
        approvals = trusted_check.ApprovalInputs(
            file_sha256=file_sha256,
            review_record_sha256=scenario.approvals.review_record_sha256,
            complete_gate_record_sha256=(
                scenario.approvals.complete_gate_record_sha256
            ),
            trusted_app_id=scenario.approvals.trusted_app_id,
        )
        with self.assertRaisesRegex(
            trusted_check.TrustedCheckError, "candidate_workflow_unapproved"
        ):
            trusted_check.attest(
                PULL_NUMBER,
                HEAD,
                TOKEN,
                approvals,
                transport=scenario.transport,
            )
        self.assertEqual(scenario.transport.posted(), [])

    def test_attestor_is_sealed_and_reverified_outside_a_worktree(self) -> None:
        with tempfile.TemporaryDirectory() as directory_text:
            directory = Path(directory_text)
            directory.chmod(0o700)
            destination = directory / "trusted_check.py"
            with mock.patch.dict(os.environ, {}, clear=True):
                receipt = trusted_check.seal_attestor(str(destination))
            self.assertEqual(receipt["status"], "pass")
            self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o500)
            with mock.patch.object(trusted_check, "__file__", str(destination)):
                self.assertEqual(
                    trusted_check.verify_sealed_runtime(
                        receipt["attestorSha256"]
                    ),
                    receipt["attestorSha256"],
                )

        current_digest = trusted_check.sha256_bytes(MODULE_PATH.read_bytes())
        with self.assertRaisesRegex(
            trusted_check.TrustedCheckError, "attestor_runtime_path_invalid"
        ):
            trusted_check.verify_sealed_runtime(current_digest)

    def test_public_attestor_digest_matches_source(self) -> None:
        expected = (
            trusted_check.sha256_bytes(MODULE_PATH.read_bytes())
            + "  trusted_check.py\n"
        )
        self.assertEqual(
            MODULE_PATH.with_name("trusted_check.sha256").read_text(
                encoding="ascii"
            ),
            expected,
        )

    def test_cli_requires_python_isolated_mode_before_sealing(self) -> None:
        with tempfile.TemporaryDirectory() as directory_text:
            destination = Path(directory_text) / "trusted_check.py"
            errors = io.StringIO()
            with mock.patch("sys.stderr", errors):
                status = trusted_check.main(
                    ["seal", "--output", str(destination)]
                )
            self.assertEqual(status, 78)
            self.assertEqual(
                errors.getvalue(),
                "trusted_check_error:attestor_python_isolation_required\n",
            )
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
