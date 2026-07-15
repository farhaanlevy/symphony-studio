#!/usr/bin/env python3
# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0

from __future__ import annotations

import argparse
from contextlib import contextmanager, redirect_stderr
import copy
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import codex_schema
import run_codex_schema_tests


FOCUSED_TEST_FILES = (
    "test/symphony_elixir/codex_schema_bundle_test.exs",
    "test/symphony_elixir/app_server_test.exs",
    "test/symphony_elixir/dynamic_tool_test.exs",
    "test/symphony_elixir/fake_codex_app_server_test.exs",
    "test/symphony_elixir/fake_linear_test.exs",
    "test/symphony_elixir/network_hermeticity_test.exs",
)


class StrictJsonTest(unittest.TestCase):
    def test_duplicate_object_keys_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "duplicate.json"
            path.write_text('{"outer":{"value":1,"value":2}}\n', encoding="utf-8")

            with self.assertRaisesRegex(codex_schema.SchemaError, "duplicate object key 'value'"):
                codex_schema.read_json(path)

    def test_non_finite_numbers_are_rejected(self) -> None:
        for constant in ("NaN", "Infinity", "-Infinity"):
            with self.subTest(constant=constant), tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary) / "non-finite.json"
                path.write_text(f'{{"value":{constant}}}\n', encoding="utf-8")

                with self.assertRaisesRegex(codex_schema.SchemaError, "non-finite number"):
                    codex_schema.read_json(path)


class MatrixValidationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.bundle = codex_schema.SCHEMA_ROOT / codex_schema.read_version()
        cls.matrix = codex_schema.read_json(codex_schema.MATRIX_SOURCE)

    def assert_schema_tamper_rejected(
        self, relative: str, mutate, expected_error: str
    ) -> None:
        target = self.bundle / relative
        original_read_json = codex_schema.read_json
        tampered = copy.deepcopy(original_read_json(target))
        mutate(tampered)

        def read_json(path: Path):
            if Path(path) == target:
                return copy.deepcopy(tampered)
            return original_read_json(path)

        with mock.patch.object(codex_schema, "read_json", side_effect=read_json):
            with self.assertRaisesRegex(codex_schema.SchemaError, expected_error):
                codex_schema.validate_matrix(self.bundle, self.matrix)

    def test_source_matrix_matches_exact_lock_and_generated_contract(self) -> None:
        self.assertEqual(
            codex_schema.matrix_canonical_sha256(self.matrix),
            codex_schema.EXPECTED_MATRIX_CANONICAL_SHA256,
        )
        codex_schema.validate_matrix(self.bundle, self.matrix)

    def test_typescript_artifact_tamper_is_rejected_by_static_lock(self) -> None:
        entries = codex_schema.artifact_entries(self.bundle)
        tampered = list(entries)
        index = next(
            index for index, entry in enumerate(tampered) if entry[0].startswith("typescript/")
        )
        path, _digest, size = tampered[index]
        tampered[index] = (path, "0" * 64, size)
        with mock.patch.object(codex_schema, "artifact_entries", return_value=tampered):
            with self.assertRaisesRegex(
                codex_schema.SchemaError, "generated artifact bundle SHA-256 mismatch"
            ):
                codex_schema.validate_matrix(self.bundle, self.matrix)

    def test_semantically_valid_matrix_tamper_is_rejected_by_canonical_lock(self) -> None:
        matrix = copy.deepcopy(self.matrix)
        field = next(
            entry for entry in matrix["fields"] if entry["id"] == "dynamic_tool.response_success"
        )
        field["payloadPath"] = "success.tampered"

        with self.assertRaisesRegex(codex_schema.SchemaError, "canonical SHA-256 mismatch"):
            codex_schema.validate_matrix(self.bundle, matrix)

    def test_top_level_shape_and_method_response_mapping_are_exact(self) -> None:
        matrix = copy.deepcopy(self.matrix)
        matrix["unexpected"] = []
        with self.assertRaisesRegex(codex_schema.SchemaError, "top-level keys"):
            codex_schema.validate_matrix(self.bundle, matrix)

        matrix = copy.deepcopy(self.matrix)
        method = next(entry for entry in matrix["methods"] if entry["id"] == "dynamic_tool_call")
        method["responseSchema"] = "json/ToolRequestUserInputResponse.json"
        with self.assertRaisesRegex(codex_schema.SchemaError, "method contract mismatch"):
            codex_schema.validate_matrix(self.bundle, matrix)

    def test_required_entries_and_direct_properties_fail_closed(self) -> None:
        matrix = copy.deepcopy(self.matrix)
        field = next(
            entry for entry in matrix["fields"] if entry["id"] == "turn_start.thread_id"
        )
        field["absentBehavior"] = "safe_block"
        with self.assertRaisesRegex(codex_schema.SchemaError, "must fail closed"):
            codex_schema.validate_matrix(self.bundle, matrix)

        matrix = copy.deepcopy(self.matrix)
        field = next(
            entry for entry in matrix["fields"] if entry["id"] == "turn_start.thread_id"
        )
        del field["schemaRequired"]
        with self.assertRaisesRegex(
            codex_schema.SchemaError, "must declare boolean schemaRequired"
        ):
            codex_schema.validate_matrix(self.bundle, matrix)

    def test_assertion_and_diagnostic_data_handling_are_bounded(self) -> None:
        matrix = copy.deepcopy(self.matrix)
        field = next(
            entry for entry in matrix["fields"] if entry["id"] == "turn_start.multi_agent_mode"
        )
        field["r002Assertion"] = "runtime_supported"
        with self.assertRaisesRegex(codex_schema.SchemaError, "invalid field r002Assertion"):
            codex_schema.validate_matrix(self.bundle, matrix)

        matrix = copy.deepcopy(self.matrix)
        field = next(entry for entry in matrix["fields"] if entry["id"] == "initialize.codex_home")
        field["dataHandling"] = "persist_raw"
        with self.assertRaisesRegex(codex_schema.SchemaError, "diagnostic_redacted_only"):
            codex_schema.validate_matrix(self.bundle, matrix)

    def test_scalar_enums_flatten_recursively_through_one_of(self) -> None:
        schema = {
            "oneOf": [
                {"enum": ["first"]},
                {"oneOf": [{"enum": ["second"]}, {"enum": ["third"]}]},
            ]
        }
        self.assertEqual(
            codex_schema.scalar_enum_values(schema),
            ["first", "second", "third"],
        )

    def test_enum_equals_rejects_branches_without_non_empty_scalar_enums(self) -> None:
        probes = (
            (
                "json/v2/ConsumeAccountRateLimitResetCreditResponse.json",
                "/definitions/ConsumeAccountRateLimitResetCreditOutcome/oneOf",
                {"type": "number"},
            ),
            (
                "json/DynamicToolCallResponse.json",
                "/definitions/DynamicToolCallOutputContentItem/oneOf",
                {
                    "type": "object",
                    "required": ["type"],
                    "properties": {"type": {"type": "string"}},
                },
            ),
        )
        for relative, pointer, branch in probes:
            with self.subTest(relative=relative):
                self.assert_schema_tamper_rejected(
                    relative,
                    lambda document, pointer=pointer, branch=branch: codex_schema.resolve_pointer(
                        document, pointer
                    ).append(branch),
                    "non-empty scalar enum",
                )

    def test_consulted_required_keywords_are_unique_non_empty_string_lists(self) -> None:
        probes = (
            (
                "json/v2/ItemStartedNotification.json",
                lambda document: document["definitions"]["ThreadItem"]["oneOf"][0].__setitem__(
                    "required", "id,type"
                ),
            ),
            (
                "json/v2/TurnStartParams.json",
                lambda document: document["required"].append(123),
            ),
            (
                "json/v2/TurnStartParams.json",
                lambda document: document["required"].append(document["required"][0]),
            ),
            (
                "json/v2/TurnStartParams.json",
                lambda document: document["required"].append(""),
            ),
        )
        for index, (relative, mutate) in enumerate(probes):
            with self.subTest(index=index, relative=relative):
                self.assert_schema_tamper_rejected(
                    relative,
                    mutate,
                    "required must be a list of unique non-empty strings",
                )

    def test_refs_reachability_types_and_union_shapes_are_exact(self) -> None:
        probes = (
            (
                "json/v1/InitializeParams.json",
                lambda document: document["properties"]["clientInfo"].__setitem__(
                    "$ref", "#/definitions/InitializeCapabilities"
                ),
                "not reachable from the schema payload root",
            ),
            (
                "json/v2/TurnStartParams.json",
                lambda document: document["properties"]["threadId"].__setitem__(
                    "type", "integer"
                ),
                "field semantic SHA-256 mismatch",
            ),
            (
                "json/v2/ItemStartedNotification.json",
                lambda document: document["definitions"]["ThreadItem"]["oneOf"].append(
                    {
                        "type": "object",
                        "required": ["id", "type"],
                        "properties": {
                            "id": {"type": "integer"},
                            "type": {"type": "integer"},
                        },
                    }
                ),
                "field semantic SHA-256 mismatch",
            ),
            (
                "json/ClientRequest.json",
                lambda document: next(
                    variant
                    for variant in document["oneOf"]
                    if variant.get("properties", {}).get("method", {}).get("enum")
                    == ["turn/start"]
                )["properties"]["params"].__setitem__(
                    "$ref", "https://example.invalid/TurnStartParams"
                ),
                "exact local JSON pointer",
            ),
            (
                "json/ClientRequest.json",
                lambda document: document.setdefault("definitions", {}).__setitem__(
                    "DeadInitializeMethodContract",
                    document["oneOf"].pop(
                        next(
                            index
                            for index, variant in enumerate(document["oneOf"])
                            if variant.get("properties", {}).get("method", {}).get("enum")
                            == ["initialize"]
                        )
                    ),
                ),
                "matrix method 'initialize' is absent",
            ),
            (
                "json/ClientRequest.json",
                lambda document: next(
                    variant
                    for variant in document["oneOf"]
                    if variant.get("properties", {}).get("method", {}).get("enum")
                    == ["initialize"]
                )["properties"]["method"].__setitem__("type", "integer"),
                "must have one exact string method",
            ),
            (
                "json/ClientRequest.json",
                lambda document: next(
                    variant
                    for variant in document["oneOf"]
                    if variant.get("properties", {}).get("method", {}).get("enum")
                    == ["initialize"]
                )["required"].remove("params"),
                "invalid required envelope",
            ),
            (
                "json/ClientRequest.json",
                lambda document: next(
                    variant
                    for variant in document["oneOf"]
                    if variant.get("properties", {}).get("method", {}).get("enum")
                    == ["initialize"]
                ).__setitem__("additionalProperties", True),
                "changes the pinned envelope policy",
            ),
            (
                "json/v2/TurnStartParams.json",
                lambda document: document.__setitem__(
                    "$ref", "#/definitions/AbsolutePathBuf"
                ),
                "not reachable from the schema payload root",
            ),
            (
                "json/v2/TurnStartParams.json",
                lambda document: document.__setitem__("enum", []),
                "schema bundle semantic SHA-256 mismatch",
            ),
            (
                "json/v2/TurnStartParams.json",
                lambda document: document.__setitem__("type", "array"),
                "schema bundle semantic SHA-256 mismatch",
            ),
        )
        for relative, mutate, expected_error in probes:
            with self.subTest(relative=relative):
                self.assert_schema_tamper_rejected(relative, mutate, expected_error)

    def test_definition_equality_tamper_is_rejected(self) -> None:
        matrix = copy.deepcopy(self.matrix)
        equality = matrix["definitionEqualities"][0]
        equality["rightPointer"] = "/definitions/RateLimitWindow"
        with self.assertRaisesRegex(
            codex_schema.SchemaError, "definition equality .* does not match"
        ):
            codex_schema.validate_matrix(self.bundle, matrix)

    def test_negative_capability_selectors_scan_files_and_recursive_schema(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary)
            schema = bundle / "json" / "Forbidden.json"
            schema.parent.mkdir()
            codex_schema.write_json(
                schema,
                {
                    "$ref": "#/definitions/Forbidden",
                    "definitions": {"Forbidden": {"type": "object"}},
                    "properties": {"agentConcurrency": {"type": "integer"}},
                    "title": "ForbiddenTitle",
                },
            )
            cases = {
                "forbiddenDefinition": "Forbidden",
                "forbiddenFileNamePattern": r"^Forbidden\.json$",
                "forbiddenPropertyNamePattern": r"(?i)agentConcurrency",
                "forbiddenReferencePattern": r"(?:^|/)Forbidden(?:#|$)",
                "forbiddenSchemaTitle": "ForbiddenTitle",
            }
            for selector, forbidden in cases.items():
                with self.subTest(selector=selector):
                    entry = {
                        "expect": "absent",
                        "id": f"negative.{selector}",
                        "schemaGlobs": ["json/*.json"],
                        selector: forbidden,
                    }
                    with self.assertRaisesRegex(codex_schema.SchemaError, "negative capability"):
                        codex_schema.validate_negative_capabilities(bundle, [entry])

            codex_schema.validate_negative_capabilities(
                bundle,
                [
                    {
                        "expect": "absent",
                        "forbiddenPropertyNamePattern": "doesNotExist",
                        "id": "negative.safe",
                        "schemaGlobs": ["json/*.json"],
                    }
                ],
            )

    def test_negative_capability_requires_a_valid_selector(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary)
            schema = bundle / "json" / "Safe.json"
            schema.parent.mkdir()
            codex_schema.write_json(schema, {"title": "Safe"})
            baseline = {
                "expect": "absent",
                "id": "negative.invalid",
                "schemaGlobs": ["json/*.json"],
            }
            with self.assertRaisesRegex(codex_schema.SchemaError, "no forbidden selector"):
                codex_schema.validate_negative_capabilities(bundle, [baseline])

            invalid_regex = dict(baseline, forbiddenReferencePattern="[")
            with self.assertRaisesRegex(
                codex_schema.SchemaError, "invalid forbiddenReferencePattern"
            ):
                codex_schema.validate_negative_capabilities(bundle, [invalid_regex])


