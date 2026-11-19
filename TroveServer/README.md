<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Server

The Vapor backend: a REST API for studies, components, schedules, and enrollments. It conforms to the generated `APIProtocol` from [`TroveAPI/`](../TroveAPI), takes its study configuration types from `GroveStudyDefinition`, and exposes Grove's module system to route handlers through the local `GroveVapor` target.

Provider account connections are available only when a deployment sets both
`PROVIDER_CONFIGURATION_FILE` and `PROVIDER_SECRETS_FILE`; without them, participant linking
is unavailable. For approved account integrations, configuration and durable collection
behavior, see [Provider collection](../docs/Provider-Collection.md).

## Getting started

Use the single [local infrastructure setup](../TroveInfrastructure/docker/README.md)
for database initialization and runtime grants. Schema changes require a fresh
development database, not a data migration. There is no separate server-only Compose file.

For native development, copy `.env.example` to `.env` in `TroveServer/`, configure the
same restricted runtime login, and run from that directory after the backing services
and operator setup have completed:

```bash
swift run TroveServer serve
```

Container builds use the pinned Swift 6.4 Ubuntu toolchain and a separate, digest-pinned
Wolfi runtime with glibc, the binary's dynamic libraries, certificate roots and time-zone
data. The server runs as UID/GID 999, matching the Kubernetes security context. Both
architectures must pass the exact-image vulnerability scan and real-store checks;
changing the runtime does not waive findings or change the compiler toolchain.

## Commands

Serving, artifact cleanup and `reverse-retraction` use restricted credentials. Schema creation uses a
separate operator login; never copy that login into the serving environment. Startup
rejects database owners, elevated roles and permissions to mutate audit, published
study, accepted consent, clinical event, recording transfer, data-grant or append-only provider history. Source records permit only their one-way revocation
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

## Artifact storage

The S3 provider uploads and reads asynchronous byte chunks with backpressure. Its
connections share one event loop, and an upload pulls a chunk only while at most 16
earlier chunks (about 1 MiB) wait for that loop, so a busy loop slows the transfer
instead of queueing the object in memory. Artifact
staging requires a known byte count and SHA-256 digest within the purpose's limit:
10 MiB for consent PDFs and 50 MiB for publication archives. A recovery row is saved
before upload. The stored object is read back and checked incrementally for exact
length and digest before becoming ready; domain acceptance retains it in the same
transaction as its referencing record. Interrupted or inconsistent transfers remain
unaccepted and eligible for cleanup.

Raw storage streams contain unverified bytes. Authorization, audit and integrity
checks belong to the domain service before disclosure. The small-artifact `Data`
conveniences and the in-memory development/test provider buffer their payloads.
Recording objects use participant/source ownership independently of study grants.
Their storage rows cannot contain a study or group, and retention matches the exact
participant and source as well as the bytes. Cleanup records a participant/source
audit event. Consent and publication artifacts retain their study ownership.

The recording staging operation requires an explicit byte budget and verifies the
stored transport bytes before returning a ready reference. The 2 GiB minus one byte
storage ceiling is a protocol limit, not a default upload allowance. Clinical
format, decompression and source-byte validation belong to recording admission;
a ready storage reference does not establish those checks or authorize disclosure.
The recording transfer service binds a client transfer UUID to one immutable
participant/source declaration: attachment path, output and measurement interval,
registered format, consent targets, encoding, and stored/source byte counts and
SHA-256 digests. Each upload attempt uses a separate object and a bounded lease.
Failed uploads release their attempt for retry; crashed attempts expire. A late
attempt cannot issue a receipt for a newer upload. No upload creates study grants.

Transport receipts are persisted with a mandatory audit event after stored-byte
verification and a second source-installation/consent check. Owned receipt lookup
remains available after withdrawal or revocation and requires a disclosure audit.
Receipts identify the exact declaration and stored bytes, with an explicit expiry
for attachment acceptance; they do not establish decoded-source validity or
clinical custody. Declarations, attempts and receipts are append-only in SQLite
and PostgreSQL. Stored and source byte budgets are separately required by the service.

Recording HTTP operations are under
`/participant/sources/{sourceId}/recording-transfers/{transferId}`:

- `POST /declaration` registers or acknowledges the exact immutable declaration.
  JSON declarations are limited to 64 KiB before decoding.
- `PUT /content` streams `application/octet-stream` with the exact `Content-Length`.
  Do not use HTTP `Content-Encoding`; a declared Zstandard payload is sent as-is,
  so its stored digest covers the transmitted bytes.
- `GET /receipt` recovers a committed transport receipt, including after a lost
  upload response. It does not renew the receipt or authorize another upload.

