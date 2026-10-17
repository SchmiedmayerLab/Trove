#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""Check the workflow's path ownership without another selection configuration."""

from pathlib import Path
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
SELECTORS = {"api", "server", "web", "ios", "ios_ui", "infrastructure", "devstack"}


class CIPathTests(unittest.TestCase):
    def test_validator_cache_is_verified_before_image_builds(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/dev-stack.yml").read_text())
        steps = workflow["jobs"]["smoke-test"]["steps"]
        cache = next(step for step in steps if step.get("name") == "Restore pinned public validator artifacts")
        self.assertIn("hashFiles('TroveInfrastructure/validator/manifest.json')", cache["with"]["key"])
        fetch = next(step for step in steps if step.get("name") == "Fetch and verify pinned validator artifacts")
        self.assertNotIn("if", fetch)
        self.assertIn("validator/fetch.py", fetch["run"])
        build = next(step for step in steps if step.get("name") == "Build the server and web images")
        self.assertLess(steps.index(fetch), steps.index(build))

    def test_ui_test_owns_its_simulator_and_retains_raw_logs(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/build-and-test.yml").read_text())
        steps = workflow["jobs"]["ios-ui"]["steps"]
        prepare = next(step for step in steps if step.get("id") == "simulator")
        self.assertEqual(prepare["timeout-minutes"], 5)
        self.assertIn("xcrun simctl create", prepare["run"])
        self.assertLess(prepare["run"].index('echo "udid='), prepare["run"].index("xcrun simctl boot"))
        self.assertIn('xcrun simctl bootstatus "$udid" -b', prepare["run"])
        test = next(step for step in steps if step.get("name") == "Run the real-stack UI test")
        self.assertEqual(test["env"]["TROVE_UI_SIMULATOR"], "${{ steps.simulator.outputs.udid }}")
        self.assertIn('-destination "platform=iOS Simulator,id=$TROVE_UI_SIMULATOR"', test["run"])
        self.assertIn('tee "$RUNNER_TEMP/trove-ui-xcodebuild.log" | xcbeautify', test["run"])
        cleanup = next(step for step in steps if step.get("name") == "Remove the job's UI-test simulator")
        self.assertEqual(cleanup["if"], "always() && steps.simulator.outputs.udid != ''")
        self.assertIn('xcrun simctl delete "$TROVE_UI_SIMULATOR"', cleanup["run"])
        self.assertNotIn("delete all", cleanup["run"])

    def test_ui_checks_queue_without_replacing_other_pull_requests(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/build-and-test.yml").read_text())
        self.assertEqual(workflow["jobs"]["ios-ui"]["concurrency"], {
            "group": "trove-ios-real-stack", "queue": "max"
        })
        configuration = yaml.safe_load((ROOT / ".github/actionlint.yaml").read_text())
        self.assertEqual(configuration, {"paths": {".github/workflows/build-and-test.yml": {
            "ignore": ['^unexpected key "queue" for "concurrency" section\\.']
        }}})

    def test_weekly_and_manual_runs_bypass_path_selection_without_publishing(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/build-and-test.yml").read_text())
        # PyYAML's YAML 1.1 loader reads the unquoted workflow key `on` as True.
        triggers = workflow[True]
        self.assertEqual(triggers["schedule"], [{"cron": "17 6 * * 0"}])
        self.assertIn("workflow_dispatch", triggers)
        changes = workflow["jobs"]["changes"]
        for name in SELECTORS:
            self.assertEqual(changes["outputs"][name], "${{ github.event_name == 'schedule' || "
                             "github.event_name == 'workflow_dispatch' || steps.filter.outputs." + name + " }}")
        step = next(step for step in changes["steps"] if step.get("id") == "filter")
        self.assertEqual(step["if"], "github.event_name != 'schedule' && github.event_name != 'workflow_dispatch'")
        self.assertEqual(workflow["jobs"]["publish-images"]["if"],
                         "github.event_name == 'push' && github.ref == 'refs/heads/main'")

    def setUp(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/build-and-test.yml").read_text())
        steps = workflow["jobs"]["changes"]["steps"]
        filters = [step for step in steps if step.get("id") == "filter"]
        self.assertEqual(len(filters), 1)
        self.assertEqual(filters[0]["uses"], "dorny/paths-filter@v4")
        self.filters = yaml.safe_load(filters[0]["with"]["filters"])
        self.assertEqual(set(self.filters), SELECTORS)
        # The current rules use only exact paths and directory/**. Reject richer
        # patterns rather than pretending this small ownership check models them.
        for patterns in self.filters.values():
            self.assertIsInstance(patterns, list)
            for pattern in patterns:
                self.assertIsInstance(pattern, str)
                literal = pattern.removesuffix("/**")
                self.assertTrue(literal)
                self.assertFalse(any(character in literal for character in "*?[]{}!()\\"), pattern)

    def selected(self, path: str) -> set[str]:
        return {
            name for name, patterns in self.filters.items()
            if any(path.startswith(pattern[:-2]) if pattern.endswith("/**") else path == pattern
                   for pattern in patterns)
        }

    def test_component_sources_and_shared_api_select_their_consumers(self) -> None:
        cases = {
            "TroveAPI/openapi.yaml": {"api", "server", "web", "ios", "ios_ui"},
            "TroveAPI/Package.resolved": {"api", "server", "ios", "ios_ui"},
            "TroveServer/Sources/NewEndpoint.swift": {"server", "ios_ui"},
            "TroveServer/Tests/NewTests.swift": {"server", "ios_ui"},
            "TroveWeb/src/NewView.tsx": {"web"},
            "TroveWeb/package-lock.json": {"web"},
            "TroveiOS/Trove/NewModel.swift": {"ios", "ios_ui"},
            "TroveiOS/TroveTests/NewTests.swift": {"ios", "ios_ui"},
            "TroveInfrastructure/docker/keycloak/realm.json": {"infrastructure", "ios_ui"},
            "TroveInfrastructure/apps/base/server/deployment.yaml": {"infrastructure"},
            "TroveInfrastructure/validator/worker.py": {"server", "infrastructure"},
            "TroveInfrastructure/validator/lifecycle-corpus.json": {"server", "infrastructure"},
            "TroveInfrastructure/validator/manifest.json": {"server", "infrastructure", "ios_ui"},
        }
        for path, expected in cases.items():
            with self.subTest(path=path):
                self.assertEqual(self.selected(path), expected)

    def test_root_docker_context_selects_both_image_consumers(self) -> None:
        self.assertEqual(self.selected(".dockerignore"), {"server", "web"})

    def test_image_scanner_setup_selects_both_image_verification_jobs(self) -> None:
        self.assertEqual(self.selected(".github/actions/setup-trivy/action.yml"), {"web", "devstack"})

    def test_web_image_verifier_and_its_environment_select_web(self) -> None:
        for path in ("TroveInfrastructure/tools/verify_web_image.py",
                     "TroveInfrastructure/tools/requirements.txt"):
            with self.subTest(path=path):
                self.assertEqual(self.selected(path), {"web", "infrastructure"})

    def test_each_reusable_workflow_selects_its_owner(self) -> None:
        cases = {
            "swift-package": {"api", "server"},
            "web": {"web"},
            "infrastructure": {"infrastructure"},
            "dev-stack": {"devstack"},
            "publish-images": {"devstack"},
            "build-and-test": SELECTORS - {"devstack"},
        }
        for workflow, expected in cases.items():
            with self.subTest(workflow=workflow):
                self.assertEqual(self.selected(f".github/workflows/{workflow}.yml"), expected)

    def test_unrelated_docs_and_similarly_named_directories_do_not_expand_builds(self) -> None:
        for path in ("docs/Architecture.md", "README.md", "TroveAPI-notes/example.swift",
                     "archive/TroveServer/example.swift", "notes/.dockerignore"):
            with self.subTest(path=path):
                self.assertEqual(self.selected(path), set())


if __name__ == "__main__":
    unittest.main()
