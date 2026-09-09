<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Applications and Integrations

Trove is designed as a shared study backend, not a requirement to use one participant interface. Applications can adopt common enrollment, task and data services while retaining their own navigation, branding, assessments and domain-specific behavior.

The integration boundary is a versioned contract and a scoped identity—not shared access to backend databases. The capabilities below follow the [roadmap](Roadmap-and-Engineering-Principles.md).

## Swift Where It Helps, Native Clients Where They Matter

Swift is the preferred language for the server and iOS application. Grove provides reusable definitions, conversion, questionnaire, scheduling and inference foundations.

The web dashboard and browser experiences use TypeScript, while Android retains native Kotlin integration, including platform-specific health collection. Shared formats and conformance fixtures are more important than forcing every implementation into one language.

A portable Swift library may be useful on Android or WebAssembly when it reduces repeated domain logic. Adoption should depend on measurable benefits in maintenance, packaging, performance and dependency support. It is not a prerequisite for Android participation or browser questionnaires.

This approach separates stable shared meaning from operating-system behavior. Background collection, permissions, notifications and user interfaces remain native responsibilities where necessary.

## Scheduler Synchronization

Apple clients use GroveScheduler as a persistent local view of assigned tasks, schedule revisions and accepted outcomes. Keep SwiftData's default store and route downloaded changes through one Scheduler-owned import path. Supported container configuration enables account-scoped persistence; it does not imply automatic synchronization, compatibility with every custom store, or support for other contexts writing scheduler models.

Import exact task versions and outcome identities without issuing new completion commands. Version identity combines the stable task ID and immutable effective boundary; occurrence identity also includes its start. Successful imports refresh queries and reconcile reminders. A schedule revision applies at its approved boundary; reject changes that would reassign or hide accepted outcomes. A stale completion cannot satisfy a replacement occurrence.

The application owns transport, account scoping, acknowledgement and late-completion policy. Persist offline commands before showing pending completion, keep pending presentation separate from accepted history, and retain commands until explicit backend disposition. Restart replays the outbox and resumes server snapshots/deltas; imports cannot discard unsent work. Library persistence notifications report commits or failures, not backend acceptance. Reconcile reminders on activation as well as after commits.

SwiftData history remains useful for optional incremental change discovery, but records changes rather than immutable copies of original commands. It is not a substitute for the outbox, and its store-local tokens are not server cursors. A custom data store or direct external-context synchronization can follow when a concrete integration justifies its additional persistence and cache-coherence work; neither is required for the first implementation.

## Device Collection and Connected Wearables

A study may receive data through a mobile health store, a device-specific collector or a server connection to a wearable provider. These routes can provide different resolution, timing and provenance even when they refer to a similar health concept.

The definition names the accepted output and allowed source routes. The implementation admits only the mappings it can faithfully produce and operate. Support for a provider does not imply support for every device, data category or historical window that provider offers.

Cloud acquisition has four separate responsibilities:

| Responsibility | Meaning |
|---|---|
| Provider registration | The approved application integration, endpoint, region and permitted scopes |
| Participant connection | A verified upstream account binding and protected credential state |
| Study collection grant | The enrollment's permitted categories, sources and collection windows |
| Synchronization state | What has been fetched and durably accepted, independently of individual studies |

Keeping these records separate permits one connection to serve multiple authorized studies without creating duplicate tokens, polling jobs or payloads. Reuse is limited to the same governed identity and deployment scope; it does not promise portability between unrelated provider registrations or institutions.

Account control also does not prove that every record belongs to the participant. Shared devices and household profiles need an unambiguous subject binding. Reconnecting the same verified account differs from replacing it with another account.

### Credentials and Collection Lifecycle

The backend uses the provider's supported secure authorization flow, with bound redirects, expiring state and proof-key protection where supported. Provider credentials remain in protected server storage; clients receive connection status, not reusable tokens.

Application secrets and participant tokens have separate lifecycles. Credential rotation and synchronization coordinate across workers. If an upstream rotation succeeds but local persistence is uncertain, recovery follows the provider's supported process or requires reauthorization. Blindly retrying an obsolete credential is not a reliable recovery strategy.

Collection follows the union of active authorized study demands. A study withdrawal removes its own demand; disconnecting the provider stops the whole connection. When no demand remains, polling stops. Keeping a dormant connection for future use requires an explicit purpose and retention policy.

### Frequent Pulls Without Unbounded Polling

Synchronization combines provider-supported notifications with scheduled reconciliation. Notifications are hints to check authorized work, not permission to fetch an entire account.

Cadence depends on the study's freshness needs, source behavior, quotas and deployment capacity. Durable checkpoints advance only after accepted data or an explicit disposition. Historical backfill has its own budget so it cannot starve current collection.