Registration and upload require the source-installation proof headers
and current collection authority. Receipt lookup requires participant ownership.
A changed declaration returns 409; an unknown declaration or receipt returns 404.
Collection policy admits workout-route outputs only with route consent.

`RECORDING_MAX_STORED_BYTES` defaults to 134217728 (128 MiB), and
`RECORDING_MAX_SOURCE_BYTES` to 536870912 (512 MiB). Each accepts a positive decimal
integer up to 2147483647. `RECORDING_UPLOAD_LEASE_SECONDS` defaults to 900 and accepts
1–3600 seconds. Invalid settings prevent startup. These are per-transfer limits;
they do not change event-envelope or pending-queue limits.

A clinical Bundle member can bind its recording paths to exact transfer and artifact
IDs. Admission resolves participant/source ownership before reading storage, then
checks the declared profile, format, path, decoded length, SHA-256, FHIR attachment
SHA-1 and measurement bounds. Zstandard decoding uses a bounded 8 MiB window.
Current consent and installation authority are checked again in the clinical
transaction. Artifact retention, the immutable attachment binding and verified
content evidence, clinical rows, study grants and mandatory audit commit together. Expiry or cleanup before that
transaction yields a retryable failure. Cleanup excludes clinically referenced
artifacts even if their registry state is damaged.

A SensorKit recording fetched as a query batch (acceleration, ambient light and
pressure, heart rate, pedometer, headphone motion and settings) contains independent
rows rather than one native session. Complete content verification retains the exact
earliest and latest row instants with the attachment evidence. A consent may be
granted such a recording, or the summary derived from it, only when its accepted
measurement window selects every row: point rows half-open, rows with a native
interval when they overlap. Overlap with the enclosing period alone is refused with
HTTP 403, at admission and at later attribution, and a batch without verified row
evidence cannot be granted. The retained file and its source identifier never change;
studies with different windows receive separate client-assigned row slices. Native
sessions such as electrocardiograms, wrist temperature, workout routes and heartbeat
series keep whole-overlap selection.

The client journal retains queue-owned files and transfer evidence across restarts;
`RecordingTransferDrainer` recovers upload receipts before resending bytes, and
`EventDeliveryDrainer` recovers clinical receipts before another submission. Transport
receipts alone do not permit the client to discard its files.

Study recording downloads use `GET /studies/{studyId}/data/recordings/{grantId}`.
`RECORDING_MAX_DOWNLOAD_BYTES` independently bounds both stored and decoded bytes
per download, defaults to 536870912 (512 MiB), and accepts positive decimal integers
up to 2147483647. Invalid settings prevent startup. Capacity failure is explicit
and does not change upload or collection authority.

The development SeaweedFS service receives the same `S3_ACCESS_KEY` and
`S3_SECRET_KEY` as the server, through its standard AWS credential variables.
Authentication is required to verify signed streaming chunks. Its health probe
checks that the S3 listener rejects an unsigned request. The test fixture uses only
the synthetic `trove_test` credentials and loopback connections.

For a focused memory measurement, run the large-storage test alone with a disposable
authenticated S3 service:

```sh
TROVE_TEST_S3_PORT=18333 swift test --package-path TroveServer \
  --filter ArtifactS3IntegrationTests.largeSidecarStreamsThroughRealStorageWithBoundedMemory
```

It generates 96 MiB plus one byte in 64 KiB chunks, uploads and verifies the complete
object, and deletes it. A 1 MiB warm-up upload through the same path runs first. The
test then samples the process's resident memory throughout the large upload on Linux
and requires its peak to stay less than 64 MiB above the value after the warm-up.
Earlier tests' peak memory does not count; concurrent tests in the same process
would, so measure with `--no-parallel` or alone. `EventLoopPacedBodyTests` checks the
pacing bound itself against a blocked event loop. This is
storage-transport evidence, not a measurement of the complete mobile collection and
durable-queue pipeline.

`RecordingTransferStreamingTests.largeHTTPUploadStreamsToStorageAndRecoversItsReceipt`
adds a real HTTP listener and streamed client request to the same 96 MiB workload.
It applies the same resident-growth bound, measured from just before the upload, and
paces its own client body like the storage upload. It covers authentication,
declaration recovery, HTTP upload, S3 readback and receipt persistence. Its generated
bytes are transport fixtures, not clinically valid route data; source decoding,
compression and mobile queue storage are outside that measurement.

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

## Delegated Draft Access

The public `trove-cli` and `trove-draft-editor` identity-provider clients use
authorization code with S256 PKCE, the registered loopback callback
`http://127.0.0.1:8765/oauth/callback`, and five-minute access tokens. They have no
client secret, password grant, or service-account flow. The existing development
password client remains a local fixture and is not accepted by production policy.

