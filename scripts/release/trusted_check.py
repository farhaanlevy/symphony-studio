#!/usr/bin/env python3
# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0
"""Owner-invoked, fail-closed producer for the trusted R0-07 CheckRun.

This program deliberately runs outside GitHub Actions.  It accepts only a
short-lived GitHub App installation token from the process environment, reads
all candidate and live evidence from GitHub, and performs its sole mutation --
creating the successful ``studio/release-gate`` CheckRun -- only after every
validation has passed.
"""

from __future__ import annotations

import argparse
import base64
import dataclasses
import datetime as dt
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import sys
from typing import Any, Mapping, MutableMapping, Sequence
import urllib.error
import urllib.parse
import urllib.request
import zipfile


API_BASE = "https://api.github.com"
API_VERSION = "2022-11-28"
USER_AGENT = "symphony-studio-trusted-check/0.1"
TOKEN_ENVIRONMENT_VARIABLE = "SYMPHONY_TRUSTED_CHECK_TOKEN"

REPOSITORY = "farhaanlevy/symphony-studio"
RELEASE_BRANCH = "release/v0.1.0"
BASE_BRANCH = "main"
VERSION = "v0.1.0"
STAGE = "R0"
CHECK_NAME = "studio/release-gate"
CHECK_TITLE = "Symphony Studio R0-07 trusted candidate"
GITHUB_ACTIONS_APP_ID = 15368

REQUIRED_CHECKS = ("make-all", "pr-description-lint", CHECK_NAME)
REQUIRED_WORKFLOW_PATHS = (
    ".github/workflows/make-all.yml",
    ".github/workflows/pr-description-lint.yml",
    ".github/workflows/release-gate.yml",
    ".github/workflows/publish-release.yml",
    "scripts/release/release.py",
)
RELEASE_GATE_WORKFLOW_PATH = ".github/workflows/release-gate.yml"
# This digest is the independently approved untrusted evidence producer.  A
# workflow edit must be deliberately reviewed and this trust root advanced.
TRUSTED_RELEASE_GATE_SHA256 = (
    "e7354599ae84da5438c55c08c7587e7580a05acd6f7767b5276c2283c1592dfa"
)
READINESS_PATH = "artifacts/readiness/implementation-readiness.json"
SCHEMA_MANIFEST_PATH = "elixir/priv/codex_schema/0.144.3/manifest.json"
RELEASE_GATE_JOB_NAME = "release-gate evidence (untrusted Actions producer)"
RELEASE_GATE_ARTIFACT_PREFIX = "release-gate-"
RELEASE_GATE_RECEIPT = "release-gate-test-evidence.json"
REQUIRED_RELEASE_GATE_STEPS = (
    "Checkout exact candidate",
    "Verify exact checkout and workflow boundary",
    "Set up mise tools",
    "Verify release tooling",
    "Install exact Codex compatibility pin",
    "Verify accepted foundation and current installed schema binding",
    "Emit exact-head release-gate receipt",
    "Upload public release-gate receipts",
)
REQUIRED_CONFORMANCE_IDS = {
    "capability_fake_conformance",
    "depth_guard_conformance",
    "installed_codex_verify",
    "linear_fake_conformance",
    "linear_live_discovery",
    "no_model_live_discovery",
    "readiness_harness",
    "schema_harness",
    "schema_regeneration",
    "source_archive_rehearsal",
    "source_bound_fixture_replay",
    "subagent_cap_conformance",
    "upstream_make_all",
}
REQUIRED_LINEAR_CAPABILITIES = {
    "blockers",
    "comments",
    "connectivity",
    "labels",
    "mutations",
    "project",
    "states",
}

SHA1_RE = re.compile(r"[0-9a-f]{40}\Z")
SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")
TIMESTAMP_RE = re.compile(
    r"20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\Z"
)
MAX_JSON_BYTES = 1024 * 1024
MAX_CANDIDATE_MANIFEST_BYTES = 32 * 1024
MAX_REMOTE_FILE_BYTES = 1024 * 1024
MAX_ARTIFACT_BYTES = 2 * 1024 * 1024
MAX_ARTIFACT_ENTRY_BYTES = 256 * 1024
MAX_TOKEN_BYTES = 4096
MAX_ATTESTOR_BYTES = 512 * 1024
HTTP_TIMEOUT_SECONDS = 30
MAX_REDIRECTS = 4

ALLOWED_ARTIFACT_HOST_SUFFIXES = (
    ".amazonaws.com",
    ".blob.core.windows.net",
    ".githubusercontent.com",
)


class TrustedCheckError(RuntimeError):
    """A content-free validation failure safe to report to an operator."""


@dataclasses.dataclass(frozen=True)
class HttpResponse:
    status: int
    headers: Mapping[str, str]
    body: bytes


@dataclasses.dataclass(frozen=True)
class ApprovalInputs:
    file_sha256: Mapping[str, str]
    review_record_sha256: Mapping[str, str]
    complete_gate_record_sha256: str
    trusted_app_id: int


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(
        self,
        request: urllib.request.Request,
        file_pointer: Any,
        code: int,
        message: str,
        headers: Mapping[str, str],
        new_url: str,
    ) -> None:
        return None


class UrllibTransport:
    """Small bounded HTTP transport that never follows redirects implicitly."""

    def __init__(self) -> None:
        self._opener = urllib.request.build_opener(_NoRedirect())

    @staticmethod
    def _bounded_body(response: Any, maximum: int) -> bytes:
        length_text = response.headers.get("Content-Length")
        if length_text is not None:
            try:
                length = int(length_text)
            except ValueError as error:
                raise TrustedCheckError("github_content_length_invalid") from error
            if length < 0 or length > maximum:
                raise TrustedCheckError("github_response_too_large")
        body = response.read(maximum + 1)
        if len(body) > maximum:
            raise TrustedCheckError("github_response_too_large")
        return body

    def request(
        self,
        method: str,
        url: str,
        headers: Mapping[str, str],
        body: bytes | None,
        maximum_response_bytes: int,
    ) -> HttpResponse:
        request = urllib.request.Request(
            url,
            data=body,
            headers=dict(headers),
            method=method,
        )
        try:
            with self._opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
                return HttpResponse(
                    status=response.status,
                    headers=dict(response.headers.items()),
                    body=self._bounded_body(response, maximum_response_bytes),
                )
        except urllib.error.HTTPError as error:
            try:
                response_body = self._bounded_body(error, maximum_response_bytes)
            finally:
                error.close()
            return HttpResponse(
                status=error.code,
                headers=dict(error.headers.items()),
                body=response_body,
            )
        except (OSError, TimeoutError, urllib.error.URLError) as error:
            raise TrustedCheckError("github_transport_failed") from error


def canonical_json_bytes(value: Any) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        + "\n"
    ).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def git_blob_sha1(value: bytes) -> str:
    framing = f"blob {len(value)}\0".encode("ascii")
    return hashlib.sha1(framing + value).hexdigest()


def _header(headers: Mapping[str, str], name: str) -> str | None:
    lowered = name.lower()
    for key, value in headers.items():
        if key.lower() == lowered:
            return value
    return None


def _parse_json(raw: bytes, failure: str) -> Any:
    if len(raw) > MAX_JSON_BYTES:
        raise TrustedCheckError(failure)
    try:
        return json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise TrustedCheckError(failure) from error


def _is_sha1(value: Any) -> bool:
    return isinstance(value, str) and SHA1_RE.fullmatch(value) is not None


