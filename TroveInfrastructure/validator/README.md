<!--
SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
SPDX-License-Identifier: MIT
-->

# Offline FHIR Validation

This worker validates one exchange Bundle against the pinned Grove FHIR 0.6.0 contract. It runs the IG's own profile, graph and identity checks, then the official FHIR Validator against the complete local package closure. Trove separately authorizes the participant, source, supported output shape, consent and study attribution. A valid FHIR graph is not permission to store or disclose it.

`manifest.json` records the exact companion source revision, worker implementation, runtime images, Java validator and package archive checksums. The worker verifies its own implementation hash before startup. The guide archives are the checksum-verified assets of the published Grove FHIR 0.6.0 release identified by `guideRelease`; rebuilding an archive with different bytes requires an explicit manifest review, not an automatic checksum update.

The runtime companion contract remains at `444e06fb25680c3af29e5d3ccbebeb0249be7318`.
The published packages were built from release revision
`83668d2d33325d2c1c9d42638fdc7557314f3d88`, not that earlier commit. All ten guide
directories, catalogs, producer validators, Questionnaire companion and build-tool
locks are identical at both revisions. The only source differences add an offline
CI job and recognize one narrowly scoped BCP 47 Publisher QA warning in
`Scripts/check-guide-qa.py`. These are compatible published package assets, not a
new exchange contract. Their `ci-build`/`notForPublication` metadata remains an
upstream preview designation; use here does not establish deployment approval or
online terminology validation.

Run `bash scripts/check validator-pin` to compare the locked Java tool with its
official GitHub release asset. This online check is separate from offline context
preparation and is also required by Repository Standards. A missing or changed
digest fails rather than trusting the tag or a cache hit. Updating the tool does
not itself change the IG exchange contract: review the manifest identity and
repeat the valid/invalid, lifecycle and receiver checks before accepting new bytes.

## Build

Prepare from a local Grove FHIR checkout containing the pinned commit, `.build/fhir-tools/`, and each guide's `output/package.tgz`. Preparation checks all archives and extracts the pinned source with `git archive`, ignoring working-tree modifications. It makes no network requests and requires a new output directory.

```sh
python3 TroveInfrastructure/validator/prepare.py \
  --grove-fhir /absolute/path/to/grove-fhir \
  --output /private/tmp/trove-validator-build
docker build --network=none --tag trove-fhir-validator:local /private/tmp/trove-validator-build
python3 -m unittest discover -s TroveInfrastructure/validator -p test_worker.py
```

The two base images are digest-pinned; Docker may fetch those bases when they are not cached. No build step resolves FHIR packages online. Keep the prepared context outside the repository; it contains approximately 1.4 GB of tooling and package data.

If the checkout's build outputs have changed, pass
`--artifacts /absolute/path/to/locked-artifacts` to preparation. That directory
contains `validator_cli.jar` and `packages/` with the filenames in the manifest;
an earlier prepared `assets/` directory uses this layout. Every artifact is
verified against the current repository manifest, not an input manifest or cache
metadata. Source still comes from the pinned Git revision. This does not replace
the checkout's cache or change package pins. Download an updated tool separately
and check `validator-pin` before preparing it. Never repin to make changed bytes
pass.

To reconstruct the locked inventory, download the named release assets
`<packageId>-0.6.0.tgz` from the repository and release ID in `guideRelease`.
Verify their SHA-256 against both the GitHub asset digest and each manifest entry,
then place them under `packages/<file>` in the artifact directory. Keep the
checksum-pinned validator JAR and bootstrap packages beside them. Preparation
rechecks every byte; a matching version label alone is insufficient. Retain this
inventory durably with its manifest, outside the source repository and temporary
CI artifact retention. Do not rely on regenerating byte-identical archives.

## Deployment Boundary

Use `compose.yaml` as an overlay for `../docker/docker-compose.yml`. Set `FHIR_VALIDATOR_IMAGE` to the built image's immutable digest and `FHIR_VALIDATOR_IDENTITY` to `sha256:` followed by the manifest's SHA-256. The server must compare the expected identity, contract revision and digest of the exact submitted bytes; it must never learn its expected identity from a response.

Only the server joins both the normal application network and the internal validation network. The worker has no published port, external network, database credentials, storage credentials or Docker socket. Keep those restrictions when deploying outside Compose. The image runs as an unprivileged user with a read-only filesystem, dropped capabilities, bounded CPU, memory, processes and temporary storage. A writable private copy of the verified package cache prevents cache changes from surviving a container restart.