The server classifies clients from the verified token's `azp` claim. A draft-editor
client cannot acquire ordinary researcher or participant access by omitting its
`Trove-Delegation-ID` header or receiving additional identity-provider roles. The
header selects a persisted grant; it conveys no authority by itself. Grants bind
one study, researcher identity, registered client, preset, and expiry of at most
24 hours. Inspect grants allow draft reads; edit grants additionally allow edits
and validation. Neither preset permits publication, participant-data access,
invitations, audit access, credential management, or further delegation.

This first flow binds the delegated token's subject to the grantor. It does not
support unattended service-account delegation. Before delegated work, the server
reads the grantor's current enabled status, effective roles, and complete group
memberships from Keycloak. Missing, unavailable, oversized, or incomplete responses
fail closed. These reads are not cached and happen outside database locks. A
prepared decision expires after 30 seconds; validation completion and queued work
must obtain fresh authority.

Application-grant checks, protected effects, and mandatory audit persistence use
the same study-locked transaction as revocation. An operation ordered before
revocation may complete; subsequent operations cannot use the grant. Result
disclosure requires a committed authorization and audit decision. Already sent
bytes or dispatched external requests cannot be retracted. Identity-provider
permission changes are observed on the next live check, not atomically committed
with the application database.

Grant lists are cursor-paginated (default 50, maximum 100). Researchers see their
own grants; study administrators can inspect and revoke all grants for that study.
Returned metadata never includes OAuth credentials.

## Study Data Access

`GET /api/v0/studies/{studyId}/data?limit=20&versions=current&before={cursor}`
requires an interactive researcher token, `/Group Name/researcher` or
`/Group Name/admin`, and the separately assigned `/Group Name/data-reader`
membership. Neither administration nor audit access implies clinical-data access.
The development realm templates include an empty `data-reader` subgroup; existing
realms need the same explicit identity-administrator setup. No users are assigned
automatically. Renew tokens after changing memberships; their lifetime bounds
outstanding identity-provider claims. Delegated draft clients cannot use this route.

The response contains derived FHIR R4 collection Bundles encoded as Base64 so
ordinary JSON clients cannot round clinical numeric values. Decode the bytes with
a FHIR-aware, decimal-preserving reader. Each record identifies its selected
output addresses, original source profiles and `isCurrent` status. Source
profiles are lineage, not conformance claims for the filtered resources. Stable
study subjects use enrollment UUIDs under `urn:trove:study:{studyId}:participants`;
they do not depend on source keys, app installations or a request host. Exact
grant identifiers provide study-scoped derivation lineage.

Each page selects at most 100 complete records and 1024 outputs, reads one bounded custody record at a time,
and verifies its retained digest before projection. A single transaction holds
participant/enrollment locks, rechecks the selected outputs and researcher access,
and persists `study.data.disclosure` intent before returning a page. The audit
target is the response page ID; it records intent, not proof of network delivery.
Audit failure releases no clinical data. Responses carry `Cache-Control: no-store`.

Current mode returns only the selected current version; history mode includes
superseded versions with `isCurrent: false`. Withdrawal and source retraction
exclude data in both modes, while enrollment end alone preserves eligible history.
The cursor is scoped to the study/version view and grants no access itself. A
changed selection or invalidated cursor requires a fresh first page; newly
attributed historical data also requires restarting. These are live pages, not a
frozen dataset snapshot. The default response budget is 24 MiB, configurable up to 96 MiB, including Base64
and JSON overhead. Capacity failure returns HTTP 503 without a partial page or
audit intent; request fewer outputs to reduce page size.

File-backed recording attachments in a derived Bundle point to a study recording
download route, using one of that output's exact grant identifiers and the page's
current/history selection. These locations require the same authenticated researcher
and group data-reader access as the page. They are not bearer links. Original custody
documents and their attachment paths remain unchanged.

A recording download checks study eligibility before reading storage. For a query
batch it also proves again that the grant's exact consent window selects every
verified row; a grant without that proof returns HTTP 404 and releases no bytes.
Study data pages apply the same rule to the recording document and its derived
summary and fail with HTTP 500, without a disclosure audit, instead of releasing or
silently omitting such an output.
The server then stages and verifies the complete stored and decoded bytes in private, unnamed temporary
files. Zstandard decoding uses an 8 MiB window and file reads use 64 KiB chunks.
Compressed preparation can hold both a stored and a decoded temporary file; neither
whole representation is collected in memory. It then rechecks the same grant,
withdrawal/retraction state, current version, researcher access and token expiry,
and commits `study.recording.disclosure` before returning bytes. The audit target is
the exact study grant and its version view. No database locks span storage reads.

