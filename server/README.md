<!--

This source file is part of the StudyPlatform open-source project

SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT

-->

# StudyPlatform Server

[![CI](https://github.com/SchmiedmayerLab/StudyPlatform/actions/workflows/server.yml/badge.svg)](https://github.com/SchmiedmayerLab/StudyPlatform/actions/workflows/server.yml)

> **StudyPlatform** is an open-source, end-to-end platform for running research studies: researchers author studies in the [web portal](../web), those definitions configure the participant [iOS app](../ios), and a Vapor server with a shared [OpenAPI contract](../api) ties it together, deployed via [GitOps infrastructure](../infrastructure). See the [monorepo overview](../README.md) for the full picture.

**This package** is the Vapor backend: a REST API for managing clinical research studies, including:

- **Studies** — create and manage study definitions with metadata
- **Components** — configure study components (questionnaires, health data collection, informational content)
- **Schedules** — define when components should be presented to participants

It conforms to the generated `APIProtocol` from the shared [`api/`](../api) package and integrates with [SpeziStudy](https://github.com/StanfordSpezi/SpeziStudy) for study configuration types and [SpeziVapor](https://github.com/StanfordSpezi/SpeziVapor) for dependency injection.

## Requirements

- Swift 6.0+
- Docker

## Getting Started

To run the server locally, follow these steps:

1. Create a `.env` file:
   ```bash
   cp .env.example .env
   ```
2. Start the backing services (PostgreSQL, Keycloak) using the Docker Compose setup in [`infrastructure/docker`](../infrastructure/docker).
3. Run the database migrations:
   ```bash
   swift run StudyPlatformServer migrate --yes
   ```
4. Start the server:
   ```bash
   swift run StudyPlatformServer serve
   ```

## Commands

| Task | Swift | Docker Compose |
| ---- | ----- | -------------- |
| Run the server | `swift run StudyPlatformServer serve` | `docker compose up app` |
| Run migrations | `swift run StudyPlatformServer migrate --yes` | `docker compose run migrate` |
| Revert the last migration | `swift run StudyPlatformServer migrate --revert --yes` | `docker compose run revert` |

The Docker Compose `app` service requires `docker compose build` first.

## Run Tests

```bash
swift test --no-parallel
```

Tests must run without parallelism (`--no-parallel`) because integration test suites share an in-memory SQLite database per suite. Tests use mock JWT signing, so no Docker services are required.

## Bruno

API request collections are available in `tools/bruno/`. [Bruno](https://www.usebruno.com) is an open-source API client. Select the **StudyPlatform** environment in Bruno to load the required variables.

Run the **Seed** request to bootstrap a working dataset: it logs in via Keycloak, fetches groups, creates a study, and adds sample components in sequence. Requests use post-response scripts to pass IDs (e.g. `groupId`, `studyId`) to subsequent requests automatically.

## Architecture

The server follows a module-based architecture:

```
Sources/StudyPlatformServer/
├── App/              # Application bootstrap and configuration
├── Modules/          # Feature modules (Study, Component, etc.)
├── Models/           # Fluent database models
├── Migrations/       # Database migrations
└── Core/             # Shared infrastructure
```

Each module contains its own Controller, Service, Repository, and Mapper.

## License

This project is licensed under the MIT License. See [LICENSE.md](../LICENSE.md) for details, and [CONTRIBUTORS.md](../CONTRIBUTORS.md) for the list of contributors.

This package is based on the [`SpeziStudyPlatform-Server`](https://github.com/StanfordSpezi/SpeziStudyPlatform-Server) repository, published under the MIT License.


## Our Research

For more information, visit the [Schmiedmayer Lab GitHub organization](https://github.com/SchmiedmayerLab).

![Stanford and Stanford Medicine logos](https://raw.githubusercontent.com/SchmiedmayerLab/.github/main/assets/stanford-footer-light.png#gh-light-mode-only)
![Stanford and Stanford Medicine logos](https://raw.githubusercontent.com/SchmiedmayerLab/.github/main/assets/stanford-footer-dark.png#gh-dark-mode-only)
