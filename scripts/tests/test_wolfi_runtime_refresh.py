# This source file is part of the Trove open-source project
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

"""Wolfi runtime refresh: version selection and pin rewriting."""

import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("refresh", ROOT / "scripts/refresh-wolfi-runtime.py")
assert SPEC is not None and SPEC.loader is not None
REFRESH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REFRESH)
DIGEST = "sha256:" + "a" * 64


class WolfiRuntimeRefreshTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        for path in (REFRESH.SERVER, REFRESH.RUNTIME, REFRESH.MANIFEST):
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT / path, self.root / path)
        self.names = list(REFRESH.pins((ROOT / REFRESH.RUNTIME).read_text()))

    def test_policy_output_lists_versions_oldest_first(self):
        output = "python-3.15 policy:\n  3.15.2_git20261113-r0:\n    https://apk.cgr.dev/chainguard\n" \
                 "  3.15.2_git20261120-r0:\n    https://apk.cgr.dev/chainguard\n"
        self.assertEqual(REFRESH.parse_policy(output),
                         {"python-3.15": ["3.15.2_git20261113-r0", "3.15.2_git20261120-r0"]})

    def test_newest_version_must_exist_on_every_architecture(self):
        amd64 = {"tool": ["1-r0", "1-r1", "2-r0"]}
        arm64 = {"tool": ["1-r0", "1-r1"]}
        self.assertEqual(REFRESH.newest_common("tool", "1-r0", [amd64, arm64]), "1-r1")
        with self.assertRaises(ValueError):
            REFRESH.newest_common("tool", "1-r0", [amd64, {"tool": []}])

    def test_a_current_pin_that_is_missing_or_newer_fails(self):
        versions = [{"tool": ["1-r0", "1-r1"]}]
        with self.assertRaises(ValueError):
            REFRESH.newest_common("tool", "0-r9", versions)
        with self.assertRaises(ValueError):
            REFRESH.newest_common("tool", "1-r1", [{"tool": ["1-r0", "1-r1"]}, {"tool": ["1-r0"]}])

    def test_refresh_keeps_the_dockerfiles_and_manifest_identical(self):
        current = REFRESH.pins((ROOT / REFRESH.RUNTIME).read_text())
        versions = {name: [current[name], f"9-{name}-r1"] for name in self.names}
        changes = REFRESH.refresh(self.root, DIGEST, [versions, versions])
        self.assertEqual({subject for subject, _, _ in changes}, {f"wolfi-base in {REFRESH.SERVER}", f"wolfi-base in {REFRESH.RUNTIME}", *self.names})
        runtime = (self.root / REFRESH.RUNTIME).read_text()
        manifest = json.loads((self.root / REFRESH.MANIFEST).read_text())["runtimeImages"]
        self.assertEqual(manifest["base"], f"{REFRESH.BASE}@{DIGEST}")
        self.assertIn(f"FROM {manifest['base']}", runtime)
        self.assertIn(f"FROM {manifest['base']}", (self.root / REFRESH.SERVER).read_text())
        self.assertEqual(manifest["packages"], [f"{name}=9-{name}-r1" for name in self.names])
        self.assertEqual(REFRESH.pins(runtime), {name: f"9-{name}-r1" for name in self.names})

    def test_refresh_without_newer_versions_changes_nothing(self):
        runtime = (self.root / REFRESH.RUNTIME).read_text()
        current = REFRESH.BASE_PATTERN.search(runtime).group(0)
        server = self.root / REFRESH.SERVER
        server.write_text(REFRESH.BASE_PATTERN.sub(current, server.read_text()))
        current = current.split("@")[1]
        before = {path: (self.root / path).read_text() for path in (REFRESH.SERVER, REFRESH.RUNTIME, REFRESH.MANIFEST)}
        versions = {name: [version] for name, version in REFRESH.pins(before[REFRESH.RUNTIME]).items()}
        self.assertEqual(REFRESH.refresh(self.root, current, [versions]), [])
        self.assertEqual(before, {path: (self.root / path).read_text() for path in before})

    def test_refresh_rejects_a_malformed_digest(self):
        with self.assertRaises(ValueError):
            REFRESH.refresh(self.root, "latest", [{}])


if __name__ == "__main__":
    unittest.main()
