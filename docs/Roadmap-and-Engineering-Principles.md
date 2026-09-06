<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Roadmap and Engineering Principles

Trove's development is organized around complete study workflows rather than a growing checklist of disconnected features. A useful release must connect researcher setup, participant experience, data handling and operations.

The milestones below describe the intended sequence, not announced release dates or claims that the capabilities have shipped. Detailed implementation progress belongs in the project's published issues and release notes.

## First: One Complete Study

The first delivery supports a single-arm study with one approved site and administration language. It connects:

- Versioned study configuration, approved consent and a manually supplied questionnaire.
- Participant invitation, verified enrollment and an accessible consent experience.
- Scheduled questionnaire execution, native iOS collection and one server-linked wearable route.
- Reliable submission, accepted-state restoration and understandable failure states.
- Coordinator views, bounded follow-up, meaningful collection status and authorized export.
- Measured deployment capacity, retained-data upgrades and recovery.

The first cloud-collection engineering fixture uses Withings body measurements, alongside native collection such as HealthKit steps. The conversion roadmap also covers Oura and Google Health API; the pilot requires one admitted subset rather than completion of every mapping. Provider access and tested conversion remain prerequisites for each activated route.

A representative synthetic study can test the whole path before any field deployment. A field study additionally needs approved content, actual research and operational owners, a supported client/device matrix and predefined success measures.

Success is more than a passing build. A researcher must be able to configure and publish the supported study without bespoke database changes. Participants must be able to enroll, perform activities, recover from interruption and withdraw. Coordinators must be able to distinguish setup, synchronization and coverage problems. Exports must retain interpretable versions and provenance.

The first study does not wait for conversations, generated authoring, multiple arms, every language or a custom-document service. Those capabilities build on the same foundations when required.

### Reference Protocol and Field Acceptance

The engineering reference is **Trove Collection Pilot**: one single-arm, one-site configuration, a versioned synthetic daily check-in Questionnaire, HealthKit steps and the selected Withings body-measurement route. Synthetic accounts exercise the lifecycle before any approved human pilot. This fixture is neither a validated clinical instrument nor an approved research protocol.

Before field activation, record the actual investigator, coordinator and operator; approved protocol/instrument revisions; participant count and duration; app/OS/device matrix; provider access; data handling and support route. Set numeric setup-success, coordinator-time, delivery-delay, recovery, support-cost and capacity criteria before collecting evidence. Missing owners, approval or thresholds block field activation, not synthetic development.

The acceptance report demonstrates:

1. Study configuration and publication without direct database edits or bespoke application code.
2. Invitation, verified identity, exact consent, setup, tasks, collection and withdrawal.
3. Accepted-state restoration and interruption/revision recovery without fabricated completion or lost acknowledged data.
4. Coordinator identification of setup, authorization, synchronization and partial-coverage problems, followed by permitted outreach.
5. An interpretable, exact-version export/codebook; separate two-study fixtures prove attribution and withdrawal isolation.
6. Retained-data upgrade, restore and lifecycle-under-load behavior, measuring access denial separately from payload cleanup.
7. Observed results against the predeclared criteria, unresolved support cases, cost and an explicit go/no-go decision.

Existing study deployments are not pilot targets without separately approved adoption.

## Next: One Conversation Study

The conversation delivery adds a Stanford-backed text task, shared eligibility checks, durable messages and enforced usage through GroveLLM.

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
| REDCap exchange | An approved study-specific mapping with one clear owner for each record |
| Custom document contracts | A real application need that does not belong in core clinical or study state |

These are extensions of the common model, not a requirement to build a full clinical-trial management system. Scientific analysis, advanced allocation systems, supply logistics, arbitrary hosted code and a broad assessment library remain outside the initial scope.

## Implementation Ownership

Trove tracks changes whose acceptance depends on the platform: portable-definition adoption, enrollment revision transitions, collection delivery, custom-client integration and MHC/Plainly migration proofs. A Trove issue can coordinate bounded changes in several repositories without creating a separate planning issue for each file or package.

