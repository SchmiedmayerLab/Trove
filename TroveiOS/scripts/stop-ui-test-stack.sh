#!/bin/bash
#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

set -euo pipefail

stop_process() {
    local name="$1"
    local pid="$2"

    if [ -z "$pid" ] || ! kill -0 "$pid" 2> /dev/null; then
        return
    fi

    kill "$pid"
    for _ in {1..30}; do
        if ! kill -0 "$pid" 2> /dev/null; then
            return
        fi
        sleep 1
    done

    echo "$name did not stop gracefully; terminating it." >&2
    kill -KILL "$pid"
}

stop_process "Trove server" "${TROVE_SERVER_PID:-}"
stop_process "Keycloak" "${TROVE_KEYCLOAK_PID:-}"
