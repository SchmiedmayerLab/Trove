---
title: Trove — Digital Health Studies
hide:
  - navigation
  - toc
---

<!--
SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
SPDX-License-Identifier: MIT
-->

<div class="trove-home" markdown>

<div class="trove-hero" markdown>

# Study management for digital health research

Configure studies in the web dashboard, publish reviewed revisions, and enroll
participants through the iOS app. Trove supports study information, consent,
and health-data collection, with a Swift server and command-line client.

[Explore the Platform](Platform-Tour.md){ .md-button .md-button--primary }
[Run Trove Locally](https://github.com/SchmiedmayerLab/Trove#running-it-locally){ .md-button }

<p class="trove-caption">Built with Swift and Grove · FHIR-aligned exchange · MIT licensed</p>

</div>

<figure class="trove-showcase">
  <picture><source media="(prefers-color-scheme: dark)" srcset="images/web/study-details~dark.png"><img src="images/web/study-details.png" alt="Trove dashboard: study details and a participant preview side by side" width="1600" fetchpriority="high"></picture>
  <figcaption>Define a study and see how it will appear to participants. All screenshots use synthetic data.</figcaption>
</figure>

<section class="trove-section" markdown>

## Configure and Publish a Study

Configure eligibility and enrollment, write consent documents, and organize study
components. Review a publication candidate before making that exact revision
available to participants. Later draft edits stay separate from published content.

[Study authoring walkthrough](Platform-Tour.md#study-authoring)

</section>

<section class="trove-split trove-section" markdown>

<div markdown>

## Edit Consent Documents

Write consent in Markdown or use the visual editor for agreement, selection, and
signature fields. Participants review the document attached to their study revision
in the native app before authorizing collection.

[Consent and enrollment model](Study-Model-and-Research-Workflows.md#enrollment-consent-and-lifecycle)

</div>

<picture><source media="(prefers-color-scheme: dark)" srcset="images/web/consent-editor~dark.png"><img src="images/web/consent-editor.png" alt="Visual consent editor with editable agreement and signature controls" loading="lazy" width="1200"></picture>

</section>

<section class="trove-section" markdown>

## Participant App

Discover published studies, review the details, and provide consent in the iOS app.
Study-specific apps can integrate through the API rather than adopting Trove's
participant interface.

<div class="trove-phones">
  <figure><picture><source media="(prefers-color-scheme: dark)" srcset="images/mobile/studies~dark.png"><img src="images/mobile/studies.png" alt="Study discovery in the Trove iOS app" loading="lazy" width="260"></picture><figcaption>Discover a study</figcaption></figure>
  <figure><picture><source media="(prefers-color-scheme: dark)" srcset="images/mobile/study~dark.png"><img src="images/mobile/study.png" alt="Study information and eligibility in the Trove iOS app" loading="lazy" width="260"></picture><figcaption>Review the details</figcaption></figure>
  <figure><picture><source media="(prefers-color-scheme: dark)" srcset="images/mobile/consent~dark.png"><img src="images/mobile/consent.png" alt="Consent review in the Trove iOS app" loading="lazy" width="260"></picture><figcaption>Provide consent</figcaption></figure>
</div>

</section>

<section class="trove-section trove-foundation" markdown>

## Architecture

Trove stores an event once and authorizes access independently for each study.
Swift powers the server, CLI, and iOS app; the web dashboard uses the same typed API.
[Grove](https://github.com/SchmiedmayerLab/Grove) supplies reusable application
components, and the [Grove FHIR implementation guides](https://schmiedmayerlab.github.io/grove-fhir/)
define the exchange contracts.

[Read the Architecture](Data-and-Platform-Architecture.md){ .md-button }
[Project Scope](Vision.md){ .md-button }

</section>

<section class="trove-section" markdown>

## Beta Release

Trove is in beta and is being actively tested and used at Stanford.
The [tour](Platform-Tour.md) documents the current interfaces. GitHub milestones
track planned work and delivery status; issues contain the implementation details
and acceptance criteria.

[GitHub Milestones](https://github.com/SchmiedmayerLab/Trove/milestones){ .md-button .md-button--primary }
[Contribute on GitHub](https://github.com/SchmiedmayerLab/Trove){ .md-button }

</section>

</div>
