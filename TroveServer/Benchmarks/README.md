<!--
SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
SPDX-License-Identifier: MIT
-->

# TimescaleDB benchmark

This harness reproduces the workload used to choose TimescaleDB for Trove's
`fhir_resources` table. It compares a plain PostgreSQL table with an otherwise
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
docker compose --env-file TroveInfrastructure/docker/.env.example \
  -f TroveInfrastructure/docker/docker-compose.yml up -d server-timescale
python3 TroveServer/Benchmarks/benchmark.py
```

The full profile needs substantial time and disk space. A small smoke run is
useful while changing the harness:

```sh
python3 TroveServer/Benchmarks/benchmark.py \
  --participants 2 --days 1 --payload-bytes 512 --warmups 1 --runs 2 \
  --output /tmp/trove-benchmark-smoke.json
```

The JSON output retains every timing sample and the Markdown companion is ready
for a GitHub Actions job summary. The scheduled workflow uploads both files so
runs can be compared over time. It intentionally has no `pull_request` or
`push` trigger.

To check the deterministic generator without a database:

```sh
python3 -m unittest TroveServer/Benchmarks/test_workload.py
```
