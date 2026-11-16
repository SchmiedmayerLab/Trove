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

[Build and Test](https://github.com/SchmiedmayerLab/Trove/blob/main/.github/workflows/build-and-test.yml) runs the jobs of the
components a change touches. Manual runs and the weekly scheduled run select every
component. `Required Verification` passes only when every selected job succeeded.
The secret scan and the dependency vulnerability scan run on every change, and the
[verification commands](https://github.com/SchmiedmayerLab/Trove/blob/main/AGENTS.md#verification) run the same checks locally.
[Static Analysis](https://github.com/SchmiedmayerLab/Trove/blob/main/.github/workflows/static-analysis.yml) runs SwiftLint and Swift
CodeQL, and [CodeQL](https://github.com/SchmiedmayerLab/Trove/blob/main/.github/workflows/codeql.yml) analyzes JavaScript and
TypeScript. The workflows and
[`.github/rulesets/main.json`](https://github.com/SchmiedmayerLab/Trove/blob/main/.github/rulesets/main.json) define the exact jobs,
triggers and required checks.

## Image Candidates

The [Dev Stack](https://github.com/SchmiedmayerLab/Trove/blob/main/.github/workflows/dev-stack.yml) workflow builds the server and
dashboard images once on AMD64 and ARM64 runners, scans and tests them, and keeps
the tested archives with their provenance and SBOMs. When candidate publication is
enabled, [Publish Verified Images](https://github.com/SchmiedmayerLab/Trove/blob/main/.github/workflows/publish-images.yml) publishes these
exact archives to `ghcr.io/schmiedmayerlab/trove-server` and
`ghcr.io/schmiedmayerlab/trove-web` after required verification on `main`;
`Trove-Published-Candidate/candidate.json` records their digests. Publishing a
candidate does not deploy it.

## Local Development and Deployment

Use disposable Docker services for integration and a local Kubernetes setup for
orchestration checks. Exercise the real identity provider, database, object store
and validator. Test interrupted writes, repeated delivery, withdrawal and recovery
against these services.

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