def _is_sha256(value: Any) -> bool:
    return isinstance(value, str) and SHA256_RE.fullmatch(value) is not None


def _is_timestamp(value: Any) -> bool:
    if not isinstance(value, str) or TIMESTAMP_RE.fullmatch(value) is None:
        return False
    try:
        parsed = dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return False
    return parsed.strftime("%Y-%m-%dT%H:%M:%SZ") == value


def consume_token(environment: MutableMapping[str, str]) -> str:
    token = environment.pop(TOKEN_ENVIRONMENT_VARIABLE, None)
    if (
        not isinstance(token, str)
        or not 20 <= len(token.encode("utf-8")) <= MAX_TOKEN_BYTES
        or any(character.isspace() or ord(character) < 0x21 for character in token)
        or any(ord(character) > 0x7E for character in token)
    ):
        raise TrustedCheckError("trusted_check_token_missing_or_invalid")
    return token


def _has_git_worktree_ancestor(path: Path) -> bool:
    cursor = path if path.is_dir() else path.parent
    while True:
        marker = cursor / ".git"
        try:
            marker.lstat()
        except FileNotFoundError:
            pass
        except OSError as error:
            raise TrustedCheckError("attestor_path_unverifiable") from error
        else:
            return True
        if cursor.parent == cursor:
            return False
        cursor = cursor.parent


