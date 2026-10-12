#!/usr/bin/env python3
"""Bounded authenticated ingestion measurement on a uniquely owned disposable stack.

Uses the real receiver, restricted database role and pinned full IG validator.
This is a bounded scalar/graph workload, not a production admission envelope.
"""

# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

import argparse
import base64
import copy
from concurrent.futures import CancelledError, ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "TroveInfrastructure/validator"))
from rekey_fixture import rekey
from verify_process_restart import Checkpoint, add_stack_arguments, request, require, run_verification


class BenchmarkCheckpoint(Checkpoint):
    def postgres_arguments(self) -> tuple[list[str], list[str]]:
        if not self.args.capacity:
            return super().postgres_arguments()
        # An anonymous Docker volume is disk-backed and removed by owned-container
        # cleanup. Disable swap so the cgroup limit is a real database memory bound.
        return (["--memory", "256m", "--memory-swap", "256m", "--cpus", "2",
                 "--mount", "type=volume,destination=/pgdata"],
                ["postgres", "-c", "shared_buffers=64MB", "-c", "work_mem=4MB",
                 "-c", "maintenance_work_mem=32MB", "-c", "effective_cache_size=128MB"])

    @property
    def additional_participants(self):
        return [f"benchmark-{index}@example.com" for index in range(1, self.args.participants)]

    def prepare_keycloak(self):
        super().prepare_keycloak(participant_usernames=self.additional_participants)


def validate_workload(events, participants, batch_size, concurrency, request_rate=None, *, capacity=False, withdraw_primary=False):
    limit = 32768 if capacity else 8192
    require(2 <= events <= 1024 and 1 <= participants <= 32 and events * participants <= limit,
            f"Expected 2–1024 events per participant, 1–32 participants, at most {limit} events total")
    require(1 <= batch_size <= 16 and 1 <= concurrency <= 4, "Expected batch size 1–16 and concurrency 1–4")
    require(not withdraw_primary or (participants >= 2 and concurrency >= 2),
            "Withdrawal verification requires independent participants and concurrent workers")
    if request_rate is not None:
        require(math.isfinite(request_rate) and 0.1 <= request_rate <= 32,
                "Expected a finite request rate from 0.1 through 32 per second")
        requests = math.ceil(events / batch_size) * participants
        require((requests - 1) / request_rate <= (2400 if capacity else 600), "Planned arrivals exceed this mode's bound")


@dataclass(frozen=True)
class RequestTiming:
    scheduled: float
    dispatched: float
    completed: float

    def __post_init__(self) -> None:
        require(all(math.isfinite(value) for value in (self.scheduled, self.dispatched, self.completed))
                and 0 <= self.scheduled <= self.dispatched <= self.completed,
                "Request timestamps are non-finite or out of order")

    @property
    def request_milliseconds(self) -> float:
        return (self.completed - self.dispatched) * 1000

    @property
    def dispatch_delay_milliseconds(self) -> float:
        return (self.dispatched - self.scheduled) * 1000

    @property
    def total_milliseconds(self) -> float:
        return (self.completed - self.scheduled) * 1000


def wait_for_arrival(deadline: float, cancelled: threading.Event) -> float:
    if cancelled.wait(max(0, deadline - time.monotonic())):
        raise CancelledError("Admission schedule was cancelled")
    return time.monotonic()


def arrival_summary(timings: list[RequestTiming], rate: float | None) -> dict[str, object]:
    require(bool(timings), "Missing arrival measurements")
    # Positive-length intervals only; dispatches precede arrivals at equal instants.
    changes = sorted(change for timing in timings if timing.dispatched > timing.scheduled
                     for change in ((timing.scheduled, 1), (timing.dispatched, -1)))
    waiting = peak = 0
    for _, delta in changes:
        waiting += delta
        require(waiting >= 0, "Invalid scheduled backlog")
        peak = max(peak, waiting)
    require(waiting == 0, "Incomplete dispatch timeline")
    return {"mode": "paced" if rate is not None else "burst", "targetRequestsPerSecond": rate,
            "lastScheduledArrivalSeconds": max(item.scheduled for item in timings),
            "peakAwaitingDispatch": peak,
            "dispatchDelay": latency_summary([item.dispatch_delay_milliseconds for item in timings]),
            "arrivalToCompletion": latency_summary([item.total_milliseconds for item in timings]),
            "method": "Fixed intended arrivals; bounded dispatch workers. Delay includes client queueing and host contention, not measured server queueing."}


