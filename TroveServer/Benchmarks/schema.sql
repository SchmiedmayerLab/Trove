-- This source file is part of the Trove open-source project
-- SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
-- SPDX-License-Identifier: MIT

\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS timescaledb;

DROP TABLE IF EXISTS benchmark_timescale;
DROP TABLE IF EXISTS benchmark_postgres;

CREATE TABLE benchmark_postgres (
    participant_id UUID NOT NULL,
    resource_type TEXT NOT NULL,
    time TIMESTAMPTZ NOT NULL,
    external_id TEXT NOT NULL,
    code TEXT,
    code_system TEXT,
    value DOUBLE PRECISION,
    value_code TEXT,
    value_system TEXT,
    resource JSONB NOT NULL,
    PRIMARY KEY (participant_id, time, external_id)
);

CREATE INDEX benchmark_postgres_participant_type_code_time
    ON benchmark_postgres (participant_id, resource_type, code_system, code, time DESC);

CREATE TABLE benchmark_timescale (LIKE benchmark_postgres INCLUDING ALL);

SELECT create_hypertable(
    'benchmark_timescale',
    'time',
    chunk_time_interval => INTERVAL '7 days'
);

ALTER TABLE benchmark_timescale SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'participant_id, resource_type, code_system, code',
    timescaledb.compress_orderby = 'time DESC'
);
