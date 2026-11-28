<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Study Model and Research Workflows

A study definition specifies content, activities and collection requirements.
Published revisions connect that definition to enrollment, consent and results.
Specialized procedures remain in study applications.

## Study Definitions and Revisions

A study definition contains components of three types: informational content, FHIR Questionnaires and health-data collection requirements. An informational component holds one document per language-region locale; a questionnaire component holds one multilingual resource.

Collection requirements refer to admitted Grove FHIR concepts, profiles, output forms and source capabilities. A requirement for granular step observations is different from a requirement for a daily total. A server-linked wearable route is different from a collector running on a participant's phone.

The definition therefore separates the desired information from the allowed acquisition routes. An application reports its capabilities; the platform rejects an unsupported required path rather than silently substituting a different measurement. Optional unavailable capabilities remain visible as unavailable. The server's collection-capability endpoint lists the outputs a deployment can collect, and the dashboard offers only those.

Each requirement declares its measurement window: from acceptance, a calendar lookback in a declared time zone, a specific start or all available history. The server resolves that window once when the participant consents and retains it with the exact accepted consent and revision. Admission evaluates every record against the accepted window of each study independently, and a later publication cannot broaden it. Sleep and workout sessions that overlap a window are collected complete.

### Three Kinds of Version

The study-definition schema, the FHIR package set and the published study revision have different meanings:

| Version | What it identifies |
|---|---|
| Definition schema | How software reads the structure of a study |
| FHIR package set | Which exchange profiles, terminology and validation rules apply |
| Published study revision | The exact protocol configuration and participant-facing content in use |

A change to one does not silently update the others. This distinction lets software evolve while preserving the meaning of historical consent and collected data.

Each publication records these separately: the Grove study definition schema version of its participant bundle, the version and source revision of the Grove FHIR IG package that validated it, the validator identity and the execution capability, next to its revision number. A collection policy written by an earlier release stays readable; policies of version 6, which have no requirement levels, read every requirement as required.

### Publication Readiness

Draft validation checks, besides every questionnaire, three groups of facts, and each finding names its field or path, its rule and the next action.

- Readiness facts: aims, population, procedures, participant burden, data retention, withdrawal, and the prerequisites for opening enrollment: the concern route (how participants reach a person about concerns and how incidental findings reach a responsible person; a reference to an approved external route suffices), responsible coverage and the reviewed co-enrollment policy. Each is required in the source language of the study details, as is at least one responsible contact with a name, a role and an email address or phone number. A missing fact or contact blocks publication. A fact missing in another language of the study details is an advisory. The check tests presence and basic form; it does not judge the content. Publications record the facts they were validated with; the participant bundle does not contain them.
- Administration languages: each questionnaire component names the languages in which participants may answer it, by default its base language. Each one must be the base language or a translation language of the resource, every displayed string must carry a translation into it, and a study administrator must have approved that exact resource for that language. An approval names the resource's SHA-256 digest, so any edit requires new approvals. Delegated clients and researchers without administrator authority cannot approve or revoke. A single-language questionnaire needs only the approval of its base language. Approving does not change the draft revision; publication requires validating again, and a candidate whose approval was revoked cannot be published.
- Collection routes: a requirement is required unless it is marked optional. A route is available when the participant app implements its native source, or when an approved provider registration qualifies its source and profile. An unavailable required route blocks publication. An unavailable optional route is an advisory; the publication lists that requirement as unavailable and grants no collection for it. Publication checks the granted routes again; a route lost after validation refuses publication and names the affected requirements; the draft must be validated again.

The dashboard edits the readiness facts with the study details, the administration languages and approvals on the questionnaire form, and the requirement level in the collection settings. The CLI approves and revokes with `trove study approve-language` and `trove study revoke-language-approval`. An approval records a decision in Trove; it does not establish that an institution reviewed the instrument or its translation.

Publishing creates an immutable revision. Artifacts have unique identities; the revision, references and publication receipt commit together. Concurrent publication cannot overwrite an accepted artifact. A participant continues under the revision they adopted until an explicit transition is permitted. Changes requiring renewed consent cannot be treated as a routine content refresh; history retains the versions that actually applied.

## Enrollment, Consent and Lifecycle

Enrollment links a participant to a study and its adopted revision. Consent records the exact approved content presented, the applicable acknowledgements or signatures and the participant's action. A reference to “the latest consent document” is insufficient because the latest document can change.

