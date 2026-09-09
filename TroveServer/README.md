<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Server

The Vapor backend: a REST API for studies, components, schedules, and enrollments. It conforms to the generated `APIProtocol` from [`TroveAPI/`](../TroveAPI), takes its study configuration types from `GroveStudyDefinition`, and exposes Grove's module system to route handlers through the local `GroveVapor` target.

## Getting started

Use the single [local infrastructure setup](../TroveInfrastructure/docker/README.md)
for database initialization and runtime grants. Schema changes currently require a fresh
development database, not a data migration. The former server-only Compose file has been
removed so it cannot drift from this setup.

For native development, copy `.env.example` to `.env` in `TroveServer/`, configure the
same restricted runtime login, and run from that directory after the backing services
and operator setup have completed:

```bash
swift run TroveServer serve
```

Container builds use the pinned Swift 6.3 Ubuntu toolchain and a separate, digest-pinned
Wolfi runtime with glibc, the binary's dynamic libraries, certificate roots and time-zone
data. The server runs as UID/GID 999, matching the Kubernetes security context. Both
architectures must pass the exact-image vulnerability scan and real-store checks;
changing the runtime does not waive findings or change the compiler toolchain.

## Commands

Serving and artifact cleanup use restricted credentials. Schema creation uses a
separate operator login; never copy that login into the serving environment. Startup
rejects database owners, elevated roles and permissions to mutate audit, published
study, accepted consent, clinical event or data-grant history. Source records permit only their one-way revocation
update; their ownership and identity remain fixed. Installing Timescale and granting privileges are operator responsibilities,
not actions the application performs while serving.

The `migrate --yes` command creates the current schema and Fluent history in one
PostgreSQL transaction. A transaction-scoped advisory lock rejects competing operators;
retry after the active operator finishes. Initialization has a two-minute transaction
deadline, a one-minute statement deadline and a 15-second database-lock deadline.
Failure rolls back both schema changes and history; losing the connection releases
the initialization lock. Serving never initializes the schema.

This command is not an upgrade path or a schema-equivalence check for older development
versions. Recreate an identified disposable database when the schema changes;
`--revert` is unsupported. Audit history remains append-only within a database's lifetime.

## Profile Data Boundaries

Birth dates must be exact Gregorian `yyyy-MM-dd` values. Missing zero padding,
surrounding whitespace, timestamps and impossible dates are rejected rather than
normalized; parsing uses UTC, independently of the server's calendar or time zone.
Gender values use exhaustive API/domain mappings and a matching database check
constraint. Unsupported persisted values cannot silently become a default option.
These are representation checks, not age eligibility or clinical validation.

## Signing-Key Trust

The server loads RS256 keys from its configured Keycloak realm. Successful JWKS
refresh replaces the trusted set; an unknown `kid` never falls back to another
key. Trust expires after five minutes, and refresh attempts share a 30-second
cooldown. Failed refresh cannot extend that expiry. While Keycloak is unavailable,
unexpired cached keys remain usable, but expired trust returns HTTP 503 rather
than authorizing a request. Token issuer, audience and expiry are checked separately.

An unannounced replacement key may receive HTTP 401 during the refresh cooldown.
For planned rotation, publish the enabled replacement as passive before activation
and allow the cache lifetime plus a refresh margin. Retain old keys for the intended
token overlap. Removing a key or logging out a session is not an instantaneous
push to every server: for emergency key invalidation, remove provider trust and
recycle serving instances. Per-user/session revocation is a separate mechanism.

