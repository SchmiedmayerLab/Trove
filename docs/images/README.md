<!--
SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
SPDX-License-Identifier: MIT
-->

# Reproducing the Platform Tour

These are captures of the working development application, using synthetic accounts
and a disposable Daily Activity Study. They are not interface mockups or evidence of
clinical deployment. Do not capture a running study or a personal Health library.

## Prepare the Local Stack

Use the repository's [native UI-test stack](https://github.com/SchmiedmayerLab/Trove/blob/main/TroveiOS/scripts/start-ui-test-stack.sh)
with the Keycloak version and setup in [Build and Test](https://github.com/SchmiedmayerLab/Trove/blob/main/.github/workflows/build-and-test.yml).
It binds Keycloak to port 8180 and a fresh in-memory development backend to port 8080.
The script refuses occupied ports. Keep its process IDs and stop only those processes
when finished; never clear another developer's database or identity service.

Set `RUNNER_TEMP` to a fresh temporary directory, `GITHUB_ENV` to a file inside it,
and `KEYCLOAK_HOME` to the local Keycloak installation. The optional
`TROVE_UI_TEST_SERVER_BINARY` must name the exact server binary built from the source
being captured. Use the development realm's synthetic password as
`KEYCLOAK_DEV_PASSWORD`; do not put tokens or real credentials in captured output.

## Web Captures

From the repository root, with Node 26 and the disposable stack running:

```sh
cd TroveWeb
npm ci --ignore-scripts
npm run generate:api
npx playwright install chromium
TROVE_DOCUMENTATION_FIXTURE=disposable npx playwright test --config documentation.config.ts
```

The fixture requires an empty development group. It creates the study and participant
through authenticated APIs, edits and publishes through the dashboard, then captures
eight researcher views in both light and dark appearances (16 PNGs). Rerun against a fresh backend; the fixture deliberately refuses
to delete or reuse existing studies. It does not contain a Questionnaire, so no capture
depends on bypassing FHIR validation.
The capture backend still needs `FHIR_VALIDATOR_IDENTITY` set to `sha256:` followed
by the SHA-256 of `TroveInfrastructure/validator/manifest.json`; publication binds
that identity even when the study has no Questionnaires. This fixture does not
exercise the remote FHIR validator.

To preserve an existing local session, run a separate fresh in-memory backend and set
`TROVE_DOCUMENTATION_API_PORT` to its loopback port (default: 8080). Both the fixture
and dashboard use that port; the empty-group safeguard still applies. Keycloak stays
on 8180. Stop only the extra backend when capture finishes.

The capture configuration starts with a 1440 × 960 viewport, English and Pacific time.
Long enrollment and consent forms increase the actual viewport height before capture,
so the sidebar footer remains at the bottom of the browser window. The capture test
checks that alignment in both appearances; it does not stretch or reposition the sidebar.
Each view is captured in the application's actual light and dark appearances;
the test waits for the design system to apply the requested color scheme.

`scripts/frame-screenshot.swift` adds Safari-style chrome with a generic `trove`
address, matching light/dark controls, rounded window corners and a subtle shadow.
The surrounding canvas is transparent. There are no footer labels or overlays on
the page content. This is a presentation frame, not a capture of Safari itself.
The underlying page capture is unchanged, with the taller viewports keeping longer
forms and signature blocks visible. Files use `name.png` and `name~dark.png`;
the documentation selects the matching appearance automatically.

To reframe an existing raw capture:

```sh
swift scripts/frame-screenshot.swift raw.png framed.png "Consent Authoring" light
```

Pass `dark` only for a page actually captured in dark mode. The synthetic-data and
development context is documented here and in the tour, rather than baked into
the images. Authentication traces and videos
are disabled. Raw captures remain in Playwright's ignored test output directory.

## Mobile Captures

First run the web-capture workflow above against the same development stack.
It seeds and publishes the synthetic Daily Activity Study used by the mobile
captures. A fresh UI-test stack alone does not contain that published study.

Build and install the same revision of the iOS app on a dedicated iPhone 17 Pro
Simulator. Use the CI build settings and `xcbeautify`; do not take screenshots while
automated tests own the simulator. Sign in as the synthetic Alice participant from
the development realm. Open RocketSim's live preview for visual review.

Explicitly install the built `Trove.app` with `xcrun simctl install` after tests.
Do not assume that launching the ordinary app uses the test build: Xcode's test
installation can leave an older app available. Use `xcrun simctl get_app_container
SIMULATOR_UDID org.troveplatform.app app` to locate the installed bundle and compare
its executable (and `Trove.debug.dylib`, when present) against the build output.
Reinstalling must preserve the synthetic participant's data; do not uninstall or
reset queued data to resolve a build mismatch.

Capture these states in order:

1. Browse the published Daily Activity Study: `studies`.
2. Open its study information before enrollment: `study`.
3. Enroll, then open the consent document without signing: `consent`.
4. Open Health Data without enabling a personal data source: `health-data`.

For each state, run from the repository root:

```sh
bash TroveiOS/scripts/capture-documentation.sh SIMULATOR_UDID consent
```

Replace `consent` with the corresponding capture name. RocketSim supplies the device
bezel; the script captures light and dark appearances, uses a consistent status bar,
and checks that both outputs decode before replacing existing files. Review every
image for the expected content, visible errors, clipping and stale branding. A valid
PNG is not proof that the app is on the correct screen.

The simulator demonstrates interface behavior only. It does not establish physical
device background delivery, HealthKit authorization, or data-protection behavior.

## Image Review and Licensing

Review the [Platform Tour](../Platform-Tour.md) against the captures. Screenshots
must show the documented revision, synthetic data and the named view without
clipping or stale branding. Planned features should not appear as working UI.

Record the source and dependency revisions with test results when updating images.
Raw captures and temporary evidence stay outside the committed documentation.
The image license is recorded in `REUSE.toml`.
