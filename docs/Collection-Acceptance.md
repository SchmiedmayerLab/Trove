<!--
This source file is part of the Trove open-source project

SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)

SPDX-License-Identifier: MIT
-->

# Collection Acceptance

[Issue #137](https://github.com/SchmiedmayerLab/Trove/issues/137) owns acceptance
of record-based collection: heart rate, sleep, workouts, configurable routes,
source fidelity, historical/offline collection, stable participant identity,
bounded delivery and study-scoped access. Record automated engineering results
and physical-device results separately. A passing synthetic or simulator test
does not establish HealthKit acquisition, background execution or device data
protection. Physical-device acceptance has not been established by this guide.

Use the [shared checks](../scripts/README.md), [API collection guide](../TroveAPI/README.md),
[server verification setup](../TroveServer/README.md#required-full-validator-ci-lane)
and [validator setup](../TroveInfrastructure/validator/README.md). The
[engineering requirements](Engineering-and-Verification.md) govern evidence and
schema changes. Use isolated test accounts, studies and disposable infrastructure;
retain existing queues and custody when a test encounters an unsupported schema.

## Automated engineering acceptance

Run from the repository root with the pinned Swift toolchain. Use the latest
stable Xcode and iOS runtime for Apple verification and record their exact builds.
Before running, capture the source commit plus any local diff, resolved dependency
revisions and checksums, OpenAPI checksum, validator manifest checksum and image
identity. Freeze the source files and dependency inputs consumed by each run.

```sh
bash scripts/check swift TroveAPI
bash scripts/check swift TroveServer
bash scripts/check web
bash scripts/check tooling
```

The ordinary server lane uses synthetic validation for many boundaries. Repeat
the server check with the isolated PostgreSQL, S3 and pinned full-validator
configuration documented in the server guide and `TROVE_REQUIRE_FULL_VALIDATOR=1`.
The validator image and assets must match the checked-in manifest, including its
16 MiB event input ceiling. Do not reuse an older running worker as evidence for
larger configured records. Record actual executed and skipped tests and dynamic
parameter cases separately; a skipped required case remains outstanding.

For focused investigation before the shared checks:

```sh
swift test --package-path TroveServer --no-parallel \
  --filter 'HistoricalMixedCollectionTests|ClinicalCapacityTests|WorkoutRouteStudyDataTests|WorkoutStudyDataTests|SleepCollectionTests|StudyRecordingDownloadTests'
```

Run Apple-only acquisition tests and the native app tests on an available iOS
simulator. Select its identifier from `xcrun simctl list devices available` and
set `TROVE_SIMULATOR_UDID` before running; use a fresh result-bundle path for each run.

```sh
xcodebuild -version
xcrun simctl list runtimes
mkdir -p .build/collection-acceptance
set -o pipefail
xcodebuild test -project TroveiOS/Trove.xcodeproj -scheme Trove-UnitTests \
  -destination "platform=iOS Simulator,id=$TROVE_SIMULATOR_UDID" \
  -resultBundlePath .build/collection-acceptance/TroveTests.xcresult \
  2>&1 | tee .build/collection-acceptance/TroveTests.log | xcbeautify
```

The following suites provide complementary evidence; no single row establishes
the entire participant journey.

| Boundary | Automated evidence and expected result |
| --- | --- |
| Accepted history and whole sessions | `CollectionMeasurementWindowTests`, `HistoricalCollectionScopeTests`, `HistoricalMixedCollectionTests`: six calendar months resolve once in the declared calendar/time zone; an overlapping sleep/workout session remains complete. The mixed Bundle stores shared heart rate once and grants only the authorized profiles to each study, including after database reopen. |
| Offline lifetime and query progress | `HeartRateOfflineTests`, `EnrollmentEndCollectionTests`, `HeartRateQuerySchedulingTests`, `ParticipantCollectionRefreshTests`: retained plans survive restart without a per-page network dependency; enrollment end and known withdrawal stop affected collection; independent live/history progress remains recoverable. |
| Sessions finalized after enrollment end | `NativeCollectionReconciliationTests` (client and server), `NativeReconciliationJournalTests`, `NativeReconciliationClientTests`, `NativeReconciliationAcquisitionTests`: an ended plan alone never queries; an online instruction selects whole overlapping sleep, workout and accepted route windows only; renewal keeps identity, window and cursor; lease expiry and local withdrawal stop a selected page; the sweep completes once and its acknowledgement is retried without another query. |
| Participant identity | `SourceIdentityRecoveryTests`, `SourceSetupRecoveryTests`, `SourceIdentityKeyStoreTests`: authorized installations recover the same derivation context with independent credentials and cursors. Conflicting or missing recovery material fails explicitly. |
| Versioning, retraction and retries | `ClinicalRecordBundleTests`, `RecordBundleRecoveryTests`, `ClientDeliveryRecoveryTests`, `ClinicalRetractionTests`: partial outcomes and regrouped retries retain exact commitments; retractions and selected versions do not double-count logical measurements. |
| Source fidelity and route scope | `WorkoutRouteAcquisitionTests`, `WorkoutRouteStudyDataTests`, `WorkoutStudyDataTests`, `SleepCollectionTests`: complete sessions, native UUIDs and supporting context survive the permitted path; routes require their own accepted setting. Later route authorization can grant retained eligible data without uploading it again. |
| Capacity and recovery | `CollectionCapacityTests`, `ClinicalCapacityTests`, recording queue/transfer suites: a complete record above 4 MiB requires explicit larger settings; staging refusal preserves cursor and queued work; reopening with sufficient capacity resumes exact delivery. The gated large-record case recalculates content identity and uses the official validator. |
| Authorized disclosure | `StudyDataAccessTests`, `StudyDataFenceTests`, `StudyRecordingDownloadTests`: current authority and a committed disclosure audit precede release; wrong-study access, withdrawal/retraction races, failed audit and corrupt bytes release no recording. Compressed storage returns exact source bytes. |

Measure the combined workload separately: complete-record JSON processing, large
compressed route upload/download, and a pending backlog above 64 MiB while live
collection continues. Record peak RSS, durable storage, decoded/stored/wire byte
counts, configuration, elapsed time and interruption points. Chunk-size assertions
alone are not a peak-memory measurement. Defaults remain unchanged; larger
configuration options require evidence appropriate to the selected deployment.

## Physical-device acceptance

Use dedicated consenting test participants and two authorized iPhones with the
latest stable iOS release. Record device model, OS build, app build, source and
backend revisions, accepted study revisions and collection settings. Record
whether background processing, HealthKit permissions, protected-data access and
network connectivity were available during each observation. An empty HealthKit
query does not prove permission denial or missing source data.

1. **Accept two distinct study plans.** Configure study A for heart rate/sleep and
   study B for heart rate/workouts with routes enabled. Select six calendar months
   of history in a declared time zone. Review the displayed scope and accept each
   revision. Confirm retained boundaries match the accepted calendar interval,
   including data measured before acceptance. Publishing a broader revision alone
   must not broaden collection.
2. **Collect complete overlapping sessions.** Identify a sleep session and a
   workout spanning a chosen collection-window boundary. Verify their original
   start/end and complete permitted outputs survive custody/export. Verify native
   HealthKit UUIDs, available recording-device/writer facts, source metadata and
   conversion Provenance against the source store. Record unavailable or omitted
   values explicitly.
3. **Check shared collection and route isolation.** Upload overlapping heart-rate
   demand once. Verify one logical measurement with independent A/B grants; A sees
   sleep but no workout or route, and B sees workouts/routes but no sleep. Disable
   routes in a new accepted revision and verify future route-location reads stop while
   required previous disclosure/retraction evidence remains. Re-enabling routes
   must backfill the newly authorized gap without relying on the summary cursor.
4. **Exercise offline collection and restart.** Disconnect networking after
   authorization, collect new samples, terminate/relaunch the app, and allow
   background opportunities. Existing accepted plans must continue until their
   enrollment ends, including after token expiration; broader scope still needs
   online authorization. Inspect durable history/live cursors and pending records.
   Reconnect and verify unchanged queued bytes/identities and explicit delayed-upload
   outcomes. Record OS scheduling opportunities; do not claim uninterrupted
   background execution from a foreground-only run.
5. **Exercise enrollment end and withdrawal independently.** Use a test enrollment
   with a near-term end alongside an ongoing enrollment. Its collection stops at
   the known end without losing eligible queued data; the ongoing study continues.
   Withdraw locally while offline and verify an immediate local stop that survives
   restart. Separately revoke remotely while the device is offline, reconnect, and
   verify collection stops when the change is learned and server admission enforces
   current authority. Preserve an explicit disposition for pending work.
   After the near-term enrollment ended, finalize a sleep or workout session that
   overlaps its last window, then synchronize online. The session must arrive once
   under its original consent, no sample wholly outside the window may be collected,
   and a later synchronization must not query that window again.
6. **Verify reinstall and two-device replay.** First retain a known sample UUID and
   its source/output identifiers. Reinstall only the dedicated test installation,
   authenticate the same participant, recover the registered identity context,
   and replay the sample. Repeat from the second authorized iPhone when the source
   store exposes that same native UUID. Logical IDs must match, with independent
   installation credentials/cursors and conversion evidence. Distinct native UUIDs
   are not merged by time/value. Revoking one installation must not silently replace
   the shared identity or revoke the other installation.
7. **Verify corrections and source retraction.** Exercise a known record revision
   and an authorized source retraction, including replay after restart. Current
   exports must select the intended logical version without double counting;
   history retains the declared lineage. Test cross-device deletion authority:
   absence from one local query must not become irreversible shared-source deletion.
8. **Exercise bounded backlog recovery.** Use explicit test capacity settings to
   reach a pending/storage limit while new samples arrive. Observe actionable
   backpressure, unchanged failed-page cursors and no eviction. Interrupt upload,
   restart, then restore sufficient capacity and drain. Compare receipt commitments,
   retained records and recording hashes before/after; record memory/storage peaks.
9. **Verify authorized retrieval and downloads.** Retrieve through the web UI and
   Swift CLI using a researcher with study-data capability. Compare recording
   source bytes and FHIR attachment size/hash, including compressed storage.
   Test a foreign study, withdrawn grant, expired token and unavailable audit;
   no recording bytes may be released. A newly authorized study should reuse
   eligible retained records under its exact accepted window without another upload.
10. **Verify locked-device behavior.** Exercise background collection after first
    unlock, lock/unlock transitions and a device restart before first unlock.
    Record the platform behavior and explicit unavailability/retry outcomes;
    verify protected queue files remain intact. Simulator filesystem tests do not
    establish hardware-backed data protection.

For each step retain timestamps, expected/actual outcome, selected synthetic UUIDs
and logical IDs, sanitized logs, receipts, byte counts/hashes and relevant screenshots
or recordings. Keep participant data in the approved evidence location; never
record derivation keys, installation proofs, tokens or private signing material.
Mark each step passed, failed, blocked or not executed, with its evidence location.

## Completion boundaries

Conversion Provenance is required; cryptographic Provenance signing is not
implemented by the Trove receiver and remains optional future work in
[issue #134](https://github.com/SchmiedmayerLab/Trove/issues/134). HMAC identity
recovery is independent of signing. Do not describe unsigned data as signature-verified.

Close engineering work only against its executed evidence. Closing #137 additionally
requires its targeted physical-device evidence. The complete collection scope requires
implemented and tested coverage of all admitted adapters in
[issue #136](https://github.com/SchmiedmayerLab/Trove/issues/136). A coverage inventory
or prioritized release slices alone do not complete those implementations. Dependency release/adoption,
physical acceptance and field activation each retain their own recorded status;
review-ready implementation does not authorize merging or deployment.
