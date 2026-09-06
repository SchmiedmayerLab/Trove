<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Study Model and Research Workflows

Trove's study model is designed to preserve the relationship between a research protocol, the participant's agreement and the software that executes it. The model covers the common structure of a digital study while leaving specialized procedures to applications.

This page describes the target design. Initial and later capabilities are separated in the [roadmap](Roadmap-and-Engineering-Principles.md).

## A Portable, Versioned Study Definition

A study definition contains reusable components: participant-facing content, questionnaires, collection requirements and, where supported, conversational or custom activities. Each component identifies the content and rules necessary to interpret its execution.

Collection requirements refer to admitted Grove FHIR concepts, profiles, output forms and source capabilities. A requirement for granular step observations is different from a requirement for a daily total. A server-linked wearable route is different from a collector running on a participant's phone.

The definition therefore separates the desired information from the allowed acquisition routes. An application reports its capabilities; the platform rejects an unsupported required path rather than silently substituting a different measurement. Optional unavailable capabilities remain visible as unavailable.

Custom components use registered, namespaced identifiers and versioned configuration schemas. They describe an integration contract, not executable code supplied to the server. A bounded structured editor is sufficient for configuration that does not warrant a dedicated authoring interface.

### Three Kinds of Version

The study-definition schema, the FHIR package set and the published study revision have different meanings:

| Version | What it identifies |
|---|---|
| Definition schema | How software reads the structure of a study |
| FHIR package set | Which exchange profiles, terminology and validation rules apply |
| Published study revision | The exact protocol configuration and participant-facing content in use |

A change to one does not silently update the others. This distinction lets software evolve while preserving the meaning of historical consent, assignments and collected data.

Publishing creates an immutable revision. Stage content under unique immutable artifact identities, then commit the revision, artifact references and publication receipt together. Concurrent publishers must not upload into the same guessed next-revision key or overwrite the winner's bytes. A participant continues under the revision they adopted until an explicit transition is permitted. Changes requiring renewed consent cannot be treated as a routine content refresh; history retains the versions that actually applied.

## Enrollment, Consent and Lifecycle

Enrollment links a participant to a study and its adopted revision. Consent records the exact approved content presented, the applicable acknowledgements or signatures and the participant's action. A reference to “the latest consent document” is insufficient because the latest document can change.

The study lifecycle distinguishes preparation, publication, recruitment, active participation, pause, closure and archive. These states have operational effects: pausing a study is not the same as completing its tasks, and closing recruitment is not the same as ending collection for enrolled participants.

Required approvals have scope and validity. Changes to that validity can stop affected enrollment, task execution, collection or communication. Previously admitted work follows its declared policy; historical records are not rewritten to make them appear newly authorized.

Withdrawal, account deletion, source-data retraction and erasure are separate operations. Withdrawal ends the affected participation and access that is no longer authorized. Retention or erasure then follows the remaining permitted purposes and applicable requirements. Account administration must not become an uncontrolled deletion of research history.

These distinctions are necessary for both participant autonomy and an interpretable scientific record. Software enforces the configured rules; the responsible research and institutional teams determine their applicability.

## A Task Is an Assigned Occurrence

A recurring questionnaire definition is not the same object as the questionnaire assigned for a particular day. Each assigned occurrence has a stable identity, enrollment, component version, intended window and accepted result references.

The server owns the occurrence and its authoritative state. Applications may cache it and queue provisional work, but local presentation state does not establish accepted completion. Completion is an explicit, idempotent operation: retrying the same submission returns its existing outcome rather than creating another result.

Scheduling separates:

- When an activity becomes available.
- Its nominal due time.
- The final permitted submission cutoff.
- The participant-reported event time and the server's receipt time.

This allows a result to be late but accepted without confusing it with a missed, cancelled or excused activity. Missed required work remains visible in operational adherence calculations; administrative cancellation must not quietly remove it from the denominator.

Reinstall or a second device restores server-acknowledged state. Work that never left a device cannot be promised recoverable. Offline submissions remain provisional until the server checks their current authorization and the study's delayed-submission policy.

GroveScheduler provides local scheduling and presentation. Its integration imports acknowledged outcomes without replaying the side effects of completing a task again.

## Questionnaires as Shared Instruments

FHIR Questionnaire JSON is the instrument source, paired with QuestionnaireResponse for results. Exact canonical identity, version and item identifiers are retained throughout authoring, administration and export.

The first authoring path is deliberately straightforward: authorized manual import or editing, validation against pinned packages, and a bounded web preview. Assisted document conversion can be added without making ordinary questionnaire use depend on inference.

There are three separate questions:

1. Is the resource structurally valid under its declared profiles?
2. Does the selected application support all required behavior?
3. Is the instrument appropriate, licensed and approved for the intended research use?

A validator addresses the first, capability checks address the second, and researcher review addresses the third. None is a substitute for the others. A technically valid expression that the renderer cannot evaluate must not be presented as supported.

Source wording, answer options, units, branching and scoring must not change accidentally during translation, import or automated repair. A published instrument remains pinned even if a catalog later offers a newer version.

## Arms, Periods and Scientific History

A study can have shared components, arm-specific activities and periods such as baseline, intervention and follow-up. Arms, observational cohorts, sites and the organization operating the study are distinct concepts.

