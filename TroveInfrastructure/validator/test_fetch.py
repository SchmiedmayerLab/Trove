"""Public artifact fetching preserves the offline validator pins."""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import hashlib
import json
from pathlib import Path
import tempfile
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


if __name__ == "__main__":
    unittest.main()
