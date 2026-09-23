<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Working in Trove

## Implementation Boundaries

- Keep changes focused on the issue's active capabilities and acceptance criteria.
  Prefer existing modules and explicit values over new frameworks or duplicate state stores.
- `TroveAPI/openapi.yaml` owns the HTTP contract. Regenerate Swift and TypeScript
  consumers after changing it; do not hand-edit generated implementations.
- PostgreSQL/Timescale owns consent, event custody and study grants in one authority.
  Store an event once; authorize each study independently. Pass transactions and
  verified audit context explicitly across repository calls.
- Authenticate before protected work. Unknown authority, unavailable validation,
  and failed mandatory audit persistence must not release data or broaden access.
  Never trust client-supplied actor, study access, or deployment identity claims.
- Preserve immutable accepted evidence and exact retry identities. Test forbidden
  side effects and persisted state, not just response codes. Use typed request and
  domain values; bind SQL values rather than constructing SQL from input strings.
- Development schemas target fresh disposable databases. Do not add legacy-data
  migrations or silently recreate a participant's queued data. Unsupported queued
  formats must fail explicitly without deleting work.

## Verification

For M3 Questionnaire work, follow the
[localization contract](docs/Study-Model-and-Research-Workflows.md#localization-sites-and-accessibility):
one multilingual FHIR JSON per instrument version, not locale-specific files.
Keep standalone translated documents separate. Preserve translation extensions
and answer identities, bind administration language to the session, and test
bilingual round-trips with the pinned IG/renderer fixtures. Draft translation is
not approval; required wording must not silently fall back.

Start with focused regressions, then run the affected component's shared CI command
once the implementation is stable. Follow dependency edges: API changes can affect
server, web and iOS; a server-only change does not require the Grove or app matrix.
Use the current workflow selectors and package ownership, not a blanket full run.

Run from the repository root:

```sh
bash scripts/check swift TroveAPI
bash scripts/check swift TroveServer
bash scripts/check web
bash scripts/check tooling
bash scripts/check secrets /private/tmp/trove-secret-evidence
```

Choose only the applicable commands. Swift checks require the CI-pinned Swift 6.4.x
toolchain; Linux also needs Python 3, pkg-config and SQLite development headers.
Tooling checks require Python 3, kubectl, actionlint and ShellCheck. Web setup and
generation are part of its shared command. Missing dependencies are not a reason
to remove a required check. See [workflows](.github/workflows) for pinned inputs.

Secret checks require Gitleaks 8.30.1 and a fresh, empty evidence directory. They
scan tracked and nonignored new files, including uncommitted changes, and verify
synthetic negative controls. Retained reports contain locations, not matched text.
This is a current-file scan, not a scan of Git history or a substitute for dependency
and container vulnerability checks. Never suppress an entire test directory to
make a secret check pass.

Vulnerability checks require Trivy 0.74.0 and a fresh evidence directory separate
from its cache. Use the same commands as CI:

```sh
bash scripts/check vulnerabilities dependencies --output /private/tmp/trove-dependency-evidence --cache /private/tmp/trove-trivy-cache
bash scripts/check vulnerabilities image --image <local-image> --output /private/tmp/trove-image-evidence --cache /private/tmp/trove-trivy-cache
```

Dependency checks cover every input in `scripts/check-vulnerabilities.py`, including
development dependencies and separately named recovery requirements. Image checks
resolve the local image ID and scan that identity without pulling a replacement.
Both require an executed negative control, complete package inventories and no
reported vulnerabilities at any severity. Keep caches out of uploaded evidence.
These inventories do not establish signed provenance or coverage of editable
upstream source changes; verify those separately before release.

Image candidates use `scripts/release-artifact.py` to package and verify the exact
tested Docker archives. Do not rebuild in the publication job or replace missing
platform evidence with another architecture's result. Dirty-source packages are
never publishable. See [candidate publication](README.md#verified-image-candidates)
for the independent approval boundary and remaining deployment gates.

The server defaults to isolated SQLite tests. The real-store lane uses disposable
loopback services selected by `TROVE_TEST_POSTGRES_PORT` and `TROVE_TEST_S3_PORT`;
follow [server test setup](TroveServer/README.md#tests). Never point test helpers at
an existing study database. Full-validator cases require their explicit setup;
report their skips separately instead of calling them passed.

For iOS, use the selected scheme, test and stack setup from
[Build and Test](.github/workflows/build-and-test.yml). Preflight the selected Xcode,
simulator, xcbeautify and coverage tools before building. Preserve exit status with
`set -o pipefail`, retain raw output with `tee`, and format Xcode output with
`xcbeautify`. Keep the `.xcresult` and verify actual test counts. A simulator result
does not establish physical-device background delivery or data-protection behavior.
Simulator verification is the accepted client boundary for the current M1/M2
iteration; physical-device acceptance is deferred and must not be reported as passed.

Lint explicit source files with the owning repository's configuration; do not
traverse build caches or apply Trove's rules to ignored dependency checkouts.
Keep test inputs unchanged during execution. Record commands, source/dependency
identity, executed/skipped counts and evidence locations. Reuse valid evidence for
unchanged components; do not present editable dependencies as a released build.

## Safe Handoff

Preserve unrelated working-tree changes. Local sibling checkouts, caches and
temporary evidence do not belong in a commit. Remove only test resources created
by the current run; do not restart or delete unrelated services to clean up.
Do not expose credentials or clinical content in logs, fixtures or reports.

Local verification does not authorize commits, publication, production access,
deployment or changes to running studies. Report implementation completion
separately from repository enforcement, release approval and operational acceptance.