Single-arm studies do not require an allocation subsystem. The initial randomized design is individual parallel allocation using a reviewed, versioned table prepared for the study. Consuming an allocation, recording the assignment and preserving its traceability form one authoritative operation. Retries do not assign a participant twice, and a failed setup does not justify trying another arm.

Assignments survive reinstall and later study revisions. Original assignment and actual delivered exposure are recorded separately. Corrections retain attributed history rather than replacing the record of what happened.

Masking is an access rule across APIs, exports, messages and staff views—not merely a hidden label. The platform cannot promise participant blinding when the experience itself reveals the intervention. Allocation design and any unblinding procedure remain research responsibilities.

Prospective scientific records include the applicable objectives, outcomes, measurement windows, protocol and analysis-plan references, sample-size rationale and dissemination plan. The purpose is to distinguish what was planned from what was assigned, observed and eventually included in a released dataset. It is not to turn Trove into a statistical design engine.

## Localization, Sites and Accessibility

User-interface language, approved administration language, site jurisdiction and processing region are separate attributes. A device locale or network location does not establish which consent or instrument is applicable.

Reviewed content variants retain their source version, language, approval scope and exact content identity. Ordinary interface text may fall back to another language. Required consent or instrument wording cannot silently fall back when an approved variant is missing.

Accessibility and internationalization apply from the first supported workflow: assistive technology, text scaling, right-to-left layout, locale-aware dates and numbers, non-US contact formats and explicit time-zone behavior. Source measurements and canonical units remain distinct from display formatting.

Site operations add scoped staff roles, delegation and transfer history. Staff-entered responses identify both the subject and the actual staff actor; they do not impersonate participant-only actions. Site transfer changes applicable future work without relabeling historical records.

Guardian, proxy, witness or signature requirements must be explicitly supported before a study relies on them. Custom configuration is not a substitute for a missing core consent capability.

## Recruitment, Communication and Participant Value

Recruitment begins with prospective contacts, not fabricated enrollments. Importing a roster does not establish consent or permission for unrestricted outreach. Invitations connect a verified person to the appropriate study and application through an explicit handoff.

Communication uses declared purposes, contact preferences, quiet hours and bounded follow-up rules. Sending rechecks current eligibility and permission. A queued reminder becomes obsolete after completion or withdrawal even if it was valid when created.

Research teams need operational views that distinguish invitation, setup, task, collection and synchronization problems. These views report what is known and identify a next action; they do not diagnose a participant's behavior from a missing upload.

The participant experience should continue beyond data submission. Reviewed study updates can communicate progress, publications and contributions. Results summaries, thank-you messages and participation certificates use approved content and verified participation facts. Receiving later updates is a separate preference from continuing study activities.

Any protocol-required human support or concern-reporting route must be available. A conversational task or technical status screen is not an emergency or clinical-monitoring service.

## Researcher Assistance from One Set of Facts

The same structured facts should support configuration, consent representations, institutional drafts and participant communication. This reduces re-entry and exposes inconsistencies when a protocol changes.

A source document can produce proposed fields with citations and unresolved questions. It cannot silently invent endpoints, sample sizes, eligibility or approval. Researchers review the proposed differences through the same operations used for manual editing.

Institutional templates are adapters over those facts. Stanford IRB and data-risk-assessment preparation are initial targets, but the underlying study model is not tied to one institution. Consent documents and the application's Markdown presentation derive from the same reviewed section model; edits made during institutional review must be reconciled before either representation is published. Generated documents remain drafts; formal decisions and approved revisions remain distinct.

The same approach supports later translation review, amendment comparisons, technical rehearsal and methods summaries. Deterministic validation should explain concrete missing requirements before generated assistance is involved.

### Safe Document and Questionnaire Authoring

Document processing reuses governed artifacts and a restricted parser worker without core-database or inference-secret credentials. DOCX, PDF and text inputs have bounded expansion, processing time, memory and output. Macros, embedded network fetches and instructions inside documents do not execute.

Proposed fields distinguish extracted evidence from suggestions and retain source locations. Applying a proposal requires the current draft revision and normal validation. Questionnaire diagnostics identify severity, rule, element path, exact content digest and validator/package versions. Invalid, unavailable and not fully evaluated are distinct outcomes. Missing terminology or expression support cannot become a pass.

A shipped authoring kit contains a concise AGENTS.md, pinned package and CLI versions, supported renderer capabilities and synthetic examples. It directs authoring tools to preserve canonical identity, linkIds, referenced terminology, wording and unresolved questions. Repair has explicit attempt/time/cost limits; it cannot delete required behavior just to satisfy a validator. Dependencies resolve through approved pinned packages, not URLs embedded in an uploaded instrument.

The output is a reviewable draft, source mapping and diagnostics. Manual entry remains available. Publication, participant contact, allocation and dataset release require separate authorized commands; neither a document nor generated text can grant that authority.

## Data Review and Closeout

Operational exports are useful before a full scientific-finalization workflow exists. As studies require formal review, dataset snapshots add exact membership, data versions, codebooks, unresolved items and reviewer decisions.

A frozen dataset is a versioned selection, not a command to stop the shared ingestion store. Reopening creates a new selection with a reason. Current disclosure and erasure requirements still apply; freezing does not grant permanent access.

The [data architecture](Data-and-Platform-Architecture.md) explains how this history is preserved without duplicating every measurement for every study.

[Platform Overview](README.md) · [Implementation Project](https://github.com/orgs/SchmiedmayerLab/projects/4)
