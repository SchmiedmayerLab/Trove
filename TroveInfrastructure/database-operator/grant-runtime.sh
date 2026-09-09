#!/bin/bash
# This source file is part of the Trove open-source project
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

set -euo pipefail
: "${PGUSER:?An operator login is required}"
: "${PGDATABASE:?The authority database is required}"
: "${PGPASSWORD:?The operator password is required}"
: "${DATABASE_USERNAME:?The runtime login is required}"
: "${DATABASE_PASSWORD:?The runtime password is required}"
if [[ ! "$DATABASE_USERNAME" =~ ^[a-z_][a-z0-9_]{0,62}$ || "$DATABASE_USERNAME" == "$PGUSER" ]]; then
    echo "A distinct, lowercase runtime role identifier is required" >&2
    exit 1
fi
if [[ "$DATABASE_PASSWORD" == "$PGPASSWORD" ]]; then
    echo "Operator and runtime passwords must be distinct" >&2
    exit 1
fi
if [[ ${#DATABASE_PASSWORD} -lt 16 || ${#DATABASE_PASSWORD} -gt 1024 || "$DATABASE_PASSWORD" == *$'\n'* || "$DATABASE_PASSWORD" == *$'\r'* ]]; then
    echo "The runtime password must be 16–1024 characters without line breaks" >&2
    exit 1
fi

script_dir=$(cd "$(dirname "$0")" && pwd)
psql -X --no-password --set ON_ERROR_STOP=1 --file "$script_dir/grant-runtime.sql"
# psql hashes this password client-side; neither plaintext SQL nor command arguments contain it.
printf '%s\n%s\n' "$DATABASE_PASSWORD" "$DATABASE_PASSWORD" \
    | psql -X --no-password --set ON_ERROR_STOP=1 --command "\\password $DATABASE_USERNAME"
psql -X --no-password --set ON_ERROR_STOP=1 --command "ALTER ROLE \"$DATABASE_USERNAME\" LOGIN"
echo "Provisioned the restricted application login."
