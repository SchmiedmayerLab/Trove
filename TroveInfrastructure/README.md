<!--

This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT

-->

# Infrastructure



The GitOps deployment layer: manages deployment of the [TroveServer](../TroveServer) and [TroveWeb](../TroveWeb) applications alongside supporting services (Keycloak, PostgreSQL, Traefik) across local and production environments, built with ArgoCD, Kustomize, Helm, and OpenTofu.

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

For running backing services (PostgreSQL, Keycloak) without Kubernetes, see the [Docker setup guide](docker/README.md). This is the recommended approach when developing the [TroveServer](../TroveServer) or [TroveWeb](../TroveWeb) applications locally.

