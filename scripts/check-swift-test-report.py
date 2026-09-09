#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""Require nonempty, successful execution in a Swift Testing xUnit report."""

from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET


def count(suite: ET.Element, name: str) -> int:
    value = suite.get(name)
    if value is None or re.fullmatch(r"[0-9]+", value) is None:
        raise ValueError(f"Missing or invalid {name} counter")
    return int(value)


def verify(path: Path) -> tuple[int, int]:
    root = ET.parse(path).getroot()
    if root.tag != "testsuites" or len(root) != 1 or root[0].tag != "testsuite":
        raise ValueError("Expected one Swift Testing results suite")
    suite = root[0]
    executed, skipped = count(suite, "tests"), count(suite, "skipped")
    if count(suite, "failures") or count(suite, "errors"):
        raise ValueError("The test report contains failures or errors")
    cases = list(suite)
    if any(case.tag != "testcase" for case in cases):
        raise ValueError("Unsupported test-suite content")
    if any(not case.get("classname") or not case.get("name") for case in cases):
        raise ValueError("A test case is missing its identity")
    if any(child.tag != "skipped" for case in cases for child in case):
        raise ValueError("The test report contains an unsuccessful or unsupported outcome")
    if any(len(case) > 1 for case in cases):
        raise ValueError("A test case contains multiple outcomes")
    observed_skips = sum(case.find("skipped") is not None for case in cases)
    # Swift Testing's tests counter excludes skipped tests and counts a
    # parameterized test once, not once per argument. Check the actual records.
    if skipped != observed_skips or executed != len(cases) - observed_skips:
        raise ValueError("Test counters do not match the recorded outcomes")
    if executed == 0:
        raise ValueError("No tests executed; empty and all-skipped selections cannot pass")
    return executed, skipped


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: check-swift-test-report.py <swift-testing.xml>", file=sys.stderr)
        return 2
    try:
        executed, skipped = verify(Path(sys.argv[1]))
    except (OSError, ET.ParseError, ValueError) as error:
        print(f"Swift test execution check failed: {error}", file=sys.stderr)
        return 1
    print(f"Swift Testing execution verified: {executed} executed, {skipped} skipped")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
