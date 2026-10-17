#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""Exercise the workflow's final gate, including selection and dependency failures."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/check-ci-results.py"
SPEC = importlib.util.spec_from_file_location("ci_results", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)

SELECTORS = ("api", "server", "web", "ios", "ios_ui", "infrastructure", "devstack")
JOBS = ("changes", "api", "server", "web", "ios", "ios-ui", "infrastructure",
        "dev-stack", "native-line-coverage", "coverage", "secret-scan", "vulnerability-scan")
EXPECTED = {
    "api": {"api", "coverage"},
    "server": {"server", "dev-stack", "coverage"},
    "web": {"web", "dev-stack", "coverage"},
    "ios": {"ios", "native-line-coverage", "coverage"},
    "ios_ui": {"ios-ui", "native-line-coverage", "coverage"},
    "infrastructure": {"infrastructure", "dev-stack", "coverage"},
    "devstack": {"dev-stack", "coverage"},
}


def fixture(selected: tuple[str, ...] = ()) -> dict[str, dict[str, object]]:
    required = {"changes", "secret-scan", "vulnerability-scan"}.union(*(EXPECTED[name] for name in selected))
    jobs: dict[str, dict[str, object]] = {
        name: {"result": "success" if name in required else "skipped"} for name in JOBS
    }
    jobs["changes"]["outputs"] = {name: "true" if name in selected else "false" for name in SELECTORS}
    return jobs


