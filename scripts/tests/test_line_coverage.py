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


if __name__ == "__main__":
    unittest.main()
