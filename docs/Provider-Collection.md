<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Provider collection

Provider collection uses deployment-approved registrations and participant-linked accounts. A registration declares its controller, region, OAuth client, approved HTTPS callbacks, source tokens and scopes. A study selects the exact registration, source token and output profile. Linking an account does not authorize collection by itself: the worker also checks accepted study requirements and current enrollment authority.

The runtime qualifies the Withings numeric `getmeas` client. The capability endpoint intersects approved registration tokens with this implemented acquisition client and the converter's exact output profiles. Oura and Google authorization clients do not by themselves qualify their clinical endpoints. Do not approve a registration for a source whose native identity, time coordinates, selected fields and query coverage have not been qualified.

## Deployment configuration

Set `PROVIDER_CONFIGURATION_FILE` and `PROVIDER_SECRETS_FILE` together to absolute, operator-managed files. Without both settings, participant linking is unavailable, and provider capability and participant connection lists are empty; the app then offers no wearable services. Invalid configuration fails explicitly; startup never invents a vault key, subject namespace or converter identity.

The public configuration is version 1 and contains:

- `workerIssuer` and `workerClientID`: the deployment's authenticated worker identity used in audit records.
- `acquisitionFacts`: explicit `applicationName`, `bundleIdentifier`, `version`, `operatingSystemVersion`; optional `build`, `operatingSystemName`, `operatingSystemBuild`, `productType`, `model`, and `manufacturer`. These describe the actual converter and host, not an upstream recording device. Each page retains its facts across retries.
- `minimumDispatchIntervalSeconds`: an optional whole-second collection-dispatch interval from 1 through 3,600, default 5. This is a conservative operating setting, not measured throughput or a statement of an upstream provider's quota. Configure it for the provider's current quota and the requests each dispatch requires.
- `dormantCredentialRetentionSeconds`: 0 through 2,592,000 seconds. Reusable participant tokens are retired after demand has ceased and the retention deadline has passed. Current demand and unfinished bounded reconciliation are checked again under transaction locks before retirement.
- `registrations`: up to 128 entries, each containing `configuration` and an explicit `approved` boolean. A configuration contains `id`, `provider`, `displayName`, `controller`, `region`, `clientID`, `redirects` (`id` and HTTPS `uri`), `scopes`, `sourceTokens`, and `supportsPKCE`.
- `ouraGlobalScope`, when Oura source qualification is enabled: an immutable deployment-owned identifier `system` and `value`. It must remain stable across accounts and registrations; it is not a provider-owned identifier URI.

The secret document has this shape; the placeholders must be replaced with operator-provisioned values:

```json
{
  "version": 1,
  "currentKeyID": "vault-key-1",
  "keys": [
    { "id": "vault-key-1", "keyBase64": "<canonical Base64 of 32 random bytes>" }
  ],
  "applications": [
    { "registrationID": "<approved registration UUID>", "clientSecret": "<provider application secret>" }
  ]
}
```

The secret file must be a bounded regular file owned by root or the server user, without group-write or any other-user permissions. An operator-mounted read-only group-readable secret is supported. Vault keys encrypt participant credentials and account binding; they are separate from source-identifier keys. Retain prior decryption keys during rotation until their retained ciphertext has been handled. Missing keys never cause automatic replacement identities.

## Scheduling and recovery

After application boot, a cancellable worker processes one bounded page at a time. Provider-wide dispatch budgets and per-connection source rotation are persisted, so separate server instances share the same budget and restarting does not restart the source order. Ingestion independently verifies the registration, participant, connection generation, source, consent and checkpoint lease before any custody write.

A checkpoint binds its selected output profiles and their individual collection windows before the first request. A later consent cannot widen an in-flight request. Completed query coverage is tracked per profile and interval; adding another field creates work for that field without refetching already covered fields. Indexed interval queries consider the complete relevant history without a lifetime checkpoint-count ceiling. Empty completed pages establish only their exact requested coverage, never the presence of measurements.

Current study grants can reuse accepted custody from the same participant, logical source and verified provider account across registrations. This pass preserves the original record and Provenance, rechecks each current consent, and requires no upstream credentials or duplicate upload. Complete acquisition coverage may also be reused for that same identity; another account, a failed page or a partial checkpoint cannot supply it. Source correction polling remains a separate acquisition responsibility.

Transient failures retain their cursor and use persistent backoff. A validated `Retry-After` can extend that delay. Capacity, invalid-source and authority failures remain explicit operational outcomes; they cannot discard a record or advance the checkpoint. OAuth refresh is dispatched durably before its external request. An uncertain refresh requires reauthorization and is never replayed automatically.

Enrollment end stops forward polling. A finite reconciliation pass may revisit a closed accepted window for complete overlapping sessions that finalize or appear afterward. Its durable checkpoint retains the exact original window and a fixed measurement cutoff across pages; current withdrawal and source authority are checked again before fetching and granting. A wholly post-window record cannot gain authority from this pass. Completion does not promise that a provider will never publish a later correction or delayed session.

Each window has a finite page and failure budget (4,096 pages and 16 failed attempts). Exhaustion preserves incomplete coverage, the next cursor and retained records in a blocked checkpoint; it does not silently mark the window complete or restart it indefinitely. The existing elapsed-day window planning and configured dispatch budget govern reconciliation as well as ordinary backfill. No universal provider finalization delay is assumed.

A previously staged page may still drain its exact, authorized records after enrollment ends, including after reusable credentials expire or are retired. The retained collection timeline continues to bound every output. Withdrawal, explicit provider disconnection, registration revocation and source revocation fence the corresponding authority. Reopening never replaces staged bytes or refetches a staged page.

Credential retirement preserves the account binding, centrally provisioned source identity, accepted events and staged records. Relinking the same verified account reuses its stable identity; a different account receives a distinct account pseudonym. Separate registrations for the same participant/provider share the logical source namespace while retaining independent registration authority and study grants.

## Verification

Run the provider integration, recovery and precision tests with the server's documented test setup:

```sh
cd TroveServer
swift test --build-system native --jobs 2 --force-resolved-versions --no-parallel \
  --filter 'Provider.*Tests|ClinicalMeasurementPrecisionTests|FHIRMeasurementInstantTests'
```

Synthetic HTTP and validator boundaries test durable staging, restart, consent and exact identity without accessing live accounts. Official FHIR fixture validation, real PostgreSQL concurrency, live endpoint qualification and operational acceptance are distinct evidence. A converter fixture passing validation does not establish upstream query completeness, corrections or deletion semantics.
