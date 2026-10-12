#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""Verify execution evidence using the Swift Testing xUnit report format."""

import importlib.util
import json
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

    def test_multiple_target_suites_require_execution_from_every_declared_target(self) -> None:
        first = document(PASSED.replace('classname="Fixture"', 'classname="APITests.Fixture"'))
        second = document(PASSED.replace('classname="Fixture"', 'classname="CLITests.Fixture"'))
        combined = first.replace("</testsuites>", "") + second.replace("<testsuites>", "")
        self.path.write_text(combined)
        self.assertEqual(REPORT.verify(self.path, {"APITests", "CLITests"}), (2, 0))
        for targets in ({"APITests"}, {"APITests", "CLITests", "MissingTests"}):
            with self.subTest(targets=targets), self.assertRaisesRegex(ValueError, "Every declared"):
                REPORT.verify(self.path, targets)
        duplicate = first.replace("</testsuites>", "") + first.replace("<testsuites>", "")
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            self.check(duplicate)
        empty = document("", tests="0")
        with self.assertRaisesRegex(ValueError, "No tests executed"):
            self.check(first.replace("</testsuites>", "") + empty.replace("<testsuites>", ""))

    def test_an_all_skipped_target_cannot_hide_in_a_unified_suite(self) -> None:
        self.path.write_text(document(
            PASSED.replace('classname="Fixture"', 'classname="APITests.Fixture"')
            + SKIPPED.replace('classname="Fixture"', 'classname="CLITests.Fixture"'), skipped="1"))
        with self.assertRaisesRegex(ValueError, "Every declared"):
            REPORT.verify(self.path, {"APITests", "CLITests"})

    def test_coverage_accepts_only_complete_declared_or_unified_bundle_sets(self) -> None:
        directory = self.path.parent / "bin"
        directory.mkdir()
        targets = {"APITests", "CLITests"}
        with self.assertRaisesRegex(ValueError, "Test bundles"):
            REPORT.coverage_objects(directory, "Example", targets)
        api = directory / "APITests.xctest"
        api.touch()
        with self.assertRaisesRegex(ValueError, "Test bundles"):
            REPORT.coverage_objects(directory, "Example", targets)
        cli = directory / "CLITests.xctest"
        binary = cli / "Contents/MacOS/CLITests"
        binary.parent.mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, "no coverage binary"):
            REPORT.coverage_objects(directory, "Example", targets)
        binary.touch()
        self.assertEqual(REPORT.coverage_objects(directory, "Example", targets), [api, binary])
        stale = directory / "ExamplePackageTests.xctest"
        stale.touch()
        with self.assertRaisesRegex(ValueError, "Test bundles"):
            REPORT.coverage_objects(directory, "Example", targets)
        api.unlink()
        binary.unlink()
        binary.parent.rmdir()
        (cli / "Contents").rmdir()
        cli.rmdir()
        self.assertEqual(REPORT.coverage_objects(directory, "Example", targets), [stale])

    def test_package_targets_come_from_manifest_metadata(self) -> None:
        package = {"name": "Example", "targets": [
            {"name": "API", "type": "library"}, {"name": "APITests", "type": "test"}]}
        self.path.write_text(json.dumps(package))
        self.assertEqual(REPORT.package_targets(self.path), ("Example", {"APITests"}))
        for name in ("../outside", "", None):
            package["name"] = name
            self.path.write_text(json.dumps(package))
            with self.subTest(name=name), self.assertRaises(ValueError):
                REPORT.package_targets(self.path)


if __name__ == "__main__":
    unittest.main()
