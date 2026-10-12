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

## CI and Release Artifacts

The aggregate verification job checks that selected component jobs ran and
succeeded. Repository standards and security checks remain separate required
checks. Workflow files do not themselves configure branch protection or
independent review.

Untrusted pull requests must not receive signing or production credentials,
privileged caches, or access to study data. Review the code and workflow changes
before approving execution on a self-hosted runner.

Build release candidates once, then test and publish those exact artifacts.
Retain source and dependency identities, toolchains, schema/configuration versions,
provenance and inventories. The [candidate publication procedure](https://github.com/SchmiedmayerLab/Trove#verified-image-candidates)
defines independent approval and per-architecture evidence. Publication does not
deploy a service.

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
