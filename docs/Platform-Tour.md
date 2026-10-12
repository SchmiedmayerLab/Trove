<!--
SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
SPDX-License-Identifier: MIT
-->

# Platform Tour

Trove connects researcher-authored study definitions with participant identity,
enrollment, reviewed consent and health-data collection. These screenshots show
the beta application with a fictional **Daily Activity Study** and synthetic accounts.
[Capture details and reproduction](images/README.md).

## Study Authoring

Researchers configure a study in order: general information, enrollment and
participation criteria, then consent. Study components have their own top-level menu.

<picture><source media="(prefers-color-scheme: dark)" srcset="images/web/study-details~dark.png"><img src="images/web/study-details.png" alt="Study metadata beside its participant preview"></picture>

<details>
<summary>Eligibility and enrollment settings</summary>

<picture><source media="(prefers-color-scheme: dark)" srcset="images/web/enrollment~dark.png"><img src="images/web/enrollment.png" alt="Participation criteria, enrollment and visibility in one form"></picture>

</details>

Consent documents combine Markdown with native agreement and signature controls.
Researchers can switch between a readable preview, a visual editor and Markdown.
Agreement, selection and signature fields have editable IDs and options. The
editor checks duplicate IDs and keeps response references consistent when options
are renamed. Constructs outside the visual editor's supported set remain editable
in Markdown. The preview shows the document without collecting participant responses.

<picture><source media="(prefers-color-scheme: dark)" srcset="images/web/consent~dark.png"><img src="images/web/consent.png" alt="Consent document authoring"></picture>

<picture><source media="(prefers-color-scheme: dark)" srcset="images/web/consent-editor~dark.png"><img src="images/web/consent-editor.png" alt="Visual editing of consent fields"></picture>

Study components include information, FHIR Questionnaires and health-data
configuration. Scheduling defines when a component should become available;
this editor does not establish server-driven task execution or reminders.

<details>
<summary>Components, information and scheduling</summary>

<picture><source media="(prefers-color-scheme: dark)" srcset="images/web/component-types~dark.png"><img src="images/web/component-types.png" alt="Available component types"></picture>
<picture><source media="(prefers-color-scheme: dark)" srcset="images/web/information~dark.png"><img src="images/web/information.png" alt="Participant information editor"></picture>
<picture><source media="(prefers-color-scheme: dark)" srcset="images/web/schedule~dark.png"><img src="images/web/schedule.png" alt="Schedule relative to enrollment"></picture>

</details>

Publication is an explicit review step. Validation produces an exact, expiring
candidate; the researcher publishes that candidate rather than an unseen newer
draft. The illustrated study does not contain a Questionnaire.

<picture><source media="(prefers-color-scheme: dark)" srcset="images/web/publication~dark.png"><img src="images/web/publication.png" alt="Review of an immutable publication candidate"></picture>

## Participant App

Participants sign in, discover published studies, review eligibility and study
information, and enroll. Consent is reviewed separately before health-data
collection is authorized. All mobile images below are captured from the current
app through RocketSim, with device bezels and synthetic account data.

<table>
  <tr><th>Study Discovery</th><th>Study Information</th><th>Consent Review</th></tr>
  <tr>
    <td><picture><source media="(prefers-color-scheme: dark)" srcset="images/mobile/studies~dark.png"><img src="images/mobile/studies.png" alt="Published synthetic study in the participant app" width="260"></picture></td>
    <td><picture><source media="(prefers-color-scheme: dark)" srcset="images/mobile/study~dark.png"><img src="images/mobile/study.png" alt="Study description and eligibility result" width="260"></picture></td>
    <td><picture><source media="(prefers-color-scheme: dark)" srcset="images/mobile/consent~dark.png"><img src="images/mobile/consent.png" alt="Native consent review with agreement and signature controls" width="260"></picture></td>
  </tr>
</table>

<details>
<summary>Health-data setup</summary>

<picture><source media="(prefers-color-scheme: dark)" srcset="images/mobile/health-data~dark.png"><img src="images/mobile/health-data.png" alt="Heart-rate device setup before enabling collection" width="300"></picture>

The app separates device setup, Health access and delivery. This capture shows
the setup screen, not authorized collection or successful sample delivery.

</details>

## Current Scope

The screenshots cover study authoring, publication, discovery, enrollment and
consent review. The [Swift CLI guide](https://github.com/SchmiedmayerLab/Trove/blob/4273560d0c3e6454219995b649d56dce1e234135/TroveAPI/CLI.md)
documents the command-line authoring operations.

Randomization, automated follow-up, questionnaire branching previews and hosted
authoring are tracked in [GitHub milestones](https://github.com/SchmiedmayerLab/Trove/milestones).
Trove is in beta and is being actively tested and used at Stanford.
The illustrated study and accounts are synthetic.
