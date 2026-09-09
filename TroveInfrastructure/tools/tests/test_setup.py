# This source file is part of the Trove open-source project
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import argparse
from contextlib import ExitStack, redirect_stderr, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("trove_setup", Path(__file__).resolve().parents[1] / "setup.py")
setup = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(setup)
REVISION = "0123456789abcdef0123456789abcdef01234567"


class SetupRevisionTests(unittest.TestCase):
    def test_repository_token_is_only_in_stdin_not_commands_or_diagnostics(self):
        token = "synthetic-repository-token"
        output = io.StringIO()
        with patch.dict(setup.os.environ, {"REPOSITORY_TOKEN": token}), \
                patch.object(setup.subprocess, "run") as run, redirect_stdout(output):
            setup.step_configure_repository()
        command = run.call_args.args[0]
        self.assertNotIn(token, " ".join(command))
        self.assertNotIn(token, output.getvalue())
        self.assertIn("--server-side", command)
        manifest = json.loads(run.call_args.kwargs["input"])
        self.assertEqual(manifest["stringData"]["password"], token)
        self.assertEqual(manifest["metadata"]["labels"]["argocd.argoproj.io/secret-type"], "repository")

    def test_revision_accepts_only_a_full_commit(self):
        self.assertEqual(setup.commit_revision(REVISION.upper()), REVISION)
        for value in ("main", "a" * 39, "a" * 41, "g" * 40, "--help"):
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                setup.commit_revision(value)

    def test_wait_does_not_accept_health_from_the_previous_revision(self):
        def status(revision):
            return subprocess.CompletedProcess([], 0, json.dumps({"status": {
                "health": {"status": "Healthy"},
                "sync": {"status": "Synced", "comparedTo": {"source": {"targetRevision": revision}}},
            }}))
        with patch.object(setup.subprocess, "run", side_effect=[status("previous"), status(REVISION)]) as run, \
                patch.object(setup.time, "sleep") as sleep, redirect_stdout(io.StringIO()):
            setup.wait_for_application("root-dev", REVISION)
        self.assertEqual(run.call_count, 2)
        sleep.assert_called_once_with(15)

    def test_checkout_must_match_revision(self):
        with patch.object(setup.subprocess, "run") as run:
            run.return_value.stdout = "f" * 40
            with self.assertRaisesRegex(ValueError, "does not match"):
                setup.verify_checkout_revision(REVISION)
            self.assertEqual(run.call_count, 1)

    def test_uncommitted_source_cannot_be_described_as_a_remote_revision(self):
        with patch.object(setup.subprocess, "run") as run:
            run.side_effect = [
                subprocess.CompletedProcess([], 0, REVISION + "\n"),
                subprocess.CompletedProcess([], 0, " M apps/base/server/configmap.yaml\n"),
            ]
            with self.assertRaisesRegex(ValueError, "clean checkout"):
                setup.verify_checkout_revision(REVISION)

    def test_ci_revision_is_used_without_selecting_a_moving_branch(self):
        with ExitStack() as stack:
            stack.enter_context(redirect_stdout(io.StringIO()))
            stack.enter_context(patch.object(setup.sys, "argv", ["setup.py", "--revision", REVISION]))
            verify = stack.enter_context(patch.object(setup, "verify_checkout_revision"))
            branch = stack.enter_context(patch.object(setup, "get_current_branch"))
            remote = stack.enter_context(patch.object(setup, "branch_exists_on_remote"))
            stack.enter_context(patch.object(setup, "step_install_argocd"))
            stack.enter_context(patch.object(setup, "step_configure_repository"))
            apply = stack.enter_context(patch.object(setup, "step_apply_root_application"))
            setup.main()
        verify.assert_called_once_with(REVISION)
        branch.assert_not_called()
        remote.assert_not_called()
        apply.assert_called_once_with("dev", REVISION)

    def test_root_and_child_sources_share_the_exact_revision(self):
        with patch.object(setup, "kubectl") as kubectl, \
                patch.object(setup, "kind_api_cidr", return_value="172.19.0.2/32"), \
                patch.object(setup, "wait_for_application"), redirect_stdout(io.StringIO()):
            setup.step_apply_root_application("dev", REVISION)
        manifest = kubectl.call_args.kwargs["input"]
        self.assertNotIn(setup.TARGET_REVISION_PLACEHOLDER, manifest)
        self.assertEqual(manifest.count(f'"{REVISION}"'), 3)
        self.assertIn("/spec/source/targetRevision", manifest)
        self.assertIn("/spec/sources/1/targetRevision", manifest)
        self.assertNotIn(setup.KIND_API_CIDR_PLACEHOLDER, manifest)
        self.assertEqual(manifest.count('"172.19.0.2/32"'), 2)

    def test_kind_api_egress_uses_exact_ready_endpoint_and_rejects_ambiguous_addresses(self):
        endpoint_slice = {
            "addressType": "IPv4",
            "ports": [{"name": "https", "port": 6443, "protocol": "TCP"}],
            "endpoints": [{"conditions": {"ready": True}, "addresses": ["172.19.0.2"]}],
        }
        def discover(items):
            with patch.object(setup, "kubectl", return_value=subprocess.CompletedProcess(
                [], 0, json.dumps({"items": items})
            )):
                return setup.kind_api_cidr()
        self.assertEqual(discover([endpoint_slice]), "172.19.0.2/32")
        invalid = [[], [{**endpoint_slice, "ports": [{"port": 443}]}],
                   [{**endpoint_slice, "addressType": "IPv6"}],
                   [{**endpoint_slice, "endpoints": [{"conditions": {"ready": False}, "addresses": ["172.19.0.2"]}]}],
                   [{**endpoint_slice, "endpoints": [{"conditions": {"ready": True}, "addresses": ["172.19.0.2", "172.19.0.3"]}]}]]
        for items in invalid:
            with self.subTest(items=items), self.assertRaises(ValueError):
                discover(items)

    def test_production_does_not_accept_a_development_revision_override(self):
        with patch.object(setup.sys, "argv", ["setup.py", "--env", "prod", "--revision", REVISION]), \
                patch.object(setup, "step_install_argocd") as install, redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as error:
                setup.main()
        self.assertEqual(error.exception.code, 2)
        install.assert_not_called()
