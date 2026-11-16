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

A study definition contains components of three types: informational content, FHIR Questionnaires and health-data collection requirements. Each component carries its localized content.

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

Publishing creates an immutable revision. Artifacts have unique identities; the revision, references and publication receipt commit together. Concurrent publication cannot overwrite an accepted artifact. A participant continues under the revision they adopted until an explicit transition is permitted. Changes requiring renewed consent cannot be treated as a routine content refresh; history retains the versions that actually applied.

## Enrollment, Consent and Lifecycle

Enrollment links a participant to a study and its adopted revision. Consent records the exact approved content presented, the applicable acknowledgements or signatures and the participant's action. A reference to “the latest consent document” is insufficient because the latest document can change.

The current revision-adoption rule requires fresh consent for every explicitly selected forward revision, even when the wording is unchanged. Omitting a revision selects the enrollment's current revision, not the newest publication. The server rechecks the exact published presentation and target participation criteria before committing consent, revision adoption, enrollment state and audit together. A newly invitation-restricted revision requires retained invitation evidence for the same study; an already redeemed code is not consumed again.

Exact command retries return the original consent receipt without adopting again, including after later adoption or withdrawal. They do not restore participation. Downgrades and consent-free upgrade routes are rejected. This rule does not establish institutional approval or legal validity of a signature.

Withdrawal and source-data retraction are separate operations. Withdrawal ends the affected participation and the collection and access that are no longer authorized; it does not delete records retained for another independently authorized study. Trove has no account-deletion or erasure operation.

## Schedules

Informational and questionnaire components can have schedules; health-data collection components cannot. A schedule runs once, at a date or relative to a study event such as enrollment or the completion of another component, or repeats daily, weekly or monthly with an interval and offset. It also declares a completion policy and whether a notification is enabled. Schedules are part of the published revision.

The server does not assign task occurrences, accept task completion or synchronize completion across devices.

## Questionnaires

A questionnaire component holds one FHIR Questionnaire JSON resource for each language-region locale of the component. The dashboard edits the resource as JSON text and can upload, format and download it. The [CLI](https://github.com/SchmiedmayerLab/Trove/blob/main/TroveAPI/CLI.md) imports an unmodified UTF-8 file into a draft revision without rewriting identifiers, profiles or whitespace.

Validation before publication runs each questionnaire through the pinned Grove validator. Its evidence binds the resource's SHA-256 digest, validator identity, contract revision and supported execution capability. A questionnaire that the supported study client cannot execute is rejected.

There are three separate questions:

1. Is the resource structurally valid under its declared profiles?
2. Does the selected application support all required behavior?
3. Is the instrument appropriate, licensed and approved for the intended research use?

A validator addresses the first, capability checks address the second, and researcher review addresses the third. None is a substitute for the others. A technically valid expression that the renderer cannot evaluate must not be presented as supported.

Import does not change source wording, answer options, units, branching or scoring. A published instrument remains pinned to its revision.

## Localization

Study content, consent documents and component content are stored per language-region locale, for example `en-US`. Consent binds the exact requested locale; it does not fall back to another language. The generated health-data collection and enrollment-period sections of a consent document are available in English and German; when a study collects health data, other consent locales are rejected.

## Invitations

Researchers can create batches of invitation codes for a study, optionally with an expiry, and list or delete them. A revision can restrict enrollment to participants with a valid code for that study; enrollment retains the redeemed code as evidence.
