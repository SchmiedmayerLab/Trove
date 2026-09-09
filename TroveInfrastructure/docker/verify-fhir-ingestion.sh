#!/bin/bash
# This source file is part of the Trove open-source project
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

# The old ingestion path is retired. This check must never become an ingestion bypass.
set -euo pipefail
KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8180}"
SERVER_URL="${SERVER_URL:-http://127.0.0.1:8080/api/v0}"
REALM="${KEYCLOAK_REALM:-trove}"
DEV_CLIENT="${KEYCLOAK_DEV_CLIENT:-trove-dev-cli}"
DEV_PASSWORD="${KEYCLOAK_DEV_PASSWORD:?KEYCLOAK_DEV_PASSWORD is required}"
DEV_USER="${KEYCLOAK_DEV_USER:-alice@example.com}"

token="$(curl --fail --silent --show-error \
    --request POST "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token" \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=password' --data-urlencode "client_id=$DEV_CLIENT" \
    --data-urlencode "username=$DEV_USER" --data-urlencode "password=$DEV_PASSWORD" | jq --exit-status --raw-output '.access_token // empty')"
[ -n "$token" ] || { echo "Could not obtain a participant token" >&2; exit 1; }

for authentication in authenticated anonymous; do
    headers=(--header 'Content-Type: application/json')
    if [[ "$authentication" == authenticated ]]; then headers+=(--header "Authorization: Bearer $token"); fi
    status="$(curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
        --request POST "$SERVER_URL/participant/fhir/resource" "${headers[@]}" \
        --data '{"resourceType":"Observation","status":"final","code":{"text":"retired-route-check"}}')"
    if [[ "$status" != 404 ]]; then
        echo "Retired ingestion route unexpectedly returned $status ($authentication)" >&2
        exit 1
    fi
done

echo "Verified authenticated and anonymous requests cannot use the retired clinical ingestion route."