class FixtureProvenanceTest(unittest.TestCase):
    def test_focused_test_paths_and_source_inventory_match_independent_baseline(self) -> None:
        self.assertEqual(codex_schema.FIXTURE_TEST_FILES, FOCUSED_TEST_FILES)

        expected = {
            "CODEX_LOCK.json",
            "CODEX_VERSION",
            "elixir/Makefile",
            "elixir/mise.toml",
            "elixir/mix.exs",
            "elixir/mix.lock",
            "elixir/priv/codex_schema/CODEX_VERSION",
            f"elixir/priv/codex_schema/{codex_schema.read_version()}/SEMANTIC-SHA256SUMS",
            "elixir/test/test_helper.exs",
            "scripts/codex_schema.py",
            "scripts/codex_schema_matrix.json",
            "scripts/run_codex_schema_tests.py",
            "scripts/test_codex_schema.py",
            *(f"elixir/{path}" for path in FOCUSED_TEST_FILES),
        }
        expected.update(relative_files(codex_schema.REPO_ROOT / "elixir" / "lib", "*.ex"))
        expected.update(relative_files(codex_schema.REPO_ROOT / "elixir" / "config", "*.exs"))
        expected.update(relative_files(codex_schema.REPO_ROOT / "elixir" / "test" / "support", "*"))
        expected.update(relative_files(codex_schema.REPO_ROOT / "elixir" / "priv" / "static", "*"))

        inventory = codex_schema.fixture_source_files()
        self.assertEqual(tuple(sorted(expected)), inventory)
        self.assertEqual(tuple(sorted(set(inventory))), inventory)

    def test_fixture_digest_changes_when_a_bound_source_changes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo_root = Path(temporary)
            paths = {
                "CODEX_LOCK.json",
                "CODEX_VERSION",
                "elixir/Makefile",
                "elixir/config/test.exs",
                "elixir/lib/example.ex",
                "elixir/mise.toml",
                "elixir/mix.exs",
                "elixir/mix.lock",
                "elixir/priv/codex_schema/CODEX_VERSION",
                "elixir/priv/codex_schema/0.144.3/SEMANTIC-SHA256SUMS",
                "elixir/priv/static/dashboard.css",
                "elixir/priv/static/favicon.png",
                "elixir/test/support/nested/fixture.txt",
                "elixir/test/test_helper.exs",
                "scripts/codex_schema.py",
                "scripts/codex_schema_matrix.json",
                "scripts/run_codex_schema_tests.py",
                "scripts/test_codex_schema.py",
                *(f"elixir/{path}" for path in FOCUSED_TEST_FILES),
            }
            for relative in paths:
                path = repo_root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(f"original:{relative}\n", encoding="utf-8")

            favicon = repo_root / "elixir/priv/static/favicon.png"
            favicon.write_bytes(b"\x89PNG\r\n\x00")

            with (
                mock.patch.object(codex_schema, "REPO_ROOT", repo_root),
                mock.patch.object(codex_schema, "read_version", return_value="0.144.3"),
            ):
                before = codex_schema.fixture_source_summary()
                favicon.write_bytes(b"\x89PNG\n\x00")
                binary_changed = codex_schema.fixture_source_summary()
                favicon.write_bytes(b"\x89PNG\r\n\x00")
                (repo_root / "elixir/lib/example.ex").write_text("mutated\n", encoding="utf-8")
                after = codex_schema.fixture_source_summary()

            self.assertEqual(before["fileCount"], len(paths))
            self.assertEqual(after["fileCount"], len(paths))
            self.assertNotEqual(before["sha256"], binary_changed["sha256"])
            self.assertNotEqual(before["sha256"], after["sha256"])

    def test_fixture_evidence_binds_artifacts_version_and_matrix(self) -> None:
        manifest = base_manifest()
        with fixture_summary_patch():
            evidence = codex_schema.sealed_fixture_evidence("2026-07-15", manifest)

        self.assertEqual(evidence["codexVersion"], codex_schema.read_version())
        self.assertEqual(evidence["artifactBundleSha256"], "a" * 64)
        self.assertEqual(evidence["schemaBundleSha256"], "b" * 64)
        self.assertEqual(evidence["matrixSha256"], "c" * 64)
        self.assertEqual(evidence["testCount"], 55)
        self.assertEqual(evidence["dependencyCommand"], list(codex_schema.FIXTURE_DEPENDENCY_COMMAND))
        self.assertEqual(
            evidence["dependencyCompileCommand"],
            list(codex_schema.FIXTURE_DEPENDENCY_COMPILE_COMMAND),
        )
        self.assertEqual(
            evidence["sourceHashAlgorithm"],
            "sha256-text-lf-binary-raw-relative-path-v2",
        )

    def test_under_test_candidate_requires_explicit_candidate_verification(self) -> None:
        with fixture_summary_patch():
            candidate = codex_schema.build_test_manifest(base_manifest(), "2026-07-15")
            with self.assertRaisesRegex(codex_schema.SchemaError, "not sealed"):
                codex_schema.validate_compatibility(candidate, require_fixture_seal=True)
            codex_schema.validate_compatibility(
                candidate,
                require_fixture_seal=True,
                allow_fixture_candidate=True,
            )

        self.assertEqual(candidate["compatibility"]["fixtures"], "under_test")

    def test_fixture_date_may_equal_or_follow_generation_but_not_precede_it(self) -> None:
        for tested_at in ("2026-07-14", "2026-07-15"):
            with self.subTest(tested_at=tested_at):
                manifest = base_manifest()
                manifest["compatibility"]["testedAt"] = tested_at
                codex_schema.validate_compatibility(manifest, require_fixture_seal=False)

        manifest = base_manifest()
        manifest["compatibility"]["testedAt"] = "2026-07-13"
        with self.assertRaisesRegex(codex_schema.SchemaError, "cannot precede"):
            codex_schema.validate_compatibility(manifest, require_fixture_seal=False)

    def test_source_only_reseal_preserves_generation_date(self) -> None:
        manifest = base_manifest()
        with fixture_summary_patch():
            first = codex_schema.build_sealed_manifest(manifest, "2026-07-15")
            second = codex_schema.build_sealed_manifest(first, "2026-07-16")
            codex_schema.validate_compatibility(second, require_fixture_seal=True)

        self.assertEqual(first["generation"]["generatedAt"], "2026-07-14")
        self.assertEqual(second["generation"]["generatedAt"], "2026-07-14")
        self.assertEqual(second["compatibility"]["testedAt"], "2026-07-16")
        self.assertEqual(second["compatibility"]["fixtureEvidence"]["testedAt"], "2026-07-16")


