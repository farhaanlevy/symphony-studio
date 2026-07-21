#!/usr/bin/env python3
# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import copy
import contextlib
import hashlib
import inspect
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import socket
import stat
import subprocess
import tempfile
import unittest
from unittest import mock

import studio_readiness as readiness


SHA_A = "a" * 64
SHA_B = "b" * 64
TREE_A = "a" * 40
TREE_B = "b" * 40
SHA_C = "c" * 64
SHA_D = "d" * 64
COMMIT_A = "1" * 40
COMMIT_B = "2" * 40
COMMIT_C = "3" * 40
BINDING_ID = "codex-binding-v1-" + "4" * 64
LINEAR_BINDING = "linear-project-v1-" + "5" * 64


def supervisor_seal() -> readiness.LiveSupervisorSeal:
    return readiness.LiveSupervisorSeal(
        seal_id=SHA_A,
        index_tree=TREE_A,
    )


def schema_manifest(matrix_sha: str = SHA_C) -> dict:
    return {
        "artifacts": {
            "artifactBundleSha256": SHA_A,
            "experimentalJson": {
                "byteCount": 400,
                "fileCount": 4,
                "path": "experimental/json",
                "sha256": SHA_A,
            },
            "experimentalTypescript": {
                "byteCount": 300,
                "fileCount": 3,
                "path": "experimental/typescript",
                "sha256": SHA_B,
            },
            "json": {
                "byteCount": 200,
                "fileCount": 2,
                "path": "json",
                "sha256": SHA_C,
            },
            "schemaBundleSha256": SHA_B,
            "typescript": {
                "byteCount": 100,
                "fileCount": 1,
                "path": "typescript",
                "sha256": SHA_D,
            },
        },
        "codex": {
            "executable": {
                "installedPackageAlias": "@openai/codex-linux-x64",
                "launcherSha256": SHA_C,
                "nativeSha256": SHA_D,
                "platformNpmIntegrity": "sha512-public-platform-fixture",
                "platformPackage": "@openai/codex@0.144.3-linux-x64",
                "target": "x86_64-unknown-linux-musl",
            },
            "npmIntegrity": "sha512-public-fixture",
            "package": "@openai/codex",
            "version": "0.144.3",
            "versionOutput": "codex-cli 0.144.3",
        },
        "compatibility": {
            "fixtureEvidence": {
                "artifactBundleSha256": SHA_A,
                "codexVersion": "0.144.3",
                "command": list(
                    readiness.REQUIRED_CONFORMANCE_COMMANDS[
                        "source_bound_fixture_replay"
                    ][:2]
                    + readiness.REQUIRED_CONFORMANCE_COMMANDS[
                        "source_bound_fixture_replay"
                    ][4:]
                ),
                "dependencyCommand": [
                    "mise",
                    "exec",
                    "--",
                    "mix",
                    "deps.get",
                    "--check-locked",
                ],
                "dependencyCompileCommand": [
                    "mise",
                    "exec",
                    "--",
                    "mix",
                    "deps.compile",
                ],
                "matrixSha256": matrix_sha,
                "schemaBundleSha256": SHA_B,
                "sourceFileCount": 10,
                "sourceHashAlgorithm": "sha256-public-fixture-v1",
                "sourceSha256": SHA_D,
                "testCount": 20,
                "testedAt": "2026-07-17",
            },
            "fixtures": "pass",
            "overall": "pending_r0_06",
            "runtimeCapabilities": "not_run",
            "schemaContract": "pass",
            "testedAt": "2026-07-17",
            "transportConformance": "pass",
        },
        "generation": {
            "cleanCodexHome": True,
            "commands": [
                [
                    "codex",
                    "app-server",
                    "generate-json-schema",
                    "--out",
                    "<bundle>/json",
                ],
                [
                    "codex",
                    "app-server",
                    "generate-ts",
                    "--out",
                    "<bundle>/typescript",
                ],
            ],
            "generatedAt": "2026-07-14",
            "jsonHashAlgorithm": "python-json-public-fixture-v1",
            "typescriptHashAlgorithm": "sha256-public-fixture-v1",
        },
        "manifestVersion": 1,
        "matrix": {
            "path": "method-field-matrix.json",
            "profile": "build-week-chatgpt-reference",
            "sha256": matrix_sha,
        },
    }


def capability_matrix() -> dict:
    base = {
        "absentBehavior": "block_managed_dispatch",
        "r002Assertion": "schema_presence",
        "r006Probe": "read",
        "requirement": "required",
    }
    return {
        "codexVersion": "0.144.3",
        "definitionEqualities": [],
        "fields": [
            {
                **base,
                "id": "models.id",
                "payloadPath": "data[].id",
                "schema": "json/Model.json",
                "schemaPointer": "/properties/id",
                "schemaRequired": True,
            },
            {
                **base,
                "absentBehavior": "hide",
                "id": "models.service_tier_id",
                "payloadPath": "data[].serviceTiers[].id",
                "requirement": "optional",
                "schema": "json/Model.json",
                "schemaPointer": "/properties/serviceTiers",
                "schemaRequired": False,
            },
        ],
        "matrixVersion": 1,
        "methods": [
            {
                **base,
                "channel": "stable",
                "direction": "client_request",
                "id": "account_read",
                "method": "account/read",
                "paramsSchema": "json/AccountParams.json",
                "responseSchema": "json/AccountResponse.json",
            },
            {
                **base,
                "absentBehavior": "hide",
                "channel": "stable",
                "direction": "client_request",
                "id": "account_usage_read",
                "method": "account/usage/read",
                "paramsSchema": None,
                "requirement": "optional",
                "responseSchema": "json/UsageResponse.json",
            },
        ],
        "negativeCapabilities": [
            {
                "expect": "absent",
                "forbiddenDefinition": "MultiAgentV2",
                "forbiddenFileNamePattern": "*MultiAgentV2*",
                "forbiddenReferencePattern": "MultiAgentV2",
                "forbiddenSchemaTitle": "MultiAgentV2",
                "id": "collaboration.no_multi_agent_v2",
                "schemaGlobs": ["json/**/*.json"],
            }
        ],
        "profile": "build-week-chatgpt-reference",
        "r002Status": "schema_only",
        "r006Status": "pending",
    }


def capability_matrix_artifact() -> readiness.MatrixArtifact:
    return readiness.MatrixArtifact(
        readiness.canonical_json_bytes(capability_matrix()), "synthetic matrix fixture"
    )


def static_basis(schema: dict | None = None) -> dict:
    schema = schema or schema_manifest()
    schema_basis = readiness.schema_manifest_basis_sha256(schema)
    source = {
        "algorithm": readiness.SOURCE_ALGORITHM,
        "fileCount": 10,
        "gitObjectFormat": "sha1",
        "readinessPathExcluded": True,
        "schemaManifestBasisSha256": schema_basis,
        "schemaManifestPath": "elixir/priv/codex_schema/0.144.3/manifest.json",
        "sha256": SHA_A,
    }
    return {
        "checkout": {
            "headCommit": COMMIT_C,
            "headSemantics": readiness.HEAD_SEMANTICS,
            "patchLedgerRevision": 24,
            "source": source,
            "upstreamBaseCommit": COMMIT_A,
            "upstreamCommit": COMMIT_B,
        },
        "codex": {
            "artifactBundleSha256": SHA_A,
            "launcherSha256": SHA_C,
            "matrixSha256": schema["matrix"]["sha256"],
            "nativeSha256": SHA_D,
            "schemaBundleSha256": SHA_B,
            "schemaManifestBasisSha256": schema_basis,
            "target": "x86_64-unknown-linux-musl",
            "version": "0.144.3",
            "versionOutput": "codex-cli 0.144.3",
        },
    }


def reference_profile(**overrides: bool | str) -> dict:
    profile = {
        "chatgptAuthentication": True,
        "identityBinding": True,
        "solAvailable": True,
        "solReviewEffort": True,
        "solUltra": True,
        "status": "pass",
        "terraAvailable": True,
        "terraHigh": True,
        "terraMedium": True,
    }
    profile.update(overrides)
    return profile


def public_report(matrix: dict | None = None) -> dict:
    matrix = matrix or capability_matrix()
    return {
        "authMode": "chatgpt",
        "conformance": [
            {
                "command": list(readiness.REQUIRED_CONFORMANCE_COMMANDS[identifier]),
                "id": identifier,
                "outcome": "pass",
                "required": True,
            }
            for identifier in sorted(readiness.REQUIRED_CONFORMANCE_IDS)
        ],
        "identityBinding": {
            "bindingId": BINDING_ID,
            "evidence": "keyed_account_metadata",
            "generation": 1,
            "status": "confirmed",
        },
        "linear": {
            "configuredProjectBinding": LINEAR_BINDING,
            **{
                key: {"status": "pass"}
                for key in readiness.LINEAR_STATUS_KEYS_IN_PROBE_ORDER
                if key != "mutations"
            },
            "mutations": {"evidence": "schema_only", "status": "pass"},
        },
        "matrixOutcomes": {
            "fields": {
                entry["id"]: (
                    "absent" if entry["requirement"] == "optional" else "pass"
                )
                for entry in matrix["fields"]
            },
            "methods": {
                entry["id"]: (
                    "absent" if entry["requirement"] == "optional" else "pass"
                )
                for entry in matrix["methods"]
            },
            "negativeCapabilities": {
                entry["id"]: "pass" for entry in matrix["negativeCapabilities"]
            },
        },
        "models": [
            {
                "defaultServiceTier": None,
                "fastServiceTierId": None,
                "id": "model-terra-opaque",
                "model": "gpt-5.6-terra",
                "reasoningEfforts": ["medium", "high"],
                "serviceTierIds": [],
            },
            {
                "defaultServiceTier": "standard",
                "fastServiceTierId": None,
                "id": "model-sol-opaque",
                "model": "gpt-5.6-sol",
                "reasoningEfforts": ["ultra", "high"],
                "serviceTierIds": ["standard"],
            },
        ],
        "platform": {
            "architecture": "x86_64",
            "os": "linux",
            "osStatus": "pass",
            "package": "source-archive",
            "packageStatus": "pass",
        },
        "quota": {
            "fullRead": "pass",
            "multiBucket": "pass",
            "sparseUpdate": "pass",
            "usage": "absent",
        },
        "referenceProfile": reference_profile(),
        "reportVersion": 1,
        "subagents": {
            "hookFailureClassification": "fail_open",
            "implementation": "multi_agent_v2",
            "nativeDepthEnforcement": False,
            "rawToOptionalChildren": [
                {"optionalChildren": 2, "raw": 3},
                {"optionalChildren": 0, "raw": 1},
                {"optionalChildren": 1, "raw": 2},
            ],
            "rootCountsTowardLimit": True,
            "studioDepthGuardRequired": True,
            "trustedGuardStatus": "pass",
        },
    }


def verified_report(matrix: dict | None = None) -> readiness.VerifiedPublicReport:
    return test_verified_report(public_report(matrix))


def test_verified_report(report: dict) -> readiness.VerifiedPublicReport:
    """Bypass the production compiler only for exhaustive synthetic truth tables."""

    value = object.__new__(readiness.VerifiedPublicReport)
    value._VerifiedPublicReport__report = copy.deepcopy(
        readiness._validate_public_report(report)
    )
    return value


def live_capability_envelope() -> dict:
    capability_report = {
        "account": {
            "authMode": "chatgpt",
            "authenticated": True,
            "identity": {
                "bindingId": BINDING_ID,
                "evidence": "keyed_account_metadata",
                "generation": 1,
                "providerIdentifierAvailable": False,
                "status": "confirmed",
            },
            "requiresOpenaiAuth": True,
        },
        "initialize": {
            "codexHomeAbsolute": True,
            "platformFamily": "unix",
            "platformOs": "linux",
            "userAgentSha256": SHA_A,
            "versionAdvertised": True,
        },
        "models": [
            {
                "defaultReasoningEffort": "ultra",
                "defaultServiceTier": "standard",
                "fastServiceTierId": "fast-opaque",
                "hidden": False,
                "id": "model-sol-opaque",
                "isDefault": True,
                "model": "gpt-5.6-sol",
                "reasoningEfforts": ["high", "ultra"],
                "serviceTierIds": ["fast-opaque", "standard"],
            },
            {
                "defaultReasoningEffort": "medium",
                "defaultServiceTier": None,
                "fastServiceTierId": None,
                "hidden": False,
                "id": "model-terra-opaque",
                "isDefault": False,
                "model": "gpt-5.6-terra",
                "reasoningEfforts": ["high", "medium"],
                "serviceTierIds": [],
            },
        ],
        "noModelWork": True,
        "optional": {
            "collaborationModes": {
                "result": [
                    {
                        "mode": "default",
                        "model": "gpt-5.6-sol",
                        "name": "default",
                        "reasoningEffort": "ultra",
                    }
                ],
                "status": "available",
            },
            "experimentalFeatures": {
                "items": [
                    {
                        "defaultEnabled": False,
                        "enabled": True,
                        "name": "multi_agent_v2",
                        "stage": "underDevelopment",
                    }
                ],
                "status": "available",
            },
            "usage": {"status": "unsupported"},
        },
        "quotaShape": {
            "bucketCount": 2,
            "bucketSource": "multi",
            "fields": ["credits", "primary"],
            "outOfRangeValues": False,
            "resetCredits": {"details": "unavailable", "summary": "absent"},
            "windowSlotCount": 2,
        },
        "referenceProfile": {
            "chatgptAuthentication": True,
            "identityBinding": True,
            "solAvailable": True,
            "solReviewEffort": True,
            "solUltra": True,
            "status": "pass",
            "terraAvailable": True,
            "terraHigh": True,
            "terraMedium": True,
        },
        "reportVersion": 1,
        "schemaVersion": "0.144.3",
    }
    methods = [
        "initialize",
        "account/read",
        "account/rateLimits/read",
        "model/list",
        "model/list",
        "account/usage/read",
        "experimentalFeature/list",
        "collaborationMode/list",
        "account/read",
    ]
    optional_outcomes = {
        "account/usage/read": "unsupported",
        "experimentalFeature/list": "pass",
        "collaborationMode/list": "pass",
    }
    receipts = [
        {
            "attempt": 1,
            "classification": "handshake" if method == "initialize" else "idempotent",
            "method": method,
            "outcome": optional_outcomes.get(method, "pass"),
            "paramsShape": (
                "omitted"
                if method in {"account/rateLimits/read", "account/usage/read"}
                else "object"
            ),
            "requestHash": f"{sequence:x}" * 64,
            "sequence": sequence,
        }
        for sequence, method in enumerate(methods, 1)
    ]
    return {
        "capabilityReport": capability_report,
        "reportVersion": 1,
        "requestReceipts": receipts,
    }


def live_capability_evidence(
    static: dict, envelope: dict | None = None
) -> readiness.LiveCapabilityEvidence:
    envelope = readiness.validate_live_capability_envelope(
        envelope or live_capability_envelope(), static["codex"]["version"]
    )
    return readiness._new_live_capability_evidence(
        {
            "envelope": envelope,
            "launcherSha256": static["codex"]["launcherSha256"],
            "nativeSha256": static["codex"]["nativeSha256"],
            "staticBasisSha256": readiness.sha256_bytes(
                readiness.canonical_json_bytes(static)
            ),
            "versionOutput": static["codex"]["versionOutput"],
        }
    )


def full_gate_evidence(
    static: dict, *, blocked_gate: str | None = None
) -> readiness.FullGateEvidence:
    executions = tuple(
        readiness.GateExecution(
            identifier=identifier,
            command=readiness.REQUIRED_CONFORMANCE_COMMANDS[identifier],
            outcome="blocked" if identifier == blocked_gate else "pass",
            stdout=b"",
            stderr=b"",
        )
        for identifier in sorted(readiness.REQUIRED_CONFORMANCE_IDS)
    )
    return readiness.FullGateEvidence(
        executions=executions,
        live=(
            None
            if blocked_gate == "no_model_live_discovery"
            else live_capability_evidence(static)
        ),
        linear={
            "configuredProjectBinding": LINEAR_BINDING,
            **{
                key: {"status": "pass"}
                for key in readiness.LINEAR_STATUS_KEYS_IN_PROBE_ORDER
                if key != "mutations"
            },
            "mutations": {"evidence": "schema_only", "status": "pass"},
        },
        package={
            "archiveSha256": SHA_B,
            "entryCount": 1,
            "indexTree": COMMIT_A,
            "package": readiness.SUPPORTED_RELEASE_PACKAGE,
            "reportVersion": 1,
            "sourceSha256": static["checkout"]["source"]["sha256"],
            "status": "pass",
        },
        source_sha256=static["checkout"]["source"]["sha256"],
        index_tree=COMMIT_A,
    )


def without_outer_git_worktree():
    environment = dict(os.environ)
    for key in ("GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE"):
        environment.pop(key, None)
    return mock.patch.dict(os.environ, environment, clear=True)


