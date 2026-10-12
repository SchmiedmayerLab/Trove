<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# iOS

The participant-facing app. It fetches the study definitions authored in the web portal and renders them as informational screens, questionnaires, and HealthKit data-collection flows, using the generated `TroveAPIClient` from [`TroveAPI/`](../TroveAPI) and the Grove UI and data modules.

## Getting started

See the [platform tour](../docs/Platform-Tour.md#participant-app) for current
RocketSim captures of study discovery, eligibility and consent, in light and dark
appearance. The [capture guide](../docs/images/README.md#mobile-captures) describes
the synthetic fixture and reproduction steps.

Open `Trove.xcodeproj` in Xcode and run the `Trove` scheme. The Swift package dependencies resolve on the first build.

## Native UI Test Boundary

The real-stack UI scenario exercises sign-in, enrollment, revised consent, device
setup, withdrawal and restored participant state. Its synthetic study has no
Questionnaires. The native launcher binds publication receipts to the checked-in
validator manifest, but deliberately leaves the validator endpoint unconfigured.
Adding a Questionnaire therefore requires a real pinned worker; it must fail
closed without one. This scenario does not establish FHIR validation or clinical
event admission. The separate validator and receiver checks cover those paths.