The [disposable rotation check](../TroveInfrastructure/validator/README.md#signing-key-rotation-check)
exercises real provider rollover, key retirement and outage expiry with the normal
cache settings. It does not replace deployment-wide rotation or recovery acceptance.

## Study Audit Access

`GET /api/v0/studies/{studyId}/audit-events?limit=50&before={auditEventId}`
requires the researcher realm role plus both `/Group Name/admin` and
`/Group Name/audit-reader` memberships. An identity administrator must explicitly
assign the reader subgroup; existing admins do not gain it automatically. The
fresh development realms include the empty subgroup without assigning users.
Existing realms require the same explicit subgroup setup. Obtain a renewed token
after membership changes; token lifetime bounds outstanding claims.

Membership paths must use exactly `/Group Name/role`; empty or additional path
segments grant no access. Multiple valid roles in one group retain the strongest
explicit role, independent of token order. Audit-reader membership remains a
separate requirement and cannot be inferred from either researcher or admin.

Only the selected study's matching group-scoped records are visible. Participant
source history, other studies and historical rows without group scope are excluded.
Results contain governed identifiers and operation metadata, not clinical payloads
or contact details. Pages are capped at 100, use descending database timestamp/ID
ordering and reject unknown or foreign cursors. A fresh first page includes newer
records; pagination is not a frozen export. Every returned page, even empty, needs
a committed disclosure intent and has `Cache-Control: no-store`.

Each authenticated request receives a server-generated audit correlation ID.
Services carry that context explicitly into database transactions, so an event's
custody record and its study grants share the same ID. A retry is a new request;
it does not rewrite the original acceptance records. Client-supplied correlation,
revision, and initiator headers do not establish audit evidence.

Set `APPLICATION_REVISION` to the actual immutable deployment revision. It accepts
1–128 ASCII letters, digits, or `-./:_`; invalid configuration prevents startup.
An unidentified local build may omit it, producing `null`, not a fabricated build
identity. This deployment assertion is not a substitute for verified release
provenance. Each `cleanup-artifacts` invocation also has one correlation ID and
the configured revision. Its actor is the cleanup service; shell access alone
does not identify a human initiator.

## Service Transport

`APP_ENVIRONMENT=production` requires certificate- and hostname-verified TLS for
PostgreSQL and HTTPS for Keycloak, S3 and any configured FHIR validator. Plaintext
services are permitted only in explicit development mode. URLs cannot include
credentials, queries or fragments. Service requests never follow redirects; configure
the final endpoint, including the correct S3 region. The validator URL must have
exactly `/validate` as its path. Leaving it unset disables event admission, while an explicitly
invalid URL fails startup.

All clients share the same TLS policy, with TLS 1.2 as the minimum. System trust is
retained. For private infrastructure, `TLS_CA_FILE` may name an absolute path to a
PEM CA bundle of at most 1 MiB. Unreadable, empty or invalid bundles fail startup;
there is no verification bypass or plaintext fallback. Mount the CA bundle read-only
in both runtime and schema-operator containers, and restart after certificate changes.
During CA rotation, distribute a bundle containing both trusted roots before replacing
leaf certificates; remove the old root after clients have restarted. The operator's
separate `psql` process needs its own `PGSSLROOTCERT` pointing to the matching bundle
with `PGSSLMODE=verify-full`.

Production serving also requires `TLS_CERTIFICATE_FILE` and `TLS_PRIVATE_KEY_FILE`,
absolute paths to a PEM certificate chain (leaf first) and its unencrypted private
key, each at most 1 MiB. Mount them read-only only in serving pods. Missing,
unreadable, malformed or mismatched identity files fail before service connections;
there is no plaintext listener alongside HTTPS. Database initialization and artifact
cleanup do not need these files. Development may omit both to serve HTTP; partial
or invalid explicit configuration still fails. Identity files are read at startup:
restart the server after renewal and verify a fresh connection's certificate.

The application owns HTTP connection lifecycle for identity, storage and validation;
storage shutdown releases its credentials without shutting down another service's
HTTP connections. Ingress must verify the backend's certificate and hostname.
Network isolation and certificate issuance remain deployment responsibilities. Development fixtures do not establish
production readiness.

## Participant Data Sources

Participant identity is the verified token's exact issuer and subject pair, not the
subject alone. App streams are registered through `POST /participant/sources` using a
participant-scoped registration UUID. The server assigns the source identity and event
namespace. Retrying returns the same registration, even after revocation. Only its owner
can read or revoke it; revocation is permanent and does not delete retained history.

The response also supplies the ten distinct Grove pseudonymous identifier systems.
They are derived from the immutable event namespace using versioned metadata names
and Grove's deterministic UUID mapping; no additional database state is needed.
Clients persist the returned set rather than deriving it or choosing defaults.
These public namespaces neither contain nor generate the client's privacy key.

Registration is not provider attestation, enrollment, consent or a study data grant.
The registration endpoints accept no health data. The retired resource-upload endpoint
remains absent.

## Event Admission

`POST /participant/sources/{sourceId}/events` accepts a JSON envelope with
`eventBase64` and `targets: [{consentId, outputFullUrls}]`. Base64 carries the exact
original Grove Mobile exchange Bundle bytes; no FHIR JSON reconstruction occurs.
Targets name immutable consent records and exact clinical output addresses, not
mutable enrollment revisions. The limits are 6 MiB for the envelope, 4 MiB for
decoded event bytes, 512 resource nodes, 16 distinct consents and 512 KiB for
normalized target intent. Study targets do not appear in URLs.

Only an actual byte-limit overflow returns HTTP 413. Interrupted reads and inconsistent
declared lengths return a sanitized HTTP 503; cancellation stops processing. Incomplete
bodies never reach validation or storage. A client retains staged bytes after an uncertain
reply and retries the same event identity, bytes and consent/output intent with bounded backoff.
HTTP 413 requires explicit size-limit handling, not repeated unchanged requests or silent
discard. The [client journal and bounded batch drainer](../TroveAPI/README.md)
implement these retry rules; actual device collection remains disabled pending its
source-identity, consent, background-execution and recovery integration.

The private validator checks the complete pinned Grove FHIR contract before the server
decodes any FHIR models. Its result must match the exact input digest, contract revision,
and operator-configured validator identity. An unavailable or mismatched validator causes
a refusal; there is no structural-only fallback. See the [validator setup](../TroveInfrastructure/validator/).

The initial receiver deliberately supports one narrow capability: immutable, single-owner,
Mobile heart-rate point quantities, including their supported questionnaire-derived source
graph. Comparable writer revisions preserve complete output membership; incomparable
or equal-maximum revisions remain conflicts with no current selection. Retractions,
other profiles, pre-consent collection and arbitrary supporting reference shapes
remain unsupported. Unsupported input is refused,
even when it is otherwise valid FHIR. A study must explicitly publish the matching collection
requirement; a native HealthKit component alone grants no backend collection permission.

Within one database transaction, the server rechecks source ownership and revocation,
each named consent, and its exact publication's consent-forward collection policy.
An accepted consent governs measurement time until the participant adopts another
revision, not until a researcher publishes one. Delayed delivery can use that earlier
consent while enrollment and source remain active. Earlier grants do not disappear
on adoption. Every retained clinical output needs policy coverage from a named
consent; only explicitly selected outputs receive a read grant for that study.
The server stores the original event once, node addresses and lossless quantity text,
independent study grants, and audit records. Composite foreign keys prevent grants from
crossing participant, study, enrollment, consent, or publication identities.

For the authenticated owner of an active source, an exact-byte retry with the same study
targets returns the original receipt without adding grants. Revoked sources cannot retry.
Changed bytes or targets conflict. Withdrawal makes only that enrollment's grant
ineffective; it does not rewrite the event or another study's decision. The receipt contains
the server record ID, source ID, original producer identifier, SHA-256 of the exact
accepted bytes, normalized target-intent digest, receipt time and node count—not
samples or current study access. Clients must match the source, complete producer
identifier and both digests to their
staged event before retiring it; HTTP success alone does not identify accepted work. No participant
observation-list or general clinical-query endpoint is exposed.

If an upload response is lost, `POST /participant/sources/{sourceId}/event-receipts/lookup`
recovers the original receipt using the complete producer identifier, payload SHA-256
and original consent/output targets. Its JSON body is limited to 1 MiB. Recovery requires
the authenticated source owner and a committed audit disclosure intent; it works
after withdrawal or source revocation without admitting data or restoring access.
An unknown/foreign-owned event returns 404; a mismatched digest or intent returns 409.
It returns no clinical payload, and an unavailable audit store denies disclosure.

`POST /participant/sources/{sourceId}/events/{eventId}/attributions` adds purposes
without resubmitting or modifying the original event. Supply a durable `commandId`
and explicit `targets`. Each grant independently requires eligible measurement time,
exact consent, source ownership and active enrollment/source. The grant and command
receipt commit with their audit records. Retrying a command returns its original
receipt, even after withdrawal or revocation, without recreating access. Changing
its event or targets conflicts. Adding a grant never makes an older revision current;
current selection occurs before intersecting exact study permissions.

## Tests

```bash
swift test --package-path TroveServer --no-parallel
```

Each test application owns an isolated database and signs synthetic JWTs. The default
SQLite lane needs no Docker services. The PostgreSQL/Timescale lane creates a fresh
database per invocation on the explicitly configured loopback test service; it never
uses deployment credentials. Run the shared `bash scripts/check swift TroveServer`
entry point from the repository root for the same build, test and coverage steps as CI.
Each helper-created application uses one shared event loop and up to two PostgreSQL
data connections plus one setup/cleanup connection. This bounds per-application pools
independently of host CPU count while preserving concurrent transaction tests. The shared
entry point still runs suites sequentially; a dedicated test exercises eight isolated
applications concurrently. Full-suite parallel resource scheduling remains a separate gate.

Client recovery tests connect the real SQLite journal and generated Swift client to
the authenticated router. They lose a partially accepted batch response, withdraw
from one study, optionally revoke the source, and reopen both databases before
receipt recovery. They check exact retained bytes, independent study access, rejected
payload retention and checkpoint-preserving pruning. The normal lane substitutes
only the validator transport; `fullValidatorClientAndReceiverRecovery` requires the
isolated pinned validator setup. Neither lane simulates an OS-process crash or a
mobile collector. Linux test builds require `pkg-config` and `libsqlite3-dev` for
the client journal; the shared entry point checks this before compiling.

## Bruno

Request collections live in `tools/bruno/`, for the [Bruno](https://www.usebruno.com) API client. Select the **Trove** environment to load the variables. The **Seed** request bootstraps a working dataset — it logs in through Keycloak, fetches groups, creates a study, and adds sample components, passing IDs between requests through post-response scripts.

## Architecture

```
Sources/TroveServer/
├── App/              # Application bootstrap and configuration
├── Modules/          # Feature modules (Study, Component, etc.)
├── Models/           # Fluent database models
├── Migrations/       # Fresh database schema creation
└── Core/             # Shared infrastructure
```

Feature modules use controllers, services, repositories and mappers where those boundaries
are useful. All core repositories use the same authoritative database; multi-record
operations pass an explicit transaction to their repositories and audit writes.

The former `/participant/fhir/resource` route is removed, including its unversioned
mapper and generated clients. It is not a compatibility fallback for the new IG receiver.
No legacy-data import or compatibility schema is included.
