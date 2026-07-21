#!/usr/bin/env python3
# Copyright 2026 Symphony Studio contributors
# SPDX-License-Identifier: Apache-2.0
"""Run the intentionally bounded Codex schema unit-test suite."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys
import unittest


EXPECTED_TEST_COUNT = 157


def discover_suite(
    start_directory: Path,
    *,
    expected_count: int = EXPECTED_TEST_COUNT,
    pattern: str = "test_*.py",
) -> unittest.TestSuite:
    suite = unittest.TestLoader().discover(str(start_directory), pattern=pattern)
    count = suite.countTestCases()
    if count == 0:
        raise RuntimeError("Codex schema unit-test discovery returned an empty suite")
    if count != expected_count:
        raise RuntimeError(
            f"Codex schema unit-test count is {count}; expected exactly {expected_count}"
        )
    return suite


def result_is_clean(result: unittest.TestResult, *, expected_count: int) -> bool:
    """Require every intentional test to run and forbid disabled-test outcomes."""

    return (
        result.testsRun == expected_count
        and not result.failures
        and not result.errors
        and not result.skipped
        and not result.expectedFailures
        and not result.unexpectedSuccesses
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--start-directory",
        type=Path,
        default=Path(__file__).resolve().parent,
    )
    parser.add_argument("--expected-count", type=int, default=EXPECTED_TEST_COUNT)
    args = parser.parse_args()
    try:
        suite = discover_suite(
            args.start_directory.resolve(), expected_count=args.expected_count
        )
    except RuntimeError as error:
        parser.error(str(error))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    if result_is_clean(result, expected_count=args.expected_count):
        return 0

    print(
        "Codex schema tests must all run normally: "
        f"ran={result.testsRun}/{args.expected_count}, "
        f"failures={len(result.failures)}, errors={len(result.errors)}, "
        f"skipped={len(result.skipped)}, "
        f"expected_failures={len(result.expectedFailures)}, "
        f"unexpected_successes={len(result.unexpectedSuccesses)}",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
