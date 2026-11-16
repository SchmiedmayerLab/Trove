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


## Wearable service authorization

Health Data lists deployment-approved wearable services and participant connection
status. A connection uses a server-created, expiring authorization intent; the app
opens the provider in the system authentication browser and returns its code and
state to Trove using the same captured participant session. Provider access and
refresh tokens remain on the server. Account changes, cancelled browser sessions,
expired intents and callbacks outside the approved HTTPS location cannot complete
an authorization under a replacement session.

The app uses the system HTTPS callback API. A deployment enabling provider linking
must configure all of the following together:

- Register the exact HTTPS callback URI with the provider and in the approved
  Trove provider registration. Use a dedicated path without query or fragment.
- Set `TROVE_PROVIDER_REDIRECT_URI` to that URI and
  `TROVE_PROVIDER_AUTH_DOMAIN` to its host in the app's build configuration.
- Select `CODE_SIGN_ENTITLEMENTS=TroveProvider.entitlements` and sign with a
  provisioning profile supporting Associated Domains. This configuration includes
  the native HealthKit and SensorKit entitlements as well as the provider callback domain.
- Host the `apple-app-site-association` file on that domain with a `webcredentials`
  association for the signed application's team and bundle identifier
  (`org.troveplatform.app` by default). The app and association file must use the
  same signing identity and domain.

Keep the callback path free of analytics, referrer forwarding and query-string
access logging. If served as a browser fallback, return a minimal page without
embedding the code or state and use `Cache-Control: no-store` and
`Referrer-Policy: no-referrer`.

Without a configured callback, the app explains why connecting a new wearable
service is unavailable; it still exposes the connection status and disconnect
controls supported by the server. Provider connection availability is separate
from consent: only the exact registration, source stream and output profiles in
accepted study settings authorize acquisition. Native simulator checks verify
callback parsing and session fencing; deployment association and real provider
credential exchange require their configured integration checks.


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
a guessed signing token. The raw and hybrid adapters, including photoplethysmogram,
are not part of the default deployment sensor list either; a deployment adds them
together with its approved entitlement and usage descriptions.

Apple documents the managed entitlement and usage descriptions in
[Configuring your project for sensor reading](https://developer.apple.com/documentation/sensorkit/configuring-your-project-for-sensor-reading).
Simulator tests do not establish managed signing, physical-device authorization,
background scheduling, retention availability or successful research deployment.

## HealthKit collection after an enrollment ends

Collection under a retained plan stops at the enrollment's end, also offline. A
sleep or workout session that overlaps the last accepted window can still be
finalized in HealthKit afterwards. When the participant synchronizes in the
foreground with a reachable server, the app requests a short-lived instruction
for each such closed window, runs its bounded query, and reports completion. It
never does so in the background or from the ended plan alone. If the lease expires,
the server is unreachable or local storage is full, the sweep keeps its position
and continues at the next synchronization. A HealthKit type whose read access was
never requested is not swept, because HealthKit would answer with no samples.
