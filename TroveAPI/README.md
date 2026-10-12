<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# API

The shared OpenAPI contract (`openapi.yaml`) and the Swift libraries generated from it: `TroveAPITypes`, `TroveAPIClient`, and `TroveAPIServer`. It is the single source of truth consumed by the server, the iOS app, and — through a generated TypeScript client — the web portal.

## Code generation

The generated `Types.swift`, `Client.swift`, and `Server.swift` are checked in. Regenerate them after editing `openapi.yaml`:

```bash
swift run --package-path TroveAPI TroveAPIGenerator --package-path TroveAPI
```

Individual targets can be regenerated on their own:

```bash
swift run --package-path TroveAPI TroveAPIGenerator --package-path TroveAPI --types --client
```

## Local Verification

Run `bash scripts/check swift TroveAPI` from the repository root with Swift 6.4.x.
Linux builds of `TroveAPIClient` require SQLite development files; on Ubuntu,
install `libsqlite3-dev` and `pkg-config`. The shared CI workflow installs these dependencies before
running the same check. Apple platforms use their system SQLite library.

## Date Encoding

Swift clients must use `Client(serverURL: ..., configuration: .trove, transport: ...)`.
The server uses the same runtime configuration. API dates use RFC 3339 with six
fractional digits in UTC, matching database microsecond precision; the default
OpenAPI runtime encoder drops fractional seconds. Keep timestamp strings intact
in TypeScript when comparing collection boundaries instead of converting them to
millisecond-only JavaScript `Date` values. This codec does not rewrite opaque FHIR
event bytes or change the IG's timestamp rules.
The same configuration emits compact JSON without escaping forward slashes,
avoiding unnecessary expansion of base64 envelopes. Use it for API JSON, not
for embedding an unescaped response in HTML.

## Source Registration

Source setup is retained in `EventDeliveryJournal` before networking. Explicitly
create a new local stream with `createSource(localID:queryDefinition:)`, then send
its `registrationID` through the authenticated client. Restore existing setup with
`sourceSetup(for:)`; never fall back to creation after a missing-state error.
`confirmSource(_:for:)` persists the response, and `identityScope(for:)` restores
the Grove conversion context without exposing key bytes. The former direct
`registerSource` API is removed. Keys and queries cannot be replaced in place.
Journal format 5 rejects earlier or unknown formats without migration or deletion.

The private journal retains the 256-bit key under its OS/app storage protections;
this does not provide independent at-rest encryption or resist same-user access.
The app restores its streams with the bounded `sourceSetups()` snapshot rather
than keeping a separate preferences index. Requests remain bound to the captured
authenticated session. No HealthKit collector is enabled by these APIs.

`SourceRegistration.synchronize` performs one captured-session operation over
existing setup: registration by the retained nonce while pending, or a source-ID
read after confirmation. It checks the journal's exact scope and revalidates the
session around suspension points. Missing remote sources never trigger replacement
registration. Failures retain setup and expose only a sanitized category/status;
the caller decides when to retry. Permanent known revocation needs no refresh.
The iOS `TroveAPIModule.synchronizeSource` wrapper supplies its existing Keycloak
session-bound client. Successful synchronization is not consent or collection authority.

## HealthKit Acquisition

The optional Apple-platform `TroveHealthKit` product connects Grove's anchored
heart-rate query and FHIR converter to the delivery journal. The server and
cross-platform API client do not link this adapter. The app's
`makeHeartRateAcquisition` factory supplies the existing captured-session client;
constructing it does not request HealthKit access or start collection.

Explicitly create a stream with `HeartRateAcquisition.queryDefinition(start:)`,
then reuse that immutable definition and the journal's retained anchor. One pass
refreshes source state and the requested enrollments' collection plans before
querying and again before staging. Changed authority, malformed plans or session
loss stops the pass. The receiver still independently authorizes each upload.

`ParticipantCollectionSnapshot` validates the complete requested set of plans and
selects exact half-open consent windows. One converted Observation can target
several consents without duplicating its event. Both the native measurement time
and Grove's millisecond-normalized wire time must be inside the selected consent,
so rounding cannot admit a pre-consent sample.

