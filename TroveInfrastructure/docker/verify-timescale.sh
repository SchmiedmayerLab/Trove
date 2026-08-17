#!/bin/bash
#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

set -euo pipefail

environment_file="${TROVE_ENV_FILE:-.env}"
set -a
# shellcheck disable=SC1090
source "$environment_file"
set +a

docker compose exec -T server-timescale \
    psql --username "$TIMESCALE_USERNAME" --dbname "$TIMESCALE_NAME" --set ON_ERROR_STOP=1 <<'SQL'
DO $verify$
DECLARE
    actual_chunk_interval interval;
    actual_segment_by text;
    actual_order_by text;
    matching_policies integer;
BEGIN
    SELECT time_interval
    INTO actual_chunk_interval
    FROM timescaledb_information.dimensions
    WHERE hypertable_schema = 'public'
      AND hypertable_name = 'fhir_resources'
      AND column_name = 'time';

    IF actual_chunk_interval IS DISTINCT FROM INTERVAL '7 days' THEN
        RAISE EXCEPTION 'Expected a seven-day fhir_resources time dimension, got %', actual_chunk_interval;
    END IF;

    SELECT string_agg(attname, ', ' ORDER BY segmentby_column_index)
    INTO actual_segment_by
    FROM timescaledb_information.compression_settings
    WHERE hypertable_schema = 'public'
      AND hypertable_name = 'fhir_resources'
      AND segmentby_column_index IS NOT NULL;

    IF actual_segment_by IS DISTINCT FROM 'participant_id, resource_type, code_system, code' THEN
        RAISE EXCEPTION 'Unexpected fhir_resources compression segments: %', actual_segment_by;
    END IF;

    SELECT string_agg(
        attname || CASE WHEN orderby_asc THEN ' ASC' ELSE ' DESC' END,
        ', ' ORDER BY orderby_column_index
    )
    INTO actual_order_by
    FROM timescaledb_information.compression_settings
    WHERE hypertable_schema = 'public'
      AND hypertable_name = 'fhir_resources'
      AND orderby_column_index IS NOT NULL;

    IF actual_order_by IS DISTINCT FROM 'time DESC' THEN
        RAISE EXCEPTION 'Unexpected fhir_resources compression order: %', actual_order_by;
    END IF;

    SELECT count(*)
    INTO matching_policies
    FROM timescaledb_information.jobs
    WHERE hypertable_schema = 'public'
      AND hypertable_name = 'fhir_resources'
      AND config ->> 'compress_after' = '7 days';

    IF matching_policies != 1 THEN
        RAISE EXCEPTION 'Expected one seven-day fhir_resources compression policy, got %', matching_policies;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM timescaledb_information.hypertables
        WHERE hypertable_schema = 'public'
          AND hypertable_name = 'fhir_resources'
          AND compression_enabled
    ) THEN
        RAISE EXCEPTION 'fhir_resources is not a compression-enabled hypertable';
    END IF;
END
$verify$;
SQL

echo "Verified the fhir_resources Timescale hypertable, compression settings, and policy."
