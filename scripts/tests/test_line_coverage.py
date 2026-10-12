#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""Regression checks for the exact filter used by local and CI Swift coverage."""

import pathlib
import subprocess
import unittest


FILTER = pathlib.Path(__file__).resolve().parents[1] / "line-coverage.awk"


class LineCoverageTests(unittest.TestCase):
    def convert(self, source):
        return subprocess.run(
            ["awk", "-f", str(FILTER)], input=source, text=True, capture_output=True, check=False
        )

    def test_preserves_uncovered_lines_not_function_invocations(self):
        source = (
            "SF:/example/Consent.swift\nFN:10,submit\nFNDA:7,submit\n"
            "DA:10,7\nDA:11,0\nDA:12,3\nLF:3\nLH:2\nend_of_record\n"
            "SF:/example/Audit.swift\nFN:4,write\nFNDA:9,write\n"
            "DA:4,9\nDA:5,0\nLF:2\nLH:1\nend_of_record\n"
        )
        result = self.convert(source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout,
            "SF:/example/Consent.swift\nDA:10,7\nDA:11,0\nDA:12,3\nLF:3\nLH:2\nend_of_record\n"
            "SF:/example/Audit.swift\nDA:4,9\nDA:5,0\nLF:2\nLH:1\nend_of_record\n",
        )

    def test_rejects_missing_line_evidence(self):
        for source in ("", "SF:a\nFN:1,test\nFNDA:1,test\nend_of_record\n", "SF:a\nDA:1,0\n"):
            with self.subTest(source=source):
                self.assertNotEqual(self.convert(source).returncode, 0)

    def test_rejects_malformed_records(self):
        for source in (
            "SF:a\nDA:1,1\nSF:b\nDA:2,0\nend_of_record\n",
            "DA:1,1\nSF:a\nDA:2,0\nend_of_record\n",
            "SF:a\nDA:1,unknown\nDA:2,0\nend_of_record\n",
        ):
            with self.subTest(source=source):
                self.assertNotEqual(self.convert(source).returncode, 0)

    def test_preserves_explicit_zero_line_macro_records_with_measured_source(self):
        measured = "SF:/source.swift\nDA:1,1\nDA:2,0\nLF:2\nLH:1\nend_of_record\n"
        macro = "SF:/macro.cc\nFN:22,expanded\nFNDA:0,expanded\nLF:0\nLH:0\nend_of_record\n"
        retained = "SF:/macro.cc\nLF:0\nLH:0\nend_of_record\n"
        for source, expected in ((macro + measured, retained + measured),
                                 (measured + macro, measured + retained)):
            with self.subTest(source=source):
                result = self.convert(source)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)
        self.assertNotEqual(self.convert(macro).returncode, 0)

    def test_empty_records_require_both_explicit_zero_counters(self):
        measured = "SF:/source.swift\nDA:1,1\nend_of_record\n"
        for counters in ("", "LF:0\n", "LH:0\n", "LF:1\nLH:0\n", "LF:0\nLH:1\n",
                         "LF:0\nLF:0\nLH:0\n", "LF:0\nLH:0\nLH:0\n"):
            with self.subTest(counters=counters):
                source = measured + "SF:/macro.cc\n" + counters + "end_of_record\n"
                self.assertNotEqual(self.convert(source).returncode, 0)

    def test_line_counters_must_be_numeric(self):
        for counters in ("LF:unknown\nLH:1\n", "LF:1\nLH:unknown\n"):
            with self.subTest(counters=counters):
                source = "SF:/source.swift\nDA:1,1\n" + counters + "end_of_record\n"
                self.assertNotEqual(self.convert(source).returncode, 0)

    def test_compiler_summaries_do_not_replace_distinct_source_line_evidence(self):
        # LLVM's summary can include multiple generated function instantiations
        # on one source line; preserve the actual DA entry and summary unchanged.
        for summary in ("LF:2\nLH:2\n", "LF:0\nLH:0\n"):
            # Header expansions can conversely have mapped lines with a zero summary.
            source = "SF:/source.swift\nDA:1,1\n" + summary + "end_of_record\n"
            result = self.convert(source)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, source)


if __name__ == "__main__":
    unittest.main()