def request_groups(participant_count, event_count, batch_size):
    """Round-robin participants without ever mixing their source-scoped batches."""
    return [(participant, list(range(start, min(start + batch_size, event_count))))
            for start in range(0, event_count, batch_size) for participant in range(participant_count)]


def canonical_targets(targets):
    return json.dumps(sorted(
        ({"consentId": item["consentId"].lower(), "outputFullUrls": sorted(item["outputFullUrls"])} for item in targets),
        key=lambda item: item["consentId"],
    ), sort_keys=True, separators=(",", ":")).encode()


def check_receipt(receipt, source, event, targets):
    bundle = json.loads(event)
    require(receipt["sourceId"] == source["id"], "Receipt source mismatch")
    require(receipt["producerEventIdentifier"] == {key: bundle["identifier"][key] for key in ("system", "value")},
            "Receipt event identity mismatch")
    require(receipt["payloadSHA256"] == hashlib.sha256(event).hexdigest(), "Receipt payload digest mismatch")
    require(receipt["targetIntentSHA256"] == hashlib.sha256(canonical_targets(targets)).hexdigest(), "Receipt target digest mismatch")
    require(receipt["nodeCount"] == len(bundle["entry"]), "Receipt node count mismatch")
    uuid.UUID(receipt["eventId"])


def check_outcomes(outcomes, source, events, submissions):
    require(isinstance(outcomes, list) and len(outcomes) == len(events), "Missing or extra batch member outcomes")
    for receipt, event, submission in zip(outcomes, events, submissions, strict=True):
        require(isinstance(receipt, dict) and "eventId" in receipt, "A batch member was not accepted")
        check_receipt(receipt, source, event, submission["targets"])


def latency_summary(samples):
    require(bool(samples) and all(math.isfinite(value) and value >= 0 for value in samples), "Missing or invalid latency samples")
    ordered = sorted(samples)
    return {"samplesMilliseconds": samples, **{
        f"p{percentile}Milliseconds": ordered[math.ceil(len(ordered) * percentile / 100) - 1]
        for percentile in (50, 95, 99)
    }, "method": "nearest rank; small smoke samples do not estimate tail capacity"}


def completion_windows(samples, elapsed):
    """Four wall-clock windows; completed events are not ordered by executor submission."""
    require(math.isfinite(elapsed) and elapsed > 0, "Invalid measured duration")
    windows = [[] for _ in range(4)]
    for sample in samples:
        completed = sample["completedSeconds"]
        require(math.isfinite(completed) and 0 <= completed <= elapsed, "Completion is outside the measured interval")
        require(isinstance(sample["events"], int) and sample["events"] > 0, "Invalid completed-event count")
        windows[min(int(completed * 4 / elapsed), 3)].append(sample)
    return [{"startSeconds": index * elapsed / 4, "endSeconds": (index + 1) * elapsed / 4,
             "events": sum(item["events"] for item in window), "requests": len(window),
             "eventsPerSecond": sum(item["events"] for item in window) * 4 / elapsed,
             "requestLatency": latency_summary([item["latencyMilliseconds"] for item in window]) if window else None}
            for index, window in enumerate(windows)]


def cpu_usage_seconds(raw):
    values = dict(line.split() for line in raw.splitlines())
    usage = values.get("usage_usec", "")
    require(usage.isascii() and usage.isdecimal(), "Missing cgroup-v2 CPU usage counter")
    return int(usage) / 1_000_000


