<!--
This source file is part of the Trove open-source project
SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
SPDX-License-Identifier: MIT
-->

# Database Operator

Schema ownership is an operator responsibility. Serving uses a separate restricted
login and rejects owner or elevated credentials at startup. This directory contains
the single grant implementation used by Docker, Kubernetes and recovery verification.

## Initialization

The Kubernetes Job runs the same server image as the serving Deployment. Its init
container runs `migrate --yes`; only success starts the grant container. Initialization
is atomic and serialized by PostgreSQL. The Job allows one retry and a five-minute
overall deadline. SQL grants have bounded connection, statement and lock waits.

Argo applies the configuration and operator service account at sync wave −2, runs
the operator as a Sync hook at −1, then updates serving at wave 0. A PreSync hook
would precede the configuration it needs on first installation. Completed and failed
Jobs remain inspectable until the next full sync replaces them. Selective sync skips
hooks; do not use it to bypass this step. See [Argo's phase and wave semantics](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/).

This ordering gates Deployment updates; it does not stop already-running replicas.
Breaking development schema changes require an explicitly stopped, disposable setup.
No mixed-version production upgrade or automatic schema-equivalence check is implied.
Direct `kubectl apply` does not interpret Argo hooks: an operator must explicitly wait
for successful Job completion before applying serving resources.

## Credentials and Transport

| Secret | Consumer | External store key |
|---|---|---|
| `trove-postgres-credentials` | Database provisioning and operator Job | `server-db-credentials` |
| `trove-postgres-runtime-credentials` | Grant step and serving process | `server-runtime-db-credentials` |

Both contain `username` and `password`. Usernames and passwords must be distinct;
runtime passwords must have 16–1024 characters without line breaks. Missing values
block setup. Development Vault values are synthetic and must never be used in a
production secret store. OpenTofu creates secret containers only; it does not create
secret versions or store plaintext credentials in its state.

The operator needs the authority to create the schema, provision a restricted role
and install the fixed preload-check function with access to its server setting.
The production CNPG bootstrap grants the `trove` owner `CREATEROLE` and membership
in `pg_read_all_settings`, without superuser, replication or bypass-RLS privileges.
The owner Secret's username must be `trove`; the runtime login remains distinct
and receives neither privilege. Production requires certificate-verified PostgreSQL
TLS, including the operator's `psql` client.

The shared grant script owns runtime-role creation, password changes and grants.
Do not continuously reconcile the schema owner's memberships through CNPG
`managed.roles`: PostgreSQL gives the creator an ADMIN membership on the runtime
role, and removing that membership breaks later password provisioning. The two
bootstrap grants avoid competing role managers. Existing databases do not rerun
bootstrap SQL; development changes here require a fresh disposable setup. Recovery
must restore and verify role administration as well as tables and grants.

The Job has a separate service account, no mounted API token and a database-only
network identity. The grant container never starts after failed initialization.
There are no wildcard future-table grants. New tables require a reviewed grant-list
update. Credential rotation requires a coordinated operator run and serving restart;
refreshing a Secret alone does not change existing process environments or passwords
in PostgreSQL.

## Verification

Install `TroveInfrastructure/tools/requirements.txt` in a local Python environment
and have `kubectl` available. `bash scripts/check tooling` renders both overlays and
checks credential separation, sync ordering, image consistency, TLS policy and
persistent-volume wiring. These checks require no live cluster.

Cluster acceptance also requires a failed-initializer test, successful restricted
runtime login, unchanged history on repeat setup and retained database/object data
after pod replacement. The single-node development stores are not a production
backup, replication or disaster-recovery implementation.
