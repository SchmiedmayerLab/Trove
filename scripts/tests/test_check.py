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
            ("Swift version 6.4 (swift-6.4-RELEASE)", True),
            ("Swift version 6.4.0 (swift-6.4-RELEASE)", True),
            ("Apple Swift version 6.4 (swiftlang-6.4.0.34.1)", True),
            ("Swift version 6.40 (swift-6.40-RELEASE)", False),
            ("Swift version 6.4garbage", False),
            ("Swift version 6.2.3 (swift-6.2.3-RELEASE)", False),
            ("Swift version 6.3.3 (swift-6.3.3-RELEASE)", False),
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
        self.assertIn("swift build --build-system native -c release --force-resolved-versions --jobs 4", dockerfile)

    def test_static_release_uses_matching_native_artifact_paths(self):
        dockerfile = (ROOT / "TroveServer/Dockerfile").read_text()
        self.assertEqual(dockerfile.count("swift build --build-system native"), 3)
        self.assertEqual(dockerfile.count("swift build --build-system native -c release --show-bin-path"), 2)
        self.assertIn("--static-swift-stdlib", dockerfile)

    def test_linux_verification_and_release_use_the_same_pinned_swift_image(self):
        dockerfile = (ROOT / "TroveServer/Dockerfile").read_text()
        workflow = (ROOT / ".github/workflows/swift-package.yml").read_text()
        image_pattern = r"swift:6\.4\.2-noble@sha256:[a-f0-9]{64}"
        build_images = re.findall(image_pattern, dockerfile)
        self.assertEqual(len(build_images), 1)
        self.assertEqual(re.findall(image_pattern, workflow), build_images * 2)

    def test_runtime_updates_installed_base_packages_before_adding_libraries(self):
        dockerfile = (ROOT / "TroveServer/Dockerfile").read_text()
        runtime = dockerfile.split("# Run image", 1)[1]
        self.assertLess(runtime.index("apk upgrade --no-cache"), runtime.index("apk add --no-cache"))

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
        self.assertIn("timescale/timescaledb:2.32.0-pg18@sha256:", compose)
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
        self.assertEqual(len(updates), 16)
        self.assertIn(("docker-compose", "/TroveServer/Benchmarks"), updates)
        for directory in ("infrastructure/base/keycloak", "infrastructure/dev", "database-operator", "argocd-apps/dev"):
            self.assertIn(("docker", "/TroveInfrastructure/" + directory), updates)
        self.assertIn(("pip", "/documentation"), updates)
        self.assertIn(("pip", "/TroveInfrastructure/tools"), updates)
        self.assertIn(("pip", "/TroveInfrastructure/validator"), updates)
        # The Wolfi Runtime Refresh workflow owns the validator runtime base and packages.
        self.assertNotIn(("docker", "/TroveInfrastructure/validator/runtime"), updates)
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
                path = ROOT / directory.lstrip("/")
                found = list(path.glob(manifests[ecosystem]))
                if ecosystem == "docker" and not found:
                    # Kubernetes manifests with pinned images.
                    found = [item for item in path.glob("*.yaml") if re.search(r"image: \S+@sha256:", item.read_text())]
                self.assertTrue(found)

    def test_validator_runtime_images_match_the_manifest(self):
        # Dependabot updates only the runtime Dockerfile; the manifest identity must change with it.
        runtime = (ROOT / "TroveInfrastructure/validator/runtime/Dockerfile").read_text()
        manifest = json.loads((ROOT / "TroveInfrastructure/validator/manifest.json").read_text())["runtimeImages"]
        self.assertEqual(re.findall(r"^FROM (\S+)", runtime, re.MULTILINE), [manifest["base"]])
        self.assertRegex(manifest["base"], r"^cgr\.dev/chainguard/wolfi-base:latest@sha256:[0-9a-f]{64}$")
        installed = re.search(r"apk add --no-cache((?:\s+\\\n\s+\S+)+)", runtime).group(1)
        self.assertEqual(sorted(re.findall(r"(\S+=\S+)", installed)), sorted(manifest["packages"]))
        for package in manifest["packages"]:
            self.assertRegex(package, r"^[a-z0-9.-]+=[0-9][^=\s]*-r\d+$")
        self.assertTrue(any(package.startswith("python-3.15=") for package in manifest["packages"]))
        self.assertTrue(any(package.startswith("openjdk-21-jre=") for package in manifest["packages"]))
        validator = (ROOT / "TroveInfrastructure/validator/Dockerfile").read_text()
        self.assertEqual(re.findall(r"^FROM (\S+)", validator, re.MULTILINE), ["${RUNTIME_IMAGE}"])
        self.assertNotIn("RUN ", validator)
        for workflow in ("dev-stack.yml", "swift-package.yml"):
            text = (ROOT / ".github/workflows" / workflow).read_text()
            runtime_build = text.index("TroveInfrastructure/validator/runtime")
            offline_build = text.index("docker build --network=none --build-arg RUNTIME_IMAGE=")
            self.assertLess(runtime_build, offline_build)

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

    def test_ui_stack_stops_before_runtime_creation_when_port_preflight_fails(self):
        for status in (1, 2):
            with self.subTest(status=status):
                result, runtime_exists = self.run_ui_preflight(f'#!/bin/bash\nexit {status}\n')
                self.assertEqual(result.returncode, status)
                self.assertFalse(runtime_exists)

    def run_ui_preflight(self, python_script):
        with tempfile.TemporaryDirectory(prefix="trove-port-test-") as directory:
            temporary = pathlib.Path(directory)
            executable = temporary / "python3"
            executable.write_text(python_script)
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
            "TroveInfrastructure/validator/manifest.json",
        ):
            self.assertIn(f'"{dependency}"', match.group(1))
        self.assertIn("if: needs.changes.outputs.ios_ui == 'true'", workflow)

    def test_real_stack_ui_resolve_and_test_require_locked_versions(self):
        workflow = (ROOT / ".github/workflows/build-and-test.yml").read_text()
        ui_job = workflow.split("  ios-ui:\n", 1)[1].split("\n  web:\n", 1)[0]
        self.assertEqual(ui_job.count("-onlyUsePackageVersionsFromResolvedFile"), 1)
        self.assertIn("git diff --exit-code -- Trove.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved", ui_job)
        self.assertIn("name: Retain resolved iOS dependency lockfile", ui_job)
        self.assertIn("name: Retain resolved Swift dependency lockfiles", ui_job)
        for package in ("TroveAPI", "TroveServer"):
            self.assertIn(f"swift package --package-path ../{package} resolve", ui_job)
            self.assertIn(f"../{package}/Package.resolved", ui_job)
        self.assertLess(ui_job.index("git diff --exit-code"), ui_job.index("name: Install the native test stack"))
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

    def test_python_tool_requirements_are_hashed_and_installed_with_hashes(self):
        for path in ("TroveInfrastructure/tools/requirements.txt",
                     "TroveInfrastructure/validator/recovery-requirements.txt"):
            with self.subTest(path=path):
                text = (ROOT / path).read_text()
                pins = re.findall(r"^([A-Za-z0-9_.-]+)==\S+", text, re.MULTILINE)
                self.assertTrue(pins)
                self.assertEqual(len(re.findall(r"^\S+==\S+.*\\\n\s+--hash=sha256:[0-9a-f]{64}", text, re.MULTILINE)), len(pins))
                self.assertTrue((ROOT / path.replace(".txt", ".in")).is_file())
        installs = [line for path in sorted((ROOT / ".github/workflows").glob("*.yml"))
                    for line in path.read_text().splitlines() if "tools/requirements.txt" in line and "install" in line]
        self.assertEqual(len(installs), 3)
        for line in installs:
            self.assertIn("--require-hashes", line)

    def test_every_action_is_pinned_to_a_commit_with_its_release(self):
        files = sorted((ROOT / ".github").rglob("*.yml"))
        references = []
        for path in files:
            for line in path.read_text().splitlines():
                match = re.match(r"\s*(?:-\s+)?uses:\s+(\S+)(.*)$", line)
                if match and not match.group(1).startswith("./"):
                    references.append((path.name, match.group(1), match.group(2)))
        self.assertGreater(len(references), 50)
        for name, reference, comment in references:
            with self.subTest(file=name, reference=reference):
                self.assertRegex(reference, r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$")
                self.assertRegex(comment, r"^ # v\d+\.\d+\.\d+$")

    def test_infrastructure_tools_are_pinned_and_checksum_verified(self):
        workflow = (ROOT / ".github/workflows/infrastructure.yml").read_text()
        self.assertNotIn("/latest/", workflow)
        self.assertNotIn("azure/setup-helm", workflow)
        for release, checksum in (("KUBECONFORM_RELEASE: v0.8.0", "KUBECONFORM_SHA256"),
                                  ("KIND_RELEASE: v0.33.0", "KIND_SHA256"),
                                  ("HELM_RELEASE: v4.3.2", "HELM_SHA256")):
            with self.subTest(release=release):
                step = workflow.split(release, 1)[1].split("- name:", 1)[0]
                self.assertRegex(workflow, checksum + r": [0-9a-f]{64}\n")
                self.assertIn(f'"${checksum}"', step)
                self.assertLess(step.index("sha256sum --check --strict"), step.index("/usr/local/bin"))

    def test_opentofu_uses_the_committed_provider_lock(self):
        workflow = (ROOT / ".github/workflows/infrastructure.yml").read_text()
        self.assertIn("tofu init -backend=false -lockfile=readonly", workflow)
        self.assertRegex(workflow, r"setup-opentofu@[0-9a-f]{40} # v[0-9.]+\n\s+with:\n\s+tofu_version: \d+\.\d+\.\d+\n")
        lock = (ROOT / "TroveInfrastructure/terraform/.terraform.lock.hcl").read_text()
        for provider in ("hashicorp/google", "hashicorp/google-beta"):
            block = lock.split(f'provider "registry.opentofu.org/{provider}"', 1)[1].split("\n}\n", 1)[0]
            self.assertRegex(block, r'version\s+= "\d+\.\d+\.\d+"')
            self.assertIn('"h1:', block)
            self.assertIn('"zh:', block)

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
