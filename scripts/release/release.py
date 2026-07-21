#!/usr/bin/env python3
# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0
"""Fail-closed Release 0 candidate, package, and publication tooling.

The candidate manifest is deliberately written outside the checkout. Embedding
an exact-head manifest in the commit it names would create an impossible
self-reference; the protected release workflow and trusted external attestor
bind the canonical artifact to the exact pull-request head instead.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import datetime as dt
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
from pathlib import PurePosixPath
import platform
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from typing import Any, Iterable, Mapping, Sequence
import urllib.parse
import urllib.request
import zipfile


ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = "farhaanlevy/symphony-studio"
UPSTREAM_REPOSITORY = "openai/symphony"
RELEASE_BRANCH = "release/v0.1.0"
VERSION = "v0.1.0"
STAGE = "R0"
REQUIRED_CONTEXT = "studio/release-gate"
GITHUB_ACTIONS_APP_ID = 15368
REQUIRED_CHECKS = ["make-all", "pr-description-lint", REQUIRED_CONTEXT]
REQUIRED_WORKFLOW_PATHS = (
    ".github/workflows/make-all.yml",
    ".github/workflows/pr-description-lint.yml",
    ".github/workflows/release-gate.yml",
    ".github/workflows/publish-release.yml",
    "scripts/release/release.py",
)
PUBLICATION_PREDICATE_TYPE = (
    "https://github.com/farhaanlevy/symphony-studio/"
    "attestations/release-publication/v1"
)
SUPPORTED_PLATFORM = {
    "architecture": "x86_64",
    "distribution": "Debian GNU/Linux 12",
    "kernel": "Linux",
    "packageKind": "prebuilt-escript-source-archive",
}
MAX_JSON_BYTES = 1024 * 1024
MAX_CANDIDATE_MANIFEST_BYTES = 32 * 1024
MAX_WORKFLOW_DISPATCH_INPUT_CHARS = 65_535
FIXED_RELEASE_BUILD_ROOT = Path("/tmp/symphony-studio-v0.1.0-build")
MAX_ARCHIVE_FILES = 5_000
MAX_ARCHIVE_FILE_BYTES = 64 * 1024 * 1024
MAX_ARCHIVE_TOTAL_BYTES = 512 * 1024 * 1024
MAX_ARCHIVE_PATH_BYTES = 4_096
MAX_TREE_RECORD_BYTES = MAX_ARCHIVE_PATH_BYTES + 256
HEX_VERSION = "2.4.2"
REBAR3_SHA512 = (
    "992fd755b7926fae455e5e07d9d195f4d3e7f181609eed1b9cabfe548624df10"
    "d148cd4b59bda40bebb185d3d68f9a9fd68a70b294101c8ad9cf0fadcc683d24"
)
DEPENDENCY_BUILD_PATCHES = (
    {
        "dependency": "bandit",
        "version": "1.10.3",
        "path": "lib/bandit.ex",
        "originalSha256": "3a7bde4381c7ecd4932933671c1de39a987ab92cd32547664f38e877a484b21b",
        "patchedSha256": "c082ceeda7be22095447b9bb55ac617e9aef0aea47198d97ebbb38a7c357f8cd",
        "purpose": "sort compile-time server-option keys under OTP 28",
        "replacements": (
            (
                b"                        |> Map.keys()\n",
                b"                        |> Map.keys()\n                        |> Enum.sort()\n",
            ),
        ),
    },
    {
        "dependency": "mint",
        "version": "1.7.1",
        "path": "lib/mint/http2/frame.ex",
        "originalSha256": "c07a9fa324667c2b94392874291c9b74bd254b0e9dcb3a6068bf40b5e52c3d95",
        "patchedSha256": "3c18b8ed239a8c305b8299da808347135a56df4b01a4ec3ecea00a417ffdf394",
        "purpose": "sort compile-time HTTP/2 type and flag maps under OTP 28",
        "replacements": (
            (
                b"  for {type, _code} <- @types do\n",
                b"  for {type, _code} <- Enum.sort(@types) do\n",
            ),
            (
                b"  for {frame, flags} <- @flags,\n",
                b"  for {frame, flags} <- Enum.sort(@flags),\n",
            ),
            (
                b"  for {frame, type} <- @types do\n",
                b"  for {frame, type} <- Enum.sort(@types) do\n",
            ),
        ),
    },
    {
        "dependency": "phoenix_live_view",
        "version": "1.1.25",
        "path": "lib/phoenix_live_view/engine.ex",
        "originalSha256": "9ed8b388cc3b09dafefb9eb2dd6eda3bfec4a03e85c594d458a9f5c557d16b03",
        "patchedSha256": "f0d300bb72625e1cc0c7f5e7a7e1b1421c55902770aea518fa6393d5072fed64",
        "purpose": "remove nondeterministic AST metadata from HEEx fingerprints under OTP 28",
        "replacements": (
            (
                b"      [block | static]\n      |> :erlang.term_to_binary()\n",
                b"      [Macro.to_string(block) | static]\n"
                b"      |> :erlang.term_to_binary([:deterministic])\n",
            ),
        ),
    },
)
RUNTIME_DEPENDENCY_INVENTORY_PATH = (
    "docs/releases/v0.1.0/runtime-dependencies.json"
)
THIRD_PARTY_NOTICES_PATH = "THIRD_PARTY_NOTICES.txt"
ALLOWED_RUNTIME_LICENSES = {
    "Apache-2.0",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "MIT",
}
EXPECTED_ESCRIPT_PRIV_FILES = {
    "erlexec/priv/x86_64-pc-linux-gnu/exec-port",
}
CODEX_SCHEMA_VERSION = "0.144.3"
SYMPHONY_PRIV_PATH = "elixir/priv"
CODEX_SCHEMA_PRIV_PATH = f"codex_schema/{CODEX_SCHEMA_VERSION}"
CODEX_SCHEMA_REQUIRED_FILES = {
    "SEMANTIC-SHA256SUMS",
    "manifest.json",
    "method-field-matrix.json",
}
SYMPHONY_PRIV_CAPTURE_FILES = {
    f"{CODEX_SCHEMA_PRIV_PATH}/{relative}"
    for relative in CODEX_SCHEMA_REQUIRED_FILES
} | {"codex_schema/CODEX_VERSION"}
SYMPHONY_PRIV_REQUIRED_FILES = SYMPHONY_PRIV_CAPTURE_FILES | {
    "codex_schema/NOTICE.md",
    "codex_schema/README.md",
    "hooks/studio_depth_guard.exs",
    "static/dashboard.css",
    "static/favicon.png",
}
MAX_ESCRIPT_APPLICATION_BYTES = 2 * 1024 * 1024
NOTICE_EMBEDDED_BODY_RECORDS = (
    {
        "bodyMarker": b"## License\n",
        "heading": b"COMPONENT ATTRIBUTION: nimble_pool 1.1.0 README.md license section",
        "sha256": "9b39219d43b3a21a31dd005a288639dca1050cc631a4de8a16f9dcb7473eaae5",
        "size": 609,
    },
    {
        "bodyMarker": b"Copyright (c) 2018, Chris McCord and Erlang Solutions\n",
        "heading": b"TELEMETRY 1.3.0 NOTICE",
        "sha256": "f72767446cdb9e79c2e6931f54106408bfc0f47e66c3b21690ba49f7af399757",
        "size": 579,
    },
    {
        "bodyMarker": b"BSD LICENSE\n",
        "heading": b"LICENSE: erlexec 2.3.4 LICENSE",
        "sha256": "14b7edb0c725c101e7ca20553627744257cf7d5f77792cb0d722075b68ed7ef2",
        "size": 1487,
    },
)
PLATFORM_RECEIPT_NAME = "debian-clean-install.json"
PUBLIC_ARTIFACT_AUDIT_NAME = "public-artifact-audit.json"
PACKAGE_ASSET_NAMES = {
    "THIRD_PARTY_NOTICES.txt",
    "codex-schema-manifest.json",
    "implementation-readiness.json",
    "migration-report.json",
    "provenance.json",
    PUBLIC_ARTIFACT_AUDIT_NAME,
    "release-candidate-manifest.json",
    "sbom.spdx.json",
    "symphony-studio-0.1.0-linux-x86_64.tar.gz",
    "test-summary.json",
    "upstream-baseline-return.json",
}
FINAL_RELEASE_ASSET_NAMES = PACKAGE_ASSET_NAMES | {
    PLATFORM_RECEIPT_NAME,
    "release-manifest.json",
    "release-package-manifest.json",
    "SHA256SUMS",
}
INHERITED_MEDIA_SHA256 = {
    ".github/media/elixir-screenshot.png": "b023cb2e25ba144be6b64f1e522b06221a6297e214ec5419db13511331a2981d",
    ".github/media/symphony-demo-poster.jpg": "808d8367a378ea439bc53395e4e9fa703ef86fcd187e23af5c4bd419dfb1fb2b",
    ".github/media/symphony-demo.mp4": "0baa5f6276ea9a790d8072e690c547ed02afb3f95312266d3f27a923d4f58ec1",
    "elixir/priv/static/favicon.png": "27913e982b8769bf1ddcdd2b47d0d395597e74ef8d5bca17ef2b428c08046f79",
}
MEDIA_SUFFIXES = {
    ".aac",
    ".aif",
    ".aiff",
    ".aup3",
    ".avif",
    ".drp",
    ".flac",
    ".gif",
    ".jpeg",
    ".jpg",
    ".m4a",
    ".mkv",
    ".mov",
    ".mp3",
    ".mp4",
    ".ogg",
    ".png",
    ".prproj",
    ".svg",
    ".wav",
    ".webm",
    ".webp",
}
FORBIDDEN_ARCHIVE_SEGMENTS = {
    ".elixir_ls",
    "_build",
    "cover",
    "coverage",
    "deps",
    "node_modules",
    "session-storage",
}
FORBIDDEN_ARCHIVE_BASENAMES = {
    ".env",
    "auth.json",
    "cookies.sqlite",
    "erl_crash.dump",
    "release-manifest.local.json",
}
FORBIDDEN_ARCHIVE_SUFFIXES = {
    ".beam",
    ".cookie",
    ".db",
    ".dump",
    ".har",
    ".log",
    ".plt",
    ".sqlite",
    ".sqlite3",
}
PUBLIC_SECRET_PATTERNS = {
    "aws_access_key": re.compile(rb"\bAKIA[0-9A-Z]{16}\b"),
    "devbox_path": re.compile(
        rb"(?:^|[^A-Za-z0-9_])" + b"/home/" + b"codexdev" + rb"(?:/|$)"
    ),
    "github_token": re.compile(
        rb"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"
    ),
    "linear_token": re.compile(rb"\blin_api_[A-Za-z0-9_-]{20,}\b"),
    "openai_token": re.compile(rb"(?:^|[^A-Za-z0-9])sk-(?:proj-)?[A-Za-z0-9_-]{20,}"),
    "private_key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    "protected_pointer": re.compile(
        b"_".join((b"SYMPHONY", b"LINEAR", b"ENV", b"FILE"))
    ),
    "slack_token": re.compile(rb"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
    "windows_user_path": re.compile(rb"[A-Za-z]:\\Users\\"),
}
SHA1_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
VERSION_RE = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")
FORBIDDEN_ENV_PARTS = (
    "AUTH",
    "CREDENTIAL",
    "GITHUB",
    "KEY",
    "LINEAR",
    "SECRET",
    "TOKEN",
)


class ReleaseError(RuntimeError):
    """A content-free release-policy failure safe to show in logs."""


def canonical_json_bytes(value: Any) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        + "\n"
    ).encode("utf-8")


def candidate_manifest_attachment(raw: bytes) -> str:
    if len(raw) > MAX_CANDIDATE_MANIFEST_BYTES:
        raise ReleaseError("candidate_manifest_transport_too_large")
    return base64.b64encode(raw).decode("ascii")


def publication_dispatch_inputs(
    candidate_raw: bytes,
    merged_sha: str,
    pull_request_number: int,
) -> dict[str, str]:
    values = {
        "candidate_manifest_base64": candidate_manifest_attachment(candidate_raw),
        "candidate_manifest_sha256": sha256_bytes(candidate_raw),
        "merged_sha": merged_sha,
        "pull_request_number": str(pull_request_number),
        "version": VERSION,
    }
    payload = json.dumps(values, sort_keys=True, separators=(",", ":"))
    if len(payload) > MAX_WORKFLOW_DISPATCH_INPUT_CHARS:
        raise ReleaseError("publication_workflow_dispatch_payload_too_large")
    return values


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(
    argv: Sequence[str],
    *,
    cwd: Path = ROOT,
    env: Mapping[str, str] | None = None,
    check: bool = True,
    timeout: int = 1800,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        list(argv),
        cwd=cwd,
        env=None if env is None else dict(env),
        text=True,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )
    if check and result.returncode != 0:
        raise ReleaseError(f"command_failed:{Path(argv[0]).name}:{result.returncode}")
    return result


def git(*args: str, cwd: Path = ROOT) -> str:
    return run(("git", *args), cwd=cwd).stdout.strip()


def git_bytes(commit: str, path: str) -> bytes:
    result = subprocess.run(
        ["git", "show", f"{commit}:{path}"],
        cwd=ROOT,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise ReleaseError(f"missing_git_path:{path}")
    return result.stdout


def atomic_write(path: Path, value: bytes, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as handle:
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def is_within(path: Path, parent: Path) -> bool:
    try:
        path.resolve().relative_to(parent.resolve())
        return True
    except ValueError:
        return False


def external_path(path_text: str, *, directory: bool = False) -> Path:
    path = Path(os.path.abspath(os.path.expanduser(path_text)))
    if is_within(path, ROOT):
        raise ReleaseError("generated_release_artifact_must_be_outside_checkout")
    parent = path if directory else path.parent
    missing: list[Path] = []
    cursor = parent
    while not cursor.exists():
        missing.append(cursor)
        if cursor.parent == cursor:
            raise ReleaseError("generated_release_parent_missing_root")
        cursor = cursor.parent
    for component in (cursor, *reversed(missing)):
        if component in missing:
            component.mkdir(mode=0o700)
        metadata = component.lstat()
        if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
            raise ReleaseError("generated_release_parent_must_be_real_directory")
    if path.exists() and path.is_symlink():
        raise ReleaseError("generated_release_artifact_must_not_be_symlink")
    return path


def load_canonical_json(path: Path) -> tuple[dict[str, Any], bytes]:
    if not path.is_file() or path.is_symlink() or path.stat().st_size > MAX_JSON_BYTES:
        raise ReleaseError(f"invalid_json_file:{path.name}")
    raw = path.read_bytes()
    try:
        parsed = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReleaseError(f"invalid_json:{path.name}") from error
    if not isinstance(parsed, dict) or canonical_json_bytes(parsed) != raw:
        raise ReleaseError(f"noncanonical_json:{path.name}")
    return parsed, raw


def iso_from_epoch(epoch: int) -> str:
    return (
        dt.datetime.fromtimestamp(epoch, tz=dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def gh_api(path: str, *, allow_missing: bool = False) -> Any:
    result = run(("gh", "api", path), check=False, timeout=60)
    if result.returncode != 0:
        if allow_missing and "HTTP 404" in result.stderr:
            return None
        raise ReleaseError("github_api_read_failed")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ReleaseError("github_api_invalid_json") from error


def check(checks: list[dict[str, str]], name: str, passed: bool, detail: str) -> None:
    checks.append({"detail": detail, "id": name, "status": "pass" if passed else "fail"})


def doctor_report(
    expected_app_id: int | None,
    *,
    expected_head: str | None = None,
    require_admin: bool = True,
) -> dict[str, Any]:
    checks: list[dict[str, str]] = []
    blockers: list[str] = []

    branch = git("branch", "--show-current")
    if expected_head is None:
        branch_ok = branch in {RELEASE_BRANCH, "main"}
        branch_detail = branch or "detached"
    else:
        observed_head = git("rev-parse", "HEAD")
        branch_ok = (
            bool(SHA1_RE.fullmatch(expected_head))
            and observed_head == expected_head
            and branch in {"", RELEASE_BRANCH, "main"}
        )
        branch_detail = "exact detached candidate" if branch_ok and not branch else branch or "head mismatch"
    check(checks, "release_branch", branch_ok, branch_detail)

    status = git("status", "--porcelain=v1", "--untracked-files=all")
    check(checks, "clean_worktree", status == "", "clean" if status == "" else "dirty")

    origin = git("remote", "get-url", "origin")
    upstream = git("remote", "get-url", "upstream")
    upstream_push = git("remote", "get-url", "--push", "upstream")
    safe_remotes = (
        origin
        in {
            "https://github.com/farhaanlevy/symphony-studio",
            "https://github.com/farhaanlevy/symphony-studio.git",
        }
        and upstream
        in {
            "https://github.com/openai/symphony",
            "https://github.com/openai/symphony.git",
        }
        and upstream_push == "DISABLED"
        and "@" not in origin
        and "@" not in upstream
    )
    check(checks, "remote_policy", safe_remotes, "credential-free exact fork/upstream remotes")

    upstream_base = (ROOT / "UPSTREAM_BASE").read_text(encoding="utf-8").strip()
    spec_unchanged = (ROOT / "SPEC.md").read_bytes() == git_bytes(upstream_base, "SPEC.md")
    check(checks, "upstream_spec", spec_unchanged, "root SPEC.md matches locked upstream")

    auth = run(("gh", "auth", "status"), check=False, timeout=30)
    check(checks, "github_auth", auth.returncode == 0, "authenticated" if auth.returncode == 0 else "unavailable")

    repo = gh_api(f"repos/{REPOSITORY}")
    repo_ok = (
        repo.get("full_name") == REPOSITORY
        and repo.get("default_branch") == "main"
        and repo.get("private") is False
        and (repo.get("parent") or {}).get("full_name") == UPSTREAM_REPOSITORY
        and repo.get("allow_auto_merge") is True
        and repo.get("delete_branch_on_merge") is False
        and repo.get("allow_merge_commit") is True
        and repo.get("allow_squash_merge") is False
        and repo.get("allow_rebase_merge") is False
        and (not require_admin or (repo.get("permissions") or {}).get("admin") is True)
    )
    operator_detail = "admin operator" if require_admin else "read-only candidate verifier"
    check(
        checks,
        "repository_policy",
        repo_ok,
        f"public fork, protected merge-commit release policy; {operator_detail}",
    )

    protection = gh_api(f"repos/{REPOSITORY}/branches/main/protection")
    required = protection.get("required_status_checks") or {}
    required_checks = required.get("checks") or []
    required_contexts = [item.get("context") for item in required_checks]
    exact_required = [item for item in required_checks if item.get("context") == REQUIRED_CONTEXT]
    app_id = exact_required[0].get("app_id") if len(exact_required) == 1 else None
    review_rule = protection.get("required_pull_request_reviews")
    bypass = (review_rule or {}).get("bypass_pull_request_allowances") or {}
    bypass_empty = all(value in (None, []) for value in bypass.values())
    protection_ok = (
        required.get("strict") is True
        and len(required_contexts) == len(set(required_contexts))
        and all(context in REQUIRED_CHECKS for context in required_contexts)
        and len(exact_required) == 1
        and (protection.get("enforce_admins") or {}).get("enabled") is True
        and (protection.get("allow_force_pushes") or {}).get("enabled") is False
        and (protection.get("allow_deletions") or {}).get("enabled") is False
        and (protection.get("required_conversation_resolution") or {}).get("enabled") is True
        and review_rule is not None
        and bypass_empty
    )
    check(checks, "branch_protection", protection_ok, "strict admin-enforced PR protection")

    trusted_source = (
        expected_app_id is not None
        and expected_app_id > 0
        and expected_app_id != GITHUB_ACTIONS_APP_ID
        and app_id == expected_app_id
    )
    check(
        checks,
        "trusted_required_check_source",
        trusted_source,
        "dedicated GitHub App" if trusted_source else "required check is not bound to the dedicated attestor",
    )

    actions = gh_api(f"repos/{REPOSITORY}/actions/permissions/workflow")
    actions_ok = (
        actions.get("default_workflow_permissions") == "read"
        and actions.get("can_approve_pull_request_reviews") is False
    )
    check(checks, "actions_permissions", actions_ok, "read-only default; PR approval disabled")

    immutable = gh_api(f"repos/{REPOSITORY}/immutable-releases")
    immutable_ok = immutable.get("enabled") is True
    immutable_detail = "owner-enforced" if immutable.get("enforced_by_owner") is True else "repository-enabled"
    check(checks, "immutable_releases", immutable_ok, immutable_detail if immutable_ok else "disabled")

    tag = gh_api(f"repos/{REPOSITORY}/git/ref/tags/{VERSION}", allow_missing=True)
    release = gh_api(f"repos/{REPOSITORY}/releases/tags/{VERSION}", allow_missing=True)
    no_collision = tag is None and release is None
    check(checks, "version_collision", no_collision, "version unused" if no_collision else "version already exists")

    for item in checks:
        if item["status"] == "fail":
            blockers.append(item["id"])

    return {
        "blockers": sorted(blockers),
        "checks": sorted(checks, key=lambda item: item["id"]),
        "doctorVersion": 1,
        "overall": "pass" if not blockers else "blocked",
        "repository": REPOSITORY,
        "requiredCheck": {"appId": app_id, "context": REQUIRED_CONTEXT},
        "stage": STAGE,
        "version": VERSION,
    }


def command_doctor(args: argparse.Namespace) -> int:
    report = doctor_report(
        args.trusted_check_app_id,
        expected_head=args.expected_head,
        require_admin=not args.read_only_ci,
    )
    output = canonical_json_bytes(report)
    if args.output:
        atomic_write(external_path(args.output), output)
    sys.stdout.buffer.write(output)
    return 0 if report["overall"] == "pass" else 78


def evidence_record(path: Path, head: str, tree: str, kind: str) -> dict[str, Any]:
    record, raw = load_canonical_json(path)
    if record.get("kind") != kind:
        raise ReleaseError(f"evidence_kind_mismatch:{path.name}")
    if record.get("exactHead") != head or record.get("exactTree") != tree:
        raise ReleaseError(f"stale_evidence:{path.name}")
    status = record.get("verdict") if kind == "independent-review" else record.get("status")
    accepted = status == "GO" if kind == "independent-review" else status == "pass"
    if not accepted:
        raise ReleaseError(f"failed_evidence:{path.name}")
    blocking = record.get("blockingFindings", [])
    if blocking not in ([], None):
        raise ReleaseError(f"blocking_evidence_findings:{path.name}")
    common = {"blockingFindings", "completedAt", "exactHead", "exactTree", "kind"}
    if kind == "independent-review":
        expected = common | {"evidenceSha256", "role", "verdict"}
        if set(record) != expected:
            raise ReleaseError(f"review_evidence_shape_invalid:{path.name}")
        if record.get("role") not in {"evidence", "release-security"}:
            raise ReleaseError(f"review_evidence_role_invalid:{path.name}")
        if not isinstance(record.get("evidenceSha256"), str) or not SHA256_RE.fullmatch(
            record["evidenceSha256"]
        ):
            raise ReleaseError(f"review_evidence_digest_invalid:{path.name}")
    else:
        expected = common | {"command", "id", "status", "summarySha256"}
        if set(record) != expected:
            raise ReleaseError(f"test_evidence_shape_invalid:{path.name}")
        if not isinstance(record.get("command"), list) or not record["command"] or not all(
            isinstance(item, str) and 0 < len(item) <= 256 for item in record["command"]
        ):
            raise ReleaseError(f"test_evidence_command_invalid:{path.name}")
        if not isinstance(record.get("summarySha256"), str) or not SHA256_RE.fullmatch(
            record["summarySha256"]
        ):
            raise ReleaseError(f"test_evidence_digest_invalid:{path.name}")
    completed = record.get("completedAt")
    if not isinstance(completed, str) or re.fullmatch(
        r"20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", completed
    ) is None:
        raise ReleaseError(f"evidence_time_invalid:{path.name}")
    return {"record": record, "sha256": sha256_bytes(raw)}


def git_blob_sha256(commit: str, path: str) -> str:
    return sha256_bytes(git_bytes(commit, path))


def create_candidate_manifest(
    *,
    head: str,
    base: str,
    reviews: Sequence[Path],
    tests: Sequence[Path],
) -> dict[str, Any]:
    if not SHA1_RE.fullmatch(head) or not SHA1_RE.fullmatch(base):
        raise ReleaseError("candidate_commit_invalid")
    if run(("git", "merge-base", "--is-ancestor", base, head), check=False).returncode != 0:
        raise ReleaseError("release_branch_not_current_with_main")
    tree = git("rev-parse", f"{head}^{{tree}}")
    tested_merge_tree = tree
    source_epoch = int(git("show", "-s", "--format=%ct", head))

    review_records = [evidence_record(path, head, tree, "independent-review") for path in reviews]
    roles = {item["record"].get("role") for item in review_records}
    if len(review_records) < 2 or None in roles or len(roles) != len(review_records):
        raise ReleaseError("two_distinct_independent_reviews_required")

    test_records = [evidence_record(path, head, tree, "test-evidence") for path in tests]
    test_ids = {item["record"].get("id") for item in test_records}
    if "r0-07-complete-gate" not in test_ids:
        raise ReleaseError("r0_07_complete_gate_evidence_required")

    upstream_base = git_bytes(head, "UPSTREAM_BASE").decode("utf-8").strip()
    if not SHA1_RE.fullmatch(upstream_base):
        raise ReleaseError("upstream_base_invalid")

    manifest = {
        "approvedWaiverIds": [],
        "baseSha": base,
        "candidateTreeSha": tree,
        "codex": {
            "artifactBundleSha256": json.loads(
                git_bytes(head, "elixir/priv/codex_schema/0.144.3/manifest.json")
            )["artifacts"]["artifactBundleSha256"],
            "version": git_bytes(head, "CODEX_VERSION").decode("utf-8").strip(),
        },
        "generatedAt": iso_from_epoch(source_epoch),
        "kind": "release-candidate-manifest",
        "manifestVersion": 1,
        "migrationPlan": {"classification": "none", "databaseSchemaVersion": None, "migrations": []},
        "previousStableTag": None,
        "readiness": {
            "path": "artifacts/readiness/implementation-readiness.json",
            "sha256": git_blob_sha256(head, "artifacts/readiness/implementation-readiness.json"),
        },
        "releaseBranch": RELEASE_BRANCH,
        "releaseHeadSha": head,
        "repository": REPOSITORY,
        "requiredChecks": REQUIRED_CHECKS,
        "reviewEvidence": review_records,
        "schemaManifest": {
            "path": "elixir/priv/codex_schema/0.144.3/manifest.json",
            "sha256": git_blob_sha256(head, "elixir/priv/codex_schema/0.144.3/manifest.json"),
        },
        "sourceDateEpoch": source_epoch,
        "specificationStage": STAGE,
        "supportedPlatforms": [SUPPORTED_PLATFORM],
        "testEvidence": test_records,
        "testedMergeTreeSha": tested_merge_tree,
        "upstreamBaseSha": upstream_base,
        "version": VERSION,
        "workflowProvenance": {
            path: git_blob_sha256(head, path)
            for path in REQUIRED_WORKFLOW_PATHS
        },
    }
    return manifest


def pr_body(manifest: Mapping[str, Any]) -> str:
    raw_manifest = canonical_json_bytes(manifest)
    candidate_manifest_attachment(raw_manifest)
    head = str(manifest["releaseHeadSha"])
    tree = str(manifest["candidateTreeSha"])
    candidate_sha = sha256_bytes(raw_manifest)
    test_hashes = ", ".join(item["sha256"] for item in manifest["testEvidence"])
    review_hashes = ", ".join(item["sha256"] for item in manifest["reviewEvidence"])
    canonical_manifest = raw_manifest.decode("utf-8").rstrip("\n")
    body = f"""#### Context

