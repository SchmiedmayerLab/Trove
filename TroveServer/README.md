<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Server

The Vapor backend: a REST API for studies, components, schedules, and enrollments. It conforms to the generated `APIProtocol` from [`TroveAPI/`](../TroveAPI), takes its study configuration types from `GroveStudyDefinition`, and exposes Grove's module system to route handlers through the local `GroveVapor` target.

## Getting started

1. Copy the environment file: `cp .env.example .env`
2. Start PostgreSQL and Keycloak from [`TroveInfrastructure/docker`](../TroveInfrastructure/docker)
3. Run the migrations and start the server:

```bash
swift run --package-path TroveServer TroveServer migrate --yes
swift run --package-path TroveServer TroveServer serve
```

## Commands

| Task | Swift | Docker Compose |
| ---- | ----- | -------------- |
| Run the server | `swift run TroveServer serve` | `docker compose up app` |
| Run migrations | `swift run TroveServer migrate --yes` | `docker compose run migrate` |
| Revert the last migration | `swift run TroveServer migrate --revert --yes` | `docker compose run revert` |

The Docker Compose `app` service requires `docker compose build` first.

## Tests

```bash
swift test --package-path TroveServer --no-parallel
```

Parallelism is off because the integration suites share one in-memory SQLite database per suite. Tests sign their own JWTs, so no Docker services are needed.

## Bruno

Request collections live in `tools/bruno/`, for the [Bruno](https://www.usebruno.com) API client. Select the **Trove** environment to load the variables. The **Seed** request bootstraps a working dataset — it logs in through Keycloak, fetches groups, creates a study, and adds sample components, passing IDs between requests through post-response scripts.

## Architecture

```
Sources/TroveServer/
├── App/              # Application bootstrap and configuration
├── Modules/          # Feature modules (Study, Component, etc.)
├── Models/           # Fluent database models
├── Migrations/       # Database migrations
└── Core/             # Shared infrastructure
```

Each module carries its own controller, service, repository, and mapper.
