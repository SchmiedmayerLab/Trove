<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Roadmap and Engineering Principles

Trove's development is organized around complete study workflows rather than a growing checklist of disconnected features. A useful release must connect researcher setup, participant experience, data handling and operations.

The milestones below describe the intended sequence, not announced release dates or claims that the capabilities have shipped. Detailed implementation progress belongs in the project's published issues and release notes.

## Foundation Checkpoint — 9 September 2026

M1 and M2 are complete at the reviewed implementation and local-verification
boundary. Trove PRs #75–#80 are merged at
`8288439e21b9f74b1357c21cba2c2518748f61c2`; the merged tree exactly matches the
reviewed combined tree. This is not a published release or production acceptance.

| Checkpoint | Completed work | Explicit follow-up |
|---|---|---|
| M1: IG Exchange Contract | Multi-study/historical-protocol examples; replay, correction, conflict, reference and retraction fixtures; implemented and locally verified HealthKit context correction | [#82](https://github.com/SchmiedmayerLab/Trove/issues/82), M3: upstream integration and released dependency adoption |
| M2: Reliable Shared Data Ingestion | Exact consent, verified token authority, immutable shared custody, independent study grants, durable delivery, audit, measured local ingestion, fresh-store recovery and shared verification/candidate mechanisms | [#83](https://github.com/SchmiedmayerLab/Trove/issues/83), M3: post-merge verification and durable evidence; [#84](https://github.com/SchmiedmayerLab/Trove/issues/84)/[#85](https://github.com/SchmiedmayerLab/Trove/issues/85), M3.1: approved publication and live protection |

M1 spans repositories. [grove-fhir #34](https://github.com/SchmiedmayerLab/grove-fhir/issues/34)
and [#35](https://github.com/SchmiedmayerLab/grove-fhir/issues/35) were merged in
[#41](https://github.com/SchmiedmayerLab/grove-fhir/pull/41).
[Grove #81](https://github.com/SchmiedmayerLab/Grove/issues/81) is implemented in
the still-open [#94](https://github.com/SchmiedmayerLab/Grove/pull/94); its final
integration remains M3 work. GitHub's repository-local milestone counts omit
these upstream issues. [Trove #74](https://github.com/SchmiedmayerLab/Trove/issues/74)
and the [project board](https://github.com/orgs/SchmiedmayerLab/projects/4) preserve
the cross-repository delivery record.

The demonstrated workflow stores an event once, authorizes two studies
independently, handles exact retries, withdraws one study without affecting the
other and preserves custody after backend restart. Simulator evidence is the
accepted client boundary. Physical-device background/protection, online disaster
recovery, deployed capacity and field use remain unverified until M3.1 acceptance.

Closing a milestone does not turn its transferred requirements into passed checks.
Publication still requires released dependencies, completed exact-source and
per-architecture verification, and independently enforced approval. The journal
remains in TroveAPIClient; optional extraction is [#25](https://github.com/SchmiedmayerLab/Trove/issues/25)
in M5. Large file-backed recordings remain conditional M3 work in
[Grove #82](https://github.com/SchmiedmayerLab/Grove/issues/82).

Next, finish #82/#83 while developing the synthetic single-arm study workflow:
portable publication and revision adoption, scheduled tasks, a Swift CLI, scoped
delegation and a shared Questionnaire editor/validator. Document-assisted authoring
then exercises those same APIs. Optional trial features do not gate the first study.

## Development Before Deployment

M1 and M2 establish exchange and ingestion contracts; they do not require a live
deployment. M3 builds the first complete study workflow with synthetic accounts.
Keep implementation acceptance, repository integration and field activation separate:

| Stage | Completion evidence | Not required at this stage |
|---|---|---|
| M1: IG Exchange Contract | Reviewed contract implementation, validated examples and producer/receiver fixtures; upstream release integration follows in M3 #82 | A running research deployment or completed upstream release |
| M2: Reliable Shared Data Ingestion | Real local stores; consent-backed two-study custody; durable delivery; failure, restart and recovery tests; measured workloads; shared verification and candidate mechanisms | A cloud account, production region, operational recovery targets, published candidate or human pilot |
| M3: Portable Study Execution and Agent-Ready Authoring | A synthetic single-arm study through tasks, collection, coordinator operations and export; Swift CLI/API parity and a source-linked Questionnaire authoring demonstration | Every optional trial feature, MCP, researcher voice or field deployment |
| M3.1: First Deployment and Reference Pilot | One selected target passes infrastructure acceptance, then an approved bounded study passes its predefined field criteria | Deployment on every cloud or completion of conversation and other later milestones |

M3.1 is the planned deployment milestone; it follows M2 and the required R1 subset
of M3, not all optional arms, sites or trial features. Preparation can run earlier.
M3 includes instrument authoring and shared inference connections formerly grouped
in M7/M4. Participant conversations remain M4; optional researcher voice is a
separate M4 increment. MCP is optional M5 integration. M6 contains participant
channels only; broader institutional and study drafting remains M7. Independent
work can proceed without waiting for the pilot. Schedule field activation only
after its owners, target and protocol are selected.

### Agent-Ready Authoring Sequence

1. Finish #82/#83 without expanding the completed foundation checkpoint.
2. Deliver [scoped delegation #87](https://github.com/SchmiedmayerLab/Trove/issues/87), revision-safe study operations (#31) and the [Swift CLI #52](https://github.com/SchmiedmayerLab/Trove/issues/52).
3. Deliver [Questionnaire validation/editor #53](https://github.com/SchmiedmayerLab/Trove/issues/53): one FHIR draft, drag-and-drop with keyboard alternatives, graph, preview and deterministic named scenarios.
4. Add [document-assisted authoring #88](https://github.com/SchmiedmayerLab/Trove/issues/88) using shared [connections #46](https://github.com/SchmiedmayerLab/Trove/issues/46). Its GroveLLM usage/completion subset is required before hosted dispatch; the participant gateway is not.
5. Demonstrate source upload, conversational and visual correction, pinned IG/renderer validation, exact reviewed publication through the CLI, and synthetic participant administration. Include stale-write, revocation, unavailable-validator and interrupted-retry failures.

These are independently testable increments. M3 tracks the authoring demonstration,
but ordinary study execution and an independently approved manual-only pilot do not
require inference to be enabled. M3.1 must verify any authoring capability selected
for deployment; otherwise it remains disabled. MCP (#89), researcher voice (#90),
multisite and randomization do not gate the first authoring demonstration.

Existing due dates remain provisional ordering targets, not re-estimated delivery
promises. Re-estimate added M3 work against actual staffing before making a commitment.

### Localization Is a Shared M3 Contract

This is remaining implementation work, not a capability supplied by the initial
[M3 pull request stack](https://github.com/SchmiedmayerLab/Trove/pull/97). That stack adds
validation, revision-bound authoring access and initial Swift CLI commands. The
single-resource localization transition, visual editor, task execution and hosted
document authoring retain their issue acceptance criteria below.

M3 stores every Questionnaire translation in one FHIR JSON resource, using the pinned Grove IG translation contract. Study metadata uses language-keyed values; standalone Markdown/PDF/media translations remain separate source-linked artifacts. Adopt the finalized upstream contract and fixtures with an immutable dependency pin rather than inventing a parallel extension or following a moving branch for acceptance.

The required synthetic verification is: import one bilingual JSON, edit both languages through the shared revision boundary, validate, publish one artifact, administer either admitted language with unchanged branching/answer identities, and export the complete multilingual source with untouched content preserved. Cover missing/malformed translations, language-only/script/region tags, string and coded answer display, RTL, stale cross-language edits, offline/restart language retention and invalidated validation/review after content changes. These are targeted contract tests, not a requirement to deploy a multilingual study.

[Definitions #23](https://github.com/SchmiedmayerLab/Trove/issues/23), [editor #53](https://github.com/SchmiedmayerLab/Trove/issues/53), [publication #31](https://github.com/SchmiedmayerLab/Trove/issues/31), [occurrences #37](https://github.com/SchmiedmayerLab/Trove/issues/37), [client/GroveStudy adoption #32](https://github.com/SchmiedmayerLab/Trove/issues/32), [CLI #52](https://github.com/SchmiedmayerLab/Trove/issues/52) and [assisted authoring #88](https://github.com/SchmiedmayerLab/Trove/issues/88) own their portions. [Reviewed variants #67](https://github.com/SchmiedmayerLab/Trove/issues/67) adds the selected additional-language/site workflow, not a separate Questionnaire representation.

M3.1 verifies exact approved artifacts and administration languages for the selected pilot. Unsupported or unapproved languages remain disabled; ordinary UI fallback cannot authorize instrument or consent fallback. Additional production languages and sites are conditional, while the single-resource architecture is not.

Use disposable Docker services for routine integration and a local Kubernetes
reference setup for orchestration-specific checks. Exercise the real database,
object store, identity provider and validator, including interrupted writes,
permission removal, repeated delivery and recovery. For the current M1/M2 iteration,
Simulator verification is the accepted client boundary; physical-device verification
does not block local completion. Actual device background and data-protection
claims remain unverified until later device/field acceptance. Provider sandbox
access and development signing may still require external services.

Keep required CI, security checks, review and coordinated dependency publication
as explicit handoff and activation gates. The completed M1/M2 checkpoint transfers
remaining execution/adoption to M3 #82/#83 and approved publication/enforcement to
M3.1 #84/#85. Uncommitted local dependencies are not published integration
evidence, and unavailable protection must still prevent publication.
A local restore proves only the tested recovery procedure;
online backup, WAL recovery and traffic interruption can also be developed locally
before target-specific durability and recovery objectives are approved. Early
development uses fresh schemas, not legacy-data migrations.

### Portable Application, Explicit Deployment Adapters

Keep the Swift application independent of a particular cloud and of Kubernetes
APIs. Use explicit PostgreSQL/Timescale, object-storage and OIDC contracts. Retain
one Kubernetes application base with small target-specific configuration for
secrets, workload identity, storage classes, ingress/certificates and backups.
AWS, GCP and a compatible self-hosted cluster are deployment targets, not three
different application architectures. The existing GCP bootstrap is one adapter,
not the portable contract; other targets are not supported until verified.

Do not build a general multi-cloud framework or require all providers to pass
before the first deployment. In particular, S3 compatibility does not establish
native GCS support, and a managed PostgreSQL service must support the required
extensions and privileges before it can replace the reference database.

Local Kubernetes checks do not prove a target's IAM, encryption/key management,
volume durability, network enforcement, certificate renewal or failure-domain
behavior. M3.1 verifies these with the exact candidate artifacts and selected
configuration, first with synthetic data. Recovery includes database state,
application objects and identity; missing current authority must prevent serving.
Only then can an independently approved human pilot begin.

### Bounded Foundation Acceptance

M2 issues close against the capabilities they implement, not every future consumer
of the same infrastructure. Deferred requirements remain mandatory in the owning
feature's acceptance before that feature is activated:

| M2 foundation | Later acceptance owner |
|---|---|
| Fresh schema and immutable custody (#29) | Deployment policy (#34) requires a reviewed upgrade before changing a retained-data deployment; no development legacy importer |
| Authenticated ingestion measurements (#28) | Export/status performance (#45), governed closeout and erasure workloads (#50), online recovery and target admission limits (#34) |
| Audit transactions, disclosure and scoped history (#54) | CLI (#52), task/publication/lifecycle/export (#37/#31/#50/#45), connector/communication (#63/#58), inference (#38/#46), custom integration (#48/#49) and target retention/recovery (#34) |
| Current contract and transition evidence (#61) | Task synchronization (#37), Questionnaire preview/pairing (#53), connectors (#63), erasure (#50), custom/Kotlin integration (#48/#49/#65), delegated access (#87) and assisted authoring (#88, then #44) |

Later issues reuse the same audit and verification mechanisms. They add actions,
fixtures and evidence for their own activated behavior; they do not require a
second audit system or reopen the foundation indefinitely. Ingestion retractions,
withdrawal isolation, failed-audit denial and queue safety remain M2 requirements.

The migration trigger is retained real data, not the final roadmap milestone.
A real-data pilot counts. Before the first subsequent schema/storage change,
create a release-specific upgrade plan and verify retained consent, grants,
receipts, artifacts and pending work, with a reviewed cutover/recovery procedure.
First deployment needs that policy, not an invented legacy dataset or migration
engine. Breaking changes remain acceptable in disposable development setups.

## First: One Complete Study

The first delivery supports a single-arm study with one approved site and administration language. It connects:

- Versioned study configuration, approved consent and a manually supplied questionnaire.
- A simple questionnaire editor with participant and branching-logic previews; optional assisted authoring uses the same FHIR draft.
- Participant invitation, verified enrollment and an accessible consent experience.
- Scheduled questionnaire execution, native iOS collection and one server-linked wearable route.
- Reliable submission, accepted-state restoration and understandable failure states.
- Coordinator views, bounded follow-up, meaningful collection status and authorized export.
- Measured local workloads and recovery; target capacity and field acceptance in M3.1.

The first cloud-collection engineering fixture uses Withings body measurements, alongside native collection such as HealthKit steps. The conversion roadmap also covers Oura and Google Health API; the pilot requires one admitted subset rather than completion of every mapping. Provider access and tested conversion remain prerequisites for each activated route.

A representative synthetic study can test the whole path before any field deployment. A field study additionally needs approved content, actual research and operational owners, a supported client/device matrix and predefined success measures.

Success is more than a passing build. A researcher must be able to configure and publish the supported study without bespoke database changes. Participants must be able to enroll, perform activities, recover from interruption and withdraw. Coordinators must be able to distinguish setup, synchronization and coverage problems. Exports must retain interpretable versions and provenance.

The first manual study does not wait for conversations, hosted generation, multiple arms, every language or a custom-document service. M3 separately demonstrates source-linked Questionnaire authoring; field activation requires only the capabilities selected for that study, with inference disabled unless its controls are verified.

### Reference Protocol and Field Acceptance

The engineering reference is **Trove Collection Pilot**: one single-arm, one-site configuration, a versioned synthetic daily check-in Questionnaire, HealthKit steps and the selected Withings body-measurement route. Synthetic accounts exercise the lifecycle before any approved human pilot. This fixture is neither a validated clinical instrument nor an approved research protocol.

Before field activation, record the actual investigator, coordinator and operator; approved protocol/instrument revisions; participant count and duration; app/OS/device matrix; provider access; data handling and support route. Set numeric setup-success, coordinator-time, delivery-delay, recovery, support-cost and capacity criteria before collecting evidence. Missing owners, approval or thresholds block field activation, not synthetic development.

The acceptance report demonstrates:

1. Study configuration and publication without direct database edits or bespoke application code.
2. Invitation, verified identity, exact consent, setup, tasks, collection and withdrawal.
3. Accepted-state restoration and interruption/revision recovery without fabricated completion or lost acknowledged data.
4. Coordinator identification of setup, authorization, synchronization and partial-coverage problems, followed by permitted outreach.
5. An interpretable, exact-version export/codebook; separate two-study fixtures prove attribution and withdrawal isolation.
6. Restore and lifecycle-under-load behavior, measuring access denial separately from payload cleanup. Retained-data upgrades are required before changing a deployment that retains real study data, not for fresh development schemas.
7. Observed results against the predeclared criteria, unresolved support cases, cost and an explicit go/no-go decision.

Existing study deployments are not pilot targets without separately approved adoption.

## Next: One Conversation Study

The conversation delivery adds a Stanford-backed text task, shared eligibility checks, durable messages and enforced usage through GroveLLM.

It also includes [human conversation review (#86)](https://github.com/SchmiedmayerLab/Trove/issues/86):
authorized study reviewers assess safety, accuracy and study-defined criteria at
conversation and message level. Versioned rubrics, exact transcript references
and independent reviewer history preserve the meaning of each rating. This is
researcher-led assessment, not an automated clinical validation or monitoring service.

Its defining property is continuity with the study model: the participant uses a published intervention within an assigned occurrence, and accepted completion can lead to a versioned follow-up questionnaire.

The initial path must handle interruption, concurrent requests, quota exhaustion, revoked eligibility and uncertain provider outcomes without inventing success or generating duplicate billable work.

Retrieval, images, multiple providers, voice and automated intervention evaluation are not prerequisites. Researchers retain responsibility for intervention suitability. Optional synthetic preview tools help configuration without certifying a clinical intervention.

## Then: Demonstrate Reuse

A second study or custom application should use the same identity, consent, task and data contracts without requiring a fork of the core backend.

The integration selects only the capabilities it needs. Collection-only reuse does not wait for conversation support. A specialized assessment can remain app-owned. Existing applications can adopt a bounded capability while retaining their interface and unrelated services.

This milestone tests whether the architecture is genuinely reusable. It should reveal where a shared abstraction helps and where application policy should remain local. Shared packages follow demonstrated reuse, not assumptions about every future study.

## Additional Capabilities, Introduced Deliberately

| Capability | What justifies adding it |
|---|---|
| More wearable providers | A needed source with supported identity, mappings, access and reliable synchronization |
| Arms and allocation | A selected protocol requiring controlled assignment and applicability |
| Additional sites and reviewed language variants | Actual administration and access requirements beyond the initial configuration |
| Dataset review and finalization | A study requiring governed data clarification and reproducible frozen selections |
| Source-document and institutional drafting | Stable structured facts, review operations and an approved processing route |
| Study-scoped retrieval and image capabilities | A concrete intervention need, supported provider behavior and appropriate data handling |
| Browser, text or voice participation | A protocol that can be represented faithfully through that channel |
| Custom document contracts | A real application need that does not belong in core clinical or study state |

These are extensions of the common model, not a requirement to build a full clinical-trial management system. Scientific analysis, advanced allocation systems, supply logistics, arbitrary hosted code and a broad assessment library remain outside the initial scope.

## Implementation Ownership

Trove tracks changes whose acceptance depends on the platform: portable-definition adoption, enrollment revision transitions, collection delivery, custom-client integration and MHC/Plainly migration proofs. A Trove issue can coordinate bounded changes in several repositories without creating a separate planning issue for each file or package.

Grove issues are reserved for independently useful, testable library improvements. Examples are unambiguous conversion context, file-backed recording input, versioned scheduler import and committed-change observation, provider-neutral inference receipts, embeddings and pure connected-provider conversion. Their tests must run without a Trove deployment or active study. Grove FHIR owns reusable exchange profiles, examples and conformance sequences.

This separates issue ownership from code ownership. Proven portable definitions or delivery adapters can still move into Grove through focused PRs; the platform deliverable remains tracked in Trove. Existing application releases are not changed until their owners approve adoption.

A useful implementation issue states the current gap, the starting code boundary, a proposed API/data shape, relevant ordering and measurable acceptance. Diagrams clarify transactions, lifecycles or ownership where prose alone is easy to misread. Checklists describe evidence, not just files to create. Contract sketches invite focused design review without requiring a complete speculative API before implementation.

Start the core integration by proving transactional custody, then one manually configured Questionnaire from publication through accepted completion and restart. Add collection routes and coordinator operations to that working path. In particular, demonstrate immutable publication under concurrent writers, committed-change pagination and recovery without replaying external effects before broadening those mechanisms. Provider formats, billable request attempts and custom-result ownership need source-specific fixtures, not only generic success tests.

Dependencies distinguish complete prerequisites from tested capability subsets and optional additions. Hosted drafting requires an approved connection and usage handling only when enabled; manual preparation remains independent. Browser questionnaires do not wait for conversation or phone support. Dedicated REDCap exchange is outside the active roadmap; standard authorized exports remain in scope.

## Keep the Architecture Simple

Use a modular Swift backend with explicit domain rules and focused adapters for persistence, identity and providers. Clients should not each reimplement consent or completion authority.

Prefer existing Grove foundations and shared contracts over parallel frameworks. A reusable interface should separate a real boundary; every type does not need an abstraction layer. A database-backed job mechanism can serve initial background work without a message-broker or microservice requirement for each feature.

Core records express domain meaning rather than arbitrary editable status fields. Typed states and explicit commands make invalid transitions easier to reject and reason about. Swift, TypeScript and Kotlin implementations share exact contract fixtures without having to share all runtime code.

The platform can make breaking API and schema changes when they improve its structure.
During early development, Trove targets fresh databases: update the canonical schema
and recreate explicitly identified disposable setups instead of maintaining upgrade
paths or legacy-data import machinery. Coordinate clients and test the new schema.
Once a deployment retains real study data, introduce a reviewed upgrade and recovery
policy before changing that deployment. This does not change the separate adoption
requirements for existing MHC or Plainly studies.

## Quality Is Part of Each Feature

Each change should identify its behavior, affected contracts and observable acceptance. Tests should verify persisted state and prohibited side effects, not only successful responses.

Important cases include cross-study access, stale revisions, repeated requests, interruption, concurrent completion, source corrections and lifecycle changes. Deterministic clocks and isolated fixtures are preferable to timing assumptions. Real database and storage tests establish behavior that an in-memory substitute cannot prove.

Local development and continuous integration use the same documented entry points and pinned inputs. Fast checks give early feedback; integration and release checks cover production-relevant boundaries. A missing prerequisite, skipped required suite or zero-test run is not success.

Accessibility, localization and actual background collection require evidence beyond unit tests. Representative devices and client versions matter because operating-system constraints affect the participant experience.

### Shared Definition of Done

Keep a small requirement-to-evidence matrix: critical behavior, owning feature, implementation boundary, concrete fixture/test identifiers and applicable release gate. Add rows as capabilities ship; a planned test is not coverage.

For each affected contract, record the authority, allowed transitions, expected versions, atomic changes, idempotency and cancellation/recovery behavior. Verify allowed outcomes and prohibited side effects, including permission removal, unavailable validation and concurrent lifecycle changes. Shared Swift, TypeScript and Kotlin fixtures pin the actual adopted contract versions; generated types alone do not prove parity.

Implementation acceptance includes coordinated callers and generated clients, explicit handling of retained/queued formats, bounded resource use, redacted diagnostics and documented failure behavior. UI changes include localizable errors and accessible presentation. No feature may depend on an unimplemented optional follow-up without declaring that dependency.

Record exact-revision results with pass, fail, skip and not-run states, including first attempts and retries. Local and CI Xcode runs use the same formatted output while preserving the original exit status and raw diagnostics. Tests use isolated service namespaces, deterministic seeds and bounded readiness, not implicit ordering or longer sleeps. Temporary quarantine needs an owner, tracked repair, expiry and replacement evidence for critical behavior.

### Trusted Checks and Release Evidence

One aggregate gate verifies that the checks selected for a change actually executed. Missing evidence, unintended skips and unexpected cancellation cannot produce a passing gate. Test the selection rules and periodically run the full applicable suite. Coverage reports must retain real covered and uncovered lines; scanner availability must be distinguished from successful analysis.

The `Build and Test` workflow's `Required Verification` job checks component
selection, dependent real-stack tests and coverage jobs. Selected jobs must succeed;
missing or malformed selection/results fail closed. Documentation-only changes may
skip the component tests. Server and web image publication also wait for this gate.
Configure it as a required repository check alongside the separate repository
standards and security checks; the workflow alone does not configure branch protection
or establish that the selected tests cover all acceptance requirements. The shared
Swift package command separately requires a fresh machine-readable Swift Testing
report with successful executed tests. Missing reports, inconsistent counts, empty
selections and all-skipped runs fail before coverage export; intentionally gated
cases remain visible as skips, not passes.

Untrusted changes run without signing, promotion or production credentials and without access to privileged caches. Prefer fresh runners, reviewed pinned tools and explicit network boundaries. Branch enforcement and independent review are verified settings, not assumptions inferred from workflow files.

Build candidates once and test the exact artifacts later promoted. Record source,
dependencies, toolchains, configuration and schema version, with provenance and a
component inventory. For the current development phase, verify fresh schema creation,
relational constraints, restricted runtime access and persistence across restart.
Retained-data upgrade tests become a release requirement before supporting production
schema changes; they are not a prerequisite for this fresh-database implementation.

## Operate What Is Shipped

A release identifies its source, build artifact, configuration, database migrations and contract versions. The tested immutable artifact is the one promoted.

Recovery includes retained-data upgrades, interrupted jobs and restoration without reintroducing erased data or obsolete permissions. Application rollback and database recovery are different operations and should not be described as interchangeable.

Operational measures include accepted-data durability, queue age, collection coverage, export delay, provider uncertainty, recovery time and cost. The platform should establish measured admission limits rather than promise capacity from participant count alone.

Before a field deployment, the team defines success measures for setup, coordinator effort, support burden, data delivery and recovery. A bounded pilot then tests those assumptions. Passing technical checks does not itself establish readiness for every study or institution.

## Responsible Automation

Automation can reduce repetitive engineering and research work, but it does not change the authority model.

Contributor tools should work with scoped access and synthetic fixtures. Security-sensitive changes, data migrations, consequential operations and weaker verification require appropriate independent review. Generated summaries are not substitutes for trusted test results.

Researcher assistance operates through the same API as the dashboard and command line. It proposes reviewable changes, preserves sources and uncertainty, and stops short of independently approving studies, contacting participants, allocating arms or releasing data.

Every new operation specifies its authenticated actor/client, resource scope, permitted action, approval boundary and forbidden side effects. Use a small shared permission scheme with readable presets, not per-interface policy. Test stale/replayed commands, revoked delegation, prompt injection and unavailable audit/validation against persisted outcomes. Keep deterministic CI separate from a bounded document/model evaluation corpus measuring source fidelity, unresolved ambiguity, correction effort and cost; model agreement is not a correctness oracle.

This keeps automation useful without making it another source of study state or a privileged route around the platform's controls.

[Platform Overview](README.md) · [Implementation Project](https://github.com/orgs/SchmiedmayerLab/projects/4)
