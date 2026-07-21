#!/usr/bin/env python3
# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import struct
import tarfile
import tempfile
import unittest
from unittest import mock
import zipfile


MODULE_PATH = Path(__file__).with_name("release.py")
SPEC = importlib.util.spec_from_file_location("studio_release", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


HEAD = "1" * 40
BASE = "2" * 40
TREE = "3" * 40
SHA = "a" * 64


class ReleaseToolTest(unittest.TestCase):
    def test_canonical_json_is_stable_and_newline_terminated(self) -> None:
        self.assertEqual(release.canonical_json_bytes({"b": 2, "a": 1}), b'{"a":1,"b":2}\n')

    def test_generated_artifacts_cannot_enter_checkout(self) -> None:
        with self.assertRaisesRegex(release.ReleaseError, "outside_checkout"):
            release.external_path(str(release.ROOT / "candidate.json"))

    def test_fixed_release_build_root_is_exclusive_and_removed(self) -> None:
        root = Path("/tmp") / f"symphony-release-test-{os.getpid()}-{id(self)}"
        self.assertFalse(root.exists())
        with mock.patch.object(release, "FIXED_RELEASE_BUILD_ROOT", root):
            with release.fixed_release_build_root() as observed:
                self.assertEqual(observed, root)
                self.assertEqual(observed.stat().st_mode & 0o777, 0o700)
            self.assertFalse(root.exists())
            root.mkdir(mode=0o700)
            try:
                with self.assertRaisesRegex(release.ReleaseError, "build_root_busy"):
                    with release.fixed_release_build_root():
                        pass
            finally:
                root.rmdir()

    def test_evidence_is_exact_head_tree_and_pass_bound(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "review.json"
            record = {
                "blockingFindings": [],
                "completedAt": "2026-07-21T11:00:00Z",
                "evidenceSha256": SHA,
                "exactHead": HEAD,
                "exactTree": TREE,
                "kind": "independent-review",
                "role": "release-security",
                "verdict": "GO",
            }
            release.atomic_write(path, release.canonical_json_bytes(record))
            observed = release.evidence_record(path, HEAD, TREE, "independent-review")
            self.assertEqual(observed["record"], record)
            self.assertRegex(observed["sha256"], r"^[0-9a-f]{64}$")
            with self.assertRaisesRegex(release.ReleaseError, "stale_evidence"):
                release.evidence_record(path, BASE, TREE, "independent-review")

    def test_safe_build_environment_drops_credential_shaped_names(self) -> None:
        manifest = {
            "codex": {"artifactBundleSha256": SHA},
            "sourceDateEpoch": 1,
            "upstreamBaseSha": BASE,
        }
        original = dict(os.environ)
        try:
            os.environ["LINEAR_API_KEY"] = "never-copy"
            os.environ["GITHUB_TOKEN"] = "never-copy"
            os.environ["PATH"] = original.get("PATH", "/usr/bin")
            with tempfile.TemporaryDirectory() as temporary:
                env = release.safe_build_environment(Path(temporary), manifest, HEAD)
            self.assertNotIn("LINEAR_API_KEY", env)
            self.assertNotIn("GITHUB_TOKEN", env)
            self.assertEqual(env["SYMPHONY_BUILD_COMMIT"], HEAD)
        finally:
            os.environ.clear()
            os.environ.update(original)

    def test_clean_install_codex_accepts_exact_nested_and_hoisted_native_layouts(
        self,
    ) -> None:
        for layout in ("nested", "hoisted"):
            with self.subTest(layout=layout), tempfile.TemporaryDirectory() as temporary:
                prefix = Path(temporary)
                package_root = prefix / "node_modules/@openai/codex"
                launcher = package_root / "bin/codex.js"
                launcher.parent.mkdir(parents=True)
                launcher.write_bytes(b"launcher")
                if layout == "nested":
                    native = (
                        package_root
                        / "node_modules/@openai/codex-linux-x64/vendor/test-target/bin/codex"
                    )
                else:
                    native = (
                        package_root.parent
                        / "codex-linux-x64/vendor/test-target/bin/codex"
                    )
                native.parent.mkdir(parents=True)
                native.write_bytes(b"native")
                lock = {
                    "platforms": [
                        {
                            "architecture": "x86_64",
                            "installedPackageAlias": "@openai/codex-linux-x64",
                            "launcherSha256": release.sha256_file(launcher),
                            "nativeSha256": release.sha256_file(native),
                            "operatingSystem": "linux",
                            "target": "test-target",
                        }
                    ],
                    "version": "0.144.3",
                    "versionOutput": "codex-cli 0.144.3",
                }
                with (
                    mock.patch.object(
                        release, "git_bytes", return_value=json.dumps(lock).encode()
                    ),
                    mock.patch.object(release.shutil, "which", return_value=str(launcher)),
                    mock.patch.object(
                        release,
                        "run",
                        return_value=mock.Mock(
                            returncode=0,
                            stderr="",
                            stdout="codex-cli 0.144.3\n",
                        ),
                    ),
                ):
                    observed = release.verify_installed_codex_compatibility(HEAD)
                self.assertEqual(observed["nativeSha256"], release.sha256_file(native))

    def test_dependency_build_patch_is_exact_hash_and_occurrence_bound(self) -> None:
        original = b"before map iteration\n"
        patched = b"after sorted iteration\n"
        patch = {
            "dependency": "example",
            "version": "1.0.0",
            "path": "lib/example.ex",
            "originalSha256": release.sha256_bytes(original),
            "patchedSha256": release.sha256_bytes(patched),
            "purpose": "test deterministic compile order",
            "replacements": ((original, patched),),
        }
        with tempfile.TemporaryDirectory() as temporary:
            deps_root = Path(temporary) / "non-default-mix-deps"
            lock_path = Path(temporary) / "mix.lock"
            lock_path.write_text(
                '%{\n  "example": {:hex, :example, "1.0.0", "'
                + "a" * 64
                + '", [:mix], [], "hexpm", "'
                + "b" * 64
                + '"}\n}\n',
                encoding="utf-8",
            )
            source = deps_root / "example/lib/example.ex"
            source.parent.mkdir(parents=True)
            source.write_bytes(original)
            records = release.apply_dependency_build_patches(deps_root, lock_path, (patch,))
            self.assertEqual(source.read_bytes(), patched)
            self.assertEqual(records, release.dependency_build_patch_records((patch,)))
            source.write_bytes(original + original)
            patch["originalSha256"] = release.sha256_file(source)
            with self.assertRaisesRegex(release.ReleaseError, "match_count_invalid"):
                release.apply_dependency_build_patches(deps_root, lock_path, (patch,))
            link = Path(temporary) / "linked-deps"
            link.symlink_to(deps_root, target_is_directory=True)
            with self.assertRaisesRegex(release.ReleaseError, "patch_root_invalid"):
                release.apply_dependency_build_patches(link, lock_path, (patch,))
            patch["version"] = "2.0.0"
            with self.assertRaisesRegex(release.ReleaseError, "version_mismatch"):
                release.apply_dependency_build_patches(deps_root, lock_path, (patch,))

    def test_dependency_build_patch_inventory_is_exact_and_public(self) -> None:
        records = release.dependency_build_patch_records()
        self.assertEqual(
            [(item["dependency"], item["version"]) for item in records],
            [("bandit", "1.10.3"), ("mint", "1.7.1"), ("phoenix_live_view", "1.1.25")],
        )
        self.assertTrue(
            all(
                set(item)
                == {
                    "dependency",
                    "originalSha256",
                    "patchedSha256",
                    "path",
                    "purpose",
                    "version",
                }
                for item in records
            )
        )

    def test_runtime_dependency_inventory_is_lock_notice_and_sbom_bound(self) -> None:
        inventory_raw = (release.ROOT / release.RUNTIME_DEPENDENCY_INVENTORY_PATH).read_bytes()
        notice_raw = (release.ROOT / release.THIRD_PARTY_NOTICES_PATH).read_bytes()
        lock_raw = (release.ROOT / "elixir/mix.lock").read_bytes()
        inventory = release.validate_runtime_dependency_inventory(
            inventory_raw, notice_raw, lock_raw
        )
        self.assertEqual(len(inventory["components"]), 31)
        self.assertEqual(len(inventory["bundledApplications"]), 34)
        self.assertEqual(inventory["externalRuntime"]["version"], "28.5")
        document = release.spdx_document(
            HEAD,
            SHA,
            "2026-07-21T12:00:00Z",
            inventory,
        )
        packages = document["packages"]
        dependency_packages = packages[1:]
        self.assertEqual(len(dependency_packages), 33)
        self.assertFalse(any("NOASSERTION" in str(item) for item in packages))
        self.assertFalse(
            {"credo", "dialyxir", "floki", "lazy_html"}
            & {item["name"] for item in packages}
        )
        for name in ("bandit", "mint", "phoenix_live_view"):
            package = next(item for item in packages if item["name"] == name)
            self.assertIn("Downstream build-only determinism patch", package["comment"])

        changed_notice = notice_raw.replace(
            b"Copyright 2019 Plataformatec",
            b"Copyright 2019 Plataformatex",
            1,
        )
        with self.assertRaisesRegex(release.ReleaseError, "notice_body_mismatch"):
            release.validate_notice_embedded_bodies(changed_notice)

        changed = json.loads(inventory_raw)
        changed["components"][0]["spdxLicense"] = "GPL-3.0-only"
        with self.assertRaisesRegex(release.ReleaseError, "component_invalid"):
            release.validate_runtime_dependency_inventory(
                release.canonical_json_bytes(changed), notice_raw, lock_raw
            )
        changed = json.loads(inventory_raw)
        changed["components"][0]["contentSha256"] = "0" * 64
        with self.assertRaisesRegex(release.ReleaseError, "lock_mismatch"):
            release.validate_runtime_dependency_inventory(
                release.canonical_json_bytes(changed), notice_raw, lock_raw
            )

    def test_escript_runtime_inventory_rejects_drift_and_extra_priv(self) -> None:
        inventory = release.validate_runtime_dependency_inventory(
            (release.ROOT / release.RUNTIME_DEPENDENCY_INVENTORY_PATH).read_bytes(),
            (release.ROOT / release.THIRD_PARTY_NOTICES_PATH).read_bytes(),
            (release.ROOT / "elixir/mix.lock").read_bytes(),
        )
        versions = {
            application: component["version"]
            for component in inventory["components"]
            for application in component["applications"]
        }
        versions["symphony_elixir"] = "0.1.0"
        priv_root = release.ROOT / release.SYMPHONY_PRIV_PATH
        self.assertGreater(len(release.symphony_priv_source_records(priv_root)), 1_800)

        def write_escript(
            path: Path,
            observed: dict[str, str],
            *,
            extra_priv: bool = False,
            fifo_entry: bool = False,
            include_nil: bool = True,
        ) -> None:
            path.write_bytes(b"#!/usr/bin/env escript\n")
            with zipfile.ZipFile(path, "a", compression=zipfile.ZIP_DEFLATED) as archive:
                if include_nil:
                    archive.writestr("nil_escript.beam", b"beam")
                for application, version in sorted(observed.items()):
                    archive.writestr(
                        f"{application}/ebin/{application}.app",
                        f'{{application,{application},[{{vsn,"{version}"}}]}}.\n'.encode(),
                    )
                archive.writestr(
                    "erlexec/priv/x86_64-pc-linux-gnu/exec-port", b"native"
                )
                if extra_priv:
                    archive.writestr("erlexec/priv/unexpected", b"unexpected")
                if fifo_entry:
                    fifo = zipfile.ZipInfo("fifo")
                    fifo.create_system = 3
                    fifo.external_attr = (stat.S_IFIFO | 0o644) << 16
                    archive.writestr(fifo, b"")

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            exact = root / "exact"
            write_escript(exact, versions)
            self.assertEqual(
                len(
                    release.validate_escript_runtime_inventory(
                        exact, inventory, priv_root
                    )
                ),
                34,
            )
            changed = dict(versions)
            changed["bandit"] = "9.9.9"
            drift = root / "drift"
            write_escript(drift, changed)
            with self.assertRaisesRegex(release.ReleaseError, "inventory_mismatch"):
                release.validate_escript_runtime_inventory(drift, inventory, priv_root)
            extra = root / "extra"
            write_escript(extra, {**versions, "credo": "1.7.16"})
            with self.assertRaisesRegex(release.ReleaseError, "inventory_mismatch"):
                release.validate_escript_runtime_inventory(extra, inventory, priv_root)
            bad_priv = root / "bad-priv"
            write_escript(bad_priv, versions, extra_priv=True)
            with self.assertRaisesRegex(release.ReleaseError, "priv_inventory_mismatch"):
                release.validate_escript_runtime_inventory(bad_priv, inventory, priv_root)
            fifo = root / "fifo"
            write_escript(fifo, versions, fifo_entry=True)
            with self.assertRaisesRegex(release.ReleaseError, "entry_invalid"):
                release.validate_escript_runtime_inventory(fifo, inventory, priv_root)
            missing_nil = root / "missing-nil"
            write_escript(missing_nil, versions, include_nil=False)
            with self.assertRaisesRegex(release.ReleaseError, "nil_escript"):
                release.validate_escript_runtime_inventory(missing_nil, inventory, priv_root)
            symlink_priv = root / "priv"
            symlink_priv.symlink_to(priv_root, target_is_directory=True)
            with self.assertRaisesRegex(release.ReleaseError, "priv_source_invalid"):
                release.symphony_priv_source_records(symlink_priv)

            copied_priv = root / "copied" / "priv"
            shutil.copytree(priv_root, copied_priv)
            schema = (
                copied_priv
                / "codex_schema/0.144.3/json/v1/InitializeParams.json"
            )
            schema.write_bytes(
                schema.read_bytes().replace(b"InitializeParams", b"InitializeParamz", 1)
            )
            with self.assertRaisesRegex(release.ReleaseError, "semantic_inventory_mismatch"):
                release.symphony_priv_source_records(copied_priv)

    @mock.patch.object(release.shutil, "which", return_value="/usr/local/bin/mise")
    @mock.patch.object(release, "run")
    def test_pinned_toolchain_path_uses_minimal_lookup_environment(
        self, run_mock: mock.Mock, _which_mock: mock.Mock
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            elixir_bin = root / "elixir" / "bin"
            erlang_bin = root / "erlang" / "bin"
            elixir_bin.mkdir(parents=True)
            erlang_bin.mkdir(parents=True)
            for tool in (elixir_bin / "mix", elixir_bin / "elixir", erlang_bin / "erl"):
                tool.touch()
            run_mock.side_effect = [
                mock.Mock(stdout=f"{elixir_bin / 'mix'}\n", stderr=""),
                mock.Mock(stdout=f"{elixir_bin / 'elixir'}\n", stderr=""),
                mock.Mock(stdout=f"{erlang_bin / 'erl'}\n", stderr=""),
            ]
            original = dict(os.environ)
            try:
                os.environ["HOME"] = "/home/builder"
                os.environ["PATH"] = "/usr/local/bin:/usr/bin"
                os.environ["LINEAR_API_KEY"] = "never-copy"
                path = release.pinned_toolchain_path(Path("/source/elixir"))
            finally:
                os.environ.clear()
                os.environ.update(original)
        self.assertEqual(
            path,
            f"{elixir_bin}:{erlang_bin}:/usr/local/bin:/usr/bin",
        )
        for call in run_mock.call_args_list:
            lookup_env = call.kwargs["env"]
            self.assertNotIn("LINEAR_API_KEY", lookup_env)
            self.assertEqual(lookup_env["HOME"], "/home/builder")

    @mock.patch.object(release.subprocess, "Popen")
    def test_tree_inventory_is_bounded_before_archive_allocation(self, popen_mock: mock.Mock) -> None:
        oversized_path = b"x" * (release.MAX_ARCHIVE_PATH_BYTES + 1)
        process = mock.Mock()
        process.stdout = io.BytesIO(b"100644 blob " + b"a" * 40 + b" 1\t" + oversized_path + b"\0")
        process.stderr = io.BytesIO()
        process.wait.return_value = 0
        popen_mock.return_value = process
        with self.assertRaisesRegex(release.ReleaseError, "record_too_large|path_too_large"):
            release.tracked_modes(HEAD)
        process.kill.assert_called_once()

    def test_escript_normalization_is_byte_reproducible(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            with source.open("wb") as handle:
                handle.write(b"#!/usr/bin/env escript\n")
            with zipfile.ZipFile(source, "a") as archive:
                archive.writestr("z.txt", b"z")
                archive.writestr("a.txt", b"a")
            first = root / "first"
            second = root / "second"
            release.normalize_escript(source, first)
            release.normalize_escript(source, second)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            self.assertEqual(first.stat().st_mode & 0o777, 0o755)
            normalized = first.read_bytes()
            marker = normalized.index(b"PK\x03\x04")
            zip_bytes = normalized[marker:]
            end = zip_bytes.rindex(b"PK\x05\x06")
            central_offset = struct.unpack_from("<I", zip_bytes, end + 16)[0]
            self.assertEqual(zip_bytes[central_offset : central_offset + 4], b"PK\x01\x02")

    def test_safe_extract_rejects_traversal_and_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "bad.tar.gz"
            with tarfile.open(archive, "w:gz") as output:
                info = tarfile.TarInfo("../escape")
                info.size = 1
                output.addfile(info, io.BytesIO(b"x"))
            destination = root / "out"
            destination.mkdir()
            with self.assertRaisesRegex(release.ReleaseError, "unsafe_package"):
                release.safe_extract(archive, destination)

    def test_safe_extract_preserves_bounded_regular_file_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "good.tar.gz"
            with tarfile.open(archive, "w:gz") as output:
                info = tarfile.TarInfo("symphony/elixir/bin/symphony")
                info.mode = 0o755
                info.size = 4
                output.addfile(info, io.BytesIO(b"test"))
            destination = root / "out"
            destination.mkdir()
            extracted = release.safe_extract(archive, destination)
            binary = extracted / "elixir/bin/symphony"
            self.assertEqual(binary.read_bytes(), b"test")
            self.assertEqual(binary.stat().st_mode & 0o777, 0o755)

    @mock.patch.object(release, "pinned_toolchain_path", return_value="/opt/elixir/bin:/opt/erlang/bin")
    @mock.patch.object(release, "run")
    def test_installed_version_probe_gets_no_inherited_credentials(
        self, run_mock: mock.Mock, _toolchain_mock: mock.Mock
    ) -> None:
        manifest = {
            "codex": {"artifactBundleSha256": SHA},
            "upstreamBaseSha": BASE,
        }
        expected = "\n".join(
            (
                "Symphony 0.1.0",
                f"commit: {HEAD}",
                f"upstream-base: {BASE}",
                f"codex-compatibility-sha256: {SHA}",
                "provenance: github-release-verified",
            )
        )
        run_mock.return_value = mock.Mock(returncode=0, stdout=expected + "\n", stderr="")
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "elixir/bin/symphony"
            binary.parent.mkdir(parents=True)
            binary.touch()
            observed = release.verify_installed_binary(binary, manifest, HEAD)
        self.assertEqual(observed, expected)
        runtime_env = run_mock.call_args.kwargs["env"]
        self.assertEqual(runtime_env["PATH"], "/opt/elixir/bin:/opt/erlang/bin")
        self.assertNotIn("LINEAR_API_KEY", runtime_env)
        self.assertNotIn("GITHUB_TOKEN", runtime_env)

        run_mock.return_value = mock.Mock(
            returncode=1,
            stdout="",
            stderr="content that must not enter the failure category",
        )
        with self.assertRaisesRegex(
            release.ReleaseError, "installed_version_runtime_validation_failed"
        ):
            release.verify_installed_binary(binary, manifest, HEAD)

    @mock.patch.object(
        release,
        "pinned_toolchain_path",
        return_value="/opt/elixir/bin:/opt/erlang/bin",
    )
    @mock.patch.object(release, "run")
    def test_packaged_guardrail_smoke_is_no_model_and_credential_free(
        self, run_mock: mock.Mock, _toolchain_mock: mock.Mock
    ) -> None:
        run_mock.return_value = mock.Mock(
            returncode=1,
            stdout="",
            stderr=(
                "Codex will run without any guardrails.\n"
                "--i-understand-that-this-will-be-running-without-the-usual-guardrails\n"
            ),
        )
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "elixir/bin/symphony"
            binary.parent.mkdir(parents=True)
            binary.touch()
            receipt = release.verify_installed_guardrail_smoke(binary)
        self.assertTrue(receipt["noModelWork"])
        self.assertTrue(receipt["runtimeHomeEmpty"])
        runtime_env = run_mock.call_args.kwargs["env"]
        self.assertNotIn("LINEAR_API_KEY", runtime_env)
        self.assertNotIn("GITHUB_TOKEN", runtime_env)

    @mock.patch.object(
        release,
        "pinned_toolchain_path",
        return_value="/usr/bin:/bin",
    )
    def test_packaged_runner_smoke_serves_zero_work_state_and_cleans_process_group(
        self, _toolchain_mock: mock.Mock
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "elixir/bin/symphony"
            binary.parent.mkdir(parents=True)
            binary.write_text(
                "#!/usr/bin/env python3\n"
                "import http.server, json, sys\n"
                "port = int(sys.argv[sys.argv.index('--port') + 1])\n"
                "payload = json.dumps({'counts': {'blocked': 0, 'retrying': 0, 'running': 0}, "
                "'running': [], 'retrying': [], 'blocked': []}).encode()\n"
                "dashboard = b'<title>Symphony Observability</title><h1>Operations Dashboard</h1>'\n"
                "class Handler(http.server.BaseHTTPRequestHandler):\n"
                "    def do_GET(self):\n"
                "        self.send_response(200)\n"
                "        self.send_header('Content-Type', 'text/html' if self.path == '/' else 'application/json')\n"
                "        self.end_headers()\n"
                "        self.wfile.write(dashboard if self.path == '/' else payload)\n"
                "    def log_message(self, *_args):\n"
                "        pass\n"
                "http.server.HTTPServer(('127.0.0.1', port), Handler).serve_forever()\n",
                encoding="utf-8",
            )
            binary.chmod(0o755)
            receipt = release.verify_installed_runner_smoke(binary)
        self.assertTrue(receipt["noModelWork"])
        self.assertTrue(receipt["noExternalTracker"])
        self.assertTrue(receipt["processGroupCleaned"])
        self.assertEqual(receipt["httpStatus"], 200)
        self.assertEqual(receipt["dashboardHttpStatus"], 200)
        self.assertTrue(receipt["dashboardMarkersPresent"])

    @mock.patch.object(
        release,
        "pinned_toolchain_path",
        return_value="/usr/bin:/bin",
    )
    def test_packaged_runner_smoke_rejects_non_200_success_response(
        self, _toolchain_mock: mock.Mock
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "elixir/bin/symphony"
            binary.parent.mkdir(parents=True)
            binary.write_text(
                "#!/usr/bin/env python3\n"
                "import http.server, json, sys\n"
                "port = int(sys.argv[sys.argv.index('--port') + 1])\n"
                "payload = json.dumps({'counts': {'blocked': 0, 'retrying': 0, 'running': 0}, "
                "'running': [], 'retrying': [], 'blocked': []}).encode()\n"
                "class Handler(http.server.BaseHTTPRequestHandler):\n"
                "    def do_GET(self):\n"
                "        self.send_response(202)\n"
                "        self.send_header('Content-Type', 'application/json')\n"
                "        self.end_headers()\n"
                "        self.wfile.write(payload)\n"
                "    def log_message(self, *_args):\n"
                "        pass\n"
                "http.server.HTTPServer(('127.0.0.1', port), Handler).serve_forever()\n",
                encoding="utf-8",
            )
            binary.chmod(0o755)
            with self.assertRaisesRegex(release.ReleaseError, "http_status_invalid"):
                release.verify_installed_runner_smoke(binary)

    def test_runner_projection_ignores_nondeterministic_generation_time(self) -> None:
        base = {
            "blocked": [],
            "counts": {"blocked": 0, "retrying": 0, "running": 0},
            "retrying": [],
            "running": [],
        }
        first = {**base, "generated_at": "2026-07-21T12:00:00Z"}
        second = {**base, "generated_at": "2026-07-21T12:00:01Z"}
        first_hash = release.sha256_bytes(
            release.canonical_json_bytes(release.zero_work_state_projection(first))
        )
        second_hash = release.sha256_bytes(
            release.canonical_json_bytes(release.zero_work_state_projection(second))
        )
        self.assertEqual(first_hash, second_hash)

    def test_checksums_require_sorted_complete_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "a.txt").write_bytes(b"a")
            (root / "b.txt").write_bytes(b"b")
            checksums = (
                f"{release.sha256_file(root / 'a.txt')}  a.txt\n"
                f"{release.sha256_file(root / 'b.txt')}  b.txt\n"
            )
            (root / "SHA256SUMS").write_text(checksums, encoding="ascii")
            release.verify_checksums(root)
            (root / "unlisted.txt").write_bytes(b"x")
            with self.assertRaisesRegex(release.ReleaseError, "inventory_incomplete"):
                release.verify_checksums(root)

    def test_checksums_reject_malformed_lines_with_controlled_error(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "SHA256SUMS").write_text("malformed\n", encoding="ascii")
            with self.assertRaisesRegex(release.ReleaseError, "checksums_format_invalid"):
                release.verify_checksums(root)

    def test_package_manifest_binds_exact_asset_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            asset = root / "archive.tar.gz"
            asset.write_bytes(b"archive")
            manifest = {
                "assets": [
                    {
                        "name": asset.name,
                        "sha256": release.sha256_file(asset),
                        "size": asset.stat().st_size,
                    }
                ],
                "candidateManifestSha256": SHA,
                "kind": "release-package-manifest",
                "mergedCommitSha": HEAD,
                "mergedTreeSha": TREE,
                "prNumber": 1,
                "specificationStage": release.STAGE,
                "version": release.VERSION,
            }
            release.atomic_write(
                root / "release-package-manifest.json",
                release.canonical_json_bytes(manifest),
            )
            with self.assertRaisesRegex(release.ReleaseError, "required_assets_invalid"):
                release.validate_package_manifest(root)

    def test_package_manifest_accepts_only_semantically_bound_fixed_assets(self) -> None:
        runtime_notice = (
            release.ROOT / release.THIRD_PARTY_NOTICES_PATH
        ).read_bytes()
        runtime_inventory_raw = (
            release.ROOT / release.RUNTIME_DEPENDENCY_INVENTORY_PATH
        ).read_bytes()
        runtime_lock = (release.ROOT / "elixir/mix.lock").read_bytes()
        runtime_inventory = release.validate_runtime_dependency_inventory(
            runtime_inventory_raw,
            runtime_notice,
            runtime_lock,
        )
        candidate = {
            "codex": {"artifactBundleSha256": SHA},
            "readiness": {"sha256": release.sha256_bytes(b"readiness")},
            "releaseHeadSha": HEAD,
            "schemaManifest": {"sha256": release.sha256_bytes(b"schema")},
            "sourceDateEpoch": 1,
            "testEvidence": [],
            "upstreamBaseSha": BASE,
        }
        expected_baseline_hashes = {
            "LICENSE": "c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4",
            "NOTICE": "38c76eb8701e52953f63154a77b407667a6ee34c3a2a8785c8f8b2cd5494d09d",
            "SPEC.md": "fa9d7c252cc72d10afdaf4e46e0d890aae28cf4331dc531c94413bc8ea199452",
        }
        version_output = [
            "Symphony 0.1.0",
            f"commit: {HEAD}",
            f"upstream-base: {BASE}",
            f"codex-compatibility-sha256: {SHA}",
            "provenance: github-release-verified",
        ]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate_raw = release.canonical_json_bytes({"fixture": "candidate"})
            files: dict[str, bytes] = {
                "THIRD_PARTY_NOTICES.txt": runtime_notice,
                "codex-schema-manifest.json": b"schema",
                "implementation-readiness.json": b"readiness",
                "migration-report.json": release.canonical_json_bytes(
                    {
                        "backupRestore": "not-applicable-release-0",
                        "databaseSchemaVersion": None,
                        "migrationSet": [],
                        "rollbackClassification": "return-to-locked-upstream-source",
                        "status": "pass",
                    }
                ),
                "provenance.json": release.canonical_json_bytes(
                    {
                        "buildType": "symphony-studio-release-v1",
                        "buildTools": {
                            "hex": release.HEX_VERSION,
                            "rebar3Sha512": release.REBAR3_SHA512,
                        },
                        "candidateManifestSha256": release.sha256_bytes(candidate_raw),
                        "dependencyBuildPatches": release.dependency_build_patch_records(),
                        "escriptSourceDateEpoch": 1,
                        "archiveMtimeEpoch": 123,
                        "mergedCommit": HEAD,
                        "mergedTree": TREE,
                        "repository": release.REPOSITORY,
                        "upstreamBase": BASE,
                    }
                ),
                "release-candidate-manifest.json": candidate_raw,
                "symphony-studio-0.1.0-linux-x86_64.tar.gz": b"archive",
                "test-summary.json": release.canonical_json_bytes(
                    {
                        "candidateHead": HEAD,
                        "mergedCommit": HEAD,
                        "status": "pass",
                        "testEvidence": [],
                        "versionOutput": version_output,
                    }
                ),
                "upstream-baseline-return.json": release.canonical_json_bytes(
                    {
                        "cleanWorktree": True,
                        "detachedHead": BASE,
                        "expectedHashes": expected_baseline_hashes,
                        "kind": "upstream-baseline-return",
                        "observedHashes": expected_baseline_hashes,
                        "repository": "https://github.com/openai/symphony.git",
                        "smokeCommand": [
                            "mix",
                            "test",
                            "test/symphony_elixir/cli_test.exs",
                            "--seed",
                            "0",
                        ],
                        "smokeEvidenceSha256": SHA,
                        "smokeStatus": "pass",
                        "status": "pass",
                        "treeSha": TREE,
                        "upstreamCommit": BASE,
                    }
                ),
            }
            archive_sha = release.sha256_bytes(files["symphony-studio-0.1.0-linux-x86_64.tar.gz"])
            files["sbom.spdx.json"] = release.canonical_json_bytes(
                release.spdx_document(
                    HEAD,
                    archive_sha,
                    release.iso_from_epoch(123),
                    runtime_inventory,
                )
            )
            public_audit = {"kind": "fixture-public-audit", "status": "pass"}
            files[release.PUBLIC_ARTIFACT_AUDIT_NAME] = release.canonical_json_bytes(public_audit)
            for name, payload in files.items():
                (root / name).write_bytes(payload)
            manifest = {
                "assets": [
                    {
                        "name": name,
                        "sha256": release.sha256_file(root / name),
                        "size": (root / name).stat().st_size,
                    }
                    for name in sorted(files)
                ],
                "candidateManifestSha256": release.sha256_bytes(candidate_raw),
                "kind": "release-package-manifest",
                "mergedCommitSha": HEAD,
                "mergedTreeSha": TREE,
                "prNumber": 1,
                "specificationStage": release.STAGE,
                "version": release.VERSION,
            }
            release.atomic_write(
                root / "release-package-manifest.json",
                release.canonical_json_bytes(manifest),
            )

            def fake_git(*args: str, cwd=release.ROOT):
                if args[:3] == ("show", "-s", "--format=%ct"):
                    return "123"
                if args[0] == "rev-parse":
                    return TREE
                raise AssertionError(args)

            def fake_git_bytes(_commit: str, path: str) -> bytes:
                values = {
                    release.RUNTIME_DEPENDENCY_INVENTORY_PATH: runtime_inventory_raw,
                    release.THIRD_PARTY_NOTICES_PATH: runtime_notice,
                    "elixir/mix.lock": runtime_lock,
                }
                try:
                    return values[path]
                except KeyError as error:
                    raise AssertionError(path) from error

            with (
                mock.patch.object(release, "validate_candidate", return_value=candidate),
                mock.patch.object(release, "git", side_effect=fake_git),
                mock.patch.object(release, "git_bytes", side_effect=fake_git_bytes),
                mock.patch.object(
                    release,
                    "public_artifact_audit_value",
                    return_value=public_audit,
                ),
            ):
                observed = release.validate_package_manifest(
                    root,
                    expected_merged_sha=HEAD,
                    expected_candidate_sha256=release.sha256_bytes(candidate_raw),
                )
                self.assertEqual(observed, manifest)
                (root / "migration-report.json").write_bytes(b"changed")
                with self.assertRaises(release.ReleaseError):
                    release.validate_package_manifest(root)

    @mock.patch.object(release, "git", return_value="1784635200")
    def test_final_manifest_is_stable_before_attestation(self, _git_mock: mock.Mock) -> None:
        candidate = {
            "approvedWaiverIds": [],
            "baseSha": BASE,
            "codex": {"artifactBundleSha256": SHA, "version": "0.144.3"},
            "readiness": {"path": "readiness.json", "sha256": SHA},
            "releaseHeadSha": HEAD,
            "requiredChecks": [release.REQUIRED_CONTEXT],
            "reviewEvidence": [],
            "schemaManifest": {"path": "schema.json", "sha256": SHA},
            "supportedPlatforms": [release.SUPPORTED_PLATFORM],
            "testEvidence": [],
            "testedMergeTreeSha": TREE,
            "upstreamBaseSha": BASE,
        }
        package_manifest = {
            "candidateManifestSha256": SHA,
            "mergedCommitSha": HEAD,
            "mergedTreeSha": TREE,
            "prNumber": 1,
        }
        remote_release = {
            "created_at": "2026-07-21T12:00:00Z",
            "id": 42,
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "archive.tar.gz").write_bytes(b"archive")
            (root / "release-package-manifest.json").write_bytes(b"package\n")
            release.append_final_manifest(root, candidate, package_manifest, remote_release)
            before_manifest = (root / "release-manifest.json").read_bytes()
            before_checksums = (root / "SHA256SUMS").read_bytes()
            observed = release.validate_final_manifest(
                root,
                candidate,
                package_manifest,
                remote_release,
            )
            self.assertEqual(observed["publicationTime"]["jsonPointer"], "/publishedAt")
            self.assertEqual(
                observed["publicationStatus"]["jsonPointer"],
                "/status",
            )
            self.assertEqual(
                observed["publicationEvidence"]["predicateType"],
                release.PUBLICATION_PREDICATE_TYPE,
            )
            self.assertEqual((root / "release-manifest.json").read_bytes(), before_manifest)
            self.assertEqual((root / "SHA256SUMS").read_bytes(), before_checksums)

    def test_pr_body_fills_template_and_binds_candidate(self) -> None:
        manifest = {
            "baseSha": BASE,
            "candidateTreeSha": TREE,
            "codex": {"artifactBundleSha256": SHA, "version": "0.144.3"},
            "releaseHeadSha": HEAD,
            "reviewEvidence": [{"sha256": SHA}],
            "specificationStage": release.STAGE,
            "testEvidence": [{"sha256": SHA}],
            "upstreamBaseSha": BASE,
            "version": release.VERSION,
        }
        body = release.pr_body(manifest)
        self.assertIn("#### Context", body)
        self.assertIn("#### TL;DR", body)
        self.assertIn("#### Summary", body)
        self.assertIn("#### Alternatives", body)
        self.assertIn("#### Test Plan", body)
        self.assertNotIn("<!--", body)
        self.assertIn(HEAD, body)
        self.assertIn(TREE, body)
        self.assertIn('"releaseHeadSha":"' + HEAD + '"', body)

    def test_candidate_transport_is_bounded_for_workflow_dispatch(self) -> None:
        raw = b"{}\n"
        inputs = release.publication_dispatch_inputs(raw, HEAD, 7)
        payload = json.dumps(inputs, sort_keys=True, separators=(",", ":"))
        self.assertLessEqual(len(payload), release.MAX_WORKFLOW_DISPATCH_INPUT_CHARS)
        self.assertEqual(inputs["candidate_manifest_sha256"], release.sha256_bytes(raw))
        with self.assertRaisesRegex(release.ReleaseError, "transport_too_large"):
            release.candidate_manifest_attachment(
                b"x" * (release.MAX_CANDIDATE_MANIFEST_BYTES + 1)
            )

    def test_protected_dispatch_binds_merge_check_and_workflow_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate_path = root / "candidate.json"
            receipt_path = root / "dispatch.json"
            candidate_path.write_bytes(b'{"candidate":1}\n')
            args = type(
                "Args",
                (),
                {
                    "candidate": str(candidate_path),
                    "merged_sha": HEAD,
                    "pr_number": 7,
                    "receipt": str(receipt_path),
                    "trusted_check_app_id": 424242,
                },
            )()
            events: list[str] = []

            def fake_run(command, **_kwargs):
                events.append("fetch" if command[:2] == ("git", "fetch") else "dispatch")
                return mock.Mock(returncode=0, stdout="", stderr="")

            def fake_verify(_args):
                events.append("verify")
                return 0

            def fake_source(*_args):
                events.append("source")

            with (
                mock.patch.object(release, "validate_candidate", return_value={"candidate": 1}),
                mock.patch.object(
                    release,
                    "command_verify_protected_merge",
                    side_effect=fake_verify,
                ) as verify,
                mock.patch.object(release, "git", return_value=BASE),
                mock.patch.object(
                    release,
                    "publication_workflow_source_record",
                    side_effect=fake_source,
                ) as source,
                mock.patch.object(
                    release,
                    "run",
                    side_effect=fake_run,
                ) as run_mock,
                mock.patch("sys.stdout", new=io.StringIO()),
            ):
                self.assertEqual(release.command_publish_dispatch(args), 0)
            self.assertEqual(events, ["fetch", "verify", "source", "dispatch"])
            verify.assert_called_once()
            source.assert_called_once_with({"candidate": 1}, HEAD, BASE)
            command = run_mock.call_args.args[0]
            self.assertEqual(
                command[:7],
                (
                    "gh",
                    "workflow",
                    "run",
                    "publish-release.yml",
                    "--repo",
                    release.REPOSITORY,
                    "--ref",
                ),
            )
            self.assertIn("candidate_manifest_base64=eyJjYW5kaWRhdGUiOjF9Cg==", command)
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            self.assertEqual(receipt["status"], "release_pending_publication")
            self.assertEqual(receipt["workflowSourceCommit"], BASE)

    def test_candidate_reconcile_accepts_exact_already_merged_pull_without_mutation(self) -> None:
        candidate = {
            "baseSha": BASE,
            "releaseHeadSha": HEAD,
        }
        merged_sha = "4" * 40
        pull = {
            "auto_merge": None,
            "base": {"ref": "main", "sha": BASE},
            "body": "exact body",
            "draft": False,
            "head": {"ref": release.RELEASE_BRANCH, "sha": HEAD},
            "html_url": "https://example.invalid/pull/7",
            "merge_commit_sha": merged_sha,
            "merged": True,
            "merged_at": "2026-07-21T12:00:00Z",
            "number": 7,
            "state": "closed",
            "title": "Release v0.1.0 — verified Symphony foundation",
        }
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = root / "candidate.json"
            receipt_path = root / "receipt.json"
            manifest.write_bytes(b'{"candidate":1}\n')
            args = type(
                "Args",
                (),
                {"manifest": str(manifest), "receipt": str(receipt_path)},
            )()

            def fake_git(*command: str, cwd=release.ROOT):
                if command == ("branch", "--show-current"):
                    return release.RELEASE_BRANCH
                if command == ("rev-parse", "HEAD"):
                    return HEAD
                if command == ("rev-parse", f"origin/{release.RELEASE_BRANCH}"):
                    return HEAD
                if command == ("rev-parse", "origin/main"):
                    return merged_sha
                if command == ("status", "--porcelain=v1", "--untracked-files=all"):
                    return ""
                raise AssertionError(command)

            with (
                mock.patch.object(release, "validate_candidate", return_value=candidate),
                mock.patch.object(release, "git", side_effect=fake_git),
                mock.patch.object(release, "release_pull_requests", return_value=[{"number": 7}]),
                mock.patch.object(release, "gh_api", return_value=pull),
                mock.patch.object(release, "pr_body", return_value="exact body"),
                mock.patch.object(
                    release,
                    "run",
                    return_value=mock.Mock(returncode=0, stdout="", stderr=""),
                ) as run_mock,
                mock.patch("sys.stdout", new=io.StringIO()),
            ):
                self.assertEqual(release.command_candidate_reconcile(args), 0)
            self.assertEqual(run_mock.call_count, 2)
            self.assertEqual(run_mock.call_args_list[0].args[0][:2], ("git", "fetch"))
            self.assertEqual(
                run_mock.call_args_list[1].args[0],
                ("git", "merge-base", "--is-ancestor", merged_sha, "origin/main"),
            )
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            self.assertEqual(receipt["state"], "merged")
            self.assertEqual(receipt["mergedSha"], merged_sha)

    def test_revert_state_rejects_an_already_merged_revert(self) -> None:
        def fake_api(path: str, *, allow_missing: bool = False):
            if "/git/ref/heads/" in path:
                return None
            if "/pulls?" in path:
                return [{"merged": True, "merged_at": "2026-07-21T12:00:00Z"}]
            raise AssertionError(path)

        with (
            mock.patch.object(release, "gh_api", side_effect=fake_api),
            self.assertRaisesRegex(release.ReleaseError, "revert_already_merged"),
        ):
            release.release_revert_state({"baseSha": BASE}, HEAD)

    def test_protected_merge_binds_latest_trusted_app_check_and_candidate_digest(self) -> None:
        candidate = {
            "baseSha": BASE,
            "releaseHeadSha": HEAD,
            "testedMergeTreeSha": TREE,
        }
        pull = {
            "base": {"ref": "main", "sha": BASE},
            "draft": False,
            "head": {"ref": release.RELEASE_BRANCH, "sha": HEAD},
            "merge_commit_sha": "4" * 40,
            "merged": True,
            "merged_at": "2026-07-21T12:00:00Z",
            "number": 7,
            "state": "closed",
        }
        with tempfile.TemporaryDirectory() as temporary:
            candidate_path = Path(temporary) / "candidate.json"
            release.atomic_write(candidate_path, release.canonical_json_bytes({"candidate": 1}))
            digest = release.sha256_file(candidate_path)
            attachment = __import__("base64").b64encode(candidate_path.read_bytes()).decode("ascii")
            old = {
                "app": {"id": 424242},
                "conclusion": "success",
                "external_id": digest,
                "head_sha": HEAD,
                "id": 10,
                "name": release.REQUIRED_CONTEXT,
                "output": {
                    "summary": f"candidate-manifest-sha256:{digest}",
                    "text": f"candidate-manifest-base64:{attachment}",
                    "title": "Symphony Studio R0-07 trusted candidate",
                },
                "status": "completed",
            }
            latest = {
                **old,
                "conclusion": "success",
                "id": 11,
            }

            def fake_api(path: str, *, allow_missing: bool = False):
                if "/pulls/7" in path:
                    return pull
                if "/commits/" in path:
                    return {"check_runs": [old, latest], "total_count": 2}
                if path.endswith("/check-runs/11"):
                    return latest
                raise AssertionError(path)

            def fake_git(*args: str, cwd=release.ROOT):
                if args[0] == "rev-list":
                    return f"{'4' * 40} {BASE} {HEAD}"
                if args[0] == "rev-parse":
                    return TREE
                raise AssertionError(args)

            args = type(
                "Args",
                (),
                {
                    "candidate": str(candidate_path),
                    "merged_sha": "4" * 40,
                    "pr_number": 7,
                    "receipt": None,
                    "trusted_check_app_id": 424242,
                },
            )()
            with (
                mock.patch.object(release, "validate_candidate", return_value=candidate),
                mock.patch.object(release, "gh_api", side_effect=fake_api),
                mock.patch.object(release, "git", side_effect=fake_git),
                mock.patch("sys.stdout", new=io.StringIO()),
            ):
                self.assertEqual(release.command_verify_protected_merge(args), 0)

            latest["external_id"] = "b" * 64
            with (
                mock.patch.object(release, "validate_candidate", return_value=candidate),
                mock.patch.object(release, "gh_api", side_effect=fake_api),
                mock.patch.object(release, "git", side_effect=fake_git),
                self.assertRaisesRegex(release.ReleaseError, "latest_mismatch"),
            ):
                release.command_verify_protected_merge(args)

    def test_draft_asset_reconciliation_uploads_only_verified_missing_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "a.txt").write_bytes(b"a")
            (root / "b.txt").write_bytes(b"b")
            remote_a = {"id": 1, "name": "a.txt", "size": 1}

            def fake_download(_asset, destination: Path) -> None:
                destination.write_bytes(b"a")

            with (
                mock.patch.object(release, "remote_assets", return_value=[remote_a]),
                mock.patch.object(release, "download_release_asset", side_effect=fake_download),
                mock.patch.object(release, "run", return_value=mock.Mock(returncode=0)) as run_mock,
                mock.patch.object(release, "release_by_exact_tag", return_value={"draft": True, "id": 2}),
                mock.patch.object(release, "verify_remote_asset_inventory"),
                mock.patch.object(release, "download_and_verify_release"),
            ):
                release.reconcile_draft_assets(root, {"id": 2})
            upload = run_mock.call_args.args[0]
            self.assertIn(str(root / "b.txt"), upload)
            self.assertNotIn(str(root / "a.txt"), upload)
            self.assertNotIn("--clobber", upload)

    def test_draft_reuse_reconciles_exact_committed_release_notes(self) -> None:
        expected = "# Exact release notes\n"
        stale = {
            "body": "stale\n",
            "draft": True,
            "id": 7,
            "name": "Symphony Studio v0.1.0 foundation",
            "prerelease": False,
            "published_at": None,
        }
        repaired = {**stale, "body": expected}
        with tempfile.TemporaryDirectory() as temporary:
            notes = Path(temporary) / "release-notes.md"
            notes.write_text(expected, encoding="utf-8")
            with (
                mock.patch.object(release, "git_bytes", return_value=expected.encode()),
                mock.patch.object(
                    release,
                    "release_by_exact_tag",
                    side_effect=[stale, repaired],
                ),
                mock.patch.object(release, "release_tag_commit", return_value=HEAD),
                mock.patch.object(
                    release,
                    "run",
                    return_value=mock.Mock(returncode=0, stdout="", stderr=""),
                ) as run_mock,
            ):
                observed = release.create_or_reuse_draft(HEAD, notes)
        self.assertEqual(observed["body"], expected)
        self.assertEqual(run_mock.call_count, 1)
        self.assertEqual(run_mock.call_args.args[0][:3], ("gh", "release", "edit"))

    def test_published_release_reuse_rejects_stale_notes_without_mutation(self) -> None:
        expected = "# Exact release notes\n"
        published = {
            "body": "stale\n",
            "draft": False,
            "id": 7,
            "name": "Symphony Studio v0.1.0 foundation",
            "prerelease": False,
            "published_at": "2026-07-21T12:00:00Z",
        }
        with tempfile.TemporaryDirectory() as temporary:
            notes = Path(temporary) / "release-notes.md"
            notes.write_text(expected, encoding="utf-8")
            with (
                mock.patch.object(release, "git_bytes", return_value=expected.encode()),
                mock.patch.object(release, "release_by_exact_tag", return_value=published),
                mock.patch.object(release, "release_tag_commit", return_value=HEAD),
                mock.patch.object(release, "run") as run_mock,
                self.assertRaisesRegex(release.ReleaseError, "published_release_notes_mismatch"),
            ):
                release.create_or_reuse_draft(HEAD, notes)
        run_mock.assert_not_called()

    def test_platform_receipt_requires_hash_bound_no_model_guardrail_smoke(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "symphony-studio-0.1.0-linux-x86_64.tar.gz"
            archive.write_bytes(b"archive")
            package_file = root / "release-package-manifest.json"
            package_file.write_bytes(b"package")
            baseline_file = root / "upstream-baseline-return.json"
            baseline_file.write_bytes(b"baseline")
            candidate = {
                "codex": {"artifactBundleSha256": SHA},
                "sourceDateEpoch": 1,
                "supportedPlatforms": [release.SUPPORTED_PLATFORM],
                "upstreamBaseSha": BASE,
            }
            package_manifest = {
                "candidateManifestSha256": SHA,
                "mergedCommitSha": HEAD,
                "mergedTreeSha": TREE,
            }
            guardrail = {
                "exitCode": 1,
                "guardrailMarkersPresent": True,
                "noModelWork": True,
                "runtimeHomeEmpty": True,
                "stderrSha256": SHA,
                "stdoutEmpty": True,
            }
            runner = {
                "dashboardEndpoint": "/",
                "dashboardHttpStatus": 200,
                "dashboardMarkersPresent": True,
                "dashboardSha256": SHA,
                "endpoint": "/api/v1/state",
                "httpStatus": 200,
                "noExternalTracker": True,
                "noModelWork": True,
                "processGroupCleaned": True,
                "stateProjectionSha256": SHA,
                "zeroAdmittedIssues": True,
            }
            codex_compatibility = {
                "authenticationRequiredForWork": True,
                "launcherSha256": SHA,
                "nativeSha256": "b" * 64,
                "versionOutput": "codex-cli 0.144.3",
            }
            receipt = {
                "architecture": "x86_64",
                "archiveMtimeEpoch": 123,
                "archiveSha256": release.sha256_file(archive),
                "baselineReturn": {
                    "reexecutedOnSupportedPlatform": True,
                    "receiptSha256": release.sha256_file(baseline_file),
                    "status": "pass",
                },
                "candidateManifestSha256": SHA,
                "codexCompatibility": codex_compatibility,
                "distribution": "Debian GNU/Linux 12",
                "escriptSourceDateEpoch": 1,
                "guardrailSmoke": guardrail,
                "kind": "supported-platform-clean-install",
                "mergedCommitSha": HEAD,
                "mergedTreeSha": TREE,
                "packageManifestSha256": release.sha256_file(package_file),
                "runnerSmoke": runner,
                "status": "pass",
                "supportedPlatform": release.SUPPORTED_PLATFORM,
                "versionOutput": [
                    "Symphony 0.1.0",
                    f"commit: {HEAD}",
                    f"upstream-base: {BASE}",
                    f"codex-compatibility-sha256: {SHA}",
                    "provenance: github-release-verified",
                ],
            }
            receipt_path = root / "receipt.json"
            release.atomic_write(receipt_path, release.canonical_json_bytes(receipt))
            with (
                mock.patch.object(
                    release,
                    "codex_compatibility_from_lock",
                    return_value=({}, codex_compatibility),
                ),
                mock.patch.object(release, "git", return_value="123"),
            ):
                self.assertEqual(
                    release.validate_platform_receipt(
                        receipt_path, root, candidate, package_manifest
                    ),
                    receipt,
                )
                receipt["guardrailSmoke"]["noModelWork"] = False
                release.atomic_write(receipt_path, release.canonical_json_bytes(receipt))
                with self.assertRaisesRegex(
                    release.ReleaseError, "platform_receipt_invalid"
                ):
                    release.validate_platform_receipt(
                        receipt_path, root, candidate, package_manifest
                    )

    def test_supported_platform_reexecutes_and_binds_baseline_receipt(self) -> None:
        baseline = {"kind": "upstream-baseline-return", "status": "pass"}
        raw = release.canonical_json_bytes(baseline)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "upstream-baseline-return.json"
            path.write_bytes(raw)
            with mock.patch.object(
                release, "baseline_return_record", return_value=baseline
            ) as replay:
                self.assertEqual(
                    release.verify_supported_platform_baseline_return(root),
                    {
                        "reexecutedOnSupportedPlatform": True,
                        "receiptSha256": release.sha256_bytes(raw),
                        "status": "pass",
                    },
                )
            replay.assert_called_once_with()

            path.write_bytes(release.canonical_json_bytes({"status": "stale"}))
            with (
                mock.patch.object(
                    release, "baseline_return_record", return_value=baseline
                ),
                self.assertRaisesRegex(
                    release.ReleaseError,
                    "clean_install_upstream_baseline_mismatch",
                ),
            ):
                release.verify_supported_platform_baseline_return(root)

    def test_public_artifact_scanner_rejects_secret_and_private_path_shapes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "artifact.txt"
            path.write_bytes(b"lin_api_" + b"x" * 24)
            with self.assertRaisesRegex(release.ReleaseError, "linear_token"):
                release.scan_public_file(path, path.name)
            path.write_bytes(b"path=" + b"/home/" + b"codexdev" + b"/private")
            with self.assertRaisesRegex(release.ReleaseError, "devbox_path"):
                release.scan_public_file(path, path.name)

    @mock.patch.object(release, "release_tag_commit", return_value=HEAD)
    def test_publication_receipt_requires_exact_release_immutability(
        self, _tag_mock: mock.Mock
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "SHA256SUMS").write_bytes(b"sums")
            (root / "release-manifest.json").write_bytes(b"manifest")
            remote = {
                "draft": False,
                "html_url": "https://github.com/farhaanlevy/symphony-studio/releases/tag/v0.1.0",
                "id": 7,
                "immutable": False,
                "published_at": "2026-07-21T12:00:00Z",
            }
            kwargs = {
                "handoff": {"releaseBranchDeleted": True},
                "integrity_verification": {"status": "pass"},
                "latest": True,
                "repository_immutable": True,
            }
            with self.assertRaisesRegex(release.ReleaseError, "policy_mismatch"):
                release.publication_receipt(remote, HEAD, root, **kwargs)
            remote["immutable"] = True
            receipt = release.publication_receipt(remote, HEAD, root, **kwargs)
            self.assertTrue(receipt["immutableRelease"])
            self.assertEqual(receipt["status"], "pass")
            self.assertEqual(receipt["tagTarget"], HEAD)

    def test_irreversible_publication_has_atomic_in_flight_failure_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            receipt_path = Path(temporary) / "publication.json"

            def fail_after_observing_receipt(*_args, **_kwargs):
                observed = json.loads(receipt_path.read_text(encoding="utf-8"))
                self.assertEqual(observed["phase"], "publication-command-in-flight")
                self.assertEqual(observed["status"], "publication-verification-pending")
                raise release.ReleaseError("simulated_release_edit_timeout")

            with (
                mock.patch.object(release, "run", side_effect=fail_after_observing_receipt),
                self.assertRaisesRegex(release.ReleaseError, "simulated_release_edit_timeout"),
            ):
                release.begin_publication_command(
                    receipt_path,
                    {"draft": True, "id": 7},
                    HEAD,
                    SHA,
                    BASE,
                )
            failed = json.loads(receipt_path.read_text(encoding="utf-8"))
            self.assertEqual(failed["phase"], "publication-command-returned")
            self.assertEqual(failed["failingPhase"], "publication-command-returned")
            self.assertEqual(failed["status"], "publication-verification-failed")

    @mock.patch.object(release, "run")
    def test_publication_custom_attestation_contains_exact_receipt(
        self, run_mock: mock.Mock
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subject = root / "release-manifest.json"
            subject.write_bytes(b"manifest\n")
            receipt_path = root / "release-publication-receipt.json"
            receipt = {"kind": "release-publication-receipt", "status": "pass"}
            release.atomic_write(receipt_path, release.canonical_json_bytes(receipt))
            run_mock.return_value = mock.Mock(
                stdout=json.dumps(
                    [
                        {
                            "attestation": {},
                            "verificationResult": {
                                "statement": {
                                    "predicate": receipt,
                                    "predicateType": release.PUBLICATION_PREDICATE_TYPE,
                                }
                            },
                        }
                    ]
                ),
                stderr="",
            )
            record = release.verify_publication_attestation(subject, receipt_path, HEAD)
        self.assertEqual(record["status"], "pass")
        self.assertEqual(record["predicateType"], release.PUBLICATION_PREDICATE_TYPE)

    def test_publication_workflow_source_allows_exact_protected_descendant(self) -> None:
        path = ".github/workflows/publish-release.yml"
        candidate = {"workflowProvenance": {path: SHA}}
        run_result = mock.Mock(returncode=0)
        with (
            mock.patch.object(release, "git", return_value=BASE),
            mock.patch.object(release, "run", return_value=run_result),
            mock.patch.object(release, "git_blob_sha256", return_value=SHA),
        ):
            record = release.publication_workflow_source_record(candidate, HEAD, BASE)
        self.assertEqual(record["workflowSourceCommit"], BASE)
        self.assertEqual(record["mergedCommit"], HEAD)

        with (
            mock.patch.object(release, "git", return_value=BASE),
            mock.patch.object(release, "run", return_value=run_result),
            mock.patch.object(release, "git_blob_sha256", return_value="b" * 64),
            self.assertRaisesRegex(release.ReleaseError, "source_hash_mismatch"),
        ):
            release.publication_workflow_source_record(candidate, HEAD, BASE)

    def test_release_workflow_keeps_app_credentials_out_of_repository_actions(self) -> None:
        workflow = (release.ROOT / ".github/workflows/publish-release.yml").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("actions/create-github-app-token", workflow)
        self.assertNotIn("TRUSTED_RELEASE_APP", workflow)
        self.assertNotIn("secrets.", workflow)
        self.assertNotIn("\n  revert:\n", workflow)
        action_required = workflow.split("\n  action-required:\n", 1)[1]
        self.assertNotIn("needs.revert", action_required)
        self.assertNotIn("revertResult", action_required)
        self.assertIn('"status": "action-required"', action_required)
        for source_policy_error in (
            "unsupported_release_tree_entry",
            "release_tree_file_too_large",
            "release_tree_file_count_exceeded",
            "release_tree_total_size_exceeded",
            "package_source_invalid",
            "package_source_too_large",
            "package_source_total_size_exceeded",
            "runtime_dependency_",
            "dependency_build_patch_",
            "symphony_priv_",
            "codex_schema_bundle_",
            "escript_runtime_",
            "installed_version_",
            "package_runtime_dependency_",
            "package_sbom_",
        ):
            self.assertIn(source_policy_error, workflow)

        build_classification = workflow.split(
            "      - name: Classify build outcome\n", 1
        )[1].split("\n  clean_install:\n", 1)[0]
        self.assertIn(
            'if test "$QUALITY_OUTCOME" = failure; then\n'
            "            kind=environment-or-evidence",
            build_classification,
        )
        self.assertNotIn("kind=merged-code", build_classification)

        clean_install = workflow.split("\n  clean_install:\n", 1)[1].split(
            "\n  publish:\n", 1
        )[0]
        self.assertIn("VERIFY_FAILURE_KIND", clean_install)
        self.assertIn("*clean_install_upstream_baseline_mismatch*", clean_install)
        self.assertIn("*symphony_priv_*", clean_install)
        self.assertIn("*codex_schema_bundle_*", clean_install)
        self.assertIn("*installed_version_*", clean_install)
        self.assertIn("*) failure_kind=environment-or-evidence ;;", clean_install)
        self.assertNotIn(
            'if test "$VERIFY_OUTCOME" = failure; then\n'
            "            kind=clean-install",
            clean_install,
        )

        make_all = (release.ROOT / ".github/workflows/make-all.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("@openai/codex@0.144.3", make_all)
        self.assertIn("codex-cli 0.144.3", make_all)
        self.assertLess(
            make_all.index("@openai/codex@0.144.3"),
            make_all.index("run: make all"),
        )

    def test_doctor_rejects_general_actions_as_trusted_producer(self) -> None:
        repo = {
            "allow_auto_merge": True,
            "delete_branch_on_merge": False,
            "allow_merge_commit": True,
            "allow_rebase_merge": False,
            "allow_squash_merge": False,
            "default_branch": "main",
            "full_name": release.REPOSITORY,
            "parent": {"full_name": release.UPSTREAM_REPOSITORY},
            "permissions": {"admin": True},
            "private": False,
        }
        protection = {
            "allow_deletions": {"enabled": False},
            "allow_force_pushes": {"enabled": False},
            "enforce_admins": {"enabled": True},
            "required_conversation_resolution": {"enabled": True},
            "required_pull_request_reviews": {},
            "required_status_checks": {
                "checks": [
                    {"app_id": release.GITHUB_ACTIONS_APP_ID, "context": release.REQUIRED_CONTEXT}
                ],
                "strict": True,
            },
        }

        def fake_api(path: str, *, allow_missing: bool = False):
            if path.endswith("/branches/main/protection"):
                return protection
            if path.endswith("/actions/permissions/workflow"):
                return {
                    "can_approve_pull_request_reviews": False,
                    "default_workflow_permissions": "read",
                }
            if path.endswith("/immutable-releases"):
                return {"enabled": True, "enforced_by_owner": True}
            if "/git/ref/tags/" in path or "/releases/tags/" in path:
                return None
            return repo

        upstream = (release.ROOT / "UPSTREAM_BASE").read_text(encoding="utf-8").strip()
        spec = (release.ROOT / "SPEC.md").read_bytes()

        def fake_git(*args: str, cwd=release.ROOT):
            command = " ".join(args)
            if command == "branch --show-current":
                return release.RELEASE_BRANCH
            if command == "status --porcelain=v1 --untracked-files=all":
                return ""
            if command == "remote get-url origin":
                return "https://github.com/farhaanlevy/symphony-studio.git"
            if command == "remote get-url upstream":
                return "https://github.com/openai/symphony.git"
            if command == "remote get-url --push upstream":
                return "DISABLED"
            raise AssertionError(command)

        with (
            mock.patch.object(release, "gh_api", side_effect=fake_api),
            mock.patch.object(release, "git", side_effect=fake_git),
            mock.patch.object(release, "git_bytes", return_value=spec),
            mock.patch.object(release, "run") as fake_run,
        ):
            fake_run.return_value.returncode = 0
            report = release.doctor_report(release.GITHUB_ACTIONS_APP_ID)
        self.assertIn("trusted_required_check_source", report["blockers"])
        self.assertNotIn("actions_permissions", report["blockers"])
        self.assertEqual(report["overall"], "blocked")
        self.assertRegex(upstream, r"^[0-9a-f]{40}$")

    def test_doctor_accepts_exact_detached_head_for_read_only_ci(self) -> None:
        repo = {
            "allow_auto_merge": True,
            "delete_branch_on_merge": False,
            "allow_merge_commit": True,
            "allow_rebase_merge": False,
            "allow_squash_merge": False,
            "default_branch": "main",
            "full_name": release.REPOSITORY,
            "parent": {"full_name": release.UPSTREAM_REPOSITORY},
            "permissions": {"admin": False},
            "private": False,
        }
        protection = {
            "allow_deletions": {"enabled": False},
            "allow_force_pushes": {"enabled": False},
            "enforce_admins": {"enabled": True},
            "required_conversation_resolution": {"enabled": True},
            "required_pull_request_reviews": {},
            "required_status_checks": {
                "checks": [{"app_id": 424242, "context": release.REQUIRED_CONTEXT}],
                "strict": True,
            },
        }

        def fake_api(path: str, *, allow_missing: bool = False):
            if path.endswith("/branches/main/protection"):
                return protection
            if path.endswith("/actions/permissions/workflow"):
                return {
                    "can_approve_pull_request_reviews": False,
                    "default_workflow_permissions": "read",
                }
            if path.endswith("/immutable-releases"):
                return {"enabled": True, "enforced_by_owner": False}
            if "/git/ref/tags/" in path or "/releases/tags/" in path:
                return None
            return repo

        upstream = (release.ROOT / "UPSTREAM_BASE").read_text(encoding="utf-8").strip()
        spec = (release.ROOT / "SPEC.md").read_bytes()

        def fake_git(*args: str, cwd=release.ROOT):
            command = " ".join(args)
            values = {
                "branch --show-current": "",
                "rev-parse HEAD": HEAD,
                "status --porcelain=v1 --untracked-files=all": "",
                "remote get-url origin": "https://github.com/farhaanlevy/symphony-studio.git",
                "remote get-url upstream": "https://github.com/openai/symphony.git",
                "remote get-url --push upstream": "DISABLED",
            }
            return values[command]

        with (
            mock.patch.object(release, "gh_api", side_effect=fake_api),
            mock.patch.object(release, "git", side_effect=fake_git),
            mock.patch.object(release, "git_bytes", return_value=spec),
            mock.patch.object(release, "run") as fake_run,
        ):
            fake_run.return_value.returncode = 0
            report = release.doctor_report(
                424242,
                expected_head=HEAD,
                require_admin=False,
            )
        self.assertEqual(report["blockers"], [])
        self.assertEqual(report["overall"], "pass")
        self.assertRegex(upstream, r"^[0-9a-f]{40}$")

    def test_manifest_transport_requires_hash_and_canonical_json(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "manifest.json"
            raw = release.canonical_json_bytes({"manifestVersion": 1})
            encoded = __import__("base64").b64encode(raw).decode("ascii")
            args = type(
                "Args",
                (),
                {"base64": encoded, "output": str(output), "sha256": release.sha256_bytes(raw)},
            )()
            release.command_manifest_decode(args)
            self.assertEqual(output.read_bytes(), raw)


if __name__ == "__main__":
    unittest.main()