The operational model distinguishes last attempt, last successful fetch, accepted-through time, provider delay and connection failure. An empty response is not proof of deletion, and a recent successful request is not proof of complete coverage.

The shared Swift conversion product covers Google Health API, Oura and Withings through separate typed converters and a checked mapping matrix. Withings body measurements provide the first end-to-end engineering fixture, not a provider limitation. Converter increments can activate independently; full catalog implementation is not a gate for a tested pilot subset. Each provider connection still has separate access, mapping and operational requirements. Catalog representation and provider permission are different prerequisites.

## Durable Collection and Client Recovery

Native collection acknowledges source delivery only after immutable events and required files are durably staged. The source cursor can then advance independently of network availability. Upload uses bounded batches and per-event receipts; partial acceptance cannot discard the unaccepted remainder.

A receipt must state the receiver's durable acceptance boundary. An accepted event transfers custody to the receiver, allowing local retirement even if its graph still awaits references. Acceptance, graph readiness and study access are separate states; pending data is not available for study use merely because it reached the server. Transport success alone is insufficient. An uncertain response is retried with the same event identity and content, not reconstructed as a new measurement.

Local queues isolate accounts and source scopes, bound disk and memory, and apply backpressure without silently dropping accepted source data. Required cases include restart between staging and cursor advancement, interruption during receipt processing, missing files, disk exhaustion and account switching. File-backed conversion has explicit ownership and lifetime; cancellation must not delete caller-owned files.

The same principle applies to task outcomes. Durable local import preserves the server's execution IDs and timestamps without emitting another completion command. Reinstall restores acknowledged server state, not unsynchronized work erased with the application.

### Share Mechanisms After Proving Them

Incubate delivery changes in Trove, then extract a small Grove adapter once two configurations demonstrate the boundary. Keep source-specific collection policy, assessment UI, scoring, routing and study-specific delays in their owning application. Conversion remains a pure mapping layer, separate from OAuth, polling and authorization.

Existing MHC and Plainly deployments stay pinned until their owners approve adoption. A migration preserves identities, queues, consent and historical outcomes, rehearses cutover and documents rollback limits. Offline output comparison is preferable to duplicate live collection. Provider-neutral inference receipts and explicit history modes belong in GroveLLM; distributed reservations, credentials and task authority belong in Trove.

## Conversation Studies Through a Shared Gateway

A conversation task is a published study component with a versioned intervention configuration. It identifies the approved connection and model policy, system prompt, allowed context, completion rule and usage limits.

Trove uses GroveLLM as the inference abstraction rather than implementing a parallel provider stack. The initial deployment route targets the Stanford AI API Gateway. A provider registry can support other routes later without binding the study model to one vendor.

The selected route must be approved for the intended data and use. Stanford's [Gateway guidance](https://uit.stanford.edu/service/ai-api-gateway/faqs) distinguishes technical access from the required review for high-risk data. A working credential is not approval, and failure must not silently redirect a request to another provider.

### Configuration and Credential Ownership

Researchers configure capabilities that the server actually supports. The first conversation path uses text and a system prompt; retrieval, image capabilities and additional channels are separate extensions.

The dashboard can register a protected API credential for an authorized connection. Subsequent reads expose status and a short identifying suffix, not the saved secret. Study revisions bind the approved connection/model policy, while each request records the secret version used. Equivalent key rotation does not rewrite study content; a material routing or policy change requires review. Neither version embeds the secret in participant configuration.

Participant inference and investigator authoring are separate purposes with separate permissions and budgets. An authorized institutional, group or personal authoring connection may be selected where supported. A user's preference cannot change the route of an already published intervention, and one purpose must not silently exhaust another's allocation.

### Eligibility on Every Turn

Authentication identifies the caller. It does not establish an eligible conversation task. The gateway checks the participant's enrollment, consent, occurrence window, unfinished state and permitted context when admitting a session and each new turn.

History access is authorized separately from generation. A participant may be allowed to read a completed conversation without being allowed to request another answer.

Durable session, message and generation identities support reconnecting after interruption. Usage is reserved before dispatch and reconciled against the available provider result. Concurrent requests cannot escape shared limits by reaching different server instances. An uncertain provider outcome remains explicit; retrying delivery must not request a second answer.

### A Clear Completion Rule

The initial rule is participant Finish after at least one durable participant/assistant exchange. The completion operation closes further turn admission, seals the accepted message set and prevents active or late generation from changing the completed result. Usage reconciliation can continue separately.

A generated answer, quota exhaustion or leaving the screen does not by itself complete the task. Accepted completion can enable an exact-version follow-up questionnaire.

This rule records participation, not scientific adequacy or intervention success. Researchers determine suitability. Optional example-question previews and technical rehearsals use synthetic context and separate budgets; they are not clinical validation services.

