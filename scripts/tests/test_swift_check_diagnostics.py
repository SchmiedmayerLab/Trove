#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""Exercise the real verification entry point when a compiler reports failure but exits zero."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class SwiftDiagnosticTests(unittest.TestCase):
    def run_check(self, stage, diagnostic, status=0, sqlite_status=0, package="TroveAPI", report_mode="passed", platform="Linux"):
        with tempfile.TemporaryDirectory(prefix="trove-swift-diagnostics-") as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            (root / package).mkdir()
            tools = root / "tools"
            tools.mkdir()
            for name in ("check", "line-coverage.awk", "check-swift-test-report.py"):
                shutil.copyfile(ROOT / "scripts" / name, root / "scripts" / name)
            stale = root / package / ".build/verification/execution.stale"
            stale.mkdir(parents=True)
            stale.joinpath("tests-swift-testing.xml").write_text(
                '<testsuites><testsuite tests="1" skipped="0" failures="0" errors="0">'
                '<testcase classname="Fixture" name="stale" /></testsuite></testsuites>'
            )
            programs = {
                "uname": 'echo "$FIXTURE_PLATFORM"\n',
                "xcrun": '[[ "$1" == llvm-cov ]]\nshift\nexec llvm-cov "$@"\n',
                "pkg-config": 'if [[ "$1" == --exists ]]; then exit "$SQLITE_STATUS"; fi\necho 3.45.1\n',
                "swift": '''if [[ "$1" == build || "$1" == test ]]; then
  [[ " $* " == *" --build-system $EXPECTED_BUILD_SYSTEM "* ]]
fi
case "$*" in
  --version) echo 'Swift version 6.4.0 (test fixture)' ;;
  *--show-bin-path) echo "$PWD/.build/debug" ;;
  'package describe --type json')
    if [[ "$REPORT_MODE" == multitarget* ]]; then
      printf '{"name":"Fixture","targets":[{"name":"FixtureTests","type":"test"},{"name":"CLITests","type":"test"}]}'
    else
      printf '{"name":"Fixture","targets":[{"name":"FixtureTests","type":"test"}]}'
    fi ;;
  *)
    echo "$1" >> "$COMMAND_TRACE"
    [[ "$*" == *--enable-code-coverage* ]]
    if [[ "$1" == build ]]; then
      [[ "$*" == *--build-tests* && "${LLVM_PROFILE_FILE:-}" == /dev/null ]]
      mkdir -p .build/debug/codecov
      touch .build/debug/codecov/test.profdata .build/debug/FixtureTests.xctest
      if [[ "$REPORT_MODE" == multitarget* ]]; then touch .build/debug/CLITests.xctest; fi
      if [[ "$REPORT_MODE" == stale-bundle ]]; then touch .build/debug/StaleTests.xctest; fi
    else
      [[ "$1" == test && "$*" == *--skip-build* && -z "${LLVM_PROFILE_FILE+x}" ]]
      arguments=("$@")
      report=""
      for ((index=0; index<${#arguments[@]}-1; index++)); do
        if [[ "${arguments[$index]}" == --xunit-output ]]; then report="${arguments[$index+1]}"; fi
      done
      [[ -n "$report" ]]
      case "$REPORT_MODE" in
        passed|stale-bundle|multitarget-missing) printf '<testsuites><testsuite tests="1" skipped="0" failures="0" errors="0"><testcase classname="FixtureTests.Fixture" name="executed" /></testsuite></testsuites>' > "${report%.xml}-swift-testing.xml" ;;
        multitarget) printf '<testsuites><testsuite tests="1" skipped="0" failures="0" errors="0"><testcase classname="FixtureTests.Fixture" name="executed" /></testsuite><testsuite tests="1" skipped="0" failures="0" errors="0"><testcase classname="CLITests.Fixture" name="executed" /></testsuite></testsuites>' > "${report%.xml}-swift-testing.xml" ;;
        empty) printf '<testsuites><testsuite tests="0" skipped="0" failures="0" errors="0" /></testsuites>' > "${report%.xml}-swift-testing.xml" ;;
        skipped) printf '<testsuites><testsuite tests="0" skipped="1" failures="0" errors="0"><testcase classname="Fixture" name="disabled"><skipped /></testcase></testsuite></testsuites>' > "${report%.xml}-swift-testing.xml" ;;
        malformed) printf '<testsuites>' > "${report%.xml}-swift-testing.xml" ;;
        missing) ;;
        *) exit 97 ;;
      esac
    fi
    if [[ "$1" == "$DIAGNOSTIC_STAGE" ]]; then
      echo "$DIAGNOSTIC_TEXT"
      exit "$DIAGNOSTIC_STATUS"
    fi
    ;;
esac
''',
                "llvm-cov": '''if [[ "$1" == --version ]]; then echo 'coverage test fixture'; exit 0; fi
[[ "$*" == *"--object $PWD/.build/debug/FixtureTests.xctest"* ]]
if [[ "$REPORT_MODE" == multitarget ]]; then [[ "$*" == *"--object $PWD/.build/debug/CLITests.xctest"* ]]; fi
echo coverage >> "$COMMAND_TRACE"
printf 'SF:/fixture.swift\\nDA:1,1\\nend_of_record\\n'
''',
            }
            for name, program in programs.items():
                path = tools / name
                path.write_text("#!/bin/bash\nset -euo pipefail\n" + program)
                path.chmod(0o755)
            trace = root / "trace"
            result = subprocess.run(
                ["/bin/bash", str(root / "scripts/check"), "swift", package],
                env={**os.environ, "PATH": str(tools) + os.pathsep + os.environ["PATH"],
                     "COMMAND_TRACE": str(trace), "DIAGNOSTIC_STAGE": stage,
                     "DIAGNOSTIC_TEXT": diagnostic, "DIAGNOSTIC_STATUS": str(status),
                     "SQLITE_STATUS": str(sqlite_status),
                     "FIXTURE_PLATFORM": platform,
                     "EXPECTED_BUILD_SYSTEM": "swiftbuild" if platform == "Darwin" else "native",
                     "REPORT_MODE": report_mode,
                     "LLVM_PROFILE_FILE": "/caller/profile-must-not-control-test-coverage"},
                capture_output=True, text=True, check=False, timeout=15,
            )
            logs = {path.name: path.read_text() for path in (root / package / ".build/verification").glob("*.log")}
            return result, trace.read_text().splitlines() if trace.exists() else [], logs

    def test_missing_sqlite_development_files_fail_before_build(self):
        for package in ("TroveAPI", "TroveServer"):
            with self.subTest(package=package):
                result, trace, logs = self.run_check("build", "Build complete!", sqlite_status=1, package=package)
                self.assertEqual(result.returncode, 1)
                self.assertIn("libsqlite3-dev", result.stderr)
                self.assertEqual(trace, [])
                self.assertEqual(logs, {})

    def test_zero_exit_compiler_errors_fail_before_coverage_and_preserve_raw_logs(self):
        for stage in ("build", "test"):
            for diagnostic in ("Internal Error: Corrupted JSON", 'LLVM Profile Error: Failed to write file "default.profraw"'):
                with self.subTest(stage=stage, diagnostic=diagnostic):
                    result, trace, logs = self.run_check(stage, diagnostic)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("diagnostics require investigation", result.stderr)
                    self.assertEqual(trace, ["build"] if stage == "build" else ["build", "test"])
                    self.assertIn(diagnostic, logs[stage + ".log"])

    def test_underlying_build_failure_is_not_replaced_by_log_filter(self):
        result, trace, logs = self.run_check("build", "Build failed", status=23)
        self.assertEqual(result.returncode, 23)
        self.assertEqual(trace, ["build"])
        self.assertIn("Build failed", logs["build.log"])

    def test_success_and_ordinary_warnings_reach_coverage(self):
        for package in ("TroveAPI", "TroveServer"):
            for diagnostic in ("Build complete!", "warning: unused import"):
                with self.subTest(package=package, diagnostic=diagnostic):
                    result, trace, _ = self.run_check("build", diagnostic, package=package)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(trace, ["build", "test", "coverage"])

    def test_no_execution_or_report_cannot_reach_coverage_even_with_stale_evidence(self):
        for mode in ("empty", "skipped", "malformed", "missing", "multitarget-missing", "stale-bundle"):
            with self.subTest(mode=mode):
                result, trace, _ = self.run_check("build", "Build complete!", report_mode=mode)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("Swift test execution check failed", result.stderr)
                self.assertEqual(trace, ["build", "test"])

    def test_every_declared_target_binary_is_exported_together(self):
        result, trace, _ = self.run_check("build", "Build complete!", report_mode="multitarget")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2 executed, 0 skipped", result.stderr)
        self.assertEqual(trace, ["build", "test", "coverage"])

    def test_platform_backend_is_consistent_under_strict_system_bash(self):
        # macOS /bin/bash is 3.2: an empty array under nounset is not portable.
        # The swift fixture also checks output-directory discovery, preventing
        # coverage from silently reading artifacts produced by another backend.
        for platform in ("Darwin", "Linux"):
            for package in ("TroveAPI", "TroveServer"):
                with self.subTest(platform=platform, package=package):
                    result, trace, _ = self.run_check("build", "Build complete!", platform=platform, package=package)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(trace, ["build", "test", "coverage"])


if __name__ == "__main__":
    unittest.main()