The query requests at most 64 additions and retains a hard 128-change staging
bound. Grove reserves event identities in a durable producer ledger backed by the
protected journal. Prepared bytes, targets and the next anchor then commit together.
Only after that commit does the caller release Grove's retry reservations. A failed
member preserves the previous anchor, exact export reservations and earlier queued
work. Delivery uses the existing drainer and never reconverts a queued event.

Known native consent exclusions advance the anchor without exporting a sample.
Unsupported changes never advance the anchor. Deletions
use Grove's source/output identities and exporter, with no copied samples
or study targets. An end-only occurrence period records the known upper time bound
without inventing an exact deletion timestamp. The observed upper bound is persisted
before export and reused after interruption until the page commits.

Source registration assigns an immutable `identifierRoot`; Grove derives the full
namespace set using the retained registration ID and key epoch. Its ledger owns the
producer UUID and wire sequence, independently of the queue's local ordering.
The receiver still authenticates ownership and checks the assigned event namespace.
Journal schema 6 and query definition 3 deliberately reject earlier local formats
without removing queued work; this development change includes no data migration.

This acquisition path is not enabled automatically. App lifecycle and permission UI remain
unfinished. Synthetic tests exercise the real converter and journal, not a live
HealthKit store or background execution. An empty query result does not prove
that HealthKit read permission was granted.

## Source Retractions

Submit a Grove Mobile Retraction Bundle through the same event endpoint with
`targets: []`. The owner must authenticate to an active registered source; study
withdrawal does not prevent a restrictive source assertion. Active events and
attribution commands still require explicit consent targets. Receipt lookup uses
the event's original intent, including an empty array for a retraction.

The receiver currently supports Observation targets. Each complete logical output
Identifier is scoped to its source and bound to the asserted source record.
Retraction keeps immutable evidence and suppresses every version of that output,
including later arrivals; it neither deletes the original event nor creates
study grants. Unrelated outputs and other sources remain unaffected. Unsupported
target types reject the entire event. A policy for reappearance remains separate work.

Direct QuestionnaireResponse derivations may remain pending until one exact
source-scoped context is known and independently authorized for the same enrollment.
Ambiguous identity or another study's grant cannot supply access. This internal
point-availability check does not authorize exporting every answer or the original Bundle.

## Enrollment Revision Adoption

Accept a reviewed consent presentation through
`POST /participant/enrollments/{enrollmentId}/consents` to adopt its exact revision.
The command checks the enrollment state version and records consent, adoption and
audit evidence atomically. There is no separate consent-free enrollment upgrade
operation; the former `PATCH /participant/enrollments/{enrollmentId}` route has
been removed, including its generated client types.

`GET /participant/enrollments/{enrollmentId}/collection-plan` returns only the
owned enrollment's exact consent/publication windows and collection requirements.
The audited response includes an enrollment state version and server observation
time, uses `Cache-Control: no-store`, and contains no signatures or samples.
Publishing alone does not change these windows; participant adoption does.
Withdrawal returns no windows. The snapshot is not an upload capability or
permission for continued offline collection: uploads recheck authority. The
foreground heart-rate adapter refreshes these windows before and after each query;
it does not enable automatic or offline collection.

## Event Batches

`POST /participant/sources/{sourceId}/events/batch` submits 1–16 events for one
owned, active source. Use the existing `EventSubmission` representation: canonical
base64 of each original event and its exact consent/output targets. The envelope
is limited to 6 MiB, with at most 5,592,408 bytes across the base64 strings.

The ordered response contains one custody receipt or `ProblemDetails` per event.
An outer HTTP 200 does not mean every event was accepted. Each event commits
independently; malformed encoding, a consent rejection or a conflict does not
roll back other members. Accepted receipts remain stable on exact replay;
rejection results are not persistent receipts and can change with retained state.

After a lost response, recover each member's original receipt before resubmitting
unchanged bytes and targets. Apply bounded backoff to transient problems and
retain permanent rejections for inspection. Processing is sequential, not a
background job. The durable drainer uses this operation for all submissions,
including one-member batches, with exact receipt lookup for uncertain deliveries.

## Delivery Journal

