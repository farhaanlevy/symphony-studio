#!/usr/bin/env python3
"""Fail-closed owner tooling for the Symphony Studio Build Week Preview.

This module deliberately does not load credentials. Live Linear mutation is
disabled until a distinct trusted out-of-process preview-write broker exists.
The tooling validates local boundaries, launches the production runtime, and
drives verification only after explicit owner acknowledgements.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from typing import Any, Iterable, Mapping, Sequence
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen


PASS = 0
FAIL = 1
BLOCKED = 20
USAGE = 64
SCHEMA_VERSION = 1
APP_MARKER = "symphony-studio-buildweek-preview"
MARKER_NAME = ".symphony-studio-preview-root.json"
MAX_TEXT_BYTES = 16 * 1024 * 1024
MAX_AUDIT_FILE_BYTES = 32 * 1024 * 1024
MAX_DRIVER_OUTPUT_BYTES = 64 * 1024
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
MAX_ARCHIVE_MEMBERS = 100_000
MAX_EXTRACTED_BYTES = 2 * 1024 * 1024 * 1024
MAX_RESET_DIRECTORY_ENTRIES = 1_024
FORBIDDEN_FIXTURE_ISSUES = frozenset({"SYM-1", "SYM-2"})
ISSUE_IDENTIFIER = re.compile(r"[A-Z][A-Z0-9]{1,9}-[1-9][0-9]{0,9}\Z")
INTENT_ID = re.compile(r"intent_[0-9a-f]{24}\Z")
MEDIA_EXTENSIONS = frozenset(
    {
        ".aac",
        ".aep",
        ".aepx",
        ".als",
        ".aup3",
        ".davinci",
        ".flac",
        ".m4a",
        ".mkv",
        ".mov",
        ".mp3",
        ".mp4",
        ".ogg",
        ".otio",
        ".prproj",
        ".wav",
        ".webm",
    }
)
# This exact upstream-provenance demo is retained by the pinned Symphony base.
# Any byte change, any second media file, or any Studio submission media fails.
ALLOWED_UPSTREAM_MEDIA_SHA256 = {
    ".github/media/symphony-demo.mp4": (
        "0baa5f6276ea9a790d8072e690c547ed02afb3f95312266d3f27a923d4f58ec1"
    )
}
AUDIT_EXCLUDED_PARTS = frozenset({".git", "deps", "node_modules", "_build"})
SENSITIVE_FILENAMES = frozenset(
    {
        ".env",
        "cookies.json",
        "storage-state.json",
        "storage_state.json",
        "playwright-auth.json",
    }
)
CONTENT_SECRET_PATTERNS: tuple[tuple[str, re.Pattern[bytes]], ...] = (
    ("private key", re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----")),
    ("GitHub token", re.compile(rb"\bgh[pousr]_[A-Za-z0-9]{30,}\b")),
    ("OpenAI-style token", re.compile(rb"\bsk-[A-Za-z0-9_-]{32,}\b")),
    ("Linear-style token", re.compile(rb"\blin_api_[A-Za-z0-9_-]{20,}\b")),
    (
        "literal Linear credential assignment",
        re.compile(
            rb"(?m)^\s*LINEAR_API_KEY\s*=\s*(?!\$|<|\{\{|REDACTED\b|redacted\b)[^\s#]{8,}\s*$"
        ),
    ),
    (
        "browser cookie material",
        re.compile(rb'(?i)"(?:cookies|localStorage|sessionStorage)"\s*:\s*\['),
    ),
    (
        "developer-home path",
        re.compile(rb"/(?:home|Users)/[A-Za-z0-9._-]+/(?:\.codex|projects|workspaces)/"),
    ),
)
SAFE_CHILD_ENVIRONMENT = frozenset(
    {
        "HOME",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "LOGNAME",
        "PATH",
        "SHELL",
        "TERM",
        "TMPDIR",
        "USER",
    }
)
BUILD_CHILD_ENVIRONMENT = SAFE_CHILD_ENVIRONMENT | {
    "MIX_HOME",
    "PYTHONDONTWRITEBYTECODE",
}
RUNTIME_CHILD_ENVIRONMENT = BUILD_CHILD_ENVIRONMENT | {
    "SYMPHONY_STUDIO_DATA_ROOT"
}
CLEAN_LAUNCH_CHILD_ENVIRONMENT = BUILD_CHILD_ENVIRONMENT | {
    "MISE_DATA_DIR",
    "MIX_ENV",
}
BROWSER_CHILD_ENVIRONMENT = SAFE_CHILD_ENVIRONMENT | {
    "PYTHONDONTWRITEBYTECODE",
    "SYMPHONY_PREVIEW_ARTIFACT_ROOT",
    "SYMPHONY_PREVIEW_BASE_URL",
    "SYMPHONY_PREVIEW_LIVE_WRITE",
}
ALLOWED_CHILD_ENVIRONMENT = (
    RUNTIME_CHILD_ENVIRONMENT
    | CLEAN_LAUNCH_CHILD_ENVIRONMENT
    | BROWSER_CHILD_ENVIRONMENT
)


class PreviewError(RuntimeError):
    """Base error with a stable public status and exit code."""

    def __init__(self, message: str, *, status: str = "failed", exit_code: int = FAIL):
        super().__init__(message)
        self.status = status
        self.exit_code = exit_code


class PreviewBlocked(PreviewError):
    """A named dependency or integration contract is unavailable."""

    def __init__(self, message: str):
        super().__init__(message, status="blocked", exit_code=BLOCKED)


def repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode(
        "utf-8"
    )


def write_private_json(path: Path, value: Any) -> None:
    payload = canonical_json(value)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.prepare")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb", closefd=True) as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def read_bounded(path: Path, limit: int = MAX_TEXT_BYTES) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise PreviewError(f"required input could not be opened safely: {path.name}") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise PreviewError(f"required input is not a regular file: {path.name}")
        if metadata.st_size > limit:
            raise PreviewError(f"required input exceeds its byte bound: {path.name}")
        chunks: list[bytes] = []
        remaining = limit + 1
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = b"".join(chunks)
        if len(payload) > limit:
            raise PreviewError(f"required input exceeds its byte bound: {path.name}")
        return payload
    finally:
        os.close(descriptor)


def run_command(
    command: Sequence[str],
    *,
    cwd: Path,
    environment: Mapping[str, str] | None = None,
    timeout: float = 60.0,
    max_output_bytes: int = MAX_TEXT_BYTES,
) -> subprocess.CompletedProcess[bytes]:
    normalized = [str(part) for part in command]
    child_environment = validated_child_environment(environment)
    try:
        with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
            process = subprocess.Popen(
                normalized,
                cwd=cwd,
                env=child_environment,
                stdin=subprocess.DEVNULL,
                stdout=stdout,
                stderr=stderr,
                start_new_session=True,
            )
            deadline = time.monotonic() + timeout
            while True:
                returncode = process.poll()
                stdout_size = os.fstat(stdout.fileno()).st_size
                stderr_size = os.fstat(stderr.fileno()).st_size
                if stdout_size + stderr_size > max_output_bytes:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=5.0)
                    raise PreviewError(
                        f"command output exceeded its byte bound: {command[0]}"
                    )
                if returncode is not None:
                    break
                if time.monotonic() >= deadline:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=5.0)
                    raise PreviewError(f"command timed out: {command[0]}")
                time.sleep(0.05)
            if returncode is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=5.0)
                raise PreviewError(f"command lost its completion status: {command[0]}")
            stdout.seek(0)
            stderr.seek(0)
            return subprocess.CompletedProcess(
                normalized,
                returncode,
                stdout.read(),
                stderr.read(),
            )
    except (OSError, subprocess.SubprocessError) as error:
        raise PreviewError(f"command could not run: {command[0]}") from error


def safe_child_environment(*, home: Path | None = None) -> dict[str, str]:
    """Return the complete environment permitted at preview child boundaries.

    This is intentionally an allowlist rather than a denylist.  In particular,
    no credential, credential pointer, token, session, or provider-specific
    variable from the owner shell is inherited by candidate compilation or the
    production BEAM.
    """

    environment = {
        key: value
        for key, value in os.environ.items()
        if key in SAFE_CHILD_ENVIRONMENT and value
    }
    if home is not None:
        environment["HOME"] = str(home)
    environment.setdefault("PATH", os.defpath)
    environment.setdefault("SHELL", "/bin/sh")
    environment["PYTHONDONTWRITEBYTECODE"] = "1"
    return environment


def validated_child_environment(
    environment: Mapping[str, str] | None,
) -> dict[str, str]:
    """Return an explicit minimum child environment or fail closed.

    An omitted environment means the safe base allowlist, never parent
    inheritance. Explicit environments may add only the named non-secret
    preview paths and flags required by build, launch, or browser verification.
    """

    candidate = safe_child_environment() if environment is None else dict(environment)
    unexpected = set(candidate) - ALLOWED_CHILD_ENVIRONMENT
    if unexpected:
        raise PreviewError("child environment contains a forbidden variable")
    if not all(isinstance(key, str) and isinstance(value, str) for key, value in candidate.items()):
        raise PreviewError("child environment contains a non-string value")
    return candidate


def start_process(
    command: Sequence[str],
    *,
    cwd: Path,
    environment: Mapping[str, str] | None = None,
) -> subprocess.Popen[bytes]:
    """Start one bounded long-running child without parent-env inheritance."""

    return subprocess.Popen(
        [str(part) for part in command],
        cwd=cwd,
        env=validated_child_environment(environment),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )


def mise_environment_allowlist(names: Iterable[str]) -> list[str]:
    """Keep mise from reintroducing globally configured environment values."""

    return [f"--allow-env={name}" for name in sorted(set(names))]


def mise_exec_command(
    mise: str,
    environment_names: Iterable[str],
    command: Sequence[str],
) -> list[str]:
    """Build the only supported mise subprocess boundary."""

    return [
        mise,
        "exec",
        "-C",
        "elixir",
        *mise_environment_allowlist(environment_names),
        "--",
        *command,
    ]


def parse_version(value: str, label: str) -> tuple[int, ...]:
    match = re.search(r"(?:^|\s)v?([0-9]+(?:\.[0-9]+){1,3})(?:\s|$)", value)
    if match is None:
        raise PreviewBlocked(f"{label} returned an unrecognized version")
    return tuple(int(part) for part in match.group(1).split("."))


def command_version(command: str, arguments: Sequence[str]) -> str:
    executable = shutil.which(command)
    if executable is None:
        raise PreviewBlocked(f"required command is unavailable: {command}")
    result = run_command([executable, *arguments], cwd=repository_root(), timeout=20.0)
    if result.returncode != 0:
        raise PreviewBlocked(f"required command failed its version check: {command}")
    value = (result.stdout or result.stderr).decode("utf-8", errors="replace").strip()
    if not value:
        raise PreviewBlocked(f"required command returned no version: {command}")
    return value.splitlines()[0]


def normalized_platform() -> tuple[str, str]:
    operating_system = platform.system().lower()
    architecture = platform.machine().lower()
    architecture = {"amd64": "x86_64", "x64": "x86_64"}.get(
        architecture, architecture
    )
    return operating_system, architecture


def locked_platforms(root: Path) -> set[tuple[str, str]]:
    try:
        value = json.loads(read_bounded(root / "CODEX_LOCK.json").decode("utf-8"))
        rows = value["platforms"]
    except (KeyError, TypeError, ValueError, UnicodeDecodeError) as error:
        raise PreviewError("CODEX_LOCK.json is malformed") from error
    result: set[tuple[str, str]] = set()
    for row in rows:
        if not isinstance(row, dict):
            raise PreviewError("CODEX_LOCK.json contains an invalid platform row")
        operating_system = row.get("operatingSystem")
        architecture = row.get("architecture")
        if not isinstance(operating_system, str) or not isinstance(architecture, str):
            raise PreviewError("CODEX_LOCK.json contains an incomplete platform row")
        result.add((operating_system, architecture))
    if not result:
        raise PreviewError("CODEX_LOCK.json has no supported platform")
    return result


def validate_loopback_url(value: str) -> str:
    parsed = urlparse(value)
    if (
        parsed.scheme not in {"http", "https"}
        or parsed.username is not None
        or parsed.password is not None
        or parsed.hostname not in {"127.0.0.1", "localhost", "::1"}
        or parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
    ):
        raise PreviewError("preview URL must be an uncredentialed loopback HTTP URL")
    try:
        _port = parsed.port
    except ValueError as error:
        raise PreviewError("preview URL contains an invalid port") from error
    return value.rstrip("/")


def validate_workflow(path: Path) -> Path:
    expanded = Path(os.path.abspath(os.path.expanduser(str(path))))
    assert_no_symlink_components(expanded)
    canonical = expanded.resolve(strict=True)
    metadata = canonical.lstat()
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise PreviewBlocked("workflow is not a regular file")
    payload = read_bounded(canonical).decode("utf-8", errors="strict")
    host_matches = re.findall(r"(?m)^\s*host:\s*[\"']?([^\s\"']+)", payload)
    if host_matches and any(host not in {"127.0.0.1", "localhost", "::1"} for host in host_matches):
        raise PreviewBlocked("workflow does not bind the owner preview to loopback")
    return canonical


def discover_worktrees(root: Path) -> tuple[Path, ...]:
    result = run_command(
        ["git", "-c", "core.quotepath=false", "worktree", "list", "--porcelain"],
        cwd=root,
        timeout=30.0,
    )
    if result.returncode != 0:
        raise PreviewBlocked("Git worktree boundaries could not be discovered")
    worktrees: list[Path] = []
    for line in result.stdout.decode("utf-8", errors="strict").splitlines():
        if line.startswith("worktree "):
            worktrees.append(Path(line.removeprefix("worktree ")).resolve(strict=True))
    if not worktrees:
        raise PreviewBlocked("Git reported no worktree boundary")
    return tuple(worktrees)


def is_relative_to(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def assert_no_symlink_components(path: Path) -> None:
    current = Path(path.anchor)
    for component in path.parts[1:]:
        current = current / component
        try:
            metadata = current.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(metadata.st_mode):
            raise PreviewError("preview data path contains a symlink")


def validate_data_root(path: Path, root: Path, *, create: bool) -> Path:
    expanded = Path(os.path.abspath(os.path.expanduser(str(path))))
    if not expanded.is_absolute():
        raise PreviewError("preview data root must be absolute")
    assert_no_symlink_components(expanded)
    forbidden_shallow = {
        Path("/"),
        Path("/tmp"),
        Path("/var/tmp"),
        Path.home().resolve(strict=True),
    }
    if expanded in forbidden_shallow:
        raise PreviewError("preview data root is too broad")
    for worktree in discover_worktrees(root):
        if is_relative_to(expanded, worktree) or is_relative_to(worktree, expanded):
            raise PreviewError("preview data root intersects a Git worktree")
    if create:
        expanded.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(expanded, 0o700)
    try:
        canonical = expanded.resolve(strict=True)
    except FileNotFoundError as error:
        raise PreviewBlocked("preview data root does not exist") from error
    metadata = canonical.lstat()
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or stat.S_IMODE(metadata.st_mode) != 0o700
    ):
        raise PreviewError("preview data root must be an owner-owned mode-0700 directory")
    return canonical


def repository_identity(root: Path) -> str:
    upstream = read_bounded(root / "UPSTREAM_BASE", 1_024).strip()
    delta = read_bounded(root / "BUILD_WEEK_DELTA.md")
    return hashlib.sha256(upstream + b"\0" + delta).hexdigest()


def prepare_data_root(path: Path, root: Path) -> Path:
    canonical = validate_data_root(path, root, create=True)
    marker = canonical / MARKER_NAME
    expected = {
        "application": APP_MARKER,
        "repositoryIdentity": repository_identity(root),
        "schemaVersion": SCHEMA_VERSION,
    }
    if marker.exists():
        try:
            actual = json.loads(read_bounded(marker, 16 * 1024).decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as error:
            raise PreviewError("preview data-root marker is malformed") from error
        if actual != expected:
            raise PreviewError("preview data root belongs to a different repository or schema")
    else:
        write_private_json(marker, expected)
    for relative in ("evidence", "logs", "receipts"):
        child = canonical / relative
        child.mkdir(mode=0o700, exist_ok=True)
        os.chmod(child, 0o700)
    return canonical


def validate_protected_file(path: Path, root: Path, label: str) -> Path:
    expanded = Path(os.path.abspath(os.path.expanduser(str(path))))
    assert_no_symlink_components(expanded)
    try:
        canonical = expanded.resolve(strict=True)
    except FileNotFoundError as error:
        raise PreviewBlocked(f"{label} is unavailable") from error
    for worktree in discover_worktrees(root):
        if is_relative_to(canonical, worktree):
            raise PreviewError(f"{label} must remain outside every Git worktree")
    metadata = canonical.lstat()
    if (
        stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or stat.S_IMODE(metadata.st_mode) != 0o600
    ):
        raise PreviewError(f"{label} must be an owner-owned mode-0600 regular file")
    return canonical


def check_row(identifier: str, status: str, detail: str) -> dict[str, str]:
    return {"detail": detail, "id": identifier, "status": status}


def collect_preflight(
    root: Path,
    *,
    workflow: Path,
    base_url: str,
    require_browser: bool,
    require_live: bool,
    storage_state: Path | None,
) -> dict[str, Any]:
    checks: list[dict[str, str]] = []
    operating_system, architecture = normalized_platform()
    if (operating_system, architecture) in locked_platforms(root):
        checks.append(check_row("platform", "pass", f"{operating_system}/{architecture}"))
    else:
        checks.append(
            check_row("platform", "blocked", f"unverified {operating_system}/{architecture}")
        )
    if sys.version_info >= (3, 10):
        checks.append(check_row("python", "pass", platform.python_version()))
    else:
        checks.append(check_row("python", "blocked", platform.python_version()))
    for command, arguments in (("git", ("--version",)), ("mise", ("--version",))):
        try:
            checks.append(check_row(command, "pass", command_version(command, arguments)))
        except PreviewBlocked as error:
            checks.append(check_row(command, "blocked", str(error)))
    try:
        workflow_path = validate_workflow(workflow)
        checks.append(check_row("workflow", "pass", workflow_path.name))
    except PreviewError as error:
        checks.append(check_row("workflow", "blocked", str(error)))
    try:
        validate_loopback_url(base_url)
        checks.append(check_row("loopback_url", "pass", "loopback-only"))
    except PreviewError as error:
        checks.append(check_row("loopback_url", "blocked", str(error)))
    if require_live:
        expected = read_bounded(root / "CODEX_VERSION", 1_024).decode("ascii").strip()
        try:
            actual = command_version("codex", ("--version",))
            status = "pass" if actual == f"codex-cli {expected}" else "blocked"
            checks.append(check_row("codex", status, actual))
        except PreviewBlocked as error:
            checks.append(check_row("codex", "blocked", str(error)))
    if require_browser:
        node_executable = shutil.which("node")
        try:
            node = command_version("node", ("--version",))
            status = "pass" if parse_version(node, "Node.js") >= (18, 0, 0) else "blocked"
            checks.append(check_row("node", status, node))
        except PreviewError as error:
            checks.append(check_row("node", "blocked", str(error)))
        package = root / "tests/preview/browser/node_modules/@playwright/test/package.json"
        if package.is_file():
            checks.append(check_row("playwright_dependencies", "pass", "installed"))
            if node_executable is None:
                checks.append(
                    check_row("chromium", "blocked", "Node.js is unavailable")
                )
            else:
                browser_root = root / "tests/preview/browser"
                chromium = run_command(
                    [
                        node_executable,
                        "-e",
                        "process.stdout.write(require('playwright').chromium.executablePath())",
                    ],
                    cwd=browser_root,
                    environment=safe_child_environment(),
                    timeout=20.0,
                    max_output_bytes=16 * 1024,
                )
                chromium_path = Path(
                    chromium.stdout.decode("utf-8", errors="strict").strip()
                )
                if (
                    chromium.returncode == 0
                    and chromium_path.is_file()
                    and os.access(chromium_path, os.X_OK)
                ):
                    checks.append(check_row("chromium", "pass", "installed"))
                else:
                    checks.append(
                        check_row(
                            "chromium",
                            "blocked",
                            "run npm run install-browser in tests/preview/browser",
                        )
                    )
        else:
            checks.append(
                check_row(
                    "playwright_dependencies",
                    "blocked",
                    "run npm ci in tests/preview/browser",
                )
            )
        if storage_state is not None:
            checks.append(
                check_row(
                    "browser_storage_state",
                    "blocked",
                    "session material is not accepted by read-only preview verification",
                )
            )
    status = "pass" if all(row["status"] == "pass" for row in checks) else "blocked"
    return {"checks": checks, "schemaVersion": SCHEMA_VERSION, "status": status}


def default_data_root() -> Path:
    state_home = os.environ.get("XDG_STATE_HOME")
    if state_home:
        return Path(state_home) / "symphony-studio-preview"
    return Path.home() / ".local/state/symphony-studio-preview"


def emit(value: Mapping[str, Any], *, as_json: bool) -> None:
    if as_json:
        sys.stdout.buffer.write(canonical_json(dict(value)))
        return
    print(f"status: {value.get('status', 'unknown')}")
    for row in value.get("checks", []):
        print(f"{row['status']:>7}  {row['id']}: {row['detail']}")


def command_preflight(args: argparse.Namespace) -> int:
    root = repository_root()
    workflow = Path(args.workflow) if args.workflow else root / "elixir/WORKFLOW.md"
    storage = Path(args.storage_state) if args.storage_state else None
    report = collect_preflight(
        root,
        workflow=workflow,
        base_url=args.base_url,
        require_browser=args.browser,
        require_live=args.live,
        storage_state=storage,
    )
    emit(report, as_json=args.json)
    return PASS if report["status"] == "pass" else BLOCKED


def build_foundation(root: Path) -> None:
    mise = shutil.which("mise")
    if mise is None:
        raise PreviewBlocked("mise is required to build the preview runtime")
    environment = safe_child_environment()
    steps = (
        (["mix", "setup"], "preview dependency setup failed"),
        (["mix", "build"], "preview runtime build failed"),
    )
    for command, failure in steps:
        result = run_command(
            mise_exec_command(mise, BUILD_CHILD_ENVIRONMENT, command),
            cwd=root,
            environment=environment,
            timeout=900.0,
            max_output_bytes=32 * 1024 * 1024,
        )
        if result.returncode != 0:
            raise PreviewBlocked(failure)


def launch_command(root: Path, workflow: Path, data_root: Path, port: int) -> list[str]:
    mise = shutil.which("mise")
    if mise is None:
        raise PreviewBlocked("mise is required to launch Symphony Studio")
    runner = root / "elixir/bin/symphony"
    if not runner.is_file() or not os.access(runner, os.X_OK):
        raise PreviewBlocked("preview runtime is not built")
    return mise_exec_command(
        mise,
        RUNTIME_CHILD_ENVIRONMENT,
        [
            "./bin/symphony",
            "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
            "--logs-root",
            str(data_root / "logs"),
            "--port",
            str(port),
            str(workflow),
        ],
    )


def command_launch(args: argparse.Namespace) -> int:
    root = repository_root()
    workflow = validate_workflow(
        Path(args.workflow) if args.workflow else root / "elixir/WORKFLOW.md"
    )
    base_url = validate_loopback_url(f"http://127.0.0.1:{args.port}")
    report = collect_preflight(
        root,
        workflow=workflow,
        base_url=base_url,
        require_browser=False,
        require_live=args.live_preflight,
        storage_state=None,
    )
    if report["status"] != "pass":
        emit(report, as_json=args.json)
        return BLOCKED
    data_root = prepare_data_root(Path(args.data_root), root)
    runner = root / "elixir/bin/symphony"
    if args.no_build:
        if not runner.is_file() or not os.access(runner, os.X_OK):
            raise PreviewBlocked("preview runtime is not built")
    else:
        build_foundation(root)
    command = launch_command(root, workflow, data_root, args.port)
    if args.dry_run:
        value = {
            "checks": [
                check_row("launch_plan", "pass", "validated production runtime command")
            ],
            "schemaVersion": SCHEMA_VERSION,
            "status": "pass",
            "url": base_url,
        }
        emit(value, as_json=args.json)
        return PASS
    print(f"Symphony Studio owner preview: {base_url}", flush=True)
    environment = safe_child_environment()
    environment["SYMPHONY_STUDIO_DATA_ROOT"] = str(data_root)
    os.execvpe(command[0], command, validated_child_environment(environment))
    raise AssertionError("exec returned unexpectedly")


def validate_issue_identifier(value: str) -> str:
    normalized = value.strip().upper()
    if normalized in FORBIDDEN_FIXTURE_ISSUES:
        raise PreviewError("protected R0 fixture issues can never be reset or reused")
    if ISSUE_IDENTIFIER.fullmatch(normalized) is None:
        raise PreviewError("demo issue identifier has an invalid shape")
    return normalized


def validate_intent_id(value: str) -> str:
    normalized = value.strip()
    if INTENT_ID.fullmatch(normalized) is None:
        raise PreviewError("intent id must be the exact persisted intent_ identifier")
    return normalized


def validate_private_directory(path: Path, data_root: Path, label: str) -> Path:
    assert_no_symlink_components(path)
    try:
        canonical = path.resolve(strict=True)
    except FileNotFoundError as error:
        raise PreviewBlocked(f"{label} is unavailable") from error
    metadata = canonical.lstat()
    if (
        not is_relative_to(canonical, data_root)
        or stat.S_ISLNK(metadata.st_mode)
        or not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or stat.S_IMODE(metadata.st_mode) != 0o700
    ):
        raise PreviewError(f"{label} must be contained, owner-owned, and mode 0700")
    return canonical


def bounded_private_file_inventory(
    directory: Path,
    data_root: Path,
    label: str,
    *,
    limit: int = MAX_RESET_DIRECTORY_ENTRIES,
) -> tuple[Path, ...]:
    canonical = validate_private_directory(directory, data_root, label)
    files: list[Path] = []
    try:
        with os.scandir(canonical) as entries:
            for entry in entries:
                if len(files) >= limit:
                    raise PreviewError(f"{label} exceeds its entry bound")
                metadata = entry.stat(follow_symlinks=False)
                if (
                    stat.S_ISLNK(metadata.st_mode)
                    or not stat.S_ISREG(metadata.st_mode)
                    or metadata.st_uid != os.getuid()
                    or stat.S_IMODE(metadata.st_mode) != 0o600
                ):
                    raise PreviewError(
                        f"{label} contains a non-private regular-file entry"
                    )
                path = Path(entry.path)
                if not is_relative_to(path, canonical):
                    raise PreviewError(f"{label} contains an escaping entry")
                files.append(path)
    except OSError as error:
        raise PreviewError(f"{label} could not be inventoried safely") from error
    return tuple(sorted(files, key=lambda path: path.name))


def read_json_object(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(read_bounded(path).decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as error:
        raise PreviewError(f"{label} is malformed") from error
    if not isinstance(value, dict):
        raise PreviewError(f"{label} is not a JSON object")
    return value


def validate_intent_document(path: Path) -> dict[str, Any]:
    match = re.fullmatch(r"(intent_[0-9a-f]{24})\.json", path.name)
    if match is None:
        raise PreviewError("Intent Store contains an unexpected document name")
    value = read_json_object(path, "Intent Store document")
    if value.get("schema_version") != SCHEMA_VERSION or value.get("intent_id") != match[1]:
        raise PreviewError("Intent Store document identity is invalid")
    start = value.get("start")
    publication = value.get("publication")
    if not isinstance(start, dict) or not isinstance(publication, dict):
        raise PreviewError("Intent Store document lifecycle is invalid")
    tasks = publication.get("tasks")
    if not isinstance(tasks, dict):
        raise PreviewError("Intent Store publication task map is invalid")
    for task_id, task in tasks.items():
        if not isinstance(task_id, str) or not isinstance(task, dict):
            raise PreviewError("Intent Store publication task entry is invalid")
        identifier = task.get("issue_identifier")
        if identifier in FORBIDDEN_FIXTURE_ISSUES:
            raise PreviewError("Intent Store document references a protected R0 fixture")
    return value


def reset_intent_target(
    data_root: Path, intent_id: str, issue_identifier: str
) -> tuple[Path, dict[str, Any]]:
    intent_root = validate_private_directory(
        data_root / "intent", data_root, "Intent Store root"
    )
    intent_directory = validate_private_directory(
        intent_root / "intents", data_root, "Intent Store intents directory"
    )
    documents = [
        (path, validate_intent_document(path))
        for path in bounded_private_file_inventory(
            intent_directory, data_root, "Intent Store intents directory"
        )
    ]
    by_id = [(path, value) for path, value in documents if value["intent_id"] == intent_id]
    by_issue = [
        (path, value)
        for path, value in documents
        if value["start"].get("issue_identifier") == issue_identifier
    ]
    if len(by_id) != 1:
        raise PreviewError("reset requires exactly one persisted matching intent id")
    if len(by_issue) != 1 or by_issue[0][0] != by_id[0][0]:
        raise PreviewError("reset issue and intent id do not identify one unique record")

    path, value = by_id[0]
    start = value["start"]
    tasks = value["publication"]["tasks"]
    matching_tasks = [
        (task_id, task)
        for task_id, task in tasks.items()
        if task.get("issue_identifier") == issue_identifier
    ]
    if len(matching_tasks) != 1:
        raise PreviewError("reset issue does not identify one unique published task")
    task_id, task = matching_tasks[0]
    if (
        start.get("task_id") != task_id
        or start.get("issue_id") != task.get("issue_id")
        or task.get("status") != "confirmed"
        or start.get("status")
        not in {"waiting_for_admission", "admitted", "blocked", "uncertain"}
    ):
        raise PreviewError("reset target lacks an exact persisted start/task binding")
    admission = value.get("admission")
    if admission is not None and (
        not isinstance(admission, dict)
        or admission.get("issue_id") != start.get("issue_id")
    ):
        raise PreviewError("reset target admission binding is invalid")
    return path, value


def reset_receipt_targets(
    data_root: Path, intent_id: str, issue_identifier: str
) -> tuple[tuple[Path, ...], Path]:
    receipt_directory = validate_private_directory(
        data_root / "receipts", data_root, "preview receipt directory"
    )
    filename = f"reset-{issue_identifier.lower()}-{intent_id}.json"
    final_path = receipt_directory / filename
    matching: list[Path] = []
    issue_prefix = f"reset-{issue_identifier.lower()}-"
    for path in bounded_private_file_inventory(
        receipt_directory, data_root, "preview receipt directory"
    ):
        if not path.name.startswith(issue_prefix):
            continue
        if path.name != filename:
            raise PreviewError("reset receipt identity is ambiguous")
        value = read_json_object(path, "reset receipt")
        if (
            value.get("schemaVersion") != SCHEMA_VERSION
            or value.get("action") != "preview_reset"
            or value.get("issueIdentifier") != issue_identifier
            or value.get("intentId") != intent_id
            or value.get("linearMutations") != 0
        ):
            raise PreviewError("existing reset receipt binding is invalid")
        matching.append(path)
    if len(matching) > 1:
        raise PreviewError("reset receipt identity is ambiguous")
    return tuple(matching), final_path


def quarantine_reset_targets(data_root: Path, targets: Sequence[Path]) -> Path:
    quarantine = Path(tempfile.mkdtemp(prefix=".reset-quarantine-", dir=data_root))
    os.chmod(quarantine, 0o700)
    moved: list[tuple[Path, Path]] = []
    try:
        for index, source in enumerate(targets):
            destination = quarantine / f"record-{index:04d}"
            os.replace(source, destination)
            moved.append((source, destination))
        return quarantine
    except OSError as error:
        for source, destination in reversed(moved):
            try:
                os.replace(destination, source)
            except OSError:
                pass
        try:
            quarantine.rmdir()
        except OSError:
            pass
        raise PreviewError("local reset could not quarantine its exact target set") from error


def remove_quarantine(quarantine: Path) -> None:
    try:
        with os.scandir(quarantine) as entries:
            paths: list[Path] = []
            for entry in entries:
                if len(paths) >= MAX_RESET_DIRECTORY_ENTRIES:
                    raise PreviewError("reset quarantine exceeds its entry bound")
                metadata = entry.stat(follow_symlinks=False)
                if (
                    stat.S_ISLNK(metadata.st_mode)
                    or not stat.S_ISREG(metadata.st_mode)
                    or metadata.st_uid != os.getuid()
                    or stat.S_IMODE(metadata.st_mode) != 0o600
                ):
                    raise PreviewError("reset quarantine contains an invalid entry")
                paths.append(Path(entry.path))
        for path in paths:
            path.unlink()
        quarantine.rmdir()
    except OSError as error:
        raise PreviewError("reset quarantine cleanup failed") from error


def validate_reset_receipt(value: Any, issue_identifier: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise PreviewError("local reset produced a non-object receipt")
    expected_keys = {
        "action",
        "issueIdentifier",
        "linearMutations",
        "localRecordsRemoved",
        "schemaVersion",
        "status",
    }
    if set(value) != expected_keys:
        raise PreviewError("local reset receipt has unexpected or missing fields")
    if (
        value["schemaVersion"] != SCHEMA_VERSION
        or value["action"] != "preview_reset"
        or value["status"] != "reset"
        or value["issueIdentifier"] != issue_identifier
        or value["linearMutations"] != 0
        or type(value["localRecordsRemoved"]) is not int
        or value["localRecordsRemoved"] < 0
    ):
        raise PreviewError("local reset receipt violates the local-only contract")
    return dict(value)


def command_reset(args: argparse.Namespace) -> int:
    root = repository_root()
    issue_identifier = validate_issue_identifier(args.issue)
    intent_id = validate_intent_id(args.intent_id)
    data_root = validate_data_root(Path(args.data_root), root, create=False)
    marker = data_root / MARKER_NAME
    try:
        marker_value = json.loads(read_bounded(marker, 16 * 1024).decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as error:
        raise PreviewError("preview data-root marker is malformed") from error
    if marker_value != {
        "application": APP_MARKER,
        "repositoryIdentity": repository_identity(root),
        "schemaVersion": SCHEMA_VERSION,
    }:
        raise PreviewError("reset target is not a Symphony Studio preview data root")
    intent_path, _document = reset_intent_target(data_root, intent_id, issue_identifier)
    prior_receipts, receipt_path = reset_receipt_targets(
        data_root, intent_id, issue_identifier
    )
    targets = (intent_path, *prior_receipts)
    if args.dry_run:
        emit(
            {
                "checks": [
                    check_row("reset_boundary", "pass", "local-only target validated"),
                    check_row("fixture_guard", "pass", "SYM-1 and SYM-2 excluded"),
                    check_row("intent_binding", "pass", "exact persisted intent and issue"),
                    check_row("linear_mutations", "pass", "zero by construction"),
                ],
                "schemaVersion": SCHEMA_VERSION,
                "status": "pass",
            },
            as_json=args.json,
        )
        return PASS

    quarantine = quarantine_reset_targets(data_root, targets)
    receipt = validate_reset_receipt(
        {
            "action": "preview_reset",
            "issueIdentifier": issue_identifier,
            "linearMutations": 0,
            "localRecordsRemoved": len(targets),
            "schemaVersion": SCHEMA_VERSION,
            "status": "reset",
        },
        issue_identifier,
    )
    receipt["intentId"] = intent_id
    receipt["recordedAt"] = int(time.time())
    try:
        write_private_json(receipt_path, receipt)
    except OSError as error:
        try:
            receipt_path.unlink()
        except FileNotFoundError:
            pass
        for index, source in reversed(list(enumerate(targets))):
            try:
                os.replace(quarantine / f"record-{index:04d}", source)
            except OSError:
                pass
        try:
            quarantine.rmdir()
        except OSError:
            pass
        raise PreviewError("local reset receipt could not be published") from error
    remove_quarantine(quarantine)
    emit(
        {
            "checks": [
                check_row("reset", "pass", "local state reset confirmed"),
                check_row("linear_mutations", "pass", "zero"),
            ],
            "schemaVersion": SCHEMA_VERSION,
            "status": "pass",
        },
        as_json=args.json,
    )
    return PASS


def discover_audit_files(root: Path) -> tuple[Path, ...]:
    git_marker = root / ".git"
    if git_marker.exists():
        result = run_command(
            [
                "git",
                "-c",
                "core.quotepath=false",
                "ls-files",
                "--cached",
                "--others",
                "--exclude-standard",
                "-z",
            ],
            cwd=root,
            timeout=60.0,
            max_output_bytes=32 * 1024 * 1024,
        )
        if result.returncode != 0:
            raise PreviewError("public-artifact inventory failed")
        relatives = [Path(item.decode("utf-8")) for item in result.stdout.split(b"\0") if item]
        files = tuple(
            root / relative
            for relative in relatives
            if not AUDIT_EXCLUDED_PARTS.intersection(relative.parts)
        )
    else:
        files = tuple(
            path
            for path in root.rglob("*")
            if path.is_file()
            and not AUDIT_EXCLUDED_PARTS.intersection(path.relative_to(root).parts)
        )
    if not files:
        raise PreviewError("public-artifact audit discovered zero files")
    return tuple(sorted(files))


def audit_files(root: Path, files: Iterable[Path]) -> dict[str, Any]:
    findings: list[dict[str, str]] = []
    scanned = 0
    for path in files:
        try:
            relative = path.relative_to(root).as_posix()
        except ValueError as error:
            raise PreviewError("audit input escaped its root") from error
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            findings.append({"kind": "symlink", "path": relative})
            continue
        if not stat.S_ISREG(metadata.st_mode):
            continue
        scanned += 1
        name = path.name.lower()
        suffix = path.suffix.lower()
        if name in SENSITIVE_FILENAMES or name.startswith(".env."):
            findings.append({"kind": "sensitive filename", "path": relative})
        if metadata.st_size > MAX_AUDIT_FILE_BYTES:
            findings.append({"kind": "unbounded file", "path": relative})
            continue
        payload = read_bounded(path, MAX_AUDIT_FILE_BYTES)
        if suffix in MEDIA_EXTENSIONS:
            allowed_digest = ALLOWED_UPSTREAM_MEDIA_SHA256.get(relative)
            actual_digest = hashlib.sha256(payload).hexdigest()
            if actual_digest != allowed_digest:
                findings.append({"kind": "submission media", "path": relative})
        for label, pattern in CONTENT_SECRET_PATTERNS:
            if pattern.search(payload):
                findings.append({"kind": label, "path": relative})
    return {
        "findings": findings,
        "filesScanned": scanned,
        "schemaVersion": SCHEMA_VERSION,
        "status": "pass" if scanned > 0 and not findings else "failed",
    }


def command_audit(args: argparse.Namespace) -> int:
    root = Path(args.root).resolve(strict=True) if args.root else repository_root()
    report = audit_files(root, discover_audit_files(root))
    emit(
        {
            "checks": [
                check_row("files_scanned", "pass", str(report["filesScanned"])),
                check_row(
                    "public_artifacts",
                    report["status"],
                    "no findings" if not report["findings"] else f"{len(report['findings'])} finding(s)",
                ),
            ],
            **report,
        },
        as_json=args.json,
    )
    return PASS if report["status"] == "pass" else FAIL


def safe_extract_tar(archive: Path, destination: Path) -> None:
    archive_metadata = archive.lstat()
    if (
        not stat.S_ISREG(archive_metadata.st_mode)
        or archive_metadata.st_size > MAX_ARCHIVE_BYTES
    ):
        raise PreviewError("clean-launch archive violates its byte bound")
    destination = destination.resolve(strict=True)
    directory_modes: list[tuple[Path, int]] = []
    with tarfile.open(archive, "r:*") as bundle:
        count = 0
        extracted_bytes = 0
        for member in bundle:
            count += 1
            if count > MAX_ARCHIVE_MEMBERS:
                raise PreviewError("clean-launch archive exceeds its member bound")
            if not member.isfile() and not member.isdir():
                raise PreviewError("clean-launch archive contains a link or special file")
            if member.size < 0 or member.size > MAX_AUDIT_FILE_BYTES:
                raise PreviewError("clean-launch archive member exceeds its byte bound")
            extracted_bytes += member.size
            if extracted_bytes > MAX_EXTRACTED_BYTES:
                raise PreviewError("clean-launch archive exceeds its extracted byte bound")
            target = (destination / member.name).resolve()
            if not is_relative_to(target, destination):
                raise PreviewError("clean-launch archive contains path traversal")
            mode = member.mode & 0o777
            if member.isdir():
                target.mkdir(mode=0o700, parents=True, exist_ok=True)
                if not target.is_dir():
                    raise PreviewError("clean-launch archive has conflicting members")
                directory_modes.append((target, mode))
                continue
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            stream = bundle.extractfile(member)
            if stream is None:
                raise PreviewError("clean-launch archive file could not be read")
            descriptor = os.open(
                target,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
                0o600,
            )
            written = 0
            try:
                with os.fdopen(descriptor, "wb", closefd=True) as output:
                    while written < member.size:
                        chunk = stream.read(min(1024 * 1024, member.size - written))
                        if not chunk:
                            break
                        output.write(chunk)
                        written += len(chunk)
                    output.flush()
                    os.fsync(output.fileno())
                if written != member.size or stream.read(1):
                    raise PreviewError("clean-launch archive member size is inconsistent")
                os.chmod(target, mode)
            except BaseException:
                target.unlink(missing_ok=True)
                raise
        if count == 0:
            raise PreviewError("clean-launch archive is empty")
    for directory, mode in sorted(
        directory_modes, key=lambda row: len(row[0].parts), reverse=True
    ):
        os.chmod(directory, mode)


def clean_launch_workflow(workspace_root: Path) -> str:
    quoted_root = json.dumps(str(workspace_root))
    return f"""---
