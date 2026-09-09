#!/bin/bash
# This source file is part of the Trove open-source project
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

set -euo pipefail
environment_file="${TROVE_ENV_FILE:-.env}"
set -a
# shellcheck disable=SC1090
source "$environment_file"
set +a

docker compose exec -T server-db sh -c \
    'PGPASSWORD="$POSTGRES_PASSWORD" exec psql -X -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" --set ON_ERROR_STOP=1' <<'SQL'
DO $verify$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'timescaledb') THEN
        RAISE EXCEPTION 'The authoritative database requires operator-installed TimescaleDB';
    END IF;
    IF (SELECT count(*) FROM _fluent_migrations) <> 13
       OR (SELECT count(DISTINCT name) FROM _fluent_migrations WHERE name IN (
        'TroveServer.CreateGroups', 'TroveServer.CreateStudy', 'TroveServer.CreateComponents',
        'TroveServer.CreateComponentSchedules', 'TroveServer.CreateStoredArtifacts',
        'TroveServer.CreatePublishedStudies', 'TroveServer.CreateParticipants', 'TroveServer.CreateSourceBindings',
        'TroveServer.CreateInvitationCodes', 'TroveServer.CreateEnrollments',
        'TroveServer.CreateEnrollmentConsents', 'TroveServer.CreateAuditEvents', 'TroveServer.CreateClinicalEvents'
    )) <> 13 THEN
        RAISE EXCEPTION 'The database schema is incomplete';
    END IF;
    IF to_regclass('public.fhir_resources') IS NOT NULL
       OR EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'legacy_custody') THEN
        RAISE EXCEPTION 'This development setup requires a fresh database';
    END IF;
END
$verify$;
SQL

echo "Verified TimescaleDB and the fresh application schema."
