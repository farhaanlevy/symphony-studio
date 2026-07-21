#!/usr/bin/env python3
# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0
"""Generate and verify Symphony Studio's pinned Codex App Server schemas."""

from __future__ import annotations

import argparse
import copy
from contextlib import contextmanager
import ctypes
from dataclasses import dataclass
from datetime import date
import errno
import fcntl
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import secrets
import selectors
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any, Iterable


REPO_ROOT = Path(__file__).resolve().parents[1]
VERSION_FILE = REPO_ROOT / "CODEX_VERSION"
LOCK_FILE = REPO_ROOT / "CODEX_LOCK.json"
MATRIX_SOURCE = REPO_ROOT / "scripts" / "codex_schema_matrix.json"
SCHEMA_ROOT = REPO_ROOT / "elixir" / "priv" / "codex_schema"
PACKAGED_VERSION_FILE = SCHEMA_ROOT / "CODEX_VERSION"

ARTIFACTS = (
    ("json", "json", True),
    ("typescript", "typescript", False),
    ("experimental/json", "experimental/json", True),
    ("experimental/typescript", "experimental/typescript", False),
)

DIRECTION_FILES = {
    "client_notification": "ClientNotification.json",
    "client_request": "ClientRequest.json",
    "server_notification": "ServerNotification.json",
    "server_request": "ServerRequest.json",
}

METHOD_REQUIREMENTS = {"required", "supporting", "optional"}
ABSENT_BEHAVIORS = {"block_managed_dispatch", "safe_block", "hide", "studio_substitute"}
R006_PROBES = {"conformance", "read", "invoke", "observe"}
R002_ASSERTIONS = {"schema_presence", "present_but_deprecated_ignored"}
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
MANIFEST_TOP_LEVEL_KEYS = {
    "artifacts",
    "codex",
    "compatibility",
    "generation",
    "manifestVersion",
    "matrix",
}

RUNTIME_STATUS_PAIRS = {
    "not_run": "pending_r0_06",
    "blocked": "blocked_r0_06",
    "pass": "pass",
}
RUNTIME_EVIDENCE_KEYS = {
    "hashAlgorithm",
    "readinessManifestSha256",
    "schemaManifestBasisSha256",
    "sourceSha256",
}
RUNTIME_EVIDENCE_HASH_ALGORITHM = "sha256-canonical-json-v1"

LOCK_ROOT = Path("/tmp") / f"symphony-schema-locks-{os.geteuid()}"
SNAPSHOT_ROOT = Path("/tmp") / f"symphony-codex-fixture-snapshots-{os.geteuid()}"
READINESS_RELATIVE = "artifacts/readiness/implementation-readiness.json"
READINESS_TRANSACTION_DIRECTORY = "symphony-readiness-transaction"
READINESS_TRANSACTION_VERSION = 3
READINESS_SCHEMA_INSTALL = ".manifest.readiness-install"
READINESS_ARTIFACT_INSTALL = ".implementation-readiness.install"
READINESS_INDEX_CANDIDATE = "index.candidate"
READINESS_INDEX_COMMIT = "index.commit"
READINESS_INDEX_ROLLBACK = "index.rollback"
READINESS_INDEX_VERIFIER = "index.verifier"
READINESS_VERIFICATION_ATTEMPT = "verification-attempt.json"
READINESS_VERIFICATION_ATTEMPT_PREPARE = ".verification-attempt.prepare"
READINESS_VERIFICATION = "verification.json"
READINESS_VERIFICATION_PREPARE = ".verification.prepare"

# This is the canonical semantic SHA-256 of scripts/codex_schema_matrix.json.
# Update it only after an intentional matrix review; whitespace-only changes do
# not affect the lock.
EXPECTED_MATRIX_CANONICAL_SHA256 = (
    "c0d1c5bfaa5105a9a785b44858767c999f5f3462490366778a1f5f933daabf24"
)

# Canonical SHA-256 of every field assertion's exact resolved schema value,
# keyed by the matrix ID, schema path, and JSON pointer.  The matrix remains a
# readable capability inventory; this independent semantic lock prevents a
# coherently rehashed generated bundle from weakening a claimed field type,
# reference, or union while leaving the matrix text unchanged.
EXPECTED_MATRIX_FIELD_PROBES_SHA256 = (
    "0fe6997b62f8d540851cfa29ddbf1482f34cb8524c7293af3fc8160525e3b93e"
)

# Canonical JSON-schema bundle SHA-256 for the exact pinned executable.  The
# field and method probes make failures specific; this complete independent
# semantic lock also binds validation keywords on every claimed schema's
# ancestors and prevents an impossible or shadowed root from retaining a
# superficially unchanged leaf probe.
EXPECTED_SCHEMA_BUNDLE_SHA256 = (
    "5044e15b8aa187e7deec44ee16b0848a4f9a20aa25e6ec66f10c1d5bcc40141a"
)

# Raw TypeScript plus canonical JSON artifact lock for the same executable.
# Regeneration remains a required independent gate; this static lock ensures a
# coherently rewritten manifest cannot bless generated-artifact drift.
EXPECTED_ARTIFACT_BUNDLE_SHA256 = (
    "d96f8d427cf68655b5658ebea0e9e2332986e8b4b9c1f0ff078957e2ceb70d69"
)

# Explicitly bind every managed method ID to its wire method and schema pair.
# The generated aggregate proves the request/notification and params binding;
# this table prevents a matrix edit from silently remapping a response schema.
EXPECTED_METHOD_CONTRACTS: dict[
    str, tuple[str, str, str, str | None, str | None]
] = {
    "initialize": (
        "initialize",
        "stable",
        "client_request",
        "json/v1/InitializeParams.json",
        "json/v1/InitializeResponse.json",
    ),
    "initialized": ("initialized", "stable", "client_notification", None, None),
    "account_read": (
        "account/read",
        "stable",
        "client_request",
        "json/v2/GetAccountParams.json",
        "json/v2/GetAccountResponse.json",
    ),
    "account_logout": (
        "account/logout",
        "stable",
        "client_request",
        None,
        "json/v2/LogoutAccountResponse.json",
    ),
    "account_rate_limits_read": (
        "account/rateLimits/read",
        "stable",
        "client_request",
        None,
        "json/v2/GetAccountRateLimitsResponse.json",
    ),
    "model_list": (
        "model/list",
        "stable",
        "client_request",
        "json/v2/ModelListParams.json",
        "json/v2/ModelListResponse.json",
    ),
    "thread_start": (
        "thread/start",
        "stable",
        "client_request",
        "json/v2/ThreadStartParams.json",
        "json/v2/ThreadStartResponse.json",
    ),
    "thread_resume": (
        "thread/resume",
        "stable",
        "client_request",
        "json/v2/ThreadResumeParams.json",
        "json/v2/ThreadResumeResponse.json",
    ),
    "turn_start": (
        "turn/start",
        "stable",
        "client_request",
        "json/v2/TurnStartParams.json",
        "json/v2/TurnStartResponse.json",
    ),
    "turn_interrupt": (
        "turn/interrupt",
        "stable",
        "client_request",
        "json/v2/TurnInterruptParams.json",
        "json/v2/TurnInterruptResponse.json",
    ),
    "review_start": (
        "review/start",
        "stable",
        "client_request",
        "json/v2/ReviewStartParams.json",
        "json/v2/ReviewStartResponse.json",
    ),
    "account_rate_limits_updated": (
        "account/rateLimits/updated",
        "stable",
        "server_notification",
        "json/v2/AccountRateLimitsUpdatedNotification.json",
        None,
    ),
    "account_updated": (
        "account/updated",
        "stable",
        "server_notification",
        "json/v2/AccountUpdatedNotification.json",
        None,
    ),
    "thread_status_changed": (
        "thread/status/changed",
        "stable",
        "server_notification",
        "json/v2/ThreadStatusChangedNotification.json",
        None,
    ),
    "turn_started": (
        "turn/started",
        "stable",
        "server_notification",
        "json/v2/TurnStartedNotification.json",
        None,
    ),
    "turn_completed": (
        "turn/completed",
        "stable",
        "server_notification",
        "json/v2/TurnCompletedNotification.json",
        None,
    ),
    "item_started": (
        "item/started",
        "stable",
        "server_notification",
        "json/v2/ItemStartedNotification.json",
        None,
    ),
    "item_completed": (
        "item/completed",
        "stable",
        "server_notification",
        "json/v2/ItemCompletedNotification.json",
        None,
    ),
    "thread_token_usage_updated": (
        "thread/tokenUsage/updated",
        "stable",
        "server_notification",
        "json/v2/ThreadTokenUsageUpdatedNotification.json",
        None,
    ),
    "server_request_resolved": (
        "serverRequest/resolved",
        "stable",
        "server_notification",
        "json/v2/ServerRequestResolvedNotification.json",
        None,
    ),
    "error": (
        "error",
        "stable",
        "server_notification",
        "json/v2/ErrorNotification.json",
        None,
    ),
    "command_approval": (
        "item/commandExecution/requestApproval",
        "stable",
        "server_request",
        "json/CommandExecutionRequestApprovalParams.json",
        "json/CommandExecutionRequestApprovalResponse.json",
    ),
    "file_change_approval": (
        "item/fileChange/requestApproval",
        "stable",
        "server_request",
        "json/FileChangeRequestApprovalParams.json",
        "json/FileChangeRequestApprovalResponse.json",
    ),
    "legacy_exec_command_approval": (
        "execCommandApproval",
        "stable",
        "server_request",
        "json/ExecCommandApprovalParams.json",
        "json/ExecCommandApprovalResponse.json",
    ),
    "legacy_apply_patch_approval": (
        "applyPatchApproval",
        "stable",
        "server_request",
        "json/ApplyPatchApprovalParams.json",
        "json/ApplyPatchApprovalResponse.json",
    ),
    "permissions_approval": (
        "item/permissions/requestApproval",
        "stable",
        "server_request",
        "json/PermissionsRequestApprovalParams.json",
        "json/PermissionsRequestApprovalResponse.json",
    ),
    "tool_user_input": (
        "item/tool/requestUserInput",
        "stable",
        "server_request",
        "json/ToolRequestUserInputParams.json",
        "json/ToolRequestUserInputResponse.json",
    ),
    "mcp_elicitation": (
        "mcpServer/elicitation/request",
        "stable",
        "server_request",
        "json/McpServerElicitationRequestParams.json",
        "json/McpServerElicitationRequestResponse.json",
    ),
    "dynamic_tool_call": (
        "item/tool/call",
        "stable",
        "server_request",
        "json/DynamicToolCallParams.json",
        "json/DynamicToolCallResponse.json",
    ),
    "thread_read": (
        "thread/read",
        "stable",
        "client_request",
        "json/v2/ThreadReadParams.json",
        "json/v2/ThreadReadResponse.json",
    ),
    "thread_list": (
        "thread/list",
        "stable",
        "client_request",
        "json/v2/ThreadListParams.json",
        "json/v2/ThreadListResponse.json",
    ),
    "account_usage_read": (
        "account/usage/read",
        "stable",
        "client_request",
        None,
        "json/v2/GetAccountTokenUsageResponse.json",
    ),
    "consume_reset_credit": (
        "account/rateLimitResetCredit/consume",
        "stable",
        "client_request",
        "json/v2/ConsumeAccountRateLimitResetCreditParams.json",
        "json/v2/ConsumeAccountRateLimitResetCreditResponse.json",
    ),
    "turn_steer": (
        "turn/steer",
        "stable",
        "client_request",
        "json/v2/TurnSteerParams.json",
        "json/v2/TurnSteerResponse.json",
    ),
    "thread_goal_set": (
        "thread/goal/set",
        "stable",
        "client_request",
        "json/v2/ThreadGoalSetParams.json",
        "json/v2/ThreadGoalSetResponse.json",
    ),
    "thread_compact": (
        "thread/compact/start",
        "stable",
        "client_request",
        "json/v2/ThreadCompactStartParams.json",
        "json/v2/ThreadCompactStartResponse.json",
    ),
    "thread_fork": (
        "thread/fork",
        "stable",
        "client_request",
        "json/v2/ThreadForkParams.json",
        "json/v2/ThreadForkResponse.json",
    ),
    "experimental_feature_list": (
        "experimentalFeature/list",
        "stable",
        "client_request",
        "json/v2/ExperimentalFeatureListParams.json",
        "json/v2/ExperimentalFeatureListResponse.json",
    ),
    "collaboration_mode_list": (
        "collaborationMode/list",
        "experimental",
        "client_request",
        "experimental/json/v2/CollaborationModeListParams.json",
        "experimental/json/v2/CollaborationModeListResponse.json",
    ),
    "turn_plan_updated": (
        "turn/plan/updated",
        "stable",
        "server_notification",
        "json/v2/TurnPlanUpdatedNotification.json",
        None,
    ),
    "turn_diff_updated": (
        "turn/diff/updated",
        "stable",
        "server_notification",
        "json/v2/TurnDiffUpdatedNotification.json",
        None,
    ),
    "thread_compacted": (
        "thread/compacted",
        "stable",
        "server_notification",
        "json/v2/ContextCompactedNotification.json",
        None,
    ),
    "thread_goal_updated": (
        "thread/goal/updated",
        "stable",
        "server_notification",
        "json/v2/ThreadGoalUpdatedNotification.json",
        None,
    ),
}

REQUIRED_FIELD_IDS = set(
    """
initialize.client_info
initialize.client_name
initialize.client_version
initialize.experimental_api
account.requires_openai_auth
account.type.chatgpt
account.type.api_key
account.updated_auth_mode
account.updated_plan_type
rate_limits.legacy_snapshot
rate_limits.used_percent
rate_limits.window_resets_at
rate_limits.window_duration
rate_limits.multi_bucket
rate_limits.bucket_limit_id
rate_limits.reset_credits
rate_limits.reset_credit_available_count
rate_limits.reset_credit_id
rate_limits.reset_credit_status
rate_limits.reset_credit_type
rate_limits.credits
rate_limits.credits_balance
rate_limits.credits_has_credits
rate_limits.credits_unlimited
rate_limits.spend_control
rate_limits.spend_limit
rate_limits.spend_used
rate_limits.spend_remaining_percent
rate_limits.spend_resets_at
models.data
models.id
models.model
models.default_effort
models.supported_efforts
models.service_tiers
models.service_tier_id
models.default_service_tier
thread_start.thread_id
thread_start.approval_policy
thread_start.cwd
thread_start.sandbox
thread_resume.thread_id
thread_start.service_tier
thread_resume.service_tier
turn_start.thread_id
turn_start.input
turn_start.approval_policy
turn_start.cwd
turn_start.sandbox_policy
turn_start.model
turn_start.effort
turn_start.service_tier
turn_start.client_user_message_id
turn_start.response_id
turn_start.response_status
turn_interrupt.thread_id
turn_interrupt.turn_id
review.detached_delivery
review.target
review.response_thread
notifications.thread_status_thread_id
notifications.thread_status_status
notifications.turn_id
notifications.item_id
notifications.token_usage_thread_id
notifications.token_usage_turn_id
notifications.token_usage_total
notifications.token_usage_last
server_requests.envelope_id
dynamic_tool.call_id
dynamic_tool.tool
dynamic_tool.arguments
dynamic_tool.thread_id
dynamic_tool.turn_id
thread_start.dynamic_tools
thread_start.dynamic_tool_type
thread_start.dynamic_tool_name
thread_start.dynamic_tool_input_schema
turn_start.collaboration_mode
turn_start.multi_agent_mode
""".split()
)

FIXTURE_TEST_FILES = (
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
VENDORED_ERLEXEC_SOURCE_FILES = (
    ".gitignore",
    "CHANGELOG.txt",
    "LICENSE",
    "README.md",
    "SYMPHONY_PATCH.md",
    "c_src/Makefile",
    "c_src/ei++.cpp",
    "c_src/ei++.hpp",
    "c_src/exec.cpp",
    "c_src/exec.hpp",
    "c_src/exec_impl.cpp",
    "c_src/poll_handler.hpp",
    "c_src/select_handler.hpp",
    "c_src/ttymodes.hpp",
    "hex_metadata.config",
    "include/exec.hrl",
    "rebar.config",
    "rebar.config.script",
    "rebar.lock",
    "src/edoc.css",
    "src/erlexec.app.src",
    "src/exec.erl",
    "src/exec_app.erl",
    "src/exec_util.erl",
)
ERLEXEC_PATH_ENV = "SYMPHONY_ERLEXEC_PATH"
FIXTURE_TEST_COMMAND = ("mise", "exec", "--", "mix", "test", *FIXTURE_TEST_FILES, "--seed", "0")
FIXTURE_DEPENDENCY_COMMAND = ("mise", "exec", "--", "mix", "deps.get", "--check-locked")
FIXTURE_DEPENDENCY_COMPILE_COMMAND = ("mise", "exec", "--", "mix", "deps.compile")
FIXTURE_EXPECTED_TEST_COUNT = 549
TEST_MANIFEST_ENV = "SYMPHONY_CODEX_SCHEMA_TEST_MANIFEST"
RESERVED_MANIFEST_PATTERNS = (".manifest.*",)
LF_NORMALIZED_SUFFIXES = {
    ".conf",
    ".css",
    ".ex",
    ".exs",
    ".js",
    ".json",
    ".lock",
    ".md",
    ".py",
    ".sh",
    ".toml",
    ".txt",
    ".yaml",
    ".yml",
}
LF_NORMALIZED_FILENAMES = {
    "CODEX_VERSION",
    "Dockerfile",
    "Makefile",
    "SEMANTIC-SHA256SUMS",
}


@dataclass(frozen=True)
class VendoredErlexecSourceProof:
    file_count: int
    byte_count: int
    sha256: str


class SchemaError(RuntimeError):
    """Raised when the pinned schema contract is not satisfied."""


class AmbiguousReadinessTransactionError(SchemaError):
    """Raised when recovery must preserve an independent writer and journal."""


def read_version(version_file: Path | None = None) -> str:
    version_file = version_file or VERSION_FILE
    version = read_regular_bytes(version_file).decode("utf-8").strip()
    if not version:
        raise SchemaError("CODEX_VERSION is empty")
    return version


def decode_json_bytes(payload: bytes, path: Path) -> Any:
    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate object key {key!r}")
            result[key] = value
        return result

    def reject_non_finite_constant(value: str) -> Any:
        raise ValueError(f"non-finite number {value!r}")

    try:
        return json.loads(
            payload.decode("utf-8"),
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_non_finite_constant,
        )
    except (OSError, json.JSONDecodeError, ValueError) as error:
        raise SchemaError(f"cannot read JSON {path}: {error}") from error


def read_json(path: Path) -> Any:
    return decode_json_bytes(read_regular_bytes(path), path)


def canonical_json_value_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def canonical_json_bytes(path: Path) -> bytes:
    return canonical_json_value_bytes(read_json(path))


def matrix_canonical_sha256(matrix: dict[str, Any]) -> str:
    return sha256_bytes(canonical_json_value_bytes(matrix))


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(read_regular_bytes(path))


def validate_iso_date(value: str) -> str:
    try:
        parsed = date.fromisoformat(value)
    except (TypeError, ValueError) as error:
        raise SchemaError(f"invalid ISO test date: {value!r}") from error
    normalized = parsed.isoformat()
    if normalized != value:
        raise SchemaError(f"test date must use YYYY-MM-DD: {value!r}")
    return normalized


Identity = tuple[int, int, int, int, int, int, int, int]


def metadata_identity(metadata: os.stat_result) -> Identity:
    """Return an identity that changes for content, mode, owner, or link mutations."""

    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_nlink,
    )


def secure_directory_flags() -> int:
    required = ("O_CLOEXEC", "O_DIRECTORY", "O_NOFOLLOW")
    missing = [name for name in required if not hasattr(os, name)]
    if (
        missing
        or os.open not in os.supports_dir_fd
        or os.stat not in os.supports_dir_fd
        or os.stat not in os.supports_follow_symlinks
        or os.listdir not in os.supports_fd
    ):
        raise SchemaError(
            f"platform lacks required no-follow directory primitives: {missing}"
        )
    return os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW


def secure_file_flags() -> int:
    secure_directory_flags()
    return os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW


def lexical_absolute(path: Path) -> Path:
    return Path(os.path.abspath(os.fspath(path)))


def stable_directory_link_identity(metadata: os.stat_result) -> tuple[int, int, int]:
    return metadata.st_dev, metadata.st_ino, metadata.st_uid


@contextmanager
def anchored_descriptor(path: Path, *, directory: bool):
    """Open every path component through retained no-follow directory FDs."""

    absolute = lexical_absolute(path)
    parts = absolute.parts[1:]
    if not parts and not directory:
        raise SchemaError(f"schema input is not a regular file: {path}")

    descriptors: list[int] = []
    links: list[tuple[int, str, Identity, bool]] = []
    try:
        current = os.open("/", secure_directory_flags())
        descriptors.append(current)
        for index, part in enumerate(parts):
            final = index == len(parts) - 1
            flags = secure_directory_flags() if (directory or not final) else secure_file_flags()
            before = os.stat(part, dir_fd=current, follow_symlinks=False)
            if stat.S_ISLNK(before.st_mode):
                raise SchemaError(f"refusing symbolic link in schema path: {path}")
            child = os.open(part, flags, dir_fd=current)
            after = os.fstat(child)
            expected_kind = stat.S_ISDIR if (directory or not final) else stat.S_ISREG
            if not expected_kind(after.st_mode):
                expected_label = "directory" if (directory or not final) else "regular file"
                raise SchemaError(f"schema input is not a {expected_label}: {path}")
            same_entry = (
                stable_directory_link_identity(after)
                == stable_directory_link_identity(before)
                if (directory or not final)
                else metadata_identity(after) == metadata_identity(before)
            )
            if not same_entry:
                raise SchemaError(f"schema path component changed while opening: {path}")
            stable_link = directory or not final
            links.append((current, part, metadata_identity(after), stable_link))
            descriptors.append(child)
            current = child

        yield current

        for parent, name, expected, stable_link in links:
            observed = os.stat(name, dir_fd=parent, follow_symlinks=False)
            unchanged = (
                stable_directory_link_identity(observed)
                == (expected[0], expected[1], expected[6])
                if stable_link
                else metadata_identity(observed) == expected
            )
            if not unchanged:
                raise SchemaError(f"schema path component changed during operation: {path}")
    except OSError as error:
        if error.errno == errno.ELOOP:
            raise SchemaError(f"refusing symbolic link in schema path: {path}") from error
        raise SchemaError(f"cannot securely open schema path {path}: {error}") from error
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


@contextmanager
def anchored_parent(path: Path):
    absolute = lexical_absolute(path)
    if absolute == Path("/"):
        raise SchemaError("filesystem root has no parent entry")
    with anchored_descriptor(absolute.parent, directory=True) as parent:
        yield parent, absolute.name


