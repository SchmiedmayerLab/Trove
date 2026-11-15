//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

#if os(iOS)
import Foundation
import GroveFHIRContract
@testable import GroveSensorKit
import GroveSensorKitFHIR
import SensorKit
import Testing
import TroveAPIClient
@testable import TroveSensorKit


struct SensorKitHybridAcquisitionTests {
    @Test(arguments: [SensorKitStructuredContract.electrocardiogram, .deviceUsage])
    func nativeFileAndSummaryStageWithIndependentGrantsAndExactRetry(contract: SensorKitStructuredContract) async throws {
        let fixture = SensorKitRecordingFixture(contract: contract)
        try await fixture.journal.withJournal(sourceToken: fixture.entry.sourceToken, collectionSnapshot: fixture.snapshot()) { journal, _ in
            let acquisition = try SensorKitAcquisition(journal: journal, scope: fixture.journal.scope, validateSession: {})
            let batch = try Self.batch(fixture)
            let first = try await acquisition.stage(batch, localID: fixture.journal.localID, queryID: fixture.journal.localID)
            #expect(first.sampleCount == 1)
            let eventID = try #require(await journal.pendingDeliveryIDs().first)
            let reference = try #require(await journal.recordingReferences(for: eventID).first)
            let commitment = try #require(await journal.recordingTransfer(for: reference.id)?.commitment)
            #expect(commitment.declaration.format == RegisteredRecordingFormat.nativeRecording.rawValue)
            #expect(commitment.declaration.sourceTypeIdentifier == batch.sourceToken)
            #expect(commitment.declaration.targets.map(\.consentId) == [fixture.recordingConsentID.uuidString.lowercased()])
            let attempt = try #require(await journal.prepareAttempt(eventID))
            #expect(attempt.commitment.targetIntent.targets.count == 2)
            let retry = try await acquisition.stage(batch, localID: fixture.journal.localID, queryID: fixture.journal.localID)
            #expect(retry.recoveredStagedBatch)
            #expect(try await journal.prepareAttempt(eventID)?.bytes == attempt.bytes)
            if let directory = ProcessInfo.processInfo.environment["TROVE_SENSOR_KIT_FIXTURE_DIRECTORY"] {
                try attempt.bytes.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent(contract.rawValue + ".json"), options: .withoutOverwriting
                )
            }
        }
    }

    @Test
    func preparedBundleBytesRespectTheConfiguredAggregateBudget() async throws {
        let fixture = SensorKitRecordingFixture(contract: .deviceUsage)
        let snapshot = try fixture.snapshot()
        try await fixture.journal.withJournal(sourceToken: fixture.entry.sourceToken, collectionSnapshot: snapshot) { journal, _ in
            let source = try #require(await journal.sourceSetup(for: fixture.journal.localID).binding?.source)
            let first = try Self.batch(fixture)
            let second = try Self.batch(fixture, sourceRecordID: UUID())
            let exporter = try await SensorKitAcquisition.exporter(
                source: source, privacy: journal.identityScope(for: fixture.journal.sourceID), facts: first.facts
            )
            var limits = await journal.configuredLimits
            let single = try await SensorKitAcquisition.payloads(
                first.inputs, exporter: exporter, facts: first.facts, snapshot: snapshot, limits: limits
            )
            let size = try #require(single.payloads.first).bytes.count
            limits.maximumBytes = size * 2 - 1
            let bounded = limits
            await #expect(throws: EventDeliveryJournal.JournalError.capacityExceeded) {
                try await SensorKitAcquisition.payloads(
                    first.inputs + second.inputs, exporter: exporter, facts: first.facts, snapshot: snapshot, limits: bounded
                )
            }
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            #expect(try await journal.checkpoint(for: fixture.journal.sourceID).cursor == nil)
        }
    }

    @Test
    func individuallyValidFilesCannotExceedTheAggregatePreparationBudget() async throws {
        let fixture = SensorKitRecordingFixture(contract: .deviceUsage)
        let input = try #require(Self.batch(fixture).inputs.first)
        let fileBytes = try #require(input.recordings.first).file.byteCount
        let limits = EventDeliveryJournal.Limits(maximumRecordingBytes: fileBytes, maximumPendingRecordingBytes: fileBytes * 2 - 1)
        let native = try Self.nativeUsageBatch(start: fixture.journal.instant)
        try await fixture.journal.withJournal(
            limits: limits, sourceToken: fixture.entry.sourceToken, collectionSnapshot: fixture.snapshot()
        ) { journal, _ in
            let acquisition = try SensorKitAcquisition(journal: journal, scope: fixture.journal.scope, validateSession: {})
            let context = try SensorKitAcquisition.RecordingBatchContext(
                localID: fixture.journal.localID, queryID: fixture.journal.localID, facts: fixture.journal.batch().facts
            )
            await #expect(throws: EventDeliveryJournal.JournalError.capacityExceeded) {
                try await acquisition.collectRecordedSamples(native, for: Sensor.deviceUsage, context: context) { _, _, _, _ in input }
            }
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            #expect(try await journal.checkpoint(for: fixture.journal.sourceID).cursor == nil)
        }
    }

    @Test(arguments: [SensorKitStructuredContract.electrocardiogram, .deviceUsage])
    func missingOriginalAuthorityCannotAdvanceOrStage(contract: SensorKitStructuredContract) async throws {
        let fixture = SensorKitRecordingFixture(contract: contract)
        try await fixture.journal.withJournal(
            sourceToken: fixture.entry.sourceToken, collectionSnapshot: fixture.snapshot(includeRecording: false)
        ) { journal, _ in
            let acquisition = try SensorKitAcquisition(journal: journal, scope: fixture.journal.scope, validateSession: {})
            let batch = try Self.batch(fixture) { Issue.record("Unauthorized companion acknowledged") }
            await #expect(throws: ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized) {
                try await acquisition.stage(batch, localID: fixture.journal.localID, queryID: fixture.journal.localID)
            }
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
        }
    }
}


