#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""Cheap validation of verification inputs and the configured manifest locations."""

import json
import os
import pathlib
import re
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class VerificationInputTests(unittest.TestCase):
    def test_swift_version_gate_accepts_linux_release_and_apple_patch_versions(self):
        source = (ROOT / "scripts/check").read_text()
        match = re.search(r'if \[\[ ! "\$swift_version" =~ (.+) ]]; then', source)
        self.assertIsNotNone(match)
        for version, accepted in (
            ("Swift version 6.3 (swift-6.3-RELEASE)", True),
            ("Swift version 6.3.0 (swift-6.3-RELEASE)", True),
            ("Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3)", True),
            ("Swift version 6.30 (swift-6.30-RELEASE)", False),
            ("Swift version 6.3garbage", False),
            ("Swift version 6.2.3 (swift-6.2.3-RELEASE)", False),
            ("Swift version 6.4 (swift-6.4-RELEASE)", False),
        ):
            with self.subTest(version=version):
                result = subprocess.run(
                    ["bash", "-c", '[[ "$VERSION" =~ ' + match.group(1) + ' ]]'],
                    env={**os.environ, "VERSION": version}, capture_output=True, check=False,
                )
                self.assertEqual(result.returncode == 0, accepted)

    def test_rejects_unknown_package_before_build(self):
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/check"), "swift", "unknown"], capture_output=True, check=False
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"Expected package", result.stderr)

    def test_rejects_artifact_path_before_build(self):
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/check"), "swift", "TroveAPI", "../outside.lcov"],
            capture_output=True, check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"not a path", result.stderr)

    def test_release_build_bounds_compiler_parallelism(self):
        dockerfile = (ROOT / "TroveServer/Dockerfile").read_text()
        self.assertIn("swift build -c release --force-resolved-versions --jobs 4", dockerfile)

    def test_database_probes_require_final_tcp_server_not_initialization_socket(self):
        for relative_path, expected_count in (
            ("TroveInfrastructure/docker/docker-compose.yml", 2),
            ("TroveServer/Benchmarks/docker-compose.yml", 1),
            ("TroveInfrastructure/infrastructure/dev/timescale.yaml", 3),
            (".github/workflows/swift-package.yml", 1),
        ):
            with self.subTest(path=relative_path):
                commands = [line for line in (ROOT / relative_path).read_text().splitlines()
                            if "pg_isready " in line]
                self.assertEqual(len(commands), expected_count)
                for command in commands:
                    self.assertIn("-h 127.0.0.1", command)
                    self.assertIn(" -d ", command)

    def test_authority_uses_a_new_volume_without_legacy_clinical_connections(self):
        compose = (ROOT / "TroveInfrastructure/docker/docker-compose.yml").read_text()
        self.assertIn("server_authority_data:/pgdata", compose)
        self.assertIn("PGDATA: /pgdata", compose)
        self.assertIn("timescale/timescaledb:latest-pg18@sha256:", compose)
        self.assertNotIn("server_db_data", compose)
        self.assertNotIn("server_timescale_data", compose)
        self.assertNotIn("server-timescale", compose)
        self.assertNotIn("TIMESCALE_", compose)
        benchmark = (ROOT / "TroveServer/Benchmarks/docker-compose.yml").read_text()
        self.assertIn("network_mode: none", benchmark)
        self.assertIn("benchmark_data:/pgdata", benchmark)
        self.assertNotIn("server_authority_data", benchmark)
        for path in ("configmap.yaml", "deployment.yaml"):
            self.assertNotIn("TIMESCALE_", (ROOT / "TroveInfrastructure/apps/base/server" / path).read_text())

    def test_timescale_startup_has_a_separate_bounded_probe_budget(self):
        manifest = (ROOT / "TroveInfrastructure/infrastructure/dev/timescale.yaml").read_text()
        startup = manifest.split("          startupProbe:\n", 1)[1].split("          readinessProbe:\n", 1)[0]
        self.assertIn("periodSeconds: 5", startup)
        self.assertIn("failureThreshold: 60", startup)
        for probe in ("startupProbe", "readinessProbe", "livenessProbe"):
            block = re.split(r"\n {10}(?=\S)", manifest.split(f"          {probe}:\n", 1)[1], maxsplit=1)[0]
            self.assertIn(" -t 2", block)
            self.assertIn("timeoutSeconds: 3", block)

    def test_dependency_updates_point_at_manifests(self):
        source = (ROOT / ".github/dependabot.yml").read_text()
        updates = re.findall(r'package-ecosystem: "([^"]+)"\s+directory: "([^"]+)"', source)
        self.assertEqual(len(updates), 10)
        self.assertIn(("pip", "/TroveInfrastructure/tools"), updates)
        self.assertIn(("pip", "/TroveInfrastructure/validator"), updates)
        manifests = {
            "github-actions": ".github/workflows/*.yml",
            "swift": "Package.swift",
            "npm": "package.json",
            "pip": "*requirements*.txt",
            "docker": "Dockerfile",
            "docker-compose": "docker-compose.yml",
            "terraform": "*.tf",
        }
        for ecosystem, directory in updates:
            with self.subTest(ecosystem=ecosystem, directory=directory):
                self.assertTrue(list((ROOT / directory.lstrip("/")).glob(manifests[ecosystem])))

    def test_ui_stack_rejects_invalid_prebuilt_binary_before_startup(self):
        for binary in ("relative/server", str(ROOT / "TroveServer"), str(ROOT / "TroveServer/Package.swift")):
            with self.subTest(binary=binary):
                result = subprocess.run(
                    ["bash", str(ROOT / "TroveiOS/scripts/start-ui-test-stack.sh")],
                    env={
                        **os.environ,
                        "GITHUB_ENV": "/unused/verification.env",
                        "KEYCLOAK_HOME": "/unused/keycloak",
                        "RUNNER_TEMP": "/unused/runtime",
                        "TROVE_UI_TEST_SERVER_BINARY": binary,
                    },
                    capture_output=True, check=False,
                )
                self.assertEqual(result.returncode, 1)
                self.assertIn(b"absolute path to an executable", result.stderr)

    def test_ui_stack_rejects_occupied_ports_before_creating_runtime(self):
        for port in (8080, 8180, 9000):
            with self.subTest(port=port):
                result, runtime_exists = self.run_ui_preflight(
                    '#!/bin/bash\nfor argument; do\n'
                    f'  if [[ "$argument" == "-iTCP:{port}" ]]; then exit 0; fi\n'
                    'done\nexit 1\n'
                )
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"port {port} is already in use".encode(), result.stderr)
                self.assertFalse(runtime_exists)

    def test_ui_stack_fails_closed_if_port_inspection_is_denied(self):
        for failure in ('echo "Permission denied" >&2\nexit 1', 'exit 2'):
            with self.subTest(failure=failure):
                result, runtime_exists = self.run_ui_preflight('#!/bin/bash\n' + failure + '\n')
                self.assertEqual(result.returncode, 1)
                self.assertIn(b"Unable to inspect native test port", result.stderr)
                self.assertFalse(runtime_exists)

    def run_ui_preflight(self, lsof_script):
        with tempfile.TemporaryDirectory(prefix="trove-port-test-") as directory:
            temporary = pathlib.Path(directory)
            executable = temporary / "lsof"
            executable.write_text(lsof_script)
            executable.chmod(0o755)
            runtime = temporary / "runtime"
            result = subprocess.run(
                ["bash", str(ROOT / "TroveiOS/scripts/start-ui-test-stack.sh")],
                env={
                    **os.environ,
                    "PATH": str(temporary) + os.pathsep + os.environ["PATH"],
                    "GITHUB_ENV": str(temporary / "environment"),
                    "KEYCLOAK_HOME": str(temporary / "keycloak"),
                    "RUNNER_TEMP": str(runtime),
                    "TROVE_UI_TEST_SERVER_BINARY": "",
                },
                capture_output=True, check=False,
            )
            return result, runtime.exists()

    def test_real_stack_ui_includes_server_and_realm_changes(self):
        workflow = (ROOT / ".github/workflows/build-and-test.yml").read_text()
        match = re.search(r"            ios_ui:\n((?:              .*\n)+)", workflow)
        self.assertIsNotNone(match)
        for dependency in (
            "TroveiOS/**", "TroveAPI/**", "TroveServer/**",
            "TroveInfrastructure/docker/keycloak/realm.json",
        ):
            self.assertIn(f'"{dependency}"', match.group(1))
        self.assertIn("if: needs.changes.outputs.ios_ui == 'true'", workflow)

    def test_real_stack_ui_resolve_and_test_require_locked_versions(self):
        workflow = (ROOT / ".github/workflows/build-and-test.yml").read_text()
        ui_job = workflow.split("  ios-ui:\n", 1)[1].split("\n  web:\n", 1)[0]
        self.assertEqual(ui_job.count("-onlyUsePackageVersionsFromResolvedFile"), 2)
        self.assertIn("-resolvePackageDependencies", ui_job)
        self.assertIn("xcodebuild test", ui_job)

    def test_native_coverage_is_required_and_does_not_use_function_summary_conversion(self):
        workflow = (ROOT / ".github/workflows/build-and-test.yml").read_text()
        native_job = workflow.split("  native-line-coverage:\n", 1)[1].split("\n  coverage:\n", 1)[0]
        collector = workflow.split("\n  coverage:\n", 1)[1]
        self.assertIn("scripts/native-line-coverage.py", native_job)
        self.assertIn("name: Trove-iOS-Tests.xcresult", native_job)
        self.assertIn("name: Trove-iOS-UI-Tests.xcresult", native_job)
        dependencies = re.search(r"^    needs: \[([^\]]+)\]$", collector, re.MULTILINE)
        self.assertIsNotNone(dependencies)
        self.assertIn("native-line-coverage", [item.strip() for item in dependencies.group(1).split(",")])
        self.assertIn("Trove-iOS-Line-Tests.lcov", collector)
        self.assertNotIn("coveragereports:", collector)

    def test_native_test_services_bind_only_to_loopback(self):
        launcher = (ROOT / "TroveiOS/scripts/start-ui-test-stack.sh").read_text()
        self.assertIn("--http-host=127.0.0.1", launcher)
        self.assertIn("--http-management-host=127.0.0.1", launcher)
        self.assertIn("--hostname 127.0.0.1", launcher)
        self.assertNotIn("0.0.0.0", launcher)

    def test_manifest_pipelines_use_fail_closed_shell(self):
        workflow = (ROOT / ".github/workflows/infrastructure.yml").read_text()
        job = workflow.split("  manifests:\n", 1)[1].split("\n  tofu-validate:\n", 1)[0]
        self.assertRegex(job, r"defaults:\n\s+run:\n\s+shell: bash\n")

    def test_dev_stack_uses_declared_node_version(self):
        package = json.loads((ROOT / "TroveWeb/package.json").read_text())
        workflow = (ROOT / ".github/workflows/dev-stack.yml").read_text()
        install = workflow.index("- name: Install the web dependencies")
        setup = workflow.index("- uses: actions/setup-node@")
        self.assertLess(setup, install)
        self.assertIn(f'node-version: {package["engines"]["node"]}', workflow[setup:install])

    def test_e2e_coverage_preserves_test_and_report_failures(self):
        command = json.loads((ROOT / "TroveWeb/package.json").read_text())["scripts"]["test:e2e:coverage"]
        for test_status, coverage_status, expected in ((0, 0, 0), (23, 0, 23), (0, 29, 29), (23, 29, 23)):
            with self.subTest(test_status=test_status, coverage_status=coverage_status):
                with tempfile.TemporaryDirectory(prefix="trove-coverage-status-") as directory:
                    temporary = pathlib.Path(directory)
                    for name, status in (("playwright", test_status), ("nyc", coverage_status)):
                        executable = temporary / name
                        executable.write_text(f'#!/bin/sh\nprintf "%s\\n" {name} >> "$VERIFICATION_CALLS"\nexit {status}\n')
                        executable.chmod(0o755)
                    calls = temporary / "calls"
                    result = subprocess.run(
                        ["sh", "-c", command], capture_output=True, check=False,
                        env={**os.environ, "PATH": str(temporary) + os.pathsep + os.environ["PATH"], "VERIFICATION_CALLS": str(calls)},
                    )
                    self.assertEqual(result.returncode, expected)
                    self.assertEqual(calls.read_text().splitlines(), ["playwright", "nyc"])


if __name__ == "__main__":
    unittest.main()
