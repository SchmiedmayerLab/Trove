<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Local Verification

Run from the repository root. These commands are also used by the package and web workflows:

```sh
bash scripts/check swift TroveAPI
bash scripts/check swift TroveServer
bash scripts/check web
bash scripts/check tooling
bash scripts/check validator-pin
```

Swift checks require Swift 6.3.x and its matching `llvm-cov` (via `xcrun` on macOS). Linux CI uses the digest-pinned Swift 6.3.0 image in `.github/workflows/swift-package.yml`; a macOS result does not replace Linux evidence. Web checks require Node.js 24 and npm. Tooling checks require actionlint, ShellCheck, Python 3, awk and kubectl. Install `TroveInfrastructure/tools/requirements.txt` in the Python environment for the rendered deployment checks; CI installs the same pinned dependency. Missing tools or mismatched compiler/runtime versions fail before builds start.

Swift checks also reject compiler-plugin `Internal Error` and `LLVM Profile Error` diagnostics when SwiftPM exits zero. Raw build/test logs remain in `.build/verification`; ordinary warnings remain visible. Fix the dependency/toolchain problem rather than filtering its output or disabling coverage.

`validator-pin` is a separate online check requiring Python 3 and authenticated
GitHub CLI access. It compares `TroveInfrastructure/validator/manifest.json` with
the official validator release asset metadata, including its checksum. Missing,
ambiguous or changed assets fail; the command never rewrites a pin or executes the
download. Repository Standards runs the same command with its read-only token.
Investigate a replaced release asset before selecting a reviewed replacement;
cached old bytes and successful past runs do not prove a fresh download is safe.

The Swift lane builds source and test targets with coverage instrumentation, then runs tests with `--skip-build`. Only build-time host-tool profiles use `/dev/null`: compiler macros cannot write profiles inside their read-only sandbox, and those invocations are not application test coverage. Test execution clears that override and lets SwiftPM record the actual test profiles used for LCOV. Compiler sandboxing remains enabled.

API and server dependency graphs are recorded in their `Package.resolved` files. Verification and the server container build use `--force-resolved-versions` so a stale or missing lockfile fails instead of silently selecting newer dependencies. The separate iOS graph is recorded at `TroveiOS/Trove.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`; the API/server lockfiles do not cover that consumer. The real-stack UI job uses `-onlyUsePackageVersionsFromResolvedFile` when resolving and testing. Use the same flag for local Xcode verification. Update dependencies intentionally, include changed lockfiles in review, and rerun verification. Verify the locked package graph on Linux as well as macOS before merging dependency updates.

The reusable iOS unit-test workflow at `SchmiedmayerLab/.github` version `v0.5` does not expose strict package resolution and tolerates errors in its separate resolution step. Enforcing the lock there requires a shared-workflow update; the strict real-stack UI job does not establish that the reusable unit job used an identical graph.

Swift build/test logs and raw and line-only LCOV reports remain under each package's `.build/verification/`. An optional third argument copies the report to the CI artifact filename. Shell pipelines preserve failures. LCOV conversion preserves measured covered and uncovered source lines; it never estimates line coverage from function invocation counts.

Native coverage uses the result archive's per-line execution records, not its function-summary report:

```sh
python3 -B scripts/native-line-coverage.py --repository "$PWD" --output native.lcov path/to/Unit.xcresult path/to/UI.xcresult
```

Supply only successful result bundles from the same source revision. The exporter includes existing Swift app sources under `TroveiOS/Trove`, preserves executable lines with zero hits, and combines actual counts across bundles. Missing or malformed evidence fails instead of retaining an older report. CI downloads each successful native artifact explicitly and sends the resulting LCOV to the shared collector; it does not use the collector's function-count-based native converter. Raw result bundles remain available for investigation. This is app line coverage, not branch coverage or a claim about uncompiled files.

The build and test phases both enable coverage so SwiftPM can reuse their objects instead of rebuilding the same dependencies with different instrumentation flags. Both use four compiler jobs, independent of the host's CPU count, to bound memory use consistently in local containers and hosted runners. The release image uses the same four-job limit. This does not change test selection. Keep verification scripts and source fixed for the duration of a run; use separate source snapshots and build directories for concurrent revisions.

## Isolated PostgreSQL Tests

The default server suite uses SQLite. To exercise the same tests on a disposable local Timescale/PostgreSQL instance, expose its port on loopback and configure the synthetic `trove_test` user with password `trove_test` and permission to create databases and the Timescale extension. Do not use an existing study database or production credentials.

```sh
TROVE_TEST_POSTGRES_PORT=15432 bash scripts/check swift TroveServer
```

Each test application creates one uniquely named authority database containing study, consent, audit, source and clinical records, then drops only that exact database afterward. No production database environment variables are used. Missing connectivity or a missing Timescale extension fails the test; there is no SQLite fallback when the port is supplied. Schema changes target fresh development databases, not in-place data migrations.

The `PostgreSQL and Timescale Tests` job uses the pinned Swift image and a digest-pinned PG17/Timescale image on a fresh GitHub-hosted Linux runner. The development stack uses PG18; both supported versions need their own runtime evidence. Ports are published only on loopback. The job verifies per-test database cleanup and removes only its own containers and anonymous volumes. Test setup uses a synthetic database-creating administrator; the runtime-permission suite additionally opens real restricted logins and tests prohibited operations. Actual deployment provisioning remains a separate check. A workflow file does not prove that its job ran or that branch protection requires it.