def _owner_only_directory(path: Path) -> Path:
    try:
        absolute = path.absolute()
        resolved = absolute.resolve(strict=True)
        metadata = absolute.lstat()
    except OSError as error:
        raise TrustedCheckError("attestor_directory_invalid") from error
    if (
        absolute != resolved
        or not stat.S_ISDIR(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or stat.S_IMODE(metadata.st_mode) != 0o700
        or _has_git_worktree_ancestor(resolved)
    ):
        raise TrustedCheckError("attestor_directory_invalid")
    return resolved


def _bounded_regular_file(path: Path, maximum: int, failure: str) -> bytes:
    try:
        absolute = path.absolute()
        resolved = absolute.resolve(strict=True)
        metadata = absolute.lstat()
    except OSError as error:
        raise TrustedCheckError(failure) from error
    if (
        absolute != resolved
        or stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or not 0 < metadata.st_size <= maximum
    ):
        raise TrustedCheckError(failure)
    try:
        raw = absolute.read_bytes()
    except OSError as error:
        raise TrustedCheckError(failure) from error
    if len(raw) != metadata.st_size or len(raw) > maximum:
        raise TrustedCheckError(failure)
    return raw


def public_source_digest(source: Path | None = None) -> str:
    source_path = Path(__file__) if source is None else source
    raw = _bounded_regular_file(source_path, MAX_ATTESTOR_BYTES, "attestor_source_invalid")
    digest_path = source_path.with_name("trusted_check.sha256")
    digest_raw = _bounded_regular_file(
        digest_path, 256, "attestor_public_digest_invalid"
    )
    try:
        digest_text = digest_raw.decode("ascii")
    except UnicodeDecodeError as error:
        raise TrustedCheckError("attestor_public_digest_invalid") from error
    match = re.fullmatch(
        r"([0-9a-f]{64})  trusted_check\.py\n", digest_text
    )
    if match is None or match.group(1) != sha256_bytes(raw):
        raise TrustedCheckError("attestor_public_digest_mismatch")
    return match.group(1)


def seal_attestor(output_text: str) -> dict[str, Any]:
    if TOKEN_ENVIRONMENT_VARIABLE in os.environ:
        raise TrustedCheckError("token_forbidden_during_attestor_seal")
    source = Path(__file__)
    source_raw = _bounded_regular_file(
        source, MAX_ATTESTOR_BYTES, "attestor_source_invalid"
    )
    digest = public_source_digest(source)
    output = Path(output_text)
    if not output.is_absolute() or not output.name:
        raise TrustedCheckError("attestor_output_path_invalid")
    parent = _owner_only_directory(output.parent)
    destination = parent / output.name
    if output.absolute() != destination:
        raise TrustedCheckError("attestor_output_path_invalid")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor: int | None = None
    try:
        descriptor = os.open(destination, flags, 0o500)
        os.fchmod(descriptor, 0o500)
        offset = 0
        while offset < len(source_raw):
            written = os.write(descriptor, source_raw[offset:])
            if written <= 0:
                raise OSError("short write")
            offset += written
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = None
        parent_descriptor = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(parent_descriptor)
        finally:
            os.close(parent_descriptor)
    except FileExistsError as error:
        raise TrustedCheckError("attestor_output_exists") from error
    except OSError as error:
        try:
            destination.unlink()
        except OSError:
            pass
        raise TrustedCheckError("attestor_seal_failed") from error
    finally:
        if descriptor is not None:
            os.close(descriptor)
    return {
        "attestorSha256": digest,
        "kind": "trusted-check-attestor-seal",
        "mode": "0500",
        "status": "pass",
    }


def verify_sealed_runtime(expected_sha256: str) -> str:
    if not _is_sha256(expected_sha256):
        raise TrustedCheckError("attestor_expected_digest_invalid")
    path = Path(__file__)
    try:
        absolute = path.absolute()
        resolved = absolute.resolve(strict=True)
        metadata = absolute.lstat()
    except OSError as error:
        raise TrustedCheckError("attestor_runtime_path_invalid") from error
    if (
        absolute != resolved
        or stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or stat.S_IMODE(metadata.st_mode) != 0o500
        or _has_git_worktree_ancestor(resolved)
    ):
        raise TrustedCheckError("attestor_runtime_path_invalid")
    _owner_only_directory(resolved.parent)
    raw = _bounded_regular_file(
        resolved, MAX_ATTESTOR_BYTES, "attestor_runtime_path_invalid"
    )
    observed = sha256_bytes(raw)
    if observed != expected_sha256:
        raise TrustedCheckError("attestor_self_digest_mismatch")
    return observed


def validate_approvals(approvals: ApprovalInputs) -> None:
    if (
        set(approvals.file_sha256) != set(REQUIRED_WORKFLOW_PATHS)
        or not all(_is_sha256(value) for value in approvals.file_sha256.values())
        or approvals.file_sha256.get(RELEASE_GATE_WORKFLOW_PATH)
        != TRUSTED_RELEASE_GATE_SHA256
        or set(approvals.review_record_sha256)
        != {"evidence", "release-security"}
        or not all(
            _is_sha256(value)
            for value in approvals.review_record_sha256.values()
        )
        or not _is_sha256(approvals.complete_gate_record_sha256)
        or type(approvals.trusted_app_id) is not int
        or approvals.trusted_app_id <= 0
        or approvals.trusted_app_id == GITHUB_ACTIONS_APP_ID
    ):
        raise TrustedCheckError("trusted_approval_inputs_invalid")


class GitHubAPI:
    def __init__(self, token: str, transport: Any | None = None) -> None:
        self._token = token
        self._transport = transport if transport is not None else UrllibTransport()

    @staticmethod
    def _common_headers() -> dict[str, str]:
        return {
            "Accept": "application/vnd.github+json",
            "User-Agent": USER_AGENT,
            "X-GitHub-Api-Version": API_VERSION,
        }

    def _api_request(
        self,
        method: str,
        path: str,
        *,
        payload: Mapping[str, Any] | None = None,
        expected_status: int = 200,
        maximum_response_bytes: int = MAX_JSON_BYTES,
    ) -> HttpResponse:
        if not path.startswith("/") or "//" in path:
            raise TrustedCheckError("github_api_path_invalid")
        headers = self._common_headers()
        headers["Authorization"] = f"Bearer {self._token}"
        body: bytes | None = None
        if payload is not None:
            body = json.dumps(
                payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
            ).encode("utf-8")
            headers["Content-Type"] = "application/json"
        response = self._transport.request(
            method,
            API_BASE + path,
            headers,
            body,
            maximum_response_bytes,
        )
        if response.status != expected_status:
            raise TrustedCheckError(f"github_api_http_{response.status}")
        return response

    def get_json(self, path: str) -> Any:
        response = self._api_request("GET", path)
        return _parse_json(response.body, "github_api_json_invalid")

    def post_json(self, path: str, payload: Mapping[str, Any]) -> Any:
        response = self._api_request(
            "POST", path, payload=payload, expected_status=201
        )
        return _parse_json(response.body, "github_api_json_invalid")

    @staticmethod
    def _validated_artifact_location(location: str) -> str:
        parsed = urllib.parse.urlsplit(location)
        hostname = parsed.hostname
        try:
            port = parsed.port
        except ValueError as error:
            raise TrustedCheckError("artifact_redirect_invalid") from error
        if (
            parsed.scheme != "https"
            or not hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.fragment
            or port not in (None, 443)
            or not any(
                hostname == suffix[1:] or hostname.endswith(suffix)
                for suffix in ALLOWED_ARTIFACT_HOST_SUFFIXES
            )
        ):
            raise TrustedCheckError("artifact_redirect_invalid")
        return location

    def download_artifact(self, artifact_id: int) -> bytes:
        if type(artifact_id) is not int or artifact_id <= 0:
            raise TrustedCheckError("artifact_id_invalid")
        path = f"/repos/{REPOSITORY}/actions/artifacts/{artifact_id}/zip"
        response = self._api_request(
            "GET",
            path,
            expected_status=302,
            maximum_response_bytes=16 * 1024,
        )
        location = _header(response.headers, "Location")
        if not isinstance(location, str):
            raise TrustedCheckError("artifact_redirect_missing")
        url = self._validated_artifact_location(location)
        headers = {
            "Accept": "application/octet-stream",
            "User-Agent": USER_AGENT,
        }
        for _attempt in range(MAX_REDIRECTS):
            response = self._transport.request(
                "GET", url, headers, None, MAX_ARTIFACT_BYTES
            )
            if response.status == 200:
                return response.body
            if response.status not in {301, 302, 303, 307, 308}:
                raise TrustedCheckError(f"artifact_download_http_{response.status}")
            location = _header(response.headers, "Location")
            if not isinstance(location, str):
                raise TrustedCheckError("artifact_redirect_missing")
            url = self._validated_artifact_location(location)
        raise TrustedCheckError("artifact_redirect_limit_exceeded")


def candidate_from_pr_body(body: Any) -> tuple[dict[str, Any], bytes, str]:
    if not isinstance(body, str) or len(body.encode("utf-8")) > 60_000:
        raise TrustedCheckError("pull_request_body_invalid")
    digest_matches = re.findall(
        r"^Candidate manifest SHA-256: `([0-9a-f]{64})`$", body, re.MULTILINE
    )
    opening = (
        "<summary>Canonical immutable candidate manifest for this exact head"
        "</summary>\n\n```json\n"
    )
    closing = "\n```\n\n</details>"
    if len(digest_matches) != 1 or body.count(opening) != 1:
        raise TrustedCheckError("candidate_manifest_transport_invalid")
    start = body.index(opening) + len(opening)
    if body.count(closing, start) != 1:
        raise TrustedCheckError("candidate_manifest_transport_invalid")
    end = body.index(closing, start)
    manifest_text = body[start:end]
    if "\n" in manifest_text or not manifest_text:
        raise TrustedCheckError("candidate_manifest_transport_invalid")
    raw = manifest_text.encode("utf-8") + b"\n"
    if len(raw) > MAX_CANDIDATE_MANIFEST_BYTES:
        raise TrustedCheckError("candidate_manifest_too_large")
    manifest = _parse_json(raw, "candidate_manifest_json_invalid")
    if not isinstance(manifest, dict) or canonical_json_bytes(manifest) != raw:
        raise TrustedCheckError("candidate_manifest_noncanonical")
    digest = sha256_bytes(raw)
    if digest_matches[0] != digest:
        raise TrustedCheckError("candidate_manifest_digest_mismatch")
    return manifest, raw, digest


def _validate_review_evidence(
    items: Any,
    head: str,
    tree: str,
    approved_record_sha256: Mapping[str, str],
) -> None:
    if not isinstance(items, list) or len(items) != 2:
        raise TrustedCheckError("candidate_review_evidence_invalid")
    roles: set[str] = set()
    expected_record_keys = {
        "blockingFindings",
        "completedAt",
        "evidenceSha256",
        "exactHead",
        "exactTree",
        "kind",
        "role",
        "verdict",
    }
    for item in items:
        if not isinstance(item, dict) or set(item) != {"record", "sha256"}:
            raise TrustedCheckError("candidate_review_evidence_invalid")
        record = item.get("record")
        if (
            not isinstance(record, dict)
            or set(record) != expected_record_keys
            or item.get("sha256") != sha256_bytes(canonical_json_bytes(record))
            or record.get("kind") != "independent-review"
            or record.get("exactHead") != head
            or record.get("exactTree") != tree
            or record.get("verdict") != "GO"
            or record.get("blockingFindings") != []
            or record.get("role") not in {"evidence", "release-security"}
            or not _is_sha256(record.get("evidenceSha256"))
            or not _is_timestamp(record.get("completedAt"))
        ):
            raise TrustedCheckError("candidate_review_evidence_invalid")
        roles.add(record["role"])
        if item["sha256"] != approved_record_sha256.get(record["role"]):
            raise TrustedCheckError("candidate_review_evidence_unapproved")
    if roles != {"evidence", "release-security"}:
        raise TrustedCheckError("candidate_review_evidence_invalid")


def _validate_test_evidence(
    items: Any,
    head: str,
    tree: str,
    approved_complete_gate_sha256: str,
) -> None:
    if not isinstance(items, list) or not items or len(items) > 32:
        raise TrustedCheckError("candidate_test_evidence_invalid")
    ids: set[str] = set()
    expected_record_keys = {
        "blockingFindings",
        "command",
        "completedAt",
        "exactHead",
        "exactTree",
        "id",
        "kind",
        "status",
        "summarySha256",
    }
    for item in items:
        if not isinstance(item, dict) or set(item) != {"record", "sha256"}:
            raise TrustedCheckError("candidate_test_evidence_invalid")
        record = item.get("record")
        evidence_id = record.get("id") if isinstance(record, dict) else None
        command = record.get("command") if isinstance(record, dict) else None
        if (
            not isinstance(record, dict)
            or set(record) != expected_record_keys
            or item.get("sha256") != sha256_bytes(canonical_json_bytes(record))
            or record.get("kind") != "test-evidence"
            or record.get("exactHead") != head
            or record.get("exactTree") != tree
            or record.get("status") != "pass"
            or record.get("blockingFindings") != []
            or not isinstance(evidence_id, str)
            or not evidence_id
            or len(evidence_id) > 128
            or evidence_id in ids
            or not isinstance(command, list)
            or not 1 <= len(command) <= 64
            or not all(
                isinstance(value, str) and 0 < len(value) <= 256
                for value in command
            )
            or not _is_sha256(record.get("summarySha256"))
            or not _is_timestamp(record.get("completedAt"))
        ):
            raise TrustedCheckError("candidate_test_evidence_invalid")
        ids.add(evidence_id)
        if (
            evidence_id == "r0-07-complete-gate"
            and item["sha256"] != approved_complete_gate_sha256
        ):
            raise TrustedCheckError("candidate_complete_gate_evidence_unapproved")
    if "r0-07-complete-gate" not in ids:
        raise TrustedCheckError("candidate_complete_gate_evidence_missing")


def validate_candidate_manifest(
    manifest: Any, expected_head: str, approvals: ApprovalInputs
) -> None:
    validate_approvals(approvals)
    expected_keys = {
        "approvedWaiverIds",
        "baseSha",
        "candidateTreeSha",
        "codex",
        "generatedAt",
        "kind",
        "manifestVersion",
        "migrationPlan",
        "previousStableTag",
        "readiness",
        "releaseBranch",
        "releaseHeadSha",
        "repository",
        "requiredChecks",
        "reviewEvidence",
        "schemaManifest",
        "sourceDateEpoch",
        "specificationStage",
        "supportedPlatforms",
        "testEvidence",
        "testedMergeTreeSha",
        "upstreamBaseSha",
        "version",
        "workflowProvenance",
    }
    if not isinstance(manifest, dict) or set(manifest) != expected_keys:
        raise TrustedCheckError("candidate_manifest_shape_invalid")
    if (
        manifest.get("kind") != "release-candidate-manifest"
        or manifest.get("manifestVersion") != 1
        or manifest.get("version") != VERSION
        or manifest.get("specificationStage") != STAGE
        or manifest.get("repository") != REPOSITORY
        or manifest.get("releaseBranch") != RELEASE_BRANCH
        or manifest.get("previousStableTag") is not None
        or manifest.get("requiredChecks") != list(REQUIRED_CHECKS)
        or manifest.get("approvedWaiverIds") != []
        or manifest.get("migrationPlan")
        != {
            "classification": "none",
            "databaseSchemaVersion": None,
            "migrations": [],
        }
        or manifest.get("supportedPlatforms")
        != [
            {
                "architecture": "x86_64",
                "distribution": "Debian GNU/Linux 12",
                "kernel": "Linux",
                "packageKind": "prebuilt-escript-source-archive",
            }
        ]
    ):
        raise TrustedCheckError("candidate_release_identity_invalid")
    head = manifest.get("releaseHeadSha")
    base = manifest.get("baseSha")
    tree = manifest.get("candidateTreeSha")
    if (
        head != expected_head
        or not _is_sha1(head)
        or not _is_sha1(base)
        or not _is_sha1(tree)
        or manifest.get("testedMergeTreeSha") != tree
        or not _is_sha1(manifest.get("upstreamBaseSha"))
    ):
        raise TrustedCheckError("candidate_git_identity_invalid")
    epoch = manifest.get("sourceDateEpoch")
    if type(epoch) is not int or epoch < 0:
        raise TrustedCheckError("candidate_source_identity_invalid")
    try:
        generated = (
            dt.datetime.fromtimestamp(epoch, tz=dt.timezone.utc)
            .replace(microsecond=0)
            .isoformat()
            .replace("+00:00", "Z")
        )
    except (OverflowError, OSError, ValueError) as error:
        raise TrustedCheckError("candidate_source_identity_invalid") from error
    codex = manifest.get("codex")
    if (
        manifest.get("generatedAt") != generated
        or not isinstance(codex, dict)
        or set(codex) != {"artifactBundleSha256", "version"}
        or codex.get("version") != "0.144.3"
        or not _is_sha256(codex.get("artifactBundleSha256"))
    ):
        raise TrustedCheckError("candidate_source_identity_invalid")
    workflow = manifest.get("workflowProvenance")
    if (
        not isinstance(workflow, dict)
        or set(workflow) != set(REQUIRED_WORKFLOW_PATHS)
        or not all(_is_sha256(value) for value in workflow.values())
    ):
        raise TrustedCheckError("candidate_workflow_provenance_invalid")
    for key, path in (
        ("readiness", READINESS_PATH),
        ("schemaManifest", SCHEMA_MANIFEST_PATH),
    ):
        record = manifest.get(key)
        if (
            not isinstance(record, dict)
            or set(record) != {"path", "sha256"}
            or record.get("path") != path
            or not _is_sha256(record.get("sha256"))
        ):
            raise TrustedCheckError("candidate_committed_evidence_invalid")
    _validate_review_evidence(
        manifest.get("reviewEvidence"),
        head,
        tree,
        approvals.review_record_sha256,
    )
    _validate_test_evidence(
        manifest.get("testEvidence"),
        head,
        tree,
        approvals.complete_gate_record_sha256,
    )


def _content_path(path: str, ref: str) -> str:
    encoded_path = urllib.parse.quote(path, safe="/")
    encoded_ref = urllib.parse.quote(ref, safe="")
    return f"/repos/{REPOSITORY}/contents/{encoded_path}?ref={encoded_ref}"


def fetch_remote_file(client: GitHubAPI, path: str, ref: str) -> bytes:
    value = client.get_json(_content_path(path, ref))
    content = value.get("content") if isinstance(value, dict) else None
    if (
        not isinstance(value, dict)
        or value.get("type") != "file"
        or value.get("path") != path
        or value.get("encoding") != "base64"
        or type(value.get("size")) is not int
        or value["size"] < 0
        or value["size"] > MAX_REMOTE_FILE_BYTES
        or not _is_sha1(value.get("sha"))
        or not isinstance(content, str)
    ):
        raise TrustedCheckError("remote_file_metadata_invalid")
    if any(character.isspace() and character != "\n" for character in content):
        raise TrustedCheckError("remote_file_encoding_invalid")
    try:
        raw = base64.b64decode(content.replace("\n", ""), validate=True)
    except (ValueError, TypeError) as error:
        raise TrustedCheckError("remote_file_encoding_invalid") from error
    if (
        len(raw) != value["size"]
        or len(raw) > MAX_REMOTE_FILE_BYTES
        or git_blob_sha1(raw) != value["sha"]
    ):
        raise TrustedCheckError("remote_file_identity_invalid")
    return raw


def _validate_readiness(value: Any, raw: bytes, manifest: Mapping[str, Any]) -> None:
    if not isinstance(value, dict) or value.get("manifestVersion") != 1:
        raise TrustedCheckError("readiness_evidence_invalid")
    runtime = value.get("runtime")
    platform = value.get("platform")
    conformance = value.get("conformance")
    checkout = value.get("checkout")
    codex = value.get("codex")
    capabilities = value.get("capabilities")
    if (
        not isinstance(runtime, dict)
        or runtime.get("overall") != "pass"
        or runtime.get("capabilities") != "pass"
        or runtime.get("blockers") != []
        or not isinstance(platform, dict)
        or platform.get("osStatus") != "pass"
        or platform.get("packageStatus") != "pass"
        or not isinstance(conformance, list)
        or len(conformance) != len(REQUIRED_CONFORMANCE_IDS)
        or not isinstance(checkout, dict)
        or not isinstance(codex, dict)
        or codex.get("version") != "0.144.3"
        or codex.get("artifactBundleSha256")
        != (manifest.get("codex") or {}).get("artifactBundleSha256")
        or not isinstance(capabilities, dict)
    ):
        raise TrustedCheckError("readiness_evidence_invalid")
    rows: dict[str, Mapping[str, Any]] = {}
    for item in conformance:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str):
            raise TrustedCheckError("readiness_evidence_invalid")
        if item["id"] in rows:
            raise TrustedCheckError("readiness_evidence_invalid")
        rows[item["id"]] = item
    if set(rows) != REQUIRED_CONFORMANCE_IDS or any(
        item.get("required") is not True or item.get("outcome") != "pass"
        for item in rows.values()
    ):
        raise TrustedCheckError("readiness_evidence_invalid")
    auth = capabilities.get("auth")
    linear = capabilities.get("linear")
    if (
        not isinstance(auth, dict)
        or (auth.get("referenceProfile") or {}).get("status") != "pass"
        or not isinstance(linear, dict)
        or not REQUIRED_LINEAR_CAPABILITIES.issubset(linear)
        or any(
            not isinstance(linear[name], dict)
            or linear[name].get("status") != "pass"
            for name in REQUIRED_LINEAR_CAPABILITIES
        )
    ):
        raise TrustedCheckError("readiness_capability_evidence_invalid")
    if sha256_bytes(raw) != (manifest.get("readiness") or {}).get("sha256"):
        raise TrustedCheckError("readiness_digest_mismatch")