The worker processes one request at a time, with a two-connection backlog and one reusable official validator engine. It loads the pinned packages before accepting requests. The engine listens only on loopback inside the container; the worker forwards only raw FHIR bytes to its fixed validation route, without query parameters. Engine administration, package loading and transformation routes are not exposed. No validation results are cached: every event, including a retry, passes both validation layers.

A timeout, dead process or malformed engine response is never an admission result. An interrupted validation returns unavailable and discards its engine; a later request can start a replacement within the same deadline. The worker does not add a process pool, durable queue or general execution API. Measure throughput before increasing concurrency.

## Questionnaire Authoring

`POST /validate/questionnaire` validates one Questionnaire against the same pinned
package closure. It requires the Grove Questionnaire profile claim, runs the IG's
`validate_questionnaire` companion rules, then the official validator. It accepts
no caller-selected packages, profiles, terminology servers or executable code.
Its response adds `"purpose": "questionnaire"`; consumers must verify this field
as well as the exact input digest, contract revision and configured identity.
The existing `/validate` route remains restricted to exchange/retraction Bundles.

Both routes use the same bounds and unavailable semantics below. For offline
synthetic checks, use `--stdin --questionnaire`. IG validity does not establish
that a study client can execute every retained feature: the server must separately
check its supported execution capabilities before publication. Exact original
Questionnaire bytes, not a rewritten or simplified resource, are validated.
Run `smoke.py` with `--questionnaire` and a synthetic IG-conformant Questionnaire
fixture to exercise this route, including official rejection, timeout recovery,
CLI framing and private-network HTTP. Run the existing exchange smoke separately;
a Questionnaire result does not replace exchange-admission evidence.

## Request and Result

`POST /validate` accepts `application/fhir+json` with one exact `Content-Length`, at most 4 MiB. Chunked or ambiguous framing is rejected. UTF-8, JSON member uniqueness, nesting depth (64), Unicode and finite numeric representations are checked before any FHIR decoding. Header/body reading has a ten-second deadline. The official validator has a 120-second deadline, bounded heap and output, `-tx n/a`, and `-no-http-access`. No request content, FHIR diagnostics or process output is logged or returned.

The response is smaller than 2 KiB:

```json
{
  "valid": true,
  "sha256": "<digest of the exact request bytes>",
  "contractRevision": "444e06fb25680c3af29e5d3ccbebeb0249be7318",
  "validatorIdentity": "sha256:<manifest digest>"
}
```

HTTP 200 means both validation layers passed and the official outcome belongs to this input. HTTP 422 returns `valid: false` and a coarse `invalid_json` or `invalid_fhir` code. Missing, malformed, oversized or unsuccessful engine results return HTTP 503 (`validator_unavailable`). Framing errors return 400, 413 or 415. A connection failure, timeout, unexpected response or mismatched digest is never an admission result. `GET /health` reports whether the initialized engine process is alive; it does not replace a real valid/invalid fixture smoke test.

`--stdin` runs the identical operation without HTTP, suitable for a `docker run --network none` verification. Exit codes are 0 for valid, 1 for invalid and 2 for unavailable. Run only synthetic fixtures in diagnostic tooling. `rekey_fixture.py` is a test-only producer: it calls the pinned IG identity helpers to bind a synthetic fixture to a real test source registration. It does not attest validation or bypass the worker.

Run the actual image smoke check with a fully valid synthetic fixture and the reviewed manifest identity:

```sh
python3 TroveInfrastructure/validator/smoke.py \
  --image trove-fhir-validator:local \
  --fixture /absolute/path/to/synthetic-event.json \
  --expected-identity sha256:<manifest-digest>
```

The smoke check tests the CLI with networking disabled, then HTTP through a temporary internal network without publishing a port. It checks valid input, duplicate JSON members, an Observation missing its required status (an official FHIR validation failure), and valid input again on the same engine. It also rejects attempts to access engine administration routes. A separate offline check suspends a real engine to force a validation timeout, verifies an unavailable response, then verifies recovery after timeout and process termination. It removes only its own containers and network, including after failures. The package cache and built image remain available for subsequent verification.

## Backend Process Restart Check

On macOS, run the complete one-event/two-studies checkpoint with a compiled native server, Python 3.12 or later, JDK 21, Docker, and the prepared context above. The Keycloak 26.6.1 archive must match the checksum checked by the script. Cache the script's digest-pinned PostgreSQL/Timescale and SeaweedFS images first; this harness does not build or update dependencies.

```sh
python3 TroveInfrastructure/validator/verify_process_restart.py \
  --binary /absolute/path/to/TroveServer/.build/debug/TroveServer \
  --assets /private/tmp/trove-validator-build/assets \
  --image trove-fhir-validator:local \
  --keycloak-archive /absolute/path/to/keycloak-26.6.1.tar.gz \
  --java-home /absolute/path/to/jdk-21/Contents/Home
```