Grove issues are reserved for independently useful, testable library improvements. Examples are unambiguous conversion context, file-backed recording input, versioned scheduler import and committed-change observation, provider-neutral inference receipts, embeddings and pure connected-provider conversion. Their tests must run without a Trove deployment or active study. Grove FHIR owns reusable exchange profiles, examples and conformance sequences.

This separates issue ownership from code ownership. Proven portable definitions or delivery adapters can still move into Grove through focused PRs; the platform deliverable remains tracked in Trove. Existing application releases are not changed until their owners approve adoption.

A useful implementation issue states the current gap, the starting code boundary, a proposed API/data shape, relevant ordering and measurable acceptance. Diagrams clarify transactions, lifecycles or ownership where prose alone is easy to misread. Checklists describe evidence, not just files to create. Contract sketches invite focused design review without requiring a complete speculative API before implementation.

Start the core integration by proving transactional custody, then one manually configured Questionnaire from publication through accepted completion and restart. Add collection routes and coordinator operations to that working path. In particular, demonstrate immutable publication under concurrent writers, committed-change pagination and recovery without replaying external effects before broadening those mechanisms. Provider formats, billable request attempts and custom-result ownership need source-specific fixtures, not only generic success tests.

Dependencies distinguish complete prerequisites from tested capability subsets and optional additions. Hosted drafting requires an approved connection and usage handling only when enabled; manual preparation remains independent. Browser questionnaires do not wait for conversation or phone support. A selected one-way REDCap exchange does not require the entire dataset-finalization workflow unless that study needs it.

## Keep the Architecture Simple

Use a modular Swift backend with explicit domain rules and focused adapters for persistence, identity and providers. Clients should not each reimplement consent or completion authority.

Prefer existing Grove foundations and shared contracts over parallel frameworks. A reusable interface should separate a real boundary; every type does not need an abstraction layer. A database-backed job mechanism can serve initial background work without a message-broker or microservice requirement for each feature.

Core records express domain meaning rather than arbitrary editable status fields. Typed states and explicit commands make invalid transitions easier to reject and reason about. Swift, TypeScript and Kotlin implementations share exact contract fixtures without having to share all runtime code.

The platform can make breaking API and schema changes when they improve its structure. That flexibility does not justify losing retained data or changing a running study's meaning. Changes need coordinated callers, explicit version handling and tested migration or a documented read-only historical representation.

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

Untrusted changes run without signing, promotion or production credentials and without access to privileged caches. Prefer fresh runners, reviewed pinned tools and explicit network boundaries. Branch enforcement and independent review are verified settings, not assumptions inferred from workflow files.

Build candidates once and test the exact artifacts later promoted. Record source, dependencies, toolchains, configuration and migration versions, with provenance and a component inventory. Test retained-data upgrades and serialized migrations, not only empty databases. API breaks remain acceptable; data loss and silent reinterpretation do not.

## Operate What Is Shipped

A release identifies its source, build artifact, configuration, database migrations and contract versions. The tested immutable artifact is the one promoted.

Recovery includes retained-data upgrades, interrupted jobs and restoration without reintroducing erased data or obsolete permissions. Application rollback and database recovery are different operations and should not be described as interchangeable.

Operational measures include accepted-data durability, queue age, collection coverage, export delay, provider uncertainty, recovery time and cost. The platform should establish measured admission limits rather than promise capacity from participant count alone.

Before a field deployment, the team defines success measures for setup, coordinator effort, support burden, data delivery and recovery. A bounded pilot then tests those assumptions. Passing technical checks does not itself establish readiness for every study or institution.

## Responsible Automation

Automation can reduce repetitive engineering and research work, but it does not change the authority model.

Contributor tools should work with scoped access and synthetic fixtures. Security-sensitive changes, data migrations, consequential operations and weaker verification require appropriate independent review. Generated summaries are not substitutes for trusted test results.

Researcher assistance operates through the same API as the dashboard and command line. It proposes reviewable changes, preserves sources and uncertainty, and stops short of independently approving studies, contacting participants, allocating arms or releasing data.

This keeps automation useful without making it another source of study state or a privileged route around the platform's controls.

[Platform Overview](README.md) · [Implementation Project](https://github.com/orgs/SchmiedmayerLab/projects/4)