def _validate_schema_manifest(
    value: Any,
    raw: bytes,
    readiness: Mapping[str, Any],
    readiness_raw: bytes,
    candidate: Mapping[str, Any],
) -> None:
    if not isinstance(value, dict) or value.get("manifestVersion") != 1:
        raise TrustedCheckError("schema_manifest_evidence_invalid")
    artifacts = value.get("artifacts")
    codex = value.get("codex")
    compatibility = value.get("compatibility")
    if (
        not isinstance(artifacts, dict)
        or artifacts.get("artifactBundleSha256")
        != (candidate.get("codex") or {}).get("artifactBundleSha256")
        or not isinstance(codex, dict)
        or codex.get("version") != "0.144.3"
        or codex.get("versionOutput") != "codex-cli 0.144.3"
        or not isinstance(compatibility, dict)
        or any(
            compatibility.get(key) != "pass"
            for key in (
                "fixtures",
                "overall",
                "runtimeCapabilities",
                "schemaContract",
                "transportConformance",
            )
        )
    ):
        raise TrustedCheckError("schema_manifest_evidence_invalid")
    runtime_evidence = compatibility.get("runtimeEvidence")
    source = (readiness.get("checkout") or {}).get("source") or {}
    if (
        not isinstance(runtime_evidence, dict)
        or runtime_evidence.get("readinessManifestSha256")
        != sha256_bytes(readiness_raw)
        or runtime_evidence.get("schemaManifestBasisSha256")
        != source.get("schemaManifestBasisSha256")
        or runtime_evidence.get("sourceSha256") != source.get("sha256")
        or sha256_bytes(raw)
        != (candidate.get("schemaManifest") or {}).get("sha256")
    ):
        raise TrustedCheckError("schema_manifest_cross_binding_invalid")


