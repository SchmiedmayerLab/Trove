#!/usr/bin/env python3
#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

import csv
from datetime import datetime, timezone
import io
import json
import unittest

from workload import PROFILES, expected_row_count, generate_rows


class WorkloadTests(unittest.TestCase):
    def test_thesis_profile_produces_expected_rows(self):
        self.assertEqual(expected_row_count(200, 30), 11_238_000)

    def test_one_participant_day_has_all_five_profiles(self):
        rows = list(generate_rows(1, 1, datetime(2025, 1, 1, tzinfo=timezone.utc), 2560))
        self.assertEqual(len(rows), 1_873)
        self.assertEqual({row[4] for row in rows}, {profile.loinc_code for profile in PROFILES})

        resource = json.loads(rows[0][9])
        self.assertEqual(resource["resourceType"], "Observation")
        self.assertEqual(len(resource["code"]["coding"]), 2)
        self.assertGreaterEqual(len(rows[0][9].encode("utf-8")), 2500)
        extension_names = {extension["url"].rsplit("/", 1)[-1] for extension in resource["extension"]}
        self.assertIn("sampleUploadTimeZone", extension_names)

    def test_rows_are_valid_csv(self):
        row = next(generate_rows(1, 1, datetime(2025, 1, 1, tzinfo=timezone.utc), 512))
        output = io.StringIO()
        csv.writer(output).writerow(row)
        parsed = next(csv.reader(io.StringIO(output.getvalue())))
        self.assertEqual(parsed, [str(value) for value in row])


if __name__ == "__main__":
    unittest.main()
