<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Docker Local Development

Local development environment for Trove. The server uses one PostgreSQL 18/Timescale
authority; Keycloak retains its separate identity database. Images and application
schema must come from the same reviewed revision.

Used by:

- [Trove-Server](https://github.com/SchmiedmayerLab/Trove)
- [Trove-Web](https://github.com/SchmiedmayerLab/Trove)

## Setup

Build both application images from the same checkout. From the repository root:

```bash
docker build -f TroveServer/Dockerfile -t ghcr.io/schmiedmayerlab/trove-server:main .
docker build -f TroveWeb/Dockerfile -t ghcr.io/schmiedmayerlab/trove-web:main .
```

Then, from `TroveInfrastructure/docker`:

```bash
cp .env.example .env
docker compose run --rm source-keyring-init
```

The initialization command creates the encryption keyring once in the
`source_identity_keys` volume, owned by the same non-root user as the server. It
refuses to overwrite an existing file. Normal startup mounts this volume read-only
and never generates a replacement. Retain and back up the keyring together with
the database; recreating the server container must reuse both volumes. Do not rerun
initialization against retained data if the keyring is lost; restore its backup.

## Full Stack

For a fresh development database. The pinned database image initializes Timescale on the
volume; server startup validates the extension and never installs it.

Normal startup runs the database, schema creation, restricted-role grants and server
in that order. The running server receives only the runtime credential. All values in
`.env.example` are synthetic development credentials; supply independent secrets for
any non-disposable environment and never commit `.env`.

```bash
docker compose up -d
```

The base stack does not include the FHIR validator. Event admission fails closed
with HTTP 503 until the [validator overlay](../validator/README.md) is configured
with the reviewed image and expected identity. Study authoring and enrollment do
not require that worker.

| Service        | URL                         |
| -------------- | --------------------------- |
| Web            | http://localhost:3000       |
| Server         | http://localhost:8080       |
| Keycloak       | http://localhost:8180       |
| Keycloak Admin | http://localhost:8180/admin |
| Server DB      | localhost:5432              |
| S3 (SeaweedFS) | http://localhost:8333       |

Published development ports bind only to `127.0.0.1`. SeaweedFS master and filer
ports remain private to the Compose network; its health check waits for the S3
endpoint. These synthetic credentials and plaintext local connections are not a
remote-device or production deployment configuration.

## Backing Services Only

For running server or web natively:

```bash
docker compose up -d server-db keycloak-db keycloak keycloak-config-cli seaweedfs
docker compose run --rm server-grants
```

Then run server/web against localhost ports. Configure `DATABASE_*` for the server
connection and `SOURCE_IDENTITY_KEYRING_FILE` for its keyring, as described in the
[server documentation](../../TroveServer/README.md#participant-data-sources). The
`keycloak-config-cli` job imports the realm, and SeaweedFS supplies local object storage.

## Development Database Lifecycle

`server_authority_data` is mounted at `/pgdata`. Schema changes update the initial
table definitions; there are no data upgrade migrations.
Recreate the explicitly identified disposable development database after such a change.
Verify the Compose project and volume before removing it; resetting the application
database need not delete Keycloak identities or object-storage data. The setup never
automatically deletes volumes or attaches an old data directory to a different image.

After initialization, `./verify-timescale.sh` checks Timescale and the current schema.
`./verify-fhir-ingestion.sh` verifies that authenticated and anonymous requests to
`/participant/fhir/resource` receive 404. It does not test the event receiver. The [bounded event receiver](../../TroveServer/README.md) has separate
[full-validator verification](../validator/README.md).

## Schema Initialization

Run on their own against an already-running stack:

```bash
docker compose run --rm server-migrate
docker compose run --rm server-grants
```

The `server-migrate` service creates the schema and Fluent history in one transaction.
It rejects competing initializers immediately; retry after the active operator finishes.
Failure rolls back schema and history, and connection loss releases the lock. The
transaction is limited to two minutes, each statement to one minute and database-lock
waits to 15 seconds. It does not migrate previous development schemas, verify their
equivalence or import legacy records. Recreate disposable databases after schema changes;
reversion is unsupported. Schema creation and grants use `DATABASE_OPERATOR_*`;
the server uses `DATABASE_*`.
The [shared operator scripts](../database-operator/README.md) contain the explicit
grant list for the study, source identity, clinical, recording, reconciliation and
provider tables, audit append/read, and one fixed Boolean preload check. It grants no
schema creation, role membership or migration-ledger mutation, and no deletion of
provider records. New tables require a reviewed grant-list update; there
is no blanket future-table grant. Keep operator credentials out of the server process.
Existing owner or privileged roles are rejected rather than silently converted.

## Test Users

All passwords: `password123`

| Email              | Role        |
| ------------------ | ----------- |
| leland@example.com | admin       |
| jane@example.com   | researcher  |
| alice@example.com  | participant |

## Keycloak Admin

Username: `admin`, password: `admin` (configurable in `.env`)

## Reset

Only for disposable local fixtures; this deletes this Compose project's declared data:

```bash
docker compose down -v
```