The response contains the original registered source bytes, matching the FHIR attachment's size and hash,
with `Cache-Control: no-store`. Retained files outlive transfer expiry. Failed
verification, storage or capacity checks return HTTP 503 without a successful
partial recording; changed eligibility and failed audit also prevent disclosure.
Stream the response to a bounded destination rather than collecting it into memory. Binary
`application/octet-stream` transport preserves the payload without JSON re-encoding;
`X-Recording-Content-Type` carries the validated original attachment media type,
encoded as one URI component. Generated clients decode it automatically; direct
HTTP clients decode it once before checking the registered media type.
The filename suffix comes from that registered type.

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
Network isolation and certificate issuance are deployment responsibilities.

## Participant Data Sources

Participant identity is the verified token's exact issuer and subject pair. Each
participant has one logical source per native repository (`healthkit` or
`sensorkit`). `POST /participant/sources` registers an installation UUID and
credential against that source. Reinstalling or registering another device
preserves the source's key ID/epoch, identifier root and repository scope.
Registration returns public source and installation descriptors, without key bytes.
Retries require the original credential and return retained state, including
permanent revocation. An approved provider connection uses a separate server-worker
source bound to its registration.

`POST /participant/source-installations/{registrationId}/identity` requires both
verified account ownership and the installation credential. It recovers the
server-provisioned HMAC key only for active source and installation records, commits
a disclosure audit before returning it, and sends `Cache-Control: no-store`.
Missing or unverifiable key material never creates a replacement identity. The
client derives all thirteen Grove namespaces from the explicit root, key ID and
epoch, and uses the returned repository scope for conversion. Matching native IDs
under this context retain their identity across installations; distinct native
IDs are not merged by matching measurement values or timestamps.

Installation revocation is independent of logical-source revocation. The verified
owner can revoke a lost installation without its credential. Both forms preserve
history and cannot be reversed. Registration and key possession are not provider
attestation, enrollment, consent or a study data grant. Identity keys are separate
from optional installation signing keys.

Serving processes require `SOURCE_IDENTITY_KEYRING_FILE`, a restricted regular file
containing a version-1 JSON object with `currentKeyID` and a `keys` array of
`{id, keyBase64}` entries. Each encryption key must be exactly 32 bytes in canonical
base64; retain historical keys during rotation. The server encrypts each participant
identity key with AES-256-GCM bound to its complete ownership and identity context.
Rewrapping changes storage encryption without changing resource identities. No
production fallback generates a deployment key. Ephemeral UI-test databases use
an explicitly ephemeral keyring.

For a fresh native development database, initialize the keyring once from
`TroveServer/`:

```sh
mkdir -p .secrets
chmod 700 .secrets
swift run --force-resolved-versions TroveServer create-source-keyring --output "$PWD/.secrets/source-keyring.secret"
```

Set `SOURCE_IDENTITY_KEYRING_FILE` in the local environment to that absolute path.
The command does not connect to application services, prints no key material, and
creates an owner-only file. Existing files, including empty files and symlinks, are
never replaced. If initialization fails after creation, inspect the incomplete
file explicitly before retrying. Back up the keyring separately with the database;
loss of an encryption key prevents recovery of identities encrypted under it.
Retain historical keys when adding a new current key, then restart serving processes.

Clinical writes require `Trove-Source-Installation-ID` and `Trove-Source-Credential`
headers in addition to account authentication and source ownership. Single-event,
batch and Bundle admission check installation authority before validation and again
under the participant transaction lock shared with revocation. Each record commits
independently; revocation during a batch preserves accepted records and rejects later
writes. Attribution commands require the same proof; a revoked installation can
replay a retained command but cannot create new grants. Receipt lookup remains an
owner-authorized read and requires no installation credential.

Before activating shared-source collection, verify cross-device deletion, deployment
recovery and the complete client lifecycle on physical devices.
The registration endpoints accept no health data.

## Event Admission

`POST /participant/sources/{sourceId}/events` accepts a JSON envelope with
`eventBase64` and `targets: [{consentId, outputFullUrls}]`. Base64 carries the exact
original Grove Mobile record as a one-record Bundle; no FHIR values are re-encoded.
Targets name immutable consent records and exact clinical output addresses, not
mutable enrollment revisions. Default budgets are 6 MiB for the envelope and
4 MiB for decoded event bytes; configured ceilings are 24 MiB and 16 MiB
respectively. Structural limits are 512 resource nodes, 16 distinct consents and 512 KiB for
normalized target intent. Study targets do not appear in URLs.