def cpu_snapshot(stack):
    return {label: cpu_usage_seconds(stack.run([
        "docker", "exec", container, "cat", "/sys/fs/cgroup/cpu.stat",
    ]).decode()) for label, container in (("postgres", stack.pg_container), ("validator", stack.name + "-worker"))}


def sql_literal(value):
    require(isinstance(value, str) and "\0" not in value, "Invalid SQL text literal")
    return "'" + value.replace("'", "''") + "'"


def query_plans(stack, workload, receipt):
    """Read-only plans for real receiver lookups; no researcher or participant endpoint."""
    identity = json.loads(workload["events"][-1])["identifier"]
    event_id = str(uuid.UUID(receipt["eventId"]))
    source_id = str(uuid.UUID(workload["source"]["id"]))
    queries = {
        "eventReplay": f"SELECT * FROM clinical_events WHERE identifier_system = {sql_literal(identity['system'])} "
                       f"AND identifier_value = {sql_literal(identity['value'])}",
        "attributionOutputs": "SELECT f.node_id, n.full_url, f.profile, f.effective_at "
                              "FROM clinical_point_facts f JOIN clinical_event_nodes n ON n.id = f.node_id "
                              f"WHERE f.event_id = '{event_id}' AND f.source_id = '{source_id}'",
    }
    plans = {name: json.loads(stack.sql("EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) " + query))[0]
             for name, query in queries.items()}
    require(all(plan["Plan"]["Actual Rows"] == 1 for plan in plans.values()), "Receiver lookup plan did not find its exact output")
    return plans


def fixture_event(template, source, sequence, instant, derive):
    """Create a distinct native record using the pinned IG identity implementation."""
    bundle = copy.deepcopy(template)
    # Synthetic workloads use the source UUID as a reproducible local producer ID.
    # The API no longer assigns producer identity; deployed clients use Grove's ledger.
    producer_instance = str(uuid.UUID(source["id"]))
    components = ["org.troveplatform.benchmark.heart-rate.v1", "HKQuantityTypeIdentifierHeartRate",
                  source["eventIdentifierSystem"], producer_instance, str(sequence)]
    identities = {role: derive(key=bytes(range(32)), key_id="test-key", epoch=1, identity_kind=role,
                              components=components + (["observation", "primary"] if role == "source-output" else []))
                  for role in ("source-record", "source-output")}

    def replace(value):
        if isinstance(value, dict):
            coding = value.get("type", {}).get("coding", []) if isinstance(value.get("type"), dict) else []
            for item in coding:
                role = item.get("code")
                if item.get("system") == "https://grovealliance.org/fhir/mobile/CodeSystem/grove-identifier-role" and role in identities:
                    value["value"] = identities[role]
            for child in value.values():
                replace(child)
        elif isinstance(value, list):
            for child in value:
                replace(child)

    replace(bundle)
    result = rekey(bundle, event_system=source["eventIdentifierSystem"], producer_instance=producer_instance,
                   participant_system=source["participantIdentifier"]["system"], participant_value=source["participantIdentifier"]["value"],
                   effective_at=instant, sequence=sequence)
    return json.dumps(result, separators=(",", ":")).encode()


def storage_snapshot(stack):
    rows = json.loads(stack.sql("""SELECT json_build_object(
        'events', (SELECT count(*) FROM clinical_events),
        'nodes', (SELECT count(*) FROM clinical_event_nodes),
        'points', (SELECT count(*) FROM clinical_point_facts),
        'grants', (SELECT count(*) FROM study_data_grants),
        'acceptanceAudits', (SELECT count(*) FROM audit_events WHERE action='clinical.event.accepted'),
        'grantAudits', (SELECT count(*) FROM audit_events WHERE action='study.data.granted'));"""))
    relations = json.loads(stack.sql("""SELECT coalesce(json_agg(json_build_object(
        'schema', schemaname, 'relation', relname,
        'tableBytes', pg_table_size(relid), 'indexBytes', pg_indexes_size(relid),
        'totalBytes', pg_total_relation_size(relid)) ORDER BY schemaname, relname), '[]'::json)
        FROM pg_stat_user_tables;"""))
    return {"rows": rows, "relations": relations, "databaseBytes": int(stack.sql("SELECT pg_database_size(current_database());"))}


