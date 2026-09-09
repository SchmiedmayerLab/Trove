#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""Regression cases for actual Xcode line coverage and runner-path normalization."""

import contextlib
import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "native_line_coverage", pathlib.Path(__file__).resolve().parents[1] / "native-line-coverage.py"
)
COVERAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(COVERAGE)
ARCHIVED = "/different/runner/Trove/TroveiOS/Trove/Example.swift"


class NativeLineCoverageTests(unittest.TestCase):
    def test_preserves_unexecuted_branch_lines(self):
        counts = COVERAGE.line_counts({ARCHIVED: [
            {"line": 1, "isExecutable": False},
            {"line": 2, "isExecutable": True, "executionCount": 8},
            {"line": 3, "isExecutable": True, "executionCount": 0},
            {"line": 4, "isExecutable": True, "executionCount": 2},
        ]}, ARCHIVED)
        self.assertEqual(COVERAGE.lcov({"TroveiOS/Trove/Example.swift": counts}),
                         "SF:TroveiOS/Trove/Example.swift\nDA:2,8\nDA:3,0\nDA:4,2\nLF:3\nLH:2\nend_of_record\n")

    def test_rejects_function_reports_and_foreign_file_identity(self):
        for payload in ({"targets": []}, {"other.swift": []}, {ARCHIVED: {"functions": []}}):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                COVERAGE.line_counts(payload, ARCHIVED)

    def test_rejects_invalid_line_evidence(self):
        for row in (
            {"line": 0, "isExecutable": True, "executionCount": 1},
            {"line": True, "isExecutable": True, "executionCount": 1},
            {"line": 1, "isExecutable": "true", "executionCount": 1},
            {"line": 1, "isExecutable": True},
            {"line": 1, "isExecutable": True, "executionCount": -1},
            {"line": 1, "isExecutable": True, "executionCount": False},
            {"line": 1, "isExecutable": True, "executionCount": 1.5},
        ):
            with self.subTest(row=row), self.assertRaises(ValueError):
                COVERAGE.line_counts({ARCHIVED: [row]}, ARCHIVED)
        row = {"line": 1, "isExecutable": True, "executionCount": 1}
        with self.assertRaises(ValueError):
            COVERAGE.line_counts({ARCHIVED: [row, row]}, ARCHIVED)

    def test_accepts_only_existing_app_sources_without_traversal(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "TroveiOS/Trove/Example.swift"
            source.parent.mkdir(parents=True)
            source.touch()
            self.assertEqual(COVERAGE.source_path(ARCHIVED, root), "TroveiOS/Trove/Example.swift")
            self.assertIsNone(COVERAGE.source_path("/third-party/Example.swift", root))
            self.assertIsNone(COVERAGE.source_path("/repo/TroveiOS/TroveTests/Example.swift", root))
            for path in (ARCHIVED.replace("Example", "Missing"), ARCHIVED.replace("Example.swift", "../Example.swift")):
                with self.subTest(path=path), self.assertRaises(ValueError):
                    COVERAGE.source_path(path, root)

    def test_merges_actual_counts_across_result_bundles(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "TroveiOS/Trove/Example.swift"
            source.parent.mkdir(parents=True)
            source.touch()
            rows = [{"line": 2, "isExecutable": True, "executionCount": 4},
                    {"line": 3, "isExecutable": True, "executionCount": 0}]
            outputs = [ARCHIVED + "\n", json.dumps({ARCHIVED: rows})] * 2
            with patch.object(COVERAGE, "xccov", side_effect=outputs):
                result = COVERAGE.collect([root / "unit.xcresult", root / "ui.xcresult"], root)
            self.assertEqual(result, {"TroveiOS/Trove/Example.swift": {2: 8, 3: 0}})

    def test_requires_evidence_in_every_requested_bundle(self):
        with patch.object(COVERAGE, "xccov", return_value="/third-party/Example.swift\n"):
            with self.assertRaises(ValueError):
                COVERAGE.collect([pathlib.Path("empty.xcresult")], pathlib.Path("."))
        with self.assertRaises(ValueError):
            COVERAGE.collect([], pathlib.Path("."))

    def test_failed_conversion_removes_a_previous_report(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "native.lcov"
            output.write_text("old passing report")
            arguments = ["export", "--repository", directory, "--output", str(output), "missing.xcresult"]
            with patch.object(COVERAGE.sys, "argv", arguments), \
                    patch.object(COVERAGE, "collect", side_effect=ValueError("Missing evidence")), \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(COVERAGE.main(), 1)
            self.assertFalse(output.exists())

    def test_invalid_output_does_not_remove_an_unrelated_file(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "source.swift"
            output.write_text("keep")
            arguments = ["export", "--repository", directory, "--output", str(output), "test.xcresult"]
            with patch.object(COVERAGE.sys, "argv", arguments), \
                    contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                COVERAGE.main()
            self.assertEqual(output.read_text(), "keep")

    def test_xcode_command_reads_the_archive_with_a_bounded_timeout(self):
        with patch.object(COVERAGE.subprocess, "run") as run:
            run.return_value.stdout = "measured data"
            self.assertEqual(COVERAGE.xccov("--file-list", "test.xcresult"), "measured data")
        run.assert_called_once_with(
            ["xcrun", "xccov", "view", "--archive", "--file-list", "test.xcresult"],
            check=True, capture_output=True, text=True, timeout=60,
        )


if __name__ == "__main__":
    unittest.main()