This is the first shared-command increment, not a complete release gate. Existing infrastructure and real-stack workflows still own service setup/teardown. The default SQLite suite is not PostgreSQL/Timescale schema or transaction evidence. The full-validator HTTP test additionally requires the [pinned validator setup](../TroveInfrastructure/validator/); a PG/S3-only run explicitly skips it. iOS checks use their existing workflow and native stack scripts; preserve `set -o pipefail`, raw logs and `xcbeautify` when invoking Xcode locally. Codecov upload, live branch protection, hosted security scanners and image publication are separate from local execution and must not be reported as locally verified.

For the native UI stack, `TROVE_UI_TEST_SERVER_BINARY` may point to an absolute executable path built from the source under review. Copy that binary into the disposable run directory before starting other builds. This avoids SwiftPM lock contention and coverage/non-coverage rebuilds while the server is running; without this option, the startup script still uses `swift run --force-resolved-versions`. Do not use an older or unrelated binary as evidence for the current source. The browser's test issuer must match Keycloak's canonical `http://localhost:8180/realms/trove` origin, even when the server's internal transport uses `127.0.0.1`.

Native setup requires `lsof` and refuses to start if ports 8080, 8180, or 9000 are occupied or cannot be inspected. Trove, Keycloak HTTP, and Keycloak management bind only to `127.0.0.1`; the synthetic test credentials are not exposed on network interfaces. Setup never stops an existing service to free those ports. The real-stack UI job also runs for server and imported Keycloak realm changes, independently of the iOS-only build filter.

Real-stack simulator tests use ad-hoc signing: `CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="-"`. No distribution certificate is needed. Do not use `CODE_SIGNING_ALLOWED=NO` for this flow: an unsigned installation can lack the application-identifier entitlement required by the keychain and fail before sign-in opens. Journal tests on Simulator verify private storage and backup exclusion, not physical-device Data Protection.

## Artifact Recovery Verification

The artifact storage lane additionally requires a disposable S3-compatible service on loopback. It uses synthetic credentials and a fresh test bucket, never deployment storage configuration:

```sh
TROVE_TEST_POSTGRES_PORT=15432 TROVE_TEST_S3_PORT=18333 bash scripts/check swift TroveServer
```

Without `TROVE_TEST_S3_PORT`, the explicitly optional real-storage test is skipped; database and in-memory recovery tests still run. Remove the disposable service and its test buckets after verification. A passing in-memory suite does not establish S3 compatibility.

The server's `cleanup-artifacts --limit 100` operator command processes at most 100 expired, unaccepted consent/publication artifacts. It requires the normal database and S3 configuration but does not contact Keycloak or start HTTP routes. It does not create a bucket. Schedule it only with a dedicated operator identity and verified storage configuration; the HTTP-serving identity should not receive deletion permission.

Cleanup commits its fence and audit intent before deleting. Accepted artifacts and referenced domain records are protected. Recovery rows remain retryable hourly because an interrupted upload can finish after a delete request succeeds. Reported delete counts are completed requests, not certification of permanent erasure. Do not remove tombstones or apply a blanket expiration policy to the artifact prefix.

This implementation supports cleanup only on an unversioned bucket. The operator needs bucket-versioning read permission as well as object deletion permission. Enabled or suspended versioning, denied access, and storage errors leave the record retryable and make the command fail. Do not change bucket versioning during cleanup. Version-aware erasure and recovery-record retention policy require separate implementation; [S3 deletion semantics](https://docs.aws.amazon.com/AmazonS3/latest/API/API_DeleteObject.html) explain why a delete marker is insufficient.

## Browser and Infrastructure Verification

After installing the locked npm dependencies, run `npx playwright install` from `TroveWeb` to install the matching browser binaries (`--with-deps` on Linux CI). Browser verification runs all three projects with one worker when `CI=true`, following [Playwright's CI guidance](https://playwright.dev/docs/ci#workers). This avoids choosing concurrency from the host's CPU count when the test container and backing services have smaller resource limits. Retries retain diagnostics, but a test that passes only on retry still fails the CI run. The complete authoring scenario has an explicit 90-second overall budget; its five-second assertions and test steps remain unchanged. Run `CI=true npm run test:e2e:coverage` against the disposable stack for the same behavior locally.

Database health checks use the loopback TCP listener so the temporary initialization server's Unix socket cannot release dependent services early. Timescale's development manifest additionally gives initialization a separate five-minute startup budget before readiness and liveness begin. These checks establish server availability, not authenticated access or completed schema setup; keep the actual SQL and migration assertions in stack verification.

The KIND workflow passes the full checkout commit to `TroveInfrastructure/tools/setup.py --revision`. Setup rejects a different or dirty checkout before changing the cluster, then uses the same revision for the root and child ArgoCD sources. Those sources must be available in the remote repository. An uncommitted local change can be checked with manifest validation and the disposable Compose stack, but neither is an exact-revision GitOps deployment test. Interactive `--branch` mode remains available for development; it tracks a moving branch and is not equivalent evidence.
