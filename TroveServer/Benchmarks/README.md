<!--
SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
SPDX-License-Identifier: MIT
-->

# TimescaleDB benchmark

The historical storage comparison below and the [authenticated receiver smoke](#authenticated-receiver-smoke)
answer different questions. Only the latter exercises Trove authorization, full IG
validation, immutable graph storage and consent-backed study grants.

This isolated harness reproduces the historical storage-comparison workload.
Its schema is not the current application schema or an IG event receiver.
It compares a plain PostgreSQL table with an otherwise
equivalent Timescale hypertable in the same database process, which controls
for PostgreSQL, host, and storage differences.

The default workload contains 200 participants over 30 days. It generates
heart rate every minute, HRV SDNN every 5 minutes, step count every 15 minutes,
oxygen saturation every 30 minutes, and body weight daily. That is 11,238,000
FHIR R4 Observations. Each resource includes LOINC and HealthKit coding,
nanosecond-precision timestamps with participant offsets, and the nested source
device, source revision, and upload time-zone extensions. Padding keeps the
JSON resource close to the thesis's 2.5 KiB average.

The runner records total relation size and ingest throughput, then reports the
median of 20 measured executions after 2 warmups for the thesis's six queries:

- primary-key point lookup;
- one participant's 24-hour window;
- one participant's 7-day average using typed columns;
- the same 7-day average using JSONB;
- the population hourly aggregate; and
- the latest value for every participant.

The runner manually compresses every Timescale chunk before measuring queries.
This makes the compression state deterministic and confirms that the aggregate
numbers include compressed chunks rather than waiting for the asynchronous
seven-day policy.

Dataset generation is measured separately from ingestion. The generator writes
one compressed CSV fixture, and both targets consume that identical fixture.
The reported throughput therefore times database COPY plus the same gzip
decompression and Docker transport for each target, without counting Python's
FHIR construction cost.

## Run it

Start the Timescale service, then run the benchmark from the repository root:

```sh
docker compose -f TroveServer/Benchmarks/docker-compose.yml up -d --wait benchmark-db
python3 TroveServer/Benchmarks/benchmark.py
```

The full profile needs substantial time and disk space. A small smoke run is
useful while changing the harness:

```sh
python3 TroveServer/Benchmarks/benchmark.py \
  --participants 2 --days 1 --payload-bytes 512 --warmups 1 --runs 2 \
  --output /tmp/trove-benchmark-smoke.json
```

Readiness requires the final TCP server and an installed TimescaleDB extension.
The image's temporary initialization server can answer socket queries before
extension creation is complete; a successful `SELECT 1` alone is insufficient.
The harness waits up to two minutes with individually bounded probes and never
retries schema changes. The dedicated Compose project has no network, published ports
or application volumes; preparation replaces only its two synthetic benchmark tables.
It uses a pinned PostgreSQL 18/Timescale image with bounded CPU and memory.
Remove its disposable data after collecting results:

```sh
docker compose -f TroveServer/Benchmarks/docker-compose.yml down -v
```

The JSON output retains every timing sample and the Markdown companion is ready
for a GitHub Actions job summary. The scheduled workflow uses a bounded hosted
regression profile: **10 participants over 30 days**, or 561,900 rows per table.
It uploads both files and records the workload dimensions so comparisons do not
mix different scales. This run checks the harness; it does not establish acceptance
of the full 200-participant historical workload or application ingestion capacity.
The workflow intentionally has no `pull_request` or `push` trigger.

The command-line default remains the full 200-participant, 30-day profile. Manual
workflow dispatch accepts the same participant/day inputs, but the standard hosted
runner may not have enough storage for that profile. Use an adequately sized local
host for a full run. Before replacing its synthetic tables or generating data, the
harness checks both temporary storage and the Docker database volume. Its conservative
combined budget covers two table copies, indexes, WAL, compression workspace and the
fixture; it is a planning guard, not a storage prediction. The default full profile
requires at least 163 GiB free by this guard; the hosted regression requires 11 GiB.
Insufficient or unreadable capacity fails explicitly without shrinking the workload
or deleting unrelated files. Full-scale evidence must still be collected separately.

To check the deterministic generator without a database:

```sh
python3 -B -m unittest discover -s TroveServer/Benchmarks -v
```

## Authenticated Receiver Smoke

Use a native server built from the source under review and the
[verified validator assets and Keycloak archive](../../TroveInfrastructure/validator/README.md#backend-process-restart-check).
Python 3.12+, JDK 21 and Docker are required on macOS:

```sh
python3 -B TroveServer/Benchmarks/authenticated.py \
  --binary /absolute/path/to/TroveServer/.build/debug/TroveServer \
  --assets /private/tmp/trove-validator-build/assets \
  --image trove-fhir-validator:local \
  --keycloak-archive /absolute/path/to/keycloak-26.8.0.tar.gz \
  --java-home /absolute/path/to/jdk-21/Contents/Home \
  --events 6 --concurrency 2
```

The command reuses the process-restart harness's owned database, restricted runtime
login, object store, Keycloak and offline validator. Occupied ports are rejected;
no existing database or service is used. Teardown runs after success or failure.
The printed evidence directory retains only local synthetic inputs, logs and results.

One or more participants consent to the same two studies. Each event contains a complete graph with
one distinct heart-rate output derived using the pinned IG identity functions.
Missing credentials, the researcher role and a different participant's source access
are rejected before timing begins. The workload submits source-scoped requests in
round-robin participant order, replays alternating requests for every participant and verifies
source/event/payload/target commitments in every receipt. Exact event, point,
node, grant and audit counts must agree after replay; HTTP success alone does not
count as successful ingestion. Batches retain one checked outcome per member in
input order; a rejected member makes the measurement fail even when the outer
response is HTTP 200. Per-source event and grant counts are checked independently.

Version 4 of `summary.json` records all request-latency samples and nearest-rank percentiles, admission
duration, events/second, relation/index/database sizes, generated WAL bytes,
sampled backend/validator memory, binary/image/fixture identities and actual
container limits. Startup, study setup and fixture generation are excluded from
ingestion timing. Allocation sizes include fixed database overhead; memory samples
are not an exact peak. Synthetic `workload.json` permits inspection without tokens.

The workload is bounded to 1–32 participants, 2–1,024 events per participant, at most
8,192 events total and 1–4 concurrent requests. `--batch-size 1` uses the single-event
endpoint; sizes 2–16 use the batch endpoint, including an incomplete final batch.
For a paired comparison, use `--participants 4 --events 64 --concurrency 4` for both
runs, first with `--batch-size 1` and then with `--batch-size 8`.

For a longer bounded run, use `--participants 8 --events 1024 --batch-size 16
--concurrency 4`. Completion timestamps divide admission into four equal wall-clock
windows, retaining their event rates and request-latency samples. Windows count
completed events, not executor submission order; an empty window reports zero
throughput and no latency estimate. This helps detect a changing rate but is not a
steady-state or open-loop arrival-rate test.

Add `--request-rate 1` for one intended request per second, independent of prior
completions. `--batch-size 16` then offers sixteen events per full request; a tail
batch can contain fewer. Rates are bounded to 0.1–32 requests/second and the
planned arrival span to ten minutes. Omitting the option retains the burst.
The existing finite workload and four-worker limit still apply.

Each request records intended arrival, actual dispatch and verified completion.
The report separates dispatch lateness, request duration and total time since
arrival, plus peak scheduled-but-not-dispatched requests and drain time after
the final intended arrival. Request duration includes local encoding and receipt
checks, not only network time. These fields expose delay hidden by request-only
latency; dispatch delay includes the bounded client queue and host contention,
not an observed server queue. Workers wait for fixed deadlines, and cancellation
interrupts those waits on failure. No deadline depends on an earlier completion.

Compare the same `--participants 4 --events 512 --batch-size 16 --concurrency 4`
workload sequentially with `--request-rate 1` and `--request-rate 4`. A run can
pass every correctness check while accumulating dispatch delay: passing does
not mean the target arrival rate was sustained. Any rejected or incomplete
receipt still fails the run. This is bounded client-dispatch measurement, not
unconstrained server overload or a production admission envelope.

The harness also records PostgreSQL/validator cgroup-v2 CPU deltas around admission
and derives average occupied cores. Counters include background service work and
the small snapshot overhead; they do not measure backend or load-generator CPU,
per-event validation time, or an exact saturation point. A missing counter fails
measurement rather than reporting zero usage.

After replay, `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)` records the actual event-replay
lookup and the event/source-scoped output lookup used for late attribution. Each
must return exactly the expected fixture output. Plans use the database's current
statistics, without manual `ANALYZE` or forced index selection. These are synthetic,
read-only repository diagnostics, not new participant or research-query endpoints.
They measure the database executor, not application authorization or transfer of
the returned payload to a client.

Batch request latency is not per-event latency: use the separately recorded event
throughput, request count and batch size when comparing runs. Fixture users are
added only to the uniquely owned test realm, with genuine participant tokens and
independent profile/enrollment/consent/source flows; live realms are never modified.
The imported development realm uses 24-hour access tokens; this workload does not
exercise the production five-minute token lifetime or refresh behavior. All events
use one collection instant after consent, so increasing the event count does not
test multi-day history or temporal partitioning.

### Withdrawal During Independent Uploads

Add `--withdraw-primary --participants 8 --events 64 --batch-size 8 --concurrency 4`
to the authenticated command above. After all first-participant receipts return,
the harness withdraws that participant from the first study while other
participants continue uploading. Completion order is tracked, so an out-of-order
batch cannot trigger withdrawal before that participant's earlier batches finish.

The run fails unless withdrawal overlaps another participant's request. After
exact replays, it verifies unchanged historical events and grants, zero effective
outputs for the withdrawn enrollment, retained access for the other study and
every other participant, and exactly one withdrawal audit. The report retains the
overlap timing. This is request-level overlap, not database transaction tracing.
The triggering request's reported duration includes withdrawal; use the default
mode for admission-only comparisons. At least two participants and workers are
required. This does not test backup recovery, erasure or production closeout.

### Disk-Backed Capacity Run

Add `--capacity` explicitly for the larger local lane. It keeps the same real
authorization, complete graphs, independent grants and exact receipt checks, but
uses an anonymous disk-backed PostgreSQL volume, a 256 MiB container memory limit
and no swap. PostgreSQL uses 64 MiB shared buffers, 4 MiB work memory and 32 MiB
maintenance work memory. These are reproducible test constraints, not production
tuning recommendations. The default smoke remains unchanged.

This mode permits up to 32,768 events and a forty-minute intended arrival span;
execution has a one-hour deadline, including setup and replay, followed by the
harness's bounded cleanup grace periods. Start with
`--capacity --participants 2 --events 5 --batch-size 3 --concurrency 2` to verify
the setup, then use `--capacity --participants 32 --events 1024 --batch-size 16
--concurrency 4 --request-rate 1` with the same required artifact arguments.
Budget several GiB of free Docker/host storage for synthetic inputs, WAL and
evidence. Container teardown removes its anonymous database volume, not any
pre-existing database. The report records the actual mount/memory boundary and
whether database bytes exceeded that memory limit; a small capacity-mode smoke
must not be described as a larger-than-memory test.

This comparison concerns the database container's RAM, including its charged page
cache, not the host's total RAM. It does not establish cold storage latency,
multi-day history or production capacity. The workload also does not yet measure
large recordings, query/export latency, lifecycle cleanup under independent
traffic or backup restore. These bounds are not supported participant counts or
an admission envelope.
The full validator reuses one bounded engine after loading its pinned packages.
Every event and replay still undergoes full validation; startup and admission costs
must remain separate. Bulk-COPY throughput does not describe this path. Larger
scheduled workloads belong to the same benchmark family once this boundary is established.
