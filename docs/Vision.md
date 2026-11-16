<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Project Scope

Trove provides study management for digital health research: study definitions,
participant enrollment and consent, and collection of health data. One deployment
serves several studies.

The [platform tour](Platform-Tour.md) shows the interfaces.

## Study Definitions

A study definition describes participant-facing content, activities, collection
requirements and execution rules. Collection requirements identify the data needed
and the permitted sources independently of any one operating system. Applications
report the capabilities they support.

Published revisions preserve the content a participant accepted. The server owns
enrollment, consent and accepted results. Clients can cache state and queue work;
consent and task completion are established only by the server.

[Grove](https://github.com/SchmiedmayerLab/Grove) supplies reusable application
components. The [Grove FHIR implementation guides](https://schmiedmayerlab.github.io/grove-fhir/)
define exchange profiles. Trove adds study management and storage around them.

## Storage and Access

One measurement can be relevant to several studies. Trove stores its source event
once and records each study's authorization separately. Withdrawal from one study
does not change another study's evidence or grant it additional access.

Health data is exchanged as FHIR resources, and questionnaires are stored as FHIR
JSON resources. PostgreSQL and TimescaleDB provide transactional and time-series
storage; object storage holds larger artifacts.

## Researcher Interfaces

The dashboard and Swift CLI use the same typed API and permission checks. The
dashboard edits consent documents visually or in Markdown and questionnaires as
FHIR JSON. The CLI creates and edits studies, imports questionnaires, publishes
revisions and retrieves study data.

Publication, participant contact and access to study data require their own
permissions. Scientific validity, institutional approval and intervention
suitability are the research team's responsibility.

## Scope Limits

Trove is not a general clinical-trial management suite, statistical analysis
environment or arbitrary application-hosting service. Research analysis uses
authorized exports in separate tools.

Specialized assessments, such as a six-minute walk test or guided ECG capture,
remain in study applications. They use Trove's configuration and result contracts
and keep their acquisition UI and scoring in the study application. Grove holds
the components that several applications share.

## Design Documents

- [Study Model and Research Workflows](Study-Model-and-Research-Workflows.md):
  definitions, publication, consent, tasks and research operations.
- [Data and Platform Architecture](Data-and-Platform-Architecture.md):
  components, storage, authorization and synchronization.
- [Applications and Integrations](Applications-and-Integrations.md):
  mobile clients, collection recovery, wearables and other research systems.
- [Engineering and Verification](Engineering-and-Verification.md):
  implementation, testing and deployment requirements.