def fetch_and_validate_candidate_files(
    client: GitHubAPI,
    candidate: Mapping[str, Any],
    approved_file_sha256: Mapping[str, str],
) -> dict[str, bytes]:
    head = candidate["releaseHeadSha"]
    paths = sorted(
        set(REQUIRED_WORKFLOW_PATHS) | {READINESS_PATH, SCHEMA_MANIFEST_PATH}
    )
    files = {path: fetch_remote_file(client, path, head) for path in paths}
    workflow = candidate["workflowProvenance"]
    for path in REQUIRED_WORKFLOW_PATHS:
        observed = sha256_bytes(files[path])
        if observed != workflow[path]:
            raise TrustedCheckError("candidate_workflow_digest_mismatch")
        if observed != approved_file_sha256.get(path):
            raise TrustedCheckError("candidate_workflow_unapproved")
    readiness = _parse_json(files[READINESS_PATH], "readiness_json_invalid")
    schema = _parse_json(files[SCHEMA_MANIFEST_PATH], "schema_manifest_json_invalid")
    _validate_readiness(readiness, files[READINESS_PATH], candidate)
    _validate_schema_manifest(
        schema,
        files[SCHEMA_MANIFEST_PATH],
        readiness,
        files[READINESS_PATH],
        candidate,
    )
    return files


def validate_installation(value: Any, expected_app_id: int) -> int:
    expected_permissions = {
        "actions": "read",
        "checks": "write",
        "contents": "read",
        "metadata": "read",
        "pull_requests": "read",
    }
    if (
        not isinstance(value, dict)
        or type(value.get("id")) is not int
        or value["id"] <= 0
        or value.get("app_id") != expected_app_id
        or value.get("repository_selection") != "selected"
        or value.get("permissions") != expected_permissions
        or value.get("suspended_at") is not None
    ):
        raise TrustedCheckError("github_app_installation_invalid")
    return value["id"]


def validate_installation_scope(value: Any) -> int:
    repositories = value.get("repositories") if isinstance(value, dict) else None
    if (
        not isinstance(value, dict)
        or value.get("total_count") != 1
        or not isinstance(repositories, list)
        or len(repositories) != 1
    ):
        raise TrustedCheckError("github_app_installation_scope_invalid")
    repository = repositories[0]
    if (
        not isinstance(repository, dict)
        or repository.get("full_name") != REPOSITORY
        or type(repository.get("id")) is not int
        or repository["id"] <= 0
    ):
        raise TrustedCheckError("github_app_installation_scope_invalid")
    return repository["id"]


def validate_pull_request(
    pull: Any,
    candidate: Mapping[str, Any],
    pull_number: int,
    repository_id: int,
) -> str:
    base = pull.get("base") if isinstance(pull, dict) else None
    head = pull.get("head") if isinstance(pull, dict) else None
    base_repository = base.get("repo") if isinstance(base, dict) else None
    head_repository = head.get("repo") if isinstance(head, dict) else None
    if (
        not isinstance(pull, dict)
        or pull.get("number") != pull_number
        or pull.get("state") != "open"
        or pull.get("merged") is not False
        or pull.get("draft") is not False
        or pull.get("title") != "Release v0.1.0 — verified Symphony foundation"
        or pull.get("mergeable") is not True
        or not isinstance(base, dict)
        or base.get("ref") != BASE_BRANCH
        or base.get("sha") != candidate.get("baseSha")
        or not isinstance(head, dict)
        or head.get("ref") != RELEASE_BRANCH
        or head.get("sha") != candidate.get("releaseHeadSha")
        or not isinstance(base_repository, dict)
        or base_repository.get("full_name") != REPOSITORY
        or base_repository.get("id") != repository_id
        or not isinstance(head_repository, dict)
        or head_repository.get("full_name") != REPOSITORY
        or head_repository.get("id") != repository_id
        or not _is_sha1(pull.get("merge_commit_sha"))
    ):
        raise TrustedCheckError("release_pull_request_identity_invalid")
    return pull["merge_commit_sha"]


