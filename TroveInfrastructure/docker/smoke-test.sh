#!/bin/bash
#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

# Verifies the local development stack end to end: the backing services come up healthy,
# the migrations apply, and the server answers an authenticated request with data it
# synced from Keycloak. Run from TroveInfrastructure/docker after `docker compose up -d`.

set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8180}"
SERVER_URL="${SERVER_URL:-http://127.0.0.1:8080}"
REALM="${KEYCLOAK_REALM:-trove}"
DEV_CLIENT="${KEYCLOAK_DEV_CLIENT:-trove-dev-cli}"
DEV_USER="${KEYCLOAK_DEV_USER:-leland@example.com}"
DEV_PASSWORD="${KEYCLOAK_DEV_PASSWORD:-password123}"
TIMEOUT="${SMOKE_TEST_TIMEOUT:-180}"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

wait_for() {
    local label="$1" url="$2" elapsed=0
    until curl -fsS -o /dev/null "$url" 2>/dev/null; do
        [ "$elapsed" -ge "$TIMEOUT" ] && fail "$label did not become available within ${TIMEOUT}s"
        sleep 3
        elapsed=$((elapsed + 3))
    done
    echo "ok: $label is reachable"
}

# A protected endpoint answers 401 rather than 2xx, so readiness is "it responded at all".
wait_for_response() {
    local label="$1" url="$2" elapsed=0
    until [ "$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)" != "000" ]; do
        [ "$elapsed" -ge "$TIMEOUT" ] && fail "$label did not become available within ${TIMEOUT}s"
        sleep 3
        elapsed=$((elapsed + 3))
    done
    echo "ok: $label is responding"
}

echo "== backing services"
services=$(docker compose ps --services --filter status=running)
for required in server-db server-timescale keycloak seaweedfs; do
    echo "$services" | grep -qx "$required" || fail "$required is not running"
done

# A container that reports unhealthy still serves traffic, so assert health explicitly:
# this is what caught the seaweedfs probe resolving localhost to IPv6.
for container in $(docker compose ps -q); do
    name=$(docker inspect "$container" --format '{{.Name}}')
    health=$(docker inspect "$container" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')
    [ "$health" = "unhealthy" ] && fail "$name is unhealthy"
    echo "ok: $name is $health"
done

echo "== keycloak realm"
wait_for "keycloak realm '$REALM'" "$KEYCLOAK_URL/realms/$REALM/.well-known/openid-configuration"

echo "== server"
wait_for_response "server" "$SERVER_URL/api/v0/groups"
status=$(curl -s -o /dev/null -w '%{http_code}' "$SERVER_URL/api/v0/groups")
[ "$status" = "401" ] || fail "unauthenticated /api/v0/groups returned $status, expected 401"
echo "ok: unauthenticated requests are rejected"

echo "== authentication"
token=$(curl -fsS -X POST "$KEYCLOAK_URL/realms/$REALM/protocol/openid-connect/token" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -d 'grant_type=password' \
    -d "client_id=$DEV_CLIENT" \
    -d "username=$DEV_USER" \
    -d "password=$DEV_PASSWORD" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')
[ -n "$token" ] || fail "could not obtain a token for $DEV_USER"
echo "ok: obtained an access token"

groups=$(curl -fsS -H "Authorization: Bearer $token" "$SERVER_URL/api/v0/groups")
echo "$groups" | python3 -c '
import json, sys
groups = json.load(sys.stdin)
if not groups:
    raise SystemExit("the server returned no groups, so the Keycloak group sync did not run")
for group in groups:
    for key in ("id", "name"):
        if key not in group:
            raise SystemExit(f"group is missing {key}: {group}")
print(f"ok: the server returned {len(groups)} group(s) synced from Keycloak")
'

echo
echo "The development stack is wired up correctly."
