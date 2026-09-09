#!/usr/bin/env python3
#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

import argparse
import subprocess
import unittest
from unittest.mock import Mock, patch

from benchmark import Benchmark


class ReadinessTests(unittest.TestCase):
    def setUp(self):
        self.benchmark = Benchmark(argparse.Namespace(
            database_user="synthetic", database_name="synthetic"
        ))
        self.now = 0.0
        clock = patch("benchmark.time.monotonic", side_effect=lambda: self.now)
        sleep = patch("benchmark.time.sleep", side_effect=self.advance)
        clock.start()
        sleep.start()
        self.addCleanup(clock.stop)
        self.addCleanup(sleep.stop)

    def advance(self, seconds):
        self.now += seconds

    def test_connection_without_extension_is_not_ready(self):
        self.benchmark.sql = Mock(side_effect=["f", "f", "t"])
        self.benchmark.wait_for_readiness()
        self.assertEqual(self.benchmark.sql.call_count, 3)
        self.assertEqual(self.now, 1.0)
        for call in self.benchmark.sql.call_args_list:
            self.assertIn("pg_extension", call.args[0])
            self.assertNotIn("CREATE", call.args[0])
            self.assertEqual(call.kwargs["timeout_seconds"], 5.0)

    def test_unavailable_and_hung_probes_can_recover(self):
        self.benchmark.sql = Mock(side_effect=[
            subprocess.CalledProcessError(2, "synthetic"),
            subprocess.TimeoutExpired("synthetic", 5),
            "t"
        ])
        self.benchmark.wait_for_readiness()
        self.assertEqual(self.benchmark.sql.call_count, 3)

    def test_missing_extension_has_a_bounded_deadline(self):
        self.benchmark.sql = Mock(return_value="f")
        with self.assertRaisesRegex(RuntimeError, "Timed out"):
            self.benchmark.wait_for_readiness(timeout_seconds=1, interval_seconds=0.5)
        self.assertEqual(self.now, 1.0)
        self.assertEqual(self.benchmark.sql.call_count, 2)
        self.assertEqual(self.benchmark.sql.call_args.kwargs["timeout_seconds"], 0.5)

    def test_queries_use_final_tcp_server_and_probe_timeout(self):
        with patch("benchmark.subprocess.run") as run:
            run.return_value.stdout = "t\n"
            self.assertEqual(self.benchmark.sql("SELECT true", timeout_seconds=3), "t")
        command = run.call_args.args[0]
        self.assertEqual(command[command.index("-h") + 1], "127.0.0.1")
        self.assertEqual(run.call_args.kwargs["timeout"], 3)
        self.assertTrue(run.call_args.kwargs["check"])

    def test_benchmark_never_targets_application_compose(self):
        self.assertEqual(self.benchmark.compose_directory, self.benchmark.directory)
        self.assertIn("benchmark-db", self.benchmark.psql)
        self.assertNotIn("server-db", self.benchmark.psql)
        self.assertNotIn("--env-file", self.benchmark.compose)

    def test_invalid_wait_configuration_is_rejected(self):
        for timeout, interval in [(0, 1), (1, 0), (-1, 1)]:
            with self.subTest(timeout=timeout, interval=interval), self.assertRaises(ValueError):
                self.benchmark.wait_for_readiness(timeout, interval)


if __name__ == "__main__":
    unittest.main()