Publish the accepted Release 0 foundation through the protected staged release train.

#### TL;DR

*Ship the hardened, upstream-compatible Symphony v0.1.0 foundation.*

#### Summary

- Bind the release candidate to exact head `{head}` and tree `{tree}`.
- Release stage/version: `{manifest['specificationStage']}` / `{manifest['version']}`.
- Prior stable tag: none (first downstream stable release).
- Commits: protected merge of exact release head `{head}` into base `{manifest['baseSha']}`.
- Migrations: none; database schema remains not applicable for Release 0.
- Compatibility: Codex `{manifest['codex']['version']}` with schema bundle `{manifest['codex']['artifactBundleSha256']}`.
- Independent-review evidence SHA-256: {review_hashes}.
- Test evidence SHA-256: {test_hashes}.
- Verify package, provenance, clean install, and upstream-baseline recovery.
- Publish only after the trusted external release gate and protected auto-merge.

Known limitations: this foundation retains the upstream Symphony runner and dashboard; the Studio preview is a separate prerelease. Supported installation is Debian GNU/Linux 12 x86_64.

Rollback: leave the prior `Latest` release unchanged on any failure before publication. After publication, return to the exact locked upstream commit `{manifest['upstreamBaseSha']}` using the verified baseline receipt; never move or reuse `v0.1.0`.

#### Alternatives

- Direct push or locally reproduced merge was rejected because protected GitHub merge is required.
- A candidate-owned required-check producer was rejected because it can spoof its own context.

#### Test Plan

- [x] `make -C elixir all`
- [x] R0-07 deterministic release-tool and adversarial provenance tests
- [x] Two fresh exact-head independent reviews
- [ ] Protected `studio/release-gate` from the dedicated attestor
- [ ] Post-merge package, clean-install, asset-download, and checksum verification

Candidate manifest SHA-256: `{candidate_sha}`

<details>
<summary>Canonical immutable candidate manifest for this exact head</summary>

```json
{canonical_manifest}
```