The current revision-adoption rule requires fresh consent for every explicitly selected forward revision, even when the wording is unchanged. Omitting a revision selects the enrollment's current revision, not the newest publication. The server rechecks the exact published presentation and target participation criteria before committing consent, revision adoption, enrollment state and audit together. A newly invitation-restricted revision requires retained invitation evidence for the same study; an already redeemed code is not consumed again.

Exact command retries return the original consent receipt without adopting again, including after later adoption or withdrawal. They do not restore participation. Downgrades and consent-free upgrade routes are rejected. This rule does not establish institutional approval or legal validity of a signature.

Withdrawal and source-data retraction are separate operations. Withdrawal ends the affected participation and the collection and access that are no longer authorized; it does not delete records retained for another independently authorized study. Trove has no account-deletion or erasure operation.

## Schedules

Informational and questionnaire components can have schedules; health-data collection components cannot. A schedule runs once, at a date or relative to a study event such as enrollment or the completion of another component, or repeats daily, weekly or monthly with an interval and offset. It also declares a completion policy, whether a notification is enabled and, with notifications, an optional reminder time of day; without it, the reminder fires at the occurrence's due time. Schedules are part of the published revision.

Consent acceptance assigns questionnaire occurrences from the exact adopted publication. A task read extends the window to cover today and the following 59 civil days in the published enrollment time zone. Repeats keep their phase from enrollment plus the schedule offset. Weekly intervals count Sunday-to-Saturday weeks starting with the week containing that anchor, independent of locale. Publication rejects incomplete dates, invalid clock times, nonpositive intervals and monthly days outside 1 through 31. A nonexistent local time advances to the first valid time on that day. A repeated local time uses its first instant. A monthly schedule skips months that lack its specified day. Dated and enrollment-relative schedules run once. A date resolves in the published enrollment time zone. An enrollment-relative time applies on its day even when enrollment happened later that day. On the first consent, such a one-time occurrence is assigned while its window is open, even when it was due before consent, but never when it falls before the enrollment day. Other lifecycle triggers require their corresponding event.

Each assignment identifies its enrollment, publication artifact, schedule, component, instrument digest and Questionnaire canonical URL and version, records when it was assigned, and lists the instrument's base language and the administration languages the publication approved. It also states whether its published schedule enables a reminder and at which time of day, and the SHA-256 of the bundle archive of its revision, so the device can verify the downloaded bundle. The completion policy determines its opening and cutoff, bounded by consent and enrollment end. An assignment whose policy sets no cutoff, in an enrollment without an end, has no deadline: it is never missed, and every time from its opening lies within its window. Withdrawal or enrollment expiry closes all remaining assignments with one audited enrollment change. After closure, a fresh snapshot is empty. A client with an earlier checkpoint receives individual removals in bounded pages. A forward adoption replaces future assignments from the previous revision and retains their historical records.

The participant task endpoint returns a snapshot ordered by committed change version. Follow each continuation to its checkpoint and use that checkpoint for subsequent deltas. Apply invalidated identifiers as removals. A cursor expires after 24 hours. Changing enrollment authority during pagination requires a fresh snapshot.

### Task Completion

The participant app starts the session of an assigned occurrence on the device, also while offline, with its own session ID, its start time and an administration language that a study administrator approved for the exact Questionnaire digest. The server confirms the session at the next sync when its start lies within the performance window and at most five minutes after server time; the confirmation may arrive after the window ended while the enrollment is active. The session fixes that language, the start time, the accepted consent, the performance window and the study-scoped subject identifier. Sending the same session again returns it. The first confirmed session of an occurrence wins: another session ID is refused with the problem title "Task Session Superseded", and that device keeps its response as not accepted. The device locale plays no part.

A completion sends the exact QuestionnaireResponse bytes with the session ID and a command key. A short transaction first returns the receipt of an exact retry or checks that the session still matches its occurrence, consent and window. Outside any database lock, Trove then checks that the response's subject is exactly the session's identifier and that its authored instant lies within the performance window, not before the whole second of the session start, and at most five minutes after server time, reads the Questionnaire bytes the occurrence pins from the derived artifact cache of the publication archive, which publication fills and a completion refills from the archive when an entry is missing or does not match its digest, and checks the pair with Grove's pair rules, which also require the status `completed` and the session language. The pinned validator then checks the response on its own with its reusable engine, as for other participant events, and the response bytes are staged in object storage. A second transaction checks the session, consent, enrollment and assignment again, retains the staged response as an artifact, records the receipt with the submitted authored time and the receipt time, records the audit event and changes the occurrence to `completed` with the receipt ID. The authored time decides the window, with the five-minute bound against server time: a response authored from the opening until the exclusive cutoff is accepted also when it reaches the server after the cutoff, while the enrollment and its consent remain active. A window without an end has no deadline.

