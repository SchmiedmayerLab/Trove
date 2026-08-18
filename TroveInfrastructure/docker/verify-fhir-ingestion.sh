#!/bin/bash
#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8180}"
SERVER_URL="${SERVER_URL:-http://127.0.0.1:8080/api/v0}"
REALM="${KEYCLOAK_REALM:-trove}"
DEV_CLIENT="${KEYCLOAK_DEV_CLIENT:-trove-dev-cli}"
DEV_PASSWORD="${KEYCLOAK_DEV_PASSWORD:?KEYCLOAK_DEV_PASSWORD is required}"
DEV_USER="${KEYCLOAK_DEV_USER:-alice@example.com}"
environment_file="${TROVE_ENV_FILE:-.env}"
OBSERVATION_TIME="2026-08-17T18:30:00Z"
run_identity="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-$$-$(date +%s)}"
OBSERVATION_CODE="trove-timescale-round-trip-$run_identity"

token="$({
    curl --fail-with-body --silent --show-error \
        --request POST "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token" \
        --header 'Content-Type: application/x-www-form-urlencoded' \
        --data-urlencode 'grant_type=password' \
        --data-urlencode "client_id=$DEV_CLIENT" \
        --data-urlencode "username=$DEV_USER" \
        --data-urlencode "password=$DEV_PASSWORD"
} | jq --raw-output '.access_token')"
[ -n "$token" ] && [ "$token" != "null" ] || { echo "Could not obtain a participant token" >&2; exit 1; }

profile_status="$(
    curl --silent --output /dev/null --write-out '%{http_code}' \
        --header "Authorization: Bearer $token" \
        "$SERVER_URL/participant/profile"
)"
if [ "$profile_status" = "404" ]; then
    curl --fail-with-body --silent --show-error \
        --request POST "$SERVER_URL/participant/profile" \
        --header "Authorization: Bearer $token" \
        --header 'Content-Type: application/json' \
        --data '{"firstName":"Timescale","lastName":"Verifier","gender":"preferNotToState","dateOfBirth":"1990-01-01","region":"US","language":"en-US","phoneNumber":"+16505550123"}' \
        > /dev/null
elif [ "$profile_status" != "200" ]; then
    echo "Unexpected participant profile status: $profile_status" >&2
    exit 1
fi

jq --null-input \
    --arg code "$OBSERVATION_CODE" \
    --arg time "$OBSERVATION_TIME" \
    '{
        resourceType: "Observation",
        id: $code,
        status: "final",
        code: {coding: [{system: "http://loinc.org", code: $code}]},
        effectiveDateTime: $time,
        valueQuantity: {
            value: 73.25,
            unit: "beats/minute",
            system: "http://unitsofmeasure.org",
            code: "/min"
        }
    }' \
    | curl --fail-with-body --silent --show-error \
        --request POST "$SERVER_URL/participant/fhir/resource" \
        --header "Authorization: Bearer $token" \
        --header 'Content-Type: application/json' \
        --data-binary @- \
        > /dev/null

set -a
# shellcheck disable=SC1090
source "$environment_file"
set +a

matching_records="$(
    docker compose exec -T server-timescale \
        psql --username "$TIMESCALE_USERNAME" --dbname "$TIMESCALE_NAME" \
            --set ON_ERROR_STOP=1 --set observation_code="$OBSERVATION_CODE" \
            --tuples-only --no-align <<'SQL'
SELECT count(*)
    FROM fhir_resources
    WHERE external_id = :'observation_code'
      AND resource_type = 'Observation'
      AND code = :'observation_code'
      AND code_system = 'http://loinc.org'
      AND value = 73.25
      AND value_code = '/min'
      AND value_system = 'http://unitsofmeasure.org'
      AND resource ->> 'resourceType' = resource_type
      AND resource #>> '{code,coding,0,code}' = code
      AND resource #>> '{code,coding,0,system}' = code_system
      AND (resource #>> '{valueQuantity,value}')::double precision = value;
SQL
)"

if [ "$matching_records" != "1" ]; then
    echo "Expected one matching authenticated FHIR ingestion record, got $matching_records" >&2
    exit 1
fi

echo "Verified authenticated FHIR ingestion directly in Timescale."
