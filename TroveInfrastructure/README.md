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

**The production deployment is not ready.** The database engine and extension are
pinned, but production certificate provisioning, enforced network policy, private
services, recovery and immutable application release images still require acceptance.
Production selects production transport policy; missing prerequisites must stop
startup, not trigger a development-mode fallback.

Development and verification SeaweedFS instances use 32 volume slots and disable
anonymous telemetry. The explicit slot limit permits separate test collections;
the default allocation exhausted available slots when two database test lanes
shared one store. This is not additional disk capacity: existing data-volume and
container limits still apply. Production object storage needs its own provisioned
capacity and security acceptance.

Development now uses one digest-pinned PostgreSQL/Timescale StatefulSet for the server,
plus the separate Keycloak database. Database and object-store data use retained volume
claims instead of ephemeral pod storage. These claims survive pod replacement, not
deletion of the namespace or KIND cluster; they are not backups or high availability.
Development schema changes require a fresh disposable database, not an in-place upgrade.

A separate [database operator Job](database-operator/README.md) initializes the schema
and provisions the restricted runtime login. Serving pods receive no owner credential
and run no initializer. Docker, Kubernetes and recovery verification reuse the same
grant scripts. The production secret resources contain no seeded passwords: operators
must supply real values through Secret Manager before synchronization.

### Production Database

