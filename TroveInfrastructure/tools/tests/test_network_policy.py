# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("network_policy", Path(__file__).resolve().parents[1] / "verify_network_policy.py")
network_policy = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = network_policy
SPEC.loader.exec_module(network_policy)


class NetworkPolicyVerificationTests(unittest.TestCase):
    def test_cases_have_known_roles_and_both_permission_outcomes(self):
        compile(network_policy.LISTENER, "listener", "exec")
        compile(network_policy.CLIENT, "client", "exec")
        names = {role.name for role in network_policy.ROLES}
        self.assertEqual(len(names), len(network_policy.ROLES))
        cases = network_policy.CASES
        self.assertTrue(all(case.source in names and case.target in names for case in cases))
        self.assertEqual({case.allowed for case in cases}, {False, True})
        self.assertEqual(len({(case.source, case.target, case.port) for case in cases}), len(cases))
        self.assertTrue(all(not case.allowed for case in cases if case.source == "outside-gateway"))
        self.assertTrue(any(network_policy.ROLES[0].worker != role.worker for role in network_policy.ROLES))

    def test_rendering_rejects_missing_denies_duplicate_names_and_foreign_namespaces(self):
        policies = [{"kind": "NetworkPolicy", "metadata": {"name": name, "namespace": "trove"}}
                    for name in ("default-deny-ingress", "default-deny-egress")]
        with patch.object(network_policy, "run", return_value="\n---\n".join(json.dumps(item) for item in policies)):
            self.assertEqual(network_policy.rendered_policies(), policies)
        invalid_sets = [policies[:1], policies + policies[:1],
                        [policies[0], {"kind": "NetworkPolicy", "metadata": {
                            "name": "default-deny-egress", "namespace": "other"}}]]
        for documents in invalid_sets:
            with self.subTest(documents=documents), \
                    patch.object(network_policy, "run", return_value="\n---\n".join(json.dumps(item) for item in documents)), \
                    self.assertRaises(ValueError):
                network_policy.rendered_policies()

    def test_partial_cluster_creation_still_cleans_only_the_owned_cluster(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(network_policy, "rendered_policies", return_value=[]), \
                patch.object(network_policy.tempfile, "mkdtemp", return_value=directory), \
                patch.object(network_policy, "run", side_effect=["sha256:synthetic", subprocess.CalledProcessError(1, "kind"), ""]) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                network_policy.exercise("kind", "local-probe")
            create, delete = run.call_args_list[1].args[0], run.call_args_list[2].args[0]
            self.assertEqual(delete[:3], ["kind", "delete", "cluster"])
            self.assertEqual(create[create.index("--name") + 1], delete[delete.index("--name") + 1])
            summary = json.loads((Path(directory) / "summary.json").read_text())
            self.assertFalse(summary["passed"])
            self.assertTrue(summary["cleanupComplete"])

    def test_cleanup_failure_cannot_report_success(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(network_policy, "rendered_policies", return_value=[]), \
                patch.object(network_policy.tempfile, "mkdtemp", return_value=directory), \
                patch.object(network_policy, "run", side_effect=["sha256:synthetic", RuntimeError("create"), RuntimeError("cleanup")]):
            with self.assertRaisesRegex(RuntimeError, "cleanup"):
                network_policy.exercise("kind", "local-probe")
            summary = json.loads((Path(directory) / "summary.json").read_text())
            self.assertFalse(summary["passed"])
            self.assertFalse(summary["cleanupComplete"])
