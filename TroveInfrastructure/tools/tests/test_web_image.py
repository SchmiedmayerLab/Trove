# This source file is part of the Trove open-source project
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

from email.message import Message
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import call, patch


SPEC = importlib.util.spec_from_file_location("web_image", Path(__file__).resolve().parents[1] / "verify_web_image.py")
web_image = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(web_image)


class WebImageVerificationTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        with patch.object(web_image, "command", return_value='[{"Id":"synthetic-image"}]'):
            self.verification = web_image.Verification("synthetic-image", root, web_image.Certificates(root))
        self.verification.containers = [("first", "owned-first"), ("second", "owned-second")]
        self.verification.network = True

    def test_cleanup_removes_every_owned_resource_even_when_log_retrieval_fails(self):
        with patch.object(web_image.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "docker logs")), \
                patch.object(web_image, "command") as command:
            with self.assertRaisesRegex(RuntimeError, "log retrieval failed"):
                self.verification.cleanup()
        self.assertEqual(command.call_args_list, [
            call("docker", "rm", "--force", "--volumes", "owned-second"),
            call("docker", "rm", "--force", "--volumes", "owned-first"),
            call("docker", "network", "rm", self.verification.name),
        ])
        self.assertTrue(self.verification.results["cleanupComplete"])
        self.assertFalse(self.verification.results["logPrivacyPassed"])

    def test_removal_failure_does_not_skip_other_cleanup_or_claim_success(self):
        with patch.object(web_image.subprocess, "run", return_value=SimpleNamespace(stdout="", stderr="")), \
                patch.object(web_image, "command", side_effect=[RuntimeError("synthetic failure"), "", ""]) as command:
            with self.assertRaisesRegex(RuntimeError, "removal failed"):
                self.verification.cleanup()
        self.assertEqual(command.call_count, 3)
        self.assertFalse(self.verification.results["cleanupComplete"])

    def test_missing_asset_must_be_404_and_cache_headers_are_combined(self):
        index = b'<script src="/assets/app.js"></script>'
        html = (200, {"Cache-Control": "no-store"}, index)
        asset_headers = Message()
        asset_headers.add_header("Cache-Control", "max-age=31536000")
        asset_headers.add_header("Cache-Control", "public, immutable")
        responses = [html, html, html, (200, {"Cache-Control": "no-store"}, b"runtime settings"),
                     (200, asset_headers, b"application script"), html]
        decoded = SimpleNamespace(stdout=json.dumps(web_image.SETTINGS).encode())
        with patch.object(self.verification, "fetch", side_effect=responses), \
                patch.object(web_image.subprocess, "run", return_value=decoded):
            with self.assertRaisesRegex(RuntimeError, "Missing asset unexpectedly"):
                self.verification.check_content(8080, secure=True)