Production uses CloudNativePG 1.30.0 (chart 0.29.0), PostgreSQL 18.6 and TimescaleDB
2.29.2, with immutable multi-architecture image references. Its supported
[image-volume extension mechanism](https://cloudnative-pg.io/docs/1.30/imagevolume_extensions/)
requires Kubernetes 1.35 or later and a compatible runtime (containerd 2.1+ or
CRI-O 1.31+). Confirm ImageVolume support before bootstrap. The PostgreSQL and
extension images both target PostgreSQL 18 on Debian Trixie; do not mix their OS,
major version or architecture. Keycloak uses the same PostgreSQL image without
the clinical extension.

The Cluster preloads TimescaleDB and disables its telemetry. The `Database/trove`
resource installs the extension at the pinned SQL version. On first installation,
wait for the Cluster to become Ready and the Database's `status.applied` to be true
before running the schema Job. The server verifies these prerequisites and fails
closed if they are missing. These are fresh-database definitions, not an in-place
upgrade of the former PostgreSQL 17 setup.

The maintained extension image contains the Apache-2 edition. It supports the
current receiver and basic hypertables; it does not provide the additional
Timescale-licensed features used by the historical compression benchmark. That
benchmark is not production-capacity evidence. The current clinical facts are
ordinary indexed tables; partitioning/compression still require measured workload
and integrity validation before adoption.

The schema owner receives only `CREATEROLE` and `pg_read_all_settings` in addition
to database ownership, through two fixed bootstrap statements. Its Secret username
must match the configured owner, `trove`. Do not also place this owner in CNPG's
`managed.roles`: its membership reconciliation can remove the administration grant
needed by the shared runtime-provisioning script. See
[operator privileges and lifecycle](database-operator/README.md).

### Local Network-Policy Verification

The local KIND configuration pins Kubernetes 1.35.8, matching the database
extension baseline. Its default networking includes NetworkPolicy support; no
additional CNI installation is needed for this bounded check.

The development bootstrap discovers the single KIND API endpoint and passes its
exact IPv4 `/32` into ArgoCD's infrastructure parameters. CNPG and Traefik can reach
only that address on TCP 6443 and the pinned Kubernetes Service address on TCP 443;
application pods retain default-deny egress. This accounts for Service destination
translation without allowing the whole Docker network. Production keeps its own
control-plane policy. The infrastructure Application uses server-side dry-run
comparison so Kubernetes-defaulted PVC template fields do not cause permanent
`OutOfSync` status; no desired fields are excluded from comparison.

```sh
python3 -B tools/verify_network_policy.py \
  --kind /absolute/path/to/kind \
  --probe-image trove-fhir-validator:local-warm
```

Run from `TroveInfrastructure` with its tooling requirements installed, Docker,
kubectl and a local image containing `python3`. The example reuses the validator
image, but overrides its command with synthetic TCP listeners and supplies no
validator assets, participant data or application credentials.

The verifier owns a randomly named two-node cluster and explicit kubeconfig;
it never uses the current kubectl context. It checks listener reachability before
applying the rendered production policies, then requires two passing matrices of
allowed and denied connections through both pod and Service addresses, including
the dashboard's port-80-to-8080 translation. Cases include database separation,
dashboard isolation, rejected plaintext identity routing and matching labels from
another namespace. Fresh connections prevent existing sessions from hiding policy
changes. The cluster is removed on success or failure and results remain locally.

This verifies the local policy implementation and selected pod/Service paths, not
GKE Dataplane V2, external identity/API routes, DNS, TLS or the full application
deployment. Production acceptance must verify those boundaries
in the target environment as well.

### Production Transport

The production manifests require certificates; they do not provision a new private
certificate authority or fall back to plaintext when trust is unavailable:

- The server and database operator mount only `ca.crt` from CloudNativePG's
  `trove-db-ca` Secret. Keycloak mounts only `ca.crt` from `keycloak-db-ca`.
  CA signing keys must never be projected into application pods. Swift clients and
  the grant process verify the database hostname as well as its certificate chain.
- Keycloak exposes HTTPS on port 8443; the API and dashboard use port 8080, using the existing `trove-main-tls-secret`
  certificate for `console.troveplatform.org`. Traefik verifies that same identity
  on all three backend connections through one `platform-https` transport. Sharing this
  certificate avoids a second PKI, but gives ingress, Keycloak, API and dashboard access to
  its private key; restrict Secret access accordingly. The database operator never
  receives the serving key. The dashboard's ClusterIP Service still uses port 80;
  its connection to the container is HTTPS on port 8080, not plaintext HTTP.
- The server and realm importer use `https://console.troveplatform.org/auth` with
  certificate verification enabled. Their identity egress is restricted to the
  configured load-balancer IP on port 443. Update that address together with the
  Traefik service configuration. Do not broaden egress to compensate for a failed route.

Before enabling production synchronization, provision the public certificate Secret
and its renewal mechanism. The retained cert-manager issuer and Certificate resources
are not included in the overlay until DNS/issuance are configured. Missing Secrets
prevent pod startup. Projected mounts receive Secret updates, but existing client trust
contexts may not: roll the server and Keycloak after database CA rotation, and rerun
the operator with the updated trust. Verify public certificate reload and overlapping
trust during rotation before relying on unattended renewal.

For routine public-certificate renewal, publish a valid replacement before expiry
and verify its new serial through a fresh, fully verified connection to both ingress
and Keycloak. Restart the API and dashboard to load the renewed identity, then verify a fresh
backend connection. Keycloak's default reload interval is one hour. Local service tests
verify reload and rejection of expired replacements, but not Kubernetes Secret
renewal. Replacing a certificate does not revoke already-established TLS sessions:
for a compromised key or withdrawn CA, drain/restart affected clients and servers
as part of the incident procedure, then verify rejection using fresh connections.
Do not use an existing keep-alive connection or an HTTPS readiness probe as evidence
that a new certificate is trusted.

Deployment acceptance must test the actual cluster's load-balancer return path, DNS,
network-policy enforcement, invalid/expired/wrong-host certificates, and certificate
rotation. Kubernetes HTTPS readiness probes do not establish certificate trust.
Rendered manifest tests verify configuration relationships, not these runtime guarantees.
The API and dashboard routes require HTTPS without a verification bypass. Their rendered
configuration and local tests do not replace actual cluster routing/renewal acceptance.

Ingress access logs retain only timestamp, method, status, duration and configured
route/service names. Headers, URLs, query strings and client addresses are excluded in
both environments. These operational logs are not the study audit trail; do not add
participant identifiers or credential-bearing URLs to routing names or diagnostics.
The dashboard disables Nginx access and request-error logs; startup diagnostics
remain available. Do not enable its default URL-bearing logs in production.
The production server sets `LOG_LEVEL=warning` so Vapor's default informational
request-path logs do not record source/enrollment identifiers. This does not disable
the transactional study audit trail. Do not enable verbose application or database
logging against real participant data; reproduce with synthetic fixtures instead.

The commands below describe the retained bootstrap workflow. Local database/job tests
and manifest validation do not establish complete GitOps, network-policy enforcement,
validator integration or production readiness. Docker remains the recommended local
application development setup while those gates are completed:

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

The setup script owns only the bootstrap boundary: it installs and configures
ArgoCD, supplies private-repository credentials when needed, and creates one
root Application. ArgoCD then reconciles the child Applications in sync-wave
order and owns all infrastructure and application resources. For development,
the root propagates `BRANCH` to each child that reads manifests from this
repository without changing the pinned versions of third-party Helm charts.

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
