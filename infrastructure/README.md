<!--

This source file is part of the StudyPlatform open-source project

SPDX-FileCopyrightText: 2026 Stanford University and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT

-->

# StudyPlatform Infrastructure

[![CI](https://github.com/SchmiedmayerLab/StudyPlatform/actions/workflows/infrastructure.yml/badge.svg)](https://github.com/SchmiedmayerLab/StudyPlatform/actions/workflows/infrastructure.yml)

> **StudyPlatform** is an open-source, end-to-end platform for running research studies: researchers author studies in the [web portal](../web), those definitions configure the participant [iOS app](../ios), and a [Vapor server](../server) with a shared [OpenAPI contract](../api) ties it together. See the [monorepo overview](../README.md) for the full picture.

**This package** is the GitOps deployment layer: it manages deployment of the [server](../server) and [web](../web) applications alongside supporting services (Keycloak, PostgreSQL, Traefik) across local and production environments, built with ArgoCD, Kustomize, Helm, and OpenTofu.

## Prerequisites

Install via [Homebrew](https://brew.sh/) or your preferred package manager:

| Tool                                               | Install                       | Purpose                    |
| -------------------------------------------------- | ----------------------------- | -------------------------- |
| [kind](https://kind.sigs.k8s.io/)                  | `brew install kind`           | Local Kubernetes clusters  |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | `brew install kubernetes-cli` | Kubernetes CLI             |
| [helm](https://helm.sh/)                           | `brew install helm`           | Kubernetes package manager |
| [python3](https://www.python.org/)                 | `brew install python`         | Setup and test scripts     |
| [kubeconform](https://github.com/yannh/kubeconform) | `brew install kubeconform`    | Schema validation          |

## Quick Start

```bash
make dev            # Create KIND cluster, bootstrap ArgoCD + all services
make dev-status     # Check sync progress
make argocd-password # Get ArgoCD admin password
```

To bootstrap from a feature branch:

```bash
git push -u origin HEAD
make dev BRANCH=my-feature
```

To start fresh:

```bash
make dev-down && make dev
```

Run `make help` to list all available targets, including production commands for OpenTofu and GKE.

### Dev Test Users

All dev users share the password `password123`:

| Username             | Role                     |
| -------------------- | ------------------------ |
| `leland@example.com` | Researcher, ArgoCD Admin |
| `jane@example.com`   | Researcher               |
| `alice@example.com`  | Participant              |

## Docker Development

For running backing services (PostgreSQL, Keycloak) without Kubernetes, see the [Docker setup guide](docker/README.md). This is the recommended approach when developing the [server](../server) or [web](../web) applications locally.

## License

This project is licensed under the MIT License. See [LICENSE.md](../LICENSE.md) for details, and [CONTRIBUTORS.md](../CONTRIBUTORS.md) for the list of contributors.

This package is based on the [`SpeziStudyPlatform-Infrastructure`](https://github.com/StanfordSpezi/SpeziStudyPlatform-Infrastructure) repository, published under the MIT License.


## Our Research

For more information, visit the [Schmiedmayer Lab GitHub organization](https://github.com/SchmiedmayerLab).

![Stanford and Stanford Medicine logos](https://raw.githubusercontent.com/SchmiedmayerLab/.github/main/assets/stanford-footer-light.png#gh-light-mode-only)
![Stanford and Stanford Medicine logos](https://raw.githubusercontent.com/SchmiedmayerLab/.github/main/assets/stanford-footer-dark.png#gh-dark-mode-only)
