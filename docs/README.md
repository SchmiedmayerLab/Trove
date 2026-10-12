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

<p class="trove-eyebrow">Open-source digital health research</p>

# From study design to participant experience.

Trove brings study authoring, enrollment, consent, and health-data collection
together. Build on a shared foundation, with room for the experience your study needs.

[Explore the Platform](Platform-Tour.md){ .md-button .md-button--primary }
[Run Trove Locally](https://github.com/SchmiedmayerLab/Trove#running-it-locally){ .md-button }

<p class="trove-caption">Built with Swift and Grove · FHIR-aligned exchange · MIT licensed</p>

</div>

<figure class="trove-showcase">
  <picture><source media="(prefers-color-scheme: dark)" srcset="images/web/study-details~dark.png"><img src="images/web/study-details.png" alt="Trove dashboard: study details and a participant preview side by side" width="1600" fetchpriority="high"></picture>
  <figcaption>Define a study and see how it will appear to participants. All screenshots use synthetic data.</figcaption>
</figure>

<section class="trove-section" markdown>

<p class="trove-eyebrow">For research teams</p>

## One study definition. A connected workflow.

Configure eligibility and enrollment, write consent documents, and organize study
components. Review a publication candidate before making that exact revision
available to participants. Later draft edits stay separate from published content.

<ol class="trove-workflow">
  <li><strong>Define</strong><span>Study information, eligibility, and components.</span></li>
  <li><strong>Review</strong><span>Consent wording and the publication candidate.</span></li>
  <li><strong>Enroll</strong><span>Authenticated discovery and participation.</span></li>
  <li><strong>Collect</strong><span>Health-data delivery with study-specific authorization.</span></li>
</ol>

[See the Authoring Workflow →](Platform-Tour.md#study-authoring)

</section>

<section class="trove-split trove-section" markdown>

<div markdown>

<p class="trove-eyebrow">Consent, made readable</p>

## Clear documents. Explicit agreement.

Write consent in Markdown or use the visual editor for agreement, selection, and
signature fields. Participants review the document attached to their study revision
in the native app before authorizing collection.

[Explore Consent and Enrollment →](Study-Model-and-Research-Workflows.md)

</div>

<picture><source media="(prefers-color-scheme: dark)" srcset="images/web/consent-editor~dark.png"><img src="images/web/consent-editor.png" alt="Visual consent editor with editable agreement and signature controls" loading="lazy" width="1200"></picture>

</section>

<section class="trove-section" markdown>

<p class="trove-eyebrow">For participants</p>

## A study they can understand. An app they can use.

Discover published studies, review the details, and provide consent in the iOS app.
The platform's direction is a shared backend that also supports study-specific
applications without prescribing their interface.

<div class="trove-phones">
  <figure><picture><source media="(prefers-color-scheme: dark)" srcset="images/mobile/studies~dark.png"><img src="images/mobile/studies.png" alt="Study discovery in the Trove iOS app" loading="lazy" width="260"></picture><figcaption>Discover a study</figcaption></figure>
  <figure><picture><source media="(prefers-color-scheme: dark)" srcset="images/mobile/study~dark.png"><img src="images/mobile/study.png" alt="Study information and eligibility in the Trove iOS app" loading="lazy" width="260"></picture><figcaption>Review the details</figcaption></figure>
  <figure><picture><source media="(prefers-color-scheme: dark)" srcset="images/mobile/consent~dark.png"><img src="images/mobile/consent.png" alt="Consent review in the Trove iOS app" loading="lazy" width="260"></picture><figcaption>Provide consent</figcaption></figure>
</div>

</section>

<section class="trove-section trove-foundation" markdown>

<p class="trove-eyebrow">A foundation you can build on</p>

## Shared data does not mean shared permission.

Trove stores an event once and authorizes access independently for each study.
Swift powers the server, CLI, and iOS app; the web dashboard uses the same typed API.
[Grove](https://github.com/SchmiedmayerLab/Grove) supplies reusable application
components, and the [Grove FHIR implementation guides](https://schmiedmayerlab.github.io/grove-fhir/)
define the exchange contracts.

[Read the Architecture](Data-and-Platform-Architecture.md){ .md-button }
[Understand the Vision](Vision.md){ .md-button }

</section>

<section class="trove-section" markdown>

## Explore what is here. Help shape what comes next.

Trove is under active development. The tour shows implemented development flows,
not a production-ready clinical service. Randomization, automated follow-up,
conversational studies, and assisted authoring remain roadmap work; they are not
capabilities demonstrated by these screenshots.

[Follow the Roadmap](Roadmap-and-Engineering-Principles.md){ .md-button .md-button--primary }
[Contribute on GitHub](https://github.com/SchmiedmayerLab/Trove){ .md-button }

</section>

</div>