The first accepted completion of an occurrence wins. Retrying the same bytes with the same session and command key returns the original receipt while the enrollment is active, also after a later revision adoption; any other completion of that occurrence is refused. A failed check, an unavailable validator or a failed audit write accepts nothing: no receipt, no retained response and no change of the occurrence. A response staged before the failure stays in object storage until the artifact cleanup removes it.

A validated response is one that Grove's pair rules accept against the exact published Questionnaire and whose own structure the validator engine accepts under the Grove QuestionnaireResponse profile. It does not mean that the official validator checked the pair. It says nothing about the clinical meaning of the answers.

An occurrence has one outcome. It is completed with a receipt; failed when the participant started its session but reports that it cannot be completed; cancelled with the reason excused when a researcher with data-reader access excuses it; or missed when its cutoff passes while it is still assigned. A response authored or a failure recorded within the window can still arrive after the cutoff while the enrollment is open, so a missed occurrence can later become completed or failed. A failure carries the device time of the attempt, which must lie within the performance window, not before the whole second of the session start, and at most five minutes after server time; the report may arrive after the cutoff. It is final. An occurrence without a cutoff is never missed. Completed, failed and excused occurrences keep their outcome when a later revision replaces future work. Withdrawal and enrollment expiry remove every occurrence, including completed, failed and excused ones, from the participant's stream; the receipts, responses, failures and excusals remain stored.

## Questionnaires

