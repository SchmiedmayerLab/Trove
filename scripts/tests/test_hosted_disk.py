# This source file is part of the Trove open-source project
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import os
from pathlib import Path
import subprocess
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "prepare-hosted-disk.sh"


class HostedDiskTests(unittest.TestCase):
    def run_preparation(self, *, actions="true", environment="github-hosted", platform="Linux", available="31457280"):
        # Never invoke real removal, even when these directories exist locally.
        command = """
sudo() {
    case "$*" in
        'rm -rf -- /usr/local/lib/android'|'rm -rf -- /usr/share/dotnet'|\
'rm -rf -- /opt/ghc'|'rm -rf -- /opt/hostedtoolcache/CodeQL') return 0 ;;
        *) echo 'Unexpected cleanup target' >&2; return 99 ;;
    esac
}
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\\nsynthetic 99999999 0 %s 0%% /\\n' "$TEST_AVAILABLE"; }
source "$1"
"""
        return subprocess.run(
            ["bash", "-c", command, "test", str(SCRIPT)], capture_output=True, text=True,
            env={**os.environ, "GITHUB_ACTIONS": actions, "RUNNER_ENVIRONMENT": environment,
                 "RUNNER_OS": platform, "TEST_AVAILABLE": available},
        )

    def test_requires_ephemeral_linux_runner(self):
        for overrides in ({"actions": "false"}, {"environment": "self-hosted"}, {"platform": "macOS"}):
            with self.subTest(overrides=overrides):
                result = self.run_preparation(**overrides)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("requires an ephemeral", result.stderr)

    def test_requires_disk_budget_after_cleanup(self):
        for available in ("31457279", "0", "unknown"):
            with self.subTest(available=available):
                result = self.run_preparation(available=available)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("at least 30 GiB", result.stderr)

    def test_accepts_disk_budget(self):
        result = self.run_preparation()
        self.assertEqual(result.returncode, 0, result.stderr)
