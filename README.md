<!--
This source file is part of the StudyPlatform open-source project

SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# StudyPlatform

**StudyPlatform** is an open-source, end-to-end platform for running research studies: researchers author studies in the [web](web), those definitions configure the participant [iOS app](ios), and a [Vapor server](server) with a shared [OpenAPI contract](api) ties it together, deployed via [GitOps infrastructure](infrastructure).

This monorepo consolidates what were previously separate repositories into a single tree with one shared API contract and one consolidated CI pipeline.

## Components

| Path | Component | Stack |
|------|-----------|-------|
| [`api/`](api) | Shared OpenAPI contract (`openapi.yaml`) plus the generated Swift `APITypes`, `APIClient`, and `APIServer` libraries. Source of truth for both the server and the clients. | Swift, swift-openapi-generator |
| [`server/`](server) | REST backend for studies, components, schedules, and enrollments. Compiles against `api/` via `.package(path: "../api")`. | Swift, Vapor, Fluent, Postgres |
| [`web/`](web) | Researcher portal for authoring studies. Generates its API client from `api/openapi.yaml`. | React, TypeScript, Vite, Tailwind |
| [`ios/`](ios) | iOS participant app. References `api/` as a local Swift package (`../api`). | Swift, SwiftUI, Spezi |
| [`infrastructure/`](infrastructure) | GitOps deployment: Kustomize overlays, ArgoCD apps, and OpenTofu/Terraform for GKE. | Kustomize, ArgoCD, OpenTofu |

## The shared API

`api/openapi.yaml` is the single source of truth for the HTTP contract:

- **Server** conforms to the generated `APIProtocol` from `StudyPlatformAPIServer`.
- **iOS** consumes the generated `StudyPlatformAPIClient`.
- **Web** regenerates a TypeScript client from `api/openapi.yaml` (`npm run generate:api`).

Regenerate the Swift sources after editing the spec:

```bash
swift run --package-path api StudyPlatformAPIGenerator
```

## Continuous integration

CI lives in [`.github/workflows/`](.github/workflows) and is path-filtered so each
component only builds when its files (or the shared `api/`) change:

| Workflow | Triggers on | Does |
|----------|-------------|------|
| `api.yml` | `api/**` | Builds and tests the API package. |
| `server.yml` | `server/**`, `api/**` | Builds and tests, then builds & pushes the server image on `main`. |
| `web.yml` | `web/**`, `api/openapi.yaml` | Installs, generates the client, lints, builds, then builds & pushes the web image on `main`. |
| `ios.yml` | `ios/**`, `api/**` | Resolves packages and builds the iOS app. |
| `infrastructure.yml` | `infrastructure/**` | Validates Kustomize manifests and OpenTofu, and runs a KIND smoke test. |
| `reuse.yml`, `codeql.yml`, `markdown-link-check.yml` | repo-wide | License compliance, code scanning, and monthly link checks. |

Container images are published to `ghcr.io/schmiedmayerlab/studyplatform-server`
and `ghcr.io/schmiedmayerlab/studyplatform-web`. The server and web images build
from the monorepo root so the inlined `api/` package is in the build context.

## Provenance

This monorepo consolidates what were previously separate repositories, each published under the MIT License. Refer to the individual repositories for their historical contributor lists.

| Component | Former repository |
|-----------|-------------------|
| [`api/`](api) | [SpeziStudyPlatform-API](https://github.com/StanfordSpezi/SpeziStudyPlatform-API) |
| [`server/`](server) | [SpeziStudyPlatform-Server](https://github.com/StanfordSpezi/SpeziStudyPlatform-Server) |
| [`web/`](web) | [SpeziStudyPlatform-Web](https://github.com/StanfordSpezi/SpeziStudyPlatform-Web) |
| [`ios/`](ios) | [SpeziStudyPlatform-iOS](https://github.com/StanfordSpezi/SpeziStudyPlatform-iOS) |
| [`infrastructure/`](infrastructure) | [SpeziStudyPlatform-Infrastructure](https://github.com/StanfordSpezi/SpeziStudyPlatform-Infrastructure) |

## License

This project is licensed under the MIT License. See [LICENSE.md](LICENSE.md) for details, and [CONTRIBUTORS.md](CONTRIBUTORS.md) for the list of contributors.

This repository is based on and incorporates content from the [`StanfordSpezi/SpeziStudyPlatform-*` repositories](https://github.com/orgs/StanfordSpezi/repositories?q=SpeziStudyPlatform), all of which were published under the MIT License.

## Our Research

For more information, visit the [Schmiedmayer Lab GitHub organization](https://github.com/SchmiedmayerLab).

![Stanford and Stanford Medicine logos](https://raw.githubusercontent.com/SchmiedmayerLab/.github/main/assets/stanford-footer-light.png#gh-light-mode-only)
![Stanford and Stanford Medicine logos](https://raw.githubusercontent.com/SchmiedmayerLab/.github/main/assets/stanford-footer-dark.png#gh-dark-mode-only)