def validate_git_state(
    client: GitHubAPI, candidate: Mapping[str, Any], merge_commit_sha: str
) -> None:
    head = candidate["releaseHeadSha"]
    base = candidate["baseSha"]
    tree = candidate["candidateTreeSha"]
    branch = client.get_json(f"/repos/{REPOSITORY}/git/ref/heads/{BASE_BRANCH}")
    if (
        not isinstance(branch, dict)
        or (branch.get("object") or {}).get("type") != "commit"
        or (branch.get("object") or {}).get("sha") != base
    ):
        raise TrustedCheckError("release_base_advanced")
    head_commit = client.get_json(f"/repos/{REPOSITORY}/git/commits/{head}")
    if (
        not isinstance(head_commit, dict)
        or head_commit.get("sha") != head
        or (head_commit.get("tree") or {}).get("sha") != tree
    ):
        raise TrustedCheckError("release_head_tree_invalid")
    merge_commit = client.get_json(
        f"/repos/{REPOSITORY}/git/commits/{merge_commit_sha}"
    )
    parents = merge_commit.get("parents") if isinstance(merge_commit, dict) else None
    if (
        not isinstance(merge_commit, dict)
        or merge_commit.get("sha") != merge_commit_sha
        or (merge_commit.get("tree") or {}).get("sha")
        != candidate.get("testedMergeTreeSha")
        or not isinstance(parents, list)
        or [item.get("sha") for item in parents if isinstance(item, dict)]
        != [base, head]
    ):
        raise TrustedCheckError("tested_merge_tree_invalid")


def _pull_numbers(value: Any) -> set[int]:
    if not isinstance(value, list):
        return set()
    return {
        item["number"]
        for item in value
        if isinstance(item, dict) and type(item.get("number")) is int
    }


def validate_required_check_runs(
    value: Any, head: str
) -> dict[str, dict[str, int]]:
    runs = value.get("check_runs") if isinstance(value, dict) else None
    if (
        not isinstance(value, dict)
        or not isinstance(value.get("total_count"), int)
        or not isinstance(runs, list)
        or value["total_count"] != len(runs)
        or len(runs) >= 100
    ):
        raise TrustedCheckError("required_check_inventory_invalid")
    selected: dict[str, dict[str, int]] = {}
    for name in REQUIRED_CHECKS[:-1]:
        named = [
            run
            for run in runs
            if isinstance(run, dict)
            and run.get("name") == name
            and run.get("head_sha") == head
            and type(run.get("id")) is int
        ]
        if not named:
            raise TrustedCheckError("required_check_missing")
        latest = max(named, key=lambda run: run["id"])
        check_suite = latest.get("check_suite")
        if (
            latest.get("status") != "completed"
            or latest.get("conclusion") != "success"
            or (latest.get("app") or {}).get("id") != GITHUB_ACTIONS_APP_ID
            or not isinstance(check_suite, dict)
            or type(check_suite.get("id")) is not int
            or check_suite["id"] <= 0
        ):
            raise TrustedCheckError("required_check_not_successful")
        selected[name] = {
            "checkRunId": latest["id"],
            "checkSuiteId": check_suite["id"],
        }
    return selected


def validate_check_suite(value: Any, suite_id: int, head: str) -> None:
    if (
        not isinstance(value, dict)
        or value.get("id") != suite_id
        or value.get("head_branch") != RELEASE_BRANCH
        or value.get("head_sha") != head
        or value.get("status") != "completed"
        or value.get("conclusion") != "success"
        or (value.get("app") or {}).get("id") != GITHUB_ACTIONS_APP_ID
        or (value.get("repository") or {}).get("full_name") != REPOSITORY
    ):
        raise TrustedCheckError("required_check_suite_invalid")


def validate_release_gate_runs(
    value: Any, head: str
) -> dict[str, Any]:
    runs = value.get("workflow_runs") if isinstance(value, dict) else None
    if (
        not isinstance(value, dict)
        or not isinstance(value.get("total_count"), int)
        or not isinstance(runs, list)
        or value["total_count"] != len(runs)
        or len(runs) >= 100
    ):
        raise TrustedCheckError("release_gate_run_inventory_invalid")
    matching = [
        run
        for run in runs
        if isinstance(run, dict)
        and run.get("head_sha") == head
        and run.get("head_branch") == RELEASE_BRANCH
        and run.get("event") == "pull_request"
        and run.get("name") == "release-gate"
        and run.get("path") == RELEASE_GATE_WORKFLOW_PATH
        and (run.get("repository") or {}).get("full_name") == REPOSITORY
        and (run.get("head_repository") or {}).get("full_name") == REPOSITORY
        and type(run.get("check_suite_id")) is int
        and run["check_suite_id"] > 0
        and type(run.get("id")) is int
    ]
    if not matching:
        raise TrustedCheckError("release_gate_run_missing")
    latest = max(matching, key=lambda run: run["id"])
    if (
        latest.get("status") != "completed"
        or latest.get("conclusion") != "success"
        or type(latest.get("run_attempt")) is not int
        or latest["run_attempt"] <= 0
    ):
        raise TrustedCheckError("release_gate_run_not_successful")
    return latest


def validate_required_workflow_run(
    value: Any,
    head: str,
    workflow_path: str,
    workflow_name: str,
    check_suite_id: int,
) -> dict[str, Any]:
    runs = value.get("workflow_runs") if isinstance(value, dict) else None
    if (
        not isinstance(value, dict)
        or not isinstance(value.get("total_count"), int)
        or not isinstance(runs, list)
        or value["total_count"] != len(runs)
        or len(runs) >= 100
    ):
        raise TrustedCheckError("required_workflow_inventory_invalid")
    matching = [
        run
        for run in runs
        if isinstance(run, dict)
        and run.get("head_sha") == head
        and run.get("head_branch") == RELEASE_BRANCH
        and run.get("event") == "pull_request"
        and run.get("name") == workflow_name
        and run.get("path") == workflow_path
        and (run.get("repository") or {}).get("full_name") == REPOSITORY
        and (run.get("head_repository") or {}).get("full_name") == REPOSITORY
        and type(run.get("check_suite_id")) is int
        and run["check_suite_id"] > 0
        and type(run.get("id")) is int
    ]
    if not matching:
        raise TrustedCheckError("required_workflow_run_missing")
    latest = max(matching, key=lambda run: run["id"])
    if (
        latest.get("status") != "completed"
        or latest.get("conclusion") != "success"
        or type(latest.get("run_attempt")) is not int
        or latest["run_attempt"] <= 0
    ):
        raise TrustedCheckError("required_workflow_run_not_successful")
    if latest.get("check_suite_id") != check_suite_id:
        raise TrustedCheckError("required_workflow_check_suite_mismatch")
    return latest


def validate_release_gate_jobs(value: Any, head: str) -> None:
    jobs = value.get("jobs") if isinstance(value, dict) else None
    if (
        not isinstance(value, dict)
        or value.get("total_count") != 1
        or not isinstance(jobs, list)
        or len(jobs) != 1
    ):
        raise TrustedCheckError("release_gate_job_inventory_invalid")
    job = jobs[0]
    steps = job.get("steps") if isinstance(job, dict) else None
    if (
        not isinstance(job, dict)
        or job.get("name") != RELEASE_GATE_JOB_NAME
        or job.get("head_sha") != head
        or job.get("status") != "completed"
        or job.get("conclusion") != "success"
        or not isinstance(steps, list)
    ):
        raise TrustedCheckError("release_gate_job_not_successful")
    for required in REQUIRED_RELEASE_GATE_STEPS:
        matching = [
            step
            for step in steps
            if isinstance(step, dict) and step.get("name") == required
        ]
        if (
            len(matching) != 1
            or matching[0].get("status") != "completed"
            or matching[0].get("conclusion") != "success"
        ):
            raise TrustedCheckError("release_gate_step_not_successful")


