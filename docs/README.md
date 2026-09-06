<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Trove: A Shared Foundation for Digital Studies

Digital studies often need the same foundations—participant identity, consent, scheduled activities, reliable data collection and a way to return results—while differing substantially in their scientific questions and participant experience.

Trove's goal is to provide those foundations once. Researchers should be able to describe a study in a structured form, run it through supported applications and services, and retain a clear record of what participants agreed to, what was assigned and what data was received. A study-specific application should be able to use the same backend without giving up its own interface or domain logic.

This documentation describes the platform's target architecture and development direction. It explains design decisions, not a guarantee that every described capability is available in a released version. The [roadmap](Roadmap-and-Engineering-Principles.md) distinguishes the initial delivery from later capabilities.

## The Core Idea

A study definition connects the scientific protocol to the software that carries it out. It identifies approved content, activities, collection requirements, supported sources and execution rules. Trove connects that definition to participant consent, assigned task occurrences and governed data access.

The definition should describe *what the study needs*, rather than encode the internals of one mobile operating system. Applications report which requirements they can support. The backend owns shared state and authorization; clients provide the appropriate experience.

The shared foundations are [Grove](https://github.com/SchmiedmayerLab/Grove) for reusable application components and the [Grove FHIR implementation guides](https://schmiedmayerlab.github.io/grove-fhir/) for interoperable exchange. Trove adds the study backend and researcher workflows around those contracts.

This separation makes several kinds of study possible within one architecture:

- A mobile study collecting wearable data and scheduled questionnaires.
- A study with a protocol-defined conversational intervention and follow-up activities.
- A custom application with specialized assessments, using shared enrollment and data services.
- Future browser or communication-channel participation where the protocol can be represented faithfully.

These are different uses of common study infrastructure, not separate products with independent consent and completion records.

## Design Principles

**One authority for study participation.** Enrollment, consent, adopted study revision, assignments and accepted task completion belong to the core backend. A client cache, external service or generated response cannot establish those facts independently.

**Shared data without shared permission.** A source measurement can be relevant to more than one study without being stored repeatedly. Access remains specific to each study's authorized purpose and exact data versions.

**Interoperability at the boundaries.** Grove FHIR profiles provide the clinical and study-exchange vocabulary. The database can use efficient relational, time-series and object storage rather than storing every internal operation as FHIR JSON.

**Extensibility through clear contracts.** Study-specific interfaces, assessment procedures and computation stay outside the core. They integrate through versioned configuration, scoped APIs and explicit result contracts.

**Researcher judgment remains essential.** The platform can check technical consistency, preserve evidence and reduce repetitive work. It does not decide scientific validity, institutional approval or the suitability of an intervention.

**A focused path to useful releases.** The first objective is one complete study workflow. Conversations, custom-client reuse and additional research capabilities build on that foundation as their requirements become concrete.

Implementation work is tracked in the [Trove project](https://github.com/orgs/SchmiedmayerLab/projects/4). Repository issues own acceptance criteria; the project tracks priority and delivery status.

## Read the Design

| Page | Questions it answers |
|---|---|
| [Study Model and Research Workflows](Study-Model-and-Research-Workflows.md) | How are studies defined, consented, executed and closed? How do research operations fit? |
| [Data and Platform Architecture](Data-and-Platform-Architecture.md) | How are data stored once, linked, authorized, synchronized and exported? |
| [Applications and Integrations](Applications-and-Integrations.md) | How do mobile apps, wearables, conversations and custom services share the platform? |
| [Roadmap and Engineering Principles](Roadmap-and-Engineering-Principles.md) | What comes first, what remains conditional, and how is quality maintained? |

## What Trove Is Not

Trove is not intended to become a general electronic data-capture suite, a clinical-trial management system, a statistical analysis environment or an unrestricted application-hosting platform.

It also does not need to implement every active assessment. Procedures such as a six-minute walk test or guided ECG capture can remain in specialized applications, with Trove providing configuration, authorized result exchange and optional shared task tracking. A reusable assessment may later justify a shared package when multiple applications need it.

Keeping these boundaries explicit allows the common infrastructure to improve without forcing every study into the same participant interface or introducing a new subsystem for each research project.
