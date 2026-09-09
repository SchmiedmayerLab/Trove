#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""Secret scan boundaries; real scanner execution is mandatory in the shared secrets command."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import yaml


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("secret_scan", ROOT / "scripts/check-secrets.py")
assert SPEC is not None and SPEC.loader is not None
SCAN = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = SCAN
SPEC.loader.exec_module(SCAN)


class SecretScanTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repository = self.root / "repository"
        self.repository.mkdir()
        subprocess.run(["git", "init", "--quiet", str(self.repository)], check=True, timeout=10)

    def test_publication_includes_new_and_modified_files_but_not_ignored_private_files(self) -> None:
        (self.repository / ".gitignore").write_text(".env\ncache/\n")
        (self.repository / ".env").write_text("not publication data")
        (self.repository / "tracked.swift").write_text("original")
        (self.repository / "removed.swift").write_text("removed")
        subprocess.run(["git", "-C", str(self.repository), "add", "tracked.swift", "removed.swift"], check=True, timeout=10)
        (self.repository / "tracked.swift").write_text("modified")
        (self.repository / "removed.swift").unlink()
        (self.repository / "new file.swift").write_text("new")
        inventory = SCAN.snapshot(self.repository, self.root / "snapshot")
        self.assertEqual([entry.path for entry in inventory], [".gitignore", "new file.swift", "tracked.swift"])
        self.assertEqual((self.root / "snapshot/tracked.swift").read_text(), "modified")
        SCAN.verify_unchanged(self.repository, inventory)

    def test_symlinks_cannot_import_ignored_or_external_data(self) -> None:
        outside = self.root / "outside"
        outside.write_text("unrelated private data")
        (self.repository / "link").symlink_to(outside)
        with self.assertRaises(ValueError):
            SCAN.publication_files(self.repository)

    def test_empty_selection_and_source_changes_cannot_pass(self) -> None:
        with self.assertRaises(ValueError):
            SCAN.publication_files(self.repository)
        source = self.repository / "source.swift"
        source.write_text("before")
        inventory = SCAN.snapshot(self.repository, self.root / "snapshot")
        source.write_text("after")
        with self.assertRaises(ValueError):
            SCAN.verify_unchanged(self.repository, inventory)
        source.write_text("before")
        (self.repository / "new.swift").write_text("new")
        with self.assertRaises(ValueError):
            SCAN.verify_unchanged(self.repository, inventory)

    def report(self, **overrides: object) -> dict[str, object]:
        source = self.repository / "source.swift"
        source.write_text("fixture")
        return {"RuleID": "github-pat", "File": str(source), "StartLine": 1,
                "Secret": "REDACTED", "Match": "must not be retained", **overrides}

    def test_retained_findings_have_locations_but_no_scanned_content(self) -> None:
        report = self.root / "report.json"
        report.write_text(json.dumps([self.report()]))
        values = SCAN.findings(report, self.repository)
        self.assertEqual(values, [SCAN.Finding("github-pat", "source.swift", 1)])
        self.assertNotIn("must not be retained", repr(values))

    def test_missing_malformed_unredacted_and_foreign_reports_fail(self) -> None:
        report = self.root / "report.json"
        with self.assertRaises(FileNotFoundError):
            SCAN.findings(report, self.repository)
        cases = [None, {}, 0, [None], [self.report(Secret="not redacted")],
                 [self.report(File=str(self.root / "outside"))], [self.report(RuleID=None)],
                 [self.report(StartLine=True)], [self.report(StartLine=0)]]
        for value in cases:
            with self.subTest(value=value):
                report.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    SCAN.findings(report, self.repository)

    def test_failure_missing_execution_and_inconsistent_status_never_pass(self) -> None:
        report = self.root / "report.json"
        for code, value, valid in [(0, [], True), (1, [self.report()], True),
                                   (0, [self.report()], False), (1, [], False), (2, [], False)]:
            with self.subTest(code=code, value=value):
                report.write_text(json.dumps(value))
                with patch.object(SCAN.subprocess, "run", return_value=subprocess.CompletedProcess([], code)) as invoked:
                    if valid:
                        result, _ = SCAN.scan("scanner", self.repository, self.root / "config", report, self.root)
                        self.assertEqual(result, code)
                    else:
                        with self.assertRaises(ValueError):
                            SCAN.scan("scanner", self.repository, self.root / "config", report, self.root)
                    arguments = invoked.call_args.args[0]
                    self.assertIn("--redact=100", arguments)
                    self.assertIn("--ignore-gitleaks-allow", arguments)
                    self.assertEqual(invoked.call_args.kwargs["timeout"], 330)

    def test_workflow_pins_download_verifies_digest_and_uses_shared_command(self) -> None:
        workflow = yaml.safe_load((ROOT / ".github/workflows/secret-scan.yml").read_text())
        self.assertEqual(workflow["permissions"], {"contents": "read"})
        job = workflow["jobs"]["scan"]
        self.assertEqual(job["runs-on"], "ubuntu-24.04")
        self.assertFalse(job["steps"][0]["with"]["persist-credentials"])
        installation = job["steps"][1]
        self.assertEqual(str(installation["env"]["GITLEAKS_VERSION"]), SCAN.VERSION)
        self.assertEqual(installation["env"]["GITLEAKS_SHA256"],
                         "551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb")
        self.assertLess(installation["run"].index("sha256sum --check --strict"), installation["run"].index("tar --extract"))
        self.assertIn("bash scripts/check secrets", job["steps"][2]["run"])
        gate = yaml.safe_load((ROOT / ".github/workflows/build-and-test.yml").read_text())["jobs"]
        self.assertIn("secret-scan", gate["verification"]["needs"])
        self.assertNotIn("if", gate["secret-scan"])
        self.assertNotIn("secrets", gate["secret-scan"])


if __name__ == "__main__":
    unittest.main()
