<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Study Model and Research Workflows

A study definition specifies content, activities and collection requirements.
Published revisions connect that definition to enrollment, consent and results.
Specialized procedures remain in study applications.

Study revisions, enrollment and consent are implemented. Server-assigned tasks,
multilingual questionnaire authoring, randomization and the research operations
below describe the intended design, not currently available end-to-end workflows.
[GitHub milestones](https://github.com/SchmiedmayerLab/Trove/milestones) and
[issues](https://github.com/SchmiedmayerLab/Trove/issues) track implementation.

## Study Definitions and Revisions

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

Publishing creates an immutable revision. Artifacts have unique identities; the revision, references and publication receipt commit together. Concurrent publication cannot overwrite an accepted artifact. A participant continues under the revision they adopted until an explicit transition is permitted. Changes requiring renewed consent cannot be treated as a routine content refresh; history retains the versions that actually applied.

## Enrollment, Consent and Lifecycle

Enrollment links a participant to a study and its adopted revision. Consent records the exact approved content presented, the applicable acknowledgements or signatures and the participant's action. A reference to “the latest consent document” is insufficient because the latest document can change.

The current revision-adoption rule requires fresh consent for every explicitly selected forward revision, even when the wording is unchanged. Omitting a revision selects the enrollment's current revision, not the newest publication. The server rechecks the exact published presentation and target participation criteria before committing consent, revision adoption, enrollment state and audit together. A newly invitation-restricted revision requires retained invitation evidence for the same study; an already redeemed code is not consumed again.

Exact command retries return the original consent receipt without adopting again, including after later adoption or withdrawal. They do not restore participation. Downgrades and consent-free upgrade routes are rejected. Researcher-configurable exceptions and institutional approval lifecycles are separate capabilities; this initial server rule does not establish institutional approval or legal validity of a signature.

The planned lifecycle extends publication and enrollment with explicit recruitment, pause, closure and archive controls. These states have operational effects: pausing a study is not the same as completing its tasks, and closing recruitment is not the same as ending collection for enrolled participants.

Required approvals have scope and validity. Changes to that validity can stop affected enrollment, task execution, collection or communication. Previously admitted work follows its declared policy; historical records are not rewritten to make them appear newly authorized.

Withdrawal, account deletion, source-data retraction and erasure are separate operations. Withdrawal ends the affected participation and access that is no longer authorized. Retention or erasure then follows the remaining permitted purposes and applicable requirements. Account administration must not become an uncontrolled deletion of research history.

## Tasks and Occurrences

Server-assigned occurrences and cross-device completion synchronization are planned.

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

## Questionnaires

Questionnaire components exist today; the multilingual editor, branching preview
and administration model below are planned extensions.

FHIR Questionnaire JSON is the instrument source, paired with QuestionnaireResponse for results. Exact canonical identity, version and item identifiers are retained throughout authoring, administration and export.

Each instrument version is **one multilingual JSON resource**, not one file per language. `Questionnaire.language` identifies the source language; translations use the [FHIR translation mechanism](https://hl7.org/fhir/R4/extension-translation.html) at locations supported by the pinned Grove IG. There are no translation sidecars or separate localization schemas in this model. Translation presence, renderer completeness and approval for administration are separate facts.

The planned editor provides a language selector, side-by-side source/translation fields, missing-text filters and language-specific diagnostics. Review indicators reflect actual digest-bound evidence, not successful parsing. Language selection changes graph labels and preview wording, never identifiers, conditions, scoring or stored answer values. Language switching preserves unsaved edits. All languages share one draft revision, with conflict detection for concurrent edits. Import/export retains untouched translations and unsupported fields; unsupported required semantics block administration rather than disappearing on save.

Authoring combines import and editing, validation against pinned packages,
synthetic scenarios and visual preview. Document-assisted creation uses the same
instrument API. Manual authoring remains usable without inference.

The planned dashboard editor combines drag-and-drop question/section editor with keyboard alternatives, participant preview and
branching graph over that same FHIR draft. Researchers edit answer choices and
typed conditions without writing JSON; import/export preserves stable item IDs
and unsupported fields rather than silently simplifying an instrument. Published
versions remain immutable. The optional authoring assistant proposes changes
through the same revision-checked editing and validation operations.

Moving an item between groups can change condition or repetition context even when its identifier stays the same. The editor must show these effects before accepting the move. Candidate content is ordinary FHIR JSON plus its base revision, source mapping and diagnostics, not an editing language. The Swift service owns validation/scenario operations; the existing browser presentation and mobile clients use shared expected-result fixtures. Profile conformance and actual renderer support remain separate checks.

The graph shows both the questionnaire hierarchy and labeled conditional
dependencies, clearly distinguished from display order. An all-branches view
supports collaborator review; synthetic-answer walkthroughs highlight enabled,
disabled and not-evaluated items and explain why. Selecting a node focuses its
editor and preview. Collapsible sections, search, a keyboard-accessible rule list
and a versioned printable overview keep larger instruments understandable.

The graph derives from FHIR enablement rules rather than a separate workflow schema. Graph and
participant preview share evaluation of the supported condition subset, including
ancestor gating and repeat context. Missing references and unsupported expressions
remain visible; an opaque expression cannot be shown as a fully analyzed branch.
Named synthetic scenarios help review but do not prove exhaustive path coverage
or scientific validity. Preview and exported diagrams contain no participant data;
private instrument access and licensing restrictions still apply.

There are three separate questions:

1. Is the resource structurally valid under its declared profiles?
2. Does the selected application support all required behavior?
3. Is the instrument appropriate, licensed and approved for the intended research use?

A validator addresses the first, capability checks address the second, and researcher review addresses the third. None is a substitute for the others. A technically valid expression that the renderer cannot evaluate must not be presented as supported.

Source wording, answer options, units, branching and scoring must not change accidentally during translation, import or automated repair. A published instrument remains pinned even if a catalog later offers a newer version.

## Study Arms and Protocol History

Randomization and arm-specific execution are planned capabilities.

A study can have shared components, arm-specific activities and periods such as baseline, intervention and follow-up. Arms, observational cohorts, sites and the organization operating the study are distinct concepts.

Single-arm studies do not require an allocation subsystem. The initial randomized design is individual parallel allocation using a reviewed, versioned table prepared for the study. Consuming an allocation, recording the assignment and preserving its traceability form one authoritative operation. Retries do not assign a participant twice, and a failed setup does not justify trying another arm.

Assignments survive reinstall and later study revisions. Original assignment and actual delivered exposure are recorded separately. Corrections retain attributed history rather than replacing the record of what happened.

Masking is an access rule across APIs, exports, messages and staff views—not merely a hidden label. The platform cannot promise participant blinding when the experience itself reveals the intervention. Allocation design and any unblinding procedure remain research responsibilities.

Prospective scientific records include the applicable objectives, outcomes, measurement windows, protocol and analysis-plan references, sample-size rationale and dissemination plan. The purpose is to distinguish what was planned from what was assigned, observed and eventually included in a released dataset. It is not to turn Trove into a statistical design engine.

## Localization, Sites and Accessibility

User-interface language, approved administration language, site jurisdiction and processing region are separate attributes. A device locale or network location does not establish which consent or instrument is applicable.

Reviewed content variants retain their source version, language, approval scope and exact content identity. Ordinary interface text may fall back to another language. Required consent or instrument wording cannot silently fall back when an approved variant is missing.

| Content | Representation |
| --- | --- |
| Questionnaire | One versioned FHIR JSON resource containing all translations |
| Study titles, descriptions and explanations | Language-keyed values with an explicit source language |
| Standalone Markdown, PDF and media | Separate language-tagged artifacts linked to the source version |

Questionnaire language approval references the same artifact version/digest plus the administration language and applicability. Document approval references the particular translated artifact. Any content edit initially invalidates whole-artifact validation and requires approval for the changed digest; there is no per-language version engine or automatic approval carry-forward. Historical publications, signed consent and accepted responses remain immutable. Assisted translation produces drafts, not approval or proof of scientific equivalence.

Language tags retain language, script and region distinctions without requiring a region. Administration selects an admitted language at session start and records it with the exact instrument in server state and pending offline work. UI-language changes cannot switch an active instrument. A missing required translation or approval blocks that administration path. Response language follows the pinned IG; study/site applicability is not inferred from device locale.

The acceptance case is a bilingual import, edit, validation, publication,
administration and export round-trip. Enabling another language also requires
the study's approved wording and applicability.

Accessibility and internationalization apply from the first supported workflow: assistive technology, text scaling, right-to-left layout, locale-aware dates and numbers, non-US contact formats and explicit time-zone behavior. Source measurements and canonical units remain distinct from display formatting.

Site operations add scoped staff roles, delegation and transfer history. Staff-entered responses identify both the subject and the actual staff actor; they do not impersonate participant-only actions. Site transfer changes applicable future work without relabeling historical records.

Guardian, proxy, witness or signature requirements must be explicitly supported before a study relies on them. Custom configuration is not a substitute for a missing core consent capability.

## Recruitment and Participant Communication

Roster import, outreach and automated follow-up are planned extensions to enrollment.

Recruitment begins with prospective contacts, not fabricated enrollments. Importing a roster does not establish consent or permission for unrestricted outreach. Invitations connect a verified person to the appropriate study and application through an explicit handoff.

Communication uses declared purposes, contact preferences, quiet hours and bounded follow-up rules. Sending rechecks current eligibility and permission. A queued reminder becomes obsolete after completion or withdrawal even if it was valid when created.

Research teams need operational views that distinguish invitation, setup, task, collection and synchronization problems. These views report what is known and identify a next action; they do not diagnose a participant's behavior from a missing upload.

The participant experience should continue beyond data submission. Reviewed study updates can communicate progress, publications and contributions. Results summaries, thank-you messages and participation certificates use approved content and verified participation facts. Receiving later updates is a separate preference from continuing study activities.

Any protocol-required human support or concern-reporting route must be available. A conversational task or technical status screen is not an emergency or clinical-monitoring service.

## Assisted Study Preparation

Planned authoring assistance will reuse study-definition fields in consent
documents, institutional forms and participant communications. Researchers review
the extracted facts and proposed wording before applying them.

A source document can produce proposed fields with citations and unresolved questions. It cannot silently invent endpoints, sample sizes, eligibility or approval. Researchers review the proposed differences through the same operations used for manual editing.

Institutional templates are adapters over those facts. Stanford IRB and data-risk-assessment preparation are initial targets, but the underlying study model is not tied to one institution. Consent documents and the application's Markdown presentation derive from the same reviewed section model; edits made during institutional review must be reconciled before either representation is published. Generated documents remain drafts; formal decisions and approved revisions remain distinct.

The same source references support translation review, amendment comparisons and
methods summaries. Validation reports missing required fields before a researcher
requests generated assistance.

### Safe Document and Questionnaire Authoring

Swift authoring orchestration reuses governed artifacts and a restricted parser worker without core-database or inference-secret credentials. DOCX, PDF and text inputs have bounded expansion, processing time, memory and output. Established parsers may be invoked behind that boundary. Macros, embedded network fetches and instructions inside documents do not execute. Unsupported scanned input and ambiguous extraction remain explicit rather than guessed.

Proposed fields distinguish extracted evidence from suggestions and retain source locations. Applying a proposal requires the current draft revision and normal validation. Questionnaire diagnostics identify severity, rule, element path, exact content digest and validator/package versions. Invalid, unavailable and not fully evaluated are distinct outcomes. Missing terminology or expression support cannot become a pass.

The planned authoring kit includes a concise AGENTS.md, pinned package and CLI versions, supported renderer capabilities and synthetic examples. It directs authoring tools to preserve canonical identity, linkIds, referenced terminology, wording and unresolved questions. Repair has explicit attempt/time/cost limits; it cannot delete required behavior just to satisfy a validator. Dependencies resolve through approved pinned packages, not URLs embedded in an uploaded instrument.

The output is a reviewable draft, source mapping and diagnostics. Manual entry remains available. Publication, participant contact, allocation and dataset release require separate authorized commands; neither a document nor generated text can grant that authority.

Authoring jobs retain candidate references and executed actions. Applying content
uses typed updates with the expected revision and current source access. An
uncertain provider outcome requires usage reconciliation before another request.

## Data Review and Closeout

Formal dataset review, freezing and closeout are planned research operations.

Operational exports are useful before a full scientific-finalization workflow exists. As studies require formal review, dataset snapshots add exact membership, data versions, codebooks, unresolved items and reviewer decisions.

A frozen dataset is a versioned selection, not a command to stop the shared ingestion store. Reopening creates a new selection with a reason. Current disclosure and erasure requirements still apply; freezing does not grant permanent access.

The [data architecture](Data-and-Platform-Architecture.md) explains how this history is preserved without duplicating every measurement for every study.