def mkdir_parents_no_follow(path: Path, *, mode: int = 0o755) -> None:
    absolute = lexical_absolute(path)
    descriptors: list[int] = []
    try:
        current = os.open("/", secure_directory_flags())
        descriptors.append(current)
        for part in absolute.parts[1:]:
            try:
                child = os.open(part, secure_directory_flags(), dir_fd=current)
            except FileNotFoundError:
                os.mkdir(part, mode, dir_fd=current)
                child = os.open(part, secure_directory_flags(), dir_fd=current)
            metadata = os.fstat(child)
            if not stat.S_ISDIR(metadata.st_mode):
                raise SchemaError(f"schema directory path is not a directory: {path}")
            descriptors.append(child)
            current = child
    except OSError as error:
        if error.errno == errno.ELOOP:
            raise SchemaError(f"refusing symbolic link in schema directory path: {path}") from error
        raise SchemaError(f"cannot create schema directory path {path}: {error}") from error
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def read_optional_regular_bytes(path: Path) -> bytes | None:
    with anchored_parent(path) as (parent, name):
        try:
            metadata = os.stat(name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            return None
        if stat.S_ISLNK(metadata.st_mode):
            raise SchemaError(f"refusing symbolic link for schema input: {path}")
        if not stat.S_ISREG(metadata.st_mode):
            raise SchemaError(f"schema input is not a regular file: {path}")
    return read_regular_bytes(path)


def path_kind_no_follow(path: Path) -> str | None:
    with anchored_parent(path) as (parent, name):
        try:
            metadata = os.stat(name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            return None
        if stat.S_ISLNK(metadata.st_mode):
            return "symlink"
        if stat.S_ISREG(metadata.st_mode):
            return "file"
        if stat.S_ISDIR(metadata.st_mode):
            return "directory"
        return "other"


def open_regular_descriptor_no_follow(path: Path, *, writable: bool = False) -> int:
    with anchored_parent(path) as (parent, name):
        before = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
            raise SchemaError(f"schema lock input is not a regular file: {path}")
        flags = (os.O_RDWR if writable else os.O_RDONLY) | os.O_CLOEXEC | os.O_NOFOLLOW
        descriptor = os.open(name, flags, dir_fd=parent)
        after = os.fstat(descriptor)
        if metadata_identity(before) != metadata_identity(after):
            os.close(descriptor)
            raise SchemaError(f"schema lock input changed while opening: {path}")
        return descriptor


def secure_replace(source: Path, destination: Path) -> None:
    with anchored_parent(source) as (source_parent, source_name):
        with anchored_parent(destination) as (destination_parent, destination_name):
            os.replace(
                source_name,
                destination_name,
                src_dir_fd=source_parent,
                dst_dir_fd=destination_parent,
            )


def secure_rename(source: Path, destination: Path) -> None:
    with anchored_parent(source) as (source_parent, source_name):
        with anchored_parent(destination) as (destination_parent, destination_name):
            os.rename(
                source_name,
                destination_name,
                src_dir_fd=source_parent,
                dst_dir_fd=destination_parent,
            )


def secure_rename_noreplace(source: Path, destination: Path) -> None:
    """Rename a regular transaction entry only if the destination is absent."""

    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = getattr(libc, "renameat2", None)
    if renameat2 is None:
        raise SchemaError("platform lacks renameat2 required for transaction fencing")
    renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    renameat2.restype = ctypes.c_int
    with anchored_parent(source) as (source_parent, source_name):
        with anchored_parent(destination) as (destination_parent, destination_name):
            result = renameat2(
                source_parent,
                os.fsencode(source_name),
                destination_parent,
                os.fsencode(destination_name),
                1,  # RENAME_NOREPLACE
            )
            if result != 0:
                error = ctypes.get_errno()
                raise SchemaError(
                    f"cannot reserve transaction destination: {os.strerror(error)}"
                )


def secure_exchange(source: Path, destination: Path) -> None:
    """Atomically exchange two entries so a displaced writer is recoverable."""

    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = getattr(libc, "renameat2", None)
    if renameat2 is None:
        raise SchemaError("platform lacks renameat2 required for manifest publication fencing")
    renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    renameat2.restype = ctypes.c_int
    with anchored_parent(source) as (source_parent, source_name):
        with anchored_parent(destination) as (destination_parent, destination_name):
            result = renameat2(
                source_parent,
                os.fsencode(source_name),
                destination_parent,
                os.fsencode(destination_name),
                2,  # RENAME_EXCHANGE
            )
            if result != 0:
                error = ctypes.get_errno()
                raise SchemaError(
                    f"cannot atomically exchange schema metadata: {os.strerror(error)}"
                )


def rename_stable_file_identity(identity: Identity) -> tuple[int, int, int, int, int, int, int]:
    # Linux updates ctime when a name is exchanged. Every other identity field
    # and the separately checked content digest must remain exact.
    return (
        identity[0],
        identity[1],
        identity[2],
        identity[3],
        identity[5],
        identity[6],
        identity[7],
    )


def regular_file_identity(path: Path) -> Identity:
    with anchored_descriptor(path, directory=False) as descriptor:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise SchemaError(f"schema input is not a regular file: {path}")
        return metadata_identity(metadata)


def regular_file_mode(path: Path) -> int:
    with anchored_descriptor(path, directory=False) as descriptor:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise SchemaError(f"schema input is not a regular file: {path}")
        return stat.S_IMODE(metadata.st_mode)


def directory_identity(path: Path) -> Identity:
    with anchored_descriptor(path, directory=True) as descriptor:
        metadata = os.fstat(descriptor)
        if not stat.S_ISDIR(metadata.st_mode):
            raise SchemaError(f"schema input is not a directory: {path}")
        return metadata_identity(metadata)


def assert_directory_unchanged(path: Path, identity: Identity) -> None:
    if directory_identity(path) != identity:
        raise SchemaError(f"schema bundle directory changed during operation: {path}")


def assert_directory_same_object(path: Path, identity: Identity) -> None:
    if directory_identity(path)[:2] != identity[:2]:
        raise SchemaError(f"schema bundle directory was replaced during operation: {path}")


def directory_fingerprint(descriptor: int) -> tuple[tuple[str, Identity], ...]:
    entries: list[tuple[str, Identity]] = []
    for name in sorted(os.listdir(descriptor)):
        metadata = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if stat.S_ISLNK(metadata.st_mode):
            raise SchemaError(f"refusing symbolic link in schema input tree: {name}")
        entries.append((name, metadata_identity(metadata)))
    return tuple(entries)


def regular_tree_files(root: Path) -> tuple[Path, ...]:
    files: list[Path] = []

    def visit(directory: Path) -> None:
        with anchored_descriptor(directory, directory=True) as descriptor:
            start_identity = metadata_identity(os.fstat(descriptor))
            before = directory_fingerprint(descriptor)
            for name, entry_identity in before:
                path = directory / name
                mode = entry_identity[5]
                if stat.S_ISDIR(mode):
                    visit(path)
                elif stat.S_ISREG(mode):
                    files.append(path)
                else:
                    raise SchemaError(
                        f"schema input tree contains a non-regular entry: {path}"
                    )
            if directory_fingerprint(descriptor) != before:
                raise SchemaError(f"schema input directory changed during traversal: {directory}")
            if metadata_identity(os.fstat(descriptor)) != start_identity:
                raise SchemaError(f"schema input directory changed during traversal: {directory}")

    visit(root)
    return tuple(sorted(files))


def regular_relative_file(root: Path, relative: str) -> Path:
    relative_path = Path(relative)
    if relative_path.is_absolute() or ".." in relative_path.parts:
        raise SchemaError(f"schema input path is not safely relative: {relative}")

    directory_identity(root)
    current = root
    for part in relative_path.parts[:-1]:
        current /= part
        directory_identity(current)
    path = root / relative_path
    regular_file_identity(path)
    return path


def read_regular_bytes(path: Path) -> bytes:
    with anchored_descriptor(path, directory=False) as descriptor:
        metadata = os.fstat(descriptor)
        expected_identity = metadata_identity(metadata)
        if not stat.S_ISREG(metadata.st_mode):
            raise SchemaError(f"schema input is not a regular file: {path}")
        chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        content = b"".join(chunks)
        metadata = os.fstat(descriptor)
        if metadata_identity(metadata) != expected_identity:
            raise SchemaError(f"schema input changed while reading regular file: {path}")
        os.lseek(descriptor, 0, os.SEEK_SET)
        confirmation_chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            confirmation_chunks.append(chunk)
        if b"".join(confirmation_chunks) != content:
            raise SchemaError(f"schema input changed while reading regular file: {path}")
        metadata = os.fstat(descriptor)
        if metadata_identity(metadata) != expected_identity:
            raise SchemaError(f"schema input changed while reading regular file: {path}")
    return content


def fixture_source_files(
    *, repo_root: Path | None = None, version: str | None = None
) -> tuple[str, ...]:
    repo_root = repo_root or REPO_ROOT
    version = version or read_version(repo_root / "CODEX_VERSION")
    relative_files = {
        "CODEX_LOCK.json",
        "CODEX_VERSION",
        "elixir/Makefile",
        "elixir/WORKFLOW.md",
        "elixir/mise.toml",
        "elixir/mix.exs",
        "elixir/mix.lock",
        "elixir/priv/codex_schema/CODEX_VERSION",
        f"elixir/priv/codex_schema/{version}/SEMANTIC-SHA256SUMS",
        "elixir/test/test_helper.exs",
        "scripts/codex_schema.py",
        "scripts/codex_schema_matrix.json",
        "scripts/run_codex_schema_tests.py",
        "scripts/studio_readiness.py",
        "scripts/test_codex_schema.py",
        "scripts/test_studio_readiness.py",
        *(f"elixir/{path}" for path in FIXTURE_TEST_FILES),
        *(f"elixir/vendor/erlexec/{path}" for path in VENDORED_ERLEXEC_SOURCE_FILES),
    }

    for root, pattern in (
        (repo_root / "elixir" / "lib", "*.ex"),
        (repo_root / "elixir" / "config", "*.exs"),
    ):
        relative_files.update(
            path.relative_to(repo_root).as_posix()
            for path in regular_tree_files(root)
            if path.match(pattern)
        )

    support_root = repo_root / "elixir" / "test" / "support"
    relative_files.update(
        path.relative_to(repo_root).as_posix() for path in regular_tree_files(support_root)
    )

    static_root = repo_root / "elixir" / "priv" / "static"
    relative_files.update(
        path.relative_to(repo_root).as_posix() for path in regular_tree_files(static_root)
    )

    hooks_root = repo_root / "elixir" / "priv" / "hooks"
    relative_files.update(
        path.relative_to(repo_root).as_posix() for path in regular_tree_files(hooks_root)
    )

    for relative in relative_files:
        regular_relative_file(repo_root, relative)
    return tuple(sorted(relative_files))


def fixture_source_summary(
    *, repo_root: Path | None = None, version: str | None = None
) -> dict[str, Any]:
    repo_root = repo_root or REPO_ROOT
    entries: list[tuple[str, str, int]] = []
    for relative in fixture_source_files(repo_root=repo_root, version=version):
        path = regular_relative_file(repo_root, relative)
        content = read_regular_bytes(path)
        if path.suffix.lower() in LF_NORMALIZED_SUFFIXES or path.name in LF_NORMALIZED_FILENAMES:
            content = content.replace(b"\r\n", b"\n")
        entries.append((relative, sha256_bytes(content), len(content)))
    return {
        "fileCount": len(entries),
        "sha256": sha256_bytes(checksum_stream(entries)),
    }


def artifact_entries(bundle: Path) -> list[tuple[str, str, int]]:
    entries: list[tuple[str, str, int]] = []

    for label, relative_root, semantic_json in ARTIFACTS:
        root = bundle / relative_root
        for path in regular_tree_files(root):
            relative = path.relative_to(root).as_posix()
            raw_content = read_regular_bytes(path)
            content = (
                canonical_json_value_bytes(decode_json_bytes(raw_content, path))
                if semantic_json
                else raw_content
            )
            entries.append((f"{label}/{relative}", sha256_bytes(content), len(raw_content)))

    return entries


def schema_semantic_entries(bundle: Path) -> list[tuple[str, str, int]]:
    """Read the complete JSON schema bundle through the semantic oracle."""

    entries: list[tuple[str, str, int]] = []
    for label, relative_root, semantic_json in ARTIFACTS:
        if not semantic_json:
            continue
        root = bundle / relative_root
        for path in regular_tree_files(root):
            relative = path.relative_to(root).as_posix()
            content = canonical_json_value_bytes(read_json(path))
            entries.append((f"{label}/{relative}", sha256_bytes(content), len(content)))
    return entries


def checksum_stream(entries: Iterable[tuple[str, str, int]]) -> bytes:
    return "".join(f"{digest}  {path}\n" for path, digest, _size in entries).encode("utf-8")


def subtree_summary(entries: list[tuple[str, str, int]], label: str) -> dict[str, Any]:
    prefix = f"{label}/"
    selected = [entry for entry in entries if entry[0].startswith(prefix)]
    relative_entries = [
        (path.removeprefix(prefix), digest, size) for path, digest, size in selected
    ]
    return {
        "byteCount": sum(size for _path, _digest, size in selected),
        "fileCount": len(selected),
        "path": label,
        "sha256": sha256_bytes(checksum_stream(relative_entries)),
    }


def find_methods(value: Any) -> set[str]:
    methods: set[str] = set()
    if isinstance(value, dict):
        properties = value.get("properties")
        if isinstance(properties, dict):
            method_schema = properties.get("method")
            if isinstance(method_schema, dict):
                enum_values = method_schema.get("enum")
                if isinstance(enum_values, list):
                    methods.update(item for item in enum_values if isinstance(item, str))
                const_value = method_schema.get("const")
                if isinstance(const_value, str):
                    methods.add(const_value)
        for nested in value.values():
            methods.update(find_methods(nested))
    elif isinstance(value, list):
        for nested in value:
            methods.update(find_methods(nested))
    return methods


def referenced_definition_names(value: Any, document: Any) -> set[str]:
    """Return exact direct local-definition targets and reject loose refs."""

    references: set[str] = set()
    if isinstance(value, dict):
        if "$ref" in value:
            reference = value["$ref"]
            if not isinstance(reference, str):
                raise SchemaError("schema $ref must be a string")
            match = re.fullmatch(r"#/definitions/([^/~]+)", reference)
            if match is None:
                raise SchemaError(
                    f"method params $ref must be an exact local definition reference: {reference!r}"
                )
            resolve_pointer(document, reference[1:])
            references.add(match.group(1))
        for nested in value.values():
            references.update(referenced_definition_names(nested, document))
    elif isinstance(value, list):
        for nested in value:
            references.update(referenced_definition_names(nested, document))
    return references


def method_contracts(
    value: Any, *, direction: str, claimed_methods: set[str]
) -> dict[str, set[str | None]]:
    """Validate and collect live top-level JSON-RPC method variants."""

    variants = value.get("oneOf") if isinstance(value, dict) else None
    if not isinstance(variants, list) or not variants:
        raise SchemaError(f"{direction} aggregate must have a non-empty root oneOf")

    is_request = direction in {"client_request", "server_request"}
    reachable = reachable_schema_pointers(value)
    contracts: dict[str, set[str | None]] = {}
    for index, nested in enumerate(variants):
        pointer = f"/oneOf/{index}"
        if pointer not in reachable:
            continue
        if not isinstance(nested, dict):
            raise SchemaError(f"{direction} aggregate variant {index} is not an object")
        properties = nested.get("properties")
        if not isinstance(properties, dict):
            raise SchemaError(f"{direction} aggregate variant {index} lacks properties")
        method_schema = properties.get("method")
        enum_values = method_schema.get("enum") if isinstance(method_schema, dict) else None
        advertised = {
            item for item in enum_values or [] if isinstance(item, str)
        } if isinstance(enum_values, list) else set()
        if not (advertised & claimed_methods):
            continue
        if not isinstance(method_schema, dict):
            raise SchemaError(f"{direction} aggregate variant {index} lacks a method schema")
        if (
            method_schema.get("type") != "string"
            or not isinstance(enum_values, list)
            or len(enum_values) != 1
            or not isinstance(enum_values[0], str)
            or not enum_values[0]
            or "const" in method_schema
        ):
            raise SchemaError(
                f"{direction} aggregate variant {index} must have one exact string method"
            )
        method = enum_values[0]
        if method in contracts:
            raise SchemaError(f"{direction} aggregate method {method!r} has multiple live variants")
        if nested.get("type") != "object":
            raise SchemaError(f"{direction} aggregate method {method!r} is not an object")
        if "additionalProperties" in nested:
            raise SchemaError(
                f"{direction} aggregate method {method!r} changes the pinned envelope policy"
            )

        params_schema = properties.get("params")
        params_required = False
        if params_schema is None:
            targets: set[str | None] = {None}
        elif params_schema == {"type": "null"}:
            targets = {None}
        elif isinstance(params_schema, dict) and set(params_schema) == {"$ref"}:
            reference = params_schema["$ref"]
            match = (
                re.fullmatch(r"#/definitions/([^/~]+)", reference)
                if isinstance(reference, str)
                else None
            )
            if match is None:
                raise SchemaError(
                    f"{direction} aggregate method {method!r} params must use one direct local ref"
                )
            resolve_pointer(value, reference[1:])
            targets = {match.group(1)}
            params_required = True
        else:
            raise SchemaError(
                f"{direction} aggregate method {method!r} has an unsupported params envelope"
            )

        expected_properties = {"method"}
        if is_request:
            expected_properties.add("id")
            if properties.get("id") != {"$ref": "#/definitions/RequestId"}:
                raise SchemaError(
                    f"{direction} aggregate method {method!r} lacks the exact request ID ref"
                )
        if params_schema is not None:
            expected_properties.add("params")
        if set(properties) != expected_properties:
            raise SchemaError(
                f"{direction} aggregate method {method!r} has unexpected envelope properties"
            )

        required = set(
            schema_required_values(
                nested.get("required", []),
                label=f"{direction} aggregate method {method}",
            )
        )
        expected_required = {"method"}
        if is_request:
            expected_required.add("id")
        if params_required:
            expected_required.add("params")
        if required != expected_required:
            raise SchemaError(
                f"{direction} aggregate method {method!r} has an invalid required envelope"
            )

        contracts[method] = targets

    return contracts


def json_pointer_component(value: str) -> str:
    return value.replace("~", "~0").replace("/", "~1")


def reachable_schema_pointers(document: Any) -> set[str]:
    """Resolve the local schema graph without treating dead definitions as live."""

    reachable: set[str] = set()

    def visit(value: Any, pointer: str) -> None:
        if pointer in reachable:
            return
        reachable.add(pointer)

        if isinstance(value, dict):
            if "$ref" in value:
                reference = value["$ref"]
                if not isinstance(reference, str) or not reference.startswith("#/"):
                    raise SchemaError(
                        f"schema $ref must be an exact local JSON pointer: {reference!r}"
                    )
                target_pointer = reference[1:]
                reachable.add(f"{pointer}/$ref")
                visit(resolve_pointer(document, target_pointer), target_pointer)
                # The pinned schemas use Draft-07, where validation siblings of
                # $ref are ignored.  Treat the node as reference-only so dead
                # sibling assertions cannot satisfy matrix reachability.
                return

            for key, nested in value.items():
                # Definitions are declarations, not roots. They become
                # reachable only when an actual schema edge references them.
                if key in {"definitions", "$defs"}:
                    continue
                child = f"{pointer}/{json_pointer_component(key)}"
                visit(nested, child)
        elif isinstance(value, list):
            for index, nested in enumerate(value):
                visit(nested, f"{pointer}/{index}")

    visit(document, "")
    return reachable


def matrix_field_probes_sha256(probes: list[dict[str, Any]]) -> str:
    return sha256_bytes(canonical_json_value_bytes(probes))


def resolve_pointer(document: Any, pointer: str) -> Any:
    if pointer == "":
        return document
    if not pointer.startswith("/"):
        raise SchemaError(f"invalid JSON pointer: {pointer}")

    current = document
    for raw_part in pointer[1:].split("/"):
        part = raw_part.replace("~1", "/").replace("~0", "~")
        try:
            if isinstance(current, list):
                current = current[int(part)]
            else:
                current = current[part]
        except (KeyError, IndexError, TypeError, ValueError) as error:
            raise SchemaError(f"JSON pointer not found: {pointer}") from error
    return current


def matrix_entry_ids(section: str, entries: Any) -> list[str]:
    if not isinstance(entries, list):
        raise SchemaError(f"matrix {section} must be an array")

    identifiers: list[str] = []
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise SchemaError(f"matrix {section}[{index}] must be an object")
        identifier = entry.get("id")
        if not isinstance(identifier, str) or not identifier or identifier.strip() != identifier:
            raise SchemaError(f"matrix {section}[{index}] ID must be a non-empty string")
        identifiers.append(identifier)

    if len(set(identifiers)) != len(identifiers):
        raise SchemaError(f"matrix {section} IDs must be unique")
    return identifiers


def validate_matrix_entry_policy(entry: dict[str, Any], kind: str) -> None:
    identifier = entry.get("id")
    requirement = entry.get("requirement")
    absent_behavior = entry.get("absentBehavior")
    assertion = entry.get("r002Assertion")

    if requirement not in METHOD_REQUIREMENTS:
        raise SchemaError(f"invalid {kind} requirement for {identifier}")
    if absent_behavior not in ABSENT_BEHAVIORS:
        raise SchemaError(f"invalid {kind} absentBehavior for {identifier}")
    if requirement == "required" and absent_behavior != "block_managed_dispatch":
        raise SchemaError(
            f"required matrix {kind} {identifier} must fail closed with block_managed_dispatch"
        )
    if assertion not in R002_ASSERTIONS:
        raise SchemaError(f"invalid {kind} r002Assertion for {identifier}")
    if entry.get("r006Probe") not in R006_PROBES:
        raise SchemaError(f"invalid {kind} r006Probe for {identifier}")
    if assertion == "present_but_deprecated_ignored":
        description = entry.get("descriptionContains")
        if not isinstance(description, str) or not description:
            raise SchemaError(
                f"deprecated-ignored matrix {kind} {identifier} must bind its schema description"
            )
        if entry.get("r006Probe") != "conformance":
            raise SchemaError(
                f"deprecated-ignored matrix {kind} {identifier} requires a conformance probe"
            )


def matrix_schema_path(
    bundle: Path,
    relative: Any,
    *,
    label: str,
    channel: str | None = None,
) -> Path:
    if not isinstance(relative, str) or not relative or relative.strip() != relative:
        raise SchemaError(f"matrix {label} must be a non-empty relative schema path")
    if "\\" in relative:
        raise SchemaError(f"matrix {label} must use POSIX schema separators: {relative!r}")

    relative_path = Path(relative)
    if (
        relative_path.is_absolute()
        or relative_path.as_posix() != relative
        or any(part in {"", ".", ".."} for part in relative_path.parts)
        or relative_path.suffix != ".json"
    ):
        raise SchemaError(f"matrix {label} is not a safe generated JSON path: {relative!r}")

    if channel is not None:
        expected_tree = "experimental/json/" if channel == "experimental" else "json/"
        if not relative.startswith(expected_tree):
            raise SchemaError(f"matrix {label} channel mismatch: {relative}")
    elif not relative.startswith(("json/", "experimental/json/")):
        raise SchemaError(f"matrix {label} is outside the generated JSON trees: {relative}")

    path = bundle / relative_path
    regular_file_identity(path)
    return path


def direct_property_pointer(pointer: str) -> tuple[str, str] | None:
    parts = pointer.rsplit("/properties/", 1)
    if len(parts) != 2 or not parts[1] or "/" in parts[1]:
        return None
    property_name = parts[1].replace("~1", "/").replace("~0", "~")
    return parts[0], property_name


def scalar_enum_values(
    value: Any, *, require_complete_one_of: bool = False
) -> list[Any]:
    def visit(candidate: Any) -> list[Any]:
        if not isinstance(candidate, dict):
            return []

        values: list[Any] = []
        enum_values = candidate.get("enum")
        if enum_values is not None:
            if not isinstance(enum_values, list):
                raise SchemaError("schema enum must be an array")
            if require_complete_one_of and not enum_values:
                raise SchemaError("schema enum must contain a non-empty scalar enum")
            for enum_value in enum_values:
                if isinstance(enum_value, (dict, list)):
                    raise SchemaError("matrix enum assertions require scalar schema enum values")
                values.append(enum_value)
        one_of = candidate.get("oneOf")
        if one_of is not None:
            if not isinstance(one_of, list):
                raise SchemaError("schema oneOf must be an array")
            for index, variant in enumerate(one_of):
                variant_values = visit(variant)
                if require_complete_one_of and not variant_values:
                    raise SchemaError(
                        f"schema oneOf variant {index} must contain a non-empty scalar enum"
                    )
                values.extend(variant_values)

        return values

    return visit(value)


def matrix_field_enum_values(
    value: Any,
    variant_property: Any,
    *,
    require_complete_one_of: bool = False,
) -> list[Any]:
    if not isinstance(value, list) or not isinstance(variant_property, str):
        return scalar_enum_values(
            value, require_complete_one_of=require_complete_one_of
        )

    values: list[Any] = []
    for index, variant in enumerate(value):
        properties = variant.get("properties") if isinstance(variant, dict) else None
        property_schema = properties.get(variant_property) if isinstance(properties, dict) else None
        variant_values = scalar_enum_values(
            property_schema, require_complete_one_of=require_complete_one_of
        )
        if require_complete_one_of and not variant_values:
            raise SchemaError(
                f"schema variant {index} property {variant_property!r} must contain "
                "a non-empty scalar enum"
            )
        values.extend(variant_values)
    return values


def schema_required_values(value: Any, *, label: str) -> list[str]:
    error = f"schema required must be a list of unique non-empty strings for {label}"
    if not isinstance(value, list):
        raise SchemaError(error)
    if any(not isinstance(item, str) or not item for item in value):
        raise SchemaError(error)
    if len(set(value)) != len(value):
        raise SchemaError(error)
    return value


def recursive_named_values(value: Any, name: str) -> list[str]:
    matches: list[str] = []
    if isinstance(value, dict):
        candidate = value.get(name)
        if isinstance(candidate, str):
            matches.append(candidate)
        for nested in value.values():
            matches.extend(recursive_named_values(nested, name))
    elif isinstance(value, list):
        for nested in value:
            matches.extend(recursive_named_values(nested, name))
    return matches


def recursive_definition_names(value: Any) -> set[str]:
    names: set[str] = set()
    if isinstance(value, dict):
        for key in ("definitions", "$defs"):
            definitions = value.get(key)
            if isinstance(definitions, dict):
                names.update(name for name in definitions if isinstance(name, str))
        for nested in value.values():
            names.update(recursive_definition_names(nested))
    elif isinstance(value, list):
        for nested in value:
            names.update(recursive_definition_names(nested))
    return names


def recursive_property_names(value: Any) -> set[str]:
    names: set[str] = set()
    if isinstance(value, dict):
        properties = value.get("properties")
        if isinstance(properties, dict):
            names.update(name for name in properties if isinstance(name, str))
        for nested in value.values():
            names.update(recursive_property_names(nested))
    elif isinstance(value, list):
        for nested in value:
            names.update(recursive_property_names(nested))
    return names


def compile_matrix_regex(identifier: str, selector: str, pattern: Any) -> re.Pattern[str]:
    if not isinstance(pattern, str) or not pattern:
        raise SchemaError(f"negative capability {identifier} {selector} must be a non-empty regex")
    try:
        return re.compile(pattern)
    except re.error as error:
        raise SchemaError(
            f"negative capability {identifier} has invalid {selector}: {error}"
        ) from error


def validate_definition_equalities(bundle: Path, entries: list[dict[str, Any]]) -> None:
    expected_keys = {"id", "leftPointer", "leftSchema", "rightPointer", "rightSchema"}
    for entry in entries:
        identifier = entry["id"]
        if set(entry) != expected_keys:
            raise SchemaError(f"definition equality {identifier} has unexpected or missing keys")

        left_path = matrix_schema_path(
            bundle, entry.get("leftSchema"), label=f"definition equality {identifier} leftSchema"
        )
        right_path = matrix_schema_path(
            bundle, entry.get("rightSchema"), label=f"definition equality {identifier} rightSchema"
        )
        left_pointer = entry.get("leftPointer")
        right_pointer = entry.get("rightPointer")
        if not isinstance(left_pointer, str) or not isinstance(right_pointer, str):
            raise SchemaError(f"definition equality {identifier} pointers must be strings")

        left = resolve_pointer(read_json(left_path), left_pointer)
        right = resolve_pointer(read_json(right_path), right_pointer)
        if left != right:
            raise SchemaError(f"definition equality {identifier} does not match")


def validate_negative_capabilities(bundle: Path, entries: list[dict[str, Any]]) -> None:
    selector_keys = {
        "forbiddenDefinition",
        "forbiddenFileNamePattern",
        "forbiddenPropertyNamePattern",
        "forbiddenReferencePattern",
        "forbiddenSchemaTitle",
    }
    common_keys = {"expect", "id", "schemaGlobs"}
    document_cache: dict[Path, Any] = {}
    roots: list[Path] = []
    if path_kind_no_follow(bundle / "json") == "directory":
        roots.append(bundle / "json")
    if path_kind_no_follow(bundle / "experimental") == "directory":
        experimental_json = bundle / "experimental" / "json"
        if path_kind_no_follow(experimental_json) == "directory":
            roots.append(experimental_json)
    available_paths = {
        path.relative_to(bundle).as_posix(): path
        for root in roots
        for path in regular_tree_files(root)
        if path.suffix == ".json"
    }

    for entry in entries:
        identifier = entry["id"]
        if not set(entry).issubset(common_keys | selector_keys) or not common_keys.issubset(
            entry
        ):
            raise SchemaError(f"negative capability {identifier} has unexpected or missing keys")
        selectors = set(entry) & selector_keys
        if not selectors:
            raise SchemaError(f"negative capability {identifier} has no forbidden selector")
        if entry.get("expect") != "absent":
            raise SchemaError(f"negative capability {identifier} expect must be absent")

        globs = entry.get("schemaGlobs")
        if (
            not isinstance(globs, list)
            or not globs
            or any(not isinstance(pattern, str) or not pattern for pattern in globs)
            or len(set(globs)) != len(globs)
        ):
            raise SchemaError(
                f"negative capability {identifier} schemaGlobs must be unique strings"
            )

        matched_paths: set[Path] = set()
        for pattern in globs:
            pattern_path = Path(pattern)
            if (
                pattern_path.is_absolute()
                or "\\" in pattern
                or any(part in {"", ".", ".."} for part in pattern_path.parts)
                or not pattern.startswith(("json/", "experimental/json/"))
                or not pattern.endswith(".json")
            ):
                raise SchemaError(
                    f"negative capability {identifier} has unsafe schema glob {pattern!r}"
                )
            zero_depth_pattern = pattern.replace("/**/", "/")
            matches = {
                path
                for relative, path in available_paths.items()
                if fnmatch.fnmatchcase(relative, pattern)
                or fnmatch.fnmatchcase(relative, zero_depth_pattern)
            }
            if not matches:
                raise SchemaError(
                    f"negative capability {identifier} schema glob matched no files: {pattern}"
                )
            matched_paths.update(matches)

        forbidden_definition = entry.get("forbiddenDefinition")
        if "forbiddenDefinition" in selectors and (
            not isinstance(forbidden_definition, str) or not forbidden_definition
        ):
            raise SchemaError(
                f"negative capability {identifier} forbiddenDefinition must be a non-empty string"
            )
        forbidden_title = entry.get("forbiddenSchemaTitle")
        if "forbiddenSchemaTitle" in selectors and (
            not isinstance(forbidden_title, str) or not forbidden_title
        ):
            raise SchemaError(
                f"negative capability {identifier} forbiddenSchemaTitle must be a non-empty string"
            )

        file_pattern = (
            compile_matrix_regex(
                identifier,
                "forbiddenFileNamePattern",
                entry["forbiddenFileNamePattern"],
            )
            if "forbiddenFileNamePattern" in selectors
            else None
        )
        property_pattern = (
            compile_matrix_regex(
                identifier,
                "forbiddenPropertyNamePattern",
                entry["forbiddenPropertyNamePattern"],
            )
            if "forbiddenPropertyNamePattern" in selectors
            else None
        )
        reference_pattern = (
            compile_matrix_regex(
                identifier,
                "forbiddenReferencePattern",
                entry["forbiddenReferencePattern"],
            )
            if "forbiddenReferencePattern" in selectors
            else None
        )

        for path in sorted(matched_paths):
            relative = path.relative_to(bundle).as_posix()
            if file_pattern is not None and (
                file_pattern.search(path.name) or file_pattern.search(relative)
            ):
                raise SchemaError(
                    f"negative capability {identifier} found forbidden file {relative}"
                )

            if path not in document_cache:
                document_cache[path] = read_json(path)
            document = document_cache[path]
            if (
                isinstance(forbidden_definition, str)
                and forbidden_definition in recursive_definition_names(document)
            ):
                raise SchemaError(
                    f"negative capability {identifier} found definition "
                    f"{forbidden_definition!r} in {relative}"
                )
            if (
                isinstance(forbidden_title, str)
                and forbidden_title in recursive_named_values(document, "title")
            ):
                raise SchemaError(
                    f"negative capability {identifier} found schema title "
                    f"{forbidden_title!r} in {relative}"
                )
            if property_pattern is not None:
                property_name = next(
                    (
                        name
                        for name in sorted(recursive_property_names(document))
                        if property_pattern.search(name)
                    ),
                    None,
                )
                if property_name is not None:
                    raise SchemaError(
                        f"negative capability {identifier} found property "
                        f"{property_name!r} in {relative}"
                    )
            if reference_pattern is not None:
                reference = next(
                    (
                        value
                        for value in recursive_named_values(document, "$ref")
                        if reference_pattern.search(value)
                    ),
                    None,
                )
                if reference is not None:
                    raise SchemaError(
                        f"negative capability {identifier} found reference "
                        f"{reference!r} in {relative}"
                    )


def validate_matrix(bundle: Path, matrix: dict[str, Any]) -> None:
    if not isinstance(matrix, dict) or set(matrix) != MATRIX_TOP_LEVEL_KEYS:
        raise SchemaError("matrix top-level keys must match the exact R0-02 contract")
    version = read_version()
    if matrix.get("matrixVersion") != 1:
        raise SchemaError("matrixVersion must be 1")
    if matrix.get("profile") != "build-week-chatgpt-reference":
        raise SchemaError("matrix profile must be build-week-chatgpt-reference")
    if matrix.get("codexVersion") != version:
        raise SchemaError("matrix codexVersion does not match CODEX_VERSION")
    if matrix.get("r002Status") != "schema_only" or matrix.get("r006Status") != "pending":
        raise SchemaError("matrix must keep R0-02 schema proof separate from R0-06 runtime proof")

    methods = matrix["methods"]
    fields = matrix["fields"]
    definition_equalities = matrix["definitionEqualities"]
    negative_capabilities = matrix["negativeCapabilities"]
    method_ids = matrix_entry_ids("methods", methods)
    field_ids = matrix_entry_ids("fields", fields)
    equality_ids = matrix_entry_ids("definitionEqualities", definition_equalities)
    negative_ids = matrix_entry_ids("negativeCapabilities", negative_capabilities)
    all_ids = method_ids + field_ids + equality_ids + negative_ids
    if len(set(all_ids)) != len(all_ids):
        raise SchemaError("matrix IDs must be unique across all sections")

    actual_method_contracts = {
        entry["id"]: (
            entry.get("method"),
            entry.get("channel"),
            entry.get("direction"),
            entry.get("paramsSchema"),
            entry.get("responseSchema"),
        )
        for entry in methods
    }
    if actual_method_contracts != EXPECTED_METHOD_CONTRACTS:
        missing = sorted(set(EXPECTED_METHOD_CONTRACTS) - set(actual_method_contracts))
        extra = sorted(set(actual_method_contracts) - set(EXPECTED_METHOD_CONTRACTS))
        mismatched = sorted(
            identifier
            for identifier in set(actual_method_contracts) & set(EXPECTED_METHOD_CONTRACTS)
            if actual_method_contracts[identifier] != EXPECTED_METHOD_CONTRACTS[identifier]
        )
        raise SchemaError(
            "matrix method contract mismatch; "
            f"missing={missing}, extra={extra}, mismatched={mismatched}"
        )

    method_cache: dict[tuple[str, str], dict[str, set[str | None]]] = {}
    claimed_methods_by_cache: dict[tuple[str, str], set[str]] = {}
    for entry in methods:
        tree = "json" if entry.get("channel") == "stable" else "experimental/json"
        claimed_methods_by_cache.setdefault((tree, entry.get("direction")), set()).add(
            entry.get("method")
        )
    for entry in methods:
        channel = entry.get("channel")
        direction = entry.get("direction")
        if channel not in {"stable", "experimental"}:
            raise SchemaError(f"invalid method channel for {entry.get('id')}")
        if direction not in DIRECTION_FILES:
            raise SchemaError(f"invalid method direction for {entry.get('id')}")
        validate_matrix_entry_policy(entry, "method")

        tree = "json" if channel == "stable" else "experimental/json"
        cache_key = (tree, direction)
        if cache_key not in method_cache:
            aggregate = matrix_schema_path(
                bundle,
                f"{tree}/{DIRECTION_FILES[direction]}",
                label=f"method {entry['id']} aggregate",
                channel=channel,
            )
            method_cache[cache_key] = method_contracts(
                read_json(aggregate),
                direction=direction,
                claimed_methods=claimed_methods_by_cache[cache_key],
            )

        method = entry.get("method")
        if method not in method_cache[cache_key]:
            raise SchemaError(
                f"matrix method {method!r} is absent from {channel} {direction} schema"
            )

        params_schema = entry.get("paramsSchema")
        expected_params = Path(params_schema).stem if isinstance(params_schema, str) else None
        if expected_params not in method_cache[cache_key][method]:
            raise SchemaError(
                f"matrix paramsSchema {params_schema!r} is not bound to method {method!r}"
            )

        for schema_key in ("paramsSchema", "responseSchema"):
            relative = entry.get(schema_key)
            if relative is None:
                continue
            path = matrix_schema_path(
                bundle,
                relative,
                label=f"method {entry['id']} {schema_key}",
                channel=channel,
            )
            title = read_json(path).get("title")
            if title != path.stem:
                raise SchemaError(f"matrix {schema_key} title mismatch: {relative} has {title!r}")

    if not REQUIRED_FIELD_IDS.issubset(field_ids):
        missing = sorted(REQUIRED_FIELD_IDS - set(field_ids))
        raise SchemaError(f"matrix field baseline is missing required IDs: {missing}")

    field_document_cache: dict[Path, tuple[Any, set[str]]] = {}
    field_probes: list[dict[str, Any]] = []
    for entry in fields:
        channel = entry.get("channel")
        if channel not in {"stable", "experimental"}:
            raise SchemaError(f"invalid field channel for {entry.get('id')}")
        validate_matrix_entry_policy(entry, "field")

        payload_path = entry.get("payloadPath")
        if (
            not isinstance(payload_path, str)
            or not payload_path
            or payload_path.strip() != payload_path
            or "," in payload_path
        ):
            raise SchemaError(f"matrix field must describe one payload path: {entry.get('id')}")

        relative = entry.get("schema")
        pointer = entry.get("schemaPointer")
        if not isinstance(pointer, str) or not pointer or pointer.strip() != pointer:
            raise SchemaError(f"matrix field schemaPointer must be non-empty: {entry.get('id')}")
        path = matrix_schema_path(
            bundle,
            relative,
            label=f"field {entry['id']} schema",
            channel=channel,
        )
        if path not in field_document_cache:
            document = read_json(path)
            field_document_cache[path] = (document, reachable_schema_pointers(document))
        document, reachable_pointers = field_document_cache[path]
        if pointer not in reachable_pointers:
            raise SchemaError(
                f"matrix field {entry.get('id')} schemaPointer is not reachable from "
                f"the schema payload root"
            )
        value = resolve_pointer(document, pointer)
        field_probes.append(
            {
                "id": entry["id"],
                "schema": relative,
                "schemaPointer": pointer,
                "value": value,
            }
        )

        variant_property = entry.get("allVariantsRequire")
        enum_values = matrix_field_enum_values(
            value,
            variant_property,
            require_complete_one_of="enumEquals" in entry,
        )
        if "enumContains" in entry:
            enum_contains = entry["enumContains"]
            if isinstance(enum_contains, (dict, list)):
                raise SchemaError(f"matrix field {entry.get('id')} enumContains must be scalar")
            if enum_contains not in enum_values:
                raise SchemaError(
                    f"matrix field {entry.get('id')} does not contain enum {enum_contains!r}"
                )

        if "enumEquals" in entry:
            expected_enum = entry["enumEquals"]
            if (
                not isinstance(expected_enum, list)
                or not expected_enum
                or any(isinstance(item, (dict, list)) for item in expected_enum)
            ):
                raise SchemaError(
                    f"matrix field {entry.get('id')} enumEquals must be scalar values"
                )
            actual_enum = enum_values
            if actual_enum != expected_enum:
                raise SchemaError(
                    f"matrix field {entry.get('id')} enum mismatch: "
                    f"expected {expected_enum!r}, got {actual_enum!r}"
                )

        if "descriptionContains" in entry:
            description_contains = entry["descriptionContains"]
            description = value.get("description") if isinstance(value, dict) else None
            if (
                not isinstance(description_contains, str)
                or not description_contains
                or not isinstance(description, str)
                or description_contains not in description
            ):
                raise SchemaError(
                    f"matrix field {entry.get('id')} schema description does not contain "
                    f"{description_contains!r}"
                )

        direct_property = direct_property_pointer(pointer)
        if direct_property is not None:
            if not isinstance(entry.get("schemaRequired"), bool):
                raise SchemaError(
                    f"direct matrix field {entry.get('id')} must declare boolean schemaRequired"
                )
            parent_pointer, property_name = direct_property
            parent = resolve_pointer(document, parent_pointer)
            required = schema_required_values(
                parent.get("required", []) if isinstance(parent, dict) else [],
                label=entry.get("id"),
            )
            actual = property_name in required
            if actual != entry["schemaRequired"]:
                raise SchemaError(
                    f"matrix schemaRequired mismatch for {entry.get('id')}: "
                    f"expected {entry['schemaRequired']}"
                )
        elif "schemaRequired" in entry:
            raise SchemaError(f"schemaRequired needs a direct property pointer: {entry.get('id')}")

        if "allVariantsRequire" in entry:
            if not isinstance(variant_property, str) or not variant_property:
                raise SchemaError(f"allVariantsRequire must name a property: {entry.get('id')}")
            if not isinstance(value, list) or not value:
                raise SchemaError(
                    f"allVariantsRequire pointer is not a non-empty list: {entry.get('id')}"
            )
            for index, variant in enumerate(value):
                if not isinstance(variant, dict):
                    raise SchemaError(
                        f"matrix field {entry.get('id')} variant {index} does not require "
                        f"{variant_property!r}"
                    )
                required = schema_required_values(
                    variant.get("required", []),
                    label=f"{entry.get('id')} variant {index}",
                )
                if variant_property not in required:
                    raise SchemaError(
                        f"matrix field {entry.get('id')} variant {index} does not require "
                        f"{variant_property!r}"
                    )
                properties = variant.get("properties", {})
                if variant_property not in properties:
                    raise SchemaError(
                        f"matrix field {entry.get('id')} variant {index} lacks property "
                        f"{variant_property!r}"
                    )

        if entry["id"] == "initialize.codex_home":
            if entry.get("dataHandling") != "diagnostic_redacted_only":
                raise SchemaError(
                    "initialize.codex_home must be diagnostic_redacted_only"
                )
        elif "dataHandling" in entry:
            raise SchemaError(f"unsupported matrix dataHandling for {entry.get('id')}")

    actual_field_probes_hash = matrix_field_probes_sha256(field_probes)
    if actual_field_probes_hash != EXPECTED_MATRIX_FIELD_PROBES_SHA256:
        raise SchemaError(
            "matrix field semantic SHA-256 mismatch; "
            f"expected {EXPECTED_MATRIX_FIELD_PROBES_SHA256}, "
            f"got {actual_field_probes_hash}"
        )

    validate_definition_equalities(bundle, definition_equalities)
    validate_negative_capabilities(bundle, negative_capabilities)

    semantic_entries = schema_semantic_entries(bundle)
    actual_schema_bundle_hash = sha256_bytes(checksum_stream(semantic_entries))
    if actual_schema_bundle_hash != EXPECTED_SCHEMA_BUNDLE_SHA256:
        raise SchemaError(
            "schema bundle semantic SHA-256 mismatch; "
            f"expected {EXPECTED_SCHEMA_BUNDLE_SHA256}, got {actual_schema_bundle_hash}"
        )

    actual_artifact_bundle_hash = sha256_bytes(checksum_stream(artifact_entries(bundle)))
    if actual_artifact_bundle_hash != EXPECTED_ARTIFACT_BUNDLE_SHA256:
        raise SchemaError(
            "generated artifact bundle SHA-256 mismatch; "
            f"expected {EXPECTED_ARTIFACT_BUNDLE_SHA256}, got {actual_artifact_bundle_hash}"
        )

    actual_hash = matrix_canonical_sha256(matrix)
    if actual_hash != EXPECTED_MATRIX_CANONICAL_SHA256:
        raise SchemaError(
            "matrix canonical SHA-256 mismatch; "
            f"expected {EXPECTED_MATRIX_CANONICAL_SHA256}, got {actual_hash}"
        )


def platform_lock(lock: dict[str, Any]) -> dict[str, Any]:
    operating_system = platform.system().lower()
    architecture = platform.machine().lower()
    architecture = {"amd64": "x86_64", "x64": "x86_64"}.get(architecture, architecture)

    for candidate in lock.get("platforms", []):
        if (
            candidate.get("operatingSystem") == operating_system
            and candidate.get("architecture") == architecture
        ):
            return candidate
    raise SchemaError(f"no executable pin for {operating_system}/{architecture}")


def codex_child_environment(root: Path) -> dict[str, str]:
    """Construct the exact non-secret environment allowed into pinned Codex."""

    root = lexical_absolute(root)
    mkdir_parents_no_follow(root, mode=0o700)
    home = root / "home"
    codex_home = root / "codex-home"
    cache = root / "cache"
    config = root / "config"
    state = root / "state"
    temporary = root / "tmp"
    for path in (home, codex_home, cache, config, state, temporary):
        mkdir_parents_no_follow(path, mode=0o700)
    return {
        "CODEX_HOME": str(codex_home),
        "HOME": str(home),
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "NO_COLOR": "1",
        "PATH": "/usr/local/bin:/usr/bin:/bin",
        "TERM": "dumb",
        "TMPDIR": str(temporary),
        "TZ": "UTC",
        "XDG_CACHE_HOME": str(cache),
        "XDG_CONFIG_HOME": str(config),
        "XDG_STATE_HOME": str(state),
    }


def verified_codex_identities(
    launcher: Path, native: Path, selected: dict[str, Any]
) -> tuple[Identity, str, Identity, str]:
    launcher_identity = regular_file_identity(launcher)
    launcher_digest = sha256_file(launcher)
    if launcher_digest != selected.get("launcherSha256"):
        raise SchemaError("installed Codex launcher checksum does not match CODEX_LOCK.json")
    native_identity = regular_file_identity(native)
    native_digest = sha256_file(native)
    if native_digest != selected.get("nativeSha256"):
        raise SchemaError("installed native Codex checksum does not match CODEX_LOCK.json")
    return launcher_identity, launcher_digest, native_identity, native_digest


def installed_codex(codex: str) -> tuple[Path, Path, dict[str, Any], dict[str, Any]]:
    lock = read_json(LOCK_FILE)
    selected = platform_lock(lock)
    executable_text = shutil.which(codex) if os.sep not in codex else codex
    if not executable_text:
        raise SchemaError(f"Codex executable not found: {codex}")
    launcher = Path(executable_text).resolve()
    regular_file_identity(launcher)
    if sha256_file(launcher) != selected.get("launcherSha256"):
        raise SchemaError("installed Codex launcher checksum does not match CODEX_LOCK.json")

    alias_name = str(selected["installedPackageAlias"]).split("/")[-1]
    package_root = launcher.parent.parent
    candidates = sorted(
        (package_root / "node_modules" / "@openai" / alias_name / "vendor").glob("**/codex")
    )
    native_candidates = [candidate for candidate in candidates if candidate.is_file()]
    if len(native_candidates) != 1:
        raise SchemaError(f"expected one installed native Codex payload; found {len(native_candidates)}")
    native = native_candidates[0]
    launcher_identity, launcher_digest, native_identity, native_digest = verified_codex_identities(
        launcher, native, selected
    )

    with tempfile.TemporaryDirectory(prefix="symphony-codex-version-") as temporary:
        environment = codex_child_environment(Path(temporary) / "environment")
        result = run_bounded_process(
            [str(launcher), "--version"],
            cwd=Path(environment["HOME"]),
            env=environment,
            deadline_seconds=CODEX_CHILD_DEADLINE_SECONDS,
            max_output_bytes=MAX_CHILD_OUTPUT_BYTES,
        )
    assert_file_unchanged(launcher, launcher_identity, launcher_digest)
    assert_file_unchanged(native, native_identity, native_digest)
    if result.failure_reason is not None or result.returncode != 0:
        raise_process_failure(
            "installed Codex version probe",
            result,
            result.failure_reason or f"exit={result.returncode}",
        )
    if result.stdout.strip() != lock.get("versionOutput"):
        raise SchemaError(
            f"installed Codex version is {result.stdout.strip()!r}; expected {lock.get('versionOutput')!r}"
        )
    return launcher, native, lock, selected


def run_generators(
    codex: Path, native: Path, destination: Path, selected: dict[str, Any]
) -> None:
    environment = codex_child_environment(destination.parent / "generator-environment")

    commands = (
        ("generate-json-schema", destination / "json", False),
        ("generate-ts", destination / "typescript", False),
        ("generate-json-schema", destination / "experimental" / "json", True),
        ("generate-ts", destination / "experimental" / "typescript", True),
    )
    for generator, output, experimental in commands:
        output.parent.mkdir(parents=True, exist_ok=True)
        argv = [str(codex), "app-server", generator, "--out", str(output)]
        if experimental:
            argv.append("--experimental")
        launcher_identity, launcher_digest, native_identity, native_digest = (
            verified_codex_identities(codex, native, selected)
        )
        result = run_bounded_process(
            argv,
            cwd=Path(environment["HOME"]),
            env=environment,
            deadline_seconds=CODEX_CHILD_DEADLINE_SECONDS,
            max_output_bytes=MAX_CHILD_OUTPUT_BYTES,
        )
        assert_file_unchanged(codex, launcher_identity, launcher_digest)
        assert_file_unchanged(native, native_identity, native_digest)
        if result.failure_reason is not None or result.returncode != 0:
            raise_process_failure(
                f"Codex {generator}",
                result,
                result.failure_reason or f"exit={result.returncode}",
            )


def preserve_equal_generated_json(existing: Path, generated: Path) -> None:
    if path_kind_no_follow(existing) is None:
        return
    if path_kind_no_follow(existing) != "directory":
        raise SchemaError(f"existing schema bundle is not a directory: {existing}")
    for relative_root in ("json", "experimental/json"):
        old_root = existing / relative_root
        new_root = generated / relative_root
        if path_kind_no_follow(old_root) is None:
            continue
        directory_identity(old_root)
        for new_path in regular_tree_files(new_root):
            if new_path.suffix != ".json":
                continue
            old_path = old_root / new_path.relative_to(new_root)
            if path_kind_no_follow(old_path) is not None:
                regular_relative_file(old_root, old_path.relative_to(old_root).as_posix())
                if canonical_json_bytes(old_path) == canonical_json_bytes(new_path):
                    payload = read_regular_bytes(old_path)
                    write_bytes_fsync(new_path, payload, create=False)


def build_manifest(
    bundle: Path,
    entries: list[tuple[str, str, int]],
    lock: dict[str, Any],
    selected: dict[str, Any],
    tested_at: str,
) -> dict[str, Any]:
    tested_at = validate_iso_date(tested_at)
    matrix_path = bundle / "method-field-matrix.json"
    json_entries = [entry for entry in entries if entry[0].startswith(("json/", "experimental/json/"))]
    all_stream = checksum_stream(entries)
    return {
        "manifestVersion": 1,
        "codex": {
            "package": lock["package"],
            "version": lock["version"],
            "versionOutput": lock["versionOutput"],
            "npmIntegrity": lock["npmIntegrity"],
            "executable": {
                "target": selected["target"],
                "installedPackageAlias": selected["installedPackageAlias"],
                "platformPackage": f"{selected['publishedPackage']}@{selected['publishedVersion']}",
                "platformNpmIntegrity": selected["npmIntegrity"],
                "launcherSha256": selected["launcherSha256"],
                "nativeSha256": selected["nativeSha256"],
            },
        },
        "generation": {
            "cleanCodexHome": True,
            "commands": [
                ["codex", "app-server", "generate-json-schema", "--out", "<bundle>/json"],
                ["codex", "app-server", "generate-ts", "--out", "<bundle>/typescript"],
                [
                    "codex",
                    "app-server",
                    "generate-json-schema",
                    "--out",
                    "<bundle>/experimental/json",
                    "--experimental",
                ],
                [
                    "codex",
                    "app-server",
                    "generate-ts",
                    "--out",
                    "<bundle>/experimental/typescript",
                    "--experimental",
                ],
            ],
            "generatedAt": tested_at,
            "jsonHashAlgorithm": "python-json-sort-keys-utf8-relative-path-v1",
            "typescriptHashAlgorithm": "sha256-raw-relative-path-v1",
        },
        "artifacts": {
            "json": subtree_summary(entries, "json"),
            "typescript": subtree_summary(entries, "typescript"),
            "experimentalJson": subtree_summary(entries, "experimental/json"),
            "experimentalTypescript": subtree_summary(entries, "experimental/typescript"),
            "schemaBundleSha256": sha256_bytes(checksum_stream(json_entries)),
            "artifactBundleSha256": sha256_bytes(all_stream),
        },
        "matrix": {
            "path": "method-field-matrix.json",
            "profile": "build-week-chatgpt-reference",
            "sha256": sha256_file(matrix_path),
        },
        "compatibility": {
            "schemaContract": "pass",
            "fixtures": "not_run",
            "transportConformance": "not_run",
            "runtimeCapabilities": "not_run",
            "overall": "pending_r0_06",
            "testedAt": tested_at,
        },
    }


def sealed_fixture_evidence(tested_at: str, manifest: dict[str, Any]) -> dict[str, Any]:
    return sealed_fixture_evidence_for_repo(tested_at, manifest, REPO_ROOT)


def sealed_fixture_evidence_for_repo(
    tested_at: str, manifest: dict[str, Any], repo_root: Path
) -> dict[str, Any]:
    tested_at = validate_iso_date(tested_at)
    source = fixture_source_summary(repo_root=repo_root)
    codex_version = manifest.get("codex", {}).get("version")
    if codex_version != read_version(repo_root / "CODEX_VERSION"):
        raise SchemaError("fixture evidence Codex version does not match CODEX_VERSION")

    hashes = {
        "artifactBundleSha256": manifest.get("artifacts", {}).get("artifactBundleSha256"),
        "matrixSha256": manifest.get("matrix", {}).get("sha256"),
        "schemaBundleSha256": manifest.get("artifacts", {}).get("schemaBundleSha256"),
    }
    for label, value in hashes.items():
        if (
            not isinstance(value, str)
            or len(value) != 64
            or any(character not in "0123456789abcdef" for character in value)
        ):
            raise SchemaError(f"fixture evidence {label} is not a lowercase SHA-256")

    return {
        "artifactBundleSha256": hashes["artifactBundleSha256"],
        "codexVersion": codex_version,
        "command": list(FIXTURE_TEST_COMMAND),
        "dependencyCommand": list(FIXTURE_DEPENDENCY_COMMAND),
        "dependencyCompileCommand": list(FIXTURE_DEPENDENCY_COMPILE_COMMAND),
        "matrixSha256": hashes["matrixSha256"],
        "schemaBundleSha256": hashes["schemaBundleSha256"],
        "sourceFileCount": source["fileCount"],
        "sourceHashAlgorithm": "sha256-text-lf-binary-raw-relative-path-v2",
        "sourceSha256": source["sha256"],
        "testCount": FIXTURE_EXPECTED_TEST_COUNT,
        "testedAt": tested_at,
    }


def validate_compatibility(
    manifest: dict[str, Any],
    *,
    require_fixture_seal: bool,
    allow_fixture_candidate: bool = False,
    allow_legacy_fixture_only_seal_source: bool = False,
    repo_root: Path | None = None,
) -> None:
    repo_root = repo_root or REPO_ROOT
    compatibility = manifest.get("compatibility")
    if not isinstance(compatibility, dict):
        raise SchemaError("manifest compatibility record is missing")

    generated_at = validate_iso_date(str(manifest.get("generation", {}).get("generatedAt", "")))
    tested_at = validate_iso_date(str(compatibility.get("testedAt", "")))
    if date.fromisoformat(tested_at) < date.fromisoformat(generated_at):
        raise SchemaError("manifest compatibility date cannot precede schema generation")

    runtime_status = compatibility.get("runtimeCapabilities")
    expected_overall = RUNTIME_STATUS_PAIRS.get(runtime_status)
    if expected_overall is None:
        raise SchemaError(
            "manifest compatibility runtimeCapabilities must be 'not_run', 'blocked', or 'pass'"
        )

    expected_static = {
        "schemaContract": "pass",
        "runtimeCapabilities": runtime_status,
        "overall": expected_overall,
        "testedAt": tested_at,
    }
    for key, expected in expected_static.items():
        if compatibility.get(key) != expected:
            raise SchemaError(f"manifest compatibility {key} must be {expected!r}")

    fixture_status = compatibility.get("fixtures")
    expected_transport_status = {
        "not_run": "not_run",
        "under_test": "under_test",
        "pass": "pass",
    }.get(fixture_status)
    transport_status = compatibility.get("transportConformance")
    legacy_fixture_only_seal_source = (
        allow_legacy_fixture_only_seal_source
        and not require_fixture_seal
        and not allow_fixture_candidate
        and fixture_status == "pass"
        and transport_status == "not_run"
    )
    if transport_status != expected_transport_status and not legacy_fixture_only_seal_source:
        raise SchemaError(
            "manifest transportConformance must match the fixture verification state"
        )

    if fixture_status == "pass":
        if (
            require_fixture_seal
            and compatibility.get("fixtureEvidence")
            != sealed_fixture_evidence_for_repo(tested_at, manifest, repo_root)
        ):
            raise SchemaError("manifest fixture evidence does not match current fixture sources")
        expected_keys = set(expected_static) | {
            "fixtures",
            "fixtureEvidence",
            "transportConformance",
        }
    elif fixture_status == "under_test" and allow_fixture_candidate:
        if compatibility.get("fixtureEvidence") != sealed_fixture_evidence_for_repo(
            tested_at, manifest, repo_root
        ):
            raise SchemaError("test manifest fixture evidence does not match current fixture sources")
        expected_keys = set(expected_static) | {
            "fixtures",
            "fixtureEvidence",
            "transportConformance",
        }
    elif fixture_status == "not_run" and not require_fixture_seal:
        if "fixtureEvidence" in compatibility:
            raise SchemaError("unsealed manifest must not contain fixture evidence")
        expected_keys = set(expected_static) | {"fixtures", "transportConformance"}
    else:
        raise SchemaError("manifest fixture evidence is not sealed")

    runtime_evidence = compatibility.get("runtimeEvidence")
    if runtime_status == "not_run":
        if "runtimeEvidence" in compatibility:
            raise SchemaError("not-run runtime compatibility must not contain runtime evidence")
    else:
        if fixture_status != "pass" or transport_status != "pass":
            raise SchemaError("paired runtime compatibility requires sealed fixture evidence")
        if not isinstance(runtime_evidence, dict):
            raise SchemaError("paired runtime compatibility requires runtime evidence")
        if set(runtime_evidence) != RUNTIME_EVIDENCE_KEYS:
            raise SchemaError("manifest runtime evidence has unexpected or missing keys")
        if runtime_evidence.get("hashAlgorithm") != RUNTIME_EVIDENCE_HASH_ALGORITHM:
            raise SchemaError("manifest runtime evidence hash algorithm is unsupported")
        for key in (
            "readinessManifestSha256",
            "schemaManifestBasisSha256",
            "sourceSha256",
        ):
            value = runtime_evidence.get(key)
            if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
                raise SchemaError(f"manifest runtime evidence {key} is not a lowercase SHA-256")
        expected_keys.add("runtimeEvidence")

    if set(compatibility) != expected_keys:
        raise SchemaError("manifest compatibility record has unexpected or missing keys")


def build_sealed_manifest(manifest: dict[str, Any], tested_at: str) -> dict[str, Any]:
    candidate = copy.deepcopy(manifest)
    generated_at = validate_iso_date(str(candidate.get("generation", {}).get("generatedAt", "")))
    tested_at = validate_iso_date(tested_at)
    if date.fromisoformat(tested_at) < date.fromisoformat(generated_at):
        raise SchemaError("fixture test date cannot precede schema generation")

    compatibility = candidate["compatibility"]
    compatibility["fixtures"] = "pass"
    compatibility["transportConformance"] = "pass"
    compatibility["fixtureEvidence"] = sealed_fixture_evidence(tested_at, candidate)
    compatibility["testedAt"] = tested_at
    return candidate


def build_test_manifest(manifest: dict[str, Any], tested_at: str) -> dict[str, Any]:
    candidate = build_sealed_manifest(manifest, tested_at)
    candidate["compatibility"]["fixtures"] = "under_test"
    candidate["compatibility"]["transportConformance"] = "under_test"
    return candidate


def build_unsealed_manifest(manifest: dict[str, Any]) -> dict[str, Any]:
    candidate = copy.deepcopy(manifest)
    compatibility = candidate["compatibility"]
    compatibility["fixtures"] = "not_run"
    compatibility["transportConformance"] = "not_run"
    compatibility["runtimeCapabilities"] = "not_run"
    compatibility["overall"] = "pending_r0_06"
    compatibility.pop("fixtureEvidence", None)
    compatibility.pop("runtimeEvidence", None)
    return candidate


def write_json(path: Path, value: Any) -> None:
    path.write_text(
        json.dumps(value, allow_nan=False, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def assert_file_unchanged(
    path: Path, identity: Identity, digest: str
) -> None:
    if regular_file_identity(path) != identity or sha256_file(path) != digest:
        raise SchemaError(f"verified schema metadata changed before publication: {path}")


def write_bytes_fsync(
    path: Path, payload: bytes, *, create: bool, mode: int = 0o600
) -> None:
    flags = os.O_WRONLY | os.O_CLOEXEC | os.O_NOFOLLOW
    if create:
        flags |= os.O_CREAT | os.O_EXCL
    with anchored_parent(path) as (parent, name):
        descriptor = os.open(name, flags, mode, dir_fd=parent)
        try:
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode):
                raise SchemaError(f"schema metadata is not a regular file: {path}")
            opened_identity = metadata_identity(metadata)
            entry_metadata = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if metadata_identity(entry_metadata) != opened_identity:
                raise SchemaError(f"schema metadata changed while opening: {path}")
            os.ftruncate(descriptor, 0)
            remaining = memoryview(payload)
            while remaining:
                written = os.write(descriptor, remaining)
                if written == 0:
                    raise OSError("zero-byte write while publishing schema metadata")
                remaining = remaining[written:]
            os.fsync(descriptor)
            final_metadata = os.fstat(descriptor)
            final_entry = os.stat(name, dir_fd=parent, follow_symlinks=False)
            if metadata_identity(final_entry) != metadata_identity(final_metadata):
                raise SchemaError(f"schema metadata path changed while writing: {path}")
        finally:
            os.close(descriptor)
    regular_file_identity(path)


def write_json_fsync(path: Path, value: Any, *, create: bool) -> None:
    payload = (
        json.dumps(value, allow_nan=False, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")
    write_bytes_fsync(path, payload, create=create)


def fsync_file(path: Path) -> None:
    with anchored_descriptor(path, directory=False) as descriptor:
        os.fsync(descriptor)


def fsync_directory(path: Path) -> None:
    with anchored_descriptor(path, directory=True) as descriptor:
        os.fsync(descriptor)


def reject_reserved_manifest_residue(bundle: Path) -> None:
    bundle_identity = directory_identity(bundle)
    with anchored_descriptor(bundle, directory=True) as descriptor:
        names = os.listdir(descriptor)
    residues = sorted(
        name
        for name in names
        if any(fnmatch.fnmatchcase(name, pattern) for pattern in RESERVED_MANIFEST_PATTERNS)
    )
    if residues:
        raise SchemaError(f"reserved schema manifest residue is present: {residues}")
    assert_directory_unchanged(bundle, bundle_identity)


def validate_bundle_root_shape(bundle: Path) -> None:
    bundle_identity = directory_identity(bundle)
    expected = {
        "SEMANTIC-SHA256SUMS": "file",
        "experimental": "directory",
        "json": "directory",
        "manifest.json": "file",
        "method-field-matrix.json": "file",
        "typescript": "directory",
    }
    with anchored_descriptor(bundle, directory=True) as descriptor:
        names = set(os.listdir(descriptor))
    if names != set(expected):
        missing = sorted(set(expected) - names)
        extra = sorted(names - set(expected))
        raise SchemaError(f"schema bundle root shape mismatch; missing={missing}, extra={extra}")

    for name, expected_kind in expected.items():
        path = bundle / name
        if expected_kind == "file":
            regular_file_identity(path)
        else:
            directory_identity(path)

    experimental = bundle / "experimental"
    with anchored_descriptor(experimental, directory=True) as descriptor:
        names = set(os.listdir(descriptor))
    if names != {"json", "typescript"}:
        raise SchemaError(
            "experimental schema root must contain exactly json and typescript directories"
        )
    directory_identity(experimental / "json")
    directory_identity(experimental / "typescript")
    assert_directory_unchanged(bundle, bundle_identity)


def restore_manifest(
    manifest_path: Path,
    original: bytes,
    publication_root: Path,
    bundle: Path,
    expected_bundle_identity: Identity,
    published_identity: Identity,
    published_digest: str,
) -> None:
    rollback_path = publication_root / "manifest.rollback"
    if path_kind_no_follow(rollback_path) is not None:
        with anchored_parent(rollback_path) as (parent, name):
            os.unlink(name, dir_fd=parent)
    write_bytes_fsync(rollback_path, original, create=True)
    try:
        assert_directory_unchanged(bundle, expected_bundle_identity)
        assert_file_unchanged(manifest_path, published_identity, published_digest)
    except SchemaError as error:
        raise SchemaError(
            "refusing stale schema manifest rollback because the published destination changed"
        ) from error
    secure_replace(rollback_path, manifest_path)
    assert_directory_same_object(bundle, expected_bundle_identity)
    restored_bundle_identity = directory_identity(bundle)
    fsync_directory(publication_root)
    fsync_directory(bundle)
    assert_directory_unchanged(bundle, restored_bundle_identity)
    regular_file_identity(manifest_path)
    if sha256_file(manifest_path) != sha256_bytes(original):
        raise SchemaError("failed to restore the original schema manifest bytes")


def copy_regular_file(source: Path, destination: Path) -> None:
    source_identity = regular_file_identity(source)
    source_mode = regular_file_mode(source)
    content = read_regular_bytes(source)
    if regular_file_identity(source) != source_identity:
        raise SchemaError(f"snapshot source changed before it could be copied: {source}")
    mkdir_parents_no_follow(destination.parent)
    existing = read_optional_regular_bytes(destination)
    if existing is not None:
        if existing != content:
            raise SchemaError(f"snapshot input collision differs from source: {destination}")
        return
    write_bytes_fsync(destination, content, create=True, mode=source_mode)
    regular_file_identity(destination)


def copy_regular_tree(
    source_root: Path, destination_root: Path, *, exclude: set[str] | None = None
) -> None:
    excluded = exclude or set()
    for source in regular_tree_files(source_root):
        relative = source.relative_to(source_root).as_posix()
        if relative not in excluded:
            copy_regular_file(source, destination_root / relative)


def copy_fixture_sources(
    snapshot_root: Path, *, repo_root: Path | None = None, version: str | None = None
) -> None:
    repo_root = repo_root or REPO_ROOT
    version = version or read_version(repo_root / "CODEX_VERSION")
    for relative in fixture_source_files(repo_root=repo_root, version=version):
        source = regular_relative_file(repo_root, relative)
        copy_regular_file(source, snapshot_root / relative)


def vendored_erlexec_source_proof(root: Path) -> VendoredErlexecSourceProof:
    entries: list[tuple[str, str, int]] = []
    for relative in VENDORED_ERLEXEC_SOURCE_FILES:
        content = read_regular_bytes(regular_relative_file(root, relative))
        entries.append((relative, sha256_bytes(content), len(content)))
    return VendoredErlexecSourceProof(
        file_count=len(entries),
        byte_count=sum(size for _path, _digest, size in entries),
        sha256=sha256_bytes(checksum_stream(entries)),
    )


def assert_vendored_erlexec_source_proof(
    root: Path, expected: VendoredErlexecSourceProof
) -> None:
    if vendored_erlexec_source_proof(root) != expected:
        raise SchemaError("writable erlexec copy changed a selected vendored source file")


def prepare_runtime_erlexec(
    snapshot_root: Path, runtime_root: Path
) -> tuple[Path, VendoredErlexecSourceProof]:
    source_root = snapshot_root / "elixir" / "vendor" / "erlexec"
    expected_inventory = tuple(sorted(VENDORED_ERLEXEC_SOURCE_FILES))
    if (
        VENDORED_ERLEXEC_SOURCE_FILES != expected_inventory
        or len(set(VENDORED_ERLEXEC_SOURCE_FILES)) != len(expected_inventory)
    ):
        raise SchemaError("vendored erlexec source inventory must be unique and sorted")
    source_inventory = tuple(
        path.relative_to(source_root).as_posix() for path in regular_tree_files(source_root)
    )
    if source_inventory != expected_inventory:
        raise SchemaError("fixture vendored erlexec tree differs from the exact source inventory")

    source_proof = vendored_erlexec_source_proof(source_root)
    runtime_erlexec = runtime_root / "vendor" / "erlexec"
    for relative in VENDORED_ERLEXEC_SOURCE_FILES:
        copy_regular_file(
            regular_relative_file(source_root, relative), runtime_erlexec / relative
        )
    runtime_inventory = tuple(
        path.relative_to(runtime_erlexec).as_posix()
        for path in regular_tree_files(runtime_erlexec)
    )
    if runtime_inventory != expected_inventory:
        raise SchemaError("writable erlexec copy differs from the exact source inventory")
    assert_vendored_erlexec_source_proof(runtime_erlexec, source_proof)
    return runtime_erlexec, source_proof


def artifact_evidence(bundle: Path) -> dict[str, str]:
    entries = artifact_entries(bundle)
    json_entries = [
        entry for entry in entries if entry[0].startswith(("json/", "experimental/json/"))
    ]
    return {
        "artifactBundleSha256": sha256_bytes(checksum_stream(entries)),
        "schemaBundleSha256": sha256_bytes(checksum_stream(json_entries)),
    }


def validate_fixture_snapshot(
    snapshot_root: Path, expected_evidence: dict[str, Any], version: str
) -> None:
    if (
        expected_evidence.get("sourceHashAlgorithm")
        != "sha256-text-lf-binary-raw-relative-path-v2"
    ):
        raise SchemaError("fixture snapshot source hash algorithm is not the supported v2 contract")
    if expected_evidence.get("command") != list(FIXTURE_TEST_COMMAND):
        raise SchemaError("fixture snapshot test command differs from the focused test contract")
    if expected_evidence.get("dependencyCommand") != list(FIXTURE_DEPENDENCY_COMMAND):
        raise SchemaError("fixture snapshot dependency command differs from the locked contract")
    if expected_evidence.get("dependencyCompileCommand") != list(
        FIXTURE_DEPENDENCY_COMPILE_COMMAND
    ):
        raise SchemaError("fixture snapshot dependency compile command differs from the locked contract")
    if expected_evidence.get("testCount") != FIXTURE_EXPECTED_TEST_COUNT:
        raise SchemaError("fixture snapshot test count differs from the focused test contract")
    source = fixture_source_summary(repo_root=snapshot_root, version=version)
    if source["fileCount"] != expected_evidence.get("sourceFileCount"):
        raise SchemaError("fixture snapshot source file count differs from pre-test evidence")
    if source["sha256"] != expected_evidence.get("sourceSha256"):
        raise SchemaError("fixture snapshot source digest differs from pre-test evidence")

    root_version = read_version(snapshot_root / "CODEX_VERSION")
    packaged_version = read_version(
        snapshot_root / "elixir" / "priv" / "codex_schema" / "CODEX_VERSION"
    )
    if root_version != version or packaged_version != version:
        raise SchemaError("fixture snapshot Codex version files do not match the pinned version")

    bundle = snapshot_root / "elixir" / "priv" / "codex_schema" / version
    artifacts = artifact_evidence(bundle)
    for key, actual in artifacts.items():
        if actual != expected_evidence.get(key):
            raise SchemaError(f"fixture snapshot {key} differs from pre-test evidence")
    if sha256_file(bundle / "method-field-matrix.json") != expected_evidence.get("matrixSha256"):
        raise SchemaError("fixture snapshot matrix differs from pre-test evidence")


def create_snapshot_runtime(snapshot_root: Path) -> tuple[Path, Path, Path, Path]:
    runtime_root = snapshot_root / ".fixture-runtime"
    if runtime_root.exists() or runtime_root.is_symlink():
        raise SchemaError("fixture snapshot runtime path must start absent")
    runtime_root.mkdir(mode=0o700)
    build_path = runtime_root / "build"
    deps_path = runtime_root / "deps"
    temporary_path = runtime_root / "tmp"
    for path in (build_path, deps_path, temporary_path):
        path.mkdir(mode=0o700)
    return runtime_root, build_path, deps_path, temporary_path


def freeze_snapshot_inputs(snapshot_root: Path, runtime_root: Path) -> None:
    runtime_identity = directory_identity(runtime_root)

    def visit(descriptor: int, display: Path, *, root: bool) -> None:
        before_names = sorted(os.listdir(descriptor))
        children: dict[str, tuple[tuple[int, int, int], bool]] = {}
        for name in before_names:
            metadata = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            path = display / name
            if stat.S_ISLNK(metadata.st_mode):
                raise SchemaError(f"refusing symbolic link in fixture snapshot: {path}")

            is_directory = stat.S_ISDIR(metadata.st_mode)
            if not is_directory and not stat.S_ISREG(metadata.st_mode):
                raise SchemaError(f"fixture snapshot contains a non-regular entry: {path}")
            children[name] = (stable_directory_link_identity(metadata), is_directory)

            if root and name == runtime_root.name:
                if not is_directory:
                    raise SchemaError("fixture runtime entry is not a directory")
                continue
            if root and name == ".active.lock":
                if is_directory:
                    raise SchemaError("fixture snapshot marker is not a regular file")
                continue

            flags = secure_directory_flags() if is_directory else secure_file_flags()
            child = os.open(name, flags, dir_fd=descriptor)
            try:
                opened = os.fstat(child)
                if stable_directory_link_identity(opened) != children[name][0]:
                    raise SchemaError(f"fixture snapshot entry changed while opening: {path}")
                if is_directory:
                    visit(child, path, root=False)
                else:
                    if opened.st_nlink != 1:
                        raise SchemaError(
                            f"fixture snapshot file has external hardlinks: {path}"
                        )
                    os.fchmod(child, stat.S_IMODE(opened.st_mode) & ~0o222)
            finally:
                os.close(child)

        if sorted(os.listdir(descriptor)) != before_names:
            raise SchemaError(f"fixture snapshot directory changed while freezing: {display}")
        for name, (expected, is_directory) in children.items():
            observed = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if (
                stable_directory_link_identity(observed) != expected
                or stat.S_ISDIR(observed.st_mode) != is_directory
            ):
                raise SchemaError(f"fixture snapshot entry changed while freezing: {display / name}")

        metadata = os.fstat(descriptor)
        os.fchmod(descriptor, stat.S_IMODE(metadata.st_mode) & ~0o222)

    with anchored_descriptor(snapshot_root, directory=True) as descriptor:
        root_identity = stable_directory_link_identity(os.fstat(descriptor))
        visit(descriptor, snapshot_root, root=True)
        if stable_directory_link_identity(os.fstat(descriptor)) != root_identity:
            raise SchemaError("fixture snapshot root changed while freezing")
    assert_directory_unchanged(runtime_root, runtime_identity)


def freeze_regular_directory_tree(root: Path, *, label: str) -> None:
    """Descriptor-freeze a private regular tree without following hardlinks."""

    def visit(descriptor: int, display: Path) -> None:
        before_names = sorted(os.listdir(descriptor))
        children: dict[str, tuple[tuple[int, int, int], bool]] = {}
        for name in before_names:
            before = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            path = display / name
            if stat.S_ISLNK(before.st_mode):
                raise SchemaError(f"{label} contains a symbolic link: {path}")
            is_directory = stat.S_ISDIR(before.st_mode)
            if not is_directory and not stat.S_ISREG(before.st_mode):
                raise SchemaError(f"{label} contains a non-regular entry: {path}")
            children[name] = (stable_directory_link_identity(before), is_directory)
            child = os.open(
                name,
                secure_directory_flags() if is_directory else secure_file_flags(),
                dir_fd=descriptor,
            )
            try:
                opened = os.fstat(child)
                if stable_directory_link_identity(opened) != children[name][0]:
                    raise SchemaError(f"{label} entry changed while opening: {path}")
                if is_directory:
                    visit(child, path)
                else:
                    if opened.st_nlink != 1:
                        raise SchemaError(f"{label} file has external hardlinks: {path}")
                    os.fchmod(child, stat.S_IMODE(opened.st_mode) & ~0o222)
            finally:
                os.close(child)

        if sorted(os.listdir(descriptor)) != before_names:
            raise SchemaError(f"{label} directory changed while freezing: {display}")
        for name, (expected, is_directory) in children.items():
            observed = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if (
                stable_directory_link_identity(observed) != expected
                or stat.S_ISDIR(observed.st_mode) != is_directory
            ):
                raise SchemaError(f"{label} entry changed while freezing: {display / name}")
        metadata = os.fstat(descriptor)
        os.fchmod(descriptor, stat.S_IMODE(metadata.st_mode) & ~0o222)

    with anchored_descriptor(root, directory=True) as descriptor:
        identity = stable_directory_link_identity(os.fstat(descriptor))
        visit(descriptor, root)
        if stable_directory_link_identity(os.fstat(descriptor)) != identity:
            raise SchemaError(f"{label} root changed while freezing")


def thaw_snapshot_descriptor(descriptor: int, display: Path) -> None:
    metadata = os.fstat(descriptor)
    os.fchmod(descriptor, stat.S_IMODE(metadata.st_mode) | 0o700)
    for name in sorted(os.listdir(descriptor)):
        before = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        path = display / name
        if stat.S_ISLNK(before.st_mode):
            continue
        if stat.S_ISDIR(before.st_mode):
            child = os.open(name, secure_directory_flags(), dir_fd=descriptor)
            try:
                if stable_directory_link_identity(os.fstat(child)) != stable_directory_link_identity(
                    before
                ):
                    raise SchemaError(f"fixture snapshot directory changed during cleanup: {path}")
                thaw_snapshot_descriptor(child, path)
            finally:
                os.close(child)
        elif stat.S_ISREG(before.st_mode):
            child = os.open(name, secure_file_flags(), dir_fd=descriptor)
            try:
                if stable_directory_link_identity(os.fstat(child)) != stable_directory_link_identity(
                    before
                ):
                    raise SchemaError(f"fixture snapshot file changed during cleanup: {path}")
                # Directory write permission is sufficient to unlink a file.
                # Never chmod a regular inode here: a writable runtime may
                # contain a hardlink whose metadata is shared outside the tree.
            finally:
                os.close(child)
        else:
            raise SchemaError(f"fixture snapshot contains unsafe cleanup entry: {path}")


def thaw_snapshot_for_cleanup(snapshot_root: Path) -> None:
    kind = path_kind_no_follow(snapshot_root)
    if kind is None:
        return
    if kind != "directory":
        raise SchemaError(f"fixture snapshot cleanup target is not a directory: {snapshot_root}")
    with anchored_descriptor(snapshot_root, directory=True) as descriptor:
        thaw_snapshot_descriptor(descriptor, snapshot_root)


def snapshot_namespace(repo_root: Path | None = None) -> Path:
    repo_root = repo_root or REPO_ROOT
    return SNAPSHOT_ROOT / schema_lock_name(repo_root).removesuffix(".lock")


def ensure_private_owner_directory(path: Path, *, label: str) -> Identity:
    mkdir_parents_no_follow(path, mode=0o700)
    with anchored_descriptor(path, directory=True) as descriptor:
        metadata = os.fstat(descriptor)
        if metadata.st_uid != os.geteuid():
            raise SchemaError(f"{label} is not owner controlled")
        os.fchmod(descriptor, 0o700)
        final = os.fstat(descriptor)
        if stat.S_IMODE(final.st_mode) != 0o700:
            raise SchemaError(f"{label} is not private")
        return metadata_identity(final)


def cleanup_directory_entry(parent: int, name: str, display: Path) -> None:
    if not shutil.rmtree.avoids_symlink_attacks:
        raise SchemaError("platform lacks descriptor-safe recursive cleanup")
    before = os.stat(name, dir_fd=parent, follow_symlinks=False)
    if not stat.S_ISDIR(before.st_mode):
        raise SchemaError(f"fixture snapshot cleanup target is not a directory: {display}")
    descriptor = os.open(name, secure_directory_flags(), dir_fd=parent)
    try:
        if stable_directory_link_identity(os.fstat(descriptor)) != stable_directory_link_identity(
            before
        ):
            raise SchemaError(f"fixture snapshot changed before cleanup: {display}")
        thaw_snapshot_descriptor(descriptor, display)
        observed = os.stat(name, dir_fd=parent, follow_symlinks=False)
        if stable_directory_link_identity(observed) != stable_directory_link_identity(before):
            raise SchemaError(f"fixture snapshot changed before cleanup: {display}")
    finally:
        os.close(descriptor)
    shutil.rmtree(name, dir_fd=parent)
    try:
        os.stat(name, dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        return
    raise SchemaError(f"fixture snapshot cleanup left residue: {display}")


def cleanup_snapshot_directory(path: Path) -> None:
    with anchored_parent(path) as (parent, name):
        cleanup_directory_entry(parent, name, path)


def quarantine_snapshot_entry(
    namespace_descriptor: int, namespace: Path, name: str
) -> None:
    quarantine = f".cleanup-{secrets.token_hex(12)}"
    os.rename(
        name,
        quarantine,
        src_dir_fd=namespace_descriptor,
        dst_dir_fd=namespace_descriptor,
    )
    os.fsync(namespace_descriptor)
    cleanup_directory_entry(
        namespace_descriptor, quarantine, namespace / quarantine
    )
    os.fsync(namespace_descriptor)


def scavenge_stale_fixture_snapshots(
    namespace: Path, *, namespace_descriptor: int | None = None
) -> None:
    if namespace_descriptor is None:
        with anchored_descriptor(namespace, directory=True) as descriptor:
            scavenge_stale_fixture_snapshots(
                namespace, namespace_descriptor=descriptor
            )
        return

    for name in sorted(os.listdir(namespace_descriptor)):
        if not name.startswith(("run-", ".creating-", ".cleanup-")):
            raise SchemaError(f"unexpected fixture snapshot namespace entry: {name}")
        candidate = namespace / name
        metadata = os.stat(name, dir_fd=namespace_descriptor, follow_symlinks=False)
        if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid():
            raise SchemaError(f"fixture snapshot residue is not an owner directory: {candidate}")

        candidate_descriptor = os.open(
            name, secure_directory_flags(), dir_fd=namespace_descriptor
        )
        marker_descriptor: int | None = None
        try:
            if stable_directory_link_identity(os.fstat(candidate_descriptor)) != (
                metadata.st_dev,
                metadata.st_ino,
                metadata.st_uid,
            ):
                raise SchemaError(f"fixture snapshot residue changed while opening: {candidate}")
            try:
                marker_metadata = os.stat(
                    ".active.lock",
                    dir_fd=candidate_descriptor,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                marker_metadata = None
            if marker_metadata is not None:
                if not stat.S_ISREG(marker_metadata.st_mode):
                    raise SchemaError(f"fixture snapshot marker is unsafe: {candidate}")
                marker_descriptor = os.open(
                    ".active.lock",
                    secure_file_flags(),
                    dir_fd=candidate_descriptor,
                )
                if metadata_identity(os.fstat(marker_descriptor)) != metadata_identity(
                    marker_metadata
                ):
                    raise SchemaError(f"fixture snapshot marker changed while opening: {candidate}")
                try:
                    fcntl.flock(marker_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError as error:
                    raise SchemaError(
                        f"another fixture snapshot is still active for this repository: {candidate}"
                    ) from error
        finally:
            os.close(candidate_descriptor)

        try:
            observed = os.stat(name, dir_fd=namespace_descriptor, follow_symlinks=False)
            if stable_directory_link_identity(observed) != stable_directory_link_identity(metadata):
                raise SchemaError(f"fixture snapshot residue changed before quarantine: {candidate}")
            quarantine_snapshot_entry(namespace_descriptor, namespace, name)
        finally:
            if marker_descriptor is not None:
                fcntl.flock(marker_descriptor, fcntl.LOCK_UN)
                os.close(marker_descriptor)


@contextmanager
def fixture_snapshot_workspace(repo_root: Path | None = None):
    repo_root = repo_root or REPO_ROOT
    ensure_private_owner_directory(
        SNAPSHOT_ROOT, label="fixture snapshot top-level directory"
    )
    namespace = snapshot_namespace(repo_root)
    namespace_identity = ensure_private_owner_directory(
        namespace, label="fixture snapshot namespace"
    )
    with anchored_descriptor(namespace, directory=True) as namespace_descriptor:
        if metadata_identity(os.fstat(namespace_descriptor)) != namespace_identity:
            raise SchemaError("fixture snapshot namespace changed before use")
        scavenge_stale_fixture_snapshots(
            namespace, namespace_descriptor=namespace_descriptor
        )

        token = secrets.token_hex(12)
        creating_name = f".creating-{token}"
        run_name = f"run-{token}"
        os.mkdir(creating_name, 0o700, dir_fd=namespace_descriptor)
        creating = namespace / creating_name
        with anchored_descriptor(creating, directory=True) as creating_descriptor:
            write_bytes_fsync(
                creating / ".active.lock", b"active\n", create=True, mode=0o600
            )
            marker_descriptor = os.open(
                ".active.lock", secure_file_flags(), dir_fd=creating_descriptor
            )
        fcntl.flock(marker_descriptor, fcntl.LOCK_EX)
        try:
            os.rename(
                creating_name,
                run_name,
                src_dir_fd=namespace_descriptor,
                dst_dir_fd=namespace_descriptor,
            )
            os.fsync(namespace_descriptor)
            snapshot_root = namespace / run_name
            run_identity = directory_identity(snapshot_root)
            try:
                yield snapshot_root
            finally:
                observed = os.stat(
                    run_name, dir_fd=namespace_descriptor, follow_symlinks=False
                )
                if stable_directory_link_identity(observed) != (
                    run_identity[0],
                    run_identity[1],
                    run_identity[6],
                ):
                    raise SchemaError("active fixture snapshot changed before cleanup")
                quarantine_snapshot_entry(
                    namespace_descriptor, namespace, run_name
                )
        finally:
            fcntl.flock(marker_descriptor, fcntl.LOCK_UN)
            os.close(marker_descriptor)
        final_namespace = os.fstat(namespace_descriptor)
        if (
            stable_directory_link_identity(final_namespace)
            != (namespace_identity[0], namespace_identity[1], namespace_identity[6])
            or stat.S_IMODE(final_namespace.st_mode) != 0o700
        ):
            raise SchemaError("fixture snapshot namespace changed during use")


def prepare_fixture_snapshot(
    snapshot_root: Path,
    test_manifest: dict[str, Any],
    expected_evidence: dict[str, Any],
) -> Path:
    version = str(expected_evidence.get("codexVersion", ""))
    directory_identity(snapshot_root)
    snapshot_schema_root = snapshot_root / "elixir" / "priv" / "codex_schema"
    copy_regular_tree(
        SCHEMA_ROOT,
        snapshot_schema_root,
        exclude={f"{version}/manifest.json"},
    )
    copy_fixture_sources(snapshot_root, version=version)

    snapshot_bundle = snapshot_schema_root / version
    test_manifest_path = snapshot_bundle / "manifest.json"
    write_json_fsync(test_manifest_path, test_manifest, create=True)
    validate_fixture_snapshot(snapshot_root, expected_evidence, version)
    verify_test_manifest(snapshot_root, snapshot_bundle, test_manifest_path, expected_evidence)
    return snapshot_bundle


ANSI_ESCAPE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
MAX_DIAGNOSTIC_OUTPUT_BYTES = 32 * 1024
MAX_CHILD_OUTPUT_BYTES = 1024 * 1024
FIXTURE_OFFLINE_HEX_MAX_ENTRIES = 50_000
FIXTURE_OFFLINE_HEX_MAX_BYTES = 512 * 1024 * 1024
FIXTURE_OFFLINE_NIF_MAX_FILES = 64
FIXTURE_OFFLINE_NIF_MAX_BYTES = 64 * 1024 * 1024
CODEX_CHILD_DEADLINE_SECONDS = 120.0
FIXTURE_CHILD_DEADLINE_SECONDS = 600.0
PROCESS_TERMINATION_GRACE_SECONDS = 1.0
SECRET_ASSIGNMENT = re.compile(
    r"(?i)\b("
    r"LINEAR_API_KEY|OPENAI_API_KEY|GITHUB_TOKEN|GH_TOKEN|NPM_TOKEN|HEX_API_KEY|"
    r"AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|DATABASE_URL|SECRET_KEY_BASE"
    r")(\s*[=:]\s*)(?:\"[^\"]*\"|'[^']*'|[^\s]+)"
)
SECRET_TOKEN = re.compile(
    r"(?i)\b(?:Bearer\s+)?(?:sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9_]{8,}|"
    r"lin_api_[A-Za-z0-9_-]{8,})\b"
)


@dataclass(frozen=True)
class BoundedProcessResult:
    args: tuple[str, ...]
    returncode: int
    stdout: str
    stderr: str
    failure_reason: str | None = None


class HeadTailBuffer:
    """Retain bounded diagnostic head/tail bytes while counting all output."""

    def __init__(self, limit: int = MAX_DIAGNOSTIC_OUTPUT_BYTES) -> None:
        self.limit = limit
        self.head_limit = limit // 2
        self.tail_limit = limit - self.head_limit
        self.total = 0
        self.head = bytearray()
        self.tail = bytearray()

    def append(self, payload: bytes) -> None:
        self.total += len(payload)
        remaining = payload
        if len(self.head) < self.head_limit:
            take = min(self.head_limit - len(self.head), len(remaining))
            self.head.extend(remaining[:take])
            remaining = remaining[take:]
        if remaining:
            self.tail.extend(remaining)
            if len(self.tail) > self.tail_limit:
                del self.tail[: len(self.tail) - self.tail_limit]

    def bytes(self) -> bytes:
        if self.total <= self.limit:
            return bytes(self.head + self.tail)
        return bytes(self.head) + b"\n...[process output truncated]...\n" + bytes(self.tail)


def process_group_alive(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


PR_SET_CHILD_SUBREAPER = 36
PR_GET_CHILD_SUBREAPER = 37
_BOUNDED_PROCESS_LOCK = threading.Lock()


def child_subreaper_enabled() -> bool:
    if platform.system() != "Linux":
        raise SchemaError("bounded child containment requires Linux child-subreaper support")
    libc = ctypes.CDLL(None, use_errno=True)
    prctl = getattr(libc, "prctl", None)
    if prctl is None:
        raise SchemaError("bounded child containment requires prctl")
    state = ctypes.c_int()
    if prctl(PR_GET_CHILD_SUBREAPER, ctypes.byref(state), 0, 0, 0) != 0:
        error = ctypes.get_errno()
        raise SchemaError(f"cannot read child-subreaper state: {os.strerror(error)}")
    return state.value == 1


def set_child_subreaper(enabled: bool) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    prctl = getattr(libc, "prctl", None)
    if prctl is None or prctl(PR_SET_CHILD_SUBREAPER, int(enabled), 0, 0, 0) != 0:
        error = ctypes.get_errno()
        raise SchemaError(f"cannot set child-subreaper state: {os.strerror(error)}")
    if child_subreaper_enabled() is not enabled:
        raise SchemaError("child-subreaper state did not match the requested boundary")


def direct_child_pids() -> set[int]:
    children_path = Path("/proc") / "self" / "task" / str(os.getpid()) / "children"
    try:
        payload = children_path.read_text(encoding="ascii").strip()
    except OSError as error:
        raise SchemaError(f"cannot inspect direct child processes through procfs: {error}") from error
    if not payload:
        return set()
    try:
        return {int(value) for value in payload.split()}
    except ValueError as error:
        raise SchemaError("procfs returned an invalid direct-child process list") from error


def proc_process_identity(pid: int) -> tuple[int, int] | None:
    try:
        payload = (Path("/proc") / str(pid) / "stat").read_bytes()
    except FileNotFoundError:
        return None
    except OSError as error:
        raise SchemaError(f"cannot inspect process {pid} through procfs: {error}") from error
    closing = payload.rfind(b") ")
    fields = payload[closing + 2 :].split() if closing >= 0 else []
    if len(fields) <= 19:
        raise SchemaError(f"procfs returned invalid identity metadata for process {pid}")
    try:
        return pid, int(fields[19])
    except ValueError as error:
        raise SchemaError(f"procfs returned invalid start time for process {pid}") from error


def prepare_process_tree_boundary() -> bool:
    if len(list((Path("/proc") / "self" / "task").iterdir())) != 1:
        raise SchemaError("bounded child containment requires a single-threaded caller")
    if signal.getsignal(signal.SIGCHLD) != signal.SIG_DFL:
        raise SchemaError("bounded child containment requires the default SIGCHLD disposition")
    for capability, name in (
        (getattr(os, "pidfd_open", None), "os.pidfd_open"),
        (getattr(os, "P_PIDFD", None), "os.P_PIDFD"),
        (getattr(os, "WNOWAIT", None), "os.WNOWAIT"),
        (getattr(signal, "pidfd_send_signal", None), "signal.pidfd_send_signal"),
    ):
        if capability is None:
            raise SchemaError(f"bounded child containment requires {name}")
    if direct_child_pids():
        raise SchemaError("bounded child containment found pre-existing direct child processes")
    previous = child_subreaper_enabled()
    if not previous:
        set_child_subreaper(True)
    if direct_child_pids():
        if not previous:
            set_child_subreaper(False)
        raise SchemaError("bounded child containment raced a pre-existing child process")
    return previous


def root_process_exited(process: subprocess.Popen[bytes]) -> bool:
    try:
        status = os.waitid(
            os.P_PID,
            process.pid,
            os.WEXITED | os.WNOHANG | os.WNOWAIT,
        )
    except ChildProcessError as error:
        raise SchemaError("bounded root process was reaped outside its containment boundary") from error
    return status is not None


def refresh_adopted_processes(
    process: subprocess.Popen[bytes], adopted: dict[int, int]
) -> None:
    for pid in sorted(direct_child_pids() - {process.pid} - set(adopted)):
        try:
            descriptor = os.pidfd_open(pid, 0)
        except ProcessLookupError:
            continue
        except OSError as error:
            raise SchemaError(f"cannot open pidfd for adopted process {pid}: {error}") from error
        if pid not in direct_child_pids():
            os.close(descriptor)
            continue
        adopted[pid] = descriptor


def reap_adopted_processes(adopted: dict[int, int]) -> None:
    for pid, descriptor in list(adopted.items()):
        try:
            status = os.waitid(os.P_PIDFD, descriptor, os.WEXITED | os.WNOHANG)
        except ChildProcessError as error:
            raise SchemaError(
                f"adopted process {pid} escaped the child-subreaper boundary"
            ) from error
        if status is not None:
            os.close(descriptor)
            del adopted[pid]


def signal_adopted_processes(adopted: dict[int, int], process_signal: signal.Signals) -> None:
    for descriptor in tuple(adopted.values()):
        try:
            signal.pidfd_send_signal(descriptor, process_signal, None, 0)
        except ProcessLookupError:
            pass


def terminate_process_tree(
    process: subprocess.Popen[bytes], adopted: dict[int, int]
) -> int:
    for process_signal in (signal.SIGTERM, signal.SIGKILL):
        deadline = time.monotonic() + PROCESS_TERMINATION_GRACE_SECONDS
        while True:
            refresh_adopted_processes(process, adopted)
            reap_adopted_processes(adopted)
            try:
                os.killpg(process.pid, process_signal)
            except ProcessLookupError:
                pass
            signal_adopted_processes(adopted, process_signal)
            refresh_adopted_processes(process, adopted)
            reap_adopted_processes(adopted)
            if root_process_exited(process) and not adopted:
                break
            if time.monotonic() >= deadline:
                break
            time.sleep(0.02)
        if root_process_exited(process) and not adopted:
            break

    refresh_adopted_processes(process, adopted)
    reap_adopted_processes(adopted)
    if not root_process_exited(process) or adopted:
        raise SchemaError("could not contain every bounded child process")
    returncode = process.wait(timeout=PROCESS_TERMINATION_GRACE_SECONDS)
    if direct_child_pids():
        raise SchemaError("bounded child processes remained after root cleanup")
    return returncode


def run_bounded_process(
    argv: Iterable[str],
    *,
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    deadline_seconds: float,
    max_output_bytes: int,
) -> BoundedProcessResult:
    """Run one child in a killable process group with bounded output/lifetime."""

    with _BOUNDED_PROCESS_LOCK:
        return _run_bounded_process(
            argv,
            cwd=cwd,
            env=env,
            deadline_seconds=deadline_seconds,
            max_output_bytes=max_output_bytes,
        )


def _run_bounded_process(
    argv: Iterable[str],
    *,
    cwd: Path | None,
    env: dict[str, str] | None,
    deadline_seconds: float,
    max_output_bytes: int,
) -> BoundedProcessResult:
    previous_subreaper = prepare_process_tree_boundary()

    arguments = tuple(str(argument) for argument in argv)
    process: subprocess.Popen[bytes] | None = None
    adopted: dict[int, int] = {}
    boundary_clean = False
    selector: selectors.BaseSelector | None = None
    try:
        process = subprocess.Popen(
            arguments,
            cwd=None if cwd is None else str(cwd),
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        if process.stdout is None or process.stderr is None:
            raise SchemaError("bounded child process did not expose diagnostic pipes")

        stdout = HeadTailBuffer()
        stderr = HeadTailBuffer()
        selector = selectors.DefaultSelector()
        for stream, buffer in ((process.stdout, stdout), (process.stderr, stderr)):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, buffer)

        deadline = time.monotonic() + deadline_seconds
        total_output = 0
        failure_reason: str | None = None
        while True:
            refresh_adopted_processes(process, adopted)
            reap_adopted_processes(adopted)
            root_exited = root_process_exited(process)
            if root_exited and not adopted and not selector.get_map():
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                failure_reason = (
                    "descendant process remained after parent exit"
                    if root_exited and adopted
                    else f"absolute deadline exceeded after {deadline_seconds:g}s"
                )
                break
            if selector.get_map():
                events = selector.select(min(remaining, 0.1))
            else:
                time.sleep(min(remaining, 0.02))
                events = []
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
                    key.data.append(chunk)
                    total_output += len(chunk)
                    if total_output > max_output_bytes:
                        failure_reason = (
                            f"combined child output exceeded {max_output_bytes} bytes"
                        )
                        break
                if failure_reason is not None:
                    break
            if failure_reason is not None:
                break

        if failure_reason is not None:
            returncode = terminate_process_tree(process, adopted)
        else:
            refresh_adopted_processes(process, adopted)
            reap_adopted_processes(adopted)
            if adopted:
                raise SchemaError("bounded child processes remained after successful root exit")
            returncode = process.wait(timeout=PROCESS_TERMINATION_GRACE_SECONDS)
            if direct_child_pids():
                raise SchemaError("bounded child processes remained after successful root exit")
        boundary_clean = True
        return BoundedProcessResult(
            args=arguments,
            returncode=returncode,
            stdout=stdout.bytes().decode("utf-8", errors="replace"),
            stderr=stderr.bytes().decode("utf-8", errors="replace"),
            failure_reason=failure_reason,
        )
    except BaseException:
        if process is not None and not boundary_clean:
            terminate_process_tree(process, adopted)
            boundary_clean = True
        raise
    finally:
        if selector is not None:
            selector.close()
        if process is not None:
            for stream in (process.stdout, process.stderr):
                if stream is not None and not stream.closed:
                    stream.close()
        for descriptor in adopted.values():
            os.close(descriptor)
        if boundary_clean or process is None:
            if child_subreaper_enabled() is not previous_subreaper:
                set_child_subreaper(previous_subreaper)


def normalized_process_output(result: subprocess.CompletedProcess[str] | BoundedProcessResult) -> str:
    combined = "\n".join(part for part in (result.stdout, result.stderr) if part)
    return ANSI_ESCAPE.sub("", combined).replace("\r\n", "\n")


def redacted_bounded_process_output(
    result: subprocess.CompletedProcess[str] | BoundedProcessResult,
) -> str:
    output = normalized_process_output(result)
    output = SECRET_ASSIGNMENT.sub(
        lambda match: f"{match.group(1)}{match.group(2)}[REDACTED]", output
    )
    output = SECRET_TOKEN.sub("[REDACTED]", output)
    encoded = output.encode("utf-8", errors="replace")
    if len(encoded) <= MAX_DIAGNOSTIC_OUTPUT_BYTES:
        return output

    marker = b"\n...[diagnostic output truncated]...\n"
    retained = MAX_DIAGNOSTIC_OUTPUT_BYTES - len(marker)
    head_size = retained // 2
    tail_size = retained - head_size
    return (encoded[:head_size] + marker + encoded[-tail_size:]).decode(
        "utf-8", errors="replace"
    )


def copy_exact_regular_file(
    source: Path,
    destination: Path,
    expected_identity: Identity,
) -> None:
    """Copy one bounded, immutable input without following either pathname."""

    if expected_identity[2] <= 0:
        raise SchemaError("fixture offline Hex input contains an empty file")
    mkdir_parents_no_follow(destination.parent, mode=0o700)
    destination_descriptor: int | None = None
    created = False
    try:
        with anchored_descriptor(source, directory=False) as source_descriptor:
            if metadata_identity(os.fstat(source_descriptor)) != expected_identity:
                raise SchemaError("fixture offline Hex input changed before copy")
            with anchored_parent(destination) as (parent, name):
                flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW
                destination_descriptor = os.open(name, flags, 0o600, dir_fd=parent)
                created = True
                remaining = expected_identity[2]
                while remaining:
                    chunk = os.read(source_descriptor, min(64 * 1024, remaining))
                    if not chunk:
                        raise SchemaError("fixture offline Hex input ended during copy")
                    offset = 0
                    while offset < len(chunk):
                        written = os.write(destination_descriptor, chunk[offset:])
                        if written <= 0:
                            raise SchemaError("fixture offline Hex input copy made no progress")
                        offset += written
                    remaining -= len(chunk)
                if os.read(source_descriptor, 1):
                    raise SchemaError("fixture offline Hex input exceeded its byte bound")
                if metadata_identity(os.fstat(source_descriptor)) != expected_identity:
                    raise SchemaError("fixture offline Hex input changed during copy")
                os.fchmod(destination_descriptor, 0o600)
                os.fsync(destination_descriptor)
        if destination_descriptor is not None:
            os.close(destination_descriptor)
            destination_descriptor = None
        copied = regular_file_identity(destination)
        if copied[2] != expected_identity[2] or regular_file_mode(destination) != 0o600:
            raise SchemaError("fixture offline Hex input copy differs from its source")
    except BaseException:
        if destination_descriptor is not None:
            os.close(destination_descriptor)
        if created and path_kind_no_follow(destination) == "file":
            with anchored_parent(destination) as (parent, name):
                os.unlink(name, dir_fd=parent)
        raise


def install_fixture_offline_hex_home(source_root: Path, destination_root: Path) -> None:
    """Install a bounded writable clone of the outer gate's read-only Hex cache."""

    source_root = lexical_absolute(source_root)
    root_identity = directory_identity(source_root)
    if path_kind_no_follow(destination_root) is not None:
        raise SchemaError("fixture private offline Hex destination already exists")

    entries: list[tuple[str, bool, Identity]] = []
    pending: list[tuple[Path, Path]] = [(source_root, Path())]
    total_bytes = 0
    while pending:
        directory, relative_directory = pending.pop()
        with anchored_descriptor(directory, directory=True) as descriptor:
            directory_before = metadata_identity(os.fstat(descriptor))
            children: list[tuple[Path, Path]] = []
            with os.scandir(descriptor) as scanner:
                for entry in scanner:
                    if len(entries) >= FIXTURE_OFFLINE_HEX_MAX_ENTRIES:
                        raise SchemaError("fixture offline Hex cache contains too many entries")
                    metadata = os.stat(entry.name, dir_fd=descriptor, follow_symlinks=False)
                    relative = relative_directory / entry.name
                    if stat.S_ISDIR(metadata.st_mode):
                        entries.append((relative.as_posix(), True, metadata_identity(metadata)))
                        children.append((directory / entry.name, relative))
                    elif stat.S_ISREG(metadata.st_mode):
                        total_bytes += metadata.st_size
                        if total_bytes > FIXTURE_OFFLINE_HEX_MAX_BYTES:
                            raise SchemaError("fixture offline Hex cache exceeds its byte bound")
                        entries.append((relative.as_posix(), False, metadata_identity(metadata)))
                    else:
                        raise SchemaError("fixture offline Hex cache contains an unsafe entry")
            if metadata_identity(os.fstat(descriptor)) != directory_before:
                raise SchemaError("fixture offline Hex cache changed during bounded traversal")
            pending.extend(children)

    entries.sort(key=lambda item: item[0])
    top_level = {
        (relative, "directory" if is_directory else "file")
        for relative, is_directory, _identity in entries
        if "/" not in relative
    }
    if top_level != {("cache.ets", "file"), ("packages", "directory")}:
        raise SchemaError("fixture offline Hex cache has an invalid top-level inventory")
    if not any(
        not is_directory and relative.startswith("packages/")
        for relative, is_directory, _identity in entries
    ):
        raise SchemaError("fixture offline Hex cache contains no package files")

    mkdir_parents_no_follow(destination_root, mode=0o700)
    os.chmod(destination_root, 0o700)
    try:
        for relative, is_directory, _identity in entries:
            if is_directory:
                destination = destination_root / relative
                mkdir_parents_no_follow(destination, mode=0o700)
                os.chmod(destination, 0o700)
        for relative, is_directory, expected_identity in entries:
            if not is_directory:
                copy_exact_regular_file(
                    source_root / relative,
                    destination_root / relative,
                    expected_identity,
                )
        if directory_identity(source_root) != root_identity:
            raise SchemaError("fixture offline Hex cache changed while copied")
        for relative, is_directory, expected_identity in entries:
            if is_directory:
                if directory_identity(source_root / relative) != expected_identity:
                    raise SchemaError("fixture offline Hex directory changed while copied")
            elif regular_file_identity(source_root / relative) != expected_identity:
                raise SchemaError("fixture offline Hex file changed while copied")
    except BaseException:
        shutil.rmtree(destination_root, ignore_errors=True)
        raise


def install_fixture_offline_nif_cache(source_root: Path, destination_root: Path) -> None:
    """Clone the outer gate's bounded precompiled-NIF cache into fixture state."""

    source_root = lexical_absolute(source_root)
    root_identity = directory_identity(source_root)
    if path_kind_no_follow(destination_root) is not None:
        raise SchemaError("fixture private offline NIF destination already exists")

    entries: list[tuple[str, Identity]] = []
    total_bytes = 0
    with anchored_descriptor(source_root, directory=True) as descriptor:
        before = metadata_identity(os.fstat(descriptor))
        with os.scandir(descriptor) as scanner:
            for entry in scanner:
                if len(entries) >= FIXTURE_OFFLINE_NIF_MAX_FILES:
                    raise SchemaError("fixture offline NIF cache contains too many files")
                metadata = os.stat(entry.name, dir_fd=descriptor, follow_symlinks=False)
                if (
                    not stat.S_ISREG(metadata.st_mode)
                    or re.fullmatch(
                        r"[A-Za-z0-9][A-Za-z0-9._-]{0,255}\.tar\.gz", entry.name
                    )
                    is None
                ):
                    raise SchemaError("fixture offline NIF cache contains an unsafe entry")
                total_bytes += metadata.st_size
                if total_bytes > FIXTURE_OFFLINE_NIF_MAX_BYTES:
                    raise SchemaError("fixture offline NIF cache exceeds its byte bound")
                entries.append((entry.name, metadata_identity(metadata)))
        if metadata_identity(os.fstat(descriptor)) != before:
            raise SchemaError("fixture offline NIF cache changed during bounded traversal")
    if not entries:
        raise SchemaError("fixture offline NIF cache is empty")

    entries.sort(key=lambda item: item[0])
    mkdir_parents_no_follow(destination_root, mode=0o700)
    os.chmod(destination_root, 0o700)
    try:
        for name, expected_identity in entries:
            copy_exact_regular_file(
                source_root / name,
                destination_root / name,
                expected_identity,
            )
        if directory_identity(source_root) != root_identity:
            raise SchemaError("fixture offline NIF cache changed while copied")
        for name, expected_identity in entries:
            if regular_file_identity(source_root / name) != expected_identity:
                raise SchemaError("fixture offline NIF archive changed while copied")
    except BaseException:
        shutil.rmtree(destination_root, ignore_errors=True)
        raise


def fixture_child_environment(
    runtime_root: Path,
    build_path: Path,
    deps_path: Path,
    temporary_path: Path,
    test_manifest_path: Path,
) -> dict[str, str]:
    """Build the exact non-secret environment allowed into fixture children."""

    mise = shutil.which("mise")
    if mise is None:
        raise SchemaError("mise is required for the fixture compatibility gate")
    mise_path = lexical_absolute(Path(mise))
    regular_file_identity(mise_path)

    host_home = Path(os.path.expanduser("~"))
    mise_data = lexical_absolute(
        Path(os.environ.get("MISE_DATA_DIR", host_home / ".local" / "share" / "mise"))
    )
    directory_identity(mise_data)

    outer_marker = os.environ.get("SYMPHONY_READINESS_OUTER_SANDBOX")
    if outer_marker not in {None, "1"}:
        raise SchemaError("fixture outer-sandbox marker is invalid")
    offline_hex_source: Path | None = None
    offline_nif_cache_source: Path | None = None
    offline_mix_archives: Path | None = None
    offline_mix_rebar3: Path | None = None
    if outer_marker == "1":
        if os.environ.get("HEX_OFFLINE") != "1":
            raise SchemaError("fixture outer sandbox is not Hex-offline")
        raw_hex_home = os.environ.get("HEX_HOME")
        raw_xdg_cache = os.environ.get("XDG_CACHE_HOME")
        raw_mix_archives = os.environ.get("MIX_ARCHIVES")
        raw_mix_rebar3 = os.environ.get("MIX_REBAR3")
        if (
            not raw_hex_home
            or not raw_xdg_cache
            or not raw_mix_archives
            or not raw_mix_rebar3
        ):
            raise SchemaError("fixture outer sandbox lacks its private Mix inputs")
        offline_hex_source = lexical_absolute(Path(raw_hex_home))
        offline_nif_cache_source = lexical_absolute(
            Path(raw_xdg_cache) / "elixir_make"
        )
        offline_mix_archives = lexical_absolute(Path(raw_mix_archives))
        offline_mix_rebar3 = lexical_absolute(Path(raw_mix_rebar3))
        directory_identity(offline_hex_source)
        directory_identity(offline_nif_cache_source)
        directory_identity(offline_mix_archives)
        regular_file_identity(offline_mix_rebar3)
        if regular_file_mode(offline_mix_rebar3) & 0o111 == 0:
            raise SchemaError("fixture outer sandbox Rebar input is not executable")

    private_home = runtime_root / "home"
    cache_root = runtime_root / "cache"
    config_root = runtime_root / "config"
    state_root = runtime_root / "state"
    for path in (private_home, cache_root, config_root, state_root):
        mkdir_parents_no_follow(path, mode=0o700)
    offline_hex_home: Path | None = None
    if offline_hex_source is not None:
        offline_hex_home = runtime_root / "offline-hex"
        install_fixture_offline_hex_home(offline_hex_source, offline_hex_home)
        assert offline_nif_cache_source is not None
        install_fixture_offline_nif_cache(
            offline_nif_cache_source, cache_root / "elixir_make"
        )
    runtime_erlexec = runtime_root / "vendor" / "erlexec"
    directory_identity(runtime_erlexec)

    codex_launcher, _native, _lock, _selected = installed_codex("codex")

    environment = {
        "CLICOLOR": "0",
        "ERL_CRASH_DUMP": str(temporary_path / "erl_crash.dump"),
        "HOME": str(private_home),
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "MISE_CACHE_DIR": str(cache_root / "mise"),
        "MISE_CONFIG_DIR": str(config_root / "mise"),
        "MISE_DATA_DIR": str(mise_data),
        "MISE_STATE_DIR": str(state_root / "mise"),
        "MIX_BUILD_PATH": str(build_path),
        "MIX_DEPS_PATH": str(deps_path),
        "MIX_ENV": "test",
        "NO_COLOR": "1",
        "PATH": ":".join(
            (str(mise_path.parent), "/usr/local/bin", "/usr/bin", "/bin")
        ),
        "REBAR_CACHE_DIR": str(cache_root / "rebar3"),
        "SHELL": "/bin/sh",
        ERLEXEC_PATH_ENV: str(runtime_erlexec),
        "SYMPHONY_FIXTURE_LOG_FILE": str(temporary_path / "symphony.log"),
        "SYMPHONY_CODEX_CONFORMANCE_BIN": str(codex_launcher),
        "TERM": "dumb",
        TEST_MANIFEST_ENV: str(test_manifest_path),
        "TMPDIR": str(temporary_path),
        "XDG_CACHE_HOME": str(cache_root),
        "XDG_CONFIG_HOME": str(config_root),
        "XDG_STATE_HOME": str(state_root),
    }
    if offline_hex_home is not None:
        environment["HEX_HOME"] = str(offline_hex_home)
        environment["HEX_OFFLINE"] = "1"
        environment["MIX_ARCHIVES"] = str(offline_mix_archives)
        environment["MIX_REBAR3"] = str(offline_mix_rebar3)
    return environment


def regular_tree_directories(
    root: Path, *, exclude: Path | None = None
) -> tuple[Path, ...]:
    directories: list[Path] = []

    def visit(directory: Path) -> None:
        directories.append(directory)
        with anchored_descriptor(directory, directory=True) as descriptor:
            before = directory_fingerprint(descriptor)
            for name, identity in before:
                if stat.S_ISDIR(identity[5]):
                    child = directory / name
                    if exclude is None or lexical_absolute(child) != lexical_absolute(exclude):
                        visit(child)
                elif not stat.S_ISREG(identity[5]):
                    raise SchemaError(
                        f"fixture snapshot input tree contains an unsafe entry: {directory / name}"
                    )
            if directory_fingerprint(descriptor) != before:
                raise SchemaError(
                    f"fixture snapshot input tree changed while installing mutation fences: {directory}"
                )

    visit(root)
    return tuple(directories)


@contextmanager
def dependency_source_event_log(
    snapshot_root: Path, *, excluded_root: Path | None = None
):
    """Record source-tree mutations, including changes later restored."""

    libc = ctypes.CDLL(None, use_errno=True)
    init = getattr(libc, "inotify_init1", None)
    add_watch = getattr(libc, "inotify_add_watch", None)
    remove_watch = getattr(libc, "inotify_rm_watch", None)
    if init is None or add_watch is None or remove_watch is None:
        raise SchemaError("platform lacks inotify required for dependency snapshot fencing")

    init.argtypes = [ctypes.c_int]
    init.restype = ctypes.c_int
    add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
    add_watch.restype = ctypes.c_int
    remove_watch.argtypes = [ctypes.c_int, ctypes.c_int]
    remove_watch.restype = ctypes.c_int

    in_modify = 0x00000002
    in_attrib = 0x00000004
    in_close_write = 0x00000008
    in_moved_from = 0x00000040
    in_moved_to = 0x00000080
    in_create = 0x00000100
    in_delete = 0x00000200
    in_delete_self = 0x00000400
    in_move_self = 0x00000800
    in_q_overflow = 0x00004000
    mask = (
        in_modify
        | in_attrib
        | in_close_write
        | in_moved_from
        | in_moved_to
        | in_create
        | in_delete
        | in_delete_self
        | in_move_self
        | in_q_overflow
    )
    inotify_descriptor = init(os.O_CLOEXEC | os.O_NONBLOCK)
    if inotify_descriptor < 0:
        error = ctypes.get_errno()
        raise SchemaError(f"cannot create dependency snapshot mutation fence: {os.strerror(error)}")

    watches: dict[int, str] = {}
    for directory in regular_tree_directories(snapshot_root, exclude=excluded_root):
        with anchored_descriptor(directory, directory=True) as descriptor:
            watch = add_watch(
                inotify_descriptor,
                os.fsencode(f"/proc/self/fd/{descriptor}"),
                mask,
            )
        if watch < 0:
            error = ctypes.get_errno()
            for installed in watches:
                remove_watch(inotify_descriptor, installed)
            os.close(inotify_descriptor)
            raise SchemaError(f"cannot watch dependency snapshot root: {os.strerror(error)}")
        watches[watch] = directory.relative_to(snapshot_root).as_posix()

    events: list[tuple[str, int, str]] = []
    try:
        yield events
    finally:
        while True:
            try:
                payload = os.read(inotify_descriptor, 64 * 1024)
            except BlockingIOError:
                break
            if not payload:
                break
            offset = 0
            while offset < len(payload):
                if len(payload) - offset < 16:
                    raise SchemaError("truncated dependency snapshot mutation event")
                event_watch, event_mask, _cookie, name_length = struct.unpack_from(
                    "iIII", payload, offset
                )
                offset += 16
                if offset + name_length > len(payload):
                    raise SchemaError("invalid dependency snapshot mutation event length")
                raw_name = payload[offset : offset + name_length]
                offset += name_length
                name = os.fsdecode(raw_name.split(b"\0", 1)[0])
                events.append((watches.get(event_watch, "<unknown>"), event_mask, name))
        for watch in watches:
            remove_watch(inotify_descriptor, watch)
        os.close(inotify_descriptor)


def validate_dependency_root_events(
    events: list[tuple[str, int, str]], *, writable_relative: str
) -> None:
    # Hex 2.4.x creates and removes one cleaned `tmp_<random>` directory in
    # the project cwd. No source, lock, or configuration entry may change,
    # even transiently and even if its final inode/bytes are restored.
    allowed_name = re.compile(r"tmp_[A-Za-z0-9._-]+")
    allowed_bits = 0x40000000 | 0x00000004 | 0x00000040 | 0x00000080 | 0x00000100 | 0x00000200
    invalid = [
        (directory, mask, name)
        for directory, mask, name in events
        if directory != writable_relative
        or not allowed_name.fullmatch(name)
        or mask & ~allowed_bits
    ]
    if invalid:
        preview = ", ".join(
            f"{directory}/{name or '<root>'}:0x{mask:x}"
            for directory, mask, name in invalid[:8]
        )
        raise SchemaError(
            f"snapshot dependency resolution mutated a protected project entry: {preview}"
        )


def validate_no_mutation_events(
    events: list[tuple[str, int, str]], *, label: str
) -> None:
    if not events:
        return
    preview = ", ".join(
        f"{directory}/{name or '<root>'}:0x{mask:x}"
        for directory, mask, name in events[:8]
    )
    raise SchemaError(f"{label} mutated a frozen input: {preview}")


def validate_vendored_erlexec_source_events(
    events: list[tuple[str, int, str]], *, label: str
) -> None:
    selected = set(VENDORED_ERLEXEC_SOURCE_FILES)

    def touches_selected_source(directory: str, mask: int, name: str) -> bool:
        if mask & 0x00004000 or directory == "<unknown>":
            return True
        if directory in {"", "."}:
            relative = name
        elif name:
            relative = f"{directory}/{name}"
        else:
            relative = directory
        if not relative:
            return True
        return relative in selected or any(
            source.startswith(f"{relative}/") for source in selected
        )

    invalid = [
        event for event in events if touches_selected_source(*event)
    ]
    if not invalid:
        return
    preview = ", ".join(
        f"{directory}/{name or '<root>'}:0x{mask:x}"
        for directory, mask, name in invalid[:8]
    )
    raise SchemaError(
        f"{label} changed a selected vendored erlexec source file transiently: {preview}"
    )


@contextmanager
def writable_snapshot_dependency_cwd(
    snapshot_elixir: Path,
    *,
    snapshot_root: Path | None = None,
    runtime_root: Path | None = None,
):
    """Permit Hex's cleaned relative temp dir, then restore and prove no residue."""

    snapshot_root = snapshot_root or snapshot_elixir
    writable_relative = snapshot_elixir.relative_to(snapshot_root).as_posix()
    with anchored_descriptor(snapshot_elixir, directory=True) as descriptor:
        original_mode = stat.S_IMODE(os.fstat(descriptor).st_mode)
        before = directory_fingerprint(descriptor)
        os.fchmod(descriptor, original_mode | stat.S_IWUSR | stat.S_IXUSR)
        try:
            with dependency_source_event_log(
                snapshot_root, excluded_root=runtime_root
            ) as events:
                yield
        finally:
            after = directory_fingerprint(descriptor)
            os.fchmod(descriptor, original_mode)
        validate_dependency_root_events(
            events, writable_relative=writable_relative
        )
        if after != before:
            raise SchemaError("snapshot dependency resolution changed the frozen project root")


def raise_process_failure(
    label: str,
    result: subprocess.CompletedProcess[str] | BoundedProcessResult,
    reason: str,
) -> None:
    output = redacted_bounded_process_output(result)
    print(f"{label} redacted bounded output:\n{output}", file=sys.stderr)
    raise SchemaError(f"{label} failed: {reason}; redacted bounded output:\n{output}")


def execute_snapshot_fixture_tests(
    snapshot_root: Path, expected_evidence: dict[str, Any]
) -> None:
    snapshot_elixir = snapshot_root / "elixir"
    snapshot_bundle = (
        snapshot_elixir
        / "priv"
        / "codex_schema"
        / str(expected_evidence["codexVersion"])
    )
    test_manifest_path = snapshot_bundle / "manifest.json"
    runtime_root, build_path, deps_path, temporary_path = create_snapshot_runtime(snapshot_root)
    runtime_erlexec, erlexec_source_proof = prepare_runtime_erlexec(
        snapshot_root, runtime_root
    )
    freeze_snapshot_inputs(snapshot_root, runtime_root)
    validate_fixture_snapshot(
        snapshot_root,
        expected_evidence,
        str(expected_evidence["codexVersion"]),
    )
    verify_test_manifest(snapshot_root, snapshot_bundle, test_manifest_path, expected_evidence)

    environment = fixture_child_environment(
        runtime_root,
        build_path,
        deps_path,
        temporary_path,
        test_manifest_path,
    )

    with writable_snapshot_dependency_cwd(
        snapshot_elixir,
        snapshot_root=snapshot_root,
        runtime_root=runtime_root,
    ):
        with dependency_source_event_log(runtime_erlexec) as erlexec_events:
            deps_result = run_bounded_process(
                FIXTURE_DEPENDENCY_COMMAND,
                cwd=snapshot_elixir,
                env=environment,
                deadline_seconds=FIXTURE_CHILD_DEADLINE_SECONDS,
                max_output_bytes=MAX_CHILD_OUTPUT_BYTES,
            )
    validate_vendored_erlexec_source_events(
        erlexec_events, label="snapshot dependency resolution"
    )
    assert_vendored_erlexec_source_proof(runtime_erlexec, erlexec_source_proof)
    if deps_result.failure_reason is not None or deps_result.returncode != 0:
        raise_process_failure(
            "snapshot dependency resolution",
            deps_result,
            deps_result.failure_reason or f"exit={deps_result.returncode}",
        )
    regular_tree_files(deps_path)
    with writable_snapshot_dependency_cwd(
        snapshot_elixir,
        snapshot_root=snapshot_root,
        runtime_root=runtime_root,
    ):
        with dependency_source_event_log(runtime_erlexec) as erlexec_events:
            dependency_compile_result = run_bounded_process(
                FIXTURE_DEPENDENCY_COMPILE_COMMAND,
                cwd=snapshot_elixir,
                env=dict(environment, HEX_OFFLINE="1"),
                deadline_seconds=FIXTURE_CHILD_DEADLINE_SECONDS,
                max_output_bytes=MAX_CHILD_OUTPUT_BYTES,
            )
    validate_vendored_erlexec_source_events(
        erlexec_events, label="snapshot dependency compilation"
    )
    assert_vendored_erlexec_source_proof(runtime_erlexec, erlexec_source_proof)
    if (
        dependency_compile_result.failure_reason is not None
        or dependency_compile_result.returncode != 0
    ):
        raise_process_failure(
            "snapshot dependency compilation",
            dependency_compile_result,
            dependency_compile_result.failure_reason
            or f"exit={dependency_compile_result.returncode}",
        )
    regular_tree_files(deps_path)
    freeze_regular_directory_tree(deps_path, label="fixture dependency tree")
    dependency_proof = capture_tree_proof(deps_path)
    validate_fixture_snapshot(
        snapshot_root,
        expected_evidence,
        str(expected_evidence["codexVersion"]),
    )
    verify_test_manifest(snapshot_root, snapshot_bundle, test_manifest_path, expected_evidence)

    test_environment = dict(environment, HEX_OFFLINE="1")
    with dependency_source_event_log(
        snapshot_root, excluded_root=runtime_root
    ) as source_events:
        with dependency_source_event_log(deps_path) as dependency_events:
            with dependency_source_event_log(runtime_erlexec) as erlexec_events:
                test_result = run_bounded_process(
                    FIXTURE_TEST_COMMAND,
                    cwd=snapshot_elixir,
                    env=test_environment,
                    deadline_seconds=FIXTURE_CHILD_DEADLINE_SECONDS,
                    max_output_bytes=MAX_CHILD_OUTPUT_BYTES,
                )
    validate_no_mutation_events(source_events, label="snapshot fixture tests")
    validate_no_mutation_events(dependency_events, label="snapshot fixture tests")
    validate_vendored_erlexec_source_events(
        erlexec_events, label="snapshot fixture tests"
    )
    assert_vendored_erlexec_source_proof(runtime_erlexec, erlexec_source_proof)
    output = normalized_process_output(test_result)
    summary = f"{FIXTURE_EXPECTED_TEST_COUNT} tests, 0 failures"
    summary_lines = [line for line in output.splitlines() if re.match(r"^\d+ tests?,", line)]
    has_skipped_or_excluded = re.search(r"\b(?:excluded|skipped)\b", output, re.IGNORECASE)
    if (
        test_result.failure_reason is not None
        or test_result.returncode != 0
        or summary_lines != [summary]
        or has_skipped_or_excluded
    ):
        reason = (
            f"failure={test_result.failure_reason!r}, exit={test_result.returncode}, "
            f"expected exactly one {summary!r} summary, "
            f"found={summary_lines!r}, skipped_or_excluded={bool(has_skipped_or_excluded)}"
        )
        raise_process_failure("snapshot fixture tests", test_result, reason)
    assert_tree_proof(deps_path, dependency_proof)
    validate_fixture_snapshot(
        snapshot_root,
        expected_evidence,
        str(expected_evidence["codexVersion"]),
    )
    verify_test_manifest(snapshot_root, snapshot_bundle, test_manifest_path, expected_evidence)


def run_snapshot_fixture_tests(
    test_manifest: dict[str, Any], expected_evidence: dict[str, Any]
) -> None:
    with fixture_snapshot_workspace() as snapshot_root:
        if snapshot_root.is_relative_to(REPO_ROOT.resolve()):
            raise SchemaError("fixture snapshot must be outside the worktree")
        prepare_fixture_snapshot(snapshot_root, test_manifest, expected_evidence)
        execute_snapshot_fixture_tests(snapshot_root, expected_evidence)


@dataclass(frozen=True)
class TreeProof:
    root_device: int
    root_inode: int
    file_count: int
    sha256: str


@dataclass(frozen=True)
class BundleProof:
    tree: TreeProof
    manifest_sha256: str
    artifact_bundle_sha256: str
    schema_bundle_sha256: str


def capture_tree_proof(root: Path) -> TreeProof:
    identity = directory_identity(root)

    def read_entries() -> list[tuple[str, str, int]]:
        entries: list[tuple[str, str, int]] = []
        for path in regular_tree_files(root):
            content = read_regular_bytes(path)
            entries.append(
                (
                    path.relative_to(root).as_posix(),
                    sha256_bytes(content),
                    len(content),
                )
            )
        return entries

    entries = read_entries()
    if read_entries() != entries:
        raise SchemaError(f"generated bundle tree changed while proving contents: {root}")
    assert_directory_unchanged(root, identity)
    return TreeProof(
        root_device=identity[0],
        root_inode=identity[1],
        file_count=len(entries),
        sha256=sha256_bytes(checksum_stream(entries)),
    )


def assert_tree_proof(root: Path, expected: TreeProof) -> None:
    actual = capture_tree_proof(root)
    if actual != expected:
        raise SchemaError(f"generated bundle tree changed during publication: {root}")


def verify_bundle_proof(bundle: Path, *, require_unsealed: bool) -> BundleProof:
    manifest, _entries = verify_bundle(bundle, require_fixture_seal=False)
    if require_unsealed and manifest.get("compatibility", {}).get("fixtures") != "not_run":
        raise SchemaError("newly generated staging bundle must be unsealed")
    proof = BundleProof(
        tree=capture_tree_proof(bundle),
        manifest_sha256=sha256_file(bundle / "manifest.json"),
        artifact_bundle_sha256=str(
            manifest.get("artifacts", {}).get("artifactBundleSha256", "")
        ),
        schema_bundle_sha256=str(
            manifest.get("artifacts", {}).get("schemaBundleSha256", "")
        ),
    )
    return proof


def assert_bundle_proof(
    bundle: Path, expected: BundleProof, *, require_unsealed: bool
) -> None:
    actual = verify_bundle_proof(bundle, require_unsealed=require_unsealed)
    if actual != expected:
        raise SchemaError(f"verified generated bundle changed during publication: {bundle}")


def fsync_regular_tree(root: Path) -> None:
    files = regular_tree_files(root)
    directories = {root}
    for path in files:
        fsync_file(path)
        parent = path.parent
        while parent != root:
            directories.add(parent)
            parent = parent.parent
    for directory in sorted(directories, key=lambda path: len(path.parts), reverse=True):
        fsync_directory(directory)


def remove_transaction_tree(path: Path) -> None:
    if path_kind_no_follow(path) != "directory":
        raise SchemaError(f"schema transaction residue is not a directory: {path}")
    identity = directory_identity(path)
    regular_tree_files(path)
    if directory_identity(path) != identity:
        raise SchemaError(f"schema transaction residue changed before cleanup: {path}")
    cleanup_snapshot_directory(path)
    fsync_directory(path.parent)


def publication_checkpoint(_name: str) -> None:
    """No-op seam used by child-process crash-recovery tests."""


def recover_generated_bundle(destination: Path, staging: Path, backup: Path) -> None:
    states = {
        "destination": path_kind_no_follow(destination),
        "staging": path_kind_no_follow(staging),
        "backup": path_kind_no_follow(backup),
    }
    invalid = {name: kind for name, kind in states.items() if kind not in {None, "directory"}}
    if invalid:
        raise SchemaError(f"unsafe generated-bundle transaction residue: {invalid}")

    destination_present = states["destination"] == "directory"
    staging_present = states["staging"] == "directory"
    backup_present = states["backup"] == "directory"

    if destination_present and staging_present and backup_present:
        raise SchemaError("ambiguous generated-bundle transaction state; preserving all copies")

    if destination_present:
        if backup_present:
            # A backup means a candidate crossed the commit boundary. Only a
            # currently valid candidate may finish that interrupted cleanup.
            verify_bundle_proof(destination, require_unsealed=True)
            remove_transaction_tree(backup)
        if staging_present:
            # Never discard the only recoverable candidate beside a corrupt or
            # attacker-replaced authoritative destination.
            verify_bundle_proof(destination, require_unsealed=False)
            remove_transaction_tree(staging)
        return

    if backup_present:
        backup_proof = verify_bundle_proof(backup, require_unsealed=False)
        secure_rename(backup, destination)
        fsync_directory(destination.parent)
        assert_bundle_proof(destination, backup_proof, require_unsealed=False)
        if staging_present:
            remove_transaction_tree(staging)
        return

    if staging_present:
        remove_transaction_tree(staging)


def publish_generated_bundle(
    staging: Path,
    destination: Path,
    backup: Path,
    candidate_proof: BundleProof,
) -> None:
    assert_bundle_proof(staging, candidate_proof, require_unsealed=True)
    if path_kind_no_follow(backup) is not None:
        raise SchemaError(f"schema backup path must be absent before publication: {backup}")

    old_proof = (
        verify_bundle_proof(destination, require_unsealed=False)
        if path_kind_no_follow(destination) == "directory"
        else None
    )
    candidate_installed = False
    try:
        if old_proof is not None:
            secure_rename(destination, backup)
            fsync_directory(destination.parent)
            assert_bundle_proof(backup, old_proof, require_unsealed=False)
            publication_checkpoint("destination_preserved")

        secure_rename(staging, destination)
        candidate_installed = True
        fsync_directory(destination.parent)
        publication_checkpoint("candidate_installed")
        assert_bundle_proof(destination, candidate_proof, require_unsealed=True)
        publication_checkpoint("candidate_verified")
    except BaseException:
        if candidate_installed:
            observed = capture_tree_proof(destination)
            if observed != candidate_proof.tree:
                raise SchemaError(
                    "refusing stale generated-bundle rollback because destination changed"
                )
            if path_kind_no_follow(staging) is not None:
                raise SchemaError("refusing generated-bundle rollback over unexpected staging")
            secure_rename(destination, staging)
            fsync_directory(destination.parent)
            publication_checkpoint("failed_candidate_moved")

        if old_proof is not None:
            if path_kind_no_follow(backup) != "directory":
                raise SchemaError("generated-bundle backup disappeared before rollback")
            secure_rename(backup, destination)
            fsync_directory(destination.parent)
            assert_bundle_proof(destination, old_proof, require_unsealed=False)
            publication_checkpoint("backup_restored")

        if path_kind_no_follow(staging) == "directory":
            remove_transaction_tree(staging)
        raise

    # Candidate verification is the commit point. Cleanup failure leaves a
    # valid destination plus a recoverable backup and must never roll back it.
    if old_proof is not None:
        assert_bundle_proof(destination, candidate_proof, require_unsealed=True)
        remove_transaction_tree(backup)
    publication_checkpoint("backup_deleted")


def generate(args: argparse.Namespace) -> None:
    validate_iso_date(args.tested_at)
    version = read_version()
    destination = SCHEMA_ROOT / version
    staging = SCHEMA_ROOT / f".{version}.staging"
    backup = SCHEMA_ROOT / f".{version}.backup"
    mkdir_parents_no_follow(SCHEMA_ROOT)
    recover_generated_bundle(destination, staging, backup)
    launcher, native, lock, selected = installed_codex(args.codex)

    with tempfile.TemporaryDirectory(
        prefix="symphony-codex-schema-", dir=LOCK_ROOT.parent
    ) as temporary:
        temporary_root = Path(temporary)
        bundle = temporary_root / "bundle"
        bundle.mkdir()
        run_generators(launcher, native, bundle, selected)
        copy_regular_file(MATRIX_SOURCE, bundle / "method-field-matrix.json")
        entries = artifact_entries(bundle)
        validate_matrix(bundle, read_json(bundle / "method-field-matrix.json"))
        preserve_equal_generated_json(destination, bundle)
        entries = artifact_entries(bundle)
        write_bytes_fsync(
            bundle / "SEMANTIC-SHA256SUMS", checksum_stream(entries), create=True
        )
        write_json_fsync(
            bundle / "manifest.json",
            build_manifest(bundle, entries, lock, selected, args.tested_at),
            create=True,
        )
        verify_bundle(bundle, require_fixture_seal=False)
        if path_kind_no_follow(staging) is not None or path_kind_no_follow(backup) is not None:
            raise SchemaError("generated-bundle transaction paths were not clean after recovery")
        with anchored_parent(staging) as (parent, name):
            os.mkdir(name, 0o700, dir_fd=parent)
        source_proof = capture_tree_proof(bundle)
        copy_regular_tree(bundle, staging)
        assert_tree_proof(bundle, source_proof)
        staging_proof = verify_bundle_proof(staging, require_unsealed=True)
        fsync_regular_tree(staging)
        fsync_directory(SCHEMA_ROOT)
        assert_bundle_proof(staging, staging_proof, require_unsealed=True)
        publication_checkpoint("staging_fsynced")
        publish_generated_bundle(staging, destination, backup, staging_proof)

    print(f"generated Codex schema bundle {version} at {destination}")


def verify_bundle(
    bundle: Path,
    *,
    require_fixture_seal: bool = True,
    manifest_path: Path | None = None,
    allow_fixture_candidate: bool = False,
    allow_legacy_fixture_only_seal_source: bool = False,
    repo_root: Path | None = None,
) -> tuple[dict[str, Any], list[tuple[str, str, int]]]:
    repo_root = repo_root or REPO_ROOT
    version_file = repo_root / "CODEX_VERSION"
    lock_file = repo_root / "CODEX_LOCK.json"
    matrix_source = repo_root / "scripts" / "codex_schema_matrix.json"
    packaged_version_file = repo_root / "elixir" / "priv" / "codex_schema" / "CODEX_VERSION"
    reject_reserved_manifest_residue(bundle)
    validate_bundle_root_shape(bundle)
    manifest_path = manifest_path or bundle / "manifest.json"
    regular_file_identity(manifest_path)
    manifest = read_json(manifest_path)
    if set(manifest) != MANIFEST_TOP_LEVEL_KEYS:
        missing = sorted(MANIFEST_TOP_LEVEL_KEYS - set(manifest))
        extra = sorted(set(manifest) - MANIFEST_TOP_LEVEL_KEYS)
        raise SchemaError(f"manifest root keys mismatch; missing={missing}, extra={extra}")
    matrix = read_json(bundle / "method-field-matrix.json")
    entries = artifact_entries(bundle)
    validate_matrix(bundle, matrix)
    expected_sums = checksum_stream(entries)
    regular_file_identity(bundle / "SEMANTIC-SHA256SUMS")
    actual_sums = read_regular_bytes(bundle / "SEMANTIC-SHA256SUMS")
    if actual_sums != expected_sums:
        raise SchemaError("SEMANTIC-SHA256SUMS does not match generated artifacts")

    lock = read_json(lock_file)
    regular_file_identity(packaged_version_file)
    version = read_version(version_file)
    if read_regular_bytes(packaged_version_file).decode("utf-8").strip() != version:
        raise SchemaError("packaged Codex version does not match root CODEX_VERSION")
    if manifest.get("codex", {}).get("version") != version:
        raise SchemaError("manifest Codex version does not match CODEX_VERSION")
    if manifest.get("codex", {}).get("npmIntegrity") != lock.get("npmIntegrity"):
        raise SchemaError("manifest package integrity does not match CODEX_LOCK.json")
    if manifest.get("matrix", {}).get("sha256") != sha256_file(bundle / "method-field-matrix.json"):
        raise SchemaError("manifest matrix checksum mismatch")
    if sha256_file(matrix_source) != sha256_file(bundle / "method-field-matrix.json"):
        raise SchemaError("committed bundle matrix differs from scripts/codex_schema_matrix.json")

    target = manifest.get("codex", {}).get("executable", {}).get("target")
    selected = next(
        (candidate for candidate in lock.get("platforms", []) if candidate.get("target") == target),
        None,
    )
    if selected is None:
        raise SchemaError(f"manifest executable target is absent from CODEX_LOCK.json: {target}")

    expected_artifacts = build_manifest(
        bundle,
        entries,
        lock,
        selected,
        manifest.get("generation", {}).get("generatedAt", ""),
    )
    for key in ("manifestVersion", "codex", "generation", "matrix"):
        if manifest.get(key) != expected_artifacts[key]:
            raise SchemaError(f"manifest {key} does not match the reproducible record")
    if manifest.get("artifacts") != expected_artifacts["artifacts"]:
        raise SchemaError("manifest artifact counts or checksums do not match the committed bundle")
    validate_compatibility(
        manifest,
        require_fixture_seal=require_fixture_seal,
        allow_fixture_candidate=allow_fixture_candidate,
        allow_legacy_fixture_only_seal_source=allow_legacy_fixture_only_seal_source,
        repo_root=repo_root,
    )

    metadata = read_regular_bytes(manifest_path).decode("utf-8") + read_regular_bytes(
        bundle / "method-field-matrix.json"
    ).decode("utf-8")
    forbidden = ("/home/", "\\Users\\", "sk-proj-", "sk_live_", "Bearer ")
    found = [needle for needle in forbidden if needle in metadata]
    if found:
        raise SchemaError(f"forbidden local/secret-like metadata found: {found}")
    return manifest, entries


def verify_test_manifest(
    snapshot_root: Path,
    bundle: Path,
    manifest_path: Path,
    expected_evidence: dict[str, Any],
) -> tuple[dict[str, Any], list[tuple[str, str, int]]]:
    manifest, entries = verify_bundle(
        bundle,
        manifest_path=manifest_path,
        allow_fixture_candidate=True,
        repo_root=snapshot_root,
    )
    compatibility = manifest.get("compatibility", {})
    if compatibility.get("fixtures") != "under_test":
        raise SchemaError("fixture test manifest must retain under_test status")
    if compatibility.get("fixtureEvidence") != expected_evidence:
        raise SchemaError("fixture test manifest evidence differs from the pre-test record")
    return manifest, entries


def seal_fixtures(args: argparse.Namespace) -> None:
    tested_at = validate_iso_date(args.tested_at)
    bundle = SCHEMA_ROOT / read_version()
    bundle_identity = directory_identity(bundle)
    manifest_path = bundle / "manifest.json"
    manifest, _entries = verify_bundle(
        bundle,
        require_fixture_seal=False,
        allow_legacy_fixture_only_seal_source=True,
    )
    assert_directory_unchanged(bundle, bundle_identity)
    committed_identity = regular_file_identity(manifest_path)
    original_manifest = read_regular_bytes(manifest_path)
    committed_digest = sha256_bytes(original_manifest)
    assert_file_unchanged(manifest_path, committed_identity, committed_digest)
    if read_json(manifest_path) != manifest:
        raise SchemaError("committed schema manifest changed after initial verification")
    test_manifest = build_test_manifest(build_unsealed_manifest(manifest), tested_at)
    test_evidence = test_manifest["compatibility"]["fixtureEvidence"]
    run_snapshot_fixture_tests(test_manifest, test_evidence)

    assert_directory_unchanged(bundle, bundle_identity)
    assert_file_unchanged(manifest_path, committed_identity, committed_digest)
    fresh_manifest, _entries = verify_bundle(
        bundle,
        require_fixture_seal=False,
        allow_legacy_fixture_only_seal_source=True,
    )
    assert_directory_unchanged(bundle, bundle_identity)
    fresh_unsealed_manifest = build_unsealed_manifest(fresh_manifest)
    publication_manifest = build_sealed_manifest(fresh_unsealed_manifest, tested_at)
    if publication_manifest["compatibility"]["fixtureEvidence"] != test_evidence:
        raise SchemaError("fixture-bound sources or schema artifacts changed while tests ran")

    with tempfile.TemporaryDirectory(
        prefix=".symphony-schema-publish-", dir=REPO_ROOT.parent
    ) as temporary:
        publication_root = Path(temporary).resolve()
        if publication_root.is_relative_to(REPO_ROOT.resolve()):
            raise SchemaError("schema publication temporary directory must be outside the worktree")
        if publication_root.stat().st_dev != bundle_identity[0]:
            raise SchemaError("schema publication temporary directory is not on the bundle filesystem")

        publication_path = publication_root / "manifest.json"
        write_json_fsync(
            publication_path,
            fresh_unsealed_manifest,
            create=True,
        )
        write_json_fsync(publication_path, publication_manifest, create=False)
        verify_bundle(bundle, manifest_path=publication_path)
        verified_identity = regular_file_identity(publication_path)
        verified_digest = sha256_file(publication_path)
        fsync_file(publication_path)
        assert_file_unchanged(publication_path, verified_identity, verified_digest)
        assert_directory_unchanged(bundle, bundle_identity)
        replaced = False
        published_identity = verified_identity
        published_bundle_identity = bundle_identity
        try:
            assert_directory_unchanged(bundle, bundle_identity)
            # The external process lock is the write-serialization contract.
            # Exchange also preserves the displaced entry so a writer in the
            # final check/rename interval can be detected and restored.
            assert_file_unchanged(manifest_path, committed_identity, committed_digest)
            secure_exchange(publication_path, manifest_path)
            replaced = True
            fsync_directory(publication_root)
            fsync_directory(bundle)
            assert_directory_same_object(bundle, bundle_identity)
            published_bundle_identity = directory_identity(bundle)
            observed_identity = regular_file_identity(manifest_path)
            if (
                rename_stable_file_identity(observed_identity)
                != rename_stable_file_identity(verified_identity)
                or sha256_file(manifest_path) != verified_digest
            ):
                raise SchemaError("published schema manifest differs from the verified candidate")
            published_identity = observed_identity

            try:
                displaced_identity = regular_file_identity(publication_path)
                displaced_matches = (
                    rename_stable_file_identity(displaced_identity)
                    == rename_stable_file_identity(committed_identity)
                    and sha256_file(publication_path) == committed_digest
                )
            except SchemaError:
                displaced_matches = False
            if not displaced_matches:
                # The installed candidate is still exact, so exchange back
                # before raising. This restores any regular file or symlink
                # that a non-locking writer placed at the destination.
                assert_file_unchanged(manifest_path, published_identity, verified_digest)
                secure_exchange(publication_path, manifest_path)
                replaced = False
                fsync_directory(publication_root)
                fsync_directory(bundle)
                restored_candidate = regular_file_identity(publication_path)
                if (
                    rename_stable_file_identity(restored_candidate)
                    != rename_stable_file_identity(verified_identity)
                    or sha256_file(publication_path) != verified_digest
                ):
                    raise SchemaError(
                        "schema manifest race rollback did not preserve the verified candidate"
                    )
                raise SchemaError(
                    "non-locking schema manifest write raced publication; displaced writer restored"
                )
            assert_directory_unchanged(bundle, published_bundle_identity)
            assert_file_unchanged(manifest_path, published_identity, verified_digest)
            verify_bundle(bundle)
            assert_directory_unchanged(bundle, published_bundle_identity)
        except BaseException:
            if replaced:
                restore_manifest(
                    manifest_path,
                    original_manifest,
                    publication_root,
                    bundle,
                    published_bundle_identity,
                    published_identity,
                    verified_digest,
                )
            raise

    print(f"sealed Codex fixture evidence for {read_version()} at {tested_at}")


def verify(args: argparse.Namespace) -> None:
    version = read_version()
    bundle = SCHEMA_ROOT / version
    manifest, entries = verify_bundle(bundle)
    if manifest["compatibility"]["runtimeCapabilities"] != "not_run":
        try:
            import studio_readiness

            studio_readiness.verify_repository_pair(
                REPO_ROOT,
                REPO_ROOT / READINESS_RELATIVE,
                args.codex,
            )
        except (ImportError, AttributeError) as error:
            raise SchemaError(
                "paired runtime compatibility cannot load the readiness verifier"
            ) from error
        except studio_readiness.ReadinessError as error:
            raise SchemaError(f"implementation-readiness pair verification failed: {error}") from error
    if args.installed:
        installed_codex(args.codex)
    print(
        f"verified Codex schema bundle {version}: {len(entries)} files, "
        f"{manifest['artifacts']['artifactBundleSha256']}"
    )


def verify_source_bound_prepublication(args: argparse.Namespace) -> None:
    """Verify current staged source, schema, and installed Codex before publication.

    The previously published runtime pair is intentionally outside this command's
    contract: publication replaces that pair only after the complete gate succeeds.
    """

    version = read_version()
    bundle = SCHEMA_ROOT / version
    manifest, entries = verify_bundle(bundle)
    try:
        import studio_readiness

        _static, _matrix, source_manifest = studio_readiness.collect_static_basis(
            REPO_ROOT, args.codex
        )
    except (ImportError, AttributeError) as error:
        raise SchemaError(
            "source-bound prepublication verification cannot load the readiness verifier"
        ) from error
    except studio_readiness.ReadinessError as error:
        raise SchemaError(
            f"source-bound prepublication verification failed: {error}"
        ) from error
    if source_manifest != manifest:
        raise SchemaError(
            "source-bound prepublication schema differs from the verified bundle"
        )
    print(
        f"verified source-bound prepublication Codex schema bundle {version}: "
        f"{len(entries)} files, {manifest['artifacts']['artifactBundleSha256']}"
    )


def regenerate_check(args: argparse.Namespace) -> None:
    version = read_version()
    committed = SCHEMA_ROOT / version
    _manifest, expected_entries = verify_bundle(committed)
    launcher, native, _lock, selected = installed_codex(args.codex)

    with tempfile.TemporaryDirectory(prefix="symphony-codex-schema-check-") as temporary:
        temporary_root = Path(temporary)
        regenerated = temporary_root / "bundle"
        regenerated.mkdir()
        run_generators(launcher, native, regenerated, selected)
        actual_entries = artifact_entries(regenerated)
        expected = [(path, digest) for path, digest, _size in expected_entries]
        actual = [(path, digest) for path, digest, _size in actual_entries]
        if actual != expected:
            expected_map = dict(expected)
            actual_map = dict(actual)
            changed = sorted(
                path for path in expected_map.keys() | actual_map.keys() if expected_map.get(path) != actual_map.get(path)
            )
            preview = ", ".join(changed[:20])
            raise SchemaError(f"regenerated schema differs in {len(changed)} files: {preview}")

    print(f"regenerated Codex schema bundle {version} matches committed semantic/raw checksums")


def schema_lock_name(repo_root: Path) -> str:
    directory_identity(repo_root)
    canonical_root = str(lexical_absolute(repo_root)).encode("utf-8")
    return f"{sha256_bytes(canonical_root)}.lock"


@contextmanager
def schema_bundle_lock(*, exclusive: bool, repo_root: Path | None = None):
    repo_root = repo_root or REPO_ROOT
    mkdir_parents_no_follow(LOCK_ROOT, mode=0o700)
    with anchored_descriptor(LOCK_ROOT, directory=True) as root_descriptor:
        root_metadata = os.fstat(root_descriptor)
        if (
            not stat.S_ISDIR(root_metadata.st_mode)
            or root_metadata.st_uid != os.geteuid()
        ):
            raise SchemaError("schema lock directory is not a private owner-controlled directory")
        os.fchmod(root_descriptor, 0o700)
        lock_descriptor = os.open(
            schema_lock_name(repo_root),
            os.O_RDWR
            | os.O_CREAT
            | os.O_CLOEXEC
            | os.O_NOFOLLOW,
            0o600,
            dir_fd=root_descriptor,
        )
        try:
            lock_metadata = os.fstat(lock_descriptor)
            if (
                not stat.S_ISREG(lock_metadata.st_mode)
                or lock_metadata.st_uid != os.geteuid()
                or lock_metadata.st_nlink != 1
            ):
                raise SchemaError("schema process lock is not a private regular file")
            os.fchmod(lock_descriptor, 0o600)
            lock_root_identity = stable_directory_link_identity(os.fstat(root_descriptor))
            fcntl.flock(lock_descriptor, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
            try:
                locked_root_metadata = os.fstat(root_descriptor)
                if (
                    stable_directory_link_identity(locked_root_metadata) != lock_root_identity
                    or stat.S_IMODE(locked_root_metadata.st_mode) != 0o700
                ):
                    raise SchemaError("schema lock directory changed before lock acquisition")
                yield
                locked_root_metadata = os.fstat(root_descriptor)
                if (
                    stable_directory_link_identity(locked_root_metadata) != lock_root_identity
                    or stat.S_IMODE(locked_root_metadata.st_mode) != 0o700
                ):
                    raise SchemaError("schema lock directory changed while lock was held")
            finally:
                fcntl.flock(lock_descriptor, fcntl.LOCK_UN)
        finally:
            os.close(lock_descriptor)


def pretty_json_bytes(value: Any) -> bytes:
    try:
        return (
            json.dumps(value, allow_nan=False, ensure_ascii=False, indent=2, sort_keys=True)
            + "\n"
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        raise SchemaError(f"readiness transaction value is not canonical JSON: {error}") from error


def _git_transaction_command(
    repo_root: Path,
    arguments: list[str],
    *,
    index_file: Path | None = None,
    input_bytes: bytes | None = None,
) -> bytes:
    # Git plumbing is part of the publication boundary. Inheriting the runner's
    # environment would expose credentials to ambient helpers such as an
    # injected core.fsmonitor and would let those helpers rewrite the index.
    # Keep only the executable search path and deterministic process settings;
    # command-line config then overrides even repository-local helper config.
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
    if index_file is not None:
        environment["GIT_INDEX_FILE"] = str(lexical_absolute(index_file))
    try:
        run_options: dict[str, Any] = {
            "cwd": repo_root,
            "env": environment,
            "stdout": subprocess.PIPE,
            "stderr": subprocess.PIPE,
            "check": False,
            "timeout": 60,
        }
        if input_bytes is None:
            run_options["stdin"] = subprocess.DEVNULL
        else:
            run_options["input"] = input_bytes
        result = subprocess.run(
            [
                "git",
                "-c",
                "core.fsmonitor=false",
                "-c",
                "core.hooksPath=/dev/null",
                *arguments,
            ],
            **run_options,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SchemaError(f"readiness Git command failed safely: {arguments[0]}: {error}") from error
    if len(result.stdout) > 8 * 1024 * 1024 or len(result.stderr) > 8 * 1024 * 1024:
        raise SchemaError(f"readiness Git command output exceeded its bound: {arguments[0]}")
    if result.returncode != 0:
        diagnostic = result.stderr.decode("utf-8", errors="replace").strip()[:512]
        raise SchemaError(
            f"readiness Git command failed ({result.returncode}) for {arguments[0]}: {diagnostic}"
        )
    return result.stdout


def _git_transaction_text(
    repo_root: Path, arguments: list[str], *, index_file: Path | None = None
) -> str:
    try:
        value = _git_transaction_command(
            repo_root, arguments, index_file=index_file
        ).decode("ascii", errors="strict").strip()
    except UnicodeDecodeError as error:
        raise SchemaError(f"readiness Git output is not ASCII: {arguments[0]}") from error
    if not value:
        raise SchemaError(f"readiness Git command returned an empty value: {arguments[0]}")
    return value


def _git_index_paths(repo_root: Path) -> tuple[Path, Path, Path]:
    index = Path(
        _git_transaction_text(
            repo_root, ["rev-parse", "--path-format=absolute", "--git-path", "index"]
        )
    )
    index = lexical_absolute(index)
    if not index.is_absolute():
        raise SchemaError("Git index path is not absolute")
    index_parent = index.parent
    with anchored_descriptor(index_parent, directory=True) as descriptor:
        parent_metadata = os.fstat(descriptor)
        parent_mode = stat.S_IMODE(parent_metadata.st_mode)
        if (
            parent_metadata.st_uid != os.geteuid()
            or parent_metadata.st_gid != os.getegid()
            or parent_mode & 0o022
        ):
            raise SchemaError("Git index parent is not owner controlled")
    _git_index_file_metadata(index)
    lock = Path(f"{index}.lock")
    transaction = index_parent / READINESS_TRANSACTION_DIRECTORY
    return index, lock, transaction


def _git_index_file_metadata(path: Path) -> tuple[int, int]:
    """Validate and return the exact mode/group of an index-state file."""

    with anchored_descriptor(path, directory=False) as descriptor:
        metadata = os.fstat(descriptor)
        mode = stat.S_IMODE(metadata.st_mode)
        if metadata.st_uid != os.geteuid() or metadata.st_gid != os.getegid():
            raise SchemaError("Git index state is not owned by the current operator")
        if metadata.st_nlink != 1:
            raise SchemaError("Git index state must have exactly one link")
        if (
            mode & 0o700 != 0o600
            or mode & 0o002
            or mode & 0o111
            or mode & 0o7000
        ):
            raise SchemaError("Git index state has unsafe permissions")
        return mode, metadata.st_gid


def _set_git_index_file_mode(path: Path, mode: int, gid: int) -> None:
    """Preserve accepted index metadata despite the process umask."""

    descriptor = open_regular_descriptor_no_follow(path, writable=True)
    try:
        metadata = os.fstat(descriptor)
        if (
            metadata.st_uid != os.geteuid()
            or metadata.st_gid != gid
            or metadata.st_nlink != 1
        ):
            raise SchemaError("readiness candidate index metadata changed")
        os.fchmod(descriptor, mode)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    if _git_index_file_metadata(path) != (mode, gid):
        raise SchemaError("readiness candidate index mode was not preserved")


def _assert_git_index_file_metadata(
    path: Path, journal: dict[str, Any], label: str
) -> None:
    expected = (journal["indexMode"], journal["indexGid"])
    if _git_index_file_metadata(path) != expected:
        raise SchemaError(f"readiness {label} index metadata changed")


def _git_index_tree(repo_root: Path, *, index_file: Path | None = None) -> str:
    value = _git_transaction_text(repo_root, ["write-tree"], index_file=index_file)
    if not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", value):
        raise SchemaError("Git index tree is not a supported object ID")
    return value


def _git_index_entries_sha256(
    repo_root: Path, *, index_file: Path | None = None
) -> str:
    """Hash the staged paths, modes, object IDs, stages, and index flags."""

    return sha256_bytes(
        _git_transaction_command(
            repo_root,
            ["ls-files", "--stage", "-v", "-z"],
            index_file=index_file,
        )
    )


def _git_blob(repo_root: Path, payload: bytes) -> str:
    value = _git_transaction_command(
        repo_root, ["hash-object", "-w", "--stdin"], input_bytes=payload
    ).decode("ascii", errors="strict").strip()
    if not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", value):
        raise SchemaError("Git hash-object returned an invalid object ID")
    return value


def _indexed_mode(repo_root: Path, relative: str) -> str:
    output = _git_transaction_command(
        repo_root, ["ls-files", "--stage", "--", relative]
    ).decode("utf-8", errors="strict").strip()
    if not output:
        return "100644"
    lines = output.splitlines()
    if len(lines) != 1:
        raise SchemaError(f"Git index contains an ambiguous entry for {relative}")
    match = re.fullmatch(r"(100644|100755) [0-9a-f]+ 0\t(.+)", lines[0])
    if match is None or match.group(2) != relative:
        raise SchemaError(f"Git index contains an invalid entry for {relative}")
    return match.group(1)


def _unlink_regular_exact(path: Path, expected_sha256: str) -> None:
    if path_kind_no_follow(path) is None:
        return
    if path_kind_no_follow(path) != "file" or sha256_file(path) != expected_sha256:
        raise SchemaError(f"refusing to remove changed readiness transaction file: {path}")
    with anchored_parent(path) as (parent, name):
        os.unlink(name, dir_fd=parent)
    fsync_directory(path.parent)


def _transaction_digest(value: Any, label: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise SchemaError(f"readiness transaction {label} is not a lowercase SHA-256")
    return value


def _read_readiness_journal(
    transaction: Path, repo_root: Path
) -> dict[str, Any]:
    journal = read_json(transaction / "journal.json")
    expected_keys = {
        "candidateIndexEntriesSha256",
        "candidateIndexSha256",
        "candidateIndexTree",
        "candidateReadinessSha256",
        "candidateSchemaSha256",
        "indexGid",
        "indexMode",
        "originalIndexSha256",
        "originalIndexTree",
        "originalReadinessSha256",
        "originalSchemaSha256",
        "readinessPath",
        "schemaPath",
        "transactionVersion",
    }
    if not isinstance(journal, dict) or set(journal) != expected_keys:
        raise SchemaError("readiness transaction journal has unexpected or missing keys")
    if journal["transactionVersion"] != READINESS_TRANSACTION_VERSION:
        raise SchemaError("readiness transaction journal version is unsupported")
    if (
        not isinstance(journal["indexMode"], int)
        or isinstance(journal["indexMode"], bool)
        or not isinstance(journal["indexGid"], int)
        or isinstance(journal["indexGid"], bool)
        or journal["indexGid"] < 0
    ):
        raise SchemaError("readiness transaction index metadata is invalid")
    mode = journal["indexMode"]
    if mode & 0o700 != 0o600 or mode & 0o002 or mode & 0o111 or mode & 0o7000:
        raise SchemaError("readiness transaction index mode is unsafe")
    version = read_version(repo_root / "CODEX_VERSION")
    expected_schema = f"elixir/priv/codex_schema/{version}/manifest.json"
    if journal["schemaPath"] != expected_schema or journal["readinessPath"] != READINESS_RELATIVE:
        raise SchemaError("readiness transaction journal paths differ from the repository contract")
    for key in (
        "candidateIndexEntriesSha256",
        "candidateIndexSha256",
        "candidateReadinessSha256",
        "candidateSchemaSha256",
        "originalIndexSha256",
        "originalSchemaSha256",
    ):
        _transaction_digest(journal[key], key)
    original_readiness = journal["originalReadinessSha256"]
    if original_readiness is not None:
        _transaction_digest(original_readiness, "originalReadinessSha256")
    for key in ("candidateIndexTree", "originalIndexTree"):
        if not isinstance(journal[key], str) or not re.fullmatch(
            r"(?:[0-9a-f]{40}|[0-9a-f]{64})", journal[key]
        ):
            raise SchemaError(f"readiness transaction {key} is not a Git tree ID")
    return journal


def _private_transaction_identity(transaction: Path) -> Identity:
    with anchored_descriptor(transaction, directory=True) as descriptor:
        metadata = os.fstat(descriptor)
        if metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
            raise SchemaError(
                "readiness transaction directory is not private and owner controlled"
            )
        return metadata_identity(metadata)


def _assert_private_transaction_same_object(
    transaction: Path, identity: Identity
) -> None:
    with anchored_descriptor(transaction, directory=True) as descriptor:
        metadata = os.fstat(descriptor)
        if (
            stable_directory_link_identity(metadata)
            != (identity[0], identity[1], identity[6])
            or metadata.st_uid != os.geteuid()
            or stat.S_IMODE(metadata.st_mode) != 0o700
        ):
            raise SchemaError("readiness transaction directory changed during recovery")


def _verification_record(journal: dict[str, Any]) -> dict[str, Any]:
    return {
        "candidateIndexEntriesSha256": journal["candidateIndexEntriesSha256"],
        "candidateIndexSha256": journal["candidateIndexSha256"],
        "candidateIndexTree": journal["candidateIndexTree"],
        "candidateReadinessSha256": journal["candidateReadinessSha256"],
        "candidateSchemaSha256": journal["candidateSchemaSha256"],
        "transactionVersion": READINESS_TRANSACTION_VERSION,
    }


def _verification_attempt_record(
    journal: dict[str, Any], candidate_index_sha256: str
) -> dict[str, Any]:
    _transaction_digest(candidate_index_sha256, "verification attempt index")
    return {
        "candidateIndexEntriesSha256": journal["candidateIndexEntriesSha256"],
        "candidateIndexSha256": candidate_index_sha256,
        "candidateIndexTree": journal["candidateIndexTree"],
        "transactionVersion": READINESS_TRANSACTION_VERSION,
    }


def _verification_attempt_index_sha256(
    transaction: Path, journal: dict[str, Any]
) -> str | None:
    """Recover one durable, canonical per-attempt fenced-index digest."""

    marker = transaction / READINESS_VERIFICATION_ATTEMPT
    preparing = transaction / READINESS_VERIFICATION_ATTEMPT_PREPARE
    marker_kind = path_kind_no_follow(marker)
    preparing_kind = path_kind_no_follow(preparing)

    def decode(path: Path) -> tuple[str, bytes]:
        payload = read_regular_bytes(path)
        value = decode_json_bytes(payload, path)
        if not isinstance(value, dict) or set(value) != {
            "candidateIndexEntriesSha256",
            "candidateIndexSha256",
            "candidateIndexTree",
            "transactionVersion",
        }:
            raise SchemaError("readiness verification-attempt record is invalid")
        digest = value["candidateIndexSha256"]
        if value != _verification_attempt_record(journal, digest):
            raise SchemaError("readiness verification-attempt record changed")
        expected = pretty_json_bytes(value)
        if payload != expected:
            raise SchemaError("readiness verification-attempt record is not canonical")
        return digest, expected

    if marker_kind is not None:
        if marker_kind != "file":
            raise SchemaError("readiness verification-attempt record is unsafe")
        digest, expected = decode(marker)
        if preparing_kind is not None:
            if preparing_kind != "file" or read_regular_bytes(preparing) != expected:
                raise SchemaError(
                    "readiness verification-attempt preparation is invalid"
                )
            _unlink_regular_exact(preparing, sha256_bytes(expected))
        return digest
    if preparing_kind is None:
        return None
    if preparing_kind != "file":
        raise SchemaError("readiness verification-attempt preparation is unsafe")
    try:
        digest, expected = decode(preparing)
    except SchemaError:
        payload = read_regular_bytes(preparing)
        _unlink_regular_exact(preparing, sha256_bytes(payload))
        return None
    secure_rename_noreplace(preparing, marker)
    fsync_directory(transaction)
    if read_regular_bytes(marker) != expected:
        raise SchemaError("readiness verification-attempt publication changed")
    return digest


def _replace_verification_attempt(
    transaction: Path,
    journal: dict[str, Any],
    candidate_index_sha256: str,
) -> None:
    existing = _verification_attempt_index_sha256(transaction, journal)
    marker = transaction / READINESS_VERIFICATION_ATTEMPT
    preparing = transaction / READINESS_VERIFICATION_ATTEMPT_PREPARE
    if existing is not None:
        _unlink_regular_exact(marker, sha256_file(marker))
    if path_kind_no_follow(preparing) is not None:
        raise SchemaError("readiness verification-attempt preparation remained")
    payload = pretty_json_bytes(
        _verification_attempt_record(journal, candidate_index_sha256)
    )
    write_bytes_fsync(preparing, payload, create=True)
    secure_rename_noreplace(preparing, marker)
    fsync_directory(transaction)
    if read_regular_bytes(marker) != payload:
        raise SchemaError("readiness verification-attempt publication changed")


def _transaction_is_verified(
    transaction: Path, journal: dict[str, Any]
) -> bool:
    marker = transaction / READINESS_VERIFICATION
    preparing = transaction / READINESS_VERIFICATION_PREPARE
    expected = pretty_json_bytes(_verification_record(journal))
    marker_kind = path_kind_no_follow(marker)
    preparing_kind = path_kind_no_follow(preparing)
    if marker_kind is not None:
        if marker_kind != "file" or read_regular_bytes(marker) != expected:
            raise SchemaError("readiness transaction verification marker is invalid")
        if preparing_kind is not None:
            if preparing_kind != "file" or read_regular_bytes(preparing) != expected:
                raise SchemaError("readiness transaction verification preparation is invalid")
            _unlink_regular_exact(preparing, sha256_bytes(expected))
        return True
    if preparing_kind is None:
        return False
    if preparing_kind != "file":
        raise SchemaError("readiness transaction verification preparation is unsafe")
    prepared = read_regular_bytes(preparing)
    if prepared != expected:
        _unlink_regular_exact(preparing, sha256_bytes(prepared))
        return False
    secure_rename_noreplace(preparing, marker)
    fsync_directory(transaction)
    if read_regular_bytes(marker) != expected:
        raise SchemaError("readiness transaction verification marker is invalid")
    return True


def _read_transaction_payload(
    transaction: Path, name: str, expected_sha256: str
) -> bytes:
    path = transaction / name
    payload = read_regular_bytes(path)
    if sha256_bytes(payload) != expected_sha256:
        raise SchemaError(f"readiness transaction payload changed: {name}")
    return payload


def _install_transaction_payload(
    destination: Path,
    install: Path,
    desired: bytes,
    *,
    allowed_existing: set[str | None],
) -> None:
    desired_digest = sha256_bytes(desired)
    current = read_optional_regular_bytes(destination)
    current_digest = sha256_bytes(current) if current is not None else None
    if current_digest not in allowed_existing:
        raise SchemaError(f"readiness transaction destination changed unexpectedly: {destination}")

    install_payload = read_optional_regular_bytes(install)
    if current_digest == desired_digest:
        if install_payload is not None:
            install_digest = sha256_bytes(install_payload)
            _unlink_regular_exact(install, install_digest)
        return

    if install_payload is not None:
        install_digest = sha256_bytes(install_payload)
        if install_digest != desired_digest:
            _unlink_regular_exact(install, install_digest)
            install_payload = None
    if install_payload is None:
        write_bytes_fsync(install, desired, create=True, mode=0o644)

    if current is None:
        secure_rename_noreplace(install, destination)
    else:
        secure_exchange(install, destination)
        displaced = read_regular_bytes(install)
        if sha256_bytes(displaced) != current_digest:
            secure_exchange(install, destination)
            raise SchemaError("readiness transaction displaced an unexpected destination")
    fsync_directory(destination.parent)
    if read_regular_bytes(destination) != desired:
        raise SchemaError(f"readiness transaction failed to install exact bytes: {destination}")


def _readiness_transaction_locations(
    repo_root: Path,
) -> tuple[Path, Path, Path, Path, Path, Path, Path]:
    version = read_version(repo_root / "CODEX_VERSION")
    schema = repo_root / "elixir" / "priv" / "codex_schema" / version / "manifest.json"
    readiness = repo_root / READINESS_RELATIVE
    mkdir_parents_no_follow(readiness.parent)
    index, index_lock, transaction = _git_index_paths(repo_root)
    schema_install = schema.parent / READINESS_SCHEMA_INSTALL
    readiness_install = readiness.parent / READINESS_ARTIFACT_INSTALL
    return schema, readiness, index, index_lock, transaction, schema_install, readiness_install


def _cleanup_readiness_install_residues(
    schema_install: Path,
    readiness_install: Path,
    journal: dict[str, Any],
) -> None:
    allowed = {
        journal["originalSchemaSha256"],
        journal["candidateSchemaSha256"],
        journal["candidateReadinessSha256"],
        journal["originalReadinessSha256"],
    }
    for residue in (schema_install, readiness_install):
        payload = read_optional_regular_bytes(residue)
        if payload is None:
            continue
        digest = sha256_bytes(payload)
        if digest not in allowed:
            raise SchemaError("readiness transaction cleanup residue changed")
        _unlink_regular_exact(residue, digest)


def _restore_original_readiness_pair(
    schema: Path,
    readiness: Path,
    schema_install: Path,
    readiness_install: Path,
    original_schema: bytes,
    original_readiness: bytes | None,
    journal: dict[str, Any],
) -> None:
    _install_transaction_payload(
        schema,
        schema_install,
        original_schema,
        allowed_existing={
            journal["originalSchemaSha256"],
            journal["candidateSchemaSha256"],
        },
    )
    original_readiness_digest = journal["originalReadinessSha256"]
    if original_readiness is None:
        current = read_optional_regular_bytes(readiness)
        if current is not None:
            digest = sha256_bytes(current)
            if digest != journal["candidateReadinessSha256"]:
                raise SchemaError(
                    "pre-commit readiness destination changed; preserving transaction"
                )
            with anchored_parent(readiness) as (parent, name):
                os.unlink(name, dir_fd=parent)
            fsync_directory(readiness.parent)
    else:
        _install_transaction_payload(
            readiness,
            readiness_install,
            original_readiness,
            allowed_existing={
                original_readiness_digest,
                journal["candidateReadinessSha256"],
            },
        )
    _cleanup_readiness_install_residues(
        schema_install, readiness_install, journal
    )


def _ensure_candidate_readiness_pair(
    schema: Path,
    readiness: Path,
    schema_install: Path,
    readiness_install: Path,
    candidate_schema: bytes,
    candidate_readiness: bytes,
    journal: dict[str, Any],
) -> None:
    _install_transaction_payload(
        schema,
        schema_install,
        candidate_schema,
        allowed_existing={
            journal["originalSchemaSha256"],
            journal["candidateSchemaSha256"],
        },
    )
    _install_transaction_payload(
        readiness,
        readiness_install,
        candidate_readiness,
        allowed_existing={
            journal["originalReadinessSha256"],
            journal["candidateReadinessSha256"],
            None,
        },
    )
    _cleanup_readiness_install_residues(
        schema_install, readiness_install, journal
    )


def _candidate_readiness_pair_is_exact(
    schema: Path,
    readiness: Path,
    candidate_schema: bytes,
    candidate_readiness: bytes,
) -> bool:
    return (
        read_optional_regular_bytes(schema) == candidate_schema
        and read_optional_regular_bytes(readiness) == candidate_readiness
    )


def _candidate_index_is_semantically_exact(
    repo_root: Path,
    index: Path,
    journal: dict[str, Any],
) -> bool:
    """Accept benign stat-cache refreshes but no staged semantic change."""

    return (
        _git_index_file_metadata(index)
        == (journal["indexMode"], journal["indexGid"])
        and _git_index_tree(repo_root, index_file=index)
        == journal["candidateIndexTree"]
        and _git_index_entries_sha256(repo_root, index_file=index)
        == journal["candidateIndexEntriesSha256"]
    )


def _candidate_readiness_state_is_exact(
    repo_root: Path,
    schema: Path,
    readiness: Path,
    index: Path,
    candidate_schema: bytes,
    candidate_readiness: bytes,
    journal: dict[str, Any],
) -> bool:
    return _candidate_readiness_pair_is_exact(
        schema, readiness, candidate_schema, candidate_readiness
    ) and _candidate_index_is_semantically_exact(repo_root, index, journal)


def _fenced_candidate_readiness_state_is_exact(
    schema: Path,
    readiness: Path,
    index: Path,
    candidate_schema: bytes,
    candidate_readiness: bytes,
    journal: dict[str, Any],
    expected_index_sha256: str,
) -> bool:
    """Use the captured raw index only while the conventional fence is held."""

    return (
        _candidate_readiness_pair_is_exact(
            schema, readiness, candidate_schema, candidate_readiness
        )
        and sha256_file(index) == expected_index_sha256
        and _git_index_file_metadata(index)
        == (journal["indexMode"], journal["indexGid"])
    )


def _return_verification_index_fence(
    index: Path,
    index_lock: Path,
    transaction: Path,
    rollback_path: Path,
    journal: dict[str, Any],
) -> None:
    if path_kind_no_follow(index_lock) != "file":
        raise AmbiguousReadinessTransactionError(
            "readiness verification index fence is missing"
        )
    if sha256_file(index_lock) != journal["originalIndexSha256"]:
        raise AmbiguousReadinessTransactionError(
            "readiness verification index fence changed"
        )
    _assert_git_index_file_metadata(index_lock, journal, "verification fence")
    if path_kind_no_follow(rollback_path) is not None:
        raise AmbiguousReadinessTransactionError(
            "duplicate readiness verification rollback index"
        )
    secure_rename_noreplace(index_lock, rollback_path)
    fsync_directory(index.parent)
    fsync_directory(transaction)


def _discard_readiness_verification_index(
    repo_root: Path,
    journal: dict[str, Any],
    transaction: Path,
    *,
    require_candidate_semantics: bool = True,
) -> None:
    """Remove only owner-controlled disposable verifier-index state."""

    verification_index = transaction / READINESS_INDEX_VERIFIER
    verification_lock = Path(f"{verification_index}.lock")
    verification_lock_kind = path_kind_no_follow(verification_lock)
    if verification_lock_kind is not None:
        if verification_lock_kind != "file":
            raise AmbiguousReadinessTransactionError(
                "readiness verification-index lock residue is unsafe"
            )
        verification_lock_metadata = _git_index_file_metadata(verification_lock)
        if require_candidate_semantics and verification_lock_metadata != (
            journal["indexMode"],
            journal["indexGid"],
        ):
            raise SchemaError(
                "readiness private verification-index lock index metadata changed"
            )
        _unlink_regular_exact(verification_lock, sha256_file(verification_lock))
    if path_kind_no_follow(verification_index) is None:
        return
    if path_kind_no_follow(verification_index) != "file":
        raise AmbiguousReadinessTransactionError(
            "readiness verification-index residue is unsafe"
        )
    verification_metadata = _git_index_file_metadata(verification_index)
    if require_candidate_semantics and verification_metadata != (
        journal["indexMode"],
        journal["indexGid"],
    ):
        raise SchemaError(
            "readiness private verification index index metadata changed"
        )
    if require_candidate_semantics and not _candidate_index_is_semantically_exact(
        repo_root, verification_index, journal
    ):
        raise AmbiguousReadinessTransactionError(
            "readiness verification index changed semantically"
        )
    if require_candidate_semantics:
        _assert_git_index_file_metadata(
            verification_index, journal, "private verification index"
        )
    _unlink_regular_exact(verification_index, sha256_file(verification_index))


def _prepare_readiness_verification_index(
    repo_root: Path,
    journal: dict[str, Any],
    transaction: Path,
    expected_live_index_sha256: str,
) -> Path:
    """Copy and semantically validate the fenced live candidate index."""

    _discard_readiness_verification_index(
        repo_root,
        journal,
        transaction,
        require_candidate_semantics=False,
    )
    verification_index = transaction / READINESS_INDEX_VERIFIER
    index, _index_lock, expected_transaction = _git_index_paths(repo_root)
    if expected_transaction != transaction:
        raise SchemaError("readiness verification transaction path changed")
    _assert_git_index_file_metadata(index, journal, "fenced candidate")
    candidate_index = read_regular_bytes(index)
    if sha256_bytes(candidate_index) != expected_live_index_sha256:
        raise AmbiguousReadinessTransactionError(
            "readiness fenced candidate changed before verifier copy"
        )
    write_bytes_fsync(
        verification_index,
        candidate_index,
        create=True,
        mode=journal["indexMode"],
    )
    _set_git_index_file_mode(
        verification_index, journal["indexMode"], journal["indexGid"]
    )
    fsync_directory(transaction)
    _assert_git_index_file_metadata(
        verification_index, journal, "private verification index"
    )
    if (
        sha256_file(verification_index) != expected_live_index_sha256
        or sha256_file(index) != expected_live_index_sha256
    ):
        raise AmbiguousReadinessTransactionError(
            "readiness verification index changed during preparation"
        )
    if not _candidate_index_is_semantically_exact(
        repo_root, verification_index, journal
    ):
        raise AmbiguousReadinessTransactionError(
            "readiness fenced candidate changed semantically"
        )
    if sha256_file(index) != expected_live_index_sha256:
        raise AmbiguousReadinessTransactionError(
            "readiness fenced candidate changed during semantic validation"
        )
    _replace_verification_attempt(
        transaction, journal, expected_live_index_sha256
    )
    readiness_publication_checkpoint("verification_index_prepared")
    return verification_index


def _acquire_verification_index_fence(
    repo_root: Path,
    journal: dict[str, Any],
    locations: tuple[Path, Path, Path, Path, Path, Path, Path],
) -> str:
    """Fence the exact committed candidate before any final verifier Git call."""

    (
        schema,
        readiness,
        index,
        index_lock,
        transaction,
        _schema_install,
        _readiness_install,
    ) = locations
    candidate_schema = _read_transaction_payload(
        transaction, "schema.candidate", journal["candidateSchemaSha256"]
    )
    candidate_readiness = _read_transaction_payload(
        transaction,
        "readiness.candidate",
        journal["candidateReadinessSha256"],
    )
    rollback_index = transaction / READINESS_INDEX_ROLLBACK
    if (
        not _candidate_readiness_state_is_exact(
            repo_root,
            schema,
            readiness,
            index,
            candidate_schema,
            candidate_readiness,
            journal,
        )
        or path_kind_no_follow(index_lock) is not None
        or path_kind_no_follow(rollback_index) != "file"
        or sha256_file(rollback_index) != journal["originalIndexSha256"]
    ):
        raise AmbiguousReadinessTransactionError(
            "readiness publication changed before final verification; "
            "preserving transaction"
        )
    candidate_index_sha256 = sha256_file(index)
    _assert_git_index_file_metadata(rollback_index, journal, "verification rollback")
    secure_rename_noreplace(rollback_index, index_lock)
    fsync_directory(index.parent)
    fsync_directory(transaction)
    readiness_publication_checkpoint("verification_index_fenced")
    _assert_git_index_file_metadata(index_lock, journal, "verification fence")
    if (
        sha256_file(index_lock) != journal["originalIndexSha256"]
        or not _fenced_candidate_readiness_state_is_exact(
            schema,
            readiness,
            index,
            candidate_schema,
            candidate_readiness,
            journal,
            candidate_index_sha256,
        )
    ):
        _return_verification_index_fence(
            index,
            index_lock,
            transaction,
            rollback_index,
            journal,
        )
        raise AmbiguousReadinessTransactionError(
            "readiness publication changed while final verification was fenced; "
            "preserving transaction"
        )
    return candidate_index_sha256


def recover_readiness_transaction(repo_root: Path = REPO_ROOT) -> bool:
    """Recover a transaction and report an unverified committed candidate.

    ``True`` means the exact candidate index/pair crossed the atomic exchange
    but still requires the strongest repository-pair verification. The durable
    journal and original payloads remain present in that state.
    """

    (
        schema,
        readiness,
        index,
        index_lock,
        transaction,
        schema_install,
        readiness_install,
    ) = _readiness_transaction_locations(repo_root)
    preparing = transaction.with_name(f"{transaction.name}.prepare")
    transaction_kind = path_kind_no_follow(transaction)
    preparing_kind = path_kind_no_follow(preparing)
    if transaction_kind is not None and preparing_kind is not None:
        raise SchemaError("ambiguous readiness transaction and preparation residues")
    if transaction_kind is None and preparing_kind is not None:
        if preparing_kind != "directory":
            raise SchemaError("readiness transaction preparation residue is unsafe")
        identity = directory_identity(preparing)
        with anchored_descriptor(preparing, directory=True) as descriptor:
            metadata = os.fstat(descriptor)
            if metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) != 0o700:
                raise SchemaError("readiness transaction preparation residue is not private")
        if directory_identity(preparing) != identity:
            raise SchemaError("readiness transaction preparation residue changed")
        remove_transaction_tree(preparing)
        preparing_kind = None
    if transaction_kind is None:
        residues = [
            path
            for path in (schema_install, readiness_install)
            if path_kind_no_follow(path) is not None
        ]
        if residues:
            raise SchemaError(f"orphan readiness transaction residue is present: {residues}")
        return False
    if transaction_kind != "directory":
        raise SchemaError("readiness transaction residue is not a directory")

    transaction_identity = _private_transaction_identity(transaction)
    journal = _read_readiness_journal(transaction, repo_root)
    original_schema = _read_transaction_payload(
        transaction, "schema.original", journal["originalSchemaSha256"]
    )
    candidate_schema = _read_transaction_payload(
        transaction, "schema.candidate", journal["candidateSchemaSha256"]
    )
    candidate_readiness = _read_transaction_payload(
        transaction, "readiness.candidate", journal["candidateReadinessSha256"]
    )
    original_readiness_digest = journal["originalReadinessSha256"]
    original_readiness = None
    if original_readiness_digest is not None:
        original_readiness = _read_transaction_payload(
            transaction, "readiness.original", original_readiness_digest
        )
    original_index = _read_transaction_payload(
        transaction, "index.original", journal["originalIndexSha256"]
    )
    candidate_index = _read_transaction_payload(
        transaction,
        READINESS_INDEX_CANDIDATE,
        journal["candidateIndexSha256"],
    )
    _assert_git_index_file_metadata(
        transaction / "index.original", journal, "original backup"
    )
    _assert_git_index_file_metadata(
        transaction / READINESS_INDEX_CANDIDATE, journal, "candidate backup"
    )
    if directory_identity(transaction) != transaction_identity:
        raise SchemaError("readiness transaction changed while its journal was read")
    verified = _transaction_is_verified(transaction, journal)
    _assert_private_transaction_same_object(transaction, transaction_identity)

    lock_kind = path_kind_no_follow(index_lock)
    if lock_kind not in (None, "file"):
        raise AmbiguousReadinessTransactionError(
            "ambiguous readiness index lock; preserving transaction"
        )
    index_digest = sha256_file(index)
    lock_digest = sha256_file(index_lock) if lock_kind == "file" else None
    original_digest = journal["originalIndexSha256"]
    candidate_digest = journal["candidateIndexSha256"]
    if index_digest in {original_digest, candidate_digest}:
        _assert_git_index_file_metadata(index, journal, "installed")
    if lock_digest in {original_digest, candidate_digest}:
        _assert_git_index_file_metadata(index_lock, journal, "lock")

    commit_path = transaction / READINESS_INDEX_COMMIT
    commit_kind = path_kind_no_follow(commit_path)
    if commit_kind not in (None, "file"):
        raise SchemaError("readiness commit-index residue is unsafe")
    if commit_kind == "file" and sha256_file(commit_path) != candidate_digest:
        raise SchemaError("readiness commit-index residue changed")
    if commit_kind == "file":
        _assert_git_index_file_metadata(commit_path, journal, "commit")
    rollback_path = transaction / READINESS_INDEX_ROLLBACK
    rollback_kind = path_kind_no_follow(rollback_path)
    if rollback_kind not in (None, "file"):
        raise SchemaError("readiness rollback-index residue is unsafe")
    if rollback_kind == "file" and sha256_file(rollback_path) != original_digest:
        raise SchemaError("readiness rollback-index residue changed")
    if rollback_kind == "file":
        _assert_git_index_file_metadata(rollback_path, journal, "rollback")
    attempt_digest = _verification_attempt_index_sha256(transaction, journal)
    if lock_digest is not None and lock_digest == attempt_digest:
        _assert_git_index_file_metadata(index_lock, journal, "verification attempt")

    if verified:
        if lock_digest == original_digest:
            if rollback_kind is not None:
                raise AmbiguousReadinessTransactionError(
                    "verified readiness has duplicate rollback indexes"
            )
            try:
                exact_pair = _candidate_readiness_pair_is_exact(
                    schema,
                    readiness,
                    candidate_schema,
                    candidate_readiness,
                ) and _git_index_file_metadata(index) == (
                    journal["indexMode"],
                    journal["indexGid"],
                )
            finally:
                _return_verification_index_fence(
                    index,
                    index_lock,
                    transaction,
                    rollback_path,
                    journal,
                )
            rollback_kind = "file"
            if not exact_pair:
                raise AmbiguousReadinessTransactionError(
                    "verified readiness pair changed; preserving transaction"
                )
        elif lock_digest is not None:
            raise AmbiguousReadinessTransactionError(
                "verified readiness index lock changed; preserving transaction"
            )
        if not _candidate_readiness_state_is_exact(
            repo_root,
            schema,
            readiness,
            index,
            candidate_schema,
            candidate_readiness,
            journal,
        ):
            raise AmbiguousReadinessTransactionError(
                "verified readiness candidate changed; preserving transaction"
            )
        if rollback_kind != "file":
            raise AmbiguousReadinessTransactionError(
                "verified readiness rollback index is missing"
            )
        # Recheck after releasing the conventional Git fence. A writer that
        # arrives after this point is a later staged-tree mutation, while a
        # writer that raced the verification boundary retains the durable
        # journal and rollback index for explicit recovery.
        if not _candidate_readiness_state_is_exact(
            repo_root,
            schema,
            readiness,
            index,
            candidate_schema,
            candidate_readiness,
            journal,
        ):
            raise AmbiguousReadinessTransactionError(
                "verified readiness candidate changed after fence release; "
                "preserving transaction"
            )
        _cleanup_readiness_install_residues(
            schema_install, readiness_install, journal
        )
        _assert_private_transaction_same_object(transaction, transaction_identity)
        remove_transaction_tree(transaction)
        return False

    if lock_digest == candidate_digest:
        if index_digest == original_digest:
            _unlink_regular_exact(index_lock, candidate_digest)
            lock_digest = None
        elif index_digest == candidate_digest:
            _unlink_regular_exact(index_lock, candidate_digest)
            lock_digest = None
        else:
            _unlink_regular_exact(index_lock, candidate_digest)
            raise AmbiguousReadinessTransactionError(
                "Git index changed behind the reserved readiness lock; preserving transaction"
            )
    elif lock_digest == original_digest:
        if rollback_kind is not None:
            raise AmbiguousReadinessTransactionError(
                "duplicate readiness rollback indexes; preserving transaction"
            )
        secure_rename_noreplace(index_lock, rollback_path)
        fsync_directory(index.parent)
        fsync_directory(transaction)
        if _candidate_index_is_semantically_exact(repo_root, index, journal):
            _ensure_candidate_readiness_pair(
                schema,
                readiness,
                schema_install,
                readiness_install,
                candidate_schema,
                candidate_readiness,
                journal,
            )
            return True
        raise AmbiguousReadinessTransactionError(
            "committed readiness Git index changed; preserving transaction"
        )
    elif attempt_digest is not None and lock_digest == attempt_digest:
        if index_digest == original_digest:
            _unlink_regular_exact(index_lock, attempt_digest)
            lock_digest = None
        else:
            raise AmbiguousReadinessTransactionError(
                "verification rollback index state changed; preserving transaction"
            )
    elif lock_digest is not None:
        if index_digest == candidate_digest:
            displaced_digest = lock_digest
            secure_exchange(index_lock, index)
            fsync_directory(index.parent)
            if (
                sha256_file(index) != displaced_digest
                or sha256_file(index_lock) != candidate_digest
            ):
                raise AmbiguousReadinessTransactionError(
                    "readiness index exchange rollback changed; preserving transaction"
                )
            _unlink_regular_exact(index_lock, candidate_digest)
        raise AmbiguousReadinessTransactionError(
            "ambiguous readiness index lock; preserving transaction"
        )

    current_tree = _git_index_tree(repo_root)
    if current_tree == journal["originalIndexTree"]:
        if rollback_kind is not None:
            raise AmbiguousReadinessTransactionError(
                "committed readiness rollback index has an original-tree "
                "worktree; preserving transaction"
            )
        _restore_original_readiness_pair(
            schema,
            readiness,
            schema_install,
            readiness_install,
            original_schema,
            original_readiness,
            journal,
        )
        if read_regular_bytes(index) != original_index:
            # Tree equality permits benign index stat refreshes. Never rewrite
            # such an index; the staged semantic state is already the original.
            if _git_index_tree(repo_root) != journal["originalIndexTree"]:
                raise SchemaError("pre-commit Git index changed during recovery")
        _assert_private_transaction_same_object(transaction, transaction_identity)
        remove_transaction_tree(transaction)
        return False
    if current_tree == journal["candidateIndexTree"]:
        if not _candidate_index_is_semantically_exact(repo_root, index, journal):
            raise AmbiguousReadinessTransactionError(
                "committed readiness index flags changed; preserving transaction"
            )
        if rollback_kind != "file":
            raise AmbiguousReadinessTransactionError(
                "committed readiness transaction lost its rollback index"
            )
        _ensure_candidate_readiness_pair(
            schema,
            readiness,
            schema_install,
            readiness_install,
            candidate_schema,
            candidate_readiness,
            journal,
        )
        return True
    raise AmbiguousReadinessTransactionError(
        "ambiguous readiness transaction index state; preserving transaction"
    )


def readiness_publication_checkpoint(_name: str) -> None:
    """No-op seam for crash-injection tests of the two-file/index transaction."""


def _prepare_readiness_transaction(
    repo_root: Path,
    schema_candidate: bytes,
    readiness_candidate: bytes,
) -> tuple[dict[str, Any], tuple[Path, Path, Path, Path, Path, Path, Path]]:
    locations = _readiness_transaction_locations(repo_root)
    schema, readiness, index, index_lock, transaction, schema_install, readiness_install = locations
    preparing = transaction.with_name(f"{transaction.name}.prepare")
    if path_kind_no_follow(transaction) is not None:
        raise SchemaError("readiness transaction is already present")
    if path_kind_no_follow(preparing) is not None:
        raise SchemaError("readiness transaction preparation is already present")
    if path_kind_no_follow(index_lock) is not None:
        raise SchemaError("Git index is locked by another writer")
    for residue in (schema_install, readiness_install):
        if path_kind_no_follow(residue) is not None:
            raise SchemaError(f"readiness transaction install residue already exists: {residue}")

    original_schema = read_regular_bytes(schema)
    original_readiness = read_optional_regular_bytes(readiness)
    index_mode, index_gid = _git_index_file_metadata(index)
    original_index = read_regular_bytes(index)
    if sha256_bytes(schema_candidate) == sha256_bytes(original_schema):
        raise SchemaError("readiness publication must advance the paired schema manifest")
    for relative in (schema.relative_to(repo_root).as_posix(), READINESS_RELATIVE):
        if _indexed_mode(repo_root, relative) != "100644":
            raise SchemaError(
                f"readiness publication metadata must use index mode 100644: {relative}"
            )
    with anchored_parent(preparing) as (parent, name):
        os.mkdir(name, 0o700, dir_fd=parent)
    directory_identity(preparing)
    try:
        payloads: list[tuple[str, bytes]] = [
            ("schema.original", original_schema),
            ("schema.candidate", schema_candidate),
            ("readiness.candidate", readiness_candidate),
            ("index.original", original_index),
            (READINESS_INDEX_CANDIDATE, original_index),
        ]
        if original_readiness is not None:
            payloads.append(("readiness.original", original_readiness))
        for name, payload in payloads:
            write_bytes_fsync(preparing / name, payload, create=True)
        for name in ("index.original", READINESS_INDEX_CANDIDATE):
            _set_git_index_file_mode(preparing / name, index_mode, index_gid)

        candidate_index = preparing / READINESS_INDEX_CANDIDATE
        original_tree = _git_index_tree(repo_root, index_file=candidate_index)
        schema_relative = schema.relative_to(repo_root).as_posix()
        schema_blob = _git_blob(repo_root, schema_candidate)
        readiness_blob = _git_blob(repo_root, readiness_candidate)
        for relative, blob in (
            (schema_relative, schema_blob),
            (READINESS_RELATIVE, readiness_blob),
        ):
            _git_transaction_command(
                repo_root,
                ["update-index", "--add", "--cacheinfo", f"100644,{blob},{relative}"],
                index_file=candidate_index,
            )
        candidate_tree = _git_index_tree(repo_root, index_file=candidate_index)
        if candidate_tree == original_tree:
            raise SchemaError("readiness publication would not change the staged Git tree")
        fsync_file(candidate_index)
        _set_git_index_file_mode(candidate_index, index_mode, index_gid)
        candidate_index_bytes = read_regular_bytes(candidate_index)
        write_bytes_fsync(
            preparing / READINESS_INDEX_COMMIT,
            candidate_index_bytes,
            create=True,
            mode=index_mode,
        )
        _set_git_index_file_mode(
            preparing / READINESS_INDEX_COMMIT, index_mode, index_gid
        )
        journal = {
            "candidateIndexEntriesSha256": _git_index_entries_sha256(
                repo_root, index_file=candidate_index
            ),
            "candidateIndexSha256": sha256_bytes(candidate_index_bytes),
            "candidateIndexTree": candidate_tree,
            "candidateReadinessSha256": sha256_bytes(readiness_candidate),
            "candidateSchemaSha256": sha256_bytes(schema_candidate),
            "indexGid": index_gid,
            "indexMode": index_mode,
            "originalIndexSha256": sha256_bytes(original_index),
            "originalIndexTree": original_tree,
            "originalReadinessSha256": (
                sha256_bytes(original_readiness) if original_readiness is not None else None
            ),
            "originalSchemaSha256": sha256_bytes(original_schema),
            "readinessPath": READINESS_RELATIVE,
            "schemaPath": schema_relative,
            "transactionVersion": READINESS_TRANSACTION_VERSION,
        }
        write_bytes_fsync(
            preparing / "journal.json", pretty_json_bytes(journal), create=True
        )
        fsync_directory(preparing)
        secure_rename_noreplace(preparing, transaction)
        fsync_directory(transaction.parent)
        return journal, locations
    except BaseException:
        if path_kind_no_follow(preparing) == "directory":
            remove_transaction_tree(preparing)
        raise


def _commit_readiness_transaction(
    repo_root: Path,
    journal: dict[str, Any],
    locations: tuple[Path, Path, Path, Path, Path, Path, Path],
) -> None:
    schema, readiness, index, index_lock, transaction, schema_install, readiness_install = locations
    commit_index = transaction / READINESS_INDEX_COMMIT
    _assert_git_index_file_metadata(index, journal, "original")
    _assert_git_index_file_metadata(commit_index, journal, "commit")
    secure_rename_noreplace(commit_index, index_lock)
    fsync_directory(index.parent)
    readiness_publication_checkpoint("index_lock_reserved")
    if sha256_file(index) != journal["originalIndexSha256"]:
        raise SchemaError("Git index changed before readiness publication acquired its lock")

    schema_candidate = _read_transaction_payload(
        transaction, "schema.candidate", journal["candidateSchemaSha256"]
    )
    readiness_candidate = _read_transaction_payload(
        transaction, "readiness.candidate", journal["candidateReadinessSha256"]
    )
    _install_transaction_payload(
        schema,
        schema_install,
        schema_candidate,
        allowed_existing={journal["originalSchemaSha256"]},
    )
    readiness_publication_checkpoint("schema_installed")
    _install_transaction_payload(
        readiness,
        readiness_install,
        readiness_candidate,
        allowed_existing={journal["originalReadinessSha256"], None},
    )
    readiness_publication_checkpoint("readiness_installed")
    fsync_directory(schema.parent)
    fsync_directory(readiness.parent)
    _cleanup_readiness_install_residues(
        schema_install, readiness_install, journal
    )

    if sha256_file(index) != journal["originalIndexSha256"]:
        raise SchemaError("Git index changed behind the reserved readiness lock")
    if sha256_file(index_lock) != journal["candidateIndexSha256"]:
        raise SchemaError("reserved candidate Git index changed before commit")
    _assert_git_index_file_metadata(index, journal, "original")
    _assert_git_index_file_metadata(index_lock, journal, "candidate lock")
    secure_exchange(index_lock, index)
    fsync_directory(index.parent)
    readiness_publication_checkpoint("index_exchanged")

    installed_digest = sha256_file(index)
    displaced_digest = sha256_file(index_lock)
    if installed_digest != journal["candidateIndexSha256"]:
        if displaced_digest == journal["originalIndexSha256"]:
            _unlink_regular_exact(index_lock, displaced_digest)
        raise AmbiguousReadinessTransactionError(
            "candidate Git index changed after atomic exchange; preserving transaction"
        )
    _assert_git_index_file_metadata(index, journal, "installed candidate")
    if displaced_digest != journal["originalIndexSha256"]:
        secure_exchange(index_lock, index)
        fsync_directory(index.parent)
        if (
            sha256_file(index) != displaced_digest
            or sha256_file(index_lock) != journal["candidateIndexSha256"]
        ):
            raise AmbiguousReadinessTransactionError(
                "concurrent Git index exchange rollback changed; preserving transaction"
            )
        _unlink_regular_exact(index_lock, journal["candidateIndexSha256"])
        raise AmbiguousReadinessTransactionError(
            "concurrent Git index writer preserved; readiness transaction not committed"
        )
    if sha256_file(index) != journal["candidateIndexSha256"]:
        _unlink_regular_exact(index_lock, journal["originalIndexSha256"])
        raise AmbiguousReadinessTransactionError(
            "candidate Git index changed before lock release; preserving transaction"
        )
    rollback_index = transaction / READINESS_INDEX_ROLLBACK
    secure_rename_noreplace(index_lock, rollback_index)
    fsync_directory(index.parent)
    fsync_directory(transaction)
    readiness_publication_checkpoint("index_committed")


def _rollback_unverified_readiness_transaction(
    repo_root: Path,
    journal: dict[str, Any],
    locations: tuple[Path, Path, Path, Path, Path, Path, Path],
    *,
    fenced_candidate_index_sha256: str,
) -> None:
    """Roll back a rejected candidate while retaining the verification fence."""

    schema, readiness, index, index_lock, transaction, _schema_install, _readiness_install = (
        locations
    )
    if _transaction_is_verified(transaction, journal):
        raise SchemaError("verified readiness transaction cannot be rolled back")
    candidate_schema = _read_transaction_payload(
        transaction, "schema.candidate", journal["candidateSchemaSha256"]
    )
    candidate_readiness = _read_transaction_payload(
        transaction,
        "readiness.candidate",
        journal["candidateReadinessSha256"],
    )
    rollback_index = transaction / READINESS_INDEX_ROLLBACK
    if (
        path_kind_no_follow(index_lock) != "file"
        or sha256_file(index_lock) != journal["originalIndexSha256"]
        or path_kind_no_follow(rollback_index) is not None
        or not _fenced_candidate_readiness_state_is_exact(
            schema,
            readiness,
            index,
            candidate_schema,
            candidate_readiness,
            journal,
            fenced_candidate_index_sha256,
        )
    ):
        if (
            path_kind_no_follow(index_lock) == "file"
            and sha256_file(index_lock) == journal["originalIndexSha256"]
            and path_kind_no_follow(rollback_index) is None
        ):
            _return_verification_index_fence(
                index,
                index_lock,
                transaction,
                rollback_index,
                journal,
            )
        raise AmbiguousReadinessTransactionError(
            "committed readiness index changed before rollback; preserving transaction"
        )
    _assert_git_index_file_metadata(index_lock, journal, "verification fence")
    secure_exchange(index_lock, index)
    fsync_directory(index.parent)
    readiness_publication_checkpoint("verification_rollback_exchanged")
    restored_index_digest = sha256_file(index)
    displaced_candidate_digest = sha256_file(index_lock)
    if (
        restored_index_digest != journal["originalIndexSha256"]
        or displaced_candidate_digest != fenced_candidate_index_sha256
    ):
        secure_exchange(index_lock, index)
        fsync_directory(index.parent)
        if (
            sha256_file(index) != displaced_candidate_digest
            or sha256_file(index_lock) != restored_index_digest
        ):
            raise AmbiguousReadinessTransactionError(
                "failed verification index rollback changed; preserving transaction"
            )
        if (
            sha256_file(index_lock) == journal["originalIndexSha256"]
            and path_kind_no_follow(rollback_index) is None
        ):
            secure_rename_noreplace(index_lock, rollback_index)
            fsync_directory(index.parent)
            fsync_directory(transaction)
        raise AmbiguousReadinessTransactionError(
            "concurrent Git index writer preserved during verification rollback"
        )
    _unlink_regular_exact(index_lock, fenced_candidate_index_sha256)
    if recover_readiness_transaction(repo_root):
        raise SchemaError("readiness verification rollback remained committed")


def _record_verified_readiness_transaction(
    repo_root: Path,
    journal: dict[str, Any],
    locations: tuple[Path, Path, Path, Path, Path, Path, Path],
    *,
    verification_fence_held: bool = False,
    fenced_candidate_index_sha256: str | None = None,
) -> None:
    schema, readiness, index, index_lock, transaction, _schema_install, _readiness_install = (
        locations
    )
    candidate_schema = _read_transaction_payload(
        transaction, "schema.candidate", journal["candidateSchemaSha256"]
    )
    candidate_readiness = _read_transaction_payload(
        transaction,
        "readiness.candidate",
        journal["candidateReadinessSha256"],
    )
    rollback_index = transaction / READINESS_INDEX_ROLLBACK
    if not verification_fence_held:
        fenced_candidate_index_sha256 = _acquire_verification_index_fence(
            repo_root, journal, locations
        )
        try:
            verification_index = _prepare_readiness_verification_index(
                repo_root,
                journal,
                transaction,
                fenced_candidate_index_sha256,
            )
            if path_kind_no_follow(verification_index) != "file":
                raise SchemaError("readiness private verification index is missing")
            _discard_readiness_verification_index(
                repo_root, journal, transaction
            )
        except BaseException:
            _return_verification_index_fence(
                index,
                index_lock,
                transaction,
                rollback_index,
                journal,
            )
            raise
    elif (
        fenced_candidate_index_sha256 is None
        or path_kind_no_follow(index_lock) != "file"
        or sha256_file(index_lock) != journal["originalIndexSha256"]
        or path_kind_no_follow(rollback_index) is not None
    ):
        raise AmbiguousReadinessTransactionError(
            "readiness final-verification fence changed; preserving transaction"
        )
    _assert_git_index_file_metadata(index_lock, journal, "verification fence")
    if (
        sha256_file(index_lock) != journal["originalIndexSha256"]
        or not _fenced_candidate_readiness_state_is_exact(
            schema,
            readiness,
            index,
            candidate_schema,
            candidate_readiness,
            journal,
            fenced_candidate_index_sha256,
        )
    ):
        _return_verification_index_fence(
            index,
            index_lock,
            transaction,
            rollback_index,
            journal,
        )
        raise AmbiguousReadinessTransactionError(
            "readiness publication changed while final verification was fenced; "
            "preserving transaction"
        )
    marker = transaction / READINESS_VERIFICATION
    preparing = transaction / READINESS_VERIFICATION_PREPARE
    if path_kind_no_follow(marker) is not None or path_kind_no_follow(preparing) is not None:
        raise SchemaError("readiness verification marker residue already exists")
    marker_bytes = pretty_json_bytes(_verification_record(journal))
    write_bytes_fsync(preparing, marker_bytes, create=True)
    secure_rename_noreplace(preparing, marker)
    fsync_directory(transaction)
    readiness_publication_checkpoint("verification_recorded")
    if (
        sha256_file(index_lock) != journal["originalIndexSha256"]
        or not _fenced_candidate_readiness_state_is_exact(
            schema,
            readiness,
            index,
            candidate_schema,
            candidate_readiness,
            journal,
            fenced_candidate_index_sha256,
        )
    ):
        _return_verification_index_fence(
            index,
            index_lock,
            transaction,
            rollback_index,
            journal,
        )
        raise AmbiguousReadinessTransactionError(
            "readiness publication changed after verification was recorded; "
            "preserving transaction"
        )
    if recover_readiness_transaction(repo_root):
        raise SchemaError("verified readiness transaction was not finalized")


def _verify_and_finalize_readiness_transaction(
    repo_root: Path,
    codex_command: str,
    studio_readiness: Any,
    journal: dict[str, Any],
    locations: tuple[Path, Path, Path, Path, Path, Path, Path],
) -> None:
    index, index_lock, transaction = locations[2:5]
    rollback_index = transaction / READINESS_INDEX_ROLLBACK
    fenced_candidate_index_sha256 = _acquire_verification_index_fence(
        repo_root, journal, locations
    )
    try:
        verification_index = _prepare_readiness_verification_index(
            repo_root,
            journal,
            transaction,
            fenced_candidate_index_sha256,
        )
        studio_readiness.verify_repository_pair(
            repo_root,
            repo_root / READINESS_RELATIVE,
            codex_command,
            index_file=verification_index,
        )
        _discard_readiness_verification_index(repo_root, journal, transaction)
    except studio_readiness.ReadinessError as error:
        try:
            _discard_readiness_verification_index(
                repo_root,
                journal,
                transaction,
                require_candidate_semantics=False,
            )
        except BaseException:
            _return_verification_index_fence(
                index,
                index_lock,
                transaction,
                rollback_index,
                journal,
            )
            raise
        _rollback_unverified_readiness_transaction(
            repo_root,
            journal,
            locations,
            fenced_candidate_index_sha256=fenced_candidate_index_sha256,
        )
        raise SchemaError(
            f"published readiness pair failed final verification and was rolled back: {error}"
        ) from error
    except BaseException:
        try:
            _discard_readiness_verification_index(
                repo_root,
                journal,
                transaction,
                require_candidate_semantics=False,
            )
        finally:
            _return_verification_index_fence(
                index,
                index_lock,
                transaction,
                rollback_index,
                journal,
            )
        raise
    _record_verified_readiness_transaction(
        repo_root,
        journal,
        locations,
        verification_fence_held=True,
        fenced_candidate_index_sha256=fenced_candidate_index_sha256,
    )


def publish_readiness(args: argparse.Namespace) -> None:
    if os.environ.get("LINEAR_API_KEY") is not None:
        raise SchemaError("raw Linear credential reached the readiness publisher")
    try:
        import studio_readiness
    except ImportError as error:
        raise SchemaError("cannot load the readiness compiler") from error
    if getattr(studio_readiness, "READINESS_RELATIVE", None) != READINESS_RELATIVE:
        raise SchemaError("readiness compiler and publisher paths differ")

    # Recovery is short and lock-protected. The expensive full gate compiler
    # intentionally runs after this lock is released.
    with schema_bundle_lock(exclusive=True):
        if recover_readiness_transaction(REPO_ROOT):
            locations = _readiness_transaction_locations(REPO_ROOT)
            transaction = locations[4]
            journal = _read_readiness_journal(transaction, REPO_ROOT)
            _verify_and_finalize_readiness_transaction(
                REPO_ROOT, args.codex, studio_readiness, journal, locations
            )
            print("recovered, verified, and staged Symphony Studio implementation-readiness pair")
            return

    try:
        readiness, schema_manifest, static_basis = studio_readiness.compile_full_gate_pair(
            repo_root=REPO_ROOT,
            codex_command=args.codex,
            mise_command=args.mise,
        )
    except AttributeError as error:
        raise SchemaError("readiness compiler does not expose compile_full_gate_pair") from error
    except studio_readiness.ReadinessError as error:
        raise SchemaError(f"full readiness gate failed: {error}") from error
    try:
        studio_readiness.require_green_pair(readiness, schema_manifest)
    except (AttributeError, studio_readiness.ReadinessError) as error:
        raise SchemaError(
            f"full readiness gate did not produce an acceptable green pair: {error}"
        ) from error

    compiled_index_tree = _git_index_tree(REPO_ROOT)
    readiness_bytes = studio_readiness.canonical_json_bytes(readiness)
    schema_bytes = studio_readiness.canonical_json_bytes(schema_manifest)
    try:
        source_sha256 = static_basis["checkout"]["source"]["sha256"]
    except (KeyError, TypeError) as error:
        raise SchemaError("readiness compiler returned an invalid static source basis") from error
    if not isinstance(source_sha256, str) or not re.fullmatch(r"[0-9a-f]{64}", source_sha256):
        raise SchemaError("readiness compiler returned an invalid source SHA-256")
    final_archive = None
    if isinstance(readiness.get("platform"), dict) and readiness["platform"].get(
        "packageStatus"
    ) == "pass":
        try:
            final_archive = studio_readiness.rehearse_final_pair_source_archive(
                REPO_ROOT,
                readiness,
                schema_manifest,
                source_sha256,
                compiled_index_tree,
            )
        except AttributeError as error:
            raise SchemaError("readiness compiler does not expose final archive rehearsal") from error
        except studio_readiness.ReadinessError as error:
            raise SchemaError(f"final readiness archive rehearsal failed: {error}") from error

    with schema_bundle_lock(exclusive=True):
        recover_readiness_transaction(REPO_ROOT)
        fresh_static, fresh_matrix, fresh_schema = studio_readiness.collect_static_basis(
            REPO_ROOT, args.codex
        )
        if fresh_static != static_basis:
            raise SchemaError("readiness static basis changed while full gates ran")
        if _git_index_tree(REPO_ROOT) != compiled_index_tree:
            raise SchemaError("Git index changed after full readiness compilation")
        try:
            studio_readiness.verify_readiness_pair(
                readiness,
                schema_manifest,
                fresh_matrix,
                expected_static_basis=static_basis,
            )
            studio_readiness.require_green_pair(readiness, schema_manifest)
        except studio_readiness.ReadinessError as error:
            raise SchemaError(f"full readiness compiler returned an invalid pair: {error}") from error
        journal, locations = _prepare_readiness_transaction(
            REPO_ROOT, schema_bytes, readiness_bytes
        )
        try:
            expected_original_schema = studio_readiness.canonical_json_bytes(fresh_schema)
            if (
                journal["originalIndexTree"] != compiled_index_tree
                or journal["originalSchemaSha256"]
                != sha256_bytes(expected_original_schema)
            ):
                raise SchemaError(
                    "schema manifest or Git index changed at readiness publication boundary"
                )
            if final_archive is not None:
                try:
                    studio_readiness.validate_package_probe_record(
                        final_archive,
                        source_sha256,
                        journal["candidateIndexTree"],
                    )
                except studio_readiness.ReadinessError as error:
                    raise SchemaError(
                        f"published candidate tree differs from final archive rehearsal: {error}"
                    ) from error
            _commit_readiness_transaction(REPO_ROOT, journal, locations)
        except AmbiguousReadinessTransactionError:
            raise
        except BaseException:
            # SIGKILL cannot enter this path; the next command will recover the
            # durable journal. Ordinary failures recover immediately.
            recover_readiness_transaction(REPO_ROOT)
            raise
        _verify_and_finalize_readiness_transaction(
            REPO_ROOT, args.codex, studio_readiness, journal, locations
        )
    print("published and staged Symphony Studio implementation-readiness pair")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="command", required=True)

    generate_parser = subparsers.add_parser(
        "generate",
        help="generate, durably verify, and crash-recover the pinned bundle",
        description=(
            "Generate and fsync a verified staging bundle, preserve the prior pin, "
            "install and reverify the candidate, and recover interrupted rename states."
        ),
    )
    generate_parser.add_argument("--codex", default="codex")
    generate_parser.add_argument("--tested-at", required=True)
    generate_parser.set_defaults(function=generate, lock_exclusive=True)

    seal_parser = subparsers.add_parser(
        "seal-fixtures", help="run deterministic fixture tests and seal their source-bound evidence"
    )
    seal_parser.add_argument("--tested-at", required=True)
    seal_parser.set_defaults(function=seal_fixtures, lock_exclusive=True)

    readiness_parser = subparsers.add_parser(
        "publish-readiness",
        help="run all R0-06 gates outside the lock, then atomically publish and stage the pair",
    )
    readiness_parser.add_argument("--codex", default="codex")
    readiness_parser.add_argument("--mise", default="mise")
    readiness_parser.set_defaults(function=publish_readiness, manages_lock=True)

    verify_parser = subparsers.add_parser("verify", help="verify committed metadata and artifacts")
    verify_parser.add_argument("--installed", action="store_true")
    verify_parser.add_argument("--codex", default="codex")
    verify_parser.set_defaults(function=verify, lock_exclusive=False)

    prepublication_parser = subparsers.add_parser(
        "verify-source-bound-prepublication",
        help=(
            "verify staged source, schema, and installed Codex without consulting "
            "the pair that publication will replace"
        ),
    )
    prepublication_parser.add_argument("--codex", default="codex")
    prepublication_parser.set_defaults(
        function=verify_source_bound_prepublication,
        lock_exclusive=False,
    )

    regenerate_parser = subparsers.add_parser(
        "regenerate-check", help="regenerate in a temporary directory and compare without writing"
    )
    regenerate_parser.add_argument("--codex", default="codex")
    regenerate_parser.set_defaults(function=regenerate_check, lock_exclusive=False)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if getattr(args, "manages_lock", False):
            args.function(args)
        else:
            with schema_bundle_lock(exclusive=args.lock_exclusive):
                if args.lock_exclusive:
                    if recover_readiness_transaction(REPO_ROOT):
                        raise SchemaError(
                            "committed readiness transaction requires publish-readiness verification"
                        )
                args.function(args)
    except (OSError, SchemaError, subprocess.CalledProcessError) as error:
        print(f"codex-schema: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
