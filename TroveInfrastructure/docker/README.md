<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Docker Local Development

Local development environment for the Trove. Provides backing services (PostgreSQL, Keycloak) and optionally runs the full stack using published container images.

Used by:

- [Trove-Server](https://github.com/SchmiedmayerLab/Trove)
- [Trove-Web](https://github.com/SchmiedmayerLab/Trove)

## Setup

```bash
cp .env.example .env
```

## Full Stack

Apply the migrations first: the server syncs the Keycloak groups on boot and exits if the schema
is not there yet. Running the migration starts the backing services it needs.

```bash
docker compose run --rm server-migrate
docker compose up -d
```

| Service        | URL                         |
| -------------- | --------------------------- |
| Web            | http://localhost:3000       |
| Server         | http://localhost:8080       |
| Keycloak       | http://localhost:8180       |
| Keycloak Admin | http://localhost:8180/admin |
| Server DB      | localhost:5432              |
| Server Timescale | localhost:5433            |
| S3 (SeaweedFS) | http://localhost:8333       |

## Backing Services Only

For running server or web natively:

```bash
docker compose up -d server-db server-timescale keycloak-db keycloak keycloak-config-cli seaweedfs
```

Then run server/web from their repos against localhost ports. This starts everything the server needs: the databases, the `seaweedfs` S3 object storage (`localhost:8333`), Keycloak, and the `keycloak-config-cli` job that imports the `trove` realm (without it, the server fails with "Realm does not exist").

## Migrations

Run on their own against an already-running stack:

```bash
docker compose run --rm server-migrate
```

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

```bash
docker compose down -v
```