A questionnaire component holds one FHIR Questionnaire JSON resource with every language of the instrument. `Questionnaire.language` names the base language; the other languages are standard [`translation` extensions](https://hl7.org/fhir/extensions/StructureDefinition-translation.html) on the strings a participant reads, as the Grove FHIR Questionnaire profile defines. The server stores, publishes and exports the resource's exact bytes, and the component API reports its base language and the translation languages it contains. The dashboard edits the resource as JSON text, lists those languages, and uploads and downloads the text without reformatting; formatting it is a separate action. The [CLI](https://github.com/SchmiedmayerLab/Trove/blob/main/TroveAPI/CLI.md) imports an unmodified UTF-8 file into a draft revision and exports the stored resource byte for byte.

Validation runs each questionnaire through the pinned validator: the official FHIR Validator with the Grove FHIR packages, which checks the profile, including that a translation never repeats the base language and that a string carries at most one translation per language, and the Grove FHIR questionnaire rules. Trove then checks the supported execution subset. A translation is admitted only on a string that the participant application renders in the participant's language: the title, description and purpose, use-context displays, and an item's text, prefix, code displays and answer option displays and string values. A translation anywhere else, and any other extension on those strings, is rejected.

Each finding names its severity, its source (FHIR Validator, Grove rules or Trove rules), a stable rule or message identifier, the FHIRPath of the element and, where it concerns one translation, that translation's language. Trove's own rules also state the next action. A result is `valid` only when no finding is an error and no finding of the official validator states that a check was skipped. It is `invalid` when any finding is an error, `incomplete` when the official validator reports that it could not resolve the Questionnaire a response names, an enableWhen condition or a profile the resource declares, or could not check slicing cardinality or a code against a value set binding or answer options, and `unavailable` when the validator could not be reached or returned no trustworthy result. A code from a code system outside the offline package set is reported as information unless a value set check depends on it. Neither `incomplete` nor `unavailable` counts as valid.

A questionnaire component can be validated on its own, from the dashboard's questionnaire form or with `trove questionnaire validate`; that result changes nothing and is not publication evidence. Draft validation checks every questionnaire of the exact draft revision together with the study details languages. It returns the findings that prevent publication as blockers and the others as advisories, and only a `valid` result creates a publication candidate. Its evidence binds each resource's SHA-256 digest, its base and translation languages, the validator identity, contract revision and supported execution capability.

The server contains a validation of a QuestionnaireResponse against the exact Questionnaire it answers, with Grove's pair rules and the official validator. The validator runs one such pair at a time in a separate process and validates nothing else meanwhile. Participant task completion does not use it; see [Task Completion](#task-completion).

There are three separate questions:

1. Is the resource structurally valid under its declared profiles?
2. Does the selected application support all required behavior?
3. Is the instrument appropriate, licensed and approved for the intended research use?

A validator addresses the first, capability checks address the second, and researcher review addresses the third. None is a substitute for the others. A technically valid expression that the renderer cannot evaluate must not be presented as supported.

Import does not change source wording, translations, answer options, units, branching or scoring. A published instrument remains pinned to its revision, and the participant study bundle contains the one resource; a renderer selects the language to show.

### Branching Scenarios

The scenarios operation (`POST /studies/{studyId}/components/{componentId}/scenarios`, or `trove questionnaire scenario`) derives the branching graph of a stored questionnaire and evaluates named sets of synthetic answers against it. The graph has a node for every item and three kinds of edge: containment from a group or question to each nested item, order between consecutive siblings, and dependency from the question an `enableWhen` condition names to the item it gates. Each scenario reports every item instance as `enabled`, `disabled` or `notEvaluated` with the reason and the outcome of each condition, and the answers a completed response keeps, which leave out the answers of disabled items.

Evaluation follows the FHIR enableWhen rules ([R4 definitions](https://hl7.org/fhir/R4/questionnaire-definitions.html#Questionnaire.item.enableWhen)): `enableBehavior` `all` or `any`, `exists`, and equality and order for the answer type of the question. Operators follow the R5 wording, which is also the intent of the R4 text. `=`, `>`, `<`, `>=` and `<=` hold when at least one answer satisfies them, and `!=` holds when no answer has a value equal to the condition's, so it holds without an answer. An item is enabled only while every enclosing item is, and the answers of a disabled question count as absent. A coding matches only when its system and code both equal the condition's, so a coding without a system matches only another coding without one; the graph and questionnaire validation report every answer option and condition coding without a system as a warning, which makes the graph incomplete. When a question occurs more than once, a condition reads the nearest occurrence by the R4 rule: an enclosing occurrence on the ancestor axis, otherwise the nearest preceding occurrence, otherwise the nearest following one, in the document order of every item instance the form shows. Inside a repeating group, a question before the gated item is therefore read in the same instance, and a question after it is read in the previous instance, except in the first. An item nested under an answer of a question reads all of that question's answers. The graph reports a warning for a condition whose question repeats outside the gated item's repeat context and for one whose question follows the gated item inside a repeating context, because both can read another instance.

An item is `notEvaluated` when its state depends on something the evaluator does not decide: an SDC `enableWhenExpression` or `calculatedExpression`, a dependency cycle through conditions or enclosing items, a condition with a dangling or ambiguous reference, a type or operator mismatch, several conditions without `enableBehavior`, dates of different precision that agree as far as both go, or quantities in different units. Expressions are preserved and reported, and they add no edge. The graph is complete only when it reports no error or warning, so a broken reference, a cycle or an unevaluated expression is never shown as a verified branch. The result is bound to the SHA-256 digest of the evaluated bytes, the draft revision and the evaluator identity; it is not stored and creates no participant records. Inspecting the draft is enough to run scenarios.

The shared fixtures in `TroveAPI/Tests/Fixtures/questionnaire-scenarios` hold a questionnaire, a request and the expected graph and results for each rule. Every member a fixture states must equal the evaluator's output; members it leaves out are not compared, and a stated array must have as many elements as the output.

## Localization

Study details (title, short title and explanations) are language-keyed values with an explicit source language. A language is a BCP 47 tag in canonical case: a language with an optional script and region, such as `de`, `zh-Hant` or `pt-BR`. A region is not required, and distinct tags stay distinct. The special codes `und`, `mul`, `zxx`, `mis` and `qaa`–`qtz` are rejected. The participant study bundle keys details by language and region, so publication gives a tag without a region its likely region (`de` as `de-DE`) and rejects tags that would share a locale or that no locale represents.

A questionnaire carries its languages inside its one resource. Publication requires its base language to have a region, such as `en-US`; translation languages need none.

Consent documents and informational content are separate documents per language-region locale, for example `en-US`. Consent binds the exact requested locale; it does not fall back to another language. The generated health-data collection and enrollment-period sections of a consent document are available in English and German; when a study collects health data, other consent locales are rejected.

## Invitations

Researchers can create batches of invitation codes for a study, optionally with an expiry, and list or delete them. A revision can restrict enrollment to participants with a valid code for that study; enrollment retains the redeemed code as evidence.
