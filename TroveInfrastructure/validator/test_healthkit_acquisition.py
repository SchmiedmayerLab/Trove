"""Negative controls for the real HealthKit acquisition verifier."""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import copy
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

from verify_healthkit_acquisition import (
    AcquisitionCheckpoint, CustodyCounts, PROFILE, require_heart_rate_sample, require_ui_success, simulator_identifier,
)
from verify_process_restart import Checkpoint


class HealthKitAcquisitionTests(unittest.TestCase):
    def test_simulator_identifier_uses_xcode_destination_spelling(self):
        expected = "1DF41FC2-4972-4C8B-BA34-C68528C37DEB"
        for value in (expected, expected.lower(), expected + "\n"):
            with self.subTest(value=value):
                self.assertEqual(simulator_identifier(value), expected)
        for value in ("", "iPhone 17 Pro", expected + "extra"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                simulator_identifier(value)

    def test_simulator_deletion_is_attempted_even_if_shutdown_times_out(self):
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = object.__new__(AcquisitionCheckpoint)
            checkpoint.evidence = Path(directory)
            checkpoint.summary = {"passed": True}
            checkpoint.simulator = "00000000-0000-4000-8000-000000000001"
            checkpoint.run = Mock()
            with patch("verify_healthkit_acquisition.subprocess.run", side_effect=subprocess.TimeoutExpired("shutdown", 60)), \
                    patch.object(Checkpoint, "cleanup") as inherited:
                checkpoint.cleanup()
            checkpoint.run.assert_called_once_with(["xcrun", "simctl", "delete", checkpoint.simulator])
            inherited.assert_called_once()
            self.assertTrue(checkpoint.summary["simulatorRemoved"])

    def test_failed_simulator_cleanup_cannot_report_complete_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            checkpoint = object.__new__(AcquisitionCheckpoint)
            checkpoint.evidence = Path(directory)
            checkpoint.summary = {"passed": True}
            checkpoint.simulator = "00000000-0000-4000-8000-000000000001"
            checkpoint.run = Mock(side_effect=RuntimeError("delete failed"))
            with patch("verify_healthkit_acquisition.subprocess.run"), \
                    patch.object(Checkpoint, "cleanup", side_effect=lambda: checkpoint.summary.update(cleanupComplete=True)) as inherited, \
                    self.assertRaises(RuntimeError):
                checkpoint.cleanup()
            inherited.assert_called_once()
            result = json.loads((checkpoint.evidence / "summary.json").read_text())
            self.assertFalse(result["passed"])
            self.assertFalse(result["cleanupComplete"])
            self.assertFalse(result["simulatorRemoved"])

    def test_count_row_requires_six_unsigned_ascii_integers(self):
        self.assertEqual(CustodyCounts.parse("1|1|2|1|1|2"), CustodyCounts(1, 1, 2, 1, 1, 2))
        for row in ("", "1|1|2", "1|1|2|1|1|2|0", "1|1|2|1|1|-2", "1|1|2|1|1|2.0", "1|1|2|1|1|２"):
            with self.subTest(row=row), self.assertRaises(ValueError):
                CustodyCounts.parse(row)

    def test_ui_summary_requires_one_pass_and_no_skips(self):
        valid = dict(result="Passed", totalTestCount=1, passedTests=1, failedTests=0, skippedTests=0, expectedFailures=0)
        require_ui_success(valid)
        for field in valid:
            missing = dict(valid)
            del missing[field]
            with self.subTest(missing=field), self.assertRaises(ValueError):
                require_ui_success(missing)
        for field, value in (("passedTests", True), ("skippedTests", False), ("totalTestCount", "1"),
                             ("totalTestCount", 2), ("skippedTests", 1), ("result", "Failed")):
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                require_ui_success({**valid, field: value})
        for value in (None, [], "Passed"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                require_ui_success(value)

    def test_sample_requires_exact_profile_quantity_and_single_observation(self):
        observation = {"resourceType": "Observation", "meta": {"profile": [PROFILE]},
                       "valueQuantity": {"value": 73, "code": "/min", "system": "http://unitsofmeasure.org"}}
        def payload(entries):
            return json.dumps({"resourceType": "Bundle", "entry": [{"resource": item} for item in entries]}).encode()
        require_heart_rate_sample(payload([observation]))
        for entries in ([], [observation, observation]):
            with self.subTest(entries=len(entries)), self.assertRaises(RuntimeError):
                require_heart_rate_sample(payload(entries))
        for field, value in (("value", True), ("value", "73"), ("value", 74), ("code", "kg"), ("system", "wrong")):
            changed = copy.deepcopy(observation)
            changed["valueQuantity"][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(RuntimeError):
                require_heart_rate_sample(payload([changed]))
        for profiles in ([], PROFILE, ["https://example.com/other-profile"]):
            changed = copy.deepcopy(observation)
            changed["meta"]["profile"] = profiles
            with self.subTest(profiles=profiles), self.assertRaises(RuntimeError):
                require_heart_rate_sample(payload([changed]))