def validate_artifact_inventory(value: Any, head: str, run_id: int) -> dict[str, Any]:
    artifacts = value.get("artifacts") if isinstance(value, dict) else None
    if (
        not isinstance(value, dict)
        or value.get("total_count") != 1
        or not isinstance(artifacts, list)
        or len(artifacts) != 1
    ):
        raise TrustedCheckError("release_gate_artifact_inventory_invalid")
    artifact = artifacts[0]
    workflow_run = artifact.get("workflow_run") if isinstance(artifact, dict) else None
    if (
        not isinstance(artifact, dict)
        or type(artifact.get("id")) is not int
        or artifact["id"] <= 0
        or artifact.get("name") != RELEASE_GATE_ARTIFACT_PREFIX + head
        or artifact.get("expired") is not False
        or type(artifact.get("size_in_bytes")) is not int
        or not 0 < artifact["size_in_bytes"] <= MAX_ARTIFACT_BYTES
        or not isinstance(artifact.get("digest"), str)
        or re.fullmatch(r"sha256:[0-9a-f]{64}", artifact["digest"]) is None
        or not isinstance(workflow_run, dict)
        or workflow_run.get("id") != run_id
        or workflow_run.get("head_sha") != head
    ):
        raise TrustedCheckError("release_gate_artifact_invalid")
    return artifact


def validate_release_gate_artifact(
    archive: bytes,
    artifact: Mapping[str, Any],
    head: str,
    tree: str,
) -> None:
    if (
        not archive
        or len(archive) > MAX_ARTIFACT_BYTES
        or sha256_bytes(archive) != str(artifact["digest"]).removeprefix("sha256:")
    ):
        raise TrustedCheckError("release_gate_artifact_digest_mismatch")
    try:
        with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
            entries = zipped.infolist()
            if len(entries) != 1 or entries[0].filename != RELEASE_GATE_RECEIPT:
                raise TrustedCheckError("release_gate_artifact_shape_invalid")
            entry = entries[0]
            mode = (entry.external_attr >> 16) & 0xFFFF
            file_type = stat.S_IFMT(mode)
            if (
                entry.flag_bits & 0x1
                or entry.is_dir()
                or file_type not in {0, stat.S_IFREG}
                or entry.file_size > MAX_ARTIFACT_ENTRY_BYTES
                or entry.compress_size > MAX_ARTIFACT_BYTES
            ):
                raise TrustedCheckError("release_gate_artifact_entry_invalid")
            raw = zipped.read(entry)
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        raise TrustedCheckError("release_gate_artifact_zip_invalid") from error
    receipt = _parse_json(raw, "release_gate_receipt_json_invalid")
    expected = {
        "blockingFindings": [],
        "exactHead": head,
        "exactTree": tree,
        "id": "r0-07-release-specific-gate",
        "kind": "test-evidence",
        "status": "pass",
    }
    if not isinstance(receipt, dict) or receipt != expected or canonical_json_bytes(receipt) != raw:
        raise TrustedCheckError("release_gate_receipt_invalid")


def _pull_path(pull_number: int) -> str:
    return f"/repos/{REPOSITORY}/pulls/{pull_number}"


def _main_ref_path() -> str:
    return f"/repos/{REPOSITORY}/git/ref/heads/{BASE_BRANCH}"


def _check_runs_path(head: str) -> str:
    return (
        f"/repos/{REPOSITORY}/commits/{head}/check-runs"
        "?filter=all&per_page=100"
    )


def _workflow_runs_path(workflow_file: str, head: str) -> str:
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*\.yml", workflow_file):
        raise TrustedCheckError("workflow_file_invalid")
    encoded = urllib.parse.urlencode(
        {
            "event": "pull_request",
            "head_sha": head,
            "per_page": 100,
        }
    )
    return (
        f"/repos/{REPOSITORY}/actions/workflows/{workflow_file}/runs?{encoded}"
    )


def _release_gate_runs_path(head: str) -> str:
    return _workflow_runs_path("release-gate.yml", head)


def _same_pr_identity(first: Mapping[str, Any], second: Mapping[str, Any]) -> bool:
    def identity(value: Mapping[str, Any]) -> tuple[Any, ...]:
        base = value.get("base") or {}
        head = value.get("head") or {}
        return (
            value.get("number"),
            value.get("state"),
            value.get("merged"),
            value.get("draft"),
            value.get("title"),
            value.get("body"),
            value.get("mergeable"),
            value.get("merge_commit_sha"),
            base.get("ref"),
            base.get("sha"),
            head.get("ref"),
            head.get("sha"),
        )

    return identity(first) == identity(second)


def _check_payload(
    pull_number: int, head: str, candidate_raw: bytes, candidate_sha: str
) -> dict[str, Any]:
    attachment = base64.b64encode(candidate_raw).decode("ascii")
    return {
        "conclusion": "success",
        "details_url": f"https://github.com/{REPOSITORY}/pull/{pull_number}",
        "external_id": candidate_sha,
        "head_sha": head,
        "name": CHECK_NAME,
        "output": {
            "summary": f"candidate-manifest-sha256:{candidate_sha}",
            "text": f"candidate-manifest-base64:{attachment}",
            "title": CHECK_TITLE,
        },
        "status": "completed",
    }


def _validate_created_check(
    value: Any,
    payload: Mapping[str, Any],
    expected_app_id: int,
) -> int:
    output = value.get("output") if isinstance(value, dict) else None
    expected_output = payload.get("output")
    if (
        not isinstance(value, dict)
        or type(value.get("id")) is not int
        or value["id"] <= 0
        or any(
            value.get(key) != payload.get(key)
            for key in (
                "name",
                "head_sha",
                "details_url",
                "external_id",
                "status",
                "conclusion",
            )
        )
        or not isinstance(output, dict)
        or not isinstance(expected_output, dict)
        or any(
            output.get(key) != expected_output.get(key)
            for key in ("title", "summary", "text")
        )
        or (value.get("app") or {}).get("id") != expected_app_id
    ):
        raise TrustedCheckError("created_check_run_identity_invalid")
    return value["id"]


def existing_trusted_check_id(
    client: GitHubAPI,
    inventory: Any,
    payload: Mapping[str, Any],
    expected_app_id: int,
) -> int | None:
    runs = inventory.get("check_runs") if isinstance(inventory, dict) else None
    if not isinstance(runs, list):
        raise TrustedCheckError("required_check_inventory_invalid")
    named = [
        run
        for run in runs
        if isinstance(run, dict)
        and run.get("name") == CHECK_NAME
        and run.get("head_sha") == payload.get("head_sha")
        and (run.get("app") or {}).get("id") == expected_app_id
    ]
    if not named:
        return None
    if not all(type(run.get("id")) is int and run["id"] > 0 for run in named):
        raise TrustedCheckError("trusted_check_inventory_invalid")
    latest = max(named, key=lambda run: run["id"])
    selected = client.get_json(
        f"/repos/{REPOSITORY}/check-runs/{latest['id']}"
    )
    try:
        selected_id = _validate_created_check(selected, payload, expected_app_id)
    except TrustedCheckError as error:
        raise TrustedCheckError("trusted_check_latest_mismatch") from error
    if selected_id != latest["id"]:
        raise TrustedCheckError("trusted_check_revalidation_failed")
    return latest["id"]