class CIResultTests(unittest.TestCase):
    def test_documentation_only_change_does_not_require_unselected_tests(self) -> None:
        self.assertEqual(GATE.verify(fixture()), ["changes", "secret-scan", "vulnerability-scan"])

    def test_every_selection_combination_requires_its_transitive_checks(self) -> None:
        for mask in range(1 << len(SELECTORS)):
            selected = tuple(name for index, name in enumerate(SELECTORS) if mask & (1 << index))
            with self.subTest(selected=selected):
                required = {"changes", "secret-scan", "vulnerability-scan"}.union(*(EXPECTED[name] for name in selected))
                self.assertEqual(set(GATE.verify(fixture(selected))), required)

    def test_selected_failure_cancellation_or_skip_never_passes(self) -> None:
        for name in JOBS:
            for result in ("failure", "cancelled", "skipped"):
                with self.subTest(job=name, result=result):
                    jobs = fixture(SELECTORS)
                    jobs[name]["result"] = result
                    with self.assertRaises(ValueError):
                        GATE.verify(jobs)

    def test_extra_success_is_safe_but_unselected_failure_is_not(self) -> None:
        for name in JOBS[1:]:
            for result in ("success", "failure", "cancelled"):
                with self.subTest(job=name, result=result):
                    jobs = fixture()
                    jobs[name]["result"] = result
                    if result == "success":
                        self.assertEqual(GATE.verify(jobs), ["changes", "secret-scan", "vulnerability-scan"])
                    else:
                        with self.assertRaises(ValueError):
                            GATE.verify(jobs)

    def test_missing_extra_and_malformed_jobs_fail_closed(self) -> None:
        for name in JOBS:
            jobs = fixture()
            del jobs[name]
            with self.subTest(missing=name), self.assertRaises(ValueError):
                GATE.verify(jobs)
            for result in (None, True, 0, [], {}, "", "pending", "neutral"):
                jobs = fixture()
                jobs[name]["result"] = result
                with self.subTest(job=name, result=result), self.assertRaises(ValueError):
                    GATE.verify(jobs)
        with self.assertRaises(ValueError):
            GATE.verify({**fixture(), "unexpected": {"result": "success"}})
        for value in (None, [], "", 0, {**fixture(), "api": None}):
            with self.subTest(value=value), self.assertRaises(ValueError):
                GATE.verify(value)

    def test_missing_or_noncanonical_selectors_fail_closed(self) -> None:
        for name in SELECTORS:
            for value in (None, True, False, 0, 1, [], {}, "", "True", "FALSE", "true "):
                jobs = fixture()
                jobs["changes"]["outputs"] = {
                    selector: value if selector == name else "false" for selector in SELECTORS
                }
                with self.subTest(selector=name, value=value), self.assertRaises(ValueError):
                    GATE.verify(jobs)
            jobs = fixture()
            jobs["changes"]["outputs"] = {selector: "false" for selector in SELECTORS if selector != name}
            with self.subTest(missing=name), self.assertRaises(ValueError):
                GATE.verify(jobs)
        for outputs in (None, [], {}, {**dict.fromkeys(SELECTORS, "false"), "unexpected": "false"}):
            jobs = fixture()
            jobs["changes"]["outputs"] = outputs
            with self.subTest(outputs=outputs), self.assertRaises(ValueError):
                GATE.verify(jobs)

    def test_cli_preserves_failure_status_and_does_not_echo_untrusted_payload(self) -> None:
        for payload, expected in ((json.dumps(fixture(SELECTORS)), 0), ("private-malformed-input", 1),
                                  (json.dumps({}), 1), (json.dumps(fixture()), 0)):
            with self.subTest(expected=expected):
                result = subprocess.run([sys.executable, str(SCRIPT)], input=payload,
                                        text=True, capture_output=True, timeout=10, check=False)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertNotIn("private-malformed-input", result.stdout + result.stderr)

    def test_actual_workflow_wires_the_complete_gate(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/build-and-test.yml").read_text())
        jobs = workflow["jobs"]
        gate = jobs["verification"]
        self.assertEqual(set(gate["needs"]), set(JOBS))
        self.assertEqual(gate["if"], "always()")
        self.assertEqual(gate["runs-on"], "ubuntu-24.04")
        self.assertEqual(set(jobs["changes"]["outputs"]), set(SELECTORS))
        step = gate["steps"][-1]
        self.assertEqual(step["env"]["TROVE_CI_NEEDS"], "${{ toJSON(needs) }}")
        self.assertIn("set -euo pipefail", step["run"])
        self.assertIn("python3 scripts/check-ci-results.py", step["run"])
        self.assertEqual(set(jobs) - {"verification", "publish-images"}, set(JOBS))
        for selector, job in (("api", "api"), ("server", "server"), ("web", "web"),
                              ("ios", "ios"), ("ios_ui", "ios-ui"), ("infrastructure", "infrastructure")):
            self.assertEqual(jobs[job]["needs"], "changes")
            self.assertEqual(jobs[job]["if"], f"needs.changes.outputs.{selector} == 'true'")
        self.assertEqual(jobs["dev-stack"]["needs"], "changes")
        self.assertEqual(" ".join(jobs["dev-stack"]["if"].split()), " || ".join(
            f"needs.changes.outputs.{name} == 'true'" for name in ("server", "web", "infrastructure", "devstack")
        ))
        self.assertEqual(set(jobs["publish-images"]["needs"]), {"verification", "dev-stack"})

    def test_linux_workflow_installs_the_execution_verifier_runtime(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/swift-package.yml").read_text())
        for name in ("test", "postgres"):
            with self.subTest(job=name):
                commands = "\n".join(step.get("run", "") for step in workflow["jobs"][name]["steps"])
                installs = [line for line in commands.splitlines() if "apt-get install" in line]
                self.assertEqual(len(installs), 1)
                self.assertIn("python3", installs[0].split())
                self.assertIn("libsqlite3-dev", installs[0].split())

    def test_real_store_lane_requires_full_validator_execution_and_isolation(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/swift-package.yml").read_text())
        steps = workflow["jobs"]["postgres"]["steps"]
        commands = "\n".join(step.get("run", "") for step in steps)
        for required in ("--include-lifecycle-corpus", "--env TROVE_REQUIRE_FULL_VALIDATOR=1",
                         "--env TROVE_TEST_VALIDATOR_ASSETS=", "--env TROVE_TEST_LIFECYCLE_CORPUS=",
                         "--env FHIR_VALIDATOR_URL=", "--env FHIR_VALIDATOR_IDENTITY",
                         "docker network create --internal", "--publish 127.0.0.1:18080:8080",
                         "--read-only", "--cap-drop ALL", "--security-opt no-new-privileges"):
            self.assertIn(required, commands)
        cleanup = steps[-1]
        self.assertEqual(cleanup["if"], "always()")
        self.assertIn('"$VALIDATOR_CONTAINER"', cleanup["run"])
        self.assertIn('docker network rm "$VALIDATOR_NETWORK"', cleanup["run"])

    def test_ruleset_requires_the_aggregate_not_conditionally_skipped_components(self) -> None:
        ruleset = json.loads((ROOT / ".github/rulesets/main.json").read_text())
        rule = next(rule for rule in ruleset["rules"] if rule["type"] == "required_status_checks")
        contexts = {check["context"] for check in rule["parameters"]["required_status_checks"]}
        workflow = yaml.safe_load((ROOT / ".github/workflows/build-and-test.yml").read_text())
        self.assertIn(workflow["jobs"]["verification"]["name"], contexts)
        self.assertFalse(contexts.intersection({"API / Swift Test", "Server / Swift Test", "Web / Lint & Build"}))
        self.assertTrue(rule["parameters"]["strict_required_status_checks_policy"])
        self.assertEqual(ruleset["bypass_actors"], [])

    def test_public_repository_scanning_is_unconditional_and_required(self) -> None:
        ruleset = json.loads((ROOT / ".github/rulesets/main.json").read_text())
        rules = {rule["type"]: rule for rule in ruleset["rules"]}
        contexts = {check["context"] for check in rules["required_status_checks"]["parameters"]["required_status_checks"]}
        self.assertIn("required_signatures", rules)
        self.assertIn("required_linear_history", rules)
        for filename, job_id in (("codeql.yml", "analyze"), ("static-analysis.yml", "codeql")):
            workflow = yaml.safe_load((ROOT / ".github/workflows" / filename).read_text())
            # PyYAML's YAML 1.1 reader interprets the unquoted workflow key 'on' as True.
            self.assertIsNone(workflow[True]["pull_request"])
            job = workflow["jobs"][job_id]
            self.assertNotIn("if", job)
            self.assertNotIn("needs", job)
            if job_id == "codeql":
                self.assertEqual(json.loads(job["with"]["runsonlabels"]), ["macos-26"])
                self.assertEqual(job["with"]["xcodeversion"], "26.6")
                self.assertTrue(job["with"]["codeql"])
                self.assertEqual(job["with"]["destination"], "generic/platform=iOS Simulator")
                self.assertIn(f'{job["name"]} / {job["with"]["job_name"]}', contexts)
            else:
                self.assertIn(job["name"], contexts)

    def test_fork_runner_routing_and_simulator_runtime_are_explicit(self) -> None:
        jobs = yaml.safe_load((ROOT / ".github/workflows/build-and-test.yml").read_text())["jobs"]
        self.assertEqual(jobs["ios"]["with"]["destination"],
                         "platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0")
        ui_test = next(step["run"] for step in jobs["ios-ui"]["steps"]
                       if step.get("name") == "Run the real-stack UI test")
        prepare = next(step["run"] for step in jobs["ios-ui"]["steps"]
                       if step.get("id") == "simulator")
        self.assertIn("com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", prepare)
        self.assertIn("com.apple.CoreSimulator.SimRuntime.iOS-27-0", prepare)
        self.assertIn('platform=iOS Simulator,id=$TROVE_UI_SIMULATOR', ui_test)
        self.assertNotIn("--show-sdk-version", ui_test)
        for runner in (jobs["ios"]["with"]["runsonlabels"], jobs["ios-ui"]["runs-on"],
                       jobs["native-line-coverage"]["runs-on"], jobs["coverage"]["with"]["runs_on_labels"]):
            self.assertIn("github.event.pull_request.head.repo.full_name != github.repository", runner)
            self.assertIn("'[\"xcode-27\"]' || '[\"self-hosted\", \"macOS\"]'", runner)


if __name__ == "__main__":
    unittest.main()
