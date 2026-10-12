<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Trove

[![Build and Test](https://github.com/SchmiedmayerLab/Trove/actions/workflows/build-and-test.yml/badge.svg)](https://github.com/SchmiedmayerLab/Trove/actions/workflows/build-and-test.yml)
[![CodeQL](https://github.com/SchmiedmayerLab/Trove/actions/workflows/codeql.yml/badge.svg)](https://github.com/SchmiedmayerLab/Trove/actions/workflows/codeql.yml)
[![REUSE status](https://api.reuse.software/badge/github.com/SchmiedmayerLab/Trove)](https://github.com/SchmiedmayerLab/Trove/actions/workflows/repository-standards.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE.md)

**Study management for digital health research. Open source, built with Swift and Grove.**

Define a study in the web dashboard, then make it available to participants in the
iOS app. Trove brings study information, eligibility, enrollment, consent and
health-data collection into one platform.

[Take a Tour](docs/Platform-Tour.md) · [Run Locally](#running-it-locally) · [Roadmap](docs/Roadmap-and-Engineering-Principles.md)

## For Research Teams

Set up eligibility and enrollment, edit consent documents, and add study components.
Preview what participants will see before publishing. Each published revision keeps
the study definition and consent terms together, separate from later draft edits.

![Trove dashboard: editing study information beside a participant preview](docs/images/web/study-details.png#gh-light-mode-only)
![Trove dashboard: editing study information beside a participant preview](docs/images/web/study-details~dark.png#gh-dark-mode-only)

## For Participants

Discover a study, review its requirements, and enroll. Review and sign its consent
document before authorizing health-data collection.

<table>
  <tr>
    <th>Find a Study</th>
    <th>Review the Details</th>
    <th>Provide Consent</th>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/mobile/studies.png#gh-light-mode-only" alt="Published studies in the Trove iOS app" width="230"><img src="docs/images/mobile/studies~dark.png#gh-dark-mode-only" alt="Published studies in the Trove iOS app" width="230"></td>
    <td align="center"><img src="docs/images/mobile/study.png#gh-light-mode-only" alt="Study information and eligibility in the Trove iOS app" width="230"><img src="docs/images/mobile/study~dark.png#gh-dark-mode-only" alt="Study information and eligibility in the Trove iOS app" width="230"></td>
    <td align="center"><img src="docs/images/mobile/consent.png#gh-light-mode-only" alt="Consent review with agreement and signature fields" width="230"><img src="docs/images/mobile/consent~dark.png#gh-dark-mode-only" alt="Consent review with agreement and signature fields" width="230"></td>
  </tr>
</table>

Trove is under active development. These screenshots use a fictional Daily Activity
Study and synthetic participant data. The [tour](docs/Platform-Tour.md) shows the
current flows; the [roadmap](docs/Roadmap-and-Engineering-Principles.md) covers planned
features, including randomization and automated follow-up.

Health-data exchange follows the Grove FHIR implementation guide. See the
[event-admission contract](TroveServer/README.md#event-admission) for supported data
and validation requirements.

## How it fits together

```mermaid
flowchart LR
    R([Researcher]) --> W["Web portal<br/><i>React, TypeScript</i>"]
    P([Participant]) --> I["iOS app<br/><i>Swift, SwiftUI</i>"]

    W -->|study management| S["Server<br/><i>Swift, Vapor</i>"]
    I -->|enrolment, reviewed consent| S

    W -.->|OIDC| K[Keycloak]
    I -.->|OIDC| K
    S -.->|token validation| K

    S --> PG[("PostgreSQL + TimescaleDB<br/>one core and clinical authority")]
    S --> OS[("S3 object store<br/>bundles, consent PDFs")]

    API[/"OpenAPI contract"/] -.-> W
    API -.-> I
    API -.-> S
```

One OpenAPI contract in [`TroveAPI/`](TroveAPI) is the source of truth: the server conforms to the generated `APIProtocol`, iOS consumes the generated Swift client, and the web portal generates its TypeScript client from the same spec. A change to the contract that breaks a consumer breaks the build.

| Path | What it is | Stack |
|------|-----------|-------|
| [`TroveAPI/`](TroveAPI) | The shared OpenAPI contract and the Swift libraries generated from it | Swift, swift-openapi-generator |
| [`TroveServer/`](TroveServer) | Study lifecycle, enrolment, consent, and clinical data authority | Swift, Vapor, Fluent |
| [`TroveWeb/`](TroveWeb) | The researcher portal for composing and publishing studies | React, TypeScript, Vite |
| [`TroveiOS/`](TroveiOS) | The participant app: identity, study discovery, enrolment | Swift, SwiftUI |
| [`TroveInfrastructure/`](TroveInfrastructure) | GitOps deployment onto Kubernetes | Kustomize, ArgoCD, OpenTofu |

## Studies and revisions

A study is a set of components a researcher configures and combines: informational content, questionnaires, and health-data collection, each with its own schedule and eligibility rules. Publishing freezes the current definition into a numbered revision. Enrolments point at a revision rather than at the mutable study, so the terms a participant accepted stay fixed even as the researcher keeps editing.

## Storing the data

One **PostgreSQL database with TimescaleDB** owns study definitions, enrolments, consent,
audit and the clinical data boundary. Repositories participating in one accepted operation
share its explicit transaction; two separate database pools cannot provide that guarantee.
**S3-compatible object storage** holds immutable study bundles and signed consent PDFs.

Trove is in early development: schema changes target a fresh database, with no upgrade
or legacy-data import path. Recreate disposable development databases when their schema
changes; do not attach an old PostgreSQL data directory to a different engine image.
The IG receiver retains event custody separately from independently authorized
study grants; withdrawal from one study does not rewrite another study's evidence.

Keycloak is the sole authority for identities, roles, and group membership; all three applications authenticate against it over OpenID Connect and the server validates tokens against its JWKS.

## Running it locally

Follow the [local stack instructions](TroveInfrastructure/docker/README.md) to build the
current images and initialize a fresh database. The setup orders schema creation and explicit
runtime grants before server startup. Serving and schema-owner credentials are separate;
the runtime must not be a database owner.

[`TroveInfrastructure/docker/smoke-test.sh`](TroveInfrastructure/docker/smoke-test.sh) checks the stack end to end — services healthy, realm imported, protected routes rejecting anonymous callers, and the server answering an authenticated request with the groups it synced from Keycloak. It runs in CI on every change to the server, web, or infrastructure.

## Continuous integration

`build-and-test.yml` is the entry point: it works out which components a change touches and runs only those, so a web-only change does not rebuild the iOS app.

Manual runs and the weekly Sunday 06:17 UTC run select every Trove component,
including the native AMD64/ARM64 stack checks, to detect gaps in path selection.
They do not publish images or deploy services. This is the Trove matrix, not the
full matrix of its upstream Grove repository.

| Job | Runs when |
|----------|-------------|
| API | `TroveAPI/**` |
| Server | `TroveServer/**`, `TroveAPI/**` |
| Web | `TroveWeb/**`, `TroveAPI/openapi.yaml` |
| iOS | `TroveiOS/**`, `TroveAPI/**` |
| Infrastructure | `TroveInfrastructure/**` |
| Dev Stack | `TroveServer/**`, `TroveWeb/**`, `TroveInfrastructure/**` |
| Secret Scan | Every run, including documentation-only changes |
| Dependency Vulnerability Scan | Every run; also scheduled weekly |

`Required Verification` rejects failed, cancelled, missing or unexpectedly skipped
required jobs. The secret scan uses the same pinned tool and shared command locally
and in CI, tests synthetic negative controls, and retains location-only findings.
See [verification commands](AGENTS.md#verification).

The dependency scan requires every declared input to be analyzed and checks a
known-vulnerable control. Web and development-stack jobs also scan their built
application images by local image ID. Findings of any severity fail verification;
reports, input identities and CycloneDX inventories are retained as artifacts.

`static-analysis.yml` runs SwiftLint and Swift CodeQL analysis. `codeql.yml` covers
JavaScript and TypeScript. Both scans run on every pull request, including stacks;
GitHub's default CodeQL setup must remain disabled to avoid conflicting uploads.
`repository-standards.yml` runs the organization checks; coverage is uploaded to
Codecov. The required checks, signed commits and review requirements are in
[`.github/rulesets/main.json`](.github/rulesets/main.json). This file does not apply
branch protection automatically; keep the hosted `main` ruleset synchronized with it.

Trusted iOS tests and coverage use self-hosted macOS runners. Fork pull requests
use GitHub-hosted Xcode 27 runners; Swift CodeQL also requires a hosted runner in
the shared workflow. All external contributors' runs require maintainer approval.
Before approving a fork, review workflow changes and the code that will execute:
runner selection in a pull request is not an isolation boundary. Self-hosted
runners must have no production credentials or access to study data. Workflow
tokens default to read-only and cannot approve pull requests.

### Verified Image Candidates

The Dev Stack workflow builds the server and dashboard once on native AMD64 and
ARM64 runners. Each image must pass its vulnerability scan and stack checks;
the dashboard is tested both through instrumented Vite and as the built image.
Docker archives retain the tested image identities, build provenance and SBOMs.
Artifacts bind their bytes and scan evidence to one clean source tree and workflow
attempt. Local dirty-tree packages are useful for testing but cannot be published.

After required verification succeeds on `main`, `publish-images.yml` consumes
these archives without rebuilding. It requires the `candidate-publication`
environment to have required reviewers, prevent self-review and allow only
protected branches. An administrator must configure this environment and branch
protection before publication; missing configuration fails closed. Disable
administrator bypass as part of that setup. The API check verifies configuration,
not the absence of a privileged administrator override.

Candidates go to `ghcr.io/schmiedmayerlab/trove-server` and
`ghcr.io/schmiedmayerlab/trove-web` under source/run/attempt-specific tags. Publication
checks each registry digest and verifies that the combined index preserves both
platforms and their attestations. `Trove-Published-Candidate/candidate.json` records
the resulting digests. Consume those digests, not mutable tags. An expired advisory
database requires a new verification run before publication.

This publishes a candidate, not a deployment: it does not update `main` image tags,
deployment manifests or running services. Target configuration, recovery evidence,
identity/withdrawal reconciliation and deployment approval remain separate release
gates. A failed publication can leave partial candidate uploads, but produces no
successful candidate record and does not deploy them.

## Platform Design and Roadmap

The [design documentation](docs/README.md) describes the target architecture, study model, integrations and delivery sequence. These plans are distinct from currently released functionality. Implementation priorities and status are tracked in the [Trove project](https://github.com/orgs/SchmiedmayerLab/projects/4).

## Contributing

See [repository working instructions](AGENTS.md) for implementation boundaries,
affected-component verification and safe test-resource handling.

Contributions to this project are welcome. Please make sure to read the [contribution guidelines](https://github.com/SchmiedmayerLab/.github/blob/main/CONTRIBUTING.md) and the [contributor covenant code of conduct](https://github.com/SchmiedmayerLab/.github/blob/main/CODE_OF_CONDUCT.md) first. You can find a list of contributors in the [CONTRIBUTORS.md](CONTRIBUTORS.md) file.

## License

This project is licensed under the MIT License. See [LICENSE.md](LICENSE.md) for details, and [CONTRIBUTORS.md](CONTRIBUTORS.md) for the list of contributors.

## Citation

If you use this software, please cite it using the metadata in [CITATION.cff](CITATION.cff), which GitHub surfaces through the [*Cite this repository*](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-citation-files) button.

## Our Research

For more information, visit the [Schmiedmayer Lab GitHub organization](https://github.com/SchmiedmayerLab).

![Schmiedmayer Lab](https://raw.githubusercontent.com/SchmiedmayerLab/.github/main/assets/footer-light.png#gh-light-mode-only)
![Schmiedmayer Lab](https://raw.githubusercontent.com/SchmiedmayerLab/.github/main/assets/footer-dark.png#gh-dark-mode-only)