</details>
"""
    if len(body.encode("utf-8")) > 60_000:
        raise ReleaseError("release_pull_request_body_too_large")
    return body


def command_candidate(args: argparse.Namespace) -> int:
    head = args.head or git("rev-parse", "HEAD")
    base = args.base or git("rev-parse", "origin/main")
    manifest = create_candidate_manifest(
        head=head,
        base=base,
        reviews=[Path(path).resolve() for path in args.review_evidence],
        tests=[Path(path).resolve() for path in args.test_evidence],
    )
    raw = canonical_json_bytes(manifest)
    candidate_manifest_attachment(raw)
    output = external_path(args.output)
    atomic_write(output, raw)
    if args.pr_body_output:
        atomic_write(external_path(args.pr_body_output), pr_body(manifest).encode("utf-8"))
    print(sha256_bytes(raw))
    return 0


def validate_candidate(
    manifest_path: Path,
    *,
    verify_refs: bool = True,
    allow_origin_main_descendant: bool = False,
) -> dict[str, Any]:
    manifest, raw = load_canonical_json(manifest_path)
    candidate_manifest_attachment(raw)
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
    if set(manifest) != expected_keys:
        raise ReleaseError("candidate_manifest_shape_invalid")
    if manifest.get("kind") != "release-candidate-manifest" or manifest.get("manifestVersion") != 1:
        raise ReleaseError("candidate_manifest_identity_invalid")
    if (
        manifest.get("version") != VERSION
        or manifest.get("specificationStage") != STAGE
        or manifest.get("repository") != REPOSITORY
        or manifest.get("releaseBranch") != RELEASE_BRANCH
        or manifest.get("previousStableTag") is not None
        or manifest.get("requiredChecks") != REQUIRED_CHECKS
        or manifest.get("approvedWaiverIds") != []
        or manifest.get("migrationPlan")
        != {"classification": "none", "databaseSchemaVersion": None, "migrations": []}
        or manifest.get("supportedPlatforms") != [SUPPORTED_PLATFORM]
    ):
        raise ReleaseError("candidate_release_identity_invalid")
    head = manifest.get("releaseHeadSha")
    base = manifest.get("baseSha")
    tree = manifest.get("candidateTreeSha")
    if not all(isinstance(item, str) and SHA1_RE.fullmatch(item) for item in (head, base, tree)):
        raise ReleaseError("candidate_git_identity_invalid")
    upstream = manifest.get("upstreamBaseSha")
    source_epoch = manifest.get("sourceDateEpoch")
    codex = manifest.get("codex")
    if (
        not isinstance(upstream, str)
        or SHA1_RE.fullmatch(upstream) is None
        or not isinstance(source_epoch, int)
        or source_epoch < 0
        or manifest.get("generatedAt") != iso_from_epoch(source_epoch)
        or not isinstance(codex, dict)
        or set(codex) != {"artifactBundleSha256", "version"}
        or codex.get("version") != "0.144.3"
        or not isinstance(codex.get("artifactBundleSha256"), str)
        or SHA256_RE.fullmatch(codex["artifactBundleSha256"]) is None
    ):
        raise ReleaseError("candidate_source_identity_invalid")
    if verify_refs:
        if git("rev-parse", head) != head or git("rev-parse", f"{head}^{{tree}}") != tree:
            raise ReleaseError("candidate_head_or_tree_mismatch")
        if git("rev-parse", base) != base:
            raise ReleaseError("candidate_base_missing")
        if git("rev-parse", "origin/main") != base:
            if (
                not allow_origin_main_descendant
                or run(
                    ("git", "merge-base", "--is-ancestor", base, "origin/main"),
                    check=False,
                ).returncode
                != 0
            ):
                raise ReleaseError("candidate_base_is_stale")
        if int(git("show", "-s", "--format=%ct", head)) != source_epoch:
            raise ReleaseError("candidate_source_epoch_mismatch")
    if manifest.get("testedMergeTreeSha") != tree:
        raise ReleaseError("candidate_tested_merge_tree_mismatch")
    workflow = manifest.get("workflowProvenance")
    if not isinstance(workflow, dict) or set(workflow) != set(REQUIRED_WORKFLOW_PATHS):
        raise ReleaseError("candidate_workflow_provenance_invalid")
    for path, expected in workflow.items():
        if not isinstance(expected, str) or SHA256_RE.fullmatch(expected) is None:
            raise ReleaseError(f"candidate_workflow_digest_invalid:{path}")
        if git_blob_sha256(head, path) != expected:
            raise ReleaseError(f"candidate_workflow_hash_mismatch:{path}")
    expected_evidence_paths = {
        "readiness": "artifacts/readiness/implementation-readiness.json",
        "schemaManifest": "elixir/priv/codex_schema/0.144.3/manifest.json",
    }
    for key, expected_path in expected_evidence_paths.items():
        evidence = manifest.get(key) or {}
        if (
            not isinstance(evidence, dict)
            or set(evidence) != {"path", "sha256"}
            or evidence.get("path") != expected_path
            or not isinstance(evidence.get("sha256"), str)
            or SHA256_RE.fullmatch(evidence["sha256"]) is None
        ):
            raise ReleaseError(f"candidate_{key}_shape_invalid")
        if git_blob_sha256(head, evidence.get("path", "")) != evidence.get("sha256"):
            raise ReleaseError(f"candidate_{key}_hash_mismatch")
    reviews = manifest.get("reviewEvidence")
    if not isinstance(reviews, list) or len(reviews) != 2:
        raise ReleaseError("candidate_reviews_missing")
    review_roles: set[str] = set()
    for item in reviews:
        if not isinstance(item, dict) or set(item) != {"record", "sha256"}:
            raise ReleaseError("candidate_review_shape_invalid")
        record = item.get("record") or {}
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
        if (
            not isinstance(record, dict)
            or set(record) != expected_record_keys
            or item.get("sha256") != sha256_bytes(canonical_json_bytes(record))
            or not isinstance(item.get("sha256"), str)
            or SHA256_RE.fullmatch(item["sha256"]) is None
        ):
            raise ReleaseError("candidate_review_hash_mismatch")
        if (
            record.get("kind") != "independent-review"
            or record.get("exactHead") != head
            or record.get("exactTree") != tree
            or record.get("verdict") != "GO"
            or record.get("blockingFindings") != []
            or record.get("role") not in {"evidence", "release-security"}
            or not isinstance(record.get("evidenceSha256"), str)
            or SHA256_RE.fullmatch(record["evidenceSha256"]) is None
            or not isinstance(record.get("completedAt"), str)
            or re.fullmatch(
                r"20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z",
                record["completedAt"],
            )
            is None
        ):
            raise ReleaseError("candidate_review_invalid")
        review_roles.add(record["role"])
    if review_roles != {"evidence", "release-security"}:
        raise ReleaseError("candidate_review_roles_invalid")
    tests = manifest.get("testEvidence")
    if not isinstance(tests, list) or not tests:
        raise ReleaseError("candidate_test_evidence_missing")
    test_ids: set[str] = set()
    for item in tests:
        if not isinstance(item, dict) or set(item) != {"record", "sha256"}:
            raise ReleaseError("candidate_test_evidence_shape_invalid")
        record = item.get("record") or {}
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
        if (
            not isinstance(record, dict)
            or set(record) != expected_record_keys
            or item.get("sha256") != sha256_bytes(canonical_json_bytes(record))
            or not isinstance(item.get("sha256"), str)
            or SHA256_RE.fullmatch(item["sha256"]) is None
        ):
            raise ReleaseError("candidate_test_evidence_hash_mismatch")
        evidence_id = record.get("id")
        if (
            record.get("kind") != "test-evidence"
            or record.get("exactHead") != head
            or record.get("exactTree") != tree
            or record.get("status") != "pass"
            or record.get("blockingFindings") != []
            or not isinstance(evidence_id, str)
            or not evidence_id
            or evidence_id in test_ids
            or not isinstance(record.get("summarySha256"), str)
            or SHA256_RE.fullmatch(record["summarySha256"]) is None
            or not isinstance(record.get("command"), list)
            or not record["command"]
            or not all(isinstance(value, str) and 0 < len(value) <= 256 for value in record["command"])
            or not isinstance(record.get("completedAt"), str)
            or re.fullmatch(
                r"20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z",
                record["completedAt"],
            )
            is None
        ):
            raise ReleaseError("candidate_test_evidence_invalid")
        test_ids.add(evidence_id)
    if "r0-07-complete-gate" not in test_ids:
        raise ReleaseError("candidate_complete_gate_missing")
    if sha256_bytes(raw) != sha256_file(manifest_path):
        raise ReleaseError("candidate_manifest_hash_internal_error")
    return manifest


def command_verify_candidate(args: argparse.Namespace) -> int:
    manifest_path = Path(args.manifest).resolve()
    manifest = validate_candidate(manifest_path, verify_refs=not args.no_ref_check)
    print(sha256_file(manifest_path))
    print(manifest["releaseHeadSha"])
    return 0


def publication_workflow_source_record(
    candidate: Mapping[str, Any],
    merged_sha: str,
    workflow_sha: str,
) -> dict[str, Any]:
    if (
        SHA1_RE.fullmatch(merged_sha) is None
        or SHA1_RE.fullmatch(workflow_sha) is None
        or git("rev-parse", workflow_sha) != workflow_sha
        or run(
            ("git", "merge-base", "--is-ancestor", merged_sha, workflow_sha),
            check=False,
        ).returncode
        != 0
        or run(
            ("git", "merge-base", "--is-ancestor", workflow_sha, "origin/main"),
            check=False,
        ).returncode
        != 0
    ):
        raise ReleaseError("publication_workflow_source_not_protected_main_descendant")
    path = ".github/workflows/publish-release.yml"
    expected = (candidate.get("workflowProvenance") or {}).get(path)
    observed = git_blob_sha256(workflow_sha, path)
    if expected != observed:
        raise ReleaseError("publication_workflow_source_hash_mismatch")
    return {
        "candidateWorkflowSha256": expected,
        "kind": "publication-workflow-source",
        "mergedCommit": merged_sha,
        "status": "pass",
        "workflowSourceCommit": workflow_sha,
    }


def command_verify_workflow_source(args: argparse.Namespace) -> int:
    candidate_path = external_path(args.candidate)
    candidate = validate_candidate(candidate_path, verify_refs=False)
    record = publication_workflow_source_record(
        candidate,
        args.merged_sha,
        args.workflow_sha,
    )
    print(sha256_bytes(canonical_json_bytes(record)))
    return 0


def release_pull_requests() -> list[dict[str, Any]]:
    owner = REPOSITORY.split("/", 1)[0]
    head = urllib.parse.quote(f"{owner}:{RELEASE_BRANCH}", safe="")
    base = urllib.parse.quote("main", safe="")
    pulls = gh_api(
        f"repos/{REPOSITORY}/pulls?state=all&head={head}&base={base}&per_page=100"
    )
    if not isinstance(pulls, list) or len(pulls) >= 100:
        raise ReleaseError("release_pull_request_inventory_unbounded")
    return pulls


def validate_release_pull_request(
    pull: Mapping[str, Any],
    candidate: Mapping[str, Any],
    *,
    require_merged_sha: str | None = None,
) -> None:
    base = pull.get("base") or {}
    head = pull.get("head") or {}
    if (
        not isinstance(pull.get("number"), int)
        or pull.get("draft") is not False
        or base.get("ref") != "main"
        or base.get("sha") != candidate["baseSha"]
        or head.get("ref") != RELEASE_BRANCH
        or head.get("sha") != candidate["releaseHeadSha"]
    ):
        raise ReleaseError("release_pull_request_candidate_mismatch")
    if require_merged_sha is not None and (
        pull.get("state") != "closed"
        or pull.get("merged") is not True
        or pull.get("merge_commit_sha") != require_merged_sha
        or not pull.get("merged_at")
    ):
        raise ReleaseError("release_pull_request_merge_mismatch")


def command_candidate_reconcile(args: argparse.Namespace) -> int:
    candidate_path = external_path(args.manifest)
    receipt_path = external_path(args.receipt)
    run(
        (
            "git",
            "fetch",
            "--no-tags",
            "origin",
            "+refs/heads/main:refs/remotes/origin/main",
        ),
        timeout=120,
    )
    candidate = validate_candidate(
        candidate_path,
        allow_origin_main_descendant=True,
    )
    if (
        git("branch", "--show-current") != RELEASE_BRANCH
        or git("rev-parse", "HEAD") != candidate["releaseHeadSha"]
        or git("rev-parse", f"origin/{RELEASE_BRANCH}") != candidate["releaseHeadSha"]
        or git("status", "--porcelain=v1", "--untracked-files=all")
    ):
        raise ReleaseError("release_pull_request_local_state_invalid")
    pulls = release_pull_requests()
    if len(pulls) > 1:
        raise ReleaseError("duplicate_release_pull_requests")
    body = pr_body(candidate)
    title = "Release v0.1.0 — verified Symphony foundation"
    if pulls:
        pull = gh_api(f"repos/{REPOSITORY}/pulls/{pulls[0]['number']}")
        validate_release_pull_request(pull, candidate)
        if pull.get("merged") is True:
            if (
                pull.get("state") != "closed"
                or not isinstance(pull.get("merge_commit_sha"), str)
                or SHA1_RE.fullmatch(pull["merge_commit_sha"]) is None
                or not isinstance(pull.get("merged_at"), str)
            ):
                raise ReleaseError("release_pull_request_merged_identity_invalid")
            if (
                run(
                    (
                        "git",
                        "merge-base",
                        "--is-ancestor",
                        pull["merge_commit_sha"],
                        "origin/main",
                    ),
                    check=False,
                ).returncode
                != 0
            ):
                raise ReleaseError("release_pull_request_merge_not_on_main")
        elif pull.get("state") == "closed":
            if git("rev-parse", "origin/main") != candidate["baseSha"]:
                raise ReleaseError("release_pull_request_base_advanced")
            run(
                (
                    "gh",
                    "pr",
                    "reopen",
                    str(pull["number"]),
                    "--repo",
                    REPOSITORY,
                ),
                timeout=120,
            )
        elif git("rev-parse", "origin/main") != candidate["baseSha"]:
            raise ReleaseError("release_pull_request_base_advanced")
    else:
        if git("rev-parse", "origin/main") != candidate["baseSha"]:
            raise ReleaseError("release_pull_request_base_advanced")
        with tempfile.TemporaryDirectory(prefix="symphony-release-pr-") as temporary:
            body_file = Path(temporary) / "body.md"
            atomic_write(body_file, body.encode("utf-8"), 0o600)
            run(
                (
                    "gh",
                    "pr",
                    "create",
                    "--repo",
                    REPOSITORY,
                    "--base",
                    "main",
                    "--head",
                    RELEASE_BRANCH,
                    "--title",
                    title,
                    "--body-file",
                    str(body_file),
                ),
                timeout=120,
            )
        pulls = release_pull_requests()
        if len(pulls) != 1:
            raise ReleaseError("release_pull_request_creation_failed")
        pull = gh_api(f"repos/{REPOSITORY}/pulls/{pulls[0]['number']}")
    validate_release_pull_request(pull, candidate)
    if pull.get("title") != title or pull.get("body") != body:
        if pull.get("merged") is True:
            raise ReleaseError("release_pull_request_merged_body_mismatch")
        with tempfile.TemporaryDirectory(prefix="symphony-release-pr-") as temporary:
            body_file = Path(temporary) / "body.md"
            atomic_write(body_file, body.encode("utf-8"), 0o600)
            run(
                (
                    "gh",
                    "pr",
                    "edit",
                    str(pull["number"]),
                    "--repo",
                    REPOSITORY,
                    "--title",
                    title,
                    "--body-file",
                    str(body_file),
                ),
                timeout=120,
            )
        pull = gh_api(f"repos/{REPOSITORY}/pulls/{pull['number']}")
        if pull.get("title") != title or pull.get("body") != body:
            raise ReleaseError("release_pull_request_body_mismatch")
    if pull.get("merged") is not True and pull.get("auto_merge") is None:
        result = run(
            (
                "gh",
                "pr",
                "merge",
                str(pull["number"]),
                "--repo",
                REPOSITORY,
                "--auto",
                "--merge",
                "--match-head-commit",
                candidate["releaseHeadSha"],
            ),
            check=False,
            timeout=120,
        )
        if result.returncode != 0:
            raise ReleaseError("release_pull_request_auto_merge_failed")
        pull = gh_api(f"repos/{REPOSITORY}/pulls/{pull['number']}")
    auto_merge = pull.get("auto_merge") or {}
    if pull.get("merged") is not True and auto_merge.get("merge_method") != "merge":
        raise ReleaseError("release_pull_request_auto_merge_missing")
    receipt = {
        "autoMergeMethod": "merge",
        "baseSha": candidate["baseSha"],
        "bodySha256": sha256_bytes(body.encode("utf-8")),
        "candidateManifestSha256": sha256_file(candidate_path),
        "headSha": candidate["releaseHeadSha"],
        "kind": "release-pull-request-reconciliation",
        "mergedSha": pull.get("merge_commit_sha") if pull.get("merged") is True else None,
        "number": pull["number"],
        "repository": REPOSITORY,
        "state": "merged" if pull.get("merged") is True else "awaiting-protected-auto-merge",
        "status": "pass",
        "url": pull.get("html_url"),
    }
    atomic_write(receipt_path, canonical_json_bytes(receipt))
    print(pull.get("html_url"))
    print(sha256_file(receipt_path))
    return 0


def command_verify_protected_merge(args: argparse.Namespace) -> int:
    candidate_path = external_path(args.candidate)
    candidate = validate_candidate(candidate_path, verify_refs=False)
    app_id = args.trusted_check_app_id
    if app_id <= 0 or app_id == GITHUB_ACTIONS_APP_ID:
        raise ReleaseError("trusted_check_app_id_invalid")
    pull = gh_api(f"repos/{REPOSITORY}/pulls/{args.pr_number}")
    validate_release_pull_request(pull, candidate, require_merged_sha=args.merged_sha)
    encoded_name = urllib.parse.quote(REQUIRED_CONTEXT, safe="")
    checks = gh_api(
        f"repos/{REPOSITORY}/commits/{candidate['releaseHeadSha']}"
        f"/check-runs?check_name={encoded_name}&filter=all&app_id={app_id}&per_page=100"
    )
    runs = checks.get("check_runs") if isinstance(checks, dict) else None
    if (
        not isinstance(runs, list)
        or len(runs) >= 100
        or not isinstance(checks.get("total_count"), int)
        or checks["total_count"] != len(runs)
    ):
        raise ReleaseError("trusted_check_inventory_invalid")
    candidate_sha = sha256_file(candidate_path)
    named = [
        item
        for item in runs
        if item.get("name") == REQUIRED_CONTEXT
        and item.get("head_sha") == candidate["releaseHeadSha"]
        and (item.get("app") or {}).get("id") == app_id
    ]
    exact = [
        item
        for item in named
        if item.get("status") == "completed"
        and item.get("conclusion") == "success"
        and item.get("external_id") == candidate_sha
    ]
    if not named or not exact or not all(isinstance(item.get("id"), int) for item in named):
        raise ReleaseError("trusted_release_check_missing_or_ambiguous")
    latest = max(named, key=lambda item: item["id"])
    matching_latest = [item for item in exact if item["id"] == latest["id"]]
    if len(matching_latest) != 1:
        raise ReleaseError("trusted_release_check_latest_mismatch")
    selected = gh_api(f"repos/{REPOSITORY}/check-runs/{latest['id']}")
    if any(
        selected.get(key) != latest.get(key)
        for key in ("id", "name", "head_sha", "external_id", "status", "conclusion")
    ) or (selected.get("app") or {}).get("id") != app_id:
        raise ReleaseError("trusted_release_check_revalidation_failed")
    output = selected.get("output") or {}
    candidate_attachment = candidate_manifest_attachment(candidate_path.read_bytes())
    if (
        output.get("title") != "Symphony Studio R0-07 trusted candidate"
        or output.get("summary") != f"candidate-manifest-sha256:{candidate_sha}"
        or output.get("text") != f"candidate-manifest-base64:{candidate_attachment}"
    ):
        raise ReleaseError("trusted_release_check_candidate_attachment_mismatch")
    parents = git("rev-list", "--parents", "-n", "1", args.merged_sha).split()
    if parents != [args.merged_sha, candidate["baseSha"], candidate["releaseHeadSha"]]:
        raise ReleaseError("protected_merge_parent_identity_mismatch")
    merged_tree = git("rev-parse", f"{args.merged_sha}^{{tree}}")
    if merged_tree != candidate["testedMergeTreeSha"]:
        raise ReleaseError("protected_merge_tree_mismatch")
    receipt = {
        "baseSha": candidate["baseSha"],
        "candidateManifestSha256": candidate_sha,
        "checkAppId": app_id,
        "checkRunId": selected.get("id"),
        "checkRunName": REQUIRED_CONTEXT,
        "headSha": candidate["releaseHeadSha"],
        "kind": "protected-release-merge-verification",
        "mergedSha": args.merged_sha,
        "mergedTreeSha": merged_tree,
        "pullRequestNumber": args.pr_number,
        "status": "pass",
    }
    if args.receipt:
        atomic_write(external_path(args.receipt), canonical_json_bytes(receipt))
    print(sha256_bytes(canonical_json_bytes(receipt)))
    return 0


def command_publish_dispatch(args: argparse.Namespace) -> int:
    candidate_path = external_path(args.candidate)
    receipt_path = external_path(args.receipt)
    candidate = validate_candidate(candidate_path, verify_refs=False)
    run(
        (
            "git",
            "fetch",
            "--no-tags",
            "origin",
            "+refs/heads/main:refs/remotes/origin/main",
        ),
        timeout=120,
    )
    verify_args = argparse.Namespace(
        candidate=str(candidate_path),
        merged_sha=args.merged_sha,
        pr_number=args.pr_number,
        receipt=None,
        trusted_check_app_id=args.trusted_check_app_id,
    )
    with contextlib.redirect_stdout(io.StringIO()):
        command_verify_protected_merge(verify_args)
    workflow_source = git("rev-parse", "origin/main")
    publication_workflow_source_record(candidate, args.merged_sha, workflow_source)
    raw = candidate_path.read_bytes()
    inputs = publication_dispatch_inputs(raw, args.merged_sha, args.pr_number)
    command = [
        "gh",
        "workflow",
        "run",
        "publish-release.yml",
        "--repo",
        REPOSITORY,
        "--ref",
        "main",
    ]
    for name in sorted(inputs):
        command.extend(("-f", f"{name}={inputs[name]}"))
    run(tuple(command), timeout=120)
    receipt = {
        "candidateManifestSha256": sha256_bytes(raw),
        "dispatchInputSha256": sha256_bytes(canonical_json_bytes(inputs)),
        "kind": "release-publication-dispatch",
        "mergedCommit": args.merged_sha,
        "pullRequestNumber": args.pr_number,
        "repository": REPOSITORY,
        "status": "release_pending_publication",
        "version": VERSION,
        "workflowSourceCommit": workflow_source,
    }
    atomic_write(receipt_path, canonical_json_bytes(receipt))
    print(sha256_file(receipt_path))
    return 0


def release_revert_state(
    candidate: Mapping[str, Any], merged_sha: str
) -> dict[str, Any]:
    if SHA1_RE.fullmatch(merged_sha) is None:
        raise ReleaseError("release_revert_merged_sha_invalid")
    branch = f"revert/v0.1.0-{merged_sha[:12]}"
    encoded_branch = urllib.parse.quote(branch, safe="")
    reference = gh_api(
        f"repos/{REPOSITORY}/git/ref/heads/{encoded_branch}", allow_missing=True
    )
    owner = REPOSITORY.split("/", 1)[0]
    head = urllib.parse.quote(f"{owner}:{branch}", safe="")
    pulls = gh_api(
        f"repos/{REPOSITORY}/pulls?state=all&head={head}&base=main&per_page=100"
    )
    if not isinstance(pulls, list) or len(pulls) >= 100 or len(pulls) > 1:
        raise ReleaseError("release_revert_pull_request_inventory_invalid")
    pull = pulls[0] if pulls else None
    if pull is not None and (pull.get("merged") is True or pull.get("merged_at")):
        raise ReleaseError("release_revert_already_merged")
    open_pull = pull if pull is not None and pull.get("state") == "open" else None
    branch_sha = None
    if reference is not None:
        branch_sha = (reference.get("object") or {}).get("sha")
        if not isinstance(branch_sha, str) or SHA1_RE.fullmatch(branch_sha) is None:
            raise ReleaseError("release_revert_branch_identity_invalid")
        parents = git("rev-list", "--parents", "-n", "1", branch_sha).split()
        if parents != [branch_sha, merged_sha]:
            raise ReleaseError("release_revert_commit_parent_invalid")
        if git("rev-parse", f"{branch_sha}^{{tree}}") != git(
            "rev-parse", f"{candidate['baseSha']}^{{tree}}"
        ):
            raise ReleaseError("release_revert_tree_invalid")
    if open_pull is not None:
        pull_head = (open_pull.get("head") or {}).get("sha")
        if (
            not isinstance(open_pull.get("number"), int)
            or branch_sha is None
            or pull_head != branch_sha
            or (open_pull.get("base") or {}).get("ref") != "main"
        ):
            raise ReleaseError("release_revert_pull_request_identity_invalid")
    return {
        "branch": branch,
        "branchSha": branch_sha,
        "openPullRequestNumber": open_pull.get("number") if open_pull else None,
        "openPullRequestUrl": open_pull.get("html_url") if open_pull else None,
        "status": "active" if branch_sha is not None or open_pull is not None else "absent",
    }


def require_no_active_release_revert(
    candidate: Mapping[str, Any], merged_sha: str
) -> dict[str, Any]:
    state = release_revert_state(candidate, merged_sha)
    if state.get("status") != "absent":
        raise ReleaseError("release_revert_still_active")
    return state


def safe_build_environment(temp_root: Path, manifest: Mapping[str, Any], merged_sha: str) -> dict[str, str]:
    keep = {"LANG", "LC_ALL", "PATH", "SSL_CERT_FILE", "TERM", "TZ"}
    env = {key: value for key, value in os.environ.items() if key in keep}
    for key in list(env):
        if any(part in key.upper() for part in FORBIDDEN_ENV_PARTS):
            env.pop(key, None)
    env.update(
        {
            "ERL_COMPILER_OPTIONS": "deterministic",
            "HEX_HOME": str(temp_root / "hex-home"),
            "HOME": str(temp_root / "home"),
            "MIX_BUILD_PATH": str(temp_root / "mix-build"),
            "MIX_DEPS_PATH": str(temp_root / "mix-deps"),
            "MIX_ENV": "prod",
            "MIX_HOME": str(temp_root / "mix-home"),
            "SOURCE_DATE_EPOCH": str(manifest["sourceDateEpoch"]),
            "SYMPHONY_BUILD_CODEX_COMPATIBILITY_SHA256": str(
                manifest["codex"]["artifactBundleSha256"]
            ),
            "SYMPHONY_BUILD_COMMIT": merged_sha,
            "SYMPHONY_BUILD_PROVENANCE": "github-release-verified",
            "SYMPHONY_BUILD_UPSTREAM_BASE": str(manifest["upstreamBaseSha"]),
            "SYMPHONY_BUILD_VERSION": VERSION.removeprefix("v"),
            "TZ": "UTC",
        }
    )
    for name in ("home", "hex-home", "mix-build", "mix-deps", "mix-home"):
        (temp_root / name).mkdir(parents=True, exist_ok=True, mode=0o700)
    return env


def dependency_build_patch_records(
    patches: Sequence[Mapping[str, Any]] = DEPENDENCY_BUILD_PATCHES,
) -> list[dict[str, str]]:
    keys = (
        "dependency",
        "originalSha256",
        "patchedSha256",
        "path",
        "purpose",
        "version",
    )
    return [{key: str(patch[key]) for key in keys} for patch in patches]


def locked_hex_packages(raw: bytes) -> dict[str, dict[str, str]]:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ReleaseError("mix_lock_not_utf8") from error
    pattern = re.compile(
        r'^\s*"([a-zA-Z0-9_]+)": \{:hex, :[^,]+, "([^"]+)", '
        r'"([0-9a-f]{64})".*?, "hexpm", "([0-9a-f]{64})"\},?$',
        re.MULTILINE,
    )
    packages: dict[str, dict[str, str]] = {}
    for name, version, content_sha, registry_sha in pattern.findall(text):
        if name in packages:
            raise ReleaseError("mix_lock_duplicate_package")
        packages[name] = {
            "contentSha256": content_sha,
            "registrySha256": registry_sha,
            "version": version,
        }
    if not packages:
        raise ReleaseError("mix_lock_package_inventory_empty")
    return packages


def canonical_json_object(raw: bytes, label: str) -> dict[str, Any]:
    if len(raw) > MAX_JSON_BYTES:
        raise ReleaseError(f"{label}_too_large")
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReleaseError(f"{label}_invalid_json") from error
    if not isinstance(value, dict) or canonical_json_bytes(value) != raw:
        raise ReleaseError(f"{label}_not_canonical")
    return value


def valid_inventory_relative_path(value: Any) -> bool:
    if not isinstance(value, str):
        return False
    path = PurePosixPath(value)
    return bool(
        not path.is_absolute()
        and path.parts
        and all(part not in {"", ".", ".."} for part in path.parts)
        and len(value.encode("utf-8")) <= MAX_ARCHIVE_PATH_BYTES
    )


def validate_notice_embedded_bodies(notice_raw: bytes) -> None:
    separator = b"=" * 78
    for record in NOTICE_EMBEDDED_BODY_RECORDS:
        heading = record["heading"]
        marker = record["bodyMarker"]
        if notice_raw.count(heading) != 1:
            raise ReleaseError("runtime_dependency_notice_heading_invalid")
        heading_start = notice_raw.index(heading)
        body_start = notice_raw.find(marker, heading_start + len(heading))
        body_end = notice_raw.find(separator, body_start + len(marker))
        if body_start < 0 or body_end < 0:
            raise ReleaseError("runtime_dependency_notice_body_missing")
        header = notice_raw[heading_start:body_start]
        body = notice_raw[body_start:body_end]
        if (
            len(body) != record["size"]
            or sha256_bytes(body) != record["sha256"]
            or str(record["size"]).encode("ascii") not in header
            or str(record["sha256"]).encode("ascii") not in header
        ):
            raise ReleaseError("runtime_dependency_notice_body_mismatch")
    if (
        notice_raw.count(b"COMPONENT ATTRIBUTION: req 0.5.17 LICENSE.md") != 1
        or notice_raw.count(b"Copyright 2021 Wojtek Mach") != 1
    ):
        raise ReleaseError("runtime_dependency_req_attribution_missing")


def validate_runtime_dependency_inventory(
    inventory_raw: bytes,
    notice_raw: bytes,
    lock_raw: bytes,
) -> dict[str, Any]:
    validate_notice_embedded_bodies(notice_raw)
    inventory = canonical_json_object(
        inventory_raw, "runtime_dependency_inventory"
    )
    expected_top_keys = {
        "bundledApplications",
        "components",
        "externalRuntime",
        "kind",
        "noticeFile",
        "schemaVersion",
        "symphonyApplication",
    }
    if (
        set(inventory) != expected_top_keys
        or inventory.get("schemaVersion") != 1
        or inventory.get("kind") != "runtime-dependency-license-inventory"
        or inventory.get("externalRuntime")
        != {"bundled": False, "name": "Erlang/OTP", "version": "28.5"}
        or inventory.get("symphonyApplication")
        != {"name": "symphony_elixir", "version": "0.1.0"}
        or inventory.get("noticeFile")
        != {
            "path": THIRD_PARTY_NOTICES_PATH,
            "sha256": sha256_bytes(notice_raw),
        }
    ):
        raise ReleaseError("runtime_dependency_inventory_header_invalid")

    bundled = inventory.get("bundledApplications")
    components = inventory.get("components")
    if (
        not isinstance(bundled, list)
        or bundled != sorted(set(bundled))
        or not bundled
        or not all(
            isinstance(item, str)
            and re.fullmatch(r"[a-z][a-z0-9_]*", item) is not None
            for item in bundled
        )
        or not isinstance(components, list)
        or not components
    ):
        raise ReleaseError("runtime_dependency_inventory_list_invalid")

    locked = locked_hex_packages(lock_raw)
    component_names: list[str] = []
    application_versions: dict[str, str] = {}
    component_by_name: dict[str, dict[str, Any]] = {}
    notice_text = notice_raw.decode("utf-8", errors="strict")
    for component in components:
        if not isinstance(component, dict):
            raise ReleaseError("runtime_dependency_component_invalid")
        name = component.get("name")
        version = component.get("version")
        source_kind = component.get("sourceKind")
        scope = component.get("scope")
        license_expression = component.get("spdxLicense")
        applications = component.get("applications")
        license_files = component.get("licenseFiles")
        if (
            not isinstance(name, str)
            or re.fullmatch(r"[a-z][a-z0-9_]*", name) is None
            or not isinstance(version, str)
            or re.fullmatch(r"[0-9]+(?:\.[0-9]+)+(?:[-+][A-Za-z0-9.-]+)?", version)
            is None
            or source_kind not in {"hex", "pinned-toolchain", "vendored-path"}
            or scope
            not in {"bundled-language", "direct-runtime", "transitive-runtime"}
            or license_expression not in ALLOWED_RUNTIME_LICENSES
            or not isinstance(applications, list)
            or applications != sorted(set(applications))
            or not applications
            or not all(
                isinstance(item, str)
                and re.fullmatch(r"[a-z][a-z0-9_]*", item) is not None
                for item in applications
            )
            or not isinstance(license_files, list)
            or not license_files
        ):
            raise ReleaseError("runtime_dependency_component_invalid")
        component_names.append(name)
        component_by_name[name] = component
        for application in applications:
            if application in application_versions:
                raise ReleaseError("runtime_dependency_application_duplicate")
            application_versions[application] = version

        common_keys = {
            "applications",
            "licenseFiles",
            "name",
            "scope",
            "sourceKind",
            "spdxLicense",
            "version",
        }
        if source_kind == "hex":
            if set(component) != common_keys | {
                "contentSha256",
                "registrySha256",
            }:
                raise ReleaseError("runtime_dependency_hex_shape_invalid")
            observed_lock = locked.get(name)
            if observed_lock != {
                "contentSha256": component.get("contentSha256"),
                "registrySha256": component.get("registrySha256"),
                "version": version,
            }:
                raise ReleaseError(f"runtime_dependency_lock_mismatch:{name}")
        elif source_kind == "pinned-toolchain":
            if set(component) != common_keys:
                raise ReleaseError("runtime_dependency_toolchain_shape_invalid")
        elif (
            set(component) != common_keys | {"metadataLicense"}
            or component.get("metadataLicense") != "BSD-2-Clause"
        ):
            raise ReleaseError("runtime_dependency_vendored_shape_invalid")

        license_file_order: list[tuple[str, str]] = []
        for license_file in license_files:
            if not isinstance(license_file, dict):
                raise ReleaseError("runtime_dependency_license_file_invalid")
            kind = license_file.get("kind")
            path = license_file.get("path")
            digest = license_file.get("sha256")
            keys = {"kind", "path", "sha256"}
            if kind == "hex-extract-attribution":
                keys.add("excerptSha256")
            elif kind == "pinned-toolchain":
                keys.add("source")
            elif kind not in {"hex-extract", "immutable-upstream", "vendored"}:
                raise ReleaseError("runtime_dependency_license_kind_invalid")
            if (
                set(license_file) != keys
                or not isinstance(path, str)
                or not isinstance(digest, str)
                or SHA256_RE.fullmatch(digest) is None
                or (
                    kind == "immutable-upstream"
                    and not path.startswith("https://github.com/")
                )
                or (
                    kind != "immutable-upstream"
                    and not valid_inventory_relative_path(path)
                )
                or (
                    kind == "hex-extract-attribution"
                    and (
                        not isinstance(license_file.get("excerptSha256"), str)
                        or SHA256_RE.fullmatch(license_file["excerptSha256"])
                        is None
                    )
                )
                or (
                    kind == "pinned-toolchain"
                    and (
                        not isinstance(license_file.get("source"), str)
                        or not license_file["source"].startswith(
                            "https://github.com/elixir-lang/elixir/tree/"
                        )
                    )
                )
            ):
                raise ReleaseError("runtime_dependency_license_file_invalid")
            license_file_order.append((path, kind))
            if digest not in notice_text:
                raise ReleaseError(
                    f"runtime_dependency_license_not_in_notice:{name}"
                )
            if (
                kind == "hex-extract-attribution"
                and license_file["excerptSha256"] not in notice_text
            ):
                raise ReleaseError(
                    f"runtime_dependency_license_excerpt_not_in_notice:{name}"
                )
        if len(license_file_order) != len(set(license_file_order)):
            raise ReleaseError("runtime_dependency_license_duplicate")
        index_line = (
            f"- {name} {version} — {license_expression} — "
            + ", ".join(applications)
        )
        if index_line not in notice_text:
            raise ReleaseError(f"runtime_dependency_notice_index_missing:{name}")

    if component_names != sorted(set(component_names)):
        raise ReleaseError("runtime_dependency_component_order_invalid")
    expected_bundled = sorted(
        [*application_versions, inventory["symphonyApplication"]["name"]]
    )
    if bundled != expected_bundled:
        raise ReleaseError("runtime_dependency_bundled_inventory_mismatch")

    required_components = {
        "elixir": {
            "applications": ["eex", "elixir", "logger"],
            "sourceKind": "pinned-toolchain",
            "spdxLicense": "Apache-2.0",
            "version": "1.19.5",
        },
        "erlexec": {
            "applications": ["erlexec"],
            "metadataLicense": "BSD-2-Clause",
            "sourceKind": "vendored-path",
            "spdxLicense": "BSD-3-Clause",
            "version": "2.3.4",
        },
    }
    for name, expected in required_components.items():
        component = component_by_name.get(name, {})
        if any(component.get(key) != value for key, value in expected.items()):
            raise ReleaseError(f"runtime_dependency_required_component_invalid:{name}")
    telemetry = component_by_name.get("telemetry", {})
    if not any(
        item.get("path") == "NOTICE"
        and item.get("sha256")
        == "3ca23c239bc03e2bcd3899da04d4271370e230e30f7dc171c7e8ad35809c6bb0"
        for item in telemetry.get("licenseFiles", [])
        if isinstance(item, dict)
    ):
        raise ReleaseError("runtime_dependency_telemetry_notice_missing")
    for patch in DEPENDENCY_BUILD_PATCHES:
        component = component_by_name.get(str(patch["dependency"]), {})
        if component.get("version") != patch["version"]:
            raise ReleaseError("runtime_dependency_patch_version_mismatch")
    return inventory


def runtime_license_excerpt(raw: bytes) -> bytes:
    marker = b"## License\n"
    start = raw.find(marker)
    if start < 0:
        raise ReleaseError("runtime_dependency_license_excerpt_missing")
    end = raw.find(b"\n[docs]:", start + len(marker))
    if end < 0:
        return raw[start:]
    return raw[start : end + 1]


def checked_runtime_license_file(path: Path, expected_sha256: str) -> bytes:
    metadata = path.lstat() if path.exists() else None
    if (
        metadata is None
        or stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_size < 1
        or metadata.st_size > MAX_ARCHIVE_FILE_BYTES
    ):
        raise ReleaseError("runtime_dependency_license_source_invalid")
    raw = path.read_bytes()
    if sha256_bytes(raw) != expected_sha256:
        raise ReleaseError("runtime_dependency_license_source_mismatch")
    return raw


def checked_runtime_source_file(path: Path) -> bytes:
    metadata = path.lstat() if path.exists() else None
    if (
        metadata is None
        or stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_size < 1
        or metadata.st_size > MAX_ARCHIVE_FILE_BYTES
    ):
        raise ReleaseError("runtime_dependency_source_file_invalid")
    return path.read_bytes()


def symphony_priv_source_records(priv_root: Path) -> dict[str, str]:
    root_metadata = priv_root.lstat() if priv_root.exists() else None
    if (
        root_metadata is None
        or stat.S_ISLNK(root_metadata.st_mode)
        or not stat.S_ISDIR(root_metadata.st_mode)
        or root_metadata.st_uid != os.getuid()
        or priv_root.name != "priv"
    ):
        raise ReleaseError("symphony_priv_source_invalid")

    pending = [priv_root]
    records: dict[str, str] = {}
    special_contents: dict[str, bytes] = {}
    semantic_records: dict[str, str] = {}
    entry_count = 0
    total_bytes = 0
    while pending:
        directory = pending.pop()
        try:
            scanner = os.scandir(directory)
        except OSError as error:
            raise ReleaseError("codex_schema_bundle_directory_unreadable") from error
        with scanner:
            for entry in scanner:
                entry_count += 1
                if entry_count > MAX_ARCHIVE_FILES:
                    raise ReleaseError("codex_schema_bundle_entry_count_invalid")
                path = Path(entry.path)
                try:
                    relative = path.relative_to(priv_root).as_posix()
                    encoded_relative = relative.encode("utf-8")
                    metadata = entry.stat(follow_symlinks=False)
                except (OSError, UnicodeEncodeError, ValueError) as error:
                    raise ReleaseError("codex_schema_bundle_entry_invalid") from error
                pure = PurePosixPath(relative)
                if (
                    pure.is_absolute()
                    or not pure.parts
                    or any(part in {"", ".", ".."} for part in pure.parts)
                    or len(encoded_relative) > MAX_ARCHIVE_PATH_BYTES
                    or stat.S_ISLNK(metadata.st_mode)
                    or metadata.st_uid != os.getuid()
                ):
                    raise ReleaseError("codex_schema_bundle_entry_invalid")
                if stat.S_ISDIR(metadata.st_mode):
                    pending.append(path)
                    continue
                if (
                    not stat.S_ISREG(metadata.st_mode)
                    or metadata.st_size < 1
                    or metadata.st_size > MAX_ARCHIVE_FILE_BYTES
                    or relative in records
                ):
                    raise ReleaseError("codex_schema_bundle_entry_invalid")
                total_bytes += metadata.st_size
                if total_bytes > MAX_ARCHIVE_TOTAL_BYTES:
                    raise ReleaseError("codex_schema_bundle_total_size_exceeded")

                flags = os.O_RDONLY
                if hasattr(os, "O_NOFOLLOW"):
                    flags |= os.O_NOFOLLOW
                try:
                    descriptor = os.open(path, flags)
                except OSError as error:
                    raise ReleaseError("codex_schema_bundle_file_unreadable") from error
                digest = hashlib.sha256()
                schema_relative = (
                    relative.removeprefix(f"{CODEX_SCHEMA_PRIV_PATH}/")
                    if relative.startswith(f"{CODEX_SCHEMA_PRIV_PATH}/")
                    else None
                )
                semantic_json = schema_relative is not None and schema_relative.startswith(
                    ("json/", "experimental/json/")
                )
                semantic_raw = schema_relative is not None and schema_relative.startswith(
                    ("typescript/", "experimental/typescript/")
                )
                captured = (
                    bytearray()
                    if relative in SYMPHONY_PRIV_CAPTURE_FILES or semantic_json
                    else None
                )
                try:
                    with os.fdopen(descriptor, "rb") as handle:
                        opened = os.fstat(handle.fileno())
                        if (
                            not stat.S_ISREG(opened.st_mode)
                            or (opened.st_dev, opened.st_ino, opened.st_size)
                            != (metadata.st_dev, metadata.st_ino, metadata.st_size)
                        ):
                            raise ReleaseError("codex_schema_bundle_file_replaced")
                        observed_size = 0
                        while chunk := handle.read(1024 * 1024):
                            observed_size += len(chunk)
                            if observed_size > metadata.st_size:
                                raise ReleaseError("codex_schema_bundle_file_replaced")
                            digest.update(chunk)
                            if captured is not None:
                                if len(captured) + len(chunk) > MAX_JSON_BYTES:
                                    raise ReleaseError("codex_schema_bundle_metadata_too_large")
                                captured.extend(chunk)
                        closed = os.fstat(handle.fileno())
                        if (
                            observed_size != metadata.st_size
                            or (closed.st_dev, closed.st_ino, closed.st_size)
                            != (metadata.st_dev, metadata.st_ino, metadata.st_size)
                        ):
                            raise ReleaseError("codex_schema_bundle_file_replaced")
                except OSError as error:
                    raise ReleaseError("codex_schema_bundle_file_unreadable") from error
                records[relative] = digest.hexdigest()
                if captured is not None:
                    contents = bytes(captured)
                    if relative in SYMPHONY_PRIV_CAPTURE_FILES:
                        special_contents[relative] = contents
                    if semantic_json:
                        try:
                            value = json.loads(contents)
                            canonical = json.dumps(
                                value,
                                ensure_ascii=False,
                                allow_nan=False,
                                separators=(",", ":"),
                                sort_keys=True,
                            ).encode("utf-8")
                        except (UnicodeDecodeError, ValueError, TypeError) as error:
                            raise ReleaseError(
                                "codex_schema_bundle_generated_json_invalid"
                            ) from error
                        assert schema_relative is not None
                        semantic_records[schema_relative] = sha256_bytes(canonical)
                if semantic_raw:
                    assert schema_relative is not None
                    semantic_records[schema_relative] = digest.hexdigest()

    try:
        pinned_version = special_contents.get("codex_schema/CODEX_VERSION", b"").decode(
            "ascii"
        ).strip()
    except UnicodeDecodeError as error:
        raise ReleaseError("symphony_priv_shape_invalid") from error
    if (
        set(special_contents) != SYMPHONY_PRIV_CAPTURE_FILES
        or not SYMPHONY_PRIV_REQUIRED_FILES.issubset(records)
        or pinned_version != CODEX_SCHEMA_VERSION
    ):
        raise ReleaseError("symphony_priv_shape_invalid")
    manifest_path = f"{CODEX_SCHEMA_PRIV_PATH}/manifest.json"
    matrix_path = f"{CODEX_SCHEMA_PRIV_PATH}/method-field-matrix.json"
    semantic_path = f"{CODEX_SCHEMA_PRIV_PATH}/SEMANTIC-SHA256SUMS"
    try:
        manifest = json.loads(special_contents[manifest_path])
        matrix = json.loads(special_contents[matrix_path])
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReleaseError("codex_schema_bundle_metadata_invalid") from error
    schema_records = {
        relative.removeprefix(f"{CODEX_SCHEMA_PRIV_PATH}/"): digest
        for relative, digest in records.items()
        if relative.startswith(f"{CODEX_SCHEMA_PRIV_PATH}/")
    }
    artifact_sections = (
        "json",
        "typescript",
        "experimentalJson",
        "experimentalTypescript",
    )
    artifacts = manifest.get("artifacts") if isinstance(manifest, dict) else None
    counts = (
        [artifacts.get(section, {}).get("fileCount") for section in artifact_sections]
        if isinstance(artifacts, dict)
        else []
    )
    if (
        not isinstance(manifest, dict)
        or not isinstance(matrix, dict)
        or not all(isinstance(count, int) and count > 0 for count in counts)
        or sum(counts) != len(schema_records) - len(CODEX_SCHEMA_REQUIRED_FILES)
        or (manifest.get("codex") or {}).get("version") != CODEX_SCHEMA_VERSION
        or (manifest.get("matrix") or {}).get("path") != "method-field-matrix.json"
        or (manifest.get("matrix") or {}).get("sha256")
        != sha256_bytes(special_contents[matrix_path])
        or SHA256_RE.fullmatch(artifacts.get("artifactBundleSha256", "")) is None
    ):
        raise ReleaseError("codex_schema_bundle_manifest_invalid")

    semantic_raw = special_contents[semantic_path]
    if not semantic_raw.endswith(b"\n"):
        raise ReleaseError("codex_schema_bundle_semantic_inventory_invalid")
    expected_semantic_records: dict[str, str] = {}
    try:
        semantic_lines = semantic_raw.decode("ascii").splitlines()
    except UnicodeDecodeError as error:
        raise ReleaseError("codex_schema_bundle_semantic_inventory_invalid") from error
    for line in semantic_lines:
        match = re.fullmatch(r"([0-9a-f]{64})  ([^\r\n]+)", line)
        if match is None:
            raise ReleaseError("codex_schema_bundle_semantic_inventory_invalid")
        digest, relative = match.groups()
        pure = PurePosixPath(relative)
        if (
            pure.is_absolute()
            or not pure.parts
            or any(part in {"", ".", ".."} for part in pure.parts)
            or relative in CODEX_SCHEMA_REQUIRED_FILES
            or relative not in schema_records
            or relative in expected_semantic_records
        ):
            raise ReleaseError("codex_schema_bundle_semantic_inventory_invalid")
        expected_semantic_records[relative] = digest
    if (
        set(expected_semantic_records) != set(schema_records) - CODEX_SCHEMA_REQUIRED_FILES
        or expected_semantic_records != semantic_records
    ):
        raise ReleaseError("codex_schema_bundle_semantic_inventory_mismatch")

    return {relative: records[relative] for relative in sorted(records)}


def validate_runtime_dependency_sources(
    tree_root: Path,
    deps_root: Path,
    build_path: str,
) -> dict[str, Any]:
    inventory_path = tree_root / RUNTIME_DEPENDENCY_INVENTORY_PATH
    notices_path = tree_root / THIRD_PARTY_NOTICES_PATH
    lock_path = tree_root / "elixir/mix.lock"
    inventory = validate_runtime_dependency_inventory(
        checked_runtime_source_file(inventory_path),
        checked_runtime_source_file(notices_path),
        checked_runtime_source_file(lock_path),
    )
    elixir_binary = shutil.which("elixir", path=build_path)
    erlang_binary = shutil.which("erl", path=build_path)
    if not elixir_binary or not erlang_binary:
        raise ReleaseError("runtime_dependency_toolchain_license_unavailable")
    elixir_license = Path(elixir_binary).resolve().parents[1] / "LICENSE"
    otp_version_path = (
        Path(erlang_binary).resolve().parents[1]
        / "releases"
        / "28"
        / "OTP_VERSION"
    )
    if checked_runtime_source_file(otp_version_path).decode("ascii").strip() != "28.5":
        raise ReleaseError("runtime_dependency_erlang_version_mismatch")
    for component in inventory["components"]:
        for license_file in component["licenseFiles"]:
            kind = license_file["kind"]
            if kind == "immutable-upstream":
                continue
            if kind in {"hex-extract", "hex-extract-attribution"}:
                dependency_root = deps_root / component["name"]
                if (
                    not dependency_root.is_dir()
                    or dependency_root.is_symlink()
                    or dependency_root.resolve().parent != deps_root.resolve()
                ):
                    raise ReleaseError(
                        f"runtime_dependency_source_invalid:{component['name']}"
                    )
                source = dependency_root / license_file["path"]
                if not is_within(source, dependency_root):
                    raise ReleaseError("runtime_dependency_license_path_invalid")
            elif kind == "vendored":
                source = tree_root / license_file["path"]
                if not is_within(source, tree_root):
                    raise ReleaseError("runtime_dependency_license_path_invalid")
            else:
                source = elixir_license
            raw = checked_runtime_license_file(source, license_file["sha256"])
            if (
                kind == "hex-extract-attribution"
                and sha256_bytes(runtime_license_excerpt(raw))
                != license_file["excerptSha256"]
            ):
                raise ReleaseError(
                    f"runtime_dependency_license_excerpt_mismatch:{component['name']}"
                )
    return inventory


def validate_escript_runtime_inventory(
    escript: Path,
    inventory: Mapping[str, Any],
    symphony_priv: Path,
) -> list[dict[str, str]]:
    metadata = escript.lstat() if escript.exists() else None
    if (
        metadata is None
        or stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_size > MAX_ARCHIVE_FILE_BYTES
    ):
        raise ReleaseError("escript_runtime_inventory_source_invalid")
    raw = escript.read_bytes()
    marker = raw.find(b"PK\x03\x04")
    if marker < 0:
        raise ReleaseError("escript_runtime_inventory_zip_missing")
    expected_versions = {
        application: component["version"]
        for component in inventory["components"]
        for application in component["applications"]
    }
    symphony = inventory["symphonyApplication"]
    expected_versions[symphony["name"]] = symphony["version"]
    symphony_priv_source_records(symphony_priv)
    expected_priv_files = EXPECTED_ESCRIPT_PRIV_FILES
    observed: dict[str, str] = {}
    priv_files: set[str] = set()
    nil_escript_count = 0
    with zipfile.ZipFile(io.BytesIO(raw[marker:]), "r") as archive:
        infos = archive.infolist()
        if not infos or len(infos) > MAX_ARCHIVE_FILES:
            raise ReleaseError("escript_runtime_inventory_entry_count_invalid")
        seen: set[str] = set()
        total_bytes = 0
        for info in infos:
            name = PurePosixPath(info.filename)
            mode = (info.external_attr >> 16) & 0o170000
            if (
                info.is_dir()
                or name.is_absolute()
                or not name.parts
                or any(part in {"", ".", ".."} for part in name.parts)
                or len(info.filename.encode("utf-8")) > MAX_ARCHIVE_PATH_BYTES
                or info.filename in seen
                or mode not in {0, stat.S_IFREG}
                or info.flag_bits & 0x1
                or info.file_size < 0
                or info.file_size > MAX_ARCHIVE_FILE_BYTES
            ):
                raise ReleaseError("escript_runtime_inventory_entry_invalid")
            seen.add(info.filename)
            total_bytes += info.file_size
            if total_bytes > MAX_ARCHIVE_TOTAL_BYTES:
                raise ReleaseError("escript_runtime_inventory_total_size_exceeded")
            if len(name.parts) >= 2 and name.parts[1] == "priv":
                priv_files.add(info.filename)
            if info.filename == "nil_escript.beam":
                nil_escript_count += 1
            if info.filename.endswith(".app"):
                if (
                    len(name.parts) != 3
                    or name.parts[1] != "ebin"
                    or name.parts[2] != f"{name.parts[0]}.app"
                    or info.file_size > MAX_ESCRIPT_APPLICATION_BYTES
                ):
                    raise ReleaseError("escript_runtime_application_path_invalid")
                application = name.parts[0]
                app_raw = archive.read(info)
                versions = re.findall(rb'\{vsn,"([^"\r\n]+)"\}', app_raw)
                if len(versions) != 1:
                    raise ReleaseError(
                        f"escript_runtime_application_version_invalid:{application}"
                    )
                try:
                    version = versions[0].decode("ascii")
                except UnicodeDecodeError as error:
                    raise ReleaseError(
                        "escript_runtime_application_version_invalid"
                    ) from error
                if application in observed:
                    raise ReleaseError("escript_runtime_application_duplicate")
                observed[application] = version
    if observed != expected_versions:
        raise ReleaseError("escript_runtime_application_inventory_mismatch")
    if nil_escript_count != 1:
        raise ReleaseError("escript_runtime_nil_escript_inventory_mismatch")
    if priv_files != expected_priv_files:
        raise ReleaseError("escript_runtime_priv_inventory_mismatch")
    return [
        {"name": name, "version": observed[name]}
        for name in sorted(observed)
    ]


def apply_dependency_build_patches(
    deps_root: Path,
    lock_path: Path,
    patches: Sequence[Mapping[str, Any]] = DEPENDENCY_BUILD_PATCHES,
) -> list[dict[str, str]]:
    root_metadata = deps_root.lstat() if deps_root.exists() else None
    if (
        root_metadata is None
        or stat.S_ISLNK(root_metadata.st_mode)
        or not stat.S_ISDIR(root_metadata.st_mode)
        or root_metadata.st_uid != os.getuid()
    ):
        raise ReleaseError("dependency_build_patch_root_invalid")
    lock_metadata = lock_path.lstat() if lock_path.exists() else None
    if (
        lock_metadata is None
        or stat.S_ISLNK(lock_metadata.st_mode)
        or not stat.S_ISREG(lock_metadata.st_mode)
        or lock_metadata.st_size > MAX_JSON_BYTES
    ):
        raise ReleaseError("dependency_build_patch_lock_invalid")
    locked = locked_hex_packages(lock_path.read_bytes())
    patch_dependencies = [str(patch.get("dependency")) for patch in patches]
    if len(patch_dependencies) != len(set(patch_dependencies)):
        raise ReleaseError("dependency_build_patch_duplicate_dependency")
    for patch in patches:
        dependency = str(patch["dependency"])
        relative = PurePosixPath(str(patch["path"]))
        if (
            re.fullmatch(r"[a-z0-9_]+", dependency) is None
            or relative.is_absolute()
            or not relative.parts
            or any(part in {"", ".", ".."} for part in relative.parts)
        ):
            raise ReleaseError("dependency_build_patch_path_invalid")
        locked_dependency = locked.get(dependency)
        if (
            locked_dependency is None
            or locked_dependency.get("version") != patch.get("version")
        ):
            raise ReleaseError(f"dependency_build_patch_version_mismatch:{dependency}")
        dependency_root = deps_root / dependency
        dependency_metadata = (
            dependency_root.lstat() if dependency_root.exists() else None
        )
        if (
            dependency_metadata is None
            or stat.S_ISLNK(dependency_metadata.st_mode)
            or not stat.S_ISDIR(dependency_metadata.st_mode)
            or dependency_metadata.st_uid != os.getuid()
        ):
            raise ReleaseError(f"dependency_build_patch_source_invalid:{dependency}")
        path = dependency_root / Path(*relative.parts)
        metadata = path.lstat() if path.exists() else None
        if (
            metadata is None
            or stat.S_ISLNK(metadata.st_mode)
            or not stat.S_ISREG(metadata.st_mode)
            or metadata.st_size > MAX_ARCHIVE_FILE_BYTES
        ):
            raise ReleaseError(f"dependency_build_patch_source_invalid:{dependency}")
        raw = path.read_bytes()
        if sha256_bytes(raw) != patch["originalSha256"]:
            raise ReleaseError(f"dependency_build_patch_original_mismatch:{dependency}")
        patched = raw
        replacements = patch.get("replacements")
        if not isinstance(replacements, tuple) or not replacements:
            raise ReleaseError("dependency_build_patch_replacements_invalid")
        for before, after in replacements:
            if not isinstance(before, bytes) or not isinstance(after, bytes):
                raise ReleaseError("dependency_build_patch_replacement_type_invalid")
            if patched.count(before) != 1:
                raise ReleaseError(f"dependency_build_patch_match_count_invalid:{dependency}")
            patched = patched.replace(before, after, 1)
        if sha256_bytes(patched) != patch["patchedSha256"]:
            raise ReleaseError(f"dependency_build_patch_result_mismatch:{dependency}")
        atomic_write(path, patched, stat.S_IMODE(metadata.st_mode))
    return dependency_build_patch_records(patches)


def pinned_toolchain_path(elixir: Path) -> str:
    mise = shutil.which("mise")
    home = os.environ.get("HOME")
    inherited_path = os.environ.get("PATH")
    if not mise or not home or not inherited_path:
        raise ReleaseError("pinned_build_toolchain_unavailable")
    lookup_env = {
        "HOME": home,
        "LANG": os.environ.get("LANG", "C.UTF-8"),
        "PATH": inherited_path,
        "TZ": "UTC",
    }
    tool_directories: set[str] = set()
    for tool in ("mix", "elixir", "erl"):
        result = run((mise, "which", tool), cwd=elixir, env=lookup_env, timeout=60)
        resolved = Path(result.stdout.strip())
        if not resolved.is_absolute() or not resolved.is_file() or result.stderr:
            raise ReleaseError(f"pinned_build_tool_missing:{tool}")
        tool_directories.add(str(resolved.parent))
    return os.pathsep.join((*sorted(tool_directories), inherited_path))


def normalize_escript(source: Path, destination: Path) -> None:
    metadata = source.lstat()
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_size > MAX_ARCHIVE_FILE_BYTES
    ):
        raise ReleaseError("escript_build_output_invalid")
    raw = source.read_bytes()
    marker = raw.find(b"PK\x03\x04")
    if marker < 0:
        raise ReleaseError("escript_zip_marker_missing")
    prefix = raw[:marker]
    with zipfile.ZipFile(io.BytesIO(raw[marker:]), "r") as archive:
        infos = archive.infolist()
        if not infos or len(infos) > MAX_ARCHIVE_FILES:
            raise ReleaseError("escript_entry_count_invalid")
        names: set[str] = set()
        total_bytes = 0
        for info in infos:
            name = PurePosixPath(info.filename)
            mode = (info.external_attr >> 16) & 0o170000
            if (
                info.is_dir()
                or name.is_absolute()
                or not name.parts
                or any(part in {"", ".", ".."} for part in name.parts)
                or len(info.filename.encode("utf-8")) > MAX_ARCHIVE_PATH_BYTES
                or info.filename in names
                or mode not in {0, stat.S_IFREG}
                or info.flag_bits & 0x1
                or info.file_size < 0
                or info.file_size > MAX_ARCHIVE_FILE_BYTES
            ):
                raise ReleaseError("escript_entry_invalid")
            names.add(info.filename)
            total_bytes += info.file_size
            if total_bytes > MAX_ARCHIVE_TOTAL_BYTES:
                raise ReleaseError("escript_total_size_exceeded")
        entries = [(info, archive.read(info.filename)) for info in infos]
    archive_buffer = io.BytesIO()
    with zipfile.ZipFile(
        archive_buffer,
        "w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=9,
    ) as archive:
        for old, content in sorted(entries, key=lambda pair: pair[0].filename):
            info = zipfile.ZipInfo(old.filename, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            mode = (old.external_attr >> 16) & 0o777
            info.external_attr = ((mode or 0o644) & 0o777) << 16
            info.flag_bits = old.flag_bits & 0x800
            archive.writestr(info, content)
    atomic_write(destination, prefix + archive_buffer.getvalue(), 0o755)


def export_tree(commit: str, destination: Path) -> None:
    archive = subprocess.Popen(
        ["git", "archive", "--format=tar", commit],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert archive.stdout is not None
    extract = subprocess.run(
        ["tar", "-xf", "-", "-C", str(destination)],
        stdin=archive.stdout,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    archive.stdout.close()
    archive_stderr = archive.stderr.read() if archive.stderr else b""
    archive_rc = archive.wait()
    if archive_rc != 0 or extract.returncode != 0:
        raise ReleaseError("git_tree_export_failed")
    if archive_stderr:
        raise ReleaseError("git_tree_export_diagnostic")


@contextlib.contextmanager
def fixed_release_build_root():
    root = FIXED_RELEASE_BUILD_ROOT
    parent = root.parent
    parent_metadata = parent.lstat()
    if (
        stat.S_ISLNK(parent_metadata.st_mode)
        or not stat.S_ISDIR(parent_metadata.st_mode)
        or parent.resolve() != Path("/tmp")
    ):
        raise ReleaseError("fixed_release_build_parent_invalid")
    try:
        root.mkdir(mode=0o700)
    except FileExistsError as error:
        raise ReleaseError("fixed_release_build_root_busy") from error
    metadata = root.lstat()
    identity = (metadata.st_dev, metadata.st_ino)
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISDIR(metadata.st_mode)
        or stat.S_IMODE(metadata.st_mode) != 0o700
        or metadata.st_uid != os.getuid()
    ):
        raise ReleaseError("fixed_release_build_root_invalid")
    try:
        yield root
    finally:
        current = root.lstat() if root.exists() else None
        if (
            current is None
            or stat.S_ISLNK(current.st_mode)
            or not stat.S_ISDIR(current.st_mode)
            or (current.st_dev, current.st_ino) != identity
        ):
            raise ReleaseError("fixed_release_build_root_replaced")
        shutil.rmtree(root)
        if root.exists():
            raise ReleaseError("fixed_release_build_root_cleanup_failed")


def build_escript(tree_root: Path, temp_root: Path, manifest: Mapping[str, Any], merged_sha: str) -> Path:
    elixir = tree_root / "elixir"
    env = safe_build_environment(temp_root, manifest, merged_sha)
    env["PATH"] = pinned_toolchain_path(elixir)
    setup_commands = (
        ("mix", "local.hex", HEX_VERSION, "--force"),
        ("mix", "local.rebar", "--force", "--sha512", REBAR3_SHA512),
        ("mix", "deps.get", "--check-locked"),
    )
    for command in setup_commands:
        run(command, cwd=elixir, env=env, timeout=1800)
    inventory = validate_runtime_dependency_sources(
        tree_root,
        Path(env["MIX_DEPS_PATH"]),
        env["PATH"],
    )
    apply_dependency_build_patches(Path(env["MIX_DEPS_PATH"]), elixir / "mix.lock")
    build_commands = (
        ("mix", "deps.compile"),
        ("mix", "escript.build"),
    )
    for command in build_commands:
        run(command, cwd=elixir, env=env, timeout=1800)
    built = elixir / "bin" / "symphony"
    if not built.is_file():
        raise ReleaseError("escript_build_output_missing")
    normalized = temp_root / "symphony.normalized"
    normalize_escript(built, normalized)
    validate_escript_runtime_inventory(
        normalized,
        inventory,
        tree_root / SYMPHONY_PRIV_PATH,
    )
    return normalized


def build_reproducible_escript(
    commit: str,
    manifest: Mapping[str, Any],
    merged_sha: str,
    destination: Path,
) -> None:
    with fixed_release_build_root() as root:
        tree_root = root / "tree"
        tree_root.mkdir(mode=0o700)
        export_tree(commit, tree_root)
        built = build_escript(tree_root, root / "build", manifest, merged_sha)
        atomic_write(destination, built.read_bytes(), 0o755)


def tracked_modes(commit: str) -> dict[str, int]:
    process = subprocess.Popen(
        ["git", "ls-tree", "-rzl", "--full-tree", commit],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert process.stdout is not None
    modes: dict[str, int] = {}
    total_bytes = 0
    buffer = bytearray()
    while chunk := process.stdout.read(64 * 1024):
        buffer.extend(chunk)
        while (separator := buffer.find(b"\0")) >= 0:
            record = bytes(buffer[:separator])
            del buffer[: separator + 1]
            if not record:
                continue
            if len(record) > MAX_TREE_RECORD_BYTES:
                process.kill()
                process.wait()
                raise ReleaseError("release_tree_record_too_large")
            try:
                metadata, raw_path = record.split(b"\t", 1)
                mode_text, kind, _object, size_text = metadata.decode("ascii").split()
                path = raw_path.decode("utf-8")
                size = int(size_text)
            except (UnicodeDecodeError, ValueError) as error:
                process.kill()
                process.wait()
                raise ReleaseError("release_tree_record_invalid") from error
            if len(raw_path) > MAX_ARCHIVE_PATH_BYTES:
                process.kill()
                process.wait()
                raise ReleaseError("release_tree_path_too_large")
            if kind != "blob" or mode_text not in {"100644", "100755"}:
                process.kill()
                process.wait()
                raise ReleaseError(f"unsupported_release_tree_entry:{path}")
            if size < 0 or size > MAX_ARCHIVE_FILE_BYTES:
                process.kill()
                process.wait()
                raise ReleaseError(f"release_tree_file_too_large:{path}")
            if len(modes) >= MAX_ARCHIVE_FILES:
                process.kill()
                process.wait()
                raise ReleaseError("release_tree_file_count_exceeded")
            total_bytes += size
            if total_bytes > MAX_ARCHIVE_TOTAL_BYTES:
                process.kill()
                process.wait()
                raise ReleaseError("release_tree_total_size_exceeded")
            modes[path] = 0o755 if mode_text == "100755" else 0o644
        if len(buffer) > MAX_TREE_RECORD_BYTES:
            process.kill()
            process.wait()
            raise ReleaseError("release_tree_record_too_large")
    stderr = process.stderr.read() if process.stderr else b""
    return_code = process.wait()
    if buffer or return_code != 0 or stderr:
        raise ReleaseError("git_tree_inventory_failed")
    return modes


def deterministic_archive(
    tree_root: Path,
    tracked: Mapping[str, int],
    normalized_escript: Path,
    output: Path,
    epoch: int,
) -> None:
    modes = dict(tracked)
    if "elixir/bin/symphony" not in modes and len(modes) >= MAX_ARCHIVE_FILES:
        raise ReleaseError("release_tree_file_count_exceeded")
    modes["elixir/bin/symphony"] = 0o755
    total_bytes = 0
    for relative in modes:
        source = normalized_escript if relative == "elixir/bin/symphony" else tree_root / relative
        if not source.is_file() or source.is_symlink():
            raise ReleaseError(f"package_source_invalid:{relative}")
        size = source.stat().st_size
        if size > MAX_ARCHIVE_FILE_BYTES:
            raise ReleaseError(f"package_source_too_large:{relative}")
        total_bytes += size
        if total_bytes > MAX_ARCHIVE_TOTAL_BYTES:
            raise ReleaseError("package_source_total_size_exceeded")
    prefix = f"symphony-studio-{VERSION.removeprefix('v')}"
    tar_buffer = io.BytesIO()
    with tarfile.open(fileobj=tar_buffer, mode="w", format=tarfile.GNU_FORMAT) as archive:
        for relative in sorted(modes):
            source = normalized_escript if relative == "elixir/bin/symphony" else tree_root / relative
            content = source.read_bytes()
            info = tarfile.TarInfo(f"{prefix}/{relative}")
            info.size = len(content)
            info.mode = modes[relative]
            info.mtime = epoch
            info.uid = 0
            info.gid = 0
            info.uname = "root"
            info.gname = "root"
            archive.addfile(info, io.BytesIO(content))
    with output.open("wb") as handle:
        with gzip.GzipFile(filename="", mode="wb", fileobj=handle, mtime=0, compresslevel=9) as zipped:
            zipped.write(tar_buffer.getvalue())


def git_runtime_dependency_inventory(commit: str) -> dict[str, Any]:
    return validate_runtime_dependency_inventory(
        git_bytes(commit, RUNTIME_DEPENDENCY_INVENTORY_PATH),
        git_bytes(commit, THIRD_PARTY_NOTICES_PATH),
        git_bytes(commit, "elixir/mix.lock"),
    )


def runtime_dependency_packages(
    inventory: Mapping[str, Any],
) -> list[dict[str, Any]]:
    patches = {
        str(patch["dependency"]): patch
        for patch in dependency_build_patch_records()
    }
    packages: list[dict[str, Any]] = []
    for component in inventory["components"]:
        if component["sourceKind"] == "hex":
            download_location = (
                f"https://hex.pm/packages/{component['name']}/{component['version']}"
            )
        elif component["sourceKind"] == "pinned-toolchain":
            download_location = component["licenseFiles"][0]["source"]
        else:
            download_location = "https://github.com/saleyn/erlexec/tree/2.3.4"
        for application in component["applications"]:
            package: dict[str, Any] = {
                "SPDXID": f"SPDXRef-Package-{application.replace('_', '-')}",
                "comment": (
                    f"Runtime component {component['name']}; scope {component['scope']}; "
                    f"bundled application {application}."
                ),
                "downloadLocation": download_location,
                "filesAnalyzed": False,
                "licenseConcluded": component["spdxLicense"],
                "licenseDeclared": component["spdxLicense"],
                "name": application,
                "versionInfo": component["version"],
            }
            if component["sourceKind"] == "hex":
                package["checksums"] = [
                    {
                        "algorithm": "SHA256",
                        "checksumValue": component["contentSha256"],
                    }
                ]
                package["externalRefs"] = [
                    {
                        "referenceCategory": "PACKAGE-MANAGER",
                        "referenceLocator": (
                            f"pkg:hex/{component['name']}@{component['version']}"
                        ),
                        "referenceType": "purl",
                    }
                ]
                package["comment"] += (
                    " Hex content checksum is the SPDX package checksum; "
                    f"Hex registry checksum {component['registrySha256']}."
                )
            if component["name"] == "erlexec":
                package["comment"] += (
                    " Hex metadata labels BSD-2-Clause; the bundled three-clause "
                    "license text is authoritative and concluded BSD-3-Clause."
                )
            patch = patches.get(component["name"])
            if patch is not None:
                package["comment"] += (
                    " Downstream build-only determinism patch: "
                    f"{patch['path']}; original SHA-256 {patch['originalSha256']}; "
                    f"patched SHA-256 {patch['patchedSha256']}; {patch['purpose']}."
                )
            packages.append(package)
    return sorted(packages, key=lambda item: item["SPDXID"])


def spdx_document(
    commit: str,
    archive_sha: str,
    created: str,
    inventory: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    root_package = {
        "SPDXID": "SPDXRef-Package-Symphony-Studio",
        "checksums": [{"algorithm": "SHA256", "checksumValue": archive_sha}],
        "downloadLocation": f"https://github.com/{REPOSITORY}",
        "filesAnalyzed": False,
        "licenseConcluded": "Apache-2.0",
        "licenseDeclared": "Apache-2.0",
        "name": "Symphony Studio",
        "comment": (
            "The install archive contains the exact committed "
            f"{THIRD_PARTY_NOTICES_PATH} and the normalized production escript."
        ),
        "versionInfo": VERSION.removeprefix("v"),
    }
    dependencies = runtime_dependency_packages(
        inventory if inventory is not None else git_runtime_dependency_inventory(commit)
    )
    return {
        "SPDXID": "SPDXRef-DOCUMENT",
        "creationInfo": {"created": created, "creators": ["Tool: Symphony-Studio-release/1"]},
        "dataLicense": "CC0-1.0",
        "documentDescribes": [root_package["SPDXID"]],
        "documentNamespace": f"https://github.com/{REPOSITORY}/releases/{VERSION}/{commit}",
        "name": f"Symphony Studio {VERSION} SBOM",
        "packages": [root_package, *dependencies],
        "relationships": [
            {
                "relatedSpdxElement": package["SPDXID"],
                "relationshipType": "DEPENDS_ON",
                "spdxElementId": root_package["SPDXID"],
            }
            for package in dependencies
        ],
        "spdxVersion": "SPDX-2.3",
    }


def safe_extract(archive: Path, destination: Path) -> Path:
    roots: set[str] = set()
    seen: set[str] = set()
    total_bytes = 0
    file_count = 0
    with tarfile.open(archive, "r:gz") as source:
        for member in source:
            file_count += 1
            if file_count > MAX_ARCHIVE_FILES:
                raise ReleaseError("package_archive_file_count_exceeded")
            path = PurePosixPath(member.name)
            encoded_name = member.name.encode("utf-8")
            if (
                not member.isfile()
                or path.is_absolute()
                or not path.parts
                or any(part in {"", ".", ".."} for part in path.parts)
                or len(encoded_name) > MAX_ARCHIVE_PATH_BYTES + 128
                or member.name in seen
                or member.mode not in {0o644, 0o755}
                or member.size < 0
                or member.size > MAX_ARCHIVE_FILE_BYTES
            ):
                raise ReleaseError("unsafe_package_archive_entry")
            total_bytes += member.size
            if total_bytes > MAX_ARCHIVE_TOTAL_BYTES:
                raise ReleaseError("package_archive_total_size_exceeded")
            seen.add(member.name)
            roots.add(path.parts[0])
            target = destination.joinpath(*path.parts)
            if not is_within(target, destination):
                raise ReleaseError("unsafe_package_archive_entry")
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            cursor = destination
            for part in path.parts[:-1]:
                cursor = cursor / part
                metadata = cursor.lstat()
                if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
                    raise ReleaseError("unsafe_package_archive_parent")
            extracted = source.extractfile(member)
            if extracted is None:
                raise ReleaseError("package_archive_content_missing")
            copied = 0
            try:
                with target.open("xb") as output:
                    while chunk := extracted.read(1024 * 1024):
                        copied += len(chunk)
                        if copied > member.size:
                            raise ReleaseError("package_archive_size_mismatch")
                        output.write(chunk)
                    output.flush()
                    os.fsync(output.fileno())
            finally:
                extracted.close()
            if copied != member.size:
                raise ReleaseError("package_archive_size_mismatch")
            target.chmod(member.mode)
    if not seen:
        raise ReleaseError("package_archive_empty")
    if len(roots) != 1:
        raise ReleaseError("package_archive_root_invalid")
    root = destination / next(iter(roots))
    if not root.is_dir() or root.is_symlink():
        raise ReleaseError("package_archive_root_invalid")
    return root


def scan_public_file(path: Path, label: str) -> None:
    metadata = path.lstat()
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_size > MAX_ARCHIVE_FILE_BYTES
    ):
        raise ReleaseError(f"public_artifact_file_invalid:{label}")
    payload = path.read_bytes()
    for category, pattern in PUBLIC_SECRET_PATTERNS.items():
        if pattern.search(payload):
            raise ReleaseError(f"public_artifact_content_rejected:{category}:{label}")


def public_artifact_audit_value(
    directory: Path, merged_sha: str
) -> dict[str, Any]:
    archive_name = f"symphony-studio-{VERSION.removeprefix('v')}-linux-x86_64.tar.gz"
    archive = directory / archive_name
    package_scope = sorted(
        path
        for path in directory.iterdir()
        if path.is_file()
        and path.name
        not in {
            PLATFORM_RECEIPT_NAME,
            PUBLIC_ARTIFACT_AUDIT_NAME,
            "release-package-manifest.json",
            "release-manifest.json",
            "SHA256SUMS",
        }
    )
    for path in package_scope:
        if path.name != archive_name:
            scan_public_file(path, path.name)
    inherited_media: dict[str, str] = {}
    scanned_files = 0
    with tempfile.TemporaryDirectory(prefix="symphony-release-public-audit-") as temporary:
        extracted = safe_extract(archive, Path(temporary))
        for path in sorted(item for item in extracted.rglob("*") if item.is_file()):
            relative = path.relative_to(extracted).as_posix()
            pure = PurePosixPath(relative)
            lowered_parts = {part.lower() for part in pure.parts}
            lowered_name = pure.name.lower()
            if (
                lowered_parts & FORBIDDEN_ARCHIVE_SEGMENTS
                or lowered_name in FORBIDDEN_ARCHIVE_BASENAMES
                or any(lowered_name.endswith(suffix) for suffix in FORBIDDEN_ARCHIVE_SUFFIXES)
            ):
                raise ReleaseError(f"public_archive_path_rejected:{relative}")
            if pure.suffix.lower() in MEDIA_SUFFIXES:
                inherited_media[relative] = sha256_file(path)
            scan_public_file(path, f"archive:{relative}")
            scanned_files += 1
    if inherited_media != INHERITED_MEDIA_SHA256:
        raise ReleaseError("public_archive_media_inventory_mismatch")
    inventory = [
        {"name": path.name, "sha256": sha256_file(path), "size": path.stat().st_size}
        for path in package_scope
    ]
    return {
        "archiveFileCount": scanned_files,
        "archiveSha256": sha256_file(archive),
        "artifactInventorySha256": sha256_bytes(canonical_json_bytes(inventory)),
        "forbiddenContentMatches": 0,
        "inheritedMedia": inherited_media,
        "kind": "public-release-artifact-audit",
        "packageFilesScanned": len(package_scope) - 1,
        "sourceCommit": merged_sha,
        "status": "pass",
    }


def verify_installed_binary(binary: Path, manifest: Mapping[str, Any], merged_sha: str) -> str:
    with tempfile.TemporaryDirectory(prefix="symphony-release-runtime-home-") as runtime_home:
        runtime_env = {
            "HOME": runtime_home,
            "LANG": os.environ.get("LANG", "C.UTF-8"),
            "PATH": pinned_toolchain_path(binary.parent.parent),
            "TZ": "UTC",
        }
        result = run(
            (str(binary), "--version"),
            cwd=binary.parent,
            env=runtime_env,
            check=False,
            timeout=60,
        )
    if result.returncode != 0:
        raise ReleaseError("installed_version_runtime_validation_failed")
    expected = "\n".join(
        (
            f"Symphony {VERSION.removeprefix('v')}",
            f"commit: {merged_sha}",
            f"upstream-base: {manifest['upstreamBaseSha']}",
            f"codex-compatibility-sha256: {manifest['codex']['artifactBundleSha256']}",
            "provenance: github-release-verified",
        )
    )
    if result.stdout.strip() != expected or result.stderr:
        raise ReleaseError("installed_version_output_mismatch")
    return expected


def verify_installed_guardrail_smoke(binary: Path) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix="symphony-release-guardrail-home-") as runtime_home:
        runtime_root = Path(runtime_home)
        runtime_env = {
            "HOME": runtime_home,
            "LANG": os.environ.get("LANG", "C.UTF-8"),
            "PATH": pinned_toolchain_path(binary.parent.parent),
            "TZ": "UTC",
        }
        result = run(
            (str(binary),),
            cwd=binary.parent,
            env=runtime_env,
            check=False,
            timeout=60,
        )
        runtime_home_empty = not any(runtime_root.iterdir())
    required_markers = (
        "Codex will run without any guardrails.",
        "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
    )
    if (
        result.returncode != 1
        or result.stdout
        or not all(marker in result.stderr for marker in required_markers)
        or not runtime_home_empty
    ):
        raise ReleaseError("installed_guardrail_smoke_failed")
    return {
        "exitCode": 1,
        "guardrailMarkersPresent": True,
        "noModelWork": True,
        "runtimeHomeEmpty": True,
        "stderrSha256": sha256_bytes(result.stderr.encode("utf-8")),
        "stdoutEmpty": True,
    }


def codex_compatibility_from_lock(
    merged_sha: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    try:
        lock = json.loads(git_bytes(merged_sha, "CODEX_LOCK.json"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReleaseError("clean_install_codex_lock_invalid") from error
    platforms = lock.get("platforms") if isinstance(lock, dict) else None
    selected = [
        item
        for item in platforms or []
        if isinstance(item, dict)
        and item.get("operatingSystem") == "linux"
        and item.get("architecture") == "x86_64"
    ]
    if (
        lock.get("version") != "0.144.3"
        or lock.get("versionOutput") != "codex-cli 0.144.3"
        or len(selected) != 1
    ):
        raise ReleaseError("clean_install_codex_lock_invalid")
    platform_lock = selected[0]
    record = {
        "authenticationRequiredForWork": True,
        "launcherSha256": platform_lock.get("launcherSha256"),
        "nativeSha256": platform_lock.get("nativeSha256"),
        "versionOutput": lock["versionOutput"],
    }
    if (
        not isinstance(record["launcherSha256"], str)
        or SHA256_RE.fullmatch(record["launcherSha256"]) is None
        or not isinstance(record["nativeSha256"], str)
        or SHA256_RE.fullmatch(record["nativeSha256"]) is None
    ):
        raise ReleaseError("clean_install_codex_lock_invalid")
    return platform_lock, record


def verify_installed_codex_compatibility(merged_sha: str) -> dict[str, Any]:
    platform_lock, record = codex_compatibility_from_lock(merged_sha)
    executable = shutil.which("codex")
    if not executable:
        raise ReleaseError("clean_install_codex_missing")
    launcher = Path(executable).resolve()
    if (
        not launcher.is_file()
        or launcher.is_symlink()
        or sha256_file(launcher) != platform_lock.get("launcherSha256")
    ):
        raise ReleaseError("clean_install_codex_launcher_mismatch")
    alias = str(platform_lock.get("installedPackageAlias", "")).split("/")[-1]
    target = platform_lock.get("target")
    if (
        re.fullmatch(r"[a-z0-9_-]+", alias) is None
        or not isinstance(target, str)
        or re.fullmatch(r"[A-Za-z0-9_-]+", target) is None
    ):
        raise ReleaseError("clean_install_codex_lock_invalid")
    package_root = launcher.parent.parent
    native_candidates = [
        package_root
        / "node_modules"
        / "@openai"
        / alias
        / "vendor"
        / target
        / "bin"
        / "codex",
        package_root.parent
        / alias
        / "vendor"
        / target
        / "bin"
        / "codex",
    ]
    native_candidates = [
        path for path in native_candidates if path.is_file() and not path.is_symlink()
    ]
    if (
        len(native_candidates) != 1
        or sha256_file(native_candidates[0]) != platform_lock.get("nativeSha256")
    ):
        raise ReleaseError("clean_install_codex_native_mismatch")
    home = Path.home()
    if not home.is_dir() or home.is_symlink():
        raise ReleaseError("clean_install_codex_home_invalid")
    with tempfile.TemporaryDirectory(
        prefix=".symphony-codex-version-", dir=home
    ) as temporary:
        result = run(
            (str(launcher), "--version"),
            cwd=Path(temporary),
            env={
                "HOME": temporary,
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "PATH": os.environ.get("PATH", "/usr/local/bin:/usr/bin:/bin"),
                "TERM": "dumb",
                "TZ": "UTC",
            },
            timeout=30,
        )
    if result.stdout.strip() != record["versionOutput"] or result.stderr:
        raise ReleaseError("clean_install_codex_version_mismatch")
    return record


def zero_work_state_projection(observed: Any) -> dict[str, Any]:
    projection = {
        "blocked": observed.get("blocked") if isinstance(observed, dict) else None,
        "counts": observed.get("counts") if isinstance(observed, dict) else None,
        "retrying": observed.get("retrying") if isinstance(observed, dict) else None,
        "running": observed.get("running") if isinstance(observed, dict) else None,
    }
    if projection != {
        "blocked": [],
        "counts": {"blocked": 0, "retrying": 0, "running": 0},
        "retrying": [],
        "running": [],
    }:
        raise ReleaseError("installed_runner_smoke_state_invalid")
    return projection


def verify_installed_runner_smoke(binary: Path) -> dict[str, Any]:
    acknowledgement = "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
    with tempfile.TemporaryDirectory(prefix="symphony-release-runner-smoke-") as temporary:
        root = Path(temporary)
        runtime_home = root / "home"
        workspace_root = root / "workspaces"
        logs_root = root / "logs"
        for path in (runtime_home, workspace_root, logs_root):
            path.mkdir(mode=0o700)
        workflow = root / "WORKFLOW.md"
        workflow.write_text(
            "---\n"
            "tracker:\n"
            "  kind: memory\n"
            '  endpoint: "http://127.0.0.1:0/graphql"\n'
            '  api_key: "network-hermetic-test-token"\n'
            '  project_slug: "network-hermetic-release-smoke"\n'
            '  assignee: "network-hermetic-release-smoke"\n'
            "  required_labels: []\n"
            '  active_states: ["Todo", "In Progress"]\n'
            '  terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]\n'
            "polling:\n"
            "  interval_ms: 30000\n"
            "workspace:\n"
            f'  root: "{workspace_root}"\n'
            "agent:\n"
            "  max_concurrent_agents: 1\n"
            "  max_turns: 1\n"
            "codex:\n"
            '  command: "codex app-server"\n'
            "  approval_policy:\n"
            "    reject:\n"
            "      sandbox_approval: true\n"
            "      rules: true\n"
            "      mcp_elicitations: true\n"
            '  thread_sandbox: "workspace-write"\n'
            "observability:\n"
            "  dashboard_enabled: false\n"
            "server:\n"
            "  port: null\n"
            '  host: "127.0.0.1"\n'
            "---\n"
            "Release package network-hermetic startup smoke.\n",
            encoding="utf-8",
        )
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("127.0.0.1", 0))
            port = int(listener.getsockname()[1])
        runtime_env = {
            "HOME": str(runtime_home),
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": pinned_toolchain_path(binary.parent.parent),
            "SHELL": "/bin/sh",
            "TZ": "UTC",
        }
        output_path = root / "runner.log"
        with output_path.open("wb") as output:
            process = subprocess.Popen(
                (
                    str(binary),
                    acknowledgement,
                    "--logs-root",
                    str(logs_root),
                    "--port",
                    str(port),
                    str(workflow),
                ),
                cwd=binary.parent,
                env=runtime_env,
                stdin=subprocess.DEVNULL,
                stdout=output,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            payload: bytes | None = None
            observed_status: int | None = None
            dashboard_payload: bytes | None = None
            dashboard_status: int | None = None
            try:
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    if process.poll() is not None:
                        raise ReleaseError("installed_runner_smoke_exited_early")
                    try:
                        request = urllib.request.Request(
                            f"http://127.0.0.1:{port}/api/v1/state",
                            headers={"Connection": "close"},
                        )
                        with urllib.request.urlopen(request, timeout=1) as response:
                            observed_status = response.status
                            payload = response.read(MAX_JSON_BYTES + 1)
                            if observed_status != 200:
                                raise ReleaseError("installed_runner_smoke_http_status_invalid")
                            break
                    except OSError:
                        pass
                    time.sleep(0.2)
                if payload is None or observed_status != 200 or len(payload) > MAX_JSON_BYTES:
                    raise ReleaseError("installed_runner_smoke_http_failed")
                try:
                    observed = json.loads(payload)
                except (UnicodeDecodeError, json.JSONDecodeError) as error:
                    raise ReleaseError("installed_runner_smoke_json_invalid") from error
                state_projection = zero_work_state_projection(observed)
                dashboard_request = urllib.request.Request(
                    f"http://127.0.0.1:{port}/",
                    headers={"Connection": "close"},
                )
                try:
                    with urllib.request.urlopen(
                        dashboard_request, timeout=5
                    ) as response:
                        dashboard_status = response.status
                        dashboard_payload = response.read(MAX_JSON_BYTES + 1)
                except OSError as error:
                    raise ReleaseError("installed_runner_dashboard_http_failed") from error
                if (
                    dashboard_status != 200
                    or dashboard_payload is None
                    or len(dashboard_payload) > MAX_JSON_BYTES
                ):
                    raise ReleaseError("installed_runner_dashboard_http_invalid")
                dashboard_markers = (
                    b"<title>Symphony Observability</title>",
                    b"Operations Dashboard",
                )
                if any(marker not in dashboard_payload for marker in dashboard_markers):
                    raise ReleaseError("installed_runner_dashboard_marker_missing")
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    try:
                        process.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=5)
                try:
                    os.killpg(process.pid, 0)
                except ProcessLookupError:
                    pass
                else:
                    os.killpg(process.pid, signal.SIGKILL)
                    raise ReleaseError("installed_runner_smoke_process_group_retained")
        if output_path.stat().st_size > MAX_JSON_BYTES:
            raise ReleaseError("installed_runner_smoke_output_too_large")
        return {
            "dashboardEndpoint": "/",
            "dashboardHttpStatus": dashboard_status,
            "dashboardMarkersPresent": True,
            "dashboardSha256": sha256_bytes(dashboard_payload or b""),
            "endpoint": "/api/v1/state",
            "httpStatus": observed_status,
            "noExternalTracker": True,
            "noModelWork": True,
            "processGroupCleaned": True,
            "stateProjectionSha256": sha256_bytes(
                canonical_json_bytes(state_projection)
            ),
            "zeroAdmittedIssues": True,
        }


def prepare_package(
    manifest_path: Path,
    output_dir: Path,
    merged_sha: str,
    pr_number: int,
) -> dict[str, Any]:
    manifest = validate_candidate(manifest_path, verify_refs=False)
    if git("rev-parse", "HEAD") != merged_sha:
        raise ReleaseError("packaging_requires_exact_merged_main")
    if run(("git", "merge-base", "--is-ancestor", merged_sha, "origin/main"), check=False).returncode != 0:
        raise ReleaseError("packaging_commit_not_on_remote_main")
    parents = git("rev-list", "--parents", "-n", "1", merged_sha).split()
    if parents != [merged_sha, manifest["baseSha"], manifest["releaseHeadSha"]]:
        raise ReleaseError("protected_merge_parent_identity_mismatch")
    merged_tree = git("rev-parse", f"{merged_sha}^{{tree}}")
    if merged_tree != manifest["testedMergeTreeSha"]:
        raise ReleaseError("merged_tree_differs_from_tested_candidate")
    if run(("git", "merge-base", "--is-ancestor", manifest["releaseHeadSha"], merged_sha), check=False).returncode != 0:
        raise ReleaseError("merged_commit_missing_release_head")
    if git("status", "--porcelain=v1", "--untracked-files=all"):
        raise ReleaseError("packaging_worktree_not_clean")

    inventory = tracked_modes(merged_sha)
    if (
        inventory.get(THIRD_PARTY_NOTICES_PATH) != 0o644
        or inventory.get(RUNTIME_DEPENDENCY_INVENTORY_PATH) != 0o644
    ):
        raise ReleaseError("runtime_dependency_release_source_mode_invalid")
    runtime_inventory = git_runtime_dependency_inventory(merged_sha)

    output_dir.mkdir(parents=True, exist_ok=True)
    epoch = int(git("show", "-s", "--format=%ct", merged_sha))
    created = iso_from_epoch(epoch)
    with tempfile.TemporaryDirectory(prefix="symphony-release-build-") as temporary:
        temp = Path(temporary)
        escript = temp / "symphony-build-a"
        rehearsal_escript = temp / "symphony-build-b"
        build_reproducible_escript(merged_sha, manifest, merged_sha, escript)
        build_reproducible_escript(
            merged_sha,
            manifest,
            merged_sha,
            rehearsal_escript,
        )
        if escript.read_bytes() != rehearsal_escript.read_bytes():
            raise ReleaseError("independent_escript_build_not_reproducible")
        tree_root = temp / "tree"
        tree_root.mkdir()
        export_tree(merged_sha, tree_root)
        package = output_dir / f"symphony-studio-{VERSION.removeprefix('v')}-linux-x86_64.tar.gz"
        deterministic_archive(tree_root, inventory, escript, package, epoch)
        rehearsal = temp / "rehearsal.tar.gz"
        deterministic_archive(tree_root, inventory, escript, rehearsal, epoch)
        if package.read_bytes() != rehearsal.read_bytes():
            raise ReleaseError("package_archive_not_reproducible")
        install_root = temp / "install"
        install_root.mkdir()
        extracted = safe_extract(package, install_root)
        version_output = verify_installed_binary(extracted / "elixir/bin/symphony", manifest, merged_sha)
        if (
            (extracted / THIRD_PARTY_NOTICES_PATH).read_bytes()
            != git_bytes(merged_sha, THIRD_PARTY_NOTICES_PATH)
            or (extracted / RUNTIME_DEPENDENCY_INVENTORY_PATH).read_bytes()
            != git_bytes(merged_sha, RUNTIME_DEPENDENCY_INVENTORY_PATH)
        ):
            raise ReleaseError("package_runtime_dependency_evidence_mismatch")
        validate_escript_runtime_inventory(
            extracted / "elixir/bin/symphony",
            runtime_inventory,
            extracted / SYMPHONY_PRIV_PATH,
        )

    package_sha = sha256_file(package)
    sbom_path = output_dir / "sbom.spdx.json"
    atomic_write(
        sbom_path,
        canonical_json_bytes(
            spdx_document(merged_sha, package_sha, created, runtime_inventory)
        ),
    )
    notices_path = output_dir / "THIRD_PARTY_NOTICES.txt"
    atomic_write(
        notices_path,
        git_bytes(merged_sha, THIRD_PARTY_NOTICES_PATH),
    )
    candidate_copy = output_dir / "release-candidate-manifest.json"
    atomic_write(candidate_copy, manifest_path.read_bytes())
    readiness_path = output_dir / "implementation-readiness.json"
    atomic_write(readiness_path, git_bytes(merged_sha, "artifacts/readiness/implementation-readiness.json"))
    schema_path = output_dir / "codex-schema-manifest.json"
    atomic_write(schema_path, git_bytes(merged_sha, "elixir/priv/codex_schema/0.144.3/manifest.json"))
    migration_path = output_dir / "migration-report.json"
    atomic_write(
        migration_path,
        canonical_json_bytes(
            {
                "backupRestore": "not-applicable-release-0",
                "databaseSchemaVersion": None,
                "migrationSet": [],
                "rollbackClassification": "return-to-locked-upstream-source",
                "status": "pass",
            }
        ),
    )
    test_summary_path = output_dir / "test-summary.json"
    atomic_write(
        test_summary_path,
        canonical_json_bytes(
            {
                "candidateHead": manifest["releaseHeadSha"],
                "mergedCommit": merged_sha,
                "status": "pass",
                "testEvidence": manifest["testEvidence"],
                "versionOutput": version_output.splitlines(),
            }
        ),
    )
    provenance_path = output_dir / "provenance.json"
    atomic_write(
        provenance_path,
        canonical_json_bytes(
            {
                "buildType": "symphony-studio-release-v1",
                "buildTools": {
                    "hex": HEX_VERSION,
                    "rebar3Sha512": REBAR3_SHA512,
                },
                "candidateManifestSha256": sha256_file(manifest_path),
                "dependencyBuildPatches": dependency_build_patch_records(),
                "escriptSourceDateEpoch": manifest["sourceDateEpoch"],
                "archiveMtimeEpoch": epoch,
                "mergedCommit": merged_sha,
                "mergedTree": merged_tree,
                "repository": REPOSITORY,
                "upstreamBase": manifest["upstreamBaseSha"],
            }
        ),
    )
    baseline_path = output_dir / "upstream-baseline-return.json"
    atomic_write(baseline_path, canonical_json_bytes(baseline_return_record()))
    public_audit_path = output_dir / PUBLIC_ARTIFACT_AUDIT_NAME
    atomic_write(
        public_audit_path,
        canonical_json_bytes(public_artifact_audit_value(output_dir, merged_sha)),
    )
    package_manifest = {
        "assets": [],
        "candidateManifestSha256": sha256_file(manifest_path),
        "kind": "release-package-manifest",
        "mergedCommitSha": merged_sha,
        "mergedTreeSha": merged_tree,
        "prNumber": pr_number,
        "specificationStage": STAGE,
        "version": VERSION,
    }
    for path in sorted(output_dir.iterdir()):
        if path.is_file() and path.name not in {"release-package-manifest.json", "SHA256SUMS"}:
            package_manifest["assets"].append(
                {"name": path.name, "sha256": sha256_file(path), "size": path.stat().st_size}
            )
    package_manifest_path = output_dir / "release-package-manifest.json"
    atomic_write(package_manifest_path, canonical_json_bytes(package_manifest))
    checksum_paths = sorted(path for path in output_dir.iterdir() if path.is_file() and path.name != "SHA256SUMS")
    checksum_text = "".join(f"{sha256_file(path)}  {path.name}\n" for path in checksum_paths)
    atomic_write(output_dir / "SHA256SUMS", checksum_text.encode("ascii"))
    return package_manifest


def command_publish_prepare(args: argparse.Namespace) -> int:
    output = external_path(args.output_dir, directory=True)
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ReleaseError("release_output_directory_not_empty")
    result = prepare_package(Path(args.candidate).resolve(), output, args.merged_sha, args.pr_number)
    print(sha256_file(output / "release-package-manifest.json"))
    print(result["mergedCommitSha"])
    return 0


def command_publish_attach_platform(args: argparse.Namespace) -> int:
    directory = external_path(args.directory, directory=True)
    receipt_path = external_path(args.platform_receipt)
    verify_checksums(directory)
    package_manifest = validate_package_manifest(directory)
    candidate_path = directory / "release-candidate-manifest.json"
    candidate = validate_candidate(candidate_path, verify_refs=False)
    if sha256_file(candidate_path) != package_manifest["candidateManifestSha256"]:
        raise ReleaseError("platform_receipt_candidate_mismatch")
    validate_platform_receipt(receipt_path, directory, candidate, package_manifest)
    destination = directory / PLATFORM_RECEIPT_NAME
    atomic_write(destination, receipt_path.read_bytes())
    checksum_paths = sorted(
        path for path in directory.iterdir() if path.is_file() and path.name != "SHA256SUMS"
    )
    checksum_text = "".join(
        f"{sha256_file(path)}  {path.name}\n" for path in checksum_paths
    )
    atomic_write(directory / "SHA256SUMS", checksum_text.encode("ascii"))
    verify_checksums(directory)
    validate_package_manifest(directory, require_platform=True)
    print(sha256_file(destination))
    return 0


def verify_checksums(directory: Path) -> None:
    checksum_path = directory / "SHA256SUMS"
    if not checksum_path.is_file():
        raise ReleaseError("checksums_missing")
    lines = checksum_path.read_text(encoding="ascii").splitlines()
    if any(
        re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._-]+)", line) is None
        for line in lines
    ):
        raise ReleaseError("checksums_format_invalid")
    if lines != sorted(lines, key=lambda line: line.split("  ", 1)[1]):
        raise ReleaseError("checksums_not_sorted")
    seen: set[str] = set()
    for line in lines:
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._-]+)", line)
        if not match:
            raise ReleaseError("checksums_format_invalid")
        expected, name = match.groups()
        if name in seen or name == "SHA256SUMS":
            raise ReleaseError("checksums_inventory_invalid")
        seen.add(name)
        path = directory / name
        if not path.is_file() or path.is_symlink() or sha256_file(path) != expected:
            raise ReleaseError(f"asset_checksum_mismatch:{name}")
    actual = {path.name for path in directory.iterdir() if path.is_file() and path.name != "SHA256SUMS"}
    if seen != actual:
        raise ReleaseError("checksums_inventory_incomplete")


def require_final_asset_inventory(directory: Path) -> None:
    actual = {path.name for path in directory.iterdir() if path.is_file()}
    if actual != FINAL_RELEASE_ASSET_NAMES or any(
        (directory / name).is_symlink() for name in actual
    ):
        raise ReleaseError("final_release_asset_inventory_invalid")


def validate_package_manifest(
    directory: Path,
    *,
    expected_merged_sha: str | None = None,
    expected_candidate_sha256: str | None = None,
    require_platform: bool = False,
) -> dict[str, Any]:
    manifest, _raw = load_canonical_json(directory / "release-package-manifest.json")
    expected_keys = {
        "assets",
        "candidateManifestSha256",
        "kind",
        "mergedCommitSha",
        "mergedTreeSha",
        "prNumber",
        "specificationStage",
        "version",
    }
    if set(manifest) != expected_keys:
        raise ReleaseError("package_manifest_shape_invalid")
    if (
        manifest.get("kind") != "release-package-manifest"
        or manifest.get("version") != VERSION
        or manifest.get("specificationStage") != STAGE
        or not isinstance(manifest.get("prNumber"), int)
        or manifest["prNumber"] <= 0
        or not isinstance(manifest.get("candidateManifestSha256"), str)
        or SHA256_RE.fullmatch(manifest["candidateManifestSha256"]) is None
        or not isinstance(manifest.get("mergedCommitSha"), str)
        or SHA1_RE.fullmatch(manifest["mergedCommitSha"]) is None
        or not isinstance(manifest.get("mergedTreeSha"), str)
        or SHA1_RE.fullmatch(manifest["mergedTreeSha"]) is None
    ):
        raise ReleaseError("package_manifest_invalid")
    if expected_merged_sha is not None and manifest["mergedCommitSha"] != expected_merged_sha:
        raise ReleaseError("package_manifest_merged_commit_mismatch")
    if (
        expected_candidate_sha256 is not None
        and manifest["candidateManifestSha256"] != expected_candidate_sha256
    ):
        raise ReleaseError("package_manifest_candidate_mismatch")
    assets = manifest.get("assets")
    if not isinstance(assets, list):
        raise ReleaseError("package_manifest_assets_invalid")
    names: list[str] = []
    for asset in assets:
        if not isinstance(asset, dict) or set(asset) != {"name", "sha256", "size"}:
            raise ReleaseError("package_manifest_asset_shape_invalid")
        name = asset.get("name")
        digest = asset.get("sha256")
        size = asset.get("size")
        if (
            not isinstance(name, str)
            or re.fullmatch(r"[A-Za-z0-9._-]+", name) is None
            or not isinstance(digest, str)
            or SHA256_RE.fullmatch(digest) is None
            or not isinstance(size, int)
            or size < 0
            or size > MAX_ARCHIVE_TOTAL_BYTES
        ):
            raise ReleaseError("package_manifest_asset_invalid")
        path = directory / name
        if not path.is_file() or path.is_symlink():
            raise ReleaseError(f"package_manifest_asset_missing:{name}")
        if path.stat().st_size != size or sha256_file(path) != digest:
            raise ReleaseError(f"package_manifest_asset_mismatch:{name}")
        names.append(name)
    if names != sorted(set(names)):
        raise ReleaseError("package_manifest_asset_order_invalid")
    if set(names) != PACKAGE_ASSET_NAMES:
        raise ReleaseError("package_manifest_required_assets_invalid")
    actual = sorted(
        path.name
        for path in directory.iterdir()
        if path.is_file()
        and path.name
        not in {
            PLATFORM_RECEIPT_NAME,
            "release-package-manifest.json",
            "release-manifest.json",
            "SHA256SUMS",
        }
    )
    if names != actual:
        raise ReleaseError("package_manifest_asset_inventory_mismatch")

    candidate_path = directory / "release-candidate-manifest.json"
    if sha256_file(candidate_path) != manifest["candidateManifestSha256"]:
        raise ReleaseError("package_candidate_copy_mismatch")
    candidate = validate_candidate(candidate_path, verify_refs=False)
    if sha256_file(directory / "implementation-readiness.json") != candidate["readiness"]["sha256"]:
        raise ReleaseError("package_readiness_mismatch")
    if sha256_file(directory / "codex-schema-manifest.json") != candidate["schemaManifest"]["sha256"]:
        raise ReleaseError("package_schema_manifest_mismatch")

    migration, _ = load_canonical_json(directory / "migration-report.json")
    if migration != {
        "backupRestore": "not-applicable-release-0",
        "databaseSchemaVersion": None,
        "migrationSet": [],
        "rollbackClassification": "return-to-locked-upstream-source",
        "status": "pass",
    }:
        raise ReleaseError("package_migration_report_invalid")

    provenance, _ = load_canonical_json(directory / "provenance.json")
    expected_provenance = {
        "buildType": "symphony-studio-release-v1",
        "buildTools": {"hex": HEX_VERSION, "rebar3Sha512": REBAR3_SHA512},
        "candidateManifestSha256": manifest["candidateManifestSha256"],
        "dependencyBuildPatches": dependency_build_patch_records(),
        "escriptSourceDateEpoch": candidate["sourceDateEpoch"],
        "archiveMtimeEpoch": int(
            git("show", "-s", "--format=%ct", manifest["mergedCommitSha"])
        ),
        "mergedCommit": manifest["mergedCommitSha"],
        "mergedTree": manifest["mergedTreeSha"],
        "repository": REPOSITORY,
        "upstreamBase": candidate["upstreamBaseSha"],
    }
    if provenance != expected_provenance:
        raise ReleaseError("package_provenance_invalid")

    test_summary, _ = load_canonical_json(directory / "test-summary.json")
    expected_version_output = [
        f"Symphony {VERSION.removeprefix('v')}",
        f"commit: {manifest['mergedCommitSha']}",
        f"upstream-base: {candidate['upstreamBaseSha']}",
        f"codex-compatibility-sha256: {candidate['codex']['artifactBundleSha256']}",
        "provenance: github-release-verified",
    ]
    if test_summary != {
        "candidateHead": candidate["releaseHeadSha"],
        "mergedCommit": manifest["mergedCommitSha"],
        "status": "pass",
        "testEvidence": candidate["testEvidence"],
        "versionOutput": expected_version_output,
    }:
        raise ReleaseError("package_test_summary_invalid")

    baseline, _ = load_canonical_json(directory / "upstream-baseline-return.json")
    expected_baseline_hashes = {
        "LICENSE": "c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4",
        "NOTICE": "38c76eb8701e52953f63154a77b407667a6ee34c3a2a8785c8f8b2cd5494d09d",
        "SPEC.md": "fa9d7c252cc72d10afdaf4e46e0d890aae28cf4331dc531c94413bc8ea199452",
    }
    if (
        set(baseline)
        != {
            "cleanWorktree",
            "detachedHead",
            "expectedHashes",
            "kind",
            "observedHashes",
            "repository",
            "smokeCommand",
            "smokeEvidenceSha256",
            "smokeStatus",
            "status",
            "treeSha",
            "upstreamCommit",
        }
        or baseline.get("expectedHashes") != expected_baseline_hashes
        or baseline.get("observedHashes") != expected_baseline_hashes
        or baseline.get("kind") != "upstream-baseline-return"
        or baseline.get("repository") != "https://github.com/openai/symphony.git"
        or baseline.get("upstreamCommit") != candidate["upstreamBaseSha"]
        or baseline.get("status") != "pass"
        or baseline.get("detachedHead") != candidate["upstreamBaseSha"]
        or baseline.get("cleanWorktree") is not True
        or baseline.get("smokeStatus") != "pass"
        or baseline.get("smokeCommand")
        != ["mix", "test", "test/symphony_elixir/cli_test.exs", "--seed", "0"]
        or not isinstance(baseline.get("smokeEvidenceSha256"), str)
        or SHA256_RE.fullmatch(baseline["smokeEvidenceSha256"]) is None
        or baseline.get("treeSha")
        != git("rev-parse", f"{candidate['upstreamBaseSha']}^{{tree}}")
    ):
        raise ReleaseError("package_upstream_baseline_receipt_invalid")

    public_audit, _ = load_canonical_json(directory / PUBLIC_ARTIFACT_AUDIT_NAME)
    expected_public_audit = public_artifact_audit_value(
        directory, manifest["mergedCommitSha"]
    )
    if public_audit != expected_public_audit:
        raise ReleaseError("package_public_artifact_audit_invalid")

    archive_name = f"symphony-studio-{VERSION.removeprefix('v')}-linux-x86_64.tar.gz"
    sbom, _ = load_canonical_json(directory / "sbom.spdx.json")
    created = iso_from_epoch(
        int(git("show", "-s", "--format=%ct", manifest["mergedCommitSha"]))
    )
    expected_sbom = spdx_document(
        manifest["mergedCommitSha"],
        sha256_file(directory / archive_name),
        created,
    )
    if sbom != expected_sbom:
        raise ReleaseError("package_sbom_invalid")

    expected_notices = git_bytes(
        manifest["mergedCommitSha"], THIRD_PARTY_NOTICES_PATH
    )
    if (directory / "THIRD_PARTY_NOTICES.txt").read_bytes() != expected_notices:
        raise ReleaseError("package_notices_invalid")

    platform_path = directory / PLATFORM_RECEIPT_NAME
    if require_platform:
        validate_platform_receipt(platform_path, directory, candidate, manifest)
    elif platform_path.exists() and (not platform_path.is_file() or platform_path.is_symlink()):
        raise ReleaseError("supported_platform_receipt_invalid")
    return manifest


def command_verify_package(args: argparse.Namespace) -> int:
    directory = Path(args.directory).resolve()
    verify_checksums(directory)
    validate_package_manifest(directory)
    print(sha256_file(directory / "SHA256SUMS"))
    return 0


def platform_receipt_value(
    directory: Path,
    candidate: Mapping[str, Any],
    package_manifest: Mapping[str, Any],
    version_output: str,
    baseline_return: Mapping[str, Any],
    codex_compatibility: Mapping[str, Any],
    guardrail_smoke: Mapping[str, Any],
    runner_smoke: Mapping[str, Any],
) -> dict[str, Any]:
    os_release = platform.freedesktop_os_release()
    if (
        platform.system() != "Linux"
        or platform.machine() != "x86_64"
        or os_release.get("ID") != "debian"
        or os_release.get("VERSION_ID") != "12"
    ):
        raise ReleaseError("supported_platform_identity_mismatch")
    archive = directory / f"symphony-studio-{VERSION.removeprefix('v')}-linux-x86_64.tar.gz"
    return {
        "architecture": "x86_64",
        "archiveMtimeEpoch": int(
            git("show", "-s", "--format=%ct", package_manifest["mergedCommitSha"])
        ),
        "archiveSha256": sha256_file(archive),
        "baselineReturn": dict(baseline_return),
        "candidateManifestSha256": package_manifest["candidateManifestSha256"],
        "codexCompatibility": dict(codex_compatibility),
        "distribution": "Debian GNU/Linux 12",
        "escriptSourceDateEpoch": candidate["sourceDateEpoch"],
        "guardrailSmoke": dict(guardrail_smoke),
        "kind": "supported-platform-clean-install",
        "mergedCommitSha": package_manifest["mergedCommitSha"],
        "mergedTreeSha": package_manifest["mergedTreeSha"],
        "packageManifestSha256": sha256_file(directory / "release-package-manifest.json"),
        "runnerSmoke": dict(runner_smoke),
        "status": "pass",
        "supportedPlatform": candidate["supportedPlatforms"][0],
        "versionOutput": version_output.splitlines(),
    }


def validate_platform_receipt(
    receipt_path: Path,
    directory: Path,
    candidate: Mapping[str, Any],
    package_manifest: Mapping[str, Any],
) -> dict[str, Any]:
    receipt, _raw = load_canonical_json(receipt_path)
    expected_version_output = [
        f"Symphony {VERSION.removeprefix('v')}",
        f"commit: {package_manifest['mergedCommitSha']}",
        f"upstream-base: {candidate['upstreamBaseSha']}",
        f"codex-compatibility-sha256: {candidate['codex']['artifactBundleSha256']}",
        "provenance: github-release-verified",
    ]
    expected_keys = {
        "architecture",
        "archiveMtimeEpoch",
        "archiveSha256",
        "baselineReturn",
        "candidateManifestSha256",
        "codexCompatibility",
        "distribution",
        "escriptSourceDateEpoch",
        "guardrailSmoke",
        "kind",
        "mergedCommitSha",
        "mergedTreeSha",
        "packageManifestSha256",
        "runnerSmoke",
        "status",
        "supportedPlatform",
        "versionOutput",
    }
    archive = directory / f"symphony-studio-{VERSION.removeprefix('v')}-linux-x86_64.tar.gz"
    if (
        set(receipt) != expected_keys
        or receipt.get("kind") != "supported-platform-clean-install"
        or receipt.get("status") != "pass"
        or receipt.get("architecture") != "x86_64"
        or receipt.get("distribution") != "Debian GNU/Linux 12"
        or receipt.get("baselineReturn")
        != {
            "reexecutedOnSupportedPlatform": True,
            "receiptSha256": sha256_file(
                directory / "upstream-baseline-return.json"
            ),
            "status": "pass",
        }
        or receipt.get("codexCompatibility")
        != codex_compatibility_from_lock(package_manifest["mergedCommitSha"])[1]
        or receipt.get("guardrailSmoke")
        != {
            "exitCode": 1,
            "guardrailMarkersPresent": True,
            "noModelWork": True,
            "runtimeHomeEmpty": True,
            "stderrSha256": receipt.get("guardrailSmoke", {}).get("stderrSha256")
            if isinstance(receipt.get("guardrailSmoke"), dict)
            else None,
            "stdoutEmpty": True,
        }
        or not isinstance(receipt.get("guardrailSmoke", {}).get("stderrSha256"), str)
        or SHA256_RE.fullmatch(receipt["guardrailSmoke"]["stderrSha256"]) is None
        or receipt.get("runnerSmoke")
        != {
            "dashboardEndpoint": "/",
            "dashboardHttpStatus": 200,
            "dashboardMarkersPresent": True,
            "dashboardSha256": receipt.get("runnerSmoke", {}).get(
                "dashboardSha256"
            )
            if isinstance(receipt.get("runnerSmoke"), dict)
            else None,
            "endpoint": "/api/v1/state",
            "httpStatus": 200,
            "noExternalTracker": True,
            "noModelWork": True,
            "processGroupCleaned": True,
            "stateProjectionSha256": receipt.get("runnerSmoke", {}).get(
                "stateProjectionSha256"
            )
            if isinstance(receipt.get("runnerSmoke"), dict)
            else None,
            "zeroAdmittedIssues": True,
        }
        or not isinstance(
            receipt.get("runnerSmoke", {}).get("stateProjectionSha256"), str
        )
        or not isinstance(
            receipt.get("runnerSmoke", {}).get("dashboardSha256"), str
        )
        or SHA256_RE.fullmatch(receipt["runnerSmoke"]["dashboardSha256"])
        is None
        or SHA256_RE.fullmatch(receipt["runnerSmoke"]["stateProjectionSha256"])
        is None
        or receipt.get("candidateManifestSha256") != package_manifest["candidateManifestSha256"]
        or receipt.get("mergedCommitSha") != package_manifest["mergedCommitSha"]
        or receipt.get("mergedTreeSha") != package_manifest["mergedTreeSha"]
        or receipt.get("packageManifestSha256")
        != sha256_file(directory / "release-package-manifest.json")
        or receipt.get("archiveSha256") != sha256_file(archive)
        or receipt.get("supportedPlatform") != candidate["supportedPlatforms"][0]
        or not isinstance(receipt.get("escriptSourceDateEpoch"), int)
        or receipt.get("escriptSourceDateEpoch") != candidate.get("sourceDateEpoch")
        or not isinstance(receipt.get("archiveMtimeEpoch"), int)
        or receipt.get("archiveMtimeEpoch")
        != int(
            git("show", "-s", "--format=%ct", package_manifest["mergedCommitSha"])
        )
        or receipt.get("versionOutput") != expected_version_output
    ):
        raise ReleaseError("supported_platform_receipt_invalid")
    return receipt


def command_verify_clean_install(args: argparse.Namespace) -> int:
    directory = external_path(args.directory, directory=True)
    receipt_path = external_path(args.receipt)
    verify_checksums(directory)
    package_manifest = validate_package_manifest(directory)
    candidate_path = directory / "release-candidate-manifest.json"
    candidate = validate_candidate(candidate_path, verify_refs=False)
    if sha256_file(candidate_path) != package_manifest["candidateManifestSha256"]:
        raise ReleaseError("clean_install_candidate_mismatch")
    archive = directory / f"symphony-studio-{VERSION.removeprefix('v')}-linux-x86_64.tar.gz"
    codex_compatibility = verify_installed_codex_compatibility(
        package_manifest["mergedCommitSha"]
    )
    with tempfile.TemporaryDirectory(prefix="symphony-debian-clean-install-") as temporary:
        extracted = safe_extract(archive, Path(temporary))
        notices = checked_runtime_source_file(
            extracted / THIRD_PARTY_NOTICES_PATH
        )
        inventory_raw = checked_runtime_source_file(
            extracted / RUNTIME_DEPENDENCY_INVENTORY_PATH
        )
        if notices != (directory / THIRD_PARTY_NOTICES_PATH).read_bytes():
            raise ReleaseError("clean_install_notice_asset_mismatch")
        runtime_inventory = validate_runtime_dependency_inventory(
            inventory_raw,
            notices,
            checked_runtime_source_file(extracted / "elixir/mix.lock"),
        )
        validate_escript_runtime_inventory(
            extracted / "elixir/bin/symphony",
            runtime_inventory,
            extracted / SYMPHONY_PRIV_PATH,
        )
        version_output = verify_installed_binary(
            extracted / "elixir/bin/symphony",
            candidate,
            package_manifest["mergedCommitSha"],
        )
        guardrail_smoke = verify_installed_guardrail_smoke(
            extracted / "elixir/bin/symphony"
        )
        runner_smoke = verify_installed_runner_smoke(extracted / "elixir/bin/symphony")
    baseline_return = verify_supported_platform_baseline_return(directory)
    receipt = platform_receipt_value(
        directory,
        candidate,
        package_manifest,
        version_output,
        baseline_return,
        codex_compatibility,
        guardrail_smoke,
        runner_smoke,
    )
    atomic_write(receipt_path, canonical_json_bytes(receipt))
    print(sha256_file(receipt_path))
    return 0


def verify_supported_platform_baseline_return(directory: Path) -> dict[str, Any]:
    baseline_bytes = canonical_json_bytes(baseline_return_record())
    baseline_path = directory / "upstream-baseline-return.json"
    if (
        not baseline_path.is_file()
        or baseline_path.is_symlink()
        or baseline_bytes != baseline_path.read_bytes()
    ):
        raise ReleaseError("clean_install_upstream_baseline_mismatch")
    return {
        "reexecutedOnSupportedPlatform": True,
        "receiptSha256": sha256_bytes(baseline_bytes),
        "status": "pass",
    }


def baseline_return_record() -> dict[str, Any]:
    upstream = (ROOT / "UPSTREAM_BASE").read_text(encoding="utf-8").strip()
    expected = {
        "LICENSE": "c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4",
        "NOTICE": "38c76eb8701e52953f63154a77b407667a6ee34c3a2a8785c8f8b2cd5494d09d",
        "SPEC.md": "fa9d7c252cc72d10afdaf4e46e0d890aae28cf4331dc531c94413bc8ea199452",
    }
    repository = "https://github.com/openai/symphony.git"
    with tempfile.TemporaryDirectory(prefix="symphony-upstream-baseline-") as temporary:
        temporary_path = Path(temporary)
        source = temporary_path / "source"
        home = temporary_path / "home"
        home.mkdir(mode=0o700)
        inherited_path = os.environ.get("PATH")
        if not inherited_path:
            raise ReleaseError("baseline_path_unavailable")
        git_env = {
            "GIT_ASKPASS": "/bin/false",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "HOME": str(home),
            "LANG": os.environ.get("LANG", "C.UTF-8"),
            "PATH": inherited_path,
            "SSH_ASKPASS": "/bin/false",
            "TZ": "UTC",
        }
        run(("git", "init", "--quiet", str(source)), cwd=temporary_path, env=git_env, timeout=60)
        run(("git", "remote", "add", "upstream", repository), cwd=source, env=git_env, timeout=60)
        run(
            ("git", "fetch", "--quiet", "--depth=1", "upstream", upstream),
            cwd=source,
            env=git_env,
            timeout=300,
        )
        run(("git", "checkout", "--quiet", "--detach", "FETCH_HEAD"), cwd=source, env=git_env, timeout=60)
        detached_head = run(("git", "rev-parse", "HEAD"), cwd=source, env=git_env).stdout.strip()
        remote = run(("git", "remote", "get-url", "upstream"), cwd=source, env=git_env).stdout.strip()
        observed = {path: sha256_file(source / path) for path in expected}
        if detached_head != upstream or remote != repository or observed != expected:
            raise ReleaseError("upstream_baseline_identity_mismatch")

        smoke_root = temporary_path / "smoke"
        smoke_root.mkdir(mode=0o700)
        smoke_env = dict(git_env)
        smoke_env.update(
            {
                "HEX_HOME": str(smoke_root / "hex-home"),
                "MIX_BUILD_PATH": str(smoke_root / "mix-build"),
                "MIX_DEPS_PATH": str(smoke_root / "mix-deps"),
                "MIX_ENV": "test",
                "MIX_HOME": str(smoke_root / "mix-home"),
                "PATH": pinned_toolchain_path(ROOT / "elixir"),
            }
        )
        for name in ("hex-home", "mix-build", "mix-deps", "mix-home"):
            (smoke_root / name).mkdir(mode=0o700)
        elixir = source / "elixir"
        install_hex = run(
            ("mix", "local.hex", HEX_VERSION, "--force"),
            cwd=elixir,
            env=smoke_env,
            timeout=300,
        )
        install_rebar = run(
            ("mix", "local.rebar", "--force", "--sha512", REBAR3_SHA512),
            cwd=elixir,
            env=smoke_env,
            timeout=300,
        )
        deps = run(("mix", "deps.get"), cwd=elixir, env=smoke_env, timeout=900)
        smoke_command = ("mix", "test", "test/symphony_elixir/cli_test.exs", "--seed", "0")
        smoke = run(
            smoke_command,
            cwd=elixir,
            env=smoke_env,
            timeout=900,
        )
        clean = run(
            ("git", "status", "--porcelain=v1", "--untracked-files=all"),
            cwd=source,
            env=git_env,
        ).stdout.strip() == ""
        if not clean:
            raise ReleaseError("upstream_baseline_smoke_modified_source")
        smoke_evidence = {
            "commands": [
                ["mix", "local.hex", HEX_VERSION, "--force"],
                ["mix", "local.rebar", "--force", "--sha512", REBAR3_SHA512],
                ["mix", "deps.get"],
                list(smoke_command),
            ],
            "exitCodes": [
                install_hex.returncode,
                install_rebar.returncode,
                deps.returncode,
                smoke.returncode,
            ],
            "sourceCommit": upstream,
        }
        tree = run(("git", "rev-parse", "HEAD^{tree}"), cwd=source, env=git_env).stdout.strip()

    return {
        "cleanWorktree": True,
        "detachedHead": upstream,
        "expectedHashes": expected,
        "kind": "upstream-baseline-return",
        "observedHashes": observed,
        "repository": repository,
        "smokeCommand": list(smoke_command),
        "smokeEvidenceSha256": sha256_bytes(canonical_json_bytes(smoke_evidence)),
        "smokeStatus": "pass",
        "status": "pass",
        "treeSha": tree,
        "upstreamCommit": upstream,
    }


def command_verify_baseline(args: argparse.Namespace) -> int:
    output = external_path(args.output)
    receipt = baseline_return_record()
    atomic_write(output, canonical_json_bytes(receipt))
    print(sha256_file(output))
    return 0


def release_tag_commit(tag: str) -> str | None:
    reference = gh_api(f"repos/{REPOSITORY}/git/ref/tags/{tag}", allow_missing=True)
    if reference is None:
        return None
    target = reference.get("object") or {}
    if target.get("type") == "commit":
        return target.get("sha")
    if target.get("type") == "tag":
        tag_object = gh_api(f"repos/{REPOSITORY}/git/tags/{target.get('sha')}")
        peeled = tag_object.get("object") or {}
        if peeled.get("type") == "commit":
            return peeled.get("sha")
    raise ReleaseError("release_tag_target_invalid")


def final_manifest_value(
    directory: Path,
    candidate: Mapping[str, Any],
    package_manifest: Mapping[str, Any],
    release: Mapping[str, Any],
) -> dict[str, Any]:
    assets = []
    for path in sorted(directory.iterdir()):
        if path.is_file() and path.name not in {"SHA256SUMS", "release-manifest.json"}:
            assets.append({"name": path.name, "sha256": sha256_file(path), "size": path.stat().st_size})
    return {
        "approvedWaiverIds": candidate["approvedWaiverIds"],
        "assets": assets,
        "backupRestoreResult": "not-applicable-release-0",
        "candidateManifestSha256": package_manifest["candidateManifestSha256"],
        "codex": candidate["codex"],
        "compatibilityManifest": candidate["schemaManifest"],
        "databaseSchemaVersion": None,
        "githubReleaseId": release.get("id"),
        "immutableEvidence": {
            "readiness": candidate["readiness"],
            "reviews": candidate["reviewEvidence"],
            "tests": candidate["testEvidence"],
        },
        "kind": "release-manifest",
        "knownLimitations": [
            "Release 0 preserves the original Symphony runner and dashboard; Studio preview surfaces ship separately.",
            "Supported release platform is Debian GNU/Linux 12 on x86_64.",
        ],
        "manifestVersion": 1,
        "baseSha": candidate["baseSha"],
        "mergeTime": iso_from_epoch(
            int(git("show", "-s", "--format=%ct", package_manifest["mergedCommitSha"]))
        ),
        "mergedCommitSha": package_manifest["mergedCommitSha"],
        "mergedTreeSha": package_manifest["mergedTreeSha"],
        "migrationSet": [],
        "previousStableTag": None,
        "publicationAuthorizedAt": release.get("created_at"),
        "publicationEvidence": {
            "jsonPointers": {
                "publicationStatus": "/status",
                "publicationTime": "/publishedAt",
            },
            "predicateType": PUBLICATION_PREDICATE_TYPE,
            "retrieval": "gh attestation download release-manifest.json --repo farhaanlevy/symphony-studio --predicate-type <predicateType>",
            "subject": "release-manifest.json",
        },
        "publicationStatus": {
            "jsonPointer": "/status",
            "predicateType": PUBLICATION_PREDICATE_TYPE,
            "subject": "release-manifest.json",
        },
        "publicationTime": {
            "jsonPointer": "/publishedAt",
            "predicateType": PUBLICATION_PREDICATE_TYPE,
            "subject": "release-manifest.json",
        },
        "releaseBranchHeadSha": candidate["releaseHeadSha"],
        "releasePullRequestNumber": package_manifest["prNumber"],
        "repository": REPOSITORY,
        "requiredChecks": candidate["requiredChecks"],
        "rollbackClassification": "return-to-locked-upstream-source",
        "specificationStage": STAGE,
        "supportedPlatforms": candidate["supportedPlatforms"],
        "tag": VERSION,
        "testedMergeTreeSha": candidate["testedMergeTreeSha"],
        "upstreamBaseSha": candidate["upstreamBaseSha"],
        "version": VERSION,
    }


def append_final_manifest(
    directory: Path,
    candidate: Mapping[str, Any],
    package_manifest: Mapping[str, Any],
    release: Mapping[str, Any],
) -> Path:
    final = final_manifest_value(directory, candidate, package_manifest, release)
    path = directory / "release-manifest.json"
    atomic_write(path, canonical_json_bytes(final))
    checksum_paths = sorted(
        item for item in directory.iterdir() if item.is_file() and item.name != "SHA256SUMS"
    )
    checksums = "".join(f"{sha256_file(item)}  {item.name}\n" for item in checksum_paths)
    atomic_write(directory / "SHA256SUMS", checksums.encode("ascii"))
    return path


def validate_final_manifest(
    directory: Path,
    candidate: Mapping[str, Any],
    package_manifest: Mapping[str, Any],
    release: Mapping[str, Any],
) -> dict[str, Any]:
    path = directory / "release-manifest.json"
    observed, raw = load_canonical_json(path)
    expected = final_manifest_value(directory, candidate, package_manifest, release)
    if observed != expected or raw != canonical_json_bytes(expected):
        raise ReleaseError("release_manifest_mismatch")
    return observed


def remote_assets(release_id: int) -> list[dict[str, Any]]:
    assets = gh_api(f"repos/{REPOSITORY}/releases/{release_id}/assets?per_page=100")
    if not isinstance(assets, list) or len(assets) >= 100:
        raise ReleaseError("release_assets_response_invalid")
    return assets


def release_by_exact_tag(*, allow_missing: bool = False) -> dict[str, Any] | None:
    releases = gh_api(f"repos/{REPOSITORY}/releases?per_page=100")
    if not isinstance(releases, list) or len(releases) >= 100:
        raise ReleaseError("release_inventory_unbounded")
    matches = [release for release in releases if release.get("tag_name") == VERSION]
    if len(matches) > 1:
        raise ReleaseError("duplicate_release_tag_records")
    if not matches:
        if allow_missing:
            return None
        raise ReleaseError("release_record_missing")
    release = matches[0]
    if (
        release.get("name") != "Symphony Studio v0.1.0 foundation"
        or release.get("prerelease") is not False
        or not isinstance(release.get("id"), int)
    ):
        raise ReleaseError("release_record_identity_mismatch")
    return release


def validate_published_release(
    release: Mapping[str, Any], expected_id: int, expected_body: str
) -> dict[str, Any]:
    assets = release.get("assets") if isinstance(release, dict) else None
    if (
        release.get("id") != expected_id
        or release.get("tag_name") != VERSION
        or release.get("name") != "Symphony Studio v0.1.0 foundation"
        or release.get("draft") is not False
        or release.get("prerelease") is not False
        or release.get("body") != expected_body
        or release.get("immutable") is not True
        or not isinstance(release.get("published_at"), str)
        or not isinstance(assets, list)
        or len(assets) != len(FINAL_RELEASE_ASSET_NAMES)
        or any(
            asset.get("state") != "uploaded"
            or not isinstance(asset.get("digest"), str)
            or re.fullmatch(r"sha256:[0-9a-f]{64}", asset["digest"]) is None
            for asset in assets
        )
    ):
        raise ReleaseError("published_release_identity_invalid")
    return dict(release)


def published_release_by_exact_tag(expected_id: int, expected_body: str) -> dict[str, Any]:
    release = published_release_observation()
    return validate_published_release(release, expected_id, expected_body)


def published_release_observation() -> dict[str, Any]:
    release = gh_api(f"repos/{REPOSITORY}/releases/tags/{VERSION}")
    if not isinstance(release, dict):
        raise ReleaseError("published_release_identity_invalid")
    return release


def require_repository_immutable_policy() -> dict[str, Any]:
    value = gh_api(f"repos/{REPOSITORY}/immutable-releases")
    if not isinstance(value, dict) or value.get("enabled") is not True:
        raise ReleaseError("published_repository_immutability_missing")
    return value


def require_latest_release(expected_id: int) -> dict[str, Any]:
    value = gh_api(f"repos/{REPOSITORY}/releases/latest")
    if not isinstance(value, dict) or value.get("id") != expected_id:
        raise ReleaseError("published_latest_release_mismatch")
    return value


def verify_remote_asset_inventory(directory: Path, release: Mapping[str, Any]) -> None:
    local = {path.name: path for path in directory.iterdir() if path.is_file()}
    remote_list = remote_assets(int(release["id"]))
    remote = {asset.get("name"): asset for asset in remote_list}
    if len(remote) != len(remote_list):
        raise ReleaseError("remote_release_asset_names_not_unique")
    if set(remote) != set(local):
        raise ReleaseError("remote_release_asset_inventory_mismatch")
    for name, path in local.items():
        asset = remote[name]
        if asset.get("size") != path.stat().st_size:
            raise ReleaseError(f"remote_release_asset_size_mismatch:{name}")
        digest = asset.get("digest")
        if digest not in (None, f"sha256:{sha256_file(path)}"):
            raise ReleaseError(f"remote_release_asset_digest_mismatch:{name}")


def create_or_reuse_draft(merged_sha: str, notes_file: Path) -> dict[str, Any]:
    expected_notes_bytes = git_bytes(
        merged_sha,
        "docs/releases/v0.1.0/release-notes.md",
    )
    if notes_file.read_bytes() != expected_notes_bytes:
        raise ReleaseError("release_notes_source_mismatch")
    try:
        expected_notes = expected_notes_bytes.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ReleaseError("release_notes_not_utf8") from error
    release = release_by_exact_tag(allow_missing=True)
    tag_commit = release_tag_commit(VERSION)
    if release is None:
        if tag_commit not in {None, merged_sha}:
            raise ReleaseError("release_tag_commit_mismatch")
        if tag_commit is None:
            run(
                (
                    "gh",
                    "api",
                    "--method",
                    "POST",
                    f"repos/{REPOSITORY}/git/refs",
                    "-f",
                    f"ref=refs/tags/{VERSION}",
                    "-f",
                    f"sha={merged_sha}",
                ),
                timeout=120,
            )
            tag_commit = release_tag_commit(VERSION)
            if tag_commit != merged_sha:
                raise ReleaseError("release_tag_creation_failed")
        result = run(
            (
                "gh",
                "release",
                "create",
                VERSION,
                "--repo",
                REPOSITORY,
                "--draft",
                "--latest=false",
                "--target",
                merged_sha,
                "--title",
                "Symphony Studio v0.1.0 foundation",
                "--notes-file",
                str(notes_file),
            ),
            timeout=120,
        )
        if not result.stdout.strip():
            raise ReleaseError("draft_release_url_missing")
        release = release_by_exact_tag()
        tag_commit = release_tag_commit(VERSION)
    if tag_commit != merged_sha:
        raise ReleaseError("release_tag_commit_mismatch")
    if not release.get("draft") and release.get("published_at") is None:
        raise ReleaseError("release_state_invalid")
    if release.get("body") != expected_notes:
        if release.get("draft") is not True:
            raise ReleaseError("published_release_notes_mismatch")
        run(
            (
                "gh",
                "release",
                "edit",
                VERSION,
                "--repo",
                REPOSITORY,
                "--notes-file",
                str(notes_file),
            ),
            timeout=120,
        )
        release = release_by_exact_tag()
        if release.get("draft") is not True or release.get("body") != expected_notes:
            raise ReleaseError("draft_release_notes_reconciliation_failed")
    return release


def download_release_asset(asset: Mapping[str, Any], destination: Path) -> None:
    asset_id = asset.get("id")
    if not isinstance(asset_id, int) or asset_id <= 0:
        raise ReleaseError("release_asset_id_invalid")
    with destination.open("xb") as output:
        result = subprocess.run(
            (
                "gh",
                "api",
                "-H",
                "Accept: application/octet-stream",
                f"repos/{REPOSITORY}/releases/assets/{asset_id}",
            ),
            cwd=ROOT,
            stdin=subprocess.DEVNULL,
            stdout=output,
            stderr=subprocess.PIPE,
            check=False,
            timeout=300,
        )
    if result.returncode != 0:
        destination.unlink(missing_ok=True)
        raise ReleaseError("release_asset_download_failed")


def download_and_verify_release(directory: Path, release: Mapping[str, Any]) -> None:
    with tempfile.TemporaryDirectory(prefix="symphony-release-download-") as temporary:
        download = Path(temporary)
        local_names = {path.name for path in directory.iterdir() if path.is_file()}
        assets = remote_assets(int(release["id"]))
        for asset in assets:
            name = asset.get("name")
            if not isinstance(name, str) or re.fullmatch(r"[A-Za-z0-9._-]+", name) is None:
                raise ReleaseError("release_asset_name_invalid")
            download_release_asset(asset, download / name)
        downloaded_names = {path.name for path in download.iterdir() if path.is_file()}
        if local_names != downloaded_names:
            raise ReleaseError("downloaded_release_asset_inventory_mismatch")
        for name in sorted(local_names):
            if sha256_file(directory / name) != sha256_file(download / name):
                raise ReleaseError(f"downloaded_release_asset_hash_mismatch:{name}")
        verify_checksums(download)


def reconcile_draft_assets(directory: Path, release: Mapping[str, Any]) -> None:
    local = {path.name: path for path in directory.iterdir() if path.is_file()}
    existing_list = remote_assets(int(release["id"]))
    existing = {asset.get("name"): asset for asset in existing_list}
    if len(existing) != len(existing_list) or not set(existing).issubset(local):
        raise ReleaseError("draft_release_asset_inventory_conflict")
    with tempfile.TemporaryDirectory(prefix="symphony-release-existing-") as temporary:
        download = Path(temporary)
        for name, asset in existing.items():
            if not isinstance(name, str) or re.fullmatch(r"[A-Za-z0-9._-]+", name) is None:
                raise ReleaseError("release_asset_name_invalid")
            if asset.get("size") != local[name].stat().st_size:
                raise ReleaseError(f"draft_release_asset_size_mismatch:{name}")
            destination = download / name
            download_release_asset(asset, destination)
            if sha256_file(destination) != sha256_file(local[name]):
                raise ReleaseError(f"draft_release_asset_hash_mismatch:{name}")
    missing = sorted(set(local) - set(existing))
    if missing:
        run(
            (
                "gh",
                "release",
                "upload",
                VERSION,
                "--repo",
                REPOSITORY,
                *(str(local[name]) for name in missing),
            ),
            timeout=900,
        )
    refreshed = release_by_exact_tag()
    if refreshed.get("draft") is not True:
        raise ReleaseError("staged_release_not_draft")
    verify_remote_asset_inventory(directory, refreshed)
    download_and_verify_release(directory, refreshed)


def verified_publication_inputs(
    directory: Path,
    candidate_path: Path,
    merged_sha: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    if is_within(candidate_path, ROOT):
        raise ReleaseError("candidate_manifest_must_be_external")
    candidate = validate_candidate(candidate_path, verify_refs=False)
    candidate_sha = sha256_file(candidate_path)
    verify_checksums(directory)
    package_manifest = validate_package_manifest(
        directory,
        expected_merged_sha=merged_sha,
        expected_candidate_sha256=candidate_sha,
        require_platform=True,
    )
    if git("rev-parse", "HEAD") != merged_sha:
        raise ReleaseError("publication_requires_exact_merged_main")
    if run(("git", "merge-base", "--is-ancestor", merged_sha, "origin/main"), check=False).returncode != 0:
        raise ReleaseError("publication_commit_not_on_remote_main")
    if git("status", "--porcelain=v1", "--untracked-files=all"):
        raise ReleaseError("publication_worktree_not_clean")
    parents = git("rev-list", "--parents", "-n", "1", merged_sha).split()
    if parents != [merged_sha, candidate["baseSha"], candidate["releaseHeadSha"]]:
        raise ReleaseError("publication_merge_parent_identity_mismatch")
    merged_tree = git("rev-parse", f"{merged_sha}^{{tree}}")
    if (
        merged_tree != candidate["testedMergeTreeSha"]
        or merged_tree != package_manifest["mergedTreeSha"]
    ):
        raise ReleaseError("publication_merged_tree_mismatch")
    return candidate, package_manifest


def stage_receipt(
    release: Mapping[str, Any],
    merged_sha: str,
    directory: Path,
) -> dict[str, Any]:
    if release_tag_commit(VERSION) != merged_sha:
        raise ReleaseError("staged_tag_commit_mismatch")
    return {
        "assetCount": len([path for path in directory.iterdir() if path.is_file()]),
        "checksumsSha256": sha256_file(directory / "SHA256SUMS"),
        "draft": release.get("draft"),
        "kind": "release-stage-receipt",
        "mergedCommit": merged_sha,
        "releaseId": release.get("id"),
        "releaseManifestSha256": sha256_file(directory / "release-manifest.json"),
        "repository": REPOSITORY,
        "status": "pass",
        "tag": VERSION,
    }


def publication_receipt(
    release: Mapping[str, Any],
    merged_sha: str,
    directory: Path,
    *,
    handoff: Mapping[str, Any],
    integrity_verification: Mapping[str, Any],
    repository_immutable: bool,
    latest: bool,
) -> dict[str, Any]:
    tag_commit = release_tag_commit(VERSION)
    if release.get("draft") is not False or not release.get("published_at"):
        raise ReleaseError("release_not_published")
    if tag_commit != merged_sha:
        raise ReleaseError("published_tag_commit_mismatch")
    release_immutable = release.get("immutable") is True
    if not repository_immutable or not release_immutable or not latest:
        raise ReleaseError("published_release_policy_mismatch")
    return {
        "assetCount": len([path for path in directory.iterdir() if path.is_file()]),
        "checksumsSha256": sha256_file(directory / "SHA256SUMS"),
        "immutableRelease": release_immutable,
        "handoff": dict(handoff),
        "integrityVerification": dict(integrity_verification),
        "kind": "release-publication-receipt",
        "latestRelease": latest,
        "mergedCommit": merged_sha,
        "publishedAt": release["published_at"],
        "releaseId": release["id"],
        "releaseManifestSha256": sha256_file(directory / "release-manifest.json"),
        "releaseUrl": release["html_url"],
        "repository": REPOSITORY,
        "repositoryImmutablePolicy": repository_immutable,
        "status": "pass"
        if handoff.get("releaseBranchDeleted") is True
        else "publication-verified-cleanup-pending",
        "tag": VERSION,
        "tagTarget": tag_commit,
    }


def publication_pending_receipt(
    release: Mapping[str, Any],
    merged_sha: str,
    candidate_sha256: str,
    workflow_sha: str,
    *,
    phase: str,
) -> dict[str, Any]:
    return {
        "candidateManifestSha256": candidate_sha256,
        "failingPhase": None,
        "kind": "release-publication-receipt",
        "latestRelease": None,
        "mergedCommit": merged_sha,
        "observedDraft": release.get("draft"),
        "observedPublishedAt": release.get("published_at"),
        "observedReleaseId": release.get("id"),
        "observedReleaseUrl": release.get("html_url"),
        "phase": phase,
        "recordedAt": iso_from_epoch(int(dt.datetime.now(tz=dt.timezone.utc).timestamp())),
        "releaseImmutable": release.get("immutable"),
        "repository": REPOSITORY,
        "repositoryImmutablePolicy": None,
        "status": "publication-verification-pending",
        "tag": VERSION,
        "tagTarget": None,
        "verifiedPhases": [],
        "workflowSourceCommit": workflow_sha,
    }


def run_publication_gate(
    receipt_path: Path,
    progress: dict[str, Any],
    phase: str,
    operation,
    projector=lambda _result: {},
) -> tuple[Any, dict[str, Any]]:
    try:
        result = operation()
        projected = projector(result)
    except Exception:
        failed = {
            **progress,
            "failingPhase": phase,
            "phase": phase,
            "recordedAt": iso_from_epoch(int(dt.datetime.now(tz=dt.timezone.utc).timestamp())),
            "status": "publication-verification-failed",
        }
        atomic_write(receipt_path, canonical_json_bytes(failed))
        raise
    advanced = {
        **progress,
        **projected,
        "failingPhase": None,
        "phase": phase,
        "recordedAt": iso_from_epoch(int(dt.datetime.now(tz=dt.timezone.utc).timestamp())),
        "verifiedPhases": [*progress["verifiedPhases"], phase],
    }
    atomic_write(receipt_path, canonical_json_bytes(advanced))
    return result, advanced


def begin_publication_command(
    receipt_path: Path,
    release: Mapping[str, Any],
    merged_sha: str,
    candidate_sha256: str,
    workflow_sha: str,
) -> dict[str, Any]:
    progress = publication_pending_receipt(
        release,
        merged_sha,
        candidate_sha256,
        workflow_sha,
        phase="publication-command-in-flight",
    )
    atomic_write(receipt_path, canonical_json_bytes(progress))
    if release.get("draft") is True:
        _result, progress = run_publication_gate(
            receipt_path,
            progress,
            "publication-command-returned",
            lambda: run(
                (
                    "gh",
                    "release",
                    "edit",
                    VERSION,
                    "--repo",
                    REPOSITORY,
                    "--draft=false",
                    "--latest",
                ),
                timeout=120,
            ),
        )
    else:
        _result, progress = run_publication_gate(
            receipt_path,
            progress,
            "publication-command-not-required",
            lambda: None,
        )
    return progress


def verify_remote_main_ancestry(merged_sha: str) -> dict[str, Any]:
    comparison = gh_api(f"repos/{REPOSITORY}/compare/{merged_sha}...main")
    if (
        comparison.get("status") not in {"ahead", "identical"}
        or (comparison.get("merge_base_commit") or {}).get("sha") != merged_sha
    ):
        raise ReleaseError("published_commit_not_ancestor_of_remote_main")
    commits = comparison.get("commits") or []
    if comparison.get("status") == "ahead" and (
        not commits or not isinstance(commits[-1].get("sha"), str)
    ):
        raise ReleaseError("published_main_comparison_invalid")
    return {
        "mainAncestry": "verified",
        "mainHeadSha": commits[-1]["sha"]
        if comparison.get("status") == "ahead"
        else merged_sha,
    }


def delete_release_branch(candidate: Mapping[str, Any]) -> dict[str, Any]:
    branch_path = f"repos/{REPOSITORY}/git/ref/heads/{RELEASE_BRANCH}"
    branch_delete_path = f"repos/{REPOSITORY}/git/refs/heads/{RELEASE_BRANCH}"
    release_branch = gh_api(branch_path, allow_missing=True)
    if release_branch is not None:
        if (release_branch.get("object") or {}).get("sha") != candidate["releaseHeadSha"]:
            raise ReleaseError("release_branch_head_mismatch_before_delete")
        result = run(
            ("gh", "api", "--method", "DELETE", branch_delete_path),
            check=False,
            timeout=120,
        )
        if result.returncode != 0:
            raise ReleaseError("release_branch_delete_failed")
    if gh_api(branch_path, allow_missing=True) is not None:
        raise ReleaseError("release_branch_delete_not_observed")
    return {
        "releaseBranchDeleted": True,
        "releaseBranchHeadSha": candidate["releaseHeadSha"],
    }


def verify_build_provenance(directory: Path, workflow_sha: str) -> dict[str, Any]:
    if SHA1_RE.fullmatch(workflow_sha) is None:
        raise ReleaseError("publication_workflow_sha_invalid")
    signer = f"{REPOSITORY}/.github/workflows/publish-release.yml"
    provenance_hashes: dict[str, str] = {}
    for path in sorted(item for item in directory.iterdir() if item.is_file()):
        provenance = run(
            (
                "gh",
                "attestation",
                "verify",
                str(path),
                "--repo",
                REPOSITORY,
                "--signer-workflow",
                signer,
                "--source-ref",
                "refs/heads/main",
                "--source-digest",
                workflow_sha,
                "--signer-digest",
                workflow_sha,
                "--predicate-type",
                "https://slsa.dev/provenance/v1",
                "--deny-self-hosted-runners",
                "--limit",
                "100",
                "--format",
                "json",
            ),
            timeout=300,
        )
        try:
            provenance_verification = json.loads(provenance.stdout)
        except json.JSONDecodeError as error:
            raise ReleaseError(f"build_provenance_json_invalid:{path.name}") from error
        if (
            not isinstance(provenance_verification, list)
            or not provenance_verification
            or any(
                not isinstance(item, dict)
                or item.get("attestation") is None
                or item.get("verificationResult") is None
                for item in provenance_verification
            )
        ):
            raise ReleaseError(f"build_provenance_invalid:{path.name}")
        provenance_hashes[path.name] = sha256_bytes(
            (provenance.stdout + provenance.stderr).encode("utf-8")
        )
    if set(provenance_hashes) != {
        path.name for path in directory.iterdir() if path.is_file()
    }:
        raise ReleaseError("build_provenance_inventory_mismatch")
    return {
        "assetCount": len(provenance_hashes),
        "buildProvenanceOutputSha256": provenance_hashes,
        "signerWorkflow": signer,
        "status": "pass",
        "workflowSourceSha": workflow_sha,
    }


def verify_published_integrity(
    directory: Path, workflow_sha: str
) -> dict[str, Any]:
    provenance = verify_build_provenance(directory, workflow_sha)
    release_result = run(
        ("gh", "release", "verify", VERSION, "--repo", REPOSITORY, "--format", "json"),
        timeout=300,
    )
    try:
        release_verification = json.loads(release_result.stdout)
    except json.JSONDecodeError as error:
        raise ReleaseError("release_attestation_json_invalid") from error
    if (
        not isinstance(release_verification, dict)
        or release_verification.get("attestation") is None
        or release_verification.get("verificationResult") is None
    ):
        raise ReleaseError("release_attestation_invalid")
    release_asset_hashes: dict[str, str] = {}
    for path in sorted(item for item in directory.iterdir() if item.is_file()):
        release_asset = run(
            (
                "gh",
                "release",
                "verify-asset",
                VERSION,
                str(path),
                "--repo",
                REPOSITORY,
                "--format",
                "json",
            ),
            timeout=300,
        )
        try:
            release_asset_verification = json.loads(release_asset.stdout)
        except json.JSONDecodeError as error:
            raise ReleaseError(f"published_attestation_json_invalid:{path.name}") from error
        if (
            not isinstance(release_asset_verification, dict)
            or release_asset_verification.get("attestation") is None
            or release_asset_verification.get("verificationResult") is None
        ):
            raise ReleaseError(f"published_attestation_invalid:{path.name}")
        release_asset_hashes[path.name] = sha256_bytes(
            (release_asset.stdout + release_asset.stderr).encode("utf-8")
        )
    if set(release_asset_hashes) != {
        path.name for path in directory.iterdir() if path.is_file()
    }:
        raise ReleaseError("published_integrity_inventory_mismatch")
    return {
        **provenance,
        "releaseAssetOutputSha256": release_asset_hashes,
        "releaseAttestationOutputSha256": sha256_bytes(
            (release_result.stdout + release_result.stderr).encode("utf-8")
        ),
    }


def command_verify_build_provenance(args: argparse.Namespace) -> int:
    directory = external_path(args.directory, directory=True)
    record = verify_build_provenance(directory, args.workflow_sha)
    print(sha256_bytes(canonical_json_bytes(record)))
    return 0


def verify_publication_attestation(
    subject_path: Path,
    receipt_path: Path,
    workflow_sha: str,
) -> dict[str, Any]:
    receipt, _raw = load_canonical_json(receipt_path)
    if receipt.get("kind") != "release-publication-receipt" or receipt.get("status") != "pass":
        raise ReleaseError("publication_attestation_receipt_invalid")
    signer = f"{REPOSITORY}/.github/workflows/publish-release.yml"
    result = run(
        (
            "gh",
            "attestation",
            "verify",
            str(subject_path),
            "--repo",
            REPOSITORY,
            "--signer-workflow",
            signer,
            "--source-ref",
            "refs/heads/main",
            "--source-digest",
            workflow_sha,
            "--signer-digest",
            workflow_sha,
            "--predicate-type",
            PUBLICATION_PREDICATE_TYPE,
            "--deny-self-hosted-runners",
            "--limit",
            "100",
            "--format",
            "json",
        ),
        timeout=300,
    )
    try:
        verification = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ReleaseError("publication_attestation_json_invalid") from error
    matching = []
    if isinstance(verification, list):
        for item in verification:
            verification_result = item.get("verificationResult") if isinstance(item, dict) else None
            statement = (
                verification_result.get("statement")
                if isinstance(verification_result, dict)
                else None
            )
            if (
                isinstance(statement, dict)
                and statement.get("predicateType") == PUBLICATION_PREDICATE_TYPE
                and statement.get("predicate") == receipt
                and item.get("attestation") is not None
            ):
                matching.append(item)
    if not matching:
        raise ReleaseError("publication_attestation_predicate_mismatch")
    return {
        "kind": "release-publication-attestation-verification",
        "predicateType": PUBLICATION_PREDICATE_TYPE,
        "receiptSha256": sha256_file(receipt_path),
        "signerWorkflow": signer,
        "status": "pass",
        "subjectName": subject_path.name,
        "subjectSha256": sha256_file(subject_path),
        "verificationOutputSha256": sha256_bytes(
            (result.stdout + result.stderr).encode("utf-8")
        ),
        "workflowSourceSha": workflow_sha,
    }


def command_verify_publication_attestation(args: argparse.Namespace) -> int:
    subject = external_path(args.subject)
    receipt = external_path(args.receipt)
    record = verify_publication_attestation(subject, receipt, args.workflow_sha)
    print(sha256_bytes(canonical_json_bytes(record)))
    return 0


def command_publish_stage(args: argparse.Namespace) -> int:
    directory = external_path(args.directory, directory=True)
    candidate_path = external_path(args.candidate)
    notes_file = Path(args.notes_file).resolve()
    if notes_file != ROOT / "docs/releases/v0.1.0/release-notes.md":
        raise ReleaseError("release_notes_path_invalid")
    receipt_path = external_path(args.receipt)
    candidate, package_manifest = verified_publication_inputs(
        directory,
        candidate_path,
        args.merged_sha,
    )
    immutable = gh_api(f"repos/{REPOSITORY}/immutable-releases")
    if immutable.get("enabled") is not True:
        raise ReleaseError("immutable_releases_not_enabled")
    release = create_or_reuse_draft(args.merged_sha, notes_file)
    append_final_manifest(directory, candidate, package_manifest, release)
    require_final_asset_inventory(directory)
    verify_checksums(directory)
    validate_package_manifest(
        directory,
        expected_merged_sha=args.merged_sha,
        expected_candidate_sha256=sha256_file(candidate_path),
    )
    validate_final_manifest(directory, candidate, package_manifest, release)

    if release.get("draft") is True:
        reconcile_draft_assets(directory, release)
        release = release_by_exact_tag()
    verify_remote_asset_inventory(directory, release)
    download_and_verify_release(directory, release)
    receipt = stage_receipt(release, args.merged_sha, directory)
    atomic_write(receipt_path, canonical_json_bytes(receipt))
    print(sha256_file(receipt_path))
    return 0


def command_publish_finalize(args: argparse.Namespace) -> int:
    directory = external_path(args.directory, directory=True)
    candidate_path = external_path(args.candidate)
    receipt_path = external_path(args.receipt)
    candidate, package_manifest = verified_publication_inputs(
        directory,
        candidate_path,
        args.merged_sha,
    )
    publication_workflow_source_record(candidate, args.merged_sha, args.workflow_sha)
    candidate_sha256 = sha256_file(candidate_path)
    release = release_by_exact_tag(allow_missing=True)
    if release is None:
        raise ReleaseError("staged_release_missing")
    expected_notes = git_bytes(
        args.merged_sha,
        "docs/releases/v0.1.0/release-notes.md",
    ).decode("utf-8")
    if release.get("body") != expected_notes:
        raise ReleaseError("staged_release_notes_mismatch")
    require_final_asset_inventory(directory)
    validate_final_manifest(directory, candidate, package_manifest, release)
    verify_remote_asset_inventory(directory, release)
    download_and_verify_release(directory, release)
    require_no_active_release_revert(candidate, args.merged_sha)
    if release.get("draft") is True and release_tag_commit(VERSION) != args.merged_sha:
        raise ReleaseError("staged_tag_commit_mismatch_before_publication")
    progress = begin_publication_command(
        receipt_path,
        release,
        args.merged_sha,
        candidate_sha256,
        args.workflow_sha,
    )
    observed_release, progress = run_publication_gate(
        receipt_path,
        progress,
        "published-release-fetched",
        published_release_observation,
        lambda value: {
            "observedDraft": value.get("draft") if isinstance(value, dict) else None,
            "observedPublishedAt": value.get("published_at")
            if isinstance(value, dict)
            else None,
            "observedReleaseId": value.get("id") if isinstance(value, dict) else None,
            "observedReleaseUrl": value.get("html_url") if isinstance(value, dict) else None,
            "releaseImmutable": value.get("immutable") if isinstance(value, dict) else None,
        },
    )
    release, progress = run_publication_gate(
        receipt_path,
        progress,
        "published-release-identity-verified",
        lambda: validate_published_release(
            observed_release,
            int(release["id"]),
            expected_notes,
        ),
        lambda value: {"releaseImmutable": value.get("immutable")},
    )
    tag_target, progress = run_publication_gate(
        receipt_path,
        progress,
        "published-tag-target-verified",
        lambda: release_tag_commit(VERSION),
        lambda value: {"tagTarget": value},
    )
    if tag_target != args.merged_sha:
        progress["failingPhase"] = "published-tag-target-verified"
        progress["status"] = "publication-verification-failed"
        atomic_write(receipt_path, canonical_json_bytes(progress))
        raise ReleaseError("published_tag_commit_mismatch")
    _ignored, progress = run_publication_gate(
        receipt_path,
        progress,
        "published-asset-inventory-verified",
        lambda: verify_remote_asset_inventory(directory, release),
    )
    _ignored, progress = run_publication_gate(
        receipt_path,
        progress,
        "published-assets-downloaded-and-rehashed",
        lambda: download_and_verify_release(directory, release),
    )
    immutable_state, progress = run_publication_gate(
        receipt_path,
        progress,
        "repository-immutability-verified",
        require_repository_immutable_policy,
        lambda value: {"repositoryImmutablePolicy": value.get("enabled")},
    )
    latest_release, progress = run_publication_gate(
        receipt_path,
        progress,
        "latest-release-verified",
        lambda: require_latest_release(int(release["id"])),
        lambda value: {"latestRelease": value.get("id") == release.get("id")},
    )
    repository_immutable = immutable_state.get("enabled") is True
    latest = latest_release.get("id") == release.get("id")
    integrity_verification, progress = run_publication_gate(
        receipt_path,
        progress,
        "published-attestations-verified",
        lambda: verify_published_integrity(directory, args.workflow_sha),
    )
    remote_main, progress = run_publication_gate(
        receipt_path,
        progress,
        "protected-main-ancestry-verified",
        lambda: verify_remote_main_ancestry(args.merged_sha),
    )
    cleanup_pending = {
        **remote_main,
        "releaseBranchDeleted": False,
        "releaseBranchHeadSha": candidate["releaseHeadSha"],
    }

    receipt = publication_receipt(
        release,
        args.merged_sha,
        directory,
        handoff=cleanup_pending,
        integrity_verification=integrity_verification,
        repository_immutable=repository_immutable,
        latest=latest,
    )
    atomic_write(receipt_path, canonical_json_bytes(receipt))
    handoff = {**remote_main, **delete_release_branch(candidate)}
    receipt = publication_receipt(
        release,
        args.merged_sha,
        directory,
        handoff=handoff,
        integrity_verification=integrity_verification,
        repository_immutable=repository_immutable,
        latest=latest,
    )
    atomic_write(receipt_path, canonical_json_bytes(receipt))
    print(receipt["releaseUrl"])
    print(sha256_file(receipt_path))
    return 0


def command_manifest_decode(args: argparse.Namespace) -> int:
    output = external_path(args.output)
    try:
        raw = base64.b64decode(args.base64, validate=True)
    except ValueError as error:
        raise ReleaseError("candidate_manifest_base64_invalid") from error
    candidate_manifest_attachment(raw)
    if sha256_bytes(raw) != args.sha256:
        raise ReleaseError("candidate_manifest_transport_hash_mismatch")
    atomic_write(output, raw)
    load_canonical_json(output)
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog="release.py")
    commands = root.add_subparsers(dest="command", required=True)

    doctor = commands.add_parser("doctor")
    doctor.add_argument("--trusted-check-app-id", type=int)
    doctor.add_argument("--expected-head")
    doctor.add_argument("--read-only-ci", action="store_true")
    doctor.add_argument("--output")
    doctor.set_defaults(handler=command_doctor)

    candidate = commands.add_parser("candidate")
    candidate.add_argument("--head")
    candidate.add_argument("--base")
    candidate.add_argument("--review-evidence", action="append", default=[], required=True)
    candidate.add_argument("--test-evidence", action="append", default=[], required=True)
    candidate.add_argument("--output", required=True)
    candidate.add_argument("--pr-body-output")
    candidate.set_defaults(handler=command_candidate)

    reconcile = commands.add_parser("reconcile-pr")
    reconcile.add_argument("--manifest", required=True)
    reconcile.add_argument("--receipt", required=True)
    reconcile.set_defaults(handler=command_candidate_reconcile)

    verify = commands.add_parser("verify")
    verify_commands = verify.add_subparsers(dest="verify_command", required=True)
    verify_candidate_parser = verify_commands.add_parser("candidate")
    verify_candidate_parser.add_argument("--manifest", required=True)
    verify_candidate_parser.add_argument("--no-ref-check", action="store_true")
    verify_candidate_parser.set_defaults(handler=command_verify_candidate)
    verify_protected_merge_parser = verify_commands.add_parser("protected-merge")
    verify_protected_merge_parser.add_argument("--candidate", required=True)
    verify_protected_merge_parser.add_argument("--merged-sha", required=True)
    verify_protected_merge_parser.add_argument("--pr-number", type=int, required=True)
    verify_protected_merge_parser.add_argument(
        "--trusted-check-app-id", type=int, required=True
    )
    verify_protected_merge_parser.add_argument("--receipt")
    verify_protected_merge_parser.set_defaults(handler=command_verify_protected_merge)
    verify_workflow_source_parser = verify_commands.add_parser("workflow-source")
    verify_workflow_source_parser.add_argument("--candidate", required=True)
    verify_workflow_source_parser.add_argument("--merged-sha", required=True)
    verify_workflow_source_parser.add_argument("--workflow-sha", required=True)
    verify_workflow_source_parser.set_defaults(handler=command_verify_workflow_source)
    verify_package_parser = verify_commands.add_parser("package")
    verify_package_parser.add_argument("--directory", required=True)
    verify_package_parser.set_defaults(handler=command_verify_package)
    verify_clean_install_parser = verify_commands.add_parser("clean-install")
    verify_clean_install_parser.add_argument("--directory", required=True)
    verify_clean_install_parser.add_argument("--receipt", required=True)
    verify_clean_install_parser.set_defaults(handler=command_verify_clean_install)
    verify_provenance_parser = verify_commands.add_parser("build-provenance")
    verify_provenance_parser.add_argument("--directory", required=True)
    verify_provenance_parser.add_argument("--workflow-sha", required=True)
    verify_provenance_parser.set_defaults(handler=command_verify_build_provenance)
    verify_publication_attestation_parser = verify_commands.add_parser(
        "publication-attestation"
    )
    verify_publication_attestation_parser.add_argument("--subject", required=True)
    verify_publication_attestation_parser.add_argument("--receipt", required=True)
    verify_publication_attestation_parser.add_argument("--workflow-sha", required=True)
    verify_publication_attestation_parser.set_defaults(
        handler=command_verify_publication_attestation
    )
    verify_baseline_parser = verify_commands.add_parser("baseline-return")
    verify_baseline_parser.add_argument("--output", required=True)
    verify_baseline_parser.set_defaults(handler=command_verify_baseline)

    publish = commands.add_parser("publish")
    publish_commands = publish.add_subparsers(dest="publish_command", required=True)
    dispatch = publish_commands.add_parser("dispatch")
    dispatch.add_argument("--candidate", required=True)
    dispatch.add_argument("--merged-sha", required=True)
    dispatch.add_argument("--pr-number", type=int, required=True)
    dispatch.add_argument("--trusted-check-app-id", type=int, required=True)
    dispatch.add_argument("--receipt", required=True)
    dispatch.set_defaults(handler=command_publish_dispatch)
    prepare = publish_commands.add_parser("prepare")
    prepare.add_argument("--candidate", required=True)
    prepare.add_argument("--merged-sha", required=True)
    prepare.add_argument("--pr-number", type=int, required=True)
    prepare.add_argument("--output-dir", required=True)
    prepare.set_defaults(handler=command_publish_prepare)
    attach_platform = publish_commands.add_parser("attach-platform")
    attach_platform.add_argument("--directory", required=True)
    attach_platform.add_argument("--platform-receipt", required=True)
    attach_platform.set_defaults(handler=command_publish_attach_platform)
    stage = publish_commands.add_parser("stage")
    stage.add_argument("--candidate", required=True)
    stage.add_argument("--merged-sha", required=True)
    stage.add_argument("--directory", required=True)
    stage.add_argument("--notes-file", required=True)
    stage.add_argument("--receipt", required=True)
    stage.set_defaults(handler=command_publish_stage)
    finalize = publish_commands.add_parser("finalize")
    finalize.add_argument("--candidate", required=True)
    finalize.add_argument("--merged-sha", required=True)
    finalize.add_argument("--directory", required=True)
    finalize.add_argument("--receipt", required=True)
    finalize.add_argument("--workflow-sha", required=True)
    finalize.set_defaults(handler=command_publish_finalize)

    decode = commands.add_parser("decode-manifest")
    decode.add_argument("--base64", required=True)
    decode.add_argument("--sha256", required=True)
    decode.add_argument("--output", required=True)
    decode.set_defaults(handler=command_manifest_decode)
    return root


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        return int(args.handler(args))
    except ReleaseError as error:
        print(str(error), file=sys.stderr)
        return 78


if __name__ == "__main__":
    raise SystemExit(main())
