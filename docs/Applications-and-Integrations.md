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

## Current Clients

The iOS app uses Grove for shared application components and FHIR conversion.
HealthKit acquisition policy belongs to TroveHealthKit, SensorKit acquisition to
TroveSensorKit, and the durable delivery journal to TroveAPIClient. This separates
collection from transport and allows uploads to resume after interruption.
SensorKit collection is built only when the `TROVE_SENSORKIT_ENABLED` build
setting is on; it is off by default and requires Apple's research entitlement.

The dashboard provides study configuration, health-collection settings, consent
editing, publication and a results page for study-scoped data and recording
downloads. The [researcher CLI](https://github.com/SchmiedmayerLab/Trove/blob/main/TroveAPI/CLI.md)
uses Swift Argument Parser and the generated OpenAPI client; `trove study data`
retrieves the same study-scoped data. It accepts an already-issued access token;
it does not provide interactive login or token renewal. Its guide lists the
supported commands and output formats.

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

Accepted collection plans are retained on the device, so collection continues
offline until the enrollment ends. Withdrawing in the app stops local collection
immediately, before the server is reached; other devices learn of it when they
reconnect. Sleep and workout sessions that finalize after an enrollment ended are
collected once through a bounded, server-issued reconciliation instruction rather
than by ordinary planning.

The server keeps one logical source per participant and native repository.
Each installation registers its own credential and recovers the server-held
identity context, so a reinstall or second iPhone produces the same source and
record identifiers for the same HealthKit sample. Revoking one installation does
not replace the shared identity.

## Device and Wearable Connections

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

Registrations, participant connections, link intents and polling workers are
implemented, but a deployment collects from a provider only after an operator
configures approved registrations, secrets and an HTTPS callback. Without that
configuration, provider capability lists are empty and the app explains that
connecting is unavailable. [Provider collection](Provider-Collection.md)
describes the configuration and the currently qualified acquisition client.

## Other Research Systems

Trove has no REDCap synchronization service or dedicated exchange API.
An external record cannot establish Trove consent or bypass validation.