HealthKit records may also carry the original lowercase sample UUID as an
unroled identifier under the registered source's
`<identifierRoot>/NamingSystem/healthkit-native-record` namespace. Retraction
targets use Grove's existing native-identifier extension. The receiver retains
these exact bytes and checks the store namespace; native UUIDs never supply
source ownership, consent, retraction authority or revision selection. Existing
records without this optional evidence remain admissible. The study data endpoint
preserves this evidence in authorized derived exports.

A primary HealthKit Observation or DocumentReference that carries its native
UUID, the writer-record identity and exactly one writer-record version may also
carry one readable HealthKit sync identifier, typed only
`healthkit-identifier-type#healthkit-sync-id`, under
`<native UUID system>/healthkit-sync-identifier/<bundle identifier>`, where the
native system names an authority and has no query or fragment, as Grove requires
before it discloses one. Its text
is retained verbatim and treated like the native UUID: it is never an identity,
entry key, deduplication key, version selector, receipt or retraction target, and
derived exports preserve it. A sync identifier anywhere else, more than one, or
one under a Grove identity system fails the record, and so does one without the
native UUID beside it or under any other system.

`StudyDataQuery` provides the internal selection layer for the study data endpoint. It returns
at most 100 exact output addresses per page, deduplicates overlapping consent
grants, and applies the same study, withdrawal, retraction and derivation rules as
the grant-count diagnostic. Current-version selection never falls back to an older
authorized record when the actual current record is not granted to that study.
History mode labels superseded versions but still excludes withdrawn or retracted
data. Enrollment expiry ends acquisition without erasing eligible retained history.
Pages use stored receipt time and node identity; invalidated cursors and newly
attributed historical records can require restarting at the first page.

`StudyDataQuery.fence` rechecks a captured page while holding participant locks,
then enrollment locks, in the same order as admission. It returns every exact
consent/publication grant for those outputs and their enrollment end dates.
Withdrawal, retraction or a changed current version invalidates the captured page;
the query never fills it with new candidates whose owners were not locked. Keep
the transaction open through projection and disclosure-intent persistence.

`StudyPointExport` assembles a derived FHIR R4 collection Bundle for one retained
record and one enrollment. Its `study-point-view-v1` policy preserves exact
numeric tokens, native UUIDs, readable sync identifiers, writer facts and conversion Provenance. It selects
only granted observations or recording documents and their necessary device graph, uses a stable
study-specific logical patient identity supplied by the caller, and includes the
exact historical ResearchStudy/PlanDefinition/ResearchSubject context for each
output's grants. Overlapping revisions do not duplicate the observation.

File-backed recording views use the hash and measurement bounds verified at
admission and retained with the immutable attachment binding. Page projection
checks this evidence against the original document and transfer declaration without
fetching or decoding the recording again. Retained bindings outlive transfer expiry.
Listing a document does not establish that its storage object is currently available
or authorize a separate download.

The derived Bundle has a new identity and separate receiver derivation Provenance
whose source identifiers name the study's exact grants. Original custody bytes
remain unchanged. Original Patient demographics, QuestionnaireResponse answers and
producer participation graphs are excluded; questionnaire lineage retains only its
logical business identifier. Copied narratives, administrative tags/source URLs,
producer policy/purpose annotations and immutable representation/profile claims
are removed; security labels remain, and changed resources carry `SUBSETTED`.
Original profile names remain in internal lineage. This is structural study isolation, not anonymization
or free-text redaction; permitted clinical notes and source facts remain governed
data. Bounds are 8,192 exact grants and 4,096 assembled entries, with a default
16 MiB encoded export budget configurable up to 64 MiB. Exceeding a bound fails explicitly without dropping data
or lineage; these are implementation ceilings, not measured recording-size targets.

