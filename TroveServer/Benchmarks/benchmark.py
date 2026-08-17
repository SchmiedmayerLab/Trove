#!/usr/bin/env python3
#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""Load and measure the PostgreSQL and Timescale benchmark targets."""

from __future__ import annotations

import argparse
from datetime import timedelta
import json
from pathlib import Path
import statistics
import subprocess
import sys
import time

from workload import LOINC_SYSTEM, PROFILES, expected_row_count, parse_start, participant_id


COLUMNS = "participant_id,resource_type,time,external_id,code,code_system,value,value_code,value_system,resource"


class Benchmark:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.directory = Path(__file__).resolve().parent
        self.repository = self.directory.parents[1]
        self.compose_directory = self.repository / "TroveInfrastructure" / "docker"
        self.compose = [
            "docker",
            "compose",
            "--env-file",
            str(self.compose_directory / args.env_file),
            "-f",
            str(self.compose_directory / "docker-compose.yml"),
        ]
        self.psql = [
            *self.compose,
            "exec",
            "-T",
            "server-timescale",
            "psql",
            "-X",
            "-v",
            "ON_ERROR_STOP=1",
            "-U",
            args.database_user,
            "-d",
            args.database_name,
        ]

    def sql(self, statement: str) -> str:
        result = subprocess.run(
            [*self.psql, "-Atqc", statement],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()

    def prepare(self) -> None:
        subprocess.run(
            self.psql,
            input=(self.directory / "schema.sql").read_text(encoding="utf-8"),
            check=True,
            text=True,
        )

    def load(self, table: str) -> tuple[int, float]:
        generator = [
            sys.executable,
            str(self.directory / "workload.py"),
            "--participants",
            str(self.args.participants),
            "--days",
            str(self.args.days),
            "--start",
            self.args.start,
            "--payload-bytes",
            str(self.args.payload_bytes),
        ]
        started = time.monotonic()
        producer = subprocess.Popen(generator, stdout=subprocess.PIPE)
        assert producer.stdout is not None
        consumer = subprocess.Popen(
            [*self.psql, "-c", f"\\copy {table} ({COLUMNS}) FROM STDIN WITH (FORMAT csv)"],
            stdin=producer.stdout,
        )
        producer.stdout.close()
        consumer_status = consumer.wait()
        producer_status = producer.wait()
        if consumer_status or producer_status:
            raise RuntimeError(f"load failed: generator={producer_status}, psql={consumer_status}")
        elapsed = time.monotonic() - started
        rows = int(self.sql(f"SELECT count(*) FROM {table}"))
        return rows, elapsed

    def compress(self) -> tuple[int, int, float]:
        before = int(self.sql("SELECT hypertable_size('benchmark_timescale')"))
        started = time.monotonic()
        self.sql(
            "SELECT compress_chunk(chunk, if_not_compressed => true) "
            "FROM show_chunks('benchmark_timescale') AS chunk"
        )
        elapsed = time.monotonic() - started
        compressed_chunks = int(
            self.sql(
                "SELECT count(*) FROM timescaledb_information.chunks "
                "WHERE hypertable_name = 'benchmark_timescale' AND is_compressed"
            )
        )
        return before, compressed_chunks, elapsed

    def queries(self) -> dict[str, str]:
        start = parse_start(self.args.start)
        end = start + timedelta(days=self.args.days)
        window_start = start + timedelta(days=min(self.args.days // 2, self.args.days - 1))
        window_end = min(end, window_start + timedelta(days=1))
        average_end = window_end
        average_start = max(start, average_end - timedelta(days=7))
        participant = participant_id(0)
        heart_rate = PROFILES[0]
        point_external_id = f"p000-{heart_rate.loinc_code}-000000"
        start_sql = start.isoformat()
        window_start_sql = window_start.isoformat()
        window_end_sql = window_end.isoformat()
        average_start_sql = average_start.isoformat()
        average_end_sql = average_end.isoformat()
        end_sql = end.isoformat()
        return {
            "point_lookup": (
                "SELECT resource FROM {table} "
                f"WHERE participant_id = '{participant}' AND time = '{start_sql}' "
                f"AND external_id = '{point_external_id}'"
            ),
            "participant_24h_window": (
                "SELECT time, value FROM {table} "
                f"WHERE participant_id = '{participant}' AND resource_type = 'Observation' "
                f"AND code_system = '{LOINC_SYSTEM}' AND code = '{heart_rate.loinc_code}' "
                f"AND time >= '{window_start_sql}' AND time < '{window_end_sql}' ORDER BY time"
            ),
            "participant_7d_average_typed": (
                "SELECT avg(value) FROM {table} "
                f"WHERE participant_id = '{participant}' AND resource_type = 'Observation' "
                f"AND code_system = '{LOINC_SYSTEM}' AND code = '{heart_rate.loinc_code}' "
                f"AND time >= '{average_start_sql}' AND time < '{average_end_sql}'"
            ),
            "participant_7d_average_jsonb": (
                "SELECT avg((resource #>> '{{valueQuantity,value}}')::double precision) FROM {table} "
                f"WHERE participant_id = '{participant}' AND resource_type = 'Observation' "
                f"AND code_system = '{LOINC_SYSTEM}' AND code = '{heart_rate.loinc_code}' "
                f"AND time >= '{average_start_sql}' AND time < '{average_end_sql}'"
            ),
            "population_hourly_bucket": (
                "SELECT date_trunc('hour', time) AS bucket, avg(value) FROM {table} "
                f"WHERE resource_type = 'Observation' AND code_system = '{LOINC_SYSTEM}' "
                f"AND code = '{heart_rate.loinc_code}' AND time >= '{start_sql}' AND time < '{end_sql}' "
                "GROUP BY bucket ORDER BY bucket"
            ),
            "latest_value_per_participant": (
                "SELECT DISTINCT ON (participant_id) participant_id, time, value FROM {table} "
                f"WHERE resource_type = 'Observation' AND code_system = '{LOINC_SYSTEM}' "
                f"AND code = '{heart_rate.loinc_code}' ORDER BY participant_id, time DESC"
            ),
        }

    def execution_time_ms(self, query: str) -> float:
        plan = json.loads(self.sql(f"EXPLAIN (ANALYZE, FORMAT JSON, TIMING OFF) {query}"))
        return float(plan[0]["Execution Time"])

    def measure_queries(self) -> dict[str, dict[str, float | list[float]]]:
        results: dict[str, dict[str, float | list[float]]] = {}
        for name, template in self.queries().items():
            for table in ("benchmark_postgres", "benchmark_timescale"):
                query = template.format(table=table)
                for _ in range(self.args.warmups):
                    self.execution_time_ms(query)
                samples = [self.execution_time_ms(query) for _ in range(self.args.runs)]
                results.setdefault(name, {})[table] = round(statistics.median(samples), 3)
                results[name][f"{table}_samples_ms"] = samples
        return results

    def run(self) -> dict[str, object]:
        self.prepare()
        expected = expected_row_count(self.args.participants, self.args.days)
        ingestion: dict[str, object] = {}
        for table in ("benchmark_postgres", "benchmark_timescale"):
            rows, seconds = self.load(table)
            if rows != expected:
                raise RuntimeError(f"{table} loaded {rows} rows, expected {expected}")
            ingestion[table] = {
                "rows": rows,
                "seconds": round(seconds, 3),
                "rows_per_second": round(rows / seconds, 1),
            }

        timescale_before, compressed_chunks, compression_seconds = self.compress()
        sizes = {
            "benchmark_postgres": int(self.sql("SELECT pg_total_relation_size('benchmark_postgres')")),
            "benchmark_timescale_before_compression": timescale_before,
            "benchmark_timescale": int(self.sql("SELECT hypertable_size('benchmark_timescale')")),
        }
        average_payload = float(self.sql("SELECT avg(octet_length(resource::text)) FROM benchmark_postgres"))
        return {
            "configuration": {
                "participants": self.args.participants,
                "days": self.args.days,
                "start": self.args.start,
                "payload_bytes_target": self.args.payload_bytes,
                "warmups": self.args.warmups,
                "runs": self.args.runs,
                "expected_rows": expected,
            },
            "database": {
                "postgres_version": self.sql("SHOW server_version"),
                "timescaledb_version": self.sql(
                    "SELECT extversion FROM pg_extension WHERE extname = 'timescaledb'"
                ),
            },
            "ingestion": ingestion,
            "storage_bytes": sizes,
            "average_resource_bytes": round(average_payload, 1),
            "compression": {
                "chunks": compressed_chunks,
                "seconds": round(compression_seconds, 3),
                "queries_measured_after_manual_compression": True,
            },
            "query_median_ms": self.measure_queries(),
        }


def markdown(results: dict[str, object]) -> str:
    ingestion = results["ingestion"]
    storage = results["storage_bytes"]
    queries = results["query_median_ms"]
    assert isinstance(ingestion, dict) and isinstance(storage, dict) and isinstance(queries, dict)
    postgres_ingest = ingestion["benchmark_postgres"]["rows_per_second"]
    timescale_ingest = ingestion["benchmark_timescale"]["rows_per_second"]
    postgres_gib = storage["benchmark_postgres"] / 2**30
    timescale_gib = storage["benchmark_timescale"] / 2**30
    lines = [
        "## Timescale benchmark",
        "",
        "| Metric | PostgreSQL | TimescaleDB |",
        "| --- | ---: | ---: |",
        f"| Ingest throughput (rows/s) | {postgres_ingest:,.1f} | {timescale_ingest:,.1f} |",
        f"| On-disk size (GiB) | {postgres_gib:.3f} | {timescale_gib:.3f} |",
    ]
    for name, values in queries.items():
        label = name.replace("_", " ").capitalize()
        lines.append(
            f"| {label} (median ms) | {values['benchmark_postgres']:.3f} | {values['benchmark_timescale']:.3f} |"
        )
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--participants", type=int, default=200)
    parser.add_argument("--days", type=int, default=30)
    parser.add_argument("--start", default="2025-01-01T00:00:00Z")
    parser.add_argument("--payload-bytes", type=int, default=2560)
    parser.add_argument("--warmups", type=int, default=2)
    parser.add_argument("--runs", type=int, default=20)
    parser.add_argument("--database-user", default="trove")
    parser.add_argument("--database-name", default="trove")
    parser.add_argument("--env-file", default=".env.example")
    parser.add_argument("--output", type=Path, default=Path("benchmark-results.json"))
    args = parser.parse_args()
    if min(args.participants, args.days, args.runs) < 1 or args.warmups < 0 or args.payload_bytes < 512:
        parser.error(
            "participants, days, and runs must be positive; warmups cannot be negative; "
            "payload-bytes must be at least 512"
        )

    results = Benchmark(args).run()
    args.output.write_text(json.dumps(results, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    summary_path = args.output.with_suffix(".md")
    summary_path.write_text(markdown(results), encoding="utf-8")
    print(markdown(results))
    print(f"Detailed samples: {args.output}")


if __name__ == "__main__":
    main()
