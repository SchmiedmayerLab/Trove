<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Engineering and Verification

Implementation scope and acceptance criteria belong in
[GitHub issues](https://github.com/SchmiedmayerLab/Trove/issues). This page records
the engineering requirements shared by those features. Local commands and test
setup are maintained in the [shared check guide](https://github.com/SchmiedmayerLab/Trove/blob/main/scripts/README.md)
and the component READMEs.

## Code and Contract Ownership

Use a modular Swift server with explicit domain operations and adapters for
storage, identity and external providers. Prefer existing Grove components;
extract a shared package when there is a second concrete use, not just similar
type names.

OpenAPI owns the HTTP contract. Regenerate Swift and TypeScript consumers when it
changes. Shared fixtures test that clients interpret the contract consistently.
Typed states, bound SQL parameters and explicit transaction handles keep
authorization and persistence rules visible in the code.

## Schema Changes

Development uses fresh, disposable databases. Update the canonical schema and
coordinated clients rather than adding legacy import or upgrade machinery for
test data. Recreating a database must be an explicit operation on an identified
disposable setup.

A deployment that retains real study data needs a reviewed upgrade and recovery
procedure before its first subsequent schema change. This applies to a research
pilot as well as a production service. Preserve consent, grants, receipts,
artifacts and pending work; an application rollback does not undo a database change.

## Feature Verification

Test the accepted state and forbidden side effects, not only HTTP status codes.
For a changed operation, cover the relevant cases:

- Successful execution, denied access and unavailable required validation or audit.
- Exact retries, altered retries, stale versions and concurrent writes.
- Interruption before and after commit, restart and permission removal.
- Cross-study isolation and retention of queued or previously accepted work.

Use deterministic fixtures and isolated service namespaces. Database and
object-store behavior needs tests against those services, not only in-memory
substitutes. Shared contract fixtures should identify their exact versions.

Run focused regressions while implementing, then the affected component's shared
CI command. Record source and dependency revisions, commands, executed and skipped
counts, and evidence locations. A skipped suite or an empty test selection is not
a passing result. A quarantined test needs an owner, repair issue and expiry.

UI checks include localization, accessibility and appropriate client versions.
Simulator tests cover the current local client workflow; they do not verify
physical-device background collection or data protection.

## Continuous Integration

[Build and Test](https://github.com/SchmiedmayerLab/Trove/blob/main/.github/workflows/build-and-test.yml) is the entry point.
It detects which components a change touches and runs only their jobs, so a
web-only change does not rebuild the iOS app.

| Job | Runs when |
|----------|-------------|
| API | `TroveAPI/**` |
| API (macOS) | `TroveAPI/**`; runs the package tests natively, including the HealthKit and SensorKit acquisition tests that Linux cannot build |
| Server | `TroveServer/**`, `TroveAPI/**` |
| Web | `TroveWeb/**`, `TroveAPI/openapi.yaml` |
| iOS | `TroveiOS/**`, `TroveAPI/**` |
| iOS Real Stack UI | `TroveiOS/**`, `TroveAPI/**`, `TroveServer/**` |
| Infrastructure | `TroveInfrastructure/**` |
| Dev Stack | `TroveServer/**`, `TroveWeb/**`, `TroveInfrastructure/**` |
| Secret Scan | Every run, including documentation-only changes |
| Vulnerability Scan | Every run; also scheduled weekly |

Manual runs and the weekly Sunday 06:17 UTC run select every Trove component,
including the native AMD64/ARM64 stack checks, to detect gaps in path selection.
They do not publish images or deploy services. This is the Trove matrix, not the
full matrix of its upstream Grove repository.

`Required Verification` checks that the selected component jobs ran and succeeded.
It rejects failed, cancelled, missing or unexpectedly skipped required jobs.

### Secret and Dependency Scans

The secret scan uses the same pinned tool and shared command locally and in CI,
tests synthetic negative controls, and retains location-only findings.

The dependency scan requires every declared input to be analyzed and checks a
known-vulnerable control. Web and development-stack jobs also scan their built
application images by local image ID. Findings of any severity fail verification;
reports, input identities and CycloneDX inventories are retained as artifacts.
The [verification commands](https://github.com/SchmiedmayerLab/Trove/blob/main/AGENTS.md#verification) run the same checks locally.

### Static Analysis and Repository Standards

`static-analysis.yml` runs SwiftLint and Swift CodeQL analysis; `codeql.yml` covers
JavaScript and TypeScript. Both scans run on every pull request, including stacked
pull requests. GitHub's default CodeQL setup must remain disabled to avoid
conflicting uploads.

`repository-standards.yml` runs the organization checks and the verification-script
tests; coverage is uploaded to Codecov. Repository standards and security checks
remain separate required checks.

The required checks, signed commits and review requirements are recorded in
[`.github/rulesets/main.json`](https://github.com/SchmiedmayerLab/Trove/blob/main/.github/rulesets/main.json). Neither this file nor
the workflows configure branch protection or independent review; keep the hosted
`main` ruleset synchronized with it.

## Runners and Fork Pull Requests

Trusted iOS tests and coverage use self-hosted macOS runners. Fork pull requests
use GitHub-hosted Xcode 27 runners. All external contributors' runs require
maintainer approval.

Untrusted pull requests must not receive signing or production credentials,
privileged caches, or access to study data. Before approving a fork, review the
workflow changes and the code that will execute: runner selection in a pull
request is not an isolation boundary. Self-hosted runners must have no production
credentials or access to study data. Workflow tokens default to read-only and
cannot approve pull requests.

## Verified Image Candidates

Build release candidates once, then test and publish those exact artifacts.
Retain source and dependency identities, toolchains, schema/configuration versions,
provenance and inventories.

The Dev Stack workflow builds the server and dashboard once on native AMD64 and
ARM64 runners. Each image must pass its vulnerability scan and stack checks;
the dashboard is tested both through instrumented Vite and as the built image.
Docker archives retain the tested image identities, build provenance and SBOMs.
`scripts/release-artifact.py` binds their bytes and scan evidence to one clean
source tree and workflow attempt. Local dirty-tree packages are useful for testing
but cannot be published.

Candidate publication is disabled by default. After configuring the approval
boundary below, an administrator can set the repository variable
`TROVE_CANDIDATE_PUBLICATION_ENABLED=true` to enable it. Unset or false leaves
verification and documentation deployment enabled without publishing images.

After required verification succeeds on `main`, enabled publication consumes
these archives without rebuilding. It requires the `candidate-publication`
environment to have required reviewers, prevent self-review and allow only
protected branches. An administrator must configure this environment and branch
protection before publication; missing configuration fails closed. The `main`
ruleset allows organization and repository administrators to bypass it; remove that
bypass as part of that setup. The API check verifies configuration, not the absence
of a privileged administrator override.

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

## Local Development and Deployment

Use disposable Docker services for integration and a local Kubernetes setup for
orchestration checks. Exercise the real identity provider, database, object store
and validator. Test interrupted writes, repeated delivery, withdrawal and recovery
before selecting a hosting provider.

The application connects through PostgreSQL, S3-compatible storage and OIDC.
Cloud SDKs and Kubernetes APIs stay in deployment adapters. A Kubernetes base can
share application manifests while target configuration supplies workload identity,
secrets, ingress, storage and backups. Each target still needs verification:
S3 compatibility does not imply native GCS support, and managed PostgreSQL must
provide the required extensions and privileges.

Before a field deployment, verify the selected target's access controls,
encryption, network policy, volume durability, certificate renewal and recovery
with synthetic data. Restoration must reconcile identity, erasures and revoked
permissions before serving records or resuming external work.

A participant-facing deployment requires research and operational owners,
approved content, a supported device matrix and defined acceptance measures.
Enabled inference services additionally require approved processing routes,
access controls and usage limits.

## Assisted Workflows

Researcher tools use the same authorized API as manual operations. Record the
initiating researcher and executing client, preserve source citations, and apply
proposals through revision-checked updates. Documents and model output cannot
grant permissions.

Keep deterministic contract tests separate from model evaluations. Evaluate
source fidelity, unresolved ambiguity, correction effort and cost using a bounded
synthetic corpus. Require separate authorization for publication, participant
contact, allocation, exports and credential changes.
