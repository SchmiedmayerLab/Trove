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


## SensorKit deployment

Native SensorKit acquisition uses the same participant journal and delivery queue
as HealthKit. A capture pass stages a bounded batch and its immutable source facts
before acknowledging the native cursor. Recording restarts follow the locally
retained study authority; local withdrawal stops recording before another capture
pass. Background processing is an opportunity supplied by iOS, not a guarantee of
continuous collection or access to data outside SensorKit's retention window.

SensorKit is disabled in the default build configuration. Before enabling it:

- Obtain Apple's managed sensor-reader entitlement and a matching provisioning
  profile for the research deployment. The base and provider-enabled entitlement
  files include `on-wrist`, `visits`, `messages-usage` and `phone-usage`.
- Set `TROVE_SENSORKIT_ENABLED=YES` and `TROVE_SENSORKIT_PRIVACY_POLICY_URL` to the
  deployment's HTTPS research privacy policy. Missing or invalid settings leave
  SensorKit disabled before any reader is created.
- Keep `TroveSensorKitSources`, the signed entitlement array and the per-sensor
  `NSSensorKitUsageDetail` descriptions aligned with the deployment's approved
  sensor selection. Study consent still controls each source and output separately.

The sleep-session adapter retains the native identifier and exact supplied bounds,
but it is not included in the deployment sensor list: the exact managed entitlement
and usage-description keys require confirmation for that sensor. Do not substitute
a guessed signing token. Additional raw and hybrid adapters are not advertised as
available until their acquisition and receiver paths are implemented and verified.

Apple documents the managed entitlement and usage descriptions in
[Configuring your project for sensor reading](https://developer.apple.com/documentation/sensorkit/configuring-your-project-for-sensor-reading).
Simulator tests do not establish managed signing, physical-device authorization,
background scheduling, retention availability or successful research deployment.
