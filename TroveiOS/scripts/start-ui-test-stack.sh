#!/bin/bash
#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

set -euo pipefail

: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${KEYCLOAK_HOME:?KEYCLOAK_HOME is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"

runtime_directory="$RUNNER_TEMP/trove-ui-test-stack"
mkdir -p "$runtime_directory" "$KEYCLOAK_HOME/data/import"
cp TroveInfrastructure/docker/keycloak/realm.json "$KEYCLOAK_HOME/data/import/trove-realm.json"

keycloak_log="$runtime_directory/keycloak.log"
SERVER_CLIENT_SECRET=dev-server-secret \
KC_BOOTSTRAP_ADMIN_USERNAME=admin \
KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
    "$KEYCLOAK_HOME/bin/kc.sh" start-dev \
        --health-enabled=true \
        --http-port=8180 \
        --import-realm \
        > "$keycloak_log" 2>&1 &
keycloak_pid=$!
echo "TROVE_KEYCLOAK_PID=$keycloak_pid" >> "$GITHUB_ENV"

for _ in {1..120}; do
    if curl --fail --silent http://127.0.0.1:8180/realms/trove > /dev/null; then
        break
    fi
    if ! kill -0 "$keycloak_pid" 2> /dev/null; then
        echo "Keycloak exited before the Trove realm became ready." >&2
        tail -n 200 "$keycloak_log" >&2
        exit 1
    fi
    sleep 2
done

if ! curl --fail --silent http://127.0.0.1:8180/realms/trove > /dev/null; then
    echo "Keycloak did not become ready before the timeout." >&2
    tail -n 200 "$keycloak_log" >&2
    exit 1
fi

server_log="$runtime_directory/server.log"
(
    cd TroveServer
    exec env \
        APP_ENVIRONMENT=development \
        TROVE_UI_TEST_MODE=true \
        KEYCLOAK_URL=http://127.0.0.1:8180 \
        KEYCLOAK_REALM=trove \
        KEYCLOAK_CLIENT_ID=trove-server \
        KEYCLOAK_CLIENT_SECRET=dev-server-secret \
        KEYCLOAK_RESEARCHER_ROLE=trove-researcher \
        KEYCLOAK_PARTICIPANT_ROLE=trove-participant \
        swift run TroveServer serve \
            --env testing \
            --hostname 0.0.0.0 \
            --port 8080
) > "$server_log" 2>&1 &
server_pid=$!
echo "TROVE_SERVER_PID=$server_pid" >> "$GITHUB_ENV"

for _ in {1..300}; do
    if curl --fail --silent http://127.0.0.1:8080/api/v0/health > /dev/null; then
        echo "Native UI-test stack is ready."
        exit 0
    fi
    if ! kill -0 "$server_pid" 2> /dev/null; then
        echo "The server exited before becoming ready." >&2
        tail -n 200 "$server_log" >&2
        exit 1
    fi
    sleep 2
done

echo "The server did not become ready before the timeout." >&2
tail -n 200 "$server_log" >&2
exit 1
