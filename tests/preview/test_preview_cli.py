# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import tarfile
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/preview"))

import preview_cli as preview  # noqa: E402


class PreviewCliTest(unittest.TestCase):
    def prepare_reset_root(self, parent: Path) -> Path:
        data_root = parent / "state" / "preview"
        with mock.patch.object(preview, "discover_worktrees", return_value=(ROOT,)):
            preview.prepare_data_root(data_root, ROOT)
        for directory in (
            data_root / "intent",
            data_root / "intent" / "projects",
            data_root / "intent" / "intents",
        ):
            directory.mkdir(mode=0o700, exist_ok=True)
            directory.chmod(0o700)
        return data_root

    def intent_document(
        self,
        intent_id: str,
        issue_identifier: str,
        *,
        issue_id: str | None = None,
        task_id: str = "task_demo",
    ) -> dict[str, object]:
        external_id = issue_id or f"linear-{issue_identifier.lower()}"
        return {
            "admission": {
                "event_id": "evt-demo",
                "issue_id": external_id,
                "run_id": "run-demo",
            },
            "intent_id": intent_id,
            "publication": {
                "tasks": {
                    task_id: {
                        "issue_id": external_id,
                        "issue_identifier": issue_identifier,
                        "status": "confirmed",
                    }
                }
            },
            "schema_version": 1,
            "start": {
                "issue_id": external_id,
                "issue_identifier": issue_identifier,
                "status": "admitted",
                "task_id": task_id,
            },
        }

    def write_intent(self, data_root: Path, document: dict[str, object]) -> Path:
        path = data_root / "intent" / "intents" / f"{document['intent_id']}.json"
        preview.write_private_json(path, document)
        return path

    def test_loopback_url_accepts_only_uncredentialed_loopback(self) -> None:
        self.assertEqual(
            preview.validate_loopback_url("http://127.0.0.1:4000/"),
            "http://127.0.0.1:4000",
        )
        self.assertEqual(
            preview.validate_loopback_url("https://localhost:4443"),
            "https://localhost:4443",
        )
        for invalid in (
            "http://example.test:4000",
            "http://user:secret@localhost:4000",
            "file:///tmp/index.html",
            "http://localhost:bad",
            "http://localhost:4000?token=secret",
            "http://localhost:4000/not-the-preview-root",
        ):
            with self.subTest(invalid=invalid), self.assertRaises(preview.PreviewError):
                preview.validate_loopback_url(invalid)

    def test_fixture_issues_can_never_be_reset(self) -> None:
        for identifier in ("SYM-1", "sym-2", " SYM-1 "):
            with self.subTest(identifier=identifier), self.assertRaises(
                preview.PreviewError
            ):
                preview.validate_issue_identifier(identifier)
        self.assertEqual(preview.validate_issue_identifier("sym-314"), "SYM-314")

    def test_intent_id_requires_the_exact_persisted_shape(self) -> None:
        self.assertEqual(
            preview.validate_intent_id(" intent_0123456789abcdef01234567 "),
            "intent_0123456789abcdef01234567",
        )
        for invalid in (
            "",
            "buildweek.copy-evidence-hash",
            "INTENT_0123456789ABCDEF01234567",
            "intent_01234567",
            "intent_0123456789abcdef0123456g",
            "../intent_0123456789abcdef01234567",
        ):
            with self.subTest(invalid=invalid), self.assertRaises(preview.PreviewError):
                preview.validate_intent_id(invalid)

    def test_reset_receipt_requires_zero_linear_mutations(self) -> None:
        valid = {
            "action": "preview_reset",
            "issueIdentifier": "SYM-314",
            "linearMutations": 0,
            "localRecordsRemoved": 4,
            "schemaVersion": 1,
            "status": "reset",
        }
        self.assertEqual(preview.validate_reset_receipt(valid, "SYM-314"), valid)
        for field, value in (
            ("linearMutations", 1),
            ("issueIdentifier", "SYM-1"),
            ("status", "completed"),
            ("localRecordsRemoved", -1),
        ):
            invalid = {**valid, field: value}
            with self.subTest(field=field), self.assertRaises(preview.PreviewError):
                preview.validate_reset_receipt(invalid, "SYM-314")

    def test_local_reset_removes_only_the_exact_bound_intent_and_prior_receipt(self) -> None:
        intent_id = "intent_0123456789abcdef01234567"
        other_intent_id = "intent_89abcdef0123456701234567"
        with tempfile.TemporaryDirectory() as temporary:
            data_root = self.prepare_reset_root(Path(temporary))
            target = self.write_intent(
                data_root, self.intent_document(intent_id, "SYM-314")
            )
            other = self.write_intent(
                data_root, self.intent_document(other_intent_id, "SYM-999")
            )
            prior_receipt = (
                data_root
                / "receipts"
                / f"reset-sym-314-{intent_id}.json"
            )
            preview.write_private_json(
                prior_receipt,
                {
                    "action": "preview_reset",
                    "intentId": intent_id,
                    "issueIdentifier": "SYM-314",
                    "linearMutations": 0,
                    "localRecordsRemoved": 1,
                    "recordedAt": 1,
                    "schemaVersion": 1,
                    "status": "reset",
                },
            )
            args = SimpleNamespace(
                data_root=str(data_root),
                dry_run=True,
                intent_id=intent_id,
                issue="SYM-314",
                json=True,
            )
            with (
                mock.patch.object(preview, "discover_worktrees", return_value=(ROOT,)),
                mock.patch.object(preview, "emit"),
                mock.patch.object(preview, "urlopen", side_effect=AssertionError("network")),
            ):
                self.assertEqual(preview.command_reset(args), preview.PASS)
            self.assertTrue(target.is_file())
            self.assertTrue(prior_receipt.is_file())

            args.dry_run = False
            with (
                mock.patch.object(preview, "discover_worktrees", return_value=(ROOT,)),
                mock.patch.object(preview, "emit") as emitted,
                mock.patch.object(preview, "urlopen", side_effect=AssertionError("network")),
            ):
                self.assertEqual(preview.command_reset(args), preview.PASS)
            self.assertFalse(target.exists())
            self.assertTrue(other.is_file())
            self.assertTrue(prior_receipt.is_file())
            receipt = json.loads(prior_receipt.read_text(encoding="utf-8"))
            self.assertEqual(receipt["intentId"], intent_id)
            self.assertEqual(receipt["issueIdentifier"], "SYM-314")
            self.assertEqual(receipt["localRecordsRemoved"], 2)
            self.assertEqual(receipt["linearMutations"], 0)
            self.assertEqual(emitted.call_args.args[0]["status"], "pass")
            self.assertEqual(
                list(data_root.glob(".reset-quarantine-*")),
                [],
            )

    def test_local_reset_fails_closed_on_ambiguous_or_corrupt_store(self) -> None:
        intent_id = "intent_0123456789abcdef01234567"
        other_intent_id = "intent_89abcdef0123456701234567"
        with tempfile.TemporaryDirectory() as temporary:
            data_root = self.prepare_reset_root(Path(temporary))
            target = self.write_intent(
                data_root, self.intent_document(intent_id, "SYM-314")
            )
            ambiguous = self.write_intent(
                data_root, self.intent_document(other_intent_id, "SYM-314")
            )
            with self.assertRaisesRegex(preview.PreviewError, "unique record"):
                preview.reset_intent_target(data_root, intent_id, "SYM-314")
            self.assertTrue(target.is_file())
            self.assertTrue(ambiguous.is_file())

            ambiguous.unlink()
            corrupt = data_root / "intent" / "intents" / f"{other_intent_id}.json"
            corrupt.write_text("not-json\n", encoding="utf-8")
            corrupt.chmod(0o600)
            with self.assertRaisesRegex(preview.PreviewError, "malformed"):
                preview.reset_intent_target(data_root, intent_id, "SYM-314")
            self.assertTrue(target.is_file())

    def test_local_reset_rolls_back_quarantine_when_receipt_cannot_publish(self) -> None:
        intent_id = "intent_0123456789abcdef01234567"
        with tempfile.TemporaryDirectory() as temporary:
            data_root = self.prepare_reset_root(Path(temporary))
            target = self.write_intent(
                data_root, self.intent_document(intent_id, "SYM-314")
            )
            args = SimpleNamespace(
                data_root=str(data_root),
                dry_run=False,
                intent_id=intent_id,
                issue="SYM-314",
                json=True,
            )
            with (
                mock.patch.object(preview, "discover_worktrees", return_value=(ROOT,)),
                mock.patch.object(
                    preview, "write_private_json", side_effect=OSError("simulated")
                ),
                self.assertRaisesRegex(preview.PreviewError, "could not be published"),
            ):
                preview.command_reset(args)
            self.assertTrue(target.is_file())
            self.assertEqual(list(data_root.glob(".reset-quarantine-*")), [])

    def test_reset_inventory_is_bounded_before_sorting(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            data_root = self.prepare_reset_root(Path(temporary))
            receipts = data_root / "receipts"
            preview.write_private_json(receipts / "one.json", {"safe": True})
            preview.write_private_json(receipts / "two.json", {"safe": True})
            with self.assertRaisesRegex(preview.PreviewError, "entry bound"):
                preview.bounded_private_file_inventory(
                    receipts, data_root, "preview receipt directory", limit=1
                )

    def test_launch_rebuilds_existing_runner_unless_no_build_is_explicit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "repo"
            runner = root / "elixir" / "bin" / "symphony"
            runner.parent.mkdir(parents=True)
            runner.write_text("stale\n", encoding="utf-8")
            runner.chmod(0o700)
            state = Path(temporary) / "state"
            state.mkdir()
            workflow = root / "elixir" / "WORKFLOW.md"
            workflow.write_text("---\nserver: {}\n---\n", encoding="utf-8")
            args = SimpleNamespace(
                data_root=str(state),
                dry_run=True,
                json=True,
                live_preflight=False,
                no_build=False,
                port=4000,
                workflow=None,
            )
            with (
                mock.patch.object(preview, "repository_root", return_value=root),
                mock.patch.object(preview, "validate_workflow", return_value=workflow),
                mock.patch.object(
                    preview,
                    "collect_preflight",
                    return_value={"checks": [], "schemaVersion": 1, "status": "pass"},
                ),
                mock.patch.object(preview, "prepare_data_root", return_value=state),
                mock.patch.object(preview, "launch_command", return_value=[str(runner)]),
                mock.patch.object(preview, "emit"),
                mock.patch.object(preview, "build_foundation") as build,
            ):
                self.assertEqual(preview.command_launch(args), preview.PASS)
                build.assert_called_once_with(root)

            args.no_build = True
            with (
                mock.patch.object(preview, "repository_root", return_value=root),
                mock.patch.object(preview, "validate_workflow", return_value=workflow),
                mock.patch.object(
                    preview,
                    "collect_preflight",
                    return_value={"checks": [], "schemaVersion": 1, "status": "pass"},
                ),
                mock.patch.object(preview, "prepare_data_root", return_value=state),
                mock.patch.object(preview, "launch_command", return_value=[str(runner)]),
                mock.patch.object(preview, "emit"),
                mock.patch.object(preview, "build_foundation") as build,
            ):
                self.assertEqual(preview.command_launch(args), preview.PASS)
                build.assert_not_called()

            runner.unlink()
            with (
                mock.patch.object(preview, "repository_root", return_value=root),
                mock.patch.object(preview, "validate_workflow", return_value=workflow),
                mock.patch.object(
                    preview,
                    "collect_preflight",
                    return_value={"checks": [], "schemaVersion": 1, "status": "pass"},
                ),
                mock.patch.object(preview, "prepare_data_root", return_value=state),
                mock.patch.object(preview, "launch_command", return_value=[str(runner)]),
                mock.patch.object(preview, "emit"),
                mock.patch.object(preview, "build_foundation") as build,
                self.assertRaisesRegex(preview.PreviewBlocked, "not built"),
            ):
                preview.command_launch(args)
            build.assert_not_called()

    def test_data_root_rejects_worktree_intersection_and_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            worktree = parent / "worktree"
            worktree.mkdir()
            outside = parent / "state" / "preview"
            with mock.patch.object(preview, "discover_worktrees", return_value=(worktree,)):
                with self.assertRaisesRegex(preview.PreviewError, "worktree"):
                    preview.validate_data_root(worktree / "state", worktree, create=True)
                canonical = preview.validate_data_root(outside, worktree, create=True)
                self.assertEqual(canonical, outside.resolve())
                self.assertEqual(stat.S_IMODE(canonical.stat().st_mode), 0o700)
                linked = parent / "linked"
                linked.symlink_to(canonical, target_is_directory=True)
                with self.assertRaisesRegex(preview.PreviewError, "symlink"):
                    preview.validate_data_root(linked / "child", worktree, create=True)

    def test_prepare_data_root_writes_owner_only_marker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "repo"
            root.mkdir()
            (root / "UPSTREAM_BASE").write_text("a" * 40 + "\n", encoding="ascii")
            (root / "BUILD_WEEK_DELTA.md").write_text("delta\n", encoding="utf-8")
            state_root = Path(temporary) / "state" / "preview"
            with mock.patch.object(preview, "discover_worktrees", return_value=(root,)):
                actual = preview.prepare_data_root(state_root, root)
            marker = actual / preview.MARKER_NAME
            self.assertEqual(stat.S_IMODE(marker.stat().st_mode), 0o600)
            value = json.loads(marker.read_text(encoding="utf-8"))
            self.assertEqual(value["application"], preview.APP_MARKER)
            self.assertNotIn(str(root), marker.read_text(encoding="utf-8"))

    def test_public_audit_detects_media_and_secret_material(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            safe = root / "README.md"
            safe.write_text("safe public text\n", encoding="utf-8")
            clean = preview.audit_files(root, (safe,))
            self.assertEqual(clean["status"], "pass")
            media = root / "recording.mp4"
            media.write_bytes(b"not-real-media")
            secret = root / "leak.txt"
            secret.write_text(
                "lin_" + "api_" + "ABCDEFGHIJKLMNOPQRSTUVWXYZ123456\n",
                encoding="ascii",
            )
            dirty = preview.audit_files(root, (safe, media, secret))
            self.assertEqual(dirty["status"], "failed")
            self.assertEqual(
                {(row["kind"], row["path"]) for row in dirty["findings"]},
                {
                    ("submission media", "recording.mp4"),
                    ("Linear-style token", "leak.txt"),
                },
            )

    def test_public_audit_allows_only_the_exact_pinned_upstream_demo(self) -> None:
        upstream_media = ROOT / ".github/media/symphony-demo.mp4"
        self.assertEqual(
            preview.audit_files(ROOT, (upstream_media,))["status"],
            "pass",
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            media = root / ".github/media/symphony-demo.mp4"
            media.parent.mkdir(parents=True)
            media.write_bytes(b"changed downstream media")
            report = preview.audit_files(root, (media,))
            self.assertEqual(report["status"], "failed")
            self.assertEqual(
                report["findings"],
                [
                    {
                        "kind": "submission media",
                        "path": ".github/media/symphony-demo.mp4",
                    }
                ],
            )

    def test_public_audit_rejects_zero_file_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = preview.audit_files(root, ())
            self.assertEqual(report["status"], "failed")
            self.assertEqual(report["filesScanned"], 0)

    def test_clean_launch_workflow_is_external_and_empty_tracker_only(self) -> None:
        value = preview.clean_launch_workflow(Path("/private/workspaces"))
        self.assertIn("kind: memory", value)
        self.assertIn('root: "/private/workspaces"', value)
        self.assertNotIn("LINEAR_API_KEY", value)
        self.assertNotIn("SYM-1", value)
        self.assertNotIn("SYM-2", value)

    def test_clean_launch_archive_rejects_links_before_escape(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "source.tar"
            destination = root / "destination"
            destination.mkdir()
            with tarfile.open(archive, "w") as bundle:
                regular = tarfile.TarInfo("README.md")
                payload = b"safe\n"
                regular.size = len(payload)
                bundle.addfile(regular, io.BytesIO(payload))
                link = tarfile.TarInfo("escape")
                link.type = tarfile.SYMTYPE
                link.linkname = "../outside"
                bundle.addfile(link)
            with self.assertRaisesRegex(preview.PreviewError, "link or special"):
                preview.safe_extract_tar(archive, destination)
            self.assertTrue((destination / "README.md").is_file())
            self.assertFalse((root / "outside").exists())

    def test_safe_child_environment_drops_credential_like_names(self) -> None:
        fake_environment = {
            "PATH": "/bin",
            "HOME": "/safe-home",
            "LINEAR_API_KEY": "should-not-pass",
            "OPENAI_TOKEN": "should-not-pass",
            "UNRELATED": "should-not-pass",
        }
        with mock.patch.dict(os.environ, fake_environment, clear=True):
            actual = preview.safe_child_environment(home=Path("/isolated-home"))
        self.assertEqual(actual["HOME"], "/isolated-home")
        self.assertEqual(actual["PATH"], "/bin")
        self.assertNotIn("LINEAR_API_KEY", actual)
        self.assertNotIn("OPENAI_TOKEN", actual)
        self.assertNotIn("UNRELATED", actual)

    def test_command_runner_enforces_output_and_time_bounds(self) -> None:
        with self.assertRaisesRegex(preview.PreviewError, "output exceeded"):
            preview.run_command(
                [sys.executable, "-c", "print('x' * 4096)"],
                cwd=ROOT,
                max_output_bytes=128,
            )
        with self.assertRaisesRegex(preview.PreviewError, "timed out"):
            preview.run_command(
                [sys.executable, "-c", "import time; time.sleep(10)"],
                cwd=ROOT,
                timeout=0.1,
            )

    def test_workflow_rejects_a_symlink_even_when_its_target_is_regular(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "workflow.md"
            target.write_text("---\nserver:\n  host: 127.0.0.1\n---\n", encoding="utf-8")
            link = root / "linked-workflow.md"
            link.symlink_to(target)
            with self.assertRaisesRegex(preview.PreviewError, "symlink"):
                preview.validate_workflow(link)


if __name__ == "__main__":
    unittest.main()
