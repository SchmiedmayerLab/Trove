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

## Study Data Retrieval

The generated `getStudyData` operation reads authorized point data for a study.
Its records contain Base64-encoded derived FHIR Bundles to preserve clinical numeric
tokens through JSON clients. Decode with a decimal-preserving FHIR reader; source
profile names are lineage, not conformance claims for the derived representation.
The endpoint requires explicit clinical-data access and committed disclosure audit.
See [study data access](../TroveServer/README.md#study-data-access) for the full
contract, limits and live-page semantics.

The generated `getStudyRecording` operation downloads the original registered source bytes for an exact
study grant. Derived recording attachments contain authenticated, origin-relative
download locations. Pass the same current/history selection when using the operation
directly. The server verifies the complete recording and commits disclosure intent
before returning its `HTTPBody`; consume that body incrementally into a bounded
destination. Default `OpenAPIURLSession` transport streams on Apple platforms but
buffers on Linux, so incremental application reads alone do not establish bounded
Linux transport memory. The body uses
`application/octet-stream` to preserve source bytes without JSON decoding. The
required `X-Recording-Content-Type` (URI-component encoded; decode exactly once) header retains the original registered media
type, including the FHIR release parameter when present. Clients verify it against
the attachment and save a media-appropriate suffix without rendering a preview.

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

## Recording Transfers

The generated clients expose `declareParticipantRecordingTransfer`,
`uploadParticipantRecordingTransfer` and `lookupParticipantRecordingTransferReceipt`.
Retain one transfer UUID and unchanged declaration across retries. Register the
small JSON declaration, then send the bytes separately as `application/octet-stream`
with the declared `Content-Length`. Swift accepts an `HTTPBody` backed by an
asynchronous byte sequence; the caller must provide the exact known length.
Zstandard compression is declared in the content descriptor, not HTTP
`Content-Encoding`. Stored and decoded counts and SHA-256 digests are separate.

After a lost upload response, look up the receipt before retransmitting. A receipt
confirms the stored transport bytes, not decoded-source validity or clinical
custody. It has an explicit expiry and does not create study grants. See
[recording transfer limits and authority](../TroveServer/README.md#artifact-storage).

`RecordingTransferDrainer` uploads a declaration prepared in the delivery journal.
It first recovers any server receipt, then registers the retained declaration and
streams an immutable snapshot of the queued file. The snapshot's length and SHA-256
must match the declaration before upload. Reads are demand-driven and at most
64 KiB each; retries preserve the transfer identity and exact bytes. Registration
and upload receipts remain in the journal across restarts. An upload receipt does
not retire the file or submit its clinical record.

The HTTP transport must also stream request bodies to preserve bounded memory.
The pinned Swift OpenAPI URLSession transport streams on Trove's supported Apple
platforms; its Linux implementation buffers request bodies. A bounded body adapter
alone does not make that Linux transport suitable for large recordings. Snapshot
creation temporarily requires disk space for one additional copy of the active
recording.

`EventDeliveryDrainer` transfers each prepared recording before submitting its
clinical Bundle. Each member carries the relative attachment path and exact
transfer/artifact IDs separately from its immutable FHIR bytes. After an uncertain
clinical response, receipt lookup precedes any recording upload; only verified
clinical custody permits file reclamation. HealthKit recordings use the same atomic
file staging and retained transfer declarations before advancing their source cursor.

## Source Registration

Source setup is retained in `EventDeliveryJournal` before networking. Explicitly
create a local stream with `createSource(localID:queryDefinition:)`. This persists
an installation UUID and a random 256-bit installation credential, but creates no
participant identity key. Restore existing setup with `sourceSetup(for:)`; never
fall back to creation after a missing-state error.

`SourceRegistration.synchronize` registers the retained installation UUID,
credential and native repository through the captured-session client. A separate,
audited recovery request returns the server's complete identity context and HMAC
key. The journal atomically confirms that context and key. Once confirmed,
synchronization reads the installation's current state without redistributing the
key. Missing remote state, an unrecoverable key or conflicting identity fails
explicitly; none generates replacement IDs.

The logical source, key ID/epoch, identifier root and repository scope remain
independent of the local installation UUID. Authorized installations recover the
same conversion identity for the same native record ID while retaining independent
credentials, acquisition cursors and revocation. `identityScope(for:)` restores the
Grove context. `confirmSource(_:for:identityKey:)` rejects changed keys or immutable
identity metadata. Known source or installation revocation cannot be cleared by a
later response. Journal format 20 upgrades formats 17 to 19 in place and rejects earlier or
unknown formats without migration or deletion.

Recording files are staged beside the journal in an owner-only directory. The
journal commits empty-file reservations before consuming recording chunks, then
flushes the complete files and commits their SHA-256 digests, delivery bindings,
and acquisition cursor together. Failed staging leaves the cursor unchanged;
`reclaimRecordingFiles()` removes abandoned reservations without touching pending
recordings or unknown files. A verified clinical custody receipt retires files;
reclamation removes their bytes before `pruneDelivered()` removes the retained
commitments. An artifact-transfer receipt alone does not permit file deletion.

Recording limits are separate from JSON and SQLite limits: 128 MiB per file,
1 GiB of pending recording bytes, and 4,096 retained file entries by default.
Callers may configure these budgets through `DeliveryJournal.Limits`; exceeding
one refuses staging without evicting queued data. The event drainer requires a
prepared transfer declaration for every queued recording before submission.
Temporary upload or admission failures retain the file and schedule a retry.

`prepareRecordingTransfer(recordingID:deliveryID:declaration:)` retains a transfer
declaration before networking. It checks the queued bytes, relative attachment
path, document profile/format, available measurement period, and exact consent
selection. `RecordingTransferCommitment` canonicalizes declarations at the API's
microsecond date precision and verifies the entire server acknowledgement.
Registration and artifact receipts survive reopening through
`recordingTransfer(for:)`. Expired artifact evidence remains readable, but
`usableReceipt(at:)` excludes it from new clinical admissions. A newer upload may
replace expired artifact evidence while the clinical delivery is pending; it does
not replace the declaration or release the file.

The private journal retains both secrets under its OS/app storage protections;
this does not provide independent at-rest encryption or resist same-user access.
Setup snapshots exclude secret bytes. The app restores streams with bounded
`sourceSetups()` rather than a separate preferences index. Session checks surround
network suspension points, and failures expose sanitized categories/statuses.
The iOS `TroveAPIModule.synchronizeSource` wrapper supplies its existing Keycloak
session-bound client. Successful synchronization is not consent or collection
authority, and these HMAC identity keys are separate from optional signing keys.

The drainer sends the retained installation UUID and credential as
`Trove-Source-Installation-ID` and `Trove-Source-Credential` headers on Bundle
submissions. These transport credentials do not enter FHIR bytes, resource IDs or
submission commitments. Known installation revocation blocks submission, while an
uncertain earlier upload can still recover its receipt through authenticated lookup
without these headers. The server independently checks installation revocation at
admission; a stale client state cannot authorize a revoked installation.

## HealthKit Acquisition

The optional Apple-platform `TroveHealthKit` product connects Grove's anchored
quantity and category queries, blood pressure, audiograms, electrocardiograms, state of mind, GAD-7 and PHQ-9
assessments, workouts, food correlations, clinical documents, heartbeat series and optional workout routes to the
delivery journal. The enabled collection capabilities expose only implemented producer and receiver paths.

An ECG is queried one per page. Only after its interval has an accepted consent are its voltages and correlated
symptoms read; Grove converts it into one record with the lead's voltages as SampledData in the waveform Observation
and the average heart rate as a second Observation derived from it. Both outputs are selected together under the
ECG requirement. The waveform names each symptom by output identity only: a symptom stays its own record and is
collected only through its own consented symptom stream. The permission request for the ECG stream includes the
correlated symptom types, because an ECG that reports symptoms cannot be converted without reading them. Heartbeat series stream
into the registered beat-interval CSV format with original gap markers and a separate
source-bound recording scope. Their complete files use the same bounded compression and
resumable delivery path as workout routes. The server and cross-platform
API client do not link this native acquisition adapter. The app's
`makeHealthKitAcquisition` factory supplies the journal and captured-session validation;
constructing it does not request HealthKit access or start collection.

Each native source type remains an independent stream even when several sports or
sensors use the same semantic FHIR profile. Accepted requirements, permission requests,
query windows, cursors and consent selection retain the exact HealthKit type identifier.
An ambiguous semantic profile alone cannot select a new native query. Type names and
canonical units come from Grove; clinical profiles and temporal shapes come from its
portable generated contract.

The journal can retain several immutable query definitions for one registered source.
`createQuery(for:queryID:definition:)` adds a separate cursor and pending conversion
instant; `checkpoints(for:)` restores them without resetting the original query.
The original query remains the default of `checkpoint(for:)`. Staging advances only
its selected checkpoint while all queries share the source identity, credentials,
delivery sequence and exact-payload deduplication. Pending deletion bounds are
also query-specific so another page cannot retire them. Query count and bytes are
bounded; a rejected creation or page leaves every existing checkpoint intact.

`prepareQueryDefinition()` chooses the initial live boundary from the retained
accepted plan and setup time. Persist it once through source creation; restoration
never replaces it. Historical ranges have separate immutable definitions and
anchors, reconciled through `healthKitQueryPlan(for:state:)` as described below.
Acquisition checks local source, session and retained consent state on every page;
changed local authority or session loss stops staging. Foreground refresh learns
server changes, and the receiver independently authorizes each upload.

`ParticipantCollectionSnapshot` validates the complete requested set of plans and
selects exact half-open measurement windows, which may precede consent adoption
when historical collection was explicitly accepted. One converted Observation can
target multiple studies without duplicating its record. Overlapping historical
revisions select the newest eligible consent per enrollment. Both the native
measurement and Grove's millisecond-normalized wire measurement must satisfy the same
selection rule: points fall inside a window; complete intervals overlap it. Rounding
cannot widen the accepted measurement range.

Workout routes require `includeWorkoutRoutes` in the accepted workout requirement and
separate HealthKit read permission. They have their own live and historical cursors,
so enabling routes backfills eligible history independently of workout summaries.
Only an eligible route loads its companion locations. Grove carries the complete
HealthKit sample interval in `DocumentReference.context.period` and its locations in
the registered CSV attachment. A route targets only consents that explicitly request
routes; a study requesting workout summaries does not receive the recording.

Clinical FHIR documents use the dates when HealthKit downloaded the record to the device;
CDA documents use the document dates assigned by their creator. Accepted requirements retain
that explicit `timeBasis`. Both carry those dates on the conversion Provenance source entity,
never as `DocumentReference.context.period`. Selection retains complete overlapping documents,
which may describe care outside the selected source-date window. Embedded clinical dates are
not guessed or substituted. Original FHIR release, JSON numeric tokens and CDA XML bytes are
preserved in file-backed attachments. HealthKit supplies one complete `Data` per document;
subsequent hashing, optional compression and upload read the staged file in bounded chunks.

CDA contents require a separate foreground review. Automatic passes skip their document-data
queries and leave their cursors untouched; `catchUp(..., reviewDocuments: true)` runs the explicit
HealthKit review flow after checking retained collection authority. Missing or denied document
contents do not acknowledge a successful collection. Other streams continue their normal sweeps.

Food entries and nutrients remain independent source records. A grouping retains logical
membership references, while each nutrient needs its own exact source/profile/window permission.
Unrequested nutrient payloads and conversion evidence are not retained or uploaded. Per-UUID
conversion instants let an authorized nutrient collected through food deduplicate with the same
sample collected independently. Deleting a grouping does not delete its nutrient samples.

The adapter includes the original lowercase HealthKit sample UUID by default,
using Grove's existing native-identifier option. Its clear identifier system is
`<identifierRoot>/NamingSystem/healthkit-native-record`, separate from Grove's
keyed identity systems and stable across installations and derivation-key epochs.
The same UUID accompanies a retraction target. It does not replace the opaque
source-record/output identities, authorize access, or establish source authenticity.
Published collection consent describes this baseline disclosure. Original queued
bytes remain unchanged; upgrading the adapter never rewrites a pending record.
Native conversion regressions require the Apple verification lane.

Ordinary queries request at most 64 additions; recording, document and food queries request
one source item per page. All pages retain the 128-output staging bound, including independently
authorized food members. Route and heartbeat readers verify complete sample counts. Original
files use the configured recording-byte limit, independent of the encoded record limit. Capacity
failures preserve the source cursor and pending work without truncating content.
The journal persists one conversion instant for the pending checkpoint,
so Grove's stateless converter reproduces the same record version after interruption.
Canonical record bytes, targets and the next anchor then commit together, clearing
that pending instant. A failed member preserves the previous anchor, conversion
instant and earlier queued work. Delivery never reconverts a queued record.

Known native consent exclusions advance the anchor without exporting a sample.
Unsupported changes never advance the anchor. Deletions
use Grove's source/output identities and exporter, with no copied samples
or study targets. An end-only occurrence period records the known upper time bound
without inventing an exact deletion timestamp. The observed upper bound is persisted
before export and reused after interruption until the page commits.

Source registration assigns an immutable `identifierRoot`; Grove derives the full
namespace set using the retained registration ID and key epoch. Record-version
and retraction identifiers replace producer-instance event sequences; queue ordering
is local to the journal. The receiver authenticates ownership and checks the assigned
namespace for each lifecycle kind. Journal schema 14 and query definition 6 reject earlier local formats
without removing queued work; this development change includes no data migration.

Collection requires participant setup and HealthKit permission UI. The app connects
foreground sync and observer capture to the same journal owner. Native offline and
query-scheduling changes still require Apple-platform build and runtime verification.
Saved plans include the study identity and title from the adopted publication. The
local Health Data screen can read these settings without remote profile discovery,
including locally stopped plans. Withdrawal persists the local stop before server
requests; a retry reconciles an already completed server withdrawal. Displayed
settings do not grant acquisition permission, and account changes hide prior settings.
These native UI changes remain subject to the Apple-platform verification above.

Synthetic adapter tests exercise the converter and journal, not a live HealthKit
store or physical-device background execution. An empty query result does not prove
that HealthKit read permission was granted.

## Source Retractions

Submit a Grove Mobile Retraction Bundle through the same event endpoint with
`targets: []`. The owner must authenticate to an active registered source; study
withdrawal does not prevent a restrictive source assertion. Active events and
attribution commands still require explicit consent targets. Receipt lookup uses
the event's original intent, including an empty array for a retraction.

The receiver resolves the complete source-record Identifier within the registered
source. Retraction keeps immutable evidence and suppresses every output of every
version of that record, including later arrivals; it neither deletes the original
record nor creates study grants. Other source records remain unaffected. Repeated
reports use the same record-retraction identity; the first accepted report keeps
its lifecycle effect, while additional accepted bytes have their own custody receipts.

A HealthKit record is stored once for the participant's source and shared by every
study and installation, so a retraction applies to all of them. The rule is
therefore narrow:

- A retraction is minted only for an object HealthKit itself reports as deleted in
  an anchored query, by its native UUID. A sample that is absent from a query, a
  page or a newly installed phone produces no event.
- The receiver accepts a retraction only from the authenticated owner, through an
  active installation of that participant's HealthKit source. Any installation of
  the source may report the deletion; other repositories cannot retract.
- A retraction is a tombstone. The record's bytes, versions and grants stay in
  custody, and an operator can reverse the tombstone (see the server README).

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
owned enrollment's exact consent/publication windows, collection requirements,
study display details and retained enrollment end.
The outer window's `start`/`end` describe adoption chronology, capped by enrollment end. Each resolved
requirement has its own inclusive measurement `start` and optional exclusive `end`;
historical starts can precede adoption. These resolved values are retained at
acceptance. A later publication does not broaden them. Do not infer measurement
bounds from the outer adoption window or recompute relative history on a device.
The audited response includes an enrollment state version and server observation
time, uses `Cache-Control: no-store`, and contains no signatures or samples.
Publishing alone does not change these windows; participant adoption does.
Withdrawal returns no windows. A collection snapshot is not an upload capability;
the receiver rechecks every upload against current server authority.

`ParticipantCollectionRefresh` discovers the complete enrollment set and retains
all active plans atomically in the account/backend-bound delivery journal. Failed
or partial discovery does not replace accepted plans. Known withdrawals are
persisted immediately, including when a later plan request fails. Enrollment
versions and observation times cannot move backward, and a delayed response cannot
overwrite an intervening adoption or local stop.

`collectionState()` restores these plans without a network request or elapsed-time
lease. `snapshot.active(at:)` excludes enrollments at their retained exclusive end. Observation time is not a lease, and resolved historical bounds never
move on restart. Call `stopCollection(for:)` before attempting local withdrawal
online; that stop survives restart and cannot be undone by a server refresh.
The stop preserves queued bytes and their original consent IDs. Use
`collectionCheckpoint(for:state:)` to bind acquisition to its retained snapshot;
`stage` rejects it atomically if authority changed while the page was in flight,
including changes written through another journal connection and expiry of an
enrollment while querying, converting or staging. Other studies can continue on
the next pass; expiry does not erase queued data or become a withdrawal.

A sleep or workout session that overlaps an accepted window can be finalized in
HealthKit after its enrollment ended, when the retained plan no longer permits a
query. `POST /participant/enrollments/{enrollmentId}/collection-reconciliations`
(participant and installation authenticated) returns one instruction per closed,
originally accepted sleep, workout or opted-in workout-route window of an ended,
not withdrawn enrollment. An instruction fixes source, enrollment state version,
consent, publication, revision, source token and the original window, and carries a
short lease (`issuedAt`, `expiresAt`). It opens no new measurement window and never
changes the plan's `endsAt`. Repeating the request renews unfinished sweeps under
the same `id`; a completed sweep is not issued again.
`ParticipantNativeReconciliation.request` asks only for ended enrollments after a
complete plan refresh and retains each instruction with a compare-and-swap on the
collection revision, so a response that crosses a local withdrawal is discarded.
`NativeCollectionReconciliation` validates an instruction against the retained plan;
a changed state version, consent, publication, revision, window or source refuses it.

Each instruction owns a separate historical query, keyed by its `id`. Ordinary
query planning ignores it, and `nativeReconciliationSelection` is the only path that
supplies an ended enrollment to acquisition: as a temporary snapshot restricted to
that one requirement, with the lease as its acquisition deadline.
`retainCollectionSnapshot` rejects that temporary snapshot. Whole-overlap selection,
conversion identity, staging and delivery are the ordinary ones, so a session that
was already uploaded keeps its identity. `stage` rechecks lease, collection revision
and query in its transaction; expiry, withdrawal, cancellation and a full queue keep
the previous cursor. The sweep ends when an empty page is staged. Its completion is
then reported through `.../collection-reconciliations/{reconciliationId}/complete`
until the server acknowledges it; a lost acknowledgement is retried without another
HealthKit query. Completion states that the bounded query was exhausted once, not
that every later source publication was captured or that uploads finished. HealthKit
has no insertion-time filter, so `issuedAt` is never used as a measurement bound.
The lease is evaluated on the device clock, like the enrollment end.

The native HealthKit adapter has no network client. It uses the retained plan,
source binding and local session checks on each page. Foreground sync refreshes
source and collection authority once; an unavailable network preserves previously
accepted collection. Background observer capture makes no HTTP requests. Initial
setup still requires successful server discovery and source registration. Uploads
remain separate: a full queue preserves the uncommitted page while foreground
delivery can free space, and ending collection does not discard pending custody.

Native account restoration uses the retained, configuration-bound identity without
first requiring a token refresh. Expired access tokens alone do not end local
collection; authenticated requests still obtain a usable token. A temporarily
unavailable keychain leaves credentials intact and restoration retries after device
unlock. SDK state changes persist token rotation or clear a confirmed invalid
session even after a waiting request was cancelled. These native changes still
require Apple-platform verification. Offline profile/navigation availability is a
separate remaining acceptance check; restoring identity does not establish that a
server profile was loaded successfully.

The enrollment UI persists a local stop before its withdrawal request, including
before device setup. A failed network request leaves collection stopped and shows
withdrawal as pending until the server confirms it. Reopening restores that state
from the same account-bound journal. New settings and remote withdrawals become
known through foreground refresh; the receiver checks current authority
independently at upload.

Initial setup fixes a live query boundary for its first measurement profile. Each
additional requested profile has its own live query and independent historical queries. `healthKitQueryPlan(for:state:)` creates
independent historical queries for earlier accepted measurements and newly eligible
gaps. Reconciliation records consent IDs alongside query creation in one journal
transaction; a broader consent can require a new backfill even inside an existing
query's date range if its cursor previously skipped unauthorized measurements.
Overlapping study requirements share queries. Existing anchors and source identity
are preserved; capacity failures roll back both new queries and reconciliation.

When an accepted configuration disables a measurement or routes, existing cursors
continue in `retractionsOnly` mode while the enrollment remains active. New samples
are ignored without loading route locations. Only deleted UUIDs in the durable
conversion index produce retractions, including records whose earlier delivery may
have uncertain custody. This index survives receipt-based payload pruning and restart;
no new history query is created for a disabled stream. Local withdrawal and enrollment
end stop this maintenance as well. Re-enabling a stream creates independent backfill
queries for newly authorized gaps, even if deletion processing advanced an old cursor.

Each native catch-up pass services each live measurement query first, then the least
recently served pending query, with at most eight pages total. Page ordering and sweep
progress survive restart and observation-only authority refreshes. Only an empty
raw HealthKit delta exhausts a query for that sweep; filtering every sample out of
a page does not. Later sweeps revisit historical predicates for late imports and
explicit deletions. Point-only profiles, including body weight, partition sample start
dates into half-open ranges. Period and dual-shape profiles, including heart rate,
sleep and workouts, include complete intervals overlapping the selected range.
An interval can be observed by more than one query. The journal retains the first
conversion time per native UUID and converter configuration across queries and
restarts. An unchanged sample therefore reuses its record version and exact payload;
new study targets can still produce a distinct delivery intent. This index counts
toward the configured journal byte limit. Capacity failure preserves existing cursors.
Application build, host facts, writer revision, and export policy identify the converter configuration;
a changed configuration records its own conversion time.

Point measurements use half-open windows. Interval records are selected in full when
they overlap an accepted window, including heart-rate, sleep and workout records that
cross a boundary. `ParticipantCollectionSnapshot` applies that same rule when selecting
consent IDs and selects at most one consent per study. Query and source identity must
not depend on clipping a record to a study window.

Query definition version 7 applies these temporal rules to each exact native stream.
Retained version 6 queries and anchors remain readable and immutable. A version 7
query safely replays authorized history using a new cursor; shared native-record and
conversion identities deduplicate unchanged samples across the transition. Pending
version 6 delivery bytes are never reinterpreted or rewritten.

Published collection-policy schema 4 includes the explicit enrollment period: an
optional Gregorian calendar duration from enrollment, a fixed closing date, or
both (earliest wins). Neither means ongoing enrollment. Creation resolves the
rule from the database's stored enrollment timestamp and retains `endsAt` in the
same transaction. Later publication/adoption never renews an existing end.
The enrollment editor configures this rule and publication includes its translated
text in retained consent. Dates are distinct from historical measurement windows.

At or after the retained end, the server refuses new consent commands while
preserving exact receipt replay. Previously collected pre-end measurements can
still be admitted under their original consent; timestamps at the end are
excluded. Withdrawal and source revocation retain their independent restrictions.
Apple-platform and physical-device acceptance remain separate gates from portable
journal tests; the native scheduler has not yet completed those gates.

## Record Representations and Receipts

An accepted clinical version may have several byte representations: equivalent JSON
serialization, a changed enrollment snapshot outside the clinical version, or another
report of the same whole-record retraction. These share the server `eventId`, but each
receipt binds its exact submitted bytes through `payloadSHA256`, with its own
`receivedAt` and `nodeCount`. Clinical facts, versions and study grants are not duplicated. The journal stages distinct
byte-and-target commitments separately and reuses the retained delivery ID for an exact
duplicate, including one with an already verified receipt.
New representations still require validation, current collection authority and an audit
record. Changed clinical tokens under the same version or changed study targets conflict.

Receipt lookup returns 404 for a payload digest whose bytes have not been accepted,
even when the clinical version is known. The client then resubmits the staged bytes for
validation. Only a receipt matching the original source, producer identifier, payload
and target-intent digests permits retirement. Already retained receipts remain
recoverable after withdrawal or source revocation without restoring study access.

## Event Batches

`POST /participant/sources/{sourceId}/events/batch` submits 1–16 events for one
owned, active source. Use the existing `EventSubmission` representation: canonical
base64 of each original event and its exact consent/output targets. The envelope
defaults to 6 MiB, with at most 5,592,408 bytes across the base64 strings.
Deployment settings may raise these to the shared wire ceilings of 24 MiB and
22,369,624 bytes respectively; clients must use the deployment's operating policy.

The ordered response contains one custody receipt or `ProblemDetails` per event.
An outer HTTP 200 does not mean every event was accepted. Each event commits
independently; malformed encoding, a consent rejection or a conflict does not
roll back other members. Accepted receipts remain stable on exact replay;
rejection results are not persistent receipts and can change with retained state.

After a lost response, recover each member's original receipt before resubmitting
unchanged bytes and targets. Apply bounded backoff to transient problems and
retain permanent rejections for inspection. Processing is sequential, not a
background job.

## Record Bundle Delivery

The durable drainer uses `POST /participant/sources/{sourceId}/record-bundles`.
Grove's packer combines up to 16 compatible records and states shared entries once.
Active records and retractions travel separately, as do different versions of the
same source record. The Bundle is transient: the journal continues to store each
original canonical one-record Bundle and its exact consent targets.

Each member carries its receipt commitment and original entry order. The receiver
validates the transport graph, restores the original record by splicing unchanged
entry tokens, and checks the payload digest before full record validation and
atomic admission. Missing or repeated commitments reject the envelope before any
admission. A record's validation or authorization failure does not discard accepted
siblings. Rejected records and transport-only framing are not retained as custody.

The default decoded transport budget is 4 MiB plus 1 KiB for framing, with a
4 MiB record budget and 6 MiB JSON envelope. `EventSubmissionLimits.Configuration`
accepts independently configured budgets up to 16 MiB per record, 16 MiB plus
1 KiB per transport Bundle and 24 MiB per JSON envelope, including consent targets.
The 512-entry record bound remains. Remaining records can be
regrouped or reordered on retry: receipts still bind their original bytes and
intent, independently of transport timestamps and shared-entry placement.

## Collection capacity

`EventDeliveryCapacityConfiguration(settings:)` validates deployment settings once
and supplies both journal staging and `EventDeliveryDrainer` packing limits. Use
the same configuration for both. `COLLECTION_MAX_RECORD_BYTES`,
`COLLECTION_MAX_BUNDLE_BYTES`, `COLLECTION_MAX_ENVELOPE_BYTES` and
`COLLECTION_MAX_BATCH_RECORDS` control admission and transport. A Bundle must leave
at least 1 KiB above the configured record budget; its envelope must accommodate
base64 expansion and framing. Exact encoded envelopes are checked when packing.
Only whole records move between Bundles. A record that cannot fit the local
operating budget stays pending and reports capacity backpressure; raising the
budget permits retry without changing its bytes or identity.

Pending storage has independent settings: `COLLECTION_MAX_PENDING_BYTES` (64 MiB
by default), `COLLECTION_MAX_DATABASE_BYTES` (128 MiB; at least 136 KiB, the room an empty journal needs),
`COLLECTION_MAX_RECORDING_BYTES` (128 MiB per recording), and
`COLLECTION_MAX_PENDING_RECORDING_BYTES` (1 GiB). Count settings are
`COLLECTION_MAX_PENDING_EVENTS` (2,048), `COLLECTION_MAX_QUERIES` (2,048), and
`COLLECTION_MAX_RECORDING_FILES` (4,096). Invalid values fail configuration. Lower
new-record budgets do not erase already staged work or change custody commitments.
Staging above a budget fails before advancing its query cursor.

The native app reads these decimal-string values from the signed Info.plist
`TroveCollectionCapacity` dictionary. Debug launches may override individual keys
with environment values. Server upload stored/decoded limits and study-export and
recording-download budgets remain independent and must be sized for the deployment.
Defaults retain existing behavior; the larger bounded options are not claims of
measured peak-memory suitability. Verify representative complete-record and
continued-collection workloads before selecting larger deployment values.

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
neither the cursor nor local queue ordering. Established journals must
be opened explicitly and are never silently recreated or migrated.

The caller owns source registration, FHIR transformation, authenticated transport
and bounded source queries. Register an immutable query definition with each
source; additional immutable ranges use independent queries under that same source.
Never reset a retained anchor or generate a replacement identity to widen a range.
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
the first device unlock. Logical payload/intent/setup/query/cursor/collection-plan byte and event quotas, and an independent
SQLite database-size limit provide backpressure; reserve additional disk space
for the rollback journal. Fixed-size receipt/metadata overhead is covered by the
physical limit. Full storage never silently evicts pending work.

## Authenticated Delivery

`EventDeliveryDrainer` performs a bounded pass over ready journal entries using
source-specific Bundles, the generated client and a captured-session validator. Construct it for
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
consent intent and original entry addresses, and flushes before crossing a bound,
changing source or kind, or encountering another version of a packed source record. A short,
extra or malformed batch result list retains every member with backoff. Complete
receipts are verified against their original positional commitments; one invalid
receipt cannot retire another event. Any 401 in a batch stops that instance before
storing the response's sibling receipts. Accepted receipts can still be recovered
later using a newly authenticated, correctly scoped drainer.

The caller schedules passes. There is no internal timer, independent token manager
or separate collector checkpoint authority. Formats 17 and 18 upgrade in place; any earlier
journal format requires a fresh development journal.

## Grove Development Dependency

API, server and iOS pin Grove commit
`7193096b38960ea71af54b28c3a49369ddb37b21`, the top of Grove's unreleased collection stack
(branch `provider-converters`), which builds on
[Grove #144](https://github.com/SchmiedmayerLab/Grove/pull/144). It
provides typed source metadata, recording-device mappings, complete recording periods,
file-backed recordings, the collection catalog and the provider and SensorKit converters
for the stateless Bundle exchange. `GroveConsent` supplies the shared consent
document format. Stable Xcode 27.2 (27B52) generated the iOS lockfile; Apple compilation
and simulator checks are separate verification gates.
Resolve each package and the Xcode project with their checked-in lockfiles;
local editable overrides are not adoption evidence.

This remains a development revision. Grove's producer conformance source and
Trove's validator source/package closure have separate identities. The validator
manifest is not advanced merely because the Swift dependency builds. The
[released-dependency gate](https://github.com/SchmiedmayerLab/Trove/issues/82)
still requires reviewed releases, matching package inventories and the affected
producer/receiver and consent/collection checks on that final graph.
