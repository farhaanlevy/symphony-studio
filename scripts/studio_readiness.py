#!/usr/bin/env python3
# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0
"""Build and verify Symphony Studio's redacted R0-06 readiness pair.

The verified capability report consumed by :func:`build_readiness_candidate`
is an opaque compiler result. Its already-redacted payload has exactly these
keys::

    {
      "reportVersion": 1,
      "matrixOutcomes": {
        "methods": {"<matrix id>": "pass|absent|auth_restricted|unsupported|blocked|not_run", ...},
        "fields": {"<matrix id>": "pass|absent|auth_restricted|unsupported|blocked|not_run", ...},
        "negativeCapabilities": {"<matrix id>": "pass|blocked|not_run", ...}
      },
      "models": [
        {"id": "<opaque public model id>", "model": "<public model slug>",
         "defaultServiceTier": "<opaque tier id>" | null,
         "fastServiceTierId": "<opaque tier id>" | null,
         "reasoningEfforts": ["<opaque effort>", ...],
         "serviceTierIds": ["<opaque tier id>", ...]}
      ],
      "subagents": {
        "implementation": "multi_agent_v2",
        "rootCountsTowardLimit": true,
        "rawToOptionalChildren": [
          {"raw": 1, "optionalChildren": 0},
          {"raw": 2, "optionalChildren": 1},
          {"raw": 3, "optionalChildren": 2}
        ],
        "nativeDepthEnforcement": false,
        "studioDepthGuardRequired": true,
        "trustedGuardStatus": "pass|blocked|not_run",
        "hookFailureClassification": "fail_open|blocked|not_run"
      },
      "authMode": "chatgpt|api_key|unavailable|unsupported",
      "identityBinding": {
        "bindingId": "codex-binding-v1-<64 lowercase hex>" | null,
        "evidence": "keyed_account_metadata|unavailable|not_run",
        "generation": <non-negative integer>,
        "status": "confirmed|unconfirmed|blocked|not_run"
      },
      "referenceProfile": {
        "chatgptAuthentication": true|false,
        "identityBinding": true|false,
        "solAvailable": true|false,
        "solReviewEffort": true|false,
        "solUltra": true|false,
        "status": "pass|fail|not_run",
        "terraAvailable": true|false,
        "terraHigh": true|false,
        "terraMedium": true|false
      },
      "quota": {
        "fullRead": "pass|blocked|not_run",
        "sparseUpdate": "pass|blocked|not_run",
        "multiBucket": "pass|absent|blocked|not_run",
        "usage": "pass|absent|blocked|not_run"
      },
      "linear": {
        "configuredProjectBinding": "linear-project-v1-<64 lowercase hex>" | null,
        "connectivity": {"status": "pass|blocked|not_run"},
        "project": {"status": "pass|blocked|not_run"},
        "states": {"status": "pass|blocked|not_run"},
        "labels": {"status": "pass|blocked|not_run"},
        "blockers": {"status": "pass|blocked|not_run"},
        "comments": {"status": "pass|blocked|not_run"},
        "mutations": {
          "evidence": "schema_only|unavailable|not_run",
          "status": "pass|blocked|not_run"
        }
      },
      "platform": {
        "os": "<public OS id>",
        "architecture": "<public architecture id>",
        "osStatus": "pass|blocked|not_run",
        "package": "<public package id>",
        "packageStatus": "pass|pending|blocked|not_run"
      },
      "conformance": [
        {"id": "<stable public id>", "command": ["<relative/safe arg>", ...],
         "required": true, "outcome": "pass|blocked|not_run"}
      ]
    }

It intentionally retains only the persistence-safe, domain-separated HMAC
identity binding. It has no raw account identifier, email, plan, absolute
path, CODEX_HOME, quota amount, provider payload, log, or raw response.
The module does not publish files.  Its candidate CLI emits both canonical
candidate objects to stdout so ``codex_schema.py`` can later install them under
one lock and one atomic verification boundary.
"""

from __future__ import annotations

import argparse
import copy
from dataclasses import dataclass
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import selectors
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import platform as host_platform
import time
from typing import Any, Iterable, Mapping, Sequence


REPO_ROOT = Path(__file__).resolve().parents[1]
READINESS_RELATIVE = "artifacts/readiness/implementation-readiness.json"
MATRIX_RELATIVE = "scripts/codex_schema_matrix.json"
PATCH_LEDGER_RELATIVE = "docs/architecture/patch-ledger.md"
MAX_JSON_BYTES = 8 * 1024 * 1024
MAX_TEXT_BYTES = 16 * 1024 * 1024
MAX_GIT_OUTPUT_BYTES = 32 * 1024 * 1024
MAX_EXECUTABLE_BYTES = 512 * 1024 * 1024
MAX_MODELS = 1_024
MAX_CONFORMANCE_ROWS = 256
MAX_LIVE_RECEIPTS = 64
MAX_COMMAND_ARGUMENTS = 128
MAX_IDENTIFIER_BYTES = 256
MAX_COMMAND_ARGUMENT_BYTES = 1_024
LIVE_JSON_PREFIX = "SYMPHONY_STUDIO_CAPABILITIES_JSON="
LIVE_TASK_ENTRYPOINT = "Mix.Tasks.Studio.Capabilities.run_sealed(System.argv())"
LINEAR_TASK_ENTRYPOINT = (
    "Mix.Tasks.Studio.LinearCapabilities.run_sealed(System.argv())"
)
MAX_RUNTIME_CODE_PATHS = 48
CODEX_PROBE_JSON_PREFIX = "SYMPHONY_STUDIO_CODEX_PROBE_JSON="
LINEAR_PROBE_JSON_PREFIX = "SYMPHONY_STUDIO_LINEAR_PROBE_JSON="
LINEAR_TASK_JSON_PREFIX = "SYMPHONY_STUDIO_LINEAR_CAPABILITIES_JSON="
LINEAR_BROKER_ENVIRONMENT_KEY = "SYMPHONY_LINEAR_BROKER_SOCKET"
LINEAR_BROKER_SANDBOX_PATH = "/run/symphony-readiness/linear-broker.sock"
LIVE_SUPERVISOR_SOCKET_ENVIRONMENT_KEY = "SYMPHONY_READINESS_SUPERVISOR_SOCKET"
LIVE_SUPERVISOR_SHARED_PARENT_ENVIRONMENT_KEY = (
    "SYMPHONY_READINESS_SHARED_PARENT"
)
LIVE_SUPERVISOR_SOCKET_PATH = Path("/run/symphony-supervisor/control.sock")
LIVE_SUPERVISOR_SHARED_PARENT = Path("/run/symphony-supervisor/work")
LIVE_SUPERVISOR_PROTOCOL_VERSION = 4
MAX_LIVE_SUPERVISOR_FRAME_BYTES = MAX_JSON_BYTES
PACKAGE_PROBE_JSON_PREFIX = "SYMPHONY_STUDIO_PACKAGE_PROBE_JSON="
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_GATE_OUTPUT_BYTES = 32 * 1024 * 1024
MAX_HEX_CACHE_BYTES = 64 * 1024 * 1024
MAX_MIX_HEX_ARCHIVES = 8
MAX_HEX_RUNTIME_ENTRIES = 8
MAX_MIX_TOOL_INPUT_BYTES = 64 * 1024 * 1024
MAX_MIX_TOOL_INPUT_ENTRIES = 20_000
MAX_PRIVATE_PLT_BYTES = 256 * 1024 * 1024
MAX_PRIVATE_PLT_ENTRIES = 50_000
MAX_DEPENDENCY_ENTRIES = 50_000
MAX_BUILD_LINK_BYTES = 4 * 1024
MAX_ERLEXEC_SOURCE_BYTES = 64 * 1024 * 1024
MAX_ERLEXEC_GENERATED_BYTES = 64 * 1024 * 1024
MAX_GATE_GENERATED_BYTES = 64 * 1024 * 1024
MAX_GATE_GENERATED_FILES = 4_096
ERLEXEC_INDEX_PREFIX = "elixir/vendor/erlexec/"
ERLEXEC_SOURCE_RELATIVE = "elixir/vendor/erlexec"
GATE_COVER_RELATIVE = "elixir/cover"
GATE_ESCRIPT_RELATIVE = "elixir/bin"
GATE_MOUNTPOINT_RELATIVES = (
    GATE_COVER_RELATIVE,
    GATE_ESCRIPT_RELATIVE,
    ".git",
)
SETUP_ELIXIR_REQUIRED = frozenset(
    {"config/config.exs", "config/test.exs", "mise.toml", "mix.exs", "mix.lock"}
)
KNOWN_MIX_PREAMBLE = (
    re.compile(r"Compiling [1-9][0-9]* files? \(\.ex\)\Z"),
    re.compile(r"Generated symphony_elixir app\Z"),
    re.compile(r"===> Analyzing applications\.\.\.\Z"),
    re.compile(r"===> Compiling erlexec\Z"),
    re.compile(r"make: Nothing to be done for 'all'\.\Z"),
    re.compile(
        r"make: (?:Entering|Leaving) directory "
        r"'.*/(?:elixir/vendor/erlexec|erlexec-source)/c_src'\Z"
    ),
)
MATRIX_TOP_LEVEL_KEYS = {
    "codexVersion",
    "definitionEqualities",
    "fields",
    "matrixVersion",
    "methods",
    "negativeCapabilities",
    "profile",
    "r002Status",
    "r006Status",
}

READINESS_ROOT_KEYS = {
    "capabilities",
    "checkout",
    "codex",
    "conformance",
    "manifestVersion",
    "platform",
    "profile",
    "runtime",
}
STATIC_BASIS_KEYS = {"checkout", "codex"}
CHECKOUT_KEYS = {
    "headCommit",
    "headSemantics",
    "patchLedgerRevision",
    "source",
    "upstreamBaseCommit",
    "upstreamCommit",
}
SOURCE_KEYS = {
    "algorithm",
    "fileCount",
    "gitObjectFormat",
    "readinessPathExcluded",
    "schemaManifestBasisSha256",
    "schemaManifestPath",
    "sha256",
}
CODEX_KEYS = {
    "artifactBundleSha256",
    "launcherSha256",
    "matrixSha256",
    "nativeSha256",
    "schemaBundleSha256",
    "schemaManifestBasisSha256",
    "target",
    "version",
    "versionOutput",
}
CAPABILITY_KEYS = {"auth", "linear", "matrix", "models", "quota", "subagents"}
MATRIX_OUTCOME_KEYS = {"fields", "methods", "negativeCapabilities"}
MATRIX_ROW_KEYS = {"absentBehavior", "id", "outcome", "probe", "requirement"}
NEGATIVE_ROW_KEYS = {"id", "outcome"}
MODEL_KEYS = {
    "defaultServiceTier",
    "fastServiceTierId",
    "id",
    "model",
    "reasoningEfforts",
    "serviceTierIds",
}
REFERENCE_PROFILE_KEYS = {
    "chatgptAuthentication",
    "identityBinding",
    "solAvailable",
    "solReviewEffort",
    "solUltra",
    "status",
    "terraAvailable",
    "terraHigh",
    "terraMedium",
}
SUBAGENT_KEYS = {
    "hookFailureClassification",
    "implementation",
    "nativeDepthEnforcement",
    "rawToOptionalChildren",
    "rootCountsTowardLimit",
    "studioDepthGuardRequired",
    "trustedGuardStatus",
}
CAP_ROW_KEYS = {"optionalChildren", "raw"}
AUTH_KEYS = {"identityBinding", "mode", "referenceProfile"}
IDENTITY_BINDING_KEYS = {"bindingId", "evidence", "generation", "status"}
QUOTA_KEYS = {"fullRead", "multiBucket", "sparseUpdate", "usage"}
LINEAR_STATUS_KEYS = {
    "blockers",
    "comments",
    "connectivity",
    "labels",
    "mutations",
    "project",
    "states",
}
LINEAR_KEYS = {"configuredProjectBinding", *LINEAR_STATUS_KEYS}
LINEAR_STATUS_KEYS_IN_PROBE_ORDER = (
    "connectivity",
    "project",
    "states",
    "labels",
    "blockers",
    "comments",
    "mutations",
)
LINEAR_STATUS_ROW_KEYS = {"status"}
LINEAR_MUTATION_ROW_KEYS = {"evidence", "status"}
LINEAR_MUTATION_EVIDENCE = {"not_run", "schema_only", "unavailable"}
LINEAR_PROBE_STATUS_ROW_KEYS = {"reason", "status"}
LINEAR_MUTATION_PROBE_ROW_KEYS = {"evidence", "reason", "status"}
LINEAR_BINDING_RE = re.compile(r"linear-project-v1-[0-9a-f]{64}\Z")
LINEAR_BINDING_GENERATION = 1
LINEAR_PROBE_REASONS = {
    "binding_key_unavailable",
    "configuration_changed",
    "configuration_limit",
    "configuration_unavailable",
    "configured_labels_missing",
    "configured_states_missing",
    "duplicate_entity",
    "duplicate_or_malformed_entity",
    "fixture_blocker_missing",
    "fixture_changed",
    "fixture_comment_missing",
    "fixture_issue_missing",
    "fixture_shape_mismatch",
    "graphql_error",
    "invalid_endpoint",
    "invalid_label_configuration",
    "invalid_state_configuration",
    "malformed_payload",
    "missing_api_key",
    "missing_project_configuration",
    "pagination_cycle",
    "pagination_limit",
    "project_binding_mismatch",
    "project_changed",
    "project_not_found",
    "request_failed",
    "unknown_schema",
    "unsupported_tracker",
    "validation_team_mismatch",
    "verified",
    "viewer_changed",
}
PLATFORM_KEYS = {"architecture", "os", "osStatus", "package", "packageStatus"}
CONFORMANCE_ROW_KEYS = {"command", "id", "outcome", "required"}
RUNTIME_KEYS = {"blockers", "capabilities", "overall"}
PUBLIC_REPORT_KEYS = {
    "authMode",
    "conformance",
    "linear",
    "matrixOutcomes",
    "models",
    "platform",
    "quota",
    "referenceProfile",
    "reportVersion",
    "subagents",
    "identityBinding",
}

SCHEMA_ROOT_KEYS = {
    "artifacts",
    "codex",
    "compatibility",
    "generation",
    "manifestVersion",
    "matrix",
}
SCHEMA_COMPATIBILITY_BASE_KEYS = {
    "fixtureEvidence",
    "fixtures",
    "overall",
    "runtimeCapabilities",
    "schemaContract",
    "testedAt",
    "transportConformance",
}
SCHEMA_ARTIFACT_KEYS = {
    "artifactBundleSha256",
    "experimentalJson",
    "experimentalTypescript",
    "json",
    "schemaBundleSha256",
    "typescript",
}
SCHEMA_ARTIFACT_ROW_KEYS = {"byteCount", "fileCount", "path", "sha256"}
SCHEMA_CODEX_KEYS = {"executable", "npmIntegrity", "package", "version", "versionOutput"}
SCHEMA_EXECUTABLE_KEYS = {
    "installedPackageAlias",
    "launcherSha256",
    "nativeSha256",
    "platformNpmIntegrity",
    "platformPackage",
    "target",
}
SCHEMA_GENERATION_KEYS = {
    "cleanCodexHome",
    "commands",
    "generatedAt",
    "jsonHashAlgorithm",
    "typescriptHashAlgorithm",
}
SCHEMA_MATRIX_KEYS = {"path", "profile", "sha256"}
SCHEMA_FIXTURE_EVIDENCE_KEYS = {
    "artifactBundleSha256",
    "codexVersion",
    "command",
    "dependencyCommand",
    "dependencyCompileCommand",
    "matrixSha256",
    "schemaBundleSha256",
    "sourceFileCount",
    "sourceHashAlgorithm",
    "sourceSha256",
    "testCount",
    "testedAt",
}
SCHEMA_RUNTIME_EVIDENCE_KEYS = {
    "hashAlgorithm",
    "readinessManifestSha256",
    "schemaManifestBasisSha256",
    "sourceSha256",
}
LIVE_EVIDENCE_KEYS = {"capabilityReport", "reportVersion", "requestReceipts"}
LIVE_RECEIPT_KEYS = {
    "attempt",
    "classification",
    "method",
    "outcome",
    "paramsShape",
    "requestHash",
    "sequence",
}
CAPABILITY_REPORT_KEYS = {
    "account",
    "initialize",
    "models",
    "noModelWork",
    "optional",
    "quotaShape",
    "referenceProfile",
    "reportVersion",
    "schemaVersion",
}

OUTCOMES = {"absent", "auth_restricted", "blocked", "not_run", "pass", "unsupported"}
REQUIRED_OUTCOMES = {"blocked", "not_run", "pass"}
AUTH_MODES = {"api_key", "chatgpt", "unavailable", "unsupported"}
IDENTITY_BINDING_STATUSES = {"blocked", "confirmed", "not_run", "unconfirmed"}
PACKAGE_OUTCOMES = {"blocked", "not_run", "pass", "pending"}
RUNTIME_CAPABILITIES = {"blocked", "not_run", "pass"}
RUNTIME_OVERALL = {"blocked_r0_06", "pass", "pending_r0_06"}
HASH_ALGORITHM = "sha256-canonical-json-v1"
SOURCE_ALGORITHM = "sha256-git-index-mode-oid-path-synthetic-schema-v1"
HEAD_SEMANTICS = "generation-head-with-staged-index-v1"
SCHEMA_RUNTIME_SENTINEL = "<r0-06-runtime-capabilities>"
SCHEMA_OVERALL_SENTINEL = "<r0-06-overall>"
EXPECTED_CAP_MAPPING = (
    {"optionalChildren": 0, "raw": 1},
    {"optionalChildren": 1, "raw": 2},
    {"optionalChildren": 2, "raw": 3},
)
SOURCE_BOUND_FIXTURE_FILES = (
    "test/symphony_elixir/codex_schema_bundle_test.exs",
    "test/symphony_elixir/app_server_test.exs",
    "test/symphony_elixir/codex_compatibility_circuit_test.exs",
    "test/symphony_elixir/codex_connection_test.exs",
    "test/symphony_elixir/codex_jsonl_framer_test.exs",
    "test/symphony_elixir/codex_process_adapter_test.exs",
    "test/symphony_elixir/codex_request_policy_test.exs",
    "test/symphony_elixir/codex_stderr_diagnostics_test.exs",
    "test/symphony_elixir/dynamic_tool_test.exs",
    "test/symphony_elixir/extensions_test.exs",
    "test/symphony_elixir/event_sink_test.exs",
    "test/symphony_elixir/event_test.exs",
    "test/symphony_elixir/fake_codex_app_server_test.exs",
    "test/symphony_elixir/fake_linear_test.exs",
    "test/symphony_elixir/identity_test.exs",
    "test/symphony_elixir/network_hermeticity_test.exs",
    "test/symphony_elixir/orchestrator_event_test.exs",
    "test/symphony_elixir/orchestrator_status_test.exs",
    "test/symphony_elixir/workspace_and_config_test.exs",
    "test/symphony_elixir/cancellation_lifecycle_test.exs",
    "test/symphony_elixir/cancellation_safety_regression_test.exs",
    "test/symphony_elixir/hook_cancellation_containment_test.exs",
    "test/symphony_elixir/runtime_supervisor_test.exs",
    "test/symphony_elixir/tracker_outbox_test.exs",
    "test/symphony_elixir/codex_capability_error_test.exs",
    "test/symphony_elixir/codex_capability_decoder_test.exs",
    "test/symphony_elixir/codex_capability_discovery_test.exs",
    "test/symphony_elixir/codex_capability_report_test.exs",
    "test/symphony_elixir/codex_depth_guard_test.exs",
    "test/symphony_elixir/codex_identity_binding_test.exs",
    "test/symphony_elixir/codex_quota_shape_test.exs",
    "test/symphony_elixir/fake_responses_test.exs",
    "test/symphony_elixir/codex_v2_cap_hook_conformance_test.exs",
    "test/mix/tasks/studio_capabilities_test.exs",
    "test/symphony_elixir/linear_capability_discovery_test.exs",
    "test/symphony_elixir/linear_error_boundary_test.exs",
    "test/symphony_elixir/linear_read_only_broker_test.exs",
    "test/mix/tasks/studio_linear_capabilities_test.exs",
)
REQUIRED_CONFORMANCE_COMMANDS = {
    "capability_fake_conformance": (
        "mise",
        "exec",
        "-C",
        "elixir",
        "--",
        "mix",
        "test",
        "test/symphony_elixir/codex_capability_error_test.exs",
        "test/symphony_elixir/codex_capability_decoder_test.exs",
        "test/symphony_elixir/codex_capability_discovery_test.exs",
        "test/symphony_elixir/codex_capability_report_test.exs",
        "test/symphony_elixir/codex_identity_binding_test.exs",
        "test/symphony_elixir/codex_quota_shape_test.exs",
        "test/mix/tasks/studio_capabilities_test.exs",
        "--seed",
        "0",
    ),
    "depth_guard_conformance": (
        "mise",
        "exec",
        "-C",
        "elixir",
        "--",
        "mix",
        "test",
        "test/symphony_elixir/codex_depth_guard_test.exs",
        "--seed",
        "0",
    ),
    "installed_codex_verify": (
        "python3",
        "scripts/codex_schema.py",
        "verify-source-bound-prepublication",
        "--codex",
        "codex",
    ),
    "linear_fake_conformance": (
        "mise",
        "exec",
        "-C",
        "elixir",
        "--",
        "mix",
        "test",
        "test/symphony_elixir/fake_linear_test.exs",
        "test/symphony_elixir/dynamic_tool_test.exs",
        "test/symphony_elixir/linear_capability_discovery_test.exs",
        "test/symphony_elixir/linear_error_boundary_test.exs",
        "test/symphony_elixir/linear_read_only_broker_test.exs",
        "test/symphony_elixir/extensions_test.exs",
        "test/mix/tasks/studio_linear_capabilities_test.exs",
        "--seed",
        "0",
    ),
    "linear_live_discovery": (
        "python3",
        "scripts/studio_readiness.py",
        "probe-linear",
        "--repo-root",
        ".",
        "--mise",
        "mise",
    ),
    "no_model_live_discovery": (
        "python3",
        "scripts/studio_readiness.py",
        "probe-codex",
        "--repo-root",
        ".",
        "--codex",
        "codex",
        "--mise",
        "mise",
    ),
    "readiness_harness": (
        "python3",
        "scripts/test_studio_readiness.py",
    ),
    "schema_harness": ("python3", "scripts/run_codex_schema_tests.py"),
    "schema_regeneration": (
        "python3",
        "scripts/codex_schema.py",
        "regenerate-check",
        "--codex",
        "codex",
    ),
    "source_archive_rehearsal": (
        "python3",
        "scripts/studio_readiness.py",
        "probe-source-archive",
        "--repo-root",
        ".",
    ),
    "source_bound_fixture_replay": (
        "mise",
        "exec",
        "-C",
        "elixir",
        "--",
        "mix",
        "test",
        *SOURCE_BOUND_FIXTURE_FILES,
        "--seed",
        "0",
    ),
    "subagent_cap_conformance": (
        "mise",
        "exec",
        "-C",
        "elixir",
        "--",
        "mix",
        "test",
        "test/symphony_elixir/codex_v2_cap_hook_conformance_test.exs",
        "--seed",
        "0",
    ),
    "upstream_make_all": ("mise", "exec", "-C", "elixir", "--", "make", "all"),
}
REQUIRED_CONFORMANCE_IDS = frozenset(REQUIRED_CONFORMANCE_COMMANDS)
CODEX_TARGET_PLATFORMS = {
    "x86_64-unknown-linux-musl": ("linux", "x86_64"),
}
SUPPORTED_RELEASE_PACKAGE = "source-archive"

PROBE_GATE_REQUIREMENTS = {
    "conformance": frozenset(
        {
            "installed_codex_verify",
            "schema_harness",
            "schema_regeneration",
            "source_bound_fixture_replay",
        }
    ),
    "invoke": frozenset(
        {
            "installed_codex_verify",
            "source_bound_fixture_replay",
            "upstream_make_all",
        }
    ),
    "observe": frozenset(
        {
            "installed_codex_verify",
            "source_bound_fixture_replay",
            "upstream_make_all",
        }
    ),
    "read": frozenset(
        {
            "capability_fake_conformance",
            "installed_codex_verify",
            "no_model_live_discovery",
            "source_bound_fixture_replay",
        }
    ),
}
SCHEMA_NEGATIVE_GATES = frozenset(
    {"installed_codex_verify", "schema_harness", "schema_regeneration"}
)
ELIXIR_GATE_IDS = frozenset(
    identifier
    for identifier, command in REQUIRED_CONFORMANCE_COMMANDS.items()
    if "mix" in command or "make" in command
)
ERLEXEC_WRITABLE_GATE_IDS = ELIXIR_GATE_IDS | frozenset(
    {"linear_live_discovery", "no_model_live_discovery"}
)
HEX_RUNTIME_WRITABLE_GATE_IDS = frozenset({"upstream_make_all"})
MIX_HOME_WRITABLE_GATE_IDS = frozenset({"upstream_make_all"})
OFFLINE_DIALYZER_REPLAY_COMMAND = (
    "mise",
    "exec",
    "-C",
    "elixir",
    "--",
    "mix",
    "dialyzer",
    "--format",
    "dialyzer",
)
DIALYZER_ERROR_MARKER = b":dialyzer.run error:"
INSTALLED_CODEX_PROBE_TIMEOUT_SECONDS = 15.0
GIT_COMMAND_TIMEOUT_SECONDS = 30.0
LIVE_CHECKOUT_TIMEOUT_SECONDS = 60.0
LIVE_SETUP_COMMAND_TIMEOUT_SECONDS = 600.0
LIVE_SETUP_COMMAND_COUNT = 6
LIVE_TASK_TIMEOUT_SECONDS = 180.0
LIVE_SUPERVISOR_SESSION_BOUND_SECONDS = 600.0
LIVE_SUPERVISOR_CLIENT_TIMEOUT_SECONDS = 660.0
LIVE_TASK_ENVIRONMENT_KEYS = frozenset(
    {
        "ALL_PROXY",
        "ERL_CRASH_DUMP",
        "HOME",
        "HTTPS_PROXY",
        "HTTP_PROXY",
        "LANG",
        "LC_ALL",
        "LOGNAME",
        "NO_COLOR",
        "NO_PROXY",
        "SSL_CERT_DIR",
        "SSL_CERT_FILE",
        "TERM",
        "TMPDIR",
        "TZ",
        "USER",
        "XDG_CACHE_HOME",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
        "all_proxy",
        "http_proxy",
        "https_proxy",
        "no_proxy",
    }
)
STATIC_BASIS_GIT_COMMAND_COUNT = 17
LIVE_PROBE_PREPOST_GIT_COMMAND_COUNT = 7
STATIC_BASIS_BOUND_SECONDS = (
    STATIC_BASIS_GIT_COMMAND_COUNT * GIT_COMMAND_TIMEOUT_SECONDS
    + INSTALLED_CODEX_PROBE_TIMEOUT_SECONDS
)
LIVE_PROBE_NESTED_BOUND_SECONDS = (
    LIVE_PROBE_PREPOST_GIT_COMMAND_COUNT * GIT_COMMAND_TIMEOUT_SECONDS
    + LIVE_CHECKOUT_TIMEOUT_SECONDS
    + 2 * INSTALLED_CODEX_PROBE_TIMEOUT_SECONDS
    + LIVE_SETUP_COMMAND_COUNT * LIVE_SETUP_COMMAND_TIMEOUT_SECONDS
    + LIVE_TASK_TIMEOUT_SECONDS
)
NO_MODEL_LIVE_DISCOVERY_MINIMUM_BOUND_SECONDS = (
    2 * STATIC_BASIS_BOUND_SECONDS + LIVE_PROBE_NESTED_BOUND_SECONDS
)
# Standalone `probe-codex` verifies the complete static basis both before and
# after its six credential-free preparation phases. The initial dependency and
# test-NIF bootstrap phases alone retain network; every replay/application
# compile is network-isolated. The full-gate compiler reuses the same frozen dev
# build and therefore executes only the final bounded direct task.
NO_MODEL_LIVE_DISCOVERY_AUDITED_BOUND_SECONDS = 5_400.0
NO_MODEL_LIVE_DISCOVERY_MARGIN_SECONDS = 300.0
# The exact private `make all` gate repeats the complete Python schema harness
# before coverage and a fresh Dialyzer analysis.  The Revision 40 diagnostic
# reached Dialyzer's real warning result in 1,257.930 seconds, so the audited
# 1,500-second command ceiling retains a separate five-minute scheduling and
# teardown margin.  The byte-stability replay is a distinct, already-built
# Dialyzer command and keeps its own finite deadline.
UPSTREAM_MAKE_ALL_AUDITED_BOUND_SECONDS = 1_500.0
UPSTREAM_MAKE_ALL_MARGIN_SECONDS = 300.0
UPSTREAM_MAKE_ALL_TIMEOUT_SECONDS = (
    UPSTREAM_MAKE_ALL_AUDITED_BOUND_SECONDS + UPSTREAM_MAKE_ALL_MARGIN_SECONDS
)
OFFLINE_DIALYZER_REPLAY_TIMEOUT_SECONDS = 1_200.0
GATE_TIMEOUT_SECONDS = {
    "no_model_live_discovery": (
        NO_MODEL_LIVE_DISCOVERY_AUDITED_BOUND_SECONDS
        + NO_MODEL_LIVE_DISCOVERY_MARGIN_SECONDS
    ),
    "schema_harness": 900.0,
    "source_bound_fixture_replay": 900.0,
    "upstream_make_all": UPSTREAM_MAKE_ALL_TIMEOUT_SECONDS,
}

SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")
GIT_COMMIT_RE = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
IDENTIFIER_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:+/\-]{0,255}\Z")
IDENTITY_BINDING_ID_RE = re.compile(r"codex-binding-v1-[0-9a-f]{64}\Z")
EMAIL_RE = re.compile(r"(?i)(?<![A-Za-z0-9._%+\-])[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")
WINDOWS_ABSOLUTE_RE = re.compile(r"(?i)^[A-Z]:[\\/]")
EMBEDDED_POSIX_ABSOLUTE_RE = re.compile(r"(?:^|[=:\s])/(?!/)[^\s]*")
EMBEDDED_WINDOWS_ABSOLUTE_RE = re.compile(r"(?i)(?:^|[=:\s])[A-Z]:[\\/]")
SENSITIVE_ASSIGNMENT_RE = re.compile(
    r"(?i)(?:api[_-]?key|authorization|cookie|credential|password|secret|token)"
    r"[A-Za-z0-9_.-]*="
)
SECRET_PATTERNS = (
    re.compile(r"(?i)\bBearer\s+[A-Za-z0-9._~+/=\-]+"),
    re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_\-]{8,}"),
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{12,}"),
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
)
FORBIDDEN_PUBLIC_KEYS = {
    "accountId",
    "account_id",
    "balance",
    "codexHome",
    "codex_home",
    "credits",
    "email",
    "identityBindingId",
    "identity_binding_id",
    "logs",
    "plan",
    "planType",
    "plan_type",
    "providerPayload",
    "provider_payload",
    "quotaPayload",
    "quota_payload",
    "rawPayload",
    "raw_payload",
    "token",
    "tokens",
}


class ReadinessError(RuntimeError):
    """Raised when a readiness candidate is unsafe, stale, or inconsistent."""


class VerifiedPublicReport:
    """Opaque report issued only by a production evidence compiler."""

    __slots__ = ("__report",)

    def __init__(self) -> None:
        raise ReadinessError("verified reports must come from the trusted compiler")

    def _copy_for_builder(self) -> dict[str, Any]:
        return copy.deepcopy(self.__report)


class LiveCapabilityEvidence:
    """Opaque, receipt-checked output captured from the exact compiled task entry."""

    __slots__ = ("__value",)

    def __init__(self) -> None:
        raise ReadinessError("live evidence must be captured by the trusted compiler")

    def _copy_for_compiler(self) -> dict[str, Any]:
        return copy.deepcopy(self.__value)


@dataclass(frozen=True)
class PrivateLiveRuntimeTools:
    """Exact project-independent Elixir/Erlang entry tools for the live task."""

    elixir_runner: Path
    elixirc_runner: Path
    erlang_root: Path
    fingerprint_paths: tuple[tuple[str, Path, bool], ...]


@dataclass(frozen=True)
class LiveSupervisorSeal:
    """Opaque transient binding to one supervisor-owned credential runtime."""

    seal_id: str
    index_tree: str


@dataclass(frozen=True)
class GateExecution:
    """One bounded execution of an exact public conformance command."""

    identifier: str
    command: tuple[str, ...]
    outcome: str
    stdout: bytes
    stderr: bytes


@dataclass(frozen=True)
class FullGateEvidence:
    """Opaque-in-practice evidence retained only inside the trusted compiler."""

    executions: tuple[GateExecution, ...]
    live: LiveCapabilityEvidence | None
    linear: dict[str, Any]
    package: dict[str, Any]
    source_sha256: str
    index_tree: str


@dataclass(frozen=True)
class GateSandbox:
    """Host-side inputs mounted into one structurally credential-blind namespace."""

    temporary_root: Path
    sandbox_uid: int
    sandbox_gid: int
    snapshot: Path
    setup_elixir: Path
    setup_elixir_tracked: tuple[tuple[str, str, str], ...]
    git_dir: Path
    home: Path
    xdg_cache: Path
    xdg_config: Path
    xdg_data: Path
    xdg_state: Path
    hex_home: Path
    hex_runtime: Path
    mix_home: Path
    mix_tools: Path
    mix_rebar_version: str
    mix_tools_fingerprint: str
    mix_build: Path
    mix_deps: Path
    rebar_build: Path
    erlexec_source: Path
    erlexec_tracked: tuple[tuple[str, str, str], ...]
    coverage_output: Path
    escript_output: Path
    tmp: Path
    mise_cache: Path
    mise_config: Path
    mise_state: Path
    host_home: Path
    host_tool_bin: Path
    host_codex_package: Path
    host_mise_data: Path
    host_mix_home: Path
    resolver_config: Path | None
    resolver_target: str | None
    resolver_sha256: str | None


class MatrixArtifact(Mapping[str, Any]):
    """Strict parsed matrix bound to the exact bounded bytes that produced it."""

    __slots__ = ("__label", "__payload", "__semantic_sha256", "__value")

    def __init__(self, payload: bytes, label: str = "capability matrix") -> None:
        if not isinstance(payload, bytes) or len(payload) > MAX_JSON_BYTES:
            raise ReadinessError(f"{label} bytes exceed their bound")
        value = _mapping(decode_json_bytes(payload, label), label)
        self.__label = label
        self.__payload = bytes(payload)
        self.__value = copy.deepcopy(value)
        self.__semantic_sha256 = sha256_bytes(canonical_json_bytes(value))

    def __getitem__(self, key: str) -> Any:
        return self.__value[key]

    def __iter__(self):
        return iter(self.__value)

    def __len__(self) -> int:
        return len(self.__value)

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, MatrixArtifact):
            return NotImplemented
        return self.__payload == other.__payload and self.__value == other.__value

    def __deepcopy__(self, memo: dict[int, Any]) -> "MatrixArtifact":
        del memo
        return MatrixArtifact(self.__payload, self.__label)

    @property
    def raw_sha256(self) -> str:
        return sha256_bytes(self.__payload)

    def _copy_for_verification(self) -> dict[str, Any]:
        value = copy.deepcopy(self.__value)
        if self.__semantic_sha256 != sha256_bytes(canonical_json_bytes(value)):
            raise ReadinessError(
                "capability matrix changed after its artifact bytes were verified"
            )
        return value


def read_matrix_artifact(path: Path) -> MatrixArtifact:
    return MatrixArtifact(_read_regular_bytes(path, MAX_JSON_BYTES), str(path))


def _require_matrix_artifact(value: Any) -> MatrixArtifact:
    if not isinstance(value, MatrixArtifact):
        raise ReadinessError("capability matrix must come from exact bounded artifact bytes")
    value._copy_for_verification()
    return value


def _new_live_capability_evidence(value: Mapping[str, Any]) -> LiveCapabilityEvidence:
    evidence = object.__new__(LiveCapabilityEvidence)
    evidence._LiveCapabilityEvidence__value = copy.deepcopy(
        _mapping(value, "live capability evidence")
    )
    return evidence


def _new_verified_public_report(
    report: Mapping[str, Any], live_evidence: LiveCapabilityEvidence
) -> VerifiedPublicReport:
    if not isinstance(live_evidence, LiveCapabilityEvidence):
        raise ReadinessError("verified report requires captured live evidence")
    value = object.__new__(VerifiedPublicReport)
    value._VerifiedPublicReport__report = copy.deepcopy(
        _mapping(report, "verified public report")
    )
    return value


def _exact_keys(value: Mapping[str, Any], expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise ReadinessError(f"{label} keys mismatch; missing={missing}, extra={extra}")


def _mapping(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ReadinessError(f"{label} must be an object")
    if not all(isinstance(key, str) for key in value):
        raise ReadinessError(f"{label} keys must be strings")
    return value


def _list(value: Any, label: str, maximum: int) -> list[Any]:
    if not isinstance(value, list):
        raise ReadinessError(f"{label} must be an array")
    if len(value) > maximum:
        raise ReadinessError(f"{label} exceeds its item bound")
    return value


def _identifier(value: Any, label: str) -> str:
    if not isinstance(value, str) or not IDENTIFIER_RE.fullmatch(value):
        raise ReadinessError(f"{label} must be a bounded public identifier")
    if len(value.encode("utf-8")) > MAX_IDENTIFIER_BYTES:
        raise ReadinessError(f"{label} exceeds its byte bound")
    return value


def _public_text(value: Any, label: str, maximum: int = 256) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise ReadinessError(f"{label} must be a non-empty public string")
    if len(value.encode("utf-8")) > maximum:
        raise ReadinessError(f"{label} exceeds its byte bound")
    _assert_public_tree(value, label)
    return value


def _contains_absolute_path(value: str) -> bool:
    return bool(
        value.startswith(("/", "~/", "~\\", "\\\\"))
        or WINDOWS_ABSOLUTE_RE.match(value)
        or EMBEDDED_POSIX_ABSOLUTE_RE.search(value)
        or EMBEDDED_WINDOWS_ABSOLUTE_RE.search(value)
    )


def _sha256(value: Any, label: str) -> str:
    if not isinstance(value, str) or not SHA256_RE.fullmatch(value):
        raise ReadinessError(f"{label} must be a lowercase SHA-256")
    return value


def _commit(value: Any, label: str) -> str:
    if not isinstance(value, str) or not GIT_COMMIT_RE.fullmatch(value):
        raise ReadinessError(f"{label} must be a lowercase Git commit ID")
    return value


def _enum(value: Any, allowed: set[str], label: str) -> str:
    if not isinstance(value, str) or value not in allowed:
        raise ReadinessError(f"{label} must be one of {sorted(allowed)}")
    return value


def canonical_json_bytes(value: Any) -> bytes:
    """Return the repository's deterministic, human-readable JSON encoding."""

    try:
        return (
            json.dumps(value, allow_nan=False, ensure_ascii=False, indent=2, sort_keys=True)
            + "\n"
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise ReadinessError(f"value cannot be encoded as canonical JSON: {error}") from error


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _read_regular_bytes(path: Path, maximum: int) -> bytes:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ReadinessError(f"cannot inspect required file {path}: {error}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise ReadinessError(f"required input is not a regular non-symlink file: {path}")
    if metadata.st_size > maximum:
        raise ReadinessError(f"required input exceeds its byte bound: {path}")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
        try:
            opened = os.fstat(descriptor)
            if not stat.S_ISREG(opened.st_mode):
                raise ReadinessError(f"required input is not a regular file: {path}")
            if (opened.st_dev, opened.st_ino, opened.st_size) != (
                metadata.st_dev,
                metadata.st_ino,
                metadata.st_size,
            ):
                raise ReadinessError(f"required input changed while opening: {path}")
            chunks: list[bytes] = []
            total = 0
            while True:
                chunk = os.read(descriptor, min(64 * 1024, maximum + 1 - total))
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
                if total > maximum:
                    raise ReadinessError(f"required input exceeds its byte bound: {path}")
            after = os.fstat(descriptor)
            if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != (
                opened.st_dev,
                opened.st_ino,
                opened.st_size,
                opened.st_mtime_ns,
            ):
                raise ReadinessError(f"required input changed while reading: {path}")
            return b"".join(chunks)
        finally:
            os.close(descriptor)
    except OSError as error:
        raise ReadinessError(f"cannot securely read required file {path}: {error}") from error


def sha256_regular_file(path: Path, maximum: int = MAX_EXECUTABLE_BYTES) -> str:
    """Hash one bounded regular non-symlink file without retaining its contents."""

    try:
        metadata = path.lstat()
    except OSError as error:
        raise ReadinessError(f"cannot inspect executable input {path}: {error}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise ReadinessError(f"executable input is not a regular non-symlink file: {path}")
    if metadata.st_size > maximum:
        raise ReadinessError(f"executable input exceeds its byte bound: {path}")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
        try:
            opened = os.fstat(descriptor)
            if not stat.S_ISREG(opened.st_mode):
                raise ReadinessError(f"executable input is not a regular file: {path}")
            identity = (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns)
            digest = hashlib.sha256()
            total = 0
            while True:
                chunk = os.read(descriptor, 1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > maximum:
                    raise ReadinessError(f"executable input exceeds its byte bound: {path}")
                digest.update(chunk)
            after = os.fstat(descriptor)
            if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != identity:
                raise ReadinessError(f"executable input changed while hashing: {path}")
            return digest.hexdigest()
        finally:
            os.close(descriptor)
    except OSError as error:
        raise ReadinessError(f"cannot securely hash executable input {path}: {error}") from error


def _terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    for process_signal in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, process_signal)
        except ProcessLookupError:
            break
        deadline = time.monotonic() + 1.0
        while time.monotonic() < deadline:
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.02)
        else:
            continue
        break
    if process.poll() is None:
        try:
            process.wait(timeout=1.0)
        except subprocess.TimeoutExpired as error:
            raise ReadinessError("bounded child root could not be reaped") from error


def _process_group_alive(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def run_bounded_command(
    command: Sequence[str],
    *,
    cwd: Path,
    environment: Mapping[str, str],
    timeout_seconds: float,
    max_output_bytes: int,
) -> tuple[int, bytes, bytes]:
    """Run one process group with an absolute deadline and retained-output cap."""

    process: subprocess.Popen[bytes] | None = None
    selector = selectors.DefaultSelector()
    stdout = bytearray()
    stderr = bytearray()
    try:
        process = subprocess.Popen(
            [str(argument) for argument in command],
            cwd=cwd,
            env=dict(environment),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        if process.stdout is None or process.stderr is None:
            raise ReadinessError("bounded child did not expose output pipes")
        for stream, buffer in ((process.stdout, stdout), (process.stderr, stderr)):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, buffer)
        deadline = time.monotonic() + timeout_seconds
        failure: str | None = None
        while selector.get_map() or process.poll() is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                failure = "absolute deadline exceeded"
                break
            events = selector.select(min(remaining, 0.1)) if selector.get_map() else []
            for key, _mask in events:
                stream = key.fileobj
                while True:
                    try:
                        chunk = os.read(stream.fileno(), 64 * 1024)
                    except BlockingIOError:
                        break
                    if not chunk:
                        selector.unregister(stream)
                        stream.close()
                        break
                    key.data.extend(chunk)
                    if len(stdout) + len(stderr) > max_output_bytes:
                        failure = "combined output exceeded its byte bound"
                        break
                if failure is not None:
                    break
            if failure is not None:
                break
        if failure is not None:
            _terminate_process_group(process)
            raise ReadinessError(f"bounded child failed safely: {failure}")
        returncode = process.wait(timeout=1.0)
        if _process_group_alive(process.pid):
            _terminate_process_group(process)
            raise ReadinessError("bounded child left a residual process-group member")
        return returncode, bytes(stdout), bytes(stderr)
    except BaseException as error:
        if process is not None:
            _terminate_process_group(process)
        if isinstance(error, ReadinessError):
            raise
        if isinstance(error, (OSError, subprocess.SubprocessError)):
            raise ReadinessError(f"bounded child failed safely: {error}") from error
        raise
    finally:
        selector.close()
        if process is not None:
            for stream in (process.stdout, process.stderr):
                if stream is not None and not stream.closed:
                    stream.close()


def verify_installed_codex(
    lock: Mapping[str, Any], selected: Mapping[str, Any], codex_command: str = "codex"
) -> dict[str, str]:
    """Verify the selected host launcher, native payload, and version output."""

    operating_system = host_platform.system().lower()
    architecture = host_platform.machine().lower()
    architecture = {"amd64": "x86_64", "x64": "x86_64"}.get(architecture, architecture)
    if selected.get("operatingSystem") != operating_system or selected.get("architecture") != architecture:
        raise ReadinessError("selected Codex executable pin does not match the current host")

    executable_text = (
        shutil.which(codex_command) if os.sep not in codex_command else codex_command
    )
    if not executable_text:
        raise ReadinessError("installed Codex executable was not found")
    try:
        launcher = Path(executable_text).resolve(strict=True)
    except OSError as error:
        raise ReadinessError(f"cannot resolve installed Codex executable: {error}") from error
    launcher_sha = sha256_regular_file(launcher)
    if launcher_sha != selected.get("launcherSha256"):
        raise ReadinessError("installed Codex launcher hash differs from CODEX_LOCK")

    alias = selected.get("installedPackageAlias")
    if not isinstance(alias, str) or not alias.startswith("@openai/"):
        raise ReadinessError("Codex lock installed package alias is invalid")
    alias_name = alias.rsplit("/", 1)[-1]
    package_root = launcher.parent.parent
    candidates = sorted(
        package_root.glob(f"node_modules/@openai/{alias_name}/vendor/**/codex")
    )
    native_candidates: list[Path] = []
    for candidate in candidates:
        try:
            metadata = candidate.lstat()
        except OSError:
            continue
        if stat.S_ISREG(metadata.st_mode) and not stat.S_ISLNK(metadata.st_mode):
            native_candidates.append(candidate)
    if len(native_candidates) != 1:
        raise ReadinessError(
            f"expected one installed native Codex payload; found {len(native_candidates)}"
        )
    native = native_candidates[0]
    native_sha = sha256_regular_file(native)
    if native_sha != selected.get("nativeSha256"):
        raise ReadinessError("installed native Codex hash differs from CODEX_LOCK")

    with tempfile.TemporaryDirectory(prefix="symphony-readiness-codex-") as temporary:
        root = Path(temporary)
        home = root / "home"
        codex_home = root / "codex-home"
        cache = root / "cache"
        config = root / "config"
        state = root / "state"
        tmp = root / "tmp"
        for path in (home, codex_home, cache, config, state, tmp):
            path.mkdir(mode=0o700)
        environment = {
            "CODEX_HOME": str(codex_home),
            "HOME": str(home),
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "NO_COLOR": "1",
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "TERM": "dumb",
            "TMPDIR": str(tmp),
            "TZ": "UTC",
            "XDG_CACHE_HOME": str(cache),
            "XDG_CONFIG_HOME": str(config),
            "XDG_STATE_HOME": str(state),
        }
        returncode, stdout, stderr = run_bounded_command(
            [str(launcher), "--version"],
            cwd=home,
            environment=environment,
            timeout_seconds=INSTALLED_CODEX_PROBE_TIMEOUT_SECONDS,
            max_output_bytes=128 * 1024,
        )
    if returncode != 0:
        raise ReadinessError("installed Codex version probe returned a failure")
    try:
        version_output = stdout.decode("utf-8").strip()
    except UnicodeDecodeError as error:
        raise ReadinessError("installed Codex version output is not UTF-8") from error
    if stderr.strip():
        raise ReadinessError("installed Codex version probe emitted unexpected stderr")
    if version_output != lock.get("versionOutput"):
        raise ReadinessError("installed Codex version output differs from CODEX_LOCK")
    if sha256_regular_file(launcher) != launcher_sha or sha256_regular_file(native) != native_sha:
        raise ReadinessError("installed Codex executable changed during verification")
    return {
        "launcherPath": str(launcher),
        "launcherSha256": launcher_sha,
        "nativePath": str(native),
        "nativeSha256": native_sha,
        "versionOutput": version_output,
    }


def _boolean(value: Any, label: str) -> bool:
    if type(value) is not bool:
        raise ReadinessError(f"{label} must be boolean")
    return value


def _non_negative_integer(value: Any, label: str) -> int:
    if type(value) is not int or value < 0:
        raise ReadinessError(f"{label} must be a non-negative integer")
    return value


def _nullable_identifier(value: Any, label: str) -> str | None:
    return None if value is None else _identifier(value, label)


def _validate_live_model(raw: Any, index: int) -> dict[str, Any]:
    label = f"live capability model[{index}]"
    row = _mapping(raw, label)
    keys = {
        "defaultReasoningEffort",
        "defaultServiceTier",
        "fastServiceTierId",
        "hidden",
        "id",
        "isDefault",
        "model",
        "reasoningEfforts",
        "serviceTierIds",
    }
    _exact_keys(row, keys, label)
    efforts = _normalize_string_list(row["reasoningEfforts"], f"{label} efforts")
    tiers = _normalize_string_list(row["serviceTierIds"], f"{label} tiers")
    default_tier = _nullable_identifier(
        row["defaultServiceTier"], f"{label} default tier"
    )
    fast_tier = _nullable_identifier(row["fastServiceTierId"], f"{label} fast tier")
    if default_tier is not None and default_tier not in tiers:
        raise ReadinessError(f"{label} default tier is not advertised")
    if fast_tier is not None and fast_tier not in tiers:
        raise ReadinessError(f"{label} Fast tier is not advertised")
    return {
        "defaultReasoningEffort": _identifier(
            row["defaultReasoningEffort"], f"{label} default effort"
        ),
        "defaultServiceTier": default_tier,
        "fastServiceTierId": fast_tier,
        "hidden": _boolean(row["hidden"], f"{label} hidden"),
        "id": _identifier(row["id"], f"{label} ID"),
        "isDefault": _boolean(row["isDefault"], f"{label} default flag"),
        "model": _identifier(row["model"], f"{label} model"),
        "reasoningEfforts": efforts,
        "serviceTierIds": tiers,
    }


def _validate_live_optional_status(
    raw: Any, label: str, payload_key: str
) -> dict[str, Any]:
    row = _mapping(raw, label)
    status = _enum(
        row.get("status"),
        {"available", "auth_restricted", "unavailable", "unsupported"},
        f"{label} status",
    )
    expected_keys = {"status", payload_key} if status == "available" else {"status"}
    _exact_keys(row, expected_keys, label)
    return row


def _validate_live_capability_report(raw: Any, expected_version: str) -> dict[str, Any]:
    report = copy.deepcopy(_mapping(raw, "live capability report"))
    _exact_keys(report, CAPABILITY_REPORT_KEYS, "live capability report")
    if report["reportVersion"] != 1 or report["schemaVersion"] != expected_version:
        raise ReadinessError("live capability report version differs from the Codex pin")
    if report["noModelWork"] is not True:
        raise ReadinessError("live capability report does not prove no-model collection")

    account = _mapping(report["account"], "live account")
    _exact_keys(
        account,
        {"authMode", "authenticated", "identity", "requiresOpenaiAuth"},
        "live account",
    )
    _enum(account["authMode"], AUTH_MODES - {"unavailable"}, "live auth mode")
    _boolean(account["authenticated"], "live authenticated status")
    _boolean(account["requiresOpenaiAuth"], "live OpenAI-auth requirement")
    identity = _mapping(account["identity"], "live identity")
    _exact_keys(
        identity,
        {
            "bindingId",
            "evidence",
            "generation",
            "providerIdentifierAvailable",
            "status",
        },
        "live identity",
    )
    normalized_identity = _normalize_identity_binding(
        {
            "bindingId": identity["bindingId"],
            "evidence": identity["evidence"],
            "generation": identity["generation"],
            "status": identity["status"],
        }
    )
    if identity["providerIdentifierAvailable"] is not False:
        raise ReadinessError("pinned Codex unexpectedly advertised a provider identity")
    if account["authMode"] == "chatgpt" and account["authenticated"] is not True:
        raise ReadinessError("ChatGPT capability report is not authenticated")
    if normalized_identity["status"] == "confirmed" and account["authenticated"] is not True:
        raise ReadinessError("confirmed identity is inconsistent with authentication")

    initialize = _mapping(report["initialize"], "live initialize result")
    _exact_keys(
        initialize,
        {
            "codexHomeAbsolute",
            "platformFamily",
            "platformOs",
            "userAgentSha256",
            "versionAdvertised",
        },
        "live initialize result",
    )
    if initialize["codexHomeAbsolute"] is not True:
        raise ReadinessError("live initialize result did not prove an absolute Codex home")
    _identifier(initialize["platformFamily"], "live platform family")
    _identifier(initialize["platformOs"], "live platform OS")
    _sha256(initialize["userAgentSha256"], "live user-agent hash")
    if initialize["versionAdvertised"] is not True:
        raise ReadinessError("live App Server did not advertise the pinned version")

    models = [
        _validate_live_model(row, index)
        for index, row in enumerate(_list(report["models"], "live models", MAX_MODELS))
    ]
    if models != sorted(models, key=lambda item: (item["model"], item["id"])):
        raise ReadinessError("live models are not in canonical order")
    if len({row["id"] for row in models}) != len(models):
        raise ReadinessError("live models contain duplicate IDs")

    optional = _mapping(report["optional"], "live optional capabilities")
    _exact_keys(
        optional,
        {"collaborationModes", "experimentalFeatures", "usage"},
        "live optional capabilities",
    )
    collaboration = _validate_live_optional_status(
        optional["collaborationModes"], "live collaboration modes", "result"
    )
    if collaboration["status"] == "available":
        rows = _list(collaboration["result"], "live collaboration modes result", 1_024)
        for index, raw_row in enumerate(rows):
            row = _mapping(raw_row, f"live collaboration mode[{index}]")
            _exact_keys(
                row,
                {"mode", "model", "name", "reasoningEffort"},
                f"live collaboration mode[{index}]",
            )
            _nullable_identifier(row["mode"], "live collaboration mode")
            _nullable_identifier(row["model"], "live collaboration model")
            _identifier(row["name"], "live collaboration name")
            _nullable_identifier(row["reasoningEffort"], "live collaboration effort")
    features = _validate_live_optional_status(
        optional["experimentalFeatures"], "live experimental features", "items"
    )
    if features["status"] == "available":
        rows = _list(features["items"], "live experimental feature items", 1_024)
        for index, raw_row in enumerate(rows):
            row = _mapping(raw_row, f"live experimental feature[{index}]")
            _exact_keys(
                row,
                {"defaultEnabled", "enabled", "name", "stage"},
                f"live experimental feature[{index}]",
            )
            _boolean(row["defaultEnabled"], "live feature default-enabled flag")
            _boolean(row["enabled"], "live feature enabled flag")
            _identifier(row["name"], "live feature name")
            _identifier(row["stage"], "live feature stage")
    usage = _validate_live_optional_status(optional["usage"], "live usage", "result")
    if usage["status"] == "available":
        result = _mapping(usage["result"], "live usage result")
        _exact_keys(result, {"dailyBucketCount", "populatedSummaryFields"}, "live usage result")
        _non_negative_integer(result["dailyBucketCount"], "live daily bucket count")
        _normalize_string_list(result["populatedSummaryFields"], "live usage fields")

    quota = _mapping(report["quotaShape"], "live quota shape")
    if set(quota) == {"status"}:
        _enum(quota["status"], {"auth_restricted", "unsupported"}, "live quota status")
    else:
        _exact_keys(
            quota,
            {
                "bucketCount",
                "bucketSource",
                "fields",
                "outOfRangeValues",
                "resetCredits",
                "windowSlotCount",
            },
            "live quota shape",
        )
        _non_negative_integer(quota["bucketCount"], "live quota bucket count")
        _identifier(quota["bucketSource"], "live quota bucket source")
        _normalize_string_list(quota["fields"], "live quota fields")
        _boolean(quota["outOfRangeValues"], "live quota range status")
        _non_negative_integer(quota["windowSlotCount"], "live quota window count")
        credits = _mapping(quota["resetCredits"], "live reset credits")
        _exact_keys(credits, {"details", "summary"}, "live reset credits")
        _identifier(credits["details"], "live reset-credit details")
        _identifier(credits["summary"], "live reset-credit summary")

    reference = _mapping(report["referenceProfile"], "live reference profile")
    _exact_keys(reference, REFERENCE_PROFILE_KEYS, "live reference profile")
    for key in REFERENCE_PROFILE_KEYS - {"status"}:
        _boolean(reference[key], f"live reference profile {key}")
    status = _enum(
        reference["status"], {"fail", "pass"}, "live reference profile status"
    )
    expected_status = (
        "pass"
        if all(reference[key] for key in REFERENCE_PROFILE_KEYS - {"status"})
        else "fail"
    )
    if status != expected_status:
        raise ReadinessError("live reference profile status is inconsistent")
    _assert_public_tree(report, "live capability report")
    return report


def _validate_live_receipts(raw: Any, report: Mapping[str, Any]) -> list[dict[str, Any]]:
    rows = _list(raw, "live request receipts", MAX_LIVE_RECEIPTS)
    normalized: list[dict[str, Any]] = []
    for index, raw_row in enumerate(rows, 1):
        row = copy.deepcopy(_mapping(raw_row, f"live receipt[{index}]"))
        _exact_keys(row, LIVE_RECEIPT_KEYS, f"live receipt[{index}]")
        if (
            type(row["sequence"]) is not int
            or type(row["attempt"]) is not int
            or row["sequence"] != index
            or row["attempt"] != 1
        ):
            raise ReadinessError("live receipt sequence/attempt is not deterministic")
        method = _identifier(row["method"], f"live receipt[{index}] method")
        expected_classification = "handshake" if method == "initialize" else "idempotent"
        if row["classification"] != expected_classification:
            raise ReadinessError("live receipt request classification differs from policy")
        expected_shape = (
            "omitted"
            if method in {"account/rateLimits/read", "account/usage/read"}
            else "object"
        )
        if row["paramsShape"] != expected_shape:
            raise ReadinessError("live receipt parameter shape differs from the pinned schema")
        _enum(
            row["outcome"],
            {"auth_restricted", "pass", "unavailable", "unsupported"},
            f"live receipt[{index}] outcome",
        )
        _sha256(row["requestHash"], f"live receipt[{index}] request hash")
        normalized.append(row)

    methods = [row["method"] for row in normalized]
    minimum = ["initialize", "account/read", "account/rateLimits/read"]
    if methods[:3] != minimum:
        raise ReadinessError("live receipts do not start with the exact required sequence")
    cursor = 3
    model_count = 0
    while cursor < len(methods) and methods[cursor] == "model/list":
        model_count += 1
        cursor += 1
    if model_count == 0:
        raise ReadinessError("live receipts contain no bounded model pagination")
    if cursor >= len(methods) or methods[cursor] != "account/usage/read":
        raise ReadinessError("live receipts omit the optional usage read")
    cursor += 1
    feature_count = 0
    while cursor < len(methods) and methods[cursor] == "experimentalFeature/list":
        feature_count += 1
        cursor += 1
    if feature_count == 0:
        raise ReadinessError("live receipts contain no bounded feature pagination")
    expected_tail = ["collaborationMode/list", "account/read"]
    if methods[cursor:] != expected_tail:
        raise ReadinessError("live receipts do not end with collaboration and account revalidation")

    optional = report["optional"]
    expected_outcomes = {
        "account/usage/read": optional["usage"]["status"],
        "experimentalFeature/list": optional["experimentalFeatures"]["status"],
        "collaborationMode/list": optional["collaborationModes"]["status"],
    }
    expected_outcomes = {
        method: "pass" if status == "available" else status
        for method, status in expected_outcomes.items()
    }
    quota = report["quotaShape"]
    expected_outcomes["account/rateLimits/read"] = quota.get("status", "pass")
    for row in normalized:
        method = row["method"]
        expected = expected_outcomes.get(method, "pass")
        if row["outcome"] != expected:
            raise ReadinessError(f"live receipt outcome differs from report for {method}")
    if report["account"]["authMode"] == "chatgpt" and expected_outcomes[
        "account/rateLimits/read"
    ] != "pass":
        raise ReadinessError("ChatGPT live evidence lacks the required full quota read")
    _assert_public_tree(normalized, "live request receipts")
    return normalized


def validate_live_capability_envelope(
    value: Mapping[str, Any], expected_version: str
) -> dict[str, Any]:
    """Strictly validate one captured no-model task envelope and its receipts."""

    envelope = copy.deepcopy(_mapping(value, "live capability envelope"))
    _exact_keys(envelope, LIVE_EVIDENCE_KEYS, "live capability envelope")
    if envelope["reportVersion"] != 1:
        raise ReadinessError("unsupported live capability envelope version")
    report = _validate_live_capability_report(
        envelope["capabilityReport"], expected_version
    )
    receipts = _validate_live_receipts(envelope["requestReceipts"], report)
    envelope["capabilityReport"] = report
    envelope["requestReceipts"] = receipts
    return envelope


def decode_live_task_stdout(
    payload: bytes, *, allow_build_preamble: bool = True
) -> dict[str, Any]:
    """Extract one final task envelope while discarding bounded Mix build chatter."""

    try:
        lines = payload.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise ReadinessError("live capability task stdout is not UTF-8") from error
    while lines and not lines[-1].strip():
        lines.pop()
    if not lines:
        raise ReadinessError("live capability task emitted no JSON envelope")
    final = lines[-1]
    if not final.startswith(LIVE_JSON_PREFIX):
        raise ReadinessError("live capability task omitted its final JSON record prefix")
    json_text = final[len(LIVE_JSON_PREFIX) :]
    if not json_text.startswith("{"):
        raise ReadinessError("live capability task final record is not a JSON object")
    if not allow_build_preamble and lines[:-1]:
        raise ReadinessError("live capability task unexpectedly rebuilt authenticated code")
    for line in lines[:-1]:
        if line.startswith(LIVE_JSON_PREFIX):
            raise ReadinessError("live capability task emitted duplicate JSON records")
        if not any(pattern.fullmatch(line) for pattern in KNOWN_MIX_PREAMBLE):
            raise ReadinessError("live capability task emitted unexpected build output")
    value = decode_json_bytes(json_text.encode("utf-8"), "live capability task stdout")
    return _mapping(value, "live capability envelope")


def run_live_capability_probe(
    repo_root: Path,
    lock: Mapping[str, Any],
    selected: Mapping[str, Any],
    static_basis: Mapping[str, Any],
    codex_command: str = "codex",
    mise_command: str = "mise",
) -> LiveCapabilityEvidence:
    """Use the sealed credential-free-build/direct-runner Codex boundary."""

    repo_root = Path(repo_root).resolve(strict=True)
    static = copy.deepcopy(_mapping(static_basis, "live expected static basis"))
    _validate_static_basis(static)
    lock_value = _mapping(lock, "live Codex lock")
    selected_value = _mapping(selected, "live selected Codex executable")
    if lock_value.get("version") != static["codex"]["version"]:
        raise ReadinessError("live Codex lock differs from the static basis")
    if selected_value.get("target") != static["codex"]["target"]:
        raise ReadinessError("live selected Codex target differs from the static basis")
    for key in ("launcherSha256", "nativeSha256"):
        if selected_value.get(key) != static["codex"][key]:
            raise ReadinessError("live selected Codex hashes differ from the static basis")
    record = build_codex_probe_record(repo_root, codex_command, mise_command)
    return validate_codex_probe_record(record, static)


def compile_live_blocked_report(
    live_evidence: LiveCapabilityEvidence,
    matrix: MatrixArtifact,
    static_basis: Mapping[str, Any],
) -> VerifiedPublicReport:
    """Adapt trusted live facts into a truthful, blocked supplemental candidate.

    This adapter never invents the deterministic, Linear, package, or review
    receipts that the live task does not own. A later evidence compiler may
    promote those exact rows only after their authoritative gates execute.
    """

    if not isinstance(live_evidence, LiveCapabilityEvidence):
        raise ReadinessError("live report compilation requires captured task evidence")
    captured = live_evidence._copy_for_compiler()
    _exact_keys(
        captured,
        {
            "envelope",
            "launcherSha256",
            "nativeSha256",
            "staticBasisSha256",
            "versionOutput",
        },
        "captured live capability evidence",
    )
    static = copy.deepcopy(_mapping(static_basis, "live compiler static basis"))
    _validate_static_basis(static)
    if captured["staticBasisSha256"] != sha256_bytes(canonical_json_bytes(static)):
        raise ReadinessError("live capability evidence belongs to a different static basis")
    codex = static["codex"]
    matrix_artifact = _require_matrix_artifact(matrix)
    matrix_value = matrix_artifact._copy_for_verification()
    _exact_keys(matrix_value, MATRIX_TOP_LEVEL_KEYS, "capability matrix")
    if matrix_artifact.raw_sha256 != codex["matrixSha256"]:
        raise ReadinessError("capability matrix bytes differ from the static Codex basis")
    for key in ("launcherSha256", "nativeSha256", "versionOutput"):
        if captured[key] != codex[key]:
            raise ReadinessError("live executable evidence differs from the static basis")
    envelope = _mapping(captured["envelope"], "captured live envelope")
    report = envelope["capabilityReport"]
    if report["schemaVersion"] != codex.get("version"):
        raise ReadinessError("live report version differs from the readiness Codex basis")
    receipt_outcomes: dict[str, str] = {}
    for receipt in envelope["requestReceipts"]:
        outcome = "absent" if receipt["outcome"] == "unavailable" else receipt["outcome"]
        prior = receipt_outcomes.setdefault(receipt["method"], outcome)
        if prior != outcome:
            raise ReadinessError("paginated live receipt outcomes are inconsistent")

    matrix_outcomes: dict[str, dict[str, str]] = {
        "fields": {},
        "methods": {},
        "negativeCapabilities": {},
    }
    for entry in _list(matrix_value.get("methods"), "matrix methods", 4_096):
        row = _mapping(entry, "matrix method")
        identifier = _identifier(row.get("id"), "matrix method ID")
        observed = receipt_outcomes.get(row.get("method"))
        if observed is not None:
            matrix_outcomes["methods"][identifier] = observed
        else:
            matrix_outcomes["methods"][identifier] = "not_run"
    for entry in _list(matrix_value.get("fields"), "matrix fields", 4_096):
        row = _mapping(entry, "matrix field")
        identifier = _identifier(row.get("id"), "matrix field ID")
        matrix_outcomes["fields"][identifier] = "not_run"
    for entry in _list(
        matrix_value.get("negativeCapabilities"),
        "matrix negative capabilities",
        4_096,
    ):
        row = _mapping(entry, "matrix negative capability")
        matrix_outcomes["negativeCapabilities"][
            _identifier(row.get("id"), "matrix negative capability ID")
        ] = "not_run"

    account = report["account"]
    live_identity = account["identity"]
    models = [
        {
            "defaultServiceTier": row["defaultServiceTier"],
            "fastServiceTierId": row["fastServiceTierId"],
            "id": row["id"],
            "model": row["model"],
            "reasoningEfforts": row["reasoningEfforts"],
            "serviceTierIds": row["serviceTierIds"],
        }
        for row in report["models"]
        if row["hidden"] is False
    ]
    quota_shape = report["quotaShape"]
    quota_full = "pass" if "status" not in quota_shape else "blocked"
    quota_multi = (
        "pass"
        if quota_full == "pass" and quota_shape.get("bucketSource") == "multi"
        else "absent"
    )
    usage_status = report["optional"]["usage"]["status"]
    quota_usage = "pass" if usage_status == "available" else usage_status
    if quota_usage == "unavailable":
        quota_usage = "absent"

    expected_platform = CODEX_TARGET_PLATFORMS.get(codex.get("target"))
    if expected_platform is None:
        raise ReadinessError("Codex target has no supported live platform mapping")
    expected_os, expected_architecture = expected_platform
    if report["initialize"]["platformOs"] != expected_os:
        raise ReadinessError("live App Server platform differs from the installed Codex target")
    conformance = [
        {
            "command": list(REQUIRED_CONFORMANCE_COMMANDS[identifier]),
            "id": identifier,
            # The trusted probe ran from an immutable checkout-index snapshot with
            # resolved tool paths and private dependency/build directories.  That
            # execution is not byte-for-byte the public replay recipe, so this
            # interim adapter must not promote the conformance row.
            "outcome": "not_run",
            "required": True,
        }
        for identifier in sorted(REQUIRED_CONFORMANCE_IDS)
    ]
    compiled = {
        "authMode": account["authMode"],
        "conformance": conformance,
        "identityBinding": {
            "bindingId": live_identity["bindingId"],
            "evidence": live_identity["evidence"],
            "generation": live_identity["generation"],
            "status": live_identity["status"],
        },
        "linear": _default_linear(),
        "matrixOutcomes": matrix_outcomes,
        "models": models,
        "platform": {
            "architecture": expected_architecture,
            "os": expected_os,
            "osStatus": "pass",
            "package": SUPPORTED_RELEASE_PACKAGE,
            "packageStatus": "pending",
        },
        "quota": {
            "fullRead": quota_full,
            "multiBucket": quota_multi,
            "sparseUpdate": "not_run",
            "usage": quota_usage,
        },
        "referenceProfile": report["referenceProfile"],
        "reportVersion": 1,
        "subagents": {
            "hookFailureClassification": "not_run",
            "implementation": "multi_agent_v2",
            "nativeDepthEnforcement": False,
            "rawToOptionalChildren": list(EXPECTED_CAP_MAPPING),
            "rootCountsTowardLimit": True,
            "studioDepthGuardRequired": True,
            "trustedGuardStatus": "not_run",
        },
    }
    return _new_verified_public_report(_validate_public_report(compiled), live_evidence)


def _new_full_verified_public_report(
    report: Mapping[str, Any], evidence: FullGateEvidence
) -> VerifiedPublicReport:
    if not isinstance(evidence, FullGateEvidence):
        raise ReadinessError("full verified report requires trusted gate evidence")
    value = object.__new__(VerifiedPublicReport)
    value._VerifiedPublicReport__report = copy.deepcopy(
        _mapping(report, "full verified public report")
    )
    return value


def _decode_prefixed_record(payload: bytes, prefix: str, label: str) -> dict[str, Any]:
    try:
        lines = payload.decode("utf-8").splitlines()
    except UnicodeDecodeError as error:
        raise ReadinessError(f"{label} output is not UTF-8") from error
    while lines and not lines[-1].strip():
        lines.pop()
    if not lines or not lines[-1].startswith(prefix):
        raise ReadinessError(f"{label} final line is not its strict prefixed record")
    record = lines[-1][len(prefix) :]
    if not record.startswith("{"):
        raise ReadinessError(f"{label} final record is not a JSON object")
    for line in lines[:-1]:
        if line.startswith(prefix):
            raise ReadinessError(f"{label} emitted duplicate prefixed records")
        if not any(pattern.fullmatch(line) for pattern in KNOWN_MIX_PREAMBLE):
            raise ReadinessError(f"{label} emitted unexpected public output")
    return _mapping(
        decode_json_bytes(record.encode("utf-8"), label), label
    )


def _source_binding_without_codex(repo_root: Path) -> dict[str, Any]:
    version = _read_regular_bytes(repo_root / "CODEX_VERSION", 1024).decode("utf-8").strip()
    schema_relative = _schema_manifest_relative(version)
    schema = _mapping(
        read_json_bounded(repo_root / schema_relative), "probe schema manifest"
    )
    return index_source_basis(repo_root, schema, schema_relative)


def _normalize_linear_task_report(value: Mapping[str, Any]) -> dict[str, Any]:
    """Validate the probe and retain only safe capability/evidence semantics."""

    report = copy.deepcopy(_mapping(value, "Linear task report"))
    _exact_keys(
        report,
        {
            "configuredProjectBindingGeneration",
            "reportVersion",
            *LINEAR_KEYS,
        },
        "Linear task report",
    )
    if report["reportVersion"] != 1:
        raise ReadinessError("unsupported Linear task report version")
    if report["configuredProjectBindingGeneration"] != LINEAR_BINDING_GENERATION:
        raise ReadinessError("unsupported Linear configured-project binding generation")
    binding = report["configuredProjectBinding"]
    if not isinstance(binding, str) or not LINEAR_BINDING_RE.fullmatch(binding):
        raise ReadinessError("Linear task configured project binding is invalid")
    public: dict[str, Any] = {"configuredProjectBinding": binding}
    for key in LINEAR_STATUS_KEYS_IN_PROBE_ORDER:
        row = _mapping(report[key], f"Linear task {key}")
        if key == "mutations" and set(row) == LINEAR_MUTATION_PROBE_ROW_KEYS:
            if row["evidence"] != "schema_only":
                raise ReadinessError("Linear mutation evidence is not schema-only")
            status = _enum(
                row["status"], {"blocked", "pass"}, "Linear task mutations status"
            )
            expected_reason = {
                "blocked": "mutation_schema_mismatch",
                "pass": "schema_verified",
            }[status]
            if row["reason"] != expected_reason:
                raise ReadinessError("Linear mutation schema reason/status pair is inconsistent")
            public[key] = {"evidence": "schema_only", "status": status}
        else:
            _exact_keys(row, LINEAR_PROBE_STATUS_ROW_KEYS, f"Linear task {key}")
            status = _enum(
                row["status"], {"blocked", "pass"}, f"Linear task {key} status"
            )
            reason = _enum(
                row["reason"], LINEAR_PROBE_REASONS, f"Linear task {key} reason"
            )
            if (status, reason) != ("pass", "verified") and (
                status == "pass" or reason == "verified"
            ):
                raise ReadinessError(
                    f"Linear task {key} reason/status pair is inconsistent"
                )
            if key == "mutations" and status == "pass":
                raise ReadinessError(
                    "passing Linear mutations require explicit schema-only evidence"
                )
            public[key] = (
                {"evidence": "unavailable", "status": status}
                if key == "mutations"
                else {"status": status}
            )
    _assert_public_tree(public, "Linear public capabilities")
    return public


def build_linear_probe_record(
    repo_root: Path, mise_command: str = "mise"
) -> dict[str, Any]:
    """Compile credential-free, then run one sealed query-only Linear task."""

    repo_root = Path(repo_root).resolve(strict=True)
    assert_no_unstaged_source(repo_root)
    source_before = _source_binding_without_codex(repo_root)
    index_tree = _git_text(repo_root, ["write-tree"])
    index_entries = _parse_index_entries(repo_root)
    metadata_fingerprint = _git_metadata_fingerprint(repo_root)
    mise = _require_public_launcher_selector(mise_command, "mise", "mise")
    mise_sha = sha256_regular_file(mise, 128 * 1024 * 1024)
    codex_path = _require_public_launcher_selector("codex", "codex", "Codex")
    with _gate_temporary_directory() as temporary:
        temporary_root = Path(temporary)
        snapshot = temporary_root / "snapshot"
        snapshot.mkdir(mode=0o700)
        (temporary_root / "tmp").mkdir(mode=0o700)
        _run_git(
            repo_root,
            ["checkout-index", "--all", "--force", f"--prefix={snapshot}{os.sep}"],
            timeout=LIVE_CHECKOUT_TIMEOUT_SECONDS,
        )
        snapshot_fingerprint = _inspect_source_bound_snapshot(
            snapshot, index_entries, source_before
        )
        sandbox = _prepare_gate_sandbox(
            repo_root,
            snapshot,
            temporary_root,
            index_tree,
            codex_path,
            index_entries,
        )
        _run_gate_sandbox_canary(repo_root, sandbox, metadata_fingerprint)
        erlexec_fingerprint, dependency_fingerprint, build_fingerprint = (
            _bootstrap_private_gate_dependencies(sandbox)
        )
        credential_runtime_fingerprint = _private_credential_runtime_fingerprint(
            sandbox
        )
        supervisor_seal = _seal_live_supervisor_runtime(
            repo_root,
            sandbox,
            index_tree=index_tree,
        )
        returncode, stdout, stderr = _execute_sealed_linear_gate(
            repo_root,
            sandbox,
            source_before["sha256"],
            index_tree,
            supervisor_seal,
            build_fingerprint,
            credential_runtime_fingerprint,
        )
        if returncode != 0 or stderr.strip():
            raise ReadinessError("sealed Linear capability task did not complete cleanly")
        record = _mapping(
            _decode_prefixed_record(
                stdout, LINEAR_PROBE_JSON_PREFIX, "Linear public probe"
            ),
            "Linear public probe",
        )
        validate_linear_probe_record(record, source_before["sha256"])
        _remove_gate_output_mountpoints(snapshot, index_entries)
        if (
            _inspect_private_erlexec_source(
                sandbox.erlexec_source,
                sandbox.erlexec_tracked,
                normalize_generated=True,
                require_compiled=True,
            )
            != erlexec_fingerprint
            or _private_dependency_fingerprint(sandbox) != dependency_fingerprint
            or _private_gate_build_fingerprint(sandbox) != build_fingerprint
            or _inspect_source_bound_snapshot(
                snapshot, index_entries, source_before
            )
            != snapshot_fingerprint
        ):
            raise ReadinessError("sealed Linear preparation inputs changed")
    if sha256_regular_file(mise, 128 * 1024 * 1024) != mise_sha:
        raise ReadinessError("mise executable changed during Linear discovery")
    source_after = _source_binding_without_codex(repo_root)
    if source_after != source_before or _git_text(repo_root, ["write-tree"]) != index_tree:
        raise ReadinessError("staged source changed during Linear discovery")
    return copy.deepcopy(record)


def validate_linear_probe_record(
    value: Mapping[str, Any], expected_source_sha256: str
) -> dict[str, Any]:
    record = copy.deepcopy(_mapping(value, "Linear probe record"))
    expected_keys = {"reportVersion", "sourceSha256", *LINEAR_KEYS}
    _exact_keys(record, expected_keys, "Linear probe record")
    if record["reportVersion"] != 1:
        raise ReadinessError("unsupported Linear probe record version")
    if _sha256(record["sourceSha256"], "Linear probe source") != expected_source_sha256:
        raise ReadinessError("Linear probe belongs to a different staged source")
    linear = _normalize_linear(
        {key: record[key] for key in LINEAR_KEYS}, "Linear probe capabilities"
    )
    _assert_public_tree(linear, "Linear probe capabilities")
    return linear


def _archive_index_entries(
    repo_root: Path,
    *,
    git_dir: Path | None = None,
    work_tree: Path | None = None,
    index_file: Path | None = None,
) -> list[tuple[str, int, bytes]]:
    result: list[tuple[str, int, bytes]] = []
    retained_budget = 10_240  # two terminal tar records plus block padding
    for path, mode, object_id in _parse_index_entries(
        repo_root,
        git_dir=git_dir,
        work_tree=work_tree,
        index_file=index_file,
    ):
        if mode not in {"100644", "100755"}:
            raise ReadinessError(f"source archive rejects index mode {mode} for {path}")
        blob = _run_git(
            repo_root,
            ["cat-file", "blob", object_id],
            timeout=60.0,
            git_dir=git_dir,
            work_tree=work_tree,
            index_file=index_file,
        ).stdout
        if len(blob) > MAX_ARCHIVE_BYTES:
            raise ReadinessError(f"source archive entry exceeds its byte bound: {path}")
        # PAX may require an extended path record in addition to the ordinary
        # header. This deliberately conservative accounting rejects before the
        # retained blob list or eventual tar can exceed the package bound.
        retained_budget += len(blob) + 4_096 + 2 * len(path.encode("utf-8"))
        if retained_budget > MAX_ARCHIVE_BYTES:
            raise ReadinessError("source archive aggregate exceeds its byte bound")
        result.append((path, 0o755 if mode == "100755" else 0o644, blob))
    return result


def _write_deterministic_tar(path: Path, entries: Sequence[tuple[str, int, bytes]]) -> None:
    with tarfile.open(path, mode="w", format=tarfile.PAX_FORMAT) as archive:
        for relative, mode, payload in entries:
            safe = _safe_relative_path(relative, "source archive entry")
            info = tarfile.TarInfo(f"symphony-studio/{safe}")
            info.size = len(payload)
            info.mode = mode
            info.mtime = 0
            info.uid = 0
            info.gid = 0
            info.uname = ""
            info.gname = ""
            archive.addfile(info, io.BytesIO(payload))
    if path.stat().st_size > MAX_ARCHIVE_BYTES:
        raise ReadinessError("source archive exceeds its byte bound")


def build_package_probe_record(repo_root: Path) -> dict[str, Any]:
    """Build the exact staged source archive twice and compare canonical bytes."""

    repo_root = Path(os.path.abspath(repo_root))
    source = _source_binding_without_codex(repo_root)
    index_tree = _git_text(repo_root, ["write-tree"])
    entries = _archive_index_entries(repo_root)
    with tempfile.TemporaryDirectory(prefix="symphony-readiness-archive-") as temporary:
        first = Path(temporary) / "first.tar"
        second = Path(temporary) / "second.tar"
        _write_deterministic_tar(first, entries)
        _write_deterministic_tar(second, entries)
        first_bytes = _read_regular_bytes(first, MAX_ARCHIVE_BYTES)
        second_bytes = _read_regular_bytes(second, MAX_ARCHIVE_BYTES)
        if first_bytes != second_bytes:
            raise ReadinessError("source archive reproduction differs byte-for-byte")
        archive_sha = sha256_bytes(first_bytes)
    if _git_text(repo_root, ["write-tree"]) != index_tree:
        raise ReadinessError("Git index changed during source archive rehearsal")
    return {
        "archiveSha256": archive_sha,
        "entryCount": len(entries),
        "indexTree": _commit(index_tree, "source archive index tree"),
        "package": SUPPORTED_RELEASE_PACKAGE,
        "reportVersion": 1,
        "sourceSha256": source["sha256"],
        "status": "pass",
    }


def rehearse_final_pair_source_archive(
    repo_root: Path,
    readiness: Mapping[str, Any],
    paired_schema: Mapping[str, Any],
    expected_source_sha256: str,
    expected_original_index_tree: str,
    *,
    index_file: Path | None = None,
) -> dict[str, Any]:
    """Rehearse the archive from a private index containing the exact final pair."""

    repo_root = Path(repo_root).resolve(strict=True)
    readiness_bytes = canonical_json_bytes(_mapping(readiness, "final readiness pair"))
    schema_bytes = canonical_json_bytes(_mapping(paired_schema, "final schema pair"))
    source = _mapping(readiness["checkout"]["source"], "final readiness source")
    if source["sha256"] != expected_source_sha256:
        raise ReadinessError("final pair archive source binding differs from compilation")
    schema_relative = _safe_relative_path(
        source["schemaManifestPath"], "final pair schema path"
    )
    if (
        _git_text(repo_root, ["write-tree"], index_file=index_file)
        != expected_original_index_tree
    ):
        raise ReadinessError("Git index changed before final pair archive rehearsal")

    with tempfile.TemporaryDirectory(prefix="symphony-readiness-final-archive-") as temporary:
        root = Path(temporary)
        snapshot = root / "snapshot"
        snapshot.mkdir(mode=0o700)
        _run_git(
            repo_root,
            ["checkout-index", "--all", "--force", f"--prefix={snapshot}{os.sep}"],
            timeout=90.0,
            index_file=index_file,
        )
        git_dir = _prepare_private_gate_git(
            repo_root, snapshot, root, expected_original_index_tree
        )
        schema_path = snapshot / schema_relative
        readiness_path = snapshot / READINESS_RELATIVE
        _private_directory(readiness_path.parent)
        for path, payload in (
            (schema_path, schema_bytes),
            (readiness_path, readiness_bytes),
        ):
            if path.exists():
                metadata = path.lstat()
                if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                    raise ReadinessError("final pair archive destination is not regular")
            with path.open("wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(path, 0o644)
        _run_git(
            snapshot,
            ["add", "--all", "--force", "--", schema_relative, READINESS_RELATIVE],
            timeout=90.0,
            git_dir=git_dir,
            work_tree=snapshot,
        )
        final_tree = _git_text(
            snapshot,
            ["write-tree"],
            git_dir=git_dir,
            work_tree=snapshot,
        )
        pair_modes = {
            path: mode
            for path, mode, _object_id in _parse_index_entries(
                snapshot, git_dir=git_dir, work_tree=snapshot
            )
            if path in {schema_relative, READINESS_RELATIVE}
        }
        if pair_modes != {
            schema_relative: "100644",
            READINESS_RELATIVE: "100644",
        }:
            raise ReadinessError("final readiness pair must use exact 100644 index modes")
        entries = _archive_index_entries(
            snapshot, git_dir=git_dir, work_tree=snapshot
        )
        first_path = root / "final-first.tar"
        second_path = root / "final-second.tar"
        _write_deterministic_tar(first_path, entries)
        _write_deterministic_tar(second_path, entries)
        first = _read_regular_bytes(first_path, MAX_ARCHIVE_BYTES)
        second = _read_regular_bytes(second_path, MAX_ARCHIVE_BYTES)
        if first != second:
            raise ReadinessError("final pair source archive is not reproducible")
        record = {
            "archiveSha256": sha256_bytes(first),
            "entryCount": len(entries),
            "indexTree": final_tree,
            "package": SUPPORTED_RELEASE_PACKAGE,
            "reportVersion": 1,
            "sourceSha256": expected_source_sha256,
            "status": "pass",
        }
        validate_package_probe_record(record, expected_source_sha256, final_tree)
        _assert_public_tree(record, "final pair source archive")
        return record


def validate_package_probe_record(
    value: Mapping[str, Any], expected_source_sha256: str, expected_index_tree: str
) -> dict[str, Any]:
    record = copy.deepcopy(_mapping(value, "package probe record"))
    keys = {
        "archiveSha256",
        "entryCount",
        "indexTree",
        "package",
        "reportVersion",
        "sourceSha256",
        "status",
    }
    _exact_keys(record, keys, "package probe record")
    if record["reportVersion"] != 1:
        raise ReadinessError("unsupported package probe record version")
    _sha256(record["archiveSha256"], "package archive")
    if type(record["entryCount"]) is not int or record["entryCount"] <= 0:
        raise ReadinessError("package probe entryCount must be positive")
    if _commit(record["indexTree"], "package index tree") != expected_index_tree:
        raise ReadinessError("package probe belongs to a different staged tree")
    if _sha256(record["sourceSha256"], "package source") != expected_source_sha256:
        raise ReadinessError("package probe belongs to a different staged source")
    if record["package"] != SUPPORTED_RELEASE_PACKAGE or record["status"] != "pass":
        raise ReadinessError("package probe did not prove the supported source archive")
    _assert_public_tree(record, "package probe record")
    return record


def build_codex_probe_record(
    repo_root: Path, codex_command: str = "codex", mise_command: str = "mise"
) -> dict[str, Any]:
    repo_root = Path(repo_root).resolve(strict=True)
    static, _matrix, _schema = collect_static_basis(repo_root, codex_command)
    index_tree = _git_text(repo_root, ["write-tree"])
    index_entries = _parse_index_entries(repo_root)
    metadata_fingerprint = _git_metadata_fingerprint(repo_root)
    codex_path = _require_public_launcher_selector(
        codex_command, "codex", "Codex"
    )
    mise_path = _require_public_launcher_selector(mise_command, "mise", "mise")
    mise_sha = sha256_regular_file(mise_path, 128 * 1024 * 1024)
    with _gate_temporary_directory() as temporary:
        temporary_root = Path(temporary)
        snapshot = temporary_root / "snapshot"
        snapshot.mkdir(mode=0o700)
        (temporary_root / "tmp").mkdir(mode=0o700)
        _run_git(
            repo_root,
            ["checkout-index", "--all", "--force", f"--prefix={snapshot}{os.sep}"],
            timeout=LIVE_CHECKOUT_TIMEOUT_SECONDS,
        )
        snapshot_fingerprint = _inspect_source_bound_snapshot(
            snapshot, index_entries, static["checkout"]["source"]
        )
        sandbox = _prepare_gate_sandbox(
            repo_root,
            snapshot,
            temporary_root,
            index_tree,
            codex_path,
            index_entries,
        )
        _run_gate_sandbox_canary(repo_root, sandbox, metadata_fingerprint)
        erlexec_fingerprint, dependency_fingerprint, build_fingerprint = (
            _bootstrap_private_gate_dependencies(sandbox)
        )
        credential_runtime_fingerprint = _private_credential_runtime_fingerprint(
            sandbox
        )
        supervisor_seal = _seal_live_supervisor_runtime(
            repo_root,
            sandbox,
            index_tree=index_tree,
        )
        returncode, stdout, stderr = _execute_sealed_codex_gate(
            repo_root,
            sandbox,
            static,
            codex_command,
            index_tree,
            supervisor_seal,
            build_fingerprint,
            credential_runtime_fingerprint,
        )
        if returncode != 0 or stderr.strip():
            raise ReadinessError("sealed Codex capability task did not complete cleanly")
        record = _mapping(
            _decode_prefixed_record(
                stdout, CODEX_PROBE_JSON_PREFIX, "Codex public probe"
            ),
            "Codex public probe",
        )
        validate_codex_probe_record(record, static)
        _remove_gate_output_mountpoints(snapshot, index_entries)
        if (
            _inspect_private_erlexec_source(
                sandbox.erlexec_source,
                sandbox.erlexec_tracked,
                normalize_generated=True,
                require_compiled=True,
            )
            != erlexec_fingerprint
            or _private_dependency_fingerprint(sandbox) != dependency_fingerprint
            or _private_gate_build_fingerprint(sandbox) != build_fingerprint
            or _inspect_source_bound_snapshot(
                snapshot, index_entries, static["checkout"]["source"]
            )
            != snapshot_fingerprint
        ):
            raise ReadinessError("sealed Codex preparation inputs changed")
    after_static, _after_matrix, _after_schema = collect_static_basis(
        repo_root, codex_command
    )
    if after_static != static or _git_text(repo_root, ["write-tree"]) != index_tree:
        raise ReadinessError("staged source changed during sealed Codex discovery")
    if sha256_regular_file(mise_path, 128 * 1024 * 1024) != mise_sha:
        raise ReadinessError("mise executable changed during Codex discovery")
    return copy.deepcopy(record)


def validate_codex_probe_record(
    value: Mapping[str, Any], static_basis: Mapping[str, Any]
) -> LiveCapabilityEvidence:
    record = copy.deepcopy(_mapping(value, "Codex probe record"))
    _exact_keys(
        record,
        {"evidence", "reportVersion", "sourceSha256", "staticBasisSha256"},
        "Codex probe record",
    )
    if record["reportVersion"] != 1:
        raise ReadinessError("unsupported Codex probe record version")
    static = copy.deepcopy(_mapping(static_basis, "Codex probe static basis"))
    _validate_static_basis(static)
    if record["sourceSha256"] != static["checkout"]["source"]["sha256"]:
        raise ReadinessError("Codex probe belongs to a different staged source")
    if record["staticBasisSha256"] != sha256_bytes(canonical_json_bytes(static)):
        raise ReadinessError("Codex probe belongs to a different static basis")
    captured = _mapping(record["evidence"], "Codex captured evidence")
    _exact_keys(
        captured,
        {"envelope", "launcherSha256", "nativeSha256", "staticBasisSha256", "versionOutput"},
        "Codex captured evidence",
    )
    captured["envelope"] = validate_live_capability_envelope(
        _mapping(captured["envelope"], "Codex live envelope"), static["codex"]["version"]
    )
    for key in ("launcherSha256", "nativeSha256", "versionOutput"):
        if captured[key] != static["codex"][key]:
            raise ReadinessError("Codex probe executable evidence differs from the static basis")
    return _new_live_capability_evidence(captured)


def _probe_command(args: argparse.Namespace) -> None:
    repo_root = Path(args.repo_root).resolve(strict=True)
    if args.command == "probe-linear":
        record = build_linear_probe_record(repo_root, args.mise)
        prefix = LINEAR_PROBE_JSON_PREFIX
    elif args.command == "probe-source-archive":
        record = build_package_probe_record(repo_root)
        prefix = PACKAGE_PROBE_JSON_PREFIX
    elif args.command == "probe-codex":
        record = build_codex_probe_record(repo_root, args.codex, args.mise)
        prefix = CODEX_PROBE_JSON_PREFIX
    else:
        raise ReadinessError("unknown readiness probe command")
    _assert_public_tree(record, "public readiness probe record")
    compact = json.dumps(
        record, allow_nan=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")
    sys.stdout.buffer.write(prefix.encode("ascii") + compact + b"\n")


def _resolved_tool_fingerprints(commands: Iterable[Sequence[str]]) -> dict[str, tuple[str, str]]:
    """Resolve and hash each public launcher used by the gate inventory."""

    names = {"git", *(str(command[0]) for command in commands if command)}
    result: dict[str, tuple[str, str]] = {}
    for name in sorted(names):
        resolved = shutil.which(name) if os.sep not in name else name
        if not resolved:
            raise ReadinessError(f"required gate launcher was not found: {name}")
        path = Path(resolved).resolve(strict=True)
        result[name] = (str(path), sha256_regular_file(path, MAX_EXECUTABLE_BYTES))
    return result


def _require_public_launcher_selector(
    selector: str, public_name: str, label: str
) -> Path:
    """Require an override to resolve to the launcher used by canonical argv."""

    public_text = shutil.which(public_name)
    selected_text = shutil.which(selector) if os.sep not in selector else selector
    if not public_text or not selected_text:
        raise ReadinessError(f"{label} executable was not found for the full readiness gate")
    public = Path(public_text).resolve(strict=True)
    selected = Path(selected_text).resolve(strict=True)
    if not public.is_file() or not selected.is_file() or public != selected:
        raise ReadinessError(
            f"{label} selector differs from the exact canonical public launcher"
        )
    return public


SANDBOX_ROOT = "/run/symphony-readiness"
SANDBOX_WORKSPACE = f"{SANDBOX_ROOT}/workspace"
GATE_TEMP_PARENT = Path("/tmp")
IDENTITY_KEY_RELATIVE = "symphony-studio/codex-identity-binding-v1.key"
MAX_SANDBOX_ID = (1 << 31) - 1
SANDBOX_CANARY_OUTPUT = b"SYMPHONY_STUDIO_SANDBOX_ISOLATION=pass\n"
MIX_TOOL_CANARY_OUTPUT = b"SYMPHONY_STUDIO_PRIVATE_MIX_TOOLS=pass\n"
MIX_TOOL_CANARY_SCRIPT = r'''
archives = System.fetch_env!("MIX_ARCHIVES")
rebar = System.fetch_env!("MIX_REBAR3")

unless Mix.path_for(:archives) == archives do
  raise "Mix archive path escaped its private mount"
end

unless Mix.Rebar.env_rebar_path(:rebar3) == rebar and File.regular?(rebar) do
  raise "Mix rebar3 path escaped its private mount"
end

IO.puts("SYMPHONY_STUDIO_PRIVATE_MIX_TOOLS=pass")
'''
SANDBOX_CANARY_SCRIPT = r"""
import errno
import os
from pathlib import Path
import subprocess

allowed = {errno.EACCES, errno.EPERM, errno.EROFS}
source = Path("STUDIO_SPEC.md")
sentinel = Path(".symphony-readiness-mutation-canary")
expected_uid = int(os.environ["SYMPHONY_SANDBOX_UID"])
expected_gid = int(os.environ["SYMPHONY_SANDBOX_GID"])

if os.getresuid() != (expected_uid, expected_uid, expected_uid):
    raise SystemExit("sandbox process identity differs from its captured identity")
if os.getresgid() != (expected_gid, expected_gid, expected_gid):
    raise SystemExit("sandbox process group identity differs from its captured identity")
if any(group not in {expected_gid, 65534} for group in os.getgroups()):
    raise SystemExit("sandbox retained a privileged supplementary group")

status_payload = Path("/proc/self/status").read_bytes()
if len(status_payload) > 128 * 1024:
    raise SystemExit("sandbox process status exceeds its bound")
capabilities = {}
status_ids = {}
for raw_line in status_payload.splitlines():
    if b":" not in raw_line:
        continue
    raw_key, raw_value = raw_line.split(b":", 1)
    if raw_key in {b"Uid", b"Gid"}:
        if raw_key in status_ids:
            raise SystemExit("sandbox process status duplicates an identity field")
        try:
            status_ids[raw_key] = tuple(
                int(part, 10) for part in raw_value.split()
            )
        except ValueError as error:
            raise SystemExit("sandbox process identity field is malformed") from error
    if raw_key in {b"CapInh", b"CapPrm", b"CapEff", b"CapAmb"}:
        if raw_key in capabilities:
            raise SystemExit("sandbox process status duplicates a capability field")
        try:
            capabilities[raw_key] = int(raw_value.strip(), 16)
        except ValueError as error:
            raise SystemExit("sandbox process capability field is malformed") from error
if status_ids != {
    b"Uid": (expected_uid, expected_uid, expected_uid, expected_uid),
    b"Gid": (expected_gid, expected_gid, expected_gid, expected_gid),
}:
    raise SystemExit("sandbox filesystem identity differs from its captured identity")
if capabilities != {
    b"CapInh": 0,
    b"CapPrm": 0,
    b"CapEff": 0,
    b"CapAmb": 0,
}:
    raise SystemExit("sandbox process retained inheritable capabilities")

host_temporary_root = Path(
    os.environ["SYMPHONY_SANDBOX_HOST_TEMPORARY_ROOT"]
)
if host_temporary_root.exists():
    raise SystemExit("sandbox can read its host-side private temporary root")

def must_be_read_only(action):
    try:
        action()
    except OSError as error:
        if error.errno not in allowed:
            raise
    else:
        raise SystemExit("read-only workspace mutation unexpectedly succeeded")

mix_home = Path(os.environ["MIX_HOME"])
if mix_home != Path(os.environ["SYMPHONY_SANDBOX_PRIVATE_MIX_HOME"]):
    raise SystemExit("sandbox did not retain its explicit private MIX_HOME")
if Path(os.environ["MIX_ARCHIVES"]) != mix_home / "archives":
    raise SystemExit("sandbox did not retain its private Mix archive path")
private_rebar = Path(os.environ["MIX_REBAR3"])
if private_rebar.parent.parent.parent != mix_home or private_rebar.name != "rebar3":
    raise SystemExit("sandbox did not retain its private versioned rebar3 path")
for masked_mix_home in (
    Path(os.environ["SYMPHONY_SANDBOX_HOST_MIX_HOME"]),
    Path(os.environ["SYMPHONY_SANDBOX_HOST_MIX_ALIAS"]),
):
    if not masked_mix_home.is_dir() or list(masked_mix_home.iterdir()):
        raise SystemExit("sandbox can read the host Mix home")
must_be_read_only(
    lambda: (mix_home / "dialyxir-host-reuse-canary.plt").write_bytes(b"host")
)
must_be_read_only(
    lambda: os.chmod(private_rebar, 0o600)
)

must_be_read_only(lambda: sentinel.write_text("mutation\n", encoding="utf-8"))
must_be_read_only(lambda: os.chmod(source, 0o600))
must_be_read_only(lambda: os.rename(source, sentinel))

var_tmp = Path("/var/tmp")
if not var_tmp.is_dir() or list(var_tmp.iterdir()):
    raise SystemExit("sandbox can read the host /var/tmp tree")
var_tmp_canary = var_tmp / "symphony-readiness-private-temp-canary"
var_tmp_canary.write_text("private\n", encoding="utf-8")
var_tmp_canary.unlink()
if list(var_tmp.iterdir()):
    raise SystemExit("sandbox private /var/tmp did not return empty")

dev_shm = Path("/dev/shm")
if not dev_shm.is_dir() or list(dev_shm.iterdir()):
    raise SystemExit("sandbox can read the host /dev/shm tree")
dev_shm_canary = dev_shm / "symphony-readiness-private-shm-canary"
dev_shm_canary.write_text("private\n", encoding="utf-8")
dev_shm_canary.unlink()
if list(dev_shm.iterdir()):
    raise SystemExit("sandbox private /dev/shm did not return empty")
for host_device in (Path("/dev/fuse"), Path("/dev/net/tun"), Path("/dev/mqueue")):
    if host_device.exists():
        raise SystemExit("sandbox retained a host device or IPC mount")
private_pts = Path("/dev/pts")
if not private_pts.is_dir() or any(path.name != "ptmx" for path in private_pts.iterdir()):
    raise SystemExit("sandbox retained the host pseudo-terminal tree")

head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
subprocess.run(["git", "config", "symphony.readinessCanary", "private"], check=True)
subprocess.run(["git", "update-ref", "refs/symphony/readiness-canary", head], check=True)
if subprocess.check_output(
    ["git", "config", "--get", "symphony.readinessCanary"], text=True
).strip() != "private":
    raise SystemExit("private Git config mutation was not isolated")
if subprocess.check_output(
    ["git", "rev-parse", "refs/symphony/readiness-canary"], text=True
).strip() != head:
    raise SystemExit("private Git ref mutation was not isolated")
subprocess.run(["git", "update-ref", "-d", "refs/symphony/readiness-canary"], check=True)
subprocess.run(["git", "config", "--unset-all", "symphony.readinessCanary"], check=True)
print("SYMPHONY_STUDIO_SANDBOX_ISOLATION=pass")
"""


def _capture_gate_identity() -> tuple[int, int]:
    """Capture one immutable, bounded non-root identity for the gate namespace."""

    sandbox_uid = os.getuid()
    sandbox_gid = os.getgid()
    getresuid = getattr(os, "getresuid", None)
    getresgid = getattr(os, "getresgid", None)
    if not callable(getresuid) or not callable(getresgid):
        raise ReadinessError("gate isolation requires saved-identity inspection")
    user_ids = getresuid()
    group_ids = getresgid()
    if (
        type(sandbox_uid) is not int
        or type(sandbox_gid) is not int
        or not 0 < sandbox_uid <= MAX_SANDBOX_ID
        or not 0 < sandbox_gid <= MAX_SANDBOX_ID
        or user_ids != (sandbox_uid, sandbox_uid, sandbox_uid)
        or group_ids != (sandbox_gid, sandbox_gid, sandbox_gid)
    ):
        raise ReadinessError("gate isolation requires a proven non-root host identity")
    _require_safe_process_status(
        _read_process_status(), sandbox_uid, sandbox_gid
    )
    return sandbox_uid, sandbox_gid


def _live_supervisor_boundary(
    repo_root: Path,
) -> tuple[Path, Path, tuple[int, ...]] | None:
    """Validate the credential-blind publisher's narrow external boundary."""

    raw_socket = os.environ.get(LIVE_SUPERVISOR_SOCKET_ENVIRONMENT_KEY)
    raw_shared = os.environ.get(LIVE_SUPERVISOR_SHARED_PARENT_ENVIRONMENT_KEY)
    if raw_socket is None and raw_shared is None:
        return None
    if (
        raw_socket != str(LIVE_SUPERVISOR_SOCKET_PATH)
        or raw_shared != str(LIVE_SUPERVISOR_SHARED_PARENT)
    ):
        raise ReadinessError("live capability supervisor boundary is invalid")
    socket_path = LIVE_SUPERVISOR_SOCKET_PATH
    shared_parent = LIVE_SUPERVISOR_SHARED_PARENT
    boundary_parent = socket_path.parent
    try:
        boundary_metadata = boundary_parent.lstat()
        shared_metadata = shared_parent.lstat()
        socket_metadata = socket_path.lstat()
        canonical_parent = boundary_parent.resolve(strict=True)
        canonical_shared = shared_parent.resolve(strict=True)
        canonical_repo = repo_root.resolve(strict=True)
    except OSError as error:
        raise ReadinessError("live capability supervisor is unavailable") from error
    if canonical_parent != boundary_parent or canonical_shared != shared_parent:
        raise ReadinessError("live capability supervisor boundary is not canonical")
    try:
        canonical_parent.relative_to(canonical_repo)
    except ValueError:
        pass
    else:
        raise ReadinessError("live capability supervisor entered the repository")
    owner = os.getuid()
    group = os.getgid()
    if (
        stat.S_ISLNK(boundary_metadata.st_mode)
        or not stat.S_ISDIR(boundary_metadata.st_mode)
        or stat.S_IMODE(boundary_metadata.st_mode) != 0o700
        or boundary_metadata.st_uid != owner
        or boundary_metadata.st_gid != group
        or stat.S_ISLNK(shared_metadata.st_mode)
        or not stat.S_ISDIR(shared_metadata.st_mode)
        or stat.S_IMODE(shared_metadata.st_mode) != 0o700
        or shared_metadata.st_uid != owner
        or shared_metadata.st_gid != group
        or stat.S_ISLNK(socket_metadata.st_mode)
        or not stat.S_ISSOCK(socket_metadata.st_mode)
        or stat.S_IMODE(socket_metadata.st_mode) != 0o600
        or socket_metadata.st_uid != owner
        or socket_metadata.st_gid != group
        or socket_metadata.st_nlink != 1
    ):
        raise ReadinessError("live capability supervisor metadata is invalid")
    fingerprint = (
        boundary_metadata.st_dev,
        boundary_metadata.st_ino,
        boundary_metadata.st_mode,
        boundary_metadata.st_uid,
        boundary_metadata.st_gid,
        shared_metadata.st_dev,
        shared_metadata.st_ino,
        shared_metadata.st_mode,
        shared_metadata.st_uid,
        shared_metadata.st_gid,
        socket_metadata.st_dev,
        socket_metadata.st_ino,
        socket_metadata.st_mode,
        socket_metadata.st_uid,
        socket_metadata.st_gid,
        socket_metadata.st_nlink,
    )
    return socket_path, shared_parent, fingerprint


def _gate_temporary_directory():
    """Create private gate state beneath a masked or supervisor-shared parent."""

    boundary = _live_supervisor_boundary(REPO_ROOT)
    parent = boundary[1] if boundary is not None else GATE_TEMP_PARENT
    metadata = parent.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise ReadinessError("gate temporary parent is not a real directory")
    return tempfile.TemporaryDirectory(
        prefix="symphony-readiness-full-", dir=parent
    )


def _read_process_status() -> bytes:
    return _read_regular_bytes(Path("/proc/self/status"), 128 * 1024)


def _require_safe_process_status(
    payload: bytes, expected_uid: int, expected_gid: int
) -> None:
    """Reject elevated filesystem identities or raiseable Linux capabilities."""

    if not isinstance(payload, bytes) or len(payload) > 128 * 1024:
        raise ReadinessError("host process status exceeds its bound")
    capabilities: dict[bytes, int] = {}
    status_ids: dict[bytes, tuple[int, ...]] = {}
    for line in payload.splitlines():
        if b":" not in line:
            continue
        raw_key, raw_value = line.split(b":", 1)
        if raw_key in {b"Uid", b"Gid"}:
            if raw_key in status_ids:
                raise ReadinessError("host process status duplicates an identity field")
            try:
                status_ids[raw_key] = tuple(
                    int(part, 10) for part in raw_value.split()
                )
            except ValueError as error:
                raise ReadinessError("host process identity field is malformed") from error
            continue
        if raw_key not in {b"CapInh", b"CapPrm", b"CapEff", b"CapAmb"}:
            continue
        if raw_key in capabilities:
            raise ReadinessError("host process status duplicates a capability field")
        try:
            capabilities[raw_key] = int(raw_value.strip(), 16)
        except ValueError as error:
            raise ReadinessError("host process capability field is malformed") from error
    if status_ids != {
        b"Uid": (expected_uid, expected_uid, expected_uid, expected_uid),
        b"Gid": (expected_gid, expected_gid, expected_gid, expected_gid),
    }:
        raise ReadinessError("gate isolation requires equal filesystem identities")
    if capabilities != {
        b"CapInh": 0,
        b"CapPrm": 0,
        b"CapEff": 0,
        b"CapAmb": 0,
    }:
        raise ReadinessError("gate isolation requires zero raiseable capabilities")


def _outer_gate_private_mix_environment(repo_root: Path) -> dict[str, str]:
    """Reuse only the outer gate's already-verified read-only Mix tools."""

    marker = os.environ.get("SYMPHONY_READINESS_OUTER_SANDBOX")
    if marker is None:
        return {}
    if marker != "1":
        raise ReadinessError("outer readiness sandbox marker is invalid")
    try:
        resolved_repo = Path(repo_root).resolve(strict=True)
        resolved_cwd = Path.cwd().resolve(strict=True)
    except OSError as error:
        raise ReadinessError("outer readiness sandbox path is unavailable") from error
    expected_workspace = Path(SANDBOX_WORKSPACE)
    expected_working_directories = {
        expected_workspace,
        expected_workspace / "elixir",
    }
    if (
        resolved_repo != expected_workspace
        or resolved_cwd not in expected_working_directories
    ):
        raise ReadinessError("outer readiness sandbox workspace is not canonical")

    sandbox_uid, sandbox_gid = _capture_gate_identity()
    if (
        os.environ.get("SYMPHONY_SANDBOX_UID") != str(sandbox_uid)
        or os.environ.get("SYMPHONY_SANDBOX_GID") != str(sandbox_gid)
    ):
        raise ReadinessError("outer readiness sandbox identity is not bound")

    mix_home = Path(f"{SANDBOX_ROOT}/mix-home")
    mix_archives = mix_home / "archives"
    rebar_text = os.environ.get("MIX_REBAR3")
    expected = {
        "MIX_HOME": str(mix_home),
        "MIX_ARCHIVES": str(mix_archives),
    }
    if any(os.environ.get(key) != value for key, value in expected.items()):
        raise ReadinessError("outer readiness sandbox Mix paths are not canonical")
    if not rebar_text:
        raise ReadinessError("outer readiness sandbox rebar path is unavailable")
    rebar = Path(rebar_text)
    if (
        not rebar.is_absolute()
        or rebar.name != "rebar3"
        or rebar.parent.parent != mix_home / "elixir"
    ):
        raise ReadinessError("outer readiness sandbox rebar path is not canonical")
    rebar_version = _identifier(
        rebar.parent.name, "outer readiness sandbox rebar version"
    )
    _inspect_private_mix_tools(mix_home, rebar_version)
    return {**expected, "MIX_REBAR3": str(rebar)}


def _selected_live_host_home() -> Path:
    host_home_text = os.environ.get("HOME")
    if not host_home_text or not Path(host_home_text).is_absolute():
        raise ReadinessError("live capability discovery requires an absolute HOME")
    return Path(host_home_text)


def _selected_auth_file_path(host_home: Path) -> Path:
    configured = os.environ.get("CODEX_HOME")
    if configured:
        codex_home = Path(configured)
        if not codex_home.is_absolute():
            raise ReadinessError(
                "live capability discovery requires an absolute Codex home"
            )
    else:
        codex_home = host_home / ".codex"
    return codex_home / "auth.json"


def _selected_live_secret_sources(host_home: Path) -> tuple[Path, Path]:
    """Capture credential source paths before any network-capable child runs."""

    return _selected_auth_file_path(host_home), _selected_identity_key_path(host_home)


def _prepare_private_live_environment(
    root: Path, *, host_home: Path | None = None
) -> dict[str, str]:
    """Prepare a credential-free private tool/cache environment."""

    _private_directory(root)
    host_home = host_home or _selected_live_host_home()
    if not host_home.is_absolute():
        raise ReadinessError("live capability discovery requires an absolute HOME")
    host_mise_data = Path(
        os.environ.get("MISE_DATA_DIR", str(host_home / ".local/share/mise"))
    )
    if not host_mise_data.is_absolute():
        raise ReadinessError("live capability discovery requires an absolute mise data path")
    try:
        host_mise_data = host_mise_data.resolve(strict=True)
    except OSError as error:
        raise ReadinessError("live capability discovery requires installed mise data") from error
    if not host_mise_data.is_dir():
        raise ReadinessError("live capability discovery requires installed mise data")
    directories = {
        name: root / name
        for name in (
            "home",
            "hex-home",
            "xdg-cache",
            "xdg-config",
            "xdg-data",
            "xdg-state",
            "mise-cache",
            "mise-config",
            "mise-state",
            "tmp",
        )
    }
    for path in directories.values():
        _private_directory(path)
    source_hex = Path(os.environ.get("HEX_HOME", str(host_home / ".hex")))
    _copy_private_regular_tree(
        source_hex / "packages", directories["hex-home"] / "packages"
    )
    _copy_private_regular(
        source_hex / "cache.ets",
        directories["hex-home"] / "cache.ets",
        MAX_HEX_CACHE_BYTES,
    )
    allowed = {
        "ALL_PROXY",
        "HTTPS_PROXY",
        "HTTP_PROXY",
        "LOGNAME",
        "NO_PROXY",
        "PATH",
        "SSL_CERT_DIR",
        "SSL_CERT_FILE",
        "TERM",
        "USER",
        "all_proxy",
        "http_proxy",
        "https_proxy",
        "no_proxy",
    }
    environment = {key: value for key, value in os.environ.items() if key in allowed}
    environment.update(
        {
            "ERL_CRASH_DUMP": str(directories["tmp"] / "erl_crash.dump"),
            "HEX_HOME": str(directories["hex-home"]),
            "HEX_OFFLINE": "1",
            "HOME": str(directories["home"]),
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "MISE_CACHE_DIR": str(directories["mise-cache"]),
            "MISE_CONFIG_DIR": str(directories["mise-config"]),
            "MISE_DATA_DIR": str(host_mise_data),
            "MISE_OFFLINE": "1",
            "MISE_STATE_DIR": str(directories["mise-state"]),
            "NO_COLOR": "1",
            "TMPDIR": str(directories["tmp"]),
            "TZ": "UTC",
            "XDG_CACHE_HOME": str(directories["xdg-cache"]),
            "XDG_CONFIG_HOME": str(directories["xdg-config"]),
            "XDG_DATA_HOME": str(directories["xdg-data"]),
            "XDG_STATE_HOME": str(directories["xdg-state"]),
        }
    )
    return environment


def _install_private_live_credentials(
    auth_source: Path,
    identity_source: Path,
    credential_root: Path,
    *,
    forbidden_roots: Sequence[Path] = (),
) -> dict[str, str] | None:
    """Install verified auth inputs only after credential-free setup completes."""

    auth_payload = _verified_secret_payload(
        auth_source,
        forbidden_roots=forbidden_roots,
        maximum_bytes=MAX_JSON_BYTES,
    )
    identity_payload = _verified_secret_payload(
        identity_source,
        forbidden_roots=forbidden_roots,
        maximum_bytes=32,
        exact_bytes=32,
    )
    if auth_payload is None or identity_payload is None:
        return None
    if credential_root.exists() or credential_root.is_symlink():
        raise ReadinessError("private live credential root is not fresh")
    try:
        _private_directory(credential_root)
        codex_home = credential_root / "codex-home"
        state_home = credential_root / "xdg-state"
        _write_private_secret(codex_home / "auth.json", auth_payload)
        _write_private_secret(state_home / IDENTITY_KEY_RELATIVE, identity_payload)
    except Exception as error:
        try:
            if credential_root.is_symlink():
                raise ReadinessError(
                    "partial private live credential root became a symlink"
                )
            if credential_root.exists():
                shutil.rmtree(credential_root)
        except (OSError, ReadinessError) as cleanup_error:
            raise ReadinessError(
                "cannot clean partial private live credentials"
            ) from cleanup_error
        if credential_root.exists() or credential_root.is_symlink():
            raise ReadinessError(
                "partial private live credential cleanup failed"
            ) from error
        raise
    return {
        "CODEX_HOME": str(codex_home),
        "XDG_STATE_HOME": str(state_home),
    }


def _private_directory(path: Path) -> None:
    path.mkdir(parents=True, mode=0o700, exist_ok=True)
    os.chmod(path, 0o700)


def _bounded_tree_paths(
    root: Path, maximum_entries: int, label: str
) -> list[Path]:
    """Return a deterministically sorted tree without unbounded materialization."""

    if type(maximum_entries) is not int or maximum_entries < 0:
        raise ReadinessError(f"{label} entry bound is invalid")
    result: list[Path] = []
    pending = [root]
    while pending:
        directory = pending.pop()
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    if len(result) >= maximum_entries:
                        raise ReadinessError(f"{label} contains too many entries")
                    path = Path(entry.path)
                    result.append(path)
                    try:
                        metadata = entry.stat(follow_symlinks=False)
                    except OSError as error:
                        raise ReadinessError(
                            f"cannot inspect bounded {label} entry"
                        ) from error
                    if stat.S_ISDIR(metadata.st_mode):
                        pending.append(path)
        except ReadinessError:
            raise
        except OSError as error:
            raise ReadinessError(f"cannot traverse bounded {label}") from error
    return sorted(result)


def _copy_private_regular(source: Path, destination: Path, maximum: int) -> bool:
    try:
        metadata = source.lstat()
    except FileNotFoundError:
        return False
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise ReadinessError(f"private gate input is not a regular file: {source}")
    payload = _read_regular_bytes(source, maximum)
    try:
        after = source.lstat()
    except OSError as error:
        raise ReadinessError(f"private gate input changed while copied: {source}") from error
    identity = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_size,
        value.st_mtime_ns,
    )
    if identity(after) != identity(metadata):
        raise ReadinessError(f"private gate input changed while copied: {source}")
    _private_directory(destination.parent)
    with destination.open("xb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(destination, 0o600)
    return True


def _forbidden_secret_roots(repo_root: Path) -> tuple[Path, ...]:
    """R0 supports repository-owned WORKFLOW.md, so the repo root covers it."""

    canonical_repo = repo_root.resolve(strict=True)
    roots = {canonical_repo}
    for relative in ("WORKFLOW.md", "elixir/WORKFLOW.md"):
        workflow = canonical_repo / relative
        if workflow.is_file():
            roots.add(workflow.parent.resolve(strict=True))
    return tuple(sorted(roots, key=str))


def _selected_identity_key_path(host_home: Path) -> Path:
    configured = os.environ.get("XDG_STATE_HOME")
    state_home = (
        Path(configured)
        if configured and Path(configured).is_absolute()
        else host_home / ".local/state"
    )
    return state_home / IDENTITY_KEY_RELATIVE


def _verified_secret_payload(
    source: Path,
    *,
    forbidden_roots: Sequence[Path],
    maximum_bytes: int,
    exact_bytes: int | None = None,
) -> bytes | None:
    """Read one stable private secret without laundering path/mode violations."""

    if not source.is_absolute():
        return None
    lexical = Path(os.path.abspath(source))
    owner_uid = os.getuid()
    try:
        canonical = source.resolve(strict=True)
        parent_metadata = source.parent.lstat()
        before = source.lstat()
    except OSError:
        return None
    if canonical != lexical:
        return None
    for forbidden in forbidden_roots:
        try:
            canonical_forbidden = forbidden.resolve(strict=True)
            canonical.relative_to(canonical_forbidden)
        except ValueError:
            continue
        except OSError:
            return None
        else:
            return None
    if (
        stat.S_ISLNK(parent_metadata.st_mode)
        or not stat.S_ISDIR(parent_metadata.st_mode)
        or stat.S_IMODE(parent_metadata.st_mode) != 0o700
        or parent_metadata.st_uid != owner_uid
        or stat.S_ISLNK(before.st_mode)
        or not stat.S_ISREG(before.st_mode)
        or stat.S_IMODE(before.st_mode) != 0o600
        or before.st_uid != owner_uid
        or before.st_size <= 0
        or before.st_size > maximum_bytes
        or (exact_bytes is not None and before.st_size != exact_bytes)
    ):
        return None
    try:
        payload = _read_regular_bytes(source, maximum_bytes)
        after = source.lstat()
        canonical_after = source.resolve(strict=True)
    except (OSError, ReadinessError):
        return None
    identity = lambda metadata: (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_gid,
        metadata.st_size,
        metadata.st_mtime_ns,
    )
    if (
        (exact_bytes is not None and len(payload) != exact_bytes)
        or identity(after) != identity(before)
        or canonical_after != canonical
    ):
        return None
    return payload


def _write_private_secret(destination: Path, payload: bytes) -> None:
    _private_directory(destination.parent)
    try:
        with destination.open("xb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(destination, 0o600)
    except OSError as error:
        raise ReadinessError("cannot copy verified secret input privately") from error


def _copy_verified_identity_key(
    host_home: Path,
    destination: Path,
    *,
    forbidden_roots: Sequence[Path] = (),
) -> bool:
    """Copy a key only when the source meets IdentityBinding's exact invariants."""

    payload = _verified_secret_payload(
        _selected_identity_key_path(host_home),
        forbidden_roots=forbidden_roots,
        maximum_bytes=32,
        exact_bytes=32,
    )
    if payload is None:
        return False
    _write_private_secret(destination, payload)
    return True


def _copy_verified_auth_file(
    host_home: Path,
    destination: Path,
    *,
    forbidden_roots: Sequence[Path] = (),
) -> bool:
    configured = os.environ.get("CODEX_HOME")
    if configured:
        codex_home = Path(configured)
        if not codex_home.is_absolute():
            return False
    else:
        codex_home = host_home / ".codex"
    payload = _verified_secret_payload(
        codex_home / "auth.json",
        forbidden_roots=forbidden_roots,
        maximum_bytes=MAX_JSON_BYTES,
    )
    if payload is None:
        return False
    _write_private_secret(destination, payload)
    return True


def _copy_private_regular_tree(
    source: Path, destination: Path, *, maximum_bytes: int = 256 * 1024 * 1024
) -> None:
    """Copy a bounded cache subset without following links or special files."""

    try:
        root_metadata = source.lstat()
    except FileNotFoundError:
        _private_directory(destination)
        return
    if stat.S_ISLNK(root_metadata.st_mode) or not stat.S_ISDIR(root_metadata.st_mode):
        raise ReadinessError(f"private gate cache is not a directory: {source}")
    _private_directory(destination)
    total = 0
    for child in _bounded_tree_paths(source, 20_000, "private gate cache"):
        relative = child.relative_to(source)
        target = destination / relative
        metadata = child.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise ReadinessError(f"private gate cache contains a symlink: {child}")
        if stat.S_ISDIR(metadata.st_mode):
            _private_directory(target)
            continue
        if not stat.S_ISREG(metadata.st_mode):
            raise ReadinessError(f"private gate cache contains a special file: {child}")
        total += metadata.st_size
        if total > maximum_bytes:
            raise ReadinessError("private gate cache exceeds its aggregate byte bound")
        _copy_private_regular(child, target, max(metadata.st_size, 1))


def _prepare_private_gate_git(
    repo_root: Path, snapshot: Path, temporary_root: Path, index_tree: str
) -> Path:
    git_dir = temporary_root / "git-mirror"
    _run_git(
        repo_root,
        [
            "clone",
            "--mirror",
            "--no-local",
            "--",
            str(repo_root),
            str(git_dir),
        ],
        timeout=180.0,
    )
    _run_git(snapshot, ["config", "core.bare", "false"], git_dir=git_dir)
    _run_git(
        snapshot,
        ["config", "--remove-section", "remote.origin"],
        check=False,
        git_dir=git_dir,
    )
    alternates = git_dir / "objects/info/alternates"
    if alternates.exists():
        raise ReadinessError("private gate Git metadata unexpectedly shares an object store")
    _run_git(
        snapshot,
        ["add", "--all", "--force", "--"],
        timeout=180.0,
        git_dir=git_dir,
        work_tree=snapshot,
    )
    private_tree = _git_text(
        snapshot,
        ["write-tree"],
        git_dir=git_dir,
        work_tree=snapshot,
    )
    if private_tree != index_tree:
        raise ReadinessError("private gate Git index differs from the captured staged tree")
    return git_dir


def _git_metadata_fingerprint(
    repo_root: Path,
    *,
    git_dir: Path | None = None,
    work_tree: Path | None = None,
) -> str:
    # Raw index bytes contain mutable stat/cache-tree accelerators; read-only
    # commands such as `git status` may refresh those without changing staged
    # semantics.  Hash the stable entry/mode/OID/stage/flag projection instead.
    index_entries = _run_git(
        repo_root,
        ["ls-files", "--stage", "-v", "-z"],
        git_dir=git_dir,
        work_tree=work_tree,
    ).stdout
    refs = _run_git(
        repo_root,
        ["for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)"],
        git_dir=git_dir,
        work_tree=work_tree,
    ).stdout
    config = _run_git(
        repo_root,
        ["config", "--local", "--null", "--list"],
        git_dir=git_dir,
        work_tree=work_tree,
    ).stdout
    head = _run_git(
        repo_root,
        ["symbolic-ref", "-q", "HEAD"],
        check=False,
        git_dir=git_dir,
        work_tree=work_tree,
    ).stdout
    head_oid = _run_git(
        repo_root,
        ["rev-parse", "--verify", "HEAD"],
        git_dir=git_dir,
        work_tree=work_tree,
    ).stdout
    return sha256_bytes(
        _length_prefixed((index_entries, refs, config, head, head_oid))
    )


ERLEXEC_ARCH_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+\-]{0,127}\Z")
GATE_COVER_FILE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+\-]{0,254}\.html\Z")
MISE_ELIXIR_VERSION_RE = re.compile(
    r"(?P<major>[0-9]+)\.(?P<minor>[0-9]+)\.[0-9]+-otp-(?P<otp>[0-9]+)\Z"
)
MISE_ERLANG_VERSION_RE = re.compile(r"[0-9]+(?:\.[0-9]+){0,2}\Z")
MIX_REBAR_VERSION_RE = re.compile(r"[0-9]+-[0-9]+-otp-[0-9]+\Z")
HEX_ARCHIVE_RE = re.compile(
    r"hex-(?P<version>[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.\-]+)?)\Z"
)
CORE_ERLANG_PLT_RE = re.compile(
    r"dialyxir_erlang-(?P<otp>[0-9]+(?:\.[0-9]+)*)\.plt\Z"
)
CORE_ELIXIR_PLT_RE = re.compile(
    r"dialyxir_erlang-(?P<otp>[0-9]+(?:\.[0-9]+)*)_elixir-"
    r"(?P<elixir>[0-9]+(?:\.[0-9]+)*)\.plt\Z"
)
DEPS_DEV_PLT_RE = re.compile(
    r"dev/dialyxir_erlang-(?P<otp>[0-9]+(?:\.[0-9]+)*)_elixir-"
    r"(?P<elixir>[0-9]+(?:\.[0-9]+)*)_deps-dev\.plt\Z"
)


def _mise_elixir_tool_contract(snapshot: Path) -> tuple[str, str, str]:
    """Return the exact pinned mise Erlang/Elixir and Mix rebar versions."""

    payload = _read_regular_bytes(snapshot / "elixir/mise.toml", 64 * 1024)
    try:
        document = tomllib.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, tomllib.TOMLDecodeError) as error:
        raise ReadinessError("staged mise Elixir tool contract is malformed") from error
    tools = document.get("tools")
    version = tools.get("elixir") if isinstance(tools, dict) else None
    erlang_version = tools.get("erlang") if isinstance(tools, dict) else None
    if not isinstance(version, str):
        raise ReadinessError("staged mise Elixir version is unavailable")
    if not isinstance(erlang_version, str):
        raise ReadinessError("staged mise Erlang version is unavailable")
    match = MISE_ELIXIR_VERSION_RE.fullmatch(version)
    if match is None:
        raise ReadinessError("staged mise Elixir version is not pinned canonically")
    if (
        MISE_ERLANG_VERSION_RE.fullmatch(erlang_version) is None
        or erlang_version.split(".", 1)[0] != match.group("otp")
    ):
        raise ReadinessError("staged mise Erlang version is not pinned consistently")
    rebar_version = (
        f"{match.group('major')}-{match.group('minor')}-otp-{match.group('otp')}"
    )
    return erlang_version, version, rebar_version


def _select_private_live_runtime_tools(
    snapshot: Path, mise_data: Path
) -> PrivateLiveRuntimeTools:
    """Select exact installed runners without consulting a project at runtime."""

    erlang_version, elixir_version, _rebar_version = _mise_elixir_tool_contract(
        snapshot
    )
    try:
        mise_data = mise_data.resolve(strict=True)
        installs = (mise_data / "installs").resolve(strict=True)
        elixir_root = installs / "elixir" / elixir_version
        if elixir_root.resolve(strict=True) != elixir_root:
            raise ReadinessError("installed Elixir runtime contains a symlink")
        erlang_installs = (installs / "erlang").resolve(strict=True)
        erlang_root = (erlang_installs / erlang_version).resolve(strict=True)
    except ReadinessError:
        raise
    except OSError as error:
        raise ReadinessError("pinned live runtime tools are unavailable") from error
    if (
        not erlang_root.is_relative_to(erlang_installs)
        or erlang_root == erlang_installs
        or re.fullmatch(
            re.escape(erlang_version) + r"(?:\.[0-9]+){0,2}", erlang_root.name
        )
        is None
    ):
        raise ReadinessError("installed Erlang runtime differs from the pinned series")

    erts_roots: list[Path] = []
    try:
        with os.scandir(erlang_root) as entries:
            for entry in entries:
                if entry.name.startswith("erts-"):
                    if len(erts_roots) >= 4:
                        raise ReadinessError("installed Erlang runtime inventory is ambiguous")
                    metadata = entry.stat(follow_symlinks=False)
                    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(
                        metadata.st_mode
                    ):
                        raise ReadinessError(
                            "installed Erlang runtime inventory is invalid"
                        )
                    erts_roots.append(Path(entry.path))
    except ReadinessError:
        raise
    except OSError as error:
        raise ReadinessError("installed Erlang runtime inventory is unavailable") from error
    if len(erts_roots) != 1:
        raise ReadinessError("installed Erlang runtime inventory is ambiguous")
    erts_root = erts_roots[0]
    tools = PrivateLiveRuntimeTools(
        elixir_runner=elixir_root / "bin/elixir",
        elixirc_runner=elixir_root / "bin/elixirc",
        erlang_root=erlang_root,
        fingerprint_paths=(
            ("elixir-runner", elixir_root / "bin/elixir", True),
            ("elixirc-runner", elixir_root / "bin/elixirc", True),
            ("elixir-core", elixir_root / "lib/elixir/ebin/elixir.beam", False),
            ("mix-task", elixir_root / "lib/mix/ebin/Elixir.Mix.Task.beam", False),
            ("erl-runner", erlang_root / "bin/erl", True),
            ("erts-erlexec", erts_root / "bin/erlexec", True),
            ("erts-beam", erts_root / "bin/beam.smp", True),
        ),
    )
    _inspect_private_live_runtime_tools(tools)
    return tools


def _inspect_private_live_runtime_tools(tools: PrivateLiveRuntimeTools) -> str:
    """Fingerprint the exact installed entry scripts and native VM executables."""

    if not isinstance(tools, PrivateLiveRuntimeTools):
        raise ReadinessError("private live runtime tool selection is invalid")
    records: list[bytes] = []
    for label, path, executable in tools.fingerprint_paths:
        try:
            metadata = path.lstat()
        except OSError as error:
            raise ReadinessError("private live runtime tool disappeared") from error
        if (
            not path.is_absolute()
            or stat.S_ISLNK(metadata.st_mode)
            or not stat.S_ISREG(metadata.st_mode)
            or metadata.st_nlink != 1
            or (executable and not metadata.st_mode & stat.S_IXUSR)
        ):
            raise ReadinessError("private live runtime tool metadata is invalid")
        payload = _read_regular_bytes(path, MAX_EXECUTABLE_BYTES)
        if not payload:
            raise ReadinessError("private live runtime tool is empty")
        records.extend(
            (
                label.encode("ascii"),
                f"{stat.S_IMODE(metadata.st_mode):04o}".encode("ascii"),
                payload,
            )
        )
    return sha256_bytes(_length_prefixed(records))


def _private_runtime_code_paths(mix_build: Path) -> tuple[Path, ...]:
    """Enumerate exact real compiled ebin roots without loading Mix metadata."""

    if not mix_build.is_absolute():
        raise ReadinessError("private live build root is not absolute")
    lib_root = mix_build / "lib"
    try:
        root_metadata = lib_root.lstat()
    except OSError as error:
        raise ReadinessError("private live runtime code roots are unavailable") from error
    if stat.S_ISLNK(root_metadata.st_mode) or not stat.S_ISDIR(root_metadata.st_mode):
        raise ReadinessError("private live runtime code root is invalid")
    entries: list[os.DirEntry[str]] = []
    try:
        with os.scandir(lib_root) as children:
            for entry in children:
                if len(entries) >= MAX_RUNTIME_CODE_PATHS:
                    raise ReadinessError("private live runtime has too many code roots")
                entries.append(entry)
    except ReadinessError:
        raise
    except OSError as error:
        raise ReadinessError("private live runtime code roots are unavailable") from error
    code_paths: list[Path] = []
    apps: set[str] = set()
    for entry in sorted(entries, key=lambda value: value.name):
        if re.fullmatch(r"[a-z][a-z0-9_]{0,127}", entry.name) is None:
            raise ReadinessError("private live runtime app name is invalid")
        try:
            app_metadata = entry.stat(follow_symlinks=False)
            ebin = Path(entry.path) / "ebin"
            ebin_metadata = ebin.lstat()
        except OSError as error:
            raise ReadinessError("private live runtime code root is incomplete") from error
        if (
            stat.S_ISLNK(app_metadata.st_mode)
            or not stat.S_ISDIR(app_metadata.st_mode)
            or stat.S_ISLNK(ebin_metadata.st_mode)
            or not stat.S_ISDIR(ebin_metadata.st_mode)
        ):
            raise ReadinessError("private live runtime code root is not a real directory")
        has_beam = False
        try:
            with os.scandir(ebin) as beam_entries:
                count = 0
                for beam_entry in beam_entries:
                    count += 1
                    if count > 4_096:
                        raise ReadinessError(
                            "private live runtime code root contains too many files"
                        )
                    beam_metadata = beam_entry.stat(follow_symlinks=False)
                    if stat.S_ISLNK(beam_metadata.st_mode) or not stat.S_ISREG(
                        beam_metadata.st_mode
                    ):
                        raise ReadinessError(
                            "private live runtime code root contains an unsafe entry"
                        )
                    has_beam = has_beam or beam_entry.name.endswith(".beam")
        except ReadinessError:
            raise
        except OSError as error:
            raise ReadinessError("private live runtime code root changed") from error
        if not has_beam:
            raise ReadinessError(
                f"private live runtime code root has no beam files: {entry.name}"
            )
        apps.add(entry.name)
        code_paths.append(ebin)
    if not {"erlexec", "symphony_elixir"}.issubset(apps):
        raise ReadinessError("private live runtime code roots are incomplete")
    return tuple(code_paths)


def _assert_empty_private_runtime_root(root: Path) -> None:
    try:
        metadata = root.lstat()
        with os.scandir(root) as entries:
            occupied = next(entries, None) is not None
    except OSError as error:
        raise ReadinessError("private live runtime root is unavailable") from error
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISDIR(metadata.st_mode)
        or stat.S_IMODE(metadata.st_mode) != 0o700
        or occupied
    ):
        raise ReadinessError("private live runtime root is not empty and private")


def _private_live_task_environment(
    setup_environment: Mapping[str, str],
    credential_overrides: Mapping[str, str],
    tools: PrivateLiveRuntimeTools,
) -> dict[str, str]:
    """Drop every Mix/Hex/mise/project selector before credentials are exposed."""

    if set(credential_overrides) != {"CODEX_HOME", "XDG_STATE_HOME"}:
        raise ReadinessError("private live credential environment is invalid")
    environment = {
        key: value
        for key, value in setup_environment.items()
        if key in LIVE_TASK_ENVIRONMENT_KEYS
    }
    required = {
        "ERL_CRASH_DUMP",
        "HOME",
        "LANG",
        "LC_ALL",
        "NO_COLOR",
        "TMPDIR",
        "TZ",
        "XDG_CACHE_HOME",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
    }
    if not required.issubset(environment):
        raise ReadinessError("private live task environment is incomplete")
    environment.update(credential_overrides)
    environment.update(
        {
            "ERL_ROOTDIR": str(tools.erlang_root),
            "PATH": f"{tools.erlang_root / 'bin'}:/usr/bin:/bin",
            "SHELL": "/bin/sh",
        }
    )
    for key, value in environment.items():
        if (
            not isinstance(value, str)
            or not value
            or "\x00" in value
            or len(value.encode("utf-8")) > MAX_TEXT_BYTES
        ):
            raise ReadinessError(f"private live task environment value is invalid: {key}")
    forbidden_prefixes = ("HEX", "MISE", "MIX", "REBAR", "SYMPHONY_ERLEXEC")
    if any(key.startswith(forbidden_prefixes) for key in environment):
        raise ReadinessError("private live task environment retained a build selector")
    return environment


def _live_capability_task_command(
    tools: PrivateLiveRuntimeTools,
    code_paths: Sequence[Path],
    native_codex: str,
    snapshot: Path,
) -> list[str]:
    """Build one project-independent direct-Elixir task argv."""

    if (
        not code_paths
        or len(code_paths) > MAX_RUNTIME_CODE_PATHS
        or not Path(native_codex).is_absolute()
        or not snapshot.is_absolute()
    ):
        raise ReadinessError("private live task command inputs are invalid")
    workflow = _private_live_workflow_path(snapshot)
    command = [str(tools.elixir_runner)]
    for code_path in code_paths:
        if not code_path.is_absolute():
            raise ReadinessError("private live task code path is not absolute")
        command.extend(("-pa", str(code_path)))
    command.extend(
        (
            "-e",
            LIVE_TASK_ENTRYPOINT,
            "--",
            "--format",
            "json",
            "--codex-bin",
            native_codex,
            "--cwd",
            str(snapshot),
            "--workflow",
            str(workflow),
        )
    )
    if len(command) > MAX_COMMAND_ARGUMENTS:
        raise ReadinessError("private live task command has too many arguments")
    for argument in command:
        if (
            not argument
            or "\x00" in argument
            or len(argument.encode("utf-8")) > MAX_COMMAND_ARGUMENT_BYTES
        ):
            raise ReadinessError("private live task command argument is invalid")
    return command


def _private_live_workflow_path(snapshot: Path) -> Path:
    """Select the exact regular workflow input from the verified snapshot."""

    workflow = snapshot / "elixir" / "WORKFLOW.md"
    try:
        workflow_metadata = workflow.lstat()
        workflow_resolved = workflow.resolve(strict=True)
    except OSError as error:
        raise ReadinessError("private live workflow input is unavailable") from error
    if (
        stat.S_ISLNK(workflow_metadata.st_mode)
        or not stat.S_ISREG(workflow_metadata.st_mode)
        or workflow_resolved != workflow
    ):
        raise ReadinessError("private live workflow input is invalid")
    return workflow


def _inspect_private_mix_tools(source: Path, rebar_version: str) -> str:
    """Verify the finite Hex archive and versioned rebar3 input bundle."""

    if MIX_REBAR_VERSION_RE.fullmatch(rebar_version) is None:
        raise ReadinessError("private Mix rebar version is invalid")
    try:
        root_metadata = source.lstat()
    except OSError as error:
        raise ReadinessError("private Mix tool input root disappeared") from error
    if (
        stat.S_ISLNK(root_metadata.st_mode)
        or not stat.S_ISDIR(root_metadata.st_mode)
        or stat.S_IMODE(root_metadata.st_mode) != 0o700
    ):
        raise ReadinessError("private Mix tool input root is invalid")

    directories: set[str] = set()
    files: set[str] = set()
    archive_names: set[str] = set()
    archive_apps: dict[str, bytes] = {}
    records: list[bytes] = []
    total = 0
    for child in _bounded_tree_paths(
        source, MAX_MIX_TOOL_INPUT_ENTRIES, "private Mix tool inputs"
    ):
        relative = child.relative_to(source).as_posix()
        parts = PurePosixPath(relative).parts
        metadata = child.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise ReadinessError("private Mix tool inputs contain a symlink")
        if stat.S_ISDIR(metadata.st_mode):
            if stat.S_IMODE(metadata.st_mode) != 0o700:
                raise ReadinessError("private Mix tool input directory mode changed")
            if parts == ("archives",) or parts == ("elixir",):
                pass
            elif parts[0] == "archives" and len(parts) >= 2:
                archive_match = HEX_ARCHIVE_RE.fullmatch(parts[1])
                if archive_match is None or (len(parts) >= 3 and parts[2] != parts[1]):
                    raise ReadinessError("private Mix Hex archive path is invalid")
                archive_names.add(parts[1])
            elif parts == ("elixir", rebar_version):
                pass
            else:
                raise ReadinessError("private Mix tools contain an unexpected directory")
            directories.add(relative)
            records.extend((relative.encode("utf-8"), b"directory", b"0700"))
            continue
        if not stat.S_ISREG(metadata.st_mode):
            raise ReadinessError("private Mix tool inputs contain a special file")
        payload = _read_regular_bytes(child, MAX_MIX_TOOL_INPUT_BYTES)
        if not payload:
            raise ReadinessError("private Mix tool input is empty")
        total += len(payload)
        if total > MAX_MIX_TOOL_INPUT_BYTES:
            raise ReadinessError("private Mix tool inputs exceed their byte bound")

        expected_mode = 0o600
        if parts == ("elixir", rebar_version, "rebar3"):
            expected_mode = 0o700
            header = payload[:160]
            if (
                not header.startswith(b"#!/usr/bin/env escript\n")
                or re.search(rb"(?m)^%% Rebar3 [0-9]+\.[0-9]+\.[0-9]+$", header)
                is None
            ):
                raise ReadinessError("private versioned rebar3 input is malformed")
        elif len(parts) >= 4 and parts[0] == "archives":
            archive_match = HEX_ARCHIVE_RE.fullmatch(parts[1])
            if archive_match is None or parts[2] != parts[1]:
                raise ReadinessError("private Mix Hex archive file path is invalid")
            archive_names.add(parts[1])
            if parts[3:] == ("ebin", "hex.app"):
                archive_apps[parts[1]] = payload
        else:
            raise ReadinessError("private Mix tools contain an unexpected file")
        if (
            stat.S_IMODE(metadata.st_mode) != expected_mode
            or metadata.st_nlink != 1
        ):
            raise ReadinessError("private Mix tool input metadata changed")
        files.add(relative)
        records.extend(
            (
                relative.encode("utf-8"),
                b"file",
                f"{expected_mode:04o}".encode("ascii"),
                payload,
            )
        )

    expected_roots = {"archives", "elixir", f"elixir/{rebar_version}"}
    if not archive_names or not expected_roots.issubset(directories):
        raise ReadinessError("private Mix tool input inventory is incomplete")
    if files.intersection(
        {
            "dialyxir_erlang.plt",
            "dialyxir_erlang.plt.hash",
        }
    ):
        raise ReadinessError("private Mix tools unexpectedly contain a PLT")
    if f"elixir/{rebar_version}/rebar3" not in files:
        raise ReadinessError("private versioned rebar3 input is missing")
    for archive in archive_names:
        version = HEX_ARCHIVE_RE.fullmatch(archive).group("version")
        required = {
            f"archives/{archive}/{archive}/.elixir",
            f"archives/{archive}/{archive}/ebin/hex.app",
        }
        if not required.issubset(files):
            raise ReadinessError("private Mix Hex archive is incomplete")
        app = archive_apps.get(archive, b"")
        if f'{{vsn,"{version}"}}'.encode("ascii") not in app:
            raise ReadinessError("private Mix Hex archive version is inconsistent")
    return sha256_bytes(_length_prefixed(records))


def _prepare_private_mix_tools(
    snapshot: Path, temporary_root: Path, host_mise_data: Path
) -> tuple[Path, Path, str, str]:
    """Copy only trusted Mix executables, never host PLTs or their hashes."""

    _erlang_version, elixir_version, rebar_version = _mise_elixir_tool_contract(snapshot)
    host_mix_home = (
        host_mise_data / "installs" / "elixir" / elixir_version / ".mix"
    )
    try:
        if host_mix_home.resolve(strict=True) != host_mix_home:
            raise ReadinessError("host Mix tool home contains a symlink")
        metadata = host_mix_home.lstat()
    except OSError as error:
        raise ReadinessError("host Mix tool home is unavailable") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise ReadinessError("host Mix tool home is not a real directory")

    destination = temporary_root / "mix-tools"
    archives_destination = destination / "archives"
    rebar_destination = destination / "elixir" / rebar_version / "rebar3"
    for directory in (
        destination,
        archives_destination,
        destination / "elixir",
        rebar_destination.parent,
    ):
        _private_directory(directory)

    archives_source = host_mix_home / "archives"
    archive_entries: list[os.DirEntry[str]] = []
    try:
        with os.scandir(archives_source) as entries:
            for entry in entries:
                archive_entries.append(entry)
                if len(archive_entries) > MAX_MIX_HEX_ARCHIVES:
                    raise ReadinessError("host Mix Hex archive inventory is invalid")
    except ReadinessError:
        raise
    except OSError as error:
        raise ReadinessError("host Mix Hex archives are unavailable") from error
    if not archive_entries:
        raise ReadinessError("host Mix Hex archive inventory is invalid")
    archive_entries.sort(key=lambda entry: entry.name)
    for entry in archive_entries:
        try:
            entry_metadata = entry.stat(follow_symlinks=False)
        except OSError as error:
            raise ReadinessError("host Mix Hex archive changed while selected") from error
        if (
            HEX_ARCHIVE_RE.fullmatch(entry.name) is None
            or stat.S_ISLNK(entry_metadata.st_mode)
            or not stat.S_ISDIR(entry_metadata.st_mode)
        ):
            raise ReadinessError("host Mix archive inventory contains an unsafe entry")
        _copy_private_regular_tree(
            Path(entry.path),
            archives_destination / entry.name,
            maximum_bytes=MAX_MIX_TOOL_INPUT_BYTES,
        )

    rebar_source = host_mix_home / "elixir" / rebar_version / "rebar3"
    try:
        rebar_metadata = rebar_source.lstat()
    except OSError as error:
        raise ReadinessError("versioned host rebar3 is unavailable") from error
    if (
        stat.S_ISLNK(rebar_metadata.st_mode)
        or not stat.S_ISREG(rebar_metadata.st_mode)
        or not rebar_metadata.st_mode & stat.S_IXUSR
    ):
        raise ReadinessError("versioned host rebar3 is not a trusted executable")
    if not _copy_private_regular(
        rebar_source, rebar_destination, MAX_MIX_TOOL_INPUT_BYTES
    ):
        raise ReadinessError("versioned host rebar3 cannot be copied")
    os.chmod(rebar_destination, 0o700)
    fingerprint = _inspect_private_mix_tools(destination, rebar_version)
    return host_mix_home, destination, rebar_version, fingerprint


def _prepare_private_setup_elixir(
    snapshot: Path,
    temporary_root: Path,
    index_entries: Sequence[tuple[str, str, str]],
) -> tuple[Path, tuple[tuple[str, str, str], ...]]:
    """Copy staged Elixir bytes for credential-free dependency bootstrap only."""

    destination = temporary_root / "setup-elixir"
    _private_directory(destination)
    records: list[tuple[str, str, str]] = []
    total = 0
    indexed_elixir = {
        path.removeprefix("elixir/")
        for path, _mode, _object_id in index_entries
        if path.startswith("elixir/")
    }
    required = (
        SETUP_ELIXIR_REQUIRED if "mix.exs" in indexed_elixir else frozenset({"mise.toml"})
    )
    if not required.issubset(indexed_elixir):
        raise ReadinessError("staged Elixir dependency setup contract is incomplete")
    for indexed_path, mode, _object_id in index_entries:
        if not indexed_path.startswith("elixir/"):
            continue
        relative = indexed_path.removeprefix("elixir/")
        if relative not in required:
            continue
        if not relative or _safe_relative_path(relative, "setup Elixir path") != relative:
            raise ReadinessError("staged Elixir setup source contains an unsafe path")
        source = snapshot / indexed_path
        metadata = source.lstat()
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
            raise ReadinessError("staged Elixir setup source contains a non-regular file")
        payload = _read_regular_bytes(source, MAX_EXECUTABLE_BYTES)
        total += len(payload)
        if total > MAX_ERLEXEC_SOURCE_BYTES:
            raise ReadinessError("staged Elixir setup source exceeds its byte bound")
        target = destination / relative
        _private_directory(target.parent)
        with target.open("xb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(target, 0o755 if mode == "100755" else 0o644)
        records.append((relative, mode, sha256_bytes(payload)))
    tracked = tuple(sorted(records))
    if not tracked:
        raise ReadinessError("staged Elixir setup source is incomplete")
    for relative in ("cover", "bin"):
        target = destination / relative
        if target.exists() or target.is_symlink():
            raise ReadinessError("staged Elixir setup output path is not empty")
        target.mkdir(mode=0o700)
    _inspect_private_setup_elixir(destination, tracked)
    return destination, tracked


def _inspect_private_setup_elixir(
    source: Path, tracked: Sequence[tuple[str, str, str]]
) -> str:
    expected = {relative: (mode, digest) for relative, mode, digest in tracked}
    allowed_directories = _tracked_parent_directories(tracked) | {"bin", "cover"}
    seen_files: set[str] = set()
    seen_directories: set[str] = set()
    records: list[bytes] = []
    for child in _bounded_tree_paths(
        source, 5_000, "private Elixir setup source"
    ):
        relative = child.relative_to(source).as_posix()
        metadata = child.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise ReadinessError("private Elixir setup source contains a symlink")
        if stat.S_ISDIR(metadata.st_mode):
            if stat.S_IMODE(metadata.st_mode) != 0o700:
                raise ReadinessError("private Elixir setup directory mode changed")
            seen_directories.add(relative)
            continue
        if not stat.S_ISREG(metadata.st_mode) or relative not in expected:
            raise ReadinessError("private Elixir setup produced an unexpected file")
        mode, expected_sha256 = expected[relative]
        expected_mode = 0o755 if mode == "100755" else 0o644
        payload = _read_regular_bytes(child, MAX_EXECUTABLE_BYTES)
        if (
            stat.S_IMODE(metadata.st_mode) != expected_mode
            or sha256_bytes(payload) != expected_sha256
        ):
            raise ReadinessError("private Elixir setup tracked source changed")
        seen_files.add(relative)
        records.extend(
            (
                relative.encode("utf-8"),
                mode.encode("ascii"),
                payload,
            )
        )
    if seen_files != set(expected) or seen_directories != allowed_directories:
        raise ReadinessError("private Elixir setup source inventory changed")
    return sha256_bytes(_length_prefixed(records))


def _prepare_private_erlexec_source(
    snapshot: Path,
    temporary_root: Path,
    index_entries: Sequence[tuple[str, str, str]],
) -> tuple[Path, tuple[tuple[str, str, str], ...]]:
    """Copy the exact staged path dependency into a private build source."""

    destination = temporary_root / "erlexec-source"
    _private_directory(destination)
    entries = [
        entry for entry in index_entries if entry[0].startswith(ERLEXEC_INDEX_PREFIX)
    ]
    indexed_paths = {path for path, _mode, _object_id in index_entries}
    if "elixir/mix.exs" in indexed_paths and not entries:
        raise ReadinessError("staged Elixir project lacks its vendored erlexec source")

    total = 0
    records: list[tuple[str, str, str]] = []
    for indexed_path, mode, _object_id in entries:
        relative = indexed_path.removeprefix(ERLEXEC_INDEX_PREFIX)
        if not relative or _safe_relative_path(relative, "erlexec source path") != relative:
            raise ReadinessError("staged erlexec source contains an unsafe path")
        source = snapshot / indexed_path
        try:
            metadata = source.lstat()
        except OSError as error:
            raise ReadinessError("staged erlexec source is incomplete") from error
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
            raise ReadinessError("staged erlexec source contains a non-regular file")
        expected_mode = 0o755 if mode == "100755" else 0o644
        if bool(metadata.st_mode & stat.S_IXUSR) != (mode == "100755"):
            raise ReadinessError("staged erlexec source mode differs from its index")
        payload = _read_regular_bytes(source, MAX_EXECUTABLE_BYTES)
        total += len(payload)
        if total > MAX_ERLEXEC_SOURCE_BYTES:
            raise ReadinessError("staged erlexec source exceeds its aggregate byte bound")
        target = destination / relative
        _private_directory(target.parent)
        try:
            with target.open("xb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(target, expected_mode)
        except OSError as error:
            raise ReadinessError("cannot copy staged erlexec source privately") from error
        records.append((relative, mode, sha256_bytes(payload)))

    tracked = tuple(sorted(records))
    _inspect_private_erlexec_source(destination, tracked)
    return destination, tracked


def _expected_erlexec_generated(
    tracked: Sequence[tuple[str, str, str]],
) -> frozenset[str]:
    generated: set[str] = set()
    for relative, _mode, _sha256 in tracked:
        path = PurePosixPath(relative)
        if path.parent == PurePosixPath("c_src") and path.suffix == ".cpp":
            stem = relative[: -len(".cpp")]
            generated.update((f"{stem}.o", f"{stem}.d"))
    if tracked and not generated:
        raise ReadinessError("staged erlexec source has no bounded C++ build inputs")
    return frozenset(generated)


def _tracked_parent_directories(
    tracked: Sequence[tuple[str, str, str]],
) -> set[str]:
    result: set[str] = set()
    for relative, _mode, _sha256 in tracked:
        parent = PurePosixPath(relative).parent
        while parent != PurePosixPath("."):
            result.add(parent.as_posix())
            parent = parent.parent
    return result


def _inspect_private_erlexec_source(
    source: Path,
    tracked: Sequence[tuple[str, str, str]],
    *,
    normalize_generated: bool = False,
    require_compiled: bool = False,
) -> str:
    """Verify immutable staged bytes and the finite native-build output set."""

    expected_tracked = {
        relative: (mode, digest) for relative, mode, digest in tracked
    }
    expected_generated = _expected_erlexec_generated(tracked)
    tracked_directories = _tracked_parent_directories(tracked)
    seen_tracked: set[str] = set()
    seen_generated: set[str] = set()
    exec_paths: list[str] = []
    directories: set[str] = set()
    file_records: list[bytes] = []
    generated_total = 0

    try:
        root_metadata = source.lstat()
    except OSError as error:
        raise ReadinessError("private erlexec source disappeared") from error
    if stat.S_ISLNK(root_metadata.st_mode) or not stat.S_ISDIR(root_metadata.st_mode):
        raise ReadinessError("private erlexec source is not a real directory")
    if stat.S_IMODE(root_metadata.st_mode) != 0o700:
        raise ReadinessError("private erlexec source root mode changed")

    for child in _bounded_tree_paths(source, 1_024, "private erlexec source"):
        relative = child.relative_to(source).as_posix()
        metadata = child.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise ReadinessError("private erlexec source contains a symlink")
        if stat.S_ISDIR(metadata.st_mode):
            directories.add(relative)
            continue
        if not stat.S_ISREG(metadata.st_mode):
            raise ReadinessError("private erlexec source contains a special file")

        payload = _read_regular_bytes(child, MAX_EXECUTABLE_BYTES)
        if relative in expected_tracked:
            mode, expected_sha256 = expected_tracked[relative]
            expected_mode = 0o755 if mode == "100755" else 0o644
            if stat.S_IMODE(metadata.st_mode) != expected_mode:
                raise ReadinessError("private erlexec tracked source mode changed")
            if sha256_bytes(payload) != expected_sha256:
                raise ReadinessError("private erlexec tracked source bytes changed")
            seen_tracked.add(relative)
        elif relative in expected_generated:
            if not payload:
                raise ReadinessError("private erlexec generated object is empty")
            generated_total += len(payload)
            seen_generated.add(relative)
            if normalize_generated:
                os.chmod(child, 0o600)
                metadata = child.lstat()
            if stat.S_IMODE(metadata.st_mode) != 0o600:
                raise ReadinessError("private erlexec generated object mode is not canonical")
        else:
            parts = PurePosixPath(relative).parts
            if (
                len(parts) != 3
                or parts[0] != "priv"
                or parts[2] != "exec-port"
                or ERLEXEC_ARCH_RE.fullmatch(parts[1]) is None
            ):
                raise ReadinessError("private erlexec source produced an unexpected file")
            if not payload or len(payload) > 16 * 1024 * 1024:
                raise ReadinessError("private erlexec executable has an invalid size")
            generated_total += len(payload)
            exec_paths.append(relative)
            if normalize_generated:
                os.chmod(child, 0o700)
                metadata = child.lstat()
            if stat.S_IMODE(metadata.st_mode) != 0o700:
                raise ReadinessError("private erlexec executable mode is not canonical")

        if generated_total > MAX_ERLEXEC_GENERATED_BYTES:
            raise ReadinessError("private erlexec outputs exceed their byte bound")
        file_records.extend(
            (
                relative.encode("utf-8"),
                f"{stat.S_IMODE(metadata.st_mode):04o}".encode("ascii"),
                payload,
            )
        )

    if seen_tracked != set(expected_tracked):
        raise ReadinessError("private erlexec tracked source is incomplete")
    if len(exec_paths) > 1:
        raise ReadinessError("private erlexec source produced multiple executables")

    generated_directories = {"priv"}
    generated_directories.update(
        PurePosixPath(relative).parent.as_posix() for relative in exec_paths
    )
    allowed_directories = tracked_directories | (
        generated_directories if exec_paths else set()
    )
    if directories != allowed_directories:
        raise ReadinessError("private erlexec source produced an unexpected directory")
    for relative in sorted(directories):
        child = source / relative
        if normalize_generated and relative not in tracked_directories:
            os.chmod(child, 0o700)
        if stat.S_IMODE(child.lstat().st_mode) != 0o700:
            raise ReadinessError("private erlexec directory mode is not canonical")

    if require_compiled and (
        seen_generated != set(expected_generated) or len(exec_paths) != 1
    ):
        raise ReadinessError("private erlexec native build outputs are incomplete")
    return sha256_bytes(_length_prefixed(file_records))


def _prepare_gate_output_mountpoints(
    snapshot: Path,
    index_entries: Sequence[tuple[str, str, str]],
) -> None:
    indexed_paths = {path for path, _mode, _object_id in index_entries}
    for relative in GATE_MOUNTPOINT_RELATIVES:
        if any(path == relative or path.startswith(f"{relative}/") for path in indexed_paths):
            raise ReadinessError(f"private gate mountpoint is indexed: {relative}")
        target = snapshot / relative
        if target.exists() or target.is_symlink():
            raise ReadinessError(f"private gate mountpoint already exists: {relative}")
        try:
            target.mkdir(mode=0o700)
        except OSError as error:
            raise ReadinessError(
                f"cannot prepare private gate mountpoint: {relative}"
            ) from error


def _remove_gate_output_mountpoints(
    snapshot: Path,
    index_entries: Sequence[tuple[str, str, str]],
) -> None:
    """Remove only verified-empty gate mountpoints before exact-tree replay."""

    indexed_paths = {path for path, _mode, _object_id in index_entries}
    for relative in GATE_MOUNTPOINT_RELATIVES:
        if any(path == relative or path.startswith(f"{relative}/") for path in indexed_paths):
            raise ReadinessError(f"private gate mountpoint is indexed: {relative}")
        target = snapshot / relative
        try:
            metadata = target.lstat()
        except OSError as error:
            raise ReadinessError(
                f"private gate mountpoint disappeared: {relative}"
            ) from error
        if (
            stat.S_ISLNK(metadata.st_mode)
            or not stat.S_ISDIR(metadata.st_mode)
            or stat.S_IMODE(metadata.st_mode) != 0o700
            or metadata.st_uid != os.getuid()
            or metadata.st_gid != os.getgid()
        ):
            raise ReadinessError(f"private gate mountpoint changed: {relative}")
        _bounded_tree_paths(target, 0, f"private gate mountpoint {relative}")
        try:
            target.rmdir()
        except OSError as error:
            raise ReadinessError(
                f"private gate mountpoint cannot be removed: {relative}"
            ) from error
        if target.exists() or target.is_symlink():
            raise ReadinessError(f"private gate mountpoint cleanup failed: {relative}")


def _inspect_gate_generated_outputs(
    sandbox: GateSandbox,
    *,
    normalize: bool = False,
    require_complete: bool = False,
) -> str:
    """Bound and fingerprint the only two project-relative generated outputs."""

    records: list[bytes] = []
    total = 0
    count = 0
    coverage_count = 0
    escript_count = 0
    for label, root in (
        ("cover", sandbox.coverage_output),
        ("bin", sandbox.escript_output),
    ):
        metadata = root.lstat()
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            raise ReadinessError(f"private {label} output is not a real directory")
        if normalize:
            os.chmod(root, 0o700)
        if stat.S_IMODE(root.lstat().st_mode) != 0o700:
            raise ReadinessError(f"private {label} output directory mode changed")
        remaining = MAX_GATE_GENERATED_FILES - count
        for child in _bounded_tree_paths(root, remaining, "generated gate outputs"):
            count += 1
            child_metadata = child.lstat()
            if stat.S_ISLNK(child_metadata.st_mode) or not stat.S_ISREG(
                child_metadata.st_mode
            ):
                raise ReadinessError("generated gate outputs contain a non-regular file")
            relative = child.relative_to(root).as_posix()
            payload = _read_regular_bytes(child, MAX_GATE_GENERATED_BYTES)
            if not payload:
                raise ReadinessError("generated gate output is empty")
            total += len(payload)
            if total > MAX_GATE_GENERATED_BYTES:
                raise ReadinessError("generated gate outputs exceed their byte bound")
            if label == "cover":
                if "/" in relative or GATE_COVER_FILE_RE.fullmatch(relative) is None:
                    raise ReadinessError("coverage produced an unexpected output path")
                coverage_count += 1
                expected_mode = 0o600
            else:
                if relative != "symphony":
                    raise ReadinessError("escript build produced an unexpected output path")
                escript_count += 1
                expected_mode = 0o700
            if normalize:
                os.chmod(child, expected_mode)
                child_metadata = child.lstat()
            if stat.S_IMODE(child_metadata.st_mode) != expected_mode:
                raise ReadinessError("generated gate output mode is not canonical")
            records.extend(
                (
                    label.encode("ascii"),
                    relative.encode("utf-8"),
                    f"{expected_mode:04o}".encode("ascii"),
                    payload,
                )
            )
    if escript_count > 1:
        raise ReadinessError("escript build produced duplicate output")
    if require_complete and (coverage_count == 0 or escript_count != 1):
        raise ReadinessError("full upstream gate outputs are incomplete")
    return sha256_bytes(_length_prefixed(records))


def _dialyzer_output_has_error(stdout: bytes, stderr: bytes) -> bool:
    """Recognize Dialyxir's known zero-exit false-green marker on either stream."""

    if not isinstance(stdout, bytes) or not isinstance(stderr, bytes):
        raise ReadinessError("Dialyzer output must be bounded bytes")
    return DIALYZER_ERROR_MARKER in stdout or DIALYZER_ERROR_MARKER in stderr


def _gate_command_passed(
    identifier: str, returncode: int, stdout: bytes, stderr: bytes
) -> bool:
    if type(returncode) is not int:
        raise ReadinessError("gate return code is invalid")
    if identifier not in REQUIRED_CONFORMANCE_IDS:
        raise ReadinessError("gate identifier is invalid")
    return returncode == 0 and not (
        identifier == "upstream_make_all"
        and _dialyzer_output_has_error(stdout, stderr)
    )


def _inspect_private_plt_outputs(
    sandbox: GateSandbox,
    *,
    require_complete: bool = False,
    require_empty: bool = False,
) -> str:
    """Allowlist and fingerprint only freshly generated Dialyxir PLT outputs."""

    if require_complete and require_empty:
        raise ReadinessError("private PLT inventory requirements conflict")
    records: list[bytes] = []
    outputs: dict[str, tuple[str, bytes, re.Match[str] | None]] = {}
    total = 0

    try:
        mix_home_metadata = sandbox.mix_home.lstat()
    except OSError as error:
        raise ReadinessError("private Mix home disappeared") from error
    if (
        stat.S_ISLNK(mix_home_metadata.st_mode)
        or not stat.S_ISDIR(mix_home_metadata.st_mode)
        or stat.S_IMODE(mix_home_metadata.st_mode) != 0o700
        or mix_home_metadata.st_uid != sandbox.sandbox_uid
        or mix_home_metadata.st_gid != sandbox.sandbox_gid
    ):
        raise ReadinessError("private Mix home root changed")

    for child in _bounded_tree_paths(
        sandbox.mix_home, 16, "private Mix home outputs"
    ):
        relative = child.relative_to(sandbox.mix_home).as_posix()
        metadata = child.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise ReadinessError("private Mix home outputs contain a symlink")
        if stat.S_ISDIR(metadata.st_mode):
            if relative not in {"archives", "elixir"}:
                raise ReadinessError("private Mix home contains an unexpected directory")
            if stat.S_IMODE(metadata.st_mode) != 0o700:
                raise ReadinessError("private Mix home mountpoint mode changed")
            continue
        if not stat.S_ISREG(metadata.st_mode):
            raise ReadinessError("private Mix home outputs contain a special file")
        match: re.Match[str] | None = CORE_ERLANG_PLT_RE.fullmatch(relative)
        label = "core-erlang"
        if match is None:
            match = CORE_ELIXIR_PLT_RE.fullmatch(relative)
            label = "core-elixir"
        if match is None:
            raise ReadinessError("private Mix home contains an unexpected output")
        payload = _read_regular_bytes(child, MAX_PRIVATE_PLT_BYTES)
        total += len(payload)
        if not payload or total > MAX_PRIVATE_PLT_BYTES:
            raise ReadinessError("private PLT outputs exceed their byte bound")
        if (
            stat.S_IMODE(metadata.st_mode) != 0o600
            or metadata.st_nlink != 1
            or metadata.st_uid != sandbox.sandbox_uid
            or metadata.st_gid != sandbox.sandbox_gid
        ):
            raise ReadinessError("private PLT output metadata is invalid")
        if label in outputs:
            raise ReadinessError("private Mix home contains duplicate PLT outputs")
        outputs[label] = (relative, payload, match)
        records.extend(
            (label.encode("ascii"), relative.encode("ascii"), b"0600", payload)
        )

    try:
        build_metadata = sandbox.mix_build.lstat()
    except OSError as error:
        raise ReadinessError("private Mix build root disappeared") from error
    if stat.S_ISLNK(build_metadata.st_mode) or not stat.S_ISDIR(
        build_metadata.st_mode
    ):
        raise ReadinessError("private Mix build root is invalid")
    for child in _bounded_tree_paths(
        sandbox.mix_build, MAX_PRIVATE_PLT_ENTRIES, "private Mix build outputs"
    ):
        relative = child.relative_to(sandbox.mix_build).as_posix()
        if not (relative.endswith(".plt") or relative.endswith(".plt.hash")):
            continue
        metadata = child.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise ReadinessError("private project PLT output is a symlink")
        if not stat.S_ISREG(metadata.st_mode):
            raise ReadinessError("private project PLT output is a special file")
        plt_relative = relative.removesuffix(".hash")
        match = DEPS_DEV_PLT_RE.fullmatch(plt_relative)
        if match is None or relative not in {plt_relative, f"{plt_relative}.hash"}:
            raise ReadinessError("private Mix build contains an unexpected PLT output")
        label = "deps-dev-hash" if relative.endswith(".hash") else "deps-dev"
        payload = _read_regular_bytes(child, MAX_PRIVATE_PLT_BYTES)
        total += len(payload)
        if not payload or total > MAX_PRIVATE_PLT_BYTES:
            raise ReadinessError("private PLT outputs exceed their byte bound")
        if (
            stat.S_IMODE(metadata.st_mode) != 0o600
            or metadata.st_nlink != 1
            or metadata.st_uid != sandbox.sandbox_uid
            or metadata.st_gid != sandbox.sandbox_gid
        ):
            raise ReadinessError("private project PLT metadata is invalid")
        if label in outputs:
            raise ReadinessError("private Mix build contains duplicate PLT outputs")
        outputs[label] = (relative, payload, match)
        records.extend(
            (label.encode("ascii"), relative.encode("ascii"), b"0600", payload)
        )

    forbidden_provenance = {
        str(sandbox.host_home).encode("utf-8"),
        str(sandbox.host_mise_data).encode("utf-8"),
        str(sandbox.host_mix_home).encode("utf-8"),
        str(sandbox.temporary_root).encode("utf-8"),
    }
    for _relative, payload, _match in outputs.values():
        if any(needle and needle in payload for needle in forbidden_provenance):
            raise ReadinessError("private PLT contains host-absolute provenance")
        if re.search(rb"(?:^|[^A-Za-z0-9])(?:/home/|/Users/|/var/tmp/|/tmp/)", payload):
            raise ReadinessError("private PLT contains host-absolute provenance")

    if require_empty and outputs:
        raise ReadinessError("private PLT output roots were not fresh")
    if require_complete:
        if set(outputs) != {
            "core-erlang",
            "core-elixir",
            "deps-dev",
            "deps-dev-hash",
        }:
            raise ReadinessError("private PLT output inventory is incomplete")
        core_erlang = outputs["core-erlang"][2]
        core_elixir = outputs["core-elixir"][2]
        deps_dev = outputs["deps-dev"][2]
        deps_dev_hash = outputs["deps-dev-hash"][2]
        assert core_erlang is not None
        assert core_elixir is not None
        assert deps_dev is not None
        assert deps_dev_hash is not None
        deps_dev_relative = outputs["deps-dev"][0]
        deps_dev_hash_relative = outputs["deps-dev-hash"][0]
        if deps_dev_hash_relative != f"{deps_dev_relative}.hash":
            raise ReadinessError("private project PLT hash sidecar is inconsistent")
        if (
            core_erlang.group("otp") != core_elixir.group("otp")
            or core_elixir.group("otp") != deps_dev.group("otp")
            or deps_dev.group("otp") != deps_dev_hash.group("otp")
            or core_elixir.group("elixir") != deps_dev.group("elixir")
            or deps_dev.group("elixir") != deps_dev_hash.group("elixir")
        ):
            raise ReadinessError("private PLT versions are inconsistent")
    return sha256_bytes(_length_prefixed(records))


def _prepare_private_resolver_config(
    temporary_root: Path,
) -> tuple[Path | None, str | None]:
    """Preserve DNS after masking host runtime state under /run."""

    resolver = Path("/etc/resolv.conf")
    try:
        metadata = resolver.lstat()
    except OSError as error:
        raise ReadinessError("resolver configuration is unavailable") from error
    if not stat.S_ISLNK(metadata.st_mode):
        if not stat.S_ISREG(metadata.st_mode):
            raise ReadinessError("resolver configuration is not a regular file")
        return None, None
    try:
        link_text = os.readlink(resolver)
        canonical = resolver.resolve(strict=True)
        canonical.relative_to("/run")
    except (OSError, ValueError) as error:
        raise ReadinessError("resolver symlink target is outside the isolated runtime") from error
    target = canonical.as_posix()
    target_path = PurePosixPath(target)
    if (
        not target_path.is_absolute()
        or ".." in target_path.parts
        or "\x00" in target
    ):
        raise ReadinessError("resolver symlink target is unsafe")
    private = temporary_root / "resolver.conf"
    if not _copy_private_regular(canonical, private, 64 * 1024):
        raise ReadinessError("resolver configuration cannot be copied privately")
    try:
        after = resolver.lstat()
        if (
            (after.st_dev, after.st_ino, after.st_mtime_ns) !=
            (metadata.st_dev, metadata.st_ino, metadata.st_mtime_ns)
            or os.readlink(resolver) != link_text
            or resolver.resolve(strict=True) != canonical
        ):
            raise ReadinessError("resolver configuration changed while isolated")
    except OSError as error:
        raise ReadinessError("resolver configuration changed while isolated") from error
    return private, target


def _private_build_link_roots(
    roots: Sequence[tuple[str, Path]],
) -> dict[str, Path]:
    """Normalize the finite roots that may back compiler-generated links."""

    result: dict[str, Path] = {}
    seen_paths: set[Path] = set()
    for root_label, root in roots:
        if root_label in result or re.fullmatch(r"[a-z]+", root_label) is None:
            raise ReadinessError("private build link root labels are invalid")
        absolute = Path(os.path.abspath(root))
        try:
            metadata = absolute.lstat()
            canonical = absolute.resolve(strict=True)
        except (OSError, RuntimeError) as error:
            raise ReadinessError("private build link root is unavailable") from error
        if (
            stat.S_ISLNK(metadata.st_mode)
            or not stat.S_ISDIR(metadata.st_mode)
            or canonical != absolute
            or absolute in seen_paths
        ):
            raise ReadinessError("private build link root is unsafe")
        seen_paths.add(absolute)
        result[root_label] = absolute
    return result


def _private_build_link_target_present(
    target_root: Path,
    target_relative: str,
    *,
    diagnostic: str,
) -> bool:
    """Inspect a target lexically without traversing any symlink component."""

    current = target_root
    parts = PurePosixPath(target_relative).parts
    if not parts:
        raise ReadinessError(f"private build link target is invalid at {diagnostic}")
    for index, part in enumerate(parts):
        current /= part
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            return False
        except OSError as error:
            raise ReadinessError(
                f"private build link target cannot be inspected at {diagnostic}"
            ) from error
        if stat.S_ISLNK(metadata.st_mode):
            raise ReadinessError(
                f"private build link target has a symlink component at {diagnostic}"
            )
        if index + 1 < len(parts) and not stat.S_ISDIR(metadata.st_mode):
            raise ReadinessError(
                f"private build link target has a non-directory ancestor at {diagnostic}"
            )
        if index + 1 == len(parts) and not stat.S_ISDIR(metadata.st_mode):
            raise ReadinessError(
                f"private build link target is not a directory at {diagnostic}"
            )
    return True


def _private_build_link_binding(
    child: Path,
    metadata: os.stat_result,
    *,
    root_label: str,
    relative: str,
    allowed_roots: Mapping[str, Path],
    lexical_roots: Mapping[str, Path],
) -> bytes:
    """Bind one exact Mix/Rebar link without following it during traversal."""

    diagnostic = f"{root_label}/{relative}"
    if metadata.st_size <= 0 or metadata.st_size > MAX_BUILD_LINK_BYTES:
        raise ReadinessError(
            f"private build link text exceeds its bound at {diagnostic}"
        )
    try:
        link_text = os.readlink(child)
    except OSError as error:
        raise ReadinessError(
            f"private build link cannot be read at {diagnostic}"
        ) from error
    try:
        link_bytes = link_text.encode("utf-8", errors="strict")
    except UnicodeEncodeError as error:
        raise ReadinessError(
            f"private build link text is invalid at {diagnostic}"
        ) from error
    if (
        not link_bytes
        or len(link_bytes) != metadata.st_size
        or len(link_bytes) > MAX_BUILD_LINK_BYTES
        or b"\x00" in link_bytes
    ):
        raise ReadinessError(
            f"private build link text exceeds its bound at {diagnostic}"
        )

    absolute_link = Path(link_text).is_absolute()
    parts = PurePosixPath(relative).parts
    mix_parts = parts
    if (
        root_label == "build"
        and len(parts) >= 2
        and parts[1] in {"lib", "phoenix-colocated"}
        and re.fullmatch(r"[a-z][a-z0-9_]{0,63}", parts[0]) is not None
    ):
        # MIX_BUILD_ROOT owns one directory per Mix environment (normally
        # `dev` and `test`).  Normalize that compiler-owned profile prefix
        # before classifying the links Mix emits beneath it.
        mix_parts = parts[1:]
    expected_label: str | None = None
    expected_relative: str | None = None
    allow_missing = False
    if root_label == "build" and mix_parts == (
        "phoenix-colocated",
        "symphony_elixir",
        "node_modules",
    ):
        if absolute_link:
            raise ReadinessError(
                f"private Mix build link is absolute at {diagnostic}"
            )
        expected_label = "source"
        expected_relative = "assets/node_modules"
        allow_missing = True
    elif (
        root_label == "build"
        and len(mix_parts) == 3
        and mix_parts[0] == "lib"
        and re.fullmatch(r"[a-z][a-z0-9_]{0,127}", mix_parts[1]) is not None
        and mix_parts[2] in {"ebin", "include", "priv", "src"}
    ):
        if absolute_link:
            raise ReadinessError(
                f"private Mix build link is absolute at {diagnostic}"
            )
        app, leaf = mix_parts[1], mix_parts[2]
        if app == "symphony_elixir" and leaf in {"include", "priv"}:
            expected_label, expected_relative = "source", leaf
        elif app == "erlexec":
            expected_label, expected_relative = "erlexec", leaf
        elif app != "symphony_elixir":
            expected_label, expected_relative = "deps", f"{app}/{leaf}"
    elif root_label == "rebar" and len(parts) == 3 and parts[1] == "plugins":
        profile, plugin = parts[0], parts[2]
        safe_name = r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}"
        if (
            profile != "default"
            and re.fullmatch(safe_name, profile) is not None
            and re.fullmatch(safe_name, plugin) is not None
        ):
            expected_label = "rebar"
            expected_relative = f"default/plugins/{plugin}"

    if expected_label is None or expected_relative is None:
        raise ReadinessError(
            f"private build link target is not compiler-owned at {diagnostic}"
        )
    if absolute_link and root_label != "rebar":
        raise ReadinessError(
            f"private build link has a forbidden absolute target at {diagnostic}"
        )
    try:
        target_root = allowed_roots[expected_label]
        lexical_root = lexical_roots[expected_label]
    except KeyError as error:
        raise ReadinessError("private build link roots are incomplete") from error
    target_relative = expected_relative
    lexical_target = lexical_root / target_relative
    try:
        lexical_child_root = lexical_roots[root_label]
    except KeyError as error:
        raise ReadinessError("private build link roots are incomplete") from error
    lexical_child_parent = lexical_child_root / PurePosixPath(relative).parent
    expected_link_text = (
        str(lexical_target)
        if absolute_link
        else os.path.relpath(lexical_target, start=lexical_child_parent)
    )
    if link_text != expected_link_text:
        raise ReadinessError(
            f"private build link target is not compiler-owned at {diagnostic}"
        )

    present = _private_build_link_target_present(
        target_root, target_relative, diagnostic=diagnostic
    )
    if not present and not allow_missing:
        raise ReadinessError(
            f"private build link target is missing at {diagnostic}"
        )

    identity = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )
    try:
        after = child.lstat()
    except OSError as error:
        raise ReadinessError(
            f"private build link changed while inspected at {diagnostic}"
        ) from error
    if (
        identity(after) != identity(metadata)
        or not stat.S_ISLNK(after.st_mode)
        or after.st_size <= 0
        or after.st_size > MAX_BUILD_LINK_BYTES
    ):
        raise ReadinessError(
            f"private build link changed while inspected at {diagnostic}"
        )
    try:
        link_after = os.readlink(child)
    except OSError as error:
        raise ReadinessError(
            f"private build link changed while inspected at {diagnostic}"
        ) from error
    if link_after != link_text:
        raise ReadinessError(
            f"private build link changed while inspected at {diagnostic}"
        )

    return _length_prefixed(
        (
            b"absolute" if absolute_link else b"relative",
            expected_label.encode("ascii"),
            target_relative.encode("utf-8"),
            b"present" if present else b"missing",
        )
    )


def _private_roots_fingerprint(
    roots: Sequence[tuple[str, Path]],
    *,
    label: str,
    required_file_label: str,
    build_symlink_roots: Mapping[str, Path] | None = None,
    build_symlink_lexical_roots: Mapping[str, Path] | None = None,
) -> str:
    """Fingerprint a finite collection of private build-state roots."""

    if build_symlink_roots is None:
        if build_symlink_lexical_roots is not None:
            raise ReadinessError("private build link roots are incomplete")
        lexical_roots: Mapping[str, Path] = {}
    elif build_symlink_lexical_roots is None:
        lexical_roots = build_symlink_roots
    else:
        if set(build_symlink_lexical_roots) != set(build_symlink_roots):
            raise ReadinessError("private build link roots are incomplete")
        normalized: dict[str, Path] = {}
        seen_lexical: set[Path] = set()
        for root_label, root in build_symlink_lexical_roots.items():
            lexical = Path(root)
            if (
                not lexical.is_absolute()
                or lexical != Path(os.path.normpath(lexical))
                or lexical in seen_lexical
            ):
                raise ReadinessError("private build lexical roots are invalid")
            normalized[root_label] = lexical
            seen_lexical.add(lexical)
        lexical_roots = normalized

    records: list[bytes] = []
    total = 0
    count = 0
    file_labels: set[str] = set()
    for root_label, root in roots:
        try:
            metadata = root.lstat()
        except OSError as error:
            raise ReadinessError(f"private {label} root is unavailable") from error
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            raise ReadinessError(f"private {label} root is not a directory")
        remaining = MAX_DEPENDENCY_ENTRIES - count
        for child in _bounded_tree_paths(
            root, remaining, f"private {label} state"
        ):
            count += 1
            relative = child.relative_to(root).as_posix()
            child_metadata = child.lstat()
            if stat.S_ISLNK(child_metadata.st_mode):
                if label != "build" or not build_symlink_roots:
                    raise ReadinessError(
                        f"private {label} state contains a symlink at "
                        f"{root_label}/{relative}"
                    )
                kind = b"symlink"
                payload = _private_build_link_binding(
                    child,
                    child_metadata,
                    root_label=root_label,
                    relative=relative,
                    allowed_roots=build_symlink_roots,
                    lexical_roots=lexical_roots,
                )
                total += len(payload)
                if total > MAX_EXECUTABLE_BYTES:
                    raise ReadinessError(f"private {label} state exceeds its byte bound")
            elif stat.S_ISDIR(child_metadata.st_mode):
                kind = b"directory"
                payload = b""
            elif stat.S_ISREG(child_metadata.st_mode):
                kind = b"file"
                payload = _read_regular_bytes(child, MAX_EXECUTABLE_BYTES)
                file_labels.add(root_label)
                total += len(payload)
                if total > MAX_EXECUTABLE_BYTES:
                    raise ReadinessError(f"private {label} state exceeds its byte bound")
            else:
                raise ReadinessError(f"private {label} state contains a special file")
            records.extend(
                (
                    root_label.encode("ascii"),
                    relative.encode("utf-8"),
                    kind,
                    f"{stat.S_IMODE(child_metadata.st_mode):04o}".encode("ascii"),
                    payload,
                )
            )
    if required_file_label not in file_labels:
        raise ReadinessError(f"private {label} state produced no required files")
    return sha256_bytes(_length_prefixed(records))


def _private_dependency_roots_fingerprint(hex_home: Path, mix_deps: Path) -> str:
    return _private_roots_fingerprint(
        (("hex", hex_home), ("deps", mix_deps)),
        label="dependency",
        required_file_label="deps",
    )


def _private_dependency_fingerprint(sandbox: GateSandbox) -> str:
    """Fingerprint the lock-resolved private Hex cache and dependency sources."""

    return _private_dependency_roots_fingerprint(sandbox.hex_home, sandbox.mix_deps)


def _private_build_fingerprint(
    mix_build: Path,
    rebar_build: Path,
    *,
    source_root: Path | None = None,
    dependency_root: Path | None = None,
    erlexec_root: Path | None = None,
    lexical_roots: Mapping[str, Path] | None = None,
) -> str:
    external_roots = (source_root, dependency_root, erlexec_root)
    if all(root is None for root in external_roots):
        build_symlink_roots: Mapping[str, Path] | None = None
    elif any(root is None for root in external_roots):
        raise ReadinessError("private build link roots are incomplete")
    else:
        assert source_root is not None
        assert dependency_root is not None
        assert erlexec_root is not None
        build_symlink_roots = _private_build_link_roots(
            (
                ("build", mix_build),
                ("rebar", rebar_build),
                ("source", source_root),
                ("deps", dependency_root),
                ("erlexec", erlexec_root),
            )
        )
    return _private_roots_fingerprint(
        (("build", mix_build), ("rebar", rebar_build)),
        label="build",
        required_file_label="build",
        build_symlink_roots=build_symlink_roots,
        build_symlink_lexical_roots=lexical_roots,
    )


def _private_gate_build_fingerprint(sandbox: GateSandbox) -> str:
    """Validate and fingerprint every compiler-owned private build byte/link."""

    return _private_build_fingerprint(
        sandbox.mix_build,
        sandbox.rebar_build,
        source_root=sandbox.snapshot / "elixir",
        dependency_root=sandbox.mix_deps,
        erlexec_root=sandbox.erlexec_source,
        lexical_roots={
            "build": Path(SANDBOX_ROOT) / "mix-build",
            "rebar": Path(SANDBOX_ROOT) / "rebar-build",
            "source": Path(SANDBOX_WORKSPACE) / "elixir",
            "deps": Path(SANDBOX_ROOT) / "mix-deps",
            "erlexec": Path(SANDBOX_ROOT) / "erlexec-source",
        },
    )


def _private_credential_runtime_fingerprint(sandbox: GateSandbox) -> str:
    """Seal every compiled or native byte a credentialed direct task may run."""

    roots: list[tuple[str, Path]] = []
    seen_apps: set[str] = set()
    for code_path in _private_runtime_code_paths(sandbox.mix_build / "dev"):
        app = code_path.parent.name
        if app in seen_apps:
            raise ReadinessError("private credential runtime app is duplicated")
        seen_apps.add(app)
        roots.append((app, code_path))
    roots.append(("erlexec_native", sandbox.erlexec_source / "priv"))
    return _private_roots_fingerprint(
        roots,
        label="credential runtime",
        required_file_label="symphony_elixir",
    )


def _inspect_private_hex_runtime(
    sandbox: GateSandbox, *, require_cache: bool = True
) -> str:
    """Validate the disposable Hex registry output and nothing else."""

    root_metadata = sandbox.hex_runtime.lstat()
    if (
        stat.S_ISLNK(root_metadata.st_mode)
        or not stat.S_ISDIR(root_metadata.st_mode)
        or stat.S_IMODE(root_metadata.st_mode) != 0o700
        or root_metadata.st_uid != sandbox.sandbox_uid
        or root_metadata.st_gid != sandbox.sandbox_gid
    ):
        raise ReadinessError("private Hex runtime root changed")

    seen_directories: set[str] = set()
    seen_files: set[str] = set()
    records: list[bytes] = []
    for child in _bounded_tree_paths(
        sandbox.hex_runtime,
        MAX_HEX_RUNTIME_ENTRIES,
        "private Hex runtime",
    ):
        relative = child.relative_to(sandbox.hex_runtime).as_posix()
        metadata = child.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise ReadinessError("private Hex runtime contains a symlink")
        if stat.S_ISDIR(metadata.st_mode):
            if relative != "packages" or stat.S_IMODE(metadata.st_mode) != 0o700:
                raise ReadinessError("private Hex runtime contains an unexpected directory")
            if (
                metadata.st_uid != sandbox.sandbox_uid
                or metadata.st_gid != sandbox.sandbox_gid
            ):
                raise ReadinessError("private Hex runtime directory owner changed")
            seen_directories.add(relative)
            continue
        if not stat.S_ISREG(metadata.st_mode) or relative != "cache.ets":
            raise ReadinessError("private Hex runtime contains an unexpected file")
        if (
            stat.S_IMODE(metadata.st_mode) != 0o600
            or metadata.st_nlink != 1
            or metadata.st_uid != sandbox.sandbox_uid
            or metadata.st_gid != sandbox.sandbox_gid
        ):
            raise ReadinessError("private Hex runtime cache metadata changed")
        payload = _read_regular_bytes(child, MAX_HEX_CACHE_BYTES)
        if not payload:
            raise ReadinessError("private Hex runtime cache is empty")
        seen_files.add(relative)
        records.extend((relative.encode("ascii"), b"0600", payload))

    expected_files = {"cache.ets"} if require_cache else set()
    if seen_directories != {"packages"} or seen_files not in (
        expected_files,
        {"cache.ets"} if not require_cache else expected_files,
    ):
        raise ReadinessError("private Hex runtime inventory is incomplete")
    return sha256_bytes(_length_prefixed(records))


def _reset_private_hex_runtime(sandbox: GateSandbox) -> str:
    """Restore one bounded registry cache from the immutable bootstrap copy."""

    _inspect_private_hex_runtime(
        sandbox, require_cache=(sandbox.hex_runtime / "cache.ets").exists()
    )
    source = sandbox.hex_home / "cache.ets"
    source_metadata = source.lstat()
    if (
        stat.S_ISLNK(source_metadata.st_mode)
        or not stat.S_ISREG(source_metadata.st_mode)
        or stat.S_IMODE(source_metadata.st_mode) != 0o600
        or source_metadata.st_nlink != 1
        or source_metadata.st_uid != sandbox.sandbox_uid
        or source_metadata.st_gid != sandbox.sandbox_gid
    ):
        raise ReadinessError("private immutable Hex registry cache metadata is invalid")
    payload = _read_regular_bytes(source, MAX_HEX_CACHE_BYTES)
    if not payload:
        raise ReadinessError("private immutable Hex registry cache is empty")

    target = sandbox.hex_runtime / "cache.ets"
    try:
        if target.exists():
            target.unlink()
        flags = (
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        descriptor = os.open(target, flags, 0o600)
        try:
            offset = 0
            while offset < len(payload):
                written = os.write(descriptor, payload[offset:])
                if written <= 0:
                    raise OSError("short write while restoring Hex registry cache")
                offset += written
            os.fchmod(descriptor, 0o600)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        directory = os.open(
            sandbox.hex_runtime,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
        )
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except OSError as error:
        raise ReadinessError("cannot restore private Hex runtime cache") from error
    return _inspect_private_hex_runtime(sandbox)


def _prepare_gate_sandbox(
    repo_root: Path,
    snapshot: Path,
    temporary_root: Path,
    index_tree: str,
    codex_path: Path,
    index_entries: Sequence[tuple[str, str, str]],
) -> GateSandbox:
    sandbox_uid, sandbox_gid = _capture_gate_identity()
    host_home_text = os.environ.get("HOME")
    if not host_home_text or not Path(host_home_text).is_absolute():
        raise ReadinessError("a stable absolute host HOME is required for gate isolation")
    host_home = Path(host_home_text).resolve(strict=True)
    public_codex = shutil.which("codex")
    public_mise = shutil.which("mise")
    if not public_codex or not public_mise:
        raise ReadinessError("canonical Codex/mise launchers are unavailable")
    host_tool_bin = Path(public_codex).parent.resolve(strict=True)
    if Path(public_mise).parent.resolve(strict=True) != host_tool_bin:
        raise ReadinessError("canonical Codex and mise launchers require one isolated bin root")
    host_codex_package = codex_path.parent.parent
    host_mise_data = Path(
        os.environ.get("MISE_DATA_DIR", str(host_home / ".local/share/mise"))
    ).resolve(strict=True)
    for path in (host_tool_bin, host_codex_package, host_mise_data):
        if not path.is_dir():
            raise ReadinessError(f"isolated gate tool input is not a directory: {path}")

    paths = {
        name: temporary_root / name
        for name in (
            "home",
            "xdg-cache",
            "xdg-config",
            "xdg-data",
            "xdg-state",
            "hex-home",
            "hex-runtime",
            "mix-home",
            "mix-build",
            "mix-deps",
            "rebar-build",
            "coverage-output",
            "escript-output",
            "tmp",
            "mise-cache",
            "mise-config",
            "mise-state",
        )
    }
    for path in paths.values():
        _private_directory(path)
    # Hex package archives remain immutable inputs.  The runtime directory has
    # only an empty mountpoint for that archive tree plus one disposable
    # registry cache installed after the lock-resolved bootstrap.
    _private_directory(paths["hex-home"] / "packages")
    _private_directory(paths["hex-runtime"] / "packages")
    _private_directory(paths["mix-home"] / "archives")
    _private_directory(paths["mix-home"] / "elixir")

    git_dir = _prepare_private_gate_git(
        repo_root, snapshot, temporary_root, index_tree
    )
    setup_elixir, setup_elixir_tracked = _prepare_private_setup_elixir(
        snapshot, temporary_root, index_entries
    )
    erlexec_source, erlexec_tracked = _prepare_private_erlexec_source(
        snapshot, temporary_root, index_entries
    )
    host_mix_home, mix_tools, mix_rebar_version, mix_tools_fingerprint = (
        _prepare_private_mix_tools(snapshot, temporary_root, host_mise_data)
    )
    _prepare_gate_output_mountpoints(snapshot, index_entries)
    resolver_config, resolver_target = _prepare_private_resolver_config(
        temporary_root
    )
    resolver_sha256 = (
        sha256_regular_file(resolver_config, 64 * 1024)
        if resolver_config is not None
        else None
    )
    return GateSandbox(
        temporary_root=temporary_root,
        sandbox_uid=sandbox_uid,
        sandbox_gid=sandbox_gid,
        snapshot=snapshot,
        setup_elixir=setup_elixir,
        setup_elixir_tracked=setup_elixir_tracked,
        git_dir=git_dir,
        home=paths["home"],
        xdg_cache=paths["xdg-cache"],
        xdg_config=paths["xdg-config"],
        xdg_data=paths["xdg-data"],
        xdg_state=paths["xdg-state"],
        hex_home=paths["hex-home"],
        hex_runtime=paths["hex-runtime"],
        mix_home=paths["mix-home"],
        mix_tools=mix_tools,
        mix_rebar_version=mix_rebar_version,
        mix_tools_fingerprint=mix_tools_fingerprint,
        mix_build=paths["mix-build"],
        mix_deps=paths["mix-deps"],
        rebar_build=paths["rebar-build"],
        erlexec_source=erlexec_source,
        erlexec_tracked=erlexec_tracked,
        coverage_output=paths["coverage-output"],
        escript_output=paths["escript-output"],
        tmp=paths["tmp"],
        mise_cache=paths["mise-cache"],
        mise_config=paths["mise-config"],
        mise_state=paths["mise-state"],
        host_home=host_home,
        host_tool_bin=host_tool_bin,
        host_codex_package=host_codex_package,
        host_mise_data=host_mise_data,
        host_mix_home=host_mix_home,
        resolver_config=resolver_config,
        resolver_target=resolver_target,
        resolver_sha256=resolver_sha256,
    )


def _safe_gate_environment(
    sandbox: GateSandbox,
    *,
    hex_offline: bool = True,
    use_bootstrap_hex: bool = False,
) -> dict[str, str]:
    root = SANDBOX_ROOT
    environment = {
        "COLUMNS": "80",
        "ERL_CRASH_DUMP": f"{root}/tmp/erl_crash.dump",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_OPTIONAL_LOCKS": "0",
        "HEX_HOME": (
            f"{root}/hex-home" if use_bootstrap_hex else f"{root}/hex-runtime"
        ),
        "HOME": f"{root}/home",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "LOGNAME": os.environ.get("LOGNAME", "codexdev"),
        "MAKEFLAGS": "-s --no-print-directory",
        "MISE_CACHE_DIR": f"{root}/mise-cache",
        "MISE_CONFIG_DIR": f"{root}/mise-config",
        "MISE_DATA_DIR": str(sandbox.host_mise_data),
        "MISE_OFFLINE": "1",
        "MISE_STATE_DIR": f"{root}/mise-state",
        "MIX_ARCHIVES": f"{root}/mix-home/archives",
        "MIX_HOME": f"{root}/mix-home",
        "MIX_BUILD_ROOT": f"{root}/mix-build",
        "MIX_DEPS_PATH": f"{root}/mix-deps",
        "MIX_REBAR3": (
            f"{root}/mix-home/elixir/{sandbox.mix_rebar_version}/rebar3"
        ),
        "NO_COLOR": "1",
        "PATH": f"{sandbox.host_tool_bin}:/usr/local/bin:/usr/bin:/bin",
        "PYTHONDONTWRITEBYTECODE": "1",
        "REBAR_BASE_DIR": f"{root}/rebar-build",
        "SHELL": "/bin/sh",
        "SYMPHONY_FIXTURE_LOG_FILE": f"{root}/tmp/symphony.log",
        "SYMPHONY_CODEX_CONFORMANCE_BIN": f"{root}/tools/bin/codex",
        "SYMPHONY_ERLEXEC_PATH": f"{root}/erlexec-source",
        "SYMPHONY_READINESS_OUTER_SANDBOX": "1",
        "SYMPHONY_SANDBOX_GID": str(sandbox.sandbox_gid),
        "SYMPHONY_SANDBOX_UID": str(sandbox.sandbox_uid),
        "TERM": "dumb",
        "TMPDIR": f"{root}/tmp",
        "TZ": "UTC",
        "USER": os.environ.get("USER", "codexdev"),
        "XDG_CACHE_HOME": f"{root}/xdg-cache",
        "XDG_CONFIG_HOME": f"{root}/xdg-config",
        "XDG_DATA_HOME": f"{root}/xdg-data",
        "XDG_STATE_HOME": f"{root}/xdg-state",
    }
    if hex_offline:
        environment["HEX_OFFLINE"] = "1"
    return environment


def _sandbox_command(
    sandbox: GateSandbox,
    command: Sequence[str],
    *,
    chdir: str = SANDBOX_WORKSPACE,
    network_disabled: bool = True,
    writable_git: bool = False,
    writable_erlexec: bool = False,
    writable_project_outputs: bool = False,
    writable_dependencies: bool = False,
    writable_mix_build: bool = True,
    writable_rebar_build: bool = True,
    writable_hex_runtime: bool = False,
    writable_mix_home: bool = False,
    writable_setup_elixir: bool = False,
) -> tuple[str, ...]:
    root = SANDBOX_ROOT
    arguments = [
        "bwrap",
        "--die-with-parent",
        "--new-session",
        "--unshare-user",
        "--uid",
        str(sandbox.sandbox_uid),
        "--gid",
        str(sandbox.sandbox_gid),
        "--unshare-pid",
    ]
    if network_disabled:
        arguments.append("--unshare-net")
    arguments.extend(
        (
        "--ro-bind",
        "/",
        "/",
        "--tmpfs",
        "/run",
        "--dev",
        "/dev",
        "--tmpfs",
        "/dev/shm",
        "--proc",
        "/proc",
        "--dir",
        root,
        "--dir",
        SANDBOX_WORKSPACE,
        "--ro-bind",
        str(sandbox.snapshot),
        SANDBOX_WORKSPACE,
        "--bind" if writable_git else "--ro-bind",
        str(sandbox.git_dir),
        f"{SANDBOX_WORKSPACE}/.git",
        "--dir",
        f"{root}/tools",
        "--dir",
        f"{root}/tools/lib",
        "--dir",
        f"{root}/tools/lib/node_modules",
        "--dir",
        f"{root}/tools/lib/node_modules/@openai",
        "--dir",
        f"{root}/tools/share",
        "--ro-bind",
        str(sandbox.host_tool_bin),
        f"{root}/tools/bin",
        "--ro-bind",
        str(sandbox.host_codex_package),
        f"{root}/tools/lib/node_modules/@openai/codex",
        "--ro-bind",
        str(sandbox.host_mise_data),
        f"{root}/tools/share/mise",
        )
    )
    if writable_setup_elixir:
        arguments.extend(
            (
                "--bind",
                str(sandbox.setup_elixir),
                f"{SANDBOX_WORKSPACE}/elixir",
            )
        )
        for relative, _mode, _sha256 in sandbox.setup_elixir_tracked:
            arguments.extend(
                (
                    "--ro-bind",
                    str(sandbox.setup_elixir / relative),
                    f"{SANDBOX_WORKSPACE}/elixir/{relative}",
                )
            )
    if sandbox.resolver_config is not None:
        if sandbox.resolver_target is None:
            raise ReadinessError("private resolver mount lacks its target")
        resolver_parent = PurePosixPath(sandbox.resolver_target).parent
        resolver_parents: list[PurePosixPath] = []
        while resolver_parent != PurePosixPath("/run"):
            resolver_parents.append(resolver_parent)
            resolver_parent = resolver_parent.parent
        for parent in reversed(resolver_parents):
            arguments.extend(("--dir", parent.as_posix()))
        arguments.extend(
            (
                "--ro-bind",
                str(sandbox.resolver_config),
                sandbox.resolver_target,
            )
        )
    erlexec_operation = "--bind" if writable_erlexec else "--ro-bind"
    arguments.extend(
        (
            erlexec_operation,
            str(sandbox.erlexec_source),
            f"{root}/erlexec-source",
        )
    )
    if writable_erlexec:
        for relative, _mode, _sha256 in sandbox.erlexec_tracked:
            arguments.extend(
                (
                    "--ro-bind",
                    str(sandbox.erlexec_source / relative),
                    f"{root}/erlexec-source/{relative}",
                )
            )
    output_operation = "--bind" if writable_project_outputs else "--ro-bind"
    arguments.extend(
        (
            output_operation,
            str(sandbox.coverage_output),
            f"{SANDBOX_WORKSPACE}/{GATE_COVER_RELATIVE}",
            output_operation,
            str(sandbox.escript_output),
            f"{SANDBOX_WORKSPACE}/{GATE_ESCRIPT_RELATIVE}",
        )
    )
    writable = {
        "home": sandbox.home,
        "xdg-cache": sandbox.xdg_cache,
        "xdg-config": sandbox.xdg_config,
        "xdg-data": sandbox.xdg_data,
        "xdg-state": sandbox.xdg_state,
        "tmp": sandbox.tmp,
        "mise-cache": sandbox.mise_cache,
        "mise-config": sandbox.mise_config,
        "mise-state": sandbox.mise_state,
    }
    for name, source in writable.items():
        arguments.extend(("--bind", str(source), f"{root}/{name}"))
    for name, source, can_write in (
        ("mix-build", sandbox.mix_build, writable_mix_build),
        ("rebar-build", sandbox.rebar_build, writable_rebar_build),
    ):
        arguments.extend(
            ("--bind" if can_write else "--ro-bind", str(source), f"{root}/{name}")
        )
    arguments.extend(
        (
            "--bind" if writable_mix_home else "--ro-bind",
            str(sandbox.mix_home),
            f"{root}/mix-home",
            "--ro-bind",
            str(sandbox.mix_tools / "archives"),
            f"{root}/mix-home/archives",
            "--ro-bind",
            str(sandbox.mix_tools / "elixir"),
            f"{root}/mix-home/elixir",
        )
    )
    dependency_operation = "--bind" if writable_dependencies else "--ro-bind"
    for name, source in (
        ("hex-home", sandbox.hex_home),
        ("mix-deps", sandbox.mix_deps),
    ):
        arguments.extend((dependency_operation, str(source), f"{root}/{name}"))
    arguments.extend(
        (
            "--bind" if writable_hex_runtime else "--ro-bind",
            str(sandbox.hex_runtime),
            f"{root}/hex-runtime",
            "--ro-bind",
            str(sandbox.hex_home / "packages"),
            f"{root}/hex-runtime/packages",
        )
    )
    # Bind every explicit source while its host pathname is still visible,
    # then mask the broad host locations that contained those sources.
    arguments.extend(
        (
            "--tmpfs",
            str(sandbox.host_home),
            "--tmpfs",
            "/tmp",
            "--tmpfs",
            "/var/tmp",
        )
    )
    # Mise installations retain absolute paths under the user's tool root.
    # Re-expose only the three already-isolated tool mounts at those lexical
    # locations after masking the rest of HOME.
    lexical_targets = (
        sandbox.host_tool_bin,
        sandbox.host_codex_package,
        sandbox.host_mise_data,
    )
    masked_targets: list[Path] = []
    target_parents: set[Path] = set()
    for target in lexical_targets:
        try:
            target.relative_to(sandbox.host_home)
        except ValueError:
            continue
        masked_targets.append(target)
        parent = target.parent
        while parent != sandbox.host_home:
            target_parents.add(parent)
            parent = parent.parent
    for parent in sorted(target_parents, key=lambda path: len(path.parts)):
        arguments.extend(("--dir", str(parent)))
    for target in masked_targets:
        arguments.extend(("--ro-bind", str(target), str(target)))
    try:
        host_mix_relative = sandbox.host_mix_home.relative_to(sandbox.host_mise_data)
    except ValueError as error:
        raise ReadinessError("host Mix home escaped the isolated mise data root") from error
    arguments.extend(
        (
            "--tmpfs",
            f"{root}/tools/share/mise/{host_mix_relative.as_posix()}",
            "--tmpfs",
            str(sandbox.host_mix_home),
        )
    )
    allowed_chdirs = {
        SANDBOX_WORKSPACE,
        f"{SANDBOX_ROOT}/tmp/sealed-codex",
        f"{SANDBOX_ROOT}/tmp/sealed-linear",
    }
    if chdir not in allowed_chdirs:
        raise ReadinessError("gate sandbox working directory is not allowlisted")
    arguments.extend(("--chdir", chdir, "--", *map(str, command)))
    return tuple(arguments)


def _sandbox_runtime_code_paths(
    sandbox: GateSandbox, host_code_paths: Sequence[Path]
) -> tuple[Path, ...]:
    translated: list[Path] = []
    for code_path in host_code_paths:
        try:
            relative = code_path.relative_to(sandbox.mix_build)
        except ValueError as error:
            raise ReadinessError(
                "private runtime code path escaped the gate build root"
            ) from error
        translated.append(Path(SANDBOX_ROOT) / "mix-build" / relative)
    return tuple(translated)


def _sealed_codex_task_command(
    sandbox: GateSandbox,
    tools: PrivateLiveRuntimeTools,
    host_code_paths: Sequence[Path],
    native_codex: Path,
) -> tuple[str, ...]:
    host_command = _live_capability_task_command(
        tools, host_code_paths, str(native_codex), sandbox.snapshot
    )
    translations = {
        str(host): str(sandbox_path)
        for host, sandbox_path in zip(
            host_code_paths,
            _sandbox_runtime_code_paths(sandbox, host_code_paths),
            strict=True,
        )
    }
    translations.update(
        {
            str(sandbox.snapshot): SANDBOX_WORKSPACE,
            str(_private_live_workflow_path(sandbox.snapshot)): (
                f"{SANDBOX_WORKSPACE}/elixir/WORKFLOW.md"
            ),
        }
    )
    command = tuple(translations.get(argument, argument) for argument in host_command)
    if command.count(LIVE_TASK_ENTRYPOINT) != 1 or "mix" in command or "mise" in command:
        raise ReadinessError("sealed Codex task command is not project-independent")
    return command


def _sealed_linear_task_command(
    sandbox: GateSandbox,
    tools: PrivateLiveRuntimeTools,
    host_code_paths: Sequence[Path],
) -> tuple[str, ...]:
    _private_live_workflow_path(sandbox.snapshot)
    command: list[str] = [str(tools.elixir_runner)]
    for code_path in _sandbox_runtime_code_paths(sandbox, host_code_paths):
        command.extend(("-pa", str(code_path)))
    command.extend(
        (
            "-e",
            LINEAR_TASK_ENTRYPOINT,
            "--",
            "--format",
            "json",
            "--validation-fixtures",
            "--workflow",
            f"{SANDBOX_WORKSPACE}/elixir/WORKFLOW.md",
        )
    )
    if (
        len(command) > MAX_COMMAND_ARGUMENTS
        or command.count(LINEAR_TASK_ENTRYPOINT) != 1
        or "mix" in command
        or "mise" in command
        or any(
            not argument
            or "\x00" in argument
            or len(argument.encode("utf-8")) > MAX_COMMAND_ARGUMENT_BYTES
            for argument in command
        )
    ):
        raise ReadinessError("sealed Linear task command is invalid")
    return tuple(command)


def _credentialed_codex_sandbox_command(
    sandbox: GateSandbox,
    tools: PrivateLiveRuntimeTools,
    host_code_paths: Sequence[Path],
    native_codex: Path,
    credential_root: Path,
) -> tuple[str, ...]:
    try:
        if credential_root.parent != sandbox.temporary_root:
            raise ReadinessError("sealed Codex credential root escaped the gate root")
        for relative in ("codex-home/auth.json", f"xdg-state/{IDENTITY_KEY_RELATIVE}"):
            path = credential_root / relative
            metadata = path.lstat()
            if (
                stat.S_ISLNK(metadata.st_mode)
                or not stat.S_ISREG(metadata.st_mode)
                or stat.S_IMODE(metadata.st_mode) != 0o600
                or metadata.st_nlink != 1
            ):
                raise ReadinessError("sealed Codex credential input is invalid")
    except OSError as error:
        raise ReadinessError("sealed Codex credential input is unavailable") from error
    command = _sealed_codex_task_command(
        sandbox, tools, host_code_paths, native_codex
    )
    arguments = list(
        _sandbox_command(
            sandbox,
            command,
            chdir=f"{SANDBOX_ROOT}/tmp/sealed-codex",
            network_disabled=False,
            writable_mix_build=False,
            writable_rebar_build=False,
        )
    )
    try:
        mask_index = next(
            index
            for index in range(len(arguments) - 1)
            if arguments[index] == "--tmpfs"
            and arguments[index + 1] == str(sandbox.host_home)
        )
    except StopIteration as error:
        raise ReadinessError("sealed Codex sandbox lacks the host-secret mask") from error
    target = f"{SANDBOX_ROOT}/direct-credentials"
    arguments[mask_index:mask_index] = [
        "--dir",
        target,
        "--bind",
        str(credential_root),
        target,
    ]
    return tuple(arguments)


def _linear_broker_socket_fingerprint(repo_root: Path) -> tuple[Path, tuple[int, ...]]:
    if os.environ.get("LINEAR_API_KEY") is not None:
        raise ReadinessError("raw Linear credential reached the readiness publisher")
    raw_path = os.environ.get(LINEAR_BROKER_ENVIRONMENT_KEY)
    if (
        not raw_path
        or "\x00" in raw_path
        or len(raw_path.encode("utf-8")) > MAX_COMMAND_ARGUMENT_BYTES
    ):
        raise ReadinessError("sealed Linear broker is unavailable")
    path = Path(raw_path)
    if not path.is_absolute() or path.parent == path:
        raise ReadinessError("sealed Linear broker path is invalid")
    try:
        parent = path.parent.lstat()
        metadata = path.lstat()
        canonical_parent = path.parent.resolve(strict=True)
        canonical_repo = repo_root.resolve(strict=True)
    except OSError as error:
        raise ReadinessError("sealed Linear broker is unavailable") from error
    try:
        canonical_parent.relative_to(canonical_repo)
    except ValueError:
        pass
    else:
        raise ReadinessError("sealed Linear broker entered the repository")
    if (
        stat.S_ISLNK(parent.st_mode)
        or not stat.S_ISDIR(parent.st_mode)
        or stat.S_IMODE(parent.st_mode) != 0o700
        or parent.st_uid != os.getuid()
        or parent.st_gid != os.getgid()
        or stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISSOCK(metadata.st_mode)
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or metadata.st_uid != os.getuid()
        or metadata.st_gid != os.getgid()
        or metadata.st_nlink != 1
    ):
        raise ReadinessError("sealed Linear broker metadata is invalid")
    fingerprint = (
        parent.st_dev,
        parent.st_ino,
        parent.st_mode,
        parent.st_uid,
        parent.st_gid,
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_gid,
        metadata.st_nlink,
    )
    return path, fingerprint


def _linear_task_environment(
    sandbox: GateSandbox, tools: PrivateLiveRuntimeTools
) -> dict[str, str]:
    environment = {
        key: value
        for key, value in _safe_gate_environment(sandbox).items()
        if key in LIVE_TASK_ENVIRONMENT_KEYS or key == "XDG_STATE_HOME"
    }
    environment.update(
        {
            "ERL_ROOTDIR": str(tools.erlang_root),
            "PATH": f"{tools.erlang_root / 'bin'}:/usr/bin:/bin",
            "SHELL": "/bin/sh",
            LINEAR_BROKER_ENVIRONMENT_KEY: LINEAR_BROKER_SANDBOX_PATH,
        }
    )
    forbidden_prefixes = ("HEX", "MISE", "MIX", "REBAR", "SYMPHONY_ERLEXEC")
    if any(key.startswith(forbidden_prefixes) for key in environment):
        raise ReadinessError("sealed Linear task retained a build selector")
    return environment


def _brokered_linear_sandbox_command(
    sandbox: GateSandbox,
    command: Sequence[str],
    broker_socket: Path,
) -> tuple[str, ...]:
    arguments = list(
        _sandbox_command(
            sandbox,
            command,
            chdir=f"{SANDBOX_ROOT}/tmp/sealed-linear",
            network_disabled=True,
            writable_mix_build=False,
            writable_rebar_build=False,
        )
    )
    try:
        command_boundary = arguments.index("--chdir")
    except ValueError as error:
        raise ReadinessError("sealed Linear sandbox lacks a command boundary") from error
    arguments[command_boundary:command_boundary] = [
        "--dir",
        str(PurePosixPath(LINEAR_BROKER_SANDBOX_PATH).parent),
        "--ro-bind",
        str(broker_socket),
        LINEAR_BROKER_SANDBOX_PATH,
    ]
    if "--unshare-net" not in arguments:
        raise ReadinessError("sealed Linear sandbox retained direct network access")
    return tuple(arguments)


def _installed_codex_for_static(
    repo_root: Path, static_basis: Mapping[str, Any], codex_command: str
) -> dict[str, str]:
    static = _mapping(static_basis, "sealed Codex static basis")
    lock = _mapping(read_json_bounded(repo_root / "CODEX_LOCK.json"), "Codex lock")
    selected = next(
        (
            entry
            for entry in _list(lock.get("platforms"), "Codex lock platforms", 64)
            if isinstance(entry, dict)
            and entry.get("target") == static["codex"]["target"]
        ),
        None,
    )
    if selected is None:
        raise ReadinessError("sealed Codex target is absent from CODEX_LOCK")
    installed = verify_installed_codex(lock, selected, codex_command)
    for key in ("launcherSha256", "nativeSha256", "versionOutput"):
        if installed[key] != static["codex"][key]:
            raise ReadinessError("sealed Codex executable differs from the static basis")
    return installed


def _receive_live_supervisor_bytes(connection: socket.socket, length: int) -> bytes:
    if length <= 0 or length > MAX_LIVE_SUPERVISOR_FRAME_BYTES:
        raise ReadinessError("live capability supervisor frame exceeds its bound")
    chunks: list[bytes] = []
    remaining = length
    while remaining:
        chunk = connection.recv(min(64 * 1024, remaining))
        if not chunk:
            raise ReadinessError("live capability supervisor frame is truncated")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _live_supervisor_request_context(
    repo_root: Path,
    sandbox: GateSandbox,
    *,
    index_tree: str,
) -> tuple[Path, tuple[int, ...], Path, str]:
    """Revalidate the public half of one transient supervisor session."""

    protected_linear_selector = "_".join(("SYMPHONY", "LINEAR", "ENV", "FILE"))
    for key in (
        "LINEAR_API_KEY",
        protected_linear_selector,
        "CODEX_HOME",
    ):
        if os.environ.get(key) is not None:
            raise ReadinessError("a credential selector reached the readiness publisher")
    expected_index_tree = _commit(index_tree, "supervisor index tree")
    if _git_text(repo_root, ["write-tree"]) != expected_index_tree:
        raise ReadinessError("live capability supervisor index tree changed")
    boundary = _live_supervisor_boundary(repo_root)
    if boundary is None:
        raise ReadinessError("live capability supervisor is unavailable")
    socket_path, shared_parent, boundary_fingerprint = boundary
    try:
        temporary_root = sandbox.temporary_root.resolve(strict=True)
        if (
            temporary_root.parent != shared_parent
            or re.fullmatch(r"symphony-readiness-full-[A-Za-z0-9_-]{1,80}", temporary_root.name)
            is None
        ):
            raise ReadinessError("live capability workspace is not supervisor-shared")
    except OSError as error:
        raise ReadinessError("live capability workspace is unavailable") from error
    return socket_path, boundary_fingerprint, temporary_root, expected_index_tree


def _exchange_live_supervisor_request(
    socket_path: Path,
    request: Mapping[str, Any],
) -> dict[str, Any]:
    """Exchange one bounded public frame with the trusted local supervisor."""

    if LIVE_SUPERVISOR_CLIENT_TIMEOUT_SECONDS <= LIVE_SUPERVISOR_SESSION_BOUND_SECONDS:
        raise ReadinessError("live capability supervisor timeout contract is invalid")
    payload = json.dumps(
        request, allow_nan=False, separators=(",", ":"), sort_keys=True
    ).encode("utf-8")
    if not payload or len(payload) > 64 * 1024:
        raise ReadinessError("live capability supervisor request exceeds its bound")
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(LIVE_SUPERVISOR_CLIENT_TIMEOUT_SECONDS)
            connection.connect(str(socket_path))
            connection.sendall(struct.pack("!I", len(payload)) + payload)
            raw_length = _receive_live_supervisor_bytes(connection, 4)
            length = struct.unpack("!I", raw_length)[0]
            response_payload = _receive_live_supervisor_bytes(connection, length)
            trailing = connection.recv(1)
            if trailing:
                raise ReadinessError("live capability supervisor sent trailing data")
    except (OSError, struct.error) as error:
        raise ReadinessError("live capability supervisor request failed") from error
    return _mapping(
        decode_json_bytes(response_payload, "live capability supervisor response"),
        "live capability supervisor response",
    )


def _seal_live_supervisor_runtime(
    repo_root: Path,
    sandbox: GateSandbox,
    *,
    index_tree: str,
) -> LiveSupervisorSeal:
    """Ask the trusted supervisor to create its own exact executable seal."""

    socket_path, boundary_fingerprint, _temporary_root, expected_index_tree = (
        _live_supervisor_request_context(
            repo_root,
            sandbox,
            index_tree=index_tree,
        )
    )
    response = _exchange_live_supervisor_request(
        socket_path,
        {
            "indexTree": expected_index_tree,
            "op": "seal",
            "v": LIVE_SUPERVISOR_PROTOCOL_VERSION,
        },
    )
    _exact_keys(
        response,
        {"indexTree", "op", "sealId", "v"},
        "live capability supervisor seal response",
    )
    seal_id = response["sealId"]
    if (
        response["v"] != LIVE_SUPERVISOR_PROTOCOL_VERSION
        or response["op"] != "seal"
        or _commit(response["indexTree"], "supervisor seal index tree")
        != expected_index_tree
        or not isinstance(seal_id, str)
        or re.fullmatch(r"[0-9a-f]{64}", seal_id) is None
    ):
        raise ReadinessError("live capability supervisor seal binding is invalid")
    after = _live_supervisor_boundary(repo_root)
    if (
        after is None
        or after[2] != boundary_fingerprint
        or _git_text(repo_root, ["write-tree"]) != expected_index_tree
    ):
        raise ReadinessError("live capability supervisor boundary changed")
    return LiveSupervisorSeal(
        seal_id=seal_id,
        index_tree=expected_index_tree,
    )


def _request_live_supervisor(
    repo_root: Path,
    sandbox: GateSandbox,
    *,
    operation: str,
    index_tree: str,
    supervisor_seal: LiveSupervisorSeal,
    source_sha256: str,
    tool_runtime_fingerprint: str,
    static_basis_sha256: str | None,
    installed_codex: Mapping[str, str] | None,
) -> dict[str, Any]:
    """Request one exact child under a supervisor-owned executable seal."""

    if operation not in {"codex", "linear"}:
        raise ReadinessError("live capability supervisor operation is invalid")
    socket_path, boundary_fingerprint, _temporary_root, expected_index_tree = (
        _live_supervisor_request_context(
            repo_root,
            sandbox,
            index_tree=index_tree,
        )
    )
    if (
        not isinstance(supervisor_seal, LiveSupervisorSeal)
        or supervisor_seal.index_tree != expected_index_tree
        or re.fullmatch(r"[0-9a-f]{64}", supervisor_seal.seal_id) is None
    ):
        raise ReadinessError("live capability supervisor seal is invalid")
    installed: dict[str, str] | None
    if operation == "codex":
        if static_basis_sha256 is None or installed_codex is None:
            raise ReadinessError("Codex supervisor request lacks its static binding")
        static_basis_sha256 = _sha256(
            static_basis_sha256, "supervisor static basis"
        )
        installed = {
            key: installed_codex[key]
            for key in ("launcherSha256", "nativeSha256", "versionOutput")
        }
    else:
        if static_basis_sha256 is not None or installed_codex is not None:
            raise ReadinessError("Linear supervisor request retained Codex evidence")
        installed = None
    request = {
        "indexTree": expected_index_tree,
        "installedCodex": installed,
        "op": operation,
        "sealId": supervisor_seal.seal_id,
        "sourceSha256": _sha256(source_sha256, "supervisor source"),
        "staticBasisSha256": static_basis_sha256,
        "toolRuntimeFingerprint": _sha256(
            tool_runtime_fingerprint, "supervisor tool runtime fingerprint"
        ),
        "v": LIVE_SUPERVISOR_PROTOCOL_VERSION,
    }
    response = _exchange_live_supervisor_request(
        socket_path,
        request,
    )
    _exact_keys(
        response,
        {"op", "record", "sealId", "v"},
        "live capability supervisor response",
    )
    if (
        response["v"] != LIVE_SUPERVISOR_PROTOCOL_VERSION
        or response["op"] != operation
        or response["sealId"] != supervisor_seal.seal_id
    ):
        raise ReadinessError("live capability supervisor response binding is invalid")
    record = copy.deepcopy(_mapping(response["record"], "live capability record"))
    _assert_public_tree(record, "live capability supervisor record")
    after = _live_supervisor_boundary(repo_root)
    if (
        after is None
        or after[2] != boundary_fingerprint
        or _git_text(repo_root, ["write-tree"]) != expected_index_tree
    ):
        raise ReadinessError("live capability supervisor boundary changed")
    return record


def _execute_sealed_codex_gate(
    repo_root: Path,
    sandbox: GateSandbox,
    static_basis: Mapping[str, Any],
    codex_command: str,
    expected_index_tree: str,
    supervisor_seal: LiveSupervisorSeal,
    expected_build_fingerprint: str,
    expected_credential_runtime_fingerprint: str,
) -> tuple[int, bytes, bytes]:
    if _private_gate_build_fingerprint(sandbox) != expected_build_fingerprint:
        raise ReadinessError("sealed Codex build inputs differ before discovery")
    if (
        _private_credential_runtime_fingerprint(sandbox)
        != expected_credential_runtime_fingerprint
        or not isinstance(supervisor_seal, LiveSupervisorSeal)
        or supervisor_seal.index_tree != expected_index_tree
    ):
        raise ReadinessError("sealed Codex credential runtime changed before discovery")
    installed = _installed_codex_for_static(repo_root, static_basis, codex_command)
    tools = _select_private_live_runtime_tools(
        sandbox.snapshot, sandbox.host_mise_data
    )
    tools_fingerprint = _inspect_private_live_runtime_tools(tools)
    code_paths = _private_runtime_code_paths(sandbox.mix_build / "dev")
    code_paths_before = tuple(code_paths)
    runtime_root = sandbox.tmp / "sealed-codex"
    _private_directory(runtime_root)
    _assert_empty_private_runtime_root(runtime_root)
    static_basis_sha256 = sha256_bytes(canonical_json_bytes(static_basis))
    record = _request_live_supervisor(
        repo_root,
        sandbox,
        operation="codex",
        index_tree=expected_index_tree,
        supervisor_seal=supervisor_seal,
        source_sha256=static_basis["checkout"]["source"]["sha256"],
        tool_runtime_fingerprint=tools_fingerprint,
        static_basis_sha256=static_basis_sha256,
        installed_codex=installed,
    )
    validate_codex_probe_record(record, static_basis)
    public_stdout = (
        CODEX_PROBE_JSON_PREFIX.encode("ascii")
        + json.dumps(
            record, allow_nan=False, separators=(",", ":"), sort_keys=True
        ).encode("utf-8")
        + b"\n"
    )
    if (
        _inspect_private_live_runtime_tools(tools) != tools_fingerprint
        or _private_runtime_code_paths(sandbox.mix_build / "dev") != code_paths_before
        or _private_credential_runtime_fingerprint(sandbox)
        != expected_credential_runtime_fingerprint
        or _private_gate_build_fingerprint(sandbox) != expected_build_fingerprint
    ):
        raise ReadinessError("sealed Codex runtime inputs changed")
    _assert_empty_private_runtime_root(runtime_root)
    after = _installed_codex_for_static(repo_root, static_basis, codex_command)
    for key in ("launcherPath", "launcherSha256", "nativePath", "nativeSha256", "versionOutput"):
        if after[key] != installed[key]:
            raise ReadinessError("installed Codex changed during sealed discovery")
    return 0, public_stdout, b""


def _execute_sealed_linear_gate(
    repo_root: Path,
    sandbox: GateSandbox,
    source_sha256: str,
    expected_index_tree: str,
    supervisor_seal: LiveSupervisorSeal,
    expected_build_fingerprint: str,
    expected_credential_runtime_fingerprint: str,
) -> tuple[int, bytes, bytes]:
    if _private_gate_build_fingerprint(sandbox) != expected_build_fingerprint:
        raise ReadinessError("sealed Linear build inputs differ before discovery")
    if (
        _private_credential_runtime_fingerprint(sandbox)
        != expected_credential_runtime_fingerprint
        or not isinstance(supervisor_seal, LiveSupervisorSeal)
        or supervisor_seal.index_tree != expected_index_tree
    ):
        raise ReadinessError("sealed Linear credential runtime changed before discovery")
    tools = _select_private_live_runtime_tools(
        sandbox.snapshot, sandbox.host_mise_data
    )
    tools_fingerprint = _inspect_private_live_runtime_tools(tools)
    code_paths = _private_runtime_code_paths(sandbox.mix_build / "dev")
    code_paths_before = tuple(code_paths)
    runtime_root = sandbox.tmp / "sealed-linear"
    _private_directory(runtime_root)
    _assert_empty_private_runtime_root(runtime_root)
    record = _request_live_supervisor(
        repo_root,
        sandbox,
        operation="linear",
        index_tree=expected_index_tree,
        supervisor_seal=supervisor_seal,
        source_sha256=source_sha256,
        tool_runtime_fingerprint=tools_fingerprint,
        static_basis_sha256=None,
        installed_codex=None,
    )
    validate_linear_probe_record(record, source_sha256)
    public_stdout = (
        LINEAR_PROBE_JSON_PREFIX.encode("ascii")
        + json.dumps(
            record, allow_nan=False, separators=(",", ":"), sort_keys=True
        ).encode("utf-8")
        + b"\n"
    )
    if (
        _inspect_private_live_runtime_tools(tools) != tools_fingerprint
        or _private_runtime_code_paths(sandbox.mix_build / "dev") != code_paths_before
        or _private_credential_runtime_fingerprint(sandbox)
        != expected_credential_runtime_fingerprint
        or _private_gate_build_fingerprint(sandbox) != expected_build_fingerprint
    ):
        raise ReadinessError("sealed Linear runtime inputs changed")
    _assert_empty_private_runtime_root(runtime_root)
    return 0, public_stdout, b""


def _run_gate_sandbox_canary(
    repo_root: Path, sandbox: GateSandbox, metadata_fingerprint: str
) -> None:
    if (
        _inspect_private_mix_tools(sandbox.mix_tools, sandbox.mix_rebar_version)
        != sandbox.mix_tools_fingerprint
    ):
        raise ReadinessError("private Mix tool inputs changed before sandbox canary")
    _inspect_private_plt_outputs(sandbox, require_empty=True)
    private_metadata_fingerprint = _git_metadata_fingerprint(
        sandbox.snapshot,
        git_dir=sandbox.git_dir,
        work_tree=sandbox.snapshot,
    )
    environment = _safe_gate_environment(sandbox)
    environment["SYMPHONY_SANDBOX_HOST_TEMPORARY_ROOT"] = str(
        sandbox.temporary_root
    )
    environment["SYMPHONY_SANDBOX_PRIVATE_MIX_HOME"] = (
        f"{SANDBOX_ROOT}/mix-home"
    )
    environment["SYMPHONY_SANDBOX_HOST_MIX_HOME"] = str(sandbox.host_mix_home)
    environment["SYMPHONY_SANDBOX_HOST_MIX_ALIAS"] = (
        f"{SANDBOX_ROOT}/tools/share/mise/"
        f"{sandbox.host_mix_home.relative_to(sandbox.host_mise_data).as_posix()}"
    )
    returncode, stdout, stderr = run_bounded_command(
        _sandbox_command(
            sandbox,
            ("python3", "-c", SANDBOX_CANARY_SCRIPT),
            writable_git=True,
        ),
        cwd=sandbox.temporary_root,
        environment=environment,
        timeout_seconds=30.0,
        max_output_bytes=64 * 1024,
    )
    if returncode != 0 or stdout != SANDBOX_CANARY_OUTPUT or stderr:
        raise ReadinessError("read-only gate sandbox isolation canary failed")
    returncode, stdout, stderr = run_bounded_command(
        _sandbox_command(
            sandbox,
            (
                "mise",
                "exec",
                "-C",
                "elixir",
                "--",
                "elixir",
                "-e",
                MIX_TOOL_CANARY_SCRIPT,
            ),
        ),
        cwd=sandbox.temporary_root,
        environment=environment,
        timeout_seconds=30.0,
        max_output_bytes=64 * 1024,
    )
    if returncode != 0 or stdout != MIX_TOOL_CANARY_OUTPUT or stderr:
        raise ReadinessError("private Mix tool resolution canary failed")
    if _git_metadata_fingerprint(repo_root) != metadata_fingerprint:
        raise ReadinessError("gate sandbox canary changed original Git metadata")
    if (
        _git_metadata_fingerprint(
            sandbox.snapshot,
            git_dir=sandbox.git_dir,
            work_tree=sandbox.snapshot,
        )
        != private_metadata_fingerprint
    ):
        raise ReadinessError("gate sandbox canary changed private Git semantics")


def _bootstrap_private_gate_dependencies(
    sandbox: GateSandbox,
) -> tuple[str, str, str]:
    """Bootstrap dependencies, then compile the sealed app without credentials."""

    dependency_command = (
        "mise",
        "exec",
        "-C",
        "elixir",
        "--",
        "mix",
        "deps.get",
        "--check-locked",
    )
    setup_commands = (
        ("network dependency bootstrap", dependency_command, False, "dev", True),
        ("offline dependency replay", dependency_command, True, "dev", True),
        (
            "offline dev dependency compile",
            ("mise", "exec", "-C", "elixir", "--", "mix", "deps.compile"),
            True,
            "dev",
            True,
        ),
        (
            "network test dependency bootstrap",
            ("mise", "exec", "-C", "elixir", "--", "mix", "deps.compile"),
            False,
            "test",
            True,
        ),
        (
            "offline test dependency replay",
            ("mise", "exec", "-C", "elixir", "--", "mix", "deps.compile"),
            True,
            "test",
            True,
        ),
        (
            "offline dev application compile",
            (
                "mise",
                "exec",
                "-C",
                "elixir",
                "--",
                "mix",
                "compile",
                "--warnings-as-errors",
            ),
            True,
            "dev",
            False,
        ),
    )
    _inspect_private_erlexec_source(
        sandbox.erlexec_source, sandbox.erlexec_tracked
    )
    setup_source_fingerprint = _inspect_private_setup_elixir(
        sandbox.setup_elixir, sandbox.setup_elixir_tracked
    )
    mix_tools_fingerprint = _inspect_private_mix_tools(
        sandbox.mix_tools, sandbox.mix_rebar_version
    )
    if mix_tools_fingerprint != sandbox.mix_tools_fingerprint:
        raise ReadinessError("private Mix tool inputs changed before dependency setup")
    plt_fingerprint = _inspect_private_plt_outputs(sandbox, require_empty=True)
    project_output_fingerprint = _inspect_gate_generated_outputs(sandbox)
    for setup_label, setup, hex_offline, mix_env, minimal_setup_source in setup_commands:
        try:
            setup_environment = _safe_gate_environment(
                sandbox,
                hex_offline=hex_offline,
                use_bootstrap_hex=True,
            )
            setup_environment["MIX_ENV"] = mix_env
            returncode, _stdout, _stderr = run_bounded_command(
                _sandbox_command(
                    sandbox,
                    setup,
                    network_disabled=hex_offline,
                    writable_erlexec=True,
                    writable_dependencies=True,
                    writable_setup_elixir=minimal_setup_source,
                ),
                cwd=sandbox.temporary_root,
                environment=setup_environment,
                timeout_seconds=LIVE_SETUP_COMMAND_TIMEOUT_SECONDS,
                max_output_bytes=MAX_GATE_OUTPUT_BYTES,
            )
            if returncode != 0:
                raise ReadinessError(f"private {setup_label} failed")
        except (OSError, subprocess.SubprocessError) as error:
            raise ReadinessError(f"private {setup_label} failed") from error
        _inspect_private_erlexec_source(
            sandbox.erlexec_source,
            sandbox.erlexec_tracked,
            normalize_generated=True,
            require_compiled=setup_label.endswith("dependency compile"),
        )
        if (
            _inspect_private_setup_elixir(
                sandbox.setup_elixir, sandbox.setup_elixir_tracked
            )
            != setup_source_fingerprint
        ):
            raise ReadinessError("private dependency setup changed staged Elixir source")
        if (
            _inspect_gate_generated_outputs(sandbox)
            != project_output_fingerprint
        ):
            raise ReadinessError("private dependency setup changed project outputs")
        if (
            _inspect_private_mix_tools(sandbox.mix_tools, sandbox.mix_rebar_version)
            != mix_tools_fingerprint
        ):
            raise ReadinessError("private dependency setup changed Mix tool inputs")
        if (
            _inspect_private_plt_outputs(sandbox, require_empty=True)
            != plt_fingerprint
        ):
            raise ReadinessError("private dependency setup created a PLT")

    erlexec_fingerprint = _inspect_private_erlexec_source(
        sandbox.erlexec_source,
        sandbox.erlexec_tracked,
        require_compiled=True,
    )
    dependency_fingerprint = _private_dependency_fingerprint(sandbox)
    build_fingerprint = _private_gate_build_fingerprint(sandbox)
    _reset_private_hex_runtime(sandbox)
    return erlexec_fingerprint, dependency_fingerprint, build_fingerprint


def _run_offline_dialyzer_replay(
    sandbox: GateSandbox, expected_plt_fingerprint: str
) -> None:
    """Re-run Dialyzer offline and require byte-identical, valid private PLTs."""

    environment = _safe_gate_environment(sandbox)
    if environment.get("HEX_OFFLINE") != "1":
        raise ReadinessError("offline Dialyzer replay lacks offline Hex mode")
    try:
        returncode, stdout, stderr = run_bounded_command(
            _sandbox_command(
                sandbox,
                OFFLINE_DIALYZER_REPLAY_COMMAND,
                writable_git=True,
                writable_erlexec=True,
                writable_mix_home=True,
            ),
            cwd=sandbox.temporary_root,
            environment=environment,
            timeout_seconds=OFFLINE_DIALYZER_REPLAY_TIMEOUT_SECONDS,
            max_output_bytes=MAX_GATE_OUTPUT_BYTES,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise ReadinessError("offline Dialyzer replay failed") from error
    if returncode != 0 or _dialyzer_output_has_error(stdout, stderr):
        raise ReadinessError("offline Dialyzer replay failed")
    if (
        _inspect_private_plt_outputs(sandbox, require_complete=True)
        != expected_plt_fingerprint
    ):
        raise ReadinessError("offline Dialyzer replay changed private PLTs")
    if (
        _inspect_private_mix_tools(sandbox.mix_tools, sandbox.mix_rebar_version)
        != sandbox.mix_tools_fingerprint
    ):
        raise ReadinessError("offline Dialyzer replay changed Mix tool inputs")


def _execute_full_gate_inventory(
    repo_root: Path,
    static_basis: Mapping[str, Any],
    codex_command: str,
    mise_command: str,
) -> FullGateEvidence:
    index_tree = _git_text(repo_root, ["write-tree"])
    index_entries = _parse_index_entries(repo_root)
    source_basis = static_basis["checkout"]["source"]
    source_sha = source_basis["sha256"]
    metadata_fingerprint = _git_metadata_fingerprint(repo_root)
    tool_fingerprints = _resolved_tool_fingerprints(
        (*REQUIRED_CONFORMANCE_COMMANDS.values(), ("bwrap",), ("codex",))
    )
    codex_path = _require_public_launcher_selector(codex_command, "codex", "Codex")
    mise_path = _require_public_launcher_selector(mise_command, "mise", "mise")
    mise_sha = sha256_regular_file(mise_path, 128 * 1024 * 1024)

    executions: list[GateExecution] = []
    live: LiveCapabilityEvidence | None = None
    linear = _default_linear()
    package: dict[str, Any] = {
        "package": SUPPORTED_RELEASE_PACKAGE,
        "status": "blocked",
    }
    with _gate_temporary_directory() as temporary:
        temporary_root = Path(temporary)
        snapshot = temporary_root / "snapshot"
        snapshot.mkdir(mode=0o700)
        (temporary_root / "tmp").mkdir(mode=0o700)
        _run_git(
            repo_root,
            ["checkout-index", "--all", "--force", f"--prefix={snapshot}{os.sep}"],
            timeout=90.0,
        )
        initial_snapshot_fingerprint = _inspect_source_bound_snapshot(
            snapshot, index_entries, source_basis
        )
        sandbox = _prepare_gate_sandbox(
            repo_root,
            snapshot,
            temporary_root,
            index_tree,
            codex_path,
            index_entries,
        )
        _run_gate_sandbox_canary(repo_root, sandbox, metadata_fingerprint)
        private_git_fingerprint = _git_metadata_fingerprint(
            sandbox.snapshot,
            git_dir=sandbox.git_dir,
            work_tree=sandbox.snapshot,
        )

        erlexec_fingerprint, dependency_fingerprint, build_fingerprint = (
            _bootstrap_private_gate_dependencies(sandbox)
        )
        credential_runtime_fingerprint = _private_credential_runtime_fingerprint(
            sandbox
        )
        hex_runtime_fingerprint = _inspect_private_hex_runtime(sandbox)
        generated_output_fingerprint = _inspect_gate_generated_outputs(sandbox)
        empty_plt_fingerprint = _inspect_private_plt_outputs(
            sandbox, require_empty=True
        )
        verified_plt_fingerprint: str | None = None
        supervisor_seal: LiveSupervisorSeal | None = None

        for identifier in sorted(REQUIRED_CONFORMANCE_IDS):
            build_before_gate = _private_gate_build_fingerprint(sandbox)
            if build_before_gate != build_fingerprint:
                raise ReadinessError("private build inputs changed between exact gates")
            if (
                identifier in {"linear_live_discovery", "no_model_live_discovery"}
                and _private_credential_runtime_fingerprint(sandbox)
                != credential_runtime_fingerprint
            ):
                raise ReadinessError(
                    "sealed credential runtime changed before authenticated gate"
                )
            if _reset_private_hex_runtime(sandbox) != hex_runtime_fingerprint:
                raise ReadinessError("private Hex runtime reset differs from bootstrap")
            if (
                identifier != "upstream_make_all"
                and _inspect_private_plt_outputs(sandbox, require_empty=True)
                != empty_plt_fingerprint
            ):
                raise ReadinessError("a non-Dialyzer gate changed private PLT outputs")
            command = REQUIRED_CONFORMANCE_COMMANDS[identifier]
            try:
                if (
                    identifier in {"linear_live_discovery", "no_model_live_discovery"}
                    and supervisor_seal is None
                ):
                    supervisor_seal = _seal_live_supervisor_runtime(
                        repo_root,
                        sandbox,
                        index_tree=index_tree,
                    )
                if identifier == "no_model_live_discovery":
                    assert supervisor_seal is not None
                    returncode, stdout, stderr = _execute_sealed_codex_gate(
                        repo_root,
                        sandbox,
                        static_basis,
                        codex_command,
                        index_tree,
                        supervisor_seal,
                        build_before_gate,
                        credential_runtime_fingerprint,
                    )
                elif identifier == "linear_live_discovery":
                    assert supervisor_seal is not None
                    returncode, stdout, stderr = _execute_sealed_linear_gate(
                        repo_root,
                        sandbox,
                        source_sha,
                        index_tree,
                        supervisor_seal,
                        build_before_gate,
                        credential_runtime_fingerprint,
                    )
                else:
                    returncode, stdout, stderr = run_bounded_command(
                        _sandbox_command(
                            sandbox,
                            command,
                            # `git write-tree` is an exact source-drift oracle and
                            # necessarily refreshes the private index.  The mirror
                            # is semantic-fingerprinted after every gate.
                            writable_git=True,
                            writable_erlexec=identifier
                            in ERLEXEC_WRITABLE_GATE_IDS,
                            writable_project_outputs=identifier
                            == "upstream_make_all",
                            writable_hex_runtime=identifier
                            in HEX_RUNTIME_WRITABLE_GATE_IDS,
                            writable_mix_home=identifier
                            in MIX_HOME_WRITABLE_GATE_IDS,
                        ),
                        cwd=temporary_root,
                        environment=_safe_gate_environment(sandbox),
                        timeout_seconds=GATE_TIMEOUT_SECONDS.get(identifier, 600.0),
                        max_output_bytes=MAX_GATE_OUTPUT_BYTES,
                    )
                outcome = (
                    "pass"
                    if _gate_command_passed(
                        identifier, returncode, stdout, stderr
                    )
                    else "blocked"
                )
                if outcome == "pass" and identifier == "upstream_make_all":
                    first_plt_fingerprint = _inspect_private_plt_outputs(
                        sandbox, require_complete=True
                    )
                    _run_offline_dialyzer_replay(sandbox, first_plt_fingerprint)
                    verified_plt_fingerprint = first_plt_fingerprint
                elif outcome == "pass" and identifier == "no_model_live_discovery":
                    record = _decode_prefixed_record(
                        stdout, CODEX_PROBE_JSON_PREFIX, "Codex public probe"
                    )
                    live = validate_codex_probe_record(record, static_basis)
                elif outcome == "pass" and identifier == "linear_live_discovery":
                    record = _decode_prefixed_record(
                        stdout, LINEAR_PROBE_JSON_PREFIX, "Linear public probe"
                    )
                    linear = validate_linear_probe_record(record, source_sha)
                elif outcome == "pass" and identifier == "source_archive_rehearsal":
                    record = _decode_prefixed_record(
                        stdout, PACKAGE_PROBE_JSON_PREFIX, "package public probe"
                    )
                    package = validate_package_probe_record(record, source_sha, index_tree)
            except (OSError, ReadinessError, subprocess.SubprocessError):
                stdout = b""
                stderr = b""
                outcome = "blocked"
                if identifier == "no_model_live_discovery":
                    live = None
                elif identifier == "linear_live_discovery":
                    linear = _default_linear()
                elif identifier == "source_archive_rehearsal":
                    package = {"package": SUPPORTED_RELEASE_PACKAGE, "status": "blocked"}
            build_after_gate = _private_gate_build_fingerprint(sandbox)
            if (
                identifier in {"linear_live_discovery", "no_model_live_discovery"}
                and build_after_gate != build_before_gate
            ):
                raise ReadinessError("an authenticated gate changed private build inputs")
            if (
                identifier in {"linear_live_discovery", "no_model_live_discovery"}
                and _private_credential_runtime_fingerprint(sandbox)
                != credential_runtime_fingerprint
            ):
                raise ReadinessError(
                    "an authenticated gate changed the sealed credential runtime"
                )
            build_fingerprint = build_after_gate
            if (
                _git_metadata_fingerprint(
                    sandbox.snapshot,
                    git_dir=sandbox.git_dir,
                    work_tree=sandbox.snapshot,
                )
                != private_git_fingerprint
            ):
                raise ReadinessError("an exact gate changed private Git semantics")
            _inspect_private_hex_runtime(sandbox)
            if identifier in HEX_RUNTIME_WRITABLE_GATE_IDS:
                if _reset_private_hex_runtime(sandbox) != hex_runtime_fingerprint:
                    raise ReadinessError(
                        "private Hex runtime did not normalize to its bootstrap cache"
                    )
            elif (
                _inspect_private_hex_runtime(sandbox) != hex_runtime_fingerprint
            ):
                raise ReadinessError("an exact gate changed the read-only Hex runtime")
            if (
                _inspect_private_erlexec_source(
                    sandbox.erlexec_source,
                    sandbox.erlexec_tracked,
                    normalize_generated=True,
                    require_compiled=True,
                )
                != erlexec_fingerprint
            ):
                raise ReadinessError("an exact gate changed private erlexec inputs")
            if (
                _inspect_private_mix_tools(
                    sandbox.mix_tools, sandbox.mix_rebar_version
                )
                != sandbox.mix_tools_fingerprint
            ):
                raise ReadinessError("an exact gate changed immutable Mix tool inputs")
            if identifier == "upstream_make_all":
                current_plt_fingerprint = _inspect_private_plt_outputs(
                    sandbox, require_complete=outcome == "pass"
                )
                if (
                    outcome == "pass"
                    and current_plt_fingerprint != verified_plt_fingerprint
                ):
                    raise ReadinessError("verified private PLTs changed after replay")
            elif (
                _inspect_private_plt_outputs(sandbox, require_empty=True)
                != empty_plt_fingerprint
            ):
                raise ReadinessError("an exact non-Dialyzer gate changed private PLTs")
            if identifier == "upstream_make_all":
                _inspect_gate_generated_outputs(
                    sandbox,
                    normalize=True,
                    require_complete=outcome == "pass",
                )
            elif (
                _inspect_gate_generated_outputs(sandbox)
                != generated_output_fingerprint
            ):
                raise ReadinessError("an exact gate changed generated project outputs")
            executions.append(
                GateExecution(identifier, tuple(command), outcome, stdout, stderr)
            )

        if _private_dependency_fingerprint(sandbox) != dependency_fingerprint:
            raise ReadinessError("an exact gate changed private dependency inputs")
        if _private_gate_build_fingerprint(sandbox) != build_fingerprint:
            raise ReadinessError("private build inputs changed after exact gates")
        if (
            _inspect_private_mix_tools(sandbox.mix_tools, sandbox.mix_rebar_version)
            != sandbox.mix_tools_fingerprint
        ):
            raise ReadinessError("private Mix tool inputs differ after exact gates")
        if _inspect_private_hex_runtime(sandbox) != hex_runtime_fingerprint:
            raise ReadinessError("private Hex runtime differs after exact gates")
        if (
            _git_metadata_fingerprint(
                sandbox.snapshot,
                git_dir=sandbox.git_dir,
                work_tree=sandbox.snapshot,
            )
            != private_git_fingerprint
        ):
            raise ReadinessError("private Git semantics changed during exact gates")
        if sandbox.resolver_config is not None and (
            sha256_regular_file(sandbox.resolver_config, 64 * 1024)
            != sandbox.resolver_sha256
        ):
            raise ReadinessError("an exact gate changed the private resolver snapshot")
        _remove_gate_output_mountpoints(snapshot, index_entries)
        if (
            _inspect_source_bound_snapshot(snapshot, index_entries, source_basis)
            != initial_snapshot_fingerprint
        ):
            raise ReadinessError("immutable staged snapshot changed while readiness gates ran")

    if sha256_regular_file(mise_path, 128 * 1024 * 1024) != mise_sha:
        raise ReadinessError("mise executable changed while readiness gates ran")
    if _resolved_tool_fingerprints(
        (*REQUIRED_CONFORMANCE_COMMANDS.values(), ("bwrap",), ("codex",))
    ) != tool_fingerprints:
        raise ReadinessError("a gate launcher changed while readiness gates ran")
    if _git_metadata_fingerprint(repo_root) != metadata_fingerprint:
        raise ReadinessError("original Git refs, config, or index changed while gates ran")
    if _git_text(repo_root, ["write-tree"]) != index_tree:
        raise ReadinessError("Git index changed while readiness gates ran")
    assert_no_unstaged_source(repo_root)
    return FullGateEvidence(
        executions=tuple(executions),
        live=live,
        linear=linear,
        package=package,
        source_sha256=source_sha,
        index_tree=index_tree,
    )


def _gate_outcomes(evidence: FullGateEvidence) -> dict[str, str]:
    outcomes: dict[str, str] = {}
    for execution in evidence.executions:
        if not isinstance(execution, GateExecution):
            raise ReadinessError("trusted compiler retained a non-gate execution")
        if execution.identifier in outcomes:
            raise ReadinessError("trusted compiler retained duplicate gate executions")
        expected = REQUIRED_CONFORMANCE_COMMANDS.get(execution.identifier)
        if expected is None or execution.command != expected:
            raise ReadinessError("trusted compiler execution command differs from public inventory")
        if execution.outcome not in {"blocked", "pass"}:
            raise ReadinessError("trusted compiler execution has an invalid outcome")
        outcomes[execution.identifier] = execution.outcome
    if set(outcomes) != REQUIRED_CONFORMANCE_IDS or len(outcomes) != len(evidence.executions):
        raise ReadinessError("trusted compiler did not execute the exact conformance inventory")
    return outcomes


def _live_report(
    evidence: FullGateEvidence, expected_version: str | None = None
) -> tuple[dict[str, Any] | None, dict[str, str]]:
    if evidence.live is None:
        return None, {}
    captured = evidence.live._copy_for_compiler()
    raw_envelope = _mapping(captured["envelope"], "full gate live envelope")
    raw_report = _mapping(raw_envelope.get("capabilityReport"), "full gate live report")
    version = expected_version or _identifier(
        raw_report.get("schemaVersion"), "full gate live schema version"
    )
    envelope = validate_live_capability_envelope(raw_envelope, version)
    report = _mapping(envelope["capabilityReport"], "full gate live report")
    receipts: dict[str, str] = {}
    for receipt in envelope["requestReceipts"]:
        outcome = "absent" if receipt["outcome"] == "unavailable" else receipt["outcome"]
        prior = receipts.setdefault(receipt["method"], outcome)
        if prior != outcome:
            raise ReadinessError("full gate live pagination classifications disagree")
    return report, receipts


def _optional_live_status(status: str) -> str:
    return {"available": "pass", "unavailable": "absent"}.get(status, status)


def _quota_full_read_status(quota: Mapping[str, Any]) -> str:
    """Require one usable in-range bucket/window, not merely a decoded envelope."""

    if "status" in quota:
        return "blocked"
    if (
        quota["bucketCount"] <= 0
        or quota["windowSlotCount"] <= 0
        or quota["outOfRangeValues"] is not False
        or "primary" not in quota["fields"]
    ):
        return "blocked"
    return "pass"


def _usage_field_status(identifier: str, optional: Mapping[str, Any]) -> str | None:
    known = {
        "usage.summary",
        "usage.daily_buckets",
        "usage.daily_start_date",
        "usage.daily_tokens",
        "usage.current_streak_days",
        "usage.lifetime_tokens",
        "usage.longest_running_turn_sec",
        "usage.longest_streak_days",
        "usage.peak_daily_tokens",
    }
    if identifier not in known:
        return None
    status = optional["status"]
    if status != "available":
        return _optional_live_status(status)
    result = optional["result"]
    if identifier == "usage.summary":
        return "pass"
    if identifier in {
        "usage.daily_buckets",
        "usage.daily_start_date",
        "usage.daily_tokens",
    }:
        return "pass" if result["dailyBucketCount"] > 0 else "absent"
    source_name = {
        "usage.current_streak_days": "currentStreakDays",
        "usage.lifetime_tokens": "lifetimeTokens",
        "usage.longest_running_turn_sec": "longestRunningTurnSec",
        "usage.longest_streak_days": "longestStreakDays",
        "usage.peak_daily_tokens": "peakDailyTokens",
    }[identifier]
    return (
        "pass"
        if source_name in set(result["populatedSummaryFields"])
        else "absent"
    )


def _feature_field_status(identifier: str, optional: Mapping[str, Any]) -> str | None:
    known = {
        "features.cursor",
        "features.limit",
        "features.thread_id",
        "features.data",
        "features.name",
        "features.enabled",
        "features.default_enabled",
        "features.stage",
        "features.next_cursor",
    }
    if identifier not in known:
        return None
    status = optional["status"]
    if status != "available":
        return _optional_live_status(status)
    if identifier == "features.data":
        return "pass"
    if identifier in {
        "features.name",
        "features.enabled",
        "features.default_enabled",
        "features.stage",
    }:
        return "pass" if optional["items"] else "absent"
    # Parameter keys and a nullable next cursor are not retained by the
    # redacted report, so availability of the parent method cannot promote them.
    return "absent"


def _collaboration_field_status(
    identifier: str, optional: Mapping[str, Any]
) -> str | None:
    known = {
        "collaboration.data",
        "collaboration.mask_name",
        "collaboration.mask_mode",
        "collaboration.mask_model",
        "collaboration.mask_reasoning_effort",
    }
    if identifier not in known:
        return None
    status = optional["status"]
    if status != "available":
        return _optional_live_status(status)
    rows = optional["result"]
    if identifier == "collaboration.data":
        return "pass"
    if identifier == "collaboration.mask_name":
        return "pass" if rows else "absent"
    key = {
        "collaboration.mask_mode": "mode",
        "collaboration.mask_model": "model",
        "collaboration.mask_reasoning_effort": "reasoningEffort",
    }[identifier]
    return "pass" if any(row[key] is not None for row in rows) else "absent"


def _quota_optional_field_status(
    identifier: str, quota: Mapping[str, Any]
) -> str | None:
    """Project only optional quota fields explicitly proven by redacted telemetry."""

    field_ids = {
        "rate_limits.multi_bucket",
        "rate_limits.bucket_limit_id",
        "rate_limits.reset_credits",
        "rate_limits.reset_credit_available_count",
        "rate_limits.reset_credit_id",
        "rate_limits.reset_credit_status",
        "rate_limits.reset_credit_type",
        "rate_limits.credits",
        "rate_limits.credits_balance",
        "rate_limits.credits_has_credits",
        "rate_limits.credits_unlimited",
        "rate_limits.spend_control",
        "rate_limits.spend_limit",
        "rate_limits.spend_used",
        "rate_limits.spend_remaining_percent",
        "rate_limits.spend_resets_at",
        "rate_limits.secondary.used_percent",
        "rate_limits.secondary.window_duration",
        "rate_limits.secondary.resets_at",
        "rate_limits.bucket_primary.used_percent",
        "rate_limits.bucket_primary.window_duration",
        "rate_limits.bucket_primary.resets_at",
        "rate_limits.bucket_secondary.used_percent",
        "rate_limits.bucket_secondary.window_duration",
        "rate_limits.bucket_secondary.resets_at",
        "rate_limits.limit_id",
        "rate_limits.limit_name",
        "rate_limits.plan_type",
        "rate_limits.reached_type",
        "rate_limits.bucket_limit_name",
        "rate_limits.bucket_plan_type",
        "rate_limits.bucket_reached_type",
        "rate_limits.bucket_credits",
        "rate_limits.bucket_credits_balance",
        "rate_limits.bucket_credits_has_credits",
        "rate_limits.bucket_credits_unlimited",
        "rate_limits.bucket_spend_control",
        "rate_limits.bucket_spend_limit",
        "rate_limits.bucket_spend_used",
        "rate_limits.bucket_spend_remaining_percent",
        "rate_limits.bucket_spend_resets_at",
        "rate_limits.reset_credit_expires_at",
        "rate_limits.reset_credit_granted_at",
        "rate_limits.reset_credit_title",
        "rate_limits.reset_credit_description",
    }
    if identifier not in field_ids:
        return None
    if "status" in quota:
        return str(quota["status"])

    fields = set(quota["fields"])
    multi = quota["bucketSource"] == "multi"
    reset = quota["resetCredits"]
    if identifier == "rate_limits.multi_bucket":
        return "pass" if multi else "absent"

    simple_fields = {
        "rate_limits.limit_id": "limit_id",
        "rate_limits.limit_name": "limit_name",
        "rate_limits.plan_type": "plan_type",
        "rate_limits.reached_type": "reached_type",
        "rate_limits.credits": "credits",
        "rate_limits.credits_has_credits": "credits",
        "rate_limits.credits_unlimited": "credits",
        "rate_limits.spend_control": "spend_control",
        "rate_limits.spend_limit": "spend_control",
        "rate_limits.spend_used": "spend_control",
        "rate_limits.spend_remaining_percent": "spend_control",
        "rate_limits.spend_resets_at": "spend_control",
        "rate_limits.secondary.used_percent": "secondary",
    }
    if identifier in simple_fields:
        return "pass" if simple_fields[identifier] in fields else "absent"

    bucket_fields = {
        "rate_limits.bucket_limit_id": "limit_id",
        "rate_limits.bucket_limit_name": "limit_name",
        "rate_limits.bucket_plan_type": "plan_type",
        "rate_limits.bucket_reached_type": "reached_type",
        "rate_limits.bucket_credits": "credits",
        "rate_limits.bucket_credits_has_credits": "credits",
        "rate_limits.bucket_credits_unlimited": "credits",
        "rate_limits.bucket_spend_control": "spend_control",
        "rate_limits.bucket_spend_limit": "spend_control",
        "rate_limits.bucket_spend_used": "spend_control",
        "rate_limits.bucket_spend_remaining_percent": "spend_control",
        "rate_limits.bucket_spend_resets_at": "spend_control",
        "rate_limits.bucket_primary.used_percent": "primary",
        "rate_limits.bucket_secondary.used_percent": "secondary",
    }
    if identifier in bucket_fields:
        return (
            "pass" if multi and bucket_fields[identifier] in fields else "absent"
        )

    if identifier in {
        "rate_limits.reset_credits",
        "rate_limits.reset_credit_available_count",
    }:
        return "pass" if reset["summary"] == "present" else "absent"
    if identifier in {
        "rate_limits.reset_credit_id",
        "rate_limits.reset_credit_status",
        "rate_limits.reset_credit_type",
        "rate_limits.reset_credit_granted_at",
    }:
        return "pass" if reset["details"] == "present" else "absent"

    # Balance, nullable window metadata, and optional reset-credit prose/times
    # are intentionally omitted from the redacted live report. Their parent
    # object cannot truthfully promote those individual fields.
    return "absent"


def _field_live_override(
    identifier: str, requirement: str, report: Mapping[str, Any] | None
) -> str | None:
    if report is None:
        return None
    account = report["account"]
    if identifier == "account.type.chatgpt":
        return "pass" if account["authMode"] == "chatgpt" else "absent"
    if identifier == "account.type.api_key":
        return "pass" if account["authMode"] == "api_key" else "absent"
    if identifier == "account.email":
        return "pass" if account["identity"]["status"] == "confirmed" else "blocked"
    usage_status = _usage_field_status(identifier, report["optional"]["usage"])
    if usage_status is not None:
        return usage_status
    feature_status = _feature_field_status(
        identifier, report["optional"]["experimentalFeatures"]
    )
    if feature_status is not None:
        return feature_status
    collaboration_status = _collaboration_field_status(
        identifier, report["optional"]["collaborationModes"]
    )
    if collaboration_status is not None:
        return collaboration_status
    if identifier in {"models.service_tiers", "models.service_tier_id", "models.service_tier_name"}:
        return "pass" if any(model["serviceTierIds"] for model in report["models"]) else "absent"
    if identifier == "models.service_tier_description":
        return "absent"
    if identifier == "models.default_service_tier":
        return (
            "pass"
            if any(model["defaultServiceTier"] is not None for model in report["models"])
            else "absent"
        )
    quota = report["quotaShape"]
    if requirement == "optional":
        quota_status = _quota_optional_field_status(identifier, quota)
        if quota_status is not None:
            return quota_status
    return None


def _compile_matrix_outcomes(
    matrix: Mapping[str, Any], evidence: FullGateEvidence
) -> dict[str, dict[str, str]]:
    gate_outcomes = _gate_outcomes(evidence)
    report, receipts = _live_report(evidence)
    result: dict[str, dict[str, str]] = {
        "fields": {},
        "methods": {},
        "negativeCapabilities": {},
    }
    for group in ("methods", "fields"):
        for raw in _list(matrix.get(group), f"full compiler matrix {group}", 4_096):
            row = _mapping(raw, f"full compiler matrix {group} row")
            identifier = _identifier(row.get("id"), f"full compiler matrix {group} ID")
            probe = _enum(row.get("r006Probe"), set(PROBE_GATE_REQUIREMENTS), "matrix probe")
            required_gates = PROBE_GATE_REQUIREMENTS[probe]
            outcome = (
                "pass"
                if all(gate_outcomes.get(gate) == "pass" for gate in required_gates)
                else "blocked"
            )
            if group == "methods" and outcome == "pass" and row.get("method") in receipts:
                outcome = receipts[str(row["method"])]
            if group == "fields" and outcome == "pass":
                override = _field_live_override(
                    identifier, str(row["requirement"]), report
                )
                if override is not None:
                    outcome = override
            result[group][identifier] = outcome
    negative_pass = all(
        gate_outcomes.get(gate) == "pass" for gate in SCHEMA_NEGATIVE_GATES
    )
    for raw in _list(
        matrix.get("negativeCapabilities"), "full compiler negative capabilities", 4_096
    ):
        identifier = _identifier(
            _mapping(raw, "negative capability").get("id"), "negative capability ID"
        )
        result["negativeCapabilities"][identifier] = "pass" if negative_pass else "blocked"
    return result


def _compile_full_public_report(
    evidence: FullGateEvidence,
    matrix: MatrixArtifact,
    static_basis: Mapping[str, Any],
) -> VerifiedPublicReport:
    static = copy.deepcopy(_mapping(static_basis, "full compiler static basis"))
    _validate_static_basis(static)
    if evidence.source_sha256 != static["checkout"]["source"]["sha256"]:
        raise ReadinessError("full gate evidence belongs to a different staged source")
    _commit(evidence.index_tree, "full gate index tree")
    outcomes = _gate_outcomes(evidence)
    linear = _normalize_linear(evidence.linear, "full gate Linear evidence")
    if outcomes["linear_live_discovery"] == "pass" and linear[
        "configuredProjectBinding"
    ] is None:
        raise ReadinessError("passing Linear discovery lacks a configured project binding")
    if outcomes["linear_live_discovery"] == "blocked" and linear != _default_linear():
        raise ReadinessError("blocked Linear discovery retained unverified capabilities")
    if outcomes["source_archive_rehearsal"] == "pass":
        package = validate_package_probe_record(
            evidence.package, evidence.source_sha256, evidence.index_tree
        )
    else:
        package = {"package": SUPPORTED_RELEASE_PACKAGE, "status": "blocked"}
    if evidence.live is not None:
        captured = evidence.live._copy_for_compiler()
        _exact_keys(
            captured,
            {
                "envelope",
                "launcherSha256",
                "nativeSha256",
                "staticBasisSha256",
                "versionOutput",
            },
            "full gate captured live evidence",
        )
        if captured["staticBasisSha256"] != sha256_bytes(canonical_json_bytes(static)):
            raise ReadinessError("full gate live evidence belongs to a different static basis")
        for key in ("launcherSha256", "nativeSha256", "versionOutput"):
            if captured[key] != static["codex"][key]:
                raise ReadinessError("full gate live executable evidence differs from static basis")
    live_report, _receipts = _live_report(evidence, static["codex"]["version"])
    if outcomes["no_model_live_discovery"] == "pass" and live_report is None:
        raise ReadinessError("passing no-model discovery lacks live evidence")
    if outcomes["no_model_live_discovery"] == "blocked" and live_report is not None:
        raise ReadinessError("blocked no-model discovery retained unverified capabilities")
    if live_report is None:
        models: list[dict[str, Any]] = []
        auth_mode = "unavailable"
        identity = {
            "bindingId": None,
            "evidence": "unavailable",
            "generation": 0,
            "status": "blocked",
        }
        quota = {
            "fullRead": "blocked",
            "multiBucket": "blocked",
            "sparseUpdate": "blocked",
            "usage": "blocked",
        }
    else:
        account = live_report["account"]
        live_identity = account["identity"]
        auth_mode = account["authMode"]
        identity = {
            "bindingId": live_identity["bindingId"],
            "evidence": live_identity["evidence"],
            "generation": live_identity["generation"],
            "status": live_identity["status"],
        }
        models = [
            {
                "defaultServiceTier": row["defaultServiceTier"],
                "fastServiceTierId": row["fastServiceTierId"],
                "id": row["id"],
                "model": row["model"],
                "reasoningEfforts": row["reasoningEfforts"],
                "serviceTierIds": row["serviceTierIds"],
            }
            for row in live_report["models"]
            if row["hidden"] is False
        ]
        quota_shape = live_report["quotaShape"]
        full_read = _quota_full_read_status(quota_shape)
        quota = {
            "fullRead": full_read,
            "multiBucket": (
                "pass"
                if full_read == "pass" and quota_shape.get("bucketSource") == "multi"
                else "absent" if full_read == "pass" else "blocked"
            ),
            "sparseUpdate": (
                "pass"
                if outcomes.get("capability_fake_conformance") == "pass"
                and outcomes.get("source_bound_fixture_replay") == "pass"
                else "blocked"
            ),
            "usage": _optional_live_status(
                live_report["optional"]["usage"]["status"]
            ),
        }

    cap_pass = outcomes.get("subagent_cap_conformance") == "pass"
    guard_pass = outcomes.get("depth_guard_conformance") == "pass"
    subagents = {
        "hookFailureClassification": "fail_open" if guard_pass else "blocked",
        "implementation": "multi_agent_v2",
        "nativeDepthEnforcement": False,
        "rawToOptionalChildren": list(EXPECTED_CAP_MAPPING) if cap_pass else [],
        "rootCountsTowardLimit": cap_pass,
        "studioDepthGuardRequired": True,
        "trustedGuardStatus": "pass" if guard_pass else "blocked",
    }
    expected_platform = CODEX_TARGET_PLATFORMS.get(static["codex"]["target"])
    if expected_platform is None:
        raise ReadinessError("Codex target has no supported readiness platform mapping")
    expected_os, expected_architecture = expected_platform
    package_pass = (
        outcomes.get("source_archive_rehearsal") == "pass"
        and package.get("status") == "pass"
        and package.get("package") == SUPPORTED_RELEASE_PACKAGE
    )
    conformance = [
        {
            "command": list(execution.command),
            "id": execution.identifier,
            "outcome": execution.outcome,
            "required": True,
        }
        for execution in sorted(evidence.executions, key=lambda row: row.identifier)
    ]
    matrix_value = _require_matrix_artifact(matrix)._copy_for_verification()
    compiled = {
        "authMode": auth_mode,
        "conformance": conformance,
        "identityBinding": identity,
        "linear": linear,
        "matrixOutcomes": _compile_matrix_outcomes(matrix_value, evidence),
        "models": models,
        "platform": {
            "architecture": expected_architecture,
            "os": expected_os,
            "osStatus": (
                "pass" if outcomes.get("installed_codex_verify") == "pass" else "blocked"
            ),
            "package": SUPPORTED_RELEASE_PACKAGE,
            "packageStatus": "pass" if package_pass else "blocked",
        },
        "quota": quota,
        "referenceProfile": (
            live_report["referenceProfile"]
            if live_report is not None
            else _expected_reference_profile(models, auth_mode, identity)
        ),
        "reportVersion": 1,
        "subagents": subagents,
    }
    return _new_full_verified_public_report(_validate_public_report(compiled), evidence)


def compile_full_gate_pair(
    repo_root: Path,
    codex_command: str = "codex",
    mise_command: str = "mise",
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    """Execute and compile every R0-06 gate for the exact staged checkout.

    The function accepts tool selectors only. It has no input for outcomes,
    receipts, models, Linear claims, or package claims.
    """

    repo_root = Path(repo_root).resolve(strict=True)
    static, matrix, schema = collect_static_basis(repo_root, codex_command)
    index_tree = _git_text(repo_root, ["write-tree"])
    evidence = _execute_full_gate_inventory(
        repo_root, static, codex_command, mise_command
    )
    if evidence.index_tree != index_tree:
        raise ReadinessError("trusted compiler evidence belongs to a different staged tree")
    after_static, after_matrix, after_schema = collect_static_basis(
        repo_root, codex_command
    )
    if (after_static, after_matrix, after_schema) != (static, matrix, schema):
        raise ReadinessError("readiness source, schema, matrix, or tools changed during full gates")
    report = _compile_full_public_report(evidence, matrix, static)
    readiness, paired_schema = build_readiness_pair(static, matrix, schema, report)
    require_green_pair(readiness, paired_schema)
    if readiness["platform"]["packageStatus"] == "pass":
        rehearse_final_pair_source_archive(
            repo_root,
            readiness,
            paired_schema,
            static["checkout"]["source"]["sha256"],
            index_tree,
        )
    final_static, final_matrix, final_schema = collect_static_basis(
        repo_root, codex_command
    )
    if (final_static, final_matrix, final_schema) != (static, matrix, schema):
        raise ReadinessError(
            "readiness source, schema, matrix, or tools changed during final archive rehearsal"
        )
    if _git_text(repo_root, ["write-tree"]) != index_tree:
        raise ReadinessError("Git index changed during final pair archive rehearsal")
    return readiness, paired_schema, static


def decode_json_bytes(payload: bytes, label: str) -> Any:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate object key {key!r}")
            result[key] = value
        return result

    def reject_constant(value: str) -> Any:
        raise ValueError(f"non-finite number {value!r}")

    try:
        return json.loads(
            payload.decode("utf-8"),
            object_pairs_hook=reject_duplicates,
            parse_constant=reject_constant,
        )
    except (UnicodeDecodeError, ValueError, json.JSONDecodeError) as error:
        raise ReadinessError(f"cannot decode strict JSON {label}: {error}") from error


def read_json_bounded(path: Path) -> Any:
    return decode_json_bytes(_read_regular_bytes(path, MAX_JSON_BYTES), str(path))


def _assert_public_tree(value: Any, label: str = "readiness") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if key in FORBIDDEN_PUBLIC_KEYS:
                raise ReadinessError(f"{label} contains forbidden public key {key!r}")
            _assert_public_tree(child, f"{label}.{key}")
        return
    if isinstance(value, list):
        for index, child in enumerate(value):
            _assert_public_tree(child, f"{label}[{index}]")
        return
    if value is None or isinstance(value, (bool, int)):
        return
    if not isinstance(value, str):
        raise ReadinessError(f"{label} contains unsupported public value type")
    if "\x00" in value:
        raise ReadinessError(f"{label} contains a NUL byte")
    if _contains_absolute_path(value):
        raise ReadinessError(f"{label} contains an absolute or home-relative path")
    if EMAIL_RE.search(value):
        raise ReadinessError(f"{label} contains an email-like value")
    if any(pattern.search(value) for pattern in SECRET_PATTERNS):
        raise ReadinessError(f"{label} contains a secret-like value")
    if SENSITIVE_ASSIGNMENT_RE.search(value):
        raise ReadinessError(f"{label} contains a sensitive assignment")


def _git_environment(
    *,
    git_dir: Path | None = None,
    work_tree: Path | None = None,
    index_file: Path | None = None,
) -> dict[str, str]:
    # Git is part of the trusted evidence boundary. Never expose runner
    # credentials to ambient config, hooks, or fsmonitor helpers.
    environment = {
        "GIT_ATTR_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_TERMINAL_PROMPT": "0",
        "HOME": os.devnull,
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": os.environ.get("PATH", os.defpath),
    }
    if git_dir is not None:
        environment["GIT_DIR"] = str(git_dir)
    if work_tree is not None:
        environment["GIT_WORK_TREE"] = str(work_tree)
    if index_file is not None:
        environment["GIT_INDEX_FILE"] = str(index_file)
    return environment


def _run_git(
    repo_root: Path,
    arguments: Sequence[str],
    *,
    check: bool = True,
    timeout: float = GIT_COMMAND_TIMEOUT_SECONDS,
    git_dir: Path | None = None,
    work_tree: Path | None = None,
    index_file: Path | None = None,
) -> subprocess.CompletedProcess[bytes]:
    try:
        result = subprocess.run(
            [
                "git",
                "-c",
                "core.fsmonitor=false",
                "-c",
                "core.hooksPath=/dev/null",
                *arguments,
            ],
            cwd=repo_root,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=timeout,
            env=_git_environment(
                git_dir=git_dir, work_tree=work_tree, index_file=index_file
            ),
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ReadinessError(f"git command failed safely: {arguments[0]}: {error}") from error
    if len(result.stdout) > MAX_GIT_OUTPUT_BYTES or len(result.stderr) > MAX_GIT_OUTPUT_BYTES:
        raise ReadinessError(f"git command output exceeded its bound: {arguments[0]}")
    if check and result.returncode != 0:
        diagnostic = result.stderr.decode("utf-8", errors="replace").strip()[:512]
        raise ReadinessError(
            f"git command failed ({result.returncode}) for {arguments[0]}: {diagnostic}"
        )
    return result


def _git_text(
    repo_root: Path,
    arguments: Sequence[str],
    *,
    git_dir: Path | None = None,
    work_tree: Path | None = None,
    index_file: Path | None = None,
) -> str:
    output = _run_git(
        repo_root,
        arguments,
        git_dir=git_dir,
        work_tree=work_tree,
        index_file=index_file,
    ).stdout.decode("ascii", errors="strict").strip()
    if not output:
        raise ReadinessError(f"git command returned an empty value: {arguments[0]}")
    return output


def assert_no_unstaged_source(
    repo_root: Path, *, index_file: Path | None = None
) -> None:
    """Require every non-ignored worktree input to be represented by the index."""

    diff = _run_git(
        repo_root,
        ["diff", "--quiet", "--no-ext-diff", "--ignore-submodules", "--"],
        check=False,
        index_file=index_file,
    )
    if diff.returncode not in (0, 1):
        raise ReadinessError("cannot determine whether tracked source is unstaged")
    if diff.returncode == 1:
        raise ReadinessError("dirty unstaged tracked source is not a readiness basis")

    untracked_raw = _run_git(
        repo_root,
        ["ls-files", "--others", "--exclude-standard", "-z"],
        index_file=index_file,
    ).stdout
    untracked = {
        entry.decode("utf-8", errors="strict")
        for entry in untracked_raw.split(b"\0")
        if entry
    }
    unexpected = sorted(untracked - {READINESS_RELATIVE})
    if unexpected:
        preview = unexpected[:20]
        raise ReadinessError(f"dirty unstaged untracked source is not a readiness basis: {preview}")


def _safe_relative_path(value: str, label: str) -> str:
    if not isinstance(value, str):
        raise ReadinessError(f"{label} is not a safe repository-relative path")
    path = PurePosixPath(value)
    if path.is_absolute() or not value or "\x00" in value or ".." in path.parts:
        raise ReadinessError(f"{label} is not a safe repository-relative path")
    return value


def _positive_int(value: Any, label: str) -> int:
    if type(value) is not int or value <= 0:
        raise ReadinessError(f"{label} must be a positive integer")
    return value


def _validate_schema_manifest(schema_manifest: Mapping[str, Any]) -> None:
    """Validate every persisted schema field before it can enter a public pair."""

    manifest = _mapping(schema_manifest, "schema manifest")
    _exact_keys(manifest, SCHEMA_ROOT_KEYS, "schema manifest")
    if manifest["manifestVersion"] != 1:
        raise ReadinessError("unsupported schema manifest version")

    artifacts = _mapping(manifest["artifacts"], "schema artifacts")
    _exact_keys(artifacts, SCHEMA_ARTIFACT_KEYS, "schema artifacts")
    _sha256(artifacts["artifactBundleSha256"], "schema artifact bundle")
    _sha256(artifacts["schemaBundleSha256"], "schema bundle")
    artifact_paths = {
        "experimentalJson": "experimental/json",
        "experimentalTypescript": "experimental/typescript",
        "json": "json",
        "typescript": "typescript",
    }
    for key, expected_path in artifact_paths.items():
        row = _mapping(artifacts[key], f"schema artifacts {key}")
        _exact_keys(row, SCHEMA_ARTIFACT_ROW_KEYS, f"schema artifacts {key}")
        _positive_int(row["byteCount"], f"schema artifacts {key} byteCount")
        _positive_int(row["fileCount"], f"schema artifacts {key} fileCount")
        if _safe_relative_path(row["path"], f"schema artifacts {key} path") != expected_path:
            raise ReadinessError(f"schema artifacts {key} path differs from its contract")
        _sha256(row["sha256"], f"schema artifacts {key} hash")

    codex = _mapping(manifest["codex"], "schema Codex record")
    _exact_keys(codex, SCHEMA_CODEX_KEYS, "schema Codex record")
    _public_text(codex["npmIntegrity"], "schema Codex npm integrity", 512)
    _public_text(codex["package"], "schema Codex package")
    _identifier(codex["version"], "schema Codex version")
    _public_text(codex["versionOutput"], "schema Codex version output")
    executable = _mapping(codex["executable"], "schema executable record")
    _exact_keys(executable, SCHEMA_EXECUTABLE_KEYS, "schema executable record")
    for key in ("launcherSha256", "nativeSha256"):
        _sha256(executable[key], f"schema executable {key}")
    for key in ("installedPackageAlias", "platformPackage"):
        _public_text(executable[key], f"schema executable {key}")
    _public_text(
        executable["platformNpmIntegrity"],
        "schema executable platform npm integrity",
        512,
    )
    _identifier(executable["target"], "schema executable target")

    generation = _mapping(manifest["generation"], "schema generation")
    _exact_keys(generation, SCHEMA_GENERATION_KEYS, "schema generation")
    if type(generation["cleanCodexHome"]) is not bool:
        raise ReadinessError("schema generation cleanCodexHome must be boolean")
    commands = _list(generation["commands"], "schema generation commands", 16)
    if not commands:
        raise ReadinessError("schema generation commands cannot be empty")
    for index, command in enumerate(commands):
        _normalize_command(command, f"schema generation commands[{index}]")
    _identifier(generation["generatedAt"], "schema generatedAt")
    _identifier(generation["jsonHashAlgorithm"], "schema JSON hash algorithm")
    _identifier(
        generation["typescriptHashAlgorithm"], "schema TypeScript hash algorithm"
    )

    matrix = _mapping(manifest["matrix"], "schema matrix")
    _exact_keys(matrix, SCHEMA_MATRIX_KEYS, "schema matrix")
    _safe_relative_path(matrix["path"], "schema matrix path")
    _identifier(matrix["profile"], "schema matrix profile")
    _sha256(matrix["sha256"], "schema matrix")

    compatibility = _mapping(manifest["compatibility"], "schema compatibility")
    allowed = SCHEMA_COMPATIBILITY_BASE_KEYS | {"runtimeEvidence"}
    actual = set(compatibility)
    if actual not in (SCHEMA_COMPATIBILITY_BASE_KEYS, allowed):
        missing = sorted(SCHEMA_COMPATIBILITY_BASE_KEYS - actual)
        extra = sorted(actual - allowed)
        raise ReadinessError(
            f"schema compatibility keys mismatch; missing={missing}, extra={extra}"
        )
    for key, label in (
        ("fixtures", "fixture compatibility"),
        ("schemaContract", "schema contract"),
        ("transportConformance", "schema transport compatibility"),
    ):
        if compatibility[key] != "pass":
            raise ReadinessError(f"{label} is not sealed pass")
    runtime_capabilities = _enum(
        compatibility["runtimeCapabilities"],
        RUNTIME_CAPABILITIES,
        "schema runtime capabilities",
    )
    runtime_overall = _enum(
        compatibility["overall"], RUNTIME_OVERALL, "schema overall status"
    )
    expected_overall = {
        "blocked": "blocked_r0_06",
        "not_run": "pending_r0_06",
        "pass": "pass",
    }[runtime_capabilities]
    if runtime_overall != expected_overall:
        raise ReadinessError("schema runtime and overall statuses differ")
    _identifier(compatibility["testedAt"], "schema compatibility testedAt")

    fixture = _mapping(
        compatibility["fixtureEvidence"], "schema fixture evidence"
    )
    _exact_keys(fixture, SCHEMA_FIXTURE_EVIDENCE_KEYS, "schema fixture evidence")
    for key in (
        "artifactBundleSha256",
        "matrixSha256",
        "schemaBundleSha256",
        "sourceSha256",
    ):
        _sha256(fixture[key], f"schema fixture evidence {key}")
    _identifier(fixture["codexVersion"], "schema fixture Codex version")
    _normalize_command(fixture["command"], "schema fixture command")
    _normalize_command(fixture["dependencyCommand"], "schema dependency command")
    _normalize_command(
        fixture["dependencyCompileCommand"], "schema dependency compile command"
    )
    _positive_int(fixture["sourceFileCount"], "schema fixture sourceFileCount")
    _identifier(fixture["sourceHashAlgorithm"], "schema fixture source algorithm")
    _positive_int(fixture["testCount"], "schema fixture testCount")
    _identifier(fixture["testedAt"], "schema fixture testedAt")
    expected_fixture_values = {
        "artifactBundleSha256": artifacts["artifactBundleSha256"],
        "codexVersion": codex["version"],
        "matrixSha256": matrix["sha256"],
        "schemaBundleSha256": artifacts["schemaBundleSha256"],
        "testedAt": compatibility["testedAt"],
    }
    for key, expected in expected_fixture_values.items():
        if fixture[key] != expected:
            raise ReadinessError(f"schema fixture evidence {key} differs from its source")

    if "runtimeEvidence" in compatibility:
        evidence = _mapping(
            compatibility["runtimeEvidence"], "schema runtime evidence"
        )
        _exact_keys(evidence, SCHEMA_RUNTIME_EVIDENCE_KEYS, "schema runtime evidence")
        if evidence["hashAlgorithm"] != HASH_ALGORITHM:
            raise ReadinessError("schema runtime evidence hash algorithm is unsupported")
        for key in (
            "readinessManifestSha256",
            "schemaManifestBasisSha256",
            "sourceSha256",
        ):
            _sha256(evidence[key], f"schema runtime evidence {key}")

    _assert_public_tree(manifest, "schema manifest")


def synthetic_schema_manifest(schema_manifest: Mapping[str, Any]) -> dict[str, Any]:
    """Normalize the R0-06 seal fields so readiness/schema hashes cannot cycle."""

    manifest = copy.deepcopy(_mapping(schema_manifest, "schema manifest"))
    _validate_schema_manifest(manifest)
    compatibility = _mapping(manifest.get("compatibility"), "schema compatibility")
    compatibility.pop("runtimeEvidence", None)
    compatibility["runtimeCapabilities"] = SCHEMA_RUNTIME_SENTINEL
    compatibility["overall"] = SCHEMA_OVERALL_SENTINEL
    return manifest


def schema_manifest_basis_sha256(schema_manifest: Mapping[str, Any]) -> str:
    return sha256_bytes(canonical_json_bytes(synthetic_schema_manifest(schema_manifest)))


def codex_basis_from_schema(schema_manifest: Mapping[str, Any]) -> dict[str, str]:
    """Project exactly the public Codex hashes that readiness must mirror."""

    schema = _mapping(schema_manifest, "schema manifest")
    basis_sha = schema_manifest_basis_sha256(schema)
    artifacts = _mapping(schema.get("artifacts"), "schema artifacts")
    codex = _mapping(schema.get("codex"), "schema Codex record")
    executable = _mapping(codex.get("executable"), "schema executable record")
    matrix = _mapping(schema.get("matrix"), "schema matrix record")
    result = {
        "artifactBundleSha256": _sha256(
            artifacts.get("artifactBundleSha256"), "schema artifact bundle"
        ),
        "launcherSha256": _sha256(
            executable.get("launcherSha256"), "schema launcher"
        ),
        "matrixSha256": _sha256(matrix.get("sha256"), "schema matrix"),
        "nativeSha256": _sha256(executable.get("nativeSha256"), "schema native"),
        "schemaBundleSha256": _sha256(
            artifacts.get("schemaBundleSha256"), "schema bundle"
        ),
        "schemaManifestBasisSha256": basis_sha,
        "target": _identifier(executable.get("target"), "schema executable target"),
        "version": _identifier(codex.get("version"), "schema Codex version"),
        "versionOutput": _public_text(
            codex.get("versionOutput"), "schema Codex version output"
        ),
    }
    _exact_keys(result, CODEX_KEYS, "schema-derived Codex basis")
    return result


def _parse_index_entries(
    repo_root: Path,
    *,
    git_dir: Path | None = None,
    work_tree: Path | None = None,
    index_file: Path | None = None,
) -> list[tuple[str, str, str]]:
    raw = _run_git(
        repo_root,
        ["ls-files", "--stage", "-z"],
        git_dir=git_dir,
        work_tree=work_tree,
        index_file=index_file,
    ).stdout
    entries: list[tuple[str, str, str]] = []
    for record in raw.split(b"\0"):
        if not record:
            continue
        try:
            metadata, raw_path = record.split(b"\t", 1)
            mode, object_id, stage = metadata.decode("ascii").split(" ")
            path = raw_path.decode("utf-8", errors="strict")
        except (UnicodeDecodeError, ValueError) as error:
            raise ReadinessError("git index contains an invalid entry") from error
        if stage != "0":
            raise ReadinessError("git index contains an unresolved staged entry")
        if mode not in {"100644", "100755"}:
            raise ReadinessError(f"git index contains unsupported file mode {mode} for {path}")
        _safe_relative_path(path, "git index path")
        entries.append((path, mode, object_id))
    if not entries:
        raise ReadinessError("git index is empty")
    if len({path for path, _mode, _oid in entries}) != len(entries):
        raise ReadinessError("git index contains duplicate paths")
    return sorted(entries)


def _source_basis_from_index_entries(
    entries: Sequence[tuple[str, str, str]],
    *,
    object_format: str,
    schema_manifest_relative: str,
    schema_manifest_basis_sha256: str,
) -> dict[str, Any]:
    """Build the public source identity from one already captured index view."""

    schema_manifest_relative = _safe_relative_path(
        schema_manifest_relative, "schema manifest path"
    )
    basis_sha = _sha256(
        schema_manifest_basis_sha256, "schema manifest basis"
    )
    if object_format not in {"sha1", "sha256"}:
        raise ReadinessError(f"unsupported Git object format: {object_format}")
    indexed_paths = {entry[0] for entry in entries}
    if schema_manifest_relative not in indexed_paths:
        raise ReadinessError("schema manifest is absent from the staged index")

    stream_parts: list[bytes] = [SOURCE_ALGORITHM.encode(), object_format.encode()]
    file_count = 0
    expected_oid_length = 40 if object_format == "sha1" else 64
    for path, mode, object_id in entries:
        if path == READINESS_RELATIVE:
            continue
        if path == schema_manifest_relative:
            identity = f"synthetic-sha256:{basis_sha}"
        else:
            if re.fullmatch(rf"[0-9a-f]{{{expected_oid_length}}}", object_id) is None:
                raise ReadinessError(f"invalid staged object ID for {path}")
            identity = f"git-{object_format}:{object_id}"
        stream_parts.extend(
            (path.encode("utf-8"), mode.encode("ascii"), identity.encode("ascii"))
        )
        file_count += 1

    result = {
        "algorithm": SOURCE_ALGORITHM,
        "fileCount": file_count,
        "gitObjectFormat": object_format,
        "readinessPathExcluded": True,
        "schemaManifestBasisSha256": basis_sha,
        "schemaManifestPath": schema_manifest_relative,
        "sha256": sha256_bytes(_length_prefixed(stream_parts)),
    }
    _validate_source(result)
    return result


def _source_basis_from_checked_tree(
    tree: Path,
    entries: Sequence[tuple[str, str, str]],
    *,
    object_format: str,
    expected_source: Mapping[str, Any],
) -> dict[str, Any]:
    """Recompute the synthetic schema basis from the current indexed tree bytes."""

    schema_relative = _safe_relative_path(
        expected_source.get("schemaManifestPath"), "schema manifest path"
    )
    schema_manifest = _mapping(
        read_json_bounded(tree / schema_relative), "live schema manifest"
    )
    return _source_basis_from_index_entries(
        entries,
        object_format=object_format,
        schema_manifest_relative=schema_relative,
        schema_manifest_basis_sha256=schema_manifest_basis_sha256(schema_manifest),
    )


def _git_blob_oid(path: Path, object_format: str, maximum: int) -> str:
    """Hash one stable regular file using Git's canonical blob framing."""

    if object_format not in {"sha1", "sha256"}:
        raise ReadinessError("checkout snapshot uses an unsupported object format")
    try:
        metadata = path.lstat()
    except OSError as error:
        raise ReadinessError("checkout snapshot file disappeared") from error
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_size > maximum
        or metadata.st_nlink != 1
    ):
        raise ReadinessError("checkout snapshot contains an unsafe file")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
        try:
            opened = os.fstat(descriptor)
            identity = lambda value: (
                value.st_dev,
                value.st_ino,
                value.st_mode,
                value.st_size,
                value.st_mtime_ns,
            )
            if not stat.S_ISREG(opened.st_mode) or identity(opened) != identity(metadata):
                raise ReadinessError("checkout snapshot file changed while opening")
            digest = hashlib.new(object_format)
            digest.update(f"blob {opened.st_size}\0".encode("ascii"))
            total = 0
            while True:
                chunk = os.read(descriptor, min(64 * 1024, maximum + 1 - total))
                if not chunk:
                    break
                total += len(chunk)
                if total > maximum:
                    raise ReadinessError("checkout snapshot exceeds its byte bound")
                digest.update(chunk)
            if total != opened.st_size or identity(os.fstat(descriptor)) != identity(opened):
                raise ReadinessError("checkout snapshot file changed while hashing")
            return digest.hexdigest()
        finally:
            os.close(descriptor)
    except OSError as error:
        raise ReadinessError("cannot securely hash checkout snapshot file") from error


def _inspect_checkout_snapshot(
    snapshot: Path,
    index_entries: Sequence[tuple[str, str, str]],
    object_format: str,
) -> str:
    """Bind an exact checkout-index tree: inventory, modes, and Git blob IDs."""

    try:
        root_metadata = snapshot.lstat()
    except OSError as error:
        raise ReadinessError("checkout snapshot root disappeared") from error
    if (
        stat.S_ISLNK(root_metadata.st_mode)
        or not stat.S_ISDIR(root_metadata.st_mode)
        or stat.S_IMODE(root_metadata.st_mode) != 0o700
    ):
        raise ReadinessError("checkout snapshot root is unsafe")

    expected: dict[str, tuple[str, str]] = {}
    expected_directories: set[str] = set()
    expected_oid_length = 40 if object_format == "sha1" else 64
    if object_format not in {"sha1", "sha256"}:
        raise ReadinessError("checkout snapshot uses an unsupported object format")
    for path, mode, object_id in index_entries:
        if path in expected:
            raise ReadinessError("checkout snapshot index contains duplicate paths")
        if mode not in {"100644", "100755"} or re.fullmatch(
            rf"[0-9a-f]{{{expected_oid_length}}}", object_id
        ) is None:
            raise ReadinessError("checkout snapshot index entry is invalid")
        if _safe_relative_path(path, "checkout snapshot path") != path:
            raise ReadinessError("checkout snapshot path is unsafe")
        expected[path] = (mode, object_id)
        parent = PurePosixPath(path).parent
        while parent != PurePosixPath("."):
            expected_directories.add(parent.as_posix())
            parent = parent.parent
    if not expected:
        raise ReadinessError("checkout snapshot index is empty")

    seen_files: set[str] = set()
    seen_directories: set[str] = set()
    records: list[bytes] = []
    total = 0
    maximum_entries = len(expected) + len(expected_directories)
    for child in _bounded_tree_paths(
        snapshot, maximum_entries, "checkout snapshot"
    ):
        relative = child.relative_to(snapshot).as_posix()
        metadata = child.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise ReadinessError("checkout snapshot contains a symlink")
        if stat.S_ISDIR(metadata.st_mode):
            if relative not in expected_directories:
                raise ReadinessError("checkout snapshot contains an unexpected directory")
            seen_directories.add(relative)
            continue
        if not stat.S_ISREG(metadata.st_mode) or relative not in expected:
            raise ReadinessError("checkout snapshot contains an unexpected file")
        mode, expected_oid = expected[relative]
        actual_mode = stat.S_IMODE(metadata.st_mode)
        total += metadata.st_size
        if total > MAX_ARCHIVE_BYTES:
            raise ReadinessError("checkout snapshot exceeds its aggregate byte bound")
        if (
            actual_mode & 0o600 != 0o600
            or actual_mode & 0o022
            or (mode == "100755" and not actual_mode & 0o100)
            or (mode == "100644" and actual_mode & 0o111)
        ):
            raise ReadinessError("checkout snapshot file mode differs from its index")
        actual_oid = _git_blob_oid(child, object_format, MAX_ARCHIVE_BYTES)
        if actual_oid != expected_oid:
            raise ReadinessError("checkout snapshot file bytes differ from its index")
        seen_files.add(relative)
        records.extend(
            (
                relative.encode("utf-8"),
                mode.encode("ascii"),
                f"{actual_mode:04o}".encode("ascii"),
                actual_oid.encode("ascii"),
            )
        )
    if seen_files != set(expected) or seen_directories != expected_directories:
        raise ReadinessError("checkout snapshot inventory differs from its index")
    return sha256_bytes(_length_prefixed(records))


def _inspect_source_bound_snapshot(
    snapshot: Path,
    index_entries: Sequence[tuple[str, str, str]],
    expected_source: Mapping[str, Any],
) -> str:
    """Bind snapshot inventory and bytes to both staged OIDs and source identity."""

    source = copy.deepcopy(_mapping(expected_source, "checkout snapshot source"))
    _validate_source(source)
    object_format = source["gitObjectFormat"]
    fingerprint = _inspect_checkout_snapshot(snapshot, index_entries, object_format)
    if (
        _source_basis_from_checked_tree(
            snapshot,
            index_entries,
            object_format=object_format,
            expected_source=source,
        )
        != source
    ):
        raise ReadinessError("checkout snapshot source differs from its staged identity")
    return fingerprint


def _length_prefixed(parts: Iterable[bytes]) -> bytes:
    output = bytearray()
    for part in parts:
        output.extend(len(part).to_bytes(8, "big"))
        output.extend(part)
    return bytes(output)


def index_source_basis(
    repo_root: Path,
    schema_manifest: Mapping[str, Any],
    schema_manifest_relative: str,
    *,
    index_file: Path | None = None,
) -> dict[str, Any]:
    assert_no_unstaged_source(repo_root, index_file=index_file)
    index_tree_before = _git_text(repo_root, ["write-tree"], index_file=index_file)
    schema_manifest_relative = _safe_relative_path(
        schema_manifest_relative, "schema manifest path"
    )
    basis_sha = schema_manifest_basis_sha256(schema_manifest)
    object_format = _git_text(repo_root, ["rev-parse", "--show-object-format"])
    if object_format not in {"sha1", "sha256"}:
        raise ReadinessError(f"unsupported Git object format: {object_format}")

    entries = _parse_index_entries(repo_root, index_file=index_file)
    result = _source_basis_from_index_entries(
        entries,
        object_format=object_format,
        schema_manifest_relative=schema_manifest_relative,
        schema_manifest_basis_sha256=basis_sha,
    )
    assert_no_unstaged_source(repo_root, index_file=index_file)
    if _git_text(repo_root, ["write-tree"], index_file=index_file) != index_tree_before:
        raise ReadinessError("git index changed while the readiness source basis was captured")
    return result


def _patch_ledger_revision(repo_root: Path) -> int:
    text = _read_regular_bytes(repo_root / PATCH_LEDGER_RELATIVE, MAX_TEXT_BYTES).decode(
        "utf-8", errors="strict"
    )
    matches = re.findall(r"(?m)^Ledger revision: `([1-9][0-9]*)`\s*$", text)
    if len(matches) != 1:
        raise ReadinessError("patch ledger must contain exactly one revision header")
    history_lines = re.findall(r"(?m)^- Revision [^\r\n]+$", text)
    history_matches = re.findall(
        r"(?m)^- Revision ([1-9][0-9]*)(?: [^—\r\n]+)? "
        r"— [0-9]{4}-[0-9]{2}-[0-9]{2}:",
        text,
    )
    if not history_lines or len(history_matches) != len(history_lines):
        raise ReadinessError("patch ledger revision history is malformed")
    history = [int(value) for value in history_matches]
    if history != sorted(history):
        raise ReadinessError("patch ledger revision history is not monotonic")
    revision = int(matches[0])
    if revision != history[-1]:
        raise ReadinessError("patch ledger revision header is stale")
    return revision


def _schema_manifest_relative(version: str) -> str:
    return f"elixir/priv/codex_schema/{version}/manifest.json"


def collect_static_basis(
    repo_root: Path = REPO_ROOT,
    codex_command: str = "codex",
    *,
    index_file: Path | None = None,
) -> tuple[dict[str, Any], MatrixArtifact, dict[str, Any]]:
    """Collect the exact staged checkout, Codex contract, matrix, and schema input."""

    repo_root = Path(os.path.abspath(repo_root))
    assert_no_unstaged_source(repo_root, index_file=index_file)
    index_tree_before = _git_text(repo_root, ["write-tree"], index_file=index_file)
    version = _read_regular_bytes(repo_root / "CODEX_VERSION", 1024).decode("utf-8").strip()
    _identifier(version, "Codex version")
    schema_relative = _schema_manifest_relative(version)
    schema_manifest = _mapping(
        read_json_bounded(repo_root / schema_relative), "schema manifest"
    )
    synthetic_schema_manifest(schema_manifest)

    matrix = read_matrix_artifact(repo_root / MATRIX_RELATIVE)
    _exact_keys(matrix, MATRIX_TOP_LEVEL_KEYS, "capability matrix")
    if matrix.get("codexVersion") != version:
        raise ReadinessError("matrix Codex version differs from CODEX_VERSION")
    profile = _identifier(matrix.get("profile"), "matrix profile")
    matrix_sha = matrix.raw_sha256
    packaged_matrix = repo_root / f"elixir/priv/codex_schema/{version}/method-field-matrix.json"
    packaged_matrix_sha = sha256_bytes(_read_regular_bytes(packaged_matrix, MAX_JSON_BYTES))
    if matrix_sha != packaged_matrix_sha:
        raise ReadinessError("source and packaged capability matrices differ")
    if schema_manifest.get("matrix", {}).get("sha256") != matrix_sha:
        raise ReadinessError("schema manifest matrix hash is stale")

    compatibility = _mapping(schema_manifest["compatibility"], "schema compatibility")
    fixture = _mapping(compatibility.get("fixtureEvidence"), "schema fixture evidence")
    artifacts = _mapping(schema_manifest.get("artifacts"), "schema artifacts")
    codex_manifest = _mapping(schema_manifest.get("codex"), "schema Codex record")
    executable = _mapping(codex_manifest.get("executable"), "schema executable record")
    for key in ("artifactBundleSha256", "schemaBundleSha256"):
        _sha256(artifacts.get(key), f"schema artifacts {key}")
        if fixture.get(key) != artifacts.get(key):
            raise ReadinessError(f"fixture evidence {key} differs from schema artifacts")
    if fixture.get("matrixSha256") != matrix_sha:
        raise ReadinessError("fixture evidence matrix hash is stale")
    if fixture.get("codexVersion") != version or codex_manifest.get("version") != version:
        raise ReadinessError("schema fixture/Codex version is stale")

    lock = _mapping(read_json_bounded(repo_root / "CODEX_LOCK.json"), "Codex lock")
    if lock.get("version") != version:
        raise ReadinessError("CODEX_LOCK version differs from CODEX_VERSION")
    selected = next(
        (
            entry
            for entry in _list(lock.get("platforms"), "Codex lock platforms", 64)
            if isinstance(entry, dict) and entry.get("target") == executable.get("target")
        ),
        None,
    )
    if selected is None:
        raise ReadinessError("schema executable target is absent from CODEX_LOCK")
    for key in ("launcherSha256", "nativeSha256"):
        expected = _sha256(selected.get(key), f"Codex lock {key}")
        if executable.get(key) != expected:
            raise ReadinessError(f"schema executable {key} differs from CODEX_LOCK")
    installed = verify_installed_codex(lock, selected, codex_command)
    if installed["versionOutput"] != codex_manifest.get("versionOutput"):
        raise ReadinessError("installed Codex version output differs from schema manifest")
    for key in ("launcherSha256", "nativeSha256"):
        if installed[key] != executable.get(key):
            raise ReadinessError(f"installed Codex {key} differs from schema manifest")

    source = index_source_basis(
        repo_root,
        schema_manifest,
        schema_relative,
        index_file=index_file,
    )
    upstream_base = _read_regular_bytes(repo_root / "UPSTREAM_BASE", 1024).decode("ascii").strip()
    _commit(upstream_base, "upstream base")
    if _git_text(repo_root, ["cat-file", "-t", upstream_base]) != "commit":
        raise ReadinessError("UPSTREAM_BASE does not identify a commit")
    upstream_commit = _git_text(repo_root, ["rev-parse", "refs/remotes/upstream/main"])
    head_commit = _git_text(repo_root, ["rev-parse", "HEAD"])
    _commit(upstream_commit, "upstream commit")
    _commit(head_commit, "HEAD commit")

    basis = {
        "checkout": {
            "headCommit": head_commit,
            "headSemantics": HEAD_SEMANTICS,
            "patchLedgerRevision": _patch_ledger_revision(repo_root),
            "source": source,
            "upstreamBaseCommit": upstream_base,
            "upstreamCommit": upstream_commit,
        },
        "codex": {
            "artifactBundleSha256": artifacts["artifactBundleSha256"],
            "launcherSha256": installed["launcherSha256"],
            "matrixSha256": matrix_sha,
            "nativeSha256": installed["nativeSha256"],
            "schemaBundleSha256": artifacts["schemaBundleSha256"],
            "schemaManifestBasisSha256": source["schemaManifestBasisSha256"],
            "target": _identifier(executable.get("target"), "Codex executable target"),
            "version": version,
            "versionOutput": _public_text(installed["versionOutput"], "Codex version output"),
        },
    }
    if profile != schema_manifest.get("matrix", {}).get("profile"):
        raise ReadinessError("matrix profile differs from schema manifest")
    _validate_static_basis(basis)
    if read_json_bounded(repo_root / schema_relative) != schema_manifest:
        raise ReadinessError("schema manifest changed while the static basis was collected")
    if read_matrix_artifact(repo_root / MATRIX_RELATIVE).raw_sha256 != matrix_sha:
        raise ReadinessError("capability matrix changed while the static basis was collected")
    assert_no_unstaged_source(repo_root, index_file=index_file)
    if _git_text(repo_root, ["write-tree"], index_file=index_file) != index_tree_before:
        raise ReadinessError("git index changed while the static basis was collected")
    return basis, matrix, schema_manifest


def _normalize_string_list(value: Any, label: str, maximum: int = 64) -> list[str]:
    items = _list(value, label, maximum)
    normalized = [_identifier(item, f"{label} item") for item in items]
    if len(set(normalized)) != len(normalized):
        raise ReadinessError(f"{label} contains duplicates")
    return sorted(normalized)


def _matrix_inventory(matrix: Mapping[str, Any], group: str) -> list[dict[str, Any]]:
    entries = _list(matrix.get(group), f"matrix {group}", 4_096)
    normalized: list[dict[str, Any]] = []
    for index, raw in enumerate(entries):
        entry = _mapping(raw, f"matrix {group}[{index}]")
        identifier = _identifier(entry.get("id"), f"matrix {group} id")
        if group == "negativeCapabilities":
            normalized.append({"id": identifier})
            continue
        requirement = _enum(
            entry.get("requirement"), {"optional", "required", "supporting"},
            f"matrix {group} {identifier} requirement",
        )
        probe = _enum(
            entry.get("r006Probe"), {"conformance", "invoke", "observe", "read"},
            f"matrix {group} {identifier} probe",
        )
        absent = _enum(
            entry.get("absentBehavior"),
            {"block_managed_dispatch", "hide", "safe_block", "studio_substitute"},
            f"matrix {group} {identifier} absent behavior",
        )
        normalized.append(
            {
                "absentBehavior": absent,
                "id": identifier,
                "probe": probe,
                "requirement": requirement,
            }
        )
    normalized.sort(key=lambda item: item["id"])
    if len({entry["id"] for entry in normalized}) != len(normalized):
        raise ReadinessError(f"matrix {group} contains duplicate IDs")
    return normalized


def _matrix_outcomes(
    matrix: Mapping[str, Any], report_outcomes: Mapping[str, Any] | None
) -> dict[str, Any]:
    if report_outcomes is not None:
        outcomes = _mapping(report_outcomes, "public report matrixOutcomes")
        _exact_keys(outcomes, MATRIX_OUTCOME_KEYS, "public report matrixOutcomes")
    result: dict[str, Any] = {}
    for group in ("methods", "fields", "negativeCapabilities"):
        inventory = _matrix_inventory(matrix, group)
        supplied: dict[str, Any]
        if report_outcomes is None:
            supplied = {entry["id"]: "not_run" for entry in inventory}
        else:
            supplied = _mapping(outcomes[group], f"public report {group} outcomes")
            expected_ids = {entry["id"] for entry in inventory}
            actual_ids = set(supplied)
            if actual_ids != expected_ids:
                raise ReadinessError(
                    f"public report {group} outcome IDs mismatch; "
                    f"missing={sorted(expected_ids - actual_ids)}, "
                    f"extra={sorted(actual_ids - expected_ids)}"
                )
        rows: list[dict[str, Any]] = []
        for entry in inventory:
            allowed = REQUIRED_OUTCOMES if group == "negativeCapabilities" else OUTCOMES
            outcome = _enum(
                supplied[entry["id"]], allowed, f"{group} {entry['id']} outcome"
            )
            rows.append({**entry, "outcome": outcome})
        result[group] = rows
    return result


def _normalize_models(value: Any) -> list[dict[str, Any]]:
    rows = _list(value, "public report models", MAX_MODELS)
    models: list[dict[str, Any]] = []
    for index, raw in enumerate(rows):
        row = _mapping(raw, f"public report models[{index}]")
        _exact_keys(row, MODEL_KEYS, f"public report models[{index}]")
        tiers = _normalize_string_list(
            row["serviceTierIds"], "public model service tier IDs", 32
        )
        default_tier = _nullable_identifier(
            row["defaultServiceTier"], "public model default service tier"
        )
        fast_tier = _nullable_identifier(
            row["fastServiceTierId"], "public model Fast service tier"
        )
        if default_tier is not None and default_tier not in tiers:
            raise ReadinessError("public model default service tier is not advertised")
        if fast_tier is not None and fast_tier not in tiers:
            raise ReadinessError("public model Fast service tier is not advertised")
        models.append(
            {
                "defaultServiceTier": default_tier,
                "fastServiceTierId": fast_tier,
                "id": _identifier(row["id"], "public model id"),
                "model": _identifier(row["model"], "public model slug"),
                "reasoningEfforts": _normalize_string_list(
                    row["reasoningEfforts"], "public model reasoning efforts", 32
                ),
                "serviceTierIds": tiers,
            }
        )
    models.sort(key=lambda item: (item["model"], item["id"]))
    if len({model["id"] for model in models}) != len(models):
        raise ReadinessError("public report models contain duplicate IDs")
    if len({model["model"] for model in models}) != len(models):
        raise ReadinessError("public report models contain duplicate model slugs")
    return models


def _default_subagents() -> dict[str, Any]:
    return {
        "hookFailureClassification": "not_run",
        "implementation": "multi_agent_v2",
        "nativeDepthEnforcement": None,
        "rawToOptionalChildren": [],
        "rootCountsTowardLimit": None,
        "studioDepthGuardRequired": True,
        "trustedGuardStatus": "not_run",
    }


def _normalize_subagents(value: Any) -> dict[str, Any]:
    row = _mapping(value, "public report subagents")
    _exact_keys(row, SUBAGENT_KEYS, "public report subagents")
    mapping_rows = _list(row["rawToOptionalChildren"], "subagent cap mapping", 16)
    normalized_mapping: list[dict[str, int]] = []
    for index, raw in enumerate(mapping_rows):
        cap = _mapping(raw, f"subagent cap mapping[{index}]")
        _exact_keys(cap, CAP_ROW_KEYS, f"subagent cap mapping[{index}]")
        if type(cap["raw"]) is not int or type(cap["optionalChildren"]) is not int:
            raise ReadinessError("subagent cap mapping values must be integers")
        normalized_mapping.append(
            {"optionalChildren": cap["optionalChildren"], "raw": cap["raw"]}
        )
    normalized_mapping.sort(key=lambda item: item["raw"])
    for key in (
        "rootCountsTowardLimit",
        "nativeDepthEnforcement",
        "studioDepthGuardRequired",
    ):
        if type(row[key]) is not bool:
            raise ReadinessError(f"public report subagents {key} must be boolean")
    return {
        "hookFailureClassification": _enum(
            row["hookFailureClassification"],
            {"blocked", "fail_open", "not_run"},
            "subagent hook failure classification",
        ),
        "implementation": _identifier(row["implementation"], "subagent implementation"),
        "nativeDepthEnforcement": row["nativeDepthEnforcement"],
        "rawToOptionalChildren": normalized_mapping,
        "rootCountsTowardLimit": row["rootCountsTowardLimit"],
        "studioDepthGuardRequired": row["studioDepthGuardRequired"],
        "trustedGuardStatus": _enum(
            row["trustedGuardStatus"], REQUIRED_OUTCOMES, "trusted guard status"
        ),
    }


def _normalize_status_object(
    value: Any, keys: set[str], label: str, *, optional_keys: set[str] | None = None
) -> dict[str, str]:
    row = _mapping(value, label)
    _exact_keys(row, keys, label)
    optional_keys = optional_keys or set()
    result: dict[str, str] = {}
    for key in sorted(keys):
        allowed = OUTCOMES if key in optional_keys else REQUIRED_OUTCOMES
        result[key] = _enum(row[key], allowed, f"{label} {key}")
    return result


def _default_quota() -> dict[str, str]:
    return {key: "not_run" for key in sorted(QUOTA_KEYS)}


def _default_identity_binding() -> dict[str, Any]:
    return {
        "bindingId": None,
        "evidence": "not_run",
        "generation": 0,
        "status": "not_run",
    }


def _default_reference_profile() -> dict[str, Any]:
    return {
        **{key: False for key in sorted(REFERENCE_PROFILE_KEYS - {"status"})},
        "status": "not_run",
    }


def _normalize_reference_profile(
    value: Any, *, allow_not_run: bool
) -> dict[str, Any]:
    row = _mapping(value, "public reference profile")
    _exact_keys(row, REFERENCE_PROFILE_KEYS, "public reference profile")
    normalized = {
        key: _boolean(row[key], f"public reference profile {key}")
        for key in sorted(REFERENCE_PROFILE_KEYS - {"status"})
    }
    allowed_statuses = {"fail", "pass"}
    if allow_not_run:
        allowed_statuses.add("not_run")
    status = _enum(
        row["status"], allowed_statuses, "public reference profile status"
    )
    normalized["status"] = status
    if status == "not_run":
        if normalized != _default_reference_profile():
            raise ReadinessError("not-run reference profile must use exact defaults")
        return normalized
    expected_status = (
        "pass"
        if all(normalized[key] for key in REFERENCE_PROFILE_KEYS - {"status"})
        else "fail"
    )
    if status != expected_status:
        raise ReadinessError("public reference profile status is inconsistent")
    return normalized


def _expected_reference_profile(
    models: Sequence[Mapping[str, Any]],
    auth_mode: str,
    identity_binding: Mapping[str, Any],
) -> dict[str, Any]:
    by_model = {model["model"]: model for model in models}
    sol = by_model.get("gpt-5.6-sol")
    terra = by_model.get("gpt-5.6-terra")
    sol_efforts = set(sol["reasoningEfforts"]) if sol is not None else set()
    terra_efforts = set(terra["reasoningEfforts"]) if terra is not None else set()
    profile = {
        "chatgptAuthentication": auth_mode == "chatgpt",
        "identityBinding": identity_binding.get("status") == "confirmed",
        "solAvailable": sol is not None,
        "solReviewEffort": bool(sol_efforts.intersection({"high", "max"})),
        "solUltra": "ultra" in sol_efforts,
        "terraAvailable": terra is not None,
        "terraHigh": "high" in terra_efforts,
        "terraMedium": "medium" in terra_efforts,
    }
    profile["status"] = "pass" if all(profile.values()) else "fail"
    return profile


def _validate_reference_profile_binding(
    profile: Mapping[str, Any],
    models: Sequence[Mapping[str, Any]],
    auth_mode: str,
    identity_binding: Mapping[str, Any],
    *,
    allow_not_run: bool,
) -> None:
    if allow_not_run and profile == _default_reference_profile():
        return
    if profile != _expected_reference_profile(models, auth_mode, identity_binding):
        raise ReadinessError(
            "public reference profile differs from visible model/authentication evidence"
        )


def _normalize_identity_binding(value: Any) -> dict[str, Any]:
    row = _mapping(value, "public identity binding")
    _exact_keys(row, IDENTITY_BINDING_KEYS, "public identity binding")
    status = _enum(
        row["status"], IDENTITY_BINDING_STATUSES, "public identity binding status"
    )
    evidence = _enum(
        row["evidence"],
        {"keyed_account_metadata", "not_run", "unavailable"},
        "public identity binding evidence",
    )
    generation = row["generation"]
    if type(generation) is not int or generation < 0:
        raise ReadinessError("public identity binding generation must be non-negative")
    binding_id = row["bindingId"]
    if binding_id is not None and (
        not isinstance(binding_id, str) or not IDENTITY_BINDING_ID_RE.fullmatch(binding_id)
    ):
        raise ReadinessError("public identity binding ID has an invalid persistence-safe form")
    normalized = {
        "bindingId": binding_id,
        "evidence": evidence,
        "generation": generation,
        "status": status,
    }
    if status == "confirmed":
        if binding_id is None or generation <= 0 or evidence != "keyed_account_metadata":
            raise ReadinessError("confirmed identity binding lacks exact keyed evidence")
    elif status == "unconfirmed":
        if binding_id is not None or generation <= 0 or evidence != "unavailable":
            raise ReadinessError("unconfirmed identity binding has inconsistent evidence")
    elif status == "not_run":
        if normalized != _default_identity_binding():
            raise ReadinessError("not-run identity binding must use exact defaults")
    elif normalized != {
        "bindingId": None,
        "evidence": "unavailable",
        "generation": 0,
        "status": "blocked",
    }:
        raise ReadinessError("blocked identity binding must use exact unavailable evidence")
    return normalized


def _default_linear() -> dict[str, Any]:
    return {
        "configuredProjectBinding": None,
        **{
            key: {"status": "not_run"}
            for key in LINEAR_STATUS_KEYS_IN_PROBE_ORDER
            if key != "mutations"
        },
        "mutations": {"evidence": "not_run", "status": "not_run"},
    }


def _normalize_linear(value: Any, label: str = "public report Linear") -> dict[str, Any]:
    row = _mapping(value, label)
    _exact_keys(row, LINEAR_KEYS, label)
    binding = row["configuredProjectBinding"]
    if binding is not None and (
        not isinstance(binding, str) or not LINEAR_BINDING_RE.fullmatch(binding)
    ):
        raise ReadinessError(f"{label} configured project binding is invalid")
    result: dict[str, Any] = {"configuredProjectBinding": binding}
    for key in LINEAR_STATUS_KEYS_IN_PROBE_ORDER:
        status_row = _mapping(row[key], f"{label} {key}")
        if key == "mutations":
            _exact_keys(status_row, LINEAR_MUTATION_ROW_KEYS, f"{label} {key}")
            status = _enum(
                status_row["status"], REQUIRED_OUTCOMES, f"{label} {key} status"
            )
            evidence = _enum(
                status_row["evidence"],
                LINEAR_MUTATION_EVIDENCE,
                f"{label} {key} evidence",
            )
            allowed_pairs = {
                ("blocked", "schema_only"),
                ("blocked", "unavailable"),
                ("not_run", "not_run"),
                ("pass", "schema_only"),
            }
            if (status, evidence) not in allowed_pairs:
                raise ReadinessError(
                    f"{label} mutations status/evidence pair is inconsistent"
                )
            result[key] = {"evidence": evidence, "status": status}
        else:
            _exact_keys(status_row, LINEAR_STATUS_ROW_KEYS, f"{label} {key}")
            result[key] = {
                "status": _enum(
                    status_row["status"], REQUIRED_OUTCOMES, f"{label} {key} status"
                )
            }
    if binding is None and any(
        result[key]["status"] != "not_run" for key in LINEAR_STATUS_KEYS_IN_PROBE_ORDER
    ):
        raise ReadinessError(f"{label} statuses require a configured project binding")
    return result


def _default_platform() -> dict[str, str]:
    return {
        "architecture": "unavailable",
        "os": "unavailable",
        "osStatus": "not_run",
        "package": "unavailable",
        "packageStatus": "not_run",
    }


def _normalize_platform(value: Any) -> dict[str, str]:
    row = _mapping(value, "public report platform")
    _exact_keys(row, PLATFORM_KEYS, "public report platform")
    return {
        "architecture": _identifier(row["architecture"], "platform architecture"),
        "os": _identifier(row["os"], "platform OS"),
        "osStatus": _enum(row["osStatus"], REQUIRED_OUTCOMES, "platform OS status"),
        "package": _identifier(row["package"], "platform package"),
        "packageStatus": _enum(
            row["packageStatus"], PACKAGE_OUTCOMES, "platform package status"
        ),
    }


def _validate_platform_binding(
    platform: Mapping[str, Any], codex: Mapping[str, Any], *, allow_not_run: bool
) -> None:
    row = _mapping(platform, "readiness platform")
    if allow_not_run and row == _default_platform():
        return
    target = codex.get("target")
    expected = CODEX_TARGET_PLATFORMS.get(target)
    if expected is None:
        raise ReadinessError("Codex target has no supported readiness platform mapping")
    expected_os, expected_architecture = expected
    if row.get("os") != expected_os or row.get("architecture") != expected_architecture:
        raise ReadinessError("readiness platform differs from the verified Codex target")
    if row.get("package") != SUPPORTED_RELEASE_PACKAGE:
        raise ReadinessError("readiness package identifier is unsupported")


def _normalize_command(value: Any, label: str) -> list[str]:
    arguments = _list(value, label, MAX_COMMAND_ARGUMENTS)
    if not arguments:
        raise ReadinessError(f"{label} cannot be empty")
    normalized: list[str] = []
    for index, argument in enumerate(arguments):
        if not isinstance(argument, str) or not argument or "\x00" in argument:
            raise ReadinessError(f"{label}[{index}] must be a non-empty string")
        if len(argument.encode("utf-8")) > MAX_COMMAND_ARGUMENT_BYTES:
            raise ReadinessError(f"{label}[{index}] exceeds its byte bound")
        if _contains_absolute_path(argument):
            raise ReadinessError(f"{label}[{index}] contains an absolute path")
        if EMAIL_RE.search(argument) or any(pattern.search(argument) for pattern in SECRET_PATTERNS):
            raise ReadinessError(f"{label}[{index}] contains private or secret-like data")
        if SENSITIVE_ASSIGNMENT_RE.search(argument):
            raise ReadinessError(f"{label}[{index}] contains a sensitive assignment")
        normalized.append(argument)
    return normalized


def _normalize_conformance(value: Any) -> list[dict[str, Any]]:
    rows = _list(value, "public report conformance", MAX_CONFORMANCE_ROWS)
    result: list[dict[str, Any]] = []
    for index, raw in enumerate(rows):
        row = _mapping(raw, f"public report conformance[{index}]")
        _exact_keys(row, CONFORMANCE_ROW_KEYS, f"public report conformance[{index}]")
        if type(row["required"]) is not bool:
            raise ReadinessError("conformance required flag must be boolean")
        result.append(
            {
                "command": _normalize_command(
                    row["command"], f"public report conformance[{index}] command"
                ),
                "id": _identifier(row["id"], "conformance id"),
                "outcome": _enum(
                    row["outcome"], REQUIRED_OUTCOMES, "conformance outcome"
                ),
                "required": row["required"],
            }
        )
    result.sort(key=lambda item: item["id"])
    if len({row["id"] for row in result}) != len(result):
        raise ReadinessError("public report conformance contains duplicate IDs")
    return result


def _require_conformance_inventory(rows: list[dict[str, Any]]) -> None:
    actual = {row["id"] for row in rows}
    if actual != REQUIRED_CONFORMANCE_IDS:
        raise ReadinessError(
            "Release 0 conformance inventory mismatch; "
            f"missing={sorted(REQUIRED_CONFORMANCE_IDS - actual)}, "
            f"extra={sorted(actual - REQUIRED_CONFORMANCE_IDS)}"
        )
    if not all(row["required"] for row in rows):
        raise ReadinessError("every Release 0 conformance inventory row must be required")
    for row in rows:
        expected_command = list(REQUIRED_CONFORMANCE_COMMANDS[row["id"]])
        if row["command"] != expected_command:
            raise ReadinessError(
                f"Release 0 conformance command differs for {row['id']}"
            )


def _validate_public_report(report: Mapping[str, Any]) -> dict[str, Any]:
    value = copy.deepcopy(_mapping(report, "public capability report"))
    _exact_keys(value, PUBLIC_REPORT_KEYS, "public capability report")
    if value["reportVersion"] != 1:
        raise ReadinessError("unsupported public capability report version")
    _assert_public_tree(value, "public capability report")
    return value


def _blockers(
    matrix: Mapping[str, Any],
    models: list[dict[str, Any]],
    subagents: Mapping[str, Any],
    auth: Mapping[str, Any],
    quota: Mapping[str, Any],
    linear: Mapping[str, Any],
    platform: Mapping[str, Any],
    conformance: list[dict[str, Any]],
) -> list[str]:
    blockers: list[str] = []
    for group in ("methods", "fields"):
        for row in matrix[group]:
            outcome = row["outcome"]
            if outcome in {"blocked", "not_run"} or (
                row["requirement"] == "required" and outcome != "pass"
            ):
                blockers.append(f"matrix.{group}.{row['id']}")
    for row in matrix["negativeCapabilities"]:
        if row["outcome"] != "pass":
            blockers.append(f"matrix.negativeCapabilities.{row['id']}")

    by_model = {model["model"]: model for model in models}
    sol = by_model.get("gpt-5.6-sol")
    terra = by_model.get("gpt-5.6-terra")
    if sol is None:
        blockers.append("models.gpt-5.6-sol")
    else:
        efforts = set(sol["reasoningEfforts"])
        if "ultra" not in efforts:
            blockers.append("models.gpt-5.6-sol.ultra")
        if not efforts.intersection({"high", "max"}):
            blockers.append("models.gpt-5.6-sol.review_effort")
    if terra is None:
        blockers.append("models.gpt-5.6-terra")
    else:
        terra_efforts = set(terra["reasoningEfforts"])
        for effort in ("high", "medium"):
            if effort not in terra_efforts:
                blockers.append(f"models.gpt-5.6-terra.{effort}")

    if auth["mode"] != "chatgpt" or auth["referenceProfile"]["status"] != "pass":
        blockers.append("auth.reference_profile")
    if auth["identityBinding"]["status"] != "confirmed":
        blockers.append("auth.identity_binding")
    if list(subagents["rawToOptionalChildren"]) != list(EXPECTED_CAP_MAPPING):
        blockers.append("subagents.cap_mapping")
    if subagents["implementation"] != "multi_agent_v2":
        blockers.append("subagents.implementation")
    if subagents["rootCountsTowardLimit"] is not True:
        blockers.append("subagents.root_count")
    if subagents["nativeDepthEnforcement"] is not False:
        blockers.append("subagents.native_depth")
    if subagents["studioDepthGuardRequired"] is not True:
        blockers.append("subagents.studio_depth_guard_required")
    if subagents["trustedGuardStatus"] != "pass":
        blockers.append("subagents.trusted_guard")
    if subagents["hookFailureClassification"] != "fail_open":
        blockers.append("subagents.hook_failure_classification")

    for key in ("fullRead", "sparseUpdate"):
        if quota[key] != "pass":
            blockers.append(f"quota.{key}")
    for key in ("multiBucket", "usage"):
        if quota[key] in {"blocked", "not_run"}:
            blockers.append(f"quota.{key}")
    for key in LINEAR_STATUS_KEYS_IN_PROBE_ORDER:
        if linear[key]["status"] != "pass":
            blockers.append(f"linear.{key}")
    if platform["osStatus"] != "pass":
        blockers.append("platform.os")
    if platform["packageStatus"] != "pass":
        blockers.append("platform.package")
    for row in conformance:
        if row["required"] and row["outcome"] != "pass":
            blockers.append(f"conformance.{row['id']}")
    if not conformance:
        blockers.append("conformance.absent")
    return sorted(set(blockers))


def build_readiness_candidate(
    static_basis: Mapping[str, Any],
    matrix: MatrixArtifact,
    public_report: VerifiedPublicReport | None,
) -> dict[str, Any]:
    """Build one deterministic public candidate without publishing it."""

    static = copy.deepcopy(_mapping(static_basis, "static readiness basis"))
    _validate_static_basis(static)
    matrix_artifact = _require_matrix_artifact(matrix)
    matrix_value = matrix_artifact._copy_for_verification()
    _exact_keys(matrix_value, MATRIX_TOP_LEVEL_KEYS, "capability matrix")
    if matrix_artifact.raw_sha256 != static["codex"]["matrixSha256"]:
        raise ReadinessError("capability matrix bytes differ from the static Codex basis")
    profile = _identifier(matrix_value.get("profile"), "matrix profile")
    if matrix_value.get("codexVersion") != static["codex"]["version"]:
        raise ReadinessError("matrix version differs from the static Codex basis")

    if public_report is None:
        matrix_result = _matrix_outcomes(matrix_value, None)
        models: list[dict[str, Any]] = []
        subagents = _default_subagents()
        auth = {
            "identityBinding": _default_identity_binding(),
            "mode": "unavailable",
            "referenceProfile": _default_reference_profile(),
        }
        quota = _default_quota()
        linear = _default_linear()
        platform = _default_platform()
        conformance: list[dict[str, Any]] = []
        runtime = {
            "blockers": [],
            "capabilities": "not_run",
            "overall": "pending_r0_06",
        }
    else:
        if not isinstance(public_report, VerifiedPublicReport):
            raise ReadinessError(
                "green/blocked runtime evidence must come from the trusted compiler"
            )
        report = _validate_public_report(
            public_report._copy_for_builder()
        )
        matrix_result = _matrix_outcomes(matrix_value, report["matrixOutcomes"])
        models = _normalize_models(report["models"])
        subagents = _normalize_subagents(report["subagents"])
        identity_binding = _normalize_identity_binding(report["identityBinding"])
        auth_mode = _enum(report["authMode"], AUTH_MODES, "public auth mode")
        reference_profile = _normalize_reference_profile(
            report["referenceProfile"], allow_not_run=False
        )
        _validate_reference_profile_binding(
            reference_profile,
            models,
            auth_mode,
            identity_binding,
            allow_not_run=False,
        )
        auth = {
            "identityBinding": identity_binding,
            "mode": auth_mode,
            "referenceProfile": reference_profile,
        }
        quota = _normalize_status_object(
            report["quota"], QUOTA_KEYS, "public report quota",
            optional_keys={"multiBucket", "usage"},
        )
        linear = _normalize_linear(report["linear"])
        platform = _normalize_platform(report["platform"])
        _validate_platform_binding(platform, static["codex"], allow_not_run=False)
        conformance = _normalize_conformance(report["conformance"])
        _require_conformance_inventory(conformance)
        blockers = _blockers(
            matrix_result, models, subagents, auth, quota, linear, platform, conformance
        )
        runtime = {
            "blockers": blockers,
            "capabilities": "blocked" if blockers else "pass",
            "overall": "blocked_r0_06" if blockers else "pass",
        }

    candidate = {
        "capabilities": {
            "auth": auth,
            "linear": linear,
            "matrix": matrix_result,
            "models": models,
            "quota": quota,
            "subagents": subagents,
        },
        "checkout": static["checkout"],
        "codex": static["codex"],
        "conformance": conformance,
        "manifestVersion": 1,
        "platform": platform,
        "profile": profile,
        "runtime": runtime,
    }
    validate_readiness_manifest(candidate, matrix_artifact)
    _assert_public_tree(candidate)
    return candidate


def attach_readiness_to_schema(
    schema_manifest: Mapping[str, Any], readiness: Mapping[str, Any]
) -> dict[str, Any]:
    """Return the schema half of the pair without mutating either input."""

    schema = copy.deepcopy(_mapping(schema_manifest, "schema manifest"))
    expected_basis = schema_manifest_basis_sha256(schema)
    readiness_value = copy.deepcopy(_mapping(readiness, "readiness manifest"))
    source = _mapping(readiness_value.get("checkout", {}).get("source"), "readiness source")
    if source.get("schemaManifestBasisSha256") != expected_basis:
        raise ReadinessError("readiness candidate uses a different synthetic schema basis")
    runtime = _mapping(readiness_value.get("runtime"), "readiness runtime")
    compatibility = _mapping(schema["compatibility"], "schema compatibility")
    compatibility["runtimeCapabilities"] = runtime.get("capabilities")
    compatibility["overall"] = runtime.get("overall")
    compatibility["runtimeEvidence"] = {
        "hashAlgorithm": HASH_ALGORITHM,
        "readinessManifestSha256": sha256_bytes(canonical_json_bytes(readiness_value)),
        "schemaManifestBasisSha256": expected_basis,
        "sourceSha256": source.get("sha256"),
    }
    _validate_schema_manifest(schema)
    return schema


def build_readiness_pair(
    static_basis: Mapping[str, Any],
    matrix: MatrixArtifact,
    schema_manifest: Mapping[str, Any],
    public_report: VerifiedPublicReport | None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    readiness = build_readiness_candidate(static_basis, matrix, public_report)
    schema = attach_readiness_to_schema(schema_manifest, readiness)
    verify_readiness_pair(readiness, schema, matrix, expected_static_basis=static_basis)
    return readiness, schema


def _validate_source(source: Mapping[str, Any]) -> None:
    row = _mapping(source, "readiness source")
    _exact_keys(row, SOURCE_KEYS, "readiness source")
    if row["algorithm"] != SOURCE_ALGORITHM:
        raise ReadinessError("readiness source algorithm is unsupported")
    if type(row["fileCount"]) is not int or row["fileCount"] <= 0:
        raise ReadinessError("readiness source fileCount must be positive")
    if row["gitObjectFormat"] not in {"sha1", "sha256"}:
        raise ReadinessError("readiness source Git object format is unsupported")
    if row["readinessPathExcluded"] is not True:
        raise ReadinessError("readiness source must exclude its own artifact path")
    _safe_relative_path(row["schemaManifestPath"], "readiness schema manifest path")
    _sha256(row["schemaManifestBasisSha256"], "schema manifest basis")
    _sha256(row["sha256"], "readiness source hash")


def _validate_static_basis(value: Mapping[str, Any]) -> None:
    basis = _mapping(value, "static readiness basis")
    _exact_keys(basis, STATIC_BASIS_KEYS, "static readiness basis")
    checkout = _mapping(basis["checkout"], "static checkout")
    _exact_keys(checkout, CHECKOUT_KEYS, "static checkout")
    _commit(checkout["upstreamBaseCommit"], "upstream base commit")
    _commit(checkout["upstreamCommit"], "upstream commit")
    _commit(checkout["headCommit"], "HEAD commit")
    if checkout["headSemantics"] != HEAD_SEMANTICS:
        raise ReadinessError("static checkout HEAD semantics are unsupported")
    if type(checkout["patchLedgerRevision"]) is not int or checkout["patchLedgerRevision"] <= 0:
        raise ReadinessError("patch ledger revision must be positive")
    _validate_source(checkout["source"])
    expected_commit_length = 40 if checkout["source"]["gitObjectFormat"] == "sha1" else 64
    for key in ("upstreamBaseCommit", "upstreamCommit", "headCommit"):
        if len(checkout[key]) != expected_commit_length:
            raise ReadinessError(
                f"static checkout {key} width differs from its Git object format"
            )
    codex = _mapping(basis["codex"], "static Codex basis")
    _exact_keys(codex, CODEX_KEYS, "static Codex basis")
    for key in (
        "artifactBundleSha256",
        "launcherSha256",
        "matrixSha256",
        "nativeSha256",
        "schemaBundleSha256",
        "schemaManifestBasisSha256",
    ):
        _sha256(codex[key], f"static Codex {key}")
    if codex["schemaManifestBasisSha256"] != checkout["source"]["schemaManifestBasisSha256"]:
        raise ReadinessError("static Codex and source schema bases differ")
    for key in ("target", "version"):
        _identifier(codex[key], f"static Codex {key}")
    _public_text(codex["versionOutput"], "static Codex versionOutput")


def _validate_matrix_rows(matrix: Mapping[str, Any], source_matrix: Mapping[str, Any]) -> None:
    value = _mapping(matrix, "readiness matrix")
    _exact_keys(value, MATRIX_OUTCOME_KEYS, "readiness matrix")
    for group in ("methods", "fields", "negativeCapabilities"):
        expected = _matrix_inventory(source_matrix, group)
        rows = _list(value[group], f"readiness matrix {group}", 4_096)
        normalized: list[dict[str, Any]] = []
        for index, raw in enumerate(rows):
            row = _mapping(raw, f"readiness matrix {group}[{index}]")
            keys = NEGATIVE_ROW_KEYS if group == "negativeCapabilities" else MATRIX_ROW_KEYS
            _exact_keys(row, keys, f"readiness matrix {group}[{index}]")
            outcome = _enum(
                row["outcome"],
                REQUIRED_OUTCOMES if group == "negativeCapabilities" else OUTCOMES,
                f"readiness matrix {group} outcome",
            )
            normalized.append({**{key: row[key] for key in keys if key != "outcome"}, "outcome": outcome})
        canonical = sorted(normalized, key=lambda item: item["id"])
        if normalized != canonical:
            raise ReadinessError(f"readiness matrix {group} rows are not in canonical ID order")
        normalized = canonical
        expected_with_outcome = [
            {**entry, "outcome": next(row["outcome"] for row in normalized if row["id"] == entry["id"])}
            for entry in expected
        ] if {row.get("id") for row in normalized} == {entry["id"] for entry in expected} else []
        if normalized != expected_with_outcome:
            raise ReadinessError(f"readiness matrix {group} differs from the exact source matrix")


def _validate_models(value: Any) -> list[dict[str, Any]]:
    return _normalize_models(value)


def _validate_subagents(value: Any, *, allow_not_run_defaults: bool) -> dict[str, Any]:
    row = _mapping(value, "readiness subagents")
    _exact_keys(row, SUBAGENT_KEYS, "readiness subagents")
    if allow_not_run_defaults and row == _default_subagents():
        return copy.deepcopy(row)
    return _normalize_subagents(row)


def validate_readiness_manifest(
    readiness: Mapping[str, Any], matrix: MatrixArtifact
) -> None:
    value = _mapping(readiness, "readiness manifest")
    matrix_artifact = _require_matrix_artifact(matrix)
    source_matrix = matrix_artifact._copy_for_verification()
    _exact_keys(source_matrix, MATRIX_TOP_LEVEL_KEYS, "capability matrix")
    _exact_keys(value, READINESS_ROOT_KEYS, "readiness manifest")
    if value["manifestVersion"] != 1:
        raise ReadinessError("unsupported readiness manifest version")
    if value["profile"] != source_matrix.get("profile"):
        raise ReadinessError("readiness profile differs from the capability matrix")
    _validate_static_basis({"checkout": value["checkout"], "codex": value["codex"]})
    if matrix_artifact.raw_sha256 != value["codex"]["matrixSha256"]:
        raise ReadinessError("capability matrix bytes differ from the readiness Codex basis")
    capabilities = _mapping(value["capabilities"], "readiness capabilities")
    _exact_keys(capabilities, CAPABILITY_KEYS, "readiness capabilities")
    _validate_matrix_rows(capabilities["matrix"], source_matrix)
    models = _validate_models(capabilities["models"])
    if models != capabilities["models"]:
        raise ReadinessError("readiness models must be normalized and sorted")
    auth = _mapping(capabilities["auth"], "readiness auth")
    _exact_keys(auth, AUTH_KEYS, "readiness auth")
    auth_mode = _enum(auth["mode"], AUTH_MODES, "readiness auth mode")
    identity_binding = _normalize_identity_binding(auth["identityBinding"])
    if identity_binding != auth["identityBinding"]:
        raise ReadinessError("readiness identity binding must be normalized")
    quota = _normalize_status_object(
        capabilities["quota"], QUOTA_KEYS, "readiness quota",
        optional_keys={"multiBucket", "usage"},
    )
    linear = _normalize_linear(capabilities["linear"], "readiness Linear")
    runtime = _mapping(value["runtime"], "readiness runtime")
    _exact_keys(runtime, RUNTIME_KEYS, "readiness runtime")
    runtime_capabilities = _enum(
        runtime["capabilities"], RUNTIME_CAPABILITIES, "readiness runtime capabilities"
    )
    runtime_overall = _enum(runtime["overall"], RUNTIME_OVERALL, "readiness runtime overall")
    blockers = _list(runtime["blockers"], "readiness blockers", 10_000)
    normalized_blockers = sorted(_identifier(item, "readiness blocker") for item in blockers)
    if normalized_blockers != blockers or len(set(blockers)) != len(blockers):
        raise ReadinessError("readiness blockers must be unique and sorted")

    platform = _mapping(value["platform"], "readiness platform")
    _exact_keys(platform, PLATFORM_KEYS, "readiness platform")
    if platform == _default_platform():
        normalized_platform = platform
    else:
        normalized_platform = _normalize_platform(platform)
    _validate_platform_binding(
        normalized_platform,
        value["codex"],
        allow_not_run=runtime_capabilities == "not_run",
    )
    conformance = _normalize_conformance(value["conformance"])
    if conformance != value["conformance"]:
        raise ReadinessError("readiness conformance rows must be normalized and sorted")

    not_run = runtime_capabilities == "not_run"
    reference_profile = _normalize_reference_profile(
        auth["referenceProfile"], allow_not_run=not_run
    )
    if reference_profile != auth["referenceProfile"]:
        raise ReadinessError("readiness reference profile must be normalized")
    _validate_reference_profile_binding(
        reference_profile,
        models,
        auth_mode,
        identity_binding,
        allow_not_run=not_run,
    )
    subagents = _validate_subagents(
        capabilities["subagents"], allow_not_run_defaults=not_run
    )
    if subagents != capabilities["subagents"]:
        raise ReadinessError("readiness subagent evidence must be normalized")
    if not_run:
        if runtime_overall != "pending_r0_06" or blockers:
            raise ReadinessError("not-run readiness must remain pending without sealed blockers")
        expected_matrix = _matrix_outcomes(source_matrix, None)
        if capabilities["matrix"] != expected_matrix:
            raise ReadinessError("not-run readiness must mark every matrix ID not_run")
        if (
            models
            or auth["mode"] != "unavailable"
            or auth["identityBinding"] != _default_identity_binding()
            or auth["referenceProfile"] != _default_reference_profile()
        ):
            raise ReadinessError("not-run readiness cannot claim models or authentication")
        if quota != _default_quota() or linear != _default_linear():
            raise ReadinessError("not-run readiness cannot claim quota or Linear results")
        if subagents != _default_subagents() or normalized_platform != _default_platform():
            raise ReadinessError("not-run readiness cannot claim subagent/platform results")
        if conformance:
            raise ReadinessError("not-run readiness cannot claim conformance outcomes")
    else:
        _require_conformance_inventory(conformance)
        expected_blockers = _blockers(
            capabilities["matrix"],
            models,
            subagents,
            auth,
            quota,
            linear,
            normalized_platform,
            conformance,
        )
        if blockers != expected_blockers:
            raise ReadinessError("readiness blocker set does not match the public evidence")
        expected_capabilities = "blocked" if blockers else "pass"
        expected_overall = "blocked_r0_06" if blockers else "pass"
        if runtime_capabilities != expected_capabilities or runtime_overall != expected_overall:
            raise ReadinessError("readiness runtime status does not match its blockers")
    _assert_public_tree(value)


def verify_readiness_pair(
    readiness: Mapping[str, Any],
    schema_manifest: Mapping[str, Any],
    matrix: MatrixArtifact,
    *,
    expected_static_basis: Mapping[str, Any] | None = None,
) -> None:
    """Verify semantic content and the bidirectional, non-cyclic pair binding."""

    matrix_artifact = _require_matrix_artifact(matrix)
    value = copy.deepcopy(_mapping(readiness, "readiness manifest"))
    schema = copy.deepcopy(_mapping(schema_manifest, "schema manifest"))
    validate_readiness_manifest(value, matrix_artifact)
    synthetic = synthetic_schema_manifest(schema)
    basis_sha = sha256_bytes(canonical_json_bytes(synthetic))
    source = _mapping(value["checkout"]["source"], "readiness source")
    if basis_sha != source["schemaManifestBasisSha256"]:
        raise ReadinessError("readiness/schema synthetic basis mismatch")
    if value["codex"]["schemaManifestBasisSha256"] != basis_sha:
        raise ReadinessError("Codex/schema synthetic basis mismatch")
    schema_codex = codex_basis_from_schema(schema)
    if value["codex"] != schema_codex:
        raise ReadinessError("readiness Codex hashes differ from schema manifest")
    schema_matrix = _mapping(schema.get("matrix"), "schema matrix")
    if schema_matrix.get("sha256") != matrix_artifact.raw_sha256:
        raise ReadinessError("capability matrix bytes differ from the schema manifest")
    if schema_matrix.get("profile") != value["profile"]:
        raise ReadinessError("readiness profile differs from schema manifest")
    fixture = _mapping(
        schema.get("compatibility", {}).get("fixtureEvidence"),
        "schema fixture evidence",
    )
    fixture_command = _normalize_command(
        fixture.get("command"), "schema source-bound fixture command"
    )
    if fixture_command[:3] != ["mise", "exec", "--"]:
        raise ReadinessError("schema source-bound fixture command has an unexpected launcher")
    root_fixture_command = fixture_command[:2] + ["-C", "elixir"] + fixture_command[2:]
    conformance_by_id = {row["id"]: row for row in value["conformance"]}
    if value["runtime"]["capabilities"] != "not_run" and conformance_by_id[
        "source_bound_fixture_replay"
    ]["command"] != root_fixture_command:
        raise ReadinessError("readiness source-bound replay differs from the schema seal")

    compatibility = _mapping(schema["compatibility"], "schema compatibility")
    evidence = _mapping(compatibility.get("runtimeEvidence"), "schema runtime evidence")
    _exact_keys(evidence, SCHEMA_RUNTIME_EVIDENCE_KEYS, "schema runtime evidence")
    if evidence["hashAlgorithm"] != HASH_ALGORITHM:
        raise ReadinessError("schema runtime evidence hash algorithm is unsupported")
    expected_evidence = {
        "hashAlgorithm": HASH_ALGORITHM,
        "readinessManifestSha256": sha256_bytes(canonical_json_bytes(value)),
        "schemaManifestBasisSha256": basis_sha,
        "sourceSha256": source["sha256"],
    }
    if evidence != expected_evidence:
        raise ReadinessError("readiness/schema pair mismatch")
    if compatibility["runtimeCapabilities"] != value["runtime"]["capabilities"]:
        raise ReadinessError("schema runtime capability status differs from readiness")
    if compatibility["overall"] != value["runtime"]["overall"]:
        raise ReadinessError("schema overall status differs from readiness")
    if expected_static_basis is not None:
        expected = copy.deepcopy(_mapping(expected_static_basis, "expected static basis"))
        _validate_static_basis(expected)
        actual = {"checkout": value["checkout"], "codex": value["codex"]}
        if actual != expected:
            raise ReadinessError("readiness static basis is stale")


def require_green_pair(
    readiness: Mapping[str, Any], schema_manifest: Mapping[str, Any]
) -> None:
    """Require a semantically verified pair to satisfy the R0-06 exit gate."""

    value = _mapping(copy.deepcopy(readiness), "readiness manifest")
    schema = _mapping(copy.deepcopy(schema_manifest), "schema manifest")
    runtime = _mapping(value.get("runtime"), "readiness runtime")
    blockers = _list(runtime.get("blockers"), "readiness blockers", 10_000)
    conformance = _normalize_conformance(value.get("conformance"))
    _require_conformance_inventory(conformance)
    failed = sorted(
        row["id"] for row in conformance if row["outcome"] != "pass"
    )
    platform = _normalize_platform(value.get("platform"))
    compatibility = _mapping(schema.get("compatibility"), "schema compatibility")
    if failed:
        raise ReadinessError(
            "R0-06 acceptance requires every conformance row to pass; "
            f"blocked={failed}"
        )
    if blockers:
        raise ReadinessError("R0-06 acceptance requires an empty blocker set")
    if runtime.get("capabilities") != "pass" or runtime.get("overall") != "pass":
        raise ReadinessError("R0-06 acceptance requires passing runtime status")
    if platform["osStatus"] != "pass" or platform["packageStatus"] != "pass":
        raise ReadinessError("R0-06 acceptance requires passing platform and package status")
    if (
        compatibility.get("runtimeCapabilities") != "pass"
        or compatibility.get("overall") != "pass"
    ):
        raise ReadinessError("R0-06 acceptance requires passing paired schema status")


def _head_matches_generation_basis(repo_root: Path, recorded: str, current: str) -> bool:
    if recorded == current:
        return True
    parent = _run_git(repo_root, ["rev-parse", "HEAD^"], check=False)
    if parent.returncode != 0:
        return False
    return parent.stdout.decode("ascii", errors="strict").strip() == recorded


def verify_repository_pair(
    repo_root: Path = REPO_ROOT,
    readiness_path: Path | None = None,
    codex_command: str = "codex",
    *,
    index_file: Path | None = None,
) -> None:
    """Verify an accepted canonical pair against the current index."""

    repo_root = Path(os.path.abspath(repo_root))
    readiness_path = readiness_path or repo_root / READINESS_RELATIVE
    readiness_bytes = _read_regular_bytes(readiness_path, MAX_JSON_BYTES)
    readiness = _mapping(
        decode_json_bytes(readiness_bytes, str(readiness_path)), "readiness manifest"
    )
    if readiness_bytes != canonical_json_bytes(readiness):
        raise ReadinessError("readiness artifact is not canonical JSON")
    current, matrix, schema = collect_static_basis(
        repo_root, codex_command, index_file=index_file
    )
    verify_readiness_pair(readiness, schema, matrix)
    require_green_pair(readiness, schema)

    recorded_checkout = copy.deepcopy(readiness["checkout"])
    current_checkout = copy.deepcopy(current["checkout"])
    recorded_head = recorded_checkout.pop("headCommit")
    current_head = current_checkout.pop("headCommit")
    if recorded_checkout != current_checkout or readiness["codex"] != current["codex"]:
        raise ReadinessError("readiness checkout, source, or Codex hashes are stale")
    if not _head_matches_generation_basis(repo_root, recorded_head, current_head):
        raise ReadinessError("readiness HEAD basis is stale")
    if readiness["platform"]["packageStatus"] == "pass":
        current_tree = _git_text(repo_root, ["write-tree"], index_file=index_file)
        replay = rehearse_final_pair_source_archive(
            repo_root,
            readiness,
            schema,
            readiness["checkout"]["source"]["sha256"],
            current_tree,
            index_file=index_file,
        )
        if replay["indexTree"] != current_tree:
            raise ReadinessError(
                "published source archive replay differs from the staged final pair"
            )
        if _git_text(repo_root, ["write-tree"], index_file=index_file) != current_tree:
            raise ReadinessError("Git index changed during source archive replay")
    if _read_regular_bytes(readiness_path, MAX_JSON_BYTES) != readiness_bytes:
        raise ReadinessError("readiness artifact changed while it was being verified")


def _candidate_command(args: argparse.Namespace) -> None:
    static, matrix, schema = collect_static_basis(Path(args.repo_root), args.codex)
    report: VerifiedPublicReport | None = None
    if args.live:
        live = validate_codex_probe_record(
            build_codex_probe_record(
                Path(args.repo_root), args.codex, args.mise
            ),
            static,
        )
        after_static, after_matrix, after_schema = collect_static_basis(
            Path(args.repo_root), args.codex
        )
        if (after_static, after_matrix, after_schema) != (static, matrix, schema):
            raise ReadinessError(
                "readiness source or contract changed during live capability discovery"
            )
        report = compile_live_blocked_report(live, matrix, static)
    readiness, paired_schema = build_readiness_pair(static, matrix, schema, report)
    pair = {"readiness": readiness, "schemaManifest": paired_schema}
    sys.stdout.buffer.write(canonical_json_bytes(pair))


def _full_candidate_command(args: argparse.Namespace) -> None:
    readiness, paired_schema, static = compile_full_gate_pair(
        Path(args.repo_root), args.codex, args.mise
    )
    sys.stdout.buffer.write(
        canonical_json_bytes(
            {
                "readiness": readiness,
                "schemaManifest": paired_schema,
                "staticBasis": static,
            }
        )
    )


def _verify_command(args: argparse.Namespace) -> None:
    verify_repository_pair(
        Path(args.repo_root),
        Path(args.readiness) if args.readiness else None,
        args.codex,
    )
    print("verified accepted Symphony Studio implementation-readiness pair")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="command", required=True)
    candidate = subparsers.add_parser(
        "candidate",
        help="emit a canonical readiness/schema candidate pair without publishing files",
    )
    candidate.add_argument(
        "--codex", default="codex", help="installed Codex launcher to verify"
    )
    candidate.add_argument(
        "--live",
        action="store_true",
        help="run the exact no-model capability task and emit a truthful blocked supplement",
    )
    candidate.add_argument("--mise", default="mise")
    candidate.add_argument("--repo-root", default=str(REPO_ROOT))
    candidate.set_defaults(function=_candidate_command)
    full_candidate = subparsers.add_parser(
        "full-candidate",
        help="execute all R0-06 gates and emit the authoritative candidate objects",
    )
    full_candidate.add_argument(
        "--codex", default="codex", help="installed Codex launcher to verify"
    )
    full_candidate.add_argument("--mise", default="mise")
    full_candidate.add_argument("--repo-root", default=str(REPO_ROOT))
    full_candidate.set_defaults(function=_full_candidate_command)
    probe_linear = subparsers.add_parser(
        "probe-linear", help="emit source-bound read-only Linear capability evidence"
    )
    probe_linear.add_argument("--mise", default="mise")
    probe_linear.add_argument("--repo-root", default=str(REPO_ROOT))
    probe_linear.set_defaults(function=_probe_command)
    probe_package = subparsers.add_parser(
        "probe-source-archive", help="emit reproducible staged source archive evidence"
    )
    probe_package.add_argument("--repo-root", default=str(REPO_ROOT))
    probe_package.set_defaults(function=_probe_command)
    probe_codex = subparsers.add_parser(
        "probe-codex", help="emit source-bound no-model Codex capability evidence"
    )
    probe_codex.add_argument(
        "--codex", default="codex", help="installed Codex launcher to verify"
    )
    probe_codex.add_argument("--mise", default="mise")
    probe_codex.add_argument("--repo-root", default=str(REPO_ROOT))
    probe_codex.set_defaults(function=_probe_command)
    verify = subparsers.add_parser(
        "verify", help="verify the committed or staged readiness/schema pair"
    )
    verify.add_argument(
        "--codex", default="codex", help="installed Codex launcher to verify"
    )
    verify.add_argument("--repo-root", default=str(REPO_ROOT))
    verify.add_argument("--readiness")
    verify.set_defaults(function=_verify_command)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        args.function(args)
    except (OSError, ReadinessError, subprocess.SubprocessError) as error:
        print(f"studio-readiness: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