The harness owns fresh PostgreSQL and S3 containers, a restricted runtime database role, Keycloak, an offline worker, a fixed-destination loopback relay, and two successive backend processes. It uses ports 58032, 58033, 58080, 58081, 58180 and 59000 by default and refuses occupied ports. It never uses an existing application database or a test authentication bypass.

Through authenticated REST, it publishes two studies, accepts exact-presentation consent, registers a source and admits one fully validated synthetic event to both studies. It checks exact retries, rejects changed bytes and targets, withdraws from only one study, terminates the backend, then starts a different process against the retained stores. The final checks cover unchanged event and receipt bytes, the complete node index, one point, two grants, the three admission/grant audit records, independent effective study access, and both retained consent PDFs.

The printed evidence directory contains logs and `summary.json` with binary/image identities, backend process IDs, elapsed time, and sampled backend RSS and worker memory. These samples are not an exact peak or a throughput benchmark. The run has a 30-minute deadline and removes only its owned processes, containers, temporary volumes and network, including on failure. Synthetic evidence, the copied binary and Keycloak directory remain locally; no credentials or clinical payloads are published.

## HealthKit Acquisition Check

`verify_healthkit_acquisition.py` uses the same disposable backend stack, but
collects a synthetic 73 bpm sample through Health on a newly created iOS simulator.
It requires Xcode, an installed iOS runtime, and `xcbeautify` in addition to the
backend-check prerequisites. Run from the repository root:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
python3 TroveInfrastructure/validator/verify_healthkit_acquisition.py \
  --binary /absolute/path/to/TroveServer/.build/debug/TroveServer \
  --assets /private/tmp/trove-validator-build/assets \
  --image trove-fhir-validator:local \
  --keycloak-archive /absolute/path/to/keycloak-26.6.1.tar.gz \
  --java-home /absolute/path/to/jdk-21/Contents/Home \
  --runtime com.apple.CoreSimulator.SimRuntime.iOS-26-5
