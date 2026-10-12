"""Public artifact fetching preserves the offline validator pins."""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import hashlib
import json
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import patch

import fetch


class FetchTests(unittest.TestCase):
    def test_manifest_urls_preserve_prerelease_versions(self):
        manifest = json.loads((fetch.HERE / "manifest.json").read_bytes())
        urls = {name: url for name, _, url in fetch.artifacts(manifest)}
        self.assertEqual(
            urls["packages/hl7.fhir.uv.extensions.r4-5.3.0-ballot-tc1.tgz"],
            "https://packages.fhir.org/hl7.fhir.uv.extensions.r4/5.3.0-ballot-tc1",
        )
        self.assertEqual(len(urls), 1 + len(manifest["bootstrap"]) + len(manifest["guides"]))

    def test_only_verified_cached_bytes_are_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            cached = output / "validator_cli.jar"
            cached.write_bytes(b"verified")
            checksum = hashlib.sha256(b"verified").hexdigest()
            with patch.object(fetch, "artifacts", return_value=[(cached.name, checksum, "https://example.org/tool")]), \
                    patch.object(fetch.subprocess, "run") as download:
                fetch.fetch({}, output)
                download.assert_not_called()
                cached.write_bytes(b"tampered")
                with self.assertRaisesRegex(ValueError, "Cached artifact checksum mismatch"):
                    fetch.fetch({}, output)
                download.assert_not_called()

    def test_downloaded_bytes_must_match_the_pin(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)

            def download(command, **_):
                Path(command[command.index("--output") + 1]).write_bytes(b"wrong")

            with patch.object(fetch, "artifacts", return_value=[("tool", "0" * 64, "https://example.org/tool")]), \
                    patch.object(fetch.subprocess, "run", side_effect=download):
                with self.assertRaisesRegex(ValueError, "Pinned artifact checksum mismatch"):
                    fetch.fetch({}, output)
            self.assertEqual(list(output.iterdir()), [])

    def test_failed_transfer_does_not_poison_the_next_attempt(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            checksum = hashlib.sha256(b"verified").hexdigest()

            def interrupted(command, **_):
                Path(command[command.index("--output") + 1]).write_bytes(b"partial")
                raise subprocess.CalledProcessError(7, command)

            def downloaded(command, **kwargs):
                self.assertIn("--retry-all-errors", command)
                self.assertEqual(command[command.index("--retry") + 1], "3")
                self.assertEqual(command[command.index("--retry-max-time") + 1], "600")
                self.assertEqual(kwargs["timeout"], 930)
                Path(command[command.index("--output") + 1]).write_bytes(b"verified")

            with patch.object(fetch, "artifacts", return_value=[("tool", checksum, "https://example.org/tool")]):
                with patch.object(fetch.subprocess, "run", side_effect=interrupted):
                    with self.assertRaises(subprocess.CalledProcessError):
                        fetch.fetch({}, output)
                self.assertEqual(list(output.iterdir()), [])
                with patch.object(fetch.subprocess, "run", side_effect=downloaded):
                    fetch.fetch({}, output)
                self.assertEqual((output / "tool").read_bytes(), b"verified")
                self.assertEqual(list(output.iterdir()), [output / "tool"])


if __name__ == "__main__":
    unittest.main()
