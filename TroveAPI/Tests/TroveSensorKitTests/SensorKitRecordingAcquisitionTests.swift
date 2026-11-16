//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import GroveFHIRContract
import GroveSensorKitFHIR
import Testing
import TroveAPIClient
@testable import TroveSensorKit


struct SensorKitRecordingAcquisitionTests {
    @Test
    func companionTransferAndReceiptSurviveRestartWithIndependentStudyTargets() async throws {
        let fixture = SensorKitRecordingFixture()
        let snapshot = try fixture.snapshot()
        try await fixture.journal.withJournal(sourceToken: fixture.entry.sourceToken, collectionSnapshot: snapshot) { journal, url in
            let acquisition = try SensorKitAcquisition(journal: journal, scope: fixture.journal.scope, validateSession: {})
            let batch = try fixture.batch { throw SensorKitJournalFixture.Failure.interrupted }
            await #expect(throws: SensorKitJournalFixture.Failure.self) {
                try await acquisition.stage(batch, localID: fixture.journal.localID, queryID: fixture.journal.localID)
            }
            let eventID = try #require(await journal.pendingDeliveryIDs().first)
            let recording = try #require(await journal.recordingReferences(for: eventID).first)
            let transfer = try #require(await journal.recordingTransfer(for: recording.id))
            let declaration = transfer.commitment.declaration
            #expect(declaration.sourceTypeIdentifier == batch.sourceToken)
            #expect(declaration.content.encoding == .zstd)
            #expect(declaration.content.storedByteCount < declaration.content.sourceByteCount)
            #expect(declaration.targets.map(\.consentId) == [fixture.recordingConsentID.uuidString.lowercased()])
            let attempt = try #require(await journal.prepareAttempt(eventID))
            try emitFixture(attempt.bytes)
            let targets = attempt.commitment.targetIntent.targets
            #expect(targets.count == 2)
            let byConsent = Dictionary(uniqueKeysWithValues: targets.map {
                ($0.consentID.uuidString.lowercased(), $0.outputFullURLs)
            })
            #expect(byConsent[fixture.recordingConsentID.uuidString.lowercased()] == [declaration.outputFullUrl])
            #expect(byConsent[fixture.journal.consentID.uuidString.lowercased()]?.count == 1)
            #expect(byConsent[fixture.journal.consentID.uuidString.lowercased()]?.contains(declaration.outputFullUrl) == false)
            await journal.close()
            let reopened = try EventDeliveryJournal(url: url, scope: fixture.journal.scope, mode: .openExisting)
            let retry = try SensorKitAcquisition(journal: reopened, scope: fixture.journal.scope, validateSession: {})
            let page = try await retry.stage(fixture.batch(), localID: fixture.journal.localID, queryID: fixture.journal.localID)
            #expect(page.recoveredStagedBatch && page.sampleCount == 128)
            #expect(try await reopened.pendingDeliveryIDs() == [eventID])
            #expect(try await reopened.recordingTransfer(for: recording.id)?.commitment.serialized == transfer.commitment.serialized)
            #expect(try await reopened.prepareAttempt(eventID)?.bytes == attempt.bytes)
            await reopened.close()
        }
    }

    @Test
    func recordingCapacityFailureCannotStageAuthorityOrAcknowledge() async throws {
        let fixture = SensorKitRecordingFixture()
        let snapshot = try fixture.snapshot()
        try await fixture.journal.withJournal(
            limits: .init(maximumPayloadBytes: 1), sourceToken: fixture.entry.sourceToken, collectionSnapshot: snapshot
        ) { journal, _ in
            let acquisition = try SensorKitAcquisition(journal: journal, scope: fixture.journal.scope, validateSession: {})
            let batch = try fixture.batch { Issue.record("Failed recording staging acknowledged native data") }
            await #expect(throws: EventDeliveryJournal.JournalError.capacityExceeded) {
                try await acquisition.stage(batch, localID: fixture.journal.localID, queryID: fixture.journal.localID)
            }
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            let cursor = try #require(await journal.checkpoint(for: fixture.journal.sourceID).cursor)
            #expect(try SensorKitBatchReceipt(encoded: cursor).phase == .prepared)
            let retained = try #require(await journal.sensorKitBatchEvidencePage(
                sourceID: fixture.journal.sourceID, sourceTypeIdentifier: batch.sourceToken, deviceProductType: batch.deviceProductType
            ).first)
            #expect(retained.evidence.coordinate == batch.coordinate)
            #expect(retained.stagedAuthority == nil)
        }
    }

    @Test
    func evidenceMismatchRollsBackRecordingAndCursorInTheSameTransaction() async throws {
        let fixture = SensorKitRecordingFixture()
        let snapshot = try fixture.snapshot()
        try await fixture.journal.withJournal(sourceToken: fixture.entry.sourceToken, collectionSnapshot: snapshot) { journal, _ in
            let batch = try fixture.batch()
            let state = try await journal.collectionState()
            var checkpoint = try await journal.collectionCheckpoint(for: fixture.journal.sourceID, state: state, queryID: fixture.journal.localID)
            let receipt = try SensorKitBatchReceipt(batch: batch)
            let evidence = try fixture.evidence(batch)
            try await journal.prepareSensorKitBatch(from: checkpoint, nextCursor: receipt.encoded(), evidence: evidence)
            checkpoint = try await journal.collectionCheckpoint(for: fixture.journal.sourceID, state: state, queryID: fixture.journal.localID)
            let source = try #require(await journal.sourceSetup(for: fixture.journal.localID).binding?.source)
            let exporter = try await SensorKitAcquisition.exporter(
                source: source, privacy: journal.identityScope(for: fixture.journal.sourceID), facts: batch.facts
            )
            let prepared = try await SensorKitAcquisition.payloads(
                batch.inputs, exporter: exporter, facts: batch.facts, snapshot: snapshot, limits: journal.configuredLimits
            )
            let altered = try fixture.evidence(batch, endOffset: 1)
            await #expect(throws: EventDeliveryJournal.JournalError.eventIdentityMismatch) {
                try await journal.stageSensorKitBatch(
                    from: checkpoint,
                    nextCursor: Data([2]),
                    payloads: prepared.payloads,
                    evidence: altered,
                    authority: snapshot.authorityFingerprint(),
                    recordingDeclarations: prepared.declarations
                )
            }
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            #expect(try await journal.checkpoint(for: fixture.journal.sourceID).cursor == checkpoint.cursor)
            #expect(try await journal.sensorKitBatchEvidencePage(
                sourceID: fixture.journal.sourceID, sourceTypeIdentifier: batch.sourceToken
            ).first?.stagedAuthority == nil)
        }
    }

    @Test
    func eachStudyReceivesOnlySlicesInsideItsWindowAndSliceCoverageIsRetained() async throws {
        let fixture = SensorKitRecordingFixture()
        // The second study accepted only rows 50-99 of the 128-row native batch.
        let snapshot = try fixture.snapshot(studyWindows: [(-3600, nil), (0.5, 1)])
        try await fixture.journal.withJournal(sourceToken: fixture.entry.sourceToken, collectionSnapshot: snapshot) { journal, _ in
            let preparation = try fixture.slicePreparation(snapshot: snapshot, state: await journal.collectionState())
            let slices = preparation.slices
            #expect(slices.map(\.rows) == [0..<50, 50..<100, 100..<128])
            var batch = try fixture.batch()
            batch.slicePreparation = preparation
            batch.usesRecordingSlices = true
            let acquisition = try SensorKitAcquisition(journal: journal, scope: fixture.journal.scope, validateSession: {})
            _ = try await acquisition.stage(batch, localID: fixture.journal.localID, queryID: fixture.journal.localID)

            let both = Set([fixture.journal.consentID, fixture.recordingConsentID].map { $0.uuidString.lowercased() })
            var targets: [Date: Set<String>] = [:]
            for eventID in try await journal.pendingDeliveryIDs() {
                let recording = try #require(await journal.recordingReferences(for: eventID).first)
                let declaration = try #require(await journal.recordingTransfer(for: recording.id)).commitment.declaration
                let attempt = try #require(await journal.prepareAttempt(eventID))
                let consents = Set(attempt.commitment.targetIntent.targets.map { $0.consentID.uuidString.lowercased() })
                #expect(Set(declaration.targets.map(\.consentId)) == consents)
                targets[declaration.effectiveAt] = consents
            }
            #expect(targets.count == 3)
            #expect(targets[fixture.rowInterval(0).lowerBound] == [fixture.journal.consentID.uuidString.lowercased()])
            #expect(targets[fixture.rowInterval(50).lowerBound] == both)
            #expect(targets[fixture.rowInterval(100).lowerBound] == [fixture.journal.consentID.uuidString.lowercased()])
            #expect(try await journal.sensorKitRecordingSlices(
                sourceID: fixture.journal.sourceID,
                sourceTypeIdentifier: batch.sourceToken,
                deviceProductType: batch.deviceProductType,
                coordinate: batch.coordinate
            ) == slices)
        }
    }

    @Test
    func photoplethysmogramSampleStagesItsBinaryRecordingAndSummaryForSeparateStudies() async throws {
        let fixture = SensorKitRecordingFixture(contract: .ppg)
        try await fixture.journal.withJournal(sourceToken: fixture.entry.sourceToken, collectionSnapshot: fixture.snapshot()) { journal, _ in
            let prepared = try fixture.photoplethysmogram().prepared()
            let input = try await SensorKitAcquisition.photoplethysmogramInput(
                prepared, entry: fixture.entry, sourceID: .init(fixture.journal.recordID), title: "PPG", maximumByteCount: 1024 * 1024
            )
            #expect(input.start == fixture.rowInstant && input.end == fixture.rowInstant.addingTimeInterval(1))
            await #expect(throws: (any Error).self) {
                try await SensorKitAcquisition.photoplethysmogramInput(
                    prepared, entry: fixture.entry, sourceID: .init(UUID()), title: "PPG", maximumByteCount: prepared.data.count - 1
                )
            }
            let batch = try SensorKitAcquisition.Batch(
                coordinate: "ppg-batch-one",
                sourceToken: fixture.entry.sourceToken,
                deviceProductType: "Watch1,1",
                inputs: [input],
                facts: fixture.journal.batch().facts,
                acknowledge: {},
                replayToken: Data([1]),
                nativeSampleCount: 1
            )
            let acquisition = try SensorKitAcquisition(journal: journal, scope: fixture.journal.scope, validateSession: {})
            _ = try await acquisition.stage(batch, localID: fixture.journal.localID, queryID: fixture.journal.localID)
            let eventID = try #require(await journal.pendingDeliveryIDs().first)
            let reference = try #require(await journal.recordingReferences(for: eventID).first)
            let declaration = try #require(await journal.recordingTransfer(for: reference.id)).commitment.declaration
            #expect(declaration.format == RegisteredRecordingFormat.photoplethysmogramSamples.rawValue)
            #expect(declaration.content.sourceByteCount == Int64(prepared.data.count))
            #expect(declaration.targets.map(\.consentId) == [fixture.recordingConsentID.uuidString.lowercased()])
            #expect(try await journal.prepareAttempt(eventID)?.commitment.targetIntent.targets.count == 2)
        }
    }

    private func emitFixture(_ bytes: Data) throws {
        guard let path = ProcessInfo.processInfo.environment["TROVE_SENSOR_KIT_FIXTURE_DIRECTORY"] else {
            return
        }
        try bytes.write(to: URL(fileURLWithPath: path).appendingPathComponent("accelerometer.json"), options: .withoutOverwriting)
    }
}