## Study-Scoped Retrieval

Retrieval adds a published knowledge source to a conversation; it does not create permission to search all participant data.

A corpus consists of governed original documents, extracted content, chunks and a pinned embedding configuration. Indexing is a bounded job with explicit failure state. A new version becomes available only after it is complete, while the previous published version remains stable.

Tasks reference an exact corpus version. Retrieval filters by the authorized study before loading content, and generated citations resolve to the material actually retrieved. A citation establishes source linkage, not the correctness of the generated conclusion.

The initial storage approach uses relational metadata, object storage and PostgreSQL vector support rather than a separate vector-database service. Approximate indexing should follow demonstrated scale and retrieval-quality needs.

Research literature and participant clinical context remain distinct data sources with different permissions. Retrieved text is untrusted content, not instructions granting tools or broader access. Required retrieval failure cannot be hidden by a silent fallback to unsupported behavior.

## Custom Applications and Services

A specialized application can use Trove for identity, consent, data or tasks without adopting every feature or the default UI. Registered clients have explicit audiences and redirect policies. Existing identities require a verified migration, not matching email addresses.

Study-specific services can continue computing derived statistics or other domain results. They receive narrow credentials for named studies and operations. Notifications identify work; the service retrieves only currently authorized inputs and publishes a versioned result through the appropriate API.

Each capability has one authoritative owner during migration. Keeping two systems writable without a clear reconciliation boundary risks conflicting consent, completion and data histories. Adoption therefore proceeds through a bounded capability and tested retained-data handling.

### A Constrained Extension Document Store

Small custom records—preferences, derived display statistics or app-specific results—do not all belong in the clinical schema. A separate document service provides this flexibility through registered contracts.

A contract declares its namespace, schema version, owner, permitted fields and operations, supported indexed queries, retention and quotas. Clients use bounded queries, conditional updates and explicit conflicts. Arbitrary queries, uploaded executable rules and raw high-volume measurement arrays are outside this service.

The service has its own storage credentials and no direct core-database, consent or inference-secret authority. It checks current authorization through the core interface. Network and credential separation reduce the consequences of a compromise; they do not make the services literally air-gapped.

Core consent, assignments and task completion cannot be replaced by custom document fields. Large recordings use the shared artifact mechanism. Custom JSON does not become FHIR merely because it is stored alongside research data.

### App-Owned Assessments and Shared Results

An application owns the procedure, acquisition interface and scoring of a custom assessment, including a six-minute walk test or guided ECG capture. Its immutable study configuration describes the required app capability and result contract.

A document write does not automatically complete a core task. Optional shared tracking submits an immutable receipt for an accepted result through the normal completion operation. The [data architecture](Data-and-Platform-Architecture.md#retention-erasure-and-result-availability) defines how acceptance and later erasure remain consistent.

When multiple applications need the same assessment mechanism, it can move into a shared package or Grove. The evidence of reuse should precede the abstraction.

## One API for Dashboards, Command-Line Tools and Assistance

Dashboard operations and command-line operations are peers over one authorized application API. The command line provides structured results, explicit revisions and bounded commands suitable for human use or delegated automation.

Generated proposals use the same draft, validate, preview and apply operations as manual changes. Publishing, participant contact, allocation, data release and credential management remain separately authorized actions. Documents, model output and task instructions cannot broaden a caller's scope.

## Participation Channels

Browser participation begins with authenticated content and the supported Questionnaire subset, using the same exact-version validation and occurrence commands as mobile clients. An authoring preview is not a participant session. Drafts remain account-scoped and distinguish pending work from accepted completion.

Text-message and voice participation follow only for a selected study and approved route. Contact details require verified binding; a phone number or caller ID alone is not identity. Task-bound sessions, appropriate step-up verification, authenticated callbacks and replay checks protect handoff and completion. Reassigned numbers and opt-out must invalidate affected channel access without silently rewriting enrollment.

A channel must faithfully support the approved instrument and response semantics. Unsupported questions use an approved secure web fallback, not an improvised conversational replacement. Uncertain speech answers need confirmation; raw audio retention is off unless authorized. Channel provenance and exact instrument/item identities remain part of the result.

## Coexistence with Other Research Systems

Trove does not include a REDCap importer, synchronization service or dedicated exchange API in the active roadmap. Studies can keep other research systems independently; Trove provides authorized exports with stable identities, versions and provenance.

If a named study later needs interoperability, assess one narrowly scoped external adapter against that study's mappings and authority rules. Do not add generic field mapping, conflict reconciliation or bidirectional editing to the core platform preemptively. An external record must never create Trove consent or bypass normal authorization and validation.

[Platform Overview](README.md) · [Implementation Project](https://github.com/orgs/SchmiedmayerLab/projects/4)