tracker:
  kind: memory
  project_slug: "preview-clean-launch"
  required_labels: []
  active_states: ["Todo", "In Progress"]
  terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
polling:
  interval_ms: 30000
workspace:
  root: {quoted_root}
agent:
  max_concurrent_agents: 1
  max_turns: 1
codex:
  command: "codex app-server"
  approval_policy: never
  thread_sandbox: "read-only"
server:
  host: "127.0.0.1"
---
Clean-launch verification uses an empty in-memory tracker and starts no model turn.
"""


def choose_loopback_port() -> int:
    import socket

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


def wait_for_http(url: str, process: subprocess.Popen[bytes], timeout: float) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise PreviewBlocked("clean-launch runtime exited before becoming ready")
        try:
            request = Request(url, headers={"Accept": "application/json"})
            with urlopen(request, timeout=2.0) as response:
                if response.status != 200:
                    raise PreviewBlocked("clean-launch endpoint returned a non-success status")
                payload = response.read(MAX_DRIVER_OUTPUT_BYTES + 1)
                if len(payload) > MAX_DRIVER_OUTPUT_BYTES:
                    raise PreviewError("clean-launch endpoint exceeded its byte bound")
                value = json.loads(payload.decode("utf-8"))
                if not isinstance(value, dict):
                    raise PreviewError("clean-launch endpoint returned a non-object")
                return value
        except (HTTPError, URLError, TimeoutError, OSError, json.JSONDecodeError):
            time.sleep(0.2)
    raise PreviewBlocked("clean-launch endpoint did not become ready before its deadline")


def terminate_process(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=10.0)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5.0)


def command_clean_launch(args: argparse.Namespace) -> int:
    root = repository_root()
    if not args.execute:
        emit(
            {
                "checks": [
                    check_row("platform", "pass", "/".join(normalized_platform())),
                    check_row("source_isolation", "pass", "Git archive to private temporary root"),
                    check_row("tracker", "pass", "empty memory tracker; zero external mutation"),
                    check_row("execution", "blocked", "rerun with --execute"),
                ],
                "schemaVersion": SCHEMA_VERSION,
                "status": "blocked",
            },
            as_json=args.json,
        )
        return BLOCKED
    with tempfile.TemporaryDirectory(prefix="symphony-preview-clean-launch-") as temporary:
        temporary_root = Path(temporary)
        os.chmod(temporary_root, 0o700)
        archive = temporary_root / "source.tar"
        source = temporary_root / "source"
        source.mkdir(mode=0o700)
        archive_result = run_command(
            ["git", "archive", "--format=tar", "HEAD", "-o", str(archive)],
            cwd=root,
            timeout=120.0,
        )
        if archive_result.returncode != 0:
            raise PreviewBlocked("clean-launch source archive failed")
        safe_extract_tar(archive, source)
        audit = audit_files(source, discover_audit_files(source))
        if audit["status"] != "pass":
            raise PreviewBlocked("clean-launch source failed the public-artifact audit")
        home = temporary_root / "home"
        logs = temporary_root / "logs"
        workspaces = temporary_root / "workspaces"
        for directory in (home, logs, workspaces):
            directory.mkdir(mode=0o700)
        workflow = temporary_root / "WORKFLOW.md"
        descriptor = os.open(workflow, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(clean_launch_workflow(workspaces))
        environment = safe_child_environment(home=home)
        environment["MIX_ENV"] = "dev"
        mise = shutil.which("mise")
        if mise is None:
            raise PreviewBlocked("mise is unavailable for clean launch")
        # HOME is intentionally isolated so the child cannot read owner credentials.
        # Point mise only at its public tool installation; do not expose its config.
        mise_data = Path.home() / ".local/share/mise"
        if not mise_data.is_dir():
            raise PreviewBlocked("mise tool installation is unavailable for clean launch")
        environment["MISE_DATA_DIR"] = str(mise_data)
        for command in (("mix", "setup"), ("mix", "build")):
            result = run_command(
                mise_exec_command(mise, CLEAN_LAUNCH_CHILD_ENVIRONMENT, command),
                cwd=source,
                environment=environment,
                timeout=args.build_timeout,
                max_output_bytes=32 * 1024 * 1024,
            )
            if result.returncode != 0:
                raise PreviewBlocked(f"clean-launch {' '.join(command)} failed")
        port = choose_loopback_port()
        command = mise_exec_command(
            mise,
            CLEAN_LAUNCH_CHILD_ENVIRONMENT,
            [
                "./bin/symphony",
                "--i-understand-that-this-will-be-running-without-the-usual-guardrails",
                "--logs-root",
                str(logs),
                "--port",
                str(port),
                str(workflow),
            ],
        )
        process = start_process(
            command,
            cwd=source,
            environment=environment,
        )
        try:
            state = wait_for_http(
                f"http://127.0.0.1:{port}/api/v1/state", process, args.start_timeout
            )
            if not state:
                raise PreviewError("clean-launch state response was empty")
        finally:
            terminate_process(process)
        emit(
            {
                "checks": [
                    check_row("source_audit", "pass", f"{audit['filesScanned']} files"),
                    check_row("build", "pass", "clean source build"),
                    check_row("launch", "pass", "loopback HTTP state responded"),
                    check_row("external_mutation", "pass", "empty memory tracker"),
                ],
                "schemaVersion": SCHEMA_VERSION,
                "status": "pass",
            },
            as_json=args.json,
        )
        return PASS


def command_verify(args: argparse.Namespace) -> int:
    root = repository_root()
    base_url = validate_loopback_url(args.base_url)
    if args.storage_state:
        raise PreviewBlocked(
            "browser session material is not accepted by read-only preview verification"
        )
    if args.live_write:
        raise PreviewBlocked(
            "live browser write verification requires a trusted out-of-process preview-write broker"
        )
    artifact_root = prepare_data_root(Path(args.data_root), root) / "evidence"
    browser_root = root / "tests/preview/browser"
    package = browser_root / "node_modules/@playwright/test/package.json"
    if not package.is_file():
        raise PreviewBlocked("browser dependencies are unavailable; run npm ci first")
    driver_home = artifact_root.parent / "browser-home"
    driver_home.mkdir(mode=0o700, exist_ok=True)
    os.chmod(driver_home, 0o700)
    environment = safe_child_environment(home=driver_home)
    environment.update(
        {
            "SYMPHONY_PREVIEW_ARTIFACT_ROOT": str(artifact_root),
            "SYMPHONY_PREVIEW_BASE_URL": base_url,
            "SYMPHONY_PREVIEW_LIVE_WRITE": "1" if args.live_write else "0",
        }
    )
    command = [
        shutil.which("npm") or "npm",
        "exec",
        "--",
        "playwright",
        "test",
        "--workers=1",
        "--retries=0",
    ]
    if args.grep:
        command.extend(("--grep", args.grep))
    summary_path = artifact_root / "playwright-summary.json"
    summary_path.unlink(missing_ok=True)
    result = run_command(
        command,
        cwd=browser_root,
        environment=environment,
        timeout=args.timeout,
        max_output_bytes=32 * 1024 * 1024,
    )
    if not summary_path.is_file():
        raise PreviewError("Playwright did not publish its required summary")
    try:
        summary = json.loads(read_bounded(summary_path, 2 * 1024 * 1024).decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as error:
        raise PreviewError("Playwright summary is malformed") from error
    blocked = summary.get("blocked", 0)
    passed = summary.get("passed", 0)
    failed = summary.get("failed", 0)
    if (
        summary.get("schemaVersion") != SCHEMA_VERSION
        or type(blocked) is not int
        or type(passed) is not int
        or type(failed) is not int
        or min(blocked, passed, failed) < 0
        or not isinstance(summary.get("cases"), list)
        or blocked + passed + failed != len(summary["cases"])
    ):
        raise PreviewError("Playwright summary violates its schema")
    if result.returncode != 0 or failed:
        status = "failed"
        exit_code = FAIL
    elif blocked:
        status = "blocked"
        exit_code = BLOCKED
    elif passed <= 0:
        raise PreviewError("Playwright reported zero passing cases")
    else:
        status = "pass"
        exit_code = PASS
    emit(
        {
            "checks": [
                check_row("playwright_passed", "pass" if passed else "blocked", str(passed)),
                check_row("playwright_blocked", "pass" if not blocked else "blocked", str(blocked)),
                check_row("playwright_failed", "pass" if not failed else "failed", str(failed)),
            ],
            "schemaVersion": SCHEMA_VERSION,
            "status": status,
        },
        as_json=args.json,
    )
    return exit_code


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    subparsers = result.add_subparsers(dest="command", required=True)

    preflight = subparsers.add_parser("preflight", help="verify owner and browser prerequisites")
    preflight.add_argument("--workflow")
    preflight.add_argument("--base-url", default="http://127.0.0.1:4000")
    preflight.add_argument("--storage-state")
    preflight.add_argument("--browser", action="store_true")
    preflight.add_argument("--live", action="store_true")
    preflight.add_argument("--json", action="store_true")
    preflight.set_defaults(function=command_preflight)

    launch = subparsers.add_parser("launch", help="build and launch the owner preview on loopback")
    launch.add_argument("--workflow")
    launch.add_argument("--data-root", default=str(default_data_root()))
    launch.add_argument("--port", type=int, default=4000, choices=range(1024, 65536))
    launch.add_argument("--no-build", action="store_true")
    launch.add_argument("--live-preflight", action="store_true")
    launch.add_argument("--dry-run", action="store_true")
    launch.add_argument("--json", action="store_true")
    launch.set_defaults(function=command_launch)

    reset = subparsers.add_parser("reset", help="reset one exact local demo intent")
    reset.add_argument("--data-root", default=str(default_data_root()))
    reset.add_argument("--issue", required=True)
    reset.add_argument("--intent-id", required=True)
    reset.add_argument("--dry-run", action="store_true")
    reset.add_argument("--json", action="store_true")
    reset.set_defaults(function=command_reset)

    audit = subparsers.add_parser("audit", help="scan public source/artifacts for secrets and media")
    audit.add_argument("--root")
    audit.add_argument("--json", action="store_true")
    audit.set_defaults(function=command_audit)

    clean_launch = subparsers.add_parser(
        "clean-launch", help="build and launch an exact committed source archive hermetically"
    )
    clean_launch.add_argument("--execute", action="store_true")
    clean_launch.add_argument("--build-timeout", type=float, default=900.0)
    clean_launch.add_argument("--start-timeout", type=float, default=60.0)
    clean_launch.add_argument("--json", action="store_true")
    clean_launch.set_defaults(function=command_clean_launch)

    verify = subparsers.add_parser("verify", help="run the authoritative Playwright preview suite")
    verify.add_argument("--base-url", default="http://127.0.0.1:4000")
    verify.add_argument("--data-root", default=str(default_data_root()))
    verify.add_argument("--storage-state")
    verify.add_argument("--live-write", action="store_true")
    verify.add_argument("--live-write-ack")
    verify.add_argument("--grep")
    verify.add_argument("--timeout", type=float, default=3_600.0)
    verify.add_argument("--json", action="store_true")
    verify.set_defaults(function=command_verify)
    return result


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        return int(args.function(args))
    except PreviewError as error:
        sys.stderr.write(f"preview-{error.status}: {error}\n")
        return error.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
