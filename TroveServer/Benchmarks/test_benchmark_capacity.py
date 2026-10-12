#!/usr/bin/env python3
#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""Verify disk admission without generating a large workload or touching a database."""

import argparse
import subprocess
import unittest
from unittest.mock import Mock, patch

from benchmark import Benchmark, available_volume_bytes, required_disk_bytes


class BenchmarkCapacityTests(unittest.TestCase):
    def benchmark(self) -> Benchmark:
        return Benchmark(argparse.Namespace(
            participants=10, days=30, payload_bytes=2560,
            database_user="synthetic", database_name="synthetic",
        ))

    def test_budget_scales_with_the_selected_workload(self):
        self.assertEqual(required_disk_bytes(10, 30, 2560), (
            561_900 * 2560 * 2 + 2**30, 561_900 * 2560 * 4 + 2**30,
        ))
        self.assertEqual(required_disk_bytes(200, 30, 2560), (
            11_238_000 * 2560 * 2 + 2**30, 11_238_000 * 2560 * 4 + 2**30,
        ))

    def test_parses_portable_database_volume_capacity(self):
        self.assertEqual(available_volume_bytes(
            "Filesystem 1024-blocks Used Available Capacity Mounted on\n"
            "/dev/disk 20000 4000 16000 20% /pgdata\n"
        ), 16000 * 1024)

    def test_rejects_missing_ambiguous_or_invalid_capacity(self):
        for output in ("", "header\n", "header\n/dev/disk 1 2\n",
                       "header\n/dev/disk 1 2 unknown 1% /pgdata\n",
                       "header\n/dev/disk 1 2 -1 1% /pgdata\n",
                       "header\n/dev/a 1 2 3 1% /a\n/dev/b 1 2 3 1% /b\n"):
            with self.subTest(output=output), self.assertRaises(ValueError):
                available_volume_bytes(output)

    def test_rejects_either_storage_location_below_the_combined_budget(self):
        required = sum(required_disk_bytes(10, 30, 2560))
        for host_free, volume_free in ((required - 1, required * 2),
                                       (required * 2, required - 1),
                                       (required // 2, required // 2)):
            with self.subTest(host=host_free, volume=volume_free), \
                 patch("benchmark.shutil.disk_usage", return_value=Mock(free=host_free)), \
                 patch("benchmark.subprocess.run", return_value=Mock(stdout=(
                     "header\n/dev/disk 1 0 " + str(volume_free // 1024) + " 0% /pgdata\n"
                 ))), self.assertRaisesRegex(RuntimeError, "No benchmark tables have been replaced"):
                self.benchmark().check_disk_capacity()

    def test_accepts_sufficient_space_and_bounds_the_volume_probe(self):
        required = sum(required_disk_bytes(10, 30, 2560))
        with patch("benchmark.shutil.disk_usage", return_value=Mock(free=required)), \
             patch("benchmark.subprocess.run", return_value=Mock(stdout=(
                 "header\n/dev/disk 1 0 " + str(required // 1024 + 1) + " 0% /pgdata\n"
             ))) as run:
            self.benchmark().check_disk_capacity()
        self.assertEqual(run.call_args.args[0][-3:], ["df", "-Pk", "/pgdata"])
        self.assertEqual(run.call_args.kwargs["timeout"], 10)
        self.assertTrue(run.call_args.kwargs["check"])

    def test_unavailable_disk_inspection_never_replaces_tables(self):
        instance = self.benchmark()
        for error in (RuntimeError("not enough space"),
                      subprocess.TimeoutExpired("df", 10),
                      subprocess.CalledProcessError(1, "df"), ValueError("invalid capacity")):
            with self.subTest(error=error), \
                 patch.object(instance, "wait_for_readiness"), \
                 patch.object(instance, "check_disk_capacity", side_effect=error), \
                 patch.object(instance, "prepare") as prepare, \
                 patch.object(instance, "generate_dataset") as generate, \
                 self.assertRaises(type(error)):
                instance.run()
            prepare.assert_not_called()
            generate.assert_not_called()


if __name__ == "__main__":
    unittest.main()
