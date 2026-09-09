#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""Verify execution evidence using the format emitted by Swift 6.3's test runner."""

import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET


SCRIPT = Path(__file__).resolve().parents[2] / "scripts/check-swift-test-report.py"
SPEC = importlib.util.spec_from_file_location("swift_test_report", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)

PASSED = '<testcase classname="Fixture" name="executed()" time="0.1" />'
SKIPPED = '<testcase classname="Fixture" name="disabled()"><skipped>Not enabled.</skipped></testcase>'


def document(cases: str, tests: str = "1", skipped: str = "0", failures: str = "0", errors: str = "0") -> str:
    return (f'<testsuites><testsuite name="TestResults" tests="{tests}" skipped="{skipped}" '
            f'failures="{failures}" errors="{errors}">{cases}</testsuite></testsuites>')


class SwiftTestReportTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = tempfile.TemporaryDirectory(prefix="trove-test-report-fixture-")
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name) / "tests-swift-testing.xml"

    def check(self, content: str) -> tuple[int, int]:
        self.path.write_text(content)
        return REPORT.verify(self.path)

    def test_success_and_partial_skips_count_only_executed_test_functions(self) -> None:
        self.assertEqual(self.check(document(PASSED)), (1, 0))
        self.assertEqual(self.check(document(PASSED + SKIPPED, skipped="1")), (1, 1))
        parameterized = '<testcase classname="Fixture" name="parameterized(value:)" time="0.1" />'
        self.assertEqual(self.check(document(PASSED + parameterized + SKIPPED, tests="2", skipped="1")), (2, 1))

    def test_empty_and_all_skipped_reports_fail(self) -> None:
        for content in (document("", tests="0"), document(SKIPPED, tests="0", skipped="1")):
            with self.subTest(content=content), self.assertRaisesRegex(ValueError, "No tests executed"):
                self.check(content)

    def test_missing_and_malformed_reports_fail(self) -> None:
        with self.assertRaises(OSError):
            REPORT.verify(self.path)
        with self.assertRaises(ET.ParseError):
            self.check("<testsuites>")
        for content in ("<testsuites/>", "<testsuite/>", "<testcase/>",
                        "<testsuites><testsuite/><testsuite/></testsuites>"):
            with self.subTest(content=content), self.assertRaises(ValueError):
                self.check(content)

    def test_counters_are_required_canonical_nonnegative_integers(self) -> None:
        for counter in ("tests", "skipped", "failures", "errors"):
            for value in ("-1", "1.0", "true", "", " 1", "１"):
                root = ET.fromstring(document(PASSED))
                root[0].set(counter, value)
                with self.subTest(counter=counter, value=value), self.assertRaises(ValueError):
                    self.check(ET.tostring(root, encoding="unicode"))
            root = ET.fromstring(document(PASSED))
            del root[0].attrib[counter]
            with self.subTest(missing=counter), self.assertRaises(ValueError):
                self.check(ET.tostring(root, encoding="unicode"))

    def test_counters_cannot_hide_failure_or_disagree_with_case_records(self) -> None:
        for content in (document(PASSED, failures="1"), document(PASSED, errors="1"),
                        document(PASSED, tests="2"), document(PASSED, skipped="1"),
                        document(SKIPPED), document(PASSED, tests="0")):
            with self.subTest(content=content), self.assertRaises(ValueError):
                self.check(content)
        for outcome in ("failure", "error", "unknown"):
            case = f'<testcase classname="Fixture" name="executed()"><{outcome}/></testcase>'
            with self.subTest(outcome=outcome), self.assertRaises(ValueError):
                self.check(document(case))

    def test_invalid_case_shapes_cannot_count_as_execution(self) -> None:
        for case in ('<testcase name="test"/>', '<testcase classname="Fixture"/>',
                     '<testcase classname="" name="test"/>', '<properties/>',
                     '<testcase classname="Fixture" name="test"><skipped/><skipped/></testcase>'):
            with self.subTest(case=case), self.assertRaises(ValueError):
                self.check(document(case))


if __name__ == "__main__":
    unittest.main()
