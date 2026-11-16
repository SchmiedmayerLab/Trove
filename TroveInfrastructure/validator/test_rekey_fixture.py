"""Recovered fixture identities must never fall back to the public synthetic key."""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import base64
import copy
import json
from pathlib import Path
import subprocess
import sys
import unittest

from rekey_fixture import recovered_arguments


def recovery_fixture():
    return {"registration": {"source": {
        "keyID": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "keyEpoch": "7",
        "identifierRoot": "https://fixture.test/source",
        "participantIdentifier": {"system": "https://fixture.test/participants", "value": "participant"},
        "repositoryScope": {"system": "https://fixture.test/source/repository", "value": "healthkit"},
    }}, "identityKeyBase64": base64.b64encode(bytes(reversed(range(32)))).decode()}


class RecoveredFixtureTests(unittest.TestCase):
    def test_recovers_complete_context_including_noninitial_epoch(self):
        arguments = recovered_arguments(recovery_fixture())
        self.assertEqual(arguments["identity_key"], bytes(reversed(range(32))))
        self.assertEqual(arguments["epoch"], "7")
        self.assertEqual(arguments["repository_scope"], ("https://fixture.test/source/repository", "healthkit"))
        self.assertEqual(arguments["registration_id"], "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")

    def test_missing_or_invalid_material_fails_without_echoing_secrets(self):
        recovery = recovery_fixture()
        malformed = [None, [], {}, {"registration": []}]
        for key in ("keyID", "keyEpoch", "identifierRoot", "participantIdentifier", "repositoryScope"):
            changed = copy.deepcopy(recovery)
            del changed["registration"]["source"][key]
            malformed.append(changed)
        for value in (None, "", "secret-invalid-base64", base64.b64encode(bytes(31)).decode(),
                      recovery["identityKeyBase64"] + "\n"):
            malformed.append({**recovery, "identityKeyBase64": value})
        for epoch in (None, 1, True, "0", "01", "-1", "１", "1" * 33):
            changed = copy.deepcopy(recovery)
            changed["registration"]["source"]["keyEpoch"] = epoch
            malformed.append(changed)
        for index, value in enumerate(malformed):
            with self.subTest(case=index), self.assertRaisesRegex(ValueError, "^Invalid recovered fixture identity$"):
                recovered_arguments(value)

    def test_cli_rejects_malformed_oversized_or_overridden_recovery_without_output(self):
        command = [sys.executable, str(Path(__file__).with_name("rekey_fixture.py")),
                   "--assets", "/unused", "--fixture", "/unused", "--recovered-identity-stdin",
                   "--effective-at", "2026-11-13T00:00:00Z", "--native-record-id", "synthetic-record"]
        secret = recovery_fixture()["identityKeyBase64"]
        cases = [(b"not-json-" + secret.encode(), []), (b" " * 16_385, []),
                 (json.dumps(recovery_fixture()).encode(), ["--identifier-root", "https://override.test"]),
                 (json.dumps(recovery_fixture()).encode(), ["--registration-id", "fallback"])]
        for raw, arguments in cases:
            with self.subTest(arguments=arguments):
                result = subprocess.run(command + arguments, input=raw, capture_output=True, timeout=10, check=False)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, b"")
                self.assertNotIn(secret.encode(), result.stderr)
                self.assertNotIn(b"Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