def verify_withdrawal(stack, studies, workloads, groups, results, interval):
    require(interval is not None, "The requested withdrawal did not execute")
    started, completed = interval
    require(0 <= started < completed, "Invalid withdrawal timing")
    overlapping = sum(owner != 0 and timing.dispatched < completed and timing.completed > started
                      for (owner, _), (_, timing) in zip(groups, results, strict=True))
    require(overlapping > 0, "Withdrawal did not overlap an independent participant's request")
    rows = json.loads(stack.sql("""SELECT json_agg(json_build_object(
        'source', g.source_id, 'study', g.study_id, 'outputs', outputs)) FROM (
        SELECT g.source_id, g.study_id, count(DISTINCT g.node_id) AS outputs
        FROM study_data_grants g JOIN enrollments e ON e.id=g.enrollment_id AND e.study_id=g.study_id
        WHERE e.withdrawn_at IS NULL GROUP BY g.source_id, g.study_id) g;"""))
    require(isinstance(rows, list), "Missing effective grant measurements")
    actual = {(str(uuid.UUID(row["source"])), str(uuid.UUID(row["study"]))): row["outputs"] for row in rows}
    expected = {(str(uuid.UUID(workload["source"]["id"])), str(uuid.UUID(study))): stack.args.events
                for index, workload in enumerate(workloads) for study_index, study in enumerate(studies)
                if index != 0 or study_index != 0}
    require(actual == expected, "Withdrawal changed another study or participant's effective grants")
    require(stack.sql("SELECT count(*) FROM audit_events WHERE action='enrollment.withdrawn';") == "1",
            "Withdrawal is missing its single committed audit record")
    return {"startedSeconds": started, "completedSeconds": completed,
            "overlappingIndependentRequests": overlapping,
            "withdrawnParticipantEffectiveOutputs": [0, stack.args.events],
            "otherParticipantsRetainBothStudies": True, "withdrawalAudits": 1}