The journal lives in `TroveAPIClient`, alongside the authenticated delivery adapter.
`EventDeliveryJournal` specializes `DeliveryJournal<TroveDeliveryContract>`; Grove
provides FHIR conversion and identity types, not the persistence implementation.
The contract identifier is stored with the exact backend, issuer and subject.
Changing incompatible bindings, targets or receipts requires a new contract identifier;
opening an established journal with another contract fails without modifying it.

`EventDeliveryJournal` provides account/backend-scoped, transactional staging in
the client library. It preserves original event bytes and exact consent targets,
and commits a caller-owned query cursor in the same transaction as its event.
One query delta can stage up to 128 independently identified events atomically;
conversion or storage failure in any member rolls back the entire group and cursor.
Stale checkpoint snapshots cannot stage another event. Failed transactions advance
neither cursor nor producer sequence. Established journals must
be opened explicitly and are never silently recreated or migrated.

The caller owns source registration, FHIR transformation, authenticated transport
and bounded source queries. Register an immutable query definition with each
source; changing filters or restarting a lost stream requires a new source.
Always query from the journal's current checkpoint. Do not also let another store
advance that stream's cursor or reuse an old query result under a newer checkpoint.
The journal does not validate FHIR conformance or grant collection authority.

Verified custody replaces the event payload with a receipt. `pruneDelivered`
reclaims verified delivered rows without touching pending work, source identity,
cursor or sequence. There is no per-change retry ledger or cross-store cleanup
protocol. The iOS Health Data screen uses this journal for explicit device setup,
Health access requests and bounded foreground sync. Setup selects the earliest
eligible consent window once; restoring a source never replaces its query or key.
An empty query does not establish read permission or complete collection. Automatic
and background collection remain disabled and require separate device verification.

Supply an application-owned directory with mode `0700`. New journal files receive
mode `0600` before any identity or event bytes are written. Existing files must
have that mode, belong to the current process user and have no hard-link aliases.
Darwin extended ACLs are rejected rather than silently removed. Insecure storage
fails with `unsafeStorage`; opening never repairs permissions on existing data.
These checks supplement the application sandbox and OS storage encryption; they
do not isolate data from other processes running as the same user or an administrator.

On iOS, the directory also needs backup exclusion and
`completeUntilFirstUserAuthentication` protection. Opening fails when those
requirements cannot be verified on a physical device. Simulator builds enforce
backup exclusion and the filesystem checks above, but cannot verify iOS Data
Protection; device lock and encryption behavior require physical-device testing.
This protection permits background access after
the first device unlock. Logical payload/intent/setup/query/cursor byte and event quotas, and an independent
SQLite database-size limit provide backpressure; reserve additional disk space
for the rollback journal. Fixed-size receipt/metadata overhead is covered by the
physical limit. Full storage never silently evicts pending work.

## Authenticated Delivery

`EventDeliveryDrainer` performs a bounded pass over ready journal entries using
source-specific batches, the generated client and a captured-session validator. Construct it for
the journal's exact backend, issuer and participant. The app's `TroveAPIModule`
factory supplies its existing session-bound transport; it does not enable collection.

An uncertain attempt looks up its original receipt before resubmitting unchanged
bytes and consent targets. Retry deadlines and permanent rejection states survive
reopening. Transient failures use bounded exponential backoff with jitter and
honor `Retry-After`; unauthorized or stale sessions stop the drainer instance.
Only a verified custody receipt permits payload retirement. Permanent rejection
retains the payload and requires explicit intervention; it never loops or silently
discards work.

Packing checks both base64 length and the complete encoded envelope, including
consent intent, and flushes before crossing a bound or changing source. A short,
extra or malformed batch result list retains every member with backoff. Complete
receipts are verified against their original positional commitments; one invalid
receipt cannot retire another event. Any 401 in a batch stops that instance before
storing the response's sibling receipts. Accepted receipts can still be recovered
later using a newly authenticated, correctly scoped drainer.

The caller schedules passes. There is no internal timer, independent token manager
or separate collector checkpoint authority. Journal format changes currently require a
fresh development journal; no migration or automatic replacement is provided.