```

Select an installed runtime explicitly. Optional `--workspace` and `--derived-data`
arguments support a local development workspace and a reusable build cache; a
local dependency override is not evidence that published dependencies integrate.
The UI fixture requires free ports 8080 and 8180; the other stack ports retain
the backend-check defaults. It refuses occupied ports and never reuses a personal
simulator. Both studies and their consents are created through authenticated REST
before the UI flow starts.

Only the acquisition UI test runs. It signs in, registers the device, grants
Health access, creates the sample and syncs before and after app relaunch. The
host then checks one retained event and point, two grants and the corresponding
audit records. A separate backend restart must preserve the exact event bytes;
withdrawal from one study must leave the other study's authorization intact.
A displayed successful sync is insufficient: zero samples, duplicate custody,
skipped tests and incomplete cleanup all fail the verifier.

The evidence directory retains raw Xcode output, formatted output, the `.xcresult`
bundle with screenshots, and `summary.json`. Only the owned simulator and stack
resources are removed, including on failure. This checks foreground acquisition
on a simulator, not background delivery or physical-device behavior. The fixture
can wait until the next minute because Health's manual entry has minute precision
and the sample must be collected after consent.

## Signing-Key Rotation Check

`verify_key_rotation.py` takes the same arguments as the backend-restart check.
It creates its own Keycloak realm and uses the normal server binary and key-cache
settings. It never changes an existing realm or exports private signing keys.

The verifier creates higher-priority RS256 providers, checks new tokens without
restarting Trove, then removes the exact old provider and confirms that a
successful JWKS refresh replaces rather than merges trust. A retained published
key must still work. Finally, it stops only its owned Keycloak process: cached
trust must work while valid, then return HTTP 503 within the normal five-minute
cache lifetime. Fixture tokens outlive that interval to distinguish key-cache
expiry from token expiry. This takes several minutes; no test clock or shorter
production timeout is substituted. Unexpected statuses fail immediately; only
the expected cooldown or unexpired-cache response may be polled.

An unannounced new key can receive HTTP 401 during the 30-second refresh cooldown;
this verifier measures that interval rather than claiming zero-downtime rollover.
Publish a replacement as enabled but passive before activating it when scheduling
a rollover, and allow the five-minute cache lifetime for consumers to see it.

This tests bounded trust refresh, not immediate per-user/session revocation,
emergency key invalidation across a deployment or identity-provider recovery.
For key compromise, a process with a still-valid cached key can accept signatures
until refresh or cache expiry; remove trust at the identity provider and recycle
serving instances if immediate invalidation is required. Do not describe token
logout or removal from JWKS as an instantaneous push to every backend.

See the [Keycloak rotation guide](https://www.keycloak.org/docs/latest/server_admin/#rotating-keys)
and [component administration API](https://www.keycloak.org/docs-api/latest/rest-api/index.html#_components_resource).

## Backup and Restore Check

`verify_backup_restore.py` extends the same authenticated checkpoint. It stops the
backend after withdrawal from one study, captures a logical database backup and
all objects in the owned bucket, then stops both original stores. Replacement
containers start with empty storage. The harness verifies every public-table row
digest, object key/body/content type/metadata and canonical runtime permissions
before it starts the replacement backend. The original receipt, withdrawal,
source-revocation and consent-PDF checks then run against the restored stores.
Before granting the replacement runtime login, it also compares the restored
rows with an independent current-state checkpoint captured after the original
writers stopped. The original runtime login is disabled and any remaining runtime
session prevents capture; untracked sessions are not forcibly terminated.
A matching backup checksum alone does not authorize activation.
Object restoration also runs with the runtime role absent. The complete restored
inventory, bytes, content types and metadata must pass before that role is
provisioned; an object-store failure cannot leave an early application login.

A separate source is revoked before the snapshot is taken. After restore, owner
lookup, registration retry and repeated revocation must return the same source
and revocation timestamp. Event admission must fail at the revocation check, and
exactly one revocation audit must remain. The original active source is still
used for receipt retries and a new post-restore revocation, so these are distinct
checks. This proves retention of a restriction already present in the backup,
not reconciliation of a restriction created afterward.

The same fixture includes four interrupted artifact records: a PUT that never
completed, an uploaded but unverified object, a verified but unaccepted object,
and a deletion followed by a late PUT. After exact restoration, the restricted
runtime's `cleanup-artifacts` command must delete only abandoned objects, retain
their recovery locators and commit each cleanup audit. A second sweep removes a
simulated late PUT; only the synthetic records' retry deadlines are advanced.
Both publications and both accepted consent PDFs must remain byte-for-byte intact
through both sweeps. No application serving resumes until these checks pass.

Install the optional SDK in a dedicated virtual environment; the worker image and
ordinary tooling tests do not depend on it:

```sh
python3 -m venv /private/tmp/trove-recovery-tools
/private/tmp/trove-recovery-tools/bin/python -m pip install \
  -r TroveInfrastructure/validator/recovery-requirements.txt
/private/tmp/trove-recovery-tools/bin/python TroveInfrastructure/validator/verify_backup_restore.py \
  --binary /absolute/path/to/TroveServer/.build/debug/TroveServer \
  --assets /private/tmp/trove-validator-build/assets \
  --image trove-fhir-validator:local \
  --keycloak-archive /absolute/path/to/keycloak-26.6.1.tar.gz \
  --java-home /absolute/path/to/jdk-21/Contents/Home
```

Repeat the command with `--post-backup-restrictions` to exercise stale-backup
refusal. After the backup, the owned original backend commits another enrollment
withdrawal and source revocation through authenticated APIs, then stops. The
restored older rows must fail the current-state gate before runtime credentials,
artifact cleanup or serving are enabled. This is a passing negative verification,
not a successful restore or a permission-reconciliation algorithm. Unknown or
malformed current-state evidence is rejected as well.

The dump uses matching PostgreSQL/Timescale versions and the documented
[`timescaledb_pre_restore` / `timescaledb_post_restore` sequence](https://github.com/timescale/docs/blob/latest/self-hosted/backup-and-restore/logical-backup.md).
Restore is serial and stops at its first error. Owner/ACL restoration is disabled;
the existing reviewed operator script reapplies runtime permissions. Missing,
oversized or checksum-mismatched backups do not resume serving. The fixture is
bounded to a 64 MiB dump and sixteen objects of at most 4 MiB each. Backups remain
in the private local evidence directory; cleanup removes only the owned services.

This proves **quiescent synthetic recovery**, not a production backup strategy.
The ordinary mode has no post-backup application writes; the negative mode must
refuse its deliberately stale snapshot. The same Keycloak service remains
running. Neither mode proves stale-backup revocation/erasure reconciliation, identity
provider recovery, external-side-effect handling, point-in-time recovery, encrypted
backup retention or production RPO/RTO. A real restore must remain isolated from
participants and outbound workers until restrictions newer than the snapshot are
reconciled. If their authoritative history is unavailable, do not resume serving.
An old database alone cannot establish that its permissions are still valid.
