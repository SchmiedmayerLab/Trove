# This source file is part of the Trove open-source project
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

"""Exercise the native evidence verifier's actual jq predicates, without network access."""

import copy
import json
from pathlib import Path
import re
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "TroveiOS/scripts/verify-ui-test-consent.sh"


class ConsentVerifierTests(unittest.TestCase):
    def check_filter(self, predicate, value, accepted):
        result = subprocess.run(
            ["jq", "--exit-status", "--arg", "enrollment", "enrollment", predicate],
            input=json.dumps(value), capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode == 0, accepted, result.stderr)

    def test_requires_both_distinct_exact_revision_receipts(self):
        match = re.search(r"jq --exit-status --arg enrollment.*? '(.*?)' <<< \"\$receipts\"", SCRIPT.read_text(), re.S)
        self.assertIsNotNone(match)
        receipts = [{
            "id": f"receipt-{revision}", "enrollmentId": "enrollment", "revision": revision,
            "acceptedEnrollmentVersion": revision + 1,
            "presentation": {"locale": "en-US", "digest": str(revision) * 64},
            "userResponses": {
                "toggles": {"agree": True},
                "signatures": {"participant": {
                    "name": {"givenName": "Alice", "familyName": "Participant"},
                    "signature": "synthetic", "size": [320, 100],
                }},
            },
        } for revision in (1, 2)]
        self.check_filter(match[1], receipts, True)
        self.check_filter(match[1], list(reversed(receipts)), True)
        self.check_filter(match[1], receipts[:1], False)
        for path, value in (
            (("id",), "receipt-1"), (("revision",), 1), (("acceptedEnrollmentVersion",), 2),
            (("enrollmentId",), "foreign"), (("presentation", "digest"), "1" * 64),
            (("presentation", "locale"), "de-DE"), (("userResponses", "toggles", "agree"), False),
            (("userResponses", "signatures", "participant", "signature"), ""),
        ):
            with self.subTest(path=path):
                changed = copy.deepcopy(receipts)
                target = changed[1]
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
                self.check_filter(match[1], changed, False)

    def test_requires_withdrawal_after_exact_adoption(self):
        match = re.search(r"jq --exit-status '(select\(length == 1\).*?)'\)", SCRIPT.read_text(), re.S)
        self.assertIsNotNone(match)
        enrollment = {"withdrawnAt": "2026-09-06T12:00:00Z", "currentRevision": 2, "stateVersion": 4}
        self.check_filter(match[1], [enrollment], True)
        self.check_filter(match[1], [], False)
        self.check_filter(match[1], [enrollment, enrollment], False)
        for field, value in (("withdrawnAt", None), ("currentRevision", 1), ("stateVersion", 3)):
            with self.subTest(field=field):
                self.check_filter(match[1], [{**enrollment, field: value}], False)

    def test_pdf_comparison_errors_cannot_pass_as_distinct_documents(self):
        source = SCRIPT.read_text()
        block = source[source.index("if cmp -s "):]
        for comparison_status, expected in ((0, 1), (1, 0), (2, 2)):
            with self.subTest(comparison_status=comparison_status):
                result = subprocess.run(
                    ["bash", "-c", f"set -eu\nresult_dir=/unused\ncmp() {{ return {comparison_status}; }}\n{block}"],
                    capture_output=True, text=True, check=False,
                )
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual("Verified two" in result.stdout, comparison_status == 1)
