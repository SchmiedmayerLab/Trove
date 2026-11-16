//
// This source file is part of the Trove open-source project
//
// SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
//
// SPDX-License-Identifier: MIT
//

import Foundation
import Testing
import TroveAPIClient
@testable import TroveSensorKit


struct SensorKitSliceJournalTests {
    @Test
    func sliceCoverageAndQueuedIntentsSurviveRestartUnchanged() async throws {
        let fixture = SensorKitRecordingFixture()
        let snapshot = try fixture.snapshot(studyWindows: [(-3600, nil), (0.5, 1)])
        try await fixture.journal.withJournal(sourceToken: fixture.entry.sourceToken, collectionSnapshot: snapshot) { journal, url in
            var batch = try fixture.batch()
            batch.slicePreparation = try fixture.slicePreparation(snapshot: snapshot, state: await journal.collectionState())
            batch.usesRecordingSlices = true
            let slices = try #require(batch.slicePreparation?.slices)
            let acquisition = try SensorKitAcquisition(journal: journal, scope: fixture.journal.scope, validateSession: {})
            _ = try await acquisition.stage(batch, localID: fixture.journal.localID, queryID: fixture.journal.localID)
            let queued = try await journal.pendingDeliveryIDs()
            var attempts: [UUID: Data] = [:]
            for eventID in queued { attempts[eventID] = try await journal.prepareAttempt(eventID)?.bytes }
            await journal.close()

            let reopened = try EventDeliveryJournal(url: url, scope: fixture.journal.scope, mode: .openExisting)
            #expect(try await Self.slices(of: batch, fixture: fixture, in: reopened) == slices)
            let retry = try SensorKitAcquisition(journal: reopened, scope: fixture.journal.scope, validateSession: {})
            let page = try await retry.stage(batch, localID: fixture.journal.localID, queryID: fixture.journal.localID)
            #expect(page.recoveredStagedBatch && page.eventIDs.isEmpty)
            #expect(try await reopened.pendingDeliveryIDs() == queued)
            for eventID in queued {
                #expect(try await reopened.prepareAttempt(eventID)?.bytes == attempts[eventID])
            }
            #expect(try await Self.slices(of: batch, fixture: fixture, in: reopened) == slices)
            await reopened.close()
        }
    }

    @Test(arguments: ["files", "bytes"])
    func sliceBudgetRefusalRetainsNoSliceAndDoesNotAcknowledge(budget: String) async throws {
        let fixture = SensorKitRecordingFixture()
        let snapshot = try fixture.snapshot(studyWindows: [(-3600, nil), (0.5, 1)])
        // Three slices are planned; the journal admits two files or fewer bytes than their compressed recordings.
        let limits: EventDeliveryJournal.Limits = budget == "files" ? .init(maximumRecordingFiles: 2) : .init(maximumPendingRecordingBytes: 64)
        try await fixture.journal.withJournal(
            limits: limits, sourceToken: fixture.entry.sourceToken, collectionSnapshot: snapshot
        ) { journal, _ in
            var batch = try fixture.batch { Issue.record("A refused slice batch acknowledged native data") }
            batch.slicePreparation = try fixture.slicePreparation(snapshot: snapshot, state: await journal.collectionState())
            batch.usesRecordingSlices = true
            #expect(batch.slicePreparation?.slices.count == 3)
            let acquisition = try SensorKitAcquisition(journal: journal, scope: fixture.journal.scope, validateSession: {})
            await #expect(throws: EventDeliveryJournal.JournalError.capacityExceeded) {
                try await acquisition.stage(batch, localID: fixture.journal.localID, queryID: fixture.journal.localID)
            }
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            #expect(try await Self.slices(of: batch, fixture: fixture, in: journal).isEmpty)
            let cursor = try #require(await journal.checkpoint(for: fixture.journal.sourceID).cursor)
            #expect(try SensorKitBatchReceipt(encoded: cursor).phase == .prepared)
        }
    }
}


extension SensorKitSliceJournalTests {
    private static func slices(
        of batch: SensorKitAcquisition.Batch, fixture: SensorKitRecordingFixture, in journal: EventDeliveryJournal
    ) async throws -> [SensorKitRecordingSlice] {
        try await journal.sensorKitRecordingSlices(
            sourceID: fixture.journal.sourceID,
            sourceTypeIdentifier: batch.sourceToken,
            deviceProductType: batch.deviceProductType,
            coordinate: batch.coordinate
        )
    }
}
