#!/bin/sh

#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

set -eu

# Select only a fixed, reviewed configuration. An unset or unknown mode cannot
# silently enable plaintext; the image defaults to production.
case "${APP_ENVIRONMENT:-}" in
  production|development) ;;
  *) echo 'APP_ENVIRONMENT must be production or development' >&2; exit 1 ;;
esac
cp "/etc/nginx/trove-transport/$APP_ENVIRONMENT.conf" /var/cache/nginx/transport.conf

# Validate required environment variables.
: "${VITE_API_BASE_PATH:?VITE_API_BASE_PATH is required}"
: "${VITE_KEYCLOAK_URL:?VITE_KEYCLOAK_URL is required}"
: "${VITE_KEYCLOAK_REALM:?VITE_KEYCLOAK_REALM is required}"
: "${VITE_KEYCLOAK_CLIENT_ID:?VITE_KEYCLOAK_CLIENT_ID is required}"

# Escape backslashes, double quotes, and newlines to produce valid JS string literals.
esc() {
  printf '%s' "$1" \
    | sed -e 's/\\/\\\\/g' \
          -e 's/"/\\"/g' \
          -e 's/\r/\\r/g' \
          -e ':a' -e 'N' -e '$!ba' -e 's/\n/\\n/g'
}

cat > /var/cache/nginx/env.js <<EOF
window.__ENV__ = {
  VITE_API_BASE_PATH: "$(esc "$VITE_API_BASE_PATH")",
  VITE_KEYCLOAK_URL: "$(esc "$VITE_KEYCLOAK_URL")",
  VITE_KEYCLOAK_REALM: "$(esc "$VITE_KEYCLOAK_REALM")",
  VITE_KEYCLOAK_CLIENT_ID: "$(esc "$VITE_KEYCLOAK_CLIENT_ID")"
};
EOF

exec "$@"