def attest(
    pull_number: int,
    head: str,
    token: str,
    approvals: ApprovalInputs,
    *,
    transport: Any | None = None,
) -> dict[str, Any]:
    if type(pull_number) is not int or not 1 <= pull_number <= 2_147_483_647:
        raise TrustedCheckError("pull_request_number_invalid")
    if not _is_sha1(head):
        raise TrustedCheckError("release_head_sha_invalid")
    validate_approvals(approvals)
    client = GitHubAPI(token, transport)

    installation_record = client.get_json("/installation")
    validate_installation(installation_record, approvals.trusted_app_id)
    installation = client.get_json("/installation/repositories?per_page=100")
    repository_id = validate_installation_scope(installation)

    pull = client.get_json(_pull_path(pull_number))
    if not isinstance(pull, dict):
        raise TrustedCheckError("release_pull_request_identity_invalid")
    candidate, candidate_raw, candidate_sha = candidate_from_pr_body(pull.get("body"))
    validate_candidate_manifest(candidate, head, approvals)
    merge_commit_sha = validate_pull_request(
        pull, candidate, pull_number, repository_id
    )
    validate_git_state(client, candidate, merge_commit_sha)
    fetch_and_validate_candidate_files(
        client, candidate, approvals.file_sha256
    )

    checks_value = client.get_json(_check_runs_path(head))
    check_ids = validate_required_check_runs(checks_value, head)
    required_workflows: dict[str, dict[str, Any]] = {}
    for check_name, workflow_file in (
        ("make-all", "make-all.yml"),
        ("pr-description-lint", "pr-description-lint.yml"),
    ):
        check_suite_id = check_ids[check_name]["checkSuiteId"]
        suite_value = client.get_json(
            f"/repos/{REPOSITORY}/check-suites/{check_suite_id}"
        )
        validate_check_suite(suite_value, check_suite_id, head)
        workflow_value = client.get_json(_workflow_runs_path(workflow_file, head))
        required_workflows[check_name] = validate_required_workflow_run(
            workflow_value,
            head,
            f".github/workflows/{workflow_file}",
            check_name,
            check_suite_id,
        )

    runs_value = client.get_json(_release_gate_runs_path(head))
    run = validate_release_gate_runs(runs_value, head)
    run_id = run["id"]
    jobs = client.get_json(
        f"/repos/{REPOSITORY}/actions/runs/{run_id}/jobs?filter=latest&per_page=100"
    )
    validate_release_gate_jobs(jobs, head)
    artifacts = client.get_json(
        f"/repos/{REPOSITORY}/actions/runs/{run_id}/artifacts?per_page=100"
    )
    artifact = validate_artifact_inventory(artifacts, head, run_id)
    archive = client.download_artifact(artifact["id"])
    validate_release_gate_artifact(
        archive, artifact, head, candidate["candidateTreeSha"]
    )

    # Re-read every mutable decision surface immediately before the sole write.
    final_pull = client.get_json(_pull_path(pull_number))
    if (
        not isinstance(final_pull, dict)
        or not _same_pr_identity(pull, final_pull)
        or validate_pull_request(final_pull, candidate, pull_number, repository_id)
        != merge_commit_sha
    ):
        raise TrustedCheckError("release_pull_request_changed")
    final_branch = client.get_json(_main_ref_path())
    if (
        not isinstance(final_branch, dict)
        or (final_branch.get("object") or {}).get("type") != "commit"
        or (final_branch.get("object") or {}).get("sha") != candidate["baseSha"]
    ):
        raise TrustedCheckError("release_base_advanced")
    final_checks_value = client.get_json(_check_runs_path(head))
    final_checks = validate_required_check_runs(final_checks_value, head)
    if final_checks != check_ids:
        raise TrustedCheckError("required_check_inventory_changed")
    for check_name, workflow_file in (
        ("make-all", "make-all.yml"),
        ("pr-description-lint", "pr-description-lint.yml"),
    ):
        final_workflow = validate_required_workflow_run(
            client.get_json(_workflow_runs_path(workflow_file, head)),
            head,
            f".github/workflows/{workflow_file}",
            check_name,
            final_checks[check_name]["checkSuiteId"],
        )
        initial_workflow = required_workflows[check_name]
        if (
            final_workflow.get("id") != initial_workflow.get("id")
            or final_workflow.get("run_attempt")
            != initial_workflow.get("run_attempt")
        ):
            raise TrustedCheckError("required_workflow_run_changed")
    final_run = validate_release_gate_runs(
        client.get_json(_release_gate_runs_path(head)), head
    )
    if (
        final_run.get("id") != run_id
        or final_run.get("run_attempt") != run.get("run_attempt")
    ):
        raise TrustedCheckError("release_gate_run_changed")

    payload = _check_payload(pull_number, head, candidate_raw, candidate_sha)
    check_run_id = existing_trusted_check_id(
        client,
        final_checks_value,
        payload,
        approvals.trusted_app_id,
    )
    if check_run_id is None:
        created = client.post_json(f"/repos/{REPOSITORY}/check-runs", payload)
        check_run_id = _validate_created_check(
            created, payload, approvals.trusted_app_id
        )
    return {
        "candidateManifestSha256": candidate_sha,
        "checkRunId": check_run_id,
        "checkRunName": CHECK_NAME,
        "headSha": head,
        "kind": "trusted-release-check-publication",
        "pullRequestNumber": pull_number,
        "repository": REPOSITORY,
        "status": "pass",
    }


def approvals_from_args(args: argparse.Namespace) -> ApprovalInputs:
    approvals = ApprovalInputs(
        file_sha256={
            ".github/workflows/make-all.yml": args.make_all_sha256,
            ".github/workflows/pr-description-lint.yml": (
                args.pr_description_lint_sha256
            ),
            ".github/workflows/release-gate.yml": args.release_gate_sha256,
            ".github/workflows/publish-release.yml": (
                args.publish_release_sha256
            ),
            "scripts/release/release.py": args.release_controller_sha256,
        },
        review_record_sha256={
            "evidence": args.evidence_review_record_sha256,
            "release-security": args.security_review_record_sha256,
        },
        complete_gate_record_sha256=args.complete_gate_record_sha256,
        trusted_app_id=args.trusted_app_id,
    )
    validate_approvals(approvals)
    return approvals


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Seal or run the out-of-band R0-07 trusted CheckRun attestor."
    )
    commands = parser.add_subparsers(dest="command", required=True)
    seal = commands.add_parser(
        "seal", help="copy this reviewed attestor into an owner-only external path"
    )
    seal.add_argument("--output", required=True)

    attest_parser = commands.add_parser(
        "attest", help="validate live evidence and create the trusted CheckRun"
    )
    attest_parser.add_argument("--pull-request", type=int, required=True)
    attest_parser.add_argument("--head-sha", required=True)
    attest_parser.add_argument("--attestor-sha256", required=True)
    attest_parser.add_argument("--trusted-app-id", type=int, required=True)
    attest_parser.add_argument("--make-all-sha256", required=True)
    attest_parser.add_argument("--pr-description-lint-sha256", required=True)
    attest_parser.add_argument("--release-gate-sha256", required=True)
    attest_parser.add_argument("--publish-release-sha256", required=True)
    attest_parser.add_argument("--release-controller-sha256", required=True)
    attest_parser.add_argument("--evidence-review-record-sha256", required=True)
    attest_parser.add_argument("--security-review-record-sha256", required=True)
    attest_parser.add_argument("--complete-gate-record-sha256", required=True)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    try:
        args = parse_args(argv)
        if sys.flags.isolated != 1:
            raise TrustedCheckError("attestor_python_isolation_required")
        if args.command == "seal":
            receipt = seal_attestor(args.output)
        else:
            verify_sealed_runtime(args.attestor_sha256)
            approvals = approvals_from_args(args)
            token = consume_token(os.environ)
            receipt = attest(
                args.pull_request,
                args.head_sha,
                token,
                approvals,
            )
    except TrustedCheckError as error:
        print(f"trusted_check_error:{error}", file=sys.stderr)
        return 78
    sys.stdout.buffer.write(canonical_json_bytes(receipt))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