extension SensorKitHybridAcquisitionTests {
    private static func nativeUsageBatch(
        start: Date
    ) throws -> GroveSensorKit.SensorKit.AnchoredBatch<SRDeviceUsageReport.SafeRepresentation> {
        let cursor = try ManagedQueryAnchor.ephemeral(startDate: start).value.preparing(
            .sampleCount(deliveryTimestamp: start.addingTimeInterval(60), sampleCount: 2)
        )
        let device = GroveSensorKit.SensorKit.DeviceInfo(.current)
        let token = try GroveSensorKit.SensorKit.BatchReplayToken(
            sensorIdentifier: Sensor.deviceUsage.id, deviceProductType: device.productType, anchor: cursor
        )
        let report = SRDeviceUsageReport.SafeRepresentation(
            timestamp: start, duration: 60, totalScreenWakes: 1, totalUnlocks: 1, totalUnlockDuration: 10, version: "synthetic/1"
        )
        return .init(
            info: .init(
                timeRange: start..<start.addingTimeInterval(60),
                device: device,
                acquisitionBatch: cursor.acquisitionBatchCoordinate,
                replayToken: token
            ),
            samples: [report, report],
            acknowledgement: .init { Issue.record("Preparation capacity failure acknowledged native data") }
        )
    }

    private static func batch(
        _ fixture: SensorKitRecordingFixture, sourceRecordID: UUID? = nil, acknowledge: @escaping @Sendable () async throws -> Void = {}
    ) throws -> SensorKitAcquisition.Batch {
        let start = Date(timeIntervalSince1970: floor(fixture.journal.instant.timeIntervalSince1970))
        let file: SensorKitPreparedStructuredFile
        let period: DateInterval
        switch fixture.contract {
        case .electrocardiogram:
            let session = SensorKitECGSession(
                startDate: start.addingTimeInterval(-1),
                sessionIdentifier: "synthetic-session",
                sessionStates: [.begin, .active, .end],
                frequency: Measurement(value: 512, unit: .hertz),
                lead: .rightArmMinusLeftArm,
                guidance: .guided,
                batches: [
                    .init(offset: 1, samples: (0..<512).map { index in
                        .init(flags: [], voltage: Measurement(value: Double(index % 10), unit: .microvolts))
                    })
                ]
            )
            file = try SensorKitPreparedStructuredFile(electrocardiogram: session, maximumByteCount: 1024 * 1024)
            period = DateInterval(start: start, duration: 511.0 / 512)
        case .deviceUsage:
            let report = SRDeviceUsageReport.SafeRepresentation(
                timestamp: start, duration: 60, totalScreenWakes: 3, totalUnlocks: 2, totalUnlockDuration: 20, version: "synthetic/1"
            )
            file = try SensorKitPreparedStructuredFile(deviceUsage: report, maximumByteCount: 1024 * 1024)
            period = DateInterval(start: start, duration: 60)
        default: throw SensorKitAcquisition.AcquisitionError.invalidBatch
        }
        let input = try SensorKitAcquisition.structuredFileInput(
            file,
            entry: fixture.entry,
            sourceID: SensorKitSourceRecordID(sourceRecordID ?? fixture.journal.recordID),
            title: "Synthetic session",
            period: period
        )
        return try .init(
            coordinate: "hybrid-session-one",
            sourceToken: fixture.entry.sourceToken,
            deviceProductType: "Watch1,1",
            inputs: [input],
            facts: fixture.journal.batch().facts,
            acknowledge: acknowledge,
            replayToken: Data([1])
        )
    }
}
#endif