class ReadinessCandidateTest(unittest.TestCase):
    def setUp(self) -> None:
        self.matrix = capability_matrix_artifact()
        self.schema = schema_manifest(self.matrix.raw_sha256)
        self.static = static_basis(self.schema)

    def test_status_truth_table(self) -> None:
        absent, absent_schema = readiness.build_readiness_pair(
            self.static, self.matrix, self.schema, None
        )
        self.assertEqual(absent["runtime"]["capabilities"], "not_run")
        self.assertEqual(absent["runtime"]["overall"], "pending_r0_06")
        self.assertEqual(absent_schema["compatibility"]["runtimeCapabilities"], "not_run")
        self.assertEqual(absent_schema["compatibility"]["overall"], "pending_r0_06")

        blocked_report = public_report(self.matrix)
        blocked_report["linear"]["project"]["status"] = "blocked"
        blocked, blocked_schema = readiness.build_readiness_pair(
            self.static,
            self.matrix,
            self.schema,
            test_verified_report(blocked_report),
        )
        self.assertEqual(blocked["runtime"]["capabilities"], "blocked")
        self.assertEqual(blocked["runtime"]["overall"], "blocked_r0_06")
        self.assertIn("linear.project", blocked["runtime"]["blockers"])
        self.assertEqual(blocked_schema["compatibility"]["runtimeCapabilities"], "blocked")
        self.assertEqual(blocked_schema["compatibility"]["overall"], "blocked_r0_06")

        passed, passed_schema = readiness.build_readiness_pair(
            self.static, self.matrix, self.schema, verified_report(self.matrix)
        )
        self.assertEqual(passed["runtime"], {
            "blockers": [],
            "capabilities": "pass",
            "overall": "pass",
        })
        self.assertEqual(passed_schema["compatibility"]["runtimeCapabilities"], "pass")
        self.assertEqual(passed_schema["compatibility"]["overall"], "pass")

    def test_candidate_is_deterministic_and_records_every_matrix_id(self) -> None:
        report = public_report(self.matrix)
        first, first_schema = readiness.build_readiness_pair(
            self.static,
            self.matrix,
            self.schema,
            test_verified_report(report),
        )
        second, second_schema = readiness.build_readiness_pair(
            copy.deepcopy(self.static),
            copy.deepcopy(self.matrix),
            copy.deepcopy(self.schema),
            test_verified_report(copy.deepcopy(report)),
        )
        self.assertEqual(readiness.canonical_json_bytes(first), readiness.canonical_json_bytes(second))
        self.assertEqual(
            readiness.canonical_json_bytes(first_schema),
            readiness.canonical_json_bytes(second_schema),
        )
        for group in readiness.MATRIX_OUTCOME_KEYS:
            self.assertEqual(
                {row["id"] for row in first["capabilities"]["matrix"][group]},
                {row["id"] for row in self.matrix[group]},
            )
        self.assertEqual(
            first["capabilities"]["subagents"]["rawToOptionalChildren"],
            list(readiness.EXPECTED_CAP_MAPPING),
        )

    def test_private_or_unallowlisted_public_report_data_is_rejected(self) -> None:
        report = public_report(self.matrix)
        report["email"] = "operator@example.com"
        with self.assertRaisesRegex(readiness.ReadinessError, "keys mismatch"):
            test_verified_report(report)

        report = public_report(self.matrix)
        report["models"][0]["serviceTierIds"] = ["sk-proj-privatevalue"]
        with self.assertRaisesRegex(readiness.ReadinessError, "secret-like"):
            test_verified_report(report)

        report = public_report(self.matrix)
        report["conformance"][0]["command"].append("/home/operator/private")
        with self.assertRaisesRegex(readiness.ReadinessError, "absolute"):
            test_verified_report(report)

    def test_missing_or_extra_matrix_outcomes_fail_closed(self) -> None:
        report = public_report(self.matrix)
        del report["matrixOutcomes"]["methods"]["account_read"]
        with self.assertRaisesRegex(readiness.ReadinessError, "outcome IDs mismatch"):
            readiness.build_readiness_candidate(
                self.static,
                self.matrix,
                test_verified_report(report),
            )

        report = public_report(self.matrix)
        report["matrixOutcomes"]["fields"]["invented.field"] = "pass"
        with self.assertRaisesRegex(readiness.ReadinessError, "outcome IDs mismatch"):
            readiness.build_readiness_candidate(
                self.static,
                self.matrix,
                test_verified_report(report),
            )

    def test_cycle_free_schema_basis_and_pair_mismatch_detection(self) -> None:
        first_basis = readiness.schema_manifest_basis_sha256(self.schema)
        variant = copy.deepcopy(self.schema)
        variant["compatibility"]["runtimeCapabilities"] = "pass"
        variant["compatibility"]["overall"] = "pass"
        variant["compatibility"]["runtimeEvidence"] = {
            "hashAlgorithm": readiness.HASH_ALGORITHM,
            "readinessManifestSha256": "e" * 64,
            "schemaManifestBasisSha256": first_basis,
            "sourceSha256": "f" * 64,
        }
        self.assertEqual(first_basis, readiness.schema_manifest_basis_sha256(variant))

        passed, passed_schema = readiness.build_readiness_pair(
            self.static, self.matrix, self.schema, verified_report(self.matrix)
        )
        blocked_report = public_report(self.matrix)
        blocked_report["linear"]["project"]["status"] = "blocked"
        _blocked, blocked_schema = readiness.build_readiness_pair(
            self.static,
            self.matrix,
            self.schema,
            test_verified_report(blocked_report),
        )
        with self.assertRaisesRegex(readiness.ReadinessError, "pair mismatch"):
            readiness.verify_readiness_pair(passed, blocked_schema, self.matrix)

        stale = copy.deepcopy(self.static)
        stale["checkout"]["source"]["sha256"] = SHA_B
        with self.assertRaisesRegex(readiness.ReadinessError, "static basis is stale"):
            readiness.verify_readiness_pair(
                passed, passed_schema, self.matrix, expected_static_basis=stale
            )

    def test_raw_claim_map_cannot_cross_the_compiler_boundary(self) -> None:
        report = public_report(self.matrix)
        with self.assertRaisesRegex(readiness.ReadinessError, "trusted compiler"):
            readiness.build_readiness_candidate(self.static, self.matrix, report)
        with self.assertRaisesRegex(readiness.ReadinessError, "trusted compiler"):
            readiness.VerifiedPublicReport()

    def test_exact_conformance_inventory_and_commands_are_required(self) -> None:
        report = public_report(self.matrix)
        report["conformance"].pop()
        with self.assertRaisesRegex(readiness.ReadinessError, "inventory mismatch"):
            readiness.build_readiness_candidate(
                self.static, self.matrix, test_verified_report(report)
            )

        report = public_report(self.matrix)
        report["conformance"][0]["command"] = ["true"]
        with self.assertRaisesRegex(readiness.ReadinessError, "command differs"):
            readiness.build_readiness_candidate(
                self.static, self.matrix, test_verified_report(report)
            )

        report = public_report(self.matrix)
        report["conformance"][0]["required"] = False
        with self.assertRaisesRegex(readiness.ReadinessError, "must be required"):
            readiness.build_readiness_candidate(
                self.static, self.matrix, test_verified_report(report)
            )

    def test_identity_binding_is_bound_and_cross_field_exact(self) -> None:
        report = public_report(self.matrix)
        report["identityBinding"] = {
            "bindingId": None,
            "evidence": "unavailable",
            "generation": 2,
            "status": "unconfirmed",
        }
        report["referenceProfile"] = reference_profile(
            identityBinding=False, status="fail"
        )
        candidate = readiness.build_readiness_candidate(
            self.static, self.matrix, test_verified_report(report)
        )
        self.assertIn("auth.identity_binding", candidate["runtime"]["blockers"])

        report = public_report(self.matrix)
        report["identityBinding"] = {
            "bindingId": None,
            "evidence": "keyed_account_metadata",
            "generation": 0,
            "status": "blocked",
        }
        with self.assertRaisesRegex(readiness.ReadinessError, "exact unavailable evidence"):
            readiness.build_readiness_candidate(
                self.static, self.matrix, test_verified_report(report)
            )

    def test_api_key_compatibility_classifications_are_recorded_but_not_green(self) -> None:
        report = public_report(self.matrix)
        report["authMode"] = "api_key"
        report["identityBinding"] = {
            "bindingId": None,
            "evidence": "unavailable",
            "generation": 1,
            "status": "unconfirmed",
        }
        report["referenceProfile"] = reference_profile(
            chatgptAuthentication=False,
            identityBinding=False,
            status="fail",
        )
        report["matrixOutcomes"]["methods"]["account_read"] = "auth_restricted"
        report["matrixOutcomes"]["methods"]["account_usage_read"] = "unsupported"
        report["quota"]["fullRead"] = "blocked"
        report["quota"]["usage"] = "unsupported"
        candidate = readiness.build_readiness_candidate(
            self.static, self.matrix, test_verified_report(report)
        )
        self.assertEqual(candidate["runtime"]["capabilities"], "blocked")
        self.assertIn("matrix.methods.account_read", candidate["runtime"]["blockers"])
        self.assertNotIn(
            "matrix.methods.account_usage_read", candidate["runtime"]["blockers"]
        )
        self.assertNotIn("quota.usage", candidate["runtime"]["blockers"])

    def test_terra_medium_and_high_are_both_reference_requirements(self) -> None:
        report = public_report(self.matrix)
        terra = next(row for row in report["models"] if row["model"] == "gpt-5.6-terra")
        terra["reasoningEfforts"] = ["high"]
        report["referenceProfile"] = reference_profile(
            terraMedium=False, status="fail"
        )
        candidate = readiness.build_readiness_candidate(
            self.static, self.matrix, test_verified_report(report)
        )
        self.assertIn("models.gpt-5.6-terra.medium", candidate["runtime"]["blockers"])

    def test_reference_profile_is_bound_to_visible_models_and_auth(self) -> None:
        report = public_report(self.matrix)
        report["models"] = [
            model for model in report["models"] if model["model"] != "gpt-5.6-terra"
        ]
        with self.assertRaisesRegex(readiness.ReadinessError, "visible model"):
            readiness.build_readiness_candidate(
                self.static, self.matrix, test_verified_report(report)
            )

        report["referenceProfile"] = reference_profile(
            terraAvailable=False,
            terraHigh=False,
            terraMedium=False,
            status="fail",
        )
        candidate = readiness.build_readiness_candidate(
            self.static, self.matrix, test_verified_report(report)
        )
        self.assertEqual(
            candidate["capabilities"]["auth"]["referenceProfile"]["status"],
            "fail",
        )
        self.assertIn("auth.reference_profile", candidate["runtime"]["blockers"])
        self.assertIn("models.gpt-5.6-terra", candidate["runtime"]["blockers"])

        inconsistent = public_report(self.matrix)
        inconsistent["referenceProfile"]["terraMedium"] = False
        with self.assertRaisesRegex(readiness.ReadinessError, "status is inconsistent"):
            readiness.build_readiness_candidate(
                self.static, self.matrix, test_verified_report(inconsistent)
            )

        tampered = copy.deepcopy(candidate)
        tampered["capabilities"]["auth"]["referenceProfile"] = reference_profile(
            terraMedium=False, status="fail"
        )
        with self.assertRaisesRegex(readiness.ReadinessError, "visible model"):
            readiness.validate_readiness_manifest(tampered, self.matrix)

    def test_hidden_models_cannot_promote_reference_readiness(self) -> None:
        envelope = live_capability_envelope()
        for model in envelope["capabilityReport"]["models"]:
            model["hidden"] = True
        envelope["capabilityReport"]["referenceProfile"] = reference_profile(
            solAvailable=False,
            solReviewEffort=False,
            solUltra=False,
            terraAvailable=False,
            terraHigh=False,
            terraMedium=False,
            status="fail",
        )
        compiled = readiness.compile_live_blocked_report(
            live_capability_evidence(self.static, envelope), self.matrix, self.static
        )
        candidate = readiness.build_readiness_candidate(
            self.static, self.matrix, compiled
        )
        self.assertEqual(candidate["capabilities"]["models"], [])
        self.assertEqual(
            candidate["capabilities"]["auth"]["referenceProfile"]["status"],
            "fail",
        )
        self.assertIn("auth.reference_profile", candidate["runtime"]["blockers"])
        self.assertIn("models.gpt-5.6-sol", candidate["runtime"]["blockers"])
        self.assertIn("models.gpt-5.6-terra", candidate["runtime"]["blockers"])

        false_green = live_capability_envelope()
        for model in false_green["capabilityReport"]["models"]:
            model["hidden"] = True
        compiled_false_green = readiness.compile_live_blocked_report(
            live_capability_evidence(self.static, false_green),
            self.matrix,
            self.static,
        )
        with self.assertRaisesRegex(readiness.ReadinessError, "visible model"):
            readiness.build_readiness_candidate(
                self.static, self.matrix, compiled_false_green
            )

    def test_pair_cross_checks_codex_hashes_without_expected_static_basis(self) -> None:
        passed, paired_schema = readiness.build_readiness_pair(
            self.static, self.matrix, self.schema, verified_report(self.matrix)
        )
        mixed = copy.deepcopy(passed)
        mixed["codex"]["launcherSha256"] = SHA_B
        with self.assertRaisesRegex(readiness.ReadinessError, "Codex hashes differ"):
            readiness.verify_readiness_pair(mixed, paired_schema, self.matrix)

    def test_matrix_order_top_level_and_commit_width_fail_closed(self) -> None:
        passed, paired_schema = readiness.build_readiness_pair(
            self.static, self.matrix, self.schema, verified_report(self.matrix)
        )
        reordered = copy.deepcopy(passed)
        reordered["capabilities"]["matrix"]["methods"].reverse()
        with self.assertRaisesRegex(readiness.ReadinessError, "canonical ID order"):
            readiness.verify_readiness_pair(reordered, paired_schema, self.matrix)

        extra_matrix_value = capability_matrix()
        extra_matrix_value["invented"] = []
        extra_matrix = readiness.MatrixArtifact(
            readiness.canonical_json_bytes(extra_matrix_value), "extra matrix fixture"
        )
        with self.assertRaisesRegex(readiness.ReadinessError, "keys mismatch"):
            readiness.validate_readiness_manifest(passed, extra_matrix)

        wrong_width = copy.deepcopy(self.static)
        wrong_width["checkout"]["headCommit"] = "f" * 64
        with self.assertRaisesRegex(readiness.ReadinessError, "width differs"):
            readiness.build_readiness_candidate(wrong_width, self.matrix, None)

    def test_matrix_must_retain_its_exact_artifact_byte_binding(self) -> None:
        with self.assertRaisesRegex(readiness.ReadinessError, "exact bounded artifact bytes"):
            readiness.build_readiness_candidate(
                self.static, capability_matrix(), None
            )

        semantically_equal_bytes = json.dumps(
            capability_matrix(), separators=(",", ":"), sort_keys=True
        ).encode("utf-8")
        semantically_equal = readiness.MatrixArtifact(
            semantically_equal_bytes, "noncanonical matrix fixture"
        )
        with self.assertRaisesRegex(readiness.ReadinessError, "bytes differ"):
            readiness.build_readiness_candidate(self.static, semantically_equal, None)

        mutated = copy.deepcopy(self.matrix)
        mutated["methods"].pop()
        with self.assertRaisesRegex(readiness.ReadinessError, "changed after"):
            readiness.build_readiness_candidate(self.static, mutated, None)

    def test_platform_is_bound_to_verified_codex_target_and_package(self) -> None:
        report = public_report(self.matrix)
        report["platform"]["os"] = "windows"
        report["platform"]["architecture"] = "arm64"
        with self.assertRaisesRegex(readiness.ReadinessError, "verified Codex target"):
            readiness.build_readiness_candidate(
                self.static, self.matrix, test_verified_report(report)
            )

        report = public_report(self.matrix)
        report["platform"]["package"] = "invented-package"
        with self.assertRaisesRegex(readiness.ReadinessError, "package identifier"):
            readiness.build_readiness_candidate(
                self.static, self.matrix, test_verified_report(report)
            )

    def test_live_envelope_receipts_are_strict_and_compile_only_blocked_facts(self) -> None:
        envelope = live_capability_envelope()
        validated = readiness.validate_live_capability_envelope(envelope, "0.144.3")
        live = object.__new__(readiness.LiveCapabilityEvidence)
        live._LiveCapabilityEvidence__value = {
            "envelope": copy.deepcopy(validated),
            "launcherSha256": self.static["codex"]["launcherSha256"],
            "nativeSha256": self.static["codex"]["nativeSha256"],
            "staticBasisSha256": readiness.sha256_bytes(
                readiness.canonical_json_bytes(self.static)
            ),
            "versionOutput": self.static["codex"]["versionOutput"],
        }
        compiled = readiness.compile_live_blocked_report(
            live, self.matrix, self.static
        )
        candidate = readiness.build_readiness_candidate(self.static, self.matrix, compiled)
        self.assertEqual(candidate["runtime"]["capabilities"], "blocked")
        self.assertEqual(
            next(
                row["outcome"]
                for row in candidate["conformance"]
                if row["id"] == "no_model_live_discovery"
            ),
            "not_run",
        )
        self.assertIn(
            "conformance.no_model_live_discovery", candidate["runtime"]["blockers"]
        )
        self.assertIn("linear.project", candidate["runtime"]["blockers"])

        tampered = live_capability_envelope()
        tampered["requestReceipts"][3]["method"] = "thread/start"
        with self.assertRaisesRegex(readiness.ReadinessError, "model pagination"):
            readiness.validate_live_capability_envelope(tampered, "0.144.3")

        tampered = live_capability_envelope()
        tampered["requestReceipts"][5]["outcome"] = "pass"
        with self.assertRaisesRegex(readiness.ReadinessError, "outcome differs"):
            readiness.validate_live_capability_envelope(tampered, "0.144.3")

        tampered = live_capability_envelope()
        tampered["requestReceipts"][0]["attempt"] = True
        with self.assertRaisesRegex(readiness.ReadinessError, "sequence/attempt"):
            readiness.validate_live_capability_envelope(tampered, "0.144.3")

        encoded = json.dumps(envelope, separators=(",", ":"), sort_keys=True).encode()
        stdout = (
            b"===> Analyzing applications...\n"
            b"===> Compiling erlexec\n"
            + readiness.LIVE_JSON_PREFIX.encode("ascii")
            + encoded
            + b"\n"
        )
        self.assertEqual(readiness.decode_live_task_stdout(stdout), envelope)
        with self.assertRaisesRegex(readiness.ReadinessError, "prefix"):
            readiness.decode_live_task_stdout(encoded + b"\n")

        with self.assertRaisesRegex(readiness.ReadinessError, "trusted compiler"):
            readiness.LiveCapabilityEvidence()

        with tempfile.TemporaryDirectory() as temporary:
            host = Path(temporary) / "host"
            codex_home = host / ".codex"
            unsafe_state = Path(temporary) / "repository-state"
            codex_home.mkdir(parents=True)
            (host / ".local/share/mise").mkdir(parents=True)
            os.chmod(codex_home, 0o700)
            unsafe_state.mkdir()
            (codex_home / "auth.json").write_text("{}\n", encoding="utf-8")
            os.chmod(codex_home / "auth.json", 0o600)
            environment = dict(os.environ)
            environment.update(
                {
                    "CODEX_HOME": str(codex_home),
                    "HOME": str(host),
                    "XDG_STATE_HOME": str(unsafe_state),
                }
            )
            with mock.patch.dict(os.environ, environment, clear=True):
                host_home = readiness._selected_live_host_home()
                auth_source, identity_source = readiness._selected_live_secret_sources(
                    host_home
                )
                overrides = readiness._install_private_live_credentials(
                    auth_source,
                    identity_source,
                    Path(temporary) / "missing-credential-copy",
                )
            self.assertIsNone(overrides)
            self.assertFalse((unsafe_state / readiness.IDENTITY_KEY_RELATIVE).exists())

            default_parent = host / ".local/state/symphony-studio"
            default_parent.mkdir(parents=True, mode=0o700)
            os.chmod(default_parent, 0o700)
            key = default_parent / "codex-identity-binding-v1.key"
            key.write_bytes(b"k" * 32)
            os.chmod(key, 0o600)

            def copy_identity(
                case: str,
                xdg_state: str,
                *,
                selected_codex_home: Path = codex_home,
                forbidden_roots: tuple[Path, ...] = (),
            ) -> tuple[Path, bool]:
                destination_root = Path(temporary) / f"copy-{case}"
                case_environment = dict(os.environ)
                case_environment.update(
                    {
                        "CODEX_HOME": str(selected_codex_home),
                        "HOME": str(host),
                        "XDG_STATE_HOME": xdg_state,
                    }
                )
                with mock.patch.dict(os.environ, case_environment, clear=True):
                    try:
                        selected_home = readiness._selected_live_host_home()
                        auth_source, identity_source = (
                            readiness._selected_live_secret_sources(selected_home)
                        )
                        overrides = readiness._install_private_live_credentials(
                            auth_source,
                            identity_source,
                            destination_root,
                            forbidden_roots=forbidden_roots,
                        )
                    except readiness.ReadinessError:
                        overrides = None
                return destination_root, overrides is not None

            source_before = (key.read_bytes(), stat.S_IMODE(key.stat().st_mode))
            copied_root, ready = copy_identity(
                "safe", str(host / ".local/state")
            )
            self.assertTrue(ready)
            self.assertEqual(stat.S_IMODE(copied_root.stat().st_mode), 0o700)
            self.assertEqual(
                (copied_root / "xdg-state" / readiness.IDENTITY_KEY_RELATIVE).read_bytes(),
                b"k" * 32,
            )
            self.assertEqual(
                stat.S_IMODE(
                    (copied_root / "codex-home/auth.json").stat().st_mode
                ),
                0o600,
            )
            self.assertEqual(
                stat.S_IMODE(
                    (
                        copied_root
                        / "xdg-state"
                        / readiness.IDENTITY_KEY_RELATIVE
                    ).stat().st_mode
                ),
                0o600,
            )
            self.assertEqual(
                (key.read_bytes(), stat.S_IMODE(key.stat().st_mode)), source_before
            )

            with mock.patch.object(
                readiness.os, "getuid", return_value=os.getuid() + 1
            ):
                _copied_root, ready = copy_identity(
                    "wrong-owner", str(host / ".local/state")
                )
            self.assertFalse(ready)

            auth_file = codex_home / "auth.json"
            auth_before = auth_file.read_bytes()
            os.chmod(auth_file, 0o644)
            _copied_root, ready = copy_identity(
                "unsafe-auth-mode", str(host / ".local/state")
            )
            self.assertFalse(ready)
            self.assertEqual(auth_file.read_bytes(), auth_before)
            self.assertEqual(stat.S_IMODE(auth_file.stat().st_mode), 0o644)
            os.chmod(auth_file, 0o600)

            external_auth = Path(temporary) / "external-auth.json"
            external_auth.write_bytes(auth_before)
            os.chmod(external_auth, 0o600)
            auth_file.unlink()
            auth_file.symlink_to(external_auth)
            _copied_root, ready = copy_identity(
                "symlink-auth", str(host / ".local/state")
            )
            self.assertFalse(ready)
            self.assertEqual(external_auth.read_bytes(), auth_before)
            auth_file.unlink()
            auth_file.write_bytes(auth_before)
            os.chmod(auth_file, 0o600)

            actual_codex_home = Path(temporary) / "actual-codex-home"
            actual_codex_home.mkdir(mode=0o700)
            actual_auth = actual_codex_home / "auth.json"
            actual_auth.write_bytes(auth_before)
            os.chmod(actual_auth, 0o600)
            symlink_codex_home = Path(temporary) / "symlink-codex-home"
            symlink_codex_home.symlink_to(actual_codex_home, target_is_directory=True)
            _copied_root, ready = copy_identity(
                "symlink-auth-parent",
                str(host / ".local/state"),
                selected_codex_home=symlink_codex_home,
            )
            self.assertFalse(ready)
            os.chmod(actual_codex_home, 0o755)
            _copied_root, ready = copy_identity(
                "unsafe-auth-parent-mode",
                str(host / ".local/state"),
                selected_codex_home=actual_codex_home,
            )
            self.assertFalse(ready)
            _copied_root, ready = copy_identity(
                "relative-codex-home",
                str(host / ".local/state"),
                selected_codex_home=Path("relative-codex-home"),
            )
            self.assertFalse(ready)

            secret_repo = Path(temporary) / "secret-repo"
            secret_repo.mkdir()
            with without_outer_git_worktree():
                subprocess.run(["git", "init", "--quiet"], cwd=secret_repo, check=True)
            repo_state_parent = secret_repo / ".state/symphony-studio"
            repo_state_parent.mkdir(parents=True, mode=0o700)
            os.chmod(repo_state_parent, 0o700)
            repo_key = repo_state_parent / "codex-identity-binding-v1.key"
            repo_key.write_bytes(b"q" * 32)
            os.chmod(repo_key, 0o600)
            _copied_root, ready = copy_identity(
                "repo-held-key",
                str(secret_repo / ".state"),
                forbidden_roots=(secret_repo,),
            )
            self.assertFalse(ready)
            self.assertEqual(repo_key.read_bytes(), b"q" * 32)
            self.assertEqual(stat.S_IMODE(repo_key.stat().st_mode), 0o600)

            workflow_root = Path(temporary) / "workflow-root"
            workflow_state_parent = workflow_root / ".state/symphony-studio"
            workflow_state_parent.mkdir(parents=True, mode=0o700)
            os.chmod(workflow_state_parent, 0o700)
            workflow_key = workflow_state_parent / "codex-identity-binding-v1.key"
            workflow_key.write_bytes(b"w" * 32)
            os.chmod(workflow_key, 0o600)
            _copied_root, ready = copy_identity(
                "workflow-held-key",
                str(workflow_root / ".state"),
                forbidden_roots=(workflow_root,),
            )
            self.assertFalse(ready)
            self.assertEqual(workflow_key.read_bytes(), b"w" * 32)

            repo_codex_home = secret_repo / ".codex"
            repo_codex_home.mkdir(mode=0o700)
            repo_auth = repo_codex_home / "auth.json"
            repo_auth.write_bytes(auth_before)
            os.chmod(repo_auth, 0o600)
            _copied_root, ready = copy_identity(
                "repo-held-auth",
                str(host / ".local/state"),
                selected_codex_home=repo_codex_home,
                forbidden_roots=(secret_repo,),
            )
            self.assertFalse(ready)
            self.assertEqual(repo_auth.read_bytes(), auth_before)

            os.chmod(key, 0o644)
            copied_root, ready = copy_identity(
                "unsafe-mode", str(host / ".local/state")
            )
            self.assertFalse(ready)
            self.assertFalse(
                (copied_root / "xdg-state" / readiness.IDENTITY_KEY_RELATIVE).exists()
            )
            self.assertEqual(stat.S_IMODE(key.stat().st_mode), 0o644)

            key.write_bytes(b"short")
            os.chmod(key, 0o600)
            _copied_root, ready = copy_identity(
                "wrong-length", str(host / ".local/state")
            )
            self.assertFalse(ready)

            external_key = Path(temporary) / "external-identity.key"
            external_key.write_bytes(b"e" * 32)
            os.chmod(external_key, 0o600)
            key.unlink()
            key.symlink_to(external_key)
            _copied_root, ready = copy_identity(
                "symlink-file", str(host / ".local/state")
            )
            self.assertFalse(ready)
            self.assertEqual(external_key.read_bytes(), b"e" * 32)

            key.unlink()
            default_parent.rmdir()
            actual_parent = Path(temporary) / "actual-identity-parent"
            actual_parent.mkdir(mode=0o700)
            actual_key = actual_parent / "codex-identity-binding-v1.key"
            actual_key.write_bytes(b"a" * 32)
            os.chmod(actual_key, 0o600)
            default_parent.symlink_to(actual_parent, target_is_directory=True)
            _copied_root, ready = copy_identity(
                "symlink-parent", str(host / ".local/state")
            )
            self.assertFalse(ready)
            default_parent.unlink()

            default_parent.mkdir(mode=0o700)
            key.write_bytes(b"r" * 32)
            os.chmod(key, 0o600)
            _copied_root, ready = copy_identity("relative-xdg-fallback", "relative-state")
            self.assertTrue(ready)
            os.chmod(default_parent, 0o755)
            _copied_root, ready = copy_identity(
                "unsafe-parent-mode", str(host / ".local/state")
            )
            self.assertFalse(ready)
            self.assertEqual(key.read_bytes(), b"r" * 32)

    def test_private_live_environment_defaults_mise_data_to_original_host_home(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original_mise_data = os.environ.get("MISE_DATA_DIR")
            host_home = root / "host-home"
            host_mise_data = host_home / ".local/share/mise"
            host_mise_data.mkdir(parents=True)
            explicit_mise_data = root / "explicit-mise-data"
            explicit_mise_data.mkdir()

            def prepare(case: str, environment: dict[str, str]) -> dict[str, str]:
                with (
                    mock.patch.dict(os.environ, environment, clear=True),
                    mock.patch.object(readiness, "_copy_private_regular_tree"),
                    mock.patch.object(readiness, "_copy_private_regular"),
                ):
                    private = readiness._prepare_private_live_environment(
                        root / f"private-{case}"
                    )
                    self.assertEqual(
                        os.environ.get("MISE_DATA_DIR"), environment.get("MISE_DATA_DIR")
                    )
                return private

            private = prepare("default", {"HOME": str(host_home)})
            self.assertEqual(private["MISE_DATA_DIR"], str(host_mise_data.resolve()))
            self.assertEqual(private["MISE_OFFLINE"], "1")
            self.assertNotIn("CODEX_HOME", private)
            self.assertTrue(Path(private["HOME"]).is_relative_to(root / "private-default"))
            self.assertFalse((root / "private-default/codex-home/auth.json").exists())
            self.assertFalse(
                (
                    root
                    / "private-default/xdg-state"
                    / readiness.IDENTITY_KEY_RELATIVE
                ).exists()
            )
            for key in ("MISE_CACHE_DIR", "MISE_CONFIG_DIR", "MISE_STATE_DIR"):
                self.assertTrue(Path(private[key]).is_relative_to(root / "private-default"))
            self.assertEqual(os.environ.get("MISE_DATA_DIR"), original_mise_data)

            private = prepare(
                "explicit",
                {"HOME": str(host_home), "MISE_DATA_DIR": str(explicit_mise_data)},
            )
            self.assertEqual(private["MISE_DATA_DIR"], str(explicit_mise_data.resolve()))

            with (
                mock.patch.dict(
                    os.environ,
                    {"HOME": str(host_home), "MISE_DATA_DIR": "relative-mise-data"},
                    clear=True,
                ),
                self.assertRaisesRegex(readiness.ReadinessError, "absolute mise data"),
            ):
                readiness._prepare_private_live_environment(root / "private-relative")

    def test_standalone_live_probe_delegates_to_sealed_builder(self) -> None:
        selected = {
            "launcherSha256": self.static["codex"]["launcherSha256"],
            "nativeSha256": self.static["codex"]["nativeSha256"],
            "target": self.static["codex"]["target"],
        }
        evidence = live_capability_evidence(self.static)
        record = {
            "evidence": evidence._copy_for_compiler(),
            "reportVersion": 1,
            "sourceSha256": self.static["checkout"]["source"]["sha256"],
            "staticBasisSha256": readiness.sha256_bytes(
                readiness.canonical_json_bytes(self.static)
            ),
        }
        with mock.patch.object(
            readiness, "build_codex_probe_record", return_value=record
        ) as sealed_builder:
            result = readiness.run_live_capability_probe(
                Path.cwd(),
                {"version": self.static["codex"]["version"]},
                selected,
                self.static,
                "codex",
                "mise",
            )
        self.assertIsInstance(result, readiness.LiveCapabilityEvidence)
        sealed_builder.assert_called_once_with(Path.cwd(), "codex", "mise")

        mismatched = dict(selected)
        mismatched["nativeSha256"] = SHA_A
        with (
            mock.patch.object(readiness, "build_codex_probe_record") as sealed_builder,
            self.assertRaisesRegex(readiness.ReadinessError, "hashes differ"),
        ):
            readiness.run_live_capability_probe(
                Path.cwd(),
                {"version": self.static["codex"]["version"]},
                mismatched,
                self.static,
            )
        sealed_builder.assert_not_called()

    def test_project_independent_live_entry_ignores_candidate_mix_surface(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            host_home = Path(os.environ["HOME"])
            mise_data = Path(
                os.environ.get("MISE_DATA_DIR", str(host_home / ".local/share/mise"))
            )
            tools = readiness._select_private_live_runtime_tools(
                readiness.REPO_ROOT, mise_data
            )
            tools_before = readiness._inspect_private_live_runtime_tools(tools)
            runtime_root = root / "runtime"
            runtime_root.mkdir(mode=0o700)
            mix_build = root / "mix-build"
            symphony_ebin = mix_build / "lib/symphony_elixir/ebin"
            erlexec_ebin = mix_build / "lib/erlexec/ebin"
            symphony_ebin.mkdir(parents=True)
            erlexec_ebin.mkdir(parents=True)
            source = root / "sealed_fixture.ex"
            source.write_text(
                """
                defmodule Mix.Tasks.Studio.Capabilities do
                  def run_sealed(args), do: IO.puts("sealed:" <> Enum.join(args, "|"))
                end

                defmodule Mix.Tasks.Studio.LinearCapabilities do
                  def run_sealed(args), do: IO.puts("sealed-linear:" <> Enum.join(args, "|"))
                end
                """,
                encoding="utf-8",
            )
            setup_environment = {
                "ERL_CRASH_DUMP": str(root / "erl_crash.dump"),
                "HOME": str(root / "home"),
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "NO_COLOR": "1",
                "TMPDIR": str(root / "tmp"),
                "TZ": "UTC",
                "XDG_CACHE_HOME": str(root / "xdg-cache"),
                "XDG_CONFIG_HOME": str(root / "xdg-config"),
                "XDG_DATA_HOME": str(root / "xdg-data"),
                "MIX_HOME": str(root / "forbidden-mix"),
                "HEX_HOME": str(root / "forbidden-hex"),
                "MISE_DATA_DIR": str(mise_data),
            }
            for key in (
                "HOME",
                "TMPDIR",
                "XDG_CACHE_HOME",
                "XDG_CONFIG_HOME",
                "XDG_DATA_HOME",
            ):
                Path(setup_environment[key]).mkdir(mode=0o700)
            compile_environment = readiness._private_live_task_environment(
                setup_environment,
                {
                    "CODEX_HOME": str(root / "fake-codex-home"),
                    "XDG_STATE_HOME": str(root / "fake-state-home"),
                },
                tools,
            )
            compile_environment.pop("CODEX_HOME")
            compile_environment.pop("XDG_STATE_HOME")
            compile_returncode, _compile_stdout, compile_stderr = (
                readiness.run_bounded_command(
                    [str(tools.elixirc_runner), "-o", str(symphony_ebin), str(source)],
                    cwd=root,
                    environment=compile_environment,
                    timeout_seconds=30.0,
                    max_output_bytes=1024 * 1024,
                )
            )
            self.assertEqual(compile_returncode, 0)
            self.assertFalse(compile_stderr.strip())
            compiled = next(symphony_ebin.glob("*.beam"))
            shutil.copyfile(compiled, erlexec_ebin / "exec_app.beam")
            code_paths = readiness._private_runtime_code_paths(mix_build)

            candidate = root / "candidate"
            marker_root = root / "markers"
            (candidate / "elixir/config").mkdir(parents=True)
            (candidate / "elixir/vendor/erlexec").mkdir(parents=True)
            (candidate / "bin").mkdir(parents=True)
            candidate.joinpath("elixir/WORKFLOW.md").write_text(
                "---\ntracker:\n  kind: memory\n---\n",
                encoding="utf-8",
            )
            marker_root.mkdir()
            mix_marker = marker_root / "mix"
            runtime_marker = marker_root / "runtime"
            rebar_marker = marker_root / "rebar"
            rogue_marker = marker_root / "rogue-codex"
            candidate.joinpath("elixir/mix.exs").write_text(
                f'File.write!({json.dumps(str(mix_marker))}, "executed")\n'
                "defmodule Canary.MixProject do\n"
                "  use Mix.Project\n"
                "  def project, do: [app: :canary, version: \"0.1.0\", "
                f'aliases: [run: ["cmd {candidate / "bin/codex"}"]]]\n'
                "end\n",
                encoding="utf-8",
            )
            candidate.joinpath("elixir/config/runtime.exs").write_text(
                f'File.write!({json.dumps(str(runtime_marker))}, "executed")\n',
                encoding="utf-8",
            )
            candidate.joinpath("elixir/vendor/erlexec/rebar.config.script").write_text(
                f'file:write_file({json.dumps(str(rebar_marker))}, <<"executed">>), [].\n',
                encoding="utf-8",
            )
            rogue = candidate / "bin/codex"
            rogue.write_text(
                "#!/bin/sh\n" + f"printf executed > {shlex.quote(str(rogue_marker))}\n",
                encoding="utf-8",
            )
            rogue.chmod(0o700)
            setup_environment["PATH"] = str(rogue.parent)

            credential_environment = readiness._private_live_task_environment(
                setup_environment,
                {
                    "CODEX_HOME": str(root / "fake-codex-home"),
                    "XDG_STATE_HOME": str(root / "fake-state-home"),
                },
                tools,
            )
            self.assertFalse(
                any(
                    key.startswith(("HEX", "MISE", "MIX", "REBAR", "SYMPHONY_ERLEXEC"))
                    for key in credential_environment
                )
            )
            self.assertNotIn(str(rogue.parent), credential_environment["PATH"])
            command = readiness._live_capability_task_command(
                tools, code_paths, str(tools.elixir_runner), candidate
            )
            readiness._assert_empty_private_runtime_root(runtime_root)
            returncode, stdout, stderr = readiness.run_bounded_command(
                command,
                cwd=runtime_root,
                environment=credential_environment,
                timeout_seconds=30.0,
                max_output_bytes=1024 * 1024,
            )
            readiness._assert_empty_private_runtime_root(runtime_root)
            self.assertEqual(returncode, 0)
            self.assertFalse(stderr.strip())
            self.assertIn(b"sealed:--format|json|--codex-bin|", stdout)
            self.assertIn(b"|--workflow|", stdout)

            linear_environment = dict(credential_environment)
            linear_environment.pop("CODEX_HOME")
            linear_environment["LINEAR_API_KEY"] = "linear-canary"
            linear_command = [str(tools.elixir_runner)]
            for code_path in code_paths:
                linear_command.extend(("-pa", str(code_path)))
            linear_command.extend(
                (
                    "-e",
                    readiness.LINEAR_TASK_ENTRYPOINT,
                    "--",
                    "--format",
                    "json",
                    "--validation-fixtures",
                    "--workflow",
                    str(candidate / "elixir/WORKFLOW.md"),
                )
            )
            returncode, linear_stdout, linear_stderr = readiness.run_bounded_command(
                linear_command,
                cwd=runtime_root,
                environment=linear_environment,
                timeout_seconds=30.0,
                max_output_bytes=1024 * 1024,
            )
            self.assertEqual(returncode, 0)
            self.assertFalse(linear_stderr.strip())
            self.assertIn(b"sealed-linear:--format|json|--validation-fixtures", linear_stdout)
            self.assertFalse(any(marker_root.iterdir()))
            self.assertEqual(
                readiness._inspect_private_live_runtime_tools(tools), tools_before
            )

    def test_credential_free_bootstrap_failure_prevents_sealed_codex_execution(self) -> None:
        sandbox = mock.Mock(spec=readiness.GateSandbox)
        with (
            mock.patch.object(
                readiness,
                "collect_static_basis",
                return_value=(self.static, self.matrix, self.schema),
            ),
            mock.patch.object(readiness, "_git_text", return_value=COMMIT_A),
            mock.patch.object(readiness, "_parse_index_entries", return_value=[]),
            mock.patch.object(
                readiness, "_git_metadata_fingerprint", return_value="metadata"
            ),
            mock.patch.object(
                readiness,
                "_require_public_launcher_selector",
                side_effect=(Path("/tools/codex"), Path("/tools/mise")),
            ),
            mock.patch.object(
                readiness, "sha256_regular_file", return_value=SHA_A
            ),
            mock.patch.object(readiness, "_run_git"),
            mock.patch.object(
                readiness,
                "_inspect_source_bound_snapshot",
                return_value="snapshot",
            ),
            mock.patch.object(
                readiness, "_prepare_gate_sandbox", return_value=sandbox
            ),
            mock.patch.object(readiness, "_run_gate_sandbox_canary"),
            mock.patch.object(
                readiness,
                "_bootstrap_private_gate_dependencies",
                side_effect=readiness.ReadinessError(
                    "credential-free bootstrap failed"
                ),
            ),
            mock.patch.object(
                readiness, "_execute_sealed_codex_gate"
            ) as sealed_execution,
            self.assertRaisesRegex(
                readiness.ReadinessError, "credential-free bootstrap failed"
            ),
        ):
            readiness.build_codex_probe_record(Path.cwd())
        sealed_execution.assert_not_called()

    def test_exact_checkout_snapshot_rejects_inventory_mode_and_byte_drift(self) -> None:
        def blob_oid(payload: bytes) -> str:
            digest = hashlib.sha1()
            digest.update(f"blob {len(payload)}\0".encode("ascii"))
            digest.update(payload)
            return digest.hexdigest()

        def fixture(root: Path) -> list[tuple[str, str, str]]:
            (root / "lib").mkdir()
            source = root / "lib/source.ex"
            source.write_bytes(b"source\n")
            os.chmod(source, 0o644)
            script = root / "run"
            script.write_bytes(b"#!/bin/sh\n")
            os.chmod(script, 0o755)
            return [
                ("lib/source.ex", "100644", blob_oid(b"source\n")),
                ("run", "100755", blob_oid(b"#!/bin/sh\n")),
            ]

        mutations = {
            "bytes": lambda root: (root / "lib/source.ex").write_bytes(b"changed\n"),
            "mode": lambda root: os.chmod(root / "lib/source.ex", 0o755),
            "delete": lambda root: (root / "lib/source.ex").unlink(),
            "symlink": lambda root: (
                (root / "lib/source.ex").unlink(),
                (root / "lib/source.ex").symlink_to(root / "run"),
            ),
            "extra-file": lambda root: (root / "extra.ex").write_bytes(b"extra\n"),
            "extra-directory": lambda root: (root / "extra").mkdir(),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                snapshot = Path(temporary) / "snapshot"
                snapshot.mkdir(mode=0o700)
                entries = fixture(snapshot)
                baseline = readiness._inspect_checkout_snapshot(
                    snapshot, entries, "sha1"
                )
                self.assertRegex(baseline, r"^[0-9a-f]{64}$")
                mutate(snapshot)
                with self.assertRaises(readiness.ReadinessError):
                    readiness._inspect_checkout_snapshot(snapshot, entries, "sha1")

        with tempfile.TemporaryDirectory() as temporary:
            snapshot = Path(temporary) / "snapshot"
            snapshot.mkdir(mode=0o700)
            source = snapshot / "elixir/source.ex"
            source.parent.mkdir()
            source.write_bytes(b"source\n")
            os.chmod(source, 0o644)
            entries = [("elixir/source.ex", "100644", blob_oid(b"source\n"))]
            baseline = readiness._inspect_checkout_snapshot(snapshot, entries, "sha1")
            readiness._prepare_gate_output_mountpoints(snapshot, entries)
            with self.assertRaisesRegex(readiness.ReadinessError, "too many entries"):
                readiness._inspect_checkout_snapshot(snapshot, entries, "sha1")
            readiness._remove_gate_output_mountpoints(snapshot, entries)
            self.assertEqual(
                readiness._inspect_checkout_snapshot(snapshot, entries, "sha1"),
                baseline,
            )

            readiness._prepare_gate_output_mountpoints(snapshot, entries)
            (snapshot / readiness.GATE_COVER_RELATIVE / "unexpected").write_text(
                "unexpected\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(readiness.ReadinessError, "too many entries"):
                readiness._remove_gate_output_mountpoints(snapshot, entries)

    def test_live_source_recomputes_synthetic_schema_basis_from_tree_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            relative = "elixir/priv/codex_schema/0.144.3/manifest.json"
            manifest_path = root / relative
            manifest_path.parent.mkdir(parents=True)
            original = schema_manifest()
            original_payload = readiness.canonical_json_bytes(original)
            manifest_path.write_bytes(original_payload)
            os.chmod(manifest_path, 0o644)

            def oid(payload: bytes) -> str:
                digest = hashlib.sha1()
                digest.update(f"blob {len(payload)}\0".encode("ascii"))
                digest.update(payload)
                return digest.hexdigest()

            original_entries = [(relative, "100644", oid(original_payload))]
            expected = readiness._source_basis_from_index_entries(
                original_entries,
                object_format="sha1",
                schema_manifest_relative=relative,
                schema_manifest_basis_sha256=readiness.schema_manifest_basis_sha256(
                    original
                ),
            )
            self.assertRegex(
                readiness._inspect_source_bound_snapshot(
                    root, original_entries, expected
                ),
                r"\A[0-9a-f]{64}\Z",
            )

            changed = copy.deepcopy(original)
            changed["generation"]["generatedAt"] = "2026-07-18"
            changed_payload = readiness.canonical_json_bytes(changed)
            manifest_path.write_bytes(changed_payload)
            changed_entries = [(relative, "100644", oid(changed_payload))]
            with self.assertRaisesRegex(readiness.ReadinessError, "source differs"):
                readiness._inspect_source_bound_snapshot(
                    root, changed_entries, expected
                )

    def test_authenticated_live_stdout_rejects_build_preamble(self) -> None:
        encoded = json.dumps(
            live_capability_envelope(), separators=(",", ":"), sort_keys=True
        ).encode("utf-8")
        stdout = (
            b"Compiling 1 file (.ex)\n"
            + readiness.LIVE_JSON_PREFIX.encode("ascii")
            + encoded
            + b"\n"
        )
        with self.assertRaisesRegex(readiness.ReadinessError, "unexpectedly rebuilt"):
            readiness.decode_live_task_stdout(stdout, allow_build_preamble=False)

    def test_private_dependency_and_build_fingerprints_bind_all_roots(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            hex_home = root / "hex"
            mix_deps = root / "deps"
            mix_build = root / "build"
            rebar_build = root / "rebar"
            for directory in (hex_home, mix_deps, mix_build, rebar_build):
                directory.mkdir()
            (hex_home / "cache").write_bytes(b"hex")
            dependency = mix_deps / "dependency"
            dependency.write_bytes(b"dependency")
            build = mix_build / "app.beam"
            build.write_bytes(b"beam")
            rebar = rebar_build / "native.o"
            rebar.write_bytes(b"native")

            dependency_before = readiness._private_dependency_roots_fingerprint(
                hex_home, mix_deps
            )
            build_before = readiness._private_build_fingerprint(
                mix_build, rebar_build
            )

            dependency.write_bytes(b"changed")
            self.assertNotEqual(
                readiness._private_dependency_roots_fingerprint(hex_home, mix_deps),
                dependency_before,
            )
            dependency.write_bytes(b"dependency")
            os.chmod(dependency, 0o600)
            dependency_mode = readiness._private_dependency_roots_fingerprint(
                hex_home, mix_deps
            )
            os.chmod(dependency, 0o644)
            self.assertNotEqual(
                readiness._private_dependency_roots_fingerprint(hex_home, mix_deps),
                dependency_mode,
            )
            (mix_deps / "extra").write_bytes(b"extra")
            self.assertNotEqual(
                readiness._private_dependency_roots_fingerprint(hex_home, mix_deps),
                dependency_before,
            )
            dependency.unlink()
            dependency.symlink_to(hex_home / "cache")
            with self.assertRaisesRegex(readiness.ReadinessError, "symlink"):
                readiness._private_dependency_roots_fingerprint(hex_home, mix_deps)
            dependency.unlink()
            dependency.write_bytes(b"dependency")

            rebar.write_bytes(b"changed-native")
            self.assertNotEqual(
                readiness._private_build_fingerprint(mix_build, rebar_build),
                build_before,
            )
            rebar.unlink()
            rebar.symlink_to(build)
            with self.assertRaisesRegex(readiness.ReadinessError, "symlink"):
                readiness._private_build_fingerprint(mix_build, rebar_build)

    def test_private_build_fingerprint_binds_permitted_compiler_links(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            mix_build = root / "build"
            rebar_build = root / "rebar"
            source_root = root / "source"
            dependency_root = root / "deps"
            erlexec_root = root / "erlexec"
            for directory in (
                mix_build,
                rebar_build,
                source_root,
                dependency_root,
                erlexec_root,
            ):
                directory.mkdir()

            (mix_build / "app.beam").write_bytes(b"beam")
            (rebar_build / "native.o").write_bytes(b"native")
            (source_root / "priv").mkdir()
            (source_root / "assets").mkdir()
            for relative in (
                "phoenix/priv",
                "phoenix/include",
                "phoenix/src",
                "make_dep/ebin",
            ):
                (dependency_root / relative).mkdir(parents=True)
            for relative in ("include", "priv", "src", "ebin"):
                (erlexec_root / relative).mkdir()

            copied = mix_build / "dev/lib/copied/priv"
            copied.mkdir(parents=True)
            (copied / "asset").write_bytes(b"copy fallback")

            def relative_link(link: Path, target: Path) -> None:
                link.parent.mkdir(parents=True, exist_ok=True)
                link.symlink_to(
                    os.path.relpath(target, start=link.parent),
                    target_is_directory=True,
                )

            relative_link(
                mix_build / "dev/lib/symphony_elixir/priv", source_root / "priv"
            )
            for leaf in ("priv", "include", "src"):
                relative_link(
                    mix_build / f"dev/lib/phoenix/{leaf}",
                    dependency_root / f"phoenix/{leaf}",
                )
            relative_link(
                mix_build / "dev/lib/make_dep/ebin", dependency_root / "make_dep/ebin"
            )
            for leaf in ("include", "priv", "src", "ebin"):
                relative_link(
                    mix_build / f"dev/lib/erlexec/{leaf}", erlexec_root / leaf
                )
            relative_link(
                mix_build / "dev/phoenix-colocated/symphony_elixir/node_modules",
                source_root / "assets/node_modules",
            )

            default_plugin = rebar_build / "default/plugins/rebar3_hex"
            default_plugin.mkdir(parents=True)
            (default_plugin / "plugin.beam").write_bytes(b"plugin")
            profile_plugin = rebar_build / "prod/plugins/rebar3_hex"
            profile_plugin.parent.mkdir(parents=True)
            profile_plugin.symlink_to(default_plugin, target_is_directory=True)

            def fingerprint() -> str:
                return readiness._private_build_fingerprint(
                    mix_build,
                    rebar_build,
                    source_root=source_root,
                    dependency_root=dependency_root,
                    erlexec_root=erlexec_root,
                )

            missing_fingerprint = fingerprint()
            self.assertRegex(missing_fingerprint, r"\A[0-9a-f]{64}\Z")

            profile_plugin.unlink()
            relative_link(profile_plugin, default_plugin)
            self.assertNotEqual(fingerprint(), missing_fingerprint)

            profile_plugin.unlink()
            profile_plugin.symlink_to(default_plugin, target_is_directory=True)
            (source_root / "assets/node_modules").mkdir()
            self.assertNotEqual(fingerprint(), missing_fingerprint)

            lexical_roots = {
                "build": Path(readiness.SANDBOX_ROOT) / "mix-build",
                "rebar": Path(readiness.SANDBOX_ROOT) / "rebar-build",
                "source": Path(readiness.SANDBOX_WORKSPACE) / "elixir",
                "deps": Path(readiness.SANDBOX_ROOT) / "mix-deps",
                "erlexec": Path(readiness.SANDBOX_ROOT) / "erlexec-source",
            }
            link_targets = [
                (
                    mix_build / "dev/lib/symphony_elixir/priv",
                    lexical_roots["source"] / "priv",
                ),
                *[
                    (
                        mix_build / f"dev/lib/phoenix/{leaf}",
                        lexical_roots["deps"] / f"phoenix/{leaf}",
                    )
                    for leaf in ("priv", "include", "src")
                ],
                (
                    mix_build / "dev/lib/make_dep/ebin",
                    lexical_roots["deps"] / "make_dep/ebin",
                ),
                *[
                    (
                        mix_build / f"dev/lib/erlexec/{leaf}",
                        lexical_roots["erlexec"] / leaf,
                    )
                    for leaf in ("include", "priv", "src", "ebin")
                ],
                (
                    mix_build / "dev/phoenix-colocated/symphony_elixir/node_modules",
                    lexical_roots["source"] / "assets/node_modules",
                ),
            ]
            for link, lexical_target in link_targets:
                link.unlink()
                lexical_link = lexical_roots["build"] / link.relative_to(mix_build)
                link.symlink_to(
                    os.path.relpath(lexical_target, start=lexical_link.parent),
                    target_is_directory=True,
                )
            profile_plugin.unlink()
            profile_plugin.symlink_to(
                lexical_roots["rebar"] / "default/plugins/rebar3_hex",
                target_is_directory=True,
            )
            self.assertRegex(
                readiness._private_build_fingerprint(
                    mix_build,
                    rebar_build,
                    source_root=source_root,
                    dependency_root=dependency_root,
                    erlexec_root=erlexec_root,
                    lexical_roots=lexical_roots,
                ),
                r"\A[0-9a-f]{64}\Z",
            )

    def test_private_build_fingerprint_rejects_unsafe_compiler_links(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            mix_build = root / "build"
            rebar_build = root / "rebar"
            source_root = root / "source"
            dependency_root = root / "deps"
            erlexec_root = root / "erlexec"
            external = root / "external"
            for directory in (
                mix_build,
                rebar_build,
                source_root,
                dependency_root,
                erlexec_root,
                external,
            ):
                directory.mkdir()
            (mix_build / "app.beam").write_bytes(b"beam")
            (source_root / "priv").mkdir()

            link = mix_build / "lib/symphony_elixir/priv"
            link.parent.mkdir(parents=True)

            def fingerprint() -> str:
                return readiness._private_build_fingerprint(
                    mix_build,
                    rebar_build,
                    source_root=source_root,
                    dependency_root=dependency_root,
                    erlexec_root=erlexec_root,
                )

            link.symlink_to(source_root / "priv", target_is_directory=True)
            with self.assertRaisesRegex(readiness.ReadinessError, "absolute"):
                fingerprint()
            link.unlink()

            (external / "priv").mkdir()
            link.symlink_to(
                os.path.relpath(external / "priv", start=link.parent),
                target_is_directory=True,
            )
            with self.assertRaisesRegex(readiness.ReadinessError, "compiler-owned"):
                fingerprint()
            link.unlink()

            dependency_priv = dependency_root / "phoenix/priv"
            dependency_priv.parent.mkdir()
            dependency_link = mix_build / "lib/phoenix/priv"
            dependency_link.parent.mkdir(parents=True)
            dependency_link.symlink_to(
                os.path.relpath(dependency_priv, start=dependency_link.parent),
                target_is_directory=True,
            )
            with self.assertRaisesRegex(readiness.ReadinessError, "missing"):
                fingerprint()

            dependency_priv.write_bytes(b"not a directory")
            with self.assertRaisesRegex(readiness.ReadinessError, "not a directory"):
                fingerprint()
            dependency_priv.unlink()
            dependency_priv.symlink_to(external / "priv", target_is_directory=True)
            with self.assertRaisesRegex(readiness.ReadinessError, "symlink component"):
                fingerprint()
            dependency_priv.unlink()
            dependency_priv.mkdir()

            pivot_target = dependency_root / "foo/priv"
            pivot_target.mkdir(parents=True)
            pivot = mix_build / "lib/foo/priv"
            pivot.parent.mkdir(parents=True)
            pivot.symlink_to(
                os.path.relpath(pivot_target, start=pivot.parent),
                target_is_directory=True,
            )
            dependency_link.unlink()
            dependency_link.symlink_to(
                "../foo/priv/../../../../deps/phoenix/priv",
                target_is_directory=True,
            )
            with self.assertRaisesRegex(readiness.ReadinessError, "compiler-owned"):
                fingerprint()
            dependency_link.unlink()
            dependency_link.symlink_to(
                os.path.relpath(dependency_priv, start=dependency_link.parent),
                target_is_directory=True,
            )

            with mock.patch.object(
                readiness.os,
                "readlink",
                return_value="x" * (readiness.MAX_BUILD_LINK_BYTES + 1),
            ):
                with self.assertRaisesRegex(readiness.ReadinessError, "exceeds"):
                    fingerprint()

            dependency_link.unlink()
            arbitrary = mix_build / "unexpected"
            arbitrary.symlink_to(
                os.path.relpath(dependency_priv, start=arbitrary.parent),
                target_is_directory=True,
            )
            with self.assertRaisesRegex(readiness.ReadinessError, "compiler-owned"):
                fingerprint()
            arbitrary.unlink()

            plugin = rebar_build / "prod/plugins/rebar3_hex"
            plugin.parent.mkdir(parents=True)
            plugin.symlink_to(external / "priv", target_is_directory=True)
            with self.assertRaisesRegex(readiness.ReadinessError, "compiler-owned"):
                fingerprint()

    def test_unsealed_schema_contract_is_rejected(self) -> None:
        unsealed = copy.deepcopy(self.schema)
        unsealed["compatibility"]["fixtures"] = "not_run"
        with self.assertRaisesRegex(readiness.ReadinessError, "fixture compatibility"):
            readiness.schema_manifest_basis_sha256(unsealed)

    def test_schema_metadata_is_exact_and_public_before_pairing(self) -> None:
        extra = copy.deepcopy(self.schema)
        extra["generation"]["privatePath"] = "/home/operator/schema"
        with self.assertRaisesRegex(readiness.ReadinessError, "keys mismatch"):
            readiness.schema_manifest_basis_sha256(extra)

        private = copy.deepcopy(self.schema)
        private["generation"]["generatedAt"] = "operator@example.com"
        with self.assertRaises(readiness.ReadinessError):
            readiness.schema_manifest_basis_sha256(private)


class FullGateCompilerTest(unittest.TestCase):
    def setUp(self) -> None:
        self.matrix = capability_matrix_artifact()
        self.schema = schema_manifest(self.matrix.raw_sha256)
        self.static = static_basis(self.schema)

    def test_generic_gate_sandbox_api_is_credential_blind(self) -> None:
        self.assertTrue(
            {"codex_home", "live_state", "authenticated_inputs_ready"}.isdisjoint(
                readiness.GateSandbox.__dataclass_fields__
            )
        )
        self.assertNotIn(
            "authenticated_codex",
            inspect.signature(readiness._safe_gate_environment).parameters,
        )
        self.assertNotIn(
            "authenticated_codex",
            inspect.signature(readiness._sandbox_command).parameters,
        )

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            host_home = root / "host-home"
            host_mise_data = host_home / "mise-data"
            host_mix_home = host_mise_data / "installs" / "elixir" / "fixture" / ".mix"
            paths = {
                name: root / name
                for name in (
                    "snapshot",
                    "setup-elixir",
                    "git-dir",
                    "home",
                    "xdg-cache",
                    "xdg-config",
                    "xdg-data",
                    "xdg-state",
                    "hex-home",
                    "hex-runtime",
                    "mix-home",
                    "mix-tools",
                    "mix-build",
                    "mix-deps",
                    "rebar-build",
                    "erlexec-source",
                    "coverage-output",
                    "escript-output",
                    "tmp",
                    "mise-cache",
                    "mise-config",
                    "mise-state",
                )
            }
            sandbox = mock.Mock(spec=readiness.GateSandbox)
            for name, path in paths.items():
                setattr(sandbox, name.replace("-", "_"), path)
            sandbox.temporary_root = root
            sandbox.sandbox_uid = os.getuid()
            sandbox.sandbox_gid = os.getgid()
            sandbox.setup_elixir_tracked = ()
            sandbox.erlexec_tracked = ()
            sandbox.mix_rebar_version = "1-18-otp-28"
            sandbox.host_home = host_home
            sandbox.host_tool_bin = host_home / "tools" / "bin"
            sandbox.host_codex_package = host_home / "tools" / "codex"
            sandbox.host_mise_data = host_mise_data
            sandbox.host_mix_home = host_mix_home
            sandbox.resolver_config = None
            sandbox.resolver_target = None

            protected_pointer = "SYMPHONY_LINEAR_" + "ENV_FILE"
            with mock.patch.dict(
                os.environ,
                {
                    "CODEX_HOME": "/private/codex",
                    "LINEAR_API_KEY": "linear-canary",
                    protected_pointer: "/private/pointer",
                },
                clear=False,
            ):
                environment = readiness._safe_gate_environment(sandbox)
                command = readiness._sandbox_command(sandbox, ("true",))

            for key in (
                "CODEX_HOME",
                "LINEAR_API_KEY",
                protected_pointer,
            ):
                self.assertNotIn(key, environment)
                self.assertNotIn(key, command)
            self.assertIn("--unshare-net", command)
            self.assertNotIn("/run/symphony-readiness/codex-home", command)
            self.assertNotIn("/run/symphony-readiness/live-state", command)

    def test_dependency_bootstrap_separates_network_and_offline_compilation(self) -> None:
        sandbox = mock.Mock(spec=readiness.GateSandbox)
        sandbox.erlexec_source = Path("/private/erlexec")
        sandbox.erlexec_tracked = ()
        sandbox.setup_elixir = Path("/private/setup")
        sandbox.setup_elixir_tracked = ()
        sandbox.mix_tools = Path("/private/mix-tools")
        sandbox.mix_rebar_version = "1-18-otp-28"
        sandbox.mix_tools_fingerprint = "mix-tools"
        sandbox.temporary_root = Path("/private/gate")
        with (
            mock.patch.object(
                readiness, "_inspect_private_erlexec_source", return_value="erlexec"
            ),
            mock.patch.object(
                readiness, "_inspect_private_setup_elixir", return_value="source"
            ),
            mock.patch.object(
                readiness, "_inspect_private_mix_tools", return_value="mix-tools"
            ),
            mock.patch.object(
                readiness, "_inspect_private_plt_outputs", return_value="plt"
            ),
            mock.patch.object(
                readiness, "_inspect_gate_generated_outputs", return_value="outputs"
            ),
            mock.patch.object(
                readiness, "_private_dependency_fingerprint", return_value="deps"
            ),
            mock.patch.object(
                readiness, "_private_gate_build_fingerprint", return_value="build"
            ),
            mock.patch.object(readiness, "_reset_private_hex_runtime"),
            mock.patch.object(
                readiness, "_safe_gate_environment", return_value={}
            ),
            mock.patch.object(
                readiness, "_sandbox_command", return_value=("bwrap",)
            ) as sandbox_command,
            mock.patch.object(
                readiness, "run_bounded_command", return_value=(0, b"", b"")
            ),
        ):
            readiness._bootstrap_private_gate_dependencies(sandbox)

        self.assertEqual(sandbox_command.call_count, 6)
        self.assertEqual(
            [call.kwargs["network_disabled"] for call in sandbox_command.call_args_list],
            [False, True, True, False, True, True],
        )
        self.assertEqual(
            [
                call.kwargs["writable_setup_elixir"]
                for call in sandbox_command.call_args_list
            ],
            [True, True, True, True, True, False],
        )
        commands = [call.args[1] for call in sandbox_command.call_args_list]
        self.assertEqual(
            commands[-1][-3:], ("mix", "compile", "--warnings-as-errors")
        )

    def test_sealed_codex_publisher_never_installs_or_launches_with_credentials(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            snapshot = root / "snapshot"
            workflow = snapshot / "elixir" / "WORKFLOW.md"
            workflow.parent.mkdir(parents=True)
            workflow.write_text("---\ntracker:\n  kind: linear\n---\n", encoding="utf-8")
            mix_build = root / "mix-build"
            code_path = mix_build / "dev" / "lib" / "symphony_elixir" / "ebin"
            code_path.mkdir(parents=True)
            sandbox = mock.Mock(spec=readiness.GateSandbox)
            sandbox.temporary_root = root
            sandbox.tmp = root / "tmp"
            sandbox.tmp.mkdir()
            sandbox.snapshot = snapshot
            sandbox.mix_build = mix_build
            sandbox.host_mise_data = root / "mise-data"
            tools = readiness.PrivateLiveRuntimeTools(
                elixir_runner=root / "elixir",
                elixirc_runner=root / "elixirc",
                erlang_root=root / "erlang",
                fingerprint_paths=(),
            )
            installed = {
                "launcherPath": str(root / "codex"),
                "launcherSha256": self.static["codex"]["launcherSha256"],
                "nativePath": str(root / "native-codex"),
                "nativeSha256": self.static["codex"]["nativeSha256"],
                "versionOutput": self.static["codex"]["versionOutput"],
            }
            with (
                mock.patch.object(
                    readiness, "_installed_codex_for_static", return_value=installed
                ),
                mock.patch.object(
                    readiness,
                    "_select_private_live_runtime_tools",
                    return_value=tools,
                ),
                mock.patch.object(
                    readiness,
                    "_inspect_private_live_runtime_tools",
                    return_value="tools",
                ),
                mock.patch.object(
                    readiness,
                    "_private_runtime_code_paths",
                    return_value=(code_path,),
                ),
                mock.patch.object(
                    readiness,
                    "_private_gate_build_fingerprint",
                    return_value="build",
                ),
                mock.patch.object(
                    readiness,
                    "_private_credential_runtime_fingerprint",
                    return_value="runtime",
                ),
                mock.patch.object(
                    readiness,
                    "_request_live_supervisor",
                    side_effect=readiness.ReadinessError("bounded child timeout"),
                ) as supervisor,
                mock.patch.object(
                    readiness, "_install_private_live_credentials"
                ) as install_credentials,
                mock.patch.object(readiness, "run_bounded_command") as direct_child,
                self.assertRaisesRegex(readiness.ReadinessError, "timeout"),
            ):
                readiness._execute_sealed_codex_gate(
                    Path.cwd(),
                    sandbox,
                    self.static,
                    "codex",
                    TREE_A,
                    supervisor_seal(),
                    "build",
                    "runtime",
                )
            supervisor.assert_called_once()
            install_credentials.assert_not_called()
            direct_child.assert_not_called()

    def test_changed_runtime_is_rejected_before_credentials_are_installed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            mix_build = root / "mix-build"
            for app, payload in (
                ("erlexec", b"FOR1-erlexec-BEAM"),
                ("symphony_elixir", b"FOR1-symphony-original-BEAM"),
            ):
                ebin = mix_build / "dev" / "lib" / app / "ebin"
                ebin.mkdir(parents=True)
                (ebin / f"Elixir.{app}.beam").write_bytes(payload)
            sandbox = mock.Mock(spec=readiness.GateSandbox)
            sandbox.mix_build = mix_build
            sandbox.erlexec_source = root / "erlexec-source"
            native = sandbox.erlexec_source / "priv/x86_64-pc-linux-gnu/exec-port"
            native.parent.mkdir(parents=True)
            native.write_bytes(b"FOR1-erlexec-native-original")
            native.chmod(0o700)
            sealed_runtime = readiness._private_credential_runtime_fingerprint(sandbox)
            changed = (
                mix_build
                / "dev/lib/symphony_elixir/ebin/Elixir.symphony_elixir.beam"
            )
            changed.write_bytes(b"FOR1-symphony-replacement-BEAM")

            with (
                mock.patch.object(
                    readiness, "_private_gate_build_fingerprint", return_value="build"
                ),
                mock.patch.object(
                    readiness, "_installed_codex_for_static"
                ) as installed,
                mock.patch.object(readiness, "_request_live_supervisor") as supervisor,
                mock.patch.object(readiness, "run_bounded_command") as direct_child,
                self.assertRaisesRegex(
                    readiness.ReadinessError, "credential runtime changed"
                ),
            ):
                readiness._execute_sealed_codex_gate(
                    Path.cwd(),
                    sandbox,
                    self.static,
                    "codex",
                    TREE_A,
                    supervisor_seal(),
                    "build",
                    sealed_runtime,
                )
            installed.assert_not_called()
            supervisor.assert_not_called()
            direct_child.assert_not_called()

    def test_changed_native_runtime_is_rejected_before_supervisor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            mix_build = root / "mix-build"
            for app, payload in (
                ("erlexec", b"FOR1-erlexec-BEAM"),
                ("symphony_elixir", b"FOR1-symphony-BEAM"),
            ):
                ebin = mix_build / "dev" / "lib" / app / "ebin"
                ebin.mkdir(parents=True)
                (ebin / f"Elixir.{app}.beam").write_bytes(payload)
            erlexec_source = root / "erlexec-source"
            native = erlexec_source / "priv/x86_64-pc-linux-gnu/exec-port"
            native.parent.mkdir(parents=True)
            native.write_bytes(b"FOR1-erlexec-native-original")
            native.chmod(0o700)
            sandbox = mock.Mock(spec=readiness.GateSandbox)
            sandbox.mix_build = mix_build
            sandbox.erlexec_source = erlexec_source
            sealed_runtime = readiness._private_credential_runtime_fingerprint(sandbox)
            native.write_bytes(b"FOR1-erlexec-native-replacement")

            with (
                mock.patch.object(
                    readiness, "_private_gate_build_fingerprint", return_value="build"
                ),
                mock.patch.object(
                    readiness, "_installed_codex_for_static"
                ) as installed,
                mock.patch.object(readiness, "_request_live_supervisor") as supervisor,
                mock.patch.object(readiness, "run_bounded_command") as direct_child,
                self.assertRaisesRegex(
                    readiness.ReadinessError, "credential runtime changed"
                ),
            ):
                readiness._execute_sealed_codex_gate(
                    Path.cwd(),
                    sandbox,
                    self.static,
                    "codex",
                    TREE_A,
                    supervisor_seal(),
                    "build",
                    sealed_runtime,
                )
            installed.assert_not_called()
            supervisor.assert_not_called()
            direct_child.assert_not_called()

    def test_partial_credential_installation_is_removed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sources = root / "sources"
            sources.mkdir(mode=0o700)
            auth = sources / "auth.json"
            auth.write_text('{"tokens":{"access_token":"fixture"}}\n', encoding="utf-8")
            auth.chmod(0o600)
            identity = sources / "identity.key"
            identity.write_bytes(b"i" * 32)
            identity.chmod(0o600)
            credential_root = root / "credentials"
            original_write = readiness._write_private_secret
            writes = 0

            def fail_second_write(destination: Path, payload: bytes) -> None:
                nonlocal writes
                writes += 1
                if writes == 2:
                    raise readiness.ReadinessError("identity write failed")
                original_write(destination, payload)

            with (
                mock.patch.object(
                    readiness,
                    "_write_private_secret",
                    side_effect=fail_second_write,
                ),
                self.assertRaisesRegex(readiness.ReadinessError, "identity write failed"),
            ):
                readiness._install_private_live_credentials(
                    auth, identity, credential_root
                )
            self.assertEqual(writes, 2)
            self.assertFalse(credential_root.exists())
            self.assertFalse(credential_root.is_symlink())

    def test_git_runner_excludes_ambient_configuration_and_secrets(self) -> None:
        completed = subprocess.CompletedProcess(
            ["git", "rev-parse", "HEAD"], 0, stdout=b"value\n", stderr=b""
        )
        with (
            mock.patch.dict(
                os.environ,
                {
                    "GIT_DIR": "/attacker/git-dir",
                    "GIT_WORK_TREE": str(Path.cwd()),
                    "GIT_CONFIG_PARAMETERS": "'core.fsmonitor=/attacker/helper'",
                    "GIT_CONFIG_COUNT": "1",
                    "GIT_CONFIG_KEY_0": "core.fsmonitor",
                    "GIT_CONFIG_VALUE_0": "/attacker/helper",
                    "LINEAR_API_KEY": "must-not-reach-git",
                },
            ),
            mock.patch.object(subprocess, "run", return_value=completed) as run,
        ):
            result = readiness._run_git(Path.cwd(), ["rev-parse", "HEAD"])

        self.assertEqual(result.stdout, b"value\n")
        environment = run.call_args.kwargs["env"]
        self.assertEqual(environment["GIT_CONFIG_GLOBAL"], os.devnull)
        self.assertEqual(environment["GIT_CONFIG_NOSYSTEM"], "1")
        self.assertEqual(environment["GIT_OPTIONAL_LOCKS"], "0")
        self.assertEqual(environment["GIT_ATTR_NOSYSTEM"], "1")
        self.assertEqual(environment["HOME"], os.devnull)
        self.assertNotIn("GIT_DIR", environment)
        self.assertNotIn("GIT_WORK_TREE", environment)
        self.assertNotIn("GIT_CONFIG_PARAMETERS", environment)
        self.assertNotIn("GIT_CONFIG_COUNT", environment)
        self.assertNotIn("LINEAR_API_KEY", environment)
        command = run.call_args.args[0]
        self.assertIn("core.fsmonitor=false", command)
        self.assertIn("core.hooksPath=/dev/null", command)

    def test_real_git_runner_suppresses_ambient_and_local_fsmonitor(self) -> None:
        with without_outer_git_worktree(), tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "--quiet"], cwd=root, check=True)
            tracked = root / "tracked.txt"
            tracked.write_text("tracked\n", encoding="utf-8")
            subprocess.run(["git", "add", "tracked.txt"], cwd=root, check=True)
            hook = root / "fsmonitor-hook.sh"
            sentinel = root / "fsmonitor-ran"
            hook.write_text(
                "#!/bin/sh\n"
                f"printf '%s\\n' \"${{READINESS_AUDIT_SECRET-unset}}\" > {sentinel}\n"
                "printf '2\\n\\n'\n",
                encoding="utf-8",
            )
            hook.chmod(0o700)
            subprocess.run(
                ["git", "config", "core.fsmonitor", str(hook)],
                cwd=root,
                check=True,
            )
            index = root / ".git/index"
            before = index.read_bytes()
            with mock.patch.dict(
                os.environ,
                {
                    "GIT_CONFIG_PARAMETERS": repr(f"core.fsmonitor={hook}"),
                    "READINESS_AUDIT_SECRET": "private-sentinel",
                },
            ):
                result = readiness._run_git(
                    root,
                    ["diff", "--quiet", "--no-ext-diff", "--ignore-submodules", "--"],
                    check=False,
                )

            self.assertEqual(result.returncode, 0)
            self.assertFalse(sentinel.exists())
            self.assertEqual(index.read_bytes(), before)

    def test_actual_gate_evidence_compiles_and_one_failed_command_blocks(self) -> None:
        evidence = full_gate_evidence(self.static)
        report = readiness._compile_full_public_report(
            evidence, self.matrix, self.static
        )
        candidate, passed_schema = readiness.build_readiness_pair(
            self.static, self.matrix, self.schema, report
        )
        self.assertEqual(candidate["runtime"]["overall"], "pass")
        readiness.require_green_pair(candidate, passed_schema)
        self.assertEqual(candidate["capabilities"]["quota"]["sparseUpdate"], "pass")
        self.assertEqual(
            candidate["capabilities"]["linear"]["configuredProjectBinding"],
            LINEAR_BINDING,
        )
        sol = next(
            row
            for row in candidate["capabilities"]["models"]
            if row["model"] == "gpt-5.6-sol"
        )
        self.assertEqual(sol["defaultServiceTier"], "standard")
        self.assertEqual(sol["fastServiceTierId"], "fast-opaque")

        inconsistent_model = public_report(self.matrix)
        inconsistent_model["models"][1]["fastServiceTierId"] = "unadvertised-fast"
        with self.assertRaisesRegex(readiness.ReadinessError, "not advertised"):
            readiness.build_readiness_candidate(
                self.static,
                self.matrix,
                test_verified_report(inconsistent_model),
            )

        blocked_evidence = full_gate_evidence(
            self.static, blocked_gate="capability_fake_conformance"
        )
        blocked_report = readiness._compile_full_public_report(
            blocked_evidence, self.matrix, self.static
        )
        blocked, blocked_schema = readiness.build_readiness_pair(
            self.static, self.matrix, self.schema, blocked_report
        )
        self.assertEqual(blocked["runtime"]["overall"], "blocked_r0_06")
        self.assertIn(
            "conformance.capability_fake_conformance", blocked["runtime"]["blockers"]
        )
        self.assertIn("matrix.methods.account_read", blocked["runtime"]["blockers"])
        self.assertEqual(blocked["capabilities"]["quota"]["sparseUpdate"], "blocked")
        with self.assertRaisesRegex(
            readiness.ReadinessError, "every conformance row to pass"
        ):
            readiness.require_green_pair(blocked, blocked_schema)

        with tempfile.TemporaryDirectory() as temporary:
            readiness_path = Path(temporary) / "readiness.json"
            readiness_path.write_bytes(readiness.canonical_json_bytes(blocked))
            with (
                mock.patch.object(
                    readiness,
                    "collect_static_basis",
                    return_value=(self.static, self.matrix, blocked_schema),
                ),
                mock.patch.object(readiness, "verify_readiness_pair"),
                self.assertRaisesRegex(
                    readiness.ReadinessError, "every conformance row to pass"
                ),
            ):
                readiness.verify_repository_pair(
                    Path(temporary), readiness_path, "codex"
                )

        blocked_live_evidence = full_gate_evidence(
            self.static, blocked_gate="no_model_live_discovery"
        )
        blocked_live_report = readiness._compile_full_public_report(
            blocked_live_evidence, self.matrix, self.static
        )
        blocked_live, _blocked_live_schema = readiness.build_readiness_pair(
            self.static, self.matrix, self.schema, blocked_live_report
        )
        self.assertEqual(blocked_live["runtime"]["overall"], "blocked_r0_06")
        self.assertEqual(
            blocked_live["capabilities"]["auth"]["referenceProfile"],
            {
                "chatgptAuthentication": False,
                "identityBinding": False,
                "solAvailable": False,
                "solReviewEffort": False,
                "solUltra": False,
                "status": "fail",
                "terraAvailable": False,
                "terraHigh": False,
                "terraMedium": False,
            },
        )
        self.assertIn(
            "conformance.no_model_live_discovery",
            blocked_live["runtime"]["blockers"],
        )
        self.assertIn("auth.reference_profile", blocked_live["runtime"]["blockers"])

    def test_fabricated_command_outcome_and_live_receipt_are_rejected(self) -> None:
        evidence = full_gate_evidence(self.static)
        executions = list(evidence.executions)
        first = executions[0]
        executions[0] = readiness.GateExecution(
            first.identifier, ("true",), first.outcome, b"", b""
        )
        fabricated = readiness.FullGateEvidence(
            tuple(executions),
            evidence.live,
            evidence.linear,
            evidence.package,
            evidence.source_sha256,
            evidence.index_tree,
        )
        with self.assertRaisesRegex(readiness.ReadinessError, "command differs"):
            readiness._gate_outcomes(fabricated)

        executions[0] = readiness.GateExecution(
            first.identifier, first.command, "not_run", b"", b""
        )
        fabricated = readiness.FullGateEvidence(
            tuple(executions),
            evidence.live,
            evidence.linear,
            evidence.package,
            evidence.source_sha256,
            evidence.index_tree,
        )
        with self.assertRaisesRegex(readiness.ReadinessError, "invalid outcome"):
            readiness._gate_outcomes(fabricated)

        captured = evidence.live._copy_for_compiler()
        captured["envelope"]["requestReceipts"][0]["method"] = "thread/start"
        fabricated = readiness.FullGateEvidence(
            evidence.executions,
            readiness._new_live_capability_evidence(captured),
            evidence.linear,
            evidence.package,
            evidence.source_sha256,
            evidence.index_tree,
        )
        with self.assertRaisesRegex(readiness.ReadinessError, "classification"):
            readiness._compile_full_public_report(
                fabricated, self.matrix, self.static
            )

    def test_quota_live_overrides_are_exact_and_do_not_infer_metadata(self) -> None:
        report = live_capability_envelope()["capabilityReport"]
        expected = {
            "rate_limits.multi_bucket": "pass",
            "rate_limits.credits": "pass",
            "rate_limits.credits_has_credits": "pass",
            "rate_limits.credits_balance": "absent",
            "rate_limits.bucket_credits": "pass",
            "rate_limits.bucket_limit_id": "absent",
            "rate_limits.secondary.used_percent": "absent",
            "rate_limits.bucket_primary.used_percent": "pass",
            "rate_limits.bucket_primary.window_duration": "absent",
            "rate_limits.reset_credits": "absent",
            "rate_limits.reset_credit_description": "absent",
        }
        for identifier, outcome in expected.items():
            with self.subTest(identifier=identifier):
                self.assertEqual(
                    readiness._field_live_override(identifier, "optional", report),
                    outcome,
                )

        restricted = copy.deepcopy(report)
        restricted["quotaShape"] = {"status": "auth_restricted"}
        self.assertEqual(
            readiness._field_live_override(
                "rate_limits.bucket_credits", "optional", restricted
            ),
            "auth_restricted",
        )
        self.assertIsNone(
            readiness._field_live_override(
                "rate_limits.updated_snapshot", "required", report
            )
        )

        self.assertEqual(readiness._quota_full_read_status(report["quotaShape"]), "pass")
        for key, value in (
            ("bucketCount", 0),
            ("windowSlotCount", 0),
            ("outOfRangeValues", True),
        ):
            unusable = copy.deepcopy(report["quotaShape"])
            unusable[key] = value
            self.assertEqual(
                readiness._quota_full_read_status(unusable),
                "blocked",
                key,
            )

        usage = copy.deepcopy(report)
        usage["optional"]["usage"] = {
            "result": {
                "dailyBucketCount": 0,
                "populatedSummaryFields": ["lifetimeTokens"],
            },
            "status": "available",
        }
        self.assertEqual(
            readiness._field_live_override("usage.summary", "optional", usage),
            "pass",
        )
        self.assertEqual(
            readiness._field_live_override("usage.daily_tokens", "optional", usage),
            "absent",
        )
        self.assertEqual(
            readiness._field_live_override("usage.lifetime_tokens", "optional", usage),
            "pass",
        )
        self.assertEqual(
            readiness._field_live_override("usage.peak_daily_tokens", "optional", usage),
            "absent",
        )
        self.assertEqual(
            readiness._field_live_override("features.data", "optional", report),
            "pass",
        )
        self.assertEqual(
            readiness._field_live_override("features.cursor", "optional", report),
            "absent",
        )
        self.assertEqual(
            readiness._field_live_override("features.next_cursor", "optional", report),
            "absent",
        )
        self.assertEqual(
            readiness._field_live_override("collaboration.mask_mode", "optional", report),
            "pass",
        )
        null_collaboration = copy.deepcopy(report)
        null_collaboration["optional"]["collaborationModes"]["result"][0]["mode"] = None
        self.assertEqual(
            readiness._field_live_override(
                "collaboration.mask_mode", "optional", null_collaboration
            ),
            "absent",
        )
        self.assertIsNone(
            readiness._field_live_override("features.invented", "optional", report)
        )

    def test_linear_task_decoder_allowlists_reasons_then_strips_them(self) -> None:
        raw = {
            "configuredProjectBinding": LINEAR_BINDING,
            "configuredProjectBindingGeneration": 1,
            "reportVersion": 1,
            **{
                key: {"reason": "verified", "status": "pass"}
                for key in readiness.LINEAR_STATUS_KEYS_IN_PROBE_ORDER
            },
        }
        raw["mutations"] = {
            "evidence": "schema_only",
            "reason": "schema_verified",
            "status": "pass",
        }
        projected = readiness._normalize_linear_task_report(raw)
        self.assertEqual(projected["connectivity"], {"status": "pass"})
        self.assertEqual(
            projected["mutations"],
            {"evidence": "schema_only", "status": "pass"},
        )
        self.assertNotIn("reason", json.dumps(projected))

        blocked = copy.deepcopy(raw)
        for key in readiness.LINEAR_STATUS_KEYS_IN_PROBE_ORDER:
            blocked[key] = {"reason": "missing_api_key", "status": "blocked"}
        blocked_projected = readiness._normalize_linear_task_report(blocked)
        self.assertEqual(blocked_projected["project"]["status"], "blocked")
        self.assertEqual(
            blocked_projected["mutations"],
            {"evidence": "unavailable", "status": "blocked"},
        )

        invented = copy.deepcopy(raw)
        invented["project"]["reason"] = "raw-private-provider-message"
        with self.assertRaisesRegex(readiness.ReadinessError, "reason"):
            readiness._normalize_linear_task_report(invented)

        inconsistent = copy.deepcopy(raw)
        inconsistent["project"] = {"reason": "verified", "status": "blocked"}
        with self.assertRaisesRegex(readiness.ReadinessError, "inconsistent"):
            readiness._normalize_linear_task_report(inconsistent)

        unevidenced_mutation = copy.deepcopy(raw)
        unevidenced_mutation["mutations"] = {"reason": "verified", "status": "pass"}
        with self.assertRaisesRegex(readiness.ReadinessError, "schema-only evidence"):
            readiness._normalize_linear_task_report(unevidenced_mutation)

        self.assertEqual(
            readiness._default_linear()["mutations"],
            {"evidence": "not_run", "status": "not_run"},
        )
        for status, evidence in (
            ("pass", "unavailable"),
            ("blocked", "not_run"),
            ("not_run", "schema_only"),
        ):
            invalid_public = copy.deepcopy(projected)
            invalid_public["mutations"] = {"evidence": evidence, "status": status}
            with self.assertRaisesRegex(readiness.ReadinessError, "inconsistent"):
                readiness._normalize_linear(invalid_public)

        extra_public_key = copy.deepcopy(projected)
        extra_public_key["mutations"]["reason"] = "schema_verified"
        with self.assertRaisesRegex(readiness.ReadinessError, "keys mismatch"):
            readiness._normalize_linear(extra_public_key)

        for fixture_reason in (
            "fixture_blocker_missing",
            "fixture_changed",
            "fixture_comment_missing",
            "fixture_issue_missing",
            "fixture_shape_mismatch",
            "validation_team_mismatch",
        ):
            fixture_blocked = copy.deepcopy(raw)
            for key in readiness.LINEAR_STATUS_KEYS_IN_PROBE_ORDER:
                fixture_blocked[key] = {
                    "reason": fixture_reason,
                    "status": "blocked",
                }
            normalized = readiness._normalize_linear_task_report(fixture_blocked)
            self.assertEqual(normalized["project"], {"status": "blocked"})
            self.assertNotIn(fixture_reason, json.dumps(normalized))

    def test_source_bound_linear_probe_opts_into_private_validation_fixtures(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            snapshot = root / "snapshot"
            workflow = snapshot / "elixir" / "WORKFLOW.md"
            workflow.parent.mkdir(parents=True)
            workflow.write_text("---\ntracker:\n  kind: linear\n---\n", encoding="utf-8")
            mix_build = root / "mix-build"
            code_path = mix_build / "dev" / "lib" / "symphony_elixir" / "ebin"
            code_path.mkdir(parents=True)
            host_tool_bin = root / "tools"
            host_tool_bin.mkdir()
            host_mise_data = root / "mise-data"
            host_mise_data.mkdir()
            sandbox = mock.Mock(spec=readiness.GateSandbox)
            sandbox.snapshot = snapshot
            sandbox.mix_build = mix_build
            sandbox.host_mise_data = host_mise_data
            sandbox.host_tool_bin = host_tool_bin
            sandbox.mix_rebar_version = "1-18-otp-28"
            sandbox.sandbox_uid = os.getuid()
            sandbox.sandbox_gid = os.getgid()
            tools = readiness.PrivateLiveRuntimeTools(
                elixir_runner=host_mise_data / "bin" / "elixir",
                elixirc_runner=host_mise_data / "bin" / "elixirc",
                erlang_root=host_mise_data / "erlang",
                fingerprint_paths=(),
            )
            command = readiness._sealed_linear_task_command(
                sandbox, tools, (code_path,)
            )
            child_environment = readiness._linear_task_environment(
                sandbox, tools
            )

            self.assertEqual(command[0], str(tools.elixir_runner))
            self.assertIn(readiness.LINEAR_TASK_ENTRYPOINT, command)
            self.assertIn("--validation-fixtures", command)
            self.assertIn("--workflow", command)
            self.assertEqual(
                command[command.index("--workflow") + 1],
                f"{readiness.SANDBOX_WORKSPACE}/elixir/WORKFLOW.md",
            )
            self.assertNotIn("mix", command)
            self.assertNotIn("mise", command)
            self.assertNotIn("compile", command)
            self.assertNotIn("LINEAR_API_KEY", child_environment)
            self.assertEqual(
                child_environment[readiness.LINEAR_BROKER_ENVIRONMENT_KEY],
                readiness.LINEAR_BROKER_SANDBOX_PATH,
            )
            for prefix in ("HEX", "MISE", "MIX", "REBAR", "SYMPHONY_ERLEXEC"):
                self.assertFalse(
                    any(key.startswith(prefix) for key in child_environment)
                )
            protected_pointer = "SYMPHONY_LINEAR_" + "ENV_FILE"
            self.assertNotIn(protected_pointer, child_environment)

    def test_sealed_linear_publisher_receives_only_supervisor_public_record(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sandbox = mock.Mock(spec=readiness.GateSandbox)
            sandbox.temporary_root = root
            sandbox.snapshot = root / "snapshot"
            sandbox.mix_build = root / "mix-build"
            sandbox.host_mise_data = root / "mise-data"
            sandbox.tmp = root / "tmp"
            sandbox.tmp.mkdir()
            code_path = root / "mix-build/dev/lib/symphony_elixir/ebin"
            code_path.mkdir(parents=True)
            tools = readiness.PrivateLiveRuntimeTools(
                elixir_runner=root / "elixir",
                elixirc_runner=root / "elixirc",
                erlang_root=root / "erlang",
                fingerprint_paths=(),
            )
            record = {
                "reportVersion": 1,
                "sourceSha256": SHA_A,
                "configuredProjectBinding": LINEAR_BINDING,
                **{
                    key: {"status": "pass"}
                    for key in readiness.LINEAR_STATUS_KEYS_IN_PROBE_ORDER
                    if key != "mutations"
                },
                "mutations": {"evidence": "schema_only", "status": "pass"},
            }
            with (
                mock.patch.object(
                    readiness, "_private_gate_build_fingerprint", return_value="build"
                ),
                mock.patch.object(
                    readiness,
                    "_private_credential_runtime_fingerprint",
                    return_value="runtime",
                ),
                mock.patch.object(
                    readiness, "_select_private_live_runtime_tools", return_value=tools
                ),
                mock.patch.object(
                    readiness, "_inspect_private_live_runtime_tools", return_value="tools"
                ),
                mock.patch.object(
                    readiness, "_private_runtime_code_paths", return_value=(code_path,)
                ),
                mock.patch.object(
                    readiness, "_request_live_supervisor", return_value=record
                ) as supervisor,
                mock.patch.object(
                    readiness, "_linear_broker_socket_fingerprint"
                ) as raw_broker,
                mock.patch.object(readiness, "run_bounded_command") as direct_child,
            ):
                returncode, stdout, stderr = readiness._execute_sealed_linear_gate(
                    Path.cwd(),
                    sandbox,
                    SHA_A,
                    TREE_A,
                    supervisor_seal(),
                    "build",
                    "runtime",
                )
            self.assertEqual(returncode, 0)
            self.assertEqual(stderr, b"")
            self.assertTrue(stdout.startswith(readiness.LINEAR_PROBE_JSON_PREFIX.encode()))
            supervisor.assert_called_once()
            raw_broker.assert_not_called()
            direct_child.assert_not_called()

    def test_supervisor_boundary_metadata_and_raw_secret_selectors_fail_closed(self) -> None:
        request_parameters = inspect.signature(
            readiness._request_live_supervisor
        ).parameters
        self.assertEqual(readiness.LIVE_SUPERVISOR_PROTOCOL_VERSION, 4)
        self.assertIn("supervisor_seal", request_parameters)
        self.assertNotIn("credential_runtime_fingerprint", request_parameters)
        self.assertGreater(
            readiness.LIVE_SUPERVISOR_CLIENT_TIMEOUT_SECONDS,
            readiness.LIVE_SUPERVISOR_SESSION_BOUND_SECONDS,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo_root = root / "repo"
            repo_root.mkdir(mode=0o700)
            boundary = root / "boundary"
            boundary.mkdir(mode=0o700)
            shared = boundary / "work"
            shared.mkdir(mode=0o700)
            socket_path = boundary / "control.sock"
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                listener.bind(str(socket_path))
                socket_path.chmod(0o600)
                environment = {
                    readiness.LIVE_SUPERVISOR_SOCKET_ENVIRONMENT_KEY: str(socket_path),
                    readiness.LIVE_SUPERVISOR_SHARED_PARENT_ENVIRONMENT_KEY: str(shared),
                }
                with (
                    mock.patch.object(
                        readiness, "LIVE_SUPERVISOR_SOCKET_PATH", socket_path
                    ),
                    mock.patch.object(
                        readiness, "LIVE_SUPERVISOR_SHARED_PARENT", shared
                    ),
                    mock.patch.dict(os.environ, environment, clear=True),
                ):
                    selected = readiness._live_supervisor_boundary(repo_root)
                self.assertEqual(selected[:2], (socket_path, shared))
                self.assertEqual(len(selected[2]), 16)

                socket_path.chmod(0o666)
                with (
                    mock.patch.object(
                        readiness, "LIVE_SUPERVISOR_SOCKET_PATH", socket_path
                    ),
                    mock.patch.object(
                        readiness, "LIVE_SUPERVISOR_SHARED_PARENT", shared
                    ),
                    mock.patch.dict(os.environ, environment, clear=True),
                    self.assertRaisesRegex(readiness.ReadinessError, "metadata"),
                ):
                    readiness._live_supervisor_boundary(repo_root)

                sandbox = mock.Mock(spec=readiness.GateSandbox)
                protected_linear_selector = "_".join(
                    ("SYMPHONY", "LINEAR", "ENV", "FILE")
                )
                for selector in ("LINEAR_API_KEY", protected_linear_selector):
                    with (
                        self.subTest(selector=selector),
                        mock.patch.dict(
                            os.environ,
                            {**environment, selector: "credential-canary"},
                            clear=True,
                        ),
                        self.assertRaisesRegex(
                            readiness.ReadinessError, "credential selector"
                        ),
                    ):
                        readiness._request_live_supervisor(
                            repo_root,
                            sandbox,
                            operation="linear",
                            index_tree=TREE_A,
                            supervisor_seal=supervisor_seal(),
                            source_sha256=SHA_A,
                            tool_runtime_fingerprint=SHA_A,
                            static_basis_sha256=None,
                            installed_codex=None,
                        )
                with (
                    mock.patch.dict(os.environ, environment, clear=True),
                    mock.patch.object(
                        readiness, "_git_text", return_value=TREE_B
                    ),
                    mock.patch.object(
                        readiness, "_live_supervisor_boundary"
                    ) as selected_boundary,
                    self.assertRaisesRegex(
                        readiness.ReadinessError, "index tree changed"
                    ),
                ):
                    readiness._request_live_supervisor(
                        repo_root,
                        sandbox,
                        operation="linear",
                        index_tree=TREE_A,
                        supervisor_seal=supervisor_seal(),
                        source_sha256=SHA_A,
                        tool_runtime_fingerprint=SHA_A,
                        static_basis_sha256=None,
                        installed_codex=None,
                    )
                selected_boundary.assert_not_called()

                sandbox.temporary_root = (
                    shared / "symphony-readiness-full-client-contract"
                )
                sandbox.temporary_root.mkdir(mode=0o700)
                boundary_fingerprint = selected[2]
                seal_response = {
                    "indexTree": TREE_A,
                    "op": "seal",
                    "sealId": SHA_B,
                    "v": 4,
                }
                with (
                    mock.patch.dict(os.environ, environment, clear=True),
                    mock.patch.object(
                        readiness, "_git_text", return_value=TREE_A
                    ),
                    mock.patch.object(
                        readiness,
                        "_live_supervisor_boundary",
                        return_value=(socket_path, shared, boundary_fingerprint),
                    ),
                    mock.patch.object(
                        readiness,
                        "_exchange_live_supervisor_request",
                        return_value=seal_response,
                    ) as exchange,
                ):
                    seal = readiness._seal_live_supervisor_runtime(
                        repo_root,
                        sandbox,
                        index_tree=TREE_A,
                    )
                seal_request = exchange.call_args.args[1]
                self.assertEqual(
                    set(seal_request),
                    {"indexTree", "op", "v"},
                )
                self.assertNotIn("credentialRuntimeFingerprint", seal_request)
                self.assertNotIn("temporaryName", seal_request)
                self.assertEqual(seal.seal_id, SHA_B)

                capability_response = {
                    "op": "linear",
                    "record": {"status": "pass"},
                    "sealId": SHA_B,
                    "v": 4,
                }
                with (
                    mock.patch.dict(os.environ, environment, clear=True),
                    mock.patch.object(
                        readiness, "_git_text", return_value=TREE_A
                    ),
                    mock.patch.object(
                        readiness,
                        "_live_supervisor_boundary",
                        return_value=(socket_path, shared, boundary_fingerprint),
                    ),
                    mock.patch.object(
                        readiness,
                        "_exchange_live_supervisor_request",
                        return_value=capability_response,
                    ) as exchange,
                ):
                    readiness._request_live_supervisor(
                        repo_root,
                        sandbox,
                        operation="linear",
                        index_tree=TREE_A,
                        supervisor_seal=seal,
                        source_sha256=SHA_A,
                        tool_runtime_fingerprint=SHA_A,
                        static_basis_sha256=None,
                        installed_codex=None,
                    )
                capability_request = exchange.call_args.args[1]
                self.assertEqual(
                    set(capability_request),
                    {
                        "indexTree",
                        "installedCodex",
                        "op",
                        "sealId",
                        "sourceSha256",
                        "staticBasisSha256",
                        "toolRuntimeFingerprint",
                        "v",
                    },
                )
                self.assertNotIn("credentialRuntimeFingerprint", capability_request)
                self.assertNotIn("temporaryName", capability_request)
            finally:
                listener.close()

    def test_prefixed_probe_record_must_be_unique_and_final(self) -> None:
        prefix = readiness.PACKAGE_PROBE_JSON_PREFIX
        encoded = b'{"reportVersion":1}'
        payload = b"===> Analyzing applications...\n" + prefix.encode() + encoded + b"\n"
        self.assertEqual(
            readiness._decode_prefixed_record(payload, prefix, "fixture"),
            {"reportVersion": 1},
        )
        forged_then_chatter = (
            prefix.encode()
            + encoded
            + b"\n===> Analyzing applications...\n"
        )
        with self.assertRaisesRegex(readiness.ReadinessError, "final line"):
            readiness._decode_prefixed_record(
                forged_then_chatter, prefix, "fixture"
            )
        duplicate = prefix.encode() + encoded + b"\n" + prefix.encode() + encoded
        with self.assertRaisesRegex(readiness.ReadinessError, "duplicate"):
            readiness._decode_prefixed_record(duplicate, prefix, "fixture")

    def test_public_compiler_has_no_claim_inputs_and_source_drift_is_fatal(self) -> None:
        self.assertEqual(
            list(inspect.signature(readiness.compile_full_gate_pair).parameters),
            ["repo_root", "codex_command", "mise_command"],
        )
        drifted = copy.deepcopy(self.static)
        drifted["checkout"]["source"]["sha256"] = SHA_B
        evidence = full_gate_evidence(self.static)
        with (
            mock.patch.object(
                readiness,
                "collect_static_basis",
                side_effect=[
                    (self.static, self.matrix, self.schema),
                    (drifted, self.matrix, self.schema),
                ],
            ),
            mock.patch.object(readiness, "_git_text", return_value=COMMIT_A),
            mock.patch.object(
                readiness, "_execute_full_gate_inventory", return_value=evidence
            ),
        ):
            with self.assertRaisesRegex(readiness.ReadinessError, "changed during"):
                readiness.compile_full_gate_pair(Path.cwd())

        blocked_evidence = full_gate_evidence(
            self.static, blocked_gate="installed_codex_verify"
        )
        archive_rehearsal = mock.Mock()
        with (
            mock.patch.object(
                readiness,
                "collect_static_basis",
                side_effect=[
                    (self.static, self.matrix, self.schema),
                    (self.static, self.matrix, self.schema),
                ],
            ),
            mock.patch.object(readiness, "_git_text", return_value=COMMIT_A),
            mock.patch.object(
                readiness,
                "_execute_full_gate_inventory",
                return_value=blocked_evidence,
            ),
            mock.patch.object(
                readiness,
                "rehearse_final_pair_source_archive",
                archive_rehearsal,
            ),
            self.assertRaisesRegex(
                readiness.ReadinessError, "every conformance row to pass"
            ),
        ):
            readiness.compile_full_gate_pair(Path.cwd())
        archive_rehearsal.assert_not_called()

    def test_offline_dialyzer_replay_rejects_false_green_and_plt_drift(self) -> None:
        marker = readiness.DIALYZER_ERROR_MARKER
        self.assertTrue(readiness._dialyzer_output_has_error(marker, b""))
        self.assertTrue(readiness._dialyzer_output_has_error(b"", marker))
        self.assertFalse(readiness._dialyzer_output_has_error(b"ok\n", b""))
        for stdout, stderr in ((marker, b""), (b"", marker)):
            self.assertFalse(
                readiness._gate_command_passed(
                    "upstream_make_all", 0, stdout, stderr
                )
            )
        self.assertTrue(
            readiness._gate_command_passed(
                "upstream_make_all", 0, b"dialyzer pass\n", b""
            )
        )

        sandbox = mock.Mock()
        sandbox.temporary_root = Path("/tmp/private-gate")
        sandbox.mix_tools = Path("/tmp/private-gate/mix-tools")
        sandbox.mix_rebar_version = "1-19-otp-28"
        sandbox.mix_tools_fingerprint = SHA_A
        for stdout, stderr in ((marker, b""), (b"", marker)):
            with (
                mock.patch.object(
                    readiness,
                    "_safe_gate_environment",
                    return_value={"HEX_OFFLINE": "1"},
                ),
                mock.patch.object(
                    readiness, "_sandbox_command", return_value=("wrapped",)
                ),
                mock.patch.object(
                    readiness,
                    "run_bounded_command",
                    return_value=(0, stdout, stderr),
                ),
                self.assertRaisesRegex(readiness.ReadinessError, "replay failed"),
            ):
                readiness._run_offline_dialyzer_replay(sandbox, SHA_B)

        with (
            mock.patch.object(
                readiness,
                "_safe_gate_environment",
                return_value={"HEX_OFFLINE": "1"},
            ),
            mock.patch.object(
                readiness, "_sandbox_command", return_value=("wrapped",)
            ) as sandbox_command,
            mock.patch.object(
                readiness,
                "run_bounded_command",
                return_value=(0, b"dialyzer pass\n", b""),
            ) as bounded_command,
            mock.patch.object(
                readiness, "_inspect_private_plt_outputs", return_value=SHA_B
            ),
            mock.patch.object(
                readiness, "_inspect_private_mix_tools", return_value=SHA_A
            ),
        ):
            readiness._run_offline_dialyzer_replay(sandbox, SHA_B)
        sandbox_command.assert_called_once_with(
            sandbox,
            readiness.OFFLINE_DIALYZER_REPLAY_COMMAND,
            writable_git=True,
            writable_erlexec=True,
            writable_mix_home=True,
        )
        self.assertEqual(
            bounded_command.call_args.kwargs["timeout_seconds"],
            readiness.OFFLINE_DIALYZER_REPLAY_TIMEOUT_SECONDS,
        )

        with (
            mock.patch.object(
                readiness,
                "_safe_gate_environment",
                return_value={"HEX_OFFLINE": "1"},
            ),
            mock.patch.object(
                readiness, "_sandbox_command", return_value=("wrapped",)
            ),
            mock.patch.object(
                readiness,
                "run_bounded_command",
                return_value=(0, b"dialyzer pass\n", b""),
            ),
            mock.patch.object(
                readiness, "_inspect_private_plt_outputs", return_value=SHA_C
            ),
            self.assertRaisesRegex(readiness.ReadinessError, "changed private PLTs"),
        ):
            readiness._run_offline_dialyzer_replay(sandbox, SHA_B)

    def test_private_mix_tool_seed_excludes_host_plts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            snapshot = root / "snapshot"
            (snapshot / "elixir").mkdir(parents=True)
            (snapshot / "elixir/mise.toml").write_text(
                '[tools]\nerlang = "28"\nelixir = "1.19.5-otp-28"\n',
                encoding="utf-8",
            )
            host_mise = root / "host-mise"
            host_mix = (
                host_mise
                / "installs/elixir/1.19.5-otp-28/.mix"
            )
            archive = host_mix / "archives/hex-2.4.2/hex-2.4.2"
            (archive / "ebin").mkdir(parents=True)
            (archive / ".elixir").write_text("~> 1.12\n", encoding="ascii")
            (archive / "ebin/hex.app").write_text(
                '{application,hex,[{vsn,"2.4.2"}]}.\n', encoding="ascii"
            )
            rebar = host_mix / "elixir/1-19-otp-28/rebar3"
            rebar.parent.mkdir(parents=True)
            rebar.write_bytes(
                b"#!/usr/bin/env escript\n%% Rebar3 3.25.1\n%%! +A 1\n"
            )
            os.chmod(rebar, 0o755)
            (host_mix / "dialyxir_erlang-28.5.plt").write_bytes(b"host-core")
            (host_mix / "dialyxir_erlang-28.5.plt.hash").write_bytes(b"host-hash")

            selected, tools, rebar_version, fingerprint = (
                readiness._prepare_private_mix_tools(
                    snapshot, root / "private", host_mise
                )
            )
            self.assertEqual(selected, host_mix)
            self.assertEqual(rebar_version, "1-19-otp-28")
            self.assertEqual(
                readiness._inspect_private_mix_tools(tools, rebar_version),
                fingerprint,
            )
            self.assertFalse(
                any(
                    path.name.endswith((".plt", ".plt.hash"))
                    for path in tools.rglob("*")
                )
            )

    def test_private_mix_archive_selection_is_bounded_before_sort(self) -> None:
        class CountingScandir:
            def __init__(self) -> None:
                self.consumed = 0
                self.closed = False

            def __enter__(self):
                return self

            def __exit__(self, *_args) -> None:
                self.closed = True

            def __iter__(self):
                return self

            def __next__(self):
                self.consumed += 1
                if self.consumed > readiness.MAX_MIX_HEX_ARCHIVES + 1:
                    raise AssertionError("archive discovery exceeded its hard pull bound")
                return mock.Mock(name=f"hex-{self.consumed}")

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            snapshot = root / "snapshot"
            (snapshot / "elixir").mkdir(parents=True)
            (snapshot / "elixir/mise.toml").write_text(
                '[tools]\nerlang = "28"\nelixir = "1.19.5-otp-28"\n',
                encoding="utf-8",
            )
            host_mise = root / "host-mise"
            host_mix = host_mise / "installs/elixir/1.19.5-otp-28/.mix"
            host_mix.mkdir(parents=True)
            entries = CountingScandir()

            with (
                mock.patch.object(readiness.os, "scandir", return_value=entries),
                self.assertRaisesRegex(readiness.ReadinessError, "inventory is invalid"),
            ):
                readiness._prepare_private_mix_tools(
                    snapshot, root / "private", host_mise
                )

            self.assertEqual(
                entries.consumed, readiness.MAX_MIX_HEX_ARCHIVES + 1
            )
            self.assertTrue(entries.closed)

    def test_private_plt_inventory_binds_exact_hash_sidecar_and_versions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            mix_home = root / "mix-home"
            mix_build = root / "mix-build"
            for directory in (
                mix_home,
                mix_home / "archives",
                mix_home / "elixir",
                mix_build,
                mix_build / "dev",
            ):
                directory.mkdir(mode=0o700, exist_ok=True)

            paths = (
                mix_home / "dialyxir_erlang-28.5.plt",
                mix_home / "dialyxir_erlang-28.5_elixir-1.19.5.plt",
                mix_build
                / "dev/dialyxir_erlang-28.5_elixir-1.19.5_deps-dev.plt",
                mix_build
                / "dev/dialyxir_erlang-28.5_elixir-1.19.5_deps-dev.plt.hash",
            )
            for index, path in enumerate(paths):
                path.write_bytes(f"private-plt-{index}\n".encode("ascii"))
                os.chmod(path, 0o600)

            sandbox = mock.Mock()
            sandbox.mix_home = mix_home
            sandbox.mix_build = mix_build
            sandbox.sandbox_uid = os.getuid()
            sandbox.sandbox_gid = os.getgid()
            sandbox.host_home = root / "masked-host-home"
            sandbox.host_mise_data = root / "masked-host-mise"
            sandbox.host_mix_home = root / "masked-host-mix"
            sandbox.temporary_root = root
            readiness._inspect_private_plt_outputs(
                sandbox, require_complete=True
            )

            mismatched_hash = (
                mix_build
                / "dev/dialyxir_erlang-99.9_elixir-9.9.9_deps-dev.plt.hash"
            )
            paths[3].rename(mismatched_hash)
            with self.assertRaisesRegex(readiness.ReadinessError, "hash sidecar"):
                readiness._inspect_private_plt_outputs(
                    sandbox, require_complete=True
                )
            mismatched_hash.rename(paths[3])

            mismatched_core = mix_home / "dialyxir_erlang-28.6.plt"
            paths[0].rename(mismatched_core)
            with self.assertRaisesRegex(readiness.ReadinessError, "versions"):
                readiness._inspect_private_plt_outputs(
                    sandbox, require_complete=True
                )
            mismatched_core.rename(paths[0])

            mismatched_dependency_plt = (
                mix_build
                / "dev/dialyxir_erlang-99.9_elixir-9.9.9_deps-dev.plt"
            )
            mismatched_dependency_hash = (
                mix_build
                / "dev/dialyxir_erlang-99.9_elixir-9.9.9_deps-dev.plt.hash"
            )
            paths[2].rename(mismatched_dependency_plt)
            paths[3].rename(mismatched_dependency_hash)
            try:
                with self.assertRaisesRegex(readiness.ReadinessError, "versions"):
                    readiness._inspect_private_plt_outputs(
                        sandbox, require_complete=True
                    )
            finally:
                mismatched_dependency_plt.rename(paths[2])
                mismatched_dependency_hash.rename(paths[3])

    def test_capability_error_fixture_is_source_bound_and_targeted(self) -> None:
        fixture = "test/symphony_elixir/codex_capability_error_test.exs"
        self.assertIn(fixture, readiness.SOURCE_BOUND_FIXTURE_FILES)
        self.assertIn(
            fixture,
            readiness.REQUIRED_CONFORMANCE_COMMANDS[
                "capability_fake_conformance"
            ],
        )
        linear_command = readiness.REQUIRED_CONFORMANCE_COMMANDS[
            "linear_fake_conformance"
        ]
        for linear_fixture in (
            "test/symphony_elixir/linear_error_boundary_test.exs",
            "test/symphony_elixir/extensions_test.exs",
        ):
            self.assertIn(linear_fixture, readiness.SOURCE_BOUND_FIXTURE_FILES)
            self.assertIn(linear_fixture, linear_command)

    def test_noncanonical_tool_selector_fails_closed(self) -> None:
        self.assertEqual(
            readiness.GATE_TIMEOUT_SECONDS["upstream_make_all"],
            readiness.UPSTREAM_MAKE_ALL_TIMEOUT_SECONDS,
        )
        self.assertEqual(
            readiness.UPSTREAM_MAKE_ALL_TIMEOUT_SECONDS,
            readiness.UPSTREAM_MAKE_ALL_AUDITED_BOUND_SECONDS
            + readiness.UPSTREAM_MAKE_ALL_MARGIN_SECONDS,
        )
        self.assertGreater(
            readiness.UPSTREAM_MAKE_ALL_TIMEOUT_SECONDS,
            readiness.OFFLINE_DIALYZER_REPLAY_TIMEOUT_SECONDS,
        )
        self.assertGreaterEqual(
            readiness.GATE_TIMEOUT_SECONDS["no_model_live_discovery"],
            readiness.NO_MODEL_LIVE_DISCOVERY_AUDITED_BOUND_SECONDS
            + readiness.NO_MODEL_LIVE_DISCOVERY_MARGIN_SECONDS,
        )
        self.assertEqual(readiness.STATIC_BASIS_GIT_COMMAND_COUNT, 17)
        self.assertEqual(readiness.LIVE_PROBE_PREPOST_GIT_COMMAND_COUNT, 7)
        self.assertEqual(readiness.STATIC_BASIS_BOUND_SECONDS, 525.0)
        self.assertEqual(readiness.LIVE_PROBE_NESTED_BOUND_SECONDS, 4_080.0)
        self.assertEqual(
            readiness.NO_MODEL_LIVE_DISCOVERY_MINIMUM_BOUND_SECONDS, 5_130.0
        )
        self.assertGreaterEqual(
            readiness.NO_MODEL_LIVE_DISCOVERY_AUDITED_BOUND_SECONDS,
            readiness.NO_MODEL_LIVE_DISCOVERY_MINIMUM_BOUND_SECONDS,
        )
        standalone_environment = dict(os.environ)
        standalone_environment.pop("SYMPHONY_READINESS_OUTER_SANDBOX", None)
        standalone_environment.update(
            {
                "MIX_HOME": "/ambient/mix-home",
                "MIX_ARCHIVES": "/ambient/mix-archives",
                "MIX_REBAR3": "/ambient/rebar3",
            }
        )
        with mock.patch.dict(os.environ, standalone_environment, clear=True):
            self.assertEqual(
                readiness._outer_gate_private_mix_environment(Path.cwd()), {}
            )
        with (
            mock.patch.dict(
                os.environ,
                {"SYMPHONY_READINESS_OUTER_SANDBOX": "1"},
                clear=True,
            ),
            self.assertRaisesRegex(readiness.ReadinessError, "workspace"),
        ):
            readiness._outer_gate_private_mix_environment(Path("/tmp"))

        with (
            mock.patch.object(readiness.os, "getuid", return_value=0),
            self.assertRaisesRegex(readiness.ReadinessError, "non-root"),
        ):
            readiness._capture_gate_identity()
        real_uid = os.getuid()
        real_gid = os.getgid()
        with (
            mock.patch.object(
                readiness.os,
                "getresuid",
                return_value=(real_uid, 0, real_uid),
            ),
            mock.patch.object(
                readiness.os,
                "getresgid",
                return_value=(real_gid, real_gid, real_gid),
            ),
            self.assertRaisesRegex(readiness.ReadinessError, "non-root"),
        ):
            readiness._capture_gate_identity()
        with (
            mock.patch.object(
                readiness,
                "_read_process_status",
                return_value=(
                    f"Uid:\t{real_uid}\t{real_uid}\t{real_uid}\t0\n"
                    f"Gid:\t{real_gid}\t{real_gid}\t{real_gid}\t{real_gid}\n"
                    "CapInh:\t0000000000000000\n"
                    "CapPrm:\t0000000000000000\n"
                    "CapEff:\t0000000000000000\n"
                    "CapAmb:\t0000000000000000\n"
                ).encode("ascii"),
            ),
            self.assertRaisesRegex(readiness.ReadinessError, "filesystem identities"),
        ):
            readiness._capture_gate_identity()
        with (
            mock.patch.object(
                readiness,
                "_read_process_status",
                return_value=(
                    f"Uid:\t{real_uid}\t{real_uid}\t{real_uid}\t{real_uid}\n"
                    f"Gid:\t{real_gid}\t{real_gid}\t{real_gid}\t{real_gid}\n"
                    "CapInh:\t0000000000000000\n"
                    "CapPrm:\t0000000000000000\n"
                    "CapEff:\t0000000000000001\n"
                    "CapAmb:\t0000000000000000\n"
                ).encode("ascii"),
            ),
            self.assertRaisesRegex(readiness.ReadinessError, "zero raiseable"),
        ):
            readiness._capture_gate_identity()

        with tempfile.TemporaryDirectory() as hostile_tmp:
            with mock.patch.dict(os.environ, {"TMPDIR": hostile_tmp}):
                with readiness._gate_temporary_directory() as selected_tmp:
                    self.assertEqual(
                        Path(selected_tmp).parent, readiness.GATE_TEMP_PARENT
                    )
                    self.assertNotIn(Path(hostile_tmp), Path(selected_tmp).parents)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            canonical = root / "canonical-codex"
            alternate = root / "alternate-codex"
            canonical.write_text("canonical\n", encoding="utf-8")
            alternate.write_text("alternate\n", encoding="utf-8")
            with mock.patch.object(
                readiness.shutil,
                "which",
                side_effect=lambda name: {
                    "codex": str(canonical),
                    "selected": str(canonical),
                    "alternate": str(alternate),
                }.get(name),
            ):
                self.assertEqual(
                    readiness._require_public_launcher_selector(
                        "selected", "codex", "Codex"
                    ),
                    canonical,
                )
                with self.assertRaisesRegex(
                    readiness.ReadinessError, "canonical public launcher"
                ):
                    readiness._require_public_launcher_selector(
                        "alternate", "codex", "Codex"
                    )

            git_launcher = root / "git"
            python_launcher = root / "python3"
            git_launcher.write_text("git-one\n", encoding="utf-8")
            python_launcher.write_text("python\n", encoding="utf-8")
            with mock.patch.object(
                readiness.shutil,
                "which",
                side_effect=lambda name: {
                    "git": str(git_launcher),
                    "python3": str(python_launcher),
                }.get(name),
            ):
                first = readiness._resolved_tool_fingerprints((("python3",),))
                self.assertIn("git", first)
                git_launcher.write_text("git-two\n", encoding="utf-8")
                self.assertNotEqual(
                    readiness._resolved_tool_fingerprints((("python3",),)), first
                )

        # The readiness harness itself already runs inside one exact outer
        # sandbox gate. Retain the pure timeout, identity, selector, and marker
        # assertions above, then validate that outer context before any
        # host-only repository or Mix-tool setup can run. The top-level run
        # below remains the clean-index integration proof for standalone use.
        if readiness._outer_gate_private_mix_environment(readiness.REPO_ROOT):
            return

        with without_outer_git_worktree(), tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "repo"
            root.mkdir()
            subprocess.run(["git", "init", "--quiet"], cwd=root, check=True)
            (root / "STUDIO_SPEC.md").write_text("sandbox fixture\n", encoding="utf-8")
            (root / "studio_readiness.py").write_bytes(
                Path(readiness.__file__).read_bytes()
            )
            (root / "elixir").mkdir()
            (root / "elixir/mise.toml").write_text(
                '[tools]\nerlang = "28"\nelixir = "1.19.5-otp-28"\n',
                encoding="utf-8",
            )
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(
                [
                    "git",
                    "-c",
                    "user.name=Sandbox Test",
                    "-c",
                    "user.email=sandbox@example.invalid",
                    "commit",
                    "--quiet",
                    "-m",
                    "fixture",
                ],
                cwd=root,
                check=True,
            )
            index_tree = readiness._git_text(root, ["write-tree"])
            metadata = readiness._git_metadata_fingerprint(root)
            snapshot = Path(temporary) / "snapshot"
            snapshot.mkdir(mode=0o700)
            readiness._run_git(
                root,
                ["checkout-index", "--all", "--force", f"--prefix={snapshot}{os.sep}"],
            )
            codex_path = readiness._require_public_launcher_selector(
                "codex", "codex", "Codex"
            )
            sandbox = readiness._prepare_gate_sandbox(
                root,
                snapshot,
                Path(temporary),
                index_tree,
                codex_path,
                readiness._parse_index_entries(root),
            )
            environment = readiness._safe_gate_environment(sandbox)
            for sensitive in (
                "AWS_SECRET_ACCESS_KEY",
                "CODEX_HOME",
                "LINEAR_API_KEY",
                "SSH_AUTH_SOCK",
            ):
                self.assertNotIn(sensitive, environment)
            self.assertNotEqual(environment["HOME"], os.environ.get("HOME"))
            self.assertNotIn("GIT_DIR", environment)
            self.assertNotIn("GIT_WORK_TREE", environment)
            self.assertEqual(
                environment["SYMPHONY_READINESS_OUTER_SANDBOX"], "1"
            )
            self.assertEqual(
                environment["HEX_HOME"], f"{readiness.SANDBOX_ROOT}/hex-runtime"
            )
            self.assertEqual(
                readiness._safe_gate_environment(
                    sandbox, use_bootstrap_hex=True
                )["HEX_HOME"],
                f"{readiness.SANDBOX_ROOT}/hex-home",
            )
            self.assertEqual(
                environment["SYMPHONY_FIXTURE_LOG_FILE"],
                f"{readiness.SANDBOX_ROOT}/tmp/symphony.log",
            )
            self.assertEqual(
                environment["SYMPHONY_CODEX_CONFORMANCE_BIN"],
                f"{readiness.SANDBOX_ROOT}/tools/bin/codex",
            )
            self.assertEqual(
                environment["MIX_HOME"],
                f"{readiness.SANDBOX_ROOT}/mix-home",
            )
            self.assertEqual(
                environment["MIX_ARCHIVES"],
                f"{readiness.SANDBOX_ROOT}/mix-home/archives",
            )
            self.assertEqual(
                environment["MIX_REBAR3"],
                f"{readiness.SANDBOX_ROOT}/mix-home/elixir/"
                f"{sandbox.mix_rebar_version}/rebar3",
            )
            self.assertTrue(
                sandbox.mix_home.is_relative_to(sandbox.temporary_root)
            )
            self.assertEqual(
                readiness._inspect_private_mix_tools(
                    sandbox.mix_tools, sandbox.mix_rebar_version
                ),
                sandbox.mix_tools_fingerprint,
            )
            self.assertFalse(
                any(
                    path.name.endswith((".plt", ".plt.hash"))
                    for path in sandbox.mix_tools.rglob("*")
                )
            )
            readiness._inspect_private_plt_outputs(
                sandbox, require_empty=True
            )
            self.assertEqual(environment["COLUMNS"], "80")
            self.assertEqual(
                environment["SYMPHONY_SANDBOX_UID"], str(sandbox.sandbox_uid)
            )
            self.assertEqual(
                environment["SYMPHONY_SANDBOX_GID"], str(sandbox.sandbox_gid)
            )
            with (
                tempfile.TemporaryDirectory(dir="/var/tmp") as host_var_tmp,
                tempfile.TemporaryDirectory(dir="/dev/shm") as host_dev_shm,
            ):
                host_var_tmp_sentinel = Path(host_var_tmp) / "host-sentinel"
                host_dev_shm_sentinel = Path(host_dev_shm) / "host-sentinel"
                host_var_tmp_sentinel.write_text(
                    "must be masked\n", encoding="utf-8"
                )
                host_dev_shm_sentinel.write_text(
                    "must be masked\n", encoding="utf-8"
                )
                readiness._run_gate_sandbox_canary(root, sandbox, metadata)
                self.assertEqual(
                    host_var_tmp_sentinel.read_text(encoding="utf-8"),
                    "must be masked\n",
                )
                self.assertEqual(
                    host_dev_shm_sentinel.read_text(encoding="utf-8"),
                    "must be masked\n",
                )
            self.assertEqual(readiness._git_metadata_fingerprint(root), metadata)
            self.assertEqual(readiness._git_text(root, ["write-tree"]), index_tree)
            outer_mix_script = (
                "import json; from pathlib import Path; "
                "import studio_readiness as r; "
                "print(json.dumps(r._outer_gate_private_mix_environment(Path.cwd()), "
                "sort_keys=True))"
            )
            returncode, outer_mix_stdout, outer_mix_stderr = (
                readiness.run_bounded_command(
                    readiness._sandbox_command(
                        sandbox, ("python3", "-c", outer_mix_script)
                    ),
                    cwd=sandbox.temporary_root,
                    environment=environment,
                    timeout_seconds=30.0,
                    max_output_bytes=64 * 1024,
                )
            )
            self.assertEqual(
                returncode,
                0,
                outer_mix_stderr.decode("utf-8", errors="replace"),
            )
            self.assertEqual(outer_mix_stderr, b"")
            self.assertEqual(
                json.loads(outer_mix_stdout),
                {
                    "MIX_ARCHIVES": f"{readiness.SANDBOX_ROOT}/mix-home/archives",
                    "MIX_HOME": f"{readiness.SANDBOX_ROOT}/mix-home",
                    "MIX_REBAR3": environment["MIX_REBAR3"],
                },
            )
            tracked_source = root / "STUDIO_SPEC.md"
            tracked_payload = tracked_source.read_bytes()
            os.utime(tracked_source, None)
            subprocess.run(
                ["git", "status", "--short"],
                cwd=root,
                check=True,
                stdout=subprocess.DEVNULL,
            )
            self.assertEqual(
                readiness._git_metadata_fingerprint(root),
                metadata,
                "a raw index stat-cache refresh is not a staged semantic mutation",
            )
            tracked_source.write_bytes(tracked_payload + b"staged mutation\n")
            subprocess.run(["git", "add", "STUDIO_SPEC.md"], cwd=root, check=True)
            self.assertNotEqual(readiness._git_metadata_fingerprint(root), metadata)
            tracked_source.write_bytes(tracked_payload)
            subprocess.run(["git", "add", "STUDIO_SPEC.md"], cwd=root, check=True)
            self.assertEqual(readiness._git_metadata_fingerprint(root), metadata)
            self.assertEqual(readiness._git_text(root, ["write-tree"]), index_tree)
            returncode, stdout, stderr = readiness.run_bounded_command(
                readiness._sandbox_command(
                    sandbox,
                    (
                        "python3",
                        "-c",
                        "import sys; from pathlib import Path; "
                        "sys.path.insert(0, '/run/symphony-readiness/workspace'); "
                        "import studio_readiness as r; "
                        "print(r._git_text(Path('/run/symphony-readiness/workspace'), ['write-tree']))",
                    ),
                    writable_git=True,
                ),
                cwd=sandbox.temporary_root,
                environment=environment,
                timeout_seconds=30.0,
                max_output_bytes=64 * 1024,
            )
            self.assertEqual(
                returncode,
                0,
                stdout.decode("utf-8", errors="replace")
                + stderr.decode("utf-8", errors="replace"),
            )
            self.assertEqual(stdout.decode().strip(), index_tree)
            self.assertEqual(stderr, b"")
            for command in (
                ("mise", "exec", "-C", "elixir", "--", "elixir", "--version"),
                ("codex", "--version"),
                (environment["SYMPHONY_CODEX_CONFORMANCE_BIN"], "--version"),
            ):
                returncode, command_stdout, command_stderr = readiness.run_bounded_command(
                    readiness._sandbox_command(sandbox, command),
                    cwd=sandbox.temporary_root,
                    environment=environment,
                    timeout_seconds=30.0,
                    max_output_bytes=256 * 1024,
                )
                self.assertEqual(
                    returncode,
                    0,
                    (command, command_stderr.decode("utf-8", errors="replace")),
                )
                self.assertEqual(command_stderr, b"")
                if command[0] == environment["SYMPHONY_CODEX_CONFORMANCE_BIN"]:
                    self.assertEqual(command_stdout.strip(), b"codex-cli 0.144.3")

            nested_git_script = r"""
from pathlib import Path
import shutil
import subprocess

nested = Path("/run/symphony-readiness/tmp/nested-git")
subprocess.run(["git", "init", "--quiet", nested], check=True)
(nested / "tracked.txt").write_text("nested\n", encoding="utf-8")
subprocess.run(["git", "-C", nested, "add", "tracked.txt"], check=True)
subprocess.run(["git", "-C", nested, "write-tree"], check=True,
               stdout=subprocess.DEVNULL)
if subprocess.check_output(
    ["git", "-C", nested, "rev-parse", "--git-dir"], text=True
).strip() != ".git":
    raise SystemExit("nested Git repository was redirected")
if subprocess.check_output(
    ["git", "rev-parse", "--git-dir"], text=True
).strip() != ".git":
    raise SystemExit("workspace private Git repository was not discovered")
shutil.rmtree(nested)
print("SYMPHONY_STUDIO_NESTED_GIT=pass")
"""
            returncode, stdout, stderr = readiness.run_bounded_command(
                readiness._sandbox_command(
                    sandbox, ("python3", "-c", nested_git_script)
                ),
                cwd=sandbox.temporary_root,
                environment=environment,
                timeout_seconds=30.0,
                max_output_bytes=64 * 1024,
            )
            self.assertEqual(returncode, 0, stderr.decode(errors="replace"))
            self.assertEqual(stdout, b"SYMPHONY_STUDIO_NESTED_GIT=pass\n")
            self.assertEqual(stderr, b"")

            package_denial_script = r"""
import errno
from pathlib import Path

root = Path("/run/symphony-readiness/hex-runtime")
root_probe = root / "runtime-write-probe"
root_probe.write_text("derived\n", encoding="utf-8")
root_probe.unlink()
package_probe = root / "packages/package-write-probe"
try:
    package_probe.write_text("mutation\n", encoding="utf-8")
except OSError as error:
    if error.errno not in {errno.EACCES, errno.EPERM, errno.EROFS}:
        raise
else:
    package_probe.unlink(missing_ok=True)
    raise SystemExit("immutable Hex package mount was writable")
print("SYMPHONY_STUDIO_HEX_PACKAGE_ISOLATION=pass")
"""
            returncode, stdout, stderr = readiness.run_bounded_command(
                readiness._sandbox_command(
                    sandbox,
                    ("python3", "-c", package_denial_script),
                    writable_hex_runtime=True,
                ),
                cwd=sandbox.temporary_root,
                environment=environment,
                timeout_seconds=30.0,
                max_output_bytes=64 * 1024,
            )
            self.assertEqual(returncode, 0, stderr.decode(errors="replace"))
            self.assertEqual(
                stdout, b"SYMPHONY_STUDIO_HEX_PACKAGE_ISOLATION=pass\n"
            )
            self.assertEqual(stderr, b"")
            readiness._inspect_private_hex_runtime(sandbox, require_cache=False)

            def has_mount(
                arguments: tuple[str, ...],
                operation: str,
                source: Path,
                target: str,
            ) -> bool:
                return any(
                    arguments[index : index + 3]
                    == (operation, str(source), target)
                    for index in range(len(arguments) - 2)
                )

            def mount_index(
                arguments: tuple[str, ...],
                operation: str,
                source: Path,
                target: str,
            ) -> int:
                for index in range(len(arguments) - 2):
                    if arguments[index : index + 3] == (
                        operation,
                        str(source),
                        target,
                    ):
                        return index
                self.fail(f"missing mount: {operation} {source} {target}")

            def two_arg_index(arguments: tuple[str, ...], operation: str, target: str) -> int:
                for index in range(len(arguments) - 1):
                    if arguments[index : index + 2] == (operation, target):
                        return index
                self.fail(f"missing operation: {operation} {target}")

            exact_arguments = readiness._sandbox_command(sandbox, ("true",))
            canary_git_arguments = readiness._sandbox_command(
                sandbox, ("true",), writable_git=True
            )
            self.assertEqual(
                exact_arguments[exact_arguments.index("--uid") + 1],
                str(sandbox.sandbox_uid),
            )
            self.assertEqual(
                exact_arguments[exact_arguments.index("--gid") + 1],
                str(sandbox.sandbox_gid),
            )
            self.assertNotIn("--dev-bind", exact_arguments)
            private_dev_index = two_arg_index(exact_arguments, "--dev", "/dev")
            self.assertGreater(
                two_arg_index(exact_arguments, "--tmpfs", "/dev/shm"),
                private_dev_index,
            )
            with (
                mock.patch.object(readiness.os, "getuid", return_value=0),
                mock.patch.object(readiness.os, "getgid", return_value=0),
            ):
                drift_arguments = readiness._sandbox_command(sandbox, ("true",))
            self.assertEqual(
                drift_arguments[drift_arguments.index("--uid") + 1],
                str(sandbox.sandbox_uid),
            )
            self.assertEqual(
                drift_arguments[drift_arguments.index("--gid") + 1],
                str(sandbox.sandbox_gid),
            )
            self.assertTrue(
                has_mount(
                    exact_arguments,
                    "--ro-bind",
                    sandbox.git_dir,
                    f"{readiness.SANDBOX_WORKSPACE}/.git",
                )
            )
            self.assertTrue(
                has_mount(
                    canary_git_arguments,
                    "--bind",
                    sandbox.git_dir,
                    f"{readiness.SANDBOX_WORKSPACE}/.git",
                )
            )
            setup_arguments = readiness._sandbox_command(
                sandbox,
                ("true",),
                writable_erlexec=True,
                writable_dependencies=True,
                writable_setup_elixir=True,
            )
            make_arguments = readiness._sandbox_command(
                sandbox,
                ("true",),
                writable_erlexec=True,
                writable_hex_runtime=True,
                writable_mix_home=True,
                writable_project_outputs=True,
            )
            wrapped_mix_arguments = readiness._sandbox_command(
                sandbox, ("true",), writable_erlexec=True
            )
            self.assertTrue(
                has_mount(
                    exact_arguments,
                    "--ro-bind",
                    sandbox.erlexec_source,
                    f"{readiness.SANDBOX_ROOT}/erlexec-source",
                )
            )
            self.assertTrue(
                has_mount(
                    exact_arguments,
                    "--ro-bind",
                    sandbox.mix_home,
                    f"{readiness.SANDBOX_ROOT}/mix-home",
                )
            )
            self.assertTrue(
                has_mount(
                    make_arguments,
                    "--bind",
                    sandbox.mix_home,
                    f"{readiness.SANDBOX_ROOT}/mix-home",
                )
            )
            for relative in ("archives", "elixir"):
                target = f"{readiness.SANDBOX_ROOT}/mix-home/{relative}"
                self.assertTrue(
                    has_mount(
                        make_arguments,
                        "--ro-bind",
                        sandbox.mix_tools / relative,
                        target,
                    )
                )
                self.assertGreater(
                    mount_index(
                        make_arguments,
                        "--ro-bind",
                        sandbox.mix_tools / relative,
                        target,
                    ),
                    mount_index(
                        make_arguments,
                        "--bind",
                        sandbox.mix_home,
                        f"{readiness.SANDBOX_ROOT}/mix-home",
                    ),
                )
            host_mix_alias = (
                f"{readiness.SANDBOX_ROOT}/tools/share/mise/"
                f"{sandbox.host_mix_home.relative_to(sandbox.host_mise_data).as_posix()}"
            )
            self.assertGreater(
                two_arg_index(make_arguments, "--tmpfs", host_mix_alias),
                mount_index(
                    make_arguments,
                    "--ro-bind",
                    sandbox.host_mise_data,
                    f"{readiness.SANDBOX_ROOT}/tools/share/mise",
                ),
            )
            self.assertGreater(
                two_arg_index(
                    make_arguments, "--tmpfs", str(sandbox.host_mix_home)
                ),
                mount_index(
                    make_arguments,
                    "--ro-bind",
                    sandbox.host_mise_data,
                    str(sandbox.host_mise_data),
                ),
            )
            self.assertTrue(
                has_mount(
                    exact_arguments,
                    "--ro-bind",
                    sandbox.mix_deps,
                    f"{readiness.SANDBOX_ROOT}/mix-deps",
                )
            )
            self.assertTrue(
                has_mount(
                    exact_arguments,
                    "--ro-bind",
                    sandbox.hex_runtime,
                    f"{readiness.SANDBOX_ROOT}/hex-runtime",
                )
            )
            self.assertTrue(
                has_mount(
                    exact_arguments,
                    "--ro-bind",
                    sandbox.hex_home / "packages",
                    f"{readiness.SANDBOX_ROOT}/hex-runtime/packages",
                )
            )
            self.assertTrue(
                has_mount(
                    setup_arguments,
                    "--bind",
                    sandbox.erlexec_source,
                    f"{readiness.SANDBOX_ROOT}/erlexec-source",
                )
            )
            self.assertTrue(
                has_mount(
                    setup_arguments,
                    "--bind",
                    sandbox.mix_deps,
                    f"{readiness.SANDBOX_ROOT}/mix-deps",
                )
            )
            self.assertTrue(
                has_mount(
                    make_arguments,
                    "--bind",
                    sandbox.erlexec_source,
                    f"{readiness.SANDBOX_ROOT}/erlexec-source",
                )
            )
            self.assertTrue(
                has_mount(
                    wrapped_mix_arguments,
                    "--bind",
                    sandbox.erlexec_source,
                    f"{readiness.SANDBOX_ROOT}/erlexec-source",
                )
            )
            self.assertTrue(
                has_mount(
                    make_arguments,
                    "--bind",
                    sandbox.coverage_output,
                    f"{readiness.SANDBOX_WORKSPACE}/elixir/cover",
                )
            )
            self.assertTrue(
                has_mount(
                    make_arguments,
                    "--bind",
                    sandbox.escript_output,
                    f"{readiness.SANDBOX_WORKSPACE}/elixir/bin",
                )
            )
            self.assertTrue(
                has_mount(
                    make_arguments,
                    "--ro-bind",
                    sandbox.mix_deps,
                    f"{readiness.SANDBOX_ROOT}/mix-deps",
                )
            )
            self.assertTrue(
                has_mount(
                    make_arguments,
                    "--bind",
                    sandbox.hex_runtime,
                    f"{readiness.SANDBOX_ROOT}/hex-runtime",
                )
            )
            self.assertTrue(
                has_mount(
                    make_arguments,
                    "--ro-bind",
                    sandbox.hex_home / "packages",
                    f"{readiness.SANDBOX_ROOT}/hex-runtime/packages",
                )
            )
            self.assertGreater(
                mount_index(
                    make_arguments,
                    "--ro-bind",
                    sandbox.hex_home / "packages",
                    f"{readiness.SANDBOX_ROOT}/hex-runtime/packages",
                ),
                mount_index(
                    make_arguments,
                    "--bind",
                    sandbox.hex_runtime,
                    f"{readiness.SANDBOX_ROOT}/hex-runtime",
                ),
            )
            self.assertEqual(
                readiness.HEX_RUNTIME_WRITABLE_GATE_IDS,
                frozenset({"upstream_make_all"}),
            )
            self.assertEqual(
                readiness.MIX_HOME_WRITABLE_GATE_IDS,
                frozenset({"upstream_make_all"}),
            )
            self.assertNotIn(
                "readiness_harness", readiness.ERLEXEC_WRITABLE_GATE_IDS
            )
            self.assertIn(
                "source_bound_fixture_replay",
                readiness.ERLEXEC_WRITABLE_GATE_IDS,
            )
            self.assertIn(
                "linear_live_discovery", readiness.ERLEXEC_WRITABLE_GATE_IDS
            )

            mix_tool_extra = sandbox.mix_tools / "unexpected"
            mix_tool_extra.symlink_to("archives")
            with self.assertRaisesRegex(readiness.ReadinessError, "symlink"):
                readiness._inspect_private_mix_tools(
                    sandbox.mix_tools, sandbox.mix_rebar_version
                )
            mix_tool_extra.unlink()
            os.mkfifo(mix_tool_extra, 0o600)
            with self.assertRaisesRegex(readiness.ReadinessError, "special file"):
                readiness._inspect_private_mix_tools(
                    sandbox.mix_tools, sandbox.mix_rebar_version
                )
            mix_tool_extra.unlink()
            private_rebar = (
                sandbox.mix_tools
                / "elixir"
                / sandbox.mix_rebar_version
                / "rebar3"
            )
            os.chmod(private_rebar, 0o600)
            with self.assertRaisesRegex(readiness.ReadinessError, "metadata"):
                readiness._inspect_private_mix_tools(
                    sandbox.mix_tools, sandbox.mix_rebar_version
                )
            os.chmod(private_rebar, 0o700)
            with (
                mock.patch.object(readiness, "MAX_MIX_TOOL_INPUT_ENTRIES", 0),
                self.assertRaisesRegex(readiness.ReadinessError, "too many entries"),
            ):
                readiness._inspect_private_mix_tools(
                    sandbox.mix_tools, sandbox.mix_rebar_version
                )
            with (
                mock.patch.object(readiness, "MAX_MIX_TOOL_INPUT_BYTES", 0),
                self.assertRaisesRegex(readiness.ReadinessError, "byte bound"),
            ):
                readiness._inspect_private_mix_tools(
                    sandbox.mix_tools, sandbox.mix_rebar_version
                )
            self.assertEqual(
                readiness._inspect_private_mix_tools(
                    sandbox.mix_tools, sandbox.mix_rebar_version
                ),
                sandbox.mix_tools_fingerprint,
            )

            fake_plt_paths = (
                sandbox.mix_home / "dialyxir_erlang-28.5.plt",
                sandbox.mix_home
                / "dialyxir_erlang-28.5_elixir-1.19.5.plt",
                sandbox.mix_build
                / "dev/dialyxir_erlang-28.5_elixir-1.19.5_deps-dev.plt",
                sandbox.mix_build
                / "dev/dialyxir_erlang-28.5_elixir-1.19.5_deps-dev.plt.hash",
            )
            for index, path in enumerate(fake_plt_paths):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(f"fresh-private-plt-{index}\n".encode("ascii"))
                os.chmod(path, 0o600)
            fake_plt_fingerprint = readiness._inspect_private_plt_outputs(
                sandbox, require_complete=True
            )
            self.assertEqual(
                fake_plt_fingerprint,
                readiness._inspect_private_plt_outputs(
                    sandbox, require_complete=True
                ),
            )
            with self.assertRaisesRegex(
                readiness.ReadinessError, "were not fresh"
            ):
                readiness._inspect_private_plt_outputs(
                    sandbox, require_empty=True
                )
            os.chmod(fake_plt_paths[0], 0o644)
            with self.assertRaisesRegex(readiness.ReadinessError, "metadata"):
                readiness._inspect_private_plt_outputs(sandbox)
            os.chmod(fake_plt_paths[0], 0o600)

            original_lstat = Path.lstat

            def wrong_owner_lstat(path: Path):
                metadata = original_lstat(path)
                if path != fake_plt_paths[0]:
                    return metadata
                changed = mock.Mock()
                for attribute in (
                    "st_dev",
                    "st_gid",
                    "st_ino",
                    "st_mode",
                    "st_mtime_ns",
                    "st_nlink",
                    "st_size",
                ):
                    setattr(changed, attribute, getattr(metadata, attribute))
                changed.st_uid = metadata.st_uid + 1
                return changed

            with (
                mock.patch.object(Path, "lstat", autospec=True, side_effect=wrong_owner_lstat),
                self.assertRaisesRegex(readiness.ReadinessError, "metadata"),
            ):
                readiness._inspect_private_plt_outputs(sandbox)

            hash_payload = fake_plt_paths[3].read_bytes()
            fake_plt_paths[3].unlink()
            with self.assertRaisesRegex(readiness.ReadinessError, "incomplete"):
                readiness._inspect_private_plt_outputs(
                    sandbox, require_complete=True
                )
            fake_plt_paths[3].write_bytes(hash_payload)
            os.chmod(fake_plt_paths[3], 0o600)

            mismatched_project = (
                sandbox.mix_build
                / "dev/dialyxir_erlang-28.6_elixir-1.19.5_deps-dev.plt"
            )
            mismatched_hash = Path(f"{mismatched_project}.hash")
            fake_plt_paths[2].rename(mismatched_project)
            fake_plt_paths[3].rename(mismatched_hash)
            with self.assertRaisesRegex(readiness.ReadinessError, "inconsistent"):
                readiness._inspect_private_plt_outputs(
                    sandbox, require_complete=True
                )
            mismatched_project.rename(fake_plt_paths[2])
            mismatched_hash.rename(fake_plt_paths[3])

            unexpected_plt = sandbox.mix_build / "dev/unexpected.plt"
            unexpected_plt.write_bytes(b"unexpected\n")
            os.chmod(unexpected_plt, 0o600)
            with self.assertRaisesRegex(readiness.ReadinessError, "unexpected PLT"):
                readiness._inspect_private_plt_outputs(sandbox)
            unexpected_plt.unlink()

            fake_plt_paths[-1].write_bytes(
                str(sandbox.host_home).encode("utf-8") + b"/host.plt\n"
            )
            with self.assertRaisesRegex(
                readiness.ReadinessError, "host-absolute provenance"
            ):
                readiness._inspect_private_plt_outputs(
                    sandbox, require_complete=True
                )
            fake_plt_paths[-1].write_bytes(b"fresh-private-plt-3\n")
            os.chmod(fake_plt_paths[-1], 0o600)
            project_plt_payload = fake_plt_paths[2].read_bytes()
            fake_plt_paths[2].unlink()
            fake_plt_paths[2].symlink_to(fake_plt_paths[3].name)
            with self.assertRaisesRegex(readiness.ReadinessError, "symlink"):
                readiness._inspect_private_plt_outputs(sandbox)
            fake_plt_paths[2].unlink()
            os.mkfifo(fake_plt_paths[2], 0o600)
            with self.assertRaisesRegex(readiness.ReadinessError, "special file"):
                readiness._inspect_private_plt_outputs(sandbox)
            fake_plt_paths[2].unlink()
            fake_plt_paths[2].write_bytes(project_plt_payload)
            os.chmod(fake_plt_paths[2], 0o600)
            with (
                mock.patch.object(readiness, "MAX_PRIVATE_PLT_BYTES", 0),
                self.assertRaisesRegex(readiness.ReadinessError, "byte bound"),
            ):
                readiness._inspect_private_plt_outputs(sandbox)
            with (
                mock.patch.object(readiness, "MAX_PRIVATE_PLT_ENTRIES", 0),
                self.assertRaisesRegex(readiness.ReadinessError, "too many entries"),
            ):
                readiness._inspect_private_plt_outputs(sandbox)
            for path in fake_plt_paths:
                path.unlink()
            (sandbox.mix_build / "dev").rmdir()
            readiness._inspect_private_plt_outputs(
                sandbox, require_empty=True
            )

            setup_extra = sandbox.setup_elixir / "unexpected"
            setup_extra.write_text("unexpected\n", encoding="utf-8")
            with self.assertRaisesRegex(readiness.ReadinessError, "unexpected file"):
                readiness._inspect_private_setup_elixir(
                    sandbox.setup_elixir, sandbox.setup_elixir_tracked
                )
            setup_extra.unlink()
            setup_extra.symlink_to("mise.toml")
            with self.assertRaisesRegex(readiness.ReadinessError, "symlink"):
                readiness._inspect_private_setup_elixir(
                    sandbox.setup_elixir, sandbox.setup_elixir_tracked
                )
            setup_extra.unlink()
            tracked_setup_file = sandbox.setup_elixir / "mise.toml"
            os.chmod(tracked_setup_file, 0o600)
            with self.assertRaisesRegex(readiness.ReadinessError, "tracked source"):
                readiness._inspect_private_setup_elixir(
                    sandbox.setup_elixir, sandbox.setup_elixir_tracked
                )
            os.chmod(tracked_setup_file, 0o644)

            with self.assertRaisesRegex(readiness.ReadinessError, "incomplete"):
                readiness._inspect_gate_generated_outputs(
                    sandbox, require_complete=True
                )
            cover_file = sandbox.coverage_output / "Fixture.html"
            cover_file.write_text("coverage\n", encoding="utf-8")
            os.chmod(cover_file, 0o600)
            escript_file = sandbox.escript_output / "symphony"
            escript_file.write_bytes(b"escript\n")
            os.chmod(escript_file, 0o700)
            readiness._inspect_gate_generated_outputs(
                sandbox, require_complete=True
            )
            os.chmod(cover_file, 0o644)
            with self.assertRaisesRegex(readiness.ReadinessError, "mode"):
                readiness._inspect_gate_generated_outputs(sandbox)
            os.chmod(cover_file, 0o600)
            unexpected_output = sandbox.escript_output / "unexpected"
            unexpected_output.write_text("unexpected\n", encoding="utf-8")
            with self.assertRaisesRegex(readiness.ReadinessError, "unexpected"):
                readiness._inspect_gate_generated_outputs(sandbox)
            unexpected_output.unlink()
            cover_file.unlink()
            escript_file.unlink()

            first_head = readiness._git_text(root, ["rev-parse", "HEAD"])
            subprocess.run(
                [
                    "git",
                    "-c",
                    "user.name=Sandbox Test",
                    "-c",
                    "user.email=sandbox@example.invalid",
                    "commit",
                    "--quiet",
                    "--allow-empty",
                    "-m",
                    "same-tree second commit",
                ],
                cwd=root,
                check=True,
            )
            second_head = readiness._git_text(root, ["rev-parse", "HEAD"])
            subprocess.run(
                ["git", "checkout", "--quiet", "--detach", first_head],
                cwd=root,
                check=True,
            )
            detached_first = readiness._git_metadata_fingerprint(root)
            subprocess.run(
                ["git", "checkout", "--quiet", "--detach", second_head],
                cwd=root,
                check=True,
            )
            self.assertNotEqual(
                readiness._git_metadata_fingerprint(root), detached_first
            )

        repo_root = Path(readiness.__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(
            prefix="symphony-readiness-clean-setup-"
        ) as clean_temporary:
            clean_root = Path(clean_temporary)
            clean_snapshot = clean_root / "snapshot"
            clean_snapshot.mkdir(mode=0o700)
            clean_index_tree = readiness._git_text(repo_root, ["write-tree"])
            clean_index_entries = readiness._parse_index_entries(repo_root)
            clean_metadata = readiness._git_metadata_fingerprint(repo_root)
            readiness._run_git(
                repo_root,
                [
                    "checkout-index",
                    "--all",
                    "--force",
                    f"--prefix={clean_snapshot}{os.sep}",
                ],
            )
            clean_sandbox = readiness._prepare_gate_sandbox(
                repo_root,
                clean_snapshot,
                clean_root,
                clean_index_tree,
                readiness._require_public_launcher_selector(
                    "codex", "codex", "Codex"
                ),
                clean_index_entries,
            )
            self.assertEqual(
                [path.name for path in clean_sandbox.hex_home.iterdir()],
                ["packages"],
            )
            self.assertEqual(
                [path.name for path in clean_sandbox.hex_runtime.iterdir()],
                ["packages"],
            )
            self.assertEqual(list(clean_sandbox.mix_deps.iterdir()), [])
            self.assertEqual(
                sorted(path.name for path in clean_sandbox.mix_home.iterdir()),
                ["archives", "elixir"],
            )
            self.assertEqual(
                readiness._inspect_private_mix_tools(
                    clean_sandbox.mix_tools, clean_sandbox.mix_rebar_version
                ),
                clean_sandbox.mix_tools_fingerprint,
            )
            readiness._inspect_private_plt_outputs(
                clean_sandbox, require_empty=True
            )
            clean_environment = readiness._safe_gate_environment(clean_sandbox)
            self.assertNotIn("MIX_ENV", clean_environment)
            self.assertEqual(
                clean_environment["MIX_BUILD_ROOT"],
                f"{readiness.SANDBOX_ROOT}/mix-build",
            )
            self.assertEqual(
                clean_environment["MIX_HOME"],
                f"{readiness.SANDBOX_ROOT}/mix-home",
            )
            self.assertEqual(
                clean_environment["MIX_ARCHIVES"],
                f"{readiness.SANDBOX_ROOT}/mix-home/archives",
            )
            self.assertEqual(
                clean_environment["MIX_REBAR3"],
                f"{readiness.SANDBOX_ROOT}/mix-home/elixir/"
                f"{clean_sandbox.mix_rebar_version}/rebar3",
            )
            readiness._run_gate_sandbox_canary(
                repo_root, clean_sandbox, clean_metadata
            )
            erlexec_fingerprint, dependency_fingerprint, build_fingerprint = (
                readiness._bootstrap_private_gate_dependencies(clean_sandbox)
            )
            hex_runtime_fingerprint = readiness._inspect_private_hex_runtime(
                clean_sandbox
            )
            self.assertEqual(
                readiness._inspect_private_erlexec_source(
                    clean_sandbox.erlexec_source,
                    clean_sandbox.erlexec_tracked,
                    normalize_generated=True,
                    require_compiled=True,
                ),
                erlexec_fingerprint,
            )
            self.assertEqual(
                readiness._private_dependency_fingerprint(clean_sandbox),
                dependency_fingerprint,
            )
            self.assertEqual(
                readiness._private_gate_build_fingerprint(clean_sandbox),
                build_fingerprint,
            )
            readiness._inspect_private_plt_outputs(
                clean_sandbox, require_empty=True
            )

            make_setup_command = (
                "mise",
                "exec",
                "-C",
                "elixir",
                "--",
                "make",
                "setup",
            )
            returncode, setup_stdout, setup_stderr = readiness.run_bounded_command(
                readiness._sandbox_command(
                    clean_sandbox,
                    make_setup_command,
                    writable_erlexec=True,
                    writable_hex_runtime=True,
                ),
                cwd=clean_sandbox.temporary_root,
                environment=readiness._safe_gate_environment(clean_sandbox),
                timeout_seconds=120.0,
                max_output_bytes=readiness.MAX_GATE_OUTPUT_BYTES,
            )
            self.assertEqual(
                returncode,
                0,
                (
                    setup_stdout.decode("utf-8", errors="replace")
                    + setup_stderr.decode("utf-8", errors="replace")
                ),
            )
            readiness._inspect_private_hex_runtime(clean_sandbox)
            self.assertEqual(
                readiness._private_dependency_fingerprint(clean_sandbox),
                dependency_fingerprint,
            )
            self.assertEqual(
                readiness._reset_private_hex_runtime(clean_sandbox),
                hex_runtime_fingerprint,
            )

            hex_extra = clean_sandbox.hex_runtime / "config"
            hex_extra.write_text("unexpected\n", encoding="utf-8")
            with self.assertRaisesRegex(readiness.ReadinessError, "unexpected file"):
                readiness._inspect_private_hex_runtime(clean_sandbox)
            hex_extra.unlink()
            hex_extra.symlink_to("cache.ets")
            with self.assertRaisesRegex(readiness.ReadinessError, "symlink"):
                readiness._inspect_private_hex_runtime(clean_sandbox)
            hex_extra.unlink()
            os.mkfifo(hex_extra, 0o600)
            with self.assertRaisesRegex(readiness.ReadinessError, "unexpected file"):
                readiness._inspect_private_hex_runtime(clean_sandbox)
            hex_extra.unlink()
            hex_cache = clean_sandbox.hex_runtime / "cache.ets"
            with (
                mock.patch.object(readiness, "MAX_HEX_RUNTIME_ENTRIES", 1),
                self.assertRaisesRegex(readiness.ReadinessError, "too many entries"),
            ):
                readiness._inspect_private_hex_runtime(clean_sandbox)
            os.chmod(hex_cache, 0o644)
            with self.assertRaisesRegex(readiness.ReadinessError, "metadata"):
                readiness._inspect_private_hex_runtime(clean_sandbox)
            os.chmod(hex_cache, 0o600)
            with (
                mock.patch.object(readiness, "MAX_HEX_CACHE_BYTES", 0),
                self.assertRaisesRegex(readiness.ReadinessError, "byte bound"),
            ):
                readiness._inspect_private_hex_runtime(clean_sandbox)
            hex_cache.unlink()
            with self.assertRaisesRegex(readiness.ReadinessError, "incomplete"):
                readiness._inspect_private_hex_runtime(clean_sandbox)
            self.assertEqual(
                readiness._reset_private_hex_runtime(clean_sandbox),
                hex_runtime_fingerprint,
            )

            erlexec_extra = clean_sandbox.erlexec_source / "unexpected"
            erlexec_extra.write_text("unexpected\n", encoding="utf-8")
            with self.assertRaisesRegex(readiness.ReadinessError, "unexpected file"):
                readiness._inspect_private_erlexec_source(
                    clean_sandbox.erlexec_source,
                    clean_sandbox.erlexec_tracked,
                    require_compiled=True,
                )
            erlexec_extra.unlink()
            erlexec_extra.symlink_to("README.md")
            with self.assertRaisesRegex(readiness.ReadinessError, "symlink"):
                readiness._inspect_private_erlexec_source(
                    clean_sandbox.erlexec_source,
                    clean_sandbox.erlexec_tracked,
                    require_compiled=True,
                )
            erlexec_extra.unlink()
            generated_object = next(
                clean_sandbox.erlexec_source / relative
                for relative in readiness._expected_erlexec_generated(
                    clean_sandbox.erlexec_tracked
                )
                if relative.endswith(".o")
            )
            os.chmod(generated_object, 0o644)
            with self.assertRaisesRegex(readiness.ReadinessError, "object mode"):
                readiness._inspect_private_erlexec_source(
                    clean_sandbox.erlexec_source,
                    clean_sandbox.erlexec_tracked,
                    require_compiled=True,
                )
            os.chmod(generated_object, 0o600)
            generated_payload = generated_object.read_bytes()
            generated_object.unlink()
            with self.assertRaisesRegex(readiness.ReadinessError, "incomplete"):
                readiness._inspect_private_erlexec_source(
                    clean_sandbox.erlexec_source,
                    clean_sandbox.erlexec_tracked,
                    require_compiled=True,
                )
            generated_object.write_bytes(generated_payload)
            os.chmod(generated_object, 0o600)
            self.assertEqual(
                readiness._inspect_private_erlexec_source(
                    clean_sandbox.erlexec_source,
                    clean_sandbox.erlexec_tracked,
                    normalize_generated=True,
                    require_compiled=True,
                ),
                erlexec_fingerprint,
            )

            dependency_extra = clean_sandbox.mix_deps / "unexpected"
            dependency_extra.symlink_to("bandit")
            with self.assertRaisesRegex(readiness.ReadinessError, "symlink"):
                readiness._private_dependency_fingerprint(clean_sandbox)
            dependency_extra.unlink()
            os.mkfifo(dependency_extra, 0o600)
            with self.assertRaisesRegex(readiness.ReadinessError, "special file"):
                readiness._private_dependency_fingerprint(clean_sandbox)
            dependency_extra.unlink()
            dependency_file = next(
                path
                for path in sorted(clean_sandbox.mix_deps.rglob("*"))
                if path.is_file() and not path.is_symlink()
            )
            dependency_payload = dependency_file.read_bytes()
            dependency_mode = stat.S_IMODE(dependency_file.stat().st_mode)
            dependency_file.write_bytes(dependency_payload + b"mutation")
            self.assertNotEqual(
                readiness._private_dependency_fingerprint(clean_sandbox),
                dependency_fingerprint,
            )
            dependency_file.write_bytes(dependency_payload)
            os.chmod(dependency_file, dependency_mode)
            with (
                mock.patch.object(readiness, "MAX_EXECUTABLE_BYTES", 0),
                self.assertRaisesRegex(readiness.ReadinessError, "byte bound"),
            ):
                readiness._private_dependency_fingerprint(clean_sandbox)
            with (
                mock.patch.object(readiness, "MAX_DEPENDENCY_ENTRIES", 0),
                self.assertRaisesRegex(readiness.ReadinessError, "too many entries"),
            ):
                readiness._private_dependency_fingerprint(clean_sandbox)
            self.assertEqual(
                readiness._private_dependency_fingerprint(clean_sandbox),
                dependency_fingerprint,
            )

            test_command = (
                "mise",
                "exec",
                "-C",
                "elixir",
                "--",
                "mix",
                "test",
                "test/symphony_elixir/log_file_test.exs",
                "--seed",
                "0",
            )
            returncode, test_stdout, test_stderr = readiness.run_bounded_command(
                readiness._sandbox_command(
                    clean_sandbox, test_command, writable_erlexec=True
                ),
                cwd=clean_sandbox.temporary_root,
                environment=readiness._safe_gate_environment(clean_sandbox),
                timeout_seconds=300.0,
                max_output_bytes=readiness.MAX_GATE_OUTPUT_BYTES,
            )
            self.assertEqual(
                returncode,
                0,
                (
                    test_stdout.decode("utf-8", errors="replace")
                    + test_stderr.decode("utf-8", errors="replace")
                ),
            )
            self.assertFalse((clean_snapshot / "elixir/log").exists())
            self.assertTrue(
                any(
                    path.name.startswith("symphony.log")
                    for path in clean_sandbox.tmp.iterdir()
                )
            )
            self.assertEqual(
                readiness._inspect_private_erlexec_source(
                    clean_sandbox.erlexec_source,
                    clean_sandbox.erlexec_tracked,
                    normalize_generated=True,
                    require_compiled=True,
                ),
                erlexec_fingerprint,
            )
            self.assertEqual(
                readiness._private_dependency_fingerprint(clean_sandbox),
                dependency_fingerprint,
            )
            self.assertEqual(
                readiness._git_metadata_fingerprint(repo_root), clean_metadata
            )
            self.assertEqual(
                readiness._git_text(repo_root, ["write-tree"]), clean_index_tree
            )

    def test_source_archive_is_reproducible_and_aggregate_bounded(self) -> None:
        with without_outer_git_worktree(), tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "--quiet"], cwd=root, check=True)
            (root / "CODEX_VERSION").write_text("0.144.3\n", encoding="utf-8")
            schema_path = root / "elixir/priv/codex_schema/0.144.3/manifest.json"
            schema_path.parent.mkdir(parents=True)
            schema_path.write_bytes(readiness.canonical_json_bytes(self.schema))
            long_path = root / ("long-" + "a" * 90) / ("file-" + "b" * 90 + ".txt")
            long_path.parent.mkdir(parents=True)
            long_path.write_text("deterministic\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=root, check=True)

            first = readiness.build_package_probe_record(root)
            second = readiness.build_package_probe_record(root)
            self.assertEqual(first, second)
            self.assertEqual(first["status"], "pass")
            readiness.validate_package_probe_record(
                first, first["sourceSha256"], first["indexTree"]
            )

            final_readiness = {
                "checkout": {
                    "source": {
                        "schemaManifestPath": "elixir/priv/codex_schema/0.144.3/manifest.json",
                        "sha256": first["sourceSha256"],
                    }
                },
                "finalPair": True,
            }
            private_index = root / ".git/index.archive-verifier"
            live_index = root / ".git/index"
            live_lock = root / ".git/index.lock"
            shutil.copyfile(live_index, private_index)
            live_index_sha256 = readiness.sha256_regular_file(live_index)
            shutil.copyfile(live_index, live_lock)
            try:
                final_record = readiness.rehearse_final_pair_source_archive(
                    root,
                    final_readiness,
                    {"state": "paired-final-schema"},
                    first["sourceSha256"],
                    first["indexTree"],
                    index_file=private_index,
                )
            finally:
                live_lock.unlink(missing_ok=True)
                private_index.unlink(missing_ok=True)
            self.assertEqual(
                readiness.sha256_regular_file(live_index), live_index_sha256
            )
            self.assertEqual(final_record["status"], "pass")
            self.assertNotEqual(final_record["indexTree"], first["indexTree"])
            self.assertEqual(final_record["entryCount"], first["entryCount"] + 1)

        entries = [("first", "100644", SHA_A), ("second", "100644", SHA_B)]
        blobs = [b"a" * 2_000, b"b" * 2_000]
        with (
            mock.patch.object(readiness, "MAX_ARCHIVE_BYTES", 22_400),
            mock.patch.object(readiness, "_parse_index_entries", return_value=entries),
            mock.patch.object(
                readiness,
                "_run_git",
                side_effect=[
                    subprocess.CompletedProcess([], 0, blobs[0], b""),
                    subprocess.CompletedProcess([], 0, blobs[1], b""),
                ],
            ),
        ):
            with self.assertRaisesRegex(readiness.ReadinessError, "aggregate"):
                readiness._archive_index_entries(Path.cwd())


class InstalledCodexVerifierTest(unittest.TestCase):
    def test_actual_launcher_native_payload_and_version_are_reverified(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            package_root = Path(temporary) / "pkg"
            launcher = package_root / "bin/codex"
            native = (
                package_root
                / "node_modules/@openai/codex-test/vendor/test-target/bin/codex"
            )
            launcher.parent.mkdir(parents=True)
            native.parent.mkdir(parents=True)
            launcher.write_text(
                "#!/bin/sh\nprintf '%s\\n' 'codex-cli 0.144.3'\n",
                encoding="utf-8",
            )
            native.write_bytes(b"native-codex-fixture\n")
            os.chmod(launcher, 0o755)
            os.chmod(native, 0o755)
            architecture = platform.machine().lower()
            architecture = {"amd64": "x86_64", "x64": "x86_64"}.get(
                architecture, architecture
            )
            selected = {
                "architecture": architecture,
                "installedPackageAlias": "@openai/codex-test",
                "launcherSha256": readiness.sha256_regular_file(launcher),
                "nativeSha256": readiness.sha256_regular_file(native),
                "operatingSystem": platform.system().lower(),
                "target": "test-target",
            }
            lock = {
                "version": "0.144.3",
                "versionOutput": "codex-cli 0.144.3",
            }
            result = readiness.verify_installed_codex(lock, selected, str(launcher))
            self.assertEqual(result["launcherSha256"], selected["launcherSha256"])
            self.assertEqual(result["nativeSha256"], selected["nativeSha256"])
            self.assertEqual(result["versionOutput"], lock["versionOutput"])

            native.write_bytes(b"tampered-native\n")
            with self.assertRaisesRegex(readiness.ReadinessError, "native Codex hash"):
                readiness.verify_installed_codex(lock, selected, str(launcher))


class StagedSourceBasisTest(unittest.TestCase):
    def git(self, root: Path, *arguments: str) -> None:
        subprocess.run(
            ["git", *arguments],
            cwd=root,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )

    def test_patch_ledger_header_matches_latest_normative_revision(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ledger = root / readiness.PATCH_LEDGER_RELATIVE
            ledger.parent.mkdir(parents=True)
            ledger.write_text(
                "# Patch ledger\n\n"
                "Ledger revision: `59`\n\n"
                "- Revision 58 — 2026-07-20: prior.\n"
                "- Revision 58 fixture repair — 2026-07-20: qualified.\n"
                "- Revision 59 — 2026-07-20: current.\n",
                encoding="utf-8",
            )
            self.assertEqual(readiness._patch_ledger_revision(root), 59)

            ledger.write_text(
                ledger.read_text(encoding="utf-8").replace(
                    "Ledger revision: `59`", "Ledger revision: `58`"
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(readiness.ReadinessError, "header is stale"):
                readiness._patch_ledger_revision(root)

    def test_staged_basis_is_cycle_free_and_dirty_source_is_rejected(self) -> None:
        with without_outer_git_worktree(), tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.git(root, "init", "--quiet")
            schema_path = root / "elixir/priv/codex_schema/0.144.3/manifest.json"
            schema_path.parent.mkdir(parents=True)
            schema = schema_manifest()
            schema_path.write_bytes(readiness.canonical_json_bytes(schema))
            source = root / "source.txt"
            source.write_text("first\n", encoding="utf-8")
            self.git(root, "add", ".")
            private_index = root / ".git/index.source-verifier"
            shutil.copyfile(root / ".git/index", private_index)
            live_index_sha256 = readiness.sha256_regular_file(root / ".git/index")

            first = readiness.index_source_basis(
                root,
                schema,
                "elixir/priv/codex_schema/0.144.3/manifest.json",
                index_file=private_index,
            )
            self.assertEqual(
                readiness.sha256_regular_file(root / ".git/index"),
                live_index_sha256,
            )
            variant = copy.deepcopy(schema)
            variant["compatibility"]["runtimeCapabilities"] = "blocked"
            variant["compatibility"]["overall"] = "blocked_r0_06"
            variant["compatibility"]["runtimeEvidence"] = {
                "hashAlgorithm": readiness.HASH_ALGORITHM,
                "readinessManifestSha256": "e" * 64,
                "schemaManifestBasisSha256": first["schemaManifestBasisSha256"],
                "sourceSha256": first["sha256"],
            }
            second = readiness.index_source_basis(
                root,
                variant,
                "elixir/priv/codex_schema/0.144.3/manifest.json",
                index_file=private_index,
            )
            self.assertEqual(first, second)

            source.write_text("unstaged\n", encoding="utf-8")
            with self.assertRaisesRegex(readiness.ReadinessError, "dirty unstaged"):
                readiness.index_source_basis(
                    root,
                    schema,
                    "elixir/priv/codex_schema/0.144.3/manifest.json",
                    index_file=private_index,
                )

            self.git(root, "add", "source.txt")
            staged = readiness.index_source_basis(
                root, schema, "elixir/priv/codex_schema/0.144.3/manifest.json"
            )
            self.assertNotEqual(first["sha256"], staged["sha256"])

    def test_untracked_source_is_rejected_but_readiness_artifact_is_excluded(self) -> None:
        with without_outer_git_worktree(), tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.git(root, "init", "--quiet")
            schema_path = root / "elixir/priv/codex_schema/0.144.3/manifest.json"
            schema_path.parent.mkdir(parents=True)
            schema = schema_manifest()
            schema_path.write_bytes(readiness.canonical_json_bytes(schema))
            self.git(root, "add", ".")

            artifact = root / readiness.READINESS_RELATIVE
            artifact.parent.mkdir(parents=True)
            artifact.write_text("{}\n", encoding="utf-8")
            readiness.index_source_basis(
                root, schema, "elixir/priv/codex_schema/0.144.3/manifest.json"
            )

            (root / "unexpected.py").write_text("pass\n", encoding="utf-8")
            with self.assertRaisesRegex(readiness.ReadinessError, "untracked source"):
                readiness.index_source_basis(
                    root, schema, "elixir/priv/codex_schema/0.144.3/manifest.json"
                )


if __name__ == "__main__":
    unittest.main()
