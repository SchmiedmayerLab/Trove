<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Project Scope

Trove provides study management for digital health research: study definitions,
participant enrollment and consent, and collection of health data. The aim is to
let studies share these services while retaining their own participant interfaces
and specialized procedures.

Trove is in beta and is being actively tested and used at Stanford.
The [platform tour](Platform-Tour.md) shows the current interfaces.
The design pages describe both implemented contracts and planned extensions;
[GitHub milestones](https://github.com/SchmiedmayerLab/Trove/milestones) and
[issues](https://github.com/SchmiedmayerLab/Trove/issues) track delivery.

## Study Definitions

A study definition describes participant-facing content, activities, collection
requirements and execution rules. Collection requirements identify the data needed
and permitted sources, rather than the internals of one operating system.
Applications report the capabilities they support.

Published revisions preserve the content a participant accepted. The server owns
enrollment, consent and accepted results. Clients can cache state and queue work,
but they cannot independently establish consent or task completion.

[Grove](https://github.com/SchmiedmayerLab/Grove) supplies reusable application
components. The [Grove FHIR implementation guides](https://schmiedmayerlab.github.io/grove-fhir/)
define exchange profiles. Trove adds study management and storage around them.

## Storage and Access

One measurement can be relevant to several studies. Trove stores its source event
once and records each study's authorization separately. Withdrawal from one study
does not change another study's evidence or grant it additional access.

FHIR is the exchange format, not a requirement to represent every database row as
a FHIR resource. PostgreSQL and TimescaleDB provide transactional and time-series
storage; object storage holds larger artifacts.

## Researcher Interfaces

The dashboard, Swift CLI and planned authoring assistants use the same typed API
and permission checks. Visual editing is useful for reviewing consent wording,
questionnaire structure and branching. Command-line and assisted workflows reduce
repetitive configuration without introducing a separate study model.

Assistance produces reviewable drafts. Publication, participant contact and access
to study data require their own permissions. Scientific validity, institutional
approval and intervention suitability remain research responsibilities.

## Scope Limits

Trove is not a general clinical-trial management suite, statistical analysis
environment or arbitrary application-hosting service. Research analysis uses
authorized exports in separate tools.

Specialized assessments, such as a six-minute walk test or guided ECG capture,
remain in study applications. They can use Trove's configuration and result
contracts without moving their acquisition UI or scoring into the core platform.
A component can move into Grove when multiple applications need the same behavior.

## Design Documents

- [Study Model and Research Workflows](Study-Model-and-Research-Workflows.md):
  definitions, publication, consent, tasks and research operations.
- [Data and Platform Architecture](Data-and-Platform-Architecture.md):
  components, storage, authorization and synchronization.
- [Applications and Integrations](Applications-and-Integrations.md):
  mobile clients, wearables, conversation tasks and custom services.
- [Engineering and Verification](Engineering-and-Verification.md):
  implementation, testing and deployment requirements.
