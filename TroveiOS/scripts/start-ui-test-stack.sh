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
server_client_secret="${TROVE_UI_TEST_SERVER_CLIENT_SECRET:-dev-server-secret}"
mkdir -p "$runtime_directory" "$KEYCLOAK_HOME/data/import"
jq --arg server_client_secret "$server_client_secret" '
    [
        .clients[]
        | select(.clientId == "trove-server")
    ] as $server_clients
    | [
        .clientScopes[]?
        | select(.name == "groups")
    ] as $group_scopes
    | if ($server_clients | length) != 1 then
        error("Expected exactly one trove-server client")
      elif ($group_scopes | length) != 1 then
        error("Expected exactly one groups client scope")
      else
        ($group_scopes[0].protocolMappers // []) as $group_mappers
        | del(.clientScopes)
        | .clients |= map(
            .defaultClientScopes = ((.defaultClientScopes // []) | map(select(. != "groups")))
            | .protocolMappers = ((.protocolMappers // []) + $group_mappers)
          )
        | (.clients[] | select(.clientId == "trove-server") | .secret) = $server_client_secret
      end
' TroveInfrastructure/docker/keycloak/realm.json \
    > "$KEYCLOAK_HOME/data/import/trove-realm.json"

keycloak_log="$runtime_directory/keycloak.log"
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

if ! curl --fail-with-body --silent --show-error \
    --request POST http://127.0.0.1:8180/realms/trove/protocol/openid-connect/token \
    --header 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode 'grant_type=client_credentials' \
    --data-urlencode 'client_id=trove-server' \
    --data-urlencode "client_secret=$server_client_secret" \
    > /dev/null; then
    echo "The imported trove-server client credentials are invalid." >&2
    tail -n 200 "$keycloak_log" >&2
    exit 1
fi

authorization_response="$runtime_directory/authorization.html"
if ! curl --fail-with-body --silent --show-error --get \
    http://127.0.0.1:8180/realms/trove/protocol/openid-connect/auth \
    --data-urlencode 'client_id=trove-app' \
    --data-urlencode 'redirect_uri=trove://callback' \
    --data-urlencode 'response_type=code' \
    --data-urlencode 'scope=openid profile email' \
    --data-urlencode 'code_challenge=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' \
    --data-urlencode 'code_challenge_method=S256' \
    --output "$authorization_response"; then
    echo "The trove-app authorization endpoint rejected the configured OIDC scopes." >&2
    tail -n 200 "$keycloak_log" >&2
    exit 1
fi
if ! grep --quiet 'id="username"' "$authorization_response"; then
    echo "The trove-app authorization endpoint did not return the login form." >&2
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
        KEYCLOAK_CLIENT_SECRET="$server_client_secret" \
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