The [study data endpoint](#study-data-access) combines these building blocks with
researcher authorization, committed audit and a whole-response byte budget. An
output grant never authorizes returning its entire original custody Bundle or a
supporting QuestionnaireResponse. Internal source addresses are not raw-data access
capabilities. Frozen dataset finalization is not implemented by this route.

`POST /participant/sources/{sourceId}/record-bundles` packs several records with
shared entries into one transport. Each member supplies its original ordered entry
addresses, payload digest and consent targets. Grove validates the graph; the
receiver restores exact canonical record bytes without re-encoding FHIR values and
then applies the same full-validator and atomic admission path. A malformed record
inventory rejects the envelope; individual record failures return ordered problems
alongside accepted siblings' receipts. Transport grouping does not enter custody
identity, and rejected siblings are not retained as accepted bytes. See the
[Bundle wire limits and retry rules](../TroveAPI/README.md#record-bundle-delivery).

Only an actual byte-limit overflow returns HTTP 413. Interrupted reads and inconsistent
declared lengths return a sanitized HTTP 503; cancellation stops processing. Incomplete
bodies never reach validation or storage. A client retains staged bytes after an uncertain
reply and retries the same event identity, bytes and consent/output intent with bounded backoff.
HTTP 413 requires explicit size-limit handling, not repeated unchanged requests or silent
discard. The [client journal and bounded batch drainer](../TroveAPI/README.md)
implement these retry rules. Native [HealthKit](../TroveAPI/README.md#healthkit-acquisition)
and [SensorKit](../TroveAPI/README.md#sensorkit-acquisition) acquisition stage records under
retained consent authority; physical-device acceptance is recorded separately in
[Collection acceptance](../docs/Collection-Acceptance.md).

The private validator checks the complete pinned Grove FHIR contract before the server
decodes any FHIR models. Its result must match the exact input digest, contract revision,
and operator-configured validator identity. An unavailable or mismatched validator causes
a refusal; there is no structural-only fallback. See the [validator setup](../TroveInfrastructure/validator/).

The receiver supports immutable, single-owner records for the native profiles that
`GET /collection-capabilities` lists (HealthKit quantities and categories, blood pressure,
state of mind, GAD-7 and PHQ-9 assessments, sleep stages, complete workout sessions with
their segments and statistics, audiograms, ECGs, food correlations, clinical documents,
heartbeat-series and workout-route recordings, and the implemented SensorKit outputs) and
for the outputs of approved provider registrations. It also supports questionnaire-derived source graphs and
whole-source-record retractions. A HealthKit ECG is one source record: a waveform Observation with
one lead of millivolt SampledData, one classification, an optional algorithm version and its symptoms status and source
period, plus at most one average heart rate derived from it over exactly its period. The waveform names correlated
symptoms only by output identity; each symptom is its own record with its own requirement. When a present symptoms
status could not be read, the waveform instead carries one member with only the data-absent reason `unknown`; it
names and grants nothing. Revision selection first removes versions
dominated by a higher writer version under the same complete writer-record identity.
It then selects the latest exact `Provenance.recorded`; equal instants use the
bytewise-greater record-version identifier value, then system. Selection preserves
complete output membership and never carries an earlier study grant forward.
Retractions suppress every output version of that source record, including later
arrivals, without reserving unrelated output identities. Because a source record is
shared by all of the participant's studies and installations, a retraction is
admitted only as HealthKit's deletion report: from the authenticated owner, through
an active installation of the participant's HealthKit source. Retractions from any
other repository are refused, and no server process derives one from missing data.
A retraction is a tombstone over retained custody; no event, fact or grant is
removed. `reverse-retraction --event <retraction event ID>` is the operator command
that lifts one tombstone by appending to `clinical_retraction_reversals`, with a
mandatory `clinical.retraction.reversed` audit event. It is idempotent, rewrites no
history, and is not reachable through HTTP. The retraction of a source record has
one identity, so a repeated report of the same deletion replays the retained
receipt and does not suppress a reversed record again. Other clinical profiles
and arbitrary supporting reference shapes are unsupported.
Unsupported input is refused,
even when it is otherwise valid FHIR. A study must explicitly publish the matching collection
requirement; a native HealthKit component alone grants no backend collection permission.

Within one database transaction, the server rechecks source ownership and revocation,
each named consent, and its exact publication's retained measurement scope.
An accepted consent governs measurement time until the participant adopts another
revision, not until a researcher publishes one. Delayed delivery can use that earlier
consent while enrollment and source remain active. Earlier grants do not disappear
on adoption. Every retained clinical output needs policy coverage from a named
consent; only explicitly selected outputs receive a read grant for that study.
The server stores the original event once, node addresses, exact quantity text or
coded values, measurement start/end times, independent study grants, and audit records. Composite foreign keys prevent grants from
crossing participant, study, enrollment, consent, or publication identities.

A requirement may declare `measurementWindow` with the Gregorian calendar, an
explicit IANA time zone (or UTC), an existing `ExportSessionStartDate` strategy,
and an optional exclusive end. For example, `last` with `components: {month: 6}`
uses six calendar months before acceptance, including month-end and daylight-saving
rules; it is not a 180-day interval. An omitted start retains consent-forward
collection. `oldestSample` authorizes all available history; an absolute start and
end define a fixed measurement range. Point measurements must lie inside the half-open
window. An interval record, such as a sleep stage, workout, ECG or native SensorKit session, is included
whole when it overlaps the window; an interval that only touches a boundary is excluded. SensorKit
query batches follow the every-row rule under [Artifact storage](#artifact-storage). The receiver preserves the original
start and end without clipping or changing the source identity. Workout selection includes every segment,
including segments outside the selected window. Partial workout grants and exports are rejected. An ECG's
average heart rate is collected under the ECG requirement and its waveform's interval; partial ECG grants and
exports are rejected in the same way.

Acceptance resolves relative bounds once and stores them atomically in the
append-only consent record. Later uploads and plan reads use those literal bounds,
not the current draft, device time zone or a newly computed lookback. A historical
scope can grant an already retained eligible measurement to another study through
late attribution without copying or uploading the event again. The published
policy archive uses schema version 5 and RFC 3339 dates at API microsecond precision;
unknown or older policy contracts fail explicitly.

The selected scope is included in the retained consent markdown and therefore its
presentation digest and exported document. Collection summaries support
English and German; another requested consent locale fails publication instead of
silently substituting a language. Consent for interval records explains that complete records may
start before or end after the selected window; clinical document consent states which document
time the window refers to. The web editor configures an independent window per requirement
through the shared draft API. The native path retains offline plans and independent
live/backfill cursors per native stream.

For the authenticated owner of an active source, an exact-byte retry with the same study
targets returns the original receipt without adding grants. Revoked sources cannot retry.
A different serialization with identical lossless resource tokens, a changed enrollment
snapshot outside the clinical version, or a re-reported whole-record retraction may
retain additional exact bytes under the same server record ID. Each representation
has its own payload digest, receipt time and node count. New representations require
current collection authority and an atomic audit record, but add no clinical facts,
versions or study grants. Changed clinical tokens, changed content under a retained
snapshot key, or different study targets conflict; late attribution uses its separate
endpoint. The first retraction keeps its lifecycle effect.

Withdrawal makes only that enrollment's grant ineffective; it does not rewrite the
event or another study's decision. The receipt contains
the server record ID, source ID, original producer identifier, SHA-256 of the exact
accepted bytes, normalized target-intent digest, receipt time and node count. It
contains no samples or current study access. Clients must match the source, complete producer
identifier and both digests to their
staged event before retiring it; HTTP success alone does not identify accepted work. No participant
observation-list or general clinical-query endpoint is exposed.

If an upload response is lost, `POST /participant/sources/{sourceId}/event-receipts/lookup`
recovers the original receipt using the complete producer identifier, payload SHA-256
and original consent/output targets. Its JSON body is limited to 1 MiB. Recovery requires
the authenticated source owner and a committed audit disclosure intent; it works
after withdrawal or source revocation without admitting data or restoring access.
An unknown/foreign-owned event or unaccepted payload digest returns 404; a different
consent/output intent returns 409. An unknown digest requires resubmission and validation,
not retirement of staged bytes.
It returns no clinical payload, and an unavailable audit store denies disclosure.

`POST /participant/sources/{sourceId}/events/{eventId}/attributions` adds purposes
without resubmitting or modifying the original event. Supply a durable `commandId`
and explicit `targets`. Each grant independently requires eligible measurement time,
exact consent, source ownership and active enrollment/source. The grant and command
receipt commit with their audit records. Retrying a command returns its original
receipt, even after withdrawal or revocation, without recreating access. Changing
its event or targets conflicts. Adding a grant never makes an older revision current;
current selection occurs before intersecting exact study permissions.

### Ended sleep and workout windows

`POST /participant/enrollments/{enrollmentId}/collection-reconciliations` lets an
installation finish a bounded sweep for sessions that were finalized after the
enrollment ended. The request names the participant's HealthKit source and carries
the installation proof. Under the participant and enrollment locks the server checks
ownership, an active source and installation, and that the enrollment has ended and
is not withdrawn. It then resolves the accepted consent timeline exactly as the
collection plan does and issues one instruction per closed sleep or workout
requirement, plus one for workout routes where that consent accepted them. Other
streams are not eligible. `native_collection_reconciliations`
keeps one row per source, enrollment and exact scope; a repeated request renews the
lease of an unfinished row under the same identity, and
`.../{reconciliationId}/complete` marks it complete idempotently. A completed scope
is never issued again. Both operations record a study-scoped audit event
(`collection.reconciliation.issued`, `collection.reconciliation.completed`).
Issuance grants no upload authority: admission checks every submitted record
against its consent window.

`NATIVE_RECONCILIATION_LEASE_SECONDS` sets the lease, 900 seconds by default. It
must be a positive finite number; an invalid value prevents startup. A lease only
bounds how long one online request authorizes local querying; unfinished work
resumes at its retained position after the next request.

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
entry point runs suites sequentially; a dedicated test exercises eight isolated
applications concurrently.

Client recovery tests connect the real SQLite journal and generated Swift client to
the authenticated router. They lose a partially accepted batch response, withdraw
from one study, optionally revoke the source, and reopen both databases before
receipt recovery. They check exact retained bytes, independent study access, rejected
payload retention and checkpoint-preserving pruning. The normal lane substitutes
only the validator transport; `fullValidatorClientAndReceiverRecovery` requires the
isolated pinned validator setup. Neither lane simulates an OS-process crash or a
mobile collector. Linux test builds require `pkg-config` and `libsqlite3-dev` for
the client journal; the shared entry point checks this before compiling.

### Required full-validator CI lane

The real-store job in `swift-package.yml` runs the full server suite with the
checksum-pinned offline validator and the separately pinned receiver lifecycle
corpus. `TROVE_REQUIRE_FULL_VALIDATOR=1` requires the nine named clinical test groups
and the two Questionnaire groups to execute; missing or skipped groups fail
verification. The multilingual group validates the shared bilingual fixtures through
the questionnaire route and checks that the validator reports `qg-translation-1` for
translations that repeat the base language or a language. The response group checks a
matching QuestionnaireResponse and four mismatches (questionnaire version, missing
required answer, answer type, language not offered) through the response route. The parameterized
receiver group covers all 43 declared sequences, and the retraction group covers
both arrival orders. Deployment binding preserves recorded lexemes and writer
evidence. The pinned IG generator supplies the expected states, including the
identifier tie-break after content-derived keys change. Test-function counts are
not parameter-case counts.

To reproduce with disposable loopback PostgreSQL and S3 services, prepare the
validator context with `--include-lifecycle-corpus`, run its image on an isolated
internal network, and set:

```sh
export TROVE_TEST_POSTGRES_PORT=15432 TROVE_TEST_S3_PORT=18333
export TROVE_TEST_VALIDATOR_ASSETS=/absolute/path/to/context/assets
export TROVE_TEST_LIFECYCLE_CORPUS=/absolute/path/to/context/corpus/Conformance/corpora/receiver-lifecycle
export FHIR_VALIDATOR_URL=http://127.0.0.1:18080/validate
export FHIR_VALIDATOR_IDENTITY=sha256:$(shasum -a 256 TroveInfrastructure/validator/manifest.json | cut -d ' ' -f 1)
TROVE_REQUIRE_FULL_VALIDATOR=1 bash scripts/check swift TroveServer
```

Use the workflow's pinned service images, loopback bindings and validator resource
restrictions. Each application owns and removes its test database. Retain the
raw logs, Swift Testing XML, validator image identity and both input manifests.
This lane exercises application recreation and durable journal recovery; separate
process-crash, simulator acquisition and physical-device acceptance remain distinct.

## Bruno

Request collections live in `tools/bruno/`, for the [Bruno](https://www.usebruno.com) API client. Select the **Trove** environment to load the variables. The **Seed** request bootstraps a working dataset: it logs in through Keycloak, fetches groups, creates a study, and adds sample components, passing IDs between requests through post-response scripts.

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

There is no generic FHIR resource upload route, legacy-data import or compatibility schema.


## Collection capacity configuration

The server validates capacity environment settings at startup. Record, transport
Bundle, JSON request envelope and batch-count settings are
`COLLECTION_MAX_RECORD_BYTES`, `COLLECTION_MAX_BUNDLE_BYTES`,
`COLLECTION_MAX_ENVELOPE_BYTES` and `COLLECTION_MAX_BATCH_RECORDS`. Defaults are
4 MiB, 4 MiB plus 1 KiB, 6 MiB and 16. Hard ceilings are 16 MiB, 16 MiB plus
1 KiB, 24 MiB and 16. Middleware and admission use the same immutable configuration;
whole-record restoration and validation retain the hard ceiling so lowering a
new-admission budget does not make existing custody unreadable. The private
validator accepts up to 16 MiB per event; a worker change requires its matching
manifest and validator identity. Questionnaire operating limits are separate.

`STUDY_EXPORT_MAX_BUNDLE_BYTES` and `STUDY_EXPORT_MAX_PAGE_BYTES` independently
bound derived serialization and complete encoded pages. Defaults are 16 MiB and
24 MiB; maxima are 64 MiB and 96 MiB. Page budgets must accommodate base64 expansion
and framing. Serialization stops at the configured limit without dropping
outputs or references. `RECORDING_MAX_STORED_BYTES`,
`RECORDING_MAX_SOURCE_BYTES` and `RECORDING_MAX_DOWNLOAD_BYTES` are independent.
No setting authorizes collection, grants study access, or splits a source record.

Larger options are bounded implementation choices, not measured memory guarantees. Complete-record and combined compressed
recording/backlog workload evidence is needed when selecting deployment values;
chunked storage measurements alone do not establish JSON graph memory use.