def exercise(stack):
    validate_workload(stack.args.events, stack.args.participants, stack.args.batch_size,
                      stack.args.concurrency, stack.args.request_rate, capacity=stack.args.capacity,
                      withdraw_primary=stack.args.withdraw_primary)
    stack.backend(1)
    researcher, participant, studies, enrollments, consents = stack.prepare_studies()
    participants = [(participant, consents)]
    for username in stack.additional_participants:
        token = stack.token(username)
        stack.api_json("/participant/profile", token, "POST", {
            "firstName": "Synthetic", "lastName": "Participant", "gender": "preferNotToState", "dateOfBirth": "1990-01-01",
            "region": "US", "language": "en-US", "phoneNumber": "+16505550123"}, expected=201)
        accepted = []
        for study in studies:
            enrollment = stack.api_json(f"/participant/studies/{study}/enrollments", token, "POST", {}, 201)["id"]
            accepted.append(stack.consent(enrollment, token))
        participants.append((token, accepted))
    sys.path.insert(0, str(stack.args.assets / "grove-fhir"))
    from Scripts.exchange_protocol import derive_hmac_identity
    fixture = ROOT / "TroveServer/Tests/TroveServerTests/Resources/ImmutablePointEvent.json"
    template = json.loads(fixture.read_bytes())
    sources = [stack.api_json("/participant/sources", token, "POST", {"registrationID": str(uuid.uuid4())})
               for token, _ in participants]
    instant = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    generated_at = time.monotonic()
    workloads = []
    for (_, accepted), source in zip(participants, sources, strict=True):
        events = [fixture_event(template, source, index + 1, instant, derive_hmac_identity) for index in range(stack.args.events)]
        submissions = []
        for event in events:
            outputs = [entry["fullUrl"] for entry in json.loads(event)["entry"] if entry["resource"]["resourceType"] == "Observation"]
            require(len(outputs) == 1, "The fixture must contain exactly one scalar output")
            submissions.append({"eventBase64": base64.b64encode(event).decode(),
                                "targets": [{"consentId": consent["id"], "outputFullUrls": outputs} for consent in accepted]})
        workloads.append({"source": source, "events": events, "submissions": submissions})
    generation_seconds = time.monotonic() - generated_at
    # Retain reproducible synthetic input without credentials. Generation and setup are untimed.
    (stack.evidence / "workload.json").write_text(json.dumps(
        [{"source": item["source"], "submissions": item["submissions"]} for item in workloads], indent=2) + "\n")
    before = storage_snapshot(stack)
    baseline_lsn = stack.sql("SELECT pg_current_wal_lsn();")
    require(re.fullmatch(r"[0-9A-F]+/[0-9A-F]+", baseline_lsn) is not None, "Invalid WAL position")
    path = f'/participant/sources/{workloads[0]["source"]["id"]}/events'
    # Negative controls establish real authentication and role checks before timed ingestion.
    control = workloads[0]["submissions"][0]
    if stack.args.batch_size > 1:
        path += "/batch"
        control = {"events": [control]}
    request(stack.api + path, "POST", control, expected=401)
    request(stack.api + path, "POST", control, researcher, expected=403)
    if len(participants) > 1:
        request(stack.api + path, "POST", control, participants[1][0], expected=404)

    cpu_before = cpu_snapshot(stack)

    cancelled = threading.Event()
    primary_lock = threading.Lock()
    primary_completed = 0
    withdrawal_interval = None

    def submit(group, scheduled: float = 0):
        nonlocal primary_completed, withdrawal_interval
        dispatched = wait_for_arrival(started + scheduled, cancelled) - started
        participant_index, indices = group
        workload = workloads[participant_index]
        source, token = workload["source"], participants[participant_index][0]
        path = f'/participant/sources/{source["id"]}/events'
        submissions = [workload["submissions"][index] for index in indices]
        if stack.args.batch_size == 1:
            outcomes = [stack.api_json(path, token, "POST", submissions[0])]
        else:
            outcomes = stack.api_json(path + "/batch", token, "POST", {"events": submissions})
        check_outcomes(outcomes, source, [workload["events"][index] for index in indices], submissions)
        if stack.args.withdraw_primary and participant_index == 0:
            # Batches may complete out of order. Wait for every primary receipt,
            # not merely its final scheduled batch; never withdraw mid-admission.
            with primary_lock:
                primary_completed += len(outcomes)
                withdraw_now = primary_completed == stack.args.events
            if withdraw_now:
                withdrawal_started = time.monotonic() - started
                stack.api_json(f"/participant/enrollments/{enrollments[0]}/withdraw", token, "POST")
                withdrawal_interval = (withdrawal_started, time.monotonic() - started)
        return outcomes, RequestTiming(scheduled, dispatched, time.monotonic() - started)

    groups = request_groups(len(participants), stack.args.events, stack.args.batch_size)
    started = time.monotonic()
    pool = ThreadPoolExecutor(max_workers=stack.args.concurrency)
    try:
        deadlines = [index / stack.args.request_rate if stack.args.request_rate is not None else 0
                     for index in range(len(groups))]
        results = list(pool.map(submit, groups, deadlines))
    finally:
        # An early failure must not send the rest of a queued workload. Already
        # active requests retain the shared transport's finite timeout.
        cancelled.set()
        pool.shutdown(wait=True, cancel_futures=True)
    elapsed = time.monotonic() - started
    cpu_after = cpu_snapshot(stack)
    count = stack.args.events * len(participants)
    require(len({receipt["eventId"] for outcomes, _ in results for receipt in outcomes}) == count,
            "Distinct events shared a custody receipt")
    replay_samples = []
    replay_events = 0
    cancelled.clear()  # The verified replay phase is untimed by the arrival schedule.
    for index, (_, indices) in enumerate(groups):
        if (indices[0] // stack.args.batch_size) % 2:
            continue
        outcomes, timing = submit(groups[index])
        require(outcomes == results[index][0], "Replay changed the original receipts")
        replay_events += len(outcomes)
        replay_samples.append(timing.request_milliseconds)
    after = storage_snapshot(stack)
    require(after["rows"] == {"events": count, "nodes": count * len(template["entry"]), "points": count,
                              "grants": count * 2, "acceptanceAudits": count, "grantAudits": count * 2},
            "Stored events, independent grants or transaction audits were lost or duplicated")
    source_rows = json.loads(stack.sql("""SELECT json_agg(json_build_object(
        'sourceId', source_id, 'events', events, 'grants', grants)) FROM (
        SELECT source_id, count(*) AS events,
            (SELECT count(*) FROM study_data_grants g WHERE g.source_id=e.source_id) AS grants
        FROM clinical_events e GROUP BY source_id) counts;"""))
    require({str(uuid.UUID(row["sourceId"])) for row in source_rows}
            == {str(uuid.UUID(item["source"]["id"])) for item in workloads}
            and all(row["events"] == stack.args.events and row["grants"] == 2 * stack.args.events for row in source_rows),
            "Per-source event or study-grant counts disagree")
    withdrawal = (verify_withdrawal(stack, studies, workloads, groups, results, withdrawal_interval)
                  if stack.args.withdraw_primary else None)
    wal_bytes = int(stack.sql(f"SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), '{baseline_lsn}'::pg_lsn)::bigint;"))
    require(stack.memory["backendSamples"] > 0 and stack.memory["validatorSamples"] > 0, "Missing memory observations")
    container_limits = [{"name": item["Name"].lstrip("/"), "memoryBytes": item["HostConfig"]["Memory"],
                         "nanoCPUs": item["HostConfig"]["NanoCpus"], "imageID": item["Image"]}
                        for item in json.loads(stack.run(["docker", "inspect", *stack.containers]))]
    plans = query_plans(stack, workloads[-1], results[-1][0][-1])
    postgres = json.loads(stack.run(["docker", "inspect", stack.pg_container]))[0]
    data_mounts = [mount for mount in postgres["Mounts"] if mount["Destination"] == "/pgdata"]
    memory_limit = postgres["HostConfig"]["Memory"]
    if stack.args.capacity:
        require(len(data_mounts) == 1 and data_mounts[0]["Type"] == "volume"
                and memory_limit == 256 * 1024 * 1024
                and postgres["HostConfig"]["MemorySwap"] == memory_limit,
                "Capacity run did not use the declared disk/memory boundary")
    storage_boundary = {"mode": "disk-backed" if stack.args.capacity else "tmpfs",
                        "databaseMemoryLimitBytes": memory_limit,
                        "databaseExceedsMemoryLimit": after["databaseBytes"] > memory_limit,
                        "method": "Database size versus its container limit; not host RAM or a cold-cache guarantee"}
    completion_samples = [{"scheduledSeconds": timing.scheduled, "dispatchedSeconds": timing.dispatched,
                           "completedSeconds": timing.completed, "latencyMilliseconds": timing.request_milliseconds,
                           "events": len(outcomes)} for outcomes, timing in results]
    cpu = {label: cpu_after[label] - cpu_before[label] for label in cpu_before}
    require(all(value >= 0 for value in cpu.values()), "CPU usage counter moved backwards")
    stack.summary.update(passed=True, workload={"version": 4, "kind": "heart-rate-graph", "participants": len(participants),
        "studies": 2, "events": count, "eventsPerParticipant": stack.args.events, "concurrency": stack.args.concurrency,
        "batchSize": stack.args.batch_size, "requests": len(groups), "replayRequests": len(replay_samples), "replayedEvents": replay_events,
        "fixtureSHA256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
        "payloadBytes": sum(len(event) for item in workloads for event in item["events"]), "generationSeconds": generation_seconds},
        ingestion={"elapsedSeconds": elapsed, "eventsPerSecond": count / elapsed,
                   "requestLatency": latency_summary([timing.request_milliseconds for _, timing in results]),
                   "arrivalSchedule": arrival_summary([timing for _, timing in results], stack.args.request_rate),
                   "drainAfterLastArrivalSeconds": elapsed - max(timing.scheduled for _, timing in results),
                   "completionSamples": completion_samples, "completionWindows": completion_windows(completion_samples, elapsed)},
        serviceCPU={"seconds": cpu, "averageCores": {label: seconds / elapsed for label, seconds in cpu.items()},
                    "method": "cgroup-v2 usage deltas around admission; includes background service work and snapshot overhead"},
        queryPlans={"receiverLookups": plans, "method": "EXPLAIN ANALYZE BUFFERS after replay; no forced planner settings or manual ANALYZE"},
        replayRequestLatency=latency_summary(replay_samples), storageBefore=before, storageAfter=after,
        perSourceRows=source_rows, walBytes=wal_bytes, storageBoundary=storage_boundary,
        withdrawalDuringIndependentTraffic=withdrawal,
        host={"platform": platform.platform(), "machine": platform.machine(), "logicalCPUCount": os.cpu_count()},
        containerLimits=container_limits,
        exclusions=["production capacity", "larger-than-host-RAM data", "cold-cache guarantee",
                    "corrections/retractions", "closeout/erasure under independent traffic", "export latency",
                    "artifact payload workload", "backup/restore", "exact peak memory"])


def bounded_integer(minimum, maximum):
    def parse(value):
        number = int(value)
        if not minimum <= number <= maximum:
            raise argparse.ArgumentTypeError(f"Expected {minimum} through {maximum}")
        return number
    return parse


def bounded_request_rate(value: str) -> float:
    rate = float(value)
    if not math.isfinite(rate) or not 0.1 <= rate <= 32:
        raise argparse.ArgumentTypeError("Expected a finite request rate from 0.1 through 32 per second")
    return rate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    add_stack_arguments(parser)
    parser.add_argument("--events", type=bounded_integer(2, 1024), default=6, help="Events per participant")
    parser.add_argument("--participants", type=bounded_integer(1, 32), default=1)
    parser.add_argument("--batch-size", type=bounded_integer(1, 16), default=1, help="1 uses the single-event endpoint")
    parser.add_argument("--concurrency", type=bounded_integer(1, 4), default=2)
    parser.add_argument("--capacity", action="store_true",
                        help="Explicit disk-backed run: 256 MiB PostgreSQL, no swap, up to 32768 events and a one-hour deadline.")
    parser.add_argument("--withdraw-primary", action="store_true",
                        help="Withdraw the first participant from one study after their admission; require overlap with other participants.")
    parser.add_argument("--request-rate", type=bounded_request_rate,
                        help="Fixed intended requests per second; omit for a burst. Dispatch remains concurrency-bounded.")
    args = parser.parse_args()
    validate_workload(args.events, args.participants, args.batch_size, args.concurrency, args.request_rate,
                      capacity=args.capacity, withdraw_primary=args.withdraw_primary)
    os.umask(0o077)
    stack = BenchmarkCheckpoint(args)
    run_verification(stack, lambda: exercise(stack), timeout_seconds=3600 if args.capacity else 1800)
    print("PASS: authenticated ingestion, two-study grants and exact replay; see measured limits and exclusions in summary.json.")


if __name__ == "__main__":
    main()
