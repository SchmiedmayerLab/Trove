"""Pure reporting and receipt checks; full IG validation runs in the disposable smoke."""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import argparse
from concurrent.futures import CancelledError
import hashlib
import json
import unittest
from unittest.mock import Mock, patch

from authenticated import (BenchmarkCheckpoint, RequestTiming, arrival_summary, bounded_integer, bounded_request_rate,
                           canonical_targets, check_outcomes, check_receipt, completion_windows,
                           cpu_usage_seconds, latency_summary, request_groups, sql_literal, validate_workload,
                           verify_withdrawal, wait_for_arrival)


class AuthenticatedBenchmarkTests(unittest.TestCase):
    def test_withdrawal_requires_independent_concurrent_participants(self):
        validate_workload(8, 2, 4, 2, withdraw_primary=True)
        for participants, concurrency in ((1, 2), (2, 1)):
            with self.subTest(participants=participants, concurrency=concurrency), self.assertRaises(RuntimeError):
                validate_workload(8, participants, 4, concurrency, withdraw_primary=True)

    def test_withdrawal_requires_overlap_and_exact_isolation_after_replay(self):
        sources = ["00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002"]
        studies = ["00000000-0000-4000-8000-000000000003", "00000000-0000-4000-8000-000000000004"]
        workloads = [{"source": {"id": source}} for source in sources]
        rows = [{"source": source, "study": study, "outputs": 8}
                for source in sources for study in studies if source != sources[0] or study != studies[0]]
        stack = Mock(args=argparse.Namespace(events=8))
        stack.sql.side_effect = [json.dumps(rows), "1"]
        groups = [(0, [0]), (1, [0])]
        results = [([], RequestTiming(0, 0, 4)), ([], RequestTiming(1, 1, 3))]
        report = verify_withdrawal(stack, studies, workloads, groups, results, (2, 2.5))
        self.assertEqual(report["overlappingIndependentRequests"], 1)
        self.assertEqual(report["withdrawnParticipantEffectiveOutputs"], [0, 8])
        for interval in (None, (4, 5), (2, 2), (float("nan"), 3)):
            with self.subTest(interval=interval), self.assertRaises(RuntimeError):
                verify_withdrawal(stack, studies, workloads, groups, results, interval)
        for changed in (rows[:-1], rows + [{"source": sources[0], "study": studies[0], "outputs": 8}], None):
            stack.sql.side_effect = [json.dumps(changed), "1"]
            with self.subTest(rows=changed), self.assertRaises(RuntimeError):
                verify_withdrawal(stack, studies, workloads, groups, results, (2, 2.5))
        stack.sql.side_effect = [json.dumps(rows), "0"]
        with self.assertRaises(RuntimeError):
            verify_withdrawal(stack, studies, workloads, groups, results, (2, 2.5))

    def test_capacity_is_explicit_and_keeps_resource_and_duration_bounds(self):
        validate_workload(1024, 32, 16, 4, 1, capacity=True)
        for values in ((1024, 33, 16, 4, 1), (1024, 32, 16, 4, 0.1)):
            with self.subTest(values=values), self.assertRaises(RuntimeError):
                validate_workload(*values, capacity=True)
        with self.assertRaises(RuntimeError):
            validate_workload(1024, 32, 16, 4, 1)
        stack = object.__new__(BenchmarkCheckpoint)
        stack.args = argparse.Namespace(capacity=True)
        runtime, configuration = stack.postgres_arguments()
        self.assertNotIn("--tmpfs", runtime)
        self.assertIn("type=volume,destination=/pgdata", runtime)
        self.assertEqual(runtime[runtime.index("--memory") + 1], "256m")
        self.assertEqual(runtime[runtime.index("--memory-swap") + 1], "256m")
        self.assertIn("shared_buffers=64MB", configuration)
        stack.args.capacity = False
        runtime, configuration = stack.postgres_arguments()
        self.assertIn("--tmpfs", runtime)
        self.assertEqual(configuration, [])

    def test_arrival_measurement_keeps_queueing_out_of_request_duration(self):
        timing = RequestTiming(scheduled=1, dispatched=4, completed=5)
        self.assertEqual(timing.dispatch_delay_milliseconds, 3000)
        self.assertEqual(timing.request_milliseconds, 1000)
        self.assertEqual(timing.total_milliseconds, 4000)
        for values in ((-1, 0, 1), (2, 1, 3), (0, 2, 1), (0, 1, float("nan")), (0, float("inf"), 3)):
            with self.subTest(values=values), self.assertRaises(RuntimeError):
                RequestTiming(*values)

    def test_arrival_backlog_uses_intended_arrivals_and_actual_dispatch(self):
        result = arrival_summary([RequestTiming(1, 4, 6), RequestTiming(0, 2, 5), RequestTiming(2, 2, 3)], 1)
        self.assertEqual(result["mode"], "paced")
        self.assertEqual(result["peakAwaitingDispatch"], 2)
        self.assertEqual(result["lastScheduledArrivalSeconds"], 2)
        self.assertEqual(result["dispatchDelay"]["samplesMilliseconds"], [3000, 2000, 0])
        self.assertEqual(result["arrivalToCompletion"]["samplesMilliseconds"], [5000, 5000, 1000])
        immediate = arrival_summary([RequestTiming(0, 0, 1)], None)
        self.assertEqual(immediate["mode"], "burst")
        self.assertEqual(immediate["peakAwaitingDispatch"], 0)
        touching = arrival_summary([RequestTiming(0, 1, 2), RequestTiming(1, 2, 3)], 1)
        self.assertEqual(touching["peakAwaitingDispatch"], 1)
        with self.assertRaises(RuntimeError):
            arrival_summary([], None)

    def test_deadline_wait_is_interruptible_and_preserves_late_dispatch(self):
        stop = Mock()
        stop.wait.return_value = False
        with patch("authenticated.time.monotonic", side_effect=[1.0, 4.0]):
            self.assertEqual(wait_for_arrival(4, stop), 4)
        stop.wait.assert_called_with(3.0)
        with patch("authenticated.time.monotonic", side_effect=[6.0, 6.0]):
            self.assertEqual(wait_for_arrival(4, stop), 6)
        stop.wait.assert_called_with(0)
        stop.wait.return_value = True
        with patch("authenticated.time.monotonic", return_value=1.0), self.assertRaises(CancelledError):
            wait_for_arrival(600, stop)

    def test_paced_arrivals_have_finite_bounded_rates_and_duration(self):
        for value in ("0.1", "1", "32"):
            self.assertEqual(bounded_request_rate(value), float(value))
        for value in ("0", "-1", "nan", "inf", "33"):
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                bounded_request_rate(value)
        validate_workload(512, 4, 16, 4, 1)
        for rate in (0, -1, float("nan"), float("inf"), 33):
            with self.subTest(rate=rate), self.assertRaises(RuntimeError):
                validate_workload(512, 4, 16, 4, rate)
        with self.assertRaises(RuntimeError):
            validate_workload(1024, 8, 1, 4, 1)

    def test_nearest_rank_retains_raw_samples(self):
        samples = [20.0, 10.0, 40.0, 30.0]
        result = latency_summary(samples)
        self.assertEqual(result["samplesMilliseconds"], samples)
        self.assertEqual(result["p50Milliseconds"], 20.0)
        self.assertEqual(result["p95Milliseconds"], 40.0)
        self.assertEqual(result["p99Milliseconds"], 40.0)

    def test_invalid_or_empty_measurements_do_not_produce_success(self):
        for samples in ([], [-1], [float("nan")], [float("inf")]):
            with self.subTest(samples=samples), self.assertRaises(RuntimeError):
                latency_summary(samples)

    def test_workload_is_explicitly_bounded(self):
        parse = bounded_integer(2, 1024)
        self.assertEqual(parse("2"), 2)
        self.assertEqual(parse("1024"), 1024)
        for value in ("0", "1", "1025", "1000000"):
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                parse(value)

    def test_total_workload_and_request_parallelism_are_bounded(self):
        validate_workload(1024, 8, 16, 4)
        validate_workload(256, 32, 16, 4)
        for values in ((1024, 16, 16, 4), (1025, 1, 1, 1), (1, 1, 1, 1), (2, 0, 1, 1), (2, 33, 1, 1),
                       (2, 1, 0, 1), (2, 1, 17, 1), (2, 1, 1, 0), (2, 1, 1, 5)):
            with self.subTest(values=values), self.assertRaises(RuntimeError):
                validate_workload(*values)

    def test_completion_windows_use_wall_clock_not_submission_order(self):
        samples = [{"completedSeconds": completed, "events": events, "latencyMilliseconds": 10}
                   for completed, events in ((8, 2), (1, 3), (4, 1))]
        windows = completion_windows(samples, 8)
        self.assertEqual([window["events"] for window in windows], [3, 0, 1, 2])
        self.assertEqual([window["eventsPerSecond"] for window in windows], [1.5, 0, 0.5, 1])
        self.assertIsNone(windows[1]["requestLatency"])
        self.assertEqual(sum(window["requests"] for window in windows), len(samples))
        for completed in (-1, 9, float("nan")):
            with self.subTest(completed=completed), self.assertRaises(RuntimeError):
                completion_windows([{**samples[0], "completedSeconds": completed}], 8)
        for elapsed in (0, -1, float("inf")):
            with self.subTest(elapsed=elapsed), self.assertRaises(RuntimeError):
                completion_windows(samples, elapsed)

    def test_cpu_counters_require_nonnegative_cgroup_v2_usage(self):
        self.assertEqual(cpu_usage_seconds("usage_usec 1234567\nuser_usec 900000\nsystem_usec 334567\n"), 1.234567)
        for raw in ("", "user_usec 4", "usage_usec -1", "usage_usec nan"):
            with self.subTest(raw=raw), self.assertRaises(RuntimeError):
                cpu_usage_seconds(raw)

    def test_query_literal_cannot_escape_its_value(self):
        self.assertEqual(sql_literal("x'; DROP TABLE clinical_events; --"), "'x''; DROP TABLE clinical_events; --'")
        with self.assertRaises(RuntimeError):
            sql_literal("unsafe\0value")

    def test_round_robin_batches_keep_participants_separate_and_preserve_tail(self):
        self.assertEqual(request_groups(2, 5, 3), [(0, [0, 1, 2]), (1, [0, 1, 2]), (0, [3, 4]), (1, [3, 4])])
        for participants, events, batch in ((4, 64, 8), (3, 5, 1), (2, 3, 16)):
            groups = request_groups(participants, events, batch)
            for participant in range(participants):
                self.assertEqual([index for owner, indices in groups if owner == participant for index in indices],
                                 list(range(events)))
            self.assertTrue(all(1 <= len(indices) <= batch for _, indices in groups))

    def test_outer_batch_success_never_hides_missing_or_rejected_members(self):
        event = b'{"identifier":{"system":"urn:events","value":"one"},"entry":[]}'
        source = {"id": "source"}
        submission = {"targets": []}
        receipt = {"sourceId": "source", "producerEventIdentifier": {"system": "urn:events", "value": "one"},
                   "payloadSHA256": hashlib.sha256(event).hexdigest(), "targetIntentSHA256": hashlib.sha256(b"[]").hexdigest(),
                   "nodeCount": 0, "eventId": "489c39ee-1789-46ce-8234-6f8768237f6d"}
        check_outcomes([receipt], source, [event], [submission])
        for outcomes in ([], [receipt, receipt], [{"status": 503}], {"events": [receipt]}, [None]):
            with self.subTest(outcomes=outcomes), self.assertRaises(RuntimeError):
                check_outcomes(outcomes, source, [event], [submission])

    def test_target_commitment_ignores_only_order_and_identifier_case(self):
        first = [{"consentId": "B", "outputFullUrls": ["urn:b", "urn:a"]}, {"consentId": "A", "outputFullUrls": ["urn:c"]}]
        second = [{"consentId": "a", "outputFullUrls": ["urn:c"]}, {"consentId": "b", "outputFullUrls": ["urn:a", "urn:b"]}]
        self.assertEqual(canonical_targets(first), canonical_targets(second))
        self.assertNotEqual(canonical_targets(first), canonical_targets(second[:1]))

    def test_receipt_must_match_source_event_payload_intent_and_nodes(self):
        event = json.dumps({"identifier": {"system": "urn:events", "value": "event-1"}, "entry": [{}, {}]}).encode()
        targets = [{"consentId": "A", "outputFullUrls": ["urn:output"]}]
        receipt = {"sourceId": "source-1", "producerEventIdentifier": {"system": "urn:events", "value": "event-1"},
                   "payloadSHA256": hashlib.sha256(event).hexdigest(),
                   "targetIntentSHA256": hashlib.sha256(canonical_targets(targets)).hexdigest(), "nodeCount": 2,
                   "eventId": "489c39ee-1789-46ce-8234-6f8768237f6d"}
        check_receipt(receipt, {"id": "source-1"}, event, targets)
        for key, value in (("sourceId", "other"), ("producerEventIdentifier", {}), ("payloadSHA256", "0" * 64),
                           ("targetIntentSHA256", "0" * 64), ("nodeCount", 1)):
            with self.subTest(field=key), self.assertRaises(RuntimeError):
                check_receipt({**receipt, key: value}, {"id": "source-1"}, event, targets)


if __name__ == "__main__":
    unittest.main()
