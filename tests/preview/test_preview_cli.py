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
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/preview"))

import preview_cli as preview  # noqa: E402


class PreviewCliTest(unittest.TestCase):
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

    def test_intent_key_has_a_bounded_filename_safe_shape(self) -> None:
        self.assertEqual(
            preview.validate_intent_key("BuildWeek.Owner-1"), "buildweek.owner-1"
        )
        for invalid in ("", "../escape", "with spaces", "x" * 129):
            with self.subTest(invalid=invalid), self.assertRaises(preview.PreviewError):
                preview.validate_intent_key(invalid)

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
