<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Applications and Integrations

Trove provides a Swift server, an iOS participant app, a Swift researcher CLI and
a TypeScript dashboard. Clients use the same authenticated HTTP API; they do not
connect directly to the database or object store.

The [platform tour](Platform-Tour.md) shows the available interfaces.
The integration designs below identify capabilities that are still planned;
delivery status is maintained in [GitHub milestones](https://github.com/SchmiedmayerLab/Trove/milestones).

## Current Clients

The iOS app uses Grove for shared application components and FHIR conversion.
HealthKit acquisition policy belongs to TroveHealthKit and the app; the durable
delivery journal belongs to TroveAPIClient. This separates collection from
transport and allows uploads to resume after interruption.

The dashboard provides study configuration, consent editing and publication.
The [researcher CLI](https://github.com/SchmiedmayerLab/Trove/blob/4273560d0c3e6454219995b649d56dce1e234135/TroveAPI/CLI.md)
uses Swift Argument Parser and the generated OpenAPI client. It accepts an
already-issued access token; interactive login and token renewal are not yet
provided. Its guide lists the supported commands and output formats.

Custom applications can use the API without adopting Trove's navigation or
branding. Specialized acquisition interfaces and scoring remain application-owned.
A six-minute walk test or guided ECG assessment, for example, does not require a
new assessment engine in Trove.

## Durable Collection and Client Recovery

The client stages immutable events and required files before acknowledging source
delivery. The source cursor can then advance independently of network availability.
Bounded uploads return per-event receipts; partial acceptance leaves the remainder
queued. An uncertain response is retried with the same identity and content.

A receipt distinguishes durable acceptance from graph readiness and study access.
A stored event may still await a referenced resource. Storage alone does not make
that event available to a study.

Queues isolate accounts and source scopes. Disk limits apply backpressure rather
than silently dropping work, and cancellation does not delete caller-owned files.
Reinstall can restore server-acknowledged records, not unsynchronized work erased
with the application.

## Planned Scheduler Synchronization

The synchronization design treats GroveScheduler as the Apple client's persistent
view of assigned tasks, schedule revisions and accepted outcomes. A Scheduler-owned
import path applies server state without issuing completion commands again.
SwiftData remains the local store; automatic backend synchronization is not implied.

Task versions combine a stable task identifier with an immutable effective boundary.
Occurrence identity also includes its start. Schedule updates take effect at an
approved boundary and cannot reassign accepted outcomes to a replacement occurrence.

The application owns transport, account scoping and a durable outbox of offline
commands. Pending completion remains distinguishable from accepted completion.
Snapshot or delta imports preserve unsent work, refresh queries and reconcile
reminders. Persistence notifications report local commits or failures, not server
acceptance.

SwiftData history can help discover local changes, but it does not preserve the
original commands and its tokens are not server cursors. A separate outbox is
therefore necessary even when history is available.

## Planned Device and Wearable Connections

Study definitions separate the requested data from permitted acquisition routes:
a mobile health store, an app-specific collector or a server connection to a
wearable provider. These routes may differ in resolution, provenance and delay.
Provider support does not imply support for every device or historical window.

Server connections separate four records:

| Record | Purpose |
| --- | --- |
| Provider registration | Approved integration, region, endpoints and scopes |
| Participant connection | Verified upstream account and protected credentials |
| Study collection grant | Authorized categories, sources and collection windows |
| Synchronization state | Fetched and accepted data, independently of any one study |

One connection can serve several authorized studies without duplicating credentials,
polling jobs or source events. This reuse is limited to the governed identity and
deployment scope. Shared devices require an unambiguous subject binding; account
control alone does not prove that every record belongs to the participant.

Authorization uses bound redirects, expiring state and proof-key protection where
supported. Provider credentials remain on the server. Rotation coordinates across
workers, including recovery when the provider changes a token but local persistence
fails. Clients receive connection status, not reusable tokens.

Polling follows the union of active collection grants. Withdrawal removes one
study's demand; disconnecting stops the whole connection. Notifications prompt
reconciliation within existing permissions. Checkpoints advance after durable
acceptance, and backfill has a separate budget from current collection.

Operational status distinguishes last attempt, last successful fetch,
accepted-through time and provider delay. An empty response does not establish
deletion or complete coverage. Grove FHIR mappings for providers such as Oura,
Withings and Google Health API inform conversion; each connection also needs its
own provider access and operational verification.

## Planned Questionnaire and Android Integration

A Questionnaire version is one multilingual FHIR resource. Clients select the
session's admitted language without changing item identities, conditions or answer
values. Standalone translated Markdown and PDF files remain separate artifacts.
The [localization contract](Study-Model-and-Research-Workflows.md#localization-sites-and-accessibility)
defines approval, fallback and round-trip requirements.

Android integration will use Kotlin foundations; the dashboard remains TypeScript.
Shared Swift code on Android or WebAssembly is an option only where it reduces
maintenance and has suitable dependency support. Permissions, background collection,
notifications and UI remain platform-specific.

## Planned Conversation Gateway

A conversation task binds a published intervention configuration: connection,
model policy, system prompt, allowed context, completion rule and usage limits.
The server design uses GroveLLM for inference, beginning with text and a system
prompt. Retrieval, images and additional channels are separate capabilities.

The intended first route is the Stanford AI API Gateway. A deployment still needs
approval for its data and use; the [Gateway guidance](https://uit.stanford.edu/service/ai-api-gateway/faqs)
describes that review. A working credential is not approval, and a failed route
cannot silently fall back to another provider.

### Credentials and Turn Admission

Authorized researchers register credentials through the dashboard. Subsequent
reads return status and an identifying suffix, never the saved secret. Study
revisions bind the connection and model policy; requests record the credential
version used. Material routing changes require review.

Participant inference and researcher authoring have separate permissions and
budgets. Each turn checks enrollment, consent, the occurrence window, unfinished
task state and permitted context. Reading a completed conversation is a separate
permission from generating another answer.

Durable session, message and generation identities support reconnecting. Usage is
reserved before dispatch and reconciled afterward across server instances.
An uncertain provider result remains unresolved until reconciled; retrying delivery
must not generate a second answer.

### Completion and Review

The initial completion design is an explicit participant Finish action after at
least one stored participant/assistant exchange. Completion seals the accepted
message set and closes further turn admission. Leaving the screen, receiving an
answer or exhausting a quota does not itself complete the task.

Study-scoped reviewers will assess exact transcript snapshots using versioned
conversation- and message-level rubrics. Submitted assessments retain reviewer
identity and correction history. Transcript access requires specific review
permission and an audit record; ordinary dashboard access is insufficient.

These assessments do not establish clinical safety or provide real-time monitoring.
Research teams remain responsible for intervention suitability and any required
human support.

### Study-Scoped Retrieval

The retrieval design binds tasks to a published corpus version: original documents,
extracted content and a pinned embedding configuration. Relational metadata,
object storage and PostgreSQL vector support avoid a separate database initially.

Indexes become available only after a complete build. Retrieval applies study
authorization before loading content, and citations identify the actual source
passages. Literature and participant clinical context have separate permissions.
Retrieved text cannot grant tool access, and required retrieval failures remain
visible rather than producing an unsupported answer.

## Planned Custom Services

Study-specific services can compute derived statistics or other results using
credentials limited to named studies and operations. Notifications identify work;
the receiving service still checks current access before retrieving inputs.

### Extension Document Store

A separate service is planned for small app-specific records such as preferences
and derived display statistics. Each namespace declares a schema version, owner,
allowed fields and operations, indexed queries, retention and quotas.

Clients use bounded queries and conditional updates. Arbitrary executable rules
and high-volume measurement arrays are outside this service. Large recordings use
artifact storage instead.

The service has separate storage credentials and no direct access to core tables
or inference secrets. It obtains current authorization through the core API.
Consent, assignments and task completion remain core records, not custom fields.
An optional result receipt can connect an accepted custom result to a task; a
document write alone does not complete it.

The [result-availability design](Data-and-Platform-Architecture.md#retention-erasure-and-result-availability)
covers later erasure without rewriting completion history.

## Planned Authoring Assistance

Hosted assistance will call typed API operations directly. It uses the same study
drafts, validation and revision checks as the dashboard and CLI. Uploaded documents
and generated text are inputs, not sources of authority.

Delegation is study-scoped, expiring and revocable. Effective access is the
intersection of the researcher's current authority, registered-client restrictions
and the grant. The initiating researcher and executing client are recorded separately.
Publication, participant contact, exports and credential administration retain
separate permissions.

Questionnaire tools import and export the complete multilingual JSON. A language
selection changes diagnostics or preview, not the stored instrument. Applying a
proposal requires the current draft revision, and translation assistance does not
approve the resulting content.

Optional Swift MCP and researcher-voice adapters can expose these same operations
without a separate authorization model. Voice is an authoring interface, not a
participant channel. Text and visual review remain available, particularly for
ambiguous targets and consequential actions.

## Future Participation Channels

Browser questionnaires will require authenticated sessions and the same
exact-version validation and completion rules as mobile clients. An authoring
preview is not a participant session.

Text-message or phone participation additionally requires verified contact binding,
task-bound sessions, authenticated callbacks and replay protection. Caller ID alone
is not identity. A channel must support the approved instrument; unsupported
questions need an approved alternative rather than an improvised replacement.
Raw audio retention requires explicit authorization.

## Other Research Systems

Trove has no REDCap synchronization service or dedicated exchange API.
Interoperability work will use study-specific adapters and authorized exports with
stable identities, versions and provenance. An external record cannot establish
Trove consent or bypass validation.
