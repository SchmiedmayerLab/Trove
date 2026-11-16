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


struct SensorKitJournalTests {
    @Test
    func crashAfterStagingReplaysOnlyAcknowledgement() async throws {
        let fixture = SensorKitJournalFixture()
        try await fixture.withJournal { journal, url in
            let acquisition = try SensorKitAcquisition(journal: journal, scope: fixture.scope, validateSession: {})
            let batch = try fixture.batch {
                #expect(try await journal.pendingDeliveryIDs().count == 1)
                throw SensorKitJournalFixture.Failure.interrupted
            }
            await #expect(throws: SensorKitJournalFixture.Failure.self) {
                try await acquisition.stage(batch, localID: fixture.localID, queryID: fixture.localID)
            }
            let eventID = try #require(await journal.pendingDeliveryIDs().first)
            let exact = try #require(await journal.prepareAttempt(eventID)).bytes
            let cursor = try #require(await journal.checkpoint(for: fixture.sourceID).cursor)
            #expect(try SensorKitBatchReceipt(encoded: cursor).phase == .staged)
            await journal.close()
            let restored = try EventDeliveryJournal(url: url, scope: fixture.scope, mode: .openExisting)
            let retry = try SensorKitAcquisition(journal: restored, scope: fixture.scope, validateSession: {})
            let page = try await retry.stage(fixture.batch(), localID: fixture.localID, queryID: fixture.localID)
            #expect(page.recoveredStagedBatch)
            #expect(page.eventIDs.isEmpty)
            #expect(try await restored.pendingDeliveryIDs() == [eventID])
            #expect(try await restored.prepareAttempt(eventID)?.bytes == exact)
            await restored.close()
        }
    }

    @Test
    func capacityFailureRetainsPreparationWithoutAcknowledgement() async throws {
        let fixture = SensorKitJournalFixture()
        try await fixture.withJournal(limits: .init(maximumPayloadBytes: 1)) { journal, _ in
            let acquisition = try SensorKitAcquisition(journal: journal, scope: fixture.scope, validateSession: {})
            let batch = try fixture.batch { Issue.record("Capacity failure acknowledged native cursor") }
            await #expect(throws: EventDeliveryJournal.JournalError.capacityExceeded) {
                try await acquisition.stage(batch, localID: fixture.localID, queryID: fixture.localID)
            }
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            let cursor = try #require(await journal.checkpoint(for: fixture.sourceID).cursor)
            #expect(try SensorKitBatchReceipt(encoded: cursor).phase == .prepared)
        }
    }

    @Test
    func conversionRefusalNeverAdvancesNativeCursor() async throws {
        let fixture = SensorKitJournalFixture()
        try await fixture.withJournal { journal, _ in
            let acquisition = try SensorKitAcquisition(journal: journal, scope: fixture.scope, validateSession: {})
            let batch = try fixture.batch(valid: false) { Issue.record("Refused batch acknowledged native cursor") }
            await #expect(throws: SensorKitAcquisition.AcquisitionError.conversionRefused) {
                try await acquisition.stage(batch, localID: fixture.localID, queryID: fixture.localID)
            }
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            let cursor = try #require(await journal.checkpoint(for: fixture.sourceID).cursor)
            #expect(try SensorKitBatchReceipt(encoded: cursor).phase == .prepared)
        }
    }

    @Test
    func accountChangeAfterPreparationCannotStageOrAcknowledge() async throws {
        let fixture = SensorKitJournalFixture()
        try await fixture.withJournal { journal, _ in
            let acquisition = try SensorKitAcquisition(journal: journal, scope: fixture.scope) {
                if try await journal.checkpoint(for: fixture.sourceID).cursor != nil {
                    throw SensorKitJournalFixture.Failure.interrupted
                }
            }
            let batch = try fixture.batch { Issue.record("Previous account acknowledged native cursor") }
            await #expect(throws: SensorKitAcquisition.AcquisitionError.authenticationRequired) {
                try await acquisition.stage(batch, localID: fixture.localID, queryID: fixture.localID)
            }
            #expect(try await journal.pendingDeliveryIDs().isEmpty)
            let cursor = try #require(await journal.checkpoint(for: fixture.sourceID).cursor)
            #expect(try SensorKitBatchReceipt(encoded: cursor).phase == .prepared)
        }
    }

    @Test
    func localWithdrawalRejectsStagedReplayWithoutDeletingQueuedBytes() async throws {
        let fixture = SensorKitJournalFixture()
        try await fixture.withJournal { journal, _ in
            let acquisition = try SensorKitAcquisition(journal: journal, scope: fixture.scope, validateSession: {})
            await #expect(throws: SensorKitJournalFixture.Failure.self) {
                try await acquisition.stage(
                    fixture.batch { throw SensorKitJournalFixture.Failure.interrupted },
                    localID: fixture.localID,
                    queryID: fixture.localID
                )
            }
            let before = try await journal.pendingDeliveryIDs()
            try await journal.stopCollection(for: fixture.enrollmentID)
            let batch = try fixture.batch { Issue.record("Withdrawal acknowledged native cursor") }
            await #expect(throws: ParticipantCollectionSnapshot.CollectionError.collectionNotAuthorized) {
                try await acquisition.stage(batch, localID: fixture.localID, queryID: fixture.localID)
            }
            #expect(try await journal.pendingDeliveryIDs() == before)
        }
    }
}