class MetadataPathSafetyTest(unittest.TestCase):
    def test_regular_file_check_rejects_symlink_and_directory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            target = root / "target.json"
            target.write_text("{}\n", encoding="utf-8")
            link = root / "link.json"
            link.symlink_to(target)

            with self.assertRaisesRegex(codex_schema.SchemaError, "symbolic link"):
                codex_schema.regular_file_identity(link)
            with self.assertRaisesRegex(codex_schema.SchemaError, "not a regular file"):
                codex_schema.regular_file_identity(root)
            with self.assertRaisesRegex(codex_schema.SchemaError, "symbolic link"):
                codex_schema.read_json(link)

    def test_intermediate_symlink_swap_is_rejected_for_reads_and_writes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            legitimate = root / "legitimate"
            attacker = root / "attacker"
            legitimate.mkdir()
            attacker.mkdir()
            (legitimate / "value.txt").write_text("trusted\n", encoding="utf-8")
            attacker_value = attacker / "value.txt"
            attacker_value.write_text("attacker\n", encoding="utf-8")

            selected = codex_schema.regular_relative_file(root, "legitimate/value.txt")
            preserved = root / "preserved"
            legitimate.rename(preserved)
            legitimate.symlink_to(attacker, target_is_directory=True)

            with self.assertRaisesRegex(codex_schema.SchemaError, "symbolic link"):
                codex_schema.read_regular_bytes(selected)
            with self.assertRaisesRegex(codex_schema.SchemaError, "symbolic link"):
                codex_schema.write_bytes_fsync(
                    legitimate / "new.txt", b"blocked\n", create=True
                )
            self.assertEqual(attacker_value.read_text(encoding="utf-8"), "attacker\n")
            self.assertFalse((attacker / "new.txt").exists())

    def test_late_directory_insertion_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "first.txt").write_text("first\n", encoding="utf-8")
            original = codex_schema.directory_fingerprint
            calls = 0

            def insert_after_first_listing(descriptor):
                nonlocal calls
                fingerprint = original(descriptor)
                calls += 1
                if calls == 1:
                    (root / "late.txt").write_text("late\n", encoding="utf-8")
                return fingerprint

            with mock.patch.object(
                codex_schema,
                "directory_fingerprint",
                side_effect=insert_after_first_listing,
            ):
                with self.assertRaisesRegex(codex_schema.SchemaError, "changed during traversal"):
                    codex_schema.regular_tree_files(root)

            self.assertTrue((root / "late.txt").is_file())

    def test_same_size_in_place_rewrite_is_detected_during_read(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "input.bin"
            path.write_bytes(b"original")
            original_read = codex_schema.os.read
            tampered = False

            def tampering_read(descriptor, size):
                nonlocal tampered
                result = original_read(descriptor, size)
                if result and not tampered:
                    tampered = True
                    path.write_bytes(b"attacker")
                return result

            with mock.patch.object(codex_schema.os, "read", side_effect=tampering_read):
                with self.assertRaisesRegex(codex_schema.SchemaError, "changed while reading"):
                    codex_schema.read_regular_bytes(path)

            self.assertTrue(tampered)

    def test_artifact_and_snapshot_source_trees_reject_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = root / "bundle"
            for relative in ("json", "typescript", "experimental/json", "experimental/typescript"):
                (bundle / relative).mkdir(parents=True, exist_ok=True)
            target = root / "target.json"
            target.write_text("{}\n", encoding="utf-8")
            (bundle / "json/link.json").symlink_to(target)

            with self.assertRaisesRegex(codex_schema.SchemaError, "symbolic link"):
                codex_schema.artifact_entries(bundle)

            source = root / "source"
            destination = root / "destination"
            source.mkdir()
            (source / "link").symlink_to(target)
            with self.assertRaisesRegex(codex_schema.SchemaError, "symbolic link"):
                codex_schema.copy_regular_tree(source, destination)

    def test_bundle_root_and_manifest_shapes_are_exact(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for relative in ("json", "typescript", "experimental/json", "experimental/typescript"):
                (root / relative).mkdir(parents=True, exist_ok=True)
            for relative in ("SEMANTIC-SHA256SUMS", "manifest.json", "method-field-matrix.json"):
                (root / relative).write_text("{}\n", encoding="utf-8")
            (root / "unexpected.txt").write_text("no\n", encoding="utf-8")
            with self.assertRaisesRegex(codex_schema.SchemaError, "root shape mismatch"):
                codex_schema.validate_bundle_root_shape(root)

        bundle = codex_schema.SCHEMA_ROOT / codex_schema.read_version()
        manifest = codex_schema.read_json(bundle / "manifest.json")
        manifest["unexpected"] = True
        with tempfile.TemporaryDirectory() as temporary:
            manifest_path = Path(temporary) / "manifest.json"
            codex_schema.write_json(manifest_path, manifest)
            with self.assertRaisesRegex(codex_schema.SchemaError, "manifest root keys mismatch"):
                codex_schema.verify_bundle(bundle, manifest_path=manifest_path)

    def test_bundle_verifier_rejects_reserved_manifest_residue_first(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary)
            (bundle / ".manifest.crash.candidate").write_text("{}\n", encoding="utf-8")

            with self.assertRaisesRegex(codex_schema.SchemaError, "reserved schema manifest residue"):
                codex_schema.verify_bundle(bundle)


class SnapshotExecutionTest(unittest.TestCase):
    def test_focused_tests_use_read_only_snapshot_and_exact_success_summary(self) -> None:
        with snapshot_execution_workspace() as (snapshot_root, source, manifest_path):
            with tempfile.TemporaryDirectory() as worktree:
                worktree_source = Path(worktree) / "source.ex"
                worktree_source.write_text("original\n", encoding="utf-8")
                calls = 0

                def run(command, **kwargs):
                    nonlocal calls
                    calls += 1
                    self.assertEqual(kwargs["cwd"], snapshot_root / "elixir")
                    self.assertEqual(
                        kwargs["deadline_seconds"],
                        codex_schema.FIXTURE_CHILD_DEADLINE_SECONDS,
                    )
                    self.assertEqual(kwargs["max_output_bytes"], codex_schema.MAX_CHILD_OUTPUT_BYTES)
                    self.assertEqual(kwargs["env"]["NO_COLOR"], "1")
                    self.assertEqual(kwargs["env"]["CLICOLOR"], "0")
                    self.assertNotIn("LINEAR_API_KEY", kwargs["env"])
                    self.assertNotIn("OPENAI_API_KEY", kwargs["env"])
                    self.assertNotIn("GITHUB_TOKEN", kwargs["env"])
                    self.assertNotEqual(kwargs["env"]["HOME"], os.environ.get("HOME"))
                    self.assertEqual(
                        kwargs["env"]["SYMPHONY_FIXTURE_LOG_FILE"],
                        str(Path(kwargs["env"]["TMPDIR"]) / "symphony.log"),
                    )
                    self.assertEqual(
                        kwargs["env"]["ERL_CRASH_DUMP"],
                        str(Path(kwargs["env"]["TMPDIR"]) / "erl_crash.dump"),
                    )
                    if calls in {1, 2}:
                        expected = (
                            codex_schema.FIXTURE_DEPENDENCY_COMMAND
                            if calls == 1
                            else codex_schema.FIXTURE_DEPENDENCY_COMPILE_COMMAND
                        )
                        self.assertEqual(command, expected)
                        if calls == 1:
                            self.assertNotIn("HEX_OFFLINE", kwargs["env"])
                        else:
                            self.assertEqual(kwargs["env"]["HEX_OFFLINE"], "1")
                        self.assertNotEqual(
                            (snapshot_root / "elixir").stat().st_mode & 0o200,
                            0,
                        )
                        return codex_schema.BoundedProcessResult(
                            tuple(command), 0, "locked deps\n", ""
                        )

                    self.assertEqual(command, codex_schema.FIXTURE_TEST_COMMAND)
                    self.assertEqual(kwargs["env"]["HEX_OFFLINE"], "1")
                    self.assertEqual(source.read_text(encoding="utf-8"), "snapshot-original\n")
                    self.assertEqual(source.stat().st_mode & 0o222, 0)
                    self.assertEqual(manifest_path.stat().st_mode & 0o222, 0)
                    self.assertEqual((snapshot_root / "elixir").stat().st_mode & 0o222, 0)
                    self.assertNotEqual(
                        Path(kwargs["env"]["MIX_BUILD_PATH"]).stat().st_mode & 0o200,
                        0,
                    )
                    self.assertEqual(
                        Path(kwargs["env"]["MIX_DEPS_PATH"]).stat().st_mode & 0o222,
                        0,
                    )
                    worktree_source.write_text("changed-during-test\n", encoding="utf-8")
                    worktree_source.write_text("original\n", encoding="utf-8")
                    return codex_schema.BoundedProcessResult(
                        tuple(command),
                        0,
                        f"...................\n{codex_schema.FIXTURE_EXPECTED_TEST_COUNT} tests, 0 failures\n",
                        "",
                    )

                validator = mock.Mock()
                candidate_verifier = mock.Mock()
                try:
                    with (
                        mock.patch.dict(
                            os.environ,
                            {
                                "LINEAR_API_KEY": "sentinel-linear-secret",
                                "OPENAI_API_KEY": "sentinel-openai-secret",
                                "GITHUB_TOKEN": "sentinel-github-secret",
                            },
                        ),
                        mock.patch.object(codex_schema, "run_bounded_process", side_effect=run),
                        mock.patch.object(
                            codex_schema, "validate_fixture_snapshot", validator
                        ),
                        mock.patch.object(
                            codex_schema, "verify_test_manifest", candidate_verifier
                        ),
                    ):
                        codex_schema.execute_snapshot_fixture_tests(
                            snapshot_root, snapshot_evidence()
                        )
                finally:
                    codex_schema.thaw_snapshot_for_cleanup(snapshot_root)

                self.assertEqual(calls, 3)
                self.assertEqual(validator.call_count, 3)
                self.assertEqual(candidate_verifier.call_count, 3)
                self.assertEqual(source.read_text(encoding="utf-8"), "snapshot-original\n")
                self.assertEqual(worktree_source.read_text(encoding="utf-8"), "original\n")

    def test_summary_with_suffix_or_duplicate_is_rejected_and_output_is_surfaced(self) -> None:
        invalid_outputs = (
            ("55 tests, 0 failures, 1 excluded\n", None),
            ("55 tests, 0 failures\n1 skipped\n", None),
            ("55 tests, 0 failures\n55 tests, 0 failures\n", None),
            (
                "55 tests, 0 failures\nLINEAR_API_KEY=sentinel-secret\n1 skipped\n",
                "LINEAR_API_KEY=[REDACTED]",
            ),
        )
        for output, redacted_marker in invalid_outputs:
            with self.subTest(output=output), snapshot_execution_workspace() as (
                snapshot_root,
                _source,
                _manifest_path,
            ):
                results = iter(
                    (
                        codex_schema.BoundedProcessResult((), 0, "deps\n", ""),
                        codex_schema.BoundedProcessResult((), 0, "compiled\n", ""),
                        codex_schema.BoundedProcessResult((), 0, output, "fixture stderr"),
                    )
                )
                stderr = io.StringIO()
                try:
                    with (
                        mock.patch.object(codex_schema, "run_bounded_process", side_effect=results),
                        mock.patch.object(codex_schema, "validate_fixture_snapshot"),
                        mock.patch.object(codex_schema, "verify_test_manifest"),
                        redirect_stderr(stderr),
                    ):
                        with self.assertRaisesRegex(
                            codex_schema.SchemaError, "expected exactly one"
                        ):
                            codex_schema.execute_snapshot_fixture_tests(
                                snapshot_root, snapshot_evidence()
                            )
                finally:
                    codex_schema.thaw_snapshot_for_cleanup(snapshot_root)

                if redacted_marker is None:
                    self.assertIn(output.strip(), stderr.getvalue())
                else:
                    self.assertIn(redacted_marker, stderr.getvalue())
                    self.assertNotIn("sentinel-secret", stderr.getvalue())
                self.assertIn("fixture stderr", stderr.getvalue())

    def test_dependency_tree_symlink_is_rejected_before_tests(self) -> None:
        with snapshot_execution_workspace() as (snapshot_root, _source, _manifest_path):
            def create_symlink(_command, **kwargs):
                deps_path = Path(kwargs["env"]["MIX_DEPS_PATH"])
                target = deps_path / "target"
                target.write_text("dependency\n", encoding="utf-8")
                (deps_path / "link").symlink_to(target)
                return codex_schema.BoundedProcessResult((), 0, "deps\n", "")

            try:
                with (
                    mock.patch.object(
                        codex_schema, "run_bounded_process", side_effect=create_symlink
                    ),
                    mock.patch.object(codex_schema, "validate_fixture_snapshot"),
                    mock.patch.object(codex_schema, "verify_test_manifest"),
                ):
                    with self.assertRaisesRegex(codex_schema.SchemaError, "symbolic link"):
                        codex_schema.execute_snapshot_fixture_tests(
                            snapshot_root, snapshot_evidence()
                        )
            finally:
                codex_schema.thaw_snapshot_for_cleanup(snapshot_root)

    def test_dependency_cwd_detects_change_and_restore(self) -> None:
        for relative in ("mix.exs", "config/config.exs"):
            with self.subTest(relative=relative), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                source = root / relative
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_text("trusted\n", encoding="utf-8")
                original_identity = source.stat().st_ino

                with self.assertRaisesRegex(
                    codex_schema.SchemaError, "mutated a protected project entry"
                ):
                    with codex_schema.writable_snapshot_dependency_cwd(root):
                        preserved = source.with_suffix(source.suffix + ".preserved")
                        source.rename(preserved)
                        source.write_text("substitute\n", encoding="utf-8")
                        source.unlink()
                        preserved.rename(source)

                self.assertEqual(source.read_text(encoding="utf-8"), "trusted\n")
                self.assertEqual(source.stat().st_ino, original_identity)

    def test_focused_test_phase_detects_source_and_dependency_change_restore(self) -> None:
        for target_kind in ("source", "dependency"):
            with self.subTest(target_kind=target_kind), snapshot_execution_workspace() as (
                snapshot_root,
                source,
                _manifest_path,
            ):
                calls = 0
                dependency_file: Path | None = None

                def run(command, **kwargs):
                    nonlocal calls, dependency_file
                    calls += 1
                    if calls == 1:
                        return codex_schema.BoundedProcessResult(tuple(command), 0, "deps\n", "")
                    if calls == 2:
                        dependency_file = Path(kwargs["env"]["MIX_DEPS_PATH"]) / "fixture" / "input.ex"
                        dependency_file.parent.mkdir(parents=True)
                        dependency_file.write_text("dependency-original\n", encoding="utf-8")
                        return codex_schema.BoundedProcessResult(
                            tuple(command), 0, "compiled\n", ""
                        )

                    target = source if target_kind == "source" else dependency_file
                    assert target is not None
                    original = target.read_bytes()
                    original_mode = target.stat().st_mode & 0o777
                    target.chmod(0o600)
                    target.write_bytes(b"substitute\n")
                    target.write_bytes(original)
                    target.chmod(original_mode)
                    return codex_schema.BoundedProcessResult(
                        tuple(command),
                        0,
                        f"{codex_schema.FIXTURE_EXPECTED_TEST_COUNT} tests, 0 failures\n",
                        "",
                    )

                try:
                    with (
                        mock.patch.object(
                            codex_schema, "run_bounded_process", side_effect=run
                        ),
                        mock.patch.object(codex_schema, "validate_fixture_snapshot"),
                        mock.patch.object(codex_schema, "verify_test_manifest"),
                    ):
                        with self.assertRaisesRegex(
                            codex_schema.SchemaError, "mutated a frozen input"
                        ):
                            codex_schema.execute_snapshot_fixture_tests(
                                snapshot_root, snapshot_evidence()
                            )
                finally:
                    codex_schema.thaw_snapshot_for_cleanup(snapshot_root)

    def test_cleanup_unlinks_hardlinks_without_mutating_external_inode(self) -> None:
        for cleanup in ("snapshot", "transaction"):
            with self.subTest(cleanup=cleanup), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                external = root / "external.txt"
                tree = root / "tree"
                tree.mkdir()
                external.write_text("preserve\n", encoding="utf-8")
                external.chmod(0o400)
                os.link(external, tree / "linked.txt")
                tree.chmod(0o500)

                if cleanup == "snapshot":
                    codex_schema.cleanup_snapshot_directory(tree)
                else:
                    codex_schema.remove_transaction_tree(tree)

                self.assertFalse(tree.exists())
                self.assertEqual(external.read_text(encoding="utf-8"), "preserve\n")
                self.assertEqual(external.stat().st_mode & 0o777, 0o400)

    def test_read_only_stale_snapshot_is_scavenged_without_following_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo_root = root / "repo"
            repo_root.mkdir()
            snapshot_base = root / "snapshots"
            external = root / "external.txt"
            external.write_text("preserve\n", encoding="utf-8")

            with mock.patch.object(codex_schema, "SNAPSHOT_ROOT", snapshot_base):
                namespace = codex_schema.snapshot_namespace(repo_root)
                namespace.mkdir(parents=True)
                stale = namespace / "run-stale"
                stale.mkdir()
                marker = stale / ".active.lock"
                marker.write_text("stale\n", encoding="utf-8")
                (stale / "external-link").symlink_to(external)
                marker.chmod(0o400)
                stale.chmod(0o500)
                markerless = namespace / "run-markerless"
                markerless.mkdir()
                markerless.chmod(0o500)
                creating = namespace / ".creating-interrupted"
                creating.mkdir()
                cleanup = namespace / ".cleanup-interrupted"
                cleanup.mkdir()

                with codex_schema.fixture_snapshot_workspace(repo_root) as current:
                    self.assertTrue(current.is_dir())
                    self.assertFalse(stale.exists())
                    self.assertFalse(markerless.exists())
                    self.assertFalse(creating.exists())
                    self.assertFalse(cleanup.exists())

            self.assertEqual(external.read_text(encoding="utf-8"), "preserve\n")

    def test_snapshot_root_requires_current_owner_and_private_mode(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "snapshots"
            root.mkdir(mode=0o755)
            with (
                mock.patch.object(
                    codex_schema.os,
                    "geteuid",
                    return_value=os.geteuid() + 1,
                ),
                self.assertRaisesRegex(codex_schema.SchemaError, "not owner controlled"),
            ):
                codex_schema.ensure_private_owner_directory(root, label="snapshot root")

            codex_schema.ensure_private_owner_directory(root, label="snapshot root")
            self.assertEqual(root.stat().st_mode & 0o777, 0o700)

    def test_locked_snapshot_marker_is_never_scavenged(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo_root = root / "repo"
            repo_root.mkdir()
            snapshot_base = root / "snapshots"

            with mock.patch.object(codex_schema, "SNAPSHOT_ROOT", snapshot_base):
                namespace = codex_schema.snapshot_namespace(repo_root)
                namespace.mkdir(parents=True)
                active = namespace / "run-active"
                active.mkdir()
                marker = active / ".active.lock"
                marker.write_text("active\n", encoding="utf-8")
                descriptor = os.open(marker, os.O_RDONLY)
                try:
                    import fcntl

                    fcntl.flock(descriptor, fcntl.LOCK_EX)
                    with self.assertRaisesRegex(codex_schema.SchemaError, "still active"):
                        codex_schema.scavenge_stale_fixture_snapshots(namespace)
                    self.assertTrue(active.is_dir())
                finally:
                    fcntl.flock(descriptor, fcntl.LOCK_UN)
                    os.close(descriptor)

    def test_real_private_snapshot_runs_the_focused_mix_gate(self) -> None:
        bundle = codex_schema.SCHEMA_ROOT / codex_schema.read_version()
        manifest, _entries = codex_schema.verify_bundle(
            bundle, require_fixture_seal=False
        )
        tested_at = manifest["generation"]["generatedAt"]
        test_manifest = codex_schema.build_test_manifest(manifest, tested_at)
        evidence = test_manifest["compatibility"]["fixtureEvidence"]
        codex_schema.run_snapshot_fixture_tests(test_manifest, evidence)


class ProcessLockTest(unittest.TestCase):
    def test_cli_lock_modes_match_read_and_write_operations(self) -> None:
        parsed = codex_schema.parser()
        self.assertTrue(parsed.parse_args(["generate", "--tested-at", "2026-07-15"]).lock_exclusive)
        self.assertTrue(parsed.parse_args(["seal-fixtures", "--tested-at", "2026-07-15"]).lock_exclusive)
        self.assertFalse(parsed.parse_args(["verify"]).lock_exclusive)
        self.assertFalse(parsed.parse_args(["regenerate-check"]).lock_exclusive)

    def test_exclusive_lock_blocks_concurrent_reader_until_release(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo_root = Path(temporary) / "repo"
            repo_root.mkdir()
            holder = start_lock_holder(repo_root)
            waiter = None
            try:
                self.assertEqual(holder.stdout.readline().strip(), "locked")
                waiter = start_lock_waiter(repo_root, exclusive=False)
                with self.assertRaises(subprocess.TimeoutExpired):
                    waiter.wait(timeout=0.2)
                holder.stdin.write("x")
                holder.stdin.flush()
                self.assertEqual(holder.wait(timeout=3), 0)
                output, error = waiter.communicate(timeout=3)
                self.assertEqual(waiter.returncode, 0, error)
                self.assertEqual(output.strip(), "acquired")
            finally:
                terminate_process(holder)
                if waiter is not None:
                    terminate_process(waiter)

    def test_sigkill_releases_external_process_lock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo_root = Path(temporary) / "repo"
            repo_root.mkdir()
            holder = start_lock_holder(repo_root)
            waiter = None
            try:
                self.assertEqual(holder.stdout.readline().strip(), "locked")
                waiter = start_lock_waiter(repo_root, exclusive=True)
                with self.assertRaises(subprocess.TimeoutExpired):
                    waiter.wait(timeout=0.2)
                holder.kill()
                holder.wait(timeout=3)
                output, error = waiter.communicate(timeout=3)
                self.assertEqual(waiter.returncode, 0, error)
                self.assertEqual(output.strip(), "acquired")
            finally:
                terminate_process(holder)
                if waiter is not None:
                    terminate_process(waiter)

    def test_lock_is_shared_across_distinct_tmpdir_environments(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo_root = root / "repo"
            first_tmp = root / "tmp-a"
            second_tmp = root / "tmp-b"
            repo_root.mkdir()
            first_tmp.mkdir()
            second_tmp.mkdir()
            first_env = dict(os.environ, TMPDIR=str(first_tmp))
            second_env = dict(os.environ, TMPDIR=str(second_tmp))
            holder = start_lock_holder(repo_root, env=first_env)
            waiter = None
            try:
                self.assertEqual(holder.stdout.readline().strip(), "locked")
                waiter = start_lock_waiter(
                    repo_root, exclusive=True, env=second_env
                )
                with self.assertRaises(subprocess.TimeoutExpired):
                    waiter.wait(timeout=0.2)
                holder.stdin.write("x")
                holder.stdin.flush()
                self.assertEqual(holder.wait(timeout=3), 0)
                output, error = waiter.communicate(timeout=3)
                self.assertEqual(waiter.returncode, 0, error)
                self.assertEqual(output.strip(), "acquired")
            finally:
                terminate_process(holder)
                if waiter is not None:
                    terminate_process(waiter)


class BoundedProcessTest(unittest.TestCase):
    def test_runner_bounds_bytes_deadlines_invalid_utf8_and_descendants(self) -> None:
        previous_subreaper = codex_schema.child_subreaper_enabled()
        decoded = codex_schema.run_bounded_process(
            [sys.executable, "-c", "import sys; sys.stdout.buffer.write(b'ok\\xff\\n')"],
            deadline_seconds=2,
            max_output_bytes=1024,
        )
        self.assertEqual(decoded.returncode, 0)
        self.assertIsNone(decoded.failure_reason)
        self.assertEqual(decoded.stdout, "ok�\n")

        flooded = codex_schema.run_bounded_process(
            [sys.executable, "-c", "print('x' * 65536)"],
            deadline_seconds=2,
            max_output_bytes=1024,
        )
        self.assertRegex(flooded.failure_reason or "", "output exceeded")
        self.assertLessEqual(
            len(flooded.stdout.encode("utf-8", errors="replace")),
            codex_schema.MAX_DIAGNOSTIC_OUTPUT_BYTES
            + len("\n...[process output truncated]...\n"),
        )

        timed_out = codex_schema.run_bounded_process(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            deadline_seconds=0.1,
            max_output_bytes=1024,
        )
        self.assertRegex(timed_out.failure_reason or "", "deadline exceeded")

        with tempfile.TemporaryDirectory() as temporary:
            pid_file = Path(temporary) / "pids.txt"
            program = (
                "import os,pathlib,subprocess; "
                f"p=subprocess.Popen(['sleep','30']); pathlib.Path({str(pid_file)!r}).write_text("
                "f'{os.getpid()} {p.pid}');"
            )
            lingering = codex_schema.run_bounded_process(
                [sys.executable, "-c", program],
                deadline_seconds=0.2,
                max_output_bytes=1024,
            )
            self.assertRegex(lingering.failure_reason or "", "descendant process remained")
            process_group, _child = map(int, pid_file.read_text(encoding="utf-8").split())
            self.assertFalse(codex_schema.process_group_alive(process_group))

        short_lived_orphan = codex_schema.run_bounded_process(
            [
                sys.executable,
                "-c",
                "import subprocess; subprocess.Popen(['sleep','0.05'],"
                "start_new_session=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)",
            ],
            deadline_seconds=2,
            max_output_bytes=1024,
        )
        self.assertEqual(short_lived_orphan.returncode, 0)
        self.assertIsNone(short_lived_orphan.failure_reason)
        self.assertEqual(codex_schema.direct_child_pids(), set())

        with tempfile.TemporaryDirectory() as temporary:
            pid_file = Path(temporary) / "escaped.txt"
            program = (
                "import pathlib,subprocess; "
                "p=subprocess.Popen(['sleep','30'],start_new_session=True,"
                "stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); "
                f"stat=pathlib.Path('/proc')/str(p.pid)/'stat'; data=stat.read_bytes(); "
                "fields=data[data.rfind(b') ')+2:].split(); "
                f"pathlib.Path({str(pid_file)!r}).write_text(f'{{p.pid}} {{int(fields[19])}}')"
            )
            escaped = codex_schema.run_bounded_process(
                [sys.executable, "-c", program],
                deadline_seconds=0.2,
                max_output_bytes=1024,
            )
            self.assertRegex(escaped.failure_reason or "", "descendant process remained")
            escaped_pid, start_time = map(
                int, pid_file.read_text(encoding="utf-8").split()
            )
            self.assertNotEqual(
                codex_schema.proc_process_identity(escaped_pid),
                (escaped_pid, start_time),
            )
            self.assertEqual(codex_schema.direct_child_pids(), set())

        with tempfile.TemporaryDirectory() as temporary:
            pid_file = Path(temporary) / "double-forked.txt"
            middle_program = (
                "import pathlib,subprocess; "
                "p=subprocess.Popen(['sleep','30'],stdout=subprocess.DEVNULL,"
                "stderr=subprocess.DEVNULL); "
                "data=(pathlib.Path('/proc')/str(p.pid)/'stat').read_bytes(); "
                "fields=data[data.rfind(b') ')+2:].split(); "
                f"pathlib.Path({str(pid_file)!r}).write_text(f'{{p.pid}} {{int(fields[19])}}')"
            )
            program = f"""
import pathlib
import subprocess
import time
marker = pathlib.Path({str(pid_file)!r})
subprocess.Popen(
    [{sys.executable!r}, "-c", {middle_program!r}],
    start_new_session=True,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
deadline = time.monotonic() + 1
while not marker.exists() and time.monotonic() < deadline:
    time.sleep(0.01)
if not marker.exists():
    raise RuntimeError("double-fork marker was not written")
"""
            double_forked = codex_schema.run_bounded_process(
                [sys.executable, "-c", program],
                deadline_seconds=0.3,
                max_output_bytes=1024,
            )
            self.assertRegex(
                double_forked.failure_reason or "", "descendant process remained"
            )
            escaped_pid, start_time = map(
                int, pid_file.read_text(encoding="utf-8").split()
            )
            self.assertNotEqual(
                codex_schema.proc_process_identity(escaped_pid),
                (escaped_pid, start_time),
            )
            self.assertEqual(codex_schema.direct_child_pids(), set())

        self.assertEqual(codex_schema.child_subreaper_enabled(), previous_subreaper)
        subsequent = codex_schema.run_bounded_process(
            [sys.executable, "-c", "print('contained')"],
            deadline_seconds=2,
            max_output_bytes=1024,
        )
        self.assertIsNone(subsequent.failure_reason)
        self.assertEqual(subsequent.stdout, "contained\n")


class InstalledCodexSafetyTest(unittest.TestCase):
    def test_pin_precedes_execution_and_children_receive_only_strict_environment(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "package"
            launcher = package / "bin" / "codex"
            native = package / "node_modules" / "@openai" / "codex-linux-x64" / "vendor" / "x" / "codex"
            log = root / "environment.jsonl"
            cwd_log = root / "cwd.jsonl"
            marker = root / "bad-invoked"
            launcher.parent.mkdir(parents=True)
            native.parent.mkdir(parents=True)
            launcher.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, pathlib, sys\n"
                f"log = pathlib.Path({str(log)!r})\n"
                "with log.open('a', encoding='utf-8') as stream:\n"
                "    stream.write(json.dumps(dict(os.environ), sort_keys=True) + '\\n')\n"
                f"with pathlib.Path({str(cwd_log)!r}).open('a', encoding='utf-8') as stream:\n"
                "    stream.write(json.dumps(os.getcwd()) + '\\n')\n"
                "if sys.argv[1:] == ['--version']:\n"
                "    print('codex-cli 0.144.3')\n"
                "else:\n"
                "    out = pathlib.Path(sys.argv[sys.argv.index('--out') + 1])\n"
                "    out.mkdir(parents=True, exist_ok=True)\n"
                "    (out / 'artifact.txt').write_text('generated\\n', encoding='utf-8')\n",
                encoding="utf-8",
            )
            launcher.chmod(0o755)
            native.write_bytes(b"native fixture\n")
            selected = {
                "architecture": platform.machine().lower(),
                "operatingSystem": platform.system().lower(),
                "installedPackageAlias": "@openai/codex-linux-x64",
                "launcherSha256": codex_schema.sha256_file(launcher),
                "nativeSha256": codex_schema.sha256_file(native),
            }
            lock = {
                "platforms": [selected],
                "versionOutput": "codex-cli 0.144.3",
            }
            lock_path = root / "CODEX_LOCK.json"
            codex_schema.write_json(lock_path, lock)

            bad = root / "bad" / "bin" / "codex"
            bad.parent.mkdir(parents=True)
            bad.write_text(
                f"#!/bin/sh\ntouch {str(marker)!r}\nprintf 'codex-cli 0.144.3\\n'\n",
                encoding="utf-8",
            )
            bad.chmod(0o755)
            bad_lock = copy.deepcopy(lock)
            bad_lock["platforms"][0]["launcherSha256"] = "0" * 64
            codex_schema.write_json(lock_path, bad_lock)
            with mock.patch.object(codex_schema, "LOCK_FILE", lock_path):
                with self.assertRaisesRegex(codex_schema.SchemaError, "launcher checksum"):
                    codex_schema.installed_codex(str(bad))
            self.assertFalse(marker.exists())

            codex_schema.write_json(lock_path, lock)
            with (
                mock.patch.object(codex_schema, "LOCK_FILE", lock_path),
                mock.patch.dict(os.environ, {"OPENAI_API_KEY": "sentinel-secret"}),
            ):
                actual_launcher, actual_native, _lock, actual_selected = (
                    codex_schema.installed_codex(str(launcher))
                )
                destination = root / "generated" / "bundle"
                destination.mkdir(parents=True)
                codex_schema.run_generators(
                    actual_launcher, actual_native, destination, actual_selected
                )

            environments = [json.loads(line) for line in log.read_text().splitlines()]
            working_directories = [
                json.loads(line) for line in cwd_log.read_text().splitlines()
            ]
            self.assertEqual(len(environments), 5)
            self.assertEqual(len(working_directories), 5)
            self.assertTrue(all("OPENAI_API_KEY" not in env for env in environments))
            self.assertTrue(all(set(env) == set(codex_schema.codex_child_environment(root / "expected")) for env in environments))
            self.assertEqual(
                working_directories,
                [environment["HOME"] for environment in environments],
            )
            self.assertTrue(
                all(Path(cwd).name == "home" for cwd in working_directories)
            )


class DeterministicRunnerTest(unittest.TestCase):
    def test_runner_binds_exact_intentional_test_count(self) -> None:
        scripts = Path(__file__).resolve().parent
        suite = run_codex_schema_tests.discover_suite(scripts)
        self.assertEqual(suite.countTestCases(), run_codex_schema_tests.EXPECTED_TEST_COUNT)

    def test_runner_rejects_empty_suite_even_when_expected_count_is_zero(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            (Path(temporary) / "__init__.py").write_text("", encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "empty suite"):
                run_codex_schema_tests.discover_suite(
                    Path(temporary), expected_count=0
                )

    def test_runner_rejects_all_disabled_test_outcomes(self) -> None:
        class Skipped(unittest.TestCase):
            @unittest.skip("disabled")
            def runTest(self):
                pass

        class ExpectedFailure(unittest.TestCase):
            @unittest.expectedFailure
            def runTest(self):
                self.fail("expected")

        class UnexpectedSuccess(unittest.TestCase):
            @unittest.expectedFailure
            def runTest(self):
                pass

        for case in (Skipped, ExpectedFailure, UnexpectedSuccess):
            with self.subTest(case=case.__name__):
                stream = io.StringIO()
                result = unittest.TextTestRunner(stream=stream).run(
                    unittest.TestSuite([case()])
                )
                self.assertFalse(
                    run_codex_schema_tests.result_is_clean(result, expected_count=1)
                )

    def test_regeneration_comparator_rejects_changed_missing_and_extra_artifacts(self) -> None:
        expected = [
            ("json/schema.json", "a" * 64, 10),
            ("typescript/schema.ts", "b" * 64, 20),
        ]
        variants = (
            [("json/schema.json", "c" * 64, 10), expected[1]],
            [expected[0]],
            expected + [("typescript/extra.ts", "d" * 64, 1)],
        )
        for actual in variants:
            with self.subTest(actual=actual):
                with (
                    mock.patch.object(
                        codex_schema, "verify_bundle", return_value=({}, expected)
                    ),
                    mock.patch.object(
                        codex_schema,
                        "installed_codex",
                        return_value=(Path("/codex"), Path("/native"), {}, {}),
                    ),
                    mock.patch.object(codex_schema, "run_generators"),
                    mock.patch.object(codex_schema, "artifact_entries", return_value=actual),
                ):
                    with self.assertRaisesRegex(
                        codex_schema.SchemaError, "regenerated schema differs"
                    ):
                        codex_schema.regenerate_check(argparse.Namespace(codex="codex"))


class GeneratedBundlePublicationTest(unittest.TestCase):
    def test_generate_recovers_backup_before_external_codex_precondition(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            schema_root = Path(temporary) / "codex_schema"
            schema_root.mkdir()
            destination = schema_root / "0.144.3"
            staging = schema_root / ".0.144.3.staging"
            backup = schema_root / ".0.144.3.backup"
            backup.mkdir()
            (backup / "state.txt").write_text("old\n", encoding="utf-8")

            with (
                mock.patch.object(codex_schema, "SCHEMA_ROOT", schema_root),
                mock.patch.object(codex_schema, "read_version", return_value="0.144.3"),
                mock.patch.object(
                    codex_schema,
                    "verify_bundle_proof",
                    side_effect=lambda path, **_kwargs: dummy_bundle_proof(path),
                ),
                mock.patch.object(
                    codex_schema,
                    "installed_codex",
                    side_effect=codex_schema.SchemaError("Codex unavailable"),
                ),
            ):
                with self.assertRaisesRegex(codex_schema.SchemaError, "Codex unavailable"):
                    codex_schema.generate(
                        argparse.Namespace(codex="codex", tested_at="2026-07-15")
                    )

            self.assertEqual((destination / "state.txt").read_text(), "old\n")
            self.assertFalse(staging.exists())
            self.assertFalse(backup.exists())

    def test_failed_installed_candidate_restores_exact_previous_tree(self) -> None:
        with generation_workspace() as (destination, staging, backup):
            candidate = dummy_bundle_proof(staging)
            rejected = False

            def reject_installed(path, _proof, **_kwargs):
                nonlocal rejected
                if Path(path) == destination and not rejected:
                    rejected = True
                    raise codex_schema.SchemaError("final candidate rejected")

            with mock.patch.object(
                codex_schema, "assert_bundle_proof", side_effect=reject_installed
            ), mock.patch.object(
                codex_schema,
                "verify_bundle_proof",
                side_effect=lambda path, **_kwargs: dummy_bundle_proof(path),
            ):
                with self.assertRaisesRegex(codex_schema.SchemaError, "final candidate rejected"):
                    codex_schema.publish_generated_bundle(
                        staging, destination, backup, candidate
                    )

            self.assertEqual((destination / "state.txt").read_text(), "old\n")
            self.assertFalse(staging.exists())
            self.assertFalse(backup.exists())

    def test_replaced_destination_refuses_stale_generated_bundle_rollback(self) -> None:
        with generation_workspace() as (destination, staging, backup):
            candidate = dummy_bundle_proof(staging)
            rejected = False

            def replace_installed(path, _proof, **_kwargs):
                nonlocal rejected
                if Path(path) == destination and not rejected:
                    rejected = True
                    shutil.rmtree(path)
                    path.mkdir()
                    (path / "state.txt").write_text("other-writer\n", encoding="utf-8")
                    raise codex_schema.SchemaError("final candidate rejected")

            with mock.patch.object(
                codex_schema, "assert_bundle_proof", side_effect=replace_installed
            ), mock.patch.object(
                codex_schema,
                "verify_bundle_proof",
                side_effect=lambda path, **_kwargs: dummy_bundle_proof(path),
            ):
                with self.assertRaisesRegex(codex_schema.SchemaError, "stale.*rollback"):
                    codex_schema.publish_generated_bundle(
                        staging, destination, backup, candidate
                    )

            self.assertEqual((destination / "state.txt").read_text(), "other-writer\n")
            self.assertEqual((backup / "state.txt").read_text(), "old\n")

    def test_recovery_restores_backup_and_discards_uncommitted_staging(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination = root / "bundle"
            staging = root / ".bundle.staging"
            backup = root / ".bundle.backup"
            staging.mkdir()
            backup.mkdir()
            (staging / "state.txt").write_text("candidate\n", encoding="utf-8")
            (backup / "state.txt").write_text("old\n", encoding="utf-8")

            with mock.patch.object(
                codex_schema,
                "verify_bundle_proof",
                side_effect=lambda path, **_kwargs: dummy_bundle_proof(path),
            ):
                codex_schema.recover_generated_bundle(destination, staging, backup)

            self.assertEqual((destination / "state.txt").read_text(), "old\n")
            self.assertFalse(staging.exists())
            self.assertFalse(backup.exists())

    def test_recovery_preserves_invalid_or_unsafe_transaction_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination = root / "bundle"
            staging = root / ".bundle.staging"
            backup = root / ".bundle.backup"
            destination.mkdir()
            staging.mkdir()
            (destination / "corrupt.txt").write_text("invalid\n", encoding="utf-8")
            (staging / "state.txt").write_text("candidate\n", encoding="utf-8")

            with self.assertRaisesRegex(codex_schema.SchemaError, "root shape mismatch"):
                codex_schema.recover_generated_bundle(destination, staging, backup)
            self.assertTrue(destination.is_dir())
            self.assertTrue(staging.is_dir())

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination = root / "bundle"
            staging = root / ".bundle.staging"
            backup = root / ".bundle.backup"
            backup.mkdir()
            (backup / "corrupt.txt").write_text("invalid\n", encoding="utf-8")

            with self.assertRaisesRegex(codex_schema.SchemaError, "root shape mismatch"):
                codex_schema.recover_generated_bundle(destination, staging, backup)
            self.assertFalse(destination.exists())
            self.assertTrue(backup.is_dir())

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination = root / "bundle"
            staging = root / ".bundle.staging"
            backup = root / ".bundle.backup"
            external = root / "external"
            external.mkdir()
            (external / "preserve.txt").write_text("preserve\n", encoding="utf-8")
            destination.symlink_to(external, target_is_directory=True)

            with self.assertRaisesRegex(codex_schema.SchemaError, "unsafe.*residue"):
                codex_schema.recover_generated_bundle(destination, staging, backup)
            self.assertEqual(
                (external / "preserve.txt").read_text(encoding="utf-8"),
                "preserve\n",
            )

    def test_sigkill_boundaries_recover_one_authoritative_bundle(self) -> None:
        checkpoints = {
            "destination_preserved": "old\n",
            "candidate_installed": "candidate\n",
            "candidate_verified": "candidate\n",
            "backup_deleted": "candidate\n",
            "failed_candidate_moved": "old\n",
            "backup_restored": "old\n",
        }
        for checkpoint, expected_state in checkpoints.items():
            with self.subTest(checkpoint=checkpoint), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                destination = root / "bundle"
                staging = root / ".bundle.staging"
                backup = root / ".bundle.backup"
                destination.mkdir()
                staging.mkdir()
                (destination / "state.txt").write_text("old\n", encoding="utf-8")
                (staging / "state.txt").write_text("candidate\n", encoding="utf-8")
                program = """
import os
from pathlib import Path
import signal
import sys
sys.path.insert(0, sys.argv[1])
import codex_schema
root = Path(sys.argv[2])
target = sys.argv[3]
destination = root / 'bundle'
staging = root / '.bundle.staging'
backup = root / '.bundle.backup'
tree = codex_schema.capture_tree_proof(staging)
proof = codex_schema.BundleProof(tree, 'm', 'a', 's')
codex_schema.verify_bundle_proof = lambda path, **_kwargs: codex_schema.BundleProof(
    codex_schema.capture_tree_proof(path), 'm', 'a', 's'
)
failure_injected = False
def assert_proof(path, *_args, **_kwargs):
    global failure_injected
    if (
        target in {'failed_candidate_moved', 'backup_restored'}
        and Path(path) == destination
        and not failure_injected
    ):
        failure_injected = True
        raise codex_schema.SchemaError('injected candidate rejection')
codex_schema.assert_bundle_proof = assert_proof
def checkpoint(name):
    if name == target:
        os.kill(os.getpid(), signal.SIGKILL)
codex_schema.publication_checkpoint = checkpoint
try:
    codex_schema.publish_generated_bundle(staging, destination, backup, proof)
except codex_schema.SchemaError:
    pass
raise SystemExit(97)
"""
                result = subprocess.run(
                    [
                        sys.executable,
                        "-c",
                        program,
                        str(Path(codex_schema.__file__).resolve().parent),
                        str(root),
                        checkpoint,
                    ],
                    check=False,
                )
                self.assertEqual(result.returncode, -9)

                with mock.patch.object(
                    codex_schema,
                    "verify_bundle_proof",
                    side_effect=lambda path, **_kwargs: dummy_bundle_proof(path),
                ):
                    codex_schema.recover_generated_bundle(destination, staging, backup)
                self.assertEqual(
                    (destination / "state.txt").read_text(encoding="utf-8"),
                    expected_state,
                )
                self.assertFalse(staging.exists())
                self.assertFalse(backup.exists())

    def test_sigkill_after_backup_rename_recovers_previous_bundle(self) -> None:
        """Retained as a focused compatibility name for older gate evidence."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination = root / "bundle"
            staging = root / ".bundle.staging"
            backup = root / ".bundle.backup"
            destination.mkdir()
            staging.mkdir()
            (destination / "state.txt").write_text("old\n", encoding="utf-8")
            (staging / "state.txt").write_text("candidate\n", encoding="utf-8")
            program = """
import os
from pathlib import Path
import signal
import sys
sys.path.insert(0, sys.argv[1])
import codex_schema
root = Path(sys.argv[2])
destination = root / 'bundle'
staging = root / '.bundle.staging'
backup = root / '.bundle.backup'
tree = codex_schema.capture_tree_proof(staging)
proof = codex_schema.BundleProof(tree, 'm', 'a', 's')
codex_schema.assert_bundle_proof = lambda *_args, **_kwargs: None
codex_schema.verify_bundle_proof = lambda path, **_kwargs: codex_schema.BundleProof(
    codex_schema.capture_tree_proof(path), 'm', 'a', 's'
)
def checkpoint(name):
    if name == 'destination_preserved':
        os.kill(os.getpid(), signal.SIGKILL)
codex_schema.publication_checkpoint = checkpoint
codex_schema.publish_generated_bundle(staging, destination, backup, proof)
"""
            result = subprocess.run(
                [
                    sys.executable,
                    "-c",
                    program,
                    str(Path(codex_schema.__file__).resolve().parent),
                    str(root),
                ],
                check=False,
            )
            self.assertEqual(result.returncode, -9)
            self.assertFalse(destination.exists())
            self.assertTrue(staging.is_dir())
            self.assertTrue(backup.is_dir())

            with mock.patch.object(
                codex_schema,
                "verify_bundle_proof",
                side_effect=lambda path, **_kwargs: dummy_bundle_proof(path),
            ):
                codex_schema.recover_generated_bundle(destination, staging, backup)
            self.assertEqual((destination / "state.txt").read_text(), "old\n")
            self.assertFalse(staging.exists())
            self.assertFalse(backup.exists())


class SealPublicationTest(unittest.TestCase):
    def test_test_failure_leaves_committed_manifest_byte_identical(self) -> None:
        with seal_workspace() as (repo_root, schema_root, bundle, original):
            verifier = VerificationHarness(repo_root)
            runner = mock.Mock(side_effect=subprocess.CalledProcessError(1, "mix test"))

            with seal_patches(repo_root, schema_root, verifier, runner):
                with self.assertRaises(subprocess.CalledProcessError):
                    codex_schema.seal_fixtures(argparse.Namespace(tested_at="2026-07-15"))

            assert_committed_unchanged(self, bundle, original)

    def test_publication_verification_failure_does_not_publish(self) -> None:
        with seal_workspace() as (repo_root, schema_root, bundle, original):
            verifier = VerificationHarness(repo_root, reject_publication=True)
            runner = mock.Mock(return_value=subprocess.CompletedProcess([], 0))

            with seal_patches(repo_root, schema_root, verifier, runner):
                with self.assertRaisesRegex(codex_schema.SchemaError, "publication rejected"):
                    codex_schema.seal_fixtures(argparse.Namespace(tested_at="2026-07-15"))

            assert_committed_unchanged(self, bundle, original)

    def test_post_verification_content_mutation_is_detected_before_replace(self) -> None:
        def mutate_publication(path):
            path.write_text('{"attacker":"post verification"}\n', encoding="utf-8")

        self.assert_publication_swap_rejected(mutate_publication, "changed before publication")

    def test_post_verification_symlink_swap_is_detected_before_replace(self) -> None:
        def symlink_publication(path):
            attacker = path.parent / "attacker.json"
            attacker.write_text('{"attacker":"symlink target"}\n', encoding="utf-8")
            path.unlink()
            path.symlink_to(attacker)

        self.assert_publication_swap_rejected(symlink_publication, "symbolic link")

    def test_non_locking_destination_write_is_preserved_before_publication(self) -> None:
        with seal_workspace() as (repo_root, schema_root, bundle, _original):
            verifier = VerificationHarness(repo_root)
            runner = mock.Mock(return_value=subprocess.CompletedProcess([], 0))
            destination = bundle / "manifest.json"

            def mutate_destination(_publication_path):
                destination.write_text(
                    '{"other_writer":"preserve-before-replace"}\n',
                    encoding="utf-8",
                )

            with seal_patches(
                repo_root,
                schema_root,
                verifier,
                runner,
                fsync_file=mock.Mock(side_effect=mutate_destination),
            ):
                with self.assertRaisesRegex(
                    codex_schema.SchemaError, "changed before publication"
                ):
                    codex_schema.seal_fixtures(
                        argparse.Namespace(tested_at="2026-07-15")
                    )

            self.assertEqual(
                codex_schema.read_json(destination),
                {"other_writer": "preserve-before-replace"},
            )

    def test_non_locking_write_between_fence_and_exchange_is_restored(self) -> None:
        with seal_workspace() as (repo_root, schema_root, bundle, _original):
            verifier = VerificationHarness(repo_root)
            runner = mock.Mock(return_value=subprocess.CompletedProcess([], 0))
            destination = bundle / "manifest.json"
            real_exchange = codex_schema.secure_exchange
            attacked = False

            def racing_exchange(source, target):
                nonlocal attacked
                if not attacked:
                    attacked = True
                    destination.write_text(
                        '{"other_writer":"preserve-final-gap"}\n',
                        encoding="utf-8",
                    )
                real_exchange(source, target)

            with (
                seal_patches(repo_root, schema_root, verifier, runner),
                mock.patch.object(
                    codex_schema,
                    "secure_exchange",
                    side_effect=racing_exchange,
                ),
            ):
                with self.assertRaisesRegex(
                    codex_schema.SchemaError, "displaced writer restored"
                ):
                    codex_schema.seal_fixtures(
                        argparse.Namespace(tested_at="2026-07-15")
                    )

            self.assertTrue(attacked)
            self.assertEqual(
                codex_schema.read_json(destination),
                {"other_writer": "preserve-final-gap"},
            )

    def test_post_replace_path_swap_aborts_stale_rollback(self) -> None:
        with seal_workspace() as (repo_root, schema_root, bundle, original):
            verifier = VerificationHarness(repo_root)
            runner = mock.Mock(return_value=subprocess.CompletedProcess([], 0))
            attacked = False

            def swap_destination(_directory):
                nonlocal attacked
                if attacked:
                    return
                attacked = True
                destination = bundle / "manifest.json"
                attacker = bundle / "attacker.json"
                attacker.write_text('{"attacker":"post replace swap"}\n', encoding="utf-8")
                destination.unlink()
                destination.symlink_to(attacker)

            with seal_patches(
                repo_root,
                schema_root,
                verifier,
                runner,
                fsync_directory=mock.Mock(side_effect=swap_destination),
            ):
                with self.assertRaisesRegex(codex_schema.SchemaError, "stale schema manifest rollback"):
                    codex_schema.seal_fixtures(argparse.Namespace(tested_at="2026-07-15"))

            self.assertTrue(attacked)
            self.assertTrue((bundle / "manifest.json").is_symlink())
            self.assertIn("post replace swap", (bundle / "manifest.json").read_text(encoding="utf-8"))

    def test_bundle_directory_replacement_before_publication_is_fenced(self) -> None:
        with seal_workspace() as (repo_root, schema_root, bundle, _original):
            verifier = VerificationHarness(repo_root)
            replacement = bundle.parent / "replacement-target"

            def replace_bundle(*_args):
                bundle.rename(replacement)
                bundle.mkdir()
                (bundle / "manifest.json").write_text(
                    '{"attacker":"replacement"}\n', encoding="utf-8"
                )

            runner = mock.Mock(side_effect=replace_bundle)
            with seal_patches(repo_root, schema_root, verifier, runner):
                with self.assertRaisesRegex(codex_schema.SchemaError, "directory changed"):
                    codex_schema.seal_fixtures(argparse.Namespace(tested_at="2026-07-15"))

            self.assertEqual(
                codex_schema.read_json(bundle / "manifest.json"), {"attacker": "replacement"}
            )

    def test_bundle_directory_replacement_before_rollback_is_fenced(self) -> None:
        with seal_workspace() as (repo_root, schema_root, bundle, _original):
            verifier = VerificationHarness(repo_root)
            runner = mock.Mock(return_value=None)
            replacement = bundle.parent / "published-old"
            attacked = False

            def replace_bundle(_directory):
                nonlocal attacked
                if attacked:
                    return
                attacked = True
                bundle.rename(replacement)
                bundle.mkdir()
                (bundle / "manifest.json").write_text(
                    '{"other_writer":"preserve"}\n', encoding="utf-8"
                )

            with seal_patches(
                repo_root,
                schema_root,
                verifier,
                runner,
                fsync_directory=mock.Mock(side_effect=replace_bundle),
            ):
                with self.assertRaisesRegex(
                    codex_schema.SchemaError, "stale schema manifest rollback"
                ):
                    codex_schema.seal_fixtures(argparse.Namespace(tested_at="2026-07-15"))

            self.assertTrue(attacked)
            self.assertEqual(
                codex_schema.read_json(bundle / "manifest.json"),
                {"other_writer": "preserve"},
            )

    def test_concurrent_destination_change_is_preserved_instead_of_rolled_back(self) -> None:
        with seal_workspace() as (repo_root, schema_root, bundle, _original):
            verifier = VerificationHarness(repo_root)
            runner = mock.Mock(return_value=None)
            attacked = False

            def replace_destination(_directory):
                nonlocal attacked
                if attacked:
                    return
                attacked = True
                destination = bundle / "manifest.json"
                destination.unlink()
                destination.write_text('{"other_writer":"wins"}\n', encoding="utf-8")

            with seal_patches(
                repo_root,
                schema_root,
                verifier,
                runner,
                fsync_directory=mock.Mock(side_effect=replace_destination),
            ):
                with self.assertRaisesRegex(codex_schema.SchemaError, "stale schema manifest rollback"):
                    codex_schema.seal_fixtures(argparse.Namespace(tested_at="2026-07-15"))

            self.assertTrue(attacked)
            self.assertEqual(
                codex_schema.read_json(bundle / "manifest.json"), {"other_writer": "wins"}
            )

    def test_final_bundle_verification_failure_restores_original_manifest(self) -> None:
        with seal_workspace() as (repo_root, schema_root, bundle, original):
            verifier = VerificationHarness(repo_root, reject_final=True)
            runner = mock.Mock(return_value=subprocess.CompletedProcess([], 0))

            with seal_patches(repo_root, schema_root, verifier, runner):
                with self.assertRaisesRegex(codex_schema.SchemaError, "final bundle rejected"):
                    codex_schema.seal_fixtures(argparse.Namespace(tested_at="2026-07-15"))

            assert_committed_unchanged(self, bundle, original)

    def test_verified_private_candidate_is_published(self) -> None:
        with seal_workspace() as (repo_root, schema_root, bundle, _original):
            verifier = VerificationHarness(repo_root)
            runner = mock.Mock(return_value=subprocess.CompletedProcess([], 0))
            fsync_directory = mock.Mock(wraps=codex_schema.fsync_directory)

            with seal_patches(
                repo_root,
                schema_root,
                verifier,
                runner,
                fsync_directory=fsync_directory,
            ):
                codex_schema.seal_fixtures(argparse.Namespace(tested_at="2026-07-15"))

            published = codex_schema.read_json(bundle / "manifest.json")
            self.assertEqual(published["generation"]["generatedAt"], "2026-07-14")
            self.assertEqual(published["compatibility"]["testedAt"], "2026-07-15")
            self.assertEqual(published["compatibility"]["fixtures"], "pass")
            self.assertNotIn("attacker", published)
            self.assertEqual(list(bundle.glob(".manifest.*")), [])

            test_manifest, test_evidence = runner.call_args.args
            self.assertEqual(test_manifest["compatibility"]["fixtures"], "under_test")
            self.assertEqual(test_manifest["compatibility"]["fixtureEvidence"], test_evidence)
            self.assertEqual(len(verifier.override_paths), 1)
            self.assertFalse(verifier.override_paths[0].is_relative_to(repo_root))
            fsynced_directories = [Path(call.args[0]) for call in fsync_directory.call_args_list]
            self.assertIn(bundle, fsynced_directories)
            self.assertIn(verifier.override_paths[0].parent, fsynced_directories)

    def assert_publication_swap_rejected(self, attack, message) -> None:
        with seal_workspace() as (repo_root, schema_root, bundle, original):
            verifier = VerificationHarness(repo_root)
            runner = mock.Mock(return_value=subprocess.CompletedProcess([], 0))

            def attacked_fsync(path):
                attack(path)

            with seal_patches(
                repo_root,
                schema_root,
                verifier,
                runner,
                fsync_file=mock.Mock(side_effect=attacked_fsync),
            ):
                with self.assertRaisesRegex(codex_schema.SchemaError, message):
                    codex_schema.seal_fixtures(argparse.Namespace(tested_at="2026-07-15"))

            assert_committed_unchanged(self, bundle, original)


class VerificationHarness:
    def __init__(
        self,
        repo_root: Path,
        *,
        reject_publication: bool = False,
        reject_final: bool = False,
    ):
        self.repo_root = repo_root
        self.reject_publication = reject_publication
        self.reject_final = reject_final
        self.override_paths: list[Path] = []
        self.committed_calls = 0

    def __call__(self, _bundle, **kwargs):
        manifest_path = kwargs.get("manifest_path")
        if manifest_path is None:
            self.committed_calls += 1
            if self.reject_final and self.committed_calls == 3:
                raise codex_schema.SchemaError("final bundle rejected")
            return base_manifest(), []

        path = Path(manifest_path)
        self.override_paths.append(path)
        if self.reject_publication and len(self.override_paths) == 1:
            raise codex_schema.SchemaError("publication rejected")
        return codex_schema.read_json(path), []


class _SealPatches:
    def __init__(
        self,
        repo_root,
        schema_root,
        verifier,
        runner,
        *,
        fsync_file=None,
        fsync_directory=None,
    ):
        self.patchers = (
            mock.patch.object(codex_schema, "REPO_ROOT", repo_root),
            mock.patch.object(codex_schema, "SCHEMA_ROOT", schema_root),
            mock.patch.object(codex_schema, "read_version", return_value="0.144.3"),
            mock.patch.object(codex_schema, "verify_bundle", verifier),
            mock.patch.object(codex_schema, "run_snapshot_fixture_tests", runner),
            mock.patch("builtins.print"),
            fixture_summary_patch(),
        )
        if fsync_file is not None:
            self.patchers += (mock.patch.object(codex_schema, "fsync_file", fsync_file),)
        if fsync_directory is not None:
            self.patchers += (
                mock.patch.object(codex_schema, "fsync_directory", fsync_directory),
            )

    def __enter__(self):
        for patcher in self.patchers:
            patcher.start()
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        for patcher in reversed(self.patchers):
            patcher.stop()


@contextmanager
def generation_workspace():
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        destination = root / "bundle"
        staging = root / ".bundle.staging"
        backup = root / ".bundle.backup"
        destination.mkdir()
        staging.mkdir()
        (destination / "state.txt").write_text("old\n", encoding="utf-8")
        (staging / "state.txt").write_text("candidate\n", encoding="utf-8")
        yield destination, staging, backup


def dummy_bundle_proof(staging: Path) -> codex_schema.BundleProof:
    return codex_schema.BundleProof(
        tree=codex_schema.capture_tree_proof(staging),
        manifest_sha256="m",
        artifact_bundle_sha256="a",
        schema_bundle_sha256="s",
    )


@contextmanager
def snapshot_execution_workspace():
    with tempfile.TemporaryDirectory() as temporary:
        snapshot_root = Path(temporary)
        source = snapshot_root / "elixir" / "lib" / "source.ex"
        source.parent.mkdir(parents=True)
        source.write_text("snapshot-original\n", encoding="utf-8")
        manifest_path = (
            snapshot_root
            / "elixir"
            / "priv"
            / "codex_schema"
            / "0.144.3"
            / "manifest.json"
        )
        manifest_path.parent.mkdir(parents=True)
        manifest_path.write_text("{}\n", encoding="utf-8")
        try:
            yield snapshot_root, source, manifest_path
        finally:
            codex_schema.thaw_snapshot_for_cleanup(snapshot_root)


def snapshot_evidence() -> dict:
    return {
        "codexVersion": "0.144.3",
        "sourceHashAlgorithm": "sha256-text-lf-binary-raw-relative-path-v2",
    }


def start_lock_holder(
    repo_root: Path, *, env: dict[str, str] | None = None
) -> subprocess.Popen:
    program = """
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import codex_schema
with codex_schema.schema_bundle_lock(exclusive=True, repo_root=Path(sys.argv[2])):
    print("locked", flush=True)
    sys.stdin.read(1)
"""
    return subprocess.Popen(
        [
            sys.executable,
            "-c",
            program,
            str(Path(codex_schema.__file__).resolve().parent),
            str(repo_root),
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )


def start_lock_waiter(
    repo_root: Path,
    *,
    exclusive: bool,
    env: dict[str, str] | None = None,
) -> subprocess.Popen:
    program = """
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import codex_schema
exclusive = sys.argv[3] == "exclusive"
with codex_schema.schema_bundle_lock(exclusive=exclusive, repo_root=Path(sys.argv[2])):
    print("acquired", flush=True)
"""
    return subprocess.Popen(
        [
            sys.executable,
            "-c",
            program,
            str(Path(codex_schema.__file__).resolve().parent),
            str(repo_root),
            "exclusive" if exclusive else "shared",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )


def terminate_process(process: subprocess.Popen) -> None:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=1)
    for stream in (process.stdin, process.stdout, process.stderr):
        if stream is not None and not stream.closed:
            stream.close()


def relative_files(root: Path, pattern: str) -> set[str]:
    return {
        path.relative_to(codex_schema.REPO_ROOT).as_posix()
        for path in root.rglob(pattern)
        if path.is_file()
    }


def fixture_summary_patch():
    return mock.patch.object(
        codex_schema,
        "fixture_source_summary",
        return_value={"fileCount": 65, "sha256": "d" * 64},
    )


def seal_workspace():
    class Workspace:
        def __enter__(self):
            self.temporary = tempfile.TemporaryDirectory()
            repo_root = Path(self.temporary.name) / "repo"
            schema_root = repo_root / "elixir" / "priv" / "codex_schema"
            bundle = schema_root / "0.144.3"
            bundle.mkdir(parents=True)
            codex_schema.write_json(bundle / "manifest.json", base_manifest())
            original = (bundle / "manifest.json").read_bytes()
            return repo_root, schema_root, bundle, original

        def __exit__(self, exc_type, exc_value, traceback):
            self.temporary.cleanup()

    return Workspace()


def seal_patches(
    repo_root,
    schema_root,
    verifier,
    runner,
    *,
    fsync_file=None,
    fsync_directory=None,
):
    return _SealPatches(
        repo_root,
        schema_root,
        verifier,
        runner,
        fsync_file=fsync_file,
        fsync_directory=fsync_directory,
    )


def assert_committed_unchanged(test, bundle: Path, original: bytes) -> None:
    test.assertEqual((bundle / "manifest.json").read_bytes(), original)
    test.assertEqual(list(bundle.glob(".manifest.*")), [])


def base_manifest() -> dict:
    return {
        "artifacts": {
            "artifactBundleSha256": "a" * 64,
            "schemaBundleSha256": "b" * 64,
        },
        "codex": {"version": "0.144.3"},
        "compatibility": {
            "fixtures": "not_run",
            "overall": "pending_r0_06",
            "runtimeCapabilities": "not_run",
            "schemaContract": "pass",
            "testedAt": "2026-07-14",
            "transportConformance": "not_run",
        },
        "generation": {"generatedAt": "2026-07-14"},
        "matrix": {"sha256": "c" * 64},
    }


if __name__ == "__main__":
    unittest.main()
