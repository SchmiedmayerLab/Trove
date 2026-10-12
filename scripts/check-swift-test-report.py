#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""Require nonempty, successful execution in a Swift Testing xUnit report."""

from pathlib import Path
import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET


def count(suite: ET.Element, name: str) -> int:
    value = suite.get(name)
    if value is None or re.fullmatch(r"[0-9]+", value) is None:
        raise ValueError(f"Missing or invalid {name} counter")
    return int(value)


def verify_suite(suite: ET.Element) -> tuple[int, int]:
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


def verify(path: Path, expected_targets: set[str] | None = None) -> tuple[int, int]:
    root = ET.parse(path).getroot()
    if root.tag != "testsuites" or not len(root) or any(suite.tag != "testsuite" for suite in root):
        raise ValueError("Expected Swift Testing results suites")
    totals = [verify_suite(suite) for suite in root]
    cases = [case for suite in root for case in suite]
    identities = [(case.get("classname"), case.get("name")) for case in cases]
    if len(set(identities)) != len(identities):
        raise ValueError("Duplicate test identities across result suites")
    if expected_targets is not None:
        observed = {case.attrib["classname"].split(".", 1)[0] for case in cases}
        executed_targets = {case.attrib["classname"].split(".", 1)[0]
                            for case in cases if case.find("skipped") is None}
        if observed != expected_targets or executed_targets != expected_targets:
            raise ValueError("Every declared test target must execute; unexpected targets are not accepted")
    return sum(item[0] for item in totals), sum(item[1] for item in totals)


def package_targets(path: Path) -> tuple[str, set[str]]:
    package = json.loads(path.read_text())
    name = package["name"]
    targets = [target["name"] for target in package["targets"] if target["type"] == "test"]
    if (not targets or len(set(targets)) != len(targets)
            or any(not isinstance(value, str) or re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", value) is None
                   for value in [name, *targets])):
        raise ValueError("Invalid package or test-target names")
    return name, set(targets)


def coverage_objects(directory: Path, package: str, targets: set[str]) -> list[Path]:
    unified = directory / f"{package}PackageTests.xctest"
    separate = {directory / f"{target}.xctest" for target in targets}
    actual = set(directory.glob("*.xctest"))
    if actual == {unified}:
        bundles = [unified]
    elif actual == separate:
        bundles = sorted(separate)
    else:
        raise ValueError("Test bundles do not match the declared targets; missing or stale coverage inputs")
    objects = [bundle / "Contents/MacOS" / bundle.stem if bundle.is_dir() else bundle for bundle in bundles]
    if any(not binary.is_file() for binary in objects):
        raise ValueError("A declared test bundle has no coverage binary")
    return objects


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--package-description", type=Path)
    parser.add_argument("--binary-path", type=Path)
    arguments = parser.parse_args()
    if bool(arguments.package_description) != bool(arguments.binary_path):
        parser.error("Package description and binary path must be supplied together")
    try:
        package, targets = package_targets(arguments.package_description) if arguments.package_description else (None, None)
        executed, skipped = verify(arguments.report, targets)
        if package is not None and targets is not None:
            for binary in coverage_objects(arguments.binary_path, package, targets):
                print(binary)
    except (OSError, ET.ParseError, ValueError, KeyError, TypeError) as error:
        print(f"Swift test execution check failed: {error}", file=sys.stderr)
        return 1
    print(f"Swift Testing execution verified: {executed} executed, {skipped} skipped",
          file=sys.stderr if arguments.package_description else sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
